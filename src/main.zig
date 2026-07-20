const std = @import("std");
const Io = std.Io;

const config_mod = @import("config.zig");
const auth = @import("auth.zig");
const iface = @import("platform/interface.zig");
const Identity = @import("domain/identity.zig").Identity;
const telegram_platform = @import("platform/telegram.zig");
const matrix_platform = @import("platform/matrix.zig");
const xmpp_platform = @import("platform/xmpp.zig");
const store_pool = @import("store/pool.zig");
const migrate = @import("store/migrate.zig");
const chats = @import("store/chats.zig");
const identities = @import("store/identities.zig");
const chat_members = @import("store/chat_members.zig");
const chat_settings = @import("store/chat_settings.zig");
const bot_config = @import("store/bot_config.zig");
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
const toolcall = @import("llm/toolcall.zig");
const tool_registry = @import("tools/registry.zig");
const group_admin = @import("features/group_admin.zig");
const wordcloud = @import("features/wordcloud.zig");
const digest = @import("features/digest.zig");
const scheduler = @import("features/scheduler.zig");
const convert_file = @import("tools/convert_file.zig");

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
/// including the owner-only `/token`/`/scraper` deliberately left out of
/// this public menu (see their own dispatch-table gates in `handleMessage`).
const public_commands = [_]iface.CommandSpec{
    .{ .name = "help", .description = "Show available commands and how to talk to Warden." },
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
    .{ .name = "kick", .description = "Reply to a user's message to remove them. Admins only." },
    .{ .name = "ban", .description = "Reply to a user's message to permanently ban them. Admins only." },
    .{ .name = "promote", .description = "Reply to a user's message to grant them admin. Bot owner only." },
    .{ .name = "demote", .description = "Reply to a user's message to revoke their admin. Bot owner only." },
    .{ .name = "confirm", .description = "Confirm a pending /kick or /ban. Admins only." },
    .{ .name = "cancel", .description = "Cancel your pending file conversion, or a pending /kick or /ban." },
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
    \\/mute, /unmute, /pin, /unpin, /delete, /kick, /ban -- reply to the
    \\  target message/user (unpin doesn't need a reply)
    \\/promote, /demote -- reply to a user's message to grant/revoke real
    \\  admin rights. Bot owner only, not open to other chat admins
    \\/confirm -- confirm a pending /kick or /ban
    \\/cancel -- cancel your pending file conversion, or a pending
    \\  /kick/ban if you're an admin
    \\
    \\Bot owner only
    \\/token -- reply to a user's message to view/set their token count
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

    const config = config_mod.Config.load(init.environ_map, init.arena.allocator(), io) catch |err| {
        std.log.err("config error: {t} (did you set WARDEN_TELEGRAM_BOT_TOKEN and WARDEN_POSTGRES_DSN?)", .{err});
        return err;
    };

    // web_search only joins the tool list when an instance is configured,
    // so the model never sees a tool that's guaranteed to fail.
    var tools_buf: [base_tools.len + 1]tool_registry.ToolDef = undefined;
    @memcpy(tools_buf[0..base_tools.len], &base_tools);
    var tools_len: usize = base_tools.len;
    if (config.searxng_url != null) {
        tools_buf[tools_len] = web_search_tool;
        tools_len += 1;
    } else {
        std.log.info("web search disabled (set WARDEN_SEARXNG_URL to enable)", .{});
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

    var pool = try store_pool.PgPool.init(gpa, io, config.postgres_dsn, config.postgres_pool_size);
    defer pool.deinit();
    {
        const db = try pool.acquire();
        defer pool.release(db);
        try migrate.migrate(db, gpa);
    }

    // Device key creation/upload plus ongoing encrypt/decrypt for Matrix
    // E2E encryption (see src/matrix/olm.zig, src/matrix/crypto.zig,
    // ROADMAP.md's Phase 2b) — only active when `WARDEN_MATRIX_PICKLE_KEY`
    // is set; a failure here is logged, not fatal, since plaintext-room
    // Matrix functionality doesn't depend on it.
    if (matrix_adapter) |*m| {
        if (config.matrix_pickle_key) |pickle_key| {
            m.enableCrypto(gpa, io, &pool, pickle_key) catch |err| {
                std.log.err("matrix e2ee: device key setup failed: {t}", .{err});
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

    // Heap-allocated: whichever variant isn't selected never gets
    // constructed, and the process-lifetime singleton is fine to leave for
    // the OS to reclaim on exit rather than threading a deinit through
    // both branches here.
    const llm_provider: llm.Provider = switch (config.llm) {
        .anthropic => |a| blk: {
            const p = try gpa.create(AnthropicProvider);
            p.* = AnthropicProvider.init(gpa, io, a.api_key, a.model);
            break :blk p.provider();
        },
        .openai_compat => |o| blk: {
            const p = try gpa.create(OpenAiCompatProvider);
            p.* = OpenAiCompatProvider.init(gpa, io, o.base_url, o.api_key, o.model);
            break :blk p.provider();
        },
    };

    std.log.info("warden started, {d} connector(s), {d} owner(s) configured", .{ connectors.len, config.owners.len });

    // Best-effort: a platform without the concept (or a transient API
    // failure) just means commands don't autocomplete, not a startup
    // failure — the commands themselves work regardless via `handleMessage`.
    for (connectors) |connector| {
        connector.setCommands(gpa, &public_commands) catch |err| {
            if (err != error.Unsupported) {
                std.log.warn("failed to publish command menu for {s}: {t}", .{ @tagName(connector.platform()), err });
            }
        };
    }

    // Long-lived: every per-message task, and now every connector's own
    // poll loop below, is spawned into this one group (never awaited/
    // canceled during normal operation — see `Group`'s doc comment on why
    // that's fine for a repeatedly-added-to, long-lived group).
    var worker_group: Io.Group = .init;

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
    // `worker_group.async`: `Io.Threaded`'s async/group pool is bounded
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
    // matching how nothing here ever joins `worker_group`'s tasks either.
    for (connectors) |connector| {
        const thread = std.Thread.spawn(.{}, connectorPollLoop, .{
            connector,
            &config,
            &pool,
            llm_provider,
            active_tools,
            &pending_confirmations,
            &digest_scheduler,
            &pending_conversions,
            io,
            gpa,
            max_message_len,
            &worker_group,
        }) catch |err| {
            std.log.err("failed to start poll loop thread for {t}: {t}", .{ connector.platform(), err });
            continue;
        };
        thread.detach();
    }

    // Due-digest/reminder/alert/feed checks used to piggyback on the old
    // round-robin loop's natural ~30s-ish cadence; now that connectors
    // poll independently (no shared "lap" to hang off of), this is its own
    // explicit ~30s ticker instead — same granularity as before.
    while (true) {
        const now = Io.Timestamp.now(io, .real).toSeconds();
        checkAndSendDueDigests(connectors, gpa, io, &config, &pool, &digest_scheduler, llm_provider, max_message_len, now);
        checkAndSendDueReminders(connectors, gpa, &pool, now);
        alert_feature.checkAndDeliverAlerts(connectors, gpa, io, &pool, now);
        feed_watcher.checkAndNotifyFeeds(connectors, gpa, io, &pool, llm_provider, now);
        pending_conversions.sweepExpired(gpa, now);
        Io.sleep(io, .fromSeconds(30), .awake) catch {};
    }
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
    io: Io,
    gpa: std.mem.Allocator,
    max_message_len: usize,
    worker_group: *Io.Group,
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
                => std.log.warn("poll connection dropped (will re-poll): {t}", .{err}),
                else => std.log.err("poll failed: {t}", .{err}),
            }
            // A failed poll returns immediately instead of blocking for
            // the ~30s long-poll window, so during an outage this loop
            // would otherwise spin against a dead network. Cool off before
            // the next attempt — this connector's own cooldown, no longer
            // one that stalls every other connector's turn too.
            Io.sleep(io, .fromSeconds(5), .awake) catch {};
            continue;
        };

        for (polled_messages) |msg| {
            const ts = Io.Timestamp.now(io, .real).toSeconds();

            // Each task owns an arena for its whole lifetime, created here
            // (not shared with `poll_arena`, which this cycle frees as
            // soon as every message in it has been spawned off) and freed
            // by the task itself when it's done. `msg` is duped into it
            // right away, before `poll_arena` can be freed out from under
            // a task that hasn't started yet.
            const task_arena = gpa.create(std.heap.ArenaAllocator) catch |err| {
                std.log.err("failed to allocate task arena: {t}", .{err});
                continue;
            };
            task_arena.* = std.heap.ArenaAllocator.init(gpa);
            const duped_msg = msg.dupe(task_arena.allocator()) catch |err| {
                std.log.err("failed to dupe message for chat {s}: {t}", .{ msg.chat_id, err });
                task_arena.deinit();
                gpa.destroy(task_arena);
                continue;
            };

            worker_group.async(io, processMessageTask, .{
                connector,
                config,
                pool,
                llm_provider,
                tools,
                pending,
                digest_scheduler,
                pending_conversions,
                io,
                gpa,
                ts,
                max_message_len,
                task_arena,
                duped_msg,
            });
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

/// Body of one spawned per-message task (see `worker_group` above). Owns
/// `task_arena` end-to-end: created by the caller right before spawning
/// (so `duped_msg` has somewhere stable to live), destroyed here once this
/// message is fully handled.
fn processMessageTask(
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    pending_conversions: *convert_flow.PendingConversions,
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
    const a = task_arena.allocator();

    const chat_id = chats.upsertChat(pool, connector.platform(), msg.chat_id, msg.chat_type, msg.chat_title) catch |err| {
        std.log.err("failed to upsert chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };

    // Every group member's message counts toward this chat's local record
    // (stats/content recall), regardless of who sent it — only
    // replies/actions are owner-gated below. A button press/reaction
    // (`choice_picked`) isn't real conversational content — skip logging it
    // so it doesn't show up as a stray empty-text row in /wordcloud or the
    // LLM's history window.
    const identity_id = resolveSenderIdentity(pool, connector, msg, ts) catch |err| {
        std.log.err("failed to resolve identity for user {s}: {t}", .{ msg.user_id, err });
        return;
    };
    if (msg.choice_picked == null) {
        recordMessage(pool, chat_id, identity_id, msg.message_id, msg.text, ts, config.retention_messages);
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
    const claimed = handleMessage(connector, a, config, pool, chat_id, identity_id, llm_provider, tool_ctx, tools, pending, digest_scheduler, pending_conversions, io, ts, max_message_len, msg);
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
        std.log.warn("attachment: download failed for file_id {s}: {t}", .{ att.file_id, err });
        return null;
    };
    defer allocator.free(bytes);

    Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| {
        std.log.warn("attachment: failed to create tmp dir {s}: {t}", .{ tmp_dir, err });
        return null;
    };

    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const path = std.fmt.allocPrint(allocator, "{s}/attach_{d}{s}", .{ tmp_dir, ts, extensionFor(att) }) catch return null;

    var file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.log.warn("attachment: failed to create {s}: {t}", .{ path, err });
        return null;
    };
    defer file.close(io);
    var file_writer = file.writer(io, &.{});
    file_writer.interface.writeAll(bytes) catch |err| {
        std.log.warn("attachment: failed to write {s}: {t}", .{ path, err });
        return null;
    };
    file_writer.interface.flush() catch |err| {
        std.log.warn("attachment: failed to flush {s}: {t}", .{ path, err });
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

fn resolveQuestion(connector: iface.Connector, a: std.mem.Allocator, io: Io, config: *const config_mod.Config, tool_ctx: tool_registry.ToolContext, msg: iface.Message, text: []const u8) ResolvedQuestion {
    if (text.len > 0) return .{ .text = text };
    const att = msg.attachment orelse return .{ .text = text };

    if (att.kind == .voice) {
        if (config.whisper_url) |whisper_url| {
            if (tool_ctx.attachment_path) |path| {
                const placeholder_id = connector.sendMessageReturningId(a, msg.chat_id, "🎙️ Transcribing your voice message…", msg.message_id) catch |err| blk: {
                    std.log.warn("transcribe: couldn't send a placeholder for chat {s}: {t}", .{ msg.chat_id, err });
                    break :blk null;
                };
                if (transcribe.transcribe(a, io, whisper_url, config.tmp_dir, path)) |transcript| {
                    if (transcript.len > 0) return .{ .text = transcript, .placeholder_id = placeholder_id };
                } else |err| {
                    std.log.warn("transcribe: failed for chat {s}: {t}", .{ msg.chat_id, err });
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
    if (msg.identity) |identity| {
        const identity_id = try identities.upsertIdentity(pool, identity);
        if (msg.telegram_profile) |profile| {
            identities.upsertTelegramProfile(pool, identity_id, profile) catch |err| {
                std.log.err("failed to upsert telegram profile for identity {d}: {t}", .{ identity_id, err });
            };
        }
        if (msg.matrix_profile) |profile| {
            identities.upsertMatrixProfile(pool, identity_id, profile) catch |err| {
                std.log.err("failed to upsert matrix profile for identity {d}: {t}", .{ identity_id, err });
            };
        }
        if (msg.xmpp_profile) |profile| {
            identities.upsertXmppProfile(pool, identity_id, profile) catch |err| {
                std.log.err("failed to upsert xmpp profile for identity {d}: {t}", .{ identity_id, err });
            };
        }
        return identity_id;
    }
    return identities.getOrCreateMinimal(pool, connector.platform(), msg.user_id, msg.username orelse msg.user_id, false, ts);
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
            std.log.err("failed to upsert observed identity {s} for chat {d}: {t}", .{ identity.native_id, chat_id, err });
            continue;
        };
        chat_members.ensureKnown(pool, chat_id, identity_id) catch |err| {
            std.log.err("failed to register observed member {s} for chat {d}: {t}", .{ identity.native_id, chat_id, err });
        };
    }
}

/// Logs one message and bumps the sender's chat-membership record, then
/// prunes to the retention window — replaces the old `ChatStore.record`.
/// Errors are logged, not propagated: a storage hiccup shouldn't take down
/// the poll loop.
fn recordMessage(pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, message_id: ?[]const u8, text: ?[]const u8, ts: i64, retention: i64) void {
    messages.insert(pool, chat_id, identity_id, message_id, text, ts) catch |err| {
        std.log.err("failed to insert message for chat {d}: {t}", .{ chat_id, err });
        return;
    };
    chat_members.touch(pool, chat_id, identity_id, ts) catch |err| {
        std.log.err("failed to touch chat_members for chat {d}: {t}", .{ chat_id, err });
    };
    messages.pruneKeepLast(pool, chat_id, retention) catch |err| {
        std.log.err("prune failed for chat {d}: {t}", .{ chat_id, err });
    };
}

/// Rebuilds the in-memory enabled-chat set from every known chat's
/// persisted `chat_settings.digest_enabled` — so digests opted into before
/// a restart keep firing rather than silently going quiet.
fn loadDigestScheduleFromDisk(gpa: std.mem.Allocator, pool: *store_pool.PgPool, digest_scheduler: *scheduler.DigestScheduler) void {
    const refs = chats.listAll(pool, gpa) catch |err| {
        std.log.err("digest: failed to scan existing chats: {t}", .{err});
        return;
    };
    defer {
        for (refs) |r| gpa.free(r.native_chat_id);
        gpa.free(refs);
    }

    for (refs) |ref| {
        if (chat_settings.getDigestEnabled(pool, ref.id)) {
            digest_scheduler.enable(ref.platform, ref.native_chat_id) catch |err| {
                std.log.err("digest: failed to restore schedule for chat {s}: {t}", .{ ref.native_chat_id, err });
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
        std.log.err("digest: failed to snapshot enabled chats: {t}", .{err});
        return;
    };
    defer {
        for (enabled_chats) |k| gpa.free(k.native_chat_id);
        gpa.free(enabled_chats);
    }

    for (enabled_chats) |key| {
        const native_chat_id = key.native_chat_id;
        const connector = findConnector(connectors, key.platform) orelse {
            std.log.warn("digest: no active connector for platform {s}, skipping chat {s}", .{ @tagName(key.platform), native_chat_id });
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // `chat_type`/`title` null: this isn't a fresh inbound message, just
        // a scheduled check, and `upsertChat` preserves whatever's already
        // stored for those columns when passed null (see its doc comment).
        const chat_id = chats.upsertChat(pool, connector.platform(), native_chat_id, null, null) catch |err| {
            std.log.err("digest: failed to resolve chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };

        const last_sent = chat_settings.getLastDigestTs(pool, chat_id);
        if (now - last_sent < config.digest_interval_seconds) continue;

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
            std.log.err("digest: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };
        sendTextOrFile(connector, a, native_chat_id, digest_text, null, max_message_len, "digest.txt");
        chat_settings.setLastDigestTs(pool, chat_id, now) catch |err| {
            std.log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ native_chat_id, err });
        };
    }
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
    io: Io,
    now: i64,
    max_message_len: usize,
    msg: iface.Message,
) bool {
    // A button press / reaction pick has neither text nor an attachment of
    // its own, so this must run before the "neither" bail-out just below.
    if (msg.choice_picked) |picked| {
        convert_flow.handleChoicePicked(connector, a, io, config.tmp_dir, pending_conversions, now, msg, picked);
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
    const text = normalizeCommandMention(a, raw_text, connector.selfUsername()) orelse return false;

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
    } else if (std.mem.eql(u8, text, "/stats")) {
        replyWithStats(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/wordcloud")) {
        replyWithWordcloud(connector, a, pool, chat_id, config.tmp_dir, io, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/digest") or std.mem.startsWith(u8, text, "/digest ")) {
        handleDigestCommand(connector, a, pool, chat_id, digest_scheduler, llm_provider, tool_ctx, now, max_message_len, msg.chat_id, msg.message_id, text);
    } else if (std.mem.eql(u8, text, "/mute")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.mute(connector, a, msg, now);
    } else if (std.mem.eql(u8, text, "/unmute")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.unmute(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/pin")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.pin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/unpin")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.unpin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/delete")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.deleteMessage(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/promote")) {
        // Owner-only, not `isAuthorizedForGroupAdmin` — granting real
        // admin rights is more consequential than mute/kick/pin, and
        // Telegram's own admin flag doesn't tell us whether a given admin
        // actually has permission to add further admins themselves (see
        // `group_admin.promote`'s doc comment).
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        group_admin.promote(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/demote")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        group_admin.demote(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/kick")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.requestConfirmation(connector, a, pool, chat_id, now, msg, .kick);
    } else if (std.mem.eql(u8, text, "/ban")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.requestConfirmation(connector, a, pool, chat_id, now, msg, .ban);
    } else if (std.mem.eql(u8, text, "/confirm")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
        group_admin.confirm(connector, a, pending, now, msg);
    } else if (std.mem.eql(u8, text, "/cancel")) {
        // Dual-purpose: a pending conversion is per-user, not a moderation
        // action, so it can only ever affect something the sender
        // themselves started — no admin gate needed for that half. Falls
        // through to the existing admin-gated ban/kick cancel, unchanged,
        // only when there's nothing of the sender's own to cancel.
        if (pending_conversions.cancel(a, msg.chat_id, msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Conversion cancelled.");
        } else {
            if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return false;
            group_admin.cancel(connector, a, pending, msg);
        }
    } else if (std.mem.startsWith(u8, text, "/token")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleToken(connector, a, pool, chat_id, now, msg, text);
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
        handleRemindCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/reminders")) {
        handleRemindersList(connector, a, pool, chat_id, now, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/convert")) {
        // Bare /convert, no attachment claimed above (either none present,
        // or claiming it failed) — start (or restart) the multi-stage flow.
        convert_flow.beginConvertFlow(connector, a, pending_conversions, now, msg);
    } else if (std.mem.startsWith(u8, text, "/convert ")) {
        // UNCHANGED one-shot path: /convert <format> as an attachment's
        // caption, calling convert_file directly, no LLM round trip.
        handleConvertCommand(connector, a, tool_ctx, msg, text);
    } else if (std.mem.eql(u8, text, "/alert") or std.mem.startsWith(u8, text, "/alert ")) {
        handleAlertCommand(connector, a, config, pool, chat_id, identity_id, msg, text);
    } else if (std.mem.eql(u8, text, "/alerts")) {
        handleAlertsList(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/watch") or std.mem.startsWith(u8, text, "/watch ")) {
        handleWatchCommand(connector, a, pool, chat_id, identity_id, msg, text);
    } else if (std.mem.eql(u8, text, "/unwatch") or std.mem.startsWith(u8, text, "/unwatch ")) {
        handleUnwatchCommand(connector, a, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/watches")) {
        handleWatchesList(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/watchcheck") or std.mem.startsWith(u8, text, "/watchcheck ")) {
        handleWatchCheckCommand(connector, a, pool, io, llm_provider, chat_id, msg, text, now);
    } else if (text.len > 0 and text[0] == '/') {
        // Unrecognized slash command: ignore rather than forwarding to the
        // LLM as if it were a question.
        return false;
    } else if (isAddressedToBot(a, pool, chat_id, msg, text)) {
        // The bot's free-form LLM Q&A is owner-only by default (toggle via
        // WARDEN_LLM_OWNER_ONLY) — every other command above this stays
        // open to anyone (unchanged). Silent, not an error reply: an
        // unaddressed mention from someone else shouldn't announce "I only
        // answer my owner" to the whole group.
        if (config.llm_owner_only and !auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        const replied_to = if (msg.reply_to_is_me) msg.reply_to_text else null;
        const resolved = resolveQuestion(connector, a, io, config, tool_ctx, msg, text);
        // Per-chat /persona override, falling back to the global default —
        // see `store/chat_settings.zig`'s `getSystemPromptOverride`.
        const system_prompt = chat_settings.getSystemPromptOverride(pool, a, chat_id) orelse config.system_prompt;
        // Per-chat /thinking override, falling back to the global default —
        // see `store/chat_settings.zig`'s `getShowThinkingOverride`.
        const show_thinking = chat_settings.getShowThinkingOverride(pool, chat_id) orelse config.llm_show_thinking;
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
        replyWithAnswer(connector, a, pool, chat_id, llm_provider, tool_ctx, tools, system_prompt, io, now, config.retention_messages, max_message_len, msg.chat_id, msg.message_id, asker, resolved.text, replied_to, resolved.placeholder_id, config.llm_streaming, show_thinking);
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

/// Gate for every group-management command (/mute, /kick, /ban, etc.) —
/// the bot owner always passes (no network round trip needed), otherwise
/// this asks Telegram directly whether the sender currently administers
/// this chat. Queried fresh each time rather than cached, since admin
/// status can change at any moment; any error (network hiccup, or a
/// platform connector that doesn't implement `isGroupAdmin` at all) fails
/// closed — treated as "not authorized" rather than silently allowing the
/// action through. Silent on rejection, matching /token's and /scraper's
/// existing owner-gate convention rather than announcing "you're not
/// allowed" to the chat.
fn isAuthorizedForGroupAdmin(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, msg: iface.Message) bool {
    if (auth.isOwner(config, connector.platform(), msg.user_id)) return true;
    return connector.isGroupAdmin(a, msg.chat_id, msg.user_id) catch |err| {
        std.log.warn("group_admin: admin check failed for user {s} in chat {s}: {t}", .{ msg.user_id, msg.chat_id, err });
        return false;
    };
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
            std.log.err("magicword: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
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
        std.log.err("magicword: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
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

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change this chat's persona.");
        return;
    }

    if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setSystemPromptOverride(pool, chat_id, null) catch |err| {
            std.log.err("persona: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
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
        std.log.err("persona: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
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
            std.log.err("thinking: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Thinking will be shown for this chat.");
    } else if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setShowThinkingOverride(pool, chat_id, false) catch |err| {
            std.log.err("thinking: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Thinking will be hidden for this chat.");
    } else if (std.mem.eql(u8, arg, "default")) {
        chat_settings.setShowThinkingOverride(pool, chat_id, null) catch |err| {
            std.log.err("thinking: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
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
                std.log.err("scraper: failed to set mode for global settings: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update the scraper mode, try again.");
                return;
            };
            const confirmation = std.fmt.allocPrint(a, "Scraper mode set to remote ({s}).", .{snap.remote_url.?}) catch return;
            connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        } else if (std.mem.eql(u8, rest, "local")) {
            bot_config.setScraperMode(pool, .local) catch |err| {
                std.log.err("scraper: failed to set mode for global settings: {t}", .{err});
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
            std.log.err("scraper: failed to set remote url: {t}", .{err});
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that endpoint, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper endpoint saved. Switch to it with /scraper mode remote.");
    } else if (std.mem.eql(u8, sub, "apikey")) {
        if (rest.len == 0 or std.mem.eql(u8, rest, "off")) {
            bot_config.setScraperRemoteApiKey(pool, null) catch |err| {
                std.log.err("scraper: failed to clear remote api key: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't clear the API key, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper API key cleared.");
        } else {
            bot_config.setScraperRemoteApiKey(pool, rest) catch |err| {
                std.log.err("scraper: failed to set remote api key: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save the API key, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper API key saved.");
        }
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /scraper [mode local|remote] [url <endpoint>] [apikey <key>|off]");
    }
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
    const target = replyTarget(msg) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user you want to view/change tokens for.");
        return;
    };
    const arg = std.mem.trim(u8, text["/token".len..], " ");
    const target_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), target.user_id, target.label, false, now) catch |err| {
        std.log.err("token: failed to resolve identity for user {s}: {t}", .{ target.user_id, err });
        return;
    };
    // If there is no argument, get the current token count and reply with it.
    if (arg.len == 0) {
        const count = chat_members.getTokens(pool, chat_id, target_identity_id, 0);
        const message = std.fmt.allocPrint(a, "Current token count: {}", .{count}) catch |err| {
            std.debug.print("Failed to allocate message string: {}\n", .{err});
            return; // Exit the function early since we couldn't format the message
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    // Else just set the token count to the parsed value and reply with a confirmation.
    else {
        const count = std.fmt.parseInt(i64, arg, 10) catch 0;
        std.log.info("Detected the count to be {}", .{count});
        chat_members.setTokens(pool, chat_id, target_identity_id, count) catch |err| {
            std.log.err("Failed to set tokens on the databse: {}\n", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "token count updated to {}", .{count}) catch |err| {
            std.log.err("Failed to allocate message string: {}\n", .{err});
            return; // Exit the function early since we couldn't format the message
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
    }
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
            std.log.err("digest: failed to enable for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't enable digests, try again.", reply_to);
            return;
        };
        chat_settings.setDigestEnabled(pool, chat_id, true) catch |err| {
            std.log.err("digest: failed to persist enabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        const hours = @divTrunc(digest_scheduler.interval_seconds, 3600);
        const msg_text = std.fmt.allocPrint(a, "Digest enabled — I'll post one roughly every {d}h.", .{hours}) catch return;
        connector.sendMessage(a, native_chat_id, msg_text, reply_to);
    } else if (std.mem.eql(u8, arg, "off")) {
        digest_scheduler.disable(a, connector.platform(), native_chat_id);
        chat_settings.setDigestEnabled(pool, chat_id, false) catch |err| {
            std.log.err("digest: failed to persist disabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        connector.sendMessage(a, native_chat_id, "Digest disabled.", reply_to);
    } else if (std.mem.eql(u8, arg, "now")) {
        const digest_text = digest.generate(llm_provider, a, tool_ctx, pool, chat_id) catch |err| {
            std.log.err("digest: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't generate a digest just now.", reply_to);
            return;
        };
        sendTextOrFile(connector, a, native_chat_id, digest_text, reply_to, max_message_len, "digest.txt");
        chat_settings.setLastDigestTs(pool, chat_id, now) catch |err| {
            std.log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ native_chat_id, err });
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
    const usage = "Usage: /remind <duration e.g. 30m/2h/1d, or a clock time like 14:30> <message>, /remind every <interval> <message>, or /remind cancel <id>";
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
            std.log.err("remind: lookup failed for id {d}: {t}", .{ id, err });
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
            std.log.err("remind: cancel failed for id {d}: {t}", .{ id, err });
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

    const due_at = if (recur_interval) |interval|
        now + interval
    else
        reminder_format.parseWhen(when_str, now) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that time — use a duration like 30m/2h/1d, or a 24h clock time like 14:30.");
            return;
        };

    const id = reminders.create(pool, chat_id, identity_id, message, due_at, recur_interval) catch |err| {
        std.log.err("remind: failed to create reminder for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that reminder, try again.");
        return;
    };

    const confirmation = if (recur_interval) |interval|
        std.fmt.allocPrint(a, "Reminder #{d} set, repeating every {s}.", .{ id, reminder_format.formatInterval(a, interval) }) catch return
    else if (reminder_format.parseDuration(when_str) != null)
        std.fmt.allocPrint(a, "Reminder #{d} set for {s} from now.", .{ id, when_str }) catch return
    else
        std.fmt.allocPrint(a, "Reminder #{d} set for {s}.", .{ id, when_str }) catch return;
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
        std.log.err("reminders: list failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't load reminders, try again.", reply_to);
        return;
    };
    connector.sendMessage(a, native_chat_id, formatPendingReminders(a, pending, now), reply_to);
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
            std.log.err("alert: lookup failed for id {d}: {t}", .{ id, err });
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
            std.log.err("alert: cancel failed for id {d}: {t}", .{ id, err });
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
        std.log.err("alert: failed to create alert for chat {d}: {t}", .{ chat_id, err });
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
        std.log.err("alerts: list failed for chat {d}: {t}", .{ chat_id, err });
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
    const created = feed_watches.create(pool, chat_id, identity_id, feed_url) catch |err| {
        std.log.err("watch: failed to add feed {s} for chat {d}: {t}", .{ feed_url, chat_id, err });
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
        std.log.err("unwatch: failed to remove feed {s} for chat {d}: {t}", .{ feed_url, chat_id, err });
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
        std.log.err("watches: list failed for chat {d}: {t}", .{ chat_id, err });
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
        std.log.err("watchcheck: failed for {s} in chat {d}: {t}", .{ feed_url, chat_id, err });
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
        std.log.warn("convert: couldn't send a placeholder for chat {s}: {t}", .{ msg.chat_id, err });
        break :blk null;
    };

    const input_json = std.json.Stringify.valueAlloc(a, .{ .target_format = arg }, .{}) catch return;
    const result = convert_file.tool.execute(tool_ctx, input_json) catch |err| {
        std.log.err("convert: /convert command failed: {t}", .{err});
        convert_flow.finalizePlaceholder(connector, a, msg.chat_id, placeholder_id, msg.message_id, "Something went wrong converting that file, try again.");
        return;
    };
    convert_flow.finalizePlaceholder(connector, a, msg.chat_id, placeholder_id, msg.message_id, result);
}

/// Shared by `/reminders` and the `set_reminder` LLM tool's `action=list`.
fn formatPendingReminders(a: std.mem.Allocator, pending: []const reminders.PendingReminder, now: i64) []const u8 {
    if (pending.len == 0) return "No pending reminders. Set one with /remind <duration> <message> (or just ask).";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Pending reminders:\n", .{}) catch return "";
    for (pending) |r| {
        if (r.recur_interval_seconds) |interval| {
            w.print("  #{d} in {s} (repeats every {s}): {s}\n", .{ r.id, reminder_format.formatRemaining(a, r.due_at - now), reminder_format.formatInterval(a, interval), r.message }) catch return "";
        } else {
            w.print("  #{d} in {s}: {s}\n", .{ r.id, reminder_format.formatRemaining(a, r.due_at - now), r.message }) catch return "";
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
        return formatPendingReminders(allocator, pending, self.now);
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
                std.log.warn("find_chat_member: admin refresh failed for chat {s}: {t}", .{ self.native_chat_id, err });
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
        std.log.err("remind: failed to query due reminders: {t}", .{err});
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
            std.log.warn("remind: no active connector for platform {s}, leaving reminder {d} pending", .{ @tagName(r.platform), r.id });
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
                std.log.err("remind: failed to reschedule recurring reminder {d}: {t}", .{ r.id, err });
            };
        } else {
            reminders.markDelivered(pool, r.id, now) catch |err| {
                std.log.err("remind: failed to mark reminder {d} delivered: {t}", .{ r.id, err });
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
                std.log.warn("ticker: edit failed for chat {s}: {t}", .{ chat_id, err });
            };
            last_sent = text;
        }
    }
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
) void {
    // The placeholder + ticker only work when the platform supports
    // editing (Telegram does); anything that doesn't falls back to
    // exactly the old behavior — one blocking call, one send at the end.
    // `existing_placeholder_id` (from `resolveQuestion`'s "🎙️
    // Transcribing…" placeholder) is reused and morphed rather than
    // sending a second message right after it.
    const placeholder_id = if (existing_placeholder_id) |pid| blk: {
        connector.editMessage(a, native_chat_id, pid, thinking_text) catch |err| {
            std.log.warn("qa: couldn't morph the transcription placeholder for chat {s}: {t}", .{ native_chat_id, err });
        };
        break :blk pid;
    } else connector.sendMessageReturningId(a, native_chat_id, thinking_text, reply_to) catch |err| blk: {
        std.log.warn("qa: couldn't send a placeholder for chat {s}, falling back to a plain reply: {t}", .{ native_chat_id, err });
        break :blk null;
    };
    std.log.info("qa: placeholder for chat {s} = {?s}", .{ native_chat_id, placeholder_id });

    var state = TickerState{ .io = io, .allocator = a, .max_len = max_message_len };
    var progress: toolcall.Progress = .{};
    var ticker_future: ?Io.Future(void) = null;
    if (placeholder_id) |pid| {
        progress = .{ .ptr = &state, .onEvent = onProgressEvent };
        ticker_future = Io.concurrent(io, tickerLoop, .{ connector, native_chat_id, pid, &state }) catch |err| blk: {
            std.log.warn("qa: couldn't start the thinking animation for chat {s}: {t}", .{ native_chat_id, err });
            break :blk null;
        };
    }

    std.log.info("qa: calling the model for chat {s}", .{native_chat_id});
    const raw_answer_or_err = qa.answer(llm_provider, a, tool_ctx, tools, pool, chat_id, system_prompt, max_message_len, asker, question, replied_to, progress, stream, show_thinking);

    // Stop the ticker before touching the placeholder ourselves — it's the
    // sole owner of that Future until this point (see `Future.cancel`'s
    // "not threadsafe" note), and cancel() blocks until it has actually
    // stopped, so there's no risk of it clobbering the final edit below.
    if (ticker_future) |*f| _ = f.cancel(io);
    std.log.info("qa: model call for chat {s} returned", .{native_chat_id});

    const raw_answer = raw_answer_or_err catch |err| {
        std.log.err("qa: failed to answer in chat {s}: {t}", .{ native_chat_id, err });
        const error_text = "Sorry, I couldn't reach the model just now.";
        if (placeholder_id) |pid| {
            if (connector.editMessage(a, native_chat_id, pid, error_text)) |_| {
                std.log.info("qa: error message edited into placeholder for chat {s}", .{native_chat_id});
            } else |edit_err| {
                std.log.warn("qa: editing error message into placeholder failed for chat {s}: {t}, sending a new message instead", .{ native_chat_id, edit_err });
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
    std.log.info("qa: answer for chat {s} is {d} bytes (raw {d})", .{ native_chat_id, answer.len, raw_answer.len });
    if (answer.len == 0) {
        std.log.info("qa: empty answer for chat {s}, deleting placeholder", .{native_chat_id});
        if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
            // Previously swallowed silently — if this fails (network
            // hiccup, message already gone), the placeholder is stuck
            // showing "thinking" forever with zero trace of why. At least
            // log it; there's no good fallback text to edit in instead
            // since there was never a real answer to show.
            std.log.warn("qa: failed to delete empty-answer placeholder for chat {s}: {t}", .{ native_chat_id, err });
        };
        return;
    }

    if (answer.len > max_message_len) {
        // Too long for this platform's limit — editing the placeholder
        // in-place with it would just fail the same way sending it fresh
        // would, so drop the placeholder and attach it as a file instead.
        std.log.info("qa: answer for chat {s} exceeds max_message_len ({d} > {d}), sending as a file", .{ native_chat_id, answer.len, max_message_len });
        if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
            std.log.warn("qa: failed to delete placeholder before file fallback for chat {s}: {t}", .{ native_chat_id, err });
        };
        sendTextOrFile(connector, a, native_chat_id, answer, reply_to, max_message_len, "answer.txt");
    } else if (placeholder_id) |pid| {
        if (connector.editMessage(a, native_chat_id, pid, answer)) |_| {
            std.log.info("qa: final answer edited into placeholder for chat {s}", .{native_chat_id});
        } else |err| {
            std.log.warn("qa: final edit failed for chat {s}, sending a new message instead: {t}", .{ native_chat_id, err });
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
    const bot_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), connector.selfId() orelse "warden", bot_username, true, now) catch |err| {
        std.log.err("qa: failed to resolve bot identity for chat {s}: {t}", .{ native_chat_id, err });
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
        std.log.err("wordcloud: tokenize failed for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };
    if (words.len == 0) {
        connector.sendMessage(a, native_chat_id, "Not enough logged messages yet to build a word cloud.", reply_to);
        return;
    }
    const png = wordcloud.render(a, io, tmp_dir, words) catch |err| {
        std.log.err("wordcloud: render failed for chat {s}: {t}", .{ native_chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't render the word cloud (is Node installed?).", reply_to);
        return;
    };
    connector.sendPhoto(a, native_chat_id, png, "Word cloud of recent messages");
}

fn replyWithStats(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, native_chat_id: []const u8, reply_to: ?[]const u8) void {
    const s = stats.compute(pool, a, chat_id, 5) catch |err| {
        std.log.err("stats: query failed for chat {s}: {t}", .{ native_chat_id, err });
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
