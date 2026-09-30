const std = @import("std");
const Platform = @import("platform/interface.zig").Platform;
const instagram_transport = @import("platform/instagram/transport.zig");

pub const OwnerEntry = struct {
    platform: Platform,
    /// Native user id for that platform, as a string (Telegram: decimal numeric
    /// id; Matrix would be "@user:server", etc.).
    owner_id: []const u8,
};

pub const LlmProviderKind = enum { anthropic, openai_compat };

pub const AnthropicConfig = struct {
    api_key: []const u8,
    model: []const u8,
};

pub const OpenAiCompatConfig = struct {
    base_url: []const u8,
    /// Empty if unset — most local runtimes don't require one.
    api_key: []const u8,
    model: []const u8,
};

/// Matrix connector config — both fields required together (see `load`'s
/// handling of `WARDEN_MATRIX_HOMESERVER_URL`/`WARDEN_MATRIX_ACCESS_TOKEN`).
pub const MatrixConfig = struct {
    /// No trailing slash (trimmed in `load`).
    homeserver_url: []const u8,
    access_token: []const u8,
};

/// How `platform/xmpp/client.zig`'s `startTls` verifies the server's
/// certificate — `WARDEN_XMPP_TLS_MODE` selects one, see `loadXmppConfig`.
pub const XmppTlsMode = enum {
    /// Default: the certificate must be well-formed and self-consistent.
    self_signed,
    /// Full verification against the system CA trust store (loaded via
    /// `std.crypto.Certificate.Bundle.rescan`) plus hostname match.
    bundle,
    /// No certificate verification at all.
    insecure,
};

/// XMPP connector config — `host`/`port` is the raw TCP target.
pub const XmppConfig = struct {
    host: []const u8,
    port: u16,
    domain: []const u8,
    jid_user: []const u8,
    password: []const u8,
    /// Bare room JIDs to auto-join on connect — MUC has no Telegram/ Matrix-
    /// equivalent "just works once added to a group" step.
    muc_rooms: []const []const u8,
    tls_mode: XmppTlsMode = .self_signed,
};

/// TDLib (personal-account) connector config — the owner's own Telegram
/// account, connected via MTProto rather than the Bot API.
pub const TelegramUserConfig = struct {
    api_id: i32,
    api_hash: []const u8,
    session_dir: []const u8,
};

/// Instagram (personal-account) connector config.
pub const InstagramConfig = struct {
    enabled: bool,
    /// Base interval between inbox poll cycles — deliberately much longer than a
    /// chat platform's long-poll (XMPP/Telegram effectively poll in seconds).
    poll_interval_ms: u32 = default_instagram_poll_interval_ms,
    /// Reverse-engineered protocol constants Instagram rotates without notice.
    rotating: instagram_transport.RotatingConstants = .{},
};

pub const default_instagram_poll_interval_ms: u32 = 45_000;

pub const LlmConfig = union(LlmProviderKind) {
    anthropic: AnthropicConfig,
    openai_compat: OpenAiCompatConfig,
};

pub const DelegateKind = enum { anthropic, openai_compat };

/// One "ask another model" target the
/// `ask_delegate`/`delegate_generate_image` tools.
pub const DelegateConfig = struct {
    /// Case-insensitively matched against the tool call's `delegate` argument —
    /// also what the model sees as the tool's target name.
    name: []const u8,
    kind: DelegateKind,
    /// Required for `openai_compat`; unused for `anthropic` (which always
    /// talks to Anthropic's own API, same as `AnthropicConfig`).
    base_url: []const u8 = "",
    /// Empty means no Authorization header is sent, same convention as
    /// `OpenAiCompatConfig.api_key`.
    api_key: []const u8 = "",
    model: []const u8,
    /// Set only when this delegate should also be offered for
    /// `delegate_generate_image`.
    image_model: ?[]const u8 = null,
    /// Shown to the delegating model alongside `name` so it can pick the right
    /// target for a given task, e.g. "OpenAI's GPT-4o.
    description: []const u8 = "",
};

/// Runtime configuration, loaded from environment variables.
pub const Config = struct {
    telegram_bot_token: []const u8,
    /// One entry per connected platform.
    owners: []const OwnerEntry,
    /// libpq connection string/URI for the shared Postgres database.
    postgres_dsn: []const u8,
    /// Size of the Postgres connection pool (see `store/pool.zig`).
    postgres_pool_size: usize,
    /// How long `PgPool.acquire` waits for a free connection before giving up
    /// with `error.PoolExhausted` instead of blocking forever.
    postgres_acquire_timeout_seconds: i64,
    /// Server-side `statement_timeout` set on every pooled connection right after
    /// connecting (see `store/db.zig`'s `Db.open`).
    postgres_statement_timeout_seconds: i64,
    /// Worker threads per platform connector that actually run
    /// `processMessageTask` (see `main.zig`'s `WorkerPool` usage).
    workers_per_platform: usize,
    /// Per-chat message retention: keep only the most recent N messages.
    retention_messages: i64,
    /// Whichever provider `WARDEN_LLM_PROVIDER` selected at startup.
    llm: LlmConfig,
    /// Both loaded independently, whichever credentials are present in env.
    llm_anthropic: ?AnthropicConfig = null,
    llm_openai_compat: ?OpenAiCompatConfig = null,
    /// Every configured "ask another model" target.
    delegates: []const DelegateConfig = &.{},
    /// How long a ban/kick confirmation stays valid before expiring.
    confirm_timeout_seconds: i64,
    /// How long a pending interactive /convert flow (waiting for a file upload,
    /// or waiting for a format pick) stays valid before expiring.
    convert_timeout_seconds: i64,
    /// How long an open `/menu` session.
    menu_timeout_seconds: i64,
    /// Scratch directory for shelling out to external renderers (word
    /// cloud/diagram scripts).
    tmp_dir: []const u8,
    /// How often an opted-in chat gets a digest (interval-based, not
    /// wall-clock time-of-day — see `features/scheduler.zig`).
    digest_interval_seconds: i64,
    /// How often an opted-in chat gets a proactive briefing.
    briefing_interval_seconds: i64,
    /// Overrides the built-in Q&A system prompt when set — either inline via
    /// WARDEN_SYSTEM_PROMPT or from a file via WARDEN_SYSTEM_PROMPT_FILE.
    system_prompt: ?[]const u8,
    /// Base URL of a SearXNG instance (e.g. "http://searxng:8080") for the
    /// web_search tool. Unset disables web search entirely.
    searxng_url: ?[]const u8,
    /// Base URL of a whisper.cpp `whisper-server` instance (e.g. "http://whisper-
    /// server:8091") for transcribing inbound voice messages.
    whisper_url: ?[]const u8,
    /// Base URL of an OpenAI-compatible embeddings endpoint (e.g.
    /// "https://api.openai.com/v1" or a self-hosted server implementing `POST
    /// {url}/embeddings`) for the long-term memory feature (`llm/embeddings.zig`.
    embeddings_url: ?[]const u8,
    /// Empty string means no Authorization header is sent, same
    /// convention `OpenAiCompatProvider.api_key` uses.
    embeddings_api_key: []const u8,
    /// The embedding model to request.
    embeddings_model: []const u8,
    /// Gates the bot's free-form LLM Q&A to the configured owner(s) only.
    llm_owner_only: bool,
    /// Whether a reasoning model's chain-of-thought is shown to the user.
    llm_show_thinking: bool,
    /// Whether `toolcall.run` uses `Provider.chatStream` (progressively edits the
    /// reply into the chat as the model generates it) instead of one blocking
    /// `Provider.chat` call.
    llm_streaming: bool,
    /// Whether `toolcall.run` attaches an image attachment's actual bytes to the
    /// model call.
    llm_vision_enabled: bool,
    /// Whether `toolcall.run` attaches a PDF attachment's actual bytes to the
    /// model call.
    llm_documents_enabled: bool,
    /// Overrides `qa.zig`'s `answerMaxTokens` (which sizes the budget off the
    /// active platform's message-length cap plus a reasoning-model thinking
    /// reserve) with a flat ceiling instead — for keeping a deployment's answers
    /// short and its token spend predictable regardless of platform limits.
    llm_max_tokens_override: ?u32 = null,
    /// How many recent chat messages `qa.zig` sends verbatim as context on every
    /// LLM call.
    llm_history_messages: i64 = default_llm_history_messages,
    /// How many times a failed model call is retried before the request gives up
    /// — see `llm/toolcall.zig`'s `callProviderWithRetry`.
    llm_max_retries: i64 = default_llm_max_retries,
    /// Whether a message that's addressed to the bot but is essentially just a
    /// greeting/acknowledgement/sign-off.
    skip_trivial_messages: bool = default_skip_trivial_messages,
    /// Null when Matrix isn't configured — `main.zig` only constructs a
    /// `MatrixConnector` (and adds it to the active connector list) when this is
    /// set.
    matrix: ?MatrixConfig = null,
    /// The local secret libolm's account/session pickles (see
    /// `src/platform/matrix/olm.zig`) are encrypted under before being persisted.
    matrix_pickle_key: ?[]const u8 = null,
    /// Null when XMPP isn't configured — `main.zig` only constructs an
    /// `XmppConnector` (and adds it to the active connector list) when this is
    /// set.
    xmpp: ?XmppConfig = null,
    /// Null when the personal-account (TDLib) connector isn't configured.
    telegram_user: ?TelegramUserConfig = null,
    /// Null when the Instagram personal-account connector isn't configured.
    instagram: ?InstagramConfig = null,
    /// Null (the default) means the warden-ui HTTP+WebSocket API (`src/api/`)
    /// stays entirely off.
    api_port: ?u16 = null,
    /// Worker threads servicing API requests — same `WorkerPool` shape as
    /// `workers_per_platform`.
    api_workers: usize = default_api_workers,
    /// HMAC-SHA256 signing key for session cookies (`src/api/auth.zig`) —
    /// required (load fails) if `api_port` is set.
    api_session_secret: ?[]const u8 = null,
    /// DANGER: lets anyone hit `POST /api/v1/auth/dev-login` and become any
    /// identity by id, no real login required.
    api_dev_login: bool = false,
    /// Ladder tunables for `features/storage_sense.zig`.
    storage_sense_low_watermark_pct: i64 = default_storage_sense_low_watermark_pct,
    storage_sense_high_watermark_pct: i64 = default_storage_sense_high_watermark_pct,
    storage_sense_flood_watermark_pct: i64 = default_storage_sense_flood_watermark_pct,
    storage_sense_resume_margin_pct: i64 = default_storage_sense_resume_margin_pct,
    storage_sense_prune_age_days: i64 = default_storage_sense_prune_age_days,
    storage_sense_resample_batch_size: i64 = default_storage_sense_resample_batch_size,
    /// Off by default -- gates the ladder's destructive actions (prune, resample,
    /// sleep mode).
    storage_sense_autopilot_enabled: bool = false,
    /// Backlog-triggered compaction (`storage_sense.tickBacklog`) -- routine,
    /// independent of disk pressure: a chat compacts once its non-summary
    /// message count exceeds `llm_history_messages * backlog_multiplier`.
    storage_sense_backlog_multiplier: i64 = default_storage_sense_backlog_multiplier,
    storage_sense_backlog_interval_seconds: i64 = default_storage_sense_backlog_interval_seconds,
    /// Unconfirmed ("mentioned once") facts older than this auto-retire --
    /// see `facts.autoRetireStaleTentative`.
    facts_tentative_max_age_days: i64 = default_facts_tentative_max_age_days,

    pub const LoadError = error{ MissingBotToken, MissingLlmConfig, MissingPostgresDsn, BadSystemPromptFile, ApiEnabledWithoutSessionSecret } || std.mem.Allocator.Error;

    /// `env` is expected to be `init.environ_map` from `std.process.Init`.
    pub fn load(env: *const std.process.Environ.Map, arena: std.mem.Allocator, io: std.Io) LoadError!Config {
        const telegram_bot_token = env.get("WARDEN_TELEGRAM_BOT_TOKEN") orelse return error.MissingBotToken;

        const telegram_owner_id = env.get("WARDEN_TELEGRAM_OWNER_ID") orelse default_telegram_owner_id;

        const matrix = loadMatrixConfig(env);
        const matrix_pickle_key = nonEmpty(env.get("WARDEN_MATRIX_PICKLE_KEY"));
        const xmpp = try loadXmppConfig(arena, env);
        const telegram_user = loadTelegramUserConfig(env);
        const instagram = loadInstagramConfig(env);

        var owners_buf: [5]OwnerEntry = undefined;
        var owners_len: usize = 0;
        owners_buf[owners_len] = .{ .platform = .telegram, .owner_id = telegram_owner_id };
        owners_len += 1;
        if (matrix != null) {
            if (env.get("WARDEN_MATRIX_OWNER_ID")) |matrix_owner_id| {
                owners_buf[owners_len] = .{ .platform = .matrix, .owner_id = matrix_owner_id };
                owners_len += 1;
            } else {
                std.log.warn("WARDEN_MATRIX_HOMESERVER_URL/WARDEN_MATRIX_ACCESS_TOKEN are set but WARDEN_MATRIX_OWNER_ID isn't — owner-gated Q&A will reject the Matrix owner until it's set", .{});
            }
        }
        if (xmpp != null) {
            if (env.get("WARDEN_XMPP_OWNER_ID")) |xmpp_owner_id| {
                owners_buf[owners_len] = .{ .platform = .xmpp, .owner_id = xmpp_owner_id };
                owners_len += 1;
            } else {
                std.log.warn("WARDEN_XMPP_JID/WARDEN_XMPP_PASSWORD are set but WARDEN_XMPP_OWNER_ID isn't — owner-gated Q&A will reject the XMPP owner until it's set", .{});
            }
        }
        if (telegram_user != null) {
            // Unlike Matrix/XMPP, this connector's account IS the owner by definition —
            // there's no other identity it could authenticate as.
            if (env.get("WARDEN_TELEGRAM_USER_OWNER_ID")) |user_owner_id| {
                owners_buf[owners_len] = .{ .platform = .telegram_user, .owner_id = user_owner_id };
                owners_len += 1;
            } else {
                std.log.warn("WARDEN_TELEGRAM_USER_API_ID/_API_HASH/_SESSION_DIR are set but WARDEN_TELEGRAM_USER_OWNER_ID isn't — owner-gated actions will reject the personal account until it's set to its own numeric Telegram user id", .{});
            }
        }
        if (instagram != null) {
            if (env.get("WARDEN_INSTAGRAM_OWNER_ID")) |ig_owner_id| {
                owners_buf[owners_len] = .{ .platform = .instagram, .owner_id = ig_owner_id };
                owners_len += 1;
            } else {
                std.log.warn("WARDEN_INSTAGRAM_ENABLED is set but WARDEN_INSTAGRAM_OWNER_ID isn't — owner-gated actions will reject the Instagram account until it's set to its own numeric Instagram user id (available via /iglogin status once logged in)", .{});
            }
        }
        const owners = try arena.dupe(OwnerEntry, owners_buf[0..owners_len]);

        const postgres_dsn = env.get("WARDEN_POSTGRES_DSN") orelse return error.MissingPostgresDsn;

        const postgres_pool_size: usize = if (env.get("WARDEN_POSTGRES_POOL_SIZE")) |raw|
            std.fmt.parseInt(usize, raw, 10) catch default_postgres_pool_size
        else
            default_postgres_pool_size;

        const postgres_acquire_timeout_seconds: i64 = if (env.get("WARDEN_POSTGRES_ACQUIRE_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_postgres_acquire_timeout_seconds
        else
            default_postgres_acquire_timeout_seconds;

        const postgres_statement_timeout_seconds: i64 = if (env.get("WARDEN_POSTGRES_STATEMENT_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_postgres_statement_timeout_seconds
        else
            default_postgres_statement_timeout_seconds;

        const workers_per_platform: usize = if (env.get("WARDEN_WORKERS_PER_PLATFORM")) |raw|
            std.fmt.parseInt(usize, raw, 10) catch defaultWorkersPerPlatform()
        else
            defaultWorkersPerPlatform();

        const retention_messages: i64 = if (env.get("WARDEN_RETENTION_MESSAGES")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_retention_messages
        else
            default_retention_messages;

        const llm_loaded = try loadLlmConfig(env);
        const delegates = try loadDelegateConfigs(env, arena);

        const confirm_timeout_seconds: i64 = if (env.get("WARDEN_CONFIRM_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_confirm_timeout_seconds
        else
            default_confirm_timeout_seconds;

        const convert_timeout_seconds: i64 = if (env.get("WARDEN_CONVERT_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_convert_timeout_seconds
        else
            default_convert_timeout_seconds;

        const menu_timeout_seconds: i64 = if (env.get("WARDEN_MENU_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_menu_timeout_seconds
        else
            default_menu_timeout_seconds;

        const tmp_dir = env.get("WARDEN_TMP_DIR") orelse "data/tmp";

        const digest_interval_seconds: i64 = if (env.get("WARDEN_DIGEST_INTERVAL_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_digest_interval_seconds
        else
            default_digest_interval_seconds;

        const briefing_interval_seconds: i64 = if (env.get("WARDEN_BRIEFING_INTERVAL_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_briefing_interval_seconds
        else
            default_briefing_interval_seconds;

        var system_prompt: ?[]const u8 = env.get("WARDEN_SYSTEM_PROMPT");
        if (env.get("WARDEN_SYSTEM_PROMPT_FILE")) |path| {
            // A configured-but-unreadable prompt file is a hard error: the operator
            // clearly wanted a specific persona.
            const contents = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_system_prompt_bytes)) catch |err| {
                std.log.err("could not read WARDEN_SYSTEM_PROMPT_FILE '{s}': {t}", .{ path, err });
                return error.BadSystemPromptFile;
            };
            system_prompt = std.mem.trim(u8, contents, " \t\r\n");
        }
        if (system_prompt) |p| {
            if (p.len == 0) system_prompt = null;
        }

        var searxng_url: ?[]const u8 = env.get("WARDEN_SEARXNG_URL");
        if (searxng_url) |u| {
            const trimmed = std.mem.trimEnd(u8, u, "/");
            searxng_url = if (trimmed.len == 0) null else trimmed;
        }

        var whisper_url: ?[]const u8 = env.get("WARDEN_WHISPER_URL");
        if (whisper_url) |u| {
            const trimmed = std.mem.trimEnd(u8, u, "/");
            whisper_url = if (trimmed.len == 0) null else trimmed;
        }

        var embeddings_url: ?[]const u8 = env.get("WARDEN_EMBEDDINGS_URL");
        if (embeddings_url) |u| {
            const trimmed = std.mem.trimEnd(u8, u, "/");
            embeddings_url = if (trimmed.len == 0) null else trimmed;
        }
        const embeddings_api_key = env.get("WARDEN_EMBEDDINGS_API_KEY") orelse "";
        const embeddings_model = env.get("WARDEN_EMBEDDINGS_MODEL") orelse "text-embedding-3-small";

        const llm_owner_only = parseBoolEnv(env, "WARDEN_LLM_OWNER_ONLY", default_llm_owner_only);
        const llm_show_thinking = parseBoolEnv(env, "WARDEN_LLM_SHOW_THINKING", default_llm_show_thinking);
        const llm_streaming = parseBoolEnv(env, "WARDEN_LLM_STREAMING", default_llm_streaming);
        const llm_vision_enabled = parseBoolEnv(env, "WARDEN_LLM_VISION", default_llm_vision_enabled);
        const llm_documents_enabled = parseBoolEnv(env, "WARDEN_LLM_DOCUMENTS", default_llm_documents_enabled);
        const llm_max_tokens_override: ?u32 = if (env.get("WARDEN_LLM_MAX_TOKENS")) |raw|
            std.fmt.parseInt(u32, raw, 10) catch null
        else
            null;
        const llm_history_messages: i64 = if (env.get("WARDEN_LLM_HISTORY_MESSAGES")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_llm_history_messages
        else
            default_llm_history_messages;
        const llm_max_retries: i64 = if (env.get("WARDEN_LLM_MAX_RETRIES")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_llm_max_retries
        else
            default_llm_max_retries;
        const skip_trivial_messages = parseBoolEnv(env, "WARDEN_LLM_SKIP_TRIVIAL_MESSAGES", default_skip_trivial_messages);

        const api_port: ?u16 = if (env.get("WARDEN_API_PORT")) |raw|
            std.fmt.parseInt(u16, raw, 10) catch null
        else
            null;
        const api_workers: usize = if (env.get("WARDEN_API_WORKERS")) |raw|
            std.fmt.parseInt(usize, raw, 10) catch default_api_workers
        else
            default_api_workers;
        const api_session_secret = nonEmpty(env.get("WARDEN_API_SESSION_SECRET"));
        if (api_port != null and api_session_secret == null) {
            std.log.err("WARDEN_API_PORT is set but WARDEN_API_SESSION_SECRET isn't — refusing to start an API server with no way to sign sessions", .{});
            return error.ApiEnabledWithoutSessionSecret;
        }
        const api_dev_login = parseBoolEnv(env, "WARDEN_API_DEV_LOGIN", false);
        if (api_dev_login) {
            std.log.warn("WARDEN_API_DEV_LOGIN is set — /api/v1/auth/dev-login lets anyone become any identity by id with no real login. NEVER set this outside a contributor's own machine.", .{});
        }

        const storage_sense_low_watermark_pct: i64 = if (env.get("WARDEN_STORAGE_SENSE_LOW_WATERMARK_PCT")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_low_watermark_pct
        else
            default_storage_sense_low_watermark_pct;
        const storage_sense_high_watermark_pct: i64 = if (env.get("WARDEN_STORAGE_SENSE_HIGH_WATERMARK_PCT")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_high_watermark_pct
        else
            default_storage_sense_high_watermark_pct;
        const storage_sense_flood_watermark_pct: i64 = if (env.get("WARDEN_STORAGE_SENSE_FLOOD_WATERMARK_PCT")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_flood_watermark_pct
        else
            default_storage_sense_flood_watermark_pct;
        const storage_sense_resume_margin_pct: i64 = if (env.get("WARDEN_STORAGE_SENSE_RESUME_MARGIN_PCT")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_resume_margin_pct
        else
            default_storage_sense_resume_margin_pct;
        const storage_sense_prune_age_days: i64 = if (env.get("WARDEN_STORAGE_SENSE_PRUNE_AGE_DAYS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_prune_age_days
        else
            default_storage_sense_prune_age_days;
        const storage_sense_resample_batch_size: i64 = if (env.get("WARDEN_STORAGE_SENSE_RESAMPLE_BATCH_SIZE")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_resample_batch_size
        else
            default_storage_sense_resample_batch_size;
        const storage_sense_autopilot_enabled = parseBoolEnv(env, "WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED", false);
        const storage_sense_backlog_multiplier: i64 = if (env.get("WARDEN_STORAGE_SENSE_BACKLOG_MULTIPLIER")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_backlog_multiplier
        else
            default_storage_sense_backlog_multiplier;
        const storage_sense_backlog_interval_seconds: i64 = if (env.get("WARDEN_STORAGE_SENSE_BACKLOG_INTERVAL_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_storage_sense_backlog_interval_seconds
        else
            default_storage_sense_backlog_interval_seconds;
        const facts_tentative_max_age_days: i64 = if (env.get("WARDEN_FACTS_TENTATIVE_MAX_AGE_DAYS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_facts_tentative_max_age_days
        else
            default_facts_tentative_max_age_days;

        return .{
            .telegram_bot_token = telegram_bot_token,
            .owners = owners,
            .postgres_dsn = postgres_dsn,
            .postgres_pool_size = postgres_pool_size,
            .postgres_acquire_timeout_seconds = postgres_acquire_timeout_seconds,
            .postgres_statement_timeout_seconds = postgres_statement_timeout_seconds,
            .workers_per_platform = workers_per_platform,
            .retention_messages = retention_messages,
            .llm = llm_loaded.active,
            .llm_anthropic = llm_loaded.anthropic,
            .llm_openai_compat = llm_loaded.openai_compat,
            .delegates = delegates,
            .confirm_timeout_seconds = confirm_timeout_seconds,
            .convert_timeout_seconds = convert_timeout_seconds,
            .menu_timeout_seconds = menu_timeout_seconds,
            .tmp_dir = tmp_dir,
            .digest_interval_seconds = digest_interval_seconds,
            .briefing_interval_seconds = briefing_interval_seconds,
            .system_prompt = system_prompt,
            .searxng_url = searxng_url,
            .whisper_url = whisper_url,
            .embeddings_url = embeddings_url,
            .embeddings_api_key = embeddings_api_key,
            .embeddings_model = embeddings_model,
            .llm_owner_only = llm_owner_only,
            .llm_show_thinking = llm_show_thinking,
            .llm_streaming = llm_streaming,
            .llm_vision_enabled = llm_vision_enabled,
            .llm_documents_enabled = llm_documents_enabled,
            .llm_max_tokens_override = llm_max_tokens_override,
            .llm_history_messages = llm_history_messages,
            .llm_max_retries = llm_max_retries,
            .skip_trivial_messages = skip_trivial_messages,
            .matrix = matrix,
            .matrix_pickle_key = matrix_pickle_key,
            .xmpp = xmpp,
            .telegram_user = telegram_user,
            .instagram = instagram,
            .api_port = api_port,
            .api_workers = api_workers,
            .api_session_secret = api_session_secret,
            .api_dev_login = api_dev_login,
            .storage_sense_low_watermark_pct = storage_sense_low_watermark_pct,
            .storage_sense_high_watermark_pct = storage_sense_high_watermark_pct,
            .storage_sense_flood_watermark_pct = storage_sense_flood_watermark_pct,
            .storage_sense_resume_margin_pct = storage_sense_resume_margin_pct,
            .storage_sense_prune_age_days = storage_sense_prune_age_days,
            .storage_sense_resample_batch_size = storage_sense_resample_batch_size,
            .storage_sense_autopilot_enabled = storage_sense_autopilot_enabled,
            .storage_sense_backlog_multiplier = storage_sense_backlog_multiplier,
            .storage_sense_backlog_interval_seconds = storage_sense_backlog_interval_seconds,
            .facts_tentative_max_age_days = facts_tentative_max_age_days,
        };
    }

    /// Accepts "true"/"1" and "false"/"0" (case-insensitive for the word forms);
    /// anything else, including an unset var.
    fn parseBoolEnv(env: *const std.process.Environ.Map, key: []const u8, default: bool) bool {
        const raw = env.get(key) orelse return default;
        if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        return default;
    }

    /// Treats an empty string the same as an absent env var.
    fn nonEmpty(raw: ?[]const u8) ?[]const u8 {
        const v = raw orelse return null;
        return if (v.len == 0) null else v;
    }

    /// `null` when neither var is set.
    fn loadMatrixConfig(env: *const std.process.Environ.Map) ?MatrixConfig {
        // An env var set to an empty string (e.g. a placeholder left for a human to
        // fill in by hand) counts as unset.
        const homeserver_url = nonEmpty(env.get("WARDEN_MATRIX_HOMESERVER_URL"));
        const access_token = nonEmpty(env.get("WARDEN_MATRIX_ACCESS_TOKEN"));
        if (homeserver_url == null and access_token == null) return null;
        const hs = homeserver_url orelse {
            std.log.err("WARDEN_MATRIX_ACCESS_TOKEN is set but WARDEN_MATRIX_HOMESERVER_URL isn't — Matrix stays disabled", .{});
            return null;
        };
        const token = access_token orelse {
            std.log.err("WARDEN_MATRIX_HOMESERVER_URL is set but WARDEN_MATRIX_ACCESS_TOKEN isn't — Matrix stays disabled", .{});
            return null;
        };
        return .{ .homeserver_url = std.mem.trimEnd(u8, hs, "/"), .access_token = token };
    }

    /// `null` when neither `WARDEN_XMPP_JID` nor `WARDEN_XMPP_PASSWORD` is set;
    /// logs and also returns `null` when only one is (same half- configured-
    /// stays-disabled reasoning as `loadMatrixConfig`), or when `WARDEN_XMPP_JID`
    fn loadXmppConfig(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?XmppConfig {
        const jid = nonEmpty(env.get("WARDEN_XMPP_JID"));
        const password = nonEmpty(env.get("WARDEN_XMPP_PASSWORD"));
        if (jid == null and password == null) return null;
        const full_jid = jid orelse {
            std.log.err("WARDEN_XMPP_PASSWORD is set but WARDEN_XMPP_JID isn't — XMPP stays disabled", .{});
            return null;
        };
        const pw = password orelse {
            std.log.err("WARDEN_XMPP_JID is set but WARDEN_XMPP_PASSWORD isn't — XMPP stays disabled", .{});
            return null;
        };

        const at = std.mem.indexOfScalar(u8, full_jid, '@') orelse {
            std.log.err("WARDEN_XMPP_JID '{s}' isn't shaped like user@domain — XMPP stays disabled", .{full_jid});
            return null;
        };
        const jid_user = full_jid[0..at];
        const domain = full_jid[at + 1 ..];

        // Defaults to dialing `domain` directly on the standard client port.
        var host: []const u8 = domain;
        var port: u16 = default_xmpp_port;
        if (env.get("WARDEN_XMPP_SERVER")) |server| {
            if (std.mem.indexOfScalar(u8, server, ':')) |colon| {
                host = server[0..colon];
                port = std.fmt.parseInt(u16, server[colon + 1 ..], 10) catch default_xmpp_port;
            } else {
                host = server;
            }
        }

        var muc_rooms: std.ArrayList([]const u8) = .empty;
        if (env.get("WARDEN_XMPP_MUC_ROOMS")) |rooms_raw| {
            var it = std.mem.splitScalar(u8, rooms_raw, ',');
            while (it.next()) |room| {
                const trimmed = std.mem.trim(u8, room, " \t");
                if (trimmed.len > 0) try muc_rooms.append(arena, trimmed);
            }
        }

        var tls_mode: XmppTlsMode = .self_signed;
        if (env.get("WARDEN_XMPP_TLS_MODE")) |mode_raw| {
            tls_mode = std.meta.stringToEnum(XmppTlsMode, mode_raw) orelse blk: {
                std.log.warn("WARDEN_XMPP_TLS_MODE '{s}' isn't one of self_signed/bundle/insecure — defaulting to self_signed", .{mode_raw});
                break :blk .self_signed;
            };
        }

        return .{
            .host = host,
            .port = port,
            .domain = domain,
            .jid_user = jid_user,
            .password = pw,
            .muc_rooms = try muc_rooms.toOwnedSlice(arena),
            .tls_mode = tls_mode,
        };
    }

    /// `null` unless all three of `WARDEN_TELEGRAM_USER_API_ID`/
    /// `_API_HASH`/`_SESSION_DIR` are set (same half-configured-stays- disabled
    /// reasoning as `loadMatrixConfig`/`loadXmppConfig`, extended to three
    /// required fields instead of two — `session_dir` isn't optional-with-a-
    /// default since it holds session material equivalent to full account access;
    /// a silent default risks landing it somewhere unintended).
    fn loadTelegramUserConfig(env: *const std.process.Environ.Map) ?TelegramUserConfig {
        const api_id_raw = nonEmpty(env.get("WARDEN_TELEGRAM_USER_API_ID"));
        const api_hash = nonEmpty(env.get("WARDEN_TELEGRAM_USER_API_HASH"));
        const session_dir = nonEmpty(env.get("WARDEN_TELEGRAM_USER_SESSION_DIR"));
        if (api_id_raw == null and api_hash == null and session_dir == null) return null;

        const id_raw = api_id_raw orelse {
            std.log.err("WARDEN_TELEGRAM_USER_API_HASH/_SESSION_DIR are set but WARDEN_TELEGRAM_USER_API_ID isn't — the personal-account connector stays disabled", .{});
            return null;
        };
        const hash = api_hash orelse {
            std.log.err("WARDEN_TELEGRAM_USER_API_ID/_SESSION_DIR are set but WARDEN_TELEGRAM_USER_API_HASH isn't — the personal-account connector stays disabled", .{});
            return null;
        };
        const dir = session_dir orelse {
            std.log.err("WARDEN_TELEGRAM_USER_API_ID/_API_HASH are set but WARDEN_TELEGRAM_USER_SESSION_DIR isn't — the personal-account connector stays disabled", .{});
            return null;
        };
        const api_id = std.fmt.parseInt(i32, id_raw, 10) catch {
            std.log.err("WARDEN_TELEGRAM_USER_API_ID '{s}' isn't a valid integer — the personal-account connector stays disabled", .{id_raw});
            return null;
        };
        return .{ .api_id = api_id, .api_hash = hash, .session_dir = dir };
    }

    /// `null` unless `WARDEN_INSTAGRAM_ENABLED` is truthy.
    fn loadInstagramConfig(env: *const std.process.Environ.Map) ?InstagramConfig {
        if (!parseBoolEnv(env, "WARDEN_INSTAGRAM_ENABLED", false)) return null;

        const poll_interval_ms: u32 = if (env.get("WARDEN_INSTAGRAM_POLL_INTERVAL_MS")) |raw|
            std.fmt.parseInt(u32, raw, 10) catch default_instagram_poll_interval_ms
        else
            default_instagram_poll_interval_ms;

        var rotating: instagram_transport.RotatingConstants = .{};
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_SIG_KEY"))) |v| rotating.sig_key = v;
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_SIG_KEY_VERSION"))) |v| rotating.sig_key_version = v;
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_APP_ID"))) |v| rotating.ig_app_id = v;
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_CAPABILITIES"))) |v| rotating.ig_capabilities = v;
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_APP_VERSION"))) |v| rotating.app_version = v;
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_APP_VERSION_CODE"))) |v| rotating.app_version_code = v;
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_PASSWORD_KEY_ID"))) |v| rotating.password_encryption_key_id = v;
        if (nonEmpty(env.get("WARDEN_INSTAGRAM_PASSWORD_PUBKEY_DER_B64"))) |v| rotating.password_encryption_pubkey_der_b64 = v;

        return .{ .enabled = true, .poll_interval_ms = poll_interval_ms, .rotating = rotating };
    }

    /// Longest delegate `name` accepted.
    const max_delegate_name_len = 32;

    /// Loads every delegate named in `WARDEN_DELEGATES`.
    fn loadDelegateConfigs(env: *const std.process.Environ.Map, arena: std.mem.Allocator) ![]const DelegateConfig {
        const raw = env.get("WARDEN_DELEGATES") orelse return &.{};

        var list: std.ArrayList(DelegateConfig) = .empty;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |name_raw| {
            const name = std.mem.trim(u8, name_raw, " \t");
            if (name.len == 0) continue;
            if (name.len > max_delegate_name_len) {
                std.log.err("WARDEN_DELEGATES: delegate name '{s}' is longer than {d} bytes, skipping", .{ name, max_delegate_name_len });
                continue;
            }

            var upper_buf: [max_delegate_name_len]u8 = undefined;
            for (name, 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
            const upper = upper_buf[0..name.len];

            const kind_raw = env.get(try std.fmt.allocPrint(arena, "WARDEN_DELEGATE_{s}_KIND", .{upper})) orelse "openai_compat";
            const kind: DelegateKind = if (std.mem.eql(u8, kind_raw, "anthropic")) .anthropic else .openai_compat;

            const model = nonEmpty(env.get(try std.fmt.allocPrint(arena, "WARDEN_DELEGATE_{s}_MODEL", .{upper}))) orelse {
                std.log.err("WARDEN_DELEGATE_{s}_MODEL isn't set — delegate '{s}' stays disabled", .{ upper, name });
                continue;
            };
            const api_key = env.get(try std.fmt.allocPrint(arena, "WARDEN_DELEGATE_{s}_API_KEY", .{upper})) orelse "";

            const base_url_raw = env.get(try std.fmt.allocPrint(arena, "WARDEN_DELEGATE_{s}_BASE_URL", .{upper})) orelse "";
            const base_url = std.mem.trimEnd(u8, base_url_raw, "/");
            if (kind == .openai_compat and base_url.len == 0) {
                std.log.err("WARDEN_DELEGATE_{s}_BASE_URL isn't set — delegate '{s}' stays disabled", .{ upper, name });
                continue;
            }

            const image_model_raw = nonEmpty(env.get(try std.fmt.allocPrint(arena, "WARDEN_DELEGATE_{s}_IMAGE_MODEL", .{upper})));
            if (image_model_raw != null and kind == .anthropic) {
                std.log.warn("WARDEN_DELEGATE_{s}_IMAGE_MODEL is set but the delegate's kind is anthropic — Claude has no image-generation endpoint, ignoring it", .{upper});
            }
            const image_model = if (kind == .openai_compat) image_model_raw else null;

            const description = env.get(try std.fmt.allocPrint(arena, "WARDEN_DELEGATE_{s}_DESCRIPTION", .{upper})) orelse "";

            try list.append(arena, .{
                .name = name,
                .kind = kind,
                .base_url = base_url,
                .api_key = api_key,
                .model = model,
                .image_model = image_model,
                .description = description,
            });
        }
        return list.toOwnedSlice(arena);
    }

    const LoadedLlmConfig = struct {
        active: LlmConfig,
        anthropic: ?AnthropicConfig,
        openai_compat: ?OpenAiCompatConfig,
    };

    /// Loads *both* providers' credentials independently, whichever are present
    /// in env.
    fn loadLlmConfig(env: *const std.process.Environ.Map) LoadError!LoadedLlmConfig {
        const anthropic: ?AnthropicConfig = if (env.get("WARDEN_ANTHROPIC_API_KEY")) |api_key| .{
            .api_key = api_key,
            .model = env.get("WARDEN_ANTHROPIC_MODEL") orelse "claude-sonnet-5",
        } else null;

        const openai_compat: ?OpenAiCompatConfig = if (env.get("WARDEN_OPENAI_BASE_URL")) |base_url| .{
            .base_url = base_url,
            .api_key = env.get("WARDEN_OPENAI_API_KEY") orelse "",
            .model = env.get("WARDEN_OPENAI_MODEL") orelse "llama3",
        } else null;

        const provider_name = env.get("WARDEN_LLM_PROVIDER") orelse "anthropic";
        const active: LlmConfig = if (std.mem.eql(u8, provider_name, "openai_compat"))
            LlmConfig{ .openai_compat = openai_compat orelse return error.MissingLlmConfig }
        else
            LlmConfig{ .anthropic = anthropic orelse return error.MissingLlmConfig };

        return .{ .active = active, .anthropic = anthropic, .openai_compat = openai_compat };
    }

    pub const max_system_prompt_bytes = 64 * 1024;

    pub const default_retention_messages: i64 = 20_000;
    pub const default_postgres_pool_size: usize = 10;
    pub const default_postgres_acquire_timeout_seconds: i64 = 30;
    pub const default_postgres_statement_timeout_seconds: i64 = 30;

    /// Floor of 2 regardless of detected core count.
    fn defaultWorkersPerPlatform() usize {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        return @max(2, cpu_count);
    }
    pub const default_confirm_timeout_seconds: i64 = 60;
    pub const default_convert_timeout_seconds: i64 = 300;
    pub const default_menu_timeout_seconds: i64 = 180;
    /// Deliberately small and fixed (not CPU-scaled like
    /// `defaultWorkersPerPlatform`) — the API is new/low-traffic by design for
    /// now.
    pub const default_api_workers: usize = 4;
    pub const default_digest_interval_seconds: i64 = 86_400;
    pub const default_briefing_interval_seconds: i64 = 86_400;
    pub const default_llm_owner_only: bool = true;
    pub const default_llm_show_thinking: bool = false;
    pub const default_llm_streaming: bool = false;
    pub const default_llm_vision_enabled: bool = true;
    pub const default_llm_documents_enabled: bool = true;
    /// Unchanged from the hardcoded value `qa.zig` used before this was
    /// configurable.
    pub const default_llm_history_messages: i64 = 200;
    /// Retries per model call on a *transient* failure (see `llm/toolcall.zig`'s
    /// `isRetryable`).
    pub const default_llm_max_retries: i64 = 3;
    pub const default_skip_trivial_messages: bool = true;
    pub const default_xmpp_port: u16 = 5222;

    /// Armin's numeric Telegram user id, as a string. Deliberately not
    /// username-based, since usernames can change.
    pub const default_telegram_owner_id: []const u8 = "101573604";

    /// Elasticsearch-watermark-style thresholds for `storage_sense.zig`.
    pub const default_storage_sense_low_watermark_pct: i64 = 80;
    pub const default_storage_sense_high_watermark_pct: i64 = 90;
    pub const default_storage_sense_flood_watermark_pct: i64 = 95;
    pub const default_storage_sense_resume_margin_pct: i64 = 3;
    pub const default_storage_sense_prune_age_days: i64 = 180;
    pub const default_storage_sense_resample_batch_size: i64 = 200;
    pub const default_storage_sense_backlog_multiplier: i64 = 2;
    pub const default_storage_sense_backlog_interval_seconds: i64 = 3600;
    pub const default_facts_tentative_max_age_days: i64 = 30;
};
