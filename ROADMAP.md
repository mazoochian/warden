# Warden Roadmap

This tracks planned work beyond what's documented in `README.md` today. Phases
are meant to ship incrementally, one at a time, not as a big-bang rewrite —
this is a personal project built in spare time, so scope stays deliberately
small per phase.

Status as of writing: **Phase 1 is committed** (reminders and
file-conversion landed in `fc3658d`), **Phase 2's core (unencrypted Matrix)
is implemented** but not yet live-tested against a real homeserver (no
credentials available this session; see Phase 2's note — Matrix E2E
encryption was split out into its own Phase 2b rather than bundled in),
**Phase 3 (reminder recurrence + absolute time) is committed**, **Phase 4
(price/metric alerts) is committed**, **Phase 5 (RSS/news watcher) is
committed**, **Phase 6 (per-chat persona) is committed**, and **Phase 7
(voice transcription; TTS deliberately not included, see its note) is
committed**. `zig build test` green (145/145). Phase 2b (Matrix E2E
encryption) is the only thing left unstarted.

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
*Effort: L. Dependencies: Phase 1. Status: implemented, not live-verified.*

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

Not done / next step: **live-test against a real homeserver** — this
session had no Matrix credentials to verify the login/sync/send/moderation
round trip against, so treat it as best-effort-correct-per-spec rather than
proven. Get a homeserver + access token (matrix.org account or self-hosted
Synapse/Dendrite), then run through: DM the bot, get invited/auto-joined to
a room, send/receive text, send a photo/document both directions, `/mute`
+`/unmute`, `/kick`/`/ban`, `/pin`/`/unpin`, `/delete`, and the live-editing
reply flow.

## Phase 2b — Matrix end-to-end encryption via libolm
*Effort: L (new — split out of Phase 2). Dependencies: Phase 2's live
verification, ideally, so encrypted-room bugs aren't confused with
plaintext-room bugs.*

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
