# Operations

## Build and run

```
zig build                      # debug binary in zig-out/bin/warden
zig build -Doptimize=ReleaseSafe
./run.sh                       # sources .env and runs the binary
```

Zig 0.16. System libraries: `libpq`, `libolm`, `tdjson`. External tools
used at runtime when their features are on: `ffmpeg`/`ffprobe`, `yt-dlp`,
`node` (word cloud / pie chart renderers under `tools/`), converters
(ImageMagick, LibreOffice, ...), a `whisper-server`, a SearXNG instance.

Docker: the `Dockerfile` builds `ReleaseSafe` for `x86_64-linux-musl` and
installs the runtime tools; `compose.yaml` runs `warden` + `searxng` (+
`postgres` via an override on hosts that self-host it). Always name the
services (`docker compose up -d --build warden searxng postgres`) —
`llama-server` in the compose file is not meant to start by default.
Images are ~2.5 GB; prune build cache after a build on small hosts.

## Health

- `Heartbeat`: one timestamp per connector (last successful poll) plus one
  for the scheduler loop, written to `<WARDEN_TMP_DIR>/heartbeat` every
  cycle.
- `warden --healthcheck` (Docker `HEALTHCHECK`) reads that file in a fresh
  process and exits non-zero if any timestamp is older than 120 s or the
  file is missing. It runs before config load so it never depends on the
  bot's startup.
- The **self-watchdog** thread checks the in-process heartbeat every 60 s
  and exits the process if anything is older than 300 s, so `restart:
  unless-stopped` recovers a wedged bot even when nothing acts on the
  Docker health status. Timestamps are seeded to startup time, not 0 (a
  0-seeded slot once crash-looped every fresh container).
- A scheduler tick taking more than 10 s logs at WARN.

## Logging (`src/log.zig`)

Fixed-width columns: timestamp, level, scope, message. Levels
`debug < info < notice < warn < err < fatal`; `WARDEN_LOG_LEVEL` filters
at runtime. `std.log` calls elsewhere render through the same formatter.
Under systemd/Docker: `journalctl -u warden.service`, `docker logs`.

Useful lines when diagnosing a hang: each message task logs when it starts
(`task started`) and when it finishes; one that starts and never finishes is
what was in flight when the process died.

## Timeouts and retries

| Call | Bound |
|---|---|
| HTTP GET/POST (Telegram, tools) | 45 s (`http_util.default_timeout_ns`), 2 retries on transient connection errors, `keep_alive = false` |
| LLM calls (incl. SSE streaming) | 2 min per call, retried by the tool loop per `WARDEN_LLM_MAX_RETRIES` |
| Postgres | `connect_timeout=10`, statement timeout + client-side deadline (storage.md) |
| XMPP reads | bounded poll on a persistent background read |
| Placeholder ticker | 1.2 s cadence, stopped with a 5 s bounded join |

On timeout the blocked helper thread is detached and abandoned (a small,
bounded leak) rather than cancelled — cancellation can't interrupt these
calls (decisions.md). The poll loop sleeps 5 s after a failed poll.

## Startup requirements and failure modes

- Missing Telegram token/owner id or Postgres DSN: fatal at config load.
- Neither LLM provider configured: fatal. One configured: the other is
  simply unavailable to `WARDEN_LLM_PROVIDER` switching.
- Optional subsystems (Matrix E2EE init, the API server, the watchdog
  thread) log and continue on failure.
- Two bot instances sharing one bot token fight over `getUpdates`
  (Telegram 409s) — never run two against the same token.

## Deploying

The general sequence that has worked: tag the current image as a rollback
(`docker tag warden:latest warden:rollback-<date>`), sync the tree (dry-run
an `rsync --delete` first and read the deletions), build, verify the new
image's `Created` timestamp, restart the unit, poll the container's health
until `healthy`, confirm `select max(version) from schema_migrations`
advanced and any new columns exist. Migrations are automatic and logged;
destructive ones (drops) are called out in their SQL header.

Keep exactly one rollback tag; prune build cache after each build.
