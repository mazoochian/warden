# Decisions and incident history

The "why" behind code that would otherwise look odd. Dated where the date
matters. Newest additions go at the end of the relevant section.

## Concurrency and reliability

**Per-platform worker pools, not `Io.Group.async` (2026-07-22).** Zig
0.16's implicit `Io.Threaded` pool has `cpu_count - 1` slots and, once
full, runs further `.async()` calls inline on the caller. On the 1-vCPU
production host that was 0 slots: every message ran serially on the poll
loop's own thread, so one stuck message froze the whole platform for 12+
hours. `worker_pool.zig` owns real `std.Thread`s (floor of 2 per platform);
poll loops are real threads too and never share that pool.

**One poll loop per connector.** A single round-robin loop let one
connector's 25 s long-poll or XMPP reconnect delay every other platform.
Each connector already owned its own cursor state, so there was no reason
for the coupling.

**Detach, don't cancel (2026-07-21, 2026-08-04).** `std.http.Client`,
libpq and raw socket reads have no `Io` cancellation point;
`Io.concurrent` + `Future.cancel` on a stalled peer blocked *waiting for the
task to unwind* — the bot froze at 0 % CPU for minutes with no error.
`fetchWithTimeout`, `db.runWithDeadline` and the XMPP read run on a helper
thread that is detached on timeout. The abandoned thread must own copies
of everything it touches (buffers, allocator, `http.Client`): until
2026-08-04 the client was shared, producing a use-after-free that was
blamed for years on innocent tests as "flaky" segfaults.

**Pool acquire with a timeout (2026-07-22).** `PgPool.acquire` used to
block forever on a semaphore; one wedged connection shrank capacity by one
until every acquire starved silently. It now returns `error.PoolExhausted`
after a bounded wait, and a poisoned connection is replaced rather than
returned.

**TCP keepalives on the Postgres DSN (2026-07-23).** Even with statement
and connect timeouts, a connection the network dropped without FIN/RST
blocked libpq until a Postgres *container* restart. `keepalives_idle=20,
interval=10, count=3` detects a dark peer in ~50 s.

**Query deadline polling backs off (2026-09-13).** A flat 100 ms check
interval put a 100 ms floor under every query: 23 minutes of sleeping per
test run against 19 s of CPU.

**Heartbeat seeded to startup time (2026-07-27).** Seeding to 0 made a
connector that was merely slow on its first poll read as "stale for
decades", and the self-watchdog crash-looped every fresh container.

**Self-watchdog in-process.** Docker does not restart an unhealthy
container; only a process exit triggers `restart: unless-stopped`. The
watchdog exits the process when the heartbeat goes stale.

**Reply drafts in Postgres, not memory.** A pending "reply on my behalf"
draft may legitimately wait hours; an in-memory map lost every draft on
each deploy after the owner had already been told one was ready.

**Storage Sense exists because of an outage.** The VPS disk hit 100 %, Postgres
PANIC-looped and every write failed for ~3 hours. Autopilot is a
dynamic-config bool (defaults off) rather than a feature flag (defaults
on) on purpose.

## Access control

**Allowlist → blocklist; credits and tokens removed (2026-09-19).** The
bot now answers everyone unless a user or chat is blocked. The per-identity
LLM credit balance and the per-chat moderation tokens (a plain member could
spend one to run `/kick`) added a second permission model on top of RBAC
and were not used. The owner-only LLM gate remains the cost boundary.

**The owner is implicitly a bot admin.** Before, the owner had to
`/addadmin` themselves for anything gated specifically on `is_bot_admin`.

**`/sudo` announces itself.** A bot admin overriding a platform admin check
is never silent in the chat.

**Personal-account messages skip the access gate (2026-09-03).** Every
message from the TDLib connector is from someone else (own outgoing
messages are dropped), so `isOwner` can never match and routing them
through the normal gate silently made reply autonomy dead code. They are
routed straight to autonomy and never dispatched as commands (a contact
typing `/kick` must not run anything under the owner's identity).

**The bot's own DM is identified by id, not title (2026-09-04).** With
autonomy on, the bot drafted replies to its own draft notifications in a
loop. The guard compares the *native* chat id against the bot user id
parsed from the token — the first version compared the internal `chats`
row id and never fired.

**Reserved command names.** Aliases could once shadow `/sendas` and have
the owner's later command expand into text of the aliaser's choosing;
every dispatched name is now reserved, and aliases expand exactly once.

**`/promote` and `/demote` are owner-only.** Telegram's admin flag doesn't
say whether an admin may add other admins; granting real admin rights is
more consequential than mute/kick and isn't delegated to `/sudo` either.

## LLM

**Reasoning is handed back to the model (2026-09-19).** The
OpenAI-compatible adapter discarded `reasoning_content` between turns;
interleaved-thinking models (MiniMax M-series, the live provider through a
gateway, and Claude through the same gateway) then returned no visible
text after a tool result. It is kept as a `thinking` block and echoed under
the same field name the backend used — never a guessed key, because
OpenAI proper rejects unknown message properties.

**Empty replies get a nudge, then a visible fallback (2026-09-19).** An
empty final turn used to delete the thinking placeholder and record
nothing; to the user the bot went quiet, and the next turn had no record
anything happened.

**Tool traces in history; generated tool list in the prompt (2026-09-19).**
Only the final prose was recorded, so a turn done entirely by a
side-effecting tool left no trace, and the hand-written tool paragraph in
the prompt had fallen far behind the registry and was what the model
quoted when asked what it could do.

**Retries are per model call, not per run.** Retrying the whole loop would
re-execute tools (re-send a message, re-log an expense).

**Thinking reserve in `max_tokens`.** Sizing `max_tokens` off the visible
answer alone let a reasoning model exhaust the budget mid-thought and
produce nothing.

**Trivial replies are a regex list, not a classifier.** Cheap, auditable,
and the false-negative rate wasn't known yet.

**Tools reach the store through sinks.** `tools/registry.zig` is imported
by every tool and must stay free of store imports; `main.zig` wires
store-backed adapters per message. Owner-only sinks are null for other
askers, and a tool with a null sink is filtered out rather than offered.

**Delegates are fixed providers.** A delegate is an explicitly named target
the model asks for, never subject to the `WARDEN_LLM_PROVIDER` hot swap.

**Memory works without embeddings.** Gating the `remember_memory` tool on
an embeddings endpoint made "remembering" silently impossible: the model
agreed and nothing was stored.

## Web API and identities

**"My …" views scope by every identity the account is (2026-09-19).**
Login links one identity (Telegram); the owner's notes, reminders, etc.
written from Matrix or XMPP are recorded against those platforms' identity
rows and were invisible in the UI.

**Session tokens are HMAC-signed opaque ids, not JWTs.** Warden is the only
issuer and verifier; JWT's header/claims/algorithm negotiation buys
nothing.

**No seed rows for feature flags.** A missing row means enabled, so a test's
`TRUNCATE ... CASCADE` can never permanently erase "every module starts on".
Conversely `dynamic_config` falls back to the env default on a missing row
or a read error.

## Platforms

**Telegram: omit null optional fields.** Zig's JSON stringifier writes
`"reply_parameters": null` by default; Telegram rejects it, which silently
broke every unprompted send (reminders, alerts, digests) until
`emit_null_optional_fields = false`.

**Telegram: replies go through a narrow Markdown→HTML converter.** Models
write Markdown; Telegram needs `parse_mode`. Only unambiguous constructs
are converted, unclosed markers pass through literally so a streaming
preview never shows wrong formatting, and there is a plain-text fallback.
Thinking spans are control bytes rendered as expandable blockquotes; they
must never reach a user raw (the plain fallback once leaked them).

**`/help` is two messages.** The combined text crossed 4096 bytes; the
split is at the audience boundary (users vs moderation/operations).

**`!` is a command prefix everywhere.** Matrix clients intercept a leading
`/` before it reaches the bot.

**Matrix E2EE was "live-verified" once while producing undecryptable
events (2026-07-20).** Six send-side bugs (envelope fields, `room_id`,
`relates_to` placement, canonical JSON key order, the KEY_IDS MAC, a
`sendToDevice` leak) were only found against a real client. Verify crypto
changes end to end.

**Matrix: encrypted-room status is cached positively.** Re-checking on
every send meant a slow GET fell back to plaintext into a room already
known to be encrypted.

**Matrix: one-time keys are replenished.** The initial 20 were never topped
up, so session establishment with the bot failed once they were claimed.

**Matrix: refuse a device-id mismatch.** Reusing a device already
initialised by another client (Element) uploads keys nobody validates.

**XMPP: one background read across idle polls.** Spawning and abandoning a
read per poll reconnected every ~8 idle seconds and leaked a thread and
socket each time.

**TDLib: never mark messages read automatically.** Only `/tdsummary` and
`summarize_unread_chat` do so deliberately.

**Video download: portrait fallback.** yt-dlp's `height` is the long side,
so `height<=720` matched zero formats for Reels/Shorts and failed outright;
the selector falls back to best available.

## Data and money

**Money is integer cents parsed by hand.** `parseFloat` + rounding would
reintroduce the precision problem the schema rejects; the multiply is
checked because `/expense add 9223372036854775807 food` aborted a
`ReleaseSafe` build on overflow.

**`{d:0>2}` on a signed integer prints `+`.** Zero-padding a signed value
emits an explicit sign in Zig 0.16; format unsigned fields
(`formatMoney`, `civil_time`).

**Personal timezone is a fixed UTC offset.** DST drift twice a year is an
accepted limitation for a personal bot.

**ReDoS-safe regex.** `/redact regex` and trivial-reply matching use
`text/safe_regex.zig`, a Thompson-style engine with cost bounded by
states × input, because a user-supplied pattern must never hang a worker.

## Process

**Comments were cut from 19 % to 7 % of lines (2026-09-19)** and behaviour
documentation moved here. Keep it that way: see README.md's comment policy.
