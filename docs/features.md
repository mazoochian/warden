# Features

One section per module. "Module flag" is the `feature_flags` key
(configuration.md); access rules are summarised in commands.md and
access-control.md. Every scheduled feature runs from the ~30 s scheduler
loop in `main.zig`.

## Reminders (`features/reminder_format.zig`, `store/reminders.zig`)

`/remind <when> <message>` and the `set_reminder` tool. Accepted shapes:
durations (`10m`, `2h30m`, `3d`), clock times (`18:30`, `6pm` — today or
tomorrow), calendar dates (`M/D`, `D/M`, `Y-M-D`, year optional and rolling
forward), named weekdays (resolved server-side from the current date — the
model is told not to compute day offsets itself), and `every <interval>`
for recurrence. Times are interpreted in the setter's personal timezone
(`user_settings`, a fixed UTC offset). Delivery goes through the
connector owning the chat; a chat whose platform has no active connector
is skipped and logged. `/reminders` lists everyone's pending reminders in
the chat; the web API lists the caller's across chats.

## Alerts (`features/alerts.zig`, `store/alerts.zig`)

Standing conditions over crypto prices, weather and AQI: `subject above|
below threshold`. Checked each tick, each alert fires once per crossing
with a cooldown, and is delivered like a reminder.

## Feed watches (`features/feed_watcher.zig`, `feed_parse.zig`)

RSS/Atom, per chat. Seen GUIDs are stored so a restart never replays a
feed. A new item is announced with a one-line model-written blurb (no
tools). `/watchcheck` forces a check for testing. Anyone in the chat may
remove a watch.

## Digests and briefings (`features/digest.zig`, `briefing.zig`, `scheduler.zig`)

- **Digest** (`/digest on|off|now`): a model summary of the chat's recent
  history every `WARDEN_DIGEST_INTERVAL_SECONDS`. Opt-in per chat,
  persisted in `chat_settings` so it survives restarts.
- **Briefing** (`/briefing on|off|now`): pending reminders and alerts plus
  an optional weather line for the chat's `/location`, composed without a
  model call. Weather failures drop the section, never the briefing.
- **Daily digests for memory** (`store/daily_digests.zig`) are the
  per-chat episodic memory the context assembler ranks; distinct from the
  user-facing `/digest`. Populated by `storage_sense.tickBacklog`'s routine
  compaction (see Storage Sense below), not just the disk-pressure ladder.
- `/summary [hours]` and the `catch_me_up` tool summarise a window of the
  chat's own history on demand.

## Notes (`store/notes.zig`)

One flat table backs notes, shopping lists, wishlists, etc. — a
chat-scoped list of short lines. `/note`, `/notes`, the `set_note` tool,
and `/note` as the caption of a voice message (saves the transcript).
Delete is creator-or-owner.

## Long-term memory (`store/facts.zig`, `tools/remember_memory.zig`)

Per-identity facts that follow a person across chats. Facts are
bitemporal: a new fact can supersede an older one (`superseded_by`,
`valid_to`), retired facts are never retrieved, tentative facts are shown
to the model only in a small "may be stale" set. Ranking is hybrid
(embedding similarity when `WARDEN_EMBEDDINGS_URL` is set, plus keyword,
recency and salience). Memory works without an embeddings endpoint —
a startup notice says which mode is active. `/memory list|forget`.
Unconfirmed tentative facts (`confirmations <= 1`) older than
`WARDEN_FACTS_TENTATIVE_MAX_AGE_DAYS` (30) auto-retire the same way
`/memory forget` does — status `retired` plus a `fact_tombstones` row, never
a hard delete (`facts.autoRetireStaleTentative`, run from
`storage_sense.tickBacklog`) — so a wrong or stale one-off guess doesn't
occupy that context slot forever.

## Keyword alerts, welcome messages, polls, announcements

- **Keyword alerts** (`store/keyword_alerts.zig`): a plain substring scan
  on every message (no model call), notifying the subscriber. Runs for
  every sender at the same passive tier as message recording.
- **Welcome messages** (`/welcome`): sent per joined member from the join
  service message, `{name}` substituted.
- **Polls** (`/poll q | a | b`, `create_poll` tool): 2–10 options, native
  platform polls where available.
- **Announcements** (`store/announcements.zig`): immediate, `at <time>`, or
  `every <interval>`, pinned by default (`/autopin`), cancelable, listed.

## Finance (`store/expenses.zig`, `budgets.zig`, `subscriptions.zig`)

Per-chat expense ledger, monthly budgets per category, and recurring
subscriptions. Amounts are parsed by hand into integer cents (never via
float), USD only, no conversion. `/expense summary` shows per-category
totals against budgets for the current UTC month. The `set_expense` tool
lets the model log a receipt it can see in a photo.

## Power tools (`power_tools` flag)

`/alias` — custom shortcuts expanded exactly once (no recursion) and never
allowed to shadow a built-in name; `/template` — saved prompts.

## File conversion and transcription (`features/convert.zig`, `convert_flow.zig`, `transcribe.zig`)

- One-shot: send a file with the caption `/convert <format>`.
- Interactive: `/convert` (or the `begin_file_conversion` tool) → upload →
  pick a target format from buttons/reactions; pending state is keyed by
  (chat, user) and expires after `WARDEN_CONVERT_TIMEOUT_SECONDS`. An
  upload arriving mid-flow is claimed before normal dispatch, so a
  captionless file in a group isn't dropped.
- Conversion shells out to external tools (ffmpeg, ImageMagick, LibreOffice
  ...) under a wall-clock timeout; failures are reported in plain words.
- Voice/audio messages are transcribed through `WARDEN_WHISPER_URL`; a
  captionless voice message addressed to the bot becomes the question.

## Menu (`features/menu.zig`, `menu_tree.zig`)

`/menu` renders a comptime tree of modules as buttons (Telegram inline
keyboards, edited in place) or emoji reactions (Matrix, a new message per
level). Per-(chat, user) sessions with a timeout; nodes have `MinRole`
tiers, hidden when the presser doesn't qualify (except in Help mode, which
shows everything); `awaiting_input` nodes consume the presser's next
message as the command's argument. The tree doubles as the Help browser's
content.

## Video auto-download (`features/video_download.zig`)

Off by default per chat (`/videodownload on`), gated bot-wide by the
`video_download` flag. Any message containing a YouTube/Instagram/X link is
downloaded with `yt-dlp` (capped around 720p with a fallback for portrait
clips, whose `height` is the long side) and, in lossy mode, compressed with
ffmpeg to fit the upload ceiling; lossless mode sends the original as a
file up to 50 MB. A bare link addressed to the bot is not also answered by
the model.

## Storage Sense (`features/storage_sense.zig`)

Disk-usage ladder for the volume `WARDEN_TMP_DIR` lives on, built after a
full disk took Postgres down: monitor → alert → prune/resample → sleep.

- Watermarks: low 80 %, high 90 %, flood 95 % (env or dynamic config).
- Monitoring and the daily high-watermark alert to the owner are gated by
  the `storage_sense_monitor` flag.
- Destructive rungs — pruning messages older than
  `WARDEN_STORAGE_SENSE_PRUNE_AGE_DAYS` (180), resampling old history into
  `is_summary` rows in batches, and **sleep mode** above the flood mark
  (everything except the owner's `/storage` commands pauses; recording
  continues) — run only with `WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED`, which
  defaults off. Sleep clears once usage drops `RESUME_MARGIN_PCT` below the
  flood mark.
- `/storage status|autopilot on|off|cleanup messages|resample|tmp` is the
  manual surface and always works.
- **Backlog compaction** (`storage_sense.tickBacklog`) is a *separate*,
  routine pass — not gated by any watermark, since disk health and context
  quality are different concerns with different cadences. Once a chat's
  non-summary message count exceeds `WARDEN_LLM_HISTORY_MESSAGES *
  WARDEN_STORAGE_SENSE_BACKLOG_MULTIPLIER` (default 2x), its oldest batch is
  compacted the same way the disk ladder's resample does, but this is the
  path that actually keeps `daily_digests` populated on a host that never
  hits the low watermark — without it that table (and the "Relevant history
  in this chat" context section it feeds) stays empty indefinitely. Runs at
  most every `WARDEN_STORAGE_SENSE_BACKLOG_INTERVAL_SECONDS` (1h) and also
  sweeps stale tentative facts (see Long-term memory above) on the same
  cadence.

## Reply autonomy and drafts (`features/reply_drafts.zig`)

For the personal Telegram account. `/autonomy off|draft|auto [prompt]` per
chat (stored in `chat_settings`; a separate prompt from `/persona` so a
persona never makes ghostwritten replies sound like a bot):

- **draft**: the model writes a reply in the owner's voice and language;
  the owner is notified through the Bot API chat with Approve/Discard
  buttons, and the draft is pre-typed into that chat's Telegram composer.
  Drafts are stored in `reply_drafts` (not memory) with a 24 h expiry so a
  deploy never loses one; one pending draft per chat.
- **auto**: the reply is sent immediately.
- The bot never drafts for its own DM with the owner (`isOwnBotDm`).
`/drafts`, `/approve`, `/discard` and the web UI act on the same table.

## Personal-account tools (owner only)

Wired into the tool context only when the asker is the owner:
`list_personal_chats`, `summarize_unread_chat` (marks read deliberately),
`send_personal_message`, `reply_to_message`, `set_chat_monitoring` /
`set_default_chat_monitoring`, `get_bulletin`. Monitoring
(`chat_settings.monitor_importance`, `user_settings.monitor_all_default`;
levels off/low/normal/high) selects which chats feed the **bulletin** — a
rolled-up "what happened since I last asked" over monitored chats, with a
per-owner cursor that a plain `get_bulletin` advances and an explicit
`hours` argument leaves alone. `/tdsummary`, `/tdchats`, `/tdsearch`,
`/tdsend`, `/sendas` are the command-side equivalents.

## Curated feed (`features/curated_feed.zig`, `store/feed.zig`)

Reads opt-in channels through the personal account, filters each new post
with a one-word relevance check against a natural-language policy, then
summarises survivors into a target channel on its own interval. Inert
until enabled *and* a target *and* a policy are set; a newly added source
is caught up silently; per-pass ceilings bound cost. `/feed` and a web
page configure it.

## Redaction (`features/redact.zig`)

`/redact <N>` deletes the last N deletable messages from local history,
`reply [N]` from a point, `text <s>` by substring, `regex <p>` with the
ReDoS-safe engine in `text/safe_regex.zig` (bounded states × input, never
backtracking). Only messages the bot recorded with a native id can be
deleted.

## Web scraping and search tools

`web_search` needs `WARDEN_SEARXNG_URL`; `fetch_url` and `scrape_site`
extract readable text on-device (`tools/html_extract.zig`) or through a
remote backend the owner configures with `/scraper`. Every network tool
runs under `http_util`'s timeouts.
