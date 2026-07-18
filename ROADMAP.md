# Warden Roadmap

This tracks planned work beyond what's documented in `README.md` today. Phases
are meant to ship incrementally, one at a time, not as a big-bang rewrite —
this is a personal project built in spare time, so scope stays deliberately
small per phase.

Status as of writing: **Phase 1 is committed** (reminders and
file-conversion landed in `fc3658d`), **Phase 2's core (unencrypted Matrix)
is implemented** but not yet live-tested against a real homeserver (no
credentials available this session; see Phase 2's note — Matrix E2E
encryption was split out into its own Phase 2b rather than bundled in), and
**Phase 3 (reminder recurrence + absolute time) is committed**. `zig build
test` green (131/131). Phases 4 onward are unstarted.

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
*Effort: L. Dependencies: Phase 1's sink pattern; Phase 2's chat-id fix.*

The standout new feature, and the best fit for warden's personality: this
composes the existing `crypto_price`/`weather`/`air_quality` tools with the
reminders infrastructure's sink/scheduler pattern to support "ping me when
BTC crosses 70k" or "tell me if Tehran's AQI gets bad."

- New `src/store/alerts.zig` (chat_id, identity_id, kind, subject, condition,
  threshold, cooldown, last_triggered_at) + migration, same shape as
  `reminders.zig`.
- New `AlertSink` ptr+vtable in `registry.zig` alongside the existing
  `ReminderSink` — same reasoning: `registry.zig` is imported by every tool
  and must never depend on `src/store/*` directly.
- New `src/tools/set_alert.zig` (LLM-invocable, mirroring `set_reminder`'s
  `action=create|list|cancel` shape).
- New `src/features/alerts.zig`: a poll-loop hook (`checkAndDeliverAlerts`,
  wired in next to `checkAndSendDueDigests`/`checkAndSendDueReminders`) that
  batches pending watches by kind and calls each source tool's fetch-and-
  parse core — refactored out of `execute()` into a plain function each tool
  calls, so the alert loop can reuse it without going through the LLM
  tool-call loop — then compares against the threshold and delivers on a
  cooldown so a persistent condition doesn't spam every poll tick.
- `/alert crypto bitcoin above 70000`, `/alerts`, `/alert cancel <id>`
  commands, matching `/remind`'s authorization pattern (creator or owner may
  cancel).

## Phase 5 — RSS/news watcher
*Effort: M. Dependencies: Phase 2.*

Composes `scrape_site`/`web_search` and the digest infrastructure into a
standing feed-watcher.

- New `src/store/feed_watches.zig` (chat_id, feed_url, last_seen_guid_or_ts).
- New `src/features/feed_watcher.zig`: poll each watched feed (plain HTTP GET
  + a small hand-rolled RSS/Atom parse — no new dependency needed given
  `http_util.zig` already exists), diff against last-seen, and reuse
  `digest.zig`'s pattern of an LLM call over a small text blob to write a
  one-paragraph "here's what's new" blurb instead of dumping raw items.
- `/watch <feed_url>`, `/unwatch <feed_url>`, `/watches` commands, same shape
  as `/digest on|off`.
- Optional: let the LLM tool-call into `web_search`/`scrape_site` first to
  *find* a feed URL from a plain-language "watch TechCrunch" request.

## Phase 6 — Per-chat persona / system-prompt override
*Effort: S. Dependencies: Phase 1.*

Small, high-value, and a near-perfect fit for the existing `chat_settings`
typed-column pattern (`magic_word`, `digest_enabled` already live there).

- Extend `chat_settings.zig` with a nullable per-chat system-prompt override,
  same `INSERT ... ON CONFLICT DO UPDATE` idiom as `setMagicWord`.
- `/persona <text>` (owner-only, matching `/magicword`'s and `/scraper`'s
  owner-gating precedent — a chat member setting the bot's entire
  personality is a bigger lever than a magic word) and `/persona off` to
  fall back to `config.system_prompt`.
- `qa.zig`'s answer path takes the per-chat override when set, global
  default otherwise.
- Cool factor: different group chats get a genuinely different bot
  ("sarcastic assistant" in one, "terse and formal" in another) without
  redeploying — cheap to build, visible payoff.

## Phase 7 — Voice message transcription (+ optional TTS)
*Effort: M/L depending on TTS scope. Dependencies: Phase 1 (attachment
plumbing, ffmpeg already in the image).*

- Add `whisper.cpp` (or a small server) to the Dockerfile, same "add the
  binary, shell out to it" pattern `convert.zig` already established for
  pandoc/ffmpeg/ImageMagick.
- New `src/features/transcribe.zig`: given `ctx.attachment_path` for a
  voice/audio attachment, normalize to 16kHz mono wav via ffmpeg (reusing
  `convert.zig`'s process-running helper), then shell out to whisper.cpp.
- Wire into `main.zig`'s attachment-handling path so a voice note addressed
  to the bot gets transcribed and fed to the LLM as the actual question,
  instead of today's generic "[The user sent a voice message...]"
  placeholder.
- Optional stretch: TTS replies (piper or similar) — lower priority than
  transcription, call out as a nice-to-have rather than a hard deliverable.

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
