# Warden - An assistant bot you don't entirely hate

Warden is a self-hosted, owner-only assistant bot written in Zig. It sits in
your Telegram, Matrix, and XMPP chats, answers questions through the LLM of
your choice, and handles the practical group chores. One binary, one
Postgres database, and a `.env` file.

# Features
- **LLM Q&A** — mention the bot, reply to it, or say the magic word; answers stream in place with live tool use (web search, page scraping, weather, prices, ...).
- **Access control** — the bot answers everyone by default, with the free-form LLM Q&A owner-only unless you open it up; the owner can block any user or chat, and a bot-admin role plus `/sudo` cover the rest.
- **Group moderation** — mute, kick, ban, redact, slow mode, welcome messages, and scheduled announcements, gated by the chat's live platform admins.
- **Management rooms** — moderate a chat from a private room with a full audit log and one-tap undo.
- **Reminders and alerts** — one-off or recurring reminders, plus standing crypto/weather/AQI watches, all in natural language.
- **Digests and feeds** — scheduled chat summaries, "catch me up", RSS watching, and an owner-curated news feed.
- **Media** — file conversion, YouTube/Instagram/X auto-download, and voice-message transcription.
- **Memory and persona** — per-user facts that follow you across chats, and a per-chat system prompt override.
- **Personal Telegram account** — the bot can ghostwrite replies into your own account's composer for approval.
- **Button menu** — `/menu` drives every module without remembering command syntax; `/help` lists them all.

# Documentation
`docs/` describes how Warden works — architecture, access control, the LLM
pipeline, platforms, features, storage, operations, testing, and the design
decisions behind them. Start at `docs/README.md`. `ROADMAP.md` is the
chronological development log.

# Platforms
- **Telegram** — the primary target; everything works here.
- **Matrix** — plaintext and end-to-end encrypted rooms, auto-joins on invite.
- **XMPP** — MUC moderation with SCRAM auth; no OMEMO or file transfer.

Supported AI providers: Anthropic, and anything OpenAI-compatible (Ollama,
llama.cpp, OpenRouter, ...).

# Getting started
```bash
git clone https://github.com/mazoochian/warden.git
cd warden
zig build
```

Create a `.env` (plain shell syntax — it gets sourced). The minimum is a
Telegram bot, an LLM provider, and a Postgres DSN:

```bash
# Telegram (required)
export WARDEN_TELEGRAM_BOT_TOKEN=<your_telegram_bot_token>
export WARDEN_TELEGRAM_OWNER_ID=<your_numeric_telegram_user_id>

# LLM provider — anthropic (default) or openai_compat
export WARDEN_LLM_PROVIDER=anthropic
export WARDEN_ANTHROPIC_API_KEY=<key>
export WARDEN_ANTHROPIC_MODEL=claude-sonnet-5
# ...or any OpenAI-compatible endpoint:
# export WARDEN_LLM_PROVIDER=openai_compat
# export WARDEN_OPENAI_BASE_URL=http://localhost:11434
# export WARDEN_OPENAI_API_KEY=<key, optional>
# export WARDEN_OPENAI_MODEL=llama3

# Postgres (required). The server needs the pgvector extension installed,
# e.g. the pgvector/pgvector:pg16 image.
export WARDEN_POSTGRES_DSN=postgresql://user:password@host:5432/warden

# Optional platforms
# export WARDEN_MATRIX_HOMESERVER_URL=https://matrix.org
# export WARDEN_MATRIX_ACCESS_TOKEN=<access token>
# export WARDEN_MATRIX_OWNER_ID=@you:matrix.org
# export WARDEN_MATRIX_PICKLE_KEY=<random secret>   # enables E2EE
# export WARDEN_XMPP_JID=bot@yourserver.example
# export WARDEN_XMPP_PASSWORD=<password>
# export WARDEN_XMPP_OWNER_ID=you@yourserver.example
```

Every other knob — optional integrations, timeouts, retention, logging —
is read in `src/config.zig` and listed in `docs/configuration.md`.

Then run:
```bash
./zig-out/bin/warden
```

# Running with Docker
```bash
docker build --platform linux/amd64 -t warden:latest .
docker compose up -d
```

`.env` and `data/` are bind-mounted from the directory you run compose
from. `compose.yaml` is the bot alone; optional sidecars (web search, a
local LLM, voice transcription, a dev XMPP server) live under
`examples/<name>/` as compose fragments you merge in explicitly, each with
its own README:

```bash
docker compose -f compose.yaml -f examples/searxng/compose.yaml up -d
```

# Questions or issues
Open an issue in this repository. This is a personal project, so support is
best-effort and replies may be slow.
