# Warden - An assistant bot you don't entirely hate

Warden is a powerful AI-powered bot that can connect to various AI providers and social messaging platforms. Here is a list of the features it supports:
- Button Menu: `/menu` (or `!menu` on Matrix) opens a navigable, button-driven front end over every module below — Alerts, Reminders, Watches, Statistics, Convert, Group Administration, Settings, and a read-only Help browser — instead of needing to remember slash-command syntax. On Telegram it edits one message in place as you navigate; on Matrix it uses reactions (a fresh message per level, for now — see "Menu" below); on XMPP (no button/reaction support) it degrades to a plain text overview. Only the person who opened a menu can drive its buttons. Reminders get a proper stepper wizard: ±1/±5 buttons for date/hour/minute/second, or just reply with a time/date to jump straight there
- Weather: Provides weather information for a given location
- Stats: Provides statistics about the group's conversations
- Word Cloud: Shows a word cloud of the most common words used in the group's conversations
- Group Management: Allows the bot to manage the group's conversations, including kicking and banning users. Restricted to the chat's own Telegram admins (or the bot owner) — checked live against Telegram on every use, not cached. A non-admin can still `/kick`/`/ban` by spending a token (see "Access control" below), and a bot admin can override the check entirely with `/sudo`
- Member ACL: `/slowmode <seconds>|off` enforces warden's own per-member cooldown between messages (Telegram's Bot API has no native slow-mode setter for bots) by deleting a message sent too soon — uniform on Telegram/Matrix, not enforced on XMPP. `/permission [<duration>] <+|-><letters> @user` (or reply) grants/revokes a granular per-member permission bitmask (letters: read/write/photos/videos/file/music/voice/video-messages/stickers/polls/embed-links/reactions/edit-own-tag/change-info) — enforcement is partial and platform-dependent, see "Member ACL" below. `/tag @user <text>|off` sets a Telegram custom admin title (Telegram-only, and only works on existing chat administrators — a real Bot API limitation)
- Access Control: nobody but the owner talks to the bot at all by default — `/adduser`/`/allowchat` opt a user or a whole chat in. A separate `bot admin` role (`/addadmin`, owner-only to grant) is trusted bot-wide, not scoped to one chat, and can run any moderation command via `/sudo <command>` even where they aren't a real chat admin. `/redact` deletes messages in bulk (by count, by user, by literal text, or by a hardened regex engine — bot-admin-only, immune to catastrophic-backtracking hangs by construction)
- Web Search: Answers questions using a private SearXNG metasearch instance — no API keys or bot checks
- Air Quality: Current US AQI / PM2.5 / PM10 for any city (Open-Meteo)
- Crypto Prices: Live prices with 24h change (CoinGecko)
- QR Codes: Generates and sends QR code images into the chat
- Dictionaries: English definitions (dictionaryapi.dev) and slang (Urban Dictionary)
- Hacker News: Searches HN stories and discussions
- Site Scraping: Reads a page's clean text (not raw HTML), optionally crawling a few same-site links deep. Runs on-device by default; the owner can point it at an external scraping service instead
- Reminders: `/remind 30m walk the dog` (a relative duration, a clock time like `/remind 14:30 ...`, or a specific date like `/remind 5/22 14:30 ...`; or just ask in natural language) sets a one-off reminder; `/remind every 1d stretch` sets a recurring one; `/reminders` lists what's pending (including each recurring one's interval), `/remind cancel <id>` cancels one — restricted to whoever set it, or the bot owner. Every time shown is in *your own* timezone (a personal setting, guessed from your Telegram language and always overridable — see "Menu" below) and your own date/time formatting
- Alerts: `/alert crypto bitcoin above 70000`, `/alert weather Tehran above 35`, `/alert aqi Beijing above 150` (or just ask) set a standing watch, checked every few minutes in the background and delivered as a message once true — `/alerts` lists what's set, `/alert cancel <id>` cancels one, re-notifies only after a cooldown once already triggered — restricted to whoever set it, or the bot owner
- Feed Watching: `/watch <feed url>` watches an RSS/Atom feed and posts a short AI-written blurb here whenever something new shows up (checked every 15 minutes); `/watches` lists what's watched, `/unwatch <feed url>` removes one — open to anyone in the chat, like `/digest`
- Per-Chat Persona: `/persona <text>` overrides the bot's system prompt for just this chat — a sarcastic assistant in one group, a terse formal one in another — without redeploying; `/persona off` resets to the global default. Viewing the current persona is open to anyone; changing it is owner-only, like `/magicword`
- File Conversion: send a photo, document, voice note, audio, or video with `/convert <format>` as its caption (or ask for it in natural language) to get it back in a different format in one shot — images (jpg/png/webp/gif/bmp/tiff), audio/video (mp3/wav/ogg/mp4/webm/...), and documents (txt/md/html/docx/odt/rtf/pdf) each convert within their own family; a PDF source can only become plain text. Or say `/convert` alone (or just "I want to convert a file") and the bot walks you through it interactively — asks you to send the file, then shows every valid target format as tap-to-pick buttons (Telegram) or emoji reactions (Matrix); a "🔄 Converting…" placeholder shows while it works
- Voice Transcription: send a captionless voice message addressed to the bot and it transcribes it (via an optional self-hosted whisper.cpp instance) and answers the actual question, instead of just noticing "a voice message arrived" — a "🎙️ Transcribing…" placeholder shows while it works, morphing into "🤔 Thinking..." once the model takes over — see "Voice transcription" below to set it up
- Live Answers: Replies to your questions arrive as a threaded reply that updates in place — an animated "thinking" indicator while the model works, switching to "using <tool>…" while it calls a tool, then editing into the final answer. Each chat's messages are handled independently and concurrently, so one slow or stuck reply never blocks the rest of the bot
- Messaging Modes: `/translate <language> <text>`, `/rewrite <tone> <text>`, `/eli5 <text>`, and `/brainstorm <topic>` are reliable, documented commands over capabilities the model already has zero-shot — each also works by replying to a message with just the command and its first argument (e.g. `/translate spanish` as a reply translates that message). Ask "catch me up" or "what did I miss" (or use these commands) and the bot pulls its own logged history for the last 24h (configurable) and summarizes it itself — different from the scheduled `/digest`, this is on-demand and model-controlled
- Polls: `/poll <question> | <option 1> | <option 2> | ...` (2-10 options) sends a real native poll, or just ask in natural language ("make a poll asking pizza or sushi")
- Keyword Alerts: `/keyword add <word>` tracks a word for this chat — whenever anyone's message mentions it, the bot flags it right there (whole-word, case-insensitive, no LLM call). `/keyword list` / `/keyword remove <id>` manage the list, creator-or-owner to remove
- Welcome Messages: `/welcome <text>` (owner only to set; `{name}` is replaced with the new member's name) greets anyone who joins the chat automatically; `/welcome off` disables it. Off by default — opt in per chat
- Announcements: `/announce <text>` sends `<text>` into this chat right now and pins it; `/announce at <time> <text>` schedules a broadcast for later instead, `/announce every <interval> <text>` repeats one (same time grammar as `/remind`); `/announce list` / `/announce cancel <id>` manage scheduled ones. Chat admins only — unlike `/remind`, this makes the bot post to the whole group when nobody's watching. `/autopin on` additionally pins each *scheduled* announcement as it's posted (off by default; the bot needs pin permission) — the immediate `/announce <text>` form always pins regardless, same as the old standalone `/notice` command it replaced. Auto-pin only ever pins announcements an admin scheduled — the bot never decides on its own that someone else's message is "important"
- Group Summaries: `/summary [hours]` summarizes the last N hours of this chat (default 24, max 336) — the same summarizer `/digest` uses, but over a window you name and with no side effects, so it won't disturb the digest schedule the way `/digest now` does
- Video Auto-Download: `/videodownload on` makes the bot watch for YouTube/Instagram/X (Twitter) video links posted in the chat and auto-fetch/repost them via `yt-dlp` — never cached on disk, the local file is deleted the moment it's sent. `/videoquality lossy|lossless` picks delivery: lossy (default) fetches at up to ~720p with no cap on the source's size, compressing with `ffmpeg` down to Telegram's 50MB upload ceiling if needed — a bigger or longer clip just takes longer to fetch/compress, it isn't rejected outright; lossless delivers the original file untouched, so it's still bounded by that same 50MB ceiling since nothing shrinks it. Best-effort and fails closed — age-restricted, private, geo-blocked, oversized, or otherwise undownloadable links are silently skipped, never an in-chat error. A message that's nothing but one of these links never also triggers a separate LLM reply — just the download, no tokens spent commenting on a bare URL. Off by default (chat admins only to enable); not supported on XMPP (no file-sending capability there at all)
- Finance: `/expense add <amount> <category> [description]` (or just say it, or send a receipt photo) logs a manual expense — amounts are always stored as integer cents, never a float. `/expense summary` shows a category breakdown against any `/budget set <category> <amount>` (owner-only, monthly). `/subscription add <name> <amount> every <interval>` tracks recurring costs and their monthly-equivalent total — for reminders when they're due, use the existing `/remind every <interval> <message>`. No price/deal-alert or bank-integration features — manual entry only
- Management Rooms: bind a private room to *one* chat you administer with `/manage bind <chat id>` (1:1 — rebinding moves the room; `/manage list` shows the current binding, `/manage unbind` removes it), then drive that chat from it without joining it in a client. Every managerial action against a bound target's — mute, promote, token/credit grants, title/description/photo changes, and more — posts a log entry into its bound room (who, what, before/after state, and an "Undo" button where a clean reversal exists) as a standing audit trail. Most moderation and settings commands (`/kick`, `/mute`, `/redact`, `/announce`, `/token`, `/photo`, `/title`, `/description`, ...) run *directly* in a bound room with no prefix needed — typing `/kick` there acts on the room's bound target, not the room itself. `/as <chat id> <command>` does the same thing explicitly and from anywhere (no binding required) — `/as 7 /kick @spammer`, `/as 7 /welcome hi {name}`, `/as 7 /stats` — useful for admins managing several chats from one place (e.g. a DM). Either way the reply comes back to wherever you typed the command, not into the target chat. Both are strictly narrowing: they re-check on every use that you're a live admin *of the target chat* (never inferred from your standing wherever you typed it), and the relayed command still runs its own permission check too, so neither can ever let you do something typing the same command in that chat wouldn't have. Commands needing a message to point at (`/pin`, `/delete`) and stateful flows (`/menu`, `/convert`) are deliberately not relayable
- Group Identity: `/title <text>` renames the chat, `/description <text>` sets its description (empty clears it), `/photo` (send an image with this as its caption) sets the chat photo, `/photo remove` clears it — all admin-tier, all runnable directly in the group itself, in a bound management room, or via `/as`. Matrix maps these onto `m.room.name`/`m.room.topic`/`m.room.avatar`; XMPP has no equivalent and doesn't support them
- Quiet Moderation: add `-s` to `/mute`, `/unmute`, `/promote`, `/demote`, `/kick`, `/ban`, `/photo`, `/title`, or `/description` to skip the in-group confirmation — a bound management room's audit log still records it in full either way. `/silent on` makes `-s` this chat's default so it doesn't need typing every time. Bot admins/owner can use `-p` (phantom) instead to skip the audit log too, not just the in-group message; anyone else's `-p` is silently treated as `-s`. `/redact` doesn't support these flags yet
- Power Tools: `/alias add <name> <command or text>` makes `/name` re-dispatch as if you'd typed the saved expansion (a real built-in command can never be shadowed); `/template save <name> <text>` + `/template use <name> [extra]` re-asks a saved prompt through the normal Q&A path. `/joke`, `/riddle`, `/trivia` (all take an optional topic), `/wordoftheday`, and `/motivate` are quick, documented commands over what the model can already do zero-shot
- Storage Sense (owner-only, hidden from `/help` — a `/sudo`-style command, not a public feature): Warden watches its own disk usage roughly every 30 seconds (`storage_sense_monitor` feature flag) with an Elasticsearch-style watermark ladder. Past the high watermark (default 90%) it sends the owner a daily alert; `/storage status` reports live disk %, tier, autopilot state, and sleep state on demand. `/storage cleanup messages [chat id] [--before <date> | --keep <n>]` prunes old messages, `/storage cleanup resample [chat id]` compacts a chat's oldest messages into one LLM-written summary (so the model keeps enough context without keeping every raw message), and `/storage cleanup tmp` sweeps abandoned scratch files — all runnable by hand at any time. `/storage autopilot on` (off by default, until you've watched `/storage status` for a while) lets the ladder run these on its own once usage passes the low watermark (default 80%), and past the flood watermark (default 95%) puts the bot to sleep — no LLM replies, no tool calls, no video downloads, nothing responds but the owner's own `/storage` commands (passive message logging keeps running, since that's cheap and worth preserving) — until usage drops back below flood minus a hysteresis margin, so a nearly-full disk can't be driven the rest of the way full unattended
- Personal Account (Telegram, owner-only): once `WARDEN_TELEGRAM_USER_*` is configured (see below), `/tdlogin` logs Warden into the *owner's own* Telegram account via TDLib (phone number → login code → 2FA password if set), separate from the bot account every other feature uses. `/tdchats` lists that account's known chats; `/sendas <chat id> <text>` sends through it manually. `/autonomy off|draft|auto` sets the reply mode per chat: `draft` has the bot write a reply and hold it for approval — the notification comes with Approve/Discard buttons (`/approve`/`/discard <chat id>`, or `/drafts` to list, still work if typed instead), `auto` sends it immediately. `/tdsummary <chat id or name>` (or just ask, e.g. "what's unread in the Alice chat") fetches that chat's actual unread messages fresh from Telegram, has the bot summarize them, and marks them read — matching titles work as well as raw ids, and an ambiguous name lists the candidates instead of guessing
- LLM Delegation: Warden can hand a task off to another configured AI model — a second Claude persona, ChatGPT, a local model, anything speaking Anthropic's or an OpenAI-compatible API — and use its answer, entirely on the model's own initiative (ask, or just imply it in natural language: "see what ChatGPT thinks", "have GPT draw this"). Set up with `WARDEN_DELEGATES=<name>,<name>,...` plus, per name, `WARDEN_DELEGATE_<NAME>_KIND` (`anthropic` or `openai_compat`, default `openai_compat`), `_BASE_URL`, `_API_KEY`, `_MODEL`, and optionally `_IMAGE_MODEL`/`_DESCRIPTION` — see "LLM delegation" below for the full env var reference. The model may rewrite or expand the prompt it sends for a better result; the delegate never sees the rest of the conversation unless that's included in the prompt. Text tasks go through `ask_delegate` (works with any configured delegate); image generation goes through `delegate_generate_image`, which calls an OpenAI-compatible `/images/generations` endpoint directly and sends the result into the chat as a photo — this is how Warden can have ChatGPT/DALL-E draw something despite having no image-generation model of its own. Delegating a coding/analysis task this way gets you the delegate's *answer* (text, code, a plan) relayed back into chat — it does not give any delegate model actual access to run code or act against a real project; that's a deliberately separate, much bigger feature this doesn't attempt

# Talking to the bot
Nobody but the owner (and any bot admins — see "Access control" below) can
make the bot do *anything* by default: every message from anyone else is
silently ignored unless their user id or their whole chat has been
explicitly allowed via `/adduser`/`/allowchat`. Once allowed, the bot's
free-form LLM Q&A is still owner/bot-admin-only by default (toggle with
`WARDEN_LLM_OWNER_ONLY`) — an allowed regular user spends one "credit" per
question instead (see "Access control"). Every other command (stats, word
cloud, digests, dictionaries, weather, etc.) works for anyone allowed;
group-management commands (`/mute`, `/kick`, `/ban`, ...) work for that
chat's Telegram admins too, not just the owner (see "Group management"
below).

Within that owner-only Q&A, warden still only jumps in when actually
addressed — mentioning it (`@your_bot_username ...`), replying to one of
its messages, or saying the chat's magic word:

```
/magicword            show the current magic word
/magicword hassan     set it (bot owner only)
/magicword off        disable it (bot owner only)
```

In a private (1:1) chat with the owner, the bot answers everything — no
trigger needed.

# Group management
`/mute`, `/unmute`, `/pin`, `/unpin`, `/delete`, `/kick`, `/ban`,
`/confirm`, `/cancel`, and `/redact` are gated, in order: the bot owner;
a bot admin who prefixed the command with `/sudo` (e.g. `/sudo kick`,
which also announces the override in-chat); that specific chat's current
Telegram admins/creator — checked live via Telegram's `getChatMember` on
every use, not cached; and finally (`/redact` excluded) anyone holding a
token for this chat, which gets spent on use. Falling through every tier
is silently ignored, except running out of tokens, which gets a reply
saying so. `/promote`/`/demote` (granting real Telegram admin) and
`/scraper` stay owner-only, not extended to bot admins or `/sudo`.

`/kick` and `/ban` take their target the same three ways every other
targeted command does: reply to the person's message, pass `@username`, or
pass their raw platform user id directly (`/kick 123456789`) — useful when
they have no username, or you already have their id from `/whois` or a
previous log line. A username/id the bot has never seen still resolves for
`/kick`/`/ban` (unlike `/whois`, below): its whole point is acting on a
platform-native id, which is always enough on its own.

`/redact <N>` (the plain, no-reply-no-filter form) doesn't consult the
bot's own message log on Telegram — it walks backward by id from the
`/redact` command's own message (Telegram's `message_id` is a contiguous
per-chat counter), best-effort deleting each one whether or not the bot
ever saw it. That's what lets it clean up another bot's messages, or ones
sent before this bot joined/was online — the local DB was never going to
have those. `/redact [N]` as a reply to someone, `/redact text <substring>`,
and `/redact regex <pattern>` still search the local log, since those need
to look at message *content* to know what to delete.

# Member ACL
Three more per-chat, per-member controls, gated the same way as `/mute`/
`/kick`/etc above:

- **Slow mode** (`/slowmode <seconds>`, `/slowmode off`) — Telegram's Bot
  API has no method exposing a chat's native slow-mode delay to bots (it's
  client-UI-only), so this is warden's own logic instead, applied the same
  way on Telegram and Matrix: a message from a non-admin sent before the
  configured number of seconds have passed since their last one is
  deleted right away — the deletion itself is the feedback, no extra
  "you're rate limited" reply. Admins and the owner are always exempt,
  including from a slow mode they just set. Not enforced on XMPP (its
  connector has no moderation vtable slots at all).
- **Permission model** (`/permission [<duration>] <+|-><letters> @user`,
  or reply to their message instead of `@user`) — a 14-bit per-member
  permission mask: `r`ead, `w`rite (send messages), `p`hotos, `v`ideos,
  `f`ile, `m`usic, voice (`o`), video messages (`d`), `s`tickers/GIFs,
  pol`l`s, `e`mbed links, re`a`ctions, edit-own-`t`ag, change-`i`nfo.
  `/permission +rwpvfmodslaeti @user` grants everything, `/permission -w
  @user` mutes them. An optional leading `<duration>` (same grammar as
  `/remind`: `<n>m`/`<n>h`/`<n>d` — no week/month shorthand, since `m`
  already means minutes here) makes the change temporary; it reverts to
  full permissions automatically once it lapses (checked on the same
  ~30s scheduler tick as reminders/alerts). **Enforcement is partial by
  design** — Telegram's `restrictChatMember` has a real field for every
  letter except `r`/`a`/`t` (no Bot API concept of "can't read", "can't
  react", or "can't edit your own tag" exists), so those three are stored
  for cross-platform intent but never actually restrict anything on
  Telegram. Matrix has no granular permission object at all; only `w` is
  best-effort mapped onto the same power-level mechanism `/mute` uses,
  everything else is stored-but-unenforced. Nothing is enforced on XMPP.
  `/permission` with no arguments prints the full letter legend and this
  same enforcement caveat.
- **Custom tags** (`/tag @user <text>`, `/tag @user off`, or reply) —
  Telegram's `setChatAdministratorCustomTitle`, which the Bot API only
  allows on chat *administrators*; running it on an ordinary member
  returns a clear "must already be an admin" error rather than silently
  doing nothing. No equivalent primitive exists on Matrix or XMPP.

# Access control
Two independent trust tiers, both DB-backed (not just `.env`, unlike the
single owner):
- **Allowed users/chats** (`/adduser`, `/removeuser`, `/allowchat`,
  `/disallowchat`, owner or bot admin only) — whether the bot responds to a
  given person or chat at all. Nobody is allowed by default except the
  owner.
- **Bot admins** (`/addadmin`, `/removeadmin`, owner only) — trusted
  bot-wide, not scoped to one chat, unlike a platform's own admin flag.
  Bypass the allowed-users gate automatically, can run `/token`/`/adduser`/
  etc. directly, and can override a group-management command's live
  platform-admin check with `/sudo` (see "Group management" above). The
  owner is *always* treated as a bot admin too, everywhere one is checked —
  the owner outranks a bot admin, so there's no reason to also require the
  owner to `/addadmin` themselves before something bot-admin-gated (like
  `/sudo`) recognizes them.

`/adduser`/`/removeuser`/`/addadmin`/`/removeadmin` accept a reply,
`@username`, or a raw user id, same as `/kick`/`/ban` above.

`/whois` (owner/bot admin only) looks up a known identity by reply,
`@username`, or user id, and reports its full name, username, platform id,
and three flags: is it a bot account, is it a bot admin, and is it the
superuser (true only for the owner). Unlike `/kick`/`/ban`/`/adduser`, a
user id `/whois` has never seen gets "I don't have any record of that
user" rather than treating the bare id as enough — it's a read-only lookup,
not an action, so there's nothing to act on for someone the bot has never
actually observed.

Two currencies, both reply-to-a-message or `/command [balance] [@username]`:
- **Tokens** (`/token`, per-chat) — let a non-admin run one `/kick`/`/ban`
  per token spent, without being an admin. Grantable by that chat's own
  Telegram admins or any bot admin.
- **Credits** (`/credit`, bot-wide) — let an allowed user talk to the LLM
  at all when `WARDEN_LLM_OWNER_ONLY` is on; one credit is spent per
  question. Grantable by bot admins/owner only, since it spends real LLM
  API cost.

# Interactive prompts (buttons / reactions)
Some flows — right now, the interactive `/convert` — ask you to pick one of
several options instead of typing a command. On Telegram this is a real
inline keyboard: tap a button and you're done. Matrix has no button
concept, so the bot instead posts the options as text and reacts to its own
message with each choice's emoji, seeding tappable "pills" — react with the
same emoji as your pick and the bot detects it the same way it would a
button press.

`/convert` alone (no attachment, no format) starts the flow: send the file
you want converted, then pick a target format from the buttons/reactions
the bot offers — every valid format for that file type, not a curated
subset. `/cancel` backs out of a pending conversion (checked before, and
independently of, the existing admin-only ban/kick `/cancel`, so anyone can
cancel their own in-progress conversion). A pending conversion expires
after `WARDEN_CONVERT_TIMEOUT_SECONDS` (default 5 minutes) if left
untouched. The existing one-shot `/convert <format>`-as-caption command
keeps working exactly as before — this is additive, not a replacement.

# Menu
`/menu` (or `!menu` on Matrix — `!command` is rewritten to `/command` for
every command on every platform, not just this one) opens a navigable
button menu covering every module: Alerts, Reminders, Watches, Statistics,
Convert, Group Administration, Settings (Global/This chat/Personal), and
Help. It's a thin front end over the exact same commands and permission
checks described elsewhere in this file — a button never does anything its
slash-command equivalent couldn't already do, and kick/ban fired through
the menu are exactly as immediate as typing `/kick`/`/ban` (no extra
confirmation step).

Only the person who opened a menu can drive its buttons — someone else
tapping the same message gets a "this menu isn't yours" reply on Telegram
(silently ignored on Matrix, which has no per-press alert channel). A
"Back"/"Close" pair is always available; `/cancel` also clears an open
menu prompt, same tier as clearing a pending `/convert`/ban-kick
confirmation. A menu session (including one waiting on a follow-up reply)
expires after `WARDEN_MENU_TIMEOUT_SECONDS` (default 3 minutes) if left
untouched.

Some actions need a target the button press itself can't carry — tapping
e.g. Group Administration → Kick prompts "reply to the message of the
person you want to kick, or send their @username or user id," and your
next message (reply, `@username`, or raw id all work) completes it. Alerts
and Watches' "view" screens list this chat's actual pending items live,
each tappable to cancel/unwatch; *creating* a new one stays a typed
command (or natural language), since those take several independent
parameters a button flow doesn't meaningfully simplify.

Reminders' "New reminder" is the one exception — it's a real multi-step
wizard, not a "go type the command" placeholder. Each step (date, then
hour, then minute in 5s, then second) shows `[◀ -] [value] [+ ▶]` plus
`[⬅ Previous] [Next ➡]`; the last step hands off to a plain text prompt for
the message, then a final confirm screen with `[✅ Create]`/`[✖ Discard]`.
At any stepper step you can skip the buttons entirely and just reply with
a time (`13:37`) or date (`5/22/26`) to jump straight there. Reminders'
"View / cancel" screen shows each pending reminder's time in *its own
setter's* timezone/format, not the viewer's.

Settings → Personal holds your own timezone (a fixed UTC offset, not a
real DST-aware zone — good enough for a personal bot, see `/remind`'s own
doc comment) and date/time formatting. It defaults to a rough guess from
your Telegram `language_code` (the only locale hint Telegram's API exposes
— there's no real location/timezone field to key off), and is always
overridable by sending e.g. `+3:30`, `-5`, or `+0`.

Telegram edits one message in place as you navigate. Matrix (no
`editMessageReplyMarkup`-equivalent primitive) sends a fresh message per
navigation step instead, using the same reaction mechanism as `/convert`'s
prompts — functional, but stale reactions from earlier screens aren't
cleaned up yet; a persistent Telegram reply-keyboard mirroring the top-level
modules is also planned but not built yet (see `ROADMAP.md`). XMPP has no
button/reaction concept at all, so `/menu` there just renders as a plain
text overview.

# Site scraping
The `scrape_site` tool reads a page's clean, readable text — title and body
with tags/scripts/nav stripped — rather than raw HTML, and can follow a few
same-site links breadth-first (`max_pages`, 1-5) to pull in linked pages too.
It's separate from `fetch_url`, which returns markup as-is.

By default it extracts on-device with no external dependency. The bot owner
can instead delegate to an external scraping service (useful for
JS-rendered or bot-walled sites a plain HTTP fetch can't handle) — any
service that accepts a `{"url", "max_pages"}` JSON POST and returns text
works, e.g. a self-hosted headless-browser/katana-based crawler, Firecrawl,
ScrapingBee, etc.:

```
/scraper                        show the current mode/endpoint (owner only)
/scraper url <endpoint>         set the remote scraper endpoint
/scraper apikey <key>           set the API key sent as "Authorization: Bearer <key>"
/scraper apikey off             clear the API key
/scraper mode remote            switch to the configured remote endpoint
/scraper mode local             switch back to on-device extraction (default)
```

This whole command is owner-only, unlike `/magicword` — the configuration
can include an API key, so even viewing it is gated.

# Matrix
Warden can also connect to a Matrix homeserver (matrix.org or self-hosted),
alongside Telegram — both run at once when both are configured. Every
feature works the same way as on Telegram (Q&A, group management, reminders,
digests, file conversion, ...); see the env vars above to set it up.

Authentication is a pre-provisioned access token (`WARDEN_MATRIX_ACCESS_TOKEN`)
rather than a stored username/password — generate one from your client's
account settings, or via `curl`:
```bash
curl -XPOST https://matrix.org/_matrix/client/v3/login -d '{
  "type": "m.login.password",
  "identifier": {"type": "m.id.user", "user": "your_bot_account"},
  "password": "..."
}'
```
The bot auto-joins any room it's invited to — there's no separate "add to
group" step.

**Encryption**: end-to-end encrypted rooms (Olm/Megolm, via the audited
`libolm` library — no reimplemented crypto) are supported when
`WARDEN_MATRIX_PICKLE_KEY` is set; unset, the bot only sends/receives
plaintext, and inviting it into an encrypted room won't error but it won't
be able to read or send anything meaningful there either. Known gap:
**no device verification / cross-signing** — the bot's device will show
up as "not verified by its owner" in clients that surface that, since
there's no interactive (SAS/emoji) verification flow implemented. This
doesn't block sending or receiving; it's a trust-indicator warning only.
The bot proactively shares room keys on send and also answers
`m.room_key_request` (e.g. from a client that ran `/discardsession`) as a
self-healing fallback, since to-device delivery is best-effort, not
guaranteed.

Two smaller simplifications versus Telegram, both worth knowing about:
- Every Matrix room is treated as a "group" for the purposes of the
  mention/reply/magic-word gating described above — a Matrix DM doesn't yet
  get Telegram DMs' "answer everything, no trigger needed" treatment, since
  telling a real 1:1 room apart from a small group needs an extra lookup
  this doesn't do yet. Mention the bot or use the magic word even in a
  Matrix DM.
- Mute/unmute work via room power levels rather than a dedicated
  "restricted" state, and have no expiry — `/mute` normally auto-expires
  after an hour on Telegram, but on Matrix it lasts until explicitly
  `/unmute`d. `/permission`'s granular bitmask (see "Member ACL" above)
  is the same story on Matrix: only the `w` bit is mapped, onto that same
  power-level mechanism; everything else in the bitmask is stored but not
  live-enforced there. `/tag` has no Matrix equivalent at all.

# XMPP
Warden can also connect to an XMPP server (self-hosted Prosody/ejabberd),
alongside Telegram and Matrix. Q&A, group management (for MUC rooms), and
every other connector-agnostic feature work the same way; see the env vars
above to set it up.

Authenticate with a JID + password (`WARDEN_XMPP_JID`/`WARDEN_XMPP_PASSWORD`)
— the account needs to already exist on the server (e.g.
`prosodyctl adduser bot@yourserver`). `WARDEN_XMPP_SERVER` is only needed if
the socket you dial differs from the JID's own domain (e.g. a Docker Compose
service name).

This connector is an MVP, built and tested in one evening against a
self-hosted Prosody instance — several things a more mature XMPP client
would have are deliberately out of scope for now:
- **SASL PLAIN only, no SCRAM.** This makes the connector suitable for a
  self-hosted server you control and trust, but unsuitable against a public/
  federated server, which will almost always refuse PLAIN. TLS is still
  required (STARTTLS) so the password isn't sent in the clear, but there's
  no certificate-authority verification of the server's certificate either
  (`.no_verification` — see `xmpp/client.zig`), so this is not a hardened
  setup for use over an untrusted network.
- **No end-to-end encryption (OMEMO).** Same reasoning/precedent as Matrix's
  Olm/Megolm: a real cryptographic protocol worth doing properly or not at
  all, not attempted here.
- **No file transfer.** XMPP's mechanisms for this (XEP-0363 HTTP Upload,
  Jingle) are a separate system from a `<message>`'s `<body>`, unlike
  Matrix's `m.image`/`m.file` msgtypes — not implemented tonight.
- **Group chat (MUC, XEP-0045) has no admin features.** The bot can join
  rooms (via `WARDEN_XMPP_MUC_ROOMS`) and send/receive `groupchat` messages,
  but there's no kick/ban/affiliation support — every moderation vtable slot
  reports "unsupported" for XMPP, same as the pre-built-out Matrix/XMPP
  stubs used to before either connector was real. That includes `/slowmode`
  (stored per-chat but never enforced, since there's no `deleteMessage` to
  act on), `/permission` (the bitmask still saves, nothing is ever
  restricted live), and `/tag` (no custom-title primitive at all).
- **No roster UI.** Any incoming presence-subscription request is
  auto-accepted (mirrors Matrix's auto-join-on-invite) — there's no way to
  see or manage a roster from within the bot.
- **No mention detection in group chat.** Unlike Telegram/Matrix, an XMPP
  MUC message doesn't get scanned for an @mention of the bot yet — it'll
  only respond to the configured magic word in a room.

For local development, `compose.yaml` includes an opt-in `prosody` service
(same not-started-by-a-plain-`up`-shape as `llama-server`/`whisper-server`)
— bring it up with `docker compose up -d prosody warden searxng`, then
create a test account (`docker compose exec prosody prosodyctl adduser
bot@localhost`) before pointing `WARDEN_XMPP_JID`/`WARDEN_XMPP_PASSWORD` at
it. See `prosody/config/prosody.cfg.lua`'s comments for why this config is
test-only (self-signed TLS, `internal_plain` auth storage).

Supported Messaging Platforms:
- Telegram
- Matrix (plaintext rooms only — see "Matrix" below)
- XMPP (MVP — see "XMPP" below)
- WhatsApp (comming soon)

Supported AI Providers:
- Anthropic
- Anything OpenAI-compatible

# How to Get Started
To get started with Warden, first clone the repository and install the dependencies:

```bash
git clone https://github.com/warden.git
zig build
```

Next, set the following environment variables in your `.env` file (plain
shell syntax — the file gets sourced):
```bash
# Messaging platform (required — Telegram):
export WARDEN_TELEGRAM_BOT_TOKEN=<your_telegram_bot_token>
export WARDEN_TELEGRAM_OWNER_ID=<your_numeric_telegram_user_id>

# Personal account / TDLib (optional — see "Personal Account" above; unset
# means it stays disabled). Get api_id/api_hash from https://my.telegram.org.
# export WARDEN_TELEGRAM_USER_API_ID=<your api_id>
# export WARDEN_TELEGRAM_USER_API_HASH=<your api_hash>
# export WARDEN_TELEGRAM_USER_SESSION_DIR=/path/to/a/writable/directory
# export WARDEN_TELEGRAM_USER_OWNER_ID=<your numeric Telegram user id>

# Matrix (optional — see "Matrix" below; unset means Matrix stays disabled):
# export WARDEN_MATRIX_HOMESERVER_URL=https://matrix.org
# export WARDEN_MATRIX_ACCESS_TOKEN=<access token>
# export WARDEN_MATRIX_OWNER_ID=@you:matrix.org

# XMPP (optional — see "XMPP" below; unset means XMPP stays disabled):
# export WARDEN_XMPP_JID=bot@yourserver.example
# export WARDEN_XMPP_PASSWORD=<password>
# export WARDEN_XMPP_OWNER_ID=you@yourserver.example
# Only needed if the socket target differs from the JID's domain (e.g. a
# Docker Compose service name) — defaults to "<domain>:5222" otherwise:
# export WARDEN_XMPP_SERVER=prosody:5222
# Comma-separated bare room JIDs to auto-join on connect (optional):
# export WARDEN_XMPP_MUC_ROOMS=room1@conference.yourserver.example,room2@conference.yourserver.example

# LLM provider — anthropic (default) or openai_compat:
export WARDEN_LLM_PROVIDER=anthropic
export WARDEN_ANTHROPIC_API_KEY=<key>
export WARDEN_ANTHROPIC_MODEL=claude-sonnet-5
# ...or any OpenAI-compatible endpoint (ollama, llama.cpp, OpenRouter, etc.):
# export WARDEN_LLM_PROVIDER=openai_compat
# export WARDEN_OPENAI_BASE_URL=http://localhost:11434
# export WARDEN_OPENAI_API_KEY=<key, optional>
# export WARDEN_OPENAI_MODEL=llama3
# ...or the bundled self-hosted llama-server (see "Self-hosted local model"
# below) — same provider, just pointed at the compose service instead:
# export WARDEN_LLM_PROVIDER=openai_compat
# export WARDEN_OPENAI_BASE_URL=http://llama-server:8090/v1
# export WARDEN_OPENAI_MODEL=qwen3.5-4b

# LLM delegation (see "LLM Delegation" above) — comma-separated delegate
# names, then per name WARDEN_DELEGATE_<NAME>_*. Unset means the
# ask_delegate/delegate_generate_image tools never join the tool list.
# export WARDEN_DELEGATES=chatgpt
# export WARDEN_DELEGATE_CHATGPT_KIND=openai_compat
# export WARDEN_DELEGATE_CHATGPT_BASE_URL=https://api.openai.com/v1
# export WARDEN_DELEGATE_CHATGPT_API_KEY=<key>
# export WARDEN_DELEGATE_CHATGPT_MODEL=gpt-5
# Optional: only set this if the delegate should also be offered for image
# generation (calls {BASE_URL}/images/generations directly):
# export WARDEN_DELEGATE_CHATGPT_IMAGE_MODEL=gpt-image-1
# Optional, shown to the delegating model to help it pick a target:
# export WARDEN_DELEGATE_CHATGPT_DESCRIPTION=OpenAI's GPT-5 -- strong at code and reasoning, can generate images
# A second delegate, this time a second Claude persona (KIND defaults to
# openai_compat, so an anthropic-kind delegate must say so explicitly):
# export WARDEN_DELEGATES=chatgpt,claude2
# export WARDEN_DELEGATE_CLAUDE2_KIND=anthropic
# export WARDEN_DELEGATE_CLAUDE2_API_KEY=<key>
# export WARDEN_DELEGATE_CLAUDE2_MODEL=claude-opus-5

# Web search — base URL of a SearXNG instance with format=json enabled.
# Unset disables the web_search tool. (docker compose sets this
# automatically to its bundled searxng service.)
# export WARDEN_SEARXNG_URL=http://localhost:8080

# Voice transcription — base URL of a whisper.cpp whisper-server instance
# (see "Voice transcription" below). Unset means a voice message just gets
# the generic "a voice message arrived" placeholder, same as today.
# export WARDEN_WHISPER_URL=http://whisper-server:8091

# System prompt — override the built-in persona, either inline or (better)
# from a file you can properly edit. The file wins if both are set.
# export WARDEN_SYSTEM_PROMPT="You are Warden, ..."
# export WARDEN_SYSTEM_PROMPT_FILE=system_prompt.txt

# Database (required): a Postgres instance warden owns the schema of.
# Provision one yourself (a managed cloud instance, or your own
# self-hosted server) — compose.yaml does not bundle a Postgres service.
#
# The instance MUST have the pgvector extension available: migration
# 0025_memories.sql (Phase 12, long-term/semantic memory) runs
# `CREATE EXTENSION IF NOT EXISTS vector` and creates a `vector(1536)`
# column. `CREATE EXTENSION` can only enable an extension whose files are
# already installed on the server, so a stock image without pgvector —
# `postgres:16-alpine`, for instance — fails the migration and warden exits
# at startup. The official `pgvector/pgvector:pg16` image (or your
# platform's pgvector package) satisfies this.
#
# Adding pgvector to an instance that already holds data is not just an
# image swap: `pgvector/pgvector:*` is Debian/glibc while `*-alpine` is
# musl, and reusing a data directory across that change alters the
# collation provider, which can silently corrupt text btree index ordering.
# Migrate with pg_dump + restore into a fresh data directory (a logical
# restore rebuilds every index under the new collation), not by pointing
# the new image at the old PGDATA.
export WARDEN_POSTGRES_DSN=postgresql://user:password@host:5432/warden

# Optional knobs (defaults shown):
# export WARDEN_POSTGRES_POOL_SIZE=10
# export WARDEN_TMP_DIR=data/tmp
# export WARDEN_RETENTION_MESSAGES=20000
# export WARDEN_DIGEST_INTERVAL_SECONDS=86400
# export WARDEN_CONFIRM_TIMEOUT_SECONDS=60
# export WARDEN_CONVERT_TIMEOUT_SECONDS=300
# export WARDEN_MENU_TIMEOUT_SECONDS=180

# Storage Sense's watermark ladder (see "Storage Sense" above) — all
# live-overridable via /storage autopilot or the dynamic_config-backed
# admin API, these env vars are just the compiled-in starting point:
# export WARDEN_STORAGE_SENSE_LOW_WATERMARK_PCT=80
# export WARDEN_STORAGE_SENSE_HIGH_WATERMARK_PCT=90
# export WARDEN_STORAGE_SENSE_FLOOD_WATERMARK_PCT=95
# export WARDEN_STORAGE_SENSE_RESUME_MARGIN_PCT=3
# export WARDEN_STORAGE_SENSE_PRUNE_AGE_DAYS=180
# export WARDEN_STORAGE_SENSE_RESAMPLE_BATCH_SIZE=200
# Off until you've watched /storage status for a while and trust it:
# export WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED=false

# warden-ui's HTTP+WebSocket API (see /home/armin/claude/warden-ui) — off
# entirely by default (WARDEN_API_PORT unset) since it's still under
# active development. Setting WARDEN_API_PORT without
# WARDEN_API_SESSION_SECRET set refuses to start (fails loudly rather
# than signing sessions with no real key).
# export WARDEN_API_PORT=8081
# export WARDEN_API_WORKERS=4
# export WARDEN_API_SESSION_SECRET=some-long-random-value

# Logging: debug | info | notice | warn | error | fatal (default: info).
# Controls src/log.zig's runtime verbosity — every log line renders as
# fixed-width columns (timestamp, level, scope, message) to stderr, which
# `docker logs`/journald both capture. "debug" adds per-message and
# per-HTTP/Postgres-call timing, useful when actively chasing a hang;
# leave it at "info" (or "notice") for normal operation, since debug is
# fairly verbose under real traffic.
# export WARDEN_LOG_LEVEL=info
```

## Migrating from an older SQLite-based install
Versions before this one stored chat history in one SQLite file per chat
under `data/chats/`. If you're upgrading from one of those, run the one-time
migration tool once (with `WARDEN_POSTGRES_DSN` set, and `WARDEN_DATA_DIR`
pointed at your existing `data/chats` directory if it isn't in the default
location) before starting the new binary:

```bash
zig build migrate-data
```

This reads every `<chat_id>.db` file (plus the bot-wide `_global.db`) and
writes their messages, per-chat token balances, digest/magic-word settings,
and scraper config into Postgres, then it's done — nothing reads from the
old SQLite files afterward.

Once all is set up, run:
```bash
./zig-out/bin/warden
```

# Running with Docker
The image bundles the warden binary (built statically with Zig against musl),
the Node tool dependencies for the wordcloud and diagram features, and a
system Chromium for mermaid-cli. Node modules are installed inside the image
on purpose — `@napi-rs/canvas` ships a native binary per platform/libc, so
host `node_modules` would not work in the Alpine container.

Build it (from the repository root):

```bash
docker build --platform linux/amd64 -t warden:latest .
```

Then run it with compose. The `.env` file and the `data/` directory are
bind-mounted from the directory you run compose from:

```bash
docker compose up -d
```

Compose also starts a private SearXNG container (`searxng/` holds its
config) and points the bot at it via `WARDEN_SEARXNG_URL`, so web search
works out of the box. To use a custom system prompt in docker, add a bind
mount for the prompt file to the warden service and set
`WARDEN_SYSTEM_PROMPT_FILE` in your `.env`.

## Self-hosted local model
Compose can also run a small local LLM instead of paying for (or being
rate-limited by) a hosted API — a `llama-server` service running
[llama.cpp](https://github.com/ggml-org/llama.cpp)'s official CPU-first
inference server, currently sized for
[Qwen3.5-4B](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) (~2.7 GB at
`Q4_K_M`, chosen for real tool-calling support and solid multilingual —
including Persian — quality in a footprint an old CPU-only box can run
comfortably; ~2.1 GB resident once loaded).

1. Download the GGUF once, wherever you have a good connection — not
   necessarily the machine that'll run it:
   ```bash
   mkdir -p llama-server/models
   curl -L -o llama-server/models/Qwen3.5-4B-Q4_K_M.gguf \
     https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf
   ```
2. It's not started by a plain `docker compose up -d` (opt-in, unlike
   SearXNG) — bring it up explicitly, or point `WARDEN_OPENAI_BASE_URL` at
   it and let `docker compose up -d` start whatever your `.env` needs.
3. Point warden at it (see the `.env` example above):
   ```bash
   export WARDEN_LLM_PROVIDER=openai_compat
   export WARDEN_OPENAI_BASE_URL=http://llama-server:8090/v1
   export WARDEN_OPENAI_MODEL=qwen3.5-4b
   ```

Qwen3.5 defaults to an extended "thinking" trace before its real answer —
left as-is, a plain short question can burn its whole token budget on
reasoning and never produce a reply. `compose.yaml`'s `llama-server` command
already disables this (`--reasoning off`); if you swap in a different model,
check whether it needs the same treatment.

Swapping in a different model (a bigger one, if your hardware has room —
16 GiB of RAM comfortably fits something well past 4B) means changing the
GGUF filename in both the download command and `compose.yaml`'s
`--model`/`--alias` args, and `WARDEN_OPENAI_MODEL` in `.env` to match.

If you're on a machine that can't route bridge-network container traffic
properly (e.g. behind a Tailscale exit node with policy routing — this bit
the desktop this was developed on), see `compose.override.yaml`, which is
gitignored on purpose: it's a local networking workaround, not something to
ship anywhere else, including the router.

## Voice transcription
Compose can also run [whisper.cpp](https://github.com/ggml-org/whisper.cpp)'s
official server (`whisper-server`) to transcribe voice messages — same
opt-in-sidecar shape as the local LLM above, not started by a plain
`docker compose up -d`. A captionless voice message addressed to the bot
gets transcribed and answered for real, instead of the bot just noticing
"a voice message arrived."

1. Download the model once, wherever you have a good connection:
   ```bash
   mkdir -p whisper-server/models
   curl -L -o whisper-server/models/ggml-base.bin \
     https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
   ```
   `ggml-base.bin` (~148 MB) is the multilingual base model — picked over the
   `.en`-suffixed English-only variants since warden's other model choices
   already prioritize solid non-English (including Persian) quality. Bigger
   multilingual models (`ggml-small.bin` at ~466 MB, `ggml-medium.bin` at
   ~1.5 GB) trade more RAM/CPU for better accuracy if a captionless voice
   message's transcription quality matters enough to be worth it.
2. Bring it up explicitly (`docker compose up -d whisper-server warden
   searxng`), or just set `WARDEN_WHISPER_URL` in `.env` and let
   `docker compose up -d` start whatever it needs.
3. Point warden at it (see the `.env` example above):
   ```bash
   export WARDEN_WHISPER_URL=http://whisper-server:8091
   ```

Swapping in a different model means changing the filename in both the
download command and `compose.yaml`'s `whisper-server` `--model` arg.

## Deploying to a machine without a registry (e.g. an OpenWRT router)
Compose references the image by name (`warden:latest`). Docker always checks
the local image store first, so no registry is needed — export the image on
the build machine and import it on the target:

```bash
# On the build machine:
docker save warden:latest | gzip > warden.tar.gz
scp -r warden.tar.gz compose.yaml searxng root@router:/root/warden/
# If you're also shipping the local model (see "Self-hosted local model"),
# include it too — it's a ~2.7 GB transfer, so this one's slow on a flaky
# link; scp -C helps, or run it overnight:
scp -C -r llama-server root@router:/root/warden/

# On the router:
cd /root/warden
gunzip -c warden.tar.gz | docker load
# Put your .env next to compose.yaml, then:
docker compose up -d
```

The `build: .` key in `compose.yaml` is only consulted when the image is
missing, so on the router (where the source tree does not exist) compose
simply uses the loaded `warden:latest`.

Note: if the build machine's DNS points at a resolver that containers cannot
reach (systemd-resolved, Tailscale MagicDNS), build with
`docker build --network=host ...` and run test containers with
`--dns 1.1.1.1`.

# Questions or issues
You can ask questions or report issues in the issues section of this repository. I will try to respond as quickly as possible. Please note that this is a personal project and I may not always be able to respond immediately and support may be very limited.
