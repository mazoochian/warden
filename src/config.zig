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

/// XMPP connector config — `host`/`port` is the raw TCP target (may differ
/// from `domain`, e.g. a compose service name like "prosody" vs. a JID's
/// "localhost" domain part). Authenticates via SASL PLAIN, the only
/// mechanism `xmpp/client.zig` implements (see its doc comment: self-
/// hosted/trusted-server deployments only, not a public/federated server).
pub const XmppConfig = struct {
    host: []const u8,
    port: u16,
    domain: []const u8,
    jid_user: []const u8,
    password: []const u8,
    /// Bare room JIDs to auto-join on connect — MUC has no Telegram/
    /// Matrix-equivalent "just works once added to a group" step, so this
    /// is how the operator opts a room in.
    muc_rooms: []const []const u8,
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
    /// How long `PgPool.acquire` waits for a free connection before giving
    /// up with `error.PoolExhausted` instead of blocking forever — see
    /// `store/pool.zig`'s doc comment for why an unbounded wait here used to
    /// be able to wedge every platform's message handling permanently.
    postgres_acquire_timeout_seconds: i64,
    /// Server-side `statement_timeout` set on every pooled connection right
    /// after connecting (see `store/db.zig`'s `Db.open`) — bounds a single
    /// wedged query so it can't hold a pool slot forever even once
    /// connected, complementing `postgres_acquire_timeout_seconds` above.
    postgres_statement_timeout_seconds: i64,
    /// Worker threads per platform connector that actually run
    /// `processMessageTask` (see `main.zig`'s `WorkerPool` usage). Defaults
    /// to whatever gives real parallelism regardless of how few cores the
    /// host has — see `default_workers_per_platform`'s doc comment for why
    /// this can no longer be left to Zig's own (unconfigurable, CPU-count-
    /// derived, and silently-degrading-to-zero-on-a-1-vCPU-host) `Io.Group`
    /// pool.
    workers_per_platform: usize,
    /// Per-chat message retention: keep only the most recent N messages.
    retention_messages: i64,
    llm: LlmConfig,
    /// How long a ban/kick confirmation stays valid before expiring.
    confirm_timeout_seconds: i64,
    /// How long a pending interactive /convert flow (waiting for a file
    /// upload, or waiting for a format pick) stays valid before expiring —
    /// longer than `confirm_timeout_seconds` since the user needs time to
    /// actually go find and upload a file, not just tap yes/no.
    convert_timeout_seconds: i64,
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
    /// Whether `toolcall.run` uses `Provider.chatStream` (progressively
    /// edits the reply into the chat as the model generates it) instead of
    /// one blocking `Provider.chat` call. Defaults to off: as of this
    /// writing, the streaming SSE read path
    /// (`http_util.postJsonSSE`/`postJsonSSEOnce`) has a known bug that can
    /// spin a CPU core indefinitely, past even its own timeout — confirmed
    /// live, not theoretical. Flip on to test a fix; leave off otherwise.
    llm_streaming: bool,
    /// Null when Matrix isn't configured — `main.zig` only constructs a
    /// `MatrixConnector` (and adds it to the active connector list) when
    /// this is set.
    matrix: ?MatrixConfig = null,
    /// The local secret libolm's account/session pickles (see
    /// `src/matrix/olm.zig`) are encrypted under before being persisted —
    /// deliberately sourced from config, not stored in the database
    /// alongside the pickles themselves, so a DB-only compromise doesn't
    /// also hand over the key material needed to decrypt them. Null means
    /// Matrix E2E encryption stays inert (device keys never get created/
    /// uploaded) even if `matrix` is otherwise configured — same
    /// half-configured-stays-disabled reasoning as the connector configs.
    matrix_pickle_key: ?[]const u8 = null,
    /// Null when XMPP isn't configured — `main.zig` only constructs an
    /// `XmppConnector` (and adds it to the active connector list) when
    /// this is set.
    xmpp: ?XmppConfig = null,

    pub const LoadError = error{ MissingBotToken, MissingLlmConfig, MissingPostgresDsn, BadSystemPromptFile } || std.mem.Allocator.Error;

    /// `env` is expected to be `init.environ_map` from `std.process.Init`.
    /// `arena` should be long-lived (e.g. `init.arena.allocator()`) since
    /// the returned Config borrows from both `env` and `arena` for its
    /// lifetime. `io` is only used to read WARDEN_SYSTEM_PROMPT_FILE.
    pub fn load(env: *const std.process.Environ.Map, arena: std.mem.Allocator, io: std.Io) LoadError!Config {
        const telegram_bot_token = env.get("WARDEN_TELEGRAM_BOT_TOKEN") orelse return error.MissingBotToken;

        const telegram_owner_id = env.get("WARDEN_TELEGRAM_OWNER_ID") orelse default_telegram_owner_id;

        const matrix = loadMatrixConfig(env);
        const matrix_pickle_key = nonEmpty(env.get("WARDEN_MATRIX_PICKLE_KEY"));
        const xmpp = try loadXmppConfig(arena, env);

        var owners_buf: [3]OwnerEntry = undefined;
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

        const llm = try loadLlmConfig(env);

        const confirm_timeout_seconds: i64 = if (env.get("WARDEN_CONFIRM_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_confirm_timeout_seconds
        else
            default_confirm_timeout_seconds;

        const convert_timeout_seconds: i64 = if (env.get("WARDEN_CONVERT_TIMEOUT_SECONDS")) |raw|
            std.fmt.parseInt(i64, raw, 10) catch default_convert_timeout_seconds
        else
            default_convert_timeout_seconds;

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
        const llm_streaming = parseBoolEnv(env, "WARDEN_LLM_STREAMING", default_llm_streaming);

        return .{
            .telegram_bot_token = telegram_bot_token,
            .owners = owners,
            .postgres_dsn = postgres_dsn,
            .postgres_pool_size = postgres_pool_size,
            .postgres_acquire_timeout_seconds = postgres_acquire_timeout_seconds,
            .postgres_statement_timeout_seconds = postgres_statement_timeout_seconds,
            .workers_per_platform = workers_per_platform,
            .retention_messages = retention_messages,
            .llm = llm,
            .confirm_timeout_seconds = confirm_timeout_seconds,
            .convert_timeout_seconds = convert_timeout_seconds,
            .tmp_dir = tmp_dir,
            .digest_interval_seconds = digest_interval_seconds,
            .system_prompt = system_prompt,
            .searxng_url = searxng_url,
            .whisper_url = whisper_url,
            .llm_owner_only = llm_owner_only,
            .llm_show_thinking = llm_show_thinking,
            .llm_streaming = llm_streaming,
            .matrix = matrix,
            .matrix_pickle_key = matrix_pickle_key,
            .xmpp = xmpp,
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

    /// Treats an empty string the same as an absent env var — a value left
    /// as `export VAR=""` (e.g. a placeholder for a human to fill in by
    /// hand) should disable the feature it configures, not activate it
    /// with garbage.
    fn nonEmpty(raw: ?[]const u8) ?[]const u8 {
        const v = raw orelse return null;
        return if (v.len == 0) null else v;
    }

    /// `null` when neither var is set. When only one of the pair is set,
    /// logs an error and also returns `null` — a half-configured Matrix
    /// connector (e.g. a homeserver URL with no token) would otherwise fail
    /// obscurely on its first API call instead of just not starting.
    fn loadMatrixConfig(env: *const std.process.Environ.Map) ?MatrixConfig {
        // An env var set to an empty string (e.g. a placeholder left for a
        // human to fill in by hand) counts as unset, same as
        // `WARDEN_SEARXNG_URL`/`WARDEN_WHISPER_URL` — otherwise Matrix would
        // try to activate with blank credentials and spam connection errors
        // until real values land.
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

    /// `null` when neither `WARDEN_XMPP_JID` nor `WARDEN_XMPP_PASSWORD` is
    /// set; logs and also returns `null` when only one is (same half-
    /// configured-stays-disabled reasoning as `loadMatrixConfig`), or when
    /// `WARDEN_XMPP_JID` isn't shaped like `user@domain`.
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

        // Defaults to dialing `domain` directly on the standard client port
        // — override with `WARDEN_XMPP_SERVER` when the socket target
        // differs from the JID's domain (e.g. a compose service name).
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

        return .{
            .host = host,
            .port = port,
            .domain = domain,
            .jid_user = jid_user,
            .password = pw,
            .muc_rooms = try muc_rooms.toOwnedSlice(arena),
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
    pub const default_postgres_pool_size: usize = 10;
    pub const default_postgres_acquire_timeout_seconds: i64 = 30;
    pub const default_postgres_statement_timeout_seconds: i64 = 30;

    /// Floor of 2 regardless of detected core count: on a 1-vCPU host,
    /// Zig's own implicit `Io.Threaded` async pool sizes itself to
    /// `cpu_count - 1` (`0` slots here — confirmed live on the production
    /// VPS), which silently defeats per-message concurrency entirely
    /// (`Io.Group.async` falls back to running inline on the caller instead
    /// of queuing once its bounded pool is exhausted). `WorkerPool` is a
    /// warden-owned pool of real `std.Thread`s instead, so it isn't subject
    /// to that limit — but a "1 worker" default would still let a single
    /// stuck message wedge the whole platform forever, exactly the bug this
    /// replaces, so 2 is the true minimum useful value even on the smallest
    /// possible host. Scales up automatically on beefier hardware; override
    /// with `WARDEN_WORKERS_PER_PLATFORM` to tune either direction.
    fn defaultWorkersPerPlatform() usize {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        return @max(2, cpu_count);
    }
    pub const default_confirm_timeout_seconds: i64 = 60;
    pub const default_convert_timeout_seconds: i64 = 300;
    pub const default_digest_interval_seconds: i64 = 86_400;
    pub const default_llm_owner_only: bool = true;
    pub const default_llm_show_thinking: bool = false;
    pub const default_llm_streaming: bool = false;
    pub const default_xmpp_port: u16 = 5222;

    /// Armin's numeric Telegram user id, as a string. Deliberately not
    /// username-based, since usernames can change.
    pub const default_telegram_owner_id: []const u8 = "101573604";
};
