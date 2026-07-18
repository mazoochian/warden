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
- Reminders: `/remind 30m walk the dog` (or just ask in natural language) sets a one-off reminder; `/reminders` lists what's pending, `/remind cancel <id>` cancels one — restricted to whoever set it, or the bot owner
- File Conversion: send a photo, document, voice note, audio, or video with `/convert <format>` as its caption (or ask for it in natural language) to get it back in a different format — images (jpg/png/webp/gif/bmp/tiff), audio/video (mp3/wav/ogg/mp4/webm/...), and documents (txt/md/html/docx/odt/rtf/pdf) each convert within their own family; a PDF source can only become plain text
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

Supported Messaging Platforms:
- Telegram
- Matrix (comming soon)
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
# Messaging platform (required):
export WARDEN_TELEGRAM_BOT_TOKEN=<your_telegram_bot_token>
export WARDEN_TELEGRAM_OWNER_ID=<your_numeric_telegram_user_id>

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
