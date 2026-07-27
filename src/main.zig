const std = @import("std");
const Io = std.Io;

const logging = @import("log.zig");
const log = logging.scoped("main");

/// `log_level` is left permissive (`.debug`) so `std.log`'s own comptime
/// filter never intercepts a message before it reaches `logging.stdLogFn` —
/// filtering by `WARDEN_LOG_LEVEL` happens once, at runtime, inside
/// `log.zig` itself (see its module doc for why: `std.options.log_level` is
/// a comptime value, so it can't respond to an env var on its own). This
/// also means every pre-existing `std.log.err`/`.warn`/`.info`/`.debug` call
/// site elsewhere in the codebase (not yet migrated to `log.zig`'s own
/// `scoped()`) still renders through the same tabular formatter.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.stdLogFn,
};

const config_mod = @import("config.zig");
const auth = @import("auth.zig");
const iface = @import("platform/interface.zig");
const Identity = @import("domain/identity.zig").Identity;
const telegram_platform = @import("platform/telegram.zig");
const matrix_platform = @import("platform/matrix.zig");
const xmpp_platform = @import("platform/xmpp.zig");
const store_pool = @import("store/pool.zig");
const api_server = @import("api/server.zig");
const migrate = @import("store/migrate.zig");
const chats = @import("store/chats.zig");
const identities = @import("store/identities.zig");
const chat_members = @import("store/chat_members.zig");
const chat_settings = @import("store/chat_settings.zig");
const bot_config = @import("store/bot_config.zig");
const bot_admins = @import("store/bot_admins.zig");
const bot_allowlist = @import("store/bot_allowlist.zig");
const bot_pending_grants = @import("store/bot_pending_grants.zig");
const trivial_reply = @import("features/trivial_reply.zig");
const redact_feature = @import("features/redact.zig");
const menu_tree = @import("features/menu_tree.zig");
const menu = @import("features/menu.zig");
const piechart = @import("features/piechart.zig");
const civil_time = @import("text/civil_time.zig");
const user_settings = @import("store/user_settings.zig");
const messages = @import("store/messages.zig");
const stats = @import("store/stats.zig");
const reminders = @import("store/reminders.zig");
const reminder_format = @import("features/reminder_format.zig");
const alert_store = @import("store/alerts.zig");
const alert_feature = @import("features/alerts.zig");
const feed_watches = @import("store/feed_watches.zig");
const feed_watcher = @import("features/feed_watcher.zig");
const transcribe = @import("features/transcribe.zig");
const convert_flow = @import("features/convert_flow.zig");
const llm = @import("llm/provider.zig");
const AnthropicProvider = @import("llm/anthropic.zig").AnthropicProvider;
const OpenAiCompatProvider = @import("llm/openai_compat.zig").OpenAiCompatProvider;
const qa = @import("features/qa.zig");
const dynamic_provider_mod = @import("llm/dynamic_provider.zig");
const toolcall = @import("llm/toolcall.zig");
const tool_registry = @import("tools/registry.zig");
const group_admin = @import("features/group_admin.zig");
const wordcloud = @import("features/wordcloud.zig");
const digest = @import("features/digest.zig");
const scheduler = @import("features/scheduler.zig");
const convert_file = @import("tools/convert_file.zig");
const worker_pool = @import("worker_pool.zig");
const feature_flags = @import("store/feature_flags.zig");
const dynamic_config = @import("store/dynamic_config.zig");

const base_tools = [_]tool_registry.ToolDef{
    @import("tools/calculator.zig").tool,
    @import("tools/weather.zig").tool,
    @import("tools/air_quality.zig").tool,
    @import("tools/currency.zig").tool,
    @import("tools/crypto_price.zig").tool,
    @import("tools/fetch_url.zig").tool,
    @import("tools/scrape_site.zig").tool,
    @import("tools/draw_diagram.zig").tool,
    @import("tools/qr_code.zig").tool,
    @import("tools/word_cloud.zig").tool,
    @import("tools/dictionary.zig").tool,
    @import("tools/urban_dictionary.zig").tool,
    @import("tools/hackernews.zig").tool,
    @import("tools/remind.zig").tool,
    @import("tools/set_alert.zig").tool,
    @import("tools/begin_conversion.zig").tool,
    convert_file.tool,
    @import("tools/find_chat_member.zig").tool,
};
const web_search_tool = @import("tools/web_search.zig").tool;

/// Published via `Connector.setCommands` at startup so commands show up in
/// the platform's own UI (Telegram's "/" autocomplete / attachment menu)
/// instead of only working for people who already know the exact text to
/// type — see `handleHelp`/`help_text` below for the fuller reference,
/// including the owner/bot-admin-only `/token /credit /scraper /adduser
/// /removeuser /allowchat /disallowchat /addadmin /removeadmin /sudo`
/// deliberately left out of this public menu (see their own dispatch-table
/// gates in `handleMessage`).
const public_commands = [_]iface.CommandSpec{
    .{ .name = "help", .description = "Show available commands and how to talk to Warden." },
    .{ .name = "menu", .description = "Open a button-driven menu of every module (alerts, watches, stats, admin, settings, help)." },
    .{ .name = "ping", .description = "Check that Warden is responsive." },
    .{ .name = "stats", .description = "Show message stats for this chat." },
    .{ .name = "wordcloud", .description = "Generate a word cloud from recent chat activity." },
    .{ .name = "digest", .description = "on | off | now -- enable, disable, or generate a recent-activity summary." },
    .{ .name = "remind", .description = "<time> <message> -- set a reminder. Also: every <interval> ..., cancel <id>." },
    .{ .name = "reminders", .description = "List your pending reminders in this chat." },
    .{ .name = "alert", .description = "<crypto|weather|aqi> <subject> <above|below> <value> -- set an alert." },
    .{ .name = "alerts", .description = "List pending alerts in this chat." },
    .{ .name = "watch", .description = "<feed url> -- get notified when an RSS/Atom feed publishes." },
    .{ .name = "unwatch", .description = "<feed url> -- stop watching a feed." },
    .{ .name = "watches", .description = "List feeds this chat is watching." },
    .{ .name = "watchcheck", .description = "<feed url> -- force an immediate check of a watch, for testing." },
    .{ .name = "convert", .description = "Convert an attached photo/document/voice/audio/video to another format." },
    .{ .name = "magicword", .description = "<word> -- make Warden answer any message containing this word." },
    .{ .name = "persona", .description = "<text> -- set a custom personality for this chat (or off to reset)." },
    .{ .name = "thinking", .description = "on|off|default -- show or hide the model's reasoning for this chat." },
    .{ .name = "mute", .description = "Reply to a user's message to mute them. Admins only." },
    .{ .name = "unmute", .description = "Reply to a user's message to unmute them. Admins only." },
    .{ .name = "pin", .description = "Reply to a message to pin it. Admins only." },
    .{ .name = "unpin", .description = "Unpin the current pinned message. Admins only." },
    .{ .name = "delete", .description = "Reply to a message to delete it. Admins only." },
    .{ .name = "kick", .description = "Reply, or pass @username / user id, to remove them. Admins only." },
    .{ .name = "ban", .description = "Reply, or pass @username / user id, to permanently ban them. Admins only." },
    .{ .name = "promote", .description = "Reply to a user's message to grant them admin. Bot owner only." },
    .{ .name = "demote", .description = "Reply to a user's message to revoke their admin. Bot owner only." },
    .{ .name = "confirm", .description = "Confirm a pending /kick or /ban. Admins only." },
    .{ .name = "cancel", .description = "Cancel your pending file conversion, or a pending /kick or /ban." },
    .{ .name = "redact", .description = "<N> | reply [N] | text <substring> | regex <pattern> -- delete messages. Admins only." },
    .{ .name = "whois", .description = "Reply, or pass @username / user id, to look up who someone is. Bot admin/owner only." },
};

/// `/help`'s reply — kept as a single static string (matches `reply()`'s
/// `comptime txt` parameter) rather than built from `public_commands`, since
/// it also covers the owner-only commands deliberately left out of that
/// public menu, group-chat-only commands, and the free-form LLM path, none
/// of which fit `CommandSpec`'s flat name/description shape.
const help_text =
    \\I'm Warden. Talk to me directly by mentioning me (@username), replying
    \\to one of my messages, or (in a group) saying a chat-specific magic
    \\word if one's set — see /magicword. I'm not limited to chat commands:
    \\ask me anything in plain language and I'll use whatever tool fits
    \\(weather/air quality, currency/crypto prices, a calculator,
    \\dictionaries, Hacker News, QR codes, diagrams, word clouds, web
    \\search, fetching a URL) -- reminders, alerts, and file conversion
    \\below all work as plain requests too, not just as slash commands.
    \\
    \\General
    \\/ping -- check I'm responsive
    \\/menu -- button menu covering everything below (Matrix: !menu too)
    \\/stats -- message stats for this chat
    \\/wordcloud -- word cloud from recent activity
    \\/digest on|off|now -- enable/disable/generate a recent-activity summary
    \\
    \\Reminders, alerts, feeds
    \\/remind <time> <message> -- e.g. /remind 30m take the bread out, or
    \\  /remind 14:30 stand-up. Also: /remind every <interval> <message> to
    \\  repeat, /remind cancel <id>
    \\/reminders -- list your pending reminders
    \\/alert <crypto|weather|aqi> <subject> <above|below> <value> -- e.g.
    \\  /alert crypto btc above 100000. Also: /alert cancel <id>
    \\/alerts -- list pending alerts
    \\/watch <feed url> / /unwatch <feed url> / /watches -- RSS/Atom feed
    \\  notifications for this chat. /watchcheck <feed url> forces an
    \\  immediate check, for testing
    \\
    \\Files
    \\/convert -- start a guided conversion (I'll ask you to send a file);
    \\  or send a file with "/convert <format>" as its caption for one shot,
    \\  e.g. /convert pdf
    \\
    \\Customization
    \\/magicword <word> -- make me answer any message containing it, or
    \\  /magicword off. Owner only to change, anyone can view.
    \\/persona <text> -- set this chat's personality/system prompt, or
    \\  /persona off to reset. Owner only to change, anyone can view.
    \\/thinking on|off|default -- show or hide the model's reasoning for
    \\  this chat, overriding the bot-wide default. Owner only to change,
    \\  anyone can view.
    \\
    \\Group moderation (chat admins only, most by replying to a message)
    \\/mute, /unmute, /pin, /unpin, /delete -- reply to the target
    \\  message/user (unpin doesn't need a reply)
    \\/kick, /ban [@username | user_id] -- reply to the target, or pass
    \\  @username or their raw user id
    \\/promote, /demote -- reply to a user's message to grant/revoke real
    \\  admin rights. Bot owner only, not open to other chat admins
    \\/confirm -- confirm a pending /kick or /ban
    \\/cancel -- cancel your pending file conversion, or a pending
    \\  /kick/ban if you're an admin
    \\/redact <N> | (reply) [N] | text <substring> | regex <pattern> --
    \\  delete messages, up to 100 at a time. Plain /redact <N> walks
    \\  backward by id on Telegram, reaching messages this bot never
    \\  logged. regex mode is bot admin/owner only
    \\
    \\Tokens and credits (reply to a user, or pass @username, to view/set)
    \\/token [balance] [@user] -- lets a non-admin run one /kick or /ban per
    \\  token spent. This chat's admins or any bot admin can grant these
    \\/credit [balance] [@user] -- lets someone talk to the LLM, 1 credit per
    \\  question. Bot admin/owner only (spends real API cost)
    \\
    \\Bot admins (trusted bot-wide, not scoped to one chat -- owner only to
    \\grant/revoke; the owner counts as one automatically, everywhere)
    \\/addadmin, /removeadmin -- reply to a user, or pass @username or their
    \\  user id, to grant/revoke
    \\/adduser, /removeuser -- reply to a user, or pass @username or their
    \\  user id, to let them use this bot at all (nobody but the owner/bot
    \\  admins can by default)
    \\/allowchat, /disallowchat -- allow/disallow this whole chat
    \\/whois [@username | user_id] -- reply to a user, or pass @username or
    \\  their user id, to see their full name, username, platform id, and
    \\  bot/bot-admin/superuser flags. Bot admin/owner only
    \\/sudo <command> -- a bot admin can run any moderation command above
    \\  even where they aren't a real chat admin, e.g. /sudo kick
    \\
    \\Owner only
    \\/scraper -- configure the web-scraping backend
;

/// Appends a note about the `/command@botusername` qualified form (see
/// `normalizeCommandMention`) using this connector's *actual* username when
/// known, rather than baking a guessed example into the static `help_text`
/// above — relevant mainly when two bot instances share one group chat.
fn handleHelp(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    const username = connector.selfUsername() orelse {
        reply(connector, a, msg.chat_id, msg.message_id, help_text);
        return;
    };
    const full = std.fmt.allocPrint(
        a,
        "{s}\n\nSharing this group with another bot? Qualify a command with my username, e.g. /ping@{s}, and I'll ignore commands qualified for a different bot.",
        .{ help_text, username },
    ) catch return reply(connector, a, msg.chat_id, msg.message_id, help_text);
    connector.sendMessage(a, msg.chat_id, full, msg.message_id);
}

test "help_text leaves enough headroom under Telegram's 4096-byte message cap for handleHelp's dynamic suffix" {
    // A Telegram username is at most 32 bytes, so 200 bytes of slack is
    // generous for the "Sharing this group..." suffix `handleHelp` appends.
    try std.testing.expect(help_text.len < 4096 - 200);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // As early as possible — before the healthcheck branch, before config
    // load — so every log line from here on (including config-load
    // failures) has a real timestamp and respects `WARDEN_LOG_LEVEL`.
    logging.init(io, init.environ_map);

    // Docker's `HEALTHCHECK` (see `Dockerfile`) spawns this same binary as a
    // brand-new process on a timer rather than reaching into the running
    // one — there was previously no liveness signal at all, so a fully
    // wedged-but-still-running process (see `PgPool`'s and `WorkerPool`'s
    // doc comments for how that happened in production) looked identical to
    // a healthy one from `docker ps`'s point of view. Checked before
    // anything else (config load included) so a healthcheck probe never
    // waits on, or fails because of, the bot's own startup dependencies.
    if (wantsHealthcheck(init.minimal.args)) runHealthcheck(gpa, io, init.environ_map);

    const config = config_mod.Config.load(init.environ_map, init.arena.allocator(), io) catch |err| {
        log.fatal("config error: {t} (did you set WARDEN_TELEGRAM_BOT_TOKEN and WARDEN_POSTGRES_DSN?)", .{err});
    };
    log.notice("log level = {s} (set WARDEN_LOG_LEVEL to change)", .{@tagName(logging.currentLevel())});

    // web_search only joins the tool list when an instance is configured,
    // so the model never sees a tool that's guaranteed to fail.
    var tools_buf: [base_tools.len + 1]tool_registry.ToolDef = undefined;
    @memcpy(tools_buf[0..base_tools.len], &base_tools);
    var tools_len: usize = base_tools.len;
    if (config.searxng_url != null) {
        tools_buf[tools_len] = web_search_tool;
        tools_len += 1;
    } else {
        log.info("web search disabled (set WARDEN_SEARXNG_URL to enable)", .{});
    }
    const active_tools = tools_buf[0..tools_len];

    var telegram_adapter = telegram_platform.TelegramConnector.init(gpa, io, config.telegram_bot_token);
    defer telegram_adapter.deinit();

    // Matrix only joins the active connector list when configured (see
    // `config.zig`'s `matrix` field) — `matrix_adapter` lives in `main`'s own
    // stack frame for the whole run, so `&matrix_adapter.?` below stays valid
    // for as long as its `Connector` does.
    var matrix_adapter: ?matrix_platform.MatrixConnector = if (config.matrix) |mc|
        matrix_platform.MatrixConnector.init(gpa, io, mc.homeserver_url, mc.access_token)
    else
        null;
    defer if (matrix_adapter) |*m| m.deinit();

    // Same "only join the list when configured" shape as Matrix above.
    var xmpp_adapter: ?xmpp_platform.XmppConnector = if (config.xmpp) |xc|
        xmpp_platform.XmppConnector.init(gpa, io, xc.host, xc.port, xc.domain, xc.jid_user, xc.password, xc.muc_rooms)
    else
        null;
    defer if (xmpp_adapter) |*x| x.deinit();

    var connectors_buf: [3]iface.Connector = undefined;
    var connectors_len: usize = 0;
    connectors_buf[connectors_len] = telegram_adapter.connector();
    connectors_len += 1;
    if (matrix_adapter) |*m| {
        connectors_buf[connectors_len] = m.connector();
        connectors_len += 1;
    }
    if (xmpp_adapter) |*x| {
        connectors_buf[connectors_len] = x.connector();
        connectors_len += 1;
    }
    const connectors: []const iface.Connector = connectors_buf[0..connectors_len];
    const max_message_len = effectiveMaxMessageLength(connectors);

    var pool = store_pool.PgPool.init(
        gpa,
        io,
        config.postgres_dsn,
        config.postgres_pool_size,
        @intCast(config.postgres_acquire_timeout_seconds * std.time.ns_per_s),
        config.postgres_statement_timeout_seconds,
    ) catch |err| {
        log.fatal("postgres: pool init failed (size={d}): {t}", .{ config.postgres_pool_size, err });
    };
    defer pool.deinit();
    log.info("postgres: pool ready, {d} connection(s)", .{config.postgres_pool_size});
    {
        const db = try pool.acquire();
        defer pool.release(db);
        migrate.migrate(db, gpa) catch |err| {
            log.fatal("postgres: schema migration failed: {t}", .{err});
        };
    }

    // Device key creation/upload plus ongoing encrypt/decrypt for Matrix
    // E2E encryption (see src/matrix/olm.zig, src/matrix/crypto.zig,
    // ROADMAP.md's Phase 2b) — only active when `WARDEN_MATRIX_PICKLE_KEY`
    // is set; a failure here is logged, not fatal, since plaintext-room
    // Matrix functionality doesn't depend on it.
    if (matrix_adapter) |*m| {
        if (config.matrix_pickle_key) |pickle_key| {
            m.enableCrypto(gpa, io, &pool, pickle_key) catch |err| {
                log.err("matrix e2ee: device key setup failed: {t}", .{err});
            };
        }
    }

    var pending_confirmations = group_admin.PendingConfirmations.init(gpa, io, config.confirm_timeout_seconds);
    defer pending_confirmations.deinit();

    var digest_scheduler = scheduler.DigestScheduler.init(gpa, io, config.digest_interval_seconds);
    defer digest_scheduler.deinit();
    loadDigestScheduleFromDisk(gpa, &pool, &digest_scheduler);

    var pending_conversions = convert_flow.PendingConversions.init(gpa, io, config.convert_timeout_seconds);
    defer pending_conversions.deinit();

    var menu_sessions = menu.Sessions.init(gpa, io, config.menu_timeout_seconds);
    defer menu_sessions.deinit();

    // Heap-allocated, process-lifetime singletons -- fine to leave for the
    // OS to reclaim on exit rather than threading a deinit through here.
    // Unlike before `WARDEN_LLM_PROVIDER` became hot-swappable, *both*
    // providers get constructed whenever both have credentials (not just
    // whichever `config.llm` selected as the startup default) -- see
    // `config.zig`'s `Config.llm_anthropic`/`Config.llm_openai_compat`
    // doc comments for why, and `llm/dynamic_provider.zig` for the
    // wrapper that actually does the per-call re-resolution.
    var anthropic_provider: ?llm.Provider = null;
    if (config.llm_anthropic) |a| {
        const p = try gpa.create(AnthropicProvider);
        p.* = AnthropicProvider.init(gpa, io, a.api_key, a.model);
        anthropic_provider = p.provider();
    }
    var openai_provider: ?llm.Provider = null;
    if (config.llm_openai_compat) |o| {
        const p = try gpa.create(OpenAiCompatProvider);
        p.* = OpenAiCompatProvider.init(gpa, io, o.base_url, o.api_key, o.model);
        openai_provider = p.provider();
    }
    // `Config.load` already guarantees at least one of the two above
    // exists (same "fails if neither is configured" contract as before
    // this refactor) -- `config.llm`'s active tag tells us which one to
    // treat as the fallback/default, and it's always the one that was
    // just constructed for that tag, never null here.
    const default_provider_name: []const u8 = if (config.llm == .openai_compat) "openai_compat" else "anthropic";
    const fallback_provider = if (config.llm == .openai_compat) openai_provider.? else anthropic_provider.?;

    const dynamic_provider = try gpa.create(dynamic_provider_mod.DynamicLlmProvider);
    dynamic_provider.* = .{
        .pool = &pool,
        .anthropic = anthropic_provider,
        .openai_compat = openai_provider,
        .fallback = fallback_provider,
        .default_provider_name = default_provider_name,
    };
    const llm_provider: llm.Provider = dynamic_provider.provider();

    log.info("warden started, {d} connector(s), {d} owner(s) configured", .{ connectors.len, config.owners.len });

    // Best-effort: a platform without the concept (or a transient API
    // failure) just means commands don't autocomplete, not a startup
    // failure — the commands themselves work regardless via `handleMessage`.
    for (connectors) |connector| {
        connector.setCommands(gpa, &public_commands) catch |err| {
            if (err != error.Unsupported) {
                log.warn("failed to publish command menu for {s}: {t}", .{ @tagName(connector.platform()), err });
            }
        };
    }

    // One timestamp per connector (last successful `poll()` return) plus
    // one for `main`'s own scheduler loop below — the only cross-process
    // liveness signal that exists (see `runHealthcheck`/`selfWatchdogLoop`).
    // Sized/allocated before any poll loop starts so every connector has a
    // slot regardless of whether its own startup below succeeds; a
    // connector that never starts simply never stamps its slot, which
    // correctly reads as permanently unhealthy rather than "absent."
    var heartbeat = Heartbeat.init(gpa, io, connectors) catch |err| {
        log.fatal("failed to allocate heartbeat state: {t}", .{err});
    };

    // One persistent poll loop per connector, running concurrently —
    // previously a single loop polled every connector in turn, so one
    // connector's slow or failing poll (a ~25s long-poll timeout, or
    // XMPP's connection retries) delayed every other connector's turn by
    // however long it took. Each connector already owns its own
    // independent state (`since`/`offset` tokens, sockets), so there was
    // never a data-race reason for the round-robin — it was simply how the
    // loop looked before Matrix/XMPP joined Telegram as second and third
    // connectors, and never got revisited.
    //
    // Real OS threads (`std.Thread.spawn`), deliberately NOT
    // `Io.Group.async`: `Io.Threaded`'s async/group pool is bounded
    // (`cpu_count - 1` slots — see its `async_limit`), and once that pool
    // is exhausted, a further `.async()` call doesn't queue, it runs the
    // function *synchronously inline on the calling thread* instead.
    // These loops never return, so spawning them into that same bounded
    // pool would permanently occupy slots meant for short-lived concurrent
    // work — confirmed live: doing that once caused the "thinking"
    // ticker's edits and the LLM call itself to silently start blocking
    // instead of running concurrently, hanging real requests. Raw threads
    // sidestep the pool entirely; `io` itself is safe to call from any
    // thread; `.detach()` since these run forever and are never joined,
    // matching how nothing here ever joins a `WorkerPool`'s tasks either.
    //
    // Each connector also gets its own `MessageWorkerPool` — real
    // `std.Thread`s sized off `config.workers_per_platform` (floor of 2
    // regardless of detected cores) — replacing the old single, process-
    // wide `Io.Group` that funneled every platform's messages through
    // Zig's own implicit, unconfigurable `Io.Threaded` async pool (bounded
    // to `cpu_count - 1` slots — `0` on the production VPS's single vCPU,
    // which silently defeated per-message concurrency entirely; see
    // `worker_pool.zig`'s module doc for the full story). Isolated per
    // platform so a Telegram backlog can never starve Matrix/XMPP
    // processing or vice versa, same isolation principle as the dedicated
    // poll thread itself. A pool that fails to start (thread-spawn
    // failure — the process is already in a bad way) skips that
    // connector's poll loop too rather than aborting every platform.
    for (connectors, 0..) |connector, i| {
        const msg_pool = MessageWorkerPool.init(gpa, io, config.workers_per_platform, MessageTask.run) catch |err| {
            log.err("failed to start worker pool for {t}: {t}", .{ connector.platform(), err });
            continue;
        };
        log.info("{t}: worker pool started, {d} worker(s)", .{ connector.platform(), config.workers_per_platform });
        const thread = std.Thread.spawn(.{}, connectorPollLoop, .{
            connector,
            &config,
            &pool,
            llm_provider,
            active_tools,
            &pending_confirmations,
            &digest_scheduler,
            &pending_conversions,
            &menu_sessions,
            io,
            gpa,
            max_message_len,
            msg_pool,
            &heartbeat,
            i,
        }) catch |err| {
            log.err("failed to start poll loop thread for {t}: {t}", .{ connector.platform(), err });
            continue;
        };
        thread.detach();
        log.notice("{t}: poll loop started", .{connector.platform()});
    }

    // Guarantees recovery even if nothing external is watching the
    // `Dockerfile` HEALTHCHECK's result — Docker does not restart a
    // container merely because it reports unhealthy, only
    // `restart: unless-stopped` (already set in `compose.yaml`) reacting to
    // the *process* actually exiting does that. Generous stale threshold
    // (well above any legitimate poll/scheduler cadence) so this never
    // fires on a merely slow, still-alive bot. A failure to even start this
    // thread is logged, not fatal — the bot still runs, just without the
    // extra self-healing safety net.
    if (std.Thread.spawn(.{}, selfWatchdogLoop, .{ io, &heartbeat })) |thread| {
        thread.detach();
    } else |err| {
        log.warn("failed to start self-watchdog thread: {t}", .{err});
    }

    // warden-ui's HTTP+WebSocket API (see /home/armin/claude/warden-ui) —
    // entirely off unless WARDEN_API_PORT is set (see `Config.api_port`'s
    // doc comment for why this stays opt-in while still under active
    // development). A failure to start it is logged, not fatal — same
    // convention as the self-watchdog thread above; the bot itself must
    // never fail to start because of a problem in this newer, optional
    // surface.
    if (config.api_port) |port| {
        const api_ctx = try gpa.create(api_server.ServerContext);
        api_ctx.* = .{ .allocator = gpa, .io = io, .pool = &pool, .config = &config, .connectors = connectors };
        if (std.Thread.spawn(.{}, apiServerThread, .{ api_ctx, port, config.api_workers })) |thread| {
            thread.detach();
        } else |err| {
            log.warn("failed to start API server thread: {t}", .{err});
        }
    }

    // Due-digest/reminder/alert/feed checks used to piggyback on the old
    // round-robin loop's natural ~30s-ish cadence; now that connectors
    // poll independently (no shared "lap" to hang off of), this is its own
    // explicit ~30s ticker instead — same granularity as before.
    const scheduler_log = logging.scoped("scheduler");
    while (true) {
        const tick_started = Io.Timestamp.now(io, .real);
        const now = tick_started.toSeconds();
        checkAndSendDueDigests(connectors, gpa, io, &config, &pool, &digest_scheduler, llm_provider, max_message_len, now);
        checkAndSendDueReminders(connectors, gpa, &pool, now);
        alert_feature.checkAndDeliverAlerts(connectors, gpa, io, &pool, now);
        feed_watcher.checkAndNotifyFeeds(connectors, gpa, io, &pool, llm_provider, now);
        pending_conversions.sweepExpired(gpa, now);
        menu_sessions.sweepExpired(now);
        heartbeat.stampScheduler(now);
        heartbeat.writeToFile(io, gpa, config.tmp_dir);
        const tick_ms = @divTrunc(Io.Timestamp.now(io, .real).toNanoseconds() - tick_started.toNanoseconds(), std.time.ns_per_ms);
        // A tick well past its own ~30s cadence is a real signal something
        // downstream (a query, an HTTP call inside one of the due-item
        // checks above) is running slow — WARN instead of DEBUG so it's
        // visible even at the default log level, not just when actively
        // digging with WARDEN_LOG_LEVEL=debug.
        if (tick_ms > 10_000) {
            scheduler_log.warn("tick took {d}ms (longer than expected)", .{tick_ms});
        } else {
            scheduler_log.debug("tick completed in {d}ms", .{tick_ms});
        }
        Io.sleep(io, .fromSeconds(30), .awake) catch {};
    }
}

/// Filename (under `Config.tmp_dir`) `Heartbeat.writeToFile` writes to and
/// `runHealthcheck` reads back — the only cross-process liveness signal
/// that exists, since Docker's `HEALTHCHECK` (see `Dockerfile`) spawns a
/// brand-new instance of this same binary rather than reaching into the
/// running one.
const heartbeat_filename = "heartbeat";

/// How stale a heartbeat line can get before `--healthcheck` reports
/// unhealthy — a generous multiple of the ~30s scheduler cadence that
/// writes it, so a merely slow (not stuck) tick never trips this.
const healthcheck_stale_seconds: i64 = 120;

/// How stale before the in-process watchdog gives up waiting for an
/// external monitor and self-exits instead (see `selfWatchdogLoop`) — much
/// more generous than `healthcheck_stale_seconds` since this is the last
/// resort, not the first signal.
const watchdog_stale_seconds: i64 = 300;

/// One timestamp per connector (index-aligned with `main`'s `connectors`
/// slice) plus one for the top-level scheduler loop — see `main`'s call
/// sites for where each gets stamped. `std.atomic.Value` since connector
/// poll threads, the scheduler loop, and the self-watchdog thread all touch
/// this concurrently with no other synchronization.
const Heartbeat = struct {
    connector_platforms: []const iface.Platform,
    connector_last_ok: []std.atomic.Value(i64),
    scheduler_last_tick: std.atomic.Value(i64) = .init(0),

    /// Seeds every timestamp to `now` (startup time), not `0` — seeding to
    /// `0` made `allFreshInMemory`'s `now - slot` come out astronomically
    /// large (decades) for any connector/the scheduler that hasn't
    /// stamped yet, so a connector merely slow to complete its first poll
    /// (e.g. retrying a flaky `getUpdates` a few times) read as "stale for
    /// over 300s" the very first time `selfWatchdogLoop` checked at
    /// startup+60s, killing a perfectly healthy fresh process. Confirmed
    /// live 2026-07-27: this crash-looped a just-started container every
    /// ~60-90s. Seeding to `now` gives every connector/the scheduler the
    /// full `watchdog_stale_seconds` grace period from actual startup,
    /// same as it already gets for every check after the first.
    fn init(gpa: std.mem.Allocator, io: Io, connectors: []const iface.Connector) !Heartbeat {
        const now = Io.Timestamp.now(io, .real).toSeconds();
        const last_ok = try gpa.alloc(std.atomic.Value(i64), connectors.len);
        for (last_ok) |*slot| slot.* = .init(now);
        const platforms = try gpa.alloc(iface.Platform, connectors.len);
        for (connectors, platforms) |c, *p| p.* = c.platform();
        return .{ .connector_platforms = platforms, .connector_last_ok = last_ok, .scheduler_last_tick = .init(now) };
    }

    fn stampConnector(self: *Heartbeat, idx: usize, now: i64) void {
        self.connector_last_ok[idx].store(now, .release);
    }

    fn stampScheduler(self: *Heartbeat, now: i64) void {
        self.scheduler_last_tick.store(now, .release);
    }

    /// `true` if every tracked timestamp is within `stale_seconds` of `now`
    /// — shared logic between `runHealthcheck` (reading a written file, a
    /// separate process) and `selfWatchdogLoop` (reading this same live
    /// struct in-process).
    fn allFreshInMemory(self: *const Heartbeat, now: i64, stale_seconds: i64) bool {
        if (now - self.scheduler_last_tick.load(.acquire) > stale_seconds) return false;
        for (self.connector_last_ok) |*slot| {
            if (now - slot.load(.acquire) > stale_seconds) return false;
        }
        return true;
    }

    /// Serializes every timestamp to `<tmp_dir>/heartbeat` as plain
    /// `name=unix_timestamp` lines — read back by `runHealthcheck` in a
    /// separate process invocation. Best-effort: a write failure (disk
    /// full, permissions) shouldn't crash the bot, just skip this cycle's
    /// external health visibility — the in-process `selfWatchdogLoop` still
    /// covers actual recovery regardless of whether this file is ever
    /// read.
    fn writeToFile(self: *const Heartbeat, io: Io, gpa: std.mem.Allocator, tmp_dir: []const u8) void {
        Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| {
            log.warn("heartbeat: couldn't create tmp_dir '{s}': {t}", .{ tmp_dir, err });
            return;
        };
        const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ tmp_dir, heartbeat_filename }) catch return;
        defer gpa.free(path);

        var buf: Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        buf.writer.print("scheduler={d}\n", .{self.scheduler_last_tick.load(.acquire)}) catch return;
        for (self.connector_platforms, self.connector_last_ok) |platform, *slot| {
            buf.writer.print("{t}={d}\n", .{ platform, slot.load(.acquire) }) catch return;
        }

        var file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            log.warn("heartbeat: couldn't write '{s}': {t}", .{ path, err });
            return;
        };
        defer file.close(io);
        var file_writer = file.writer(io, &.{});
        file_writer.interface.writeAll(buf.writer.buffered()) catch |err| {
            log.warn("heartbeat: couldn't write '{s}': {t}", .{ path, err });
            return;
        };
        file_writer.interface.flush() catch {};
    }
};

/// `true` if any argument (skipping argv[0]) is exactly `--healthcheck` —
/// the flag `Dockerfile`'s `HEALTHCHECK` passes to probe liveness (see
/// `runHealthcheck`).
fn wantsHealthcheck(args: std.process.Args) bool {
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--healthcheck")) return true;
    }
    return false;
}

/// Reads `<WARDEN_TMP_DIR>/heartbeat` (same env var `Config.load` uses,
/// read directly here since a healthcheck probe shouldn't have to satisfy
/// every other config requirement, e.g. a bot token, just to check
/// liveness) and exits `0` if every recorded timestamp is fresh, `1`
/// otherwise — including when the file is missing/unreadable (a normal
/// state during the container's `--start-period` grace window, which
/// Docker itself already accounts for on its side). Never returns.
fn runHealthcheck(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) noreturn {
    const tmp_dir = env.get("WARDEN_TMP_DIR") orelse "data/tmp";
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ tmp_dir, heartbeat_filename }) catch std.process.exit(1);
    defer gpa.free(path);

    const contents = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch {
        std.process.exit(1);
    };
    defer gpa.free(contents);

    const now = Io.Timestamp.now(io, .real).toSeconds();
    var healthy = true;
    var seen_any = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const ts = std.fmt.parseInt(i64, line[eq + 1 ..], 10) catch continue;
        seen_any = true;
        if (now - ts > healthcheck_stale_seconds) healthy = false;
    }
    std.process.exit(if (healthy and seen_any) 0 else 1);
}

/// Reads the same in-process `Heartbeat` the poll loops/scheduler stamp
/// directly (no file round-trip needed here, unlike `runHealthcheck`) and
/// self-exits if anything has gone stale past `watchdog_stale_seconds` —
/// guarantees actual recovery via `compose.yaml`'s `restart: unless-stopped`
/// even if nothing external is watching the `Dockerfile` HEALTHCHECK's
/// result (Docker itself does not restart a container merely because it
/// reports unhealthy). Never returns under normal operation.
fn selfWatchdogLoop(io: Io, heartbeat: *Heartbeat) void {
    while (true) {
        Io.sleep(io, .fromSeconds(60), .awake) catch return;
        const now = Io.Timestamp.now(io, .real).toSeconds();
        if (!heartbeat.allFreshInMemory(now, watchdog_stale_seconds)) {
            log.fatal("self-watchdog: a connector or the scheduler has gone stale for over {d}s — exiting so the container restarts", .{watchdog_stale_seconds});
        }
    }
}

/// Thread entry point for `api_server.run` — a thin wrapper only because
/// `std.Thread.spawn`'s function must return `void`, not `!void`. A
/// startup failure here (e.g. the port is already in use) is logged, not
/// fatal to the whole bot — same convention as every other optional
/// subsystem's own thread spawn.
fn apiServerThread(ctx: *const api_server.ServerContext, port: u16, workers: usize) void {
    api_server.run(ctx, port, workers) catch |err| {
        log.err("api server exited: {t}", .{err});
    };
}

/// One connector's own poll-forever loop (see the call site's doc comment
/// on why this replaced a single round-robin loop over every connector).
/// Never returns under normal operation, same as `main`'s own top-level
/// loop it runs alongside.
fn connectorPollLoop(
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    io: Io,
    gpa: std.mem.Allocator,
    max_message_len: usize,
    msg_pool: *MessageWorkerPool,
    heartbeat: *Heartbeat,
    connector_idx: usize,
) void {
    while (true) {
        var poll_arena = std.heap.ArenaAllocator.init(gpa);
        defer poll_arena.deinit();
        const poll_a = poll_arena.allocator();

        const polled_messages = connector.poll(poll_a) catch |err| {
            switch (err) {
                // A long poll whose connection died or never came up is
                // operationally an empty poll: updates queue server-side
                // until the next successful getUpdates, so nothing is
                // lost. Flaky networks kill idle connections at the ~30s
                // long-poll mark and drop TLS handshakes during rough
                // patches routinely — warn, don't alarm.
                error.HttpConnectionClosing,
                error.TlsInitializationFailed,
                => log.warn("poll connection dropped (will re-poll): {t}", .{err}),
                else => log.err("poll failed: {t}", .{err}),
            }
            // A failed poll returns immediately instead of blocking for
            // the ~30s long-poll window, so during an outage this loop
            // would otherwise spin against a dead network. Cool off before
            // the next attempt — this connector's own cooldown, no longer
            // one that stalls every other connector's turn too.
            Io.sleep(io, .fromSeconds(5), .awake) catch {};
            continue;
        };

        // Stamped on every successful cycle, whether or not it returned any
        // messages — an empty-but-successful poll already proves this
        // connector isn't wedged, which is all `runHealthcheck`/
        // `selfWatchdogLoop` need to know.
        heartbeat.stampConnector(connector_idx, Io.Timestamp.now(io, .real).toSeconds());
        if (polled_messages.len > 0) {
            log.debug("{t}: poll returned {d} message(s)", .{ connector.platform(), polled_messages.len });
        }

        for (polled_messages) |msg| {
            const ts = Io.Timestamp.now(io, .real).toSeconds();

            // Each task owns an arena for its whole lifetime, created here
            // (not shared with `poll_arena`, which this cycle frees as
            // soon as every message in it has been queued) and freed by the
            // task itself when it's done. `msg` is duped into it right
            // away, before `poll_arena` can be freed out from under a task
            // that hasn't started yet.
            const task_arena = gpa.create(std.heap.ArenaAllocator) catch |err| {
                log.err("failed to allocate task arena: {t}", .{err});
                continue;
            };
            task_arena.* = std.heap.ArenaAllocator.init(gpa);
            const duped_msg = msg.dupe(task_arena.allocator()) catch |err| {
                log.err("failed to dupe message for chat {s}: {t}", .{ msg.chat_id, err });
                task_arena.deinit();
                gpa.destroy(task_arena);
                continue;
            };

            // Enqueued onto this connector's own `MessageWorkerPool` instead
            // of spawned via `Io.Group.async` — `push` never blocks on
            // processing, so this loop always gets straight back to
            // `connector.poll()` regardless of how backed up the queue is,
            // and a stuck message only ever occupies one of N worker
            // threads instead of this poll loop's own thread (see
            // `worker_pool.zig`'s module doc).
            msg_pool.push(.{
                .connector = connector,
                .config = config,
                .pool = pool,
                .llm_provider = llm_provider,
                .tools = tools,
                .pending = pending,
                .digest_scheduler = digest_scheduler,
                .pending_conversions = pending_conversions,
                .menu_sessions = menu_sessions,
                .io = io,
                .gpa = gpa,
                .ts = ts,
                .max_message_len = max_message_len,
                .task_arena = task_arena,
                .msg = duped_msg,
            }) catch |err| {
                // Queueing itself failed (OOM growing the queue's backing
                // array) — `processMessageTask` never got a chance to free
                // `task_arena`, so this is the one place that has to do it
                // instead of leaking it.
                log.err("failed to queue message for chat {s}: {t}", .{ msg.chat_id, err });
                task_arena.deinit();
                gpa.destroy(task_arena);
            };
        }
    }
}

/// Finds the connector whose platform matches `platform` among `connectors`
/// — the lookup `checkAndSendDueDigests`/`checkAndSendDueReminders` need to
/// deliver a due item through the right connector once more than one is
/// active (see `chats.ChatRef`'s doc comment).
fn findConnector(connectors: []const iface.Connector, platform: iface.Platform) ?iface.Connector {
    for (connectors) |c| {
        if (c.platform() == platform) return c;
    }
    return null;
}

/// Fallback used when no connector declares a `maxMessageLength` (shouldn't
/// happen today — Telegram always does) — Telegram's own limit, the
/// tightest of any platform actually implemented so far (see
/// `iface.Connector.VTable.maxMessageLength`'s doc comment).
const default_max_message_length: usize = 4096;

/// The tightest `maxMessageLength` across every active connector. A single
/// deployment could eventually run more than one platform connector at
/// once, each with its own limit (see `iface.Platform`); capping generated
/// text to the smallest of them keeps it valid everywhere without the
/// answer/digest generation paths needing to know which platforms are
/// actually active.
fn effectiveMaxMessageLength(connectors: []const iface.Connector) usize {
    var min_len: usize = default_max_message_length;
    for (connectors) |c| {
        if (c.maxMessageLength()) |len| min_len = @min(min_len, len);
    }
    return min_len;
}

/// Sends `text` normally if it fits within `max_len`, otherwise attaches it
/// as a `.txt` file instead — the fallback for text too long for the
/// active platform(s)' limit (LLM answers, digests). `filename` names the
/// attachment when the fallback fires.
fn sendTextOrFile(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to: ?[]const u8, max_len: usize, filename: []const u8) void {
    if (text.len <= max_len) {
        connector.sendMessage(a, chat_id, text, reply_to);
        return;
    }
    connector.sendDocument(a, chat_id, text, filename, "That was too long for a single message — attached as a file.");
}

/// One connector's own per-message `WorkerPool` (see `connectorPollLoop`'s
/// call site doc comment for why each connector gets its own instead of
/// sharing one process-wide pool).
const MessageWorkerPool = worker_pool.WorkerPool(MessageTask);

/// Bundles every argument `processMessageTask` needs into one plain-data
/// value so it can travel through `MessageWorkerPool`'s queue (see
/// `worker_pool.zig`'s doc comment on `Item`) — the pool's worker threads
/// call `MessageTask.run` directly instead of the old
/// `worker_group.async(io, processMessageTask, .{...})` call.
const MessageTask = struct {
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    io: Io,
    gpa: std.mem.Allocator,
    ts: i64,
    max_message_len: usize,
    task_arena: *std.heap.ArenaAllocator,
    msg: iface.Message,

    fn run(self: MessageTask) void {
        processMessageTask(
            self.connector,
            self.config,
            self.pool,
            self.llm_provider,
            self.tools,
            self.pending,
            self.digest_scheduler,
            self.pending_conversions,
            self.menu_sessions,
            self.io,
            self.gpa,
            self.ts,
            self.max_message_len,
            self.task_arena,
            self.msg,
        );
    }
};

/// Body of one queued per-message task (see `MessageWorkerPool`/
/// `MessageTask` above). Owns `task_arena` end-to-end: created by the
/// caller right before queueing (so `duped_msg` has somewhere stable to
/// live), destroyed here once this message is fully handled.
fn processMessageTask(
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    io: Io,
    gpa: std.mem.Allocator,
    ts: i64,
    max_message_len: usize,
    task_arena: *std.heap.ArenaAllocator,
    msg: iface.Message,
) void {
    defer {
        task_arena.deinit();
        gpa.destroy(task_arena);
    }
    // Declared after the arena-cleanup defer above so it runs *before* that
    // one (defers unwind in reverse declaration order) — `msg.chat_id`
    // below lives in `task_arena`, so the arena must still be alive when
    // this reads it. This is the single most useful log line for diagnosing
    // "the bot died, what was it doing at the time": a task that starts but
    // never logs its completion is exactly the one that was in flight when
    // the process went away.
    const task_started = Io.Timestamp.now(io, .real);
    log.debug("{t}: processing message from chat {s}, user {s}", .{ connector.platform(), msg.chat_id, msg.user_id });
    defer {
        const elapsed_ms = @divTrunc(Io.Timestamp.now(io, .real).toNanoseconds() - task_started.toNanoseconds(), std.time.ns_per_ms);
        if (elapsed_ms > 15_000) {
            log.warn("{t}: message from chat {s} took {d}ms to process (longer than expected)", .{ connector.platform(), msg.chat_id, elapsed_ms });
        } else {
            log.debug("{t}: message from chat {s} processed in {d}ms", .{ connector.platform(), msg.chat_id, elapsed_ms });
        }
    }
    const a = task_arena.allocator();

    const chat_id = chats.upsertChat(pool, connector.platform(), msg.chat_id, msg.chat_type, msg.chat_title) catch |err| {
        log.err("failed to upsert chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };

    // Every group member's message counts toward this chat's local record
    // (stats/content recall), regardless of who sent it — only
    // replies/actions are owner-gated below. A button press/reaction
    // (`choice_picked`) isn't real conversational content — skip logging it
    // so it doesn't show up as a stray empty-text row in /wordcloud or the
    // LLM's history window.
    const identity_id = resolveSenderIdentity(pool, connector, msg, ts) catch |err| {
        log.err("failed to resolve identity for user {s}: {t}", .{ msg.user_id, err });
        return;
    };
    if (msg.choice_picked == null) {
        const retention_messages = dynamic_config.getI64(pool, a, "WARDEN_RETENTION_MESSAGES", config.retention_messages);
        recordMessage(pool, chat_id, identity_id, msg.message_id, msg.text, ts, retention_messages);
    }
    recordObservedUsers(pool, chat_id, msg.observed_users);

    // Downloaded eagerly (not lazily on first tool use) since it's cheap
    // relative to the LLM round trip this task is about to make anyway, and
    // keeps `convert_file`'s execute() simple (just read ctx.attachment_path,
    // never fetch bytes itself). Deleted once this task is done regardless
    // of whether any tool actually touched it — `task_arena`'s deinit only
    // frees memory, not files on disk.
    var attachment_cleanup_path: ?[]const u8 = null;
    defer if (attachment_cleanup_path) |p| Io.Dir.cwd().deleteFile(io, p) catch {};
    const attachment_path = if (msg.attachment) |att| blk: {
        const path = downloadAttachment(connector, io, a, config.tmp_dir, att);
        attachment_cleanup_path = path;
        break :blk path;
    } else null;

    var reminder_adapter: ReminderToolAdapter = .{
        .pool = pool,
        .chat_id = chat_id,
        .identity_id = identity_id,
        .is_owner = auth.isOwner(config, connector.platform(), msg.user_id),
        .now = ts,
    };
    var alert_adapter: AlertToolAdapter = .{
        .pool = pool,
        .chat_id = chat_id,
        .identity_id = identity_id,
        .is_owner = auth.isOwner(config, connector.platform(), msg.user_id),
    };
    var convert_flow_adapter: ConvertFlowToolAdapter = .{
        .pending = pending_conversions,
        .now = ts,
        .chat_id = msg.chat_id,
        .user_id = msg.user_id,
    };
    var member_directory_adapter: MemberDirectoryToolAdapter = .{
        .pool = pool,
        .connector = connector,
        .chat_id = chat_id,
        .native_chat_id = msg.chat_id,
        .now = ts,
    };
    const tool_ctx = tool_registry.ToolContext{
        .allocator = a,
        .io = io,
        .connector = connector,
        .chat_id = msg.chat_id,
        .tmp_dir = config.tmp_dir,
        .searxng_url = config.searxng_url,
        .scraper = bot_config.loadScraperConfig(pool, a),
        .now = ts,
        .reminders = reminder_adapter.sink(),
        .alerts = alert_adapter.sink(),
        .convert_flow = convert_flow_adapter.sink(),
        .member_directory = member_directory_adapter.sink(),
        .attachment_path = attachment_path,
        .attachment_file_name = if (msg.attachment) |att| att.file_name else null,
        .attachment_mime = if (msg.attachment) |att| att.mime_type else null,
    };
    const claimed = handleMessage(connector, a, config, pool, chat_id, identity_id, llm_provider, tool_ctx, tools, pending, digest_scheduler, pending_conversions, menu_sessions, io, ts, max_message_len, msg);
    if (claimed) attachment_cleanup_path = null;
}

/// Downloads `att`'s bytes into `tmp_dir` and returns the local file path
/// (allocated in `allocator`), or null on any failure (connector doesn't
/// support downloads, network error, disk write error) — all logged, none
/// propagated, since a failed download shouldn't stop the rest of message
/// handling (LLM Q&A, other tools) from running; `convert_file` just
/// reports "no file attached" when `ctx.attachment_path` ends up null.
/// Written straight to disk rather than kept in memory and handed back,
/// since document/video attachments can run tens of MB.
fn downloadAttachment(connector: iface.Connector, io: Io, allocator: std.mem.Allocator, tmp_dir: []const u8, att: iface.Attachment) ?[]const u8 {
    const bytes = connector.downloadFile(allocator, att.file_id) catch |err| {
        log.warn("attachment: download failed for file_id {s}: {t}", .{ att.file_id, err });
        return null;
    };
    defer allocator.free(bytes);

    Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| {
        log.warn("attachment: failed to create tmp dir {s}: {t}", .{ tmp_dir, err });
        return null;
    };

    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const path = std.fmt.allocPrint(allocator, "{s}/attach_{d}{s}", .{ tmp_dir, ts, extensionFor(att) }) catch return null;

    var file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        log.warn("attachment: failed to create {s}: {t}", .{ path, err });
        return null;
    };
    defer file.close(io);
    var file_writer = file.writer(io, &.{});
    file_writer.interface.writeAll(bytes) catch |err| {
        log.warn("attachment: failed to write {s}: {t}", .{ path, err });
        return null;
    };
    file_writer.interface.flush() catch |err| {
        log.warn("attachment: failed to flush {s}: {t}", .{ path, err });
        return null;
    };

    return path;
}

/// Best-effort extension (leading dot included) for a downloaded
/// attachment's local file name — prefers the original filename's own
/// extension when Telegram sent one, falling back to a kind-appropriate
/// default so `convert_file` still has something plausible to dispatch on.
fn extensionFor(att: iface.Attachment) []const u8 {
    if (att.file_name) |name| {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i..];
    }
    return switch (att.kind) {
        .photo => ".jpg",
        .document => "",
        .voice => ".ogg",
        .audio => ".mp3",
        .video => ".mp4",
    };
}

/// Stand-in `qa.answer` question for a captionless attachment, so the
/// model's `user_content` still names what just arrived instead of reading
/// "Question: " with nothing after it.
fn attachmentPlaceholder(allocator: std.mem.Allocator, att: iface.Attachment) ![]const u8 {
    const kind_desc = switch (att.kind) {
        .photo => "a photo",
        .document => "a document",
        .voice => "a voice message",
        .audio => "an audio file",
        .video => "a video",
    };
    if (att.file_name) |name| {
        return std.fmt.allocPrint(allocator, "[The user sent {s} named \"{s}\", with no caption.]", .{ kind_desc, name });
    }
    return std.fmt.allocPrint(allocator, "[The user sent {s}, with no caption.]", .{kind_desc});
}

/// The question text `qa.answer` gets for this message. A captionless
/// voice message is transcribed (via a configured `whisper-server`) and the
/// transcript becomes the question, same role Telegram's own `text` field
/// plays for a typed message — falling back to the generic
/// `attachmentPlaceholder` on any failure (whisper not configured, the
/// attachment didn't download, the transcription call itself failed, or
/// came back empty) rather than ever blocking the reply on it.
const ResolvedQuestion = struct {
    text: []const u8,
    /// Set when a "🎙️ Transcribing…" placeholder was already sent — handed
    /// into `replyWithAnswer` so it morphs into the "🤔 Thinking..."
    /// placeholder instead of a second message appearing right after it.
    placeholder_id: ?[]const u8 = null,
};

fn resolveQuestion(connector: iface.Connector, a: std.mem.Allocator, io: Io, config: *const config_mod.Config, pool: *store_pool.PgPool, tool_ctx: tool_registry.ToolContext, msg: iface.Message, text: []const u8) ResolvedQuestion {
    if (text.len > 0) return .{ .text = text };
    const att = msg.attachment orelse return .{ .text = text };

    if (att.kind == .voice) {
        // Disabled falls back to the generic attachment placeholder below,
        // same as "whisper not configured" already does -- not a special
        // error path, just one more reason transcription doesn't happen.
        if (config.whisper_url != null and !feature_flags.isEnabled(pool, "voice_transcription")) {
            return .{ .text = attachmentPlaceholder(a, att) catch text };
        }
        if (config.whisper_url) |whisper_url| {
            if (tool_ctx.attachment_path) |path| {
                const placeholder_id = connector.sendMessageReturningId(a, msg.chat_id, "🎙️ Transcribing your voice message…", msg.message_id) catch |err| blk: {
                    log.warn("transcribe: couldn't send a placeholder for chat {s}: {t}", .{ msg.chat_id, err });
                    break :blk null;
                };
                if (transcribe.transcribe(a, io, whisper_url, config.tmp_dir, path)) |transcript| {
                    if (transcript.len > 0) return .{ .text = transcript, .placeholder_id = placeholder_id };
                } else |err| {
                    log.warn("transcribe: failed for chat {s}: {t}", .{ msg.chat_id, err });
                }
                return .{ .text = attachmentPlaceholder(a, att) catch text, .placeholder_id = placeholder_id };
            }
        }
    }

    return .{ .text = attachmentPlaceholder(a, att) catch text };
}

/// Resolves (upserting as needed) the internal `identities.id` for a
/// message's sender. Prefers the full `Identity`/`TelegramProfile` the
/// connector already built from the platform's wire format; falls back to a
/// minimal placeholder (e.g. `msg.identity` unset because `msg.from` was
/// absent) so a message never fails to log just because identity data was
/// thin.
fn resolveSenderIdentity(pool: *store_pool.PgPool, connector: iface.Connector, msg: iface.Message, ts: i64) !i64 {
    const identity_id = blk: {
        if (msg.identity) |identity| {
            const id = try identities.upsertIdentity(pool, identity);
            if (msg.telegram_profile) |profile| {
                identities.upsertTelegramProfile(pool, id, profile) catch |err| {
                    log.err("failed to upsert telegram profile for identity {d}: {t}", .{ id, err });
                };
            }
            if (msg.matrix_profile) |profile| {
                identities.upsertMatrixProfile(pool, id, profile) catch |err| {
                    log.err("failed to upsert matrix profile for identity {d}: {t}", .{ id, err });
                };
            }
            if (msg.xmpp_profile) |profile| {
                identities.upsertXmppProfile(pool, id, profile) catch |err| {
                    log.err("failed to upsert xmpp profile for identity {d}: {t}", .{ id, err });
                };
            }
            break :blk id;
        }
        break :blk try identities.getOrCreateMinimal(pool, connector.platform(), msg.user_id, msg.username orelse msg.user_id, msg.username, false, ts);
    };
    // Completes a grant queued by `/adduser`/`/addadmin` against a
    // `@username` the bot had no identity for yet — checked on every
    // message that carries a username, before `handleMessage`'s allowlist
    // gate ever runs, so this same (this person's very first) message
    // already sees the completed grant. See `store/bot_pending_grants.zig`.
    if (msg.username) |username| {
        completePendingGrants(pool, connector.platform(), username, identity_id);
    }
    return identity_id;
}

fn completePendingGrants(pool: *store_pool.PgPool, platform: iface.Platform, username: []const u8, identity_id: i64) void {
    const pending_user = bot_pending_grants.takePending(pool, platform, username, .allowed_user) catch |err| blk: {
        log.err("failed to check pending user-allow grant for @{s}: {t}", .{ username, err });
        break :blk null;
    };
    if (pending_user) |added_by| {
        bot_allowlist.addAllowedUser(pool, identity_id, added_by) catch |err| {
            log.err("failed to complete pending user-allow grant for @{s}: {t}", .{ username, err });
        };
        log.notice("completed pending allow-user grant for @{s} (identity {d})", .{ username, identity_id });
    }

    const pending_admin = bot_pending_grants.takePending(pool, platform, username, .bot_admin) catch |err| blk: {
        log.err("failed to check pending bot-admin grant for @{s}: {t}", .{ username, err });
        break :blk null;
    };
    if (pending_admin) |added_by| {
        bot_admins.addBotAdmin(pool, identity_id, added_by) catch |err| {
            log.err("failed to complete pending bot-admin grant for @{s}: {t}", .{ username, err });
        };
        log.notice("completed pending bot-admin grant for @{s} (identity {d})", .{ username, identity_id });
    }
}

/// Registers every identity a message revealed *besides* its own sender
/// (see `iface.Message.observed_users`'s doc comment) into this chat's
/// roster, so `find_chat_member` can resolve them later even if they never
/// send a message of their own. Uses `chat_members.ensureKnown`, not
/// `touch` — being mentioned or replied to isn't the same as having spoken.
/// Errors are logged, not propagated, same reasoning as `recordMessage`.
fn recordObservedUsers(pool: *store_pool.PgPool, chat_id: i64, observed: []const Identity) void {
    for (observed) |identity| {
        const identity_id = identities.upsertIdentity(pool, identity) catch |err| {
            log.err("failed to upsert observed identity {s} for chat {d}: {t}", .{ identity.native_id, chat_id, err });
            continue;
        };
        chat_members.ensureKnown(pool, chat_id, identity_id) catch |err| {
            log.err("failed to register observed member {s} for chat {d}: {t}", .{ identity.native_id, chat_id, err });
        };
    }
}

/// Logs one message and bumps the sender's chat-membership record, then
/// prunes to the retention window — replaces the old `ChatStore.record`.
/// Errors are logged, not propagated: a storage hiccup shouldn't take down
/// the poll loop.
fn recordMessage(pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, message_id: ?[]const u8, text: ?[]const u8, ts: i64, retention: i64) void {
    messages.insert(pool, chat_id, identity_id, message_id, text, ts) catch |err| {
        log.err("failed to insert message for chat {d}: {t}", .{ chat_id, err });
        return;
    };
    chat_members.touch(pool, chat_id, identity_id, ts) catch |err| {
        log.err("failed to touch chat_members for chat {d}: {t}", .{ chat_id, err });
    };
    messages.pruneKeepLast(pool, chat_id, retention) catch |err| {
        log.err("prune failed for chat {d}: {t}", .{ chat_id, err });
    };
}

/// Rebuilds the in-memory enabled-chat set from every known chat's
/// persisted `chat_settings.digest_enabled` — so digests opted into before
/// a restart keep firing rather than silently going quiet.
fn loadDigestScheduleFromDisk(gpa: std.mem.Allocator, pool: *store_pool.PgPool, digest_scheduler: *scheduler.DigestScheduler) void {
    const refs = chats.listAll(pool, gpa) catch |err| {
        log.err("digest: failed to scan existing chats: {t}", .{err});
        return;
    };
    defer {
        for (refs) |r| gpa.free(r.native_chat_id);
        gpa.free(refs);
    }

    for (refs) |ref| {
        if (chat_settings.getDigestEnabled(pool, ref.id)) {
            digest_scheduler.enable(ref.platform, ref.native_chat_id) catch |err| {
                log.err("digest: failed to restore schedule for chat {s}: {t}", .{ ref.native_chat_id, err });
            };
        }
    }
}

/// Delivers through whichever of `connectors` actually owns each due chat's
/// platform (see `findConnector`) — a chat whose platform has no active
/// connector (shouldn't normally happen; guards against a stale/removed
/// platform's leftover `chat_settings` row) is skipped with a log line
/// rather than silently misdelivered through an unrelated connector.
fn checkAndSendDueDigests(
    connectors: []const iface.Connector,
    gpa: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    digest_scheduler: *scheduler.DigestScheduler,
    llm_provider: llm.Provider,
    max_message_len: usize,
    now: i64,
) void {
    const enabled_chats = digest_scheduler.snapshotEnabledChatIds(gpa) catch |err| {
        log.err("digest: failed to snapshot enabled chats: {t}", .{err});
        return;
    };
    defer {
        for (enabled_chats) |k| gpa.free(k.native_chat_id);
        gpa.free(enabled_chats);
    }

    for (enabled_chats) |key| {
        const native_chat_id = key.native_chat_id;
        const connector = findConnector(connectors, key.platform) orelse {
            log.warn("digest: no active connector for platform {s}, skipping chat {s}", .{ @tagName(key.platform), native_chat_id });
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // `chat_type`/`title` null: this isn't a fresh inbound message, just
        // a scheduled check, and `upsertChat` preserves whatever's already
        // stored for those columns when passed null (see its doc comment).
        const chat_id = chats.upsertChat(pool, connector.platform(), native_chat_id, null, null) catch |err| {
            log.err("digest: failed to resolve chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };

        const last_sent = chat_settings.getLastDigestTs(pool, chat_id);
        const digest_interval_seconds = dynamic_config.getI64(pool, a, "WARDEN_DIGEST_INTERVAL_SECONDS", config.digest_interval_seconds);
        if (now - last_sent < digest_interval_seconds) continue;

        const tool_ctx = tool_registry.ToolContext{
            .allocator = a,
            .io = io,
            .connector = connector,
            .chat_id = native_chat_id,
            .tmp_dir = config.tmp_dir,
            .searxng_url = config.searxng_url,
            .scraper = bot_config.loadScraperConfig(pool, a),
        };
        const digest_text = digest.generate(llm_provider, a, tool_ctx, pool, chat_id) catch |err| {
            log.err("digest: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };
        sendTextOrFile(connector, a, native_chat_id, digest_text, null, max_message_len, "digest.txt");
        chat_settings.setLastDigestTs(pool, chat_id, now) catch |err| {
            log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ native_chat_id, err });
        };
    }
}

const LlmDynamicSettings = struct {
    owner_only: bool,
    show_thinking: bool,
    streaming: bool,
    max_tokens_override: ?u32,
    history_messages: i64,
    skip_trivial_messages: bool,
};

/// One `dynamic_config.listAll` fetch instead of six separate
/// `getBool`/`getI64` round trips for every free-form LLM turn — see
/// `store/dynamic_config.zig`'s `listAll`/`findBool`/`findI64` doc
/// comments for why that matters here specifically (this codebase has
/// already hit real Postgres pool exhaustion under load once). Each field
/// falls back to `config`'s own env-sourced default when no DB row exists,
/// same "missing row means default" convention as everywhere else
/// `dynamic_config`/`feature_flags` is read.
fn resolveLlmDynamicSettings(pool: *store_pool.PgPool, a: std.mem.Allocator, config: *const config_mod.Config) LlmDynamicSettings {
    const rows = dynamic_config.listAll(pool, a) catch &.{};
    defer {
        for (rows) |r| {
            a.free(r.key);
            a.free(r.value);
        }
        a.free(rows);
    }

    // `WARDEN_LLM_MAX_TOKENS=0` (or any non-positive value) is treated the
    // same as "no override" -- a real max-tokens value is never
    // meaningfully zero or negative, so this is an unambiguous sentinel
    // rather than a separate "is this key even set" lookup.
    const max_tokens_default: i64 = if (config.llm_max_tokens_override) |v| v else 0;
    const max_tokens_raw = dynamic_config.findI64(rows, "WARDEN_LLM_MAX_TOKENS", max_tokens_default);

    return .{
        .owner_only = dynamic_config.findBool(rows, "WARDEN_LLM_OWNER_ONLY", config.llm_owner_only),
        .show_thinking = dynamic_config.findBool(rows, "WARDEN_LLM_SHOW_THINKING", config.llm_show_thinking),
        .streaming = dynamic_config.findBool(rows, "WARDEN_LLM_STREAMING", config.llm_streaming),
        .max_tokens_override = if (max_tokens_raw > 0) @intCast(max_tokens_raw) else null,
        .history_messages = dynamic_config.findI64(rows, "WARDEN_LLM_HISTORY_MESSAGES", config.llm_history_messages),
        .skip_trivial_messages = dynamic_config.findBool(rows, "WARDEN_LLM_SKIP_TRIVIAL_MESSAGES", config.skip_trivial_messages),
    };
}

/// Returns whether this message's attachment (if any) was claimed by the
/// interactive `/convert` flow — `processMessageTask` must not delete a
/// claimed file via its own attachment-cleanup `defer` (see
/// `features/convert_flow.zig`'s `PendingConversions`, which owns cleanup
/// for a claimed file from here on).
fn handleMessage(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    io: Io,
    now: i64,
    max_message_len: usize,
    msg: iface.Message,
) bool {
    // Coarse "does the bot even respond here" gate — checked before
    // anything else in this function (including the choice_picked/
    // attachment-continuation paths below, for uniformity: a disallowed
    // sender gets no action taken on any kind of message, not just slash
    // commands). Owners and bot admins bypass unconditionally; everyone
    // else needs their own identity or their current chat explicitly
    // allowed. Silent — this is "will the bot talk here at all", not a
    // moderation decision, so it doesn't announce itself. Message
    // recording/stats (`recordMessage`/`recordObservedUsers`) already ran
    // earlier in `processMessageTask`, before `handleMessage`, and are
    // unaffected by this gate.
    const is_owner = auth.isOwner(config, connector.platform(), msg.user_id);
    // The owner is the highest privilege there is and shouldn't need a
    // redundant `bot_admins` row on top of that — before this, `is_bot_admin`
    // was DB-only, so the owner had to `/addadmin` themselves before
    // anything gated specifically on `is_bot_admin` (e.g. `/sudo`) would
    // recognize them as one. `or` short-circuits, so the owner's messages
    // never even pay for the `bot_admins` query.
    const is_bot_admin = is_owner or bot_admins.isBotAdmin(pool, identity_id);
    if (!is_owner and !is_bot_admin) {
        if (!(bot_allowlist.isUserAllowed(pool, identity_id) or bot_allowlist.isChatAllowed(pool, chat_id))) return false;
    }

    // A button press / reaction pick has neither text nor an attachment of
    // its own, so this must run before the "neither" bail-out just below.
    if (msg.choice_picked) |picked| {
        // Both flows key their pending state the same way ((chat, user)),
        // so only one of them should ever actually claim a given pick --
        // `isAwaitingFormat` decides which, rather than trying `menu` only
        // when `convert_flow` misses (that would make convert_flow's own
        // "prompt isn't active anymore" reply fire on a pick that was
        // actually meant for the menu).
        if (pending_conversions.isAwaitingFormat(now, msg.chat_id, msg.user_id)) {
            convert_flow.handleChoicePicked(connector, a, io, config.tmp_dir, pending_conversions, now, msg, picked);
        } else {
            menu_sessions.handleChoicePicked(menu_runner, now, menuCtx(connector, a, pool, config, chat_id, identity_id, now, msg, io, digest_scheduler, pending_conversions), picked);
        }
        return false;
    }

    // A photo/document/voice/audio/video with no caption has no `text` at
    // all (Telegram never sets it for those), but it still deserves a
    // reply when addressed to the bot — the attachment alone is enough for
    // e.g. convert_file to have something to work with. Only bail when
    // there's neither text nor an attachment to react to.
    const raw_text = msg.text orelse "";
    if (raw_text.len == 0 and msg.attachment == null) return false;

    // See `normalizeCommandMention`'s doc comment: makes `/ping@warden_bot`
    // dispatch exactly like `/ping`, and drops a command explicitly
    // addressed to a different bot instance sharing this chat.
    var text = normalizeCommandMention(a, raw_text, connector.selfUsername()) orelse return false;

    // `/sudo <command>` lets a bot admin override a platform-level
    // permission check for one command — see `auth.checkGroupAdminAccess`'s
    // doc comment for the full ladder. Rewriting `text` here (rather than
    // threading a separate "sudo command" string through the whole dispatch
    // chain below) is the minimal-diff mechanism: every existing
    // `std.mem.eql(u8, text, "/foo")`/`startsWith` site keeps working
    // unchanged, just possibly seeing the de-sudo'd command instead of the
    // original. A non-bot-admin's "/sudo foo" is deliberately left
    // untouched here — it matches no command below and falls through to
    // the existing "unrecognized slash command" silent-ignore path, so no
    // special-casing is needed for that case.
    var sudo_active = false;
    if (std.mem.startsWith(u8, text, "/sudo ") and is_bot_admin) {
        sudo_active = true;
        text = std.fmt.allocPrint(a, "/{s}", .{std.mem.trim(u8, text["/sudo ".len..], " ")}) catch text;
    }

    // A plain message (or reply) arriving while (chat, user) has an open
    // `/menu` prompt waiting on free-form input (e.g. Group Administration's
    // "reply with the person you want to kick") — consumed here, before
    // normal dispatch, so it never needs its own slash command. `/cancel`
    // is deliberately exempted so it always reaches its own handler below
    // (one of whose fallback tiers is exactly this session), rather than
    // being swallowed as a failed target-resolution attempt.
    if (!std.mem.eql(u8, text, "/cancel") and
        menu_sessions.handleAwaitingInputMessage(menu_runner, menuCtx(connector, a, pool, config, chat_id, identity_id, now, msg, io, digest_scheduler, pending_conversions)))
    {
        return false;
    }

    // An attachment arriving while (chat, user) is mid-flow, waiting for a
    // file — claimed here, before the big dispatch chain and before
    // `isAddressedToBot`, so a captionless upload in a group (no mention/
    // reply) isn't silently dropped by that gate the way it would be
    // otherwise. Excludes the protected one-shot `/convert <format>`
    // caption, which keeps working completely unchanged below.
    if (msg.attachment != null and !isOneShotConvertCaption(text) and
        pending_conversions.isAwaitingFile(a, now, msg.chat_id, msg.user_id))
    {
        if (convert_flow.claimAttachmentForConvert(connector, a, pending_conversions, now, msg, tool_ctx.attachment_path.?, tool_ctx.attachment_file_name)) return true;
        // Claim failed (e.g. no candidate targets for this file type) —
        // fall through to normal dispatch below.
    }

    if (std.mem.eql(u8, text, "/ping")) {
        connector.sendMessage(a, msg.chat_id, "pong", msg.message_id);
    } else if (std.mem.eql(u8, text, "/help") or std.mem.startsWith(u8, text, "/help ")) {
        handleHelp(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/menu")) {
        if (!feature_flags.isEnabled(pool, "menu")) return false;
        // `!menu` already reaches here as `/menu` too --
        // `normalizeCommandMention` rewrites any leading `!` to `/` for
        // every platform, not just Matrix's requested trigger.
        menu_sessions.open(connector, a, menu_runner, now, msg);
    } else if (std.mem.eql(u8, text, "/stats")) {
        replyWithStats(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/wordcloud")) {
        replyWithWordcloud(connector, a, pool, chat_id, config.tmp_dir, io, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/digest") or std.mem.startsWith(u8, text, "/digest ")) {
        if (!feature_flags.isEnabled(pool, "digest")) return false;
        handleDigestCommand(connector, a, pool, chat_id, digest_scheduler, llm_provider, tool_ctx, now, max_message_len, msg.chat_id, msg.message_id, text);
    } else if (std.mem.eql(u8, text, "/mute")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "mute")) return false;
        group_admin.mute(connector, a, msg, now);
    } else if (std.mem.eql(u8, text, "/unmute")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "unmute")) return false;
        group_admin.unmute(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/pin")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "pin")) return false;
        group_admin.pin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/unpin")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "unpin")) return false;
        group_admin.unpin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/delete")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "delete")) return false;
        group_admin.deleteMessage(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/promote")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        // Owner-only, not `checkGroupAdminAccess` — granting real admin
        // rights is more consequential than mute/kick/pin, and Telegram's
        // own admin flag doesn't tell us whether a given admin actually has
        // permission to add further admins themselves (see
        // `group_admin.promote`'s doc comment). Deliberately not extended
        // to bot admins/`/sudo` either, same reasoning.
        if (!is_owner) return false;
        group_admin.promote(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/demote")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!is_owner) return false;
        group_admin.demote(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/kick") or std.mem.startsWith(u8, text, "/kick ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "kick")) return false;
        handleKickBanCommand(connector, a, pool, now, msg, text, "/kick", .kick);
    } else if (std.mem.eql(u8, text, "/ban") or std.mem.startsWith(u8, text, "/ban ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "ban")) return false;
        handleKickBanCommand(connector, a, pool, now, msg, text, "/ban", .ban);
    } else if (std.mem.eql(u8, text, "/confirm")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "confirm")) return false;
        group_admin.confirm(connector, a, pending, now, msg);
    } else if (std.mem.eql(u8, text, "/cancel")) {
        // Three tiers, tried in order — a pending conversion or an open
        // `/menu` prompt waiting on input are both per-user, not a
        // moderation action, so either can only ever affect something the
        // sender themselves started (no admin gate needed for those two).
        // Falls through to the existing admin-gated ban/kick cancel,
        // unchanged, only when there's nothing of the sender's own to
        // cancel.
        if (pending_conversions.cancel(a, msg.chat_id, msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Conversion cancelled.");
        } else if (menu_sessions.cancel(msg.chat_id, msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Menu prompt cancelled.");
        } else {
            if (!feature_flags.isEnabled(pool, "group_admin")) return false;
            if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "cancel")) return false;
            group_admin.cancel(connector, a, pending, msg);
        }
    } else if (std.mem.startsWith(u8, text, "/token")) {
        if (!auth.checkTokenGrantAccess(connector, a, config, msg, is_bot_admin)) return false;
        handleToken(connector, a, pool, chat_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/credit") or std.mem.startsWith(u8, text, "/credit ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleCredit(connector, a, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/adduser") or std.mem.startsWith(u8, text, "/adduser ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleAddUserCommand(connector, a, pool, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/removeuser") or std.mem.startsWith(u8, text, "/removeuser ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleRemoveUserCommand(connector, a, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/allowchat")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleAllowChatCommand(connector, a, pool, chat_id, identity_id, msg);
    } else if (std.mem.eql(u8, text, "/disallowchat")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleDisallowChatCommand(connector, a, pool, chat_id, msg);
    } else if (std.mem.eql(u8, text, "/addadmin") or std.mem.startsWith(u8, text, "/addadmin ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleAddAdminCommand(connector, a, pool, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/removeadmin") or std.mem.startsWith(u8, text, "/removeadmin ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleRemoveAdminCommand(connector, a, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/whois") or std.mem.startsWith(u8, text, "/whois ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleWhoisCommand(connector, a, config, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/redact") or std.mem.startsWith(u8, text, "/redact ")) {
        // Per-mode gating happens inside handleRedactCommand itself (regex
        // mode is stricter than the other modes) rather than here, since
        // which gate applies depends on parsing the mode first.
        handleRedactCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text, sudo_active);
    } else if (std.mem.eql(u8, text, "/magicword") or std.mem.startsWith(u8, text, "/magicword ")) {
        handleMagicWord(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/persona") or std.mem.startsWith(u8, text, "/persona ")) {
        handlePersonaCommand(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/thinking") or std.mem.startsWith(u8, text, "/thinking ")) {
        handleThinkingCommand(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/scraper") or std.mem.startsWith(u8, text, "/scraper ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleScraperCommand(connector, a, pool, msg, text);
    } else if (std.mem.eql(u8, text, "/remind") or std.mem.startsWith(u8, text, "/remind ")) {
        if (!feature_flags.isEnabled(pool, "reminders")) return false;
        handleRemindCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/reminders")) {
        handleRemindersList(connector, a, pool, chat_id, now, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/convert")) {
        if (!feature_flags.isEnabled(pool, "convert")) return false;
        // Bare /convert, no attachment claimed above (either none present,
        // or claiming it failed) — start (or restart) the multi-stage flow.
        convert_flow.beginConvertFlow(connector, a, pending_conversions, now, msg);
    } else if (std.mem.startsWith(u8, text, "/convert ")) {
        if (!feature_flags.isEnabled(pool, "convert")) return false;
        // UNCHANGED one-shot path: /convert <format> as an attachment's
        // caption, calling convert_file directly, no LLM round trip.
        handleConvertCommand(connector, a, tool_ctx, msg, text);
    } else if (std.mem.eql(u8, text, "/alert") or std.mem.startsWith(u8, text, "/alert ")) {
        if (!feature_flags.isEnabled(pool, "alerts")) return false;
        handleAlertCommand(connector, a, config, pool, chat_id, identity_id, msg, text);
    } else if (std.mem.eql(u8, text, "/alerts")) {
        handleAlertsList(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/watch") or std.mem.startsWith(u8, text, "/watch ")) {
        if (!feature_flags.isEnabled(pool, "watches")) return false;
        handleWatchCommand(connector, a, pool, chat_id, identity_id, msg, text);
    } else if (std.mem.eql(u8, text, "/unwatch") or std.mem.startsWith(u8, text, "/unwatch ")) {
        handleUnwatchCommand(connector, a, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/watches")) {
        handleWatchesList(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/watchcheck") or std.mem.startsWith(u8, text, "/watchcheck ")) {
        if (!feature_flags.isEnabled(pool, "watches")) return false;
        handleWatchCheckCommand(connector, a, pool, io, llm_provider, chat_id, msg, text, now);
    } else if (text.len > 0 and text[0] == '/') {
        // Unrecognized slash command: ignore rather than forwarding to the
        // LLM as if it were a question.
        return false;
    } else if (isAddressedToBot(a, pool, chat_id, msg, text)) {
        // One bulk dynamic_config fetch for every setting this branch
        // reads, instead of six separate round trips -- see
        // `resolveLlmDynamicSettings`'s doc comment.
        const dyn = resolveLlmDynamicSettings(pool, a, config);

        // A greeting/ack/sign-off addressed to the bot doesn't need a real
        // (paid) LLM call to answer meaningfully — short-circuit with an
        // instant canned reply instead. Checked before the owner-only/
        // credit gates below: this costs nothing, so it isn't subject to
        // either (a random allowed user's "hi" gets a friendly reply
        // regardless of whether they're privileged enough for real Q&A).
        if (dyn.skip_trivial_messages and trivial_reply.isTrivialMessage(a, text)) {
            const canned = trivial_reply.pickResponse(@intCast(now));
            connector.sendMessage(a, msg.chat_id, canned, msg.message_id);
            return false;
        }
        // The bot's free-form LLM Q&A is owner-only by default (toggle via
        // WARDEN_LLM_OWNER_ONLY) — every other command above this stays
        // open to anyone (unchanged). Silent, not an error reply: an
        // unaddressed mention from someone else shouldn't announce "I only
        // answer my owner" to the whole group.
        const is_privileged = is_owner or is_bot_admin;
        if (dyn.owner_only and !is_privileged) return false;
        // Credits gate LLM usage specifically (spends the owner's real API
        // budget) — separate from, and checked after, the owner-only gate
        // above. Owner/bot admins get unlimited use; unlike the allowlist
        // gate, running out of credits gets a reply (the sender IS allowed
        // to talk to the bot, just out of budget) rather than silence.
        if (!is_privileged and !(identities.spendCredit(pool, identity_id) catch |err| blk: {
            log.err("qa: credit spend check failed for identity {d}: {t}", .{ identity_id, err });
            break :blk false;
        })) {
            connector.sendMessage(a, msg.chat_id, "You're out of LLM credits — ask the bot owner for more.", msg.message_id);
            return false;
        }
        const replied_to = if (msg.reply_to_is_me) msg.reply_to_text else null;
        const resolved = resolveQuestion(connector, a, io, config, pool, tool_ctx, msg, text);
        // Per-chat /persona override, falling back to the global default —
        // see `store/chat_settings.zig`'s `getSystemPromptOverride`.
        const system_prompt = chat_settings.getSystemPromptOverride(pool, a, chat_id) orelse config.system_prompt;
        // Per-chat /thinking override, falling back to the dynamic_config-
        // or-env global default — see `store/chat_settings.zig`'s
        // `getShowThinkingOverride`.
        const show_thinking = chat_settings.getShowThinkingOverride(pool, chat_id) orelse dyn.show_thinking;
        // Prefers the full `Identity` the connector built from the
        // platform's own user object; falls back to the thinner
        // `iface.Message` fields for a platform/message that didn't
        // populate one (see `resolveSenderIdentity`'s same fallback).
        const asker: qa.Asker = if (msg.identity) |identity| .{
            .display_name = identity.display_name,
            .username = identity.username,
            .native_id = identity.native_id,
        } else .{
            .display_name = msg.username orelse msg.user_id,
            .username = msg.username,
            .native_id = msg.user_id,
        };
        const retention_messages = dynamic_config.getI64(pool, a, "WARDEN_RETENTION_MESSAGES", config.retention_messages);
        replyWithAnswer(connector, a, pool, chat_id, llm_provider, tool_ctx, tools, system_prompt, io, now, retention_messages, max_message_len, msg.chat_id, msg.message_id, asker, resolved.text, replied_to, resolved.placeholder_id, dyn.streaming, show_thinking, dyn.max_tokens_override, dyn.history_messages);
    }
    return false;
}

/// Strips a Telegram-style `@botusername` qualifier off the leading
/// `/command` token, so `/ping` and `/ping@warden_bot` dispatch
/// identically — the qualified form is how Telegram clients disambiguate
/// which bot a command is for once two or more bots share a chat, and every
/// bot in the chat receives the update regardless of which one it names.
/// Returns the original `text` unchanged when there's no qualifier, the
/// leading token isn't a command at all, or this connector doesn't know its
/// own username yet; returns `null` when the qualifier explicitly names a
/// *different* bot (this command isn't for us — the caller should bail out
/// entirely rather than fall through to the "unrecognized command" path,
/// so two Warden instances in one group don't both act on it); otherwise
/// returns a freshly allocated copy of `text` with the qualifier removed,
/// leaving any arguments after it intact. A `text` starting with a `/` but
/// with no matching qualifier reaching `allocator` (out of memory) falls
/// back to the original, unqualified-looking `text`, which simply won't
/// match any known command below — a safe degrade, not a crash.
/// Matrix (and most other chat clients) intercept a leading `/` as their
/// own client-side slash command before it ever reaches the bot — `/ping`
/// typed in Element never arrives as message text. `!` is accepted as an
/// equivalent command indicator everywhere (not just Matrix) for exactly
/// this reason: `!ping` dispatches identically to `/ping`, rewritten to a
/// leading `/` up front so every check below (and the rest of
/// `handleMessage`'s dispatch chain) only ever has to know about one
/// prefix.
fn normalizeCommandMention(allocator: std.mem.Allocator, text: []const u8, self_username: ?[]const u8) ?[]const u8 {
    const bang_rewritten = text.len > 0 and text[0] == '!';
    const slash_text: []const u8 = if (bang_rewritten)
        std.mem.concat(allocator, u8, &.{ "/", text[1..] }) catch text
    else
        text;

    if (slash_text.len == 0 or slash_text[0] != '/') return slash_text;
    const cmd_end = std.mem.indexOfScalar(u8, slash_text, ' ') orelse slash_text.len;
    const at = std.mem.indexOfScalar(u8, slash_text[0..cmd_end], '@') orelse return slash_text;
    const me = self_username orelse return slash_text;
    const target = slash_text[at + 1 .. cmd_end];
    if (!std.ascii.eqlIgnoreCase(target, me)) {
        if (bang_rewritten) allocator.free(slash_text);
        return null;
    }
    const stripped = std.mem.concat(allocator, u8, &.{ slash_text[0..at], slash_text[cmd_end..] }) catch slash_text;
    if (bang_rewritten and stripped.ptr != slash_text.ptr) allocator.free(slash_text);
    return stripped;
}

test "normalizeCommandMention strips a qualifier naming us, preserving trailing args" {
    const a = std.testing.allocator;
    const out = normalizeCommandMention(a, "/ping@warden_bot", "warden_bot").?;
    defer a.free(out);
    try std.testing.expectEqualStrings("/ping", out);

    const out2 = normalizeCommandMention(a, "/token@warden_bot 123 add", "warden_bot").?;
    defer a.free(out2);
    try std.testing.expectEqualStrings("/token 123 add", out2);
}

test "normalizeCommandMention matches the qualifier case-insensitively" {
    const a = std.testing.allocator;
    const out = normalizeCommandMention(a, "/ping@Warden_Bot", "warden_bot").?;
    defer a.free(out);
    try std.testing.expectEqualStrings("/ping", out);
}

test "normalizeCommandMention returns null for a qualifier naming a different bot" {
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeCommandMention(std.testing.allocator, "/ping@someotherbot", "warden_bot"));
}

test "normalizeCommandMention passes non-commands and unqualified commands through unchanged" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("", normalizeCommandMention(a, "", "warden_bot").?);
    try std.testing.expectEqualStrings("hello there", normalizeCommandMention(a, "hello there", "warden_bot").?);
    try std.testing.expectEqualStrings("/ping", normalizeCommandMention(a, "/ping", "warden_bot").?);
    // No known self-username yet (e.g. before the first getMe resolves) —
    // left as-is rather than guessed at.
    try std.testing.expectEqualStrings("/ping@warden_bot", normalizeCommandMention(a, "/ping@warden_bot", null).?);
}

test "normalizeCommandMention treats a leading '!' the same as '/'" {
    const a = std.testing.allocator;
    const out = normalizeCommandMention(a, "!ping", "warden_bot").?;
    defer a.free(out);
    try std.testing.expectEqualStrings("/ping", out);

    const out2 = normalizeCommandMention(a, "!remind 1m ping me", "warden_bot").?;
    defer a.free(out2);
    try std.testing.expectEqualStrings("/remind 1m ping me", out2);

    // Mention-qualifier stripping still works after the '!' rewrite.
    const out3 = normalizeCommandMention(a, "!ping@warden_bot", "warden_bot").?;
    defer a.free(out3);
    try std.testing.expectEqualStrings("/ping", out3);
}

/// True for the protected one-shot `/convert <format>` caption path (a
/// non-empty argument after "/convert ") — must be excluded from the
/// multi-stage flow's attachment-claim check so it keeps working exactly
/// as before.
fn isOneShotConvertCaption(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "/convert ")) return false;
    return std.mem.trim(u8, text["/convert ".len..], " ").len > 0;
}

/// A non-command message deserves a reply when it's a DM, mentions the bot,
/// replies to one of the bot's messages, or says the chat's configured
/// magic word (a per-chat setting; see /magicword).
fn isAddressedToBot(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) bool {
    if (!msg.is_group) return true;
    if (msg.mentions_me or msg.reply_to_is_me) return true;

    const magic = chat_settings.getMagicWord(pool, a, chat_id) orelse return false;
    return containsWordIgnoreCase(text, magic);
}

const magic_word_key = "magic_word";
const max_magic_word_len = 64;

fn handleMagicWord(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/magicword".len..], " ");

    if (arg.len == 0) {
        const reply_text = if (chat_settings.getMagicWord(pool, a, chat_id)) |word|
            std.fmt.allocPrint(a, "Magic word: \"{s}\" — say it in any message and I'll answer. You can also mention me or reply to my messages. Change it with /magicword <word>, disable with /magicword off.", .{word}) catch return
        else
            "No magic word set — mention me or reply to my messages to get an answer. Set one with /magicword <word>.";
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change the magic word.");
        return;
    }

    if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setMagicWord(pool, chat_id, null) catch |err| {
            log.err("magicword: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Magic word disabled — I'll still answer mentions and replies.");
        return;
    }

    if (arg.len > max_magic_word_len or std.mem.indexOfScalar(u8, arg, ' ') != null) {
        reply(connector, a, msg.chat_id, msg.message_id, "The magic word must be a single word (max 64 bytes).");
        return;
    }

    chat_settings.setMagicWord(pool, chat_id, arg) catch |err| {
        log.err("magicword: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    const confirmation = std.fmt.allocPrint(a, "Magic word set to \"{s}\" — I'll answer any message that contains it.", .{arg}) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

const max_persona_len = 4000;

/// Sets (or clears, or shows) this chat's own system-prompt override for
/// the LLM Q&A path — viewing is open to anyone (no secret involved, unlike
/// /scraper), but setting/clearing is owner-only, same precedent as
/// /magicword: a chat member rewriting the bot's entire personality is a
/// bigger lever than a magic word.
fn handlePersonaCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/persona".len..], " ");

    if (arg.len == 0) {
        const reply_text = if (chat_settings.getSystemPromptOverride(pool, a, chat_id)) |prompt|
            std.fmt.allocPrint(a, "This chat's persona:\n{s}\n\nChange it with /persona <text>, reset to the default with /persona off.", .{prompt}) catch return
        else
            "Using the default persona. Set a custom one for this chat with /persona <text>.";
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    // Viewing (above) stays available even when disabled -- matches the
    // reminders/alerts/watches list commands' own policy elsewhere in this
    // file (a module toggle blocks *creating*/*changing* things, not
    // looking at what's already there). Only the actual set/clear path
    // below is gated.
    if (!feature_flags.isEnabled(pool, "persona")) return;

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change this chat's persona.");
        return;
    }

    if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setSystemPromptOverride(pool, chat_id, null) catch |err| {
            log.err("persona: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Persona reset to the default.");
        return;
    }

    if (arg.len > max_persona_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That persona text is too long (max 4000 bytes).");
        return;
    }

    chat_settings.setSystemPromptOverride(pool, chat_id, arg) catch |err| {
        log.err("persona: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    reply(connector, a, msg.chat_id, msg.message_id, "Persona updated for this chat.");
}

/// Per-chat override for whether a reasoning model's chain-of-thought is
/// shown — same view-open-to-anyone/change-owner-only access model as
/// `/persona` (a chat member flipping this is a smaller lever than a full
/// persona rewrite, but still not something to leave open to anyone).
fn handleThinkingCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/thinking".len..], " ");

    if (arg.len == 0) {
        const override = chat_settings.getShowThinkingOverride(pool, chat_id);
        const effective = override orelse config.llm_show_thinking;
        const reply_text = if (override) |_|
            std.fmt.allocPrint(
                a,
                "Thinking is {s} for this chat (override). Change it with /thinking on, /thinking off, or /thinking default to follow the bot-wide setting.",
                .{if (effective) "shown" else "hidden"},
            ) catch return
        else
            std.fmt.allocPrint(
                a,
                "Thinking is {s} for this chat (bot-wide default). Override it with /thinking on or /thinking off.",
                .{if (effective) "shown" else "hidden"},
            ) catch return;
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change this chat's thinking setting.");
        return;
    }

    if (std.mem.eql(u8, arg, "on")) {
        chat_settings.setShowThinkingOverride(pool, chat_id, true) catch |err| {
            log.err("thinking: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Thinking will be shown for this chat.");
    } else if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setShowThinkingOverride(pool, chat_id, false) catch |err| {
            log.err("thinking: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Thinking will be hidden for this chat.");
    } else if (std.mem.eql(u8, arg, "default")) {
        chat_settings.setShowThinkingOverride(pool, chat_id, null) catch |err| {
            log.err("thinking: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Thinking reset to the bot-wide default for this chat.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /thinking [on|off|default]");
    }
}

/// Owner-only, unlike /magicword: the whole command (including viewing) is
/// gated in the dispatcher above, since the config here can include a
/// remote endpoint/API key that shouldn't be visible to random chat
/// members. Bot-wide, not per-chat — see `store/bot_config.zig`.
fn handleScraperCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/scraper".len..], " ");

    if (arg.len == 0) {
        const snap = bot_config.loadScraperConfig(pool, a);
        const remote_desc = snap.remote_url orelse "(not set)";
        const key_desc = if (snap.remote_api_key != null) "set" else "not set";
        const status = std.fmt.allocPrint(
            a,
            "Scraper mode: {s}\nRemote endpoint: {s}\nRemote API key: {s}\n\nUsage:\n/scraper mode local|remote\n/scraper url <endpoint>\n/scraper apikey <key>|off",
            .{ @tagName(snap.mode), remote_desc, key_desc },
        ) catch return;
        connector.sendMessage(a, msg.chat_id, status, msg.message_id);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();
    const rest = std.mem.trim(u8, it.rest(), " ");

    if (std.mem.eql(u8, sub, "mode")) {
        if (std.mem.eql(u8, rest, "remote")) {
            const snap = bot_config.loadScraperConfig(pool, a);
            if (snap.remote_url == null) {
                reply(connector, a, msg.chat_id, msg.message_id, "Set a remote endpoint first with /scraper url <endpoint>.");
                return;
            }
            bot_config.setScraperMode(pool, .remote) catch |err| {
                log.err("scraper: failed to set mode for global settings: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update the scraper mode, try again.");
                return;
            };
            const confirmation = std.fmt.allocPrint(a, "Scraper mode set to remote ({s}).", .{snap.remote_url.?}) catch return;
            connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        } else if (std.mem.eql(u8, rest, "local")) {
            bot_config.setScraperMode(pool, .local) catch |err| {
                log.err("scraper: failed to set mode for global settings: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update the scraper mode, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Scraper mode set to local (on-device extraction).");
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /scraper mode local|remote");
        }
    } else if (std.mem.eql(u8, sub, "url")) {
        if (rest.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /scraper url <endpoint>");
            return;
        }
        bot_config.setScraperRemoteUrl(pool, rest) catch |err| {
            log.err("scraper: failed to set remote url: {t}", .{err});
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that endpoint, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper endpoint saved. Switch to it with /scraper mode remote.");
    } else if (std.mem.eql(u8, sub, "apikey")) {
        if (rest.len == 0 or std.mem.eql(u8, rest, "off")) {
            bot_config.setScraperRemoteApiKey(pool, null) catch |err| {
                log.err("scraper: failed to clear remote api key: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't clear the API key, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper API key cleared.");
        } else {
            bot_config.setScraperRemoteApiKey(pool, rest) catch |err| {
                log.err("scraper: failed to set remote api key: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save the API key, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper API key saved.");
        }
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /scraper [mode local|remote] [url <endpoint>] [apikey <key>|off]");
    }
}

/// Splits an arg string like "5 @alice", "@alice 5", "@alice", or "5" into
/// its balance and `@username` pieces, order-independent — a lone numeric
/// token is the balance, a lone `@`-prefixed token is the username, and
/// either may be absent. Shared by `/token` and `/credit`, whose arg shape
/// is identical (`<balance> [@username]`, either order).
fn parseBalanceAndUsernameArgs(arg: []const u8) struct { balance_str: []const u8, username_arg: []const u8 } {
    var balance_str: []const u8 = "";
    var username_arg: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '@') {
            username_arg = tok;
        } else if (balance_str.len == 0) {
            balance_str = tok;
        }
    }
    return .{ .balance_str = balance_str, .username_arg = username_arg };
}

/// Resolves a command's target identity, in order: a reply to the target's
/// message; failing that, an `@username` argument (`identities.
/// findByUsername` — exact-match, platform-scoped); failing that, a bare
/// argument treated as the target's raw platform-native id (Telegram's
/// numeric id, Matrix's `@user:server`, an XMPP JID, ...) — the same string
/// `Message.user_id`/`reply_to_user_id` carry, for when the bot has no
/// `@username` to go on (or the target has none at all).
///
/// `create_if_missing` controls what happens when the raw-id branch finds no
/// existing row: `true` (every mutating call site below) creates a minimal
/// placeholder via `getOrCreateMinimal`, same as the reply-target branch
/// already does — a raw id is, unlike a username, always enough on its own
/// to address that platform user, so there's nothing to "wait and see" for.
/// `false` (read-only lookups, e.g. `/whois`) uses `findByNativeId` instead,
/// which never creates a row — fabricating one just to answer an info
/// command about someone the bot has genuinely never seen would be a
/// surprising side effect. The `@username` branch is never create-on-miss
/// either way, since a username alone doesn't carry a native id to create
/// the row with.
///
/// `null` when nothing is present/resolvable. Shared by `/token`, `/credit`,
/// `/adduser`, `/removeuser`, `/addadmin`, `/removeadmin`, `/kick`, `/ban`,
/// `/whois`.
fn resolveTargetIdentity(pool: *store_pool.PgPool, connector: iface.Connector, a: std.mem.Allocator, now: i64, msg: iface.Message, target_arg: []const u8, create_if_missing: bool) !?identities.IdentityRef {
    if (replyTarget(msg)) |target| {
        // `msg.reply_to_username` (not `target.label`, which already
        // substituted the raw user id when no username is known) — passing
        // the raw, possibly-null value through lets `getOrCreateMinimal`
        // persist/backfill the real username so a later `@username` lookup
        // for this same person can actually find them.
        const id = try identities.getOrCreateMinimal(pool, connector.platform(), target.user_id, target.label, msg.reply_to_username, false, now);
        return .{ .id = id, .display_name = target.label, .native_id = target.user_id };
    }
    if (target_arg.len > 1 and target_arg[0] == '@') {
        return identities.findByUsername(pool, a, connector.platform(), target_arg[1..]);
    }
    if (target_arg.len > 0) {
        if (create_if_missing) {
            const id = try identities.getOrCreateMinimal(pool, connector.platform(), target_arg, target_arg, null, false, now);
            return .{ .id = id, .display_name = target_arg, .native_id = target_arg };
        }
        return identities.findByNativeId(pool, a, connector.platform(), target_arg);
    }
    return null;
}

fn handleToken(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    now: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/token".len..], " ");
    const parsed = parseBalanceAndUsernameArgs(arg);

    const target = (resolveTargetIdentity(pool, connector, a, now, msg, parsed.username_arg, true) catch |err| {
        log.err("token: failed to resolve target: {t}", .{err});
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username) you want to view/change tokens for.");
        return;
    };
    // If there is no balance argument, get the current token count and reply with it.
    if (parsed.balance_str.len == 0) {
        const count = chat_members.getTokens(pool, chat_id, target.id, 0);
        const message = std.fmt.allocPrint(a, "Current token count: {}", .{count}) catch |err| {
            log.err("token: failed to allocate message string: {t}", .{err});
            return; // Exit the function early since we couldn't format the message
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    // Else set the token count to the parsed value and reply with a confirmation.
    const count = std.fmt.parseInt(i64, parsed.balance_str, 10) catch 0;
    log.debug("token: parsed count {d}", .{count});
    chat_members.setTokens(pool, chat_id, target.id, count) catch |err| {
        log.err("token: failed to set tokens: {t}", .{err});
        return;
    };
    const message = std.fmt.allocPrint(a, "token count updated to {}", .{count}) catch |err| {
        log.err("token: failed to allocate message string: {t}", .{err});
        return; // Exit the function early since we couldn't format the message
    };
    connector.sendMessage(a, msg.chat_id, message, msg.message_id);
}

/// `/credit` — same shape as `/token` (reply-or-`@username` targeting,
/// `<balance> [@username]` argument order), but backed by
/// `identities.getCredits`/`setCredits` (global per-identity) instead of
/// `chat_members`'s per-chat tokens. Gate (`auth.isOwnerOrBotAdmin`) is
/// checked by the caller.
fn handleCredit(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    now: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/credit".len..], " ");
    const parsed = parseBalanceAndUsernameArgs(arg);

    const target = (resolveTargetIdentity(pool, connector, a, now, msg, parsed.username_arg, true) catch |err| {
        log.err("credit: failed to resolve target: {t}", .{err});
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username) you want to view/change credits for.");
        return;
    };
    if (parsed.balance_str.len == 0) {
        const count = identities.getCredits(pool, target.id, 0);
        const message = std.fmt.allocPrint(a, "Current credit count: {}", .{count}) catch |err| {
            log.err("credit: failed to allocate message string: {t}", .{err});
            return;
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    const count = std.fmt.parseInt(i64, parsed.balance_str, 10) catch 0;
    identities.setCredits(pool, target.id, count) catch |err| {
        log.err("credit: failed to set credits: {t}", .{err});
        return;
    };
    const message = std.fmt.allocPrint(a, "credit count updated to {}", .{count}) catch |err| {
        log.err("credit: failed to allocate message string: {t}", .{err});
        return;
    };
    connector.sendMessage(a, msg.chat_id, message, msg.message_id);
}

/// The six bot-management commands (`/adduser /removeuser /allowchat
/// /disallowchat /addadmin /removeadmin`) share this shape: resolve a
/// target identity (reply-or-`@username`), call one store mutation, reply
/// with a plain confirmation. Gate (`auth.isOwnerOrBotAdmin`) is checked by
/// the caller in every case; `granted_by`/`added_by` is always the acting
/// identity (`identity_id`, already resolved by `processMessageTask` before
/// `handleMessage` runs).
/// A bare `@username` argument (not a reply) — used as the fallback path
/// when `resolveTargetIdentity` can't find an existing identity for that
/// username, to queue (or cancel) a pending grant instead of just failing.
/// `null` for a reply-based call (no separate username argument to queue)
/// or an empty/non-`@` argument.
fn usernameFromArg(arg: []const u8) ?[]const u8 {
    if (arg.len > 1 and arg[0] == '@') return arg[1..];
    return null;
}

/// `/kick`/`/ban [@username | user_id]` — same reply-or-`@username`-or-raw-id
/// targeting as `/adduser`/`/addadmin` (via `resolveTargetIdentity`), which
/// `group_admin.zig`'s `requestConfirmation` never had: it only ever
/// resolved a reply, so `/kick @spammer`/`/kick 123456789` silently matched
/// no dispatch branch at all (see the exact-`eql` match this replaced).
/// Permission is already checked by the caller before this runs.
fn handleKickBanCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8, comptime prefix: []const u8, kind: group_admin.ActionKind) void {
    const arg = std.mem.trim(u8, text[prefix.len..], " ");
    const target = (resolveTargetIdentity(pool, connector, a, now, msg, arg, true) catch |err| {
        log.err("{s}: failed to resolve target: {t}", .{ @tagName(kind), err });
        return;
    }) orelse {
        const message = std.fmt.allocPrint(a, "Reply to the message of the person you want to {s} (or pass @username or their user id).", .{@tagName(kind)}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    };
    group_admin.requestConfirmation(connector, a, msg, kind, target.native_id);
}

fn handleAddUserCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/adduser".len..], " ");
    if (resolveTargetIdentity(pool, connector, a, now, msg, arg, true) catch |err| {
        log.err("adduser: failed to resolve target: {t}", .{err});
        return;
    }) |target| {
        bot_allowlist.addAllowedUser(pool, target.id, identity_id) catch |err| {
            log.err("adduser: failed to add: {t}", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "{s} can now use this bot.", .{target.display_name}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    // Not a reply, and no identity exists yet for this @username (the bot
    // has never seen a message from them) — queue the grant instead of
    // failing; it completes automatically the moment they do message (see
    // `resolveSenderIdentity`/`completePendingGrants`).
    if (usernameFromArg(arg)) |username| {
        bot_pending_grants.addPending(pool, connector.platform(), username, .allowed_user, identity_id) catch |err| {
            log.err("adduser: failed to queue pending grant for @{s}: {t}", .{ username, err });
            return;
        };
        const message = std.fmt.allocPrint(a, "@{s} isn't known to me yet -- they'll be allowed automatically as soon as they message me.", .{username}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username or their user id) you want to allow.");
}

fn handleRemoveUserCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/removeuser".len..], " ");
    if (resolveTargetIdentity(pool, connector, a, now, msg, arg, true) catch |err| {
        log.err("removeuser: failed to resolve target: {t}", .{err});
        return;
    }) |target| {
        bot_allowlist.removeAllowedUser(pool, target.id) catch |err| {
            log.err("removeuser: failed to remove: {t}", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "{s} can no longer use this bot (unless their chat is allowed).", .{target.display_name}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    // No resolvable identity — the only thing left to undo is a pending
    // (not yet completed) grant queued by an earlier /adduser @username.
    if (usernameFromArg(arg)) |username| {
        bot_pending_grants.removePending(pool, connector.platform(), username, .allowed_user) catch |err| {
            log.err("removeuser: failed to cancel pending grant for @{s}: {t}", .{ username, err });
            return;
        };
        const message = std.fmt.allocPrint(a, "@{s} won't be allowed automatically anymore.", .{username}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username or their user id) you want to remove.");
}

fn handleAllowChatCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, msg: iface.Message) void {
    bot_allowlist.addAllowedChat(pool, chat_id, identity_id) catch |err| {
        log.err("allowchat: failed to add: {t}", .{err});
        return;
    };
    connector.sendMessage(a, msg.chat_id, "This chat is now allowed to use the bot.", msg.message_id);
}

fn handleDisallowChatCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message) void {
    bot_allowlist.removeAllowedChat(pool, chat_id) catch |err| {
        log.err("disallowchat: failed to remove: {t}", .{err});
        return;
    };
    connector.sendMessage(a, msg.chat_id, "This chat can no longer use the bot (unless individually-allowed users remain).", msg.message_id);
}

fn handleAddAdminCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/addadmin".len..], " ");
    if (resolveTargetIdentity(pool, connector, a, now, msg, arg, true) catch |err| {
        log.err("addadmin: failed to resolve target: {t}", .{err});
        return;
    }) |target| {
        bot_admins.addBotAdmin(pool, target.id, identity_id) catch |err| {
            log.err("addadmin: failed to add: {t}", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "{s} is now a bot admin.", .{target.display_name}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    if (usernameFromArg(arg)) |username| {
        bot_pending_grants.addPending(pool, connector.platform(), username, .bot_admin, identity_id) catch |err| {
            log.err("addadmin: failed to queue pending grant for @{s}: {t}", .{ username, err });
            return;
        };
        const message = std.fmt.allocPrint(a, "@{s} isn't known to me yet -- they'll become a bot admin automatically as soon as they message me.", .{username}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username or their user id) you want to make a bot admin.");
}

fn handleRemoveAdminCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/removeadmin".len..], " ");
    if (resolveTargetIdentity(pool, connector, a, now, msg, arg, true) catch |err| {
        log.err("removeadmin: failed to resolve target: {t}", .{err});
        return;
    }) |target| {
        bot_admins.removeBotAdmin(pool, target.id) catch |err| {
            log.err("removeadmin: failed to remove: {t}", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "{s} is no longer a bot admin.", .{target.display_name}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    if (usernameFromArg(arg)) |username| {
        bot_pending_grants.removePending(pool, connector.platform(), username, .bot_admin) catch |err| {
            log.err("removeadmin: failed to cancel pending grant for @{s}: {t}", .{ username, err });
            return;
        };
        const message = std.fmt.allocPrint(a, "@{s} won't become a bot admin automatically anymore.", .{username}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username or their user id) you want to remove as a bot admin.");
}

fn platformLabel(platform: iface.Platform) []const u8 {
    return switch (platform) {
        .telegram => "Telegram",
        .matrix => "Matrix",
        .xmpp => "XMPP",
        .discord => "Discord",
        .whatsapp => "WhatsApp",
    };
}

/// `/whois [@username | user_id]` (or reply) — looks a known identity up and
/// reports every field `identities` tracks about it, including the two
/// derived-not-stored trust flags (`bot admin`, `superuser`) so this doubles
/// as a way to sanity-check the access-control state described in the
/// README's "Access control" section. Gated owner-or-bot-admin, same tier as
/// `/adduser`/`/addadmin` (see the caller in `handleMessage`).
///
/// Uses `resolveTargetIdentity`'s `create_if_missing = false` path for a
/// bare-id argument — unlike `/kick`/`/adduser`/etc., this is a read-only
/// info command, so a native id the bot has genuinely never seen should
/// report "no record" rather than fabricate a placeholder row just to
/// answer the lookup.
fn handleWhoisCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/whois".len..], " ");
    const target = (resolveTargetIdentity(pool, connector, a, now, msg, arg, false) catch |err| {
        log.err("whois: failed to resolve target: {t}", .{err});
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to a user, or pass @username or their user id, to look them up.");
        return;
    };
    const info = (identities.getWhoisInfo(pool, a, target.id) catch |err| {
        log.err("whois: failed to load identity {d}: {t}", .{ target.id, err });
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "I don't have any record of that user.");
        return;
    };
    // Superuser is always the highest privilege there is and isn't stored in
    // `bot_admins` at all (see the `is_bot_admin` fix in `handleMessage`) —
    // computed the same way here, straight from `config.owners`.
    const is_superuser = auth.isOwner(config, info.platform, info.native_id);
    const is_admin = is_superuser or bot_admins.isBotAdmin(pool, target.id);
    const message = std.fmt.allocPrint(a,
        \\Full name: {s}
        \\Username: {s}
        \\{s} ID: {s}
        \\Is bot: {s}
        \\Is bot admin: {s}
        \\Is superuser: {s}
    , .{
        info.display_name,
        if (info.username) |u| u else "(none)",
        platformLabel(info.platform),
        info.native_id,
        if (info.is_bot) "yes" else "no",
        if (is_admin) "yes" else "no",
        if (is_superuser) "yes" else "no",
    }) catch return;
    connector.sendMessage(a, msg.chat_id, message, msg.message_id);
}

/// `/redact` — parses which of the five modes (see `features/redact.zig`'s
/// doc comments) applies, gates per-mode (regex is stricter — bot-admin/
/// owner only, via `/sudo` if not otherwise a bot admin — than the other
/// four, which use the same platform-admin-or-higher ladder as `/kick` et
/// al., minus the token fallback: bulk deletion isn't something a token
/// alone should unlock), then dispatches into `features/redact.zig`. Does
/// its own gating internally (like `handleMagicWord`/`handlePersonaCommand`)
/// rather than a single gate at the dispatch call site, since which gate
/// applies depends on the parsed mode.
fn handleRedactCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    now: i64,
    msg: iface.Message,
    text: []const u8,
    sudo_active: bool,
) void {
    if (!feature_flags.isEnabled(pool, "group_admin")) return;

    const arg = std.mem.trim(u8, text["/redact".len..], " ");

    if (std.mem.startsWith(u8, arg, "regex ")) {
        if (!auth.isOwnerOrSudoBotAdmin(config, connector.platform(), msg.user_id, sudo_active)) return;
        const pattern = std.mem.trim(u8, arg["regex ".len..], " ");
        redact_feature.redactRegex(connector, a, pool, chat_id, msg, pattern);
        return;
    }

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "redact")) return;

    if (std.mem.startsWith(u8, arg, "text ")) {
        const substring = std.mem.trim(u8, arg["text ".len..], " ");
        redact_feature.redactText(connector, a, pool, chat_id, msg, substring);
        return;
    }

    if (replyTarget(msg)) |target| {
        const target_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), target.user_id, target.label, msg.reply_to_username, false, now) catch |err| {
            log.err("redact: failed to resolve target: {t}", .{err});
            return;
        };
        const n = std.fmt.parseInt(i64, arg, 10) catch 0;
        redact_feature.redactUserLastN(connector, a, pool, chat_id, msg, target_identity_id, n);
        return;
    }

    const n = std.fmt.parseInt(i64, arg, 10) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /redact <N> | (reply) /redact [N] | /redact text <substring> | /redact regex <pattern>");
        return;
    };
    redact_feature.redactLastN(connector, a, pool, chat_id, msg, n);
}

fn handleDigestCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    digest_scheduler: *scheduler.DigestScheduler,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    now: i64,
    max_message_len: usize,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/digest".len..], " ");

    if (std.mem.eql(u8, arg, "on")) {
        digest_scheduler.enable(connector.platform(), native_chat_id) catch |err| {
            log.err("digest: failed to enable for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't enable digests, try again.", reply_to);
            return;
        };
        chat_settings.setDigestEnabled(pool, chat_id, true) catch |err| {
            log.err("digest: failed to persist enabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        const hours = @divTrunc(digest_scheduler.interval_seconds, 3600);
        const msg_text = std.fmt.allocPrint(a, "Digest enabled — I'll post one roughly every {d}h.", .{hours}) catch return;
        connector.sendMessage(a, native_chat_id, msg_text, reply_to);
    } else if (std.mem.eql(u8, arg, "off")) {
        digest_scheduler.disable(a, connector.platform(), native_chat_id);
        chat_settings.setDigestEnabled(pool, chat_id, false) catch |err| {
            log.err("digest: failed to persist disabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        connector.sendMessage(a, native_chat_id, "Digest disabled.", reply_to);
    } else if (std.mem.eql(u8, arg, "now")) {
        const digest_text = digest.generate(llm_provider, a, tool_ctx, pool, chat_id) catch |err| {
            log.err("digest: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't generate a digest just now.", reply_to);
            return;
        };
        sendTextOrFile(connector, a, native_chat_id, digest_text, reply_to, max_message_len, "digest.txt");
        chat_settings.setLastDigestTs(pool, chat_id, now) catch |err| {
            log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ native_chat_id, err });
        };
    } else {
        const enabled = digest_scheduler.isEnabled(a, connector.platform(), native_chat_id);
        const last = chat_settings.getLastDigestTs(pool, chat_id);
        const msg_text = if (last == 0)
            std.fmt.allocPrint(
                a,
                "Digest is {s}. Never sent yet. Use /digest on, /digest off, or /digest now.",
                .{if (enabled) "on" else "off"},
            ) catch return
        else
            std.fmt.allocPrint(
                a,
                "Digest is {s}. Last sent {d}s ago. Use /digest on, /digest off, or /digest now.",
                .{ if (enabled) "on" else "off", now - last },
            ) catch return;
        connector.sendMessage(a, native_chat_id, msg_text, reply_to);
    }
}

const max_reminder_message_len = 500;

/// `/remind <duration|clock-time> <message>` sets a one-off reminder;
/// `/remind every <interval> <message>` sets a recurring one; `/remind
/// cancel <id>` cancels one. Open to anyone in the chat to create
/// (utility-level, like /wordcloud), but only its own creator or the bot
/// owner may cancel it — matches `/token`'s reply-to-target pattern of
/// trusting the sender's own identity_id rather than requiring group-admin
/// standing.
fn handleRemindCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    now: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const usage = "Usage: /remind <duration e.g. 30m/2h/1d, a clock time like 14:30, or a date like 5/22 14:30> <message>, /remind every <interval> <message>, or /remind cancel <id>";
    const arg = std.mem.trim(u8, text["/remind".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const first_word = it.first();

    if (std.mem.eql(u8, first_word, "cancel")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /remind cancel <id> (see /reminders for ids).");
            return;
        };
        const rem = (reminders.get(pool, a, id) catch |err| {
            log.err("remind: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that reminder, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No pending reminder with that id.");
            return;
        };
        if (rem.chat_id != chat_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "No pending reminder with that id.");
            return;
        }
        if (rem.identity_id != identity_id and !auth.isOwner(config, connector.platform(), msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever set that reminder (or the owner) can cancel it.");
            return;
        }
        reminders.cancel(pool, id) catch |err| {
            log.err("remind: cancel failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't cancel that reminder, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Reminder canceled.");
        return;
    }

    var recur_interval: ?i64 = null;
    var when_str = first_word;
    if (std.mem.eql(u8, first_word, "every")) {
        when_str = it.next() orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /remind every <interval e.g. 1d> <message>");
            return;
        };
        recur_interval = reminder_format.parseDuration(when_str) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that interval — use e.g. 30m, 2h, or 1d.");
            return;
        };
    }

    const message = std.mem.trim(u8, it.rest(), " ");
    if (message.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    if (message.len > max_reminder_message_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That reminder text is too long (max 500 bytes).");
        return;
    }

    const offset_minutes = user_settings.getEffectiveOffsetMinutes(pool, a, identity_id);
    const date_format = user_settings.getEffectiveDateFormat(pool, a, identity_id);
    const time_format = user_settings.getEffectiveTimeFormat(pool, a, identity_id);

    const due_at = if (recur_interval) |interval|
        now + interval
    else
        reminder_format.parseWhenLocal(when_str, now, offset_minutes, date_format) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that time — use a duration like 30m/2h/1d, a clock time like 14:30, or a date like 5/22 14:30.");
            return;
        };

    const id = reminders.create(pool, chat_id, identity_id, message, due_at, recur_interval) catch |err| {
        log.err("remind: failed to create reminder for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that reminder, try again.");
        return;
    };

    const local = civil_time.localFromUnix(due_at, offset_minutes);
    const date_str = civil_time.formatDate(a, local, date_format);
    const time_str = civil_time.formatTime(a, local, time_format);

    const confirmation = if (recur_interval) |interval|
        std.fmt.allocPrint(a, "Reminder #{d} set, repeating every {s} (next at {s} {s}).", .{ id, reminder_format.formatInterval(a, interval), date_str, time_str }) catch return
    else if (reminder_format.parseDuration(when_str) != null)
        std.fmt.allocPrint(a, "Reminder #{d} set for {s} from now ({s} {s}).", .{ id, when_str, date_str, time_str }) catch return
    else
        std.fmt.allocPrint(a, "Reminder #{d} set for {s} {s}.", .{ id, date_str, time_str }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn handleRemindersList(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    now: i64,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const pending = reminders.listPending(pool, a, chat_id) catch |err| {
        log.err("reminders: list failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't load reminders, try again.", reply_to);
        return;
    };
    connector.sendMessage(a, native_chat_id, formatPendingReminders(a, pool, pending, now), reply_to);
}

/// `/alert <crypto|weather|aqi> <subject> <above|below> <threshold>` sets a
/// standing alert; `/alert cancel <id>` cancels one. Subject may contain
/// spaces (city names) — everything between the kind and the trailing
/// `<above|below> <threshold>` pair is joined back together. Same
/// open-to-create/creator-or-owner-to-cancel authorization as `/remind`.
fn handleAlertCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const usage = "Usage: /alert <crypto|weather|aqi> <subject> <above|below> <threshold>, or /alert cancel <id>";
    const arg = std.mem.trim(u8, text["/alert".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const first_word = it.first();

    if (std.mem.eql(u8, first_word, "cancel")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /alert cancel <id> (see /alerts for ids).");
            return;
        };
        const al = (alert_store.get(pool, a, id) catch |err| {
            log.err("alert: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that alert, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No alert with that id.");
            return;
        };
        if (al.chat_id != chat_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "No alert with that id.");
            return;
        }
        if (al.identity_id != identity_id and !auth.isOwner(config, connector.platform(), msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever set that alert (or the owner) can cancel it.");
            return;
        }
        alert_store.cancel(pool, id) catch |err| {
            log.err("alert: cancel failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't cancel that alert, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Alert canceled.");
        return;
    }

    const kind_str = first_word;
    const kind = std.meta.stringToEnum(alert_store.Kind, kind_str) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Unknown kind — use crypto, weather, or aqi.");
        return;
    };

    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(a);
    while (it.next()) |tok| {
        if (tok.len > 0) tokens.append(a, tok) catch return;
    }
    if (tokens.items.len < 3) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    const threshold_str = tokens.items[tokens.items.len - 1];
    const condition_str = tokens.items[tokens.items.len - 2];
    const subject = std.mem.join(a, " ", tokens.items[0 .. tokens.items.len - 2]) catch return;

    const condition = std.meta.stringToEnum(alert_store.Condition, condition_str) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Unknown condition — use above or below.");
        return;
    };
    const threshold = std.fmt.parseFloat(f64, threshold_str) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that threshold — it should be a plain number.");
        return;
    };

    const currency: ?[]const u8 = if (kind == .crypto) "usd" else null;
    const id = alert_store.create(pool, chat_id, identity_id, kind, subject, currency, condition, threshold) catch |err| {
        log.err("alert: failed to create alert for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that alert, try again.");
        return;
    };
    const unit = if (kind == .crypto) "usd" else if (kind == .weather) "°C" else "AQI";
    const confirmation = std.fmt.allocPrint(a, "Alert #{d} set: notify when {s} is {s} {d} {s}.", .{ id, subject, condition_str, threshold, unit }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn handleAlertsList(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const pending = alert_store.listPending(pool, a, chat_id) catch |err| {
        log.err("alerts: list failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't load alerts, try again.", reply_to);
        return;
    };
    connector.sendMessage(a, native_chat_id, formatPendingAlerts(a, pending), reply_to);
}

/// `/watch <feed_url>` adds an RSS/Atom watch for this chat. Open to
/// anyone in the chat, same as `/digest on|off` — not restricted to
/// whoever added it (see `store/feed_watches.zig`'s doc comment on why
/// `/unwatch` works the same way).
fn handleWatchCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const feed_url = std.mem.trim(u8, text["/watch".len..], " ");
    if (feed_url.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /watch <feed url>");
        return;
    }
    if (!std.mem.startsWith(u8, feed_url, "http://") and !std.mem.startsWith(u8, feed_url, "https://")) {
        // Found live 2026-07-21: typo'd input meant for `/unwatch` (e.g.
        // "/watch cancel 1") got stored verbatim as a feed_url and
        // fetch-failed on every poll tick forever — see
        // feed_watches.bumpLastChecked's doc comment for the other half of
        // this fix. Reject obviously-not-a-URL input before it ever reaches
        // the DB instead of relying on the watcher loop to survive garbage.
        reply(connector, a, msg.chat_id, msg.message_id, "That doesn't look like a feed URL. Usage: /watch <feed url> (to stop watching, use /unwatch <feed url>)");
        return;
    }
    const created = feed_watches.create(pool, chat_id, identity_id, feed_url) catch |err| {
        log.err("watch: failed to add feed {s} for chat {d}: {t}", .{ feed_url, chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't add that watch, try again.");
        return;
    };
    if (created) {
        reply(connector, a, msg.chat_id, msg.message_id, "Watching — I'll post here when something new shows up.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Already watching that feed in this chat.");
    }
}

fn handleUnwatchCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const feed_url = std.mem.trim(u8, text["/unwatch".len..], " ");
    if (feed_url.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /unwatch <feed url>");
        return;
    }
    const removed = feed_watches.remove(pool, chat_id, feed_url) catch |err| {
        log.err("unwatch: failed to remove feed {s} for chat {d}: {t}", .{ feed_url, chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't remove that watch, try again.");
        return;
    };
    if (removed) {
        reply(connector, a, msg.chat_id, msg.message_id, "Unwatched.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Wasn't watching that feed in this chat.");
    }
}

fn handleWatchesList(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const pending = feed_watches.listPending(pool, a, chat_id) catch |err| {
        log.err("watches: list failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't load watches, try again.", reply_to);
        return;
    };
    if (pending.len == 0) {
        connector.sendMessage(a, native_chat_id, "No feeds watched. Add one with /watch <feed url>.", reply_to);
        return;
    }
    var buf: std.Io.Writer.Allocating = .init(a);
    buf.writer.print("Watched feeds:\n", .{}) catch {};
    for (pending) |fw| buf.writer.print("  #{d} {s}\n", .{ fw.id, fw.feed_url }) catch {};
    connector.sendMessage(a, native_chat_id, buf.writer.buffered(), reply_to);
}

/// Forces an immediate check of one watch already set up in this chat,
/// bypassing its `check_interval_seconds` wait — for testing/debugging a
/// watch that doesn't seem to be firing, without needing DB or log access.
/// Runs the exact same fetch/parse/dedupe/notify pipeline
/// `checkAndNotifyFeeds`'s scheduled loop uses (`feed_watcher.checkNow`,
/// sharing `checkOne` with it) — if there genuinely are new items, this
/// posts the real notification, same as an automatic check would. Either
/// way, replies with a summary of what happened, since "0 new items" and
/// "the feed didn't parse as RSS/Atom at all" would otherwise look
/// identical from outside (see `feed_watcher.zig`'s `CheckOutcome` doc
/// comment — this is the tool for telling those apart without grepping
/// logs).
fn handleWatchCheckCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    io: Io,
    llm_provider: llm.Provider,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
    now: i64,
) void {
    const feed_url = std.mem.trim(u8, text["/watchcheck".len..], " ");
    if (feed_url.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /watchcheck <feed url>");
        return;
    }
    // A single-element connector list is enough here (unlike the scheduled
    // batch loop, which needs every connector since it's checking watches
    // across every chat/platform at once): this command always runs from
    // within the exact chat the watch belongs to, so `fw.platform` can
    // only ever match `connector`'s own platform.
    const outcome = feed_watcher.checkNow(&.{connector}, a, io, pool, llm_provider, chat_id, feed_url, now) catch |err| {
        log.err("watchcheck: failed for {s} in chat {d}: {t}", .{ feed_url, chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't run that check, try again.");
        return;
    };
    const result = outcome orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Not watching that feed in this chat — add it first with /watch <feed url>.");
        return;
    };
    const summary = switch (result) {
        .baseline_recorded => |n| std.fmt.allocPrint(a, "Checked — this was the first-ever check, so it just recorded {d} item(s) as the baseline (nothing announced, same as when /watch first adds a feed).", .{n}) catch "Checked — recorded the baseline.",
        .no_new_items => "Checked — fetched and parsed fine, no new items since the last check.",
        .notified => |n| std.fmt.allocPrint(a, "Checked — found {d} new item(s) and posted the notification.", .{n}) catch "Checked — found new items and posted the notification.",
        .unrecognized_feed_shape => "Checked — the fetch succeeded, but the response doesn't look like RSS or Atom (no <item>/<entry> tags found). The URL might be wrong, or serving something other than a real feed.",
        .fetch_failed => |err| std.fmt.allocPrint(a, "Fetch failed: {t}", .{err}) catch "Fetch failed.",
        .parse_failed => |err| std.fmt.allocPrint(a, "Parse failed: {t}", .{err}) catch "Parse failed.",
        .no_connector_for_platform => "No active connector for this chat's platform right now.",
    };
    connector.sendMessage(a, msg.chat_id, summary, msg.message_id);
}

/// Direct entry point to `convert_file` (see `tools/convert_file.zig`) for
/// people who'd rather type an explicit command than phrase a request in
/// natural language — same file (`tool_ctx.attachment_path`, downloaded by
/// `processMessageTask` before `handleMessage` ever runs) and same
/// conversion logic, just skipping the LLM round trip. `text` is the
/// caption Telegram delivered on the attached photo/document/voice/audio/
/// video, e.g. "/convert pdf".
fn handleConvertCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    tool_ctx: tool_registry.ToolContext,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/convert".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: send a photo, document, voice note, audio, or video with \"/convert <format>\" as its caption, e.g. /convert pdf.");
        return;
    }

    const placeholder_id = connector.sendMessageReturningId(a, msg.chat_id, "🔄 Converting your file…", msg.message_id) catch |err| blk: {
        log.warn("convert: couldn't send a placeholder for chat {s}: {t}", .{ msg.chat_id, err });
        break :blk null;
    };

    const input_json = std.json.Stringify.valueAlloc(a, .{ .target_format = arg }, .{}) catch return;
    const result = convert_file.tool.execute(tool_ctx, input_json) catch |err| {
        log.err("convert: /convert command failed: {t}", .{err});
        convert_flow.finalizePlaceholder(connector, a, msg.chat_id, placeholder_id, msg.message_id, "Something went wrong converting that file, try again.");
        return;
    };
    convert_flow.finalizePlaceholder(connector, a, msg.chat_id, placeholder_id, msg.message_id, result);
}

/// Shared by `/reminders` and the `set_reminder` LLM tool's `action=list`.
/// Renders each reminder's absolute due moment in *its own setter's*
/// timezone/format (`store/user_settings.zig`), not the viewer's — a chat's
/// pending reminders can belong to several people, and each one set their
/// own "14:30" meaning their own local 14:30.
fn formatPendingReminders(a: std.mem.Allocator, pool: *store_pool.PgPool, pending: []const reminders.PendingReminder, now: i64) []const u8 {
    if (pending.len == 0) return "No pending reminders. Set one with /remind <duration, clock time, or date> <message> (or just ask).";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Pending reminders:\n", .{}) catch return "";
    for (pending) |r| {
        const offset_minutes = user_settings.getEffectiveOffsetMinutes(pool, a, r.identity_id);
        const date_format = user_settings.getEffectiveDateFormat(pool, a, r.identity_id);
        const time_format = user_settings.getEffectiveTimeFormat(pool, a, r.identity_id);
        const local = civil_time.localFromUnix(r.due_at, offset_minutes);
        const date_str = civil_time.formatDate(a, local, date_format);
        const time_str = civil_time.formatTime(a, local, time_format);
        if (r.recur_interval_seconds) |interval| {
            w.print("  #{d} in {s} ({s} {s}, repeats every {s}): {s}\n", .{ r.id, reminder_format.formatRemaining(a, r.due_at - now), date_str, time_str, reminder_format.formatInterval(a, interval), r.message }) catch return "";
        } else {
            w.print("  #{d} in {s} ({s} {s}): {s}\n", .{ r.id, reminder_format.formatRemaining(a, r.due_at - now), date_str, time_str, r.message }) catch return "";
        }
    }
    return buf.writer.buffered();
}

/// Wires the `set_reminder` LLM tool (see `tools/remind.zig`) to real
/// Postgres-backed reminders for one specific message's chat/sender —
/// constructed fresh per message in `processMessageTask` since `chat_id`/
/// `identity_id`/`is_owner` all vary per sender, then handed to the tool
/// loop as a `registry.ReminderSink`.
const ReminderToolAdapter = struct {
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    is_owner: bool,
    now: i64,

    fn sink(self: *ReminderToolAdapter) tool_registry.ReminderSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.ReminderSink.VTable = .{
        .create = createFn,
        .cancel = cancelFn,
        .listPending = listPendingFn,
    };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) anyerror!i64 {
        const self: *ReminderToolAdapter = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return reminders.create(self.pool, self.chat_id, self.identity_id, message, due_at, recur_interval_seconds);
    }

    fn cancelFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!tool_registry.ReminderSink.CancelResult {
        const self: *ReminderToolAdapter = @ptrCast(@alignCast(ptr));
        const rem = (try reminders.get(self.pool, allocator, id)) orelse return .not_found;
        if (rem.chat_id != self.chat_id) return .not_found;
        if (rem.identity_id != self.identity_id and !self.is_owner) return .not_authorized;
        try reminders.cancel(self.pool, id);
        return .canceled;
    }

    fn listPendingFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *ReminderToolAdapter = @ptrCast(@alignCast(ptr));
        const pending = try reminders.listPending(self.pool, allocator, self.chat_id);
        return formatPendingReminders(allocator, self.pool, pending, self.now);
    }
};

/// Wires the `set_alert` LLM tool (see `tools/set_alert.zig`) to real
/// Postgres-backed alerts — same shape/reasoning as `ReminderToolAdapter`.
const AlertToolAdapter = struct {
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    is_owner: bool,

    fn sink(self: *AlertToolAdapter) tool_registry.AlertSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.AlertSink.VTable = .{
        .create = createFn,
        .cancel = cancelFn,
        .listPending = listPendingFn,
    };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, kind: []const u8, subject: []const u8, currency: ?[]const u8, condition: []const u8, threshold: f64) anyerror!i64 {
        const self: *AlertToolAdapter = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return alert_store.create(
            self.pool,
            self.chat_id,
            self.identity_id,
            std.meta.stringToEnum(alert_store.Kind, kind) orelse return error.InvalidAlertKind,
            subject,
            currency,
            std.meta.stringToEnum(alert_store.Condition, condition) orelse return error.InvalidAlertCondition,
            threshold,
        );
    }

    fn cancelFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!tool_registry.AlertSink.CancelResult {
        const self: *AlertToolAdapter = @ptrCast(@alignCast(ptr));
        const al = (try alert_store.get(self.pool, allocator, id)) orelse return .not_found;
        if (al.chat_id != self.chat_id) return .not_found;
        if (al.identity_id != self.identity_id and !self.is_owner) return .not_authorized;
        try alert_store.cancel(self.pool, id);
        return .canceled;
    }

    fn listPendingFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *AlertToolAdapter = @ptrCast(@alignCast(ptr));
        const pending = try alert_store.listPending(self.pool, allocator, self.chat_id);
        return formatPendingAlerts(allocator, pending);
    }
};

/// Wires the `begin_file_conversion` LLM tool (see
/// `tools/begin_conversion.zig`) to `PendingConversions` for one specific
/// message's chat/sender — same per-message construction as
/// `ReminderToolAdapter`/`AlertToolAdapter`. `chat_id`/`user_id` here are
/// the native platform strings (`msg.chat_id`/`msg.user_id`), matching
/// `PendingConversions`' own composite-key scheme, not the internal
/// integer ids the other two adapters use.
const ConvertFlowToolAdapter = struct {
    pending: *convert_flow.PendingConversions,
    now: i64,
    chat_id: []const u8,
    user_id: []const u8,

    fn sink(self: *ConvertFlowToolAdapter) tool_registry.ConvertFlowSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.ConvertFlowSink.VTable = .{
        .beginAwaitingFile = beginAwaitingFileFn,
    };

    fn beginAwaitingFileFn(ptr: *anyopaque) anyerror!void {
        const self: *ConvertFlowToolAdapter = @ptrCast(@alignCast(ptr));
        return self.pending.beginAwaitingFile(self.now, self.chat_id, self.user_id);
    }
};

/// Wires the `find_chat_member` LLM tool (see `tools/find_chat_member.zig`)
/// to the local roster — same per-message construction as the other tool
/// adapters above. Before searching, best-effort refreshes this chat's admin
/// list via the connector (Telegram's `getChatAdministrators` — see
/// `iface.Connector.listChatAdmins`'s doc comment for why that's the only
/// bulk membership call bots get) so admins who've never spoken still show
/// up; a platform/failure that can't supply one just searches whatever's
/// already known instead of failing the tool call.
const MemberDirectoryToolAdapter = struct {
    pool: *store_pool.PgPool,
    connector: iface.Connector,
    chat_id: i64,
    native_chat_id: []const u8,
    now: i64,

    fn sink(self: *MemberDirectoryToolAdapter) tool_registry.MemberDirectorySink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.MemberDirectorySink.VTable = .{
        .find = findFn,
    };

    fn findFn(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8) anyerror![]tool_registry.MemberMatch {
        const self: *MemberDirectoryToolAdapter = @ptrCast(@alignCast(ptr));

        const admins = self.connector.listChatAdmins(allocator, self.native_chat_id) catch |err| blk: {
            if (err != error.Unsupported) {
                log.warn("find_chat_member: admin refresh failed for chat {s}: {t}", .{ self.native_chat_id, err });
            }
            break :blk &.{};
        };
        for (admins) |admin| {
            const identity_id = identities.upsertIdentity(self.pool, admin) catch continue;
            chat_members.ensureKnown(self.pool, self.chat_id, identity_id) catch {};
        }

        const matches = try chat_members.search(self.pool, allocator, self.chat_id, query, 5);
        var out = try allocator.alloc(tool_registry.MemberMatch, matches.len);
        for (matches, 0..) |m, i| {
            out[i] = .{ .display_name = m.display_name, .username = m.username, .native_id = m.native_id };
        }
        return out;
    }
};

/// Shared by `/alerts` and the `set_alert` LLM tool's `action=list`.
fn formatPendingAlerts(a: std.mem.Allocator, pending: []const alert_store.PendingAlert) []const u8 {
    if (pending.len == 0) return "No alerts set. Set one with /alert <crypto|weather|aqi> <subject> <above|below> <threshold> (or just ask).";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Alerts:\n", .{}) catch return "";
    for (pending) |al| {
        const unit = if (al.currency) |c| c else if (al.kind == .weather) "°C" else "AQI";
        w.print("  #{d} {s} {s} {s} {d} {s}\n", .{ al.id, @tagName(al.kind), al.subject, @tagName(al.condition), al.threshold, unit }) catch return "";
    }
    return buf.writer.buffered();
}

/// Delivers through whichever of `connectors` owns each due reminder's
/// platform — see `checkAndSendDueDigests`'s doc comment for the same
/// reasoning. A reminder whose platform has no active connector is left
/// undelivered (not marked delivered) so it retries next cycle instead of
/// being silently lost.
fn checkAndSendDueReminders(
    connectors: []const iface.Connector,
    gpa: std.mem.Allocator,
    pool: *store_pool.PgPool,
    now: i64,
) void {
    const due = reminders.dueUndelivered(pool, gpa, now) catch |err| {
        log.err("remind: failed to query due reminders: {t}", .{err});
        return;
    };
    defer {
        for (due) |r| {
            gpa.free(r.native_chat_id);
            gpa.free(r.message);
        }
        gpa.free(due);
    }

    for (due) |r| {
        const connector = findConnector(connectors, r.platform) orelse {
            log.warn("remind: no active connector for platform {s}, leaving reminder {d} pending", .{ @tagName(r.platform), r.id });
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const text = std.fmt.allocPrint(a, "⏰ Reminder: {s}", .{r.message}) catch continue;
        connector.sendMessage(a, r.native_chat_id, text, null);

        if (r.recur_interval_seconds) |interval| {
            const next_due = reminder_format.nextOccurrence(r.due_at, interval, now);
            reminders.reschedule(pool, r.id, next_due) catch |err| {
                log.err("remind: failed to reschedule recurring reminder {d}: {t}", .{ r.id, err });
            };
        } else {
            reminders.markDelivered(pool, r.id, now) catch |err| {
                log.err("remind: failed to mark reminder {d} delivered: {t}", .{ r.id, err });
            };
        }
    }
}

/// Shown while waiting on the model with nothing more specific to show (see
/// `TickerState`/`tickerLoop`). Used to cycle through several dot-count
/// frames, re-editing the message every tick — but that meant the ticker
/// kept hitting Telegram's edit rate limit even when nothing had actually
/// changed, sometimes causing edits (including the final answer) to get
/// dropped. Now static, so `tickerLoop`'s dedupe against `last_sent` means
/// no edit is sent at all until real progress (a tool call) has something
/// new to show.
const thinking_text = "🤔 Thinking...";
/// Telegram's edits are throttled to roughly 1/sec per chat in practice;
/// this keeps a comfortable margin under that.
const ticker_interval_ms: i64 = 1200;

/// Shared between `replyWithAnswer` (which owns it), the ticker task, and
/// the `toolcall.Progress` callback that updates it — all touching `status`
/// only through the mutex, since the ticker runs as an independent
/// concurrent task. `allocator` backs the "using X" text `onProgressEvent`
/// formats; `onProgressEvent` only ever runs on the main per-message task
/// (synchronously inside `qa.answer`/`toolcall.run`), never the ticker
/// task, so it's safe for this to be the same per-message arena the rest
/// of that task uses — see `tickerLoop`'s doc comment for why the ticker
/// itself must NOT share it.
const TickerState = struct {
    io: Io,
    allocator: std.mem.Allocator,
    /// This platform's hard cap on a single message's text (see
    /// `effectiveMaxMessageLength`) — a streamed `.text` status is
    /// truncated to this before being shown, since unlike the *final*
    /// answer (routed to a file when too long via `sendTextOrFile`) the
    /// growing interim preview has no such fallback and would otherwise
    /// eventually 400 out of `editMessage` on a long answer.
    max_len: usize,
    mutex: Io.Mutex = .init,
    /// null = show the generic thinking animation; set = show this until
    /// the model moves past the tool call that set it.
    status: ?[]const u8 = null,

    fn setStatus(self: *TickerState, text: ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.status = text;
    }

    fn getStatus(self: *TickerState) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.status;
    }
};

fn onProgressEvent(ptr: *anyopaque, event: toolcall.Progress.Event) void {
    const state: *TickerState = @ptrCast(@alignCast(ptr));
    switch (event) {
        .thinking => state.setStatus(null),
        .tool_use => |name| {
            const text = std.fmt.allocPrint(state.allocator, "🔧 using {s}…", .{name}) catch return;
            state.setStatus(text);
        },
        .text => |text_so_far| {
            if (text_so_far.len == 0) return; // nothing to show yet, keep the thinking animation
            state.setStatus(truncateUtf8(text_so_far, state.max_len));
        },
    }
}

/// UTF-8-boundary-safe truncation to at most `max_len` bytes — backs off
/// from `max_len` to the start of whatever multi-byte codepoint it would
/// otherwise cut through, so a truncated interim streaming preview is never
/// invalid UTF-8 (which `editMessage` would otherwise send to Telegram
/// broken, the same class of problem `toolcall.zig`'s `sanitizeUtf8` guards
/// tool results against). Returns `text` unchanged (no allocation) when
/// it's already within budget.
fn truncateUtf8(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    var end = max_len;
    // `text[end]` is the first byte being cut off; back off while it's a
    // UTF-8 continuation byte (`10xxxxxx`), i.e. while stopping here would
    // split a multi-byte codepoint in half.
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

test "truncateUtf8 passes short text through unchanged" {
    try std.testing.expectEqualStrings("hello", truncateUtf8("hello", 10));
}

test "truncateUtf8 backs off to a codepoint boundary instead of splitting one" {
    // "café" = c,a,f,é where é is the 2-byte sequence 0xC3 0xA9. Cutting at
    // byte 4 would land inside that sequence (after its leading byte).
    const text = "caf\u{e9}"; // "café"
    try std.testing.expectEqual(@as(usize, 5), text.len);
    const truncated = truncateUtf8(text, 4);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
    try std.testing.expectEqualStrings("caf", truncated);
}

test "truncateUtf8 handles max_len landing exactly on a boundary" {
    const text = "caf\u{e9}";
    try std.testing.expectEqualStrings(text, truncateUtf8(text, 5));
    try std.testing.expectEqualStrings("caf", truncateUtf8(text, 3));
}

/// Runs until canceled (see `replyWithAnswer`), editing `message_id` no
/// more than once per `ticker_interval_ms` — the generic thinking
/// animation, or whatever `state.status` currently says, whichever's
/// current. Dedupes against the last text it actually sent so a run of
/// identical statuses (or a tick where nothing changed) doesn't trigger a
/// wasted edit — besides being pointless, Telegram rejects a no-op edit
/// ("message is not modified"), which `editMessage` can't distinguish from
/// a real failure (see its doc comment).
///
/// Deliberately does NOT take the per-message arena `replyWithAnswer` and
/// `qa.answer` use — this runs as a genuinely concurrent task (a real OS
/// thread under `Io.Threaded`), and `std.heap.ArenaAllocator` has no
/// internal locking, so two threads allocating from the same arena at once
/// corrupts its bookkeeping. That was the actual cause of a reported hang:
/// no timeout ever fired because the corruption happened inside allocator
/// internals, nowhere near the network code the timeouts guard. Every
/// allocation `editMessage`'s call chain makes is `defer`-freed by itself
/// (no reliance on arena-wholesale-free), so a plain thread-safe allocator
/// works fine here — no arena needed.
fn tickerLoop(connector: iface.Connector, chat_id: []const u8, message_id: []const u8, state: *TickerState) void {
    var last_sent: []const u8 = thinking_text;
    while (true) {
        Io.sleep(state.io, .fromMilliseconds(ticker_interval_ms), .awake) catch return;

        const status = state.getStatus();
        const text = status orelse thinking_text;

        if (!std.mem.eql(u8, text, last_sent)) {
            connector.editMessage(std.heap.page_allocator, chat_id, message_id, text) catch |err| {
                log.warn("ticker: edit failed for chat {s}: {t}", .{ chat_id, err });
            };
            last_sent = text;
        }
    }
}

/// Maps an LLM tool's own `.name` (the function-calling identifier) to the
/// `feature_flags` module key that gates it — `null` for tools with no
/// toggle (calculator, currency, fetch_url, draw_diagram, word_cloud,
/// find_chat_member), which always stay available. Deliberately covers
/// more than /home/armin/claude/warden-ui/ARCHITECTURE.md §5's literal
/// "LLM-tool-shaped features" list: the standalone-module tools
/// (set_reminder, set_alert, begin_file_conversion, convert_file) map back
/// to their command's own module key too — disabling "Reminders" bot-wide
/// should stop *every* way to create one, not just the `/remind` command,
/// or the toggle would be a half-measure a careful admin would reasonably
/// call a bug.
fn toolModuleKey(name: []const u8) ?[]const u8 {
    const Pair = struct { name: []const u8, key: []const u8 };
    const pairs = [_]Pair{
        .{ .name = "weather", .key = "weather" },
        .{ .name = "air_quality", .key = "air_quality" },
        .{ .name = "crypto_price", .key = "crypto_price" },
        .{ .name = "qr_code", .key = "qr_code" },
        .{ .name = "dictionary", .key = "dictionary" },
        .{ .name = "urban_dictionary", .key = "urban_dictionary" },
        .{ .name = "hackernews_search", .key = "hackernews" },
        .{ .name = "scrape_site", .key = "scrape_site" },
        .{ .name = "web_search", .key = "web_search" },
        .{ .name = "set_reminder", .key = "reminders" },
        .{ .name = "set_alert", .key = "alerts" },
        .{ .name = "begin_file_conversion", .key = "convert" },
        .{ .name = "convert_file", .key = "convert" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.key;
    }
    return null;
}

/// Filters `tools` against `feature_flags` right before handing them to
/// the model — the "handing over" moment ARCHITECTURE.md §5 describes,
/// checked fresh on every turn so a toggle takes effect immediately, no
/// restart needed. `a` is expected to be the caller's per-message arena
/// (same convention every other per-message allocation in this function
/// follows) — falls back to returning `tools` unfiltered on allocation
/// failure rather than failing the whole reply over a disabled-tools list.
fn filterEnabledTools(pool: *store_pool.PgPool, a: std.mem.Allocator, tools: []const tool_registry.ToolDef) []const tool_registry.ToolDef {
    const out = a.alloc(tool_registry.ToolDef, tools.len) catch return tools;
    var n: usize = 0;
    for (tools) |t| {
        const key = toolModuleKey(t.name) orelse {
            out[n] = t;
            n += 1;
            continue;
        };
        if (feature_flags.isEnabled(pool, key)) {
            out[n] = t;
            n += 1;
        }
    }
    return out[0..n];
}

test "toolModuleKey maps tool names to their feature_flags module key" {
    try std.testing.expectEqualStrings("weather", toolModuleKey("weather").?);
    try std.testing.expectEqualStrings("reminders", toolModuleKey("set_reminder").?);
    try std.testing.expectEqualStrings("convert", toolModuleKey("convert_file").?);
    try std.testing.expectEqualStrings("convert", toolModuleKey("begin_file_conversion").?);
    try std.testing.expectEqualStrings("hackernews", toolModuleKey("hackernews_search").?);
    try std.testing.expectEqual(@as(?[]const u8, null), toolModuleKey("calculator"));
    try std.testing.expectEqual(@as(?[]const u8, null), toolModuleKey("nonexistent_tool"));
}

test "filterEnabledTools drops only tools whose module is explicitly disabled" {
    const test_support = @import("store/test_support.zig");
    var db = try test_support.openTestDb(std.testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(std.testing.allocator, std.testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try feature_flags.setEnabled(&pool, "weather", false, owner);

    const dummy_execute = struct {
        fn call(ctx: tool_registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
            _ = ctx;
            _ = input_json;
            return "";
        }
    }.call;

    const tools = [_]tool_registry.ToolDef{
        .{ .name = "weather", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "calculator", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "air_quality", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
    };

    // `filterEnabledTools` is documented to expect an arena (its return
    // value is a shorter sub-slice of its own internal allocation, which
    // `std.testing.allocator`'s strict tracking can't free directly) --
    // same convention every per-message call site already uses it under.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const filtered = filterEnabledTools(&pool, arena.allocator(), &tools);
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings("calculator", filtered[0].name);
    try std.testing.expectEqualStrings("air_quality", filtered[1].name);
}

fn replyWithAnswer(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    system_prompt: ?[]const u8,
    io: Io,
    now: i64,
    retention_messages: i64,
    max_message_len: usize,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
    asker: qa.Asker,
    question: []const u8,
    replied_to: ?[]const u8,
    existing_placeholder_id: ?[]const u8,
    stream: bool,
    show_thinking: bool,
    max_tokens_override: ?u32,
    history_window: i64,
) void {
    // The placeholder + ticker only work when the platform supports
    // editing (Telegram does); anything that doesn't falls back to
    // exactly the old behavior — one blocking call, one send at the end.
    // `existing_placeholder_id` (from `resolveQuestion`'s "🎙️
    // Transcribing…" placeholder) is reused and morphed rather than
    // sending a second message right after it.
    const placeholder_id = if (existing_placeholder_id) |pid| blk: {
        connector.editMessage(a, native_chat_id, pid, thinking_text) catch |err| {
            log.warn("qa: couldn't morph the transcription placeholder for chat {s}: {t}", .{ native_chat_id, err });
        };
        break :blk pid;
    } else connector.sendMessageReturningId(a, native_chat_id, thinking_text, reply_to) catch |err| blk: {
        log.warn("qa: couldn't send a placeholder for chat {s}, falling back to a plain reply: {t}", .{ native_chat_id, err });
        break :blk null;
    };
    log.info("qa: placeholder for chat {s} = {?s}", .{ native_chat_id, placeholder_id });

    var state = TickerState{ .io = io, .allocator = a, .max_len = max_message_len };
    var progress: toolcall.Progress = .{};
    var ticker_future: ?Io.Future(void) = null;
    if (placeholder_id) |pid| {
        progress = .{ .ptr = &state, .onEvent = onProgressEvent };
        ticker_future = Io.concurrent(io, tickerLoop, .{ connector, native_chat_id, pid, &state }) catch |err| blk: {
            log.warn("qa: couldn't start the thinking animation for chat {s}: {t}", .{ native_chat_id, err });
            break :blk null;
        };
    }

    log.info("qa: calling the model for chat {s}", .{native_chat_id});
    const enabled_tools = filterEnabledTools(pool, a, tools);
    const raw_answer_or_err = qa.answer(llm_provider, a, tool_ctx, enabled_tools, pool, chat_id, system_prompt, max_message_len, asker, question, replied_to, progress, stream, show_thinking, max_tokens_override, history_window);

    // Stop the ticker before touching the placeholder ourselves — it's the
    // sole owner of that Future until this point (see `Future.cancel`'s
    // "not threadsafe" note), and cancel() blocks until it has actually
    // stopped, so there's no risk of it clobbering the final edit below.
    if (ticker_future) |*f| _ = f.cancel(io);
    log.info("qa: model call for chat {s} returned", .{native_chat_id});

    const raw_answer = raw_answer_or_err catch |err| {
        log.err("qa: failed to answer in chat {s}: {t}", .{ native_chat_id, err });
        const error_text = "Sorry, I couldn't reach the model just now.";
        if (placeholder_id) |pid| {
            if (connector.editMessage(a, native_chat_id, pid, error_text)) |_| {
                log.info("qa: error message edited into placeholder for chat {s}", .{native_chat_id});
            } else |edit_err| {
                log.warn("qa: editing error message into placeholder failed for chat {s}: {t}, sending a new message instead", .{ native_chat_id, edit_err });
                connector.sendMessage(a, native_chat_id, error_text, reply_to);
            }
        } else {
            connector.sendMessage(a, native_chat_id, error_text, reply_to);
        }
        return;
    };

    // Models occasionally produce a whitespace-only answer (e.g. after a
    // photo-sending tool already did the visible work); Telegram rejects
    // empty text with a 400, so don't try to send it — and don't leave the
    // placeholder stuck showing "thinking" forever either.
    const answer = std.mem.trim(u8, raw_answer, " \t\r\n");
    log.info("qa: answer for chat {s} is {d} bytes (raw {d})", .{ native_chat_id, answer.len, raw_answer.len });
    if (answer.len == 0) {
        log.info("qa: empty answer for chat {s}, deleting placeholder", .{native_chat_id});
        if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
            // Previously swallowed silently — if this fails (network
            // hiccup, message already gone), the placeholder is stuck
            // showing "thinking" forever with zero trace of why. At least
            // log it; there's no good fallback text to edit in instead
            // since there was never a real answer to show.
            log.warn("qa: failed to delete empty-answer placeholder for chat {s}: {t}", .{ native_chat_id, err });
        };
        return;
    }

    if (answer.len > max_message_len) {
        // Too long for this platform's limit — editing the placeholder
        // in-place with it would just fail the same way sending it fresh
        // would, so drop the placeholder and attach it as a file instead.
        log.info("qa: answer for chat {s} exceeds max_message_len ({d} > {d}), sending as a file", .{ native_chat_id, answer.len, max_message_len });
        if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
            log.warn("qa: failed to delete placeholder before file fallback for chat {s}: {t}", .{ native_chat_id, err });
        };
        sendTextOrFile(connector, a, native_chat_id, answer, reply_to, max_message_len, "answer.txt");
    } else if (placeholder_id) |pid| {
        if (connector.editMessage(a, native_chat_id, pid, answer)) |_| {
            log.info("qa: final answer edited into placeholder for chat {s}", .{native_chat_id});
        } else |err| {
            log.warn("qa: final edit failed for chat {s}, sending a new message instead: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, answer, reply_to);
        }
    } else {
        connector.sendMessage(a, native_chat_id, answer, reply_to);
    }

    // Log the bot's own reply too, so follow-up questions see it in the
    // history window (inbound polling never echoes our own sends back).
    // Resolved to a real identity row (the bot's own), not the old
    // hardcoded `user_id = "warden"` placeholder.
    const bot_username = connector.selfUsername() orelse "warden";
    const bot_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), connector.selfId() orelse "warden", bot_username, connector.selfUsername(), true, now) catch |err| {
        log.err("qa: failed to resolve bot identity for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };
    recordMessage(pool, chat_id, bot_identity_id, null, answer, now, retention_messages);
}

fn replyWithWordcloud(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    tmp_dir: []const u8,
    io: Io,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const words = wordcloud.topWords(a, pool, chat_id, 60) catch |err| {
        log.err("wordcloud: tokenize failed for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };
    if (words.len == 0) {
        connector.sendMessage(a, native_chat_id, "Not enough logged messages yet to build a word cloud.", reply_to);
        return;
    }
    const png = wordcloud.render(a, io, tmp_dir, words) catch |err| {
        log.err("wordcloud: render failed for chat {s}: {t}", .{ native_chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't render the word cloud (is Node installed?).", reply_to);
        return;
    };
    connector.sendPhoto(a, native_chat_id, png, "Word cloud of recent messages");
}

fn replyWithStats(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, native_chat_id: []const u8, reply_to: ?[]const u8) void {
    const s = stats.compute(pool, a, chat_id, 5) catch |err| {
        log.err("stats: query failed for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Messages logged: {d}\nActive users: {d}\nTop users:\n", .{ s.total_messages, s.distinct_users }) catch return;
    for (s.top_users) |u| {
        if (u.username.len > 0) {
            w.print("  @{s}: {d}\n", .{ u.username, u.message_count }) catch return;
        } else {
            w.print("  {s}: {d}\n", .{ u.user_id, u.message_count }) catch return;
        }
    }

    connector.sendMessage(a, native_chat_id, buf.writer.buffered(), reply_to);
}

// ---------------------------------------------------------------------------
// /menu ActionRunner — the switch that actually performs every module's
// buttons/prompts. Deliberately thin: almost every branch below calls
// straight into a handler function (or store mutation) that already exists
// and is already gated by its own `auth.*` check for the slash-command
// equivalent — the menu is a UI layer over those, never a second
// permission system. See `features/menu.zig`'s module doc comment for the
// engine this plugs into.
// ---------------------------------------------------------------------------

fn menuCtx(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    config: *const config_mod.Config,
    chat_id: i64,
    identity_id: i64,
    now: i64,
    msg: iface.Message,
    io: Io,
    digest_scheduler: *scheduler.DigestScheduler,
    pending_conversions: *convert_flow.PendingConversions,
) menu.ActionContext {
    return .{
        .connector = connector,
        .a = a,
        .pool = pool,
        .config = config,
        .chat_id = chat_id,
        .identity_id = identity_id,
        .now = now,
        .msg = msg,
        .io = io,
        .digest_scheduler = digest_scheduler,
        .pending_conversions = pending_conversions,
    };
}

const menu_runner: menu.ActionRunner = .{
    .perform = menuPerform,
    .dynamicChoices = menuDynamicChoices,
    .performDynamicPick = menuPerformDynamicPick,
    .resumeAwaitingInput = menuResumeAwaitingInput,
    .beginWizard = menuBeginWizard,
    .finishWizard = menuFinishWizard,
};

fn menuSendAndShow(ctx: menu.ActionContext, text: []const u8, show: menu_tree.NodeId) menu.Outcome {
    ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, text, null);
    return .{ .show = show };
}

/// Distinct, ordered emoji for a `.dynamic_list`'s live entries — same
/// index-based idiom as `convert_flow.zig`'s own `choice_emoji`
/// (duplicated rather than shared: it's four lines, and exporting it would
/// couple two otherwise-independent features over a trivial helper).
const dynamic_list_emoji = [_][]const u8{ "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣", "🔟" };
fn dynamicEmojiFor(i: usize) []const u8 {
    return dynamic_list_emoji[i % dynamic_list_emoji.len];
}

/// Maps a menu action's `NodeId` to the `feature_flags` module key that
/// gates it — `null` for navigation/settings nodes with no toggle.
/// Checked once at the top of each menu dispatch function below rather
/// than duplicated per switch arm, since several of these nodes (group
/// admin actions, `.convert`, the reminder wizard) are real state-changing
/// actions reachable *only* through `/menu`, entirely separate from the
/// slash-command dispatch in `handleMessage` — ARCHITECTURE.md §5
/// explicitly calls out needing both gated, not just the command form.
fn menuNodeModuleKey(id: menu_tree.NodeId) ?[]const u8 {
    return switch (id) {
        .convert => "convert",
        .reminders_new => "reminders",
        .group_admin_mute,
        .group_admin_unmute,
        .group_admin_pin,
        .group_admin_unpin,
        .group_admin_delete,
        .group_admin_promote,
        .group_admin_demote,
        .group_admin_kick,
        .group_admin_ban,
        .group_admin_redact_lastn,
        .group_admin_redact_user,
        .group_admin_redact_text,
        .group_admin_redact_regex,
        => "group_admin",
        else => null,
    };
}

const module_disabled_text = "This feature is currently disabled.";

fn menuPerform(id: menu_tree.NodeId, ctx: menu.ActionContext) menu.Outcome {
    if (menuNodeModuleKey(id)) |key| {
        if (!feature_flags.isEnabled(ctx.pool, key)) {
            return menuSendAndShow(ctx, module_disabled_text, menu_tree.node(id).parent orelse .root);
        }
    }
    return switch (id) {
        .alerts_new => menuSendAndShow(ctx, menu_tree.node(id).body, .alerts),
        .watches_new => menuSendAndShow(ctx, menu_tree.node(id).body, .watches),
        .stats_text => blk: {
            replyWithStats(ctx.connector, ctx.a, ctx.pool, ctx.chat_id, ctx.msg.chat_id, null);
            break :blk .{ .show = .stats };
        },
        .stats_wordcloud => blk: {
            replyWithWordcloud(ctx.connector, ctx.a, ctx.pool, ctx.chat_id, ctx.config.tmp_dir, ctx.io, ctx.msg.chat_id, null);
            break :blk .{ .show = .stats };
        },
        .stats_piechart => blk: {
            const s = stats.compute(ctx.pool, ctx.a, ctx.chat_id, 8) catch |err| {
                log.err("menu: stats query failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
                break :blk menuSendAndShow(ctx, "Couldn't load stats, try again.", .stats);
            };
            if (s.top_users.len == 0) break :blk menuSendAndShow(ctx, "Not enough logged messages yet.", .stats);
            const slices = piechart.slicesFromTopUsers(ctx.a, s.top_users) catch break :blk menuSendAndShow(ctx, "Couldn't build the chart, try again.", .stats);
            const png = piechart.render(ctx.a, ctx.io, ctx.config.tmp_dir, slices) catch |err| {
                log.err("menu: piechart render failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
                break :blk menuSendAndShow(ctx, "Couldn't render the chart (is Node installed?).", .stats);
            };
            ctx.connector.sendPhoto(ctx.a, ctx.msg.chat_id, png, "Top participants");
            break :blk .{ .show = .stats };
        },
        .convert => blk: {
            convert_flow.beginConvertFlow(ctx.connector, ctx.a, ctx.pending_conversions, ctx.now, ctx.msg);
            break :blk .close; // /convert's own flow takes over from here.
        },
        .group_admin_unpin => blk: {
            group_admin.unpin(ctx.connector, ctx.a, ctx.msg);
            break :blk .{ .show = .group_admin };
        },
        .settings_global_allowchat => blk: {
            bot_allowlist.addAllowedChat(ctx.pool, ctx.chat_id, ctx.identity_id) catch |err| {
                log.err("menu: allowchat failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
            };
            break :blk menuSendAndShow(ctx, "This chat is now allowed to use the bot.", .settings_global);
        },
        .settings_global_disallowchat => blk: {
            bot_allowlist.removeAllowedChat(ctx.pool, ctx.chat_id) catch |err| {
                log.err("menu: disallowchat failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
            };
            break :blk menuSendAndShow(ctx, "This chat is no longer allowed to use the bot.", .settings_global);
        },
        .settings_global_scraper => blk: {
            const snap = bot_config.loadScraperConfig(ctx.pool, ctx.a);
            const text = std.fmt.allocPrint(
                ctx.a,
                "Scraper mode: {t}\nRemote URL: {s}\n\nUse /scraper to change (several independent options, so this stays a typed command).",
                .{ snap.mode, snap.remote_url orelse "(none)" },
            ) catch "Couldn't load the current scraper config.";
            break :blk menuSendAndShow(ctx, text, .settings_global);
        },
        .settings_chat_thinking_on => blk: {
            chat_settings.setShowThinkingOverride(ctx.pool, ctx.chat_id, true) catch {};
            break :blk menuSendAndShow(ctx, "Thinking will be shown for this chat.", .settings_chat);
        },
        .settings_chat_thinking_off => blk: {
            chat_settings.setShowThinkingOverride(ctx.pool, ctx.chat_id, false) catch {};
            break :blk menuSendAndShow(ctx, "Thinking will be hidden for this chat.", .settings_chat);
        },
        .settings_chat_thinking_default => blk: {
            chat_settings.setShowThinkingOverride(ctx.pool, ctx.chat_id, null) catch {};
            break :blk menuSendAndShow(ctx, "This chat now follows the bot-wide thinking default.", .settings_chat);
        },
        .settings_chat_digest_on => blk: {
            ctx.digest_scheduler.enable(ctx.connector.platform(), ctx.msg.chat_id) catch |err| {
                log.err("menu: digest enable failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
                break :blk menuSendAndShow(ctx, "Couldn't enable the digest, try again.", .settings_chat);
            };
            chat_settings.setDigestEnabled(ctx.pool, ctx.chat_id, true) catch {};
            break :blk menuSendAndShow(ctx, "Digest enabled.", .settings_chat);
        },
        .settings_chat_digest_off => blk: {
            ctx.digest_scheduler.disable(ctx.a, ctx.connector.platform(), ctx.msg.chat_id);
            chat_settings.setDigestEnabled(ctx.pool, ctx.chat_id, false) catch {};
            break :blk menuSendAndShow(ctx, "Digest disabled.", .settings_chat);
        },
        .settings_personal_dateformat_mdy => blk: {
            user_settings.setDateFormat(ctx.pool, ctx.identity_id, .mdy) catch {};
            break :blk menuSendAndShow(ctx, "Date format set to M/D/Y.", .settings_personal_dateformat);
        },
        .settings_personal_dateformat_dmy => blk: {
            user_settings.setDateFormat(ctx.pool, ctx.identity_id, .dmy) catch {};
            break :blk menuSendAndShow(ctx, "Date format set to D/M/Y.", .settings_personal_dateformat);
        },
        .settings_personal_dateformat_ymd => blk: {
            user_settings.setDateFormat(ctx.pool, ctx.identity_id, .ymd) catch {};
            break :blk menuSendAndShow(ctx, "Date format set to Y-M-D.", .settings_personal_dateformat);
        },
        .settings_personal_timeformat_24h => blk: {
            user_settings.setTimeFormat(ctx.pool, ctx.identity_id, .h24) catch {};
            break :blk menuSendAndShow(ctx, "Time format set to 24h.", .settings_personal_timeformat);
        },
        .settings_personal_timeformat_12h => blk: {
            user_settings.setTimeFormat(ctx.pool, ctx.identity_id, .h12) catch {};
            break :blk menuSendAndShow(ctx, "Time format set to 12h (AM/PM).", .settings_personal_timeformat);
        },
        else => .{ .show = .root },
    };
}

fn menuDynamicChoices(id: menu_tree.NodeId, ctx: menu.ActionContext) []const iface.Choice {
    var out: std.ArrayList(iface.Choice) = .empty;
    switch (id) {
        .alerts_view => {
            const pending = alert_store.listPending(ctx.pool, ctx.a, ctx.chat_id) catch return &.{};
            for (pending, 0..) |al, i| {
                const label = std.fmt.allocPrint(ctx.a, "#{d} {s} {t} {d} {s}", .{ al.id, al.subject, al.condition, al.threshold, al.currency orelse "" }) catch continue;
                const value = std.fmt.allocPrint(ctx.a, "{d}", .{al.id}) catch continue;
                out.append(ctx.a, .{ .emoji = dynamicEmojiFor(i), .label = label, .value = value }) catch continue;
            }
        },
        .watches_view => {
            const pending = feed_watches.listPending(ctx.pool, ctx.a, ctx.chat_id) catch return &.{};
            for (pending, 0..) |fw, i| {
                out.append(ctx.a, .{ .emoji = dynamicEmojiFor(i), .label = fw.feed_url, .value = fw.feed_url }) catch continue;
            }
        },
        .reminders_view => {
            const pending = reminders.listPending(ctx.pool, ctx.a, ctx.chat_id) catch return &.{};
            for (pending, 0..) |r, i| {
                // Each reminder's setter's own timezone/format, not the
                // viewer's -- see `formatPendingReminders`'s doc comment.
                const offset_minutes = user_settings.getEffectiveOffsetMinutes(ctx.pool, ctx.a, r.identity_id);
                const date_format = user_settings.getEffectiveDateFormat(ctx.pool, ctx.a, r.identity_id);
                const time_format = user_settings.getEffectiveTimeFormat(ctx.pool, ctx.a, r.identity_id);
                const local = civil_time.localFromUnix(r.due_at, offset_minutes);
                const date_str = civil_time.formatDate(ctx.a, local, date_format);
                const time_str = civil_time.formatTime(ctx.a, local, time_format);
                const label = std.fmt.allocPrint(ctx.a, "#{d} {s} {s}: {s}", .{ r.id, date_str, time_str, r.message }) catch continue;
                const value = std.fmt.allocPrint(ctx.a, "{d}", .{r.id}) catch continue;
                out.append(ctx.a, .{ .emoji = dynamicEmojiFor(i), .label = label, .value = value }) catch continue;
            }
        },
        else => {},
    }
    return out.items;
}

fn menuPerformDynamicPick(id: menu_tree.NodeId, value: []const u8, ctx: menu.ActionContext) menu.Outcome {
    return switch (id) {
        .alerts_view => blk: {
            const alert_id = std.fmt.parseInt(i64, value, 10) catch break :blk .{ .show = .alerts };
            const al = (alert_store.get(ctx.pool, ctx.a, alert_id) catch null) orelse break :blk menuSendAndShow(ctx, "No alert with that id.", .alerts);
            if (al.chat_id != ctx.chat_id) break :blk menuSendAndShow(ctx, "No alert with that id.", .alerts);
            if (al.identity_id != ctx.identity_id and !auth.isOwner(ctx.config, ctx.connector.platform(), ctx.msg.user_id)) {
                break :blk menuSendAndShow(ctx, "Only whoever set that alert (or the owner) can cancel it.", .alerts);
            }
            alert_store.cancel(ctx.pool, alert_id) catch |err| {
                log.err("menu: alert cancel failed for id {d}: {t}", .{ alert_id, err });
                break :blk menuSendAndShow(ctx, "Couldn't cancel that alert, try again.", .alerts);
            };
            break :blk menuSendAndShow(ctx, "Alert canceled.", .alerts);
        },
        .watches_view => blk: {
            const removed = feed_watches.remove(ctx.pool, ctx.chat_id, value) catch |err| {
                log.err("menu: unwatch failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
                break :blk menuSendAndShow(ctx, "Couldn't remove that watch, try again.", .watches);
            };
            break :blk menuSendAndShow(ctx, if (removed) "Unwatched." else "Wasn't watching that feed anymore.", .watches);
        },
        .reminders_view => blk: {
            const rem_id = std.fmt.parseInt(i64, value, 10) catch break :blk .{ .show = .reminders };
            const rem = (reminders.get(ctx.pool, ctx.a, rem_id) catch null) orelse break :blk menuSendAndShow(ctx, "No pending reminder with that id.", .reminders);
            if (rem.chat_id != ctx.chat_id) break :blk menuSendAndShow(ctx, "No pending reminder with that id.", .reminders);
            if (rem.identity_id != ctx.identity_id and !auth.isOwner(ctx.config, ctx.connector.platform(), ctx.msg.user_id)) {
                break :blk menuSendAndShow(ctx, "Only whoever set that reminder (or the owner) can cancel it.", .reminders);
            }
            reminders.cancel(ctx.pool, rem_id) catch |err| {
                log.err("menu: reminder cancel failed for id {d}: {t}", .{ rem_id, err });
                break :blk menuSendAndShow(ctx, "Couldn't cancel that reminder, try again.", .reminders);
            };
            break :blk menuSendAndShow(ctx, "Reminder canceled.", .reminders);
        },
        else => .{ .show = .root },
    };
}

fn menuResumeAwaitingInput(id: menu_tree.NodeId, ctx: menu.ActionContext) menu.Outcome {
    const parent = menu_tree.node(id).parent orelse .root;
    if (menuNodeModuleKey(id)) |key| {
        if (!feature_flags.isEnabled(ctx.pool, key)) {
            return menuSendAndShow(ctx, module_disabled_text, parent);
        }
    }
    switch (id) {
        .group_admin_mute => group_admin.mute(ctx.connector, ctx.a, ctx.msg, ctx.now),
        .group_admin_unmute => group_admin.unmute(ctx.connector, ctx.a, ctx.msg),
        .group_admin_pin => group_admin.pin(ctx.connector, ctx.a, ctx.msg),
        .group_admin_delete => group_admin.deleteMessage(ctx.connector, ctx.a, ctx.msg),
        .group_admin_promote => {
            if (!auth.isOwner(ctx.config, ctx.connector.platform(), ctx.msg.user_id)) {
                ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Bot owner only.", null);
            } else {
                group_admin.promote(ctx.connector, ctx.a, ctx.msg);
            }
        },
        .group_admin_demote => {
            if (!auth.isOwner(ctx.config, ctx.connector.platform(), ctx.msg.user_id)) {
                ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Bot owner only.", null);
            } else {
                group_admin.demote(ctx.connector, ctx.a, ctx.msg);
            }
        },
        .group_admin_kick => menuResumeViaCommand(ctx, "/kick", handleKickBanCommandKick),
        .group_admin_ban => menuResumeViaCommand(ctx, "/ban", handleKickBanCommandBan),
        .group_admin_redact_lastn => {
            const n = std.fmt.parseInt(i64, std.mem.trim(u8, ctx.msg.text orelse "", " "), 10) catch 0;
            redact_feature.redactLastN(ctx.connector, ctx.a, ctx.pool, ctx.chat_id, ctx.msg, n);
        },
        .group_admin_redact_user => {
            const target = replyTarget(ctx.msg) orelse {
                ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Reply to that user's message.", null);
                return .{ .show = id }; // let them try again without re-navigating
            };
            const target_identity_id = identities.getOrCreateMinimal(ctx.pool, ctx.connector.platform(), target.user_id, target.label, ctx.msg.reply_to_username, false, ctx.now) catch |err| {
                log.err("menu: redact target resolve failed: {t}", .{err});
                return .{ .show = parent };
            };
            const trailing = std.mem.trim(u8, ctx.msg.text orelse "", " ");
            const n = std.fmt.parseInt(i64, trailing, 10) catch 0;
            redact_feature.redactUserLastN(ctx.connector, ctx.a, ctx.pool, ctx.chat_id, ctx.msg, target_identity_id, n);
        },
        .group_admin_redact_text => redact_feature.redactText(ctx.connector, ctx.a, ctx.pool, ctx.chat_id, ctx.msg, std.mem.trim(u8, ctx.msg.text orelse "", " ")),
        .group_admin_redact_regex => {
            const is_bot_admin = auth.isOwner(ctx.config, ctx.connector.platform(), ctx.msg.user_id) or bot_admins.isBotAdmin(ctx.pool, ctx.identity_id);
            if (!is_bot_admin) {
                ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Regex redact is bot admin/owner only.", null);
            } else {
                redact_feature.redactRegex(ctx.connector, ctx.a, ctx.pool, ctx.chat_id, ctx.msg, std.mem.trim(u8, ctx.msg.text orelse "", " "));
            }
        },
        .settings_global_addadmin => menuResumeViaTextAdd(ctx, "/addadmin", handleAddAdminCommand),
        .settings_global_removeadmin => menuResumeViaText(ctx, "/removeadmin", handleRemoveAdminCommand),
        .settings_global_adduser => menuResumeViaTextAdd(ctx, "/adduser", handleAddUserCommand),
        .settings_global_removeuser => menuResumeViaText(ctx, "/removeuser", handleRemoveUserCommand),
        .settings_global_whois => handleWhoisCommand(ctx.connector, ctx.a, ctx.config, ctx.pool, ctx.now, ctx.msg, menuSyntheticText(ctx, "/whois")),
        .settings_chat_magicword => handleMagicWord(ctx.connector, ctx.a, ctx.config, ctx.pool, ctx.chat_id, ctx.msg, menuSyntheticText(ctx, "/magicword")),
        .settings_chat_persona => handlePersonaCommand(ctx.connector, ctx.a, ctx.config, ctx.pool, ctx.chat_id, ctx.msg, menuSyntheticText(ctx, "/persona")),
        .settings_personal_timezone => {
            const raw = std.mem.trim(u8, ctx.msg.text orelse "", " ");
            const offset = parseUtcOffsetInput(raw) orelse {
                ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Couldn't parse that — send a signed UTC offset like +3:30, -5, or +0.", null);
                return .{ .show = id };
            };
            user_settings.setUtcOffsetMinutes(ctx.pool, ctx.identity_id, offset) catch |err| {
                log.err("menu: set utc offset failed for identity {d}: {t}", .{ ctx.identity_id, err });
            };
            ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Timezone updated.", null);
        },
        else => {},
    }
    return .{ .show = parent };
}

/// A signed `H[:MM]` UTC offset, e.g. "+3:30", "-5", "+0" — an explicit
/// sign is required (no bare "5", to avoid guessing whether it means +5 or
/// local convention) since this is the one place a personal timezone is
/// set directly rather than guessed from `language_code`.
fn parseUtcOffsetInput(text: []const u8) ?i32 {
    if (text.len < 2) return null;
    const sign: i32 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const rest = text[1..];
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    const hour_str = if (colon) |c| rest[0..c] else rest;
    const minute_str = if (colon) |c| rest[c + 1 ..] else "0";
    const hour = std.fmt.parseInt(i32, hour_str, 10) catch return null;
    const minute = std.fmt.parseInt(i32, minute_str, 10) catch return null;
    if (hour < 0 or hour > 14 or minute < 0 or minute > 59) return null;
    return sign * (hour * 60 + minute);
}

/// `ActionRunner.beginWizard` — the reminder wizard's initial draft:
/// today, local current-hour-plus-one on the dot (a sensible "later
/// today" default the stepper buttons can nudge from).
fn menuBeginWizard(id: menu_tree.NodeId, ctx: menu.ActionContext) menu.ReminderDraft {
    _ = id;
    // Deliberately doesn't check `feature_flags` here -- this only builds
    // an initial draft (`menu.Session`'s own state machine calls this
    // directly for a `NodeKind.wizard` node, bypassing `menuPerform`
    // entirely), and this function's return type can't express "refuse, +
    // show a message" the way `menu.Outcome` can. Letting someone start
    // filling out a disabled module's wizard is a UX wart, not a real
    // gap -- `menuFinishWizard` below is where the reminder actually gets
    // written, and that's where the real gate lives.
    const offset_minutes = user_settings.getEffectiveOffsetMinutes(ctx.pool, ctx.a, ctx.identity_id);
    const local = civil_time.localFromUnix(ctx.now, offset_minutes);
    return .{
        .year = local.year,
        .month = local.month,
        .day = local.day,
        .hour = @intCast(@mod(@as(i32, local.hour) + 1, 24)),
        .minute = 0,
        .second = 0,
    };
}

/// `ActionRunner.finishWizard` — the confirm screen's "Create" button.
fn menuFinishWizard(draft: menu.ReminderDraft, ctx: menu.ActionContext) menu.Outcome {
    if (!feature_flags.isEnabled(ctx.pool, "reminders")) {
        return menuSendAndShow(ctx, module_disabled_text, .reminders);
    }
    if (draft.message.len == 0) {
        ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Reminder message can't be empty.", null);
        return .retry;
    }
    if (draft.message.len > max_reminder_message_len) {
        ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "That reminder text is too long (max 500 bytes).", null);
        return .retry;
    }

    const offset_minutes = user_settings.getEffectiveOffsetMinutes(ctx.pool, ctx.a, ctx.identity_id);
    const c: civil_time.Civil = .{ .year = draft.year, .month = draft.month, .day = draft.day, .hour = draft.hour, .minute = draft.minute, .second = draft.second };
    const due_at = civil_time.unixFromLocal(c, offset_minutes);

    const id = reminders.create(ctx.pool, ctx.chat_id, ctx.identity_id, draft.message, due_at, null) catch |err| {
        log.err("menu: wizard failed to create reminder for chat {d}: {t}", .{ ctx.chat_id, err });
        ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Couldn't save that reminder, try again.", null);
        return .retry;
    };

    const date_format = user_settings.getEffectiveDateFormat(ctx.pool, ctx.a, ctx.identity_id);
    const time_format = user_settings.getEffectiveTimeFormat(ctx.pool, ctx.a, ctx.identity_id);
    const date_str = civil_time.formatDate(ctx.a, c, date_format);
    const time_str = civil_time.formatTime(ctx.a, c, time_format);
    const confirmation = std.fmt.allocPrint(ctx.a, "Reminder #{d} set for {s} {s}.", .{ id, date_str, time_str }) catch "Reminder set.";
    return menuSendAndShow(ctx, confirmation, .reminders);
}

/// Builds the synthetic `"<cmd> <captured input>"` string every awaiting-
/// input resume below feeds to an existing slash-command handler, so the
/// menu and the command end up running the literal same code (including
/// its own `auth.*` gate) rather than a re-implementation of it. `ctx.msg`
/// itself (not this string) is what carries a reply, if the user replied
/// instead of typing `@username`/an id/free text.
fn menuSyntheticText(ctx: menu.ActionContext, comptime cmd: []const u8) []const u8 {
    return std.fmt.allocPrint(ctx.a, cmd ++ " {s}", .{ctx.msg.text orelse ""}) catch cmd;
}

fn menuResumeViaText(ctx: menu.ActionContext, comptime cmd: []const u8, handler: fn (iface.Connector, std.mem.Allocator, *store_pool.PgPool, i64, iface.Message, []const u8) void) void {
    handler(ctx.connector, ctx.a, ctx.pool, ctx.now, ctx.msg, menuSyntheticText(ctx, cmd));
}

fn menuResumeViaTextAdd(ctx: menu.ActionContext, comptime cmd: []const u8, handler: fn (iface.Connector, std.mem.Allocator, *store_pool.PgPool, i64, i64, iface.Message, []const u8) void) void {
    handler(ctx.connector, ctx.a, ctx.pool, ctx.identity_id, ctx.now, ctx.msg, menuSyntheticText(ctx, cmd));
}

fn menuResumeViaCommand(ctx: menu.ActionContext, comptime cmd: []const u8, handler: fn (iface.Connector, std.mem.Allocator, *store_pool.PgPool, i64, iface.Message, []const u8) void) void {
    handler(ctx.connector, ctx.a, ctx.pool, ctx.now, ctx.msg, menuSyntheticText(ctx, cmd));
}

fn handleKickBanCommandKick(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8) void {
    handleKickBanCommand(connector, a, pool, now, msg, text, "/kick", .kick);
}

fn handleKickBanCommandBan(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8) void {
    handleKickBanCommand(connector, a, pool, now, msg, text, "/ban", .ban);
}

// Zig's test collector only walks `test` blocks reachable from the file
// passed to `addTest` — it does NOT transitively pull in tests from files
// that are merely `@import`ed for their declarations. Each module below
// that has its own `test` blocks must be explicitly re-referenced here (or
// `zig build test` silently runs zero of its tests, no error, no warning).
test {
    _ = auth;
    _ = @import("store/pool.zig");
    _ = @import("store/migrate.zig");
    _ = @import("store/identities.zig");
    _ = @import("store/chats.zig");
    _ = @import("store/chat_members.zig");
    _ = @import("store/chat_settings.zig");
    _ = @import("store/bot_config.zig");
    _ = @import("store/messages.zig");
    _ = @import("store/bot_admins.zig");
    _ = @import("store/bot_allowlist.zig");
    _ = @import("store/bot_pending_grants.zig");
    _ = @import("features/trivial_reply.zig");
    _ = @import("text/safe_regex.zig");
    _ = @import("features/redact.zig");
    _ = @import("features/menu_tree.zig");
    _ = @import("features/menu.zig");
    _ = @import("features/piechart.zig");
    _ = @import("text/civil_time.zig");
    _ = @import("store/user_settings.zig");
    _ = @import("store/accounts.zig");
    _ = @import("store/web_sessions.zig");
    _ = @import("store/feature_flags.zig");
    _ = @import("store/dynamic_config.zig");
    _ = @import("store/audit_log.zig");
    _ = @import("store/oauth_providers.zig");
    _ = @import("api/auth.zig");
    _ = @import("api/router.zig");
    _ = @import("api/multipart.zig");
    _ = @import("api/oidc.zig");
    _ = @import("api/server.zig");
    _ = @import("store/admin_directory.zig");
    _ = @import("llm/dynamic_provider.zig");
    _ = @import("store/stats.zig");
    _ = @import("store/reminders.zig");
    _ = @import("features/qa.zig");
    _ = @import("features/reminder_format.zig");
    _ = @import("tools/remind.zig");
    _ = @import("features/convert.zig");
    _ = @import("tools/convert_file.zig");
    _ = @import("store/alerts.zig");
    _ = @import("features/alerts.zig");
    _ = @import("tools/set_alert.zig");
    _ = @import("store/feed_watches.zig");
    _ = @import("features/feed_watcher.zig");
    _ = @import("features/feed_parse.zig");
    _ = @import("features/transcribe.zig");
    _ = @import("features/convert_flow.zig");
    _ = @import("tools/begin_conversion.zig");
    _ = @import("tools/find_chat_member.zig");
    _ = @import("llm/provider.zig");
    _ = @import("llm/anthropic.zig");
    _ = @import("llm/openai_compat.zig");
    _ = @import("tools/calculator.zig");
    _ = @import("llm/toolcall.zig");
    _ = @import("features/group_admin.zig");
    _ = @import("features/wordcloud.zig");
    _ = @import("tools/weather.zig");
    _ = @import("tools/currency.zig");
    _ = @import("tools/fetch_url.zig");
    _ = @import("tools/draw_diagram.zig");
    _ = @import("tools/web_search.zig");
    _ = @import("tools/air_quality.zig");
    _ = @import("tools/crypto_price.zig");
    _ = @import("tools/qr_code.zig");
    _ = @import("tools/word_cloud.zig");
    _ = @import("tools/dictionary.zig");
    _ = @import("tools/urban_dictionary.zig");
    _ = @import("tools/hackernews.zig");
    _ = @import("platform/telegram.zig");
    _ = @import("telegram/client.zig");
    _ = @import("telegram/markdown_html.zig");
    _ = @import("http_util.zig");
    _ = @import("features/scheduler.zig");
    _ = @import("features/digest.zig");
    _ = @import("tools/html_extract.zig");
    _ = @import("tools/scrape_site.zig");
    _ = @import("platform/interface.zig");
    _ = @import("domain/identity.zig");
    _ = @import("domain/telegram_profile.zig");
    _ = @import("platform/matrix.zig");
    _ = @import("matrix/types.zig");
    _ = @import("domain/matrix_profile.zig");
    _ = @import("matrix/olm.zig");
    _ = @import("matrix/verification.zig");
    _ = @import("matrix/crypto.zig");
    _ = @import("store/crypto.zig");
    _ = @import("platform/xmpp.zig");
    _ = @import("xmpp/xml.zig");
    _ = @import("xmpp/types.zig");
    _ = @import("xmpp/client.zig");
    _ = @import("domain/xmpp_profile.zig");
    _ = @import("worker_pool.zig");
    _ = @import("store/db.zig");
}

/// ASCII whitespace/punctuation counts as a boundary; bytes >= 0x80 do NOT,
/// so a UTF-8 word (e.g. Persian) embedded inside a longer word isn't a
/// false match, while the same word delimited by spaces/punctuation is.
fn isWordBoundary(c: u8) bool {
    return c < 0x80 and !std.ascii.isAlphanumeric(c);
}

/// Whole-word, ASCII-case-insensitive search — used for magic-word
/// detection so "Hassan," matches a magic word of "hassan" but
/// "hassanabad" doesn't.
fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;

    var start: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(haystack, start, needle)) |abs_idx| {
        const end_idx = abs_idx + needle.len;

        const left_ok = (abs_idx == 0) or isWordBoundary(haystack[abs_idx - 1]);
        const right_ok = (end_idx == haystack.len) or isWordBoundary(haystack[end_idx]);

        if (left_ok and right_ok) {
            return true;
        }

        start = abs_idx + 1;
    }

    return false;
}

test "containsWordIgnoreCase matches whole words in any ASCII case" {
    try std.testing.expect(containsWordIgnoreCase("hey Hassan, got a sec?", "hassan"));
    try std.testing.expect(containsWordIgnoreCase("HASSAN!", "hassan"));
    try std.testing.expect(containsWordIgnoreCase("hassan", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("hassanabad is a city", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("ahassan", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("nothing relevant", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("anything", ""));
}

test "containsWordIgnoreCase handles UTF-8 magic words" {
    // Persian "حسن" delimited by spaces/punctuation matches...
    try std.testing.expect(containsWordIgnoreCase("سلام حسن جان", "حسن"));
    try std.testing.expect(containsWordIgnoreCase("حسن!", "حسن"));
    // ...but the same bytes inside a longer word ("محسن") do not.
    try std.testing.expect(!containsWordIgnoreCase("محسن اومد", "حسن"));
}

fn replyTarget(msg: iface.Message) ?struct { user_id: []const u8, label: []const u8 } {
    const user_id = msg.reply_to_user_id orelse return null;
    const label = msg.reply_to_username orelse user_id;
    return .{ .user_id = user_id, .label = label };
}

fn reply(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, reply_to: ?[]const u8, comptime txt: []const u8) void {
    connector.sendMessage(a, chat_id, txt, reply_to);
}
