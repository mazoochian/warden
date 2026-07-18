# Warden Roadmap

This tracks planned work beyond what's documented in `README.md` today. Phases
are meant to ship incrementally, one at a time, not as a big-bang rewrite —
this is a personal project built in spare time, so scope stays deliberately
small per phase.

Status as of writing: **Phase 1 is committed** — reminders and
file-conversion landed in `fc3658d`, `zig build test` is green (114/114),
and a live smoke test against the dev bot is in progress. Everything from
Phase 2 onward is unstarted.

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

## Phase 2 — Real Matrix connector, parity with Telegram
*Effort: L. Dependencies: Phase 1.*

The biggest lift on this list, and worth doing early: every scheduled feature
after this point (alerts, RSS watching) currently carries a latent
multi-connector bug that's cheap to fix once and expensive to keep
re-discovering.

- Replace the ~60-line `src/platform/matrix.zig` stub (today: `poll` returns
  empty, `sendMessage` just logs and drops) with a real Client-Server API
  implementation at roughly `telegram.zig`'s scale (~400+ lines): login,
  `/sync` long-poll for incoming events, message send, `m.replace` edits (for
  the live-editing "thinking..." reply flow), media upload/download for
  `mxc://` URIs (`sendPhoto`/`sendDocument`/`downloadFile`), and power-level-
  based moderation (mute via power-level demotion, since Matrix has no native
  mute).
- Add `WARDEN_MATRIX_HOMESERVER_URL`, `WARDEN_MATRIX_ACCESS_TOKEN` (or
  user/pass), `WARDEN_MATRIX_OWNER_ID` to `config.zig` — purely additive,
  since `auth.isOwner` already takes a platform argument and iterates
  `config.owners`.
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
*Effort: M. Dependencies: Phase 1.*

Direct continuation of the reminders system, closing its two known
limitations (relative-duration-only, no repeats).

- Extend `reminder_format.zig`'s parser with a constrained absolute-time
  format (e.g. `HH:MM` for "today/tomorrow at") — explicitly not full
  natural-language date parsing or timezone awareness, matching
  `scheduler.zig`'s own documented tradeoff for a single-owner personal bot.
- New migration adding `recur_interval_seconds` to `reminders`
  (interval-based recurrence — "every 1d", "every 2h" — not cron/day-of-week
  scheduling, consistent with `DigestScheduler`'s interval-not-wall-clock
  philosophy).
- `reminders.zig`'s `dueUndelivered`/`markDelivered`: reschedule
  (`due_at += interval`) instead of clearing when a reminder recurs.
- `set_reminder`'s tool schema and the `/remind` command syntax gain a
  `recur` option.
- Pending-reminders list formatting shows "(repeats every 1d)" for recurring
  entries.

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
