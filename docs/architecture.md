# Architecture

Warden is one Zig binary (`src/main.zig`) plus one Postgres database. It
runs several platform connectors concurrently, funnels every inbound message
through one pipeline, and answers through the connector the message came
from.

## Module layout

| Path | Role |
|---|---|
| `src/main.zig` | Startup, poll loops, the scheduler loop, the per-message pipeline and the whole slash-command dispatch chain |
| `src/config.zig` | Environment-variable config (`Config.load`) |
| `src/auth.zig` | Owner / admin permission ladder (see access-control.md) |
| `src/platform/` | `interface.zig` (the `Connector` vtable + `Message`), one directory per platform, `reply_redirect.zig` |
| `src/llm/` | Provider interface, Anthropic and OpenAI-compatible adapters, the tool-calling loop, embeddings, delegates |
| `src/tools/` | One file per LLM tool; `registry.zig` holds `ToolDef`, `ToolContext` and the sink interfaces tools use to reach the store |
| `src/features/` | Feature logic that is not a store and not a platform (reminders formatting, digests, menu, convert, storage sense, ...) |
| `src/store/` | One module per table group, `db.zig`/`pool.zig` for Postgres, `migrate.zig` + `migrations/*.sql` |
| `src/api/` | The HTTP/WebSocket API for warden-ui |
| `src/text/` | Pure text utilities (civil time, the ReDoS-safe regex engine) |
| `src/http_util.zig` | Shared HTTP helpers with timeouts and retries |
| `src/worker_pool.zig` | Fixed-size OS-thread pool used per platform |
| `src/log.zig` | Tabular leveled logger, `WARDEN_LOG_LEVEL` |

Layering rule: `tools/registry.zig` is imported by every tool and must never
import the store layer; tools reach persistent state through sink vtables
(`ReminderSink`, `NoteSink`, `MemoryTools`, ...) that `main.zig` wires with
real store-backed adapters per message. Features are "pure functions over
pool/io/config" where possible so they can be tested offline.

## Process model

Startup (`main`):

1. If invoked as the Docker healthcheck (`--healthcheck`), read the heartbeat
   file and exit — before loading config, so a probe never depends on the
   bot's own startup.
2. Load `Config`, build every configured LLM provider (both Anthropic and
   OpenAI-compatible when both have credentials, so `WARDEN_LLM_PROVIDER`
   can be hot-swapped through dynamic config), the embeddings client, and
   every configured delegate provider.
3. Open the Postgres pool and run migrations.
4. Construct connectors: Telegram Bot API (always), Matrix, XMPP, the
   personal Telegram account (TDLib) and Instagram when configured. Matrix
   E2EE state is initialised here when `WARDEN_MATRIX_PICKLE_KEY` is set;
   failure is logged, not fatal.
5. Per connector: one dedicated poll thread (`connectorPollLoop`) and one
   `MessageWorkerPool` of `WARDEN_WORKERS_PER_PLATFORM` OS threads. The poll
   thread only polls and enqueues; workers run `processMessageTask`.
6. One scheduler loop on the main thread, ticking every ~30 s: due
   reminders, alerts, feed watches, digests, briefings, announcements, the
   curated feed, storage sense.
7. A self-watchdog thread and, if `WARDEN_API_PORT` is set, the API server.

Why real `std.Thread`s and not `Io.Group.async`: Zig 0.16's implicit
`Io.Threaded` pool is bounded to `cpu_count - 1` slots (0 on a 1-vCPU host)
and runs work *inline on the caller* once exhausted, which serialised every
message behind the poll loop in production. Warden owns its threads instead
(see decisions.md, "Per-platform worker pools").

Each connector's poll loop stamps a heartbeat slot after every successful
poll; the scheduler stamps its own. The heartbeat is written to
`<WARDEN_TMP_DIR>/heartbeat` for the healthcheck process and watched
in-process by the self-watchdog (see operations.md).

## The per-message pipeline

`processMessageTask` (one worker thread, one arena per task):

1. Housekeeping signals first: a connector's synthetic messages for "the bot
   left this chat", "chat migrated to a new id", "chat ingest only" (a
   channel the bot was added to), joins (welcome messages). These return
   before anything else.
2. Resolve the sender's identity row (`resolveSenderIdentity`), completing
   any pending username-based grant (`/blockuser @name`, `/addadmin @name`
   for a user never seen before).
3. Slow-mode check (may delete the message and stop).
4. Record the message (`messages` table) and touch chat membership; publish
   to Bot View subscribers; keyword alerts; passive video auto-download.
   These run for every sender — recording is not gated by access control.
5. Download an attachment to `WARDEN_TMP_DIR` if present (deleted at the end
   of the task unless the `/convert` flow claims it).
6. Build the `ToolContext` (sinks for reminders, notes, memory, expenses,
   the personal-account tools — the latter only when the sender is the
   owner).
7. `handleMessage`: the access gate (`routeIncoming`), then button/reaction
   picks, sleep-mode check, `/sudo` prefix, alias expansion, open `/menu`
   prompts, the pending `/convert` upload, management-room direct dispatch,
   then the long `else if` chain of slash commands, and finally free-form
   Q&A when the message is addressed to the bot (mention, reply to the
   bot, magic word, or a private chat).

`handleMessage` returns whether the `/convert` flow claimed the attachment.

## Connectors

`platform/interface.zig` defines `Connector` as a `ptr + vtable` with a
required core (`platform`, `poll`, `sendMessage`) and many optional slots
(`editMessage`, `sendPhoto`, `deleteMessage`, moderation actions,
`sendChoicePrompt`, `maxMessageLength`, ...). A missing slot reports
`error.Unsupported`; callers degrade ("log once, fall back") rather than
fail. See platforms.md for what each connector implements.

`Message` carries native ids (`chat_id`, `user_id`, `message_id`) as
strings; the internal `chats.id` / `identities.id` row ids are resolved
inside the pipeline. Mixing these two id spaces has caused real bugs (see
decisions.md, "Native vs internal ids").

`reply_redirect.zig` wraps a connector so a command can *act* on one chat
while its replies go to another — the mechanism behind `/as` and
management rooms.

## Scheduler

The scheduler loop runs the "due item" checks every ~30 s. Each check
delivers through whichever connector owns the chat's platform
(`findConnector`); a chat whose platform has no active connector is skipped
with a log line. A tick that takes more than 10 s is logged at WARN. The
curated feed has its own interval stored with its settings and only runs
when due.

## Concurrency primitives worth knowing

- Per-message work uses an `ArenaAllocator` owned by the task; provider
  responses and tool inputs borrow from it and are never freed separately.
- Anything that blocks on the network or on libpq runs under a deadline on
  a helper thread that is *detached and abandoned* on timeout (`http_util`,
  `db.runWithDeadline`, XMPP reads). `Io.concurrent` + `Future.cancel` was
  tried and cannot interrupt these calls (decisions.md, "Detach, don't
  cancel").
- Shared in-memory state touched from several threads (`Heartbeat`, menu
  sessions, pending confirmations, the Matrix encrypted-room cache, TDLib's
  request map) is guarded by atomics or `Io.Mutex`. Long-lived state that
  must survive a restart (reply drafts) lives in Postgres instead.
