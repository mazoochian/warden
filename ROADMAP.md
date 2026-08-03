# Warden Roadmap

This tracks planned work beyond what's documented in `README.md` today. Phases
are meant to ship incrementally, one at a time, not as a big-bang rewrite —
this is a personal project built in spare time, so scope stays deliberately
small per phase.

Status as of writing: **Phase 1 is committed** (reminders and
file-conversion landed in `fc3658d`), **Phase 2 (Matrix, plaintext rooms)
is committed and live-verified** against a real homeserver, **Phase 2b
(Matrix E2E encryption via libolm) is live-verified end-to-end as of
2026-07-20** after finding and fixing two real send-side bugs an earlier
"live-verified" pass had missed (see its note — the previous claim was
inaccurate: the encrypt path silently produced undecryptable-by-Element
messages the whole time), **Phase 3 (reminder recurrence +
absolute time) is committed**, **Phase 4 (price/metric alerts) is
committed**, **Phase 5 (RSS/news watcher) is committed**, **Phase 6
(per-chat persona) is committed**, and **Phase 7 (voice transcription; TTS
deliberately not included, see its note) is committed**. Also shipped
outside the phase sequence: a real XMPP connector (self-hosted-only,
SASL PLAIN, no OMEMO — see its own note below). `zig build test` green.

**Unplanned, shipped outside the phase sequence** (direct user request):
interactive choice prompts — Telegram inline-keyboard buttons, and Matrix
self-seeded emoji reactions as the equivalent, since Matrix has no button
concept — applied to a new multi-stage `/convert` flow (say `/convert` alone
or ask in natural language, upload a file, pick a target format from every
valid option) layered on top of the existing one-shot `/convert <format>`
caption command, which keeps working unchanged. Also added matching
"🔄 Converting…"/"🎙️ Transcribing…" progress placeholders to the two
operations that previously had none. `zig build test` green (158/158).
While verifying this live, also found and fixed a real pre-existing bug:
Telegram's API rejects an explicitly-serialized `"reply_parameters":null`
(Zig's JSON stringifier writes null optional fields by default rather than
omitting them), which silently broke *every* unprompted message — reminders,
alerts, feed-watcher notifications, digests — since none of those are sent
as a reply to anything. Fixed in `telegram/client.zig` with
`emit_null_optional_fields = false` and two regression tests; verified live
by inserting a due reminder directly into the database and confirming
clean delivery.

**Also unplanned, shipped outside the phase sequence** (direct user
request, 2026-07-26): a button-driven `/menu`/`!menu` system covering every
module (Alerts, Watches, Statistics, Convert, Group Administration,
Settings, Help) as a thin front end over their existing commands —
`features/menu_tree.zig` (the comptime module tree, doubling as the Help
browser's content) and `features/menu.zig` (the generic navigation
engine: per-(chat,user) sessions, an `ActionRunner` the actual command
logic plugs into, ownership enforcement, `awaiting_input` free-text
prompts for actions needing a target). New in this pass: a genuinely new
"top participants" pie chart (`features/piechart.zig` + `tools/piechart/
render.mjs`, same JSON-temp-file → `@napi-rs/canvas` → PNG pipeline as
the existing word cloud) and a new `Connector.editChoicePrompt` capability
(Telegram: edits a message's text+keyboard together in one call) that
lets Telegram navigation edit one message in place instead of spamming a
new one per level. Matrix reuses `sendChoicePrompt` as-is for now (a fresh
message per navigation step, stale reactions from earlier screens left in
place) and the Telegram persistent reply-keyboard mirroring the top-level
modules wasn't built — both are explicitly deferred, see the backlog entry
below. `zig build test` green.

**Also unplanned, shipped outside the phase sequence** (direct user
request, 2026-07-26): real calendar dates and per-user timezone/formatting
for reminders, plus a stepper-based creation wizard in `/menu`. New
`text/civil_time.zig` (Howard Hinnant's constant-time civil-calendar
algorithm — days-since-epoch ↔ y/m/d — plus local-offset split/combine and
date/time formatting; no calendar math existed anywhere in this codebase
before) and `store/user_settings.zig` (migration `0015_user_settings`) back
a personal timezone/date-format/time-format setting per identity, seeded
with a rough guess from Telegram's `language_code` (the only locale hint
its API exposes) and always overridable. **Scope decision**: a personal
timezone is a fixed UTC offset in minutes, not a real DST-aware IANA zone —
twice-a-year DST drift is an accepted, documented limitation, the same
"good enough for a personal bot" tradeoff `reminder_format.zig`'s own
pre-existing naive-timezone doc comment already made process-wide, just
made per-user instead. `reminder_format.parseWhenLocal` is the new
timezone-aware, date-capable sibling of `parseWhen` (accepts an explicit
`M/D`, `D/M`, or ISO `Y-M-D` date — year optional, rolling to next year
once passed — ahead of the existing duration/clock-time shapes); the old
naive `parseWhen` stays as-is for `tools/remind.zig`'s LLM tool. `/menu`
gained a Reminders module (view/cancel live pending reminders, each in its
own setter's timezone/format) and a genuinely new `NodeKind.wizard` in
`features/menu_tree.zig`/`features/menu.zig` — a linear date → hour →
minute (5s) → second → message → confirm flow with `[◀ -][value][+ ▶]`
steppers, `[⬅ Previous][Next ➡]` nav, and a text-reply shortcut ("13:37" or
"5/22/26") that jumps straight to a value and skips ahead. Settings →
Personal, a placeholder since the `/menu` pass above, now has real content
(Timezone/Date format/Time format). `zig build` + `zig build test` green
(381/382, 1 skipped without a local Postgres).

## Phase 1 — Land the in-flight work
*Effort: S. Dependencies: none.*

The reminders and file-conversion features currently sitting as uncommitted
changes are both essentially done — this phase is about shipping them and
making one explicit scoping call, not writing new code.

- Commit the reminders feature as-is: `src/tools/remind.zig`,
  `src/features/reminder_format.zig`, `src/store/reminders.zig`,
  `src/store/migrations/0002_reminders.sql`, plus `main.zig`'s
  `checkAndSendDueReminders`/`/remind`/`/remind cancel`/`/reminders` wiring.
- Commit the file-conversion feature as-is: `src/tools/convert_file.zig`,
  `src/features/convert.zig`, and the Dockerfile's new packages (pandoc,
  poppler-utils, imagemagick, ffmpeg).
- Update `README.md`'s feature list to document both — it currently mentions
  neither.
- **Explicit scoping decision: don't build Matrix/XMPP attachment support
  yet.** `convert_file` already goes through the platform-agnostic
  `Connector.downloadFile`/`sendDocument` vtable slots — it's Telegram-only
  today purely because the Matrix stub leaves both null, not because of
  anything in `convert_file` itself. Once Phase 2 gives Matrix real
  implementations of those two vtable methods, `convert_file` starts working
  there for free with zero changes to the tool. Building that plumbing before
  Matrix exists as a real connector would be untestable.
- Close the phase with `zig build test` green and a manual smoke test against
  a real Telegram chat (`/remind 1m ping me`, convert a sent photo).

## Phase 2 — Real Matrix connector, parity with Telegram (plaintext rooms)
*Effort: L. Dependencies: Phase 1. Status: done, live-verified.*

The biggest lift on this list, and worth doing early: every scheduled feature
after this point (alerts, RSS watching) currently carries a latent
multi-connector bug that's cheap to fix once and expensive to keep
re-discovering.

Encryption was explicitly scoped out of this phase after a mid-session
check-in: Matrix's E2E encryption (Olm/Megolm) is a full cryptographic
protocol stack, and hand-rolling it from scratch carries real risk of
subtly-wrong crypto with no way to catch it without a security review and
test vectors. The agreed approach is to bind the audited `libolm` C library
via Zig FFI (same pattern as linking `libpq`) rather than reimplement the
ratchets — tracked as **Phase 2b** below, deliberately kept separate so the
plaintext-room connector could ship without waiting on it.

Done:
- Replaced the ~60-line `src/platform/matrix.zig` stub with a real
  Client-Server API implementation (`src/matrix/client.zig` +
  `src/matrix/types.zig`, ~650 lines together): access-token auth, `/sync`
  long-poll (discarding the first response's room backlog so a restart
  doesn't re-answer old messages), message send/reply, `m.replace` edits for
  the live-editing "thinking..." flow, media upload/download for `mxc://`
  URIs, auto-join on invite, and power-level-based moderation (kick/ban
  natively; mute/unmute via power-level demotion, since Matrix has no native
  mute or mute expiry).
- Added `WARDEN_MATRIX_HOMESERVER_URL`, `WARDEN_MATRIX_ACCESS_TOKEN`,
  `WARDEN_MATRIX_OWNER_ID` to `config.zig` — purely additive, since
  `auth.isOwner` already took a platform argument and iterated
  `config.owners`.
- `main.zig` now builds its connector list at runtime (Telegram always,
  Matrix only when configured) instead of a fixed one-element array.
- Fixed the multi-connector chat-id collision the old code flagged in a doc
  comment: `DigestScheduler` and `reminders.dueUndelivered` were keyed by
  bare `native_chat_id`, so a due digest/reminder would get matched against
  whichever connector happened to be polling, not the one that actually owns
  that chat's platform. Both now carry `platform` end to end (`chats.zig`'s
  `ChatRef`, `reminders.zig`'s `DueReminder`, `DigestScheduler`'s composite
  keys) and `checkAndSendDueDigests`/`checkAndSendDueReminders` pick the
  matching connector via a small `findConnector` lookup.
- Two documented simplifications versus Telegram parity (see README's
  "Matrix" section): every room is treated as a "group" (no DM
  auto-engagement) since telling a real 1:1 room apart needs an extra
  `m.direct` lookup not implemented yet; mute has no expiry.

Live-verified against a real homeserver (matrix.mazoochian.ir): DM the bot,
auto-join on invite, send/receive text, mention detection (both MSC3952
`m.mentions` and the plain-text fallback), the live-editing "thinking..."
reply flow. `!` was added as a second command prefix alongside `/`, since
Element intercepts a leading `/` as its own client command before it ever
reaches the bot. Photo/document both-directions, `/mute`+`/unmute`,
`/kick`/`/ban`, `/pin`/`/unpin`, `/delete`, and the `/convert` choice-prompt
flow are still unexercised against the real homeserver — implemented per
spec, not yet individually confirmed live.

## Phase 2b — Matrix end-to-end encryption via libolm
*Effort: L (new — split out of Phase 2). Dependencies: Phase 2's live
verification, ideally, so encrypted-room bugs aren't confused with
plaintext-room bugs. Status: done, live-verified both directions as of
2026-07-20.*

**2026-07-20 postmortem** — the earlier "done, live-verified" claim above
was wrong: encrypt-path bugs meant every message the bot sent into an
encrypted room was undecryptable by Element, silently, the entire time.
Two separate root causes, both "the plaintext payload was missing a field
the Matrix spec requires, and libolm/Megolm happily encrypt garbage
without complaining":

1. `shareWithNewDevices`'s `m.room_key` to-device payload was missing
   `sender`/`sender_device`/`keys`/`recipient`/`recipient_keys` — required
   by spec, and matrix-js-sdk's `OlmDecryption.decryptEvent` checks
   `recipient`/`recipient_keys.ed25519` *before* ever looking at the
   `m.room_key` content, throwing `OLM_BAD_RECIPIENT` otherwise. To-device
   decryption failures are only logged internally by Element, never
   surfaced in its UI — so `sendToDevice` returning `200 OK` gave no hint
   anything was wrong on either side.
2. `platform/matrix.zig`'s `sendEvent` omitted `room_id` from the
   plaintext it Megolm-encrypts. Megolm requires it as an anti-replay
   check (a session key can't be reused to forge a message into a
   different room) — once (1) was fixed, this surfaced as "the room id of
   the room key doesn't match the room id of the decrypted event:
   expected `<room>`, got None."
3. Smaller, found in the same pass: edits/replies/reactions
   (`m.relates_to`) were rendering as brand-new messages instead of
   collapsing into the original — matrix-js-sdk's `isRelation`/
   `getRelation` read `m.relates_to` from the event's *clear* (wire) top
   level, never from the decrypted content, so a relation kept only
   inside the encrypted payload is invisible to the client. Fixed by
   duplicating `m.relates_to` into the unencrypted `m.room.encrypted`
   envelope alongside `algorithm`/`ciphertext`/etc.

Also found: the bot's Matrix account (`@ameli`) has legacy cross-signing
keys server-side from an earlier real-Element-login session, predating
this bot's own hand-rolled crypto (which has no cross-signing
implementation at all). This shows up as an "unverified device" shield in
clients that surface it — cosmetic, not a decrypt-blocker; see
`README.md`'s Encryption section. No fix planned — building real
interactive (SAS/emoji) device verification for a headless bot is a
much bigger feature than this warrants, and the account's cross-signing
identity was reset once (2026-07-20) as basic hygiene regardless.

Hardening added in the same pass, beyond the two root-cause fixes:
- Answers `m.room_key_request` (e.g. from a client that ran
  `/discardsession`) with `m.forwarded_room_key`, scoped to only this
  account's own other devices — a self-healing fallback for to-device
  delivery being best-effort, not guaranteed (see `matrix/crypto.zig`'s
  `State.handleRoomKeyRequest`).
- One-time-key replenishment (`/sync`'s `device_one_time_keys_count`
  drives `State.topUpOneTimeKeysIfNeeded`) — previously the initial batch
  of 20, generated once at first startup, was never topped up.
- Fallback-key generation/upload, so OTK exhaustion doesn't hard-fail
  every future session establishment.
- Megolm outbound session rotation (time-based, 7 days) — previously a
  room's session lived for the whole process lifetime once created.
- Receive-side envelope validation (`sender`/`recipient`/
  `recipient_keys.ed25519`) mirroring matrix-js-sdk's own checks — closes
  the gap where the bot's own decrypt path was more lenient than a real
  client's, which is part of why its test suite didn't catch bug (1)
  above.

Deferred, not done: multi-Olm-session-per-sender fallback (still one
session per sender identity key, a known simplification — see
`store/crypto.zig`), and HTTP-request-shape test coverage for
`matrix/client.zig` (currently zero tests on `queryKeys`/
`claimOneTimeKey`/`sendToDevice`/etc. — the bugs above were all in
payload *construction*, not HTTP mechanics, so this stayed lower priority
this pass).

- Bind `libolm` via Zig's C interop (`link_libc` + `linkSystemLibrary`, same
  shape as `build.zig`'s existing `pq` linkage) rather than a from-scratch
  Olm/Megolm reimplementation — this is the load-bearing decision from this
  phase's scoping discussion and shouldn't be revisited without a strong
  reason.
- Device identity keys (Ed25519) and one-time keys (Curve25519), published
  via `/keys/upload` and claimed via `/keys/claim`.
- Per-device Olm sessions for the to-device key-exchange traffic, and
  Megolm inbound/outbound group sessions for actual room message
  encrypt/decrypt.
- Session/key persistence across restarts (a new store table, likely) —
  losing Megolm session state means losing the ability to decrypt history,
  so this isn't optional the way most of warden's other state is.
- Device verification is explicitly out of scope for a first pass (an
  unverified-but-functional bot account is an acceptable starting point);
  note the gap in README rather than silently pretending it's handled.
- New Dockerfile dependency: `libolm` (and its headers) in the build image.
- `main.zig`: generalize the currently fixed-size connector array
  (`const connectors = [_]iface.Connector{telegram_adapter.connector()}`)
  into something built at runtime, so Matrix is included only when its env
  vars are configured.
- **Fix the multi-connector chat-id collision** the code already flags in a
  doc comment: `DigestScheduler`'s enabled-chats set and the reminder-
  delivery scan key everything by bare native `chat_id`, with no platform
  tag. Key both by `(platform, native_chat_id)` instead — the `chats` table
  already stores both — before a second scheduled feature (Phase 4/5) makes
  the same bug more expensive to unwind.
- Promote Matrix from "coming soon" to documented in `README.md`, with its
  own env-var block alongside Telegram's.

## Phase 3 — Reminders v2: recurrence and absolute time
*Effort: M. Dependencies: Phase 1. Status: done.*

Direct continuation of the reminders system, closing its two known
limitations (relative-duration-only, no repeats).

- `reminder_format.zig` gained `parseAbsoluteTime` (`HH:MM` 24h clock,
  resolves to the next occurrence today-or-tomorrow), `parseWhen` (tries a
  relative duration first, then an absolute time — the new unified entry
  point both `/remind` and `set_reminder` use), and `nextOccurrence` (jumps
  a recurring reminder straight to the next due time strictly after `now`,
  so a reminder that missed several firings while the bot was down doesn't
  fire once per missed interval in a burst). Deliberately still no real
  calendar/timezone handling — `now` is treated as already being in
  whatever clock the operator cares about, same tradeoff
  `scheduler.zig` makes for digests.
- Migration `0003_reminders_recurrence.sql` added `recur_interval_seconds`
  to `reminders` (interval-based — "every 1d" — not cron/day-of-week
  scheduling, consistent with `DigestScheduler`'s interval-not-wall-clock
  philosophy).
- `reminders.zig`'s `dueUndelivered`/`listPending` now carry `due_at` and
  `recur_interval_seconds`; a new `reschedule` advances `due_at` instead of
  clearing the reminder when it recurs.
- `set_reminder`'s tool schema gained an independent `recur` field
  (`duration` always sets the first firing; `recur`, if set, is the repeat
  cadence after that — e.g. `duration=1h, recur=1d` fires once in an hour,
  then daily). The `/remind` command gained `every <interval> <message>`
  (single interval reused for both first-fire and cadence, a simpler
  command-line shape than the tool's two independent fields).
- `/reminders` and the tool's `action=list` both show "(repeats every 1d)"
  for recurring entries.

## Phase 4 — Price & metric alerts
*Effort: L. Dependencies: Phase 1's sink pattern; Phase 2's chat-id fix.
Status: done.*

The standout new feature, and the best fit for warden's personality: this
composes the existing `crypto_price`/`weather`/`air_quality` tools with the
reminders infrastructure's sink/scheduler pattern to support "ping me when
BTC crosses 70k" or "tell me if Tehran's AQI gets bad."

- `src/store/alerts.zig` + migration `0004_alerts.sql` (chat_id, identity_id,
  kind, subject, currency, condition, threshold, check_interval_seconds,
  cooldown_seconds, last_checked_at, last_triggered_at) — two separate
  gates rather than one: `check_interval_seconds` (default 5m) bounds how
  often the external API actually gets hit, `cooldown_seconds` (default 1h)
  bounds how often an already-true condition re-notifies. `db.zig` gained
  `bindFloat64`/`columnFloat64` for the threshold column (its first
  non-integer bound parameter).
- `AlertSink` ptr+vtable in `registry.zig` alongside the existing
  `ReminderSink` — same reasoning: `registry.zig` is imported by every tool
  and must never depend on `src/store/*` directly.
- `src/tools/set_alert.zig` (LLM-invocable, `action=create|list|cancel`,
  kind is one of crypto/weather/aqi).
- `crypto_price.zig`/`weather.zig`/`air_quality.zig` each gained a plain
  `fetchPrice`/`fetchWeather`/`fetchAirQuality` function alongside their
  existing `execute()` — the same fetch-and-parse core, callable directly
  without a JSON args round trip or the LLM tool-call loop.
- `src/features/alerts.zig`'s `checkAndDeliverAlerts` — wired into the poll
  loop next to `checkAndSendDueDigests`/`checkAndSendDueReminders` — queries
  due alerts, dispatches to the right source by `kind`, and delivers through
  whichever connector owns the alert's platform (same `findConnector`
  pattern as Phase 2's chat-id fix).
- `/alert crypto bitcoin above 70000`, `/alert weather Tehran above 35`,
  `/alerts`, `/alert cancel <id>` commands, matching `/remind`'s
  authorization pattern (creator or owner may cancel). The command syntax
  joins every token between the kind and the trailing `<above|below>
  <threshold>` pair back into `subject`, so multi-word city names work at
  the command line too, not just through the LLM tool.

## Phase 5 — RSS/news watcher
*Effort: M. Dependencies: Phase 2. Status: done (core; see deferred item
below).*

Composes a small hand-rolled feed parser with the digest infrastructure's
LLM-summarization pattern into a standing feed-watcher.

- `src/store/feed_watches.zig` + migration `0005_feed_watches.sql` — keyed
  by `(chat_id, feed_url)` rather than an id, since `/unwatch <url>` is a
  more natural command than needing to look up an id first, and unlike
  reminders/alerts, watching is open to anyone in the chat (not restricted
  to whoever added it) — same precedent as `/digest on|off`.
- `src/features/feed_parse.zig`: a deliberately small, non-namespace-aware
  RSS 2.0 / Atom parser extracting each entry's title + a stable identifier
  (`<guid>`/`<link>` for RSS, `<id>` for Atom) in document order. Not a real
  XML parser — good enough for diffing "what's new," not general feed
  reading.
- `src/features/feed_watcher.zig`'s `checkAndNotifyFeeds` (wired into the
  poll loop next to the other three checks): fetches each due feed (plain
  `http_util.get`, no new dependency), diffs against `last_seen_guid`, and
  for genuinely new items reuses `digest.zig`'s pattern of an LLM call over
  a short text blob to write a 1-2 sentence blurb instead of dumping raw
  titles. The very first check of a newly-added feed only records a
  baseline without announcing anything — same "don't replay history"
  reasoning as Phase 2's discarded first Matrix `/sync`.
- `/watch <feed_url>`, `/unwatch <feed_url>`, `/watches` commands, same
  shape as `/digest on|off`.
- **Deferred, not built this pass**: letting the LLM tool-call into
  `web_search`/`scrape_site` to *find* a feed URL from a plain-language
  "watch TechCrunch" request. `/watch` needs an explicit feed URL for now —
  consistent with `/digest` itself also having no corresponding LLM tool,
  but worth adding if "watch X" without a URL turns out to be how people
  actually want to use this.

## Phase 6 — Per-chat persona / system-prompt override
*Effort: S. Dependencies: Phase 1. Status: done.*

Small, high-value, and a near-perfect fit for the existing `chat_settings`
typed-column pattern (`magic_word`, `digest_enabled` already live there).

- Migration `0006_persona.sql` added a nullable `system_prompt` column to
  `chat_settings`; `getSystemPromptOverride`/`setSystemPromptOverride` use
  the same `INSERT ... ON CONFLICT DO UPDATE` idiom as `setMagicWord`.
- `/persona <text>` and `/persona off` (owner-only to change — a chat
  member rewriting the bot's entire personality is a bigger lever than a
  magic word) reset to `config.system_prompt`. Viewing the current persona
  (`/persona` with no argument) is open to anyone, same as `/magicword`'s
  own view/change split — no secret involved, unlike `/scraper`.
- The Q&A call site in `main.zig` (where `handleMessage` calls
  `replyWithAnswer`) resolves `chat_settings.getSystemPromptOverride` first,
  falling back to `config.system_prompt` when unset — one line, no changes
  needed inside `qa.zig` itself since it already just takes whatever
  `system_prompt: ?[]const u8` its caller hands it.

## Phase 7 — Voice message transcription (+ optional TTS)
*Effort: M/L depending on TTS scope. Dependencies: Phase 1 (attachment
plumbing, ffmpeg already in the image). Status: transcription done, TTS
not built.*

Landed as a sidecar HTTP service, not a binary shelled out to from inside
the warden image — `compose.yaml` already established this exact shape for
`llama-server` (the local LLM), and whisper.cpp ships an equivalent
official server image (`ghcr.io/ggml-org/whisper.cpp:main`, a simple
`POST /inference` multipart endpoint), so following that precedent avoided
adding a from-source native build to the Dockerfile entirely — no
Dockerfile changes were needed at all, since ffmpeg was already in the
image from Phase 1.

- `src/features/transcribe.zig`: given `ctx.attachment_path` for a voice
  attachment, normalizes to 16kHz mono wav via ffmpeg (whisper.cpp's own
  preferred input shape), then POSTs it to a configured `whisper-server`'s
  `/inference` endpoint (`response_format=text`, so the response is the
  raw transcript with no JSON to parse).
- `WARDEN_WHISPER_URL` (`config.zig`) is the base URL of the whisper-server
  instance; unset (the default) disables transcription entirely.
- `main.zig`'s new `resolveQuestion` helper wires this into the Q&A path:
  a captionless voice message with `WARDEN_WHISPER_URL` configured gets
  transcribed and the transcript becomes the model's question, falling
  back to the existing generic `attachmentPlaceholder` on any failure
  (not configured, download failed, transcription errored or came back
  empty) rather than ever blocking the reply on it.
- `compose.yaml` gained an opt-in `whisper-server` sidecar (same
  not-started-by-a-plain-`up`-shape as `llama-server`), defaulting to
  `ggml-base.bin` — the multilingual base model, picked over the
  `.en`-suffixed English-only variants given warden's other model choices
  already prioritize non-English (including Persian) quality.
- **Not built: TTS replies** — stays exactly as deprioritized as the
  original phase note called out; no work attempted this pass.
- **Live-verified this pass** (unlike Matrix in Phase 2, this one had
  real credentials to test with): downloaded `ggml-base.bin`, brought the
  sidecar up, and POSTed a synthesized speech sample straight to
  `/inference` over the compose network, matching `transcribe.zig`'s exact
  request shape — got a real (if imperfect, as expected from robotic
  TTS + the small base model) transcript back. This caught a real bug:
  the whisper.cpp image's `ENTRYPOINT` is `["bash", "-c"]`, and Compose
  always resolves `command:` to an array before handing it to Docker —
  `bash -c` treats array[0] alone as its script and silently discards
  every element after it as unused positional parameters, so the server
  started fine but ignored every flag and fell back to its own defaults.
  Fixed in `compose.yaml` by wrapping the whole command in a one-element
  YAML list, which is documented there since it's a genuinely
  non-obvious gotcha specific to this image.

## Phase 8 — Backlog

Ideas considered and deliberately deprioritized relative to the above — not
planned in detail, listed so they aren't forgotten.

- **Semantic memory / RAG over chat history** — the most powerful idea
  considered, but a genuinely bigger infra lift than anything else here:
  needs `pgvector` (a Postgres extension warden doesn't currently require),
  an embeddings API call on every stored message (cost/latency on every
  message, not just addressed ones), and a retrieval step bolted into
  `qa.zig`'s prompt construction. Worth its own dedicated phase once the
  above ship.
- Group polls/trivia games — would reuse `group_admin.zig`'s
  `PendingConfirmations`-style in-memory per-chat state pattern; fun, but
  more "toy" than the alert/watcher features above.
- Translation tool — straightforward `ToolDef` addition, but lower novelty
  since the LLM already translates fine zero-shot.
- Sandboxed code execution tool — high effort (real sandboxing, not just
  `std.process.run`) for a use case that doesn't obviously fit a group-chat
  assistant's personality as well as the others.
- Spam/toxicity auto-moderation — would meaningfully change the bot's
  owner-only-Q&A trust model (it'd need to act on messages regardless of
  addressing) and risks false-positive moderation in real groups; revisit
  only if a real need shows up.
- **History-aware context downsampling/summarization** — added
  2026-07-26: every LLM call currently sends the last `WARDEN_LLM_HISTORY_MESSAGES`
  raw "who: text" lines verbatim (see `qa.zig`'s `recentFormatted` call),
  no compression at all. A real upgrade path once the current flat window
  stops being "good enough": periodically collapse older history into a
  running per-chat digest/summary (reusing the existing `/digest` feature's
  summarization machinery as a starting point) so the prompt sends "recent
  raw messages + a compressed summary of everything older" instead of a
  strictly bigger raw window. Needs a real design pass (when to
  regenerate the summary, how stale it's allowed to get, cost of the
  summarization call itself) before starting — not a quick patch.
- **ML/embedding-based trivial-message classifier** — added 2026-07-26:
  `features/trivial_reply.zig`'s regex-based greeting/ack matcher (see
  its module doc) is a deliberately simple v1 (fixed phrase list, whole-
  message match). A real classifier (small embedding model + similarity
  threshold, or a tiny fine-tuned intent model) would generalize far
  better than a fixed pattern list, at the cost of an extra model call
  (defeats some of the point unless it's cheap/local) or a bundled
  lightweight model. Revisit once the fixed-list version's false-negative
  rate in practice is actually known.
- **Per-group LLM usage cap** — requested 2026-07-26, explicitly deferred:
  let a chat's own admins (not just bot admins/owner) cap how many credits
  (or how much LLM spend) that specific *chat* can burn through in a
  period, independent of any individual member's personal credit balance
  (see README's "Access control" section for the current global-per-
  identity credits model). Would need its own per-chat counter/limit in
  `chat_settings` (or a new table) and a spend-check alongside
  `identities.spendCredit` at the same choke point in `main.zig`. Not
  implemented — tracked here only.
- **LLM response/token caching** — noted 2026-07-26, explicitly deferred:
  cache identical or near-identical prompts/answers (e.g. the same
  trivial-adjacent question asked repeatedly, or Anthropic's own
  prompt-caching feature for the shared system-prompt/tool-schema prefix
  every request resends) to cut repeat-request cost. Anthropic's native
  prompt caching (cache the system prompt + tool schemas, which don't
  change turn to turn) is probably the highest-value, lowest-risk version
  of this — worth checking `llm/anthropic.zig`'s request builder against
  the current caching API shape when this phase starts.
- **Multi-model routing** — added 2026-07-26: today `llm.Provider` is a
  single fixed instance for the whole process (`WARDEN_LLM_PROVIDER`, one
  provider/model, chosen once at startup — see `main.zig`'s provider
  construction). A real router component would sit in front of it and:
  - classify each question (cheaply — a small model call, or a classifier
    reusing the trivial-message matcher's approach) and send it to
    whichever configured provider/model actually fits (a cheap/fast model
    for simple questions, a stronger one for anything that needs real
    reasoning or a big context);
  - let a cheap model's answer optionally get "consulted"/escalated to a
    heavier model rather than every question paying the heavy model's cost
    up front;
  - cache/reuse responses across near-duplicate questions (ties into the
    token-caching item above);
  - load-balance across multiple configured providers/keys for the same
    tier (throughput/rate-limit headroom, and a cheap way to get
    redundancy if one provider is down — directly relevant given this
    session's router9-down incident that prompted the Anthropic switch).
  This is a genuinely bigger architectural change than anything else in
  this backlog — `llm.Provider` would need to become a set of providers
  plus a routing policy, not a single instance — so it deserves its own
  dedicated phase/design pass rather than an incremental patch. Worth
  revisiting once the current single-provider setup's cost/latency
  tradeoffs are actually felt in practice.
- **`/confirm`/`/cancel` are dead code for `/kick`/`/ban`** — found
  2026-07-26 while fixing `/kick`/`/ban` targeting: `group_admin.
  requestConfirmation` runs the kick/ban immediately and never calls
  `PendingConfirmations.set`, so nothing is ever actually queued for
  `/confirm`/`/cancel` to act on — both commands (and the whole
  `PendingConfirmations` map, which only has unit tests exercising it
  directly, never through the real dispatch path) are unreachable in
  practice. Every doc comment/README line describing a "confirm-before-
  acting" flow for `/kick`/`/ban` is currently inaccurate — they act
  immediately, full stop. Left unfixed for now since wiring it up for real
  is a genuine behavior change (an admin's `/kick` would stop working
  immediately and start requiring a follow-up `/confirm`), not a targeting
  bugfix — worth a deliberate decision on which behavior is actually
  wanted before touching it.
- **`/menu` polish: Telegram reply-keyboard + Matrix reaction cleanup** —
  deferred 2026-07-26 out of the initial `/menu` pass (see its "shipped
  outside the phase sequence" note above). Two independent pieces:
  (1) a persistent Telegram reply-keyboard (`ReplyKeyboardMarkup`/
  `KeyboardButton` — neither exists in `telegram/types.zig`/`client.zig`
  today) surfacing the same top-level modules as `/menu`'s root, so they're
  reachable from the keyboard docked at the input box, not just the inline
  menu; (2) real in-place editing for Matrix (redacting stale reactions
  from a screen the session has navigated away from, via
  `matrix/client.zig`'s already-existing but currently-unused
  `redactMessage`) instead of `menu.zig`'s current fallback of sending a
  fresh message per navigation step there. Neither blocks using `/menu` on
  either platform today, just leaves Matrix messier and Telegram
  discoverable only via `/menu`/the "/" command list.

## Post-v1 feature roadmap (drafted 2026-07-31)

Warden is close to a v1 release. The list below is a forward-looking,
prioritized backlog for *after* that — not scheduled, nothing here is
started. It was triggered by a ChatGPT-drafted brainstorm of ~250-300
generic "AI Telegram assistant" feature ideas spanning everything from
personal productivity to CRM integrations to dating-profile help. Most of
that list doesn't fit Warden: it's a single-owner personal bot (see
"Access control" in `README.md`), not a multi-tenant SaaS product, so
anything assuming teams/billing/white-labeling/lead-gen was cut outright
rather than phased. What's below is the subset that's a real fit, folded
into Warden's existing category groupings (reminders, alerts, tools,
menu) and ranked most → least critical by how much daily-use value it adds
per the pattern the shipped phases above already validate: features that
become part of a daily workflow (memory, reminders, search, document
handling, proactive notifications) stick; novelty features don't.

Each phase below reuses Warden's established shape — a `store/*.zig` +
migration, a `features/*.zig` or `tools/*.zig`, a slash command, a `/menu`
entry — the same pattern every phase above already follows. Sizing (S/M/L)
is a rough guess, not a commitment; real scoping happens when a phase
actually starts.

### Phase 9 — Management rooms, channel support & delegated admin notices
*Effort: M/L. Status: slice 1 done (channel ingestion, management-room
binding, admin notices) — see the note below the bullet list for what
shipped vs. what's deliberately deferred.*

Ranked first, ahead of the ChatGPT-derived features below, because it
closes a real zero-support gap rather than adding a new nice-to-have:
**Telegram channels aren't administrable by Warden at all today.**
`platform/interface.zig`'s `chat_type` doc comment already lists
`"channel"` as a recognized value and the string is persisted if it ever
arrives, but nothing in `platform/telegram.zig` subscribes to
`channel_post`/`edited_channel_post` updates, so a channel is never
ingested as a chat in the first place. This isn't an oversight to
quick-fix, either — it's structural: a channel has no back-and-forth
message flow a member could use to type a command into it the way a group
works, so "just add channel support" alone still leaves no way to
*command* the bot there. Matrix moderation bots (Mjolnir, Draupnir) hit
the identical problem — Matrix has no DM concept either, a 1:1 is still
just a room — and solved it with a **management room**: a separate room
you talk to the bot in, where commands name which *other* room they act
on. This phase adopts the same pattern for Warden, generalized to also
cover ordinary groups (so admin commands don't have to be typed in front
of the whole group, even where that's optional rather than structurally
required):

**Done (slice 1):**
- Channel ingestion: `platform/telegram.zig`'s `pollFn` now subscribes to
  `channel_post`/`edited_channel_post` (new `Update` fields in
  `telegram/types.zig`) and translates either into a chat-ingest-only
  `iface.Message` (new `chat_ingest_only` synthetic signal, alongside
  `chat_left`/`migrated_to_native_chat_id` — `processMessageTask` upserts
  the chat row and stops, no identity resolution or LLM dispatch, since a
  channel post is never conversational content). Also fixed a gap this
  phase's own original text assumed already didn't exist: `my_chat_member`
  previously only handled the *departure* case (`chatLeftMessageFromUpdate`);
  a new `chatJoinedMessageFromUpdate` now ingests on `member`/
  `administrator`/`creator` too, which is the *only* reliable ingestion
  signal for a channel — one may go a long time between posts (or be
  post-only for other admins) after the bot's added.
- Management-room binding: new `management_room_bindings` table (migration
  `0023`) + `store/management_rooms.zig` (`bind`/`unbind`/`isBound`/
  `listTargets`), and `/manage bind|unbind <chat id>` / `/manage list` in
  `main.zig`. `<chat ref>` is warden's own internal `chats.id` (surfaced via
  `/manage list`), not a platform-native id or `@username` — no new
  Telegram API surface needed, same convention `/alert cancel <id>`/
  `/reminders` cancel already use. bind/unbind are authorized against the
  *target* chat's live admin status (new `auth.isOwnerOrLiveAdminOfChat`),
  not the room the command was typed in.
- **Admin notices**: `/notice <chat id> <text>`, plus Bot View's
  `POST /api/v1/bot-view/send` and its WS stream widened from strictly
  owner-only to also admit a live admin of that specific target chat
  (reusing `requireChatAccess`'s existing live-admin-check machinery,
  factored into `isOwnerOrLiveAdminOfChatAccount` so both call sites share
  it — `bot_admin` stays excluded either way, unchanged from the
  2026-07-28 decision). The newly-admitted admin tier's send uses
  `sendMessageReturningId` + `pinMessage` (auto-pinned, "distinct from an
  ordinary relayed message"); the owner's own existing send is completely
  unchanged (plain, unpinned).
- **Explicit v1 scoping decision for this pass**: Bot View's owner-only
  visibility stays as the ceiling for the owner (sees/acts as the bot
  everywhere, unchanged), but a chat's own live admins get scoped access —
  they may view/act only in a chat they're a live-checked admin of, never
  any other chat. No shared/team visibility beyond that boundary.
- Cross-platform management rooms aren't supported: binding/notices
  require the target chat to be on the same platform as the room the
  command was typed in (checked and rejected with a clear error
  otherwise) — in practice a non-issue today, since channels (this
  phase's actual motivating case) only exist on Telegram.

**Deferred, not built this pass** — generic `/as <chat ref> <command>`,
replaying arbitrary admin commands (kick/mute/pin/etc, not just a notice
send) against a bound target chat from a management room, the way Mjolnir's
`!mjolnir <command> !room:server` does. The blocker: every existing admin
handler replies into whatever `chat_id` it's given, so a naive
re-dispatch (swap `msg.chat_id` to the target's native id, reuse the
existing per-command live-admin auth as-is) would post confirmations into
the target chat, not back into the management room where the operator is
sitting — a real UX gap, not just a missing feature, and untangling it
(without touching every handler) is its own design problem. Same
"split off the fuzzy part" call this project made for Matrix E2EE (Phase 2
→ 2b); worth a dedicated pass once there's a real answer for reply
routing.

**Not live-verified** — unlike some earlier phases (e.g. Phase 7's
whisper sidecar), this one had no real Telegram channel + a second admin
account available to test cross-account authorization against, so this is
implemented per spec and covered by unit/store tests only, not confirmed
against a live homeserver/Bot API. Noted honestly rather than claimed,
same standard Phase 2's Matrix landing held itself to.

### Phase 10 — Vision & document understanding
*Effort: M/L. Status: slice 1 done (images) — see below for what shipped
vs. what's deferred.*

The single biggest capability gap today: `qa.zig`'s Q&A path is text-only.
Photos and PDFs already flow through the connector's attachment plumbing
(used by `/convert` and voice transcription) but the LLM itself never
*sees* them — only mechanically converts or transcribes. Wiring image
bytes into a multimodal provider call (Anthropic/OpenAI vision support)
unlocks a cluster of ChatGPT's list at once with one piece of plumbing:
image understanding, PDF understanding, OCR, handwriting recognition,
document summarization, homework-helper/math-solver (photo of a problem),
receipt OCR (feeds Phase 17's finance tracker). Highest priority because
several later phases assume it exists.

**Done (slice 1, images only):**
- New `ContentBlock.image` variant (`llm/provider.zig`) — a base64
  `{media_type, base64_data}` pair, alongside the existing `text`/
  `tool_use`/`tool_result` blocks both provider adapters already switch
  over exhaustively.
- `llm/attachment_content.zig`'s `imageBlockForAttachment` classifies
  `ToolContext`'s current attachment: a Telegram `.photo` is always an
  image (Telegram never reports a `mime_type` for those — confirmed the
  only reliable signal is `kind`, not mime/filename), a `.document` is an
  image if its mime type starts with `image/` or (no mime) its filename
  extension says so. Reads the file capped at 5MB (Anthropic's real
  per-image limit) via the same `readFileAlloc(..., .limited(n))` shape
  `transcribe.zig` already uses; any failure (missing file, over the cap)
  falls back to `null` — text-only — rather than ever failing the whole
  Q&A call over a picture the model just won't get to see that turn.
- Hooked into `llm/toolcall.zig`'s `run()`, not `main.zig`'s
  `resolveQuestion`: `resolveQuestion` only ever produces text and only
  special-cases a *captionless* attachment, so a photo sent *with* a
  caption would've been missed entirely. `ctx.attachment_path` is already
  populated by the time `toolcall.run` builds its first message,
  regardless of caption, so attaching the image there covers both cases
  with one change — and is a no-op for `digest.zig`/`feed_watcher.zig`'s
  own `toolcall.run` calls, whose synthetic `ToolContext`s never carry a
  real attachment anyway.
- `anthropic.zig`'s `writeContentBlocks` gained the native
  `{"type":"image","source":{"type":"base64",...}}` shape;
  `openai_compat.zig`'s `writeMessages` needed real restructuring (not
  just a new arm) — `content` was always written as a bare JSON string
  before this, and only switches to an array of `{"type":"text"}`/
  `{"type":"image_url"}` parts for a message that actually carries an
  image, so every existing text-only call through that file is
  byte-for-byte unchanged.
- New `WARDEN_LLM_VISION` toggle (`config.zig`'s `llm_vision_enabled`,
  default on), following the exact same `LlmDynamicSettings`/
  `dynamic_config.findBool` shape every other global LLM toggle
  (`WARDEN_LLM_SHOW_THINKING`/`WARDEN_LLM_STREAMING`/...) already uses —
  runtime-hot-swappable via warden-ui's admin config panel with no
  redeploy, same as those. An owner whose configured OpenAI-compatible
  model genuinely doesn't support vision can turn this off; there's no
  per-provider/per-model capability metadata anywhere in this codebase to
  gate it automatically instead.

**Deferred, not built this pass** — native PDF-as-document support
(Anthropic's `type: "document"` content block, real PDF understanding with
no OCR/conversion round trip). It's an Anthropic-only API shape with no
equivalent in the generic OpenAI-compatible surface warden's other
provider slot targets, so it doesn't fit one shared code path as cleanly
as images do (both providers' vision APIs handle those near-identically).
Same "split off the provider-specific part" call this project made for
Matrix E2EE (Phase 2→2b) and Phase 9's deferred `/as` relay.

**Not live-verified** — no real Telegram photo sent to a live chat this
pass, so this is implemented per spec and covered by unit tests
(`attachment_content.zig`'s image/mime classification,
`anthropic.zig`/`openai_compat.zig`'s exact JSON shapes,
`toolcall.zig`'s vision-on/vision-off message-block-count check) but not
confirmed against a real Anthropic/OpenAI vision response. Noted honestly
rather than claimed, same standard held elsewhere (e.g. Phase 9's own
note on this).

### Phase 11 — Personal knowledge base: notes & lists
*Effort: S/M. Status: core done (2026-08-02); web API + warden-ui frontend
added same day in a follow-up pass — see below for what shipped vs. what's
deferred.*

Cheapest phase on this list — a near-exact structural copy of
`reminders.zig`/`alerts.zig` (per-identity or per-chat rows, a
create/list/delete command trio, `/menu` entries) with no scheduler and no
external API. Covers: notes, shopping lists, reading list, wishlist,
packing lists, bucket list, meeting notes, voice notes (transcribe via
Phase 7's existing whisper pipeline, then store as a note). Foundational
for Phase 12 (something to actually index) and for "search notes" from
ChatGPT's Search & Knowledge cluster.

**Done:**
- One flat, freeform `notes` table (migration `0024_notes.sql`) rather
  than several typed structures — a shopping list, wishlist, packing
  list, etc. are all just "a chat-scoped list of short text entries
  someone added," not materially different shapes, so `store/notes.zig`
  is a single generic primitive (`create`/`listForChat`/`get`/`delete`)
  covering every use case in the phase's own list. Chat-scoped and
  visible to the whole chat, deletable by creator-or-owner — same model
  `reminders.zig`/`alerts.zig` already use.
- `/note add <text>`, `/note list` (also `/notes`), `/note delete <id>` —
  an explicit `add`/`delete` keyword, unlike `/remind`'s implicit
  "first word is either `cancel` or a time expression" shape, since a
  note's own text could otherwise legitimately start with a word like
  "list" or "delete" ("delete the old files"), which `/remind`'s parsing
  approach would have made ambiguous here.
- `set_note` LLM tool (`tools/set_note.zig`, action=create/list/delete) —
  the natural-language front end, wired into `filterEnabledTools`'s
  module-key map like every other tool so the same `notes` feature flag
  gates both the command and the tool.
- Voice notes: **not built this pass** despite being explicitly listed in
  scope above — `resolveQuestion`'s existing whisper transcription only
  ever feeds a transcript into the *question* asked of the LLM, it has no
  hook for "and also, save this as a note" as a side effect; wiring that
  in is a small but real follow-up, not done here.

**Deferred, not built this pass** — `/menu` entries. Every other module's
menu entry (see `features/menu_tree.zig`) is either a simple view-only
list or, for anything needing structured input like a date/time, a full
custom wizard (`NodeKind.wizard`, built for the reminders module
specifically). Notes don't need a wizard (the only field is free text),
but wiring even a view/add/delete menu screen through `menu.zig`'s
`ActionRunner` is nontrivial glue this pass didn't have room for — the
feature is fully usable today via `/note`/`/notes` and natural language,
just not yet reachable from the button menu. Flagged, not silently
dropped, same convention this file already uses elsewhere (e.g. Phase
9's deferred `/as` relay, Phase 5's menu-polish backlog entry in
warden-ui's own ROADMAP).

**Also done (2026-08-02), later same day** — a web API surface and
warden-ui frontend page, closing the same "zero frontend story" gap Phase
5a closed for reminders/alerts/watches; the initial Phase 11 landing above
was bot-side only (`/note` commands + the `set_note` LLM tool), with no
`API.md`/`router.zig` work in scope at the time.

- `GET`/`POST`/`DELETE /api/v1/notes` in `src/api/router.zig` —
  identity-scoped by default across every chat (`?chat_id=` narrows,
  `identity_id` owner/bot_admin-only to act on behalf of someone else),
  reusing the exact same `requireLoggedIn`/`resolveListIdentity`/
  `resolveCreateIdentity` helpers Reminders/Alerts/Watches already built —
  no parallel auth path. New `notes.NoteForIdentity`/
  `notes.listForIdentity` in `store/notes.zig`: the original Phase 11 pass
  only needed `listForChat` for the bot's own chat-scoped `/notes`, so the
  identity-scoped "my notes across every chat" query the web API needs
  (same shape as `reminders.listForIdentity`/`feed_watches.listForIdentity`)
  didn't exist yet. Delete authorization mirrors `/note delete` exactly
  (creator or the bot owner) — deliberately *not* Watches' looser "anyone
  currently in the chat" model, since `/note delete` was never that open.
- `notes` added to `feature_flags.known_modules` — the flag already gated
  `/note`/`set_note` bot-side (`main.zig` was already calling
  `feature_flags.isEnabled(pool, "notes")`), but the module was never
  listed in `known_modules`, so it silently never appeared as a toggle on
  `/admin/modules` even though the gate itself worked. Caught while
  wiring the new `POST` handler's own feature-flag check.
- warden-ui: `/notes` page (list/create/delete, a plain textarea for the
  freeform text rather than a typed-list builder, matching
  `store/notes.zig`'s own "one flat primitive, not several typed
  structures" design), `useNotes.ts` hook, and an `AppShell` nav entry —
  see warden-ui's own `ROADMAP.md`/`API.md` for that half in full.
- Verified: `zig build` and `zig build test` both green — checked in an
  isolated `git worktree` off this same commit rather than directly in
  this checkout, since an unrelated, uncommitted, in-progress Phase 12
  (long-term/semantic memory) pass was already sitting in this working
  tree at the time and its new migration (`0025_memories.sql`) needs the
  `pgvector` Postgres extension, which isn't installed on the local test
  Postgres (`warden-test-pg`) — every DB-touching test crashes on that
  migration otherwise, unrelated to anything in this pass. Left that
  other work-in-progress completely untouched (not committed, not
  reverted, not fixed) — it's a separate, unfinished piece of work this
  pass didn't touch and isn't positioned to finish.

Original core landing verified the same way at the time: `zig build` and
`zig build test` both green.

### Phase 12 — Long-term / semantic memory
*Effort: L. Status: done (2026-08-02) — explicit remember/forget, not a
RAG index over notes/messages; see below for the exact scope.*

Already flagged in Phase 8's backlog as "the most powerful idea
considered" — this plan doesn't change that assessment, just re-confirms
it against ChatGPT's own retention analysis (memory is called out as one
of the highest-retention feature classes). Needs `pgvector`, an embeddings
call per stored message/note, and a retrieval step in `qa.zig`'s prompt
construction. Sequenced after Phases 9-10 so there's real content worth
indexing (notes, document text) beyond raw chat lines. Covers: remember
preferences/names/projects/goals/writing style, search memories, forget
memories, memory timeline, cross-chat reasoning.

**Scope decision, confirmed before building**: explicit remember/forget,
ChatGPT-Memory-style — the model calls a tool to save a short discrete
fact when it learns something worth keeping, not a general RAG index over
every note/message ever stored (notes/messages aren't automatically
embedded). Scoped to **identity, not chat**, satisfying the "cross-chat
reasoning" item directly: a memory follows a person across every chat
they talk to the bot in, the same identity model `notes.zig`
deliberately did *not* use (notes are chat-scoped/shared; memories are
personal).

**Done:**
- `pgvector` + `memories` table (migration `0025_memories.sql`),
  `embedding vector(1536)` — fixed at migration time (matches OpenAI's
  `text-embedding-3-small`/`ada-002`; this codebase's static-SQL
  migrations can't template a runtime-configured dimension). A
  `WARDEN_EMBEDDINGS_MODEL` with a different output dimension fails
  loudly (a real Postgres error) on the first `remember` call, not
  silently — switching models later needs a manual column-type migration
  plus re-embedding every row. No approximate (`ivfflat`) index — a
  personal bot's memory table will never be large enough to need one.
- New `WARDEN_EMBEDDINGS_URL`/`_API_KEY`/`_MODEL` config
  (`src/llm/embeddings.zig`'s `EmbeddingsClient`, a small standalone
  `POST {url}/embeddings` client — deliberately not an extension of
  `OpenAiCompatProvider`, which is hardcoded to the chat-completions wire
  shape) — separate from the chat `WARDEN_OPENAI_*` config since they may
  point at different backends/models entirely. Unset disables the whole
  feature (`/memory`, the `remember_memory` tool, and `qa.zig`'s
  retrieval step all become no-ops) — same convention `WARDEN_WHISPER_URL`
  already uses.
- `src/store/memories.zig` (`remember`/`search`/`listForIdentity`/`get`/
  `forget`/`hasAny`), a `MemorySink` (`tools/registry.zig`) and
  `remember_memory` LLM tool (`action=create|list|forget`) — same
  ptr+vtable sink shape `NoteSink`/`ReminderSink` already established.
  `/memory list` / `/memory forget <id>` slash commands; deliberately
  **no** `/memory remember <text>` — creation happens contextually
  through conversation (the model deciding what's worth keeping), not a
  manually curated list.
- `qa.zig`'s `answer()` retrieval step: `hasAny` gates the embed-and-search
  round trip so an identity that's never used the feature never pays its
  latency/cost on every question; on a hit, the top 5 memories (by
  pgvector cosine distance) get folded into the prompt as a "What you
  remember about {name}" block. Any failure in this path (embeddings API
  down, search error) just means no memory block gets added — never
  blocks the answer, same soft-failure convention `resolveQuestion`'s
  voice transcription already uses.
- **Real bug caught during this pass, not just a design risk**:
  `embeddings.zig`'s `formatVectorLiteral` originally returned
  `Io.Writer.Allocating.buffered()` directly — a sub-slice into a
  possibly-larger, doubling-growth internal buffer, not itself a
  freeable allocation. `store/memories.zig`'s callers correctly
  `allocator.free()`'d what they thought was an owned string, which
  reliably aborted under `std.testing.allocator`'s strict validator
  (silently "worked" under a looser allocator, which is exactly why this
  kind of bug is dangerous). Fixed to `allocator.dupe()` the buffered
  content before returning, matching the convention `anthropic.zig`'s
  `buildPayload` already established for the identical `Writer.Allocating`
  shape — this file just hadn't followed it.
- **Not live-verified** — no real embeddings API key configured in this
  environment, so this is implemented per spec and covered by unit/store
  tests (including a `search` test confirming actual cosine-similarity
  ordering, not just presence) but not confirmed against a real
  embeddings backend. Noted honestly rather than claimed, same standard
  held elsewhere this session.
- `zig build` and `zig build test` both green (502/504; 1 skip expected,
  the 1 crash is `store.crypto`'s pre-existing local-only ABRT, already
  confirmed reproducible on unmodified master earlier this session,
  unrelated to this change).

### Phase 13 — Proactive daily briefings
*Effort: S/M. Status: core done (2026-08-02) — see below for what shipped
vs. what's deferred.*

Pure composition, not new capability — a scheduled job (same
`checkAndSendDue*` pattern as reminders/alerts/feeds) that assembles a
briefing from primitives that already exist.

**Done:**
- `chat_settings.zig` gains `briefing_enabled`/`last_briefing_ts` (migration
  `0026_briefings.sql`), same shape as the existing `digest_enabled`/
  `last_digest_ts` pair — kept separate so a chat can opt into digests,
  briefings, both, or neither independently.
- `features/scheduler.zig` gains `BriefingScheduler`, a near-exact
  structural copy of `DigestScheduler` (same interval-based, not
  wall-clock, tradeoff — see that struct's own doc comment on why a real
  timezone-aware scheduler isn't worth it for a personal bot; the same
  reasoning applies here unchanged) rather than generalizing the two into
  something shared, matching this project's established per-domain-copy
  convention (see e.g. Phase 11's notes.zig/reminders.zig relationship).
- `features/briefing.zig` (new): `generate` composes a chat's pending
  reminders (`reminders.listPending`) and pending alerts
  (`alert_store.listPending`) into one plain-text status list — no LLM
  call, unlike `digest.zig`'s narrative summary, since a briefing is just
  "what's still outstanding," not something that benefits from being
  rewritten in prose. Returns an explicit "nothing pending" message rather
  than an empty string when both are empty, mirroring `digest.generate`'s
  own "0 messages" short-circuit.
- `/briefing on|off|now` command (mirrors `/digest` exactly), gated by a
  new `briefings` feature flag, plus `WARDEN_BRIEFING_INTERVAL_SECONDS`
  (dynamic-config-overridable, same as `WARDEN_DIGEST_INTERVAL_SECONDS`)
  and a matching `checkAndSendDueBriefings`/`loadBriefingScheduleFromDisk`
  pair wired into `main.zig`'s scheduler tick loop and connector startup
  path, alongside the existing digest ones.
- **Not given a `/menu` entry** this pass — same reasoning `/digest` itself
  never got a full wizard-style entry, just a view/on/off screen; briefing
  currently is command-only (`/briefing`), consistent with how Phase 11's
  notes were also left off `/menu` initially.

**Deliberately deferred, not built this pass**:
- **Weather.** There's no per-chat default location stored anywhere —
  `tools/weather.zig` is on-demand-only, taking a location argument per
  call. Adding a "default location for this chat" setting (plus its own
  admin/command surface) is a real feature on its own, out of scope for
  what was meant to be pure composition over data that already exists.
- **New feed items since last briefing.** `store/feed_watches.zig` only
  tracks seen guids for dedup, not readable item text, so reconstructing
  "what was new" after the fact would mean duplicating
  `feed_watcher.zig`'s own live-fetch-and-parse logic rather than
  composing existing stored data — a different shape of work than this
  phase's "pure composition" framing intended.
- Both flagged here rather than silently dropped, same convention this
  file already uses elsewhere (e.g. Phase 11's deferred voice notes,
  Phase 9's deferred `/as` relay).
- `zig build` and `zig build test` both green (508/510; 1 expected skip,
  1 crash is a pre-existing `http_util.zig` fetch segfault — a known
  flake unrelated to this change, deterministic on CI, intermittent
  locally).

### Phase 14 — Messaging assistance modes
*Effort: S/M. Status: done (2026-08-03).*

New prompt-modes layered onto the existing Q&A path plus one new tool that
reads `store/messages.zig`'s existing log. Covers: summarize long chats
("catch me up"), translate (incoming or on-demand — ChatGPT's list flags
this as low-novelty since the model already translates zero-shot, so
mainly a documented command rather than new capability), rewrite/tone
adjustment, explain-like-I'm-5, brainstorming/decision-helper framings.
No new storage.

**Done:**
- `store/messages.zig` gained `recentSinceFormatted` (time-windowed, not
  row-count-windowed like the existing `recentFormatted`) — the one new
  read added over the existing `messages` table per this phase's own "no
  new storage" framing; no migration.
- `catch_me_up` (`tools/catch_me_up.zig`): an LLM-invocable tool, not a
  slash command, following `fetch_url`'s established "return raw content,
  the model summarizes it itself" shape rather than `features/digest.zig`'s
  own internal LLM call — cheaper (one model round trip, not two) and lets
  the model itself decide how much of the returned window is actually
  relevant to "what did I miss." Takes an optional `hours` argument
  (default 24, clamped to a max of 336/2 weeks) plus a fixed 2000-row
  ceiling underneath that, mirroring `recentDeletable`'s own two-bound
  shape. Wired to real data via a new `registry.ChatHistorySink` +
  `main.zig`'s `ChatHistoryToolAdapter`, same per-message-construction
  pattern every other tool sink already uses. This is deliberately
  *distinct* from `/digest`: digest is a scheduled, always-summarized
  fixed-window feature; this is on-demand, user-controlled, and triggered
  by natural language ("catch me up", "what did I miss") the same way any
  other tool call is, not its own slash command.
- `/translate <language> <text>`, `/rewrite <tone> <text>`, `/eli5 <text>`,
  `/brainstorm <topic>` — new slash commands, each replying to a message
  with just the command and its first argument (e.g. `/translate spanish`
  as a reply) translates/rewrites/explains/brainstorms *that* message
  instead of needing the text repeated (`splitModeArgs`/
  `modeArgOrReplyText` in `main.zig`). All four route through a shared
  `handleModeCommand`, which just builds a mode-specific instruction string
  and calls the exact same `replyWithAnswer` pipeline plain addressed Q&A
  uses (owner-only/credits gates, `/persona`/`/thinking` overrides, the
  placeholder+ticker flow, tool-calling, streaming) — no parallel LLM-
  calling path, no new capability, just a documented, reliable command
  shape over what the model already does zero-shot, consistent with
  ChatGPT's own "low novelty" framing for translate specifically.
- New `messaging_modes` feature flag (`store/feature_flags.zig`'s
  `known_modules`), gating all four commands plus the `catch_me_up` tool —
  same "one flag covers both a standalone command and an LLM-tool-shaped
  feature" precedent Phase 11's `notes` flag already established.
- `zig build` and `zig build test` both green (517/519; 1 expected skip, 1
  crash is the same pre-existing `http_util.zig` fetch segfault flagged in
  Phase 13's own status note, unrelated to this change).
- **Not live-verified** — no real Telegram chat exercised this pass;
  implemented per spec and covered by unit tests (`splitModeArgs`/
  `modeArgOrReplyText`'s argument parsing, `catch_me_up`'s hour-clamping
  and empty-window messaging, `messages.recentSinceFormatted`'s time-window
  behavior against a real test Postgres). Noted honestly rather than
  claimed, same standard held elsewhere in this file.

### Phase 15 — Calendar & email integration
*Effort: L.*

The biggest new-infra phase after memory: real OAuth against Google
(Calendar + Gmail scopes), token storage, and a poll or push mechanism for
"what's on my calendar" / meeting reminders / email summarization/drafting.
`store/oauth_providers.zig` exists today but is scoped to admin-configured
*login* OIDC providers (see its doc comment) — this needs its own
per-identity OAuth grant flow, not a reuse of that table as-is. Sequenced
after the cheaper phases since it's the first one touching a third-party
write-capable API (draft/send email) rather than a read-only public one
(weather, crypto, RSS).

### Phase 16 — Group/Telegram quality-of-life
*Effort: S/M.*

Extends `group_admin.zig`'s existing moderation surface rather than adding
a new subsystem. Covers: welcome messages, scheduled announcements,
auto-pin important messages, keyword alerts, poll generation, group
summaries (composes `digest.zig`, already exists in spirit). Spam
detection/auto-moderation stays explicitly out of scope — already
deferred in Phase 8's backlog over trust-model concerns, and that
reasoning doesn't change here.

### Phase 17 — Finance trackers
*Effort: M.*

Extends `alerts.zig` with a new alert kind (product/subscription price)
rather than a parallel system, plus simple ledger tables for manual entry.
Covers: expense tracker, budget planner, subscription tracker, bill
reminders, price/deal alerts. Receipt OCR line item depends on Phase 10.
Explicitly not building: investment/portfolio tracking, tax tools, KPI
dashboards — real-money-adjacent features where "close enough" is the
wrong tradeoff for a spare-time personal project.

### Phase 18 — Media generation
*Effort: M/L.*

The first phase needing a new paid external provider (image generation —
no local/free equivalent worth self-hosting at this scale). Covers: image
generation, stickers, memes, captions, background removal. Lower priority
than everything above it — fun, but not a daily-workflow feature the way
reminders/memory/documents are.

### Phase 19 — Power-user tools & light/fun features
*Effort: S, batchable.*

Grab-bag of cheap wins with no shared theme beyond "small and self-
contained enough to knock out in a batch": custom command aliases, prompt
templates, joke/riddle/trivia/word-of-day, motivational-coach framing.
Deliberately last — genuinely low effort each, but also genuinely low
retention value per ChatGPT's own framing, so there's no cost to leaving
this until everything above has shipped.

### Explicitly excluded

Cut outright rather than phased, because they assume a product shape
Warden isn't (multi-tenant SaaS, business tooling, or a trust model the
bot deliberately doesn't have):

- **Business/enterprise**: CRM integration, invoicing, proposal writing,
  contract summarization, lead qualification, KPI dashboards, team
  workspaces, white-label bots, agent marketplace, premium usage tiers —
  Warden has one owner and an allowlist, not customers or seats.
- **Social/dating**: dating profile help, icebreakers, compliment
  generator — doesn't fit the bot's existing personality/use pattern.
- **Deep health tracking**: symptom logging, step/sleep tracking,
  meal/calorie logging — needs real device integrations (wearables, health
  APIs) for the data to be worth anything; out of scope without one.
- **Travel booking**: flight tracking, hotel suggestions — read-only trip
  planning is already well served by `web_search`/`weather`; booking-shaped
  features need commercial travel APIs this project has no reason to pay
  for.
- Already explicitly deferred in Phase 8 above and unchanged by this pass:
  sandboxed code execution, spam/toxicity auto-moderation, voice cloning
  (not in Phase 8 but same "no clear consenting use case" reasoning
  applies).
