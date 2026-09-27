# Configuration

Three layers, in increasing precedence for the keys they cover:

1. **Environment variables** (`src/config.zig`, `Config.load`). The only
   source for secrets, DSNs and anything needed before the database is up.
   `.env` is plain shell syntax and gets sourced by `run.sh` /
   `docker-entrypoint.sh`.
2. **Dynamic config** (`dynamic_config` table, `src/store/dynamic_config.zig`)
   — a whitelisted subset of tunables that warden-ui may edit live. A missing
   row means "use the env value"; a read failure falls back to the env value
   as well. Never secrets or tokens.
3. **Per-chat settings** (`chat_settings`) and **per-user settings**
   (`user_settings`) override the global default for one chat or one person
   (persona, thinking display, digest opt-in, timezone, ...).

Independently of those, **feature flags** (`feature_flags` table) switch
whole modules on and off bot-wide.

## Environment variables

The authoritative list, with defaults, is `src/config.zig` — every variable
is read in `Config.load` or a `loadXxxConfig` helper next to it. Grouped:

| Group | Variables |
|---|---|
| Telegram bot (required) | `WARDEN_TELEGRAM_BOT_TOKEN`, `WARDEN_TELEGRAM_OWNER_ID` |
| Postgres (required) | `WARDEN_POSTGRES_DSN`, `WARDEN_POSTGRES_POOL_SIZE`, `WARDEN_POSTGRES_ACQUIRE_TIMEOUT_SECONDS`, `WARDEN_POSTGRES_STATEMENT_TIMEOUT_SECONDS` |
| LLM provider | `WARDEN_LLM_PROVIDER` (`anthropic` default, or `openai_compat`), `WARDEN_ANTHROPIC_API_KEY`, `WARDEN_ANTHROPIC_MODEL`, `WARDEN_OPENAI_BASE_URL`, `WARDEN_OPENAI_API_KEY`, `WARDEN_OPENAI_MODEL` |
| LLM behaviour | `WARDEN_LLM_OWNER_ONLY` (default true), `WARDEN_LLM_SHOW_THINKING`, `WARDEN_LLM_STREAMING`, `WARDEN_LLM_VISION`, `WARDEN_LLM_DOCUMENTS`, `WARDEN_LLM_MAX_TOKENS` (0 = derive from platform limit), `WARDEN_LLM_REPLY_LENGTH` (`"<n> paragraphs\|words\|tokens"` or `off`; default `1 paragraph`), `WARDEN_LLM_MAX_RETRIES`, `WARDEN_LLM_HISTORY_MESSAGES`, `WARDEN_LLM_SKIP_TRIVIAL_MESSAGES`, `WARDEN_SYSTEM_PROMPT` / `WARDEN_SYSTEM_PROMPT_FILE` |
| Delegates | `WARDEN_DELEGATES=name1,name2` plus per name `WARDEN_DELEGATE_<NAME>_KIND` (`openai_compat` default / `anthropic`), `_MODEL`, `_API_KEY`, `_BASE_URL`, `_IMAGE_MODEL`, `_DESCRIPTION` |
| Memory / embeddings | `WARDEN_EMBEDDINGS_URL`, `WARDEN_EMBEDDINGS_API_KEY`, `WARDEN_EMBEDDINGS_MODEL` (memory works without an endpoint; ranking then uses keyword/recency/salience only) |
| Optional services | `WARDEN_SEARXNG_URL` (web search tool), `WARDEN_WHISPER_URL` (voice transcription) |
| Matrix | `WARDEN_MATRIX_HOMESERVER_URL`, `WARDEN_MATRIX_ACCESS_TOKEN`, `WARDEN_MATRIX_OWNER_ID`, `WARDEN_MATRIX_PICKLE_KEY` (enables E2EE) |
| XMPP | `WARDEN_XMPP_JID`, `WARDEN_XMPP_PASSWORD`, `WARDEN_XMPP_OWNER_ID`, `WARDEN_XMPP_SERVER`, `WARDEN_XMPP_TLS_MODE`, `WARDEN_XMPP_MUC_ROOMS` |
| Personal Telegram account | `WARDEN_TELEGRAM_USER_API_ID`, `WARDEN_TELEGRAM_USER_API_HASH`, `WARDEN_TELEGRAM_USER_OWNER_ID`, `WARDEN_TELEGRAM_USER_SESSION_DIR` |
| Instagram | `WARDEN_INSTAGRAM_ENABLED`, `WARDEN_INSTAGRAM_OWNER_ID`, `WARDEN_INSTAGRAM_APP_ID`, `_APP_VERSION`, `_APP_VERSION_CODE`, `_CAPABILITIES`, `_SIG_KEY`, `_SIG_KEY_VERSION`, `_PASSWORD_KEY_ID`, `_PASSWORD_PUBKEY_DER_B64`, `_POLL_INTERVAL_MS` |
| Timeouts / cadence | `WARDEN_CONFIRM_TIMEOUT_SECONDS`, `WARDEN_CONVERT_TIMEOUT_SECONDS`, `WARDEN_MENU_TIMEOUT_SECONDS`, `WARDEN_DIGEST_INTERVAL_SECONDS`, `WARDEN_BRIEFING_INTERVAL_SECONDS` |
| Capacity | `WARDEN_WORKERS_PER_PLATFORM` (default: CPU count, floor 2), `WARDEN_RETENTION_MESSAGES` (per chat) |
| Storage Sense | `WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED`, `_LOW_WATERMARK_PCT`, `_HIGH_WATERMARK_PCT`, `_FLOOD_WATERMARK_PCT`, `_RESUME_MARGIN_PCT`, `_PRUNE_AGE_DAYS`, `_RESAMPLE_BATCH_SIZE` |
| Web API | `WARDEN_API_PORT` (off when unset), `WARDEN_API_SESSION_SECRET`, `WARDEN_API_WORKERS`, `WARDEN_API_DEV_LOGIN` (dev machines only) |
| Misc | `WARDEN_TMP_DIR`, `WARDEN_LOG_LEVEL` (`debug`/`info`/`notice`/`warn`/`err`/`fatal`) |

Owner ids: one `owners` entry per configured platform (`Config.owners`).
`auth.isOwner` compares the platform-native user id only — never a
username or display name.

## Dynamic config

Keys currently editable at runtime (the admin config handlers in
`src/api/router.zig` enumerate them): `WARDEN_LLM_PROVIDER`, `WARDEN_LLM_OWNER_ONLY`,
`WARDEN_LLM_SHOW_THINKING`, `WARDEN_LLM_STREAMING`, `WARDEN_LLM_MAX_TOKENS`,
`WARDEN_LLM_REPLY_LENGTH`,
`WARDEN_LLM_MAX_RETRIES`, `WARDEN_LLM_HISTORY_MESSAGES`,
`WARDEN_LLM_SKIP_TRIVIAL_MESSAGES`, `WARDEN_DIGEST_INTERVAL_SECONDS`,
`WARDEN_BRIEFING_INTERVAL_SECONDS`, `WARDEN_RETENTION_MESSAGES`, and
`WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED`. Secrets appear in the admin config
view only as "set / not set".

The LLM settings are read once per Q&A turn in one bulk fetch
(`resolveLlmDynamicSettings`) to avoid six round trips per message.
`WARDEN_LLM_PROVIDER` is hot-swappable because both providers are
constructed at startup when both are configured; `llm/dynamic_provider.zig`
re-resolves the active one per call.

Storage Sense autopilot is deliberately a dynamic-config bool rather than a
feature flag: it must default *off*, and feature flags default on.

## Feature flags

`src/store/feature_flags.zig` — `known_modules` is the full list. A module
with no row is enabled; `isEnabled` fails *open* on a database error so a
DB hiccup never looks like every module being switched off. Two categories:

- **standalone** modules (reminders, alerts, watches, notes, convert,
  group_admin, persona, digest, briefings, voice_transcription, menu,
  messaging_modes, polls, keyword_alerts, welcome_messages, announcements,
  finance, power_tools, video_download, storage_sense_monitor,
  curated_feed) are checked with an early return in `handleMessage`'s
  dispatch. Convention: a disabled module blocks *creating or changing*
  things; the corresponding list/view commands keep working.
- **llm_tool** modules (weather, crypto_price, air_quality, qr_code,
  dictionary, urban_dictionary, hackernews, web_search, scrape_site) are
  removed from the tool list handed to the model (`filterEnabledTools`),
  which maps each tool name to its module key (`toolModuleKey`).

`storage_sense_monitor` gates only the periodic disk check and alerts; the
manual `/storage` command always works.

## Per-chat and per-user settings

`chat_settings` holds: persona (system-prompt override), magic word,
show-thinking override, digest/briefing opt-in, default location, welcome
message, autopin, silent-by-default, video download on/off and lossy/
lossless, reply autonomy + prompt, monitoring. `user_settings` holds a
personal UTC offset (a fixed offset, not an IANA zone — DST drift is an
accepted limitation), date and time format, seeded from Telegram's
`language_code` on first sight.
