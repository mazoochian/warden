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
    /// Directory holding one SQLite file per chat.
    data_dir: []const u8,
    /// Per-chat message retention: keep only the most recent N messages.
    retention_messages: i64,
    llm: LlmConfig,
    /// How long a ban/kick confirmation stays valid before expiring.
    confirm_timeout_seconds: i64,
    /// Scratch directory for shelling out to external renderers (word
    /// cloud/diagram scripts) — separate from `data_dir` since it's
    /// throwaway, not per-chat state.
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

    pub const LoadError = error{ MissingBotToken, MissingLlmConfig, BadSystemPromptFile } || std.mem.Allocator.Error;

    /// `env` is expected to be `init.environ_map` from `std.process.Init`.
    /// `arena` should be long-lived (e.g. `init.arena.allocator()`) since
    /// the returned Config borrows from both `env` and `arena` for its
    /// lifetime. `io` is only used to read WARDEN_SYSTEM_PROMPT_FILE.
    pub fn load(env: *const std.process.Environ.Map, arena: std.mem.Allocator, io: std.Io) LoadError!Config {
        const telegram_bot_token = env.get("WARDEN_TELEGRAM_BOT_TOKEN") orelse return error.MissingBotToken;

        const telegram_owner_id = env.get("WARDEN_TELEGRAM_OWNER_ID") orelse default_telegram_owner_id;

        const owners = try arena.dupe(OwnerEntry, &.{
            .{ .platform = .telegram, .owner_id = telegram_owner_id },
        });

        const data_dir = env.get("WARDEN_DATA_DIR") orelse "data/chats";

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

        return .{
            .telegram_bot_token = telegram_bot_token,
            .owners = owners,
            .data_dir = data_dir,
            .retention_messages = retention_messages,
            .llm = llm,
            .confirm_timeout_seconds = confirm_timeout_seconds,
            .tmp_dir = tmp_dir,
            .digest_interval_seconds = digest_interval_seconds,
            .system_prompt = system_prompt,
            .searxng_url = searxng_url,
        };
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
    pub const default_confirm_timeout_seconds: i64 = 60;
    pub const default_digest_interval_seconds: i64 = 86_400;

    /// Armin's numeric Telegram user id, as a string. Deliberately not
    /// username-based, since usernames can change.
    pub const default_telegram_owner_id: []const u8 = "101573604";
};
