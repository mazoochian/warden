const std = @import("std");
const Platform = @import("platform/interface.zig").Platform;

pub const OwnerEntry = struct {
    platform: Platform,
    /// Native user id for that platform, as a string (Telegram: decimal
    /// numeric id; Matrix would be "@user:server", etc.). Compared as an
    /// exact string match — never a username, since those can change.
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
/// A pre-provisioned access token rather than username/password: same shape
/// as Telegram's bot token, avoids the bot ever holding a real password, and
/// sidesteps needing to implement the interactive `m.login.password` flow
/// (device management, refresh tokens) for what's meant to run unattended.
pub const MatrixConfig = struct {
    /// No trailing slash (trimmed in `load`).
    homeserver_url: []const u8,
    access_token: []const u8,
};

pub const LlmConfig = union(LlmProviderKind) {
    anthropic: AnthropicConfig,
    openai_compat: OpenAiCompatConfig,
};

/// Runtime configuration, loaded from environment variables.
///
/// Kept deliberately simple (env vars, not a config file) since the bot
/// currently only targets local/dev deployment.
pub const Config = struct {
    telegram_bot_token: []const u8,
    /// One entry per connected platform. Only `.telegram` is populated
    /// today; adding Matrix/Discord/WhatsApp later means adding another
    /// `OwnerEntry` here plus its own connector, not touching `auth.zig`.
    owners: []const OwnerEntry,
    /// libpq connection string/URI for the shared Postgres database.
    postgres_dsn: []const u8,
    /// Size of the Postgres connection pool (see `store/pool.zig`).
    postgres_pool_size: usize,
    /// Per-chat message retention: keep only the most recent N messages.
    retention_messages: i64,
    llm: LlmConfig,
    /// How long a ban/kick confirmation stays valid before expiring.
    confirm_timeout_seconds: i64,
    /// Scratch directory for shelling out to external renderers (word
    /// cloud/diagram scripts) — unrelated to the database, purely
    /// throwaway local scratch space.
    tmp_dir: []const u8,
    /// How often an opted-in chat gets a digest (interval-based, not
    /// wall-clock time-of-day — see `features/scheduler.zig`).
    digest_interval_seconds: i64,
    /// Overrides the built-in Q&A system prompt when set — either inline
    /// via WARDEN_SYSTEM_PROMPT or from a file via
    /// WARDEN_SYSTEM_PROMPT_FILE (the file wins if both are set, since a
    /// file is the "properly edited" variant).
    system_prompt: ?[]const u8,
    /// Base URL of a SearXNG instance (e.g. "http://searxng:8080") for the
    /// web_search tool. Unset disables web search entirely.
    searxng_url: ?[]const u8,
    /// Base URL of a whisper.cpp `whisper-server` instance (e.g.
    /// "http://whisper-server:8091") for transcribing inbound voice
    /// messages. Unset disables transcription entirely — a voice message
    /// then just gets `main.zig`'s generic attachment placeholder, same as
    /// today.
    whisper_url: ?[]const u8,
    /// Gates the bot's free-form LLM Q&A to the configured owner(s) only.
    /// Every other command keeps its own existing access control regardless
    /// of this setting. Meant to be flipped on before switching to an
    /// expensive model, off for an open assistant.
    llm_owner_only: bool,
    /// Whether a reasoning model's chain-of-thought is shown to the user.
    /// When false, `<think>`/`<thinking>` tags and any `reasoning_content`/
    /// `reasoning` field the OpenAI-compatible backend sends are filtered
    /// out before the reply is shown — see `llm/openai_compat.zig`.
    llm_show_thinking: bool,
    /// Null when Matrix isn't configured — `main.zig` only constructs a
    /// `MatrixConnector` (and adds it to the active connector list) when
    /// this is set.
    matrix: ?MatrixConfig = null,

    pub const LoadError = error{ MissingBotToken, MissingLlmConfig, MissingPostgresDsn, BadSystemPromptFile } || std.mem.Allocator.Error;

    /// `env` is expected to be `init.environ_map` from `std.process.Init`.
    /// `arena` should be long-lived (e.g. `init.arena.allocator()`) since
    /// the returned Config borrows from both `env` and `arena` for its
    /// lifetime. `io` is only used to read WARDEN_SYSTEM_PROMPT_FILE.
    pub fn load(env: *const std.process.Environ.Map, arena: std.mem.Allocator, io: std.Io) LoadError!Config {
        const telegram_bot_token = env.get("WARDEN_TELEGRAM_BOT_TOKEN") orelse return error.MissingBotToken;

        const telegram_owner_id = env.get("WARDEN_TELEGRAM_OWNER_ID") orelse default_telegram_owner_id;

        const matrix = loadMatrixConfig(env);

        var owners_buf: [2]OwnerEntry = undefined;
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
        const owners = try arena.dupe(OwnerEntry, owners_buf[0..owners_len]);

        const postgres_dsn = env.get("WARDEN_POSTGRES_DSN") orelse return error.MissingPostgresDsn;

        const postgres_pool_size: usize = if (env.get("WARDEN_POSTGRES_POOL_SIZE")) |raw|
            std.fmt.parseInt(usize, raw, 10) catch default_postgres_pool_size
        else
            default_postgres_pool_size;

        const retention_messages: i64 = if (env.get("WARDEN_RETENTION_MESSAGES")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_retention_messages
        else
            default_retention_messages;

        const llm = try loadLlmConfig(env);

        const confirm_timeout_seconds: i64 = if (env.get("WARDEN_CONFIRM_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_confirm_timeout_seconds
        else
            default_confirm_timeout_seconds;

        const tmp_dir = env.get("WARDEN_TMP_DIR") orelse "data/tmp";

        const digest_interval_seconds: i64 = if (env.get("WARDEN_DIGEST_INTERVAL_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_digest_interval_seconds
        else
            default_digest_interval_seconds;

        var system_prompt: ?[]const u8 = env.get("WARDEN_SYSTEM_PROMPT");
        if (env.get("WARDEN_SYSTEM_PROMPT_FILE")) |path| {
            // A configured-but-unreadable prompt file is a hard error: the
            // operator clearly wanted a specific persona, so silently
            // falling back to the default would be worse than not starting.
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

        const llm_owner_only = parseBoolEnv(env, "WARDEN_LLM_OWNER_ONLY", default_llm_owner_only);
        const llm_show_thinking = parseBoolEnv(env, "WARDEN_LLM_SHOW_THINKING", default_llm_show_thinking);

        return .{
            .telegram_bot_token = telegram_bot_token,
            .owners = owners,
            .postgres_dsn = postgres_dsn,
            .postgres_pool_size = postgres_pool_size,
            .retention_messages = retention_messages,
            .llm = llm,
            .confirm_timeout_seconds = confirm_timeout_seconds,
            .tmp_dir = tmp_dir,
            .digest_interval_seconds = digest_interval_seconds,
            .system_prompt = system_prompt,
            .searxng_url = searxng_url,
            .whisper_url = whisper_url,
            .llm_owner_only = llm_owner_only,
            .llm_show_thinking = llm_show_thinking,
            .matrix = matrix,
        };
    }

    /// Accepts "true"/"1" and "false"/"0" (case-insensitive for the word
    /// forms); anything else, including an unset var, falls back to
    /// `default` rather than failing config load over a typo.
    fn parseBoolEnv(env: *const std.process.Environ.Map, key: []const u8, default: bool) bool {
        const raw = env.get(key) orelse return default;
        if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        return default;
    }

    /// `null` when neither var is set. When only one of the pair is set,
    /// logs an error and also returns `null` — a half-configured Matrix
    /// connector (e.g. a homeserver URL with no token) would otherwise fail
    /// obscurely on its first API call instead of just not starting.
    fn loadMatrixConfig(env: *const std.process.Environ.Map) ?MatrixConfig {
        const homeserver_url = env.get("WARDEN_MATRIX_HOMESERVER_URL");
        const access_token = env.get("WARDEN_MATRIX_ACCESS_TOKEN");
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

    fn loadLlmConfig(env: *const std.process.Environ.Map) LoadError!LlmConfig {
        const provider_name = env.get("WARDEN_LLM_PROVIDER") orelse "anthropic";

        if (std.mem.eql(u8, provider_name, "openai_compat")) {
            const base_url = env.get("WARDEN_OPENAI_BASE_URL") orelse return error.MissingLlmConfig;
            return .{ .openai_compat = .{
                .base_url = base_url,
                .api_key = env.get("WARDEN_OPENAI_API_KEY") orelse "",
                .model = env.get("WARDEN_OPENAI_MODEL") orelse "llama3",
            } };
        }

        // Default: anthropic.
        const api_key = env.get("WARDEN_ANTHROPIC_API_KEY") orelse return error.MissingLlmConfig;
        return .{ .anthropic = .{
            .api_key = api_key,
            .model = env.get("WARDEN_ANTHROPIC_MODEL") orelse "claude-sonnet-5",
        } };
    }

    pub const max_system_prompt_bytes = 64 * 1024;

    pub const default_retention_messages: i64 = 20_000;
    pub const default_postgres_pool_size: usize = 10;
    pub const default_confirm_timeout_seconds: i64 = 60;
    pub const default_digest_interval_seconds: i64 = 86_400;
    pub const default_llm_owner_only: bool = true;
    pub const default_llm_show_thinking: bool = false;

    /// Armin's numeric Telegram user id, as a string. Deliberately not
    /// username-based, since usernames can change.
    pub const default_telegram_owner_id: []const u8 = "101573604";
};
