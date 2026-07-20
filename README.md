# Warden - An assistant bot you don't entirely hate

Warden is a powerful AI-powered bot that can connect to various AI providers and social messaging platforms. Here is a list of the features it supports:
- Weather: Provides weather information for a given location
- Stats: Provides statistics about the group's conversations
- Word Cloud: Shows a word cloud of the most common words used in the group's conversations
- Group Management: Allows the bot to manage the group's conversations, including kicking and banning users. Restricted to the chat's own Telegram admins (or the bot owner) — checked live against Telegram on every use, not cached
- Web Search: Answers questions using a private SearXNG metasearch instance — no API keys or bot checks
- Air Quality: Current US AQI / PM2.5 / PM10 for any city (Open-Meteo)
- Crypto Prices: Live prices with 24h change (CoinGecko)
- QR Codes: Generates and sends QR code images into the chat
- Dictionaries: English definitions (dictionaryapi.dev) and slang (Urban Dictionary)
- Hacker News: Searches HN stories and discussions
- Site Scraping: Reads a page's clean text (not raw HTML), optionally crawling a few same-site links deep. Runs on-device by default; the owner can point it at an external scraping service instead
- Reminders: `/remind 30m walk the dog` (a relative duration, or a 24h clock time like `/remind 14:30 ...`; or just ask in natural language) sets a one-off reminder; `/remind every 1d stretch` sets a recurring one; `/reminders` lists what's pending (including each recurring one's interval), `/remind cancel <id>` cancels one — restricted to whoever set it, or the bot owner
- Alerts: `/alert crypto bitcoin above 70000`, `/alert weather Tehran above 35`, `/alert aqi Beijing above 150` (or just ask) set a standing watch, checked every few minutes in the background and delivered as a message once true — `/alerts` lists what's set, `/alert cancel <id>` cancels one, re-notifies only after a cooldown once already triggered — restricted to whoever set it, or the bot owner
- Feed Watching: `/watch <feed url>` watches an RSS/Atom feed and posts a short AI-written blurb here whenever something new shows up (checked every 15 minutes); `/watches` lists what's watched, `/unwatch <feed url>` removes one — open to anyone in the chat, like `/digest`
- Per-Chat Persona: `/persona <text>` overrides the bot's system prompt for just this chat — a sarcastic assistant in one group, a terse formal one in another — without redeploying; `/persona off` resets to the global default. Viewing the current persona is open to anyone; changing it is owner-only, like `/magicword`
- File Conversion: send a photo, document, voice note, audio, or video with `/convert <format>` as its caption (or ask for it in natural language) to get it back in a different format in one shot — images (jpg/png/webp/gif/bmp/tiff), audio/video (mp3/wav/ogg/mp4/webm/...), and documents (txt/md/html/docx/odt/rtf/pdf) each convert within their own family; a PDF source can only become plain text. Or say `/convert` alone (or just "I want to convert a file") and the bot walks you through it interactively — asks you to send the file, then shows every valid target format as tap-to-pick buttons (Telegram) or emoji reactions (Matrix); a "🔄 Converting…" placeholder shows while it works
- Voice Transcription: send a captionless voice message addressed to the bot and it transcribes it (via an optional self-hosted whisper.cpp instance) and answers the actual question, instead of just noticing "a voice message arrived" — a "🎙️ Transcribing…" placeholder shows while it works, morphing into "🤔 Thinking..." once the model takes over — see "Voice transcription" below to set it up
- Live Answers: Replies to your questions arrive as a threaded reply that updates in place — an animated "thinking" indicator while the model works, switching to "using <tool>…" while it calls a tool, then editing into the final answer. Each chat's messages are handled independently and concurrently, so one slow or stuck reply never blocks the rest of the bot

# Talking to the bot
The bot's free-form LLM Q&A (mentioning it, replying to it, saying the magic
word, or DMing it) only answers the bot owner — everyone else's mention,
reply, or magic word gets silently ignored rather than a "not allowed"
reply. Every other command (stats, word cloud, digests, dictionaries,
weather, etc.) still works for anyone; group-management commands
(`/mute`, `/kick`, `/ban`, ...) work for that chat's Telegram admins too,
not just the owner (see "Group management" below).

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
`/confirm`, and `/cancel` are gated to that specific chat's current
Telegram admins/creator, or the bot owner — checked live via Telegram's
`getChatMember` on every use (not cached, since admin status can change at
any moment). Anyone else's attempt is silently ignored, matching how owner-
only commands like `/token` and `/scraper` already behave.

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
  `/unmute`d.

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
  stubs used to before either connector was real.
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
export WARDEN_POSTGRES_DSN=postgresql://user:password@host:5432/warden

# Optional knobs (defaults shown):
# export WARDEN_POSTGRES_POOL_SIZE=10
# export WARDEN_TMP_DIR=data/tmp
# export WARDEN_RETENTION_MESSAGES=20000
# export WARDEN_DIGEST_INTERVAL_SECONDS=86400
# export WARDEN_CONFIRM_TIMEOUT_SECONDS=60
# export WARDEN_CONVERT_TIMEOUT_SECONDS=300
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
