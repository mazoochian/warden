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

/// How `xmpp/client.zig`'s `startTls` verifies the server's certificate —
/// `WARDEN_XMPP_TLS_MODE` selects one, see `loadXmppConfig`.
pub const XmppTlsMode = enum {
    /// Default: the certificate must be well-formed and self-consistent
    /// (a valid self-signed cert, or a valid chain, expiry checked either
    /// way) and its identity must match the JID's domain — but with no CA
    /// to vouch for it, this provides no real protection against an active
    /// attacker who can present their own self-signed cert for the same
    /// name. Suitable for a self-hosted server reached over a network you
    /// already trust (a Docker Compose network, a LAN, a VPN).
    self_signed,
    /// Full verification against the system CA trust store (loaded via
    /// `std.crypto.Certificate.Bundle.rescan`) plus hostname match — the
    /// only mode that actually defends against a network-level attacker.
    /// Needs a real (e.g. Let's Encrypt) certificate on the server; a
    /// self-hosted server with a self-signed cert will fail to connect
    /// under this mode.
    bundle,
    /// No certificate verification at all — STARTTLS still runs so the
    /// password isn't sent in cleartext, but anyone who can intercept the
    /// TCP connection can impersonate the server. Escape hatch only, e.g.
    /// a self-signed cert whose name doesn't match the JID's domain.
    insecure,
};

/// XMPP connector config — `host`/`port` is the raw TCP target (may differ
/// from `domain`, e.g. a compose service name like "prosody" vs. a JID's
/// "localhost" domain part). Authenticates via SASL SCRAM-SHA-256/-SHA-1
/// when the server advertises either, falling back to PLAIN otherwise —
/// see `xmpp/client.zig`'s `authScram`/`authPlain`.
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
    tls_mode: XmppTlsMode = .self_signed,
};

/// TDLib (personal-account) connector config — the owner's own Telegram
/// account, connected via MTProto rather than the Bot API. `api_id`/
/// `api_hash` come from my.telegram.org (per-application credentials,
/// unrelated to a bot token). `session_dir` is where TDLib persists its
/// login session (phone/code/2FA happens once, interactively — see
/// `platform/telegram_user.zig`'s login flow — then this directory is
/// reused on every subsequent start, same "half-configured stays disabled"
/// convention as `MatrixConfig`/`XmppConfig`: all three of these are
/// required together or the connector doesn't start).
pub const TelegramUserConfig = struct {
    api_id: i32,
    api_hash: []const u8,
    session_dir: []const u8,
};

pub const LlmConfig = union(LlmProviderKind) {
    anthropic: AnthropicConfig,
    openai_compat: OpenAiCompatConfig,
};

pub const DelegateKind = enum { anthropic, openai_compat };

/// One "ask another model" target the `ask_delegate`/`delegate_generate_image`
/// tools (see `tools/ask_delegate.zig`, `tools/delegate_generate_image.zig`)
/// can send a task to on the delegating model's own initiative — see
/// `loadDelegateConfigs`'s doc comment for the env var shape that produces
/// these. Plain data, same "config struct in, real provider built in
/// main.zig" split as `AnthropicConfig`/`OpenAiCompatConfig` above.
pub const DelegateConfig = struct {
    /// Case-insensitively matched against the tool call's `delegate`
    /// argument — also what the model sees as the tool's target name, so
    /// keep it short and recognizable ("chatgpt", "local").
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
    /// `delegate_generate_image` — the image-generation model name to
    /// request against `{base_url}/images/generations`. Always null for an
    /// `anthropic`-kind delegate: neither Claude model family exposes an
    /// image-generation endpoint.
    image_model: ?[]const u8 = null,
    /// Shown to the delegating model alongside `name` so it can pick the
    /// right target for a given task, e.g. "OpenAI's GPT-4o — strong at
    /// code and general reasoning."
    description: []const u8 = "",
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
    /// Whichever provider `WARDEN_LLM_PROVIDER` selected at startup — the
    /// default `llm/dynamic_provider.zig` falls back to, and what
    /// `api/router.zig`'s config-display endpoint reads to decide which
    /// secret field to show. NOT necessarily what's actually in use on any
    /// given call once `dynamic_config`'s `WARDEN_LLM_PROVIDER` override
    /// exists — see `llm_anthropic`/`llm_openai_compat` below.
    llm: LlmConfig,
    /// Both loaded independently, whichever credentials are present in
    /// env (unlike `llm` above, which is a tagged union holding only the
    /// one selected at startup) — `null` for a provider whose required
    /// env vars weren't set. `Config.load` fails only if *neither* loads,
    /// same as before this pair of fields existed. Populating both
    /// (when both are configured) is what makes `WARDEN_LLM_PROVIDER`
    /// genuinely hot-swappable via `dynamic_config`: swapping to a
    /// provider whose credentials were never loaded here would have
    /// nothing to swap *to*.
    llm_anthropic: ?AnthropicConfig = null,
    llm_openai_compat: ?OpenAiCompatConfig = null,
    /// Every configured "ask another model" target — see
    /// `loadDelegateConfigs`'s doc comment for the `WARDEN_DELEGATES`/
    /// `WARDEN_DELEGATE_<NAME>_*` env vars that populate this. Empty (the
    /// default) means the `ask_delegate`/`delegate_generate_image` tools
    /// never join the active tool list at all — see `main.zig`'s tool-list
    /// construction, same "tool only joins when its backend is configured"
    /// convention as `web_search`/`WARDEN_SEARXNG_URL`.
    delegates: []const DelegateConfig = &.{},
    /// How long a ban/kick confirmation stays valid before expiring.
    confirm_timeout_seconds: i64,
    /// How long a pending interactive /convert flow (waiting for a file
    /// upload, or waiting for a format pick) stays valid before expiring —
    /// longer than `confirm_timeout_seconds` since the user needs time to
    /// actually go find and upload a file, not just tap yes/no.
    convert_timeout_seconds: i64,
    /// How long an open `/menu` session (including a submenu waiting on a
    /// follow-up reply, e.g. Group Administration's "reply with the user
    /// you want to kick") stays valid before expiring — see
    /// `features/menu.zig`.
    menu_timeout_seconds: i64,
    /// Scratch directory for shelling out to external renderers (word
    /// cloud/diagram scripts) — unrelated to the database, purely
    /// throwaway local scratch space.
    tmp_dir: []const u8,
    /// How often an opted-in chat gets a digest (interval-based, not
    /// wall-clock time-of-day — see `features/scheduler.zig`).
    digest_interval_seconds: i64,
    /// How often an opted-in chat gets a proactive briefing (same
    /// interval-based tradeoff as `digest_interval_seconds` above — see
    /// `features/scheduler.zig`'s `BriefingScheduler`).
    briefing_interval_seconds: i64,
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
    /// Base URL of an OpenAI-compatible embeddings endpoint (e.g.
    /// "https://api.openai.com/v1" or a self-hosted server implementing
    /// `POST {url}/embeddings`) for the long-term memory feature
    /// (`llm/embeddings.zig`, `store/memories.zig`) — ROADMAP.md's Phase
    /// 12. Unset disables the whole feature: `/memory`, the
    /// `remember_memory` tool, and `qa.zig`'s retrieval step all become
    /// no-ops. Deliberately separate from `llm_anthropic`/
    /// `llm_openai_compat` (the chat providers) since an embeddings
    /// backend is very likely a different service/model entirely.
    embeddings_url: ?[]const u8,
    /// Empty string means no Authorization header is sent, same
    /// convention `OpenAiCompatProvider.api_key` uses.
    embeddings_api_key: []const u8,
    /// The embedding model to request. Its output dimension must be 1536
    /// (matching OpenAI's text-embedding-3-small/ada-002) — the
    /// `memories.embedding` column's vector width is fixed at migration
    /// time (see `0025_memories.sql`), not derived from this at runtime.
    /// A model with a different dimension fails loudly on the first
    /// `remember` call (a Postgres dimension-mismatch error), not
    /// silently.
    embeddings_model: []const u8,
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
    /// Whether `toolcall.run` attaches an image attachment's actual bytes
    /// to the model call (see `llm/attachment_content.zig`) instead of only
    /// ever mechanically converting/transcribing it — ROADMAP.md's Phase 10.
    /// Defaults on: current Anthropic models all support vision. An owner
    /// pointed at an OpenAI-compatible backend whose configured model
    /// genuinely doesn't (e.g. a local non-vision-tuned model) can turn
    /// this off with one setting — there's no per-provider/per-model
    /// capability metadata anywhere else in this codebase to gate on
    /// automatically.
    llm_vision_enabled: bool,
    /// Whether `toolcall.run` attaches a PDF attachment's actual bytes to
    /// the model call (see `llm/attachment_content.zig`) so the model reads
    /// the real document instead of only ever converting it — ROADMAP.md's
    /// Phase 10 slice 2. Separate from `llm_vision_enabled` because it's a
    /// separate capability with a much narrower provider story: native
    /// document blocks are Anthropic-only, and the OpenAI-compatible
    /// adapter has to tell the model the document is unreadable instead
    /// (see `llm/openai_compat.zig`'s `writeMessages`). Defaults on, like
    /// vision; an owner on a backend without document support can turn it
    /// off to drop that note rather than have it appear on every PDF.
    llm_documents_enabled: bool,
    /// Overrides `qa.zig`'s `answerMaxTokens` (which sizes the budget off
    /// the active platform's message-length cap plus a reasoning-model
    /// thinking reserve) with a flat ceiling instead — for keeping a
    /// deployment's answers short and its token spend predictable
    /// regardless of platform limits. `null` (unset) preserves the
    /// existing dynamic sizing.
    llm_max_tokens_override: ?u32 = null,
    /// How many recent chat messages `qa.zig` sends verbatim as context on
    /// every LLM call — the entire history mechanism today (no
    /// summarization/downsampling, see `ROADMAP.md`'s backlog entry on
    /// that). Smaller means less context (cheaper, faster) at the cost of
    /// the model potentially missing something further back.
    llm_history_messages: i64 = default_llm_history_messages,
    /// Whether a message that's addressed to the bot but is essentially
    /// just a greeting/acknowledgement/sign-off ("hi", "thanks", "lol", ...)
    /// gets an instant canned reply instead of a real (paid) LLM call —
    /// see `features/trivial_reply.zig`.
    skip_trivial_messages: bool = default_skip_trivial_messages,
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
    /// Null when the personal-account (TDLib) connector isn't configured —
    /// `main.zig` only constructs a `TelegramUserConnector` (and adds it to
    /// the active connector list) when this is set. See
    /// `platform/telegram_user.zig`.
    telegram_user: ?TelegramUserConfig = null,
    /// Null (the default) means the warden-ui HTTP+WebSocket API
    /// (`src/api/`) stays entirely off — same half-configured-stays-
    /// disabled convention as `matrix`/`xmpp` above, and a deliberate
    /// choice while this is still under active development: an
    /// in-progress API surface shouldn't be reachable at all on a
    /// production deployment just because the binary happens to support
    /// it now. Set to enable it (see `api_session_secret` below, which is
    /// required once this is set).
    api_port: ?u16 = null,
    /// Worker threads servicing API requests — same `WorkerPool` shape as
    /// `workers_per_platform`, so a slow/stuck API request can't wedge the
    /// bot's own message processing (or vice versa).
    api_workers: usize = default_api_workers,
    /// HMAC-SHA256 signing key for session cookies (`src/api/auth.zig`) —
    /// required (load fails) if `api_port` is set, since an API server
    /// with no way to sign sessions can't authenticate anyone safely.
    /// Never has a default — an auto-generated or hardcoded fallback here
    /// would silently invalidate every session on every restart (auto-
    /// generated) or be a shared, guessable secret across every
    /// deployment of this codebase (hardcoded), either of which is worse
    /// than failing loudly at startup.
    api_session_secret: ?[]const u8 = null,
    /// DANGER: lets anyone hit `POST /api/v1/auth/dev-login` and become
    /// any identity by id, no real login required — exists purely so
    /// Phase 0 could prove the whole session/account/RBAC chain end to
    /// end before any real login provider (Telegram widget/Google/OIDC)
    /// was wired up. Must be confirmed OFF (unset) before this is ever
    /// reachable from anywhere but a contributor's own machine — this
    /// flag existing at all is a tracked TODO to remove once Phase 1's
    /// real logins land, not a permanent feature. Defaults to false.
    api_dev_login: bool = false,
    /// Ladder tunables for `features/storage_sense.zig` -- same
    /// "env sets the compiled default, `dynamic_config` can override live"
    /// pattern `retention_messages` already uses. See that module's doc
    /// comment for what each watermark actually triggers.
    storage_sense_low_watermark_pct: i64 = default_storage_sense_low_watermark_pct,
    storage_sense_high_watermark_pct: i64 = default_storage_sense_high_watermark_pct,
    storage_sense_flood_watermark_pct: i64 = default_storage_sense_flood_watermark_pct,
    storage_sense_resume_margin_pct: i64 = default_storage_sense_resume_margin_pct,
    storage_sense_prune_age_days: i64 = default_storage_sense_prune_age_days,
    storage_sense_resample_batch_size: i64 = default_storage_sense_resample_batch_size,
    /// Off by default -- gates the ladder's destructive actions (prune,
    /// resample, sleep mode), not the monitoring/alerting itself (that's
    /// `feature_flags.zig`'s `storage_sense_monitor`, which fails open like
    /// every other module). Stays off until the owner has watched
    /// `/storage status` for a while and flips it on deliberately.
    storage_sense_autopilot_enabled: bool = false,

    pub const LoadError = error{ MissingBotToken, MissingLlmConfig, MissingPostgresDsn, BadSystemPromptFile, ApiEnabledWithoutSessionSecret } || std.mem.Allocator.Error;

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
        const telegram_user = loadTelegramUserConfig(env);

        var owners_buf: [4]OwnerEntry = undefined;
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
            // Unlike Matrix/XMPP, this connector's account IS the owner by
            // definition — there's no other identity it could authenticate
            // as. Still sourced from an explicit env var rather than
            // resolved automatically from the TDLib session at startup:
            // `Config.load` runs before any connector exists, and requiring
            // the same numeric id you already know as the bot owner keeps
            // this whole block's shape identical to Matrix/XMPP's (each
            // platform's owner_id is a plain, explicit env var, no
            // exceptions) rather than special-casing one of the four.
            if (env.get("WARDEN_TELEGRAM_USER_OWNER_ID")) |user_owner_id| {
                owners_buf[owners_len] = .{ .platform = .telegram_user, .owner_id = user_owner_id };
                owners_len += 1;
            } else {
                std.log.warn("WARDEN_TELEGRAM_USER_API_ID/_API_HASH/_SESSION_DIR are set but WARDEN_TELEGRAM_USER_OWNER_ID isn't — owner-gated actions will reject the personal account until it's set to its own numeric Telegram user id", .{});
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
            .skip_trivial_messages = skip_trivial_messages,
            .matrix = matrix,
            .matrix_pickle_key = matrix_pickle_key,
            .xmpp = xmpp,
            .telegram_user = telegram_user,
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
    /// `_API_HASH`/`_SESSION_DIR` are set (same half-configured-stays-
    /// disabled reasoning as `loadMatrixConfig`/`loadXmppConfig`, extended
    /// to three required fields instead of two — `session_dir` isn't
    /// optional-with-a-default since it holds session material equivalent
    /// to full account access; a silent default risks landing it somewhere
    /// unintended).
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

    /// Longest delegate `name` accepted — well past anything a real config
    /// would use, just a sane bound on the stack buffer `loadDelegateConfigs`
    /// upper-cases each name into to build its env var keys.
    const max_delegate_name_len = 32;

    /// Loads every delegate named in `WARDEN_DELEGATES` (a comma-separated
    /// list, e.g. `WARDEN_DELEGATES=chatgpt,local`) from its own
    /// `WARDEN_DELEGATE_<NAME>_*` env vars — `<NAME>` is `name` upper-cased
    /// verbatim, so a delegate named `chatgpt` reads
    /// `WARDEN_DELEGATE_CHATGPT_KIND`/`_BASE_URL`/`_API_KEY`/`_MODEL`/
    /// `_IMAGE_MODEL`/`_DESCRIPTION`. `_KIND` defaults to `openai_compat`
    /// (the common case: pointing at OpenAI itself, or any other
    /// OpenAI-compatible API) — set it to `anthropic` for a second/different
    /// Claude model or persona. A delegate missing a required var for its
    /// kind is skipped (logged), same half-configured-stays-disabled
    /// convention as `loadMatrixConfig`/`loadXmppConfig` — one bad entry
    /// never fails the whole process. See `DelegateConfig`'s doc comment for
    /// what each field ends up meaning, and `main.zig` for where these turn
    /// into real `llm.Provider`s.
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

    /// Loads *both* providers' credentials independently, whichever are
    /// present in env — not just the one `WARDEN_LLM_PROVIDER` selects —
    /// so `llm/dynamic_provider.zig` has something to hot-swap *to*. Fails
    /// only if neither is configured; picking which one becomes `active`
    /// (the startup default) has the exact same precedence/fallback
    /// behavior this function had before `llm_anthropic`/`llm_openai_compat`
    /// existed, so a single-provider deployment's behavior is unchanged.
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

        // Selection logic here is byte-for-byte the same decision this
        // function made before `llm_anthropic`/`llm_openai_compat` existed
        // (explicitly selecting a provider with missing credentials is
        // still a hard `error.MissingLlmConfig`, no silent cross-provider
        // fallback) — only the *loading* changed, to also capture whatever
        // the other provider's env vars hold, if any.
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
    pub const default_menu_timeout_seconds: i64 = 180;
    /// Deliberately small and fixed (not CPU-scaled like
    /// `defaultWorkersPerPlatform`) — the API is new/low-traffic by
    /// design for now (see `api_port`'s doc comment), not yet a surface
    /// that needs to scale with the host's core count the way per-
    /// platform message workers do.
    pub const default_api_workers: usize = 4;
    pub const default_digest_interval_seconds: i64 = 86_400;
    pub const default_briefing_interval_seconds: i64 = 86_400;
    pub const default_llm_owner_only: bool = true;
    pub const default_llm_show_thinking: bool = false;
    pub const default_llm_streaming: bool = false;
    pub const default_llm_vision_enabled: bool = true;
    pub const default_llm_documents_enabled: bool = true;
    /// Unchanged from the hardcoded value `qa.zig` used before this was
    /// configurable — existing behavior by default, override via
    /// `WARDEN_LLM_HISTORY_MESSAGES` for a cheaper/smaller context window.
    pub const default_llm_history_messages: i64 = 200;
    pub const default_skip_trivial_messages: bool = true;
    pub const default_xmpp_port: u16 = 5222;

    /// Armin's numeric Telegram user id, as a string. Deliberately not
    /// username-based, since usernames can change.
    pub const default_telegram_owner_id: []const u8 = "101573604";

    /// Elasticsearch-watermark-style thresholds for `storage_sense.zig` --
    /// 80% starts pruning/resampling, 90% starts daily owner alerts, 95% is
    /// the final warning + sleep mode, with a 3-point margin below flood
    /// before it resumes (92%), so the bot doesn't flap in and out of sleep
    /// right at the boundary.
    pub const default_storage_sense_low_watermark_pct: i64 = 80;
    pub const default_storage_sense_high_watermark_pct: i64 = 90;
    pub const default_storage_sense_flood_watermark_pct: i64 = 95;
    pub const default_storage_sense_resume_margin_pct: i64 = 3;
    pub const default_storage_sense_prune_age_days: i64 = 180;
    pub const default_storage_sense_resample_batch_size: i64 = 200;
};
