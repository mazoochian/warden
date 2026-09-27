const std = @import("std");
const Io = std.Io;

const logging = @import("log.zig");
const log = logging.scoped("main");

/// `log_level` is left permissive (`.debug`) so `std.log`'s own comptime
/// filter never intercepts a message before it reaches `logging.stdLogFn`.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.stdLogFn,
};

const config_mod = @import("config.zig");
const auth = @import("auth.zig");
const iface = @import("platform/interface.zig");
const Identity = @import("domain/identity.zig").Identity;
const telegram_platform = @import("platform/telegram/connector.zig");
const matrix_platform = @import("platform/matrix/connector.zig");
const xmpp_platform = @import("platform/xmpp/connector.zig");
const telegram_user_platform = @import("platform/telegram/user_connector.zig");
const instagram_platform = @import("platform/instagram/connector.zig");
const reply_redirect = @import("platform/reply_redirect.zig");
const store_pool = @import("store/pool.zig");
const api_server = @import("api/server.zig");
const bot_view = @import("api/bot_view.zig");
const rate_limit = @import("api/rate_limit.zig");
const migrate = @import("store/migrate.zig");
const chats = @import("store/chats.zig");
const management_rooms = @import("store/management_rooms.zig");
const identities = @import("store/identities.zig");
const chat_members = @import("store/chat_members.zig");
const chat_settings = @import("store/chat_settings.zig");
const rate_limits = @import("store/rate_limits.zig");
const member_permissions = @import("store/member_permissions.zig");
const bot_config = @import("store/bot_config.zig");
const bot_admins = @import("store/bot_admins.zig");
const bot_blocklist = @import("store/bot_blocklist.zig");
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
const notes = @import("store/notes.zig");
const keyword_alerts = @import("store/keyword_alerts.zig");
const expenses = @import("store/expenses.zig");
const budgets = @import("store/budgets.zig");
const subscriptions = @import("store/subscriptions.zig");
const command_aliases = @import("store/command_aliases.zig");
const prompt_templates = @import("store/prompt_templates.zig");
const facts = @import("store/facts.zig");
const embeddings = @import("llm/embeddings.zig");
const reminder_format = @import("features/reminder_format.zig");
const alert_store = @import("store/alerts.zig");
const alert_feature = @import("features/alerts.zig");
const feed_watches = @import("store/feed_watches.zig");
const feed_watcher = @import("features/feed_watcher.zig");
const transcribe = @import("features/transcribe.zig");
const video_download = @import("features/video_download.zig");
const storage_sense = @import("features/storage_sense.zig");
const convert_flow = @import("features/convert_flow.zig");
const reply_drafts = @import("features/reply_drafts.zig");
const curated_feed = @import("features/curated_feed.zig");
const feed_store = @import("store/feed.zig");
const llm = @import("llm/provider.zig");
const AnthropicProvider = @import("llm/anthropic.zig").AnthropicProvider;
const OpenAiCompatProvider = @import("llm/openai_compat.zig").OpenAiCompatProvider;
const delegates_mod = @import("llm/delegates.zig");
const qa = @import("features/qa.zig");
const dynamic_provider_mod = @import("llm/dynamic_provider.zig");
const toolcall = @import("llm/toolcall.zig");
const tool_registry = @import("tools/registry.zig");
const group_admin = @import("features/group_admin.zig");
const audit_notify = @import("features/audit_notify.zig");
const cancel_request = @import("features/cancel_request.zig");
const wordcloud = @import("features/wordcloud.zig");
const digest = @import("features/digest.zig");
const chat_summary = @import("features/chat_summary.zig");
const bulletin = @import("features/bulletin.zig");
const briefing = @import("features/briefing.zig");
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
    @import("tools/set_note.zig").tool,
    @import("tools/remember_memory.zig").tool,
    @import("tools/begin_conversion.zig").tool,
    convert_file.tool,
    @import("tools/find_chat_member.zig").tool,
    @import("tools/catch_me_up.zig").tool,
    @import("tools/create_poll.zig").tool,
    @import("tools/set_expense.zig").tool,
    @import("tools/summarize_unread_chat.zig").tool,
    @import("tools/list_personal_chats.zig").tool,
    @import("tools/send_personal_message.zig").tool,
    @import("tools/reply_to_message.zig").tool,
    @import("tools/set_chat_monitoring.zig").tool,
    @import("tools/set_default_chat_monitoring.zig").tool,
    @import("tools/get_bulletin.zig").tool,
};
const web_search_tool = @import("tools/web_search.zig").tool;
// Only join the tool list when configured, like `web_search_tool` above.
const ask_delegate_tool = @import("tools/ask_delegate.zig").tool;
const delegate_generate_image_tool = @import("tools/delegate_generate_image.zig").tool;

/// Published via `Connector.setCommands` at startup so commands show up in
/// the platform's own UI (Telegram's "/" autocomplete / attachment menu)
/// instead of only working for people who already know the exact text to type
/// — see `handleHelp`/`help_text` below for the fuller reference, including
/// the owner/bot-admin-only `/scraper /blockuser /unblockuser /blockchat
/// /unblockchat /addadmin /removeadmin /sudo /storage` deliberately left out
/// of this public menu (see their own dispatch-table gates in
/// `handleMessage`).
const public_commands = [_]iface.CommandSpec{
    .{ .name = "help", .description = "Show available commands and how to talk to Warden." },
    .{ .name = "menu", .description = "Open a button-driven menu of every module (alerts, watches, stats, admin, settings, help)." },
    .{ .name = "ping", .description = "Check that Warden is responsive." },
    .{ .name = "stats", .description = "Show message stats for this chat." },
    .{ .name = "wordcloud", .description = "Generate a word cloud from recent chat activity." },
    .{ .name = "digest", .description = "on | off | now -- enable, disable, or generate a recent-activity summary." },
    .{ .name = "briefing", .description = "on | off | now -- enable, disable, or generate a briefing of pending reminders/alerts." },
    .{ .name = "remind", .description = "<time> <message> -- set a reminder. Also: every <interval> ..., cancel <id>." },
    .{ .name = "reminders", .description = "List your pending reminders in this chat." },
    .{ .name = "note", .description = "add <text> | list | delete <id> -- a shared notes/lists space; caption a voice message with /note to save its transcript." },
    .{ .name = "notes", .description = "List every note in this chat." },
    .{ .name = "memory", .description = "list | forget <id> -- what I remember about you, across every chat." },
    .{ .name = "keyword", .description = "add <word> | list | remove <id> -- get flagged here when a word comes up." },
    .{ .name = "alert", .description = "<crypto|weather|aqi> <subject> <above|below> <value> -- set an alert." },
    .{ .name = "alerts", .description = "List pending alerts in this chat." },
    .{ .name = "watch", .description = "<feed url> -- get notified when an RSS/Atom feed publishes." },
    .{ .name = "unwatch", .description = "<feed url> -- stop watching a feed." },
    .{ .name = "watches", .description = "List feeds this chat is watching." },
    .{ .name = "watchcheck", .description = "<feed url> -- force an immediate check of a watch, for testing." },
    .{ .name = "poll", .description = "<question> | <opt1> | <opt2> | ... -- create a poll (2-10 options)." },
    .{ .name = "translate", .description = "<language> <text> -- translate text, or reply to a message with just the language." },
    .{ .name = "rewrite", .description = "<tone> <text> -- rewrite text in a given tone, or reply to a message with just the tone." },
    .{ .name = "eli5", .description = "<text> -- explain like I'm five, or reply to a message." },
    .{ .name = "brainstorm", .description = "<topic> -- brainstorm ideas/options, or reply to a message." },
    .{ .name = "convert", .description = "Convert an attached photo/document/voice/audio/video to another format." },
    .{ .name = "magicword", .description = "<word> -- make Warden answer any message containing this word." },
    .{ .name = "location", .description = "<place> | off -- set this chat's default location, used for briefing weather." },
    .{ .name = "persona", .description = "<text> -- set a custom personality for this chat (or off to reset)." },
    .{ .name = "welcome", .description = "<text> -- greet new members ({name} = their name), or off to disable." },
    .{ .name = "photo", .description = "send an image with this as its caption to set the chat photo, or 'remove' to clear it. Admins only." },
    .{ .name = "title", .description = "<text> -- rename this chat. Admins only." },
    .{ .name = "description", .description = "<text> -- set this chat's description (empty to clear). Admins only." },
    .{ .name = "summary", .description = "[hours] -- summarize the last N hours of this chat (default 24)." },
    .{ .name = "announce", .description = "<text> -- broadcast now, pinned. Or: at <time> <text> | every <interval> <text> | list | cancel <id>. Admins only." },
    .{ .name = "autopin", .description = "on | off -- pin each scheduled announcement as it's posted. Admins only." },
    .{ .name = "silent", .description = "on | off -- default moderation/settings commands to -s (no in-group confirmation). Admins only." },
    .{ .name = "videodownload", .description = "on | off -- auto-download YouTube/Instagram/X video links posted here. Off by default, admins only." },
    .{ .name = "videoquality", .description = "lossy | lossless -- delivery mode for auto-downloaded videos. Lossy (default) sends a native compressed video; lossless keeps original quality, capped at 50MB, sent as a file. Admins only." },
    .{ .name = "expense", .description = "add <amt> <category> [desc] | list | summary | delete <id> -- expense tracker." },
    .{ .name = "budget", .description = "set <category> <amt> | list | remove <category> -- monthly budgets. Owner to set." },
    .{ .name = "subscription", .description = "add <name> <amt> every <interval> | list | remove <id> -- recurring costs." },
    .{ .name = "alias", .description = "add <name> <command> | list | remove <name> -- custom command shortcuts." },
    .{ .name = "template", .description = "save <name> <text> | list | use <name> [extra] | delete <name> -- saved prompts." },
    .{ .name = "joke", .description = "[topic] -- tell a joke." },
    .{ .name = "riddle", .description = "[topic] -- give a riddle (answer follows on its own line)." },
    .{ .name = "trivia", .description = "[topic] -- share an interesting fact." },
    .{ .name = "wordoftheday", .description = "an interesting word, its definition, and an example." },
    .{ .name = "motivate", .description = "[text] -- a short motivational pep talk, tailored if you give context." },
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
    .{ .name = "chatinfo", .description = "[native chat id] -- this chat's internal id and details, or look another up. Admins only." },
    .{ .name = "manage", .description = "bind|unbind <chat id> | list -- manage this room's bound chats (see /manage list). Admins only." },
    .{ .name = "as", .description = "<chat id> <command> -- run an admin command against a chat you're an admin of; the reply comes back here. Admins only." },
};

/// Commands deliberately left out of `public_commands` but still reserved --
/// an alias must never shadow one of these either.
const reserved_command_names_extra = [_][]const u8{
    "scraper",  "blockuser",   "unblockuser", "blockchat",  "unblockchat",
    "addadmin", "removeadmin", "sudo",        "storage",    "feed",
    "tdlogin",  "tdlogout",    "iglogin",     "sendas",     "tdsend",
    "tdchats",  "tdsearch",    "tdsummary",   "autonomy",   "drafts",
    "approve",  "discard",     "slowmode",    "permission", "tag",
};

/// True if `name` (no leading slash) is a real built-in command -- checked
/// case-insensitively.
fn isReservedCommandName(name: []const u8) bool {
    for (public_commands) |c| {
        if (std.ascii.eqlIgnoreCase(c.name, name)) return true;
    }
    for (reserved_command_names_extra) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return true;
    }
    return false;
}

test "isReservedCommandName covers both the public menu and the owner-only extras, case-insensitively" {
    try std.testing.expect(isReservedCommandName("ping"));
    try std.testing.expect(isReservedCommandName("PING"));
    try std.testing.expect(isReservedCommandName("sudo"));
    try std.testing.expect(isReservedCommandName("BlockUser"));
    try std.testing.expect(!isReservedCommandName("gm"));
    try std.testing.expect(!isReservedCommandName("standup"));
    // AUDIT-2026-09-03 CORE-3: the fifteen the list used to be missing.
    for ([_][]const u8{
        "tdlogin",  "tdlogout", "iglogin", "sendas",  "tdsend",   "tdchats",    "tdsearch", "tdsummary",
        "autonomy", "drafts",   "approve", "discard", "slowmode", "permission", "tag",
    }) |name| {
        try std.testing.expect(isReservedCommandName(name));
    }
}

/// `/help`'s reply — kept as a single static string (matches `reply()`'s
/// `comptime txt` parameter) rather than built from `public_commands`.
const help_text =
    \\I'm Warden. Talk to me by mentioning me, replying, or (in a group)
    \\saying this chat's magic word -- see /magicword. Ask anything and
    \\I'll reach for the right tool (weather, crypto, calculator, diagrams,
    \\word clouds, web search, URLs) -- most items below also work as
    \\plain asks.
    \\
    \\General
    \\/ping -- check I'm responsive
    \\/menu -- button menu covering everything below (Matrix: !menu too)
    \\/stats -- message stats for this chat
    \\/wordcloud -- word cloud from recent activity
    \\/digest on|off|now -- enable/disable/generate a recent-activity summary
    \\/briefing on|off|now -- like /digest
    \\/summary [hours] -- summarize the last N hours (default 24), no
    \\  side effects, unlike /digest now
    \\/poll <question> | <opt1> | <opt2> | ... -- create a poll (2-10 opts)
    \\
    \\Reminders, alerts, feeds
    \\/remind <time> <message> -- e.g. 30m/14:30/5-22. every <interval>
    \\  to repeat, cancel <id> to cancel
    \\/reminders -- list your pending reminders
    \\/alert <crypto|weather|aqi> <subject> <above|below> <value> -- e.g.
    \\  /alert crypto btc above 100000. cancel <id> to cancel
    \\/alerts -- list pending alerts
    \\/watch, /unwatch <feed url>; /watches -- RSS/Atom feed notifications
    \\/note add <text> | list | delete <id> -- notes/shopping lists
    \\  (caption a voice message with /note to save its transcript)
    \\/memory list | forget <id> -- what I remember (I save this myself)
    \\/keyword add <word> | list | remove <id> -- flag it here when said
    \\
    \\Messaging modes
    \\/translate <lang>, /rewrite <tone>, /eli5, /brainstorm <topic> --
    \\  give text, or reply with just the first arg
    \\
    \\Files
    \\/convert -- guided conversion (asks you to send a file); or send a
    \\  file with "/convert <format>" as its caption for one shot
    \\
    \\Customization (owner only to change, anyone can view)
    \\/magicword <word> | off -- answer any message containing this word
    \\/location <place> | off -- default location for briefing weather
    \\/persona <text> | off -- set/reset this chat's personality
    \\/thinking on|off|default -- show/hide the model's reasoning here,
    \\  overriding the bot-wide default
    \\/welcome <text> | off -- greet new members ({name} = their name)
    \\
    \\Finance (manual entry only -- no bank/price-tracking integration)
    \\/expense, /budget, /subscription -- type any of these alone for
    \\  usage (or just ask, e.g. "log $12 for lunch")
    \\
    \\Power tools
    \\/alias add <name> <command> | list | remove <name> -- shortcuts
    \\/template save <name> <text> | list | use <name> [extra] | delete
    \\/joke, /riddle, /trivia [topic]; /wordoftheday; /motivate [text]
    \\
;

/// The second half of `/help`, sent as its own message.
const help_text_admin =
    \\Group moderation (chat admins only, most by replying to a message)
    \\/mute, /unmute, /pin, /unpin, /delete -- reply to the target
    \\/kick, /ban [@user|id] -- reply to the target, or pass @user/id
    \\/promote, /demote -- reply to grant/revoke real admin. Owner only
    \\/confirm, /cancel -- confirm/cancel a pending /kick or /ban
    \\/redact <N> | (reply) [N] | text <sub> | regex <pat> -- delete up
    \\  to 100 messages. regex is admin/owner only
    \\/announce <text> -- broadcast now, pinned. at <time> <text> to
    \\  schedule instead; every <interval> <text> to repeat; list,
    \\  cancel <id> to manage
    \\/autopin on|off -- pin each scheduled announcement as it's posted
    \\  (only those -- I never pin anyone else's messages on my own)
    \\/videodownload on|off -- auto-download YouTube/Instagram/X video
    \\  links posted here, best-effort, no source size limit. Off by
    \\  default
    \\/videoquality lossy|lossless -- lossy (default) sends a compressed
    \\  native video; lossless keeps original quality, capped at 50MB,
    \\  sent as a file
    \\/photo -- send an image with this as its caption to set the chat
    \\  photo; /photo remove clears it
    \\/title <text> -- rename this chat
    \\/description <text> -- set the description (empty clears it)
    \\-s on mute/unmute/kick/ban/promote/demote/photo/title/description
    \\  skips the in-group confirmation (the bound room's audit log still
    \\  sees it regardless); /silent on|off makes -s the default here
    \\
    \\Access (owner/bot admin only). Everyone can talk to me unless blocked
    \\/addadmin, /removeadmin -- reply to a user, or pass @username/id,
    \\  to grant/revoke the bot-admin role (trusted bot-wide)
    \\/blockuser, /unblockuser -- reply to a user, or pass @username/id,
    \\  to stop me responding to them anywhere (or undo that)
    \\/blockchat, /unblockchat -- stop responding in this whole chat
    \\/whois [@user|id] -- their name/username/id/flags. Admin/owner only
    \\/chatinfo [native id] -- this chat's internal id, platform, type and
    \\  title; pass a native id to look up another chat on this platform
    \\
    \\Management rooms (for channels/groups with no back-and-forth)
    \\/manage bind|unbind|list <chat id> -- bind this room to one target
    \\  chat (rebinding moves it -- one room, one target). Most moderation
    \\  and settings commands above then run directly here against that
    \\  target, no prefix needed.
    \\
    \\Owner only
    \\/scraper -- configure the web-scraping backend
    \\/tdlogin -- connect Warden to your personal Telegram account
    \\/sendas <chat id> <text> -- send a message through your personal account
    \\/tdchats -- list your personal account's chats and their ids
    \\/autonomy [off|draft|auto] | <chat id> [off|draft|auto|clear] --
    \\  reply-on-my-behalf dial, global or per personal-account chat
    \\/drafts, /approve <chat id>, /discard <chat id> -- review, send, or
    \\  drop a drafted reply (reply_autonomy = draft)
;

/// Sends `/help` as two messages.
fn handleHelp(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    reply(connector, a, msg.chat_id, msg.message_id, help_text);

    const username = connector.selfUsername() orelse {
        reply(connector, a, msg.chat_id, msg.message_id, help_text_admin);
        return;
    };
    const full = std.fmt.allocPrint(
        a,
        "{s}\n\nSharing this group with another bot? Qualify a command with my username, e.g. /ping@{s}, and I'll ignore commands qualified for a different bot.",
        .{ help_text_admin, username },
    ) catch return reply(connector, a, msg.chat_id, msg.message_id, help_text_admin);
    connector.sendMessage(a, msg.chat_id, full, msg.message_id);
}

test "each /help message stays under Telegram's 4096-byte cap" {
    // A Telegram username is at most 32 bytes, so 200 bytes of slack is generous
    // for the "Sharing this group...
    try std.testing.expect(help_text.len < 4096);
    try std.testing.expect(help_text_admin.len < 4096 - 200);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // As early as possible — before the healthcheck branch, before config load.
    logging.init(io, init.environ_map);

    // Docker's `HEALTHCHECK` (see `Dockerfile`) spawns this same binary as a
    // brand-new process on a timer rather than reaching into the running one.
    if (wantsHealthcheck(init.minimal.args)) runHealthcheck(gpa, io, init.environ_map);

    const config = config_mod.Config.load(init.environ_map, init.arena.allocator(), io) catch |err| {
        log.fatal("config error: {t} (did you set WARDEN_TELEGRAM_BOT_TOKEN and WARDEN_POSTGRES_DSN?)", .{err});
    };
    log.notice("log level = {s} (set WARDEN_LOG_LEVEL to change)", .{@tagName(logging.currentLevel())});

    // Every configured delegate (see `Config.delegates`) gets its own always-on
    // `llm.Provider` instance -- heap-allocated, process-lifetime singletons.
    const delegates_buf = try gpa.alloc(delegates_mod.Delegate, config.delegates.len);
    for (config.delegates, 0..) |dc, i| {
        const delegate_provider: llm.Provider = switch (dc.kind) {
            .anthropic => blk: {
                const p = try gpa.create(AnthropicProvider);
                p.* = AnthropicProvider.init(gpa, io, dc.api_key, dc.model);
                break :blk p.provider();
            },
            .openai_compat => blk: {
                const p = try gpa.create(OpenAiCompatProvider);
                p.* = OpenAiCompatProvider.init(gpa, io, dc.base_url, dc.api_key, dc.model);
                break :blk p.provider();
            },
        };
        delegates_buf[i] = .{
            .name = dc.name,
            .description = dc.description,
            .provider = delegate_provider,
            .image = if (dc.image_model) |im| .{ .base_url = dc.base_url, .api_key = dc.api_key, .model = im } else null,
        };
    }
    const active_delegates: []const delegates_mod.Delegate = delegates_buf;

    // Web_search/ask_delegate/delegate_generate_image only join the tool list
    // when their backend is actually configured.
    var tools_buf: [base_tools.len + 3]tool_registry.ToolDef = undefined;
    @memcpy(tools_buf[0..base_tools.len], &base_tools);
    var tools_len: usize = base_tools.len;
    if (config.searxng_url != null) {
        tools_buf[tools_len] = web_search_tool;
        tools_len += 1;
    } else {
        log.info("web search disabled (set WARDEN_SEARXNG_URL to enable)", .{});
    }
    if (active_delegates.len > 0) {
        tools_buf[tools_len] = ask_delegate_tool;
        tools_len += 1;
        var any_image_capable = false;
        for (active_delegates) |d| {
            if (d.image != null) any_image_capable = true;
        }
        if (any_image_capable) {
            tools_buf[tools_len] = delegate_generate_image_tool;
            tools_len += 1;
        }
    } else {
        log.info("LLM delegation disabled (set WARDEN_DELEGATES to enable)", .{});
    }
    const active_tools = tools_buf[0..tools_len];

    var telegram_adapter = telegram_platform.TelegramConnector.init(gpa, io, config.telegram_bot_token);
    defer telegram_adapter.deinit();

    // Matrix only joins the active connector list when configured (see
    // `config.zig`'s `matrix` field).
    var matrix_adapter: ?matrix_platform.MatrixConnector = if (config.matrix) |mc|
        matrix_platform.MatrixConnector.init(gpa, io, mc.homeserver_url, mc.access_token)
    else
        null;
    defer if (matrix_adapter) |*m| m.deinit();

    // Same "only join the list when configured" shape as Matrix above.
    var xmpp_adapter: ?xmpp_platform.XmppConnector = if (config.xmpp) |xc|
        xmpp_platform.XmppConnector.init(gpa, io, xc.host, xc.port, xc.domain, xc.jid_user, xc.password, xc.muc_rooms, switch (xc.tls_mode) {
            .self_signed => .self_signed,
            .bundle => .bundle,
            .insecure => .insecure,
        })
    else
        null;
    defer if (xmpp_adapter) |*x| x.deinit();

    var telegram_user_adapter: ?telegram_user_platform.TelegramUserConnector = if (config.telegram_user) |tc|
        telegram_user_platform.TelegramUserConnector.init(gpa, io, tc.api_id, tc.api_hash, tc.session_dir)
    else
        null;

    // Hoisted above `connectors_buf`.
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

    // Same "only join the list when configured" shape as every other
    // connector above.
    var instagram_adapter: ?instagram_platform.InstagramConnector = if (config.instagram) |ic|
        instagram_platform.InstagramConnector.init(gpa, io, &pool, ic.poll_interval_ms, ic.rotating) catch |err| blk: {
            log.err("failed to initialize the Instagram connector: {t}", .{err});
            break :blk null;
        }
    else
        null;
    defer if (instagram_adapter) |*i| i.deinit();

    var connectors_buf: [5]iface.Connector = undefined;
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
    if (telegram_user_adapter) |*t| {
        connectors_buf[connectors_len] = t.connector();
        connectors_len += 1;
    }
    if (instagram_adapter) |*i| {
        connectors_buf[connectors_len] = i.connector();
        connectors_len += 1;
    }
    const connectors: []const iface.Connector = connectors_buf[0..connectors_len];
    const max_message_len = effectiveMaxMessageLength(connectors);

    // Device key creation/upload plus ongoing encrypt/decrypt for Matrix E2E
    // encryption.
    if (matrix_adapter) |*m| {
        if (config.matrix_pickle_key) |pickle_key| {
            m.enableCrypto(gpa, io, &pool, pickle_key) catch |err| {
                log.err("matrix e2ee: device key setup failed: {t}", .{err});
            };
        }
    }

    var pending_confirmations = group_admin.PendingConfirmations.init(gpa, io, config.confirm_timeout_seconds);
    defer pending_confirmations.deinit();

    // 24h, not `config.confirm_timeout_seconds`.
    var pending_undos = audit_notify.PendingUndos.init(gpa, io, 24 * 3600);
    defer pending_undos.deinit();

    var digest_scheduler = scheduler.DigestScheduler.init(gpa, io, config.digest_interval_seconds);
    defer digest_scheduler.deinit();
    loadDigestScheduleFromDisk(gpa, &pool, &digest_scheduler);

    var briefing_scheduler = scheduler.BriefingScheduler.init(gpa, io, config.briefing_interval_seconds);
    defer briefing_scheduler.deinit();
    loadBriefingScheduleFromDisk(gpa, &pool, &briefing_scheduler);

    var pending_conversions = convert_flow.PendingConversions.init(gpa, io, config.convert_timeout_seconds);
    defer pending_conversions.deinit();

    var menu_sessions = menu.Sessions.init(gpa, io, config.menu_timeout_seconds);
    defer menu_sessions.deinit();

    // 10 minutes: a purely defensive backstop (normal flow always unregisters
    // itself via `replyWithAnswer`'s own cleanup, well before this).
    var in_flight_requests = cancel_request.InFlightRequests.init(gpa, io, 600);
    defer in_flight_requests.deinit();

    // `reply_autonomy = .draft` drafts a reply through the personal-account
    // connector but holds it here instead of sending it, until
    // `/approve`/`/discard`.
    var pending_drafts = reply_drafts.PendingDrafts.init(&pool, 24 * 3600);

    var bot_view_broadcaster = bot_view.Broadcaster.init(gpa, io);
    defer bot_view_broadcaster.deinit();

    var auth_limiter = rate_limit.Limiter.init(gpa, io, 20, 60);
    defer auth_limiter.deinit();
    var bot_view_send_limiter = rate_limit.Limiter.init(gpa, io, 10, 60);
    defer bot_view_send_limiter.deinit();

    // Heap-allocated, process-lifetime singletons -- fine to leave for the OS to
    // reclaim on exit rather than threading a deinit through here.
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
    // `Config.load` already guarantees at least one of the two above exists (same
    // "fails if neither is configured" contract as before this refactor).
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

    // Same "heap-allocated, process-lifetime singleton" shape as the LLM
    // providers above -- null when `WARDEN_EMBEDDINGS_URL` isn't set.
    var embeddings_client: ?*embeddings.EmbeddingsClient = null;
    if (config.embeddings_url) |url| {
        const ec = try gpa.create(embeddings.EmbeddingsClient);
        ec.* = embeddings.EmbeddingsClient.init(gpa, io, url, config.embeddings_api_key, config.embeddings_model);
        embeddings_client = ec;
    } else {
        log.info("memory: WARDEN_EMBEDDINGS_URL isn't set — long-term memory still records and recalls facts, ranked by keyword/recency/salience; semantic (meaning-based) recall is off until an embeddings endpoint is configured", .{});
    }

    log.info("warden started, {d} connector(s), {d} owner(s) configured", .{ connectors.len, config.owners.len });

    // Best-effort: a platform without the concept (or a transient API failure)
    // just means commands don't autocomplete, not a startup failure.
    for (connectors) |connector| {
        connector.setCommands(gpa, &public_commands) catch |err| {
            if (err != error.Unsupported) {
                log.warn("failed to publish command menu for {s}: {t}", .{ @tagName(connector.platform()), err });
            }
        };
    }

    // One timestamp per connector (last successful `poll()` return) plus one for
    // `main`'s own scheduler loop below.
    var heartbeat = Heartbeat.init(gpa, io, connectors) catch |err| {
        log.fatal("failed to allocate heartbeat state: {t}", .{err});
    };

    // One persistent poll loop per connector, running concurrently — previously a
    // single loop polled every connector in turn.
    const telegram_user_ptr: ?*telegram_user_platform.TelegramUserConnector = if (telegram_user_adapter) |*t| t else null;

    // Same reasoning as `telegram_user_ptr` above -- `/iglogin` can be typed
    // from whichever connector the owner is actually talking to the bot on.
    const instagram_ptr: ?*instagram_platform.InstagramConnector = if (instagram_adapter) |*i| i else null;

    // A `reply_autonomy = .draft` notification.
    const owner_notify_connector = telegram_adapter.connector();

    // `storage_sense.tick`'s notification target — resolved once here rather than
    // per-tick.
    const storage_owner_native_id = ownerTelegramNativeId(&config);
    if (storage_owner_native_id == null) {
        log.warn("storage sense: no telegram owner configured, disk monitoring won't run", .{});
    }

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
            embeddings_client,
            active_tools,
            active_delegates,
            &pending_confirmations,
            &pending_undos,
            &digest_scheduler,
            &briefing_scheduler,
            &pending_conversions,
            &menu_sessions,
            &in_flight_requests,
            io,
            gpa,
            max_message_len,
            msg_pool,
            &heartbeat,
            i,
            &bot_view_broadcaster,
            telegram_user_ptr,
            &pending_drafts,
            owner_notify_connector,
            instagram_ptr,
        }) catch |err| {
            log.err("failed to start poll loop thread for {t}: {t}", .{ connector.platform(), err });
            continue;
        };
        thread.detach();
        log.notice("{t}: poll loop started", .{connector.platform()});
    }

    // Guarantees recovery even if nothing external is watching the `Dockerfile`
    // HEALTHCHECK's result.
    if (std.Thread.spawn(.{}, selfWatchdogLoop, .{ io, &heartbeat })) |thread| {
        thread.detach();
    } else |err| {
        log.warn("failed to start self-watchdog thread: {t}", .{err});
    }

    // The web API for warden-ui, off unless WARDEN_API_PORT is set.
    if (config.api_port) |port| {
        const api_ctx = try gpa.create(api_server.ServerContext);
        api_ctx.* = .{
            .allocator = gpa,
            .io = io,
            .pool = &pool,
            .config = &config,
            .connectors = connectors,
            .bot_view = &bot_view_broadcaster,
            .auth_limiter = &auth_limiter,
            .bot_view_send_limiter = &bot_view_send_limiter,
            .telegram_user = if (telegram_user_adapter) |*t| t else null,
            .llm_provider = llm_provider,
            .pending_drafts = &pending_drafts,
        };
        if (std.Thread.spawn(.{}, apiServerThread, .{ api_ctx, port, config.api_workers })) |thread| {
            thread.detach();
        } else |err| {
            log.warn("failed to start API server thread: {t}", .{err});
        }
    }

    const scheduler_log = logging.scoped("scheduler");
    while (true) {
        const tick_started = Io.Timestamp.now(io, .real);
        const now = tick_started.toSeconds();
        checkAndSendDueDigests(connectors, gpa, io, &config, &pool, &digest_scheduler, llm_provider, max_message_len, now);
        checkAndSendDueBriefings(connectors, gpa, io, &config, &pool, &briefing_scheduler, max_message_len, now);
        checkAndSendDueReminders(connectors, gpa, &pool, now);
        checkAndRevertExpiredPermissions(connectors, gpa, &pool, now);
        alert_feature.checkAndDeliverAlerts(connectors, gpa, io, &pool, now);
        feed_watcher.checkAndNotifyFeeds(connectors, gpa, io, &pool, llm_provider, now);
        checkCuratedFeed(gpa, io, &pool, llm_provider, telegram_user_ptr, &config, now);
        if (storage_owner_native_id) |onid| {
            if (feature_flags.isEnabled(&pool, "storage_sense_monitor")) {
                if (resolveOwnerIdentityId(&pool, &config, now)) |owner_identity_id| {
                    storage_sense.tick(gpa, io, &config, &pool, llm_provider, owner_notify_connector, onid, owner_identity_id, now);
                } else |err| {
                    log.warn("storage sense: couldn't resolve owner identity, skipping this tick: {t}", .{err});
                }
            }
        }
        pending_conversions.sweepExpired(gpa, now);
        menu_sessions.sweepExpired(connectors, now);
        in_flight_requests.sweepExpired(now);
        checkAndPurgeLeftChats(&pool, now);
        heartbeat.stampScheduler(now);
        heartbeat.writeToFile(io, gpa, config.tmp_dir);
        const tick_ms = @divTrunc(Io.Timestamp.now(io, .real).toNanoseconds() - tick_started.toNanoseconds(), std.time.ns_per_ms);
        // A tick well past its own ~30s cadence is a real signal something
        // downstream.
        if (tick_ms > 10_000) {
            scheduler_log.warn("tick took {d}ms (longer than expected)", .{tick_ms});
        } else {
            scheduler_log.debug("tick completed in {d}ms", .{tick_ms});
        }
        Io.sleep(io, .fromSeconds(30), .awake) catch {};
    }
}

/// Filename (under `Config.tmp_dir`) `Heartbeat.writeToFile` writes to and
/// `runHealthcheck` reads back.
const heartbeat_filename = "heartbeat";

/// How stale a heartbeat line can get before `--healthcheck` reports
/// unhealthy — a generous multiple of the ~30s scheduler cadence that writes
/// it.
const healthcheck_stale_seconds: i64 = 120;

/// How stale before the in-process watchdog gives up waiting for an external
/// monitor and self-exits instead (see `selfWatchdogLoop`).
const watchdog_stale_seconds: i64 = 300;

/// One timestamp per connector (index-aligned with `main`'s `connectors`
/// slice) plus one for the top-level scheduler loop.
const Heartbeat = struct {
    connector_platforms: []const iface.Platform,
    connector_last_ok: []std.atomic.Value(i64),
    scheduler_last_tick: std.atomic.Value(i64) = .init(0),

    /// Seeds every timestamp to `now` (startup time), not `0`.
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

    /// `true` if every tracked timestamp is within `stale_seconds` of `now`.
    fn allFreshInMemory(self: *const Heartbeat, now: i64, stale_seconds: i64) bool {
        if (now - self.scheduler_last_tick.load(.acquire) > stale_seconds) return false;
        for (self.connector_last_ok) |*slot| {
            if (now - slot.load(.acquire) > stale_seconds) return false;
        }
        return true;
    }

    /// Serializes every timestamp to `<tmp_dir>/heartbeat` as plain
    /// `name=unix_timestamp` lines.
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

/// `true` if any argument (skipping argv[0]) is exactly `--healthcheck` — the
/// flag `Dockerfile`'s `HEALTHCHECK` passes to probe liveness.
fn wantsHealthcheck(args: std.process.Args) bool {
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--healthcheck")) return true;
    }
    return false;
}

/// Reads `<WARDEN_TMP_DIR>/heartbeat`.
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
/// directly.
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
/// `std.Thread.spawn`'s function must return `void`, not `!void`.
fn apiServerThread(ctx: *const api_server.ServerContext, port: u16, workers: usize) void {
    api_server.run(ctx, port, workers) catch |err| {
        log.err("api server exited: {t}", .{err});
    };
}

/// One connector's own poll-forever loop.
fn connectorPollLoop(
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tools: []const tool_registry.ToolDef,
    delegates: []const delegates_mod.Delegate,
    pending: *group_admin.PendingConfirmations,
    pending_undos: *audit_notify.PendingUndos,
    digest_scheduler: *scheduler.DigestScheduler,
    briefing_scheduler: *scheduler.BriefingScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    in_flight_requests: *cancel_request.InFlightRequests,
    io: Io,
    gpa: std.mem.Allocator,
    max_message_len: usize,
    msg_pool: *MessageWorkerPool,
    heartbeat: *Heartbeat,
    connector_idx: usize,
    bcast: *bot_view.Broadcaster,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    owner_notify: iface.Connector,
    instagram: ?*instagram_platform.InstagramConnector,
) void {
    while (true) {
        var poll_arena = std.heap.ArenaAllocator.init(gpa);
        defer poll_arena.deinit();
        const poll_a = poll_arena.allocator();

        const polled_messages = connector.poll(poll_a) catch |err| {
            switch (err) {
                // A long poll whose connection died or never came up is operationally an
                // empty poll: updates queue server-side until the next successful getUpdates.
                error.HttpConnectionClosing,
                error.TlsInitializationFailed,
                => log.warn("poll connection dropped (will re-poll): {t}", .{err}),
                else => log.err("poll failed: {t}", .{err}),
            }
            // A failed poll returns immediately instead of blocking for the ~30s long-
            // poll window.
            Io.sleep(io, .fromSeconds(5), .awake) catch {};
            continue;
        };

        // Stamped on every successful cycle, whether or not it returned any messages
        // — an empty-but-successful poll already proves this connector isn't wedged.
        heartbeat.stampConnector(connector_idx, Io.Timestamp.now(io, .real).toSeconds());
        if (polled_messages.len > 0) {
            log.debug("{t}: poll returned {d} message(s)", .{ connector.platform(), polled_messages.len });
        }

        for (polled_messages) |msg| {
            const ts = Io.Timestamp.now(io, .real).toSeconds();

            // Each task owns an arena for its whole lifetime, created here.
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

            // Enqueued onto this connector's own `MessageWorkerPool` instead of spawned
            // via `Io.Group.async` — `push` never blocks on processing.
            msg_pool.push(.{
                .connector = connector,
                .config = config,
                .pool = pool,
                .llm_provider = llm_provider,
                .embeddings_client = embeddings_client,
                .tools = tools,
                .delegates = delegates,
                .pending = pending,
                .pending_undos = pending_undos,
                .digest_scheduler = digest_scheduler,
                .briefing_scheduler = briefing_scheduler,
                .pending_conversions = pending_conversions,
                .menu_sessions = menu_sessions,
                .in_flight_requests = in_flight_requests,
                .io = io,
                .gpa = gpa,
                .ts = ts,
                .max_message_len = max_message_len,
                .task_arena = task_arena,
                .msg = duped_msg,
                .bcast = bcast,
                .telegram_user = telegram_user,
                .pending_drafts = pending_drafts,
                .owner_notify = owner_notify,
                .instagram = instagram,
            }) catch |err| {
                // Queueing itself failed (OOM growing the queue's backing array) —
                // `processMessageTask` never got a chance to free `task_arena`.
                log.err("failed to queue message for chat {s}: {t}", .{ msg.chat_id, err });
                task_arena.deinit();
                gpa.destroy(task_arena);
            };
        }
    }
}

/// Finds the connector whose platform matches `platform` among `connectors`.
fn findConnector(connectors: []const iface.Connector, platform: iface.Platform) ?iface.Connector {
    for (connectors) |c| {
        if (c.platform() == platform) return c;
    }
    return null;
}

/// Fallback used when no connector declares a `maxMessageLength`.
const default_max_message_length: usize = 4096;

/// The tightest `maxMessageLength` across every active connector.
fn effectiveMaxMessageLength(connectors: []const iface.Connector) usize {
    var min_len: usize = default_max_message_length;
    for (connectors) |c| {
        if (c.maxMessageLength()) |len| min_len = @min(min_len, len);
    }
    return min_len;
}

/// Sends `text` normally if it fits within `max_len`, otherwise attaches it
/// as a `.txt` file instead.
fn sendTextOrFile(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to: ?[]const u8, max_len: usize, filename: []const u8) void {
    if (text.len <= max_len) {
        connector.sendMessage(a, chat_id, text, reply_to);
        return;
    }
    connector.sendDocument(a, chat_id, text, filename, "That was too long for a single message — attached as a file.");
}

/// One connector's own per-message `WorkerPool`.
const MessageWorkerPool = worker_pool.WorkerPool(MessageTask);

/// Bundles every argument `processMessageTask` needs into one plain-data
/// value so it can travel through `MessageWorkerPool`'s queue.
const MessageTask = struct {
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tools: []const tool_registry.ToolDef,
    delegates: []const delegates_mod.Delegate,
    pending: *group_admin.PendingConfirmations,
    pending_undos: *audit_notify.PendingUndos,
    digest_scheduler: *scheduler.DigestScheduler,
    briefing_scheduler: *scheduler.BriefingScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    in_flight_requests: *cancel_request.InFlightRequests,
    io: Io,
    gpa: std.mem.Allocator,
    ts: i64,
    max_message_len: usize,
    task_arena: *std.heap.ArenaAllocator,
    msg: iface.Message,
    bcast: *bot_view.Broadcaster,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    owner_notify: iface.Connector,
    instagram: ?*instagram_platform.InstagramConnector,

    fn run(self: MessageTask) void {
        processMessageTask(
            self.connector,
            self.config,
            self.pool,
            self.llm_provider,
            self.embeddings_client,
            self.tools,
            self.delegates,
            self.pending,
            self.pending_undos,
            self.digest_scheduler,
            self.briefing_scheduler,
            self.pending_conversions,
            self.menu_sessions,
            self.in_flight_requests,
            self.io,
            self.gpa,
            self.ts,
            self.max_message_len,
            self.task_arena,
            self.msg,
            self.bcast,
            self.telegram_user,
            self.pending_drafts,
            self.owner_notify,
            self.instagram,
        );
    }
};

/// Body of one queued per-message task (see `MessageWorkerPool`/
/// `MessageTask` above).
fn processMessageTask(
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tools: []const tool_registry.ToolDef,
    delegates: []const delegates_mod.Delegate,
    pending: *group_admin.PendingConfirmations,
    pending_undos: *audit_notify.PendingUndos,
    digest_scheduler: *scheduler.DigestScheduler,
    briefing_scheduler: *scheduler.BriefingScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    in_flight_requests: *cancel_request.InFlightRequests,
    io: Io,
    gpa: std.mem.Allocator,
    ts: i64,
    max_message_len: usize,
    task_arena: *std.heap.ArenaAllocator,
    msg: iface.Message,
    bcast: *bot_view.Broadcaster,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    owner_notify: iface.Connector,
    instagram: ?*instagram_platform.InstagramConnector,
) void {
    defer {
        task_arena.deinit();
        gpa.destroy(task_arena);
    }
    // Declared after the arena-cleanup defer above so it runs *before* that one
    // (defers unwind in reverse declaration order).
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

    // Housekeeping: synthetic lifecycle signals from a connector.
    if (msg.chat_ingest_only) return;
    if (msg.migrated_to_native_chat_id) |new_id| {
        chats.renameNativeChatId(pool, chat_id, new_id) catch |err| {
            log.err("failed to rename chat {s} (supergroup migration) to {s}: {t}", .{ msg.chat_id, new_id, err });
        };
        return;
    }
    if (msg.chat_left) {
        chats.markLeft(pool, chat_id, ts) catch |err| {
            log.err("failed to mark chat {s} as left: {t}", .{ msg.chat_id, err });
        };
        return;
    }

    sendWelcomeMessages(connector, a, pool, chat_id, msg);

    // Every group member's message counts toward this chat's local record
    // (stats/content recall), regardless of who sent it.
    const identity_id = resolveSenderIdentity(pool, connector, msg, ts) catch |err| {
        log.err("failed to resolve identity for user {s}: {t}", .{ msg.user_id, err });
        return;
    };
    if (msg.choice_picked == null) {
        // Warden's own slow-mode enforcement, ahead of recordMessage/keyword-
        // alerts/dispatch below.
        if (checkSlowMode(connector, a, config, pool, chat_id, identity_id, msg, ts)) return;

        const retention_messages = dynamic_config.getI64(pool, a, "WARDEN_RETENTION_MESSAGES", config.retention_messages);
        recordMessage(pool, chat_id, identity_id, msg.message_id, msg.text, ts, retention_messages);

        // Read-only tap for Bot View's live incoming-message feed.
        const sender_display_name = if (msg.identity) |identity| identity.display_name else msg.username orelse msg.user_id;
        bcast.publish(chat_id, sender_display_name, msg.text, ts);

        if (feature_flags.isEnabled(pool, "keyword_alerts")) {
            if (msg.text) |t| checkKeywordAlerts(connector, a, pool, chat_id, msg, t);
        }

        // Video auto-download.
        if (feature_flags.isEnabled(pool, "video_download") and chat_settings.getVideoDownloadEnabled(pool, chat_id)) {
            if (msg.text) |t| checkVideoDownload(connector, a, io, config, pool, chat_id, msg, t);
        }
    }
    recordObservedUsers(pool, chat_id, msg.observed_users);

    // Downloaded eagerly (not lazily on first tool use) since it's cheap relative
    // to the LLM round trip this task is about to make anyway.
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
    var note_adapter: NoteToolAdapter = .{
        .pool = pool,
        .chat_id = chat_id,
        .identity_id = identity_id,
        .is_owner = auth.isOwner(config, connector.platform(), msg.user_id),
        .now = ts,
    };
    var expense_adapter: ExpenseToolAdapter = .{
        .pool = pool,
        .chat_id = chat_id,
        .identity_id = identity_id,
        .is_owner = auth.isOwner(config, connector.platform(), msg.user_id),
        .now = ts,
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
    var memory_adapter: MemoryToolAdapter = .{
        .pool = pool,
        .identity_id = identity_id,
        .now = ts,
        .embeddings_client = embeddings_client,
    };
    var chat_history_adapter: ChatHistoryToolAdapter = .{
        .pool = pool,
        .chat_id = chat_id,
        .now = ts,
    };
    // The three adapters below act *as the owner*.
    const is_owner = auth.isOwner(config, connector.platform(), msg.user_id);
    const owner_identity_id = if (is_owner and connector.platform() != .telegram)
        resolveOwnerIdentityId(pool, config, ts) catch identity_id
    else
        identity_id;
    var personal_account_adapter: PersonalAccountToolAdapter = .{
        .telegram_user = telegram_user,
        .pool = pool,
        .io = io,
    };
    var monitoring_adapter: MonitoringToolAdapter = .{
        .telegram_user = telegram_user,
        .pool = pool,
        .owner_identity_id = owner_identity_id,
    };
    var bulletin_adapter: BulletinToolAdapter = .{
        .pool = pool,
        .owner_identity_id = owner_identity_id,
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
        .notes = note_adapter.sink(),
        .convert_flow = convert_flow_adapter.sink(),
        .member_directory = member_directory_adapter.sink(),
        // Null (not just a sink whose calls would fail) whenever the feature isn't
        // configured at all.
        .memory = memory_adapter.sink(),
        .chat_history = chat_history_adapter.sink(),
        .expenses = expense_adapter.sink(),
        .personal_account = if (is_owner) personal_account_adapter.sink() else null,
        .monitoring = if (is_owner) monitoring_adapter.sink() else null,
        .bulletin = if (is_owner) bulletin_adapter.sink() else null,
        .attachment_path = attachment_path,
        .attachment_file_name = if (msg.attachment) |att| att.file_name else null,
        .attachment_mime = if (msg.attachment) |att| att.mime_type else null,
        .attachment_kind = if (msg.attachment) |att| att.kind else null,
        .delegates = delegates,
    };
    const claimed = handleMessage(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, pending, pending_undos, digest_scheduler, briefing_scheduler, pending_conversions, menu_sessions, in_flight_requests, io, ts, max_message_len, msg, false, telegram_user, pending_drafts, owner_notify, instagram);
    if (claimed) attachment_cleanup_path = null;
}

/// Downloads `att`'s bytes into `tmp_dir` and returns the local file path
/// (allocated in `allocator`).
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

/// Best-effort extension (leading dot included) for a downloaded attachment's
/// local file name.
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

/// Stand-in `qa.answer` question for a captionless attachment, so the model's
/// `user_content` still names what just arrived instead of reading "Question.
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

/// The question text `qa.answer` gets for this message.
const ResolvedQuestion = struct {
    text: []const u8,
    /// Set when a "🎙️ Transcribing…" placeholder was already sent — handed into
    /// `replyWithAnswer` so it morphs into the "🤔 Thinking...
    placeholder_id: ?[]const u8 = null,
};

fn resolveQuestion(connector: iface.Connector, a: std.mem.Allocator, io: Io, config: *const config_mod.Config, pool: *store_pool.PgPool, tool_ctx: tool_registry.ToolContext, msg: iface.Message, text: []const u8) ResolvedQuestion {
    if (text.len > 0) return .{ .text = text };
    const att = msg.attachment orelse return .{ .text = text };

    if (att.kind == .voice) {
        // Disabled falls back to the generic attachment placeholder below, same as
        // "whisper not configured" already does.
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
/// message's sender.
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
    // Completes a grant queued by `/blockuser`/`/addadmin` against a `@username`
    // the bot had no identity for yet.
    if (msg.username) |username| {
        completePendingGrants(pool, connector.platform(), username, identity_id);
    }
    return identity_id;
}

fn completePendingGrants(pool: *store_pool.PgPool, platform: iface.Platform, username: []const u8, identity_id: i64) void {
    const pending_block = bot_pending_grants.takePending(pool, platform, username, .blocked_user) catch |err| blk: {
        log.err("failed to check pending user-block for @{s}: {t}", .{ username, err });
        break :blk null;
    };
    if (pending_block) |added_by| {
        bot_blocklist.blockUser(pool, identity_id, added_by) catch |err| {
            log.err("failed to complete pending user-block for @{s}: {t}", .{ username, err });
        };
        log.notice("completed pending user-block for @{s} (identity {d})", .{ username, identity_id });
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

/// Registers every identity a message revealed *besides* its own sender into
/// this chat's roster.
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

/// Warden's own per-(chat, member) cooldown between messages.
fn checkSlowMode(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, msg: iface.Message, now: i64) bool {
    const min_seconds = rate_limits.getSlowModeSeconds(pool, chat_id);
    if (min_seconds <= 0) return false;

    if (auth.isOwner(config, connector.platform(), msg.user_id)) return false;
    const is_admin = connector.isGroupAdmin(a, msg.chat_id, msg.user_id) catch false;
    if (is_admin) return false;

    const last = rate_limits.getLastMessageAt(pool, chat_id, identity_id);
    if (rate_limits.isRateLimited(last, min_seconds, now)) {
        const message_id = msg.message_id orelse return false;
        connector.deleteMessage(a, msg.chat_id, message_id) catch |err| {
            log.warn("slowmode: failed to delete rate-limited message in chat {s}: {t}", .{ msg.chat_id, err });
        };
        log.debug("slowmode: deleted rate-limited message from user {s} in chat {s}", .{ msg.user_id, msg.chat_id });
        return true;
    }

    rate_limits.touchLastMessage(pool, chat_id, identity_id, now) catch |err| {
        log.err("slowmode: failed to record last-message time for chat {d}: {t}", .{ chat_id, err });
    };
    return false;
}

/// Rebuilds the in-memory enabled-chat set from every known chat's persisted
/// `chat_settings.digest_enabled`.
fn checkCuratedFeed(
    gpa: std.mem.Allocator,
    io: Io,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    config: *const config_mod.Config,
    now: i64,
) void {
    if (!feature_flags.isEnabled(pool, "curated_feed")) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const settings = feed_store.getSettings(pool, a) catch |err| {
        log.err("curated feed: couldn't read settings: {t}", .{err});
        return;
    };
    if (!settings.isRunnable()) return;
    if (now - settings.last_run_at < settings.interval_seconds) return;

    const dyn = resolveLlmDynamicSettings(pool, a, config);
    const posted = curated_feed.runOnce(pool, a, io, llm_provider, telegram_user, dyn.max_retries, now) catch |err| {
        log.err("curated feed: pass failed: {t}", .{err});
        return;
    };
    if (posted > 0) log.info("curated feed: posted {d} item(s)", .{posted});
}

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
/// platform (see `findConnector`).
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

        // `chat_type`/`title` null: this isn't a fresh inbound message, just a
        // scheduled check.
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

/// Same restore-on-restart shape as `loadDigestScheduleFromDisk` above.
fn loadBriefingScheduleFromDisk(gpa: std.mem.Allocator, pool: *store_pool.PgPool, briefing_scheduler: *scheduler.BriefingScheduler) void {
    const refs = chats.listAll(pool, gpa) catch |err| {
        log.err("briefing: failed to scan existing chats: {t}", .{err});
        return;
    };
    defer {
        for (refs) |r| gpa.free(r.native_chat_id);
        gpa.free(refs);
    }

    for (refs) |ref| {
        if (chat_settings.getBriefingEnabled(pool, ref.id)) {
            briefing_scheduler.enable(ref.platform, ref.native_chat_id) catch |err| {
                log.err("briefing: failed to restore schedule for chat {s}: {t}", .{ ref.native_chat_id, err });
            };
        }
    }
}

/// One formatted weather line for a chat's default location, or `null` if the
/// chat has none set, the lookup failed, or the place didn't geocode.
fn briefingWeatherLine(a: std.mem.Allocator, io: Io, pool: *store_pool.PgPool, chat_id: i64) ?[]const u8 {
    const location = chat_settings.getDefaultLocation(pool, a, chat_id) orelse return null;
    const weather = @import("tools/weather.zig");
    const reading = (weather.fetchWeather(a, io, location) catch |err| {
        log.warn("briefing: weather lookup failed for \"{s}\": {t}", .{ location, err });
        return null;
    }) orelse {
        log.warn("briefing: default location \"{s}\" didn't geocode", .{location});
        return null;
    };
    return std.fmt.allocPrint(a, "{s}, {s}: {s}, {d:.1}°C, wind {d:.1} km/h", .{
        reading.name,
        reading.country,
        weather.describeWeatherCode(reading.weather_code),
        reading.temperature_2m,
        reading.wind_speed_10m,
    }) catch null;
}

/// Same shape as `checkAndSendDueDigests` above, minus the `llm_provider`
/// param that one needs.
fn checkAndSendDueBriefings(
    connectors: []const iface.Connector,
    gpa: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    briefing_scheduler: *scheduler.BriefingScheduler,
    max_message_len: usize,
    now: i64,
) void {
    const enabled_chats = briefing_scheduler.snapshotEnabledChatIds(gpa) catch |err| {
        log.err("briefing: failed to snapshot enabled chats: {t}", .{err});
        return;
    };
    defer {
        for (enabled_chats) |k| gpa.free(k.native_chat_id);
        gpa.free(enabled_chats);
    }

    for (enabled_chats) |key| {
        const native_chat_id = key.native_chat_id;
        const connector = findConnector(connectors, key.platform) orelse {
            log.warn("briefing: no active connector for platform {s}, skipping chat {s}", .{ @tagName(key.platform), native_chat_id });
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const chat_id = chats.upsertChat(pool, connector.platform(), native_chat_id, null, null) catch |err| {
            log.err("briefing: failed to resolve chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };

        const last_sent = chat_settings.getLastBriefingTs(pool, chat_id);
        const briefing_interval_seconds = dynamic_config.getI64(pool, a, "WARDEN_BRIEFING_INTERVAL_SECONDS", config.briefing_interval_seconds);
        if (now - last_sent < briefing_interval_seconds) continue;

        const briefing_text = briefing.generate(a, pool, chat_id, now, briefingWeatherLine(a, io, pool, chat_id)) catch |err| {
            log.err("briefing: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };
        sendTextOrFile(connector, a, native_chat_id, briefing_text, null, max_message_len, "briefing.txt");
        chat_settings.setLastBriefingTs(pool, chat_id, now) catch |err| {
            log.err("briefing: failed to persist last_briefing_ts for chat {s}: {t}", .{ native_chat_id, err });
        };
    }
}

const LlmDynamicSettings = struct {
    owner_only: bool,
    show_thinking: bool,
    streaming: bool,
    length_limits: qa.LengthLimits,
    history_messages: i64,
    skip_trivial_messages: bool,
    vision_enabled: bool,
    documents_enabled: bool,
    max_retries: u32,
};

/// One `dynamic_config.listAll` fetch instead of six separate
/// `getBool`/`getI64` round trips for every free-form LLM turn.
fn resolveLlmDynamicSettings(pool: *store_pool.PgPool, a: std.mem.Allocator, config: *const config_mod.Config) LlmDynamicSettings {
    const rows = dynamic_config.listAll(pool, a) catch &.{};
    defer {
        for (rows) |r| {
            a.free(r.key);
            a.free(r.value);
        }
        a.free(rows);
    }

    // `WARDEN_LLM_MAX_TOKENS=0` (or any non-positive value) is treated the same
    // as "no override".
    const max_tokens_default: i64 = if (config.llm_max_tokens_override) |v| v else 0;
    const max_tokens_raw = dynamic_config.findI64(rows, "WARDEN_LLM_MAX_TOKENS", max_tokens_default);

    // An unparseable value (only possible via the env var; the API validates
    // writes) falls back to the built-in default rather than to no limit.
    const reply_length_raw = dynamic_config.findString(rows, "WARDEN_LLM_REPLY_LENGTH", config.llm_reply_length);
    const reply_length = qa.ReplyLength.parse(reply_length_raw) catch blk: {
        log.warn("llm: ignoring invalid WARDEN_LLM_REPLY_LENGTH \"{s}\"", .{reply_length_raw});
        break :blk qa.ReplyLength.parse(config_mod.Config.default_llm_reply_length) catch unreachable;
    };

    return .{
        .owner_only = dynamic_config.findBool(rows, "WARDEN_LLM_OWNER_ONLY", config.llm_owner_only),
        .show_thinking = dynamic_config.findBool(rows, "WARDEN_LLM_SHOW_THINKING", config.llm_show_thinking),
        .streaming = dynamic_config.findBool(rows, "WARDEN_LLM_STREAMING", config.llm_streaming),
        .length_limits = .{
            .max_tokens_override = if (max_tokens_raw > 0) @intCast(@min(max_tokens_raw, std.math.maxInt(u32))) else null,
            .reply_length = reply_length,
        },
        .history_messages = dynamic_config.findI64(rows, "WARDEN_LLM_HISTORY_MESSAGES", config.llm_history_messages),
        .skip_trivial_messages = dynamic_config.findBool(rows, "WARDEN_LLM_SKIP_TRIVIAL_MESSAGES", config.skip_trivial_messages),
        .vision_enabled = dynamic_config.findBool(rows, "WARDEN_LLM_VISION", config.llm_vision_enabled),
        .documents_enabled = dynamic_config.findBool(rows, "WARDEN_LLM_DOCUMENTS", config.llm_documents_enabled),
        // Clamped rather than trusted.
        .max_retries = blk: {
            const raw = dynamic_config.findI64(rows, "WARDEN_LLM_MAX_RETRIES", config.llm_max_retries);
            break :blk @intCast(std.math.clamp(raw, 0, 10));
        },
    };
}

/// One argument, one piece of text — e.g. `/translate spanish hola` splits
/// into `modifier="spanish"`, `text="hola"`.
const ModeArgSplit = struct {
    modifier: []const u8,
    text: []const u8,
};

/// Parses a "messaging mode" command's argument shape.
fn splitModeArgs(arg: []const u8, reply_to_text: ?[]const u8) ?ModeArgSplit {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) return null;

    const space_idx = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const modifier = trimmed[0..space_idx];
    const rest = if (space_idx < trimmed.len) std.mem.trim(u8, trimmed[space_idx..], " \t") else "";
    const text = if (rest.len > 0) rest else (reply_to_text orelse return null);
    return .{ .modifier = modifier, .text = text };
}

/// Same "explicit text, or fall back to the replied-to message" shape as
/// `splitModeArgs`, minus the leading modifier token — for /eli5 and
/// /brainstorm.
fn modeArgOrReplyText(arg: []const u8, reply_to_text: ?[]const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len > 0) return trimmed;
    return reply_to_text;
}

/// Shared entry point for the "messaging mode" commands (/translate,
/// /rewrite, /eli5, /brainstorm).
fn handleModeCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    io: Io,
    now: i64,
    max_message_len: usize,
    is_owner: bool,
    is_bot_admin: bool,
    msg: iface.Message,
    question: []const u8,
    in_flight: *cancel_request.InFlightRequests,
) void {
    const dyn = resolveLlmDynamicSettings(pool, a, config);
    const is_privileged = is_owner or is_bot_admin;
    if (dyn.owner_only and !is_privileged) return;

    const system_prompt = chat_settings.getSystemPromptOverride(pool, a, chat_id) orelse config.system_prompt;
    const show_thinking = chat_settings.getShowThinkingOverride(pool, chat_id) orelse dyn.show_thinking;
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
    replyWithAnswer(connector, a, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, system_prompt, io, now, retention_messages, max_message_len, msg.chat_id, msg.message_id, asker, question, null, null, dyn.streaming, show_thinking, dyn.vision_enabled, dyn.documents_enabled, dyn.length_limits, dyn.history_messages, dyn.max_retries, in_flight);
}

test "splitModeArgs splits a leading modifier token from the rest, falling back to reply_to_text" {
    const with_text = splitModeArgs("spanish hola amigo", null).?;
    try std.testing.expectEqualStrings("spanish", with_text.modifier);
    try std.testing.expectEqualStrings("hola amigo", with_text.text);

    const modifier_only = splitModeArgs("spanish", "earlier message").?;
    try std.testing.expectEqualStrings("spanish", modifier_only.modifier);
    try std.testing.expectEqualStrings("earlier message", modifier_only.text);

    try std.testing.expectEqual(@as(?ModeArgSplit, null), splitModeArgs("spanish", null));
    try std.testing.expectEqual(@as(?ModeArgSplit, null), splitModeArgs("", "earlier message"));
}

test "modeArgOrReplyText prefers explicit text, falls back to reply_to_text, else null" {
    try std.testing.expectEqualStrings("hi there", modeArgOrReplyText("  hi there  ", null).?);
    try std.testing.expectEqualStrings("earlier", modeArgOrReplyText("   ", "earlier").?);
    try std.testing.expectEqual(@as(?[]const u8, null), modeArgOrReplyText("", null));
}

const create_poll_max_options = 10;

/// One `|`-delimited part parsed by `parsePollCommand`, still owning the
/// whole allocation (`parts`) that `question`/`options` are views into.
const ParsedPoll = struct {
    question: []const u8,
    options: [][]const u8,
    parts: [][]const u8,
};

/// Parses `/poll <question> | <option1> | <option2> | ...` into a question
/// and 2-10 trimmed options.
fn parsePollCommand(a: std.mem.Allocator, arg: []const u8) union(enum) { ok: ParsedPoll, err: []const u8 } {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, arg, '|');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len > 0) parts.append(a, trimmed) catch return .{ .err = "Couldn't parse that poll, try again." };
    }
    const owned = parts.toOwnedSlice(a) catch return .{ .err = "Couldn't parse that poll, try again." };
    if (owned.len < 3) {
        a.free(owned);
        return .{ .err = "Usage: /poll <question> | <option 1> | <option 2> | ... (2-10 options)." };
    }
    if (owned.len - 1 > create_poll_max_options) {
        a.free(owned);
        return .{ .err = "A poll can have at most 10 options." };
    }
    return .{ .ok = .{ .question = owned[0], .options = owned[1..], .parts = owned } };
}

fn handlePollCommand(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/poll".len..], " \t");
    switch (parsePollCommand(a, arg)) {
        .err => |e| connector.sendMessage(a, msg.chat_id, e, msg.message_id),
        .ok => |parsed| connector.sendPoll(a, msg.chat_id, parsed.question, parsed.options, msg.message_id),
    }
}

test "parsePollCommand splits on | and trims whitespace, requiring at least 2 options" {
    const a = std.testing.allocator;

    const ok = parsePollCommand(a, "pizza or sushi? | pizza | sushi");
    defer switch (ok) {
        .ok => |v| a.free(v.parts),
        .err => {},
    };
    try std.testing.expect(ok == .ok);
    try std.testing.expectEqualStrings("pizza or sushi?", ok.ok.question);
    try std.testing.expectEqual(@as(usize, 2), ok.ok.options.len);
    try std.testing.expectEqualStrings("pizza", ok.ok.options[0]);
    try std.testing.expectEqualStrings("sushi", ok.ok.options[1]);

    const too_few = parsePollCommand(a, "just a question");
    try std.testing.expect(too_few == .err);
}

test "parsePollCommand rejects more than 10 options" {
    const a = std.testing.allocator;
    const many = parsePollCommand(a, "q | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11");
    defer switch (many) {
        .ok => |v| a.free(v.parts),
        .err => {},
    };
    try std.testing.expect(many == .err);
}

/// Which of `handleMessage`'s intake paths an incoming message takes.
pub const Route = enum {
    /// Straight to `reply_autonomy` (`handleTelegramUserAutoReply`), never
    /// the command dispatcher.
    personal_account_autonomy,
    /// The normal command + Q&A dispatch chain.
    command_and_qa,
    /// Nothing happens (the sender isn't allowed to make the bot act here).
    ignored,
};

/// Warden's own Bot API user id, parsed out of the `<user id>:<secret>` shape
/// every Telegram bot token has.
pub fn telegramBotUserId(token: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, token, ':') orelse return null;
    const id = token[0..colon];
    if (id.len == 0) return null;
    for (id) |c| if (!std.ascii.isDigit(c)) return null;
    return id;
}

/// Whether `native_chat_id` is Warden's own DM with the owner, seen from the
/// personal account.
pub fn isOwnBotDm(platform: iface.Platform, native_chat_id: []const u8, bot_token: []const u8) bool {
    if (platform != .telegram_user) return false;
    const bot_id = telegramBotUserId(bot_token) orelse return false;
    return std.mem.eql(u8, native_chat_id, bot_id);
}

test "telegramBotUserId: parses the id prefix, rejects anything malformed" {
    try std.testing.expectEqualStrings("8807952951", telegramBotUserId("8807952951:AAHreal-looking-secret").?);
    try std.testing.expectEqualStrings("123", telegramBotUserId("123:x").?);
    // No colon, empty id, and a non-numeric id all have to come back null rather
    // than a wrong id.
    try std.testing.expect(telegramBotUserId("no-colon-here") == null);
    try std.testing.expect(telegramBotUserId(":secret") == null);
    try std.testing.expect(telegramBotUserId("notanumber:secret") == null);
    try std.testing.expect(telegramBotUserId("") == null);
}

test "isOwnBotDm: matches the bot's own DM by its native chat id" {
    // The real ids from the production loop: the bot is 8807952951, and its
    // DM with the owner is the chat with that same native id.
    const token = "8807952951:AAHreal-looking-secret";
    try std.testing.expect(isOwnBotDm(.telegram_user, "8807952951", token));

    // A group and another contact's DM must be untouched.
    try std.testing.expect(!isOwnBotDm(.telegram_user, "-1003974181733", token));
    try std.testing.expect(!isOwnBotDm(.telegram_user, "101573604", token));

    // The regression that shipped: `handleMessage`'s `chat_id` parameter is the
    // internal `chats` row id, a small integer nothing like the bot's user id.
    try std.testing.expect(!isOwnBotDm(.telegram_user, "7", token));
    try std.testing.expect(!isOwnBotDm(.telegram_user, "1", token));

    // Only the personal-account connector.
    try std.testing.expect(!isOwnBotDm(.telegram, "8807952951", token));
    try std.testing.expect(!isOwnBotDm(.instagram, "8807952951", token));

    // A malformed token must fail closed for the *bot's* chat only by way
    // of returning false everywhere -- there is no id to compare against.
    try std.testing.expect(!isOwnBotDm(.telegram_user, "8807952951", "malformed-token"));
}

/// The single decision about how far an incoming message gets, extracted from
/// `handleMessage` so it can actually be tested.
pub fn routeIncoming(
    platform: iface.Platform,
    is_owner: bool,
    is_bot_admin: bool,
    blocked: bool,
    is_own_bot_dm: bool,
) Route {
    if (platform == .telegram_user) {
        if (is_own_bot_dm) return .ignored;
        return .personal_account_autonomy;
    }
    if (is_owner or is_bot_admin) return .command_and_qa;
    if (blocked) return .ignored;
    return .command_and_qa;
}

test "routeIncoming: a personal-account message reaches autonomy whatever its sender's standing" {
    // The exact shape of the original bug: an inbound DM on the owner's personal
    // account is always from someone else, so is_owner/ is_bot_admin are false.
    try std.testing.expectEqual(
        Route.personal_account_autonomy,
        routeIncoming(.telegram_user, false, false, false, false),
    );
    try std.testing.expectEqual(
        Route.personal_account_autonomy,
        routeIncoming(.telegram_user, false, false, true, false),
    );
}

test "routeIncoming: a personal-account message is never dispatched as a command, whoever it looks like it's from" {
    // A contact DMing the personal account must never reach the command chain: a
    // reply to `/stats` there would go out under the owner's own identity.
    for ([_]bool{ false, true }) |is_owner| {
        for ([_]bool{ false, true }) |is_bot_admin| {
            for ([_]bool{ false, true }) |blocked| {
                try std.testing.expectEqual(
                    Route.personal_account_autonomy,
                    routeIncoming(.telegram_user, is_owner, is_bot_admin, blocked, false),
                );
            }
        }
    }
}

test "routeIncoming: bot connectors answer everyone except the blocked; owner and bot admins can't be blocked" {
    // Every non-personal platform.
    for ([_]iface.Platform{ .telegram, .matrix, .xmpp, .discord, .whatsapp, .instagram }) |platform| {
        try std.testing.expectEqual(Route.command_and_qa, routeIncoming(platform, false, false, false, false));
        try std.testing.expectEqual(Route.ignored, routeIncoming(platform, false, false, true, false));
        try std.testing.expectEqual(Route.command_and_qa, routeIncoming(platform, true, true, true, false));
        try std.testing.expectEqual(Route.command_and_qa, routeIncoming(platform, false, true, true, false));
    }
}

test "routeIncoming: the personal account's DM with Warden's own bot is left alone" {
    // The production loop: with autonomy on, the bot drafted a reply to its own
    // draft notification, whose delivery produced another notification.
    try std.testing.expectEqual(
        Route.ignored,
        routeIncoming(.telegram_user, false, false, false, true),
    );
    // Whatever else the message looks like.
    for ([_]bool{ false, true }) |is_owner| {
        for ([_]bool{ false, true }) |is_bot_admin| {
            for ([_]bool{ false, true }) |blocked| {
                try std.testing.expectEqual(
                    Route.ignored,
                    routeIncoming(.telegram_user, is_owner, is_bot_admin, blocked, true),
                );
            }
        }
    }
}

test "routeIncoming: the self-DM carve-out is scoped to the personal account" {
    // Is_own_bot_dm is only ever computed for `.telegram_user`, but it must not
    // change any other platform's routing even if it were set.
    for ([_]iface.Platform{ .telegram, .matrix, .xmpp, .discord, .whatsapp, .instagram }) |platform| {
        try std.testing.expectEqual(Route.command_and_qa, routeIncoming(platform, true, false, false, true));
        try std.testing.expectEqual(Route.command_and_qa, routeIncoming(platform, false, false, false, true));
        try std.testing.expectEqual(Route.ignored, routeIncoming(platform, false, false, true, true));
    }
}

/// Returns whether this message's attachment (if any) was claimed by the
/// interactive `/convert` flow.
fn handleMessage(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    pending_undos: *audit_notify.PendingUndos,
    digest_scheduler: *scheduler.DigestScheduler,
    briefing_scheduler: *scheduler.BriefingScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    menu_sessions: *menu.Sessions,
    in_flight: *cancel_request.InFlightRequests,
    io: Io,
    now: i64,
    max_message_len: usize,
    msg: iface.Message,
    /// True only on the recursive call `/as` makes to replay a command against
    /// another chat (see `resolveAsCommand`).
    relayed: bool,
    /// The personal-account connector, if `WARDEN_TELEGRAM_USER_*` is configured
    /// — `null` otherwise.
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    /// `reply_autonomy = .draft` staging area.
    pending_drafts: *reply_drafts.PendingDrafts,
    /// The Bot API connector to notify the owner through when a draft is ready
    /// for review.
    owner_notify: iface.Connector,
    /// The Instagram personal-account connector, if `WARDEN_INSTAGRAM_*` is
    /// configured — `null` otherwise.
    instagram: ?*instagram_platform.InstagramConnector,
) bool {
    // Coarse "how far does this message get" gate.
    const is_owner = auth.isOwner(config, connector.platform(), msg.user_id);
    // The owner is the highest privilege there is and shouldn't need a redundant
    // `bot_admins` row on top of that — before this, `is_bot_admin` was DB-only.
    const is_bot_admin = is_owner or bot_admins.isBotAdmin(pool, identity_id);
    const platform = connector.platform();
    // Warden's own DM with the owner, seen from the personal account.
    const is_own_bot_dm = isOwnBotDm(platform, msg.chat_id, config.telegram_bot_token);
    switch (routeIncoming(
        platform,
        is_owner,
        is_bot_admin,
        // `and` short-circuits, so the blocklist is only actually queried for a non-
        // owner, non-admin on a bot connector.
        platform != .telegram_user and !is_owner and !is_bot_admin and
            (bot_blocklist.isUserBlocked(pool, identity_id) or bot_blocklist.isChatBlocked(pool, chat_id)),
        is_own_bot_dm,
    )) {
        .ignored => return false,
        .personal_account_autonomy => {
            const incoming = msg.text orelse return false;
            if (incoming.len == 0) return false;
            // Storage sense's flood-watermark sleep still applies, same as it does to the
            // LLM paths below.
            if (storage_sense.isSleepModeActive(pool, a)) return false;
            handleTelegramUserAutoReply(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, msg, incoming, owner_notify, pending_drafts, telegram_user);
            return false;
        },
        .command_and_qa => {},
    }

    // A button press / reaction pick has neither text nor an attachment of
    // its own, so this must run before the "neither" bail-out just below.
    if (msg.choice_picked) |picked| {
        // "Undo" button on an audit-log entry — keyed by (control room, prompt
        // message) rather than (chat, user).
        if (audit_notify.handleUndoPicked(connector, a, pending_undos, now, msg, picked)) {
            return false;
        }
        // Same "checked on its own first, false for anything not its own" shape
        // again.
        if (cancel_request.handleCancelPicked(connector, a, in_flight, now, msg, picked)) {
            return false;
        }
        // Same "checked on its own first, false for anything not its own" shape as
        // the Undo button above.
        if (handleDraftChoicePicked(connector, a, io, config, telegram_user, pending_drafts, now, msg, picked)) {
            return false;
        }
        if (handleTdChatsPagePicked(connector, a, config, telegram_user, msg, picked)) {
            return false;
        }
        // Both flows key their pending state the same way ((chat, user)), so only one
        // of them should ever actually claim a given pick.
        if (pending_conversions.isAwaitingFormat(now, msg.chat_id, msg.user_id)) {
            convert_flow.handleChoicePicked(connector, a, io, config.tmp_dir, pending_conversions, now, msg, picked);
        } else {
            var live_admin_cache: ?bool = null;
            menu_sessions.handleChoicePicked(menu_runner, now, menuCtx(connector, a, pool, config, chat_id, identity_id, now, msg, io, digest_scheduler, pending_conversions, pending_undos, is_owner, is_bot_admin, &live_admin_cache), picked);
        }
        return false;
    }

    // A photo/document/voice/audio/video with no caption has no `text` at all
    // (Telegram never sets it for those).
    const raw_text = msg.text orelse "";
    if (raw_text.len == 0 and msg.attachment == null) return false;

    var text = normalizeCommandMention(a, raw_text, connector.selfUsername()) orelse return false;

    // Storage sense's flood-watermark sleep mode (`storage_sense.zig`): pauses
    // everything below this point except the owner's own `/storage` commands.
    if (storage_sense.isSleepModeActive(pool, a)) {
        const is_storage_cmd = std.mem.eql(u8, text, "/storage") or std.mem.startsWith(u8, text, "/storage ");
        if (!(is_owner and is_storage_cmd)) {
            if (storage_sense.shouldNotifySleepOnce(io, msg.chat_id)) {
                reply(connector, a, msg.chat_id, msg.message_id, "Temporarily paused for storage maintenance.");
            }
            return false;
        }
    }

    // `/sudo <command>` lets a bot admin override a platform-level permission
    // check for one command.
    var sudo_active = false;
    if (std.mem.startsWith(u8, text, "/sudo ") and is_bot_admin) {
        sudo_active = true;
        text = std.fmt.allocPrint(a, "/{s}", .{std.mem.trim(u8, text["/sudo ".len..], " ")}) catch text;
    }

    // Custom command aliases.
    if (feature_flags.isEnabled(pool, "power_tools") and text.len > 1 and text[0] == '/') {
        const cmd_end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
        const cmd_name = text[1..cmd_end];
        if (isReservedCommandName(cmd_name)) {
            // Fall through with `text` untouched.
        } else if (command_aliases.get(pool, a, chat_id, cmd_name) catch null) |alias| {
            const trailing = std.mem.trim(u8, text[cmd_end..], " ");
            text = if (trailing.len > 0)
                std.fmt.allocPrint(a, "{s} {s}", .{ alias.expansion, trailing }) catch text
            else
                alias.expansion;
        }
    }

    // A plain message (or reply) arriving while.
    var menu_live_admin_cache: ?bool = null;
    if (!std.mem.eql(u8, text, "/cancel") and
        menu_sessions.handleAwaitingInputMessage(menu_runner, menuCtx(connector, a, pool, config, chat_id, identity_id, now, msg, io, digest_scheduler, pending_conversions, pending_undos, is_owner, is_bot_admin, &menu_live_admin_cache)))
    {
        return false;
    }

    // An attachment arriving while (chat, user) is mid-flow, waiting for a file —
    // claimed here, before the big dispatch chain and before `isAddressedToBot`.
    if (msg.attachment != null and !isOneShotConvertCaption(text) and
        pending_conversions.isAwaitingFile(a, now, msg.chat_id, msg.user_id))
    {
        if (convert_flow.claimAttachmentForConvert(connector, a, pending_conversions, now, msg, tool_ctx.attachment_path.?, tool_ctx.attachment_file_name)) return true;
        // Claim failed (e.g. no candidate targets for this file type) —
        // fall through to normal dispatch below.
    }

    // A command typed directly in a room bound to a target chat (`/manage bind`)
    // runs against that target with no `/as <id>` prefix.
    if (feature_flags.isEnabled(pool, "management_rooms")) {
        if (resolveDirectRoomCommand(connector, a, config, pool, chat_id, msg, text, relayed)) |relay| {
            var redirect = reply_redirect.ReplyRedirect.init(connector, relay.target_native_chat_id, msg.chat_id, msg.message_id);
            return handleMessage(
                redirect.connector(),
                a,
                config,
                pool,
                relay.target_chat_id,
                identity_id,
                llm_provider,
                embeddings_client,
                tool_ctx,
                tools,
                pending,
                pending_undos,
                digest_scheduler,
                briefing_scheduler,
                pending_conversions,
                menu_sessions,
                in_flight,
                io,
                now,
                max_message_len,
                asRelayedMessage(msg, relay.target_native_chat_id, relay.command),
                true,
                telegram_user,
                pending_drafts,
                owner_notify,
                instagram,
            );
        }
    }

    if (std.mem.eql(u8, text, "/ping")) {
        connector.sendMessage(a, msg.chat_id, "pong", msg.message_id);
    } else if (std.mem.eql(u8, text, "/help") or std.mem.startsWith(u8, text, "/help ")) {
        handleHelp(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/menu")) {
        if (!feature_flags.isEnabled(pool, "menu")) return false;
        // `!menu` already reaches here as `/menu` too -- `normalizeCommandMention`
        // rewrites any leading `!` to `/` for every platform.
        menu_sessions.open(menu_runner, menuCtx(connector, a, pool, config, chat_id, identity_id, now, msg, io, digest_scheduler, pending_conversions, pending_undos, is_owner, is_bot_admin, &menu_live_admin_cache));
    } else if (std.mem.eql(u8, text, "/stats")) {
        replyWithStats(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/wordcloud")) {
        replyWithWordcloud(connector, a, pool, chat_id, config.tmp_dir, io, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/digest") or std.mem.startsWith(u8, text, "/digest ")) {
        if (!feature_flags.isEnabled(pool, "digest")) return false;
        handleDigestCommand(connector, a, pool, chat_id, digest_scheduler, llm_provider, tool_ctx, now, max_message_len, msg.chat_id, msg.message_id, text);
    } else if (std.mem.eql(u8, text, "/briefing") or std.mem.startsWith(u8, text, "/briefing ")) {
        if (!feature_flags.isEnabled(pool, "briefings")) return false;
        handleBriefingCommand(connector, a, io, pool, chat_id, briefing_scheduler, now, max_message_len, msg.chat_id, msg.message_id, text);
    } else if (std.mem.eql(u8, text, "/summary") or std.mem.startsWith(u8, text, "/summary ")) {
        // Gated with `/digest` rather than on its own flag: it's the same summarizer
        // over a caller-named window (see `handleSummaryCommand`).
        if (!feature_flags.isEnabled(pool, "digest")) return false;
        handleSummaryCommand(connector, a, pool, chat_id, llm_provider, tool_ctx, now, max_message_len, msg, text);
    } else if (std.mem.eql(u8, text, "/announce") or std.mem.startsWith(u8, text, "/announce ")) {
        if (!feature_flags.isEnabled(pool, "announcements")) return false;
        handleAnnounceCommand(connector, a, config, pool, chat_id, identity_id, now, sudo_active, msg, text);
    } else if (std.mem.eql(u8, text, "/autopin") or std.mem.startsWith(u8, text, "/autopin ")) {
        // One flag for both commands — auto-pin is a property of how
        // announcements are delivered, not a separate feature.
        if (!feature_flags.isEnabled(pool, "announcements")) return false;
        handleAutopinCommand(connector, a, config, pool, chat_id, identity_id, sudo_active, msg, text);
    } else if (std.mem.eql(u8, text, "/silent") or std.mem.startsWith(u8, text, "/silent ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        handleSilentCommand(connector, a, config, pool, chat_id, identity_id, sudo_active, msg, text);
    } else if (std.mem.eql(u8, text, "/videodownload") or std.mem.startsWith(u8, text, "/videodownload ")) {
        if (!feature_flags.isEnabled(pool, "video_download")) return false;
        handleVideoDownloadCommand(connector, a, config, pool, chat_id, identity_id, sudo_active, msg, text);
    } else if (std.mem.eql(u8, text, "/videoquality") or std.mem.startsWith(u8, text, "/videoquality ")) {
        if (!feature_flags.isEnabled(pool, "video_download")) return false;
        handleVideoQualityCommand(connector, a, config, pool, chat_id, identity_id, sudo_active, msg, text);
    } else if (std.mem.eql(u8, text, "/mute") or std.mem.startsWith(u8, text, "/mute ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "mute")) return false;
        const vis = resolveVisibility(pool, a, chat_id, std.mem.trim(u8, text["/mute".len..], " "), is_bot_admin);
        group_admin.mute(connector, a, msg, now, auditCtxWithVisibility(pool, pending_undos, chat_id, identity_id, msg, vis.visibility));
    } else if (std.mem.eql(u8, text, "/unmute") or std.mem.startsWith(u8, text, "/unmute ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "unmute")) return false;
        const vis = resolveVisibility(pool, a, chat_id, std.mem.trim(u8, text["/unmute".len..], " "), is_bot_admin);
        group_admin.unmute(connector, a, msg, now, auditCtxWithVisibility(pool, pending_undos, chat_id, identity_id, msg, vis.visibility));
    } else if (std.mem.eql(u8, text, "/pin")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "pin")) return false;
        group_admin.pin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/unpin")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "unpin")) return false;
        group_admin.unpin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/delete")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "delete")) return false;
        group_admin.deleteMessage(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/promote") or std.mem.startsWith(u8, text, "/promote ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        // Owner-only, not `checkGroupAdminAccess`.
        if (!is_owner) return false;
        const vis = resolveVisibility(pool, a, chat_id, std.mem.trim(u8, text["/promote".len..], " "), is_bot_admin);
        group_admin.promote(connector, a, msg, now, auditCtxWithVisibility(pool, pending_undos, chat_id, identity_id, msg, vis.visibility));
    } else if (std.mem.eql(u8, text, "/demote") or std.mem.startsWith(u8, text, "/demote ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!is_owner) return false;
        const vis = resolveVisibility(pool, a, chat_id, std.mem.trim(u8, text["/demote".len..], " "), is_bot_admin);
        group_admin.demote(connector, a, msg, now, auditCtxWithVisibility(pool, pending_undos, chat_id, identity_id, msg, vis.visibility));
    } else if (std.mem.eql(u8, text, "/kick") or std.mem.startsWith(u8, text, "/kick ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "kick")) return false;
        handleKickBanCommand(connector, a, pool, chat_id, identity_id, pending_undos, is_bot_admin, now, msg, text, "/kick", .kick);
    } else if (std.mem.eql(u8, text, "/ban") or std.mem.startsWith(u8, text, "/ban ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "ban")) return false;
        handleKickBanCommand(connector, a, pool, chat_id, identity_id, pending_undos, is_bot_admin, now, msg, text, "/ban", .ban);
    } else if (std.mem.eql(u8, text, "/confirm")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "confirm")) return false;
        group_admin.confirm(connector, a, pending, now, msg);
    } else if (std.mem.eql(u8, text, "/cancel")) {
        // Three tiers, tried in order — a pending conversion or an open `/menu`
        // prompt waiting on input are both per-user, not a moderation action.
        if (pending_conversions.cancel(a, msg.chat_id, msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Conversion cancelled.");
        } else if (menu_sessions.cancel(msg.chat_id, msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Menu prompt cancelled.");
        } else {
            if (!feature_flags.isEnabled(pool, "group_admin")) return false;
            if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "cancel")) return false;
            group_admin.cancel(connector, a, pending, msg);
        }
    } else if (std.mem.eql(u8, text, "/slowmode") or std.mem.startsWith(u8, text, "/slowmode ")) {
        // It's the same moderation-tier feature set, not its own toggle.
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "slowmode")) return false;
        handleSlowmodeCommand(connector, a, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/permission") or std.mem.startsWith(u8, text, "/permission ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "permission")) return false;
        handlePermissionCommand(connector, a, pool, chat_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/tag") or std.mem.startsWith(u8, text, "/tag ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "tag")) return false;
        handleTagCommand(connector, a, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/blockuser") or std.mem.startsWith(u8, text, "/blockuser ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleBlockUserCommand(connector, a, config, pool, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/unblockuser") or std.mem.startsWith(u8, text, "/unblockuser ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleUnblockUserCommand(connector, a, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/blockchat")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleBlockChatCommand(connector, a, pool, chat_id, identity_id, msg);
    } else if (std.mem.eql(u8, text, "/unblockchat")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleUnblockChatCommand(connector, a, pool, chat_id, msg);
    } else if (std.mem.eql(u8, text, "/addadmin") or std.mem.startsWith(u8, text, "/addadmin ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleAddAdminCommand(connector, a, pool, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/removeadmin") or std.mem.startsWith(u8, text, "/removeadmin ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleRemoveAdminCommand(connector, a, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/storage") or std.mem.startsWith(u8, text, "/storage ")) {
        // Hidden, owner-only; reserved so `/alias` can't shadow it.
        if (!is_owner) return false;
        handleStorageCommand(connector, a, config, pool, io, llm_provider, chat_id, identity_id, msg, text, now);
    } else if (std.mem.eql(u8, text, "/whois") or std.mem.startsWith(u8, text, "/whois ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleWhoisCommand(connector, a, config, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/chatinfo") or std.mem.startsWith(u8, text, "/chatinfo ")) {
        // Chat-scoped admin tier, not `/whois`'s bot-wide one: this answers a
        // question about *this* chat, and its whole purpose is to feed `/manage
        // bind`.
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "chatinfo")) return false;
        handleChatInfoCommand(connector, a, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/manage") or std.mem.startsWith(u8, text, "/manage ")) {
        if (!feature_flags.isEnabled(pool, "management_rooms")) return false;
        handleManageCommand(connector, a, config, pool, chat_id, identity_id, msg, text);
    } else if (std.mem.eql(u8, text, "/as") or std.mem.startsWith(u8, text, "/as ")) {
        // No binding required any more).
        if (!feature_flags.isEnabled(pool, "management_rooms")) return false;
        const relay = resolveAsCommand(connector, a, config, pool, chat_id, msg, text, relayed) orelse return false;
        var redirect = reply_redirect.ReplyRedirect.init(connector, relay.target_native_chat_id, msg.chat_id, msg.message_id);
        return handleMessage(
            redirect.connector(),
            a,
            config,
            pool,
            relay.target_chat_id,
            identity_id,
            llm_provider,
            embeddings_client,
            tool_ctx,
            tools,
            pending,
            pending_undos,
            digest_scheduler,
            briefing_scheduler,
            pending_conversions,
            menu_sessions,
            in_flight,
            io,
            now,
            max_message_len,
            asRelayedMessage(msg, relay.target_native_chat_id, relay.command),
            true,
            telegram_user,
            pending_drafts,
            owner_notify,
            instagram,
        );
    } else if (std.mem.eql(u8, text, "/redact") or std.mem.startsWith(u8, text, "/redact ")) {
        // Per-mode gating happens inside handleRedactCommand itself (regex mode is
        // stricter than the other modes) rather than here.
        handleRedactCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text, sudo_active);
    } else if (std.mem.eql(u8, text, "/magicword") or std.mem.startsWith(u8, text, "/magicword ")) {
        handleMagicWord(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/location") or std.mem.startsWith(u8, text, "/location ")) {
        handleLocationCommand(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/persona") or std.mem.startsWith(u8, text, "/persona ")) {
        handlePersonaCommand(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/welcome") or std.mem.startsWith(u8, text, "/welcome ")) {
        handleWelcomeCommand(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/photo") or std.mem.startsWith(u8, text, "/photo ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        handlePhotoCommand(connector, a, config, pool, io, chat_id, identity_id, pending_undos, now, sudo_active, is_bot_admin, msg, text, tool_ctx.attachment_path);
    } else if (std.mem.eql(u8, text, "/title") or std.mem.startsWith(u8, text, "/title ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        handleTitleCommand(connector, a, config, pool, chat_id, identity_id, pending_undos, now, sudo_active, is_bot_admin, msg, text);
    } else if (std.mem.eql(u8, text, "/description") or std.mem.startsWith(u8, text, "/description ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        handleDescriptionCommand(connector, a, config, pool, chat_id, identity_id, pending_undos, now, sudo_active, is_bot_admin, msg, text);
    } else if (std.mem.eql(u8, text, "/thinking") or std.mem.startsWith(u8, text, "/thinking ")) {
        handleThinkingCommand(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/scraper") or std.mem.startsWith(u8, text, "/scraper ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleScraperCommand(connector, a, pool, msg, text);
    } else if (std.mem.eql(u8, text, "/tdlogin") or std.mem.startsWith(u8, text, "/tdlogin ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleTdloginCommand(connector, a, config, telegram_user, io, msg, text);
    } else if (std.mem.eql(u8, text, "/iglogin") or std.mem.startsWith(u8, text, "/iglogin ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleIgloginCommand(connector, a, config, instagram, msg, text);
    } else if (std.mem.eql(u8, text, "/tdlogout")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        if (telegram_user) |conn| {
            performTdLogout(connector, a, conn, msg);
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment.");
        }
    } else if (std.mem.eql(u8, text, "/sendas") or std.mem.startsWith(u8, text, "/sendas ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleSendAsCommand(connector, a, config, telegram_user, msg, "/sendas", text);
    } else if (std.mem.eql(u8, text, "/tdsend") or std.mem.startsWith(u8, text, "/tdsend ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleSendAsCommand(connector, a, config, telegram_user, msg, "/tdsend", text);
    } else if (std.mem.eql(u8, text, "/tdchats")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleTdchatsCommand(connector, a, config, telegram_user, msg);
    } else if (std.mem.eql(u8, text, "/tdsearch") or std.mem.startsWith(u8, text, "/tdsearch ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleTdSearchCommand(connector, a, config, telegram_user, msg, text);
    } else if (std.mem.eql(u8, text, "/tdsummary") or std.mem.startsWith(u8, text, "/tdsummary ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleTdSummaryCommand(connector, a, config, pool, telegram_user, llm_provider, io, tool_ctx, msg, text);
    } else if (std.mem.eql(u8, text, "/autonomy") or std.mem.startsWith(u8, text, "/autonomy ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleAutonomyCommand(connector, a, config, pool, msg, text, now);
    } else if (std.mem.eql(u8, text, "/feed") or std.mem.startsWith(u8, text, "/feed ")) {
        if (!feature_flags.isEnabled(pool, "curated_feed")) return false;
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleFeedCommand(connector, a, config, pool, io, llm_provider, telegram_user, msg, text, now);
    } else if (std.mem.eql(u8, text, "/drafts")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleDraftsListCommand(connector, a, config, pending_drafts, msg, now);
    } else if (std.mem.eql(u8, text, "/approve") or std.mem.startsWith(u8, text, "/approve ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleApproveCommand(connector, a, config, telegram_user, pending_drafts, msg, text, now, io);
    } else if (std.mem.eql(u8, text, "/discard") or std.mem.startsWith(u8, text, "/discard ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleDiscardCommand(connector, a, config, telegram_user, pending_drafts, msg, text, io);
    } else if (std.mem.eql(u8, text, "/remind") or std.mem.startsWith(u8, text, "/remind ")) {
        if (!feature_flags.isEnabled(pool, "reminders")) return false;
        handleRemindCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/reminders")) {
        handleRemindersList(connector, a, pool, chat_id, now, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/note") or std.mem.startsWith(u8, text, "/note ")) {
        if (!feature_flags.isEnabled(pool, "notes")) return false;
        handleNoteCommand(connector, a, io, config, pool, tool_ctx, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/notes")) {
        handleNotesList(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/keyword") or std.mem.startsWith(u8, text, "/keyword ")) {
        if (!feature_flags.isEnabled(pool, "keyword_alerts")) return false;
        handleKeywordCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/expense") or std.mem.startsWith(u8, text, "/expense ")) {
        if (!feature_flags.isEnabled(pool, "finance")) return false;
        handleExpenseCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/budget") or std.mem.startsWith(u8, text, "/budget ")) {
        if (!feature_flags.isEnabled(pool, "finance")) return false;
        handleBudgetCommand(connector, a, config, pool, chat_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/subscription") or std.mem.startsWith(u8, text, "/subscription ")) {
        if (!feature_flags.isEnabled(pool, "finance")) return false;
        handleSubscriptionCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/alias") or std.mem.startsWith(u8, text, "/alias ")) {
        if (!feature_flags.isEnabled(pool, "power_tools")) return false;
        handleAliasCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/template") or std.mem.startsWith(u8, text, "/template ")) {
        if (!feature_flags.isEnabled(pool, "power_tools")) return false;
        handleTemplateCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, text, in_flight);
    } else if (std.mem.eql(u8, text, "/joke") or std.mem.startsWith(u8, text, "/joke ")) {
        if (!feature_flags.isEnabled(pool, "power_tools")) return false;
        const topic = std.mem.trim(u8, text["/joke".len..], " ");
        const question = if (topic.len > 0)
            std.fmt.allocPrint(a, "Tell a short, genuinely funny joke about {s}. Just the joke, no setup commentary.", .{topic}) catch return false
        else
            "Tell a short, genuinely funny joke. Just the joke, no setup commentary.";
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/riddle") or std.mem.startsWith(u8, text, "/riddle ")) {
        if (!feature_flags.isEnabled(pool, "power_tools")) return false;
        const topic = std.mem.trim(u8, text["/riddle".len..], " ");
        const question = if (topic.len > 0)
            std.fmt.allocPrint(a, "Give me a clever riddle about {s} and its answer, but put the answer on its own new line after \"Answer:\" so it isn't spoiled immediately.", .{topic}) catch return false
        else
            "Give me a clever riddle and its answer, but put the answer on its own new line after \"Answer:\" so it isn't spoiled immediately.";
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/trivia") or std.mem.startsWith(u8, text, "/trivia ")) {
        if (!feature_flags.isEnabled(pool, "power_tools")) return false;
        const topic = std.mem.trim(u8, text["/trivia".len..], " ");
        const question = if (topic.len > 0)
            std.fmt.allocPrint(a, "Give me one genuinely interesting trivia fact about {s}, in 1-2 sentences.", .{topic}) catch return false
        else
            "Give me one genuinely interesting trivia fact, in 1-2 sentences.";
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/wordoftheday")) {
        if (!feature_flags.isEnabled(pool, "power_tools")) return false;
        const question = "Give me an interesting, moderately advanced English word of the day: the word, a short definition, and one example sentence using it.";
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/motivate") or std.mem.startsWith(u8, text, "/motivate ")) {
        if (!feature_flags.isEnabled(pool, "power_tools")) return false;
        const context = modeArgOrReplyText(text["/motivate".len..], msg.reply_to_text);
        const question = if (context) |c|
            std.fmt.allocPrint(a, "Give me a short, genuine, non-cheesy motivational message. Tailor it to this: {s}", .{c}) catch return false
        else
            "Give me a short, genuine, non-cheesy motivational message.";
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/memory") or std.mem.startsWith(u8, text, "/memory ")) {
        if (!feature_flags.isEnabled(pool, "memory")) return false;
        handleMemoryCommand(connector, a, pool, identity_id, msg, text);
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
    } else if (std.mem.eql(u8, text, "/translate") or std.mem.startsWith(u8, text, "/translate ")) {
        // Messaging assistance modes -- thin, reliable command surfaces over the
        // existing Q&A path.
        if (!feature_flags.isEnabled(pool, "messaging_modes")) return false;
        const split = splitModeArgs(text["/translate".len..], msg.reply_to_text) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /translate <language> <text>, or reply to a message with /translate <language>.");
            return false;
        };
        const question = std.fmt.allocPrint(a, "Translate the following into {s}. Reply with only the translation, no commentary or notes:\n\n{s}", .{ split.modifier, split.text }) catch return false;
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/rewrite") or std.mem.startsWith(u8, text, "/rewrite ")) {
        if (!feature_flags.isEnabled(pool, "messaging_modes")) return false;
        const split = splitModeArgs(text["/rewrite".len..], msg.reply_to_text) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /rewrite <tone> <text>, or reply to a message with /rewrite <tone>.");
            return false;
        };
        const question = std.fmt.allocPrint(a, "Rewrite the following in a {s} tone. Reply with only the rewritten text, no commentary or notes:\n\n{s}", .{ split.modifier, split.text }) catch return false;
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/eli5") or std.mem.startsWith(u8, text, "/eli5 ")) {
        if (!feature_flags.isEnabled(pool, "messaging_modes")) return false;
        const source = modeArgOrReplyText(text["/eli5".len..], msg.reply_to_text) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /eli5 <text>, or reply to a message with /eli5.");
            return false;
        };
        const question = std.fmt.allocPrint(a, "Explain the following like I'm five years old -- simple everyday language, short sentences, no jargon:\n\n{s}", .{source}) catch return false;
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/brainstorm") or std.mem.startsWith(u8, text, "/brainstorm ")) {
        if (!feature_flags.isEnabled(pool, "messaging_modes")) return false;
        const source = modeArgOrReplyText(text["/brainstorm".len..], msg.reply_to_text) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /brainstorm <topic>, or reply to a message with /brainstorm.");
            return false;
        };
        const question = std.fmt.allocPrint(a, "Brainstorm this: give a short list of concrete ideas or options. If it reads like a decision between choices, briefly weigh the trade-offs too:\n\n{s}", .{source}) catch return false;
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
    } else if (std.mem.eql(u8, text, "/poll") or std.mem.startsWith(u8, text, "/poll ")) {
        // Group/Telegram quality-of-life.
        if (!feature_flags.isEnabled(pool, "polls")) return false;
        handlePollCommand(connector, a, msg, text);
    } else if (text.len > 0 and text[0] == '/') {
        // Unrecognized slash command: ignore rather than forwarding to the
        // LLM as if it were a question.
        return false;
    } else if (isAddressedToBot(a, pool, chat_id, msg, text)) {
        // A message that's *just* a YouTube/Instagram/X link is already handled by
        // `checkVideoDownload` in `processMessageTask` (if enabled).
        if (video_download.findLink(text)) |link| {
            if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), link)) return false;
        }

        // One bulk dynamic_config fetch for every setting this branch reads, instead
        // of six separate round trips.
        const dyn = resolveLlmDynamicSettings(pool, a, config);

        // A greeting/ack/sign-off addressed to the bot doesn't need a real (paid) LLM
        // call to answer meaningfully.
        if (dyn.skip_trivial_messages and trivial_reply.isTrivialMessage(a, text)) {
            const canned = trivial_reply.pickResponse(@intCast(now));
            connector.sendMessage(a, msg.chat_id, canned, msg.message_id);
            return false;
        }
        // The bot's free-form LLM Q&A is owner-only by default (toggle via
        // WARDEN_LLM_OWNER_ONLY).
        const is_privileged = is_owner or is_bot_admin;
        if (dyn.owner_only and !is_privileged) return false;
        const replied_to = if (msg.reply_to_is_me) msg.reply_to_text else null;
        const resolved = resolveQuestion(connector, a, io, config, pool, tool_ctx, msg, text);
        // Per-chat /persona override, falling back to the global default —
        // see `store/chat_settings.zig`'s `getSystemPromptOverride`.
        const system_prompt = chat_settings.getSystemPromptOverride(pool, a, chat_id) orelse config.system_prompt;
        // Per-chat /thinking override, falling back to the dynamic_config- or-env
        // global default — see `store/chat_settings.zig`'s `getShowThinkingOverride`.
        const show_thinking = chat_settings.getShowThinkingOverride(pool, chat_id) orelse dyn.show_thinking;
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
        replyWithAnswer(connector, a, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, system_prompt, io, now, retention_messages, max_message_len, msg.chat_id, msg.message_id, asker, resolved.text, replied_to, resolved.placeholder_id, dyn.streaming, show_thinking, dyn.vision_enabled, dyn.documents_enabled, dyn.length_limits, dyn.history_messages, dyn.max_retries, in_flight);
    }
    return false;
}

/// Strips a Telegram-style `@botusername` qualifier off the leading
/// `/command` token, so `/ping` and `/ping@warden_bot` dispatch identically.
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

    const out2 = normalizeCommandMention(a, "/kick@warden_bot 123 add", "warden_bot").?;
    defer a.free(out2);
    try std.testing.expectEqualStrings("/kick 123 add", out2);
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

/// True for the protected one-shot `/convert <format>` caption path (a non-
/// empty argument after "/convert ").
fn isOneShotConvertCaption(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "/convert ")) return false;
    return std.mem.trim(u8, text["/convert ".len..], " ").len > 0;
}

/// A non-command message deserves a reply when it's a DM, mentions the bot,
/// replies to one of the bot's messages.
fn isAddressedToBot(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) bool {
    if (!msg.is_group) return true;
    if (msg.mentions_me or msg.reply_to_is_me) return true;

    const magic = chat_settings.getMagicWord(pool, a, chat_id) orelse return false;
    return containsWordIgnoreCase(text, magic);
}

const magic_word_key = "magic_word";
/// Generous enough for "San Francisco, California, United States" while still
/// bounding what gets sent to the geocoder.
const max_location_len = 100;

/// `/location` (view) / `/location <place>` (set) / `/location off` (clear).
fn handleLocationCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/location".len..], " ");

    if (arg.len == 0) {
        const reply_text = if (chat_settings.getDefaultLocation(pool, a, chat_id)) |loc|
            std.fmt.allocPrint(a, "Default location: {s} — used for weather in briefings. Change it with /location <place>, clear it with /location off.", .{loc}) catch return
        else
            "No default location set — briefings won't include weather. Set one with /location <place>, e.g. /location Berlin.";
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change the default location.");
        return;
    }

    if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setDefaultLocation(pool, chat_id, null) catch |err| {
            log.err("location: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't clear the location, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Default location cleared — briefings won't include weather.");
        return;
    }

    if (arg.len > max_location_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That location name is too long (max 100 bytes).");
        return;
    }

    chat_settings.setDefaultLocation(pool, chat_id, arg) catch |err| {
        log.err("location: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that location, try again.");
        return;
    };
    const confirm = std.fmt.allocPrint(a, "Default location set to {s} — briefings will include its weather.", .{arg}) catch return;
    connector.sendMessage(a, msg.chat_id, confirm, msg.message_id);
}

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

/// Sets (or clears, or shows) this chat's own system-prompt override for the
/// LLM Q&A path.
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

    // Viewing (above) stays available even when disabled.
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

const max_welcome_len = 1000;

/// `/welcome <text>` / `/welcome off`.
fn handleWelcomeCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/welcome".len..], " ");

    if (arg.len == 0) {
        const reply_text = if (chat_settings.getWelcomeMessage(pool, a, chat_id)) |welcome|
            std.fmt.allocPrint(a, "This chat's welcome message:\n{s}\n\nChange it with /welcome <text> ({{name}} is replaced with the new member's name), turn it off with /welcome off.", .{welcome}) catch return
        else
            "No welcome message set. Set one with /welcome <text> -- {name} is replaced with the new member's name.";
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    // Viewing (above) stays available even when disabled -- same policy
    // `/persona`'s own gate uses. Only the set/clear path below is gated.
    if (!feature_flags.isEnabled(pool, "welcome_messages")) return;

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change this chat's welcome message.");
        return;
    }

    if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setWelcomeMessage(pool, chat_id, null) catch |err| {
            log.err("welcome: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Welcome message turned off.");
        return;
    }

    if (arg.len > max_welcome_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That welcome message is too long (max 1000 bytes).");
        return;
    }

    chat_settings.setWelcomeMessage(pool, chat_id, arg) catch |err| {
        log.err("welcome: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    reply(connector, a, msg.chat_id, msg.message_id, "Welcome message set for this chat.");
}

/// Sends this chat's configured welcome message (if any) once per newly-
/// joined member in `msg.joined_users`.
fn sendWelcomeMessages(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message) void {
    if (msg.joined_users.len == 0) return;
    if (!feature_flags.isEnabled(pool, "welcome_messages")) return;
    const template = chat_settings.getWelcomeMessage(pool, a, chat_id) orelse return;

    for (msg.joined_users) |member| {
        const text = std.mem.replaceOwned(u8, a, template, "{name}", member.display_name) catch continue;
        connector.sendMessage(a, msg.chat_id, text, null);
    }
}

test "sendWelcomeMessages substitutes {name} per joined member, no-ops without a configured template or with no joiners" {
    const test_support = @import("store/test_support.zig");
    var db = try test_support.openTestDb(std.testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(std.testing.allocator, std.testing.io, &db);
    defer pool.deinitTestWrap();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    const RecordingState = struct { sent: std.ArrayList([]const u8) = .empty };
    var state = RecordingState{};
    const vt = struct {
        const vtable: iface.Connector.VTable = .{
            .platform = platformFn,
            .poll = pollFn,
            .sendMessage = sendMessageFn,
        };
        fn platformFn(ptr: *anyopaque) iface.Platform {
            _ = ptr;
            return .telegram;
        }
        fn pollFn(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]iface.Message {
            _ = ptr;
            _ = alloc;
            return &.{};
        }
        fn sendMessageFn(ptr: *anyopaque, alloc: std.mem.Allocator, cid: []const u8, text: []const u8, reply_to: ?[]const u8) void {
            _ = cid;
            _ = reply_to;
            const s: *RecordingState = @ptrCast(@alignCast(ptr));
            s.sent.append(alloc, text) catch {};
        }
    };
    const connector: iface.Connector = .{ .ptr = &state, .vtable = &vt.vtable };

    const alice: Identity = .{ .platform = .telegram, .native_id = "10", .display_name = "Alice", .first_seen = 1000, .last_seen = 1000 };
    const bob: Identity = .{ .platform = .telegram, .native_id = "11", .display_name = "Bob", .first_seen = 1000, .last_seen = 1000 };
    const join_msg = iface.Message{ .chat_id = "1", .user_id = "0", .joined_users = &.{ alice, bob } };

    // No template configured yet -- no-op.
    sendWelcomeMessages(connector, a, &pool, chat_id, join_msg);
    try std.testing.expectEqual(@as(usize, 0), state.sent.items.len);

    try chat_settings.setWelcomeMessage(&pool, chat_id, "Welcome, {name}!");
    sendWelcomeMessages(connector, a, &pool, chat_id, join_msg);
    try std.testing.expectEqual(@as(usize, 2), state.sent.items.len);
    try std.testing.expectEqualStrings("Welcome, Alice!", state.sent.items[0]);
    try std.testing.expectEqualStrings("Welcome, Bob!", state.sent.items[1]);

    // No joiners on this message -- no-op even with a template configured.
    const no_join_msg = iface.Message{ .chat_id = "1", .user_id = "0" };
    sendWelcomeMessages(connector, a, &pool, chat_id, no_join_msg);
    try std.testing.expectEqual(@as(usize, 2), state.sent.items.len);
}

// --------------------------------------------------------------------- Phase
// 17: finance trackers -- expenses, budgets, subscriptions.

const default_currency = "USD";

/// Parses a plain decimal amount ("12", "12.5", "12.50") into integer cents
/// -- real money.
fn parseAmountCents(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const whole_str = if (dot) |d| s[0..d] else s;
    const frac_str = if (dot) |d| s[d + 1 ..] else "";
    if (dot != null and (frac_str.len == 0 or frac_str.len > 2)) return null;
    if (whole_str.len == 0) return null;

    const whole = std.fmt.parseInt(i64, whole_str, 10) catch return null;
    var frac: i64 = 0;
    if (frac_str.len == 1) {
        frac = (std.fmt.parseInt(i64, frac_str, 10) catch return null) * 10;
    } else if (frac_str.len == 2) {
        frac = std.fmt.parseInt(i64, frac_str, 10) catch return null;
    }
    // Checked, not `whole * 100 + frac`.
    const cents = std.math.add(i64, std.math.mul(i64, whole, 100) catch return null, frac) catch return null;
    if (cents <= 0 or cents > tool_registry.max_expense_cents) return null;
    return cents;
}

test "parseAmountCents handles whole numbers, one and two decimal digits, and rejects garbage" {
    try std.testing.expectEqual(@as(?i64, 1200), parseAmountCents("12"));
    try std.testing.expectEqual(@as(?i64, 1250), parseAmountCents("12.50"));
    try std.testing.expectEqual(@as(?i64, 1250), parseAmountCents("12.5"));
    try std.testing.expectEqual(@as(?i64, 5), parseAmountCents("0.05"));
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents(""));
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents("0"));
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents("-5"));
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents("12.500"));
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents(".50"));
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents("abc"));
    // AUDIT-2026-09-03 TEXT-1: `whole * 100 + frac` unchecked made this an
    // abort, reachable by any allowed user.
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents("9223372036854775807"));
    try std.testing.expectEqual(@as(?i64, null), parseAmountCents("92233720368547758.07"));
}

/// "1250 USD" -> "12.50 USD" -- always shows the ISO currency code rather
/// than guessing a symbol.
fn formatMoney(a: std.mem.Allocator, cents: i64, currency: []const u8) ![]const u8 {
    const frac: u8 = @intCast(@mod(cents, 100));
    return std.fmt.allocPrint(a, "{d}.{d:0>2} {s}", .{ @divTrunc(cents, 100), frac, currency });
}

test "formatMoney pads single-digit cents and always includes the currency code" {
    const a = std.testing.allocator;
    const x = try formatMoney(a, 1250, "USD");
    defer a.free(x);
    try std.testing.expectEqualStrings("12.50 USD", x);

    const y = try formatMoney(a, 5, "USD");
    defer a.free(y);
    try std.testing.expectEqualStrings("0.05 USD", y);
}

/// Parses a subscription's recurrence shorthand -- "30d", "1w", "1mo", "1y"
/// -- into a plain day count.
fn parseIntervalDays(s: []const u8) ?i64 {
    const suffixes = [_]struct { suffix: []const u8, days: i64 }{
        .{ .suffix = "mo", .days = 30 },
        .{ .suffix = "d", .days = 1 },
        .{ .suffix = "w", .days = 7 },
        .{ .suffix = "y", .days = 365 },
    };
    for (suffixes) |s_unit| {
        if (std.mem.endsWith(u8, s, s_unit.suffix)) {
            const num_str = s[0 .. s.len - s_unit.suffix.len];
            const n = std.fmt.parseInt(i64, num_str, 10) catch continue;
            if (n <= 0) return null;
            return n * s_unit.days;
        }
    }
    return null;
}

test "parseIntervalDays handles d/w/mo/y suffixes and rejects unknown units or non-positive counts" {
    try std.testing.expectEqual(@as(?i64, 1), parseIntervalDays("1d"));
    try std.testing.expectEqual(@as(?i64, 14), parseIntervalDays("2w"));
    try std.testing.expectEqual(@as(?i64, 30), parseIntervalDays("1mo"));
    try std.testing.expectEqual(@as(?i64, 730), parseIntervalDays("2y"));
    try std.testing.expectEqual(@as(?i64, null), parseIntervalDays("1x"));
    try std.testing.expectEqual(@as(?i64, null), parseIntervalDays("0d"));
    try std.testing.expectEqual(@as(?i64, null), parseIntervalDays("-1d"));
}

/// Unix timestamp for the first moment of the current UTC calendar month
/// containing `now`.
fn startOfMonthUnix(now: i64) i64 {
    const c = civil_time.localFromUnix(now, 0);
    return civil_time.unixFromLocal(.{ .year = c.year, .month = c.month, .day = 1 }, 0);
}

test "startOfMonthUnix returns midnight UTC on the 1st of the month containing now" {
    // 2026-08-03 00:46:00 UTC (this session's own timestamp, arbitrary).
    const now = civil_time.unixFromLocal(.{ .year = 2026, .month = 8, .day = 3, .hour = 0, .minute = 46 }, 0);
    const start = startOfMonthUnix(now);
    const c = civil_time.localFromUnix(start, 0);
    try std.testing.expectEqual(@as(i32, 2026), c.year);
    try std.testing.expectEqual(@as(u8, 8), c.month);
    try std.testing.expectEqual(@as(u8, 1), c.day);
    try std.testing.expectEqual(@as(u8, 0), c.hour);
}

/// Generic "creator or the bot owner" authorization for any chat-shared, per-
/// record feature (expenses, subscriptions, aliases, templates).
fn isRecordOwnerOrCreator(config: *const config_mod.Config, connector: iface.Connector, msg: iface.Message, identity_id: i64, record_identity_id: i64) bool {
    return record_identity_id == identity_id or auth.isOwner(config, connector.platform(), msg.user_id);
}

/// Per-chat expense tracker.
fn handleExpenseCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /expense add <amount> <category> [description], /expense list [category], /expense summary [all], or /expense delete <id>";
    const arg = std.mem.trim(u8, text["/expense".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        const category = std.mem.trim(u8, it.rest(), " ");
        const listed = expenses.listForChat(pool, a, chat_id, if (category.len > 0) category else null, null, 20) catch |err| {
            log.err("expense: list failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't load expenses, try again.");
            return;
        };
        connector.sendMessage(a, msg.chat_id, formatExpenseList(a, listed), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "summary")) {
        const scope = std.mem.trim(u8, it.rest(), " ");
        const since_ts: ?i64 = if (std.mem.eql(u8, scope, "all")) null else startOfMonthUnix(now);
        connector.sendMessage(a, msg.chat_id, formatExpenseSummary(a, pool, chat_id, since_ts), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "delete")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /expense delete <id> (see /expense list for ids).");
            return;
        };
        const expense = (expenses.get(pool, a, id) catch |err| {
            log.err("expense: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that up, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No expense with that id.");
            return;
        };
        if (expense.chat_id != chat_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "No expense with that id.");
            return;
        }
        if (!isRecordOwnerOrCreator(config, connector, msg, identity_id, expense.identity_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever logged that expense (or the owner) can delete it.");
            return;
        }
        expenses.delete(pool, id) catch |err| {
            log.err("expense: delete failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't delete that, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Expense deleted.");
        return;
    }

    if (!std.mem.eql(u8, sub, "add")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const amount_str = it.next() orelse {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    };
    const cents = parseAmountCents(amount_str) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "That doesn't look like a valid amount -- try e.g. 12.50.");
        return;
    };
    const category = it.next() orelse {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    };
    const description_raw = std.mem.trim(u8, it.rest(), " ");
    const description: ?[]const u8 = if (description_raw.len > 0) description_raw else null;

    const id = expenses.create(pool, chat_id, identity_id, cents, default_currency, category, description, now) catch |err| {
        log.err("expense: failed to create for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that, try again.");
        return;
    };
    const money = formatMoney(a, cents, default_currency) catch return;
    const confirmation = std.fmt.allocPrint(a, "Expense #{d} logged: {s} ({s}).", .{ id, money, category }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn formatExpenseList(a: std.mem.Allocator, listed: []const expenses.Expense) []const u8 {
    if (listed.len == 0) return "No expenses logged yet. Add one with /expense add <amount> <category> [description].";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Recent expenses:\n", .{}) catch return "";
    for (listed) |e| {
        const money = formatMoney(a, e.amount_cents, e.currency) catch continue;
        if (e.description) |d| {
            w.print("  #{d} {s} ({s}) -- {s}\n", .{ e.id, money, e.category, d }) catch return "";
        } else {
            w.print("  #{d} {s} ({s})\n", .{ e.id, money, e.category }) catch return "";
        }
    }
    return buf.writer.buffered();
}

/// Per-category breakdown + grand total since `since_ts` (null = all time).
fn formatExpenseSummary(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, since_ts: ?i64) []const u8 {
    const totals = expenses.totalsByCategory(pool, a, chat_id, since_ts) catch |err| {
        log.err("expense: summary failed for chat {d}: {t}", .{ chat_id, err });
        return "Couldn't load the expense summary, try again.";
    };
    if (totals.len == 0) return "No expenses in that window.";

    const budget_list = budgets.listForChat(pool, a, chat_id) catch &.{};

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Expense summary:\n", .{}) catch return "";
    var grand_total: i64 = 0;
    for (totals) |t| {
        grand_total += t.total_cents;
        const money = formatMoney(a, t.total_cents, default_currency) catch continue;
        var budget_note: []const u8 = "";
        for (budget_list) |b| {
            if (!std.mem.eql(u8, b.category, t.category)) continue;
            const budget_money = formatMoney(a, b.amount_cents, b.currency) catch break;
            budget_note = if (t.total_cents > b.amount_cents)
                std.fmt.allocPrint(a, " -- OVER budget of {s}", .{budget_money}) catch ""
            else
                std.fmt.allocPrint(a, " (budget {s})", .{budget_money}) catch "";
            break;
        }
        w.print("  {s}: {s}{s}\n", .{ t.category, money, budget_note }) catch return "";
    }
    const grand_money = formatMoney(a, grand_total, default_currency) catch return buf.writer.buffered();
    w.print("Total: {s}\n", .{grand_money}) catch return "";
    return buf.writer.buffered();
}

/// Per-chat monthly budgets -- `/budget set
/// <category> <amount>`, `/budget list`, `/budget remove <category>`.
fn handleBudgetCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /budget set <category> <amount>, /budget list, or /budget remove <category>";
    const arg = std.mem.trim(u8, text["/budget".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        connector.sendMessage(a, msg.chat_id, formatBudgetList(a, pool, chat_id, now), msg.message_id);
        return;
    }

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change this chat's budgets.");
        return;
    }

    if (std.mem.eql(u8, sub, "remove")) {
        const category = std.mem.trim(u8, it.rest(), " ");
        if (category.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /budget remove <category>");
            return;
        }
        budgets.remove(pool, chat_id, category) catch |err| {
            log.err("budget: remove failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't remove that, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Budget removed.");
        return;
    }

    if (!std.mem.eql(u8, sub, "set")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const category = it.next() orelse {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    };
    const amount_str = std.mem.trim(u8, it.rest(), " ");
    const cents = parseAmountCents(amount_str) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "That doesn't look like a valid amount -- try e.g. 300.");
        return;
    };

    _ = budgets.set(pool, chat_id, category, cents, default_currency) catch |err| {
        log.err("budget: set failed for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that, try again.");
        return;
    };
    const money = formatMoney(a, cents, default_currency) catch return;
    const confirmation = std.fmt.allocPrint(a, "Budget for {s} set to {s}/month.", .{ category, money }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn formatBudgetList(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, now: i64) []const u8 {
    const listed = budgets.listForChat(pool, a, chat_id) catch |err| {
        log.err("budget: list failed for chat {d}: {t}", .{ chat_id, err });
        return "Couldn't load budgets, try again.";
    };
    if (listed.len == 0) return "No budgets set yet. Set one with /budget set <category> <amount>.";

    const spent = expenses.totalsByCategory(pool, a, chat_id, startOfMonthUnix(now)) catch &.{};

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Budgets (this month):\n", .{}) catch return "";
    for (listed) |b| {
        var spent_cents: i64 = 0;
        for (spent) |s| {
            if (std.mem.eql(u8, s.category, b.category)) {
                spent_cents = s.total_cents;
                break;
            }
        }
        const spent_money = formatMoney(a, spent_cents, b.currency) catch continue;
        const budget_money = formatMoney(a, b.amount_cents, b.currency) catch continue;
        const flag = if (spent_cents > b.amount_cents) " OVER" else "";
        w.print("  {s}: {s} / {s}{s}\n", .{ b.category, spent_money, budget_money, flag }) catch return "";
    }
    return buf.writer.buffered();
}

/// Per-chat subscription/recurring-cost ledger.
fn handleSubscriptionCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /subscription add <name> <amount> every <interval e.g. 1mo>, /subscription list, or /subscription remove <id>";
    const arg = std.mem.trim(u8, text["/subscription".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        connector.sendMessage(a, msg.chat_id, formatSubscriptionList(a, pool, chat_id), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "remove")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /subscription remove <id> (see /subscription list for ids).");
            return;
        };
        const s = (subscriptions.get(pool, a, id) catch |err| {
            log.err("subscription: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that up, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No subscription with that id.");
            return;
        };
        if (s.chat_id != chat_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "No subscription with that id.");
            return;
        }
        if (!isRecordOwnerOrCreator(config, connector, msg, identity_id, s.identity_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever added that subscription (or the owner) can remove it.");
            return;
        }
        subscriptions.remove(pool, id) catch |err| {
            log.err("subscription: remove failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't remove that, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Subscription removed.");
        return;
    }

    if (!std.mem.eql(u8, sub, "add")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    // "<name...> <amount> every <interval>" -- name may be multiple words (e.g.
    // "Amazon Prime"), so this parses from the *end*.
    const rest = std.mem.trim(u8, it.rest(), " ");
    const every_idx = std.mem.lastIndexOf(u8, rest, " every ") orelse {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    };
    const before_every = std.mem.trim(u8, rest[0..every_idx], " ");
    const interval_str = std.mem.trim(u8, rest[every_idx + " every ".len ..], " ");
    const interval_days = parseIntervalDays(interval_str) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Bad interval -- try e.g. 30d, 1w, 1mo, or 1y.");
        return;
    };
    const amount_idx = std.mem.lastIndexOfScalar(u8, before_every, ' ') orelse {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    };
    const name = std.mem.trim(u8, before_every[0..amount_idx], " ");
    const amount_str = before_every[amount_idx + 1 ..];
    if (name.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const cents = parseAmountCents(amount_str) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "That doesn't look like a valid amount -- try e.g. 15.99.");
        return;
    };

    const id = subscriptions.create(pool, chat_id, identity_id, name, cents, default_currency, interval_days, now) catch |err| {
        log.err("subscription: failed to create for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that, try again.");
        return;
    };
    const money = formatMoney(a, cents, default_currency) catch return;
    const confirmation = std.fmt.allocPrint(a, "Subscription #{d} added: {s}, {s} every {s}.", .{ id, name, money, interval_str }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn formatSubscriptionList(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64) []const u8 {
    const listed = subscriptions.listForChat(pool, a, chat_id) catch |err| {
        log.err("subscription: list failed for chat {d}: {t}", .{ chat_id, err });
        return "Couldn't load subscriptions, try again.";
    };
    if (listed.len == 0) return "No subscriptions tracked yet. Add one with /subscription add <name> <amount> every <interval>.";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Subscriptions:\n", .{}) catch return "";
    var monthly_total: i64 = 0;
    for (listed) |s| {
        const money = formatMoney(a, s.amount_cents, s.currency) catch continue;
        const monthly_eq = subscriptions.monthlyEquivalentCents(s.amount_cents, s.interval_days);
        monthly_total += monthly_eq;
        const monthly_money = formatMoney(a, monthly_eq, s.currency) catch continue;
        w.print("  #{d} {s}: {s} every {d}d (~{s}/mo)\n", .{ s.id, s.name, money, s.interval_days, monthly_money }) catch return "";
    }
    const total_money = formatMoney(a, monthly_total, default_currency) catch return buf.writer.buffered();
    w.print("Total: ~{s}/mo\n", .{total_money}) catch return "";
    return buf.writer.buffered();
}

// --------------------------------------------------------------------- Phase
// 19: power-user tools.

/// `/alias add <name> <command/text>` / `/alias list` / `/alias remove
/// <name>`.
fn handleAliasCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /alias add <name> <command or text>, /alias list, or /alias remove <name>";
    const arg = std.mem.trim(u8, text["/alias".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        connector.sendMessage(a, msg.chat_id, formatAliasList(a, pool, chat_id), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "remove")) {
        const name = std.mem.trim(u8, it.rest(), " ");
        if (name.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /alias remove <name>");
            return;
        }
        const existing = (command_aliases.get(pool, a, chat_id, name) catch |err| {
            log.err("alias: lookup failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that up, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No alias with that name.");
            return;
        };
        if (!isRecordOwnerOrCreator(config, connector, msg, identity_id, existing.identity_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever added that alias (or the owner) can remove it.");
            return;
        }
        command_aliases.remove(pool, chat_id, name) catch |err| {
            log.err("alias: remove failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't remove that, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Alias removed.");
        return;
    }

    if (!std.mem.eql(u8, sub, "add")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const name = it.next() orelse {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    };
    const expansion = std.mem.trim(u8, it.rest(), " ");
    if (expansion.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    if (isReservedCommandName(name)) {
        reply(connector, a, msg.chat_id, msg.message_id, "That name is already a built-in command -- pick a different alias name.");
        return;
    }

    const lower_name = std.ascii.allocLowerString(a, name) catch return;
    _ = command_aliases.set(pool, chat_id, identity_id, lower_name, expansion, now) catch |err| {
        log.err("alias: failed to save for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that, try again.");
        return;
    };
    const confirmation = std.fmt.allocPrint(a, "Alias /{s} saved.", .{lower_name}) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn formatAliasList(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64) []const u8 {
    const listed = command_aliases.listForChat(pool, a, chat_id) catch |err| {
        log.err("alias: list failed for chat {d}: {t}", .{ chat_id, err });
        return "Couldn't load aliases, try again.";
    };
    if (listed.len == 0) return "No aliases yet. Add one with /alias add <name> <command or text>.";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Aliases:\n", .{}) catch return "";
    for (listed) |al| w.print("  /{s} -> {s}\n", .{ al.name, al.expansion }) catch return "";
    return buf.writer.buffered();
}

/// `/template save <name> <text>` / `/template list` / `/template use <name>
/// [extra text]` / `/template delete <name>`.
fn handleTemplateCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    io: Io,
    now: i64,
    max_message_len: usize,
    is_owner: bool,
    is_bot_admin: bool,
    msg: iface.Message,
    text: []const u8,
    in_flight: *cancel_request.InFlightRequests,
) void {
    const usage = "Usage: /template save <name> <text>, /template list, /template use <name> [extra text], or /template delete <name>";
    const arg = std.mem.trim(u8, text["/template".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        connector.sendMessage(a, msg.chat_id, formatTemplateList(a, pool, chat_id), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "delete")) {
        const name = std.mem.trim(u8, it.rest(), " ");
        if (name.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /template delete <name>");
            return;
        }
        const existing = (prompt_templates.get(pool, a, chat_id, name) catch |err| {
            log.err("template: lookup failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that up, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No template with that name.");
            return;
        };
        if (!isRecordOwnerOrCreator(config, connector, msg, identity_id, existing.identity_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever saved that template (or the owner) can delete it.");
            return;
        }
        prompt_templates.remove(pool, chat_id, name) catch |err| {
            log.err("template: delete failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't delete that, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Template deleted.");
        return;
    }

    if (std.mem.eql(u8, sub, "use")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const space = std.mem.indexOfScalar(u8, rest, ' ');
        const name = if (space) |sp| rest[0..sp] else rest;
        const extra = if (space) |sp| std.mem.trim(u8, rest[sp..], " ") else "";
        if (name.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /template use <name> [extra text]");
            return;
        }
        const template = (prompt_templates.get(pool, a, chat_id, name) catch |err| {
            log.err("template: lookup failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that up, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No template with that name.");
            return;
        };
        const question = if (extra.len > 0)
            std.fmt.allocPrint(a, "{s}\n\n{s}", .{ template.text, extra }) catch return
        else
            template.text;
        handleModeCommand(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, io, now, max_message_len, is_owner, is_bot_admin, msg, question, in_flight);
        return;
    }

    if (!std.mem.eql(u8, sub, "save")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const name = it.next() orelse {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    };
    const template_text = std.mem.trim(u8, it.rest(), " ");
    if (template_text.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    const lower_name = std.ascii.allocLowerString(a, name) catch return;
    _ = prompt_templates.set(pool, chat_id, identity_id, lower_name, template_text, now) catch |err| {
        log.err("template: failed to save for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that, try again.");
        return;
    };
    const confirmation = std.fmt.allocPrint(a, "Template \"{s}\" saved. Use it with /template use {s}.", .{ lower_name, lower_name }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn formatTemplateList(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64) []const u8 {
    const listed = prompt_templates.listForChat(pool, a, chat_id) catch |err| {
        log.err("template: list failed for chat {d}: {t}", .{ chat_id, err });
        return "Couldn't load templates, try again.";
    };
    if (listed.len == 0) return "No templates saved yet. Save one with /template save <name> <text>.";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Templates:\n", .{}) catch return "";
    for (listed) |t| w.print("  {s}\n", .{t.name}) catch return "";
    return buf.writer.buffered();
}

/// Per-chat override for whether a reasoning model's chain-of-thought is
/// shown.
fn handleTdloginCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    io: Io,
    msg: iface.Message,
    text: []const u8,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can drive the personal-account login.");
        return;
    }
    const conn = telegram_user orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment (WARDEN_TELEGRAM_USER_API_ID/_API_HASH/_SESSION_DIR/_OWNER_ID).");
        return;
    };

    const rest = std.mem.trim(u8, text["/tdlogin".len..], " ");
    const space = std.mem.indexOfScalar(u8, rest, ' ');
    const sub = if (space) |i| rest[0..i] else rest;
    const arg = if (space) |i| std.mem.trim(u8, rest[i + 1 ..], " ") else "";

    if (sub.len == 0 or std.mem.eql(u8, sub, "status")) {
        const state_text = switch (conn.authState()) {
            .none => "not started yet (will begin automatically once the connector's first poll runs)",
            .wait_tdlib_parameters => "starting up",
            .wait_phone_number => "waiting for /tdlogin phone <number>",
            .wait_code => "waiting for /tdlogin code <the digits Telegram sent, separated e.g. \"1 2 3 4 5\">",
            .wait_password => "waiting for /tdlogin password <your 2FA password>",
            .ready => "connected and ready",
            .logging_out => "logging out",
            .closed => "closed",
            .unsupported => "stuck on a login state this bot doesn't support (QR/other-device login) — check the logs",
        };
        const out = std.fmt.allocPrint(a, "Personal-account login: {s}", .{state_text}) catch return;
        connector.sendMessage(a, msg.chat_id, out, msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "phone")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /tdlogin phone +15551234567");
            return;
        }
        if (conn.authState() != .wait_phone_number) {
            reply(connector, a, msg.chat_id, msg.message_id, "Not currently waiting for a phone number — check /tdlogin status.");
            return;
        }
        const outcome = conn.submitPhoneNumber(a, io, arg) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't submit the phone number — try again.");
            return;
        };
        switch (outcome) {
            .ok => reply(connector, a, msg.chat_id, msg.message_id, "Phone number submitted. Watch this chat (or your other Telegram sessions) for the login code, then send it back with /tdlogin code — with the digits separated, e.g. \"1 2 3 4 5\", not the bare code."),
            .rejected => |why| {
                const out = std.fmt.allocPrint(a, "Telegram rejected that phone number: {s} — try /tdlogin phone again.", .{why}) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
            .timed_out => reply(connector, a, msg.chat_id, msg.message_id, "Couldn't confirm that reached Telegram in time — check /tdlogin status before retrying."),
        }
        return;
    }

    if (std.mem.eql(u8, sub, "code")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /tdlogin code 1 2 3 4 5 (digits separated — see /tdlogin status)");
            return;
        }
        if (conn.authState() != .wait_code) {
            reply(connector, a, msg.chat_id, msg.message_id, "Not currently waiting for a login code — check /tdlogin status.");
            return;
        }
        var digits_buf: [64]u8 = undefined;
        var n: usize = 0;
        for (arg) |c| {
            if (std.ascii.isDigit(c) and n < digits_buf.len) {
                digits_buf[n] = c;
                n += 1;
            }
        }
        if (n == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "That didn't contain any digits.");
            return;
        }
        const outcome = conn.submitAuthCode(a, io, digits_buf[0..n]) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't submit the code — try again.");
            return;
        };
        switch (outcome) {
            .ok => reply(connector, a, msg.chat_id, msg.message_id, "Code submitted."),
            .rejected => |why| {
                const out = std.fmt.allocPrint(a, "Telegram rejected that code: {s} — check /tdlogin status, then send /tdlogin code again.", .{why}) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
            .timed_out => reply(connector, a, msg.chat_id, msg.message_id, "Couldn't confirm that reached Telegram in time — check /tdlogin status before retrying."),
        }
        return;
    }

    if (std.mem.eql(u8, sub, "password")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /tdlogin password <your 2FA password>");
            return;
        }
        if (conn.authState() != .wait_password) {
            reply(connector, a, msg.chat_id, msg.message_id, "Not currently waiting for a 2FA password — check /tdlogin status.");
            return;
        }
        const outcome = conn.submitPassword(a, io, arg) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't submit the password — try again.");
            return;
        };
        switch (outcome) {
            .ok => reply(connector, a, msg.chat_id, msg.message_id, "Password submitted."),
            .rejected => |why| {
                const out = std.fmt.allocPrint(a, "Telegram rejected that password: {s} — send /tdlogin password again with the correct one.", .{why}) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
            .timed_out => reply(connector, a, msg.chat_id, msg.message_id, "Couldn't confirm that reached Telegram in time — check /tdlogin status before retrying."),
        }
        return;
    }

    if (std.mem.eql(u8, sub, "logout")) {
        performTdLogout(connector, a, conn, msg);
        return;
    }

    reply(connector, a, msg.chat_id, msg.message_id, "Unknown /tdlogin subcommand — use status, phone, code, password, or logout.");
}

/// `/iglogin status|start <username> <password>|challenge <digits>|code
/// <digits>|2fa <digits>|logout`.
fn handleIgloginCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    instagram: ?*instagram_platform.InstagramConnector,
    msg: iface.Message,
    text: []const u8,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can drive the Instagram connector's login.");
        return;
    }
    const conn = instagram orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The Instagram connector isn't configured on this deployment (WARDEN_INSTAGRAM_ENABLED/_OWNER_ID).");
        return;
    };

    const rest = std.mem.trim(u8, text["/iglogin".len..], " ");
    const space = std.mem.indexOfScalar(u8, rest, ' ');
    const sub = if (space) |i| rest[0..i] else rest;
    const arg = if (space) |i| std.mem.trim(u8, rest[i + 1 ..], " ") else "";

    if (sub.len == 0 or std.mem.eql(u8, sub, "status")) {
        const state_text = switch (conn.authState()) {
            .logged_out => "not logged in — start with /iglogin start <username> <password>",
            .wait_challenge_choice, .wait_challenge_code => "waiting for the challenge code Instagram sent — reply with /iglogin challenge <digits>",
            .wait_2fa_code => "waiting for a 2FA code — reply with /iglogin 2fa <digits>",
            .ready => "connected and ready",
        };
        const paused_note: []const u8 = if (conn.isPaused())
            " (polling is PAUSED — Instagram returned a challenge/checkpoint response; resolve it in the app, then /iglogin resume)"
        else
            "";
        const out = std.fmt.allocPrint(a, "Instagram login: {s}{s}", .{ state_text, paused_note }) catch return;
        connector.sendMessage(a, msg.chat_id, out, msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "start")) {
        const inner_space = std.mem.indexOfScalar(u8, arg, ' ');
        const username = if (inner_space) |i| arg[0..i] else "";
        const password = if (inner_space) |i| std.mem.trim(u8, arg[i + 1 ..], " ") else "";
        if (username.len == 0 or password.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /iglogin start <username> <password>");
            return;
        }
        const outcome = conn.login(username, password) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't reach Instagram to log in — try again.");
            return;
        };
        switch (outcome) {
            .ok => {
                const state_text: []const u8 = switch (conn.authState()) {
                    .ready => "Logged in and ready.",
                    .wait_challenge_code, .wait_challenge_choice => "Instagram wants a challenge code (check email/SMS), then reply with /iglogin challenge <digits>.",
                    .wait_2fa_code => "Instagram wants a 2FA code, then reply with /iglogin 2fa <digits>.",
                    .logged_out => "Unexpected state after login — check /iglogin status.",
                };
                connector.sendMessage(a, msg.chat_id, state_text, msg.message_id);
            },
            .rejected => |why| {
                const out = std.fmt.allocPrint(a, "Instagram rejected that login: {s}", .{why}) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
            .timed_out => reply(connector, a, msg.chat_id, msg.message_id, "Couldn't confirm that reached Instagram in time — check /iglogin status before retrying."),
        }
        return;
    }

    if (std.mem.eql(u8, sub, "challenge")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /iglogin challenge <digits>");
            return;
        }
        const outcome = conn.submitChallengeCode(arg) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't submit the challenge code — try again.");
            return;
        };
        switch (outcome) {
            .ok => {
                const state_text: []const u8 = if (conn.authState() == .ready) "Challenge passed — logged in." else "Challenge code submitted.";
                connector.sendMessage(a, msg.chat_id, state_text, msg.message_id);
            },
            .rejected => |why| {
                const out = std.fmt.allocPrint(a, "Instagram rejected that challenge code: {s}", .{why}) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
            .timed_out => reply(connector, a, msg.chat_id, msg.message_id, "Couldn't confirm that reached Instagram in time — check /iglogin status before retrying."),
        }
        return;
    }

    if (std.mem.eql(u8, sub, "2fa")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /iglogin 2fa <digits>");
            return;
        }
        const outcome = conn.submit2faCode(arg) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't submit the 2FA code — try again.");
            return;
        };
        switch (outcome) {
            .ok => reply(connector, a, msg.chat_id, msg.message_id, "2FA passed — logged in."),
            .rejected => |why| {
                const out = std.fmt.allocPrint(a, "Instagram rejected that 2FA code: {s}", .{why}) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
            .timed_out => reply(connector, a, msg.chat_id, msg.message_id, "Couldn't confirm that reached Instagram in time — check /iglogin status before retrying."),
        }
        return;
    }

    if (std.mem.eql(u8, sub, "resume")) {
        if (!conn.isPaused()) {
            reply(connector, a, msg.chat_id, msg.message_id, "Polling isn't paused.");
            return;
        }
        conn.resumePolling();
        reply(connector, a, msg.chat_id, msg.message_id, "Resumed polling.");
        return;
    }

    if (std.mem.eql(u8, sub, "logout")) {
        conn.logOut();
        reply(connector, a, msg.chat_id, msg.message_id, "Logged out of the Instagram connector. Log back in any time with /iglogin start <username> <password>.");
        return;
    }

    reply(connector, a, msg.chat_id, msg.message_id, "Unknown /iglogin subcommand — use status, start, challenge, 2fa, resume, or logout.");
}

/// Shared by `/tdlogin logout` and the standalone `/tdlogout` alias.
fn performTdLogout(connector: iface.Connector, a: std.mem.Allocator, conn: *telegram_user_platform.TelegramUserConnector, msg: iface.Message) void {
    if (conn.authState() == .none) {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector hasn't started yet — nothing to log out of.");
        return;
    }
    conn.logOut();
    reply(connector, a, msg.chat_id, msg.message_id, "Logging out of the personal-account session — Telegram will clear it locally and end it server-side, same as removing the device from your active sessions list. Log back in any time with /tdlogin phone <number>.");
}

/// `/sendas <chat_id> <text...>` / `/tdsend <chat_id> <text...>`.
fn handleSendAsCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    msg: iface.Message,
    command_prefix: []const u8,
    text: []const u8,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can send through the personal account.");
        return;
    }
    const conn = telegram_user orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment.");
        return;
    };
    if (conn.authState() != .ready) {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal account isn't logged in yet — see /tdlogin status.");
        return;
    }

    const rest = std.mem.trim(u8, text[command_prefix.len..], " ");
    const space = std.mem.indexOfScalar(u8, rest, ' ');
    const target_chat_id = if (space) |i| rest[0..i] else rest;
    const body = if (space) |i| std.mem.trim(u8, rest[i + 1 ..], " ") else "";
    if (target_chat_id.len == 0 or body.len == 0) {
        const usage = std.fmt.allocPrint(a, "Usage: {s} <chat id> <message>", .{command_prefix}) catch "Usage: <chat id> <message>";
        connector.sendMessage(a, msg.chat_id, usage, msg.message_id);
        return;
    }

    conn.connector().sendMessage(a, target_chat_id, body, null);
    reply(connector, a, msg.chat_id, msg.message_id, "Sent.");
}

/// Chats-per-page for `/tdchats`' pager and its Prev/Next buttons.
const tdchats_per_page = 15;

/// `callback_data` prefix for a `/tdchats` pager button — see
/// `handleTdChatsPagePicked`.
const tdchats_page_prefix = "tdchats_page:";

/// Builds one page's message text + Prev/Next buttons from an already-
/// resolved chat list.
fn renderTdChatsPage(a: std.mem.Allocator, chat_list: []const chat_summary.ChatMatch, page: usize) struct { text: []const u8, choices: []const iface.Choice } {
    const total_pages = if (chat_list.len == 0) 1 else std.math.divCeil(usize, chat_list.len, tdchats_per_page) catch 1;
    const clamped_page = @min(page, total_pages - 1);
    const start = clamped_page * tdchats_per_page;
    const end = @min(start + tdchats_per_page, chat_list.len);

    var out: Io.Writer.Allocating = .init(a);
    out.writer.print("Known chats (id — title) — page {d}/{d}, {d} total:\n", .{ clamped_page + 1, total_pages, chat_list.len }) catch {};
    for (chat_list[start..end]) |c| {
        const title = if (c.title.len > 60) c.title[0..60] else c.title;
        out.writer.print("{s} — {s}\n", .{ c.native_chat_id, title }) catch break;
    }

    var choices: std.ArrayList(iface.Choice) = .empty;
    if (clamped_page > 0) {
        const value = std.fmt.allocPrint(a, "{s}{d}", .{ tdchats_page_prefix, clamped_page - 1 }) catch "";
        choices.append(a, .{ .emoji = "◀️", .label = "Prev", .value = value }) catch {};
    }
    if (end < chat_list.len) {
        const value = std.fmt.allocPrint(a, "{s}{d}", .{ tdchats_page_prefix, clamped_page + 1 }) catch "";
        choices.append(a, .{ .emoji = "▶️", .label = "Next", .value = value }) catch {};
    }

    return .{ .text = out.writer.buffered(), .choices = choices.items };
}

/// A `/tdchats` pager button press.
fn handleTdChatsPagePicked(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    msg: iface.Message,
    picked: iface.ChoicePicked,
) bool {
    if (!std.mem.startsWith(u8, picked.value, tdchats_page_prefix)) return false;
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
    const conn = telegram_user orelse return false;

    const page = std.fmt.parseInt(usize, picked.value[tdchats_page_prefix.len..], 10) catch return false;
    const chats_list = chat_summary.allChatsSortedByTitle(conn, a) catch return false;
    const rendered = renderTdChatsPage(a, chats_list, page);
    connector.editChoicePrompt(a, msg.chat_id, picked.prompt_message_id, rendered.text, rendered.choices) catch |err| {
        log.warn("tdchats pagination: editChoicePrompt failed: {t}", .{err});
    };
    return true;
}

test "renderTdChatsPage: everything fits on one page, no buttons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chats_list = [_]chat_summary.ChatMatch{
        .{ .native_chat_id = "1", .title = "Alice" },
        .{ .native_chat_id = "2", .title = "Bob" },
    };
    const rendered = renderTdChatsPage(a, &chats_list, 0);
    try std.testing.expectEqual(@as(usize, 0), rendered.choices.len);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "page 1/1, 2 total") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "Bob") != null);
}

test "renderTdChatsPage: first/middle/last page show the right Prev/Next buttons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var chats_list: [tdchats_per_page * 2 + 3]chat_summary.ChatMatch = undefined;
    for (&chats_list, 0..) |*c, i| c.* = .{
        .native_chat_id = std.fmt.allocPrint(a, "{d}", .{i}) catch unreachable,
        .title = std.fmt.allocPrint(a, "Chat {d}", .{i}) catch unreachable,
    };

    const first = renderTdChatsPage(a, &chats_list, 0);
    try std.testing.expectEqual(@as(usize, 1), first.choices.len);
    try std.testing.expectEqualStrings("Next", first.choices[0].label);

    const middle = renderTdChatsPage(a, &chats_list, 1);
    try std.testing.expectEqual(@as(usize, 2), middle.choices.len);
    try std.testing.expectEqualStrings("Prev", middle.choices[0].label);
    try std.testing.expectEqualStrings("Next", middle.choices[1].label);

    const last = renderTdChatsPage(a, &chats_list, 2);
    try std.testing.expectEqual(@as(usize, 1), last.choices.len);
    try std.testing.expectEqualStrings("Prev", last.choices[0].label);
    try std.testing.expect(std.mem.indexOf(u8, last.text, "page 3/3") != null);
}

test "renderTdChatsPage: an out-of-range page clamps to the last one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chats_list = [_]chat_summary.ChatMatch{
        .{ .native_chat_id = "1", .title = "Alice" },
    };
    const rendered = renderTdChatsPage(a, &chats_list, 99);
    try std.testing.expect(std.mem.indexOf(u8, rendered.text, "page 1/1") != null);
}

/// `/tdchats` — lists the personal account's known chats (id + title),
/// paginated (see `tdchats_per_page`) with Prev/Next buttons.
fn handleTdchatsCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    msg: iface.Message,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can list the personal account's chats.");
        return;
    }
    const conn = telegram_user orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment.");
        return;
    };
    if (conn.authState() != .ready) {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal account isn't logged in yet — see /tdlogin status.");
        return;
    }

    const chats_list = chat_summary.allChatsSortedByTitle(conn, a) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Failed to list chats.");
        return;
    };
    if (chats_list.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "No chats known yet — TDLib populates this shortly after login; try again in a moment, or send/receive a message on the personal account first.");
        return;
    }

    const rendered = renderTdChatsPage(a, chats_list, 0);
    _ = connector.sendChoicePrompt(a, msg.chat_id, rendered.text, rendered.choices, msg.message_id) catch |err| {
        log.warn("/tdchats: sendChoicePrompt failed, falling back to a plain message: {t}", .{err});
        connector.sendMessage(a, msg.chat_id, rendered.text, msg.message_id);
    };
}

/// `/tdsearch <name>` — direct-user-request companion to `/tdchats`' pager.
fn handleTdSearchCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    msg: iface.Message,
    text: []const u8,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can search the personal account's chats.");
        return;
    }
    const conn = telegram_user orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment.");
        return;
    };
    if (conn.authState() != .ready) {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal account isn't logged in yet — see /tdlogin status.");
        return;
    }

    const query = std.mem.trim(u8, text["/tdsearch".len..], " ");
    if (query.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /tdsearch <name>");
        return;
    }

    const matches = chat_summary.searchChatsByTitle(conn, a, query) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Failed to search chats.");
        return;
    };
    if (matches.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "No chats match that — try /tdchats to browse everything.");
        return;
    }

    const rendered = renderTdChatsPage(a, matches, 0);
    _ = connector.sendChoicePrompt(a, msg.chat_id, rendered.text, rendered.choices, msg.message_id) catch |err| {
        log.warn("/tdsearch: sendChoicePrompt failed, falling back to a plain message: {t}", .{err});
        connector.sendMessage(a, msg.chat_id, rendered.text, msg.message_id);
    };
}

/// `/tdsummary <chat id or name>` — direct-user-request feature: summarize a
/// personal-account chat's unread messages on demand and mark them read.
fn handleTdSummaryCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    llm_provider: llm.Provider,
    io: Io,
    tool_ctx: tool_registry.ToolContext,
    msg: iface.Message,
    text: []const u8,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can summarize the personal account's chats.");
        return;
    }
    const conn = telegram_user orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment.");
        return;
    };
    if (conn.authState() != .ready) {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal account isn't logged in yet — see /tdlogin status.");
        return;
    }

    const flag = stripAllFlag(text["/tdsummary".len..]);
    if (flag.query.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /tdsummary <chat id or name> [--all]");
        return;
    }

    const resolution = chat_summary.resolveChat(conn, a, flag.query) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Failed to look up that chat.");
        return;
    };
    switch (resolution) {
        .none => reply(connector, a, msg.chat_id, msg.message_id, "No known chat matches that — try /tdchats to see what's known."),
        .ambiguous => |matches| {
            var out: Io.Writer.Allocating = .init(a);
            out.writer.writeAll("That matches more than one chat — be more specific:\n") catch {};
            for (matches) |m| out.writer.print("{s} — {s}\n", .{ m.native_chat_id, m.title }) catch break;
            connector.sendMessage(a, msg.chat_id, out.writer.buffered(), msg.message_id);
        },
        .one => |m| {
            const summary = chat_summary.summarizeChat(conn, pool, llm_provider, a, io, tool_ctx, m.native_chat_id, flag.all) catch {
                reply(connector, a, msg.chat_id, msg.message_id, "Failed to summarize that chat.");
                return;
            };
            connector.sendMessage(a, msg.chat_id, summary, msg.message_id);
        },
    }
}

/// Splits a trailing `--all` token off `/tdsummary`'s argument text.
fn stripAllFlag(text: []const u8) struct { query: []const u8, all: bool } {
    const trimmed = std.mem.trim(u8, text, " ");
    if (std.mem.eql(u8, trimmed, "--all")) return .{ .query = "", .all = true };
    if (std.mem.endsWith(u8, trimmed, " --all")) {
        return .{ .query = std.mem.trim(u8, trimmed[0 .. trimmed.len - " --all".len], " "), .all = true };
    }
    return .{ .query = trimmed, .all = false };
}

test "stripAllFlag: strips a trailing --all token, leaves a bare query alone" {
    const with_flag = stripAllFlag("Alice Work --all");
    try std.testing.expectEqualStrings("Alice Work", with_flag.query);
    try std.testing.expect(with_flag.all);

    const without_flag = stripAllFlag("Alice Work");
    try std.testing.expectEqualStrings("Alice Work", without_flag.query);
    try std.testing.expect(!without_flag.all);

    const flag_only = stripAllFlag("--all");
    try std.testing.expectEqualStrings("", flag_only.query);
    try std.testing.expect(flag_only.all);

    const embedded = stripAllFlag("chat--all");
    try std.testing.expectEqualStrings("chat--all", embedded.query);
    try std.testing.expect(!embedded.all);
}

/// The Bot API owner's own native chat id (private-chat id == user id on
/// Telegram).
fn ownerTelegramNativeId(config: *const config_mod.Config) ?[]const u8 {
    for (config.owners) |entry| {
        if (entry.platform == .telegram) return entry.owner_id;
    }
    return null;
}

/// The `identities` row for the Bot API owner — the identity
/// `user_settings.reply_autonomy_default`.
fn resolveOwnerIdentityId(pool: *store_pool.PgPool, config: *const config_mod.Config, now: i64) !i64 {
    const native_id = ownerTelegramNativeId(config) orelse return error.NoTelegramOwnerConfigured;
    return identities.getOrCreateMinimal(pool, .telegram, native_id, "Owner", null, false, now);
}

/// `/autonomy` — Phase D of the plan sent to the owner: the off/draft/auto
/// dial for `reply_autonomy` (migration `0043_reply_autonomy.sql`).
fn handleAutonomyCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    msg: iface.Message,
    text: []const u8,
    now: i64,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change reply_autonomy.");
        return;
    }
    const owner_identity_id = resolveOwnerIdentityId(pool, config, now) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't resolve the owner's identity — is WARDEN_TELEGRAM_OWNER_ID set?");
        return;
    };

    const rest = std.mem.trim(u8, text["/autonomy".len..], " ");
    if (rest.len == 0) {
        const global = user_settings.getEffectiveReplyAutonomyDefault(pool, a, owner_identity_id);
        const status = std.fmt.allocPrint(a, "Global reply_autonomy default: {s}\n\nUsage:\n/autonomy <off|draft|auto> — set the global default\n/autonomy <chat id> <off|draft|auto|clear> — per-chat override (see /tdchats for chat ids)\n/autonomy <chat id> prompt [<text>|off] — that chat's ghostwriter voice", .{@tagName(global)}) catch return;
        connector.sendMessage(a, msg.chat_id, status, msg.message_id);
        return;
    }

    const space = std.mem.indexOfScalar(u8, rest, ' ');
    if (space == null) {
        const level = std.meta.stringToEnum(user_settings.ReplyAutonomy, rest) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /autonomy <off|draft|auto>, or /autonomy <chat id> <off|draft|auto|clear>.");
            return;
        };
        user_settings.setReplyAutonomyDefault(pool, owner_identity_id, level) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Failed to save.");
            return;
        };
        const confirmation = std.fmt.allocPrint(a, "Global reply_autonomy default set to {s}.", .{@tagName(level)}) catch return;
        connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        return;
    }

    const native_chat_id = rest[0..space.?];
    const level_text = std.mem.trim(u8, rest[space.? + 1 ..], " ");
    const target = (chats.getByNative(pool, a, .telegram_user, native_chat_id) catch null) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Unknown chat id — Warden only has an override target for a personal-account chat once a message has been exchanged with it. See /tdchats.");
        return;
    };

    if (std.mem.eql(u8, level_text, "clear")) {
        chat_settings.setReplyAutonomy(pool, target.id, null) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Failed to clear.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Override cleared — this chat now inherits the global default.");
        return;
    }

    // `/autonomy <chat id> prompt [<text>]` — this chat's ghostwriter voice.
    if (std.mem.eql(u8, level_text, "prompt") or std.mem.startsWith(u8, level_text, "prompt ")) {
        const prompt_arg = std.mem.trim(u8, level_text["prompt".len..], " ");
        if (prompt_arg.len == 0) {
            const current = chat_settings.getReplyAutonomyPrompt(pool, a, target.id);
            const status = if (current) |c|
                std.fmt.allocPrint(a, "Ghostwriter prompt for chat {s}:\n\n{s}\n\n/autonomy {s} prompt off to clear it.", .{ native_chat_id, c, native_chat_id }) catch return
            else
                std.fmt.allocPrint(a, "Chat {s} uses the built-in ghostwriter prompt (write in your voice, no AI framing). Set your own with /autonomy {s} prompt <text>.", .{ native_chat_id, native_chat_id }) catch return;
            connector.sendMessage(a, msg.chat_id, status, msg.message_id);
            return;
        }
        const new_prompt: ?[]const u8 = if (std.mem.eql(u8, prompt_arg, "off")) null else prompt_arg;
        chat_settings.setReplyAutonomyPrompt(pool, target.id, new_prompt) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Failed to save.");
            return;
        };
        // `reply` takes its text comptime, so this is two calls rather
        // than one with a runtime-selected string.
        if (new_prompt == null) {
            reply(connector, a, msg.chat_id, msg.message_id, "Ghostwriter prompt cleared — back to the built-in one.");
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, "Ghostwriter prompt set for this chat.");
        }
        return;
    }
    const level = std.meta.stringToEnum(user_settings.ReplyAutonomy, level_text) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /autonomy <chat id> <off|draft|auto|clear>, or /autonomy <chat id> prompt [<text>|off].");
        return;
    };
    chat_settings.setReplyAutonomy(pool, target.id, level) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Failed to save.");
        return;
    };
    const confirmation = std.fmt.allocPrint(a, "reply_autonomy for chat {s} set to {s}.", .{ native_chat_id, @tagName(level) }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

/// `/drafts` — lists every pending `reply_autonomy = .draft` draft (see
/// `reply_drafts.PendingDrafts`).
fn handleFeedCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    io: Io,
    llm_provider: llm.Provider,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    msg: iface.Message,
    text: []const u8,
    now: i64,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can manage the curated feed.");
        return;
    }

    const rest = std.mem.trim(u8, text["/feed".len..], " ");
    if (rest.len == 0) {
        feedStatus(connector, a, pool, msg);
        return;
    }

    const space = std.mem.indexOfScalar(u8, rest, ' ');
    const sub = if (space) |i| rest[0..i] else rest;
    const arg = if (space) |i| std.mem.trim(u8, rest[i + 1 ..], " ") else "";

    if (std.mem.eql(u8, sub, "list")) {
        const sources = feed_store.listSources(pool, a, false) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't load the source list.");
            return;
        };
        if (sources.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "No sources yet. Add one with /feed add <chat id or name> — see /tdchats for ids.");
            return;
        }
        var out: Io.Writer.Allocating = .init(a);
        out.writer.writeAll("Feed sources:\n") catch {};
        for (sources) |src| {
            out.writer.print("\n{s} ({s}){s}", .{ src.title, src.native_chat_id, if (src.enabled) "" else " — paused" }) catch break;
        }
        connector.sendMessage(a, msg.chat_id, out.writer.buffered(), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "add")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /feed add <chat id or name> — see /tdchats for ids.");
            return;
        }
        const conn = telegram_user orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment.");
            return;
        };
        const resolution = chat_summary.resolveChat(conn, a, arg) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that chat up.");
            return;
        };
        switch (resolution) {
            .none => reply(connector, a, msg.chat_id, msg.message_id, "No chat matches that — see /tdchats."),
            .ambiguous => |candidates| {
                const listed = chat_summary.formatChatList(a, candidates, 10) catch return;
                const out = std.fmt.allocPrint(a, "That matches more than one chat:\n\n{s}", .{listed}) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
            .one => |match| {
                _ = feed_store.addSource(pool, match.native_chat_id, match.title) catch {
                    reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that source.");
                    return;
                };
                const out = std.fmt.allocPrint(a, "Watching \"{s}\" ({s}). Its existing posts are skipped — only new ones from here on will be considered.", .{ match.title, match.native_chat_id }) catch return;
                connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            },
        }
        return;
    }

    if (std.mem.eql(u8, sub, "remove")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /feed remove <chat id> — see /feed list.");
            return;
        }
        const removed = feed_store.removeSource(pool, arg) catch false;
        if (removed) {
            reply(connector, a, msg.chat_id, msg.message_id, "Stopped watching that channel.");
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, "That channel isn't in the feed — see /feed list.");
        }
        return;
    }

    if (std.mem.eql(u8, sub, "target")) {
        if (arg.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /feed target <chat id> — where digests get posted.");
            return;
        }
        feed_store.setTarget(pool, arg) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that.");
            return;
        };
        const out = std.fmt.allocPrint(a, "Digests will be posted to {s}.", .{arg}) catch return;
        connector.sendMessage(a, msg.chat_id, out, msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "policy")) {
        if (arg.len == 0) {
            const settings = feed_store.getSettings(pool, a) catch {
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't read the policy.");
                return;
            };
            const out = if (settings.policy) |p|
                std.fmt.allocPrint(a, "Current policy:\n\n{s}", .{p}) catch return
            else
                std.fmt.allocPrint(a, "No policy set. Set one with /feed policy <what you want>, e.g. \"international news, not crypto price talk\".", .{}) catch return;
            connector.sendMessage(a, msg.chat_id, out, msg.message_id);
            return;
        }
        feed_store.setPolicy(pool, arg) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Policy saved.");
        return;
    }

    if (std.mem.eql(u8, sub, "every")) {
        const seconds = reminder_format.parseDuration(arg) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /feed every <duration>, e.g. /feed every 1h.");
            return;
        };
        // A digest every few seconds would be a stream, not a digest, and
        // would spend model calls faster than anyone could read them.
        if (seconds < 300) {
            reply(connector, a, msg.chat_id, msg.message_id, "That's too frequent — five minutes is the shortest useful digest interval.");
            return;
        }
        feed_store.setIntervalSeconds(pool, seconds) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that.");
            return;
        };
        const out = std.fmt.allocPrint(a, "A digest will be posted at most every {d} seconds.", .{seconds}) catch return;
        connector.sendMessage(a, msg.chat_id, out, msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "on") or std.mem.eql(u8, sub, "off")) {
        const on = std.mem.eql(u8, sub, "on");
        feed_store.setEnabled(pool, on) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that.");
            return;
        };
        if (on) {
            // Enabling without a target or policy does nothing, so say so
            // rather than letting it look like it's running.
            const settings = feed_store.getSettings(pool, a) catch {
                reply(connector, a, msg.chat_id, msg.message_id, "Feed enabled.");
                return;
            };
            if (settings.target_native_chat_id == null) {
                reply(connector, a, msg.chat_id, msg.message_id, "Feed enabled — but it won't run until you set where digests go: /feed target <chat id>.");
            } else if (settings.policy == null) {
                reply(connector, a, msg.chat_id, msg.message_id, "Feed enabled — but it won't run until you set what you want: /feed policy <text>.");
            } else {
                reply(connector, a, msg.chat_id, msg.message_id, "Feed enabled.");
            }
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, "Feed disabled. Sources and policy are kept.");
        }
        return;
    }

    if (std.mem.eql(u8, sub, "run")) {
        const settings = feed_store.getSettings(pool, a) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't read the feed settings.");
            return;
        };
        if (!settings.isRunnable()) {
            reply(connector, a, msg.chat_id, msg.message_id, "The feed isn't fully set up yet — see /feed.");
            return;
        }
        const dyn = resolveLlmDynamicSettings(pool, a, config);
        const posted = curated_feed.runOnce(pool, a, io, llm_provider, telegram_user, dyn.max_retries, now) catch |err| {
            log.err("curated feed: manual run failed: {t}", .{err});
            reply(connector, a, msg.chat_id, msg.message_id, "That pass failed — see the server log.");
            return;
        };
        const out = if (posted == 0)
            std.fmt.allocPrint(a, "Nothing new matched the policy.", .{}) catch return
        else
            std.fmt.allocPrint(a, "Posted a digest with {d} item(s).", .{posted}) catch return;
        connector.sendMessage(a, msg.chat_id, out, msg.message_id);
        return;
    }

    reply(connector, a, msg.chat_id, msg.message_id, "Usage: /feed [add|remove|list|target|policy|every|on|off|run]");
}

fn feedStatus(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, msg: iface.Message) void {
    const settings = feed_store.getSettings(pool, a) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't read the feed settings.");
        return;
    };
    const sources = feed_store.listSources(pool, a, false) catch &.{};

    const out = std.fmt.allocPrint(
        a,
        "Curated feed: {s}\nSources: {d}\nTarget: {s}\nInterval: {d}s\nPolicy: {s}\n\n/feed add <chat id or name>, /feed target <chat id>, /feed policy <text>, /feed every <duration>, /feed on, /feed run",
        .{
            if (settings.isRunnable()) "on" else if (settings.enabled) "enabled but not configured" else "off",
            sources.len,
            settings.target_native_chat_id orelse "(not set)",
            settings.interval_seconds,
            settings.policy orelse "(not set)",
        },
    ) catch return;
    connector.sendMessage(a, msg.chat_id, out, msg.message_id);
}

fn handleDraftsListCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pending_drafts: *reply_drafts.PendingDrafts,
    msg: iface.Message,
    now: i64,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can list pending drafts.");
        return;
    }
    const drafts = pending_drafts.list(a, now) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Failed to list drafts.");
        return;
    };
    if (drafts.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "No drafts pending.");
        return;
    }

    var out: Io.Writer.Allocating = .init(a);
    out.writer.writeAll("Pending drafts (each one is also sitting in that chat's Telegram composer):\n") catch {};
    for (drafts) |d| {
        const preview = if (d.draft_text.len > 200) d.draft_text[0..200] else d.draft_text;
        out.writer.print("\n{s} ({s}):\n{s}\n", .{ d.chat_title, d.native_chat_id, preview }) catch break;
        // Only ever set when prefilling actually overwrote something the
        // owner had typed, so this stays out of the way in the normal case.
        if (d.replaced_draft) |r| {
            out.writer.print("  \u{26a0}\u{fe0f} replaced what you'd typed there: {s}\n", .{r}) catch break;
        }
    }
    out.writer.writeAll("\n/approve <chat id> to send, /discard <chat id> to drop — either way the composer is cleared.") catch {};
    connector.sendMessage(a, msg.chat_id, out.writer.buffered(), msg.message_id);
}

/// `/approve <chat id>` — sends a pending `reply_autonomy = .draft` draft
/// exactly as generated, through the personal-account connector.
fn handleApproveCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    msg: iface.Message,
    text: []const u8,
    now: i64,
    io: Io,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can approve a draft.");
        return;
    }
    const conn = telegram_user orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector isn't configured on this deployment.");
        return;
    };
    const native_chat_id = std.mem.trim(u8, text["/approve".len..], " ");
    if (native_chat_id.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /approve <chat id> — see /drafts.");
        return;
    }
    const draft = pending_drafts.take(a, now, native_chat_id) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "No pending draft for that chat (or it expired) — see /drafts.");
        return;
    };
    conn.connector().sendMessage(a, native_chat_id, draft.draft_text, draft.reply_to);
    // Same reasoning as the Approve button's own call — see
    // `handleDraftChoicePicked`.
    telegram_user_platform.clearComposerDraftFor(telegram_user, a, io, native_chat_id);
    const confirmation = std.fmt.allocPrint(a, "Sent to {s}.", .{draft.chat_title}) catch "Sent.";
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

/// `/discard <chat id>` — drops a pending draft without sending it.
fn handleDiscardCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    msg: iface.Message,
    text: []const u8,
    io: Io,
) void {
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can discard a draft.");
        return;
    }
    const native_chat_id = std.mem.trim(u8, text["/discard".len..], " ");
    if (native_chat_id.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /discard <chat id> — see /drafts.");
        return;
    }
    if (pending_drafts.discard(native_chat_id)) {
        telegram_user_platform.clearComposerDraftFor(telegram_user, a, io, native_chat_id);
        reply(connector, a, msg.chat_id, msg.message_id, "Draft discarded.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "No pending draft for that chat.");
    }
}

/// The reply-as-me default when no per-chat `/persona` override exists for
/// this chat — deliberately NOT `config.system_prompt`.
const default_reply_as_owner_prompt =
    \\You are ghostwriting a reply on behalf of the owner of this Telegram
    \\account, to one of their real contacts, in the owner's voice, as if
    \\the owner typed it themselves. Keep it short and natural, the way a
    \\real person texts -- no AI disclaimers, no "as an AI" framing, no
    \\signing off with a name.
    \\
    \\Your entire output is the message. It is typed into the chat and
    \\sent to the contact exactly as you write it, with nothing removed
    \\and nobody reading it first. So write only the message text itself.
    \\
    \\Never address the owner. Never ask the owner a question, never ask
    \\for direction or more context, never describe what you can or can't
    \\tell about the conversation, and never offer options like "should I
    \\send X, or do you want Y". The owner is not the audience and cannot
    \\answer you -- anything of that kind is sent to the contact instead,
    \\where it reads as nonsense and exposes the account as automated.
    \\
    \\You will often have little context about who the contact is or what
    \\the history is. That is normal and is not a reason to stop. Write
    \\the ordinary, low-risk thing a person would type in that spot: match
    \\a greeting with a greeting, acknowledge a message that just needs
    \\acknowledging, and keep it vague rather than inventing specifics --
    \\names, dates, plans, opinions, or commitments the owner never made.
    \\If there is genuinely nothing safe to say, reply with a brief
    \\friendly holding line such as "hey! give me a bit and I'll get back
    \\to you" -- still a sendable message, never a question aimed at the
    \\owner.
;

/// Appended to whichever `reply_autonomy` system prompt is in force, so it
/// survives a per-chat override set through `/autonomy prompt`.
const reply_language_rule =
    \\
    \\
    \\Write in the same language and script the contact just used, always.
    \\If they wrote Persian, reply in Persian; the same for every other
    \\language. Do not translate their message, do not answer in English
    \\because the instructions above are in English, and do not switch
    \\language mid-conversation. Match how they actually type -- if they
    \\write Persian in Latin letters ("salam chetori"), reply the same way
    \\rather than switching to Perso-Arabic script. If a chat genuinely
    \\mixes languages, follow their most recent message.
;

/// `Choice.value` prefixes for the Approve/Discard buttons on a
/// `reply_autonomy = .draft` notification.
const draft_approve_prefix = "draft_approve:";
const draft_discard_prefix = "draft_discard:";

/// Owner-configured `reply_autonomy` for an incoming personal-account message
/// (Phase D of the plan sent to the owner).
fn handleTelegramUserAutoReply(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    io: Io,
    now: i64,
    max_message_len: usize,
    msg: iface.Message,
    text: []const u8,
    owner_notify: iface.Connector,
    pending_drafts: *reply_drafts.PendingDrafts,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
) void {
    const owner_identity_id = resolveOwnerIdentityId(pool, config, now) catch |err| {
        log.err("reply_autonomy: couldn't resolve the owner's identity: {t}", .{err});
        return;
    };
    const autonomy = chat_settings.resolveReplyAutonomy(pool, a, chat_id, owner_identity_id);
    if (autonomy == .off) return;

    const dyn = resolveLlmDynamicSettings(pool, a, config);
    const answer: []const u8 = if (dyn.skip_trivial_messages and trivial_reply.isTrivialMessage(a, text))
        trivial_reply.pickResponse(@intCast(now))
    else blk: {
        // `reply_autonomy`'s own per-chat prompt override, NOT `/persona`'s.
        const base_prompt = chat_settings.getReplyAutonomyPrompt(pool, a, chat_id) orelse default_reply_as_owner_prompt;
        const system_prompt = std.fmt.allocPrint(a, "{s}{s}", .{ base_prompt, reply_language_rule }) catch base_prompt;
        const asker: qa.Asker = if (msg.identity) |identity| .{
            .display_name = identity.display_name,
            .username = identity.username,
            .native_id = identity.native_id,
        } else .{
            .display_name = msg.username orelse msg.user_id,
            .username = msg.username,
            .native_id = msg.user_id,
        };
        const enabled_tools = filterEnabledTools(pool, a, tool_ctx, tools);
        const result = qa.answer(llm_provider, embeddings_client, a, tool_ctx, enabled_tools, pool, chat_id, identity_id, system_prompt, max_message_len, asker, text, null, .{}, false, dyn.show_thinking, dyn.vision_enabled, dyn.documents_enabled, dyn.length_limits, dyn.history_messages, dyn.max_retries) catch |err| {
            log.err("reply_autonomy: qa.answer failed for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        break :blk std.mem.trim(u8, result.text, " \t\r\n");
    };
    if (answer.len == 0) return;

    switch (autonomy) {
        .off => unreachable,
        .auto => connector.sendMessage(a, msg.chat_id, answer, msg.message_id),
        .draft => {
            const chat_title = msg.chat_title orelse msg.chat_id;

            // Write the draft straight into that chat's Telegram composer.
            var replaced_draft: ?[]const u8 = null;
            if (telegram_user) |tu| {
                if (std.fmt.parseInt(i64, msg.chat_id, 10)) |native_id| {
                    replaced_draft = tu.fetchComposerDraft(a, io, native_id) catch |err| blk_draft: {
                        log.warn("reply_autonomy: couldn't read the existing composer draft for chat {s}: {t}", .{ msg.chat_id, err });
                        break :blk_draft null;
                    };
                    if (!tu.setChatDraft(a, io, native_id, answer, now)) {
                        // The notification and the drafts page below still work, so this degrades
                        // rather than fails.
                        log.warn("reply_autonomy: couldn't prefill the composer for chat {s}; falling back to notification-only", .{msg.chat_id});
                        replaced_draft = null;
                    }
                } else |_| {
                    log.warn("reply_autonomy: chat id {s} isn't a TDLib chat id, skipping composer prefill", .{msg.chat_id});
                }
            }

            pending_drafts.set(now, msg.chat_id, chat_title, text, answer, msg.message_id, replaced_draft) catch |err| {
                log.err("reply_autonomy: failed to stash a draft for chat {s}: {t}", .{ msg.chat_id, err });
                return;
            };
            const owner_chat_id = ownerTelegramNativeId(config) orelse {
                log.err("reply_autonomy: draft mode is on but no Bot API owner id is configured to notify", .{});
                return;
            };
            const incoming_preview = if (text.len > 300) text[0..300] else text;
            const replaced_note = if (replaced_draft) |r|
                std.fmt.allocPrint(a, "\n\n\u{26a0}\u{fe0f} This replaced what you'd already typed there: \"{s}\"", .{r}) catch ""
            else
                "";
            const notify_text = std.fmt.allocPrint(
                a,
                "\u{1f4ac} Draft reply ready\nChat: {s} ({s})\nThey said: \"{s}\"\n\nDraft: \"{s}\"{s}",
                .{ chat_title, msg.chat_id, incoming_preview, answer, replaced_note },
            ) catch return;
            // Buttons, not "type /approve <chat id>" — see `handleDraftChoicePicked` for
            // what picking one does.
            const approve_value = std.fmt.allocPrint(a, "{s}{s}", .{ draft_approve_prefix, msg.chat_id }) catch return;
            const discard_value = std.fmt.allocPrint(a, "{s}{s}", .{ draft_discard_prefix, msg.chat_id }) catch return;
            const choices = [_]iface.Choice{
                .{ .emoji = "\xe2\x9c\x85", .label = "Approve", .value = approve_value },
                .{ .emoji = "\xe2\x9d\x8c", .label = "Discard", .value = discard_value },
            };
            _ = owner_notify.sendChoicePrompt(a, owner_chat_id, notify_text, &choices, null) catch |err| {
                log.warn("reply_autonomy: sendChoicePrompt failed for the owner notification, chat {s}: {t}", .{ msg.chat_id, err });
            };
        },
    }
}

/// Consumes a `ChoicePicked` that's an Approve/Discard button press on a
/// `reply_autonomy = .draft` notification.
fn handleDraftChoicePicked(
    connector: iface.Connector,
    a: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    now: i64,
    msg: iface.Message,
    picked: iface.ChoicePicked,
) bool {
    const is_draft_button = std.mem.startsWith(u8, picked.value, draft_approve_prefix) or
        std.mem.startsWith(u8, picked.value, draft_discard_prefix);
    if (!is_draft_button) return false;
    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        log.warn("reply_autonomy: ignoring draft button {s} pressed by non-owner {s} in chat {s}", .{ picked.value, msg.user_id, msg.chat_id });
        return true;
    }
    if (std.mem.startsWith(u8, picked.value, draft_approve_prefix)) {
        const native_chat_id = picked.value[draft_approve_prefix.len..];
        const draft = pending_drafts.take(a, now, native_chat_id) orelse {
            connector.sendMessage(a, msg.chat_id, "That draft is gone (already sent/discarded, or expired).", msg.message_id);
            return true;
        };
        const conn = telegram_user orelse {
            connector.sendMessage(a, msg.chat_id, "The personal-account connector isn't configured on this deployment.", msg.message_id);
            return true;
        };
        conn.connector().sendMessage(a, native_chat_id, draft.draft_text, draft.reply_to);
        // The composer still holds this exact text (that's how the owner saw it in
        // the first place).
        telegram_user_platform.clearComposerDraftFor(telegram_user, a, io, native_chat_id);
        const confirmation = std.fmt.allocPrint(a, "Sent to {s}.", .{draft.chat_title}) catch "Sent.";
        connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        return true;
    }
    if (std.mem.startsWith(u8, picked.value, draft_discard_prefix)) {
        const native_chat_id = picked.value[draft_discard_prefix.len..];
        if (pending_drafts.discard(native_chat_id)) {
            telegram_user_platform.clearComposerDraftFor(telegram_user, a, io, native_chat_id);
            connector.sendMessage(a, msg.chat_id, "Draft discarded.", msg.message_id);
        } else {
            connector.sendMessage(a, msg.chat_id, "That draft is already gone.", msg.message_id);
        }
        return true;
    }
    return false;
}

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
/// gated in the dispatcher above.
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

/// Resolves a command's target identity, in order: a reply to the target's
/// message; failing that, an `@username` argument.
fn resolveTargetIdentity(pool: *store_pool.PgPool, connector: iface.Connector, a: std.mem.Allocator, now: i64, msg: iface.Message, target_arg: []const u8, create_if_missing: bool) !?identities.IdentityRef {
    if (replyTarget(msg)) |target| {
        // `msg.reply_to_username` (not `target.label`, which already substituted the
        // raw user id when no username is known).
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

/// The six bot-management commands (`/blockuser /unblockuser /blockchat
/// /unblockchat /addadmin /removeadmin`) share this shape.
fn usernameFromArg(arg: []const u8) ?[]const u8 {
    if (arg.len > 1 and arg[0] == '@') return arg[1..];
    return null;
}

/// `/kick`/`/ban [@username | user_id]` — same reply-or-`@username`-or-raw-id
/// targeting as `/blockuser`/`/addadmin` (via `resolveTargetIdentity`).
fn handleKickBanCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, pending_undos: *audit_notify.PendingUndos, is_superuser: bool, now: i64, msg: iface.Message, text: []const u8, comptime prefix: []const u8, kind: group_admin.ActionKind) void {
    const raw_arg = std.mem.trim(u8, text[prefix.len..], " ");
    const vis = resolveVisibility(pool, a, chat_id, raw_arg, is_superuser);
    const target = (resolveTargetIdentity(pool, connector, a, now, msg, vis.rest, true) catch |err| {
        log.err("{s}: failed to resolve target: {t}", .{ @tagName(kind), err });
        return;
    }) orelse {
        const message = std.fmt.allocPrint(a, "Reply to the message of the person you want to {s} (or pass @username or their user id).", .{@tagName(kind)}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    };
    group_admin.requestConfirmation(connector, a, msg, kind, target.native_id, target.display_name, now, auditCtxWithVisibility(pool, pending_undos, chat_id, identity_id, msg, vis.visibility));
}

/// `/slowmode <seconds>` sets warden's own per-chat cooldown between a
/// member's messages, `/slowmode off` clears it.
fn handleSlowmodeCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/slowmode".len..], " ");
    if (arg.len == 0) {
        const current = rate_limits.getSlowModeSeconds(pool, chat_id);
        if (current > 0) {
            const message = std.fmt.allocPrint(a, "Slow mode is on: {d}s between messages per member. Usage: /slowmode <seconds>|off", .{current}) catch return;
            connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, "Slow mode is off. Usage: /slowmode <seconds>|off");
        }
        return;
    }
    if (std.ascii.eqlIgnoreCase(arg, "off")) {
        rate_limits.setSlowModeSeconds(pool, chat_id, 0) catch |err| {
            log.err("slowmode: failed to disable for chat {d}: {t}", .{ chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Slow mode disabled.");
        return;
    }
    const seconds = std.fmt.parseInt(i64, arg, 10) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /slowmode <seconds>|off");
        return;
    };
    if (seconds <= 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Seconds must be positive -- use /slowmode off to disable.");
        return;
    }
    rate_limits.setSlowModeSeconds(pool, chat_id, seconds) catch |err| {
        log.err("slowmode: failed to set for chat {d}: {t}", .{ chat_id, err });
        return;
    };
    const message = std.fmt.allocPrint(
        a,
        "Slow mode set: {d}s between messages per member (enforced on Telegram/Matrix by deleting messages sent too soon; not enforced on XMPP). Admins are exempt.",
        .{seconds},
    ) catch return;
    connector.sendMessage(a, msg.chat_id, message, msg.message_id);
}

/// Order-independent tokenizer for `/permission`'s arg string, same style as
/// `parseBalanceAndUsernameArgs` above.
fn parsePermissionArgs(arg: []const u8) struct { duration_str: []const u8, spec: []const u8, target_arg: []const u8 } {
    var duration_str: []const u8 = "";
    var spec: []const u8 = "";
    var target_arg: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '@') {
            target_arg = tok;
        } else if (tok.len > 0 and (tok[0] == '+' or tok[0] == '-')) {
            spec = tok;
        } else if (duration_str.len == 0) {
            duration_str = tok;
        }
    }
    return .{ .duration_str = duration_str, .spec = spec, .target_arg = target_arg };
}

const permission_usage =
    "Usage: /permission [<duration>] <+|-><letters> <@user>  (or reply to their message)\n" ++
    "Letters: r=read w=write p=photos v=videos f=file m=music o=voice d=video-messages s=stickers/gifs l=polls e=embed-links a=reactions t=edit-own-tag i=change-info\n" ++
    "Example: /permission -w @user   (mutes them)\n" ++
    "Duration uses the same grammar as /remind: <n>m (minutes), <n>h (hours), <n>d (days) -- no week/month shorthand.\n" ++
    "Enforcement is partial: w/p/v/f/m/o/d/s/l/e/i are enforced on Telegram (best-effort on Matrix: only w); r/a/t are stored but not enforceable on any platform today; nothing is enforced on XMPP.";

/// `/permission [<duration>] <+|-><letters> <@user|reply>`.
fn handlePermissionCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/permission".len..], " ");
    if (arg.len == 0) {
        connector.sendMessage(a, msg.chat_id, permission_usage, msg.message_id);
        return;
    }
    const parsed = parsePermissionArgs(arg);
    if (parsed.spec.len == 0) {
        connector.sendMessage(a, msg.chat_id, permission_usage, msg.message_id);
        return;
    }
    const change = member_permissions.parseChange(parsed.spec) catch |err| {
        const message = switch (err) {
            error.MissingSign => "Permission spec must start with + (grant) or - (revoke).",
            error.EmptyLetters => "Permission spec needs at least one letter after the +/-.",
            error.UnknownLetter => "Unknown permission letter -- use any of: r w p v f m o d s l e a t i.",
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    };

    var expires_at: ?i64 = null;
    if (parsed.duration_str.len > 0) {
        const secs = reminder_format.parseDuration(parsed.duration_str) orelse {
            const message = std.fmt.allocPrint(a, "Couldn't parse duration '{s}' -- use <n>m (minutes), <n>h (hours), or <n>d (days).", .{parsed.duration_str}) catch return;
            connector.sendMessage(a, msg.chat_id, message, msg.message_id);
            return;
        };
        expires_at = now + secs;
    }

    const target = (resolveTargetIdentity(pool, connector, a, now, msg, parsed.target_arg, true) catch |err| {
        log.err("permission: failed to resolve target: {t}", .{err});
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the target's message, or pass @username, then the +/-letters.");
        return;
    };

    const current_bits = member_permissions.getBits(pool, chat_id, target.id);
    const new_bits = member_permissions.applyChange(current_bits, change);
    member_permissions.setBits(pool, chat_id, target.id, new_bits, expires_at) catch |err| {
        log.err("permission: failed to save bits for identity {d} in chat {d}: {t}", .{ target.id, chat_id, err });
        return;
    };

    // Best-effort live enforcement.
    connector.restrictChatMemberPermissions(a, msg.chat_id, target.native_id, new_bits, if (expires_at) |e| e else 0) catch |err| {
        if (err == error.Unsupported) {
            log.debug("permission: platform has no granular permission enforcement for {s} in chat {s} (bitmask stored only)", .{ target.native_id, msg.chat_id });
        } else {
            log.warn("permission: failed to enforce live restriction for {s} in chat {s}: {t}", .{ target.native_id, msg.chat_id, err });
        }
    };

    const duration_note: []const u8 = if (expires_at != null) " (temporary -- reverts automatically)" else "";
    const message = std.fmt.allocPrint(
        a,
        "Updated permissions for {s}{s}. Enforcement is partial by platform: w/p/v/f/m/o/d/s/l/e/i are enforced on Telegram; only w (mute) is enforced on Matrix; r/a/t are stored but not enforceable anywhere; nothing is enforced on XMPP. Run /permission with no arguments for the full letter grammar.",
        .{ target.display_name, duration_note },
    ) catch return;
    connector.sendMessage(a, msg.chat_id, message, msg.message_id);
}

/// `/tag @user <text>` / `/tag @user off` (or reply to the target's message
/// instead of `@user`) — Telegram's `setChatAdministratorCustomTitle`.
fn handleTagCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/tag".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /tag <@user|reply> <text>  or  /tag <@user|reply> off  (Telegram only -- target must already be a chat administrator)");
        return;
    }

    var target_arg: []const u8 = "";
    var tag_text: []const u8 = arg;
    if (arg[0] == '@') {
        const sp = std.mem.indexOfScalar(u8, arg, ' ') orelse arg.len;
        target_arg = arg[0..sp];
        tag_text = std.mem.trim(u8, arg[sp..], " ");
    }

    const target = (resolveTargetIdentity(pool, connector, a, now, msg, target_arg, true) catch |err| {
        log.err("tag: failed to resolve target: {t}", .{err});
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the target's message, or pass @username, then the tag text (or 'off' to clear).");
        return;
    };

    if (tag_text.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /tag <@user|reply> <text>  or  /tag <@user|reply> off");
        return;
    }

    const clearing = std.ascii.eqlIgnoreCase(tag_text, "off");
    const title: []const u8 = if (clearing) "" else tag_text;

    connector.setChatAdminTitle(a, msg.chat_id, target.native_id, title) catch |err| {
        if (err == error.Unsupported) {
            reply(connector, a, msg.chat_id, msg.message_id, "Custom tags aren't supported on this platform.");
        } else {
            const message = std.fmt.allocPrint(
                a,
                "Couldn't set a tag for {s} -- Telegram only allows a custom title on chat *administrators*. Make sure they're an admin and the bot itself has admin rights here.",
                .{target.display_name},
            ) catch return;
            connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        }
        return;
    };

    if (clearing) {
        const message = std.fmt.allocPrint(a, "Tag cleared for {s}.", .{target.display_name}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
    } else {
        const message = std.fmt.allocPrint(a, "Tagged {s} as \"{s}\".", .{ target.display_name, tag_text }) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
    }
}

fn handleBlockUserCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/blockuser".len..], " ");
    if (resolveTargetIdentity(pool, connector, a, now, msg, arg, true) catch |err| {
        log.err("blockuser: failed to resolve target: {t}", .{err});
        return;
    }) |target| {
        // A block on the owner or a bot admin would be a no-op at the gate (they're
        // checked before the blocklist).
        if (auth.isOwner(config, connector.platform(), target.native_id) or bot_admins.isBotAdmin(pool, target.id)) {
            const message = std.fmt.allocPrint(a, "{s} is the owner or a bot admin and can't be blocked.", .{target.display_name}) catch return;
            connector.sendMessage(a, msg.chat_id, message, msg.message_id);
            return;
        }
        bot_blocklist.blockUser(pool, target.id, identity_id) catch |err| {
            log.err("blockuser: failed to block: {t}", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "{s} is blocked -- I won't respond to them anywhere.", .{target.display_name}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    // Not a reply, and no identity exists yet for this @username (the bot has
    // never seen a message from them).
    if (usernameFromArg(arg)) |username| {
        bot_pending_grants.addPending(pool, connector.platform(), username, .blocked_user, identity_id) catch |err| {
            log.err("blockuser: failed to queue pending block for @{s}: {t}", .{ username, err });
            return;
        };
        const message = std.fmt.allocPrint(a, "@{s} isn't known to me yet -- they'll be blocked automatically as soon as they message me.", .{username}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username or their user id) you want to block.");
}

fn handleUnblockUserCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, now: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/unblockuser".len..], " ");
    if (resolveTargetIdentity(pool, connector, a, now, msg, arg, true) catch |err| {
        log.err("unblockuser: failed to resolve target: {t}", .{err});
        return;
    }) |target| {
        bot_blocklist.unblockUser(pool, target.id) catch |err| {
            log.err("unblockuser: failed to unblock: {t}", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "{s} is no longer blocked.", .{target.display_name}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    // No resolvable identity — the only thing left to undo is a pending
    // (not yet completed) block queued by an earlier /blockuser @username.
    if (usernameFromArg(arg)) |username| {
        bot_pending_grants.removePending(pool, connector.platform(), username, .blocked_user) catch |err| {
            log.err("unblockuser: failed to cancel pending block for @{s}: {t}", .{ username, err });
            return;
        };
        const message = std.fmt.allocPrint(a, "@{s} won't be blocked automatically anymore.", .{username}) catch return;
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user (or pass @username or their user id) you want to unblock.");
}

fn handleBlockChatCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, msg: iface.Message) void {
    bot_blocklist.blockChat(pool, chat_id, identity_id) catch |err| {
        log.err("blockchat: failed to block: {t}", .{err});
        return;
    };
    connector.sendMessage(a, msg.chat_id, "This chat is blocked -- I'll only respond to the owner and bot admins here. /unblockchat undoes it.", msg.message_id);
}

fn handleUnblockChatCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message) void {
    bot_blocklist.unblockChat(pool, chat_id) catch |err| {
        log.err("unblockchat: failed to unblock: {t}", .{err});
        return;
    };
    connector.sendMessage(a, msg.chat_id, "This chat is no longer blocked.", msg.message_id);
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

const storage_usage =
    \\Usage:
    \\/storage status
    \\/storage autopilot on|off
    \\/storage cleanup messages [chat id] [--before YYYY-MM-DD | --keep N]
    \\/storage cleanup resample [chat id]
    \\/storage cleanup tmp
    \\Omit [chat id] for the current chat -- run /chatinfo to get another
    \\chat's id (that's warden's own id, not the platform's).
;

/// `/storage` dispatch — hidden, owner-only (checked by the caller).
fn handleStorageCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    io: Io,
    llm_provider: llm.Provider,
    chat_id: i64,
    identity_id: i64,
    msg: iface.Message,
    text: []const u8,
    now: i64,
) void {
    const rest = std.mem.trim(u8, text["/storage".len..], " ");
    if (rest.len == 0 or std.mem.eql(u8, rest, "status")) {
        const report = storage_sense.buildStatusReport(a, io, config, pool) catch |err| {
            log.err("storage: buildStatusReport failed: {t}", .{err});
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't build a status report, try again.");
            return;
        };
        connector.sendMessage(a, msg.chat_id, report, msg.message_id);
        return;
    }

    if (std.mem.startsWith(u8, rest, "autopilot")) {
        const arg = std.mem.trim(u8, rest["autopilot".len..], " ");
        if (std.mem.eql(u8, arg, "on")) {
            dynamic_config.set(pool, storage_sense.autopilot_enabled_key, "true", identity_id) catch |err| {
                log.err("storage: failed to enable autopilot: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update autopilot, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Autopilot on — the ladder will prune/resample and can enter sleep mode.");
        } else if (std.mem.eql(u8, arg, "off")) {
            dynamic_config.set(pool, storage_sense.autopilot_enabled_key, "false", identity_id) catch |err| {
                log.err("storage: failed to disable autopilot: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update autopilot, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Autopilot off — monitoring/alerts stay on, but the ladder won't clean up or sleep on its own.");
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, storage_usage);
        }
        return;
    }

    if (std.mem.startsWith(u8, rest, "cleanup")) {
        handleStorageCleanupCommand(connector, a, config, pool, io, llm_provider, chat_id, msg, std.mem.trim(u8, rest["cleanup".len..], " "), now);
        return;
    }

    reply(connector, a, msg.chat_id, msg.message_id, storage_usage);
}

fn handleStorageCleanupCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    io: Io,
    llm_provider: llm.Provider,
    chat_id: i64,
    msg: iface.Message,
    rest: []const u8,
    now: i64,
) void {
    // No `/storage cleanup versions` -- Docker image/build-cache cleanup stays a
    // host-side ops concern (a cron/script outside the container).
    if (std.mem.startsWith(u8, rest, "messages")) {
        handleStorageCleanupMessages(connector, a, config, pool, chat_id, msg, std.mem.trim(u8, rest["messages".len..], " "), now);
    } else if (std.mem.startsWith(u8, rest, "resample")) {
        handleStorageCleanupResample(connector, a, config, pool, io, llm_provider, chat_id, msg, std.mem.trim(u8, rest["resample".len..], " "));
    } else if (std.mem.eql(u8, rest, "tmp")) {
        handleStorageCleanupTmp(connector, a, config, io, msg);
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, storage_usage);
    }
}

/// Parses an optional leading `<chat id>` token off `rest`.
fn stripLeadingChatId(rest: []const u8, default_chat_id: i64) struct { chat_id: i64, rest: []const u8 } {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const first = it.peek() orelse return .{ .chat_id = default_chat_id, .rest = rest };
    const parsed = std.fmt.parseInt(i64, first, 10) catch return .{ .chat_id = default_chat_id, .rest = rest };
    _ = it.next();
    return .{ .chat_id = parsed, .rest = it.rest() };
}

fn handleStorageCleanupMessages(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    rest: []const u8,
    now: i64,
) void {
    const target = stripLeadingChatId(rest, chat_id);

    if (std.mem.startsWith(u8, target.rest, "--keep")) {
        const n_str = std.mem.trim(u8, target.rest["--keep".len..], " ");
        const keep_n = std.fmt.parseInt(i64, n_str, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, storage_usage);
            return;
        };
        messages.pruneKeepLast(pool, target.chat_id, keep_n) catch |err| {
            log.err("storage: cleanup messages --keep failed for chat {d}: {t}", .{ target.chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't prune, try again.");
            return;
        };
        const reply_text = std.fmt.allocPrint(a, "Pruned chat {d}, keeping the most recent {d} messages.", .{ target.chat_id, keep_n }) catch return;
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    var cutoff_ts = now - dynamic_config.getI64(pool, a, storage_sense.prune_age_days_key, config.storage_sense_prune_age_days) * 86400;
    if (std.mem.startsWith(u8, target.rest, "--before")) {
        const date_str = std.mem.trim(u8, target.rest["--before".len..], " ");
        const parts = reminder_format.parseDatePart(date_str, .ymd) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that date -- use YYYY-MM-DD.");
            return;
        };
        const year = parts.year orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "That date needs a year -- use YYYY-MM-DD.");
            return;
        };
        cutoff_ts = civil_time.unixFromLocal(.{ .year = year, .month = parts.month, .day = parts.day }, 0);
    } else if (target.rest.len > 0) {
        reply(connector, a, msg.chat_id, msg.message_id, storage_usage);
        return;
    }

    const result = storage_sense.pruneOldMessages(pool, a, target.chat_id, cutoff_ts) catch |err| {
        log.err("storage: cleanup messages failed for chat {d}: {t}", .{ target.chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't prune, try again.");
        return;
    };
    const reply_text = std.fmt.allocPrint(a, "Pruned {d} messages from chat {d}.", .{ result.rows_deleted, target.chat_id }) catch return;
    connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
}

fn handleStorageCleanupResample(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    io: Io,
    llm_provider: llm.Provider,
    chat_id: i64,
    msg: iface.Message,
    rest: []const u8,
) void {
    var target_chat_id = chat_id;
    if (rest.len > 0) {
        target_chat_id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, storage_usage);
            return;
        };
    }
    const batch_size = dynamic_config.getI64(pool, a, storage_sense.resample_batch_size_key, config.storage_sense_resample_batch_size);
    const result = storage_sense.resampleOldMessages(pool, a, io, llm_provider, target_chat_id, batch_size) catch |err| {
        log.err("storage: cleanup resample failed for chat {d}: {t}", .{ target_chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't resample, try again.");
        return;
    };
    const reply_text = if (result.messages_compacted > 0)
        std.fmt.allocPrint(a, "Compacted {d} messages from chat {d} into one summary.", .{ result.messages_compacted, target_chat_id }) catch return
    else
        std.fmt.allocPrint(a, "Nothing to resample in chat {d} (not enough old messages).", .{target_chat_id}) catch return;
    connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
}

fn handleStorageCleanupTmp(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, io: Io, msg: iface.Message) void {
    const result = storage_sense.sweepTmpDir(io, a, config.tmp_dir, storage_sense.tmp_sweep_max_age_seconds) catch |err| {
        log.err("storage: cleanup tmp failed: {t}", .{err});
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't sweep tmp, try again.");
        return;
    };
    const reply_text = std.fmt.allocPrint(a, "Swept {d} stale files ({d} bytes freed) from {s}.", .{ result.files_deleted, result.bytes_freed, config.tmp_dir }) catch return;
    connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
}

fn platformLabel(platform: iface.Platform) []const u8 {
    return switch (platform) {
        .telegram => "Telegram",
        .telegram_user => "Telegram (personal)",
        .matrix => "Matrix",
        .xmpp => "XMPP",
        .discord => "Discord",
        .whatsapp => "WhatsApp",
        .instagram => "Instagram",
    };
}

/// `/chatinfo [native chat id]` — the chat-side counterpart to `/whois`.
fn handleChatInfoCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) void {
    const arg = std.mem.trim(u8, text["/chatinfo".len..], " ");

    const target_id = if (arg.len == 0) chat_id else blk: {
        const found = (chats.getByNative(pool, a, connector.platform(), arg) catch |err| {
            log.err("chatinfo: getByNative failed for {s}: {t}", .{ arg, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that chat up, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "I have no record of a chat with that id on this platform.");
            return;
        };
        break :blk found.id;
    };

    const info = (chats.getInfoById(pool, a, target_id) catch |err| {
        log.err("chatinfo: getInfoById failed for chat {d}: {t}", .{ target_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that chat up, try again.");
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "I have no record of that chat.");
        return;
    };

    var buf: std.Io.Writer.Allocating = .init(a);
    buf.writer.print("{s}\n", .{if (arg.len == 0) "This chat:" else "That chat:"}) catch {};
    buf.writer.print("  id: {d} (use this with /manage bind)\n", .{info.id}) catch {};
    buf.writer.print("  platform: {t}\n", .{info.platform}) catch {};
    buf.writer.print("  native id: {s}\n", .{info.native_chat_id}) catch {};
    if (info.chat_type) |t| buf.writer.print("  type: {s}\n", .{t}) catch {};
    if (info.title) |t| buf.writer.print("  title: {s}\n", .{t}) catch {};
    if (info.left) buf.writer.print("  status: I'm no longer in this chat\n", .{}) catch {};
    connector.sendMessage(a, msg.chat_id, buf.writer.buffered(), msg.message_id);
}

/// `/whois [@username | user_id]` (or reply).
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
    // `bot_admins` at all (see the `is_bot_admin` fix in `handleMessage`).
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

/// `/manage bind|unbind <chat id>` / `/manage list`.
fn handleManageCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /manage bind <chat id> | /manage unbind <chat id> | /manage list\nRun /chatinfo in the chat you want to bind to get its id.";
    const arg = std.mem.trim(u8, text["/manage".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        const targets = management_rooms.listTargets(pool, a, chat_id) catch |err| {
            log.err("manage: listTargets failed for control room {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't list bound chats, try again.");
            return;
        };
        if (targets.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "No chats bound to this room yet. Run /chatinfo in the chat you want to bind to get its id, then /manage bind <chat id> here.");
            return;
        }
        var buf: std.Io.Writer.Allocating = .init(a);
        buf.writer.print("Chats bound to this room:\n", .{}) catch {};
        for (targets) |t| buf.writer.print("  #{d} — {t} {s}\n", .{ t.id, t.platform, t.native_chat_id }) catch {};
        connector.sendMessage(a, msg.chat_id, buf.writer.buffered(), msg.message_id);
        return;
    }

    const want_bind = std.mem.eql(u8, sub, "bind");
    if (!want_bind and !std.mem.eql(u8, sub, "unbind")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const rest = std.mem.trim(u8, it.rest(), " ");
    const target_id = std.fmt.parseInt(i64, rest, 10) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /manage bind <chat id> — that's warden's own id for the chat, not the platform's. Run /chatinfo in the target chat to get it (or /manage list for ones already bound).");
        return;
    };
    const target = (chats.getById(pool, a, target_id) catch |err| {
        log.err("manage: getById failed for chat {d}: {t}", .{ target_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that chat, try again.");
        return;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "No chat with that id.");
        return;
    };
    if (target.platform != connector.platform()) {
        reply(connector, a, msg.chat_id, msg.message_id, "That chat is on a different platform than this room — cross-platform management rooms aren't supported yet.");
        return;
    }
    if (!auth.isOwnerOrLiveAdminOfChat(connector, a, config, target.native_chat_id, msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "You need to be the owner or a live admin of that chat to bind/unbind it.");
        return;
    }

    if (want_bind) {
        management_rooms.bind(pool, chat_id, target.id, identity_id) catch |err| {
            log.err("manage: bind failed (control {d}, target {d}): {t}", .{ chat_id, target.id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't bind that chat, try again.");
            return;
        };
        const confirmation = std.fmt.allocPrint(a, "This room is now a control room for chat #{d}.", .{target.id}) catch return;
        connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
    } else {
        const removed = management_rooms.unbind(pool, chat_id, target.id) catch |err| {
            log.err("manage: unbind failed (control {d}, target {d}): {t}", .{ chat_id, target.id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't unbind that chat, try again.");
            return;
        };
        const confirmation: []const u8 = if (removed) "Unbound." else "That chat wasn't bound to this room.";
        connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
    }
}

/// Commands `/as <chat id> <command>` will replay against a chat.
const as_relayable_commands = [_][]const u8{
    // Smoke test for the relay itself.
    "ping",
    // Moderation that targets a *user*, not a message.
    "kick",
    "ban",
    "mute",
    "unmute",
    "promote",
    "demote",
    "unpin",
    "redact",
    // Per-chat configuration.
    "welcome",
    "persona",
    "location",
    "magicword",
    "thinking",
    "keyword",
    "digest",
    "briefing",
    "alias",
    "template",
    "blockchat",
    "unblockchat",
    "announce",
    "photo",
    "title",
    "description",
    // Read-only reports about the target chat.
    "stats",
    "wordcloud",
    "reminders",
    "notes",
    "alerts",
    "watches",
};

/// The bare command name in `text` (no leading `/` or `!`, no `@botusername`
/// qualifier, no arguments), or null if `text` isn't a command at all.
fn asCommandName(text: []const u8) ?[]const u8 {
    if (text.len < 2 or (text[0] != '/' and text[0] != '!')) return null;
    var end: usize = 1;
    while (end < text.len and text[end] != ' ' and text[end] != '@') : (end += 1) {}
    if (end == 1) return null;
    return text[1..end];
}

fn isRelayableUnderAs(name: []const u8) bool {
    for (as_relayable_commands) |c| {
        if (std.ascii.eqlIgnoreCase(c, name)) return true;
    }
    return false;
}

const AsRelay = struct {
    /// Warden's internal `chats.id` for the target — what handlers taking a
    /// `chat_id: i64` need.
    target_chat_id: i64,
    /// The target's platform-native id — what goes into the relayed
    /// `Message.chat_id`, and what `ReplyRedirect` matches sends against.
    target_native_chat_id: []const u8,
    /// The command to replay, e.g. "/kick @spammer".
    command: []const u8,
};

/// Parses and fully authorizes `/as <chat id> <command>`, returning the plan
/// for `handleMessage` to replay.
fn resolveAsCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    control_chat_id: i64,
    msg: iface.Message,
    text: []const u8,
    relayed: bool,
) ?AsRelay {
    const usage = "Usage: /as <chat id> <command> — e.g. /as 7 /kick @spammer (see /manage list for ids).";

    if (relayed) {
        reply(connector, a, msg.chat_id, msg.message_id, "/as can't be relayed through another /as.");
        return null;
    }

    const arg = std.mem.trim(u8, text["/as".len..], " ");
    var it = std.mem.splitScalar(u8, arg, ' ');
    const id_str = it.first();
    const target_id = std.fmt.parseInt(i64, id_str, 10) catch {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return null;
    };
    const command = std.mem.trim(u8, it.rest(), " ");
    if (command.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return null;
    }
    const name = asCommandName(command) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "The relayed part has to be a command — e.g. /as 7 /stats.");
        return null;
    };
    if (!isRelayableUnderAs(name)) {
        const denial = std.fmt.allocPrint(a, "/{s} can't be run through /as. Relayable: /help lists them; the short version is chat-scoped admin and settings commands that don't need you to reply to a message in that chat.", .{name}) catch return null;
        connector.sendMessage(a, msg.chat_id, denial, msg.message_id);
        return null;
    }

    const target = (chats.getById(pool, a, target_id) catch |err| {
        log.err("as: getById failed for chat {d}: {t}", .{ target_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that chat, try again.");
        return null;
    }) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "No chat with that id.");
        return null;
    };
    if (target.platform != connector.platform()) {
        reply(connector, a, msg.chat_id, msg.message_id, "That chat is on a different platform than where you typed this — cross-platform /as isn't supported yet.");
        return null;
    }
    if (!auth.isOwnerOrLiveAdminOfChat(connector, a, config, target.native_chat_id, msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "You need to be the owner or a live admin of that chat to run commands against it.");
        return null;
    }

    log.info("as: relaying {s} from chat {d} to chat {d} for user {s}", .{ name, control_chat_id, target.id, msg.user_id });
    return .{
        .target_chat_id = target.id,
        .target_native_chat_id = target.native_chat_id,
        .command = command,
    };
}

/// Bundles what `group_admin.mute`/`unmute`/`promote`/`demote` need to log an
/// audit entry.
fn auditCtx(pool: *store_pool.PgPool, pending_undos: *audit_notify.PendingUndos, chat_id: i64, identity_id: i64, msg: iface.Message) group_admin.AuditContext {
    return .{
        .pool = pool,
        .pending_undos = pending_undos,
        .chat_id = chat_id,
        .actor_identity_id = identity_id,
        .actor_label = msg.username orelse msg.user_id,
    };
}

/// Same as `auditCtx`, plus the `-s`/`-p` visibility.
fn auditCtxWithVisibility(pool: *store_pool.PgPool, pending_undos: *audit_notify.PendingUndos, chat_id: i64, identity_id: i64, msg: iface.Message, visibility: group_admin.Visibility) group_admin.AuditContext {
    var ctx = auditCtx(pool, pending_undos, chat_id, identity_id, msg);
    ctx.visibility = visibility;
    return ctx;
}

/// Parses the `-s`/`-p` flag out of `arg`.
fn resolveVisibility(pool: *store_pool.PgPool, a: std.mem.Allocator, chat_id: i64, arg: []const u8, is_superuser: bool) struct { visibility: group_admin.Visibility, rest: []const u8 } {
    const parsed = group_admin.parseVisibility(a, arg, is_superuser);
    const visibility: group_admin.Visibility = if (parsed.visibility == .normal and chat_settings.getSilentByDefault(pool, chat_id))
        .silent
    else
        parsed.visibility;
    return .{ .visibility = visibility, .rest = parsed.rest };
}

/// A command typed *directly* in a bound management room, no `/as <id>`
/// prefix needed.
fn resolveDirectRoomCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
    relayed: bool,
) ?AsRelay {
    if (relayed) return null;
    const name = asCommandName(text) orelse return null;
    if (!isRelayableUnderAs(name)) return null;

    const target = (management_rooms.getBoundTarget(pool, a, chat_id) catch |err| {
        log.err("direct-room: getBoundTarget failed for room {d}: {t}", .{ chat_id, err });
        return null;
    }) orelse return null;

    if (target.platform != connector.platform()) return null;

    if (!auth.isOwnerOrLiveAdminOfChat(connector, a, config, target.native_chat_id, msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "This room is bound to a chat, but you need to be its owner or a live admin to run commands against it here.");
        return null;
    }

    log.info("direct-room: relaying {s} from bound room {d} to chat {d} for user {s}", .{ name, chat_id, target.id, msg.user_id });
    return .{
        .target_chat_id = target.id,
        .target_native_chat_id = target.native_chat_id,
        .command = text,
    };
}

/// Rebuilds the operator's `/as` message as the message the relayed command
/// should see: same sender.
fn asRelayedMessage(msg: iface.Message, target_native_chat_id: []const u8, command: []const u8) iface.Message {
    return .{
        .chat_id = target_native_chat_id,
        .message_id = msg.message_id,
        .user_id = msg.user_id,
        .username = msg.username,
        .text = command,
        .reply_to_user_id = msg.reply_to_user_id,
        .reply_to_username = msg.reply_to_username,
        .is_group = true,
        .identity = msg.identity,
        .telegram_profile = msg.telegram_profile,
        .matrix_profile = msg.matrix_profile,
        .xmpp_profile = msg.xmpp_profile,
    };
}

test "asCommandName strips the indicator, arguments and any @bot qualifier" {
    try std.testing.expectEqualStrings("kick", asCommandName("/kick @spammer").?);
    try std.testing.expectEqualStrings("stats", asCommandName("/stats").?);
    // `normalizeCommandMention` only rewrites the leading indicator of the
    // whole message, so the relayed half can still arrive with a `!`.
    try std.testing.expectEqualStrings("kick", asCommandName("!kick @spammer").?);
    try std.testing.expectEqualStrings("ping", asCommandName("/ping@warden_bot").?);
    try std.testing.expect(asCommandName("kick @spammer") == null);
    try std.testing.expect(asCommandName("/") == null);
    try std.testing.expect(asCommandName("") == null);
    try std.testing.expect(asCommandName("/ x") == null);
}

test "the /as allow-list admits chat-scoped admin commands and refuses everything else" {
    try std.testing.expect(isRelayableUnderAs("kick"));
    try std.testing.expect(isRelayableUnderAs("ban"));
    try std.testing.expect(isRelayableUnderAs("stats"));
    try std.testing.expect(isRelayableUnderAs("welcome"));
    // Case-insensitive, same as `isReservedCommandName`.
    try std.testing.expect(isRelayableUnderAs("KICK"));
    // None of these need a message id.
    try std.testing.expect(isRelayableUnderAs("redact"));
    try std.testing.expect(isRelayableUnderAs("announce"));
    try std.testing.expect(isRelayableUnderAs("blockchat"));
    // None of these act on a message either.
    try std.testing.expect(isRelayableUnderAs("photo"));
    try std.testing.expect(isRelayableUnderAs("title"));
    try std.testing.expect(isRelayableUnderAs("description"));

    // No nesting, no privilege prefixes.
    try std.testing.expect(!isRelayableUnderAs("as"));
    try std.testing.expect(!isRelayableUnderAs("sudo"));
    // Needs a message in the target chat to point at.
    try std.testing.expect(!isRelayableUnderAs("pin"));
    try std.testing.expect(!isRelayableUnderAs("delete"));
    // Stateful flows keyed by (chat, user).
    try std.testing.expect(!isRelayableUnderAs("menu"));
    try std.testing.expect(!isRelayableUnderAs("convert"));
    try std.testing.expect(!isRelayableUnderAs("cancel"));
    try std.testing.expect(!isRelayableUnderAs("confirm"));
    try std.testing.expect(!isRelayableUnderAs("manage"));
    // Not chat-scoped.
    try std.testing.expect(!isRelayableUnderAs("whois"));
    try std.testing.expect(!isRelayableUnderAs("memory"));
    try std.testing.expect(!isRelayableUnderAs("addadmin"));
    try std.testing.expect(!isRelayableUnderAs("scraper"));
    // Not a command at all.
    try std.testing.expect(!isRelayableUnderAs(""));
    try std.testing.expect(!isRelayableUnderAs("nonsense"));
}

test "every /as-relayable command name is a real built-in" {
    // Guards against a typo in `as_relayable_commands` silently making a command
    // unrelayable.
    for (as_relayable_commands) |name| {
        std.testing.expect(isReservedCommandName(name)) catch |err| {
            std.debug.print("as_relayable_commands lists unknown command /{s}\n", .{name});
            return err;
        };
    }
}

test "asRelayedMessage re-addresses the message but keeps who sent it" {
    const original: iface.Message = .{
        .chat_id = "control-room",
        .message_id = "op-msg-7",
        .user_id = "42",
        .username = "alice",
        .text = "/as 7 /kick @spammer",
        .reply_to_message_id = "a-control-room-message",
        .reply_to_user_id = "99",
        .reply_to_username = "spammer",
        .reply_to_text = "buy my coins",
        .chat_type = "supergroup",
        .chat_title = "Ops",
        .is_group = true,
    };

    const relayed = asRelayedMessage(original, "-1001234", "/kick @spammer");

    try std.testing.expectEqualStrings("-1001234", relayed.chat_id);
    try std.testing.expectEqualStrings("/kick @spammer", relayed.text.?);
    // Sender identity is untouched — the relayed command's own auth check
    // must see the real operator.
    try std.testing.expectEqualStrings("42", relayed.user_id);
    try std.testing.expectEqualStrings("alice", relayed.username.?);
    // Threading target for the redirected reply, back in the control room.
    try std.testing.expectEqualStrings("op-msg-7", relayed.message_id.?);
    // A user means the same thing in any chat...
    try std.testing.expectEqualStrings("99", relayed.reply_to_user_id.?);
    try std.testing.expectEqualStrings("spammer", relayed.reply_to_username.?);
    // ...a message id does not.
    try std.testing.expect(relayed.reply_to_message_id == null);
    try std.testing.expect(relayed.reply_to_text == null);
    // Describes the control room, not the target.
    try std.testing.expect(relayed.chat_type == null);
    try std.testing.expect(relayed.chat_title == null);
    try std.testing.expect(relayed.attachment == null);
    try std.testing.expect(relayed.choice_picked == null);
}

/// `/redact` — parses which of the five modes applies, gates per-mode.
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

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "redact")) return;

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

/// Same on/off/now shape as `handleDigestCommand` above, minus the
/// `llm_provider`/`tool_ctx` params that one needs.
fn handleBriefingCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    io: Io,
    pool: *store_pool.PgPool,
    chat_id: i64,
    briefing_scheduler: *scheduler.BriefingScheduler,
    now: i64,
    max_message_len: usize,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/briefing".len..], " ");

    if (std.mem.eql(u8, arg, "on")) {
        briefing_scheduler.enable(connector.platform(), native_chat_id) catch |err| {
            log.err("briefing: failed to enable for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't enable briefings, try again.", reply_to);
            return;
        };
        chat_settings.setBriefingEnabled(pool, chat_id, true) catch |err| {
            log.err("briefing: failed to persist enabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        const hours = @divTrunc(briefing_scheduler.interval_seconds, 3600);
        const msg_text = std.fmt.allocPrint(a, "Briefing enabled — I'll post one roughly every {d}h.", .{hours}) catch return;
        connector.sendMessage(a, native_chat_id, msg_text, reply_to);
    } else if (std.mem.eql(u8, arg, "off")) {
        briefing_scheduler.disable(a, connector.platform(), native_chat_id);
        chat_settings.setBriefingEnabled(pool, chat_id, false) catch |err| {
            log.err("briefing: failed to persist disabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        connector.sendMessage(a, native_chat_id, "Briefing disabled.", reply_to);
    } else if (std.mem.eql(u8, arg, "now")) {
        const briefing_text = briefing.generate(a, pool, chat_id, now, briefingWeatherLine(a, io, pool, chat_id)) catch |err| {
            log.err("briefing: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't generate a briefing just now.", reply_to);
            return;
        };
        sendTextOrFile(connector, a, native_chat_id, briefing_text, reply_to, max_message_len, "briefing.txt");
        chat_settings.setLastBriefingTs(pool, chat_id, now) catch |err| {
            log.err("briefing: failed to persist last_briefing_ts for chat {s}: {t}", .{ native_chat_id, err });
        };
    } else {
        const enabled = briefing_scheduler.isEnabled(a, connector.platform(), native_chat_id);
        const last = chat_settings.getLastBriefingTs(pool, chat_id);
        const msg_text = if (last == 0)
            std.fmt.allocPrint(
                a,
                "Briefing is {s}. Never sent yet. Use /briefing on, /briefing off, or /briefing now.",
                .{if (enabled) "on" else "off"},
            ) catch return
        else
            std.fmt.allocPrint(
                a,
                "Briefing is {s}. Last sent {d}s ago. Use /briefing on, /briefing off, or /briefing now.",
                .{ if (enabled) "on" else "off", now - last },
            ) catch return;
        connector.sendMessage(a, native_chat_id, msg_text, reply_to);
    }
}

const max_reminder_message_len = 500;

/// `/remind <duration|clock-time> <message>` sets a one-off reminder;
/// `/remind every <interval> <message>` sets a recurring one; `/remind cancel
/// <id>` cancels one.
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

// --------------------------------------------------------------------- Phase
// 16, slice 4: scheduled announcements.

/// Longer than `max_reminder_message_len` (500): an announcement is a
/// prepared broadcast to a whole group.
const max_announcement_len = 1000;

/// `/announce <text>` sends `<text>` into this chat right now and pins it
/// (merged the old standalone `/notice <chat id> <text>` into this bare-text
/// form -- ROADMAP.md's gave `/notice` its own command.
fn handleAnnounceCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    now: i64,
    sudo_active: bool,
    msg: iface.Message,
    text: []const u8,
) void {
    const usage = "Usage: /announce <text> (sends now, pinned), /announce at <time e.g. 30m, 14:30, or 5/22 14:30> <text> to schedule, /announce every <interval e.g. 1d> <text> to repeat, /announce list, or /announce cancel <id>";
    const arg = std.mem.trim(u8, text["/announce".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const first_word = it.first();

    if (std.mem.eql(u8, first_word, "list")) {
        const pending = reminders.listPending(pool, a, chat_id, .announcement) catch |err| {
            log.err("announce: list failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't load announcements, try again.");
            return;
        };
        connector.sendMessage(a, msg.chat_id, formatPendingAnnouncements(a, pool, pending, now), msg.message_id);
        return;
    }

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "announce")) return;

    if (std.mem.eql(u8, first_word, "cancel")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /announce cancel <id> (see /announce list for ids).");
            return;
        };
        const row = (reminders.get(pool, a, id) catch |err| {
            log.err("announce: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that announcement, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No scheduled announcement with that id.");
            return;
        };
        // A reminder id passed to `/announce cancel` is told apart from a nonexistent
        // one on purpose.
        if (row.chat_id != chat_id or row.kind != .announcement) {
            reply(connector, a, msg.chat_id, msg.message_id, "No scheduled announcement with that id (if that's a reminder id, use /remind cancel).");
            return;
        }
        reminders.cancel(pool, id) catch |err| {
            log.err("announce: cancel failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't cancel that announcement, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Announcement canceled.");
        return;
    }

    const offset_minutes = user_settings.getEffectiveOffsetMinutes(pool, a, identity_id);
    const date_format = user_settings.getEffectiveDateFormat(pool, a, identity_id);
    const time_format = user_settings.getEffectiveTimeFormat(pool, a, identity_id);

    var recur_interval: ?i64 = null;
    var due_at: i64 = now;
    var announcement: []const u8 = arg;
    var immediate = true;

    if (std.mem.eql(u8, first_word, "every")) {
        immediate = false;
        const when_str = it.next() orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /announce every <interval e.g. 1d> <text>");
            return;
        };
        recur_interval = reminder_format.parseDuration(when_str) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that interval — use e.g. 30m, 2h, or 1d.");
            return;
        };
        // "every <interval>" alone means "first one an interval from now" -- same
        // shorthand `/remind every` uses.
        due_at = now + recur_interval.?;
        announcement = std.mem.trim(u8, it.rest(), " ");
    } else if (std.mem.eql(u8, first_word, "at")) {
        immediate = false;
        const when_str = it.next() orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /announce at <time e.g. 30m, 14:30, or 5/22 14:30> <text>");
            return;
        };
        due_at = reminder_format.parseWhenLocal(when_str, now, offset_minutes, date_format) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that time — use a duration like 30m/2h/1d, a clock time like 14:30, or a date like 5/22 14:30.");
            return;
        };
        announcement = std.mem.trim(u8, it.rest(), " ");
    }

    if (announcement.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    if (announcement.len > max_announcement_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That announcement is too long (max 1000 bytes).");
        return;
    }

    if (immediate) {
        const sent_id = connector.sendMessageReturningId(a, msg.chat_id, announcement, null) catch |err| {
            log.err("announce: immediate send failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't send that announcement, try again.");
            return;
        };
        if (sent_id) |sid| {
            connector.pinMessage(a, msg.chat_id, sid) catch |err| {
                log.warn("announce: sent to chat {d} but pin failed: {t}", .{ chat_id, err });
            };
        }
        reply(connector, a, msg.chat_id, msg.message_id, "Announcement sent.");
        return;
    }

    const id = reminders.createOfKind(pool, chat_id, identity_id, announcement, due_at, recur_interval, .announcement) catch |err| {
        log.err("announce: failed to create announcement for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't schedule that announcement, try again.");
        return;
    };

    const local = civil_time.localFromUnix(due_at, offset_minutes);
    const date_str = civil_time.formatDate(a, local, date_format);
    const time_str = civil_time.formatTime(a, local, time_format);

    const confirmation = if (recur_interval) |interval|
        std.fmt.allocPrint(a, "Announcement #{d} scheduled, repeating every {s} (next at {s} {s}).", .{ id, reminder_format.formatInterval(a, interval), date_str, time_str }) catch return
    else
        std.fmt.allocPrint(a, "Announcement #{d} scheduled for {s} {s}.", .{ id, date_str, time_str }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

/// `/announce list`'s rendering — same per-setter-timezone rule
/// `formatPendingReminders` documents.
fn formatPendingAnnouncements(a: std.mem.Allocator, pool: *store_pool.PgPool, pending: []const reminders.PendingReminder, now: i64) []const u8 {
    if (pending.len == 0) return "No scheduled announcements. Schedule one with /announce <time> <text> (chat admins only).";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Scheduled announcements:\n", .{}) catch return "";
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

/// `/autopin` shows this chat's setting; `/autopin on|off` changes it.
fn handleAutopinCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    sudo_active: bool,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/autopin".len..], " ");
    const enabled = chat_settings.getAutopinAnnouncements(pool, chat_id);

    if (arg.len == 0) {
        const reply_text = std.fmt.allocPrint(
            a,
            "Auto-pin is {s} for this chat. When on, I pin each scheduled /announce as I post it (nothing else — I never pin other people's messages on my own). Change it with /autopin on or /autopin off.",
            .{if (enabled) "on" else "off"},
        ) catch return;
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    const want = if (std.mem.eql(u8, arg, "on"))
        true
    else if (std.mem.eql(u8, arg, "off"))
        false
    else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /autopin on | off");
        return;
    };

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "autopin")) return;

    chat_settings.setAutopinAnnouncements(pool, chat_id, want) catch |err| {
        log.err("autopin: failed to persist for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that setting, try again.");
        return;
    };
    if (want) {
        reply(connector, a, msg.chat_id, msg.message_id, "Auto-pin on — I'll pin each scheduled announcement as I post it. (I need pin permission in this group.)");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Auto-pin off — announcements will be posted without pinning.");
    }
}

/// `/silent on|off`.
fn handleSilentCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    sudo_active: bool,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/silent".len..], " ");
    const enabled = chat_settings.getSilentByDefault(pool, chat_id);

    if (arg.len == 0) {
        const reply_text = std.fmt.allocPrint(
            a,
            "Silent-by-default is {s} for this chat. When on, moderation/settings commands (redact, kick, ban, promote, demote, mute, unmute, photo, title, description) skip their in-group confirmation unless run without -s. Change it with /silent on or /silent off.",
            .{if (enabled) "on" else "off"},
        ) catch return;
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    const want = if (std.mem.eql(u8, arg, "on"))
        true
    else if (std.mem.eql(u8, arg, "off"))
        false
    else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /silent on | off");
        return;
    };

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "silent")) return;

    chat_settings.setSilentByDefault(pool, chat_id, want) catch |err| {
        log.err("silent: failed to persist for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that setting, try again.");
        return;
    };
    if (want) {
        reply(connector, a, msg.chat_id, msg.message_id, "Silent-by-default on — moderation/settings commands will skip their in-group confirmation unless run without -s.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Silent-by-default off.");
    }
}

/// `/photo` (send an image with this as its caption) sets the chat's photo;
/// `/photo remove` clears it.
fn handlePhotoCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    io: Io,
    chat_id: i64,
    identity_id: i64,
    pending_undos: *audit_notify.PendingUndos,
    now: i64,
    sudo_active: bool,
    is_superuser: bool,
    msg: iface.Message,
    text: []const u8,
    attachment_path: ?[]const u8,
) void {
    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "photo")) return;
    const raw_arg = std.mem.trim(u8, text["/photo".len..], " ");
    const vis = resolveVisibility(pool, a, chat_id, raw_arg, is_superuser);

    if (std.mem.eql(u8, vis.rest, "remove")) {
        connector.deleteChatPhoto(a, msg.chat_id) catch |err| {
            reportChatSettingFailure(connector, a, msg.chat_id, msg.message_id, "remove the photo", err);
            return;
        };
        if (vis.visibility != .phantom) {
            audit_notify.recordAndNotify(connector, a, pool, pending_undos, now, chat_id, msg.chat_id, identity_id, msg.username orelse msg.user_id, .{ .photo_change = .{ .removed = true } });
        }
        if (vis.visibility == .normal) reply(connector, a, msg.chat_id, msg.message_id, "Photo removed.");
        return;
    }

    const path = attachment_path orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Send an image with /photo as its caption, or use /photo remove.");
        return;
    };
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(20 * 1024 * 1024)) catch |err| {
        log.err("photo: failed to read downloaded attachment {s}: {t}", .{ path, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't read that image, try again.");
        return;
    };
    connector.setChatPhoto(a, msg.chat_id, bytes) catch |err| {
        reportChatSettingFailure(connector, a, msg.chat_id, msg.message_id, "set the photo", err);
        return;
    };
    if (vis.visibility != .phantom) {
        audit_notify.recordAndNotify(connector, a, pool, pending_undos, now, chat_id, msg.chat_id, identity_id, msg.username orelse msg.user_id, .{ .photo_change = .{ .removed = false } });
    }
    if (vis.visibility == .normal) reply(connector, a, msg.chat_id, msg.message_id, "Photo updated.");
}

/// `/title <text>`.
fn handleTitleCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    pending_undos: *audit_notify.PendingUndos,
    now: i64,
    sudo_active: bool,
    is_superuser: bool,
    msg: iface.Message,
    text: []const u8,
) void {
    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "title")) return;
    const raw_arg = std.mem.trim(u8, text["/title".len..], " ");
    const vis = resolveVisibility(pool, a, chat_id, raw_arg, is_superuser);
    const new_title = vis.rest;
    if (new_title.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /title <text>");
        return;
    }
    connector.setChatTitle(a, msg.chat_id, new_title) catch |err| {
        reportChatSettingFailure(connector, a, msg.chat_id, msg.message_id, "set the title", err);
        return;
    };
    if (vis.visibility != .phantom) {
        audit_notify.recordAndNotify(connector, a, pool, pending_undos, now, chat_id, msg.chat_id, identity_id, msg.username orelse msg.user_id, .{ .title_change = .{ .new_title = new_title } });
    }
    if (vis.visibility == .normal) reply(connector, a, msg.chat_id, msg.message_id, "Title updated.");
}

/// `/description <text>` — same shape as `/title`.
fn handleDescriptionCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    pending_undos: *audit_notify.PendingUndos,
    now: i64,
    sudo_active: bool,
    is_superuser: bool,
    msg: iface.Message,
    text: []const u8,
) void {
    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "description")) return;
    const raw_arg = std.mem.trim(u8, text["/description".len..], " ");
    const vis = resolveVisibility(pool, a, chat_id, raw_arg, is_superuser);
    const new_description = vis.rest;
    connector.setChatDescription(a, msg.chat_id, new_description) catch |err| {
        reportChatSettingFailure(connector, a, msg.chat_id, msg.message_id, "set the description", err);
        return;
    };
    if (vis.visibility != .phantom) {
        audit_notify.recordAndNotify(connector, a, pool, pending_undos, now, chat_id, msg.chat_id, identity_id, msg.username orelse msg.user_id, .{ .description_change = .{ .new_description = new_description } });
    }
    if (vis.visibility != .normal) return;
    if (new_description.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Description cleared.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Description updated.");
    }
}

/// Shared failure reply for the three chat-settings commands above.
fn reportChatSettingFailure(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, reply_to: ?[]const u8, action: []const u8, err: anyerror) void {
    log.err("{s} failed: {t}", .{ action, err });
    if (err == error.Unsupported) {
        reply(connector, a, chat_id, reply_to, "That isn't supported on this platform.");
        return;
    }
    const message = std.fmt.allocPrint(a, "Couldn't {s} — check the bot is an admin here with the right permissions.", .{action}) catch return;
    connector.sendMessage(a, chat_id, message, reply_to);
}

/// `/videodownload` shows this chat's setting; `/videodownload on|off`
/// changes it.
fn handleVideoDownloadCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    sudo_active: bool,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/videodownload".len..], " ");
    const enabled = chat_settings.getVideoDownloadEnabled(pool, chat_id);

    if (arg.len == 0) {
        const reply_text = std.fmt.allocPrint(
            a,
            "Video auto-download is {s} for this chat. When on, I try to fetch and repost YouTube/Instagram/X video links posted here -- best-effort, no source size limit (a longer/larger clip just takes longer); if it can't be fetched at all, whether it's private/age-restricted or a downstream error, you'll get a short note instead of nothing. Change it with /videodownload on or /videodownload off.",
            .{if (enabled) "on" else "off"},
        ) catch return;
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    const want = if (std.mem.eql(u8, arg, "on"))
        true
    else if (std.mem.eql(u8, arg, "off"))
        false
    else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /videodownload on | off");
        return;
    };

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "videodownload")) return;

    chat_settings.setVideoDownloadEnabled(pool, chat_id, want) catch |err| {
        log.err("videodownload: failed to persist for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that setting, try again.");
        return;
    };
    if (want) {
        reply(connector, a, msg.chat_id, msg.message_id, "Video auto-download on — I'll try to fetch and repost YouTube/Instagram/X links posted here (best-effort, no source size limit).");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Video auto-download off.");
    }
}

/// `/videoquality` shows this chat's video-auto-download delivery mode;
/// `/videoquality lossy|lossless` changes it.
fn handleVideoQualityCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    sudo_active: bool,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/videoquality".len..], " ");
    const lossy = chat_settings.getVideoDownloadLossy(pool, chat_id);

    if (arg.len == 0) {
        const reply_text = std.fmt.allocPrint(
            a,
            "Video delivery mode is {s} for this chat. Lossy sends a compressed native video (always fits, some quality loss on longer clips); lossless keeps the original file, capped at 50MB, and silently skips anything bigger. Change it with /videoquality lossy or /videoquality lossless.",
            .{if (lossy) "lossy" else "lossless"},
        ) catch return;
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    const want_lossy = if (std.mem.eql(u8, arg, "lossy"))
        true
    else if (std.mem.eql(u8, arg, "lossless"))
        false
    else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /videoquality lossy | lossless");
        return;
    };

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, "videoquality")) return;

    chat_settings.setVideoDownloadLossy(pool, chat_id, want_lossy) catch |err| {
        log.err("videoquality: failed to persist for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that setting, try again.");
        return;
    };
    if (want_lossy) {
        reply(connector, a, msg.chat_id, msg.message_id, "Video delivery set to lossy — auto-downloaded videos will be compressed and sent as a native video.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Video delivery set to lossless — auto-downloaded videos will keep original quality, capped at 50MB, sent as a file.");
    }
}

/// How often `videoProgressTickerLoop` may edit the placeholder message.
const video_progress_ticker_interval_ms: i64 = 3500;

/// Shared between `videoDownloadWorker` (which owns it) and
/// `videoProgressTickerLoop`.
const VideoProgressState = struct {
    io: Io,
    tmp_dir: []const u8,
    ts: i96,
    estimated_total_bytes: ?u64,
    started_at: Io.Timestamp,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

/// Runs on its own detached `std.Thread`, exactly like `tickerLoop`.
fn videoProgressTickerLoop(connector: iface.Connector, chat_id: []const u8, message_id: []const u8, state: *VideoProgressState) void {
    defer state.done.store(true, .release);
    const a = std.heap.page_allocator;
    var last_sent: ?[]const u8 = null;
    defer if (last_sent) |t| a.free(t);

    while (!state.stop.load(.acquire)) {
        Io.sleep(state.io, .fromMilliseconds(video_progress_ticker_interval_ms), .awake) catch return;
        if (state.stop.load(.acquire)) return;

        const elapsed_seconds: i64 = @intCast(@divTrunc(Io.Timestamp.now(state.io, .real).toNanoseconds() - state.started_at.toNanoseconds(), std.time.ns_per_s));
        const current_bytes = video_download.pollCurrentBytes(state.io, state.tmp_dir, state.ts);
        const text = video_download.formatProgressText(a, elapsed_seconds, current_bytes, state.estimated_total_bytes) catch continue;

        if (last_sent != null and std.mem.eql(u8, text, last_sent.?)) {
            a.free(text);
            continue;
        }
        connector.editMessage(a, chat_id, message_id, text) catch |err| {
            log.warn("video_download: progress edit failed for chat {s}: {t}", .{ chat_id, err });
        };
        if (last_sent) |t| a.free(t);
        last_sent = text;
    }
}

/// Passive auto-download of YouTube/Instagram/X links.
fn checkVideoDownload(connector: iface.Connector, a: std.mem.Allocator, io: Io, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) void {
    const url = video_download.findLink(text) orelse return;

    if (connector.vtable.sendDocument == null) {
        log.info("video_download: {t} has no sendDocument support, skipping {s}", .{ connector.platform(), url });
        return;
    }

    // Reuses `storage_sense.zig` rather than a separate check.
    if (storage_sense.checkDiskUsage(a, io, config.tmp_dir)) |usage| {
        const low = dynamic_config.getI64(pool, a, storage_sense.low_watermark_key, config.storage_sense_low_watermark_pct);
        if (usage.used_pct >= @as(f64, @floatFromInt(low))) {
            reply(connector, a, msg.chat_id, msg.message_id, "Storage is low right now, video downloads are paused.");
            return;
        }
    } else |err| {
        log.warn("video_download: disk check failed, letting the download through: {t}", .{err});
    }

    const quality: video_download.Quality = if (chat_settings.getVideoDownloadLossy(pool, chat_id)) .lossy else .lossless;
    // Generated here, not inside `video_download.download`.
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();

    // `page_allocator`-owned dupes, NOT `task_arena`-backed.
    const native_chat_id = std.heap.page_allocator.dupe(u8, msg.chat_id) catch |err| {
        log.warn("video_download: couldn't allocate for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    const url_dup = std.heap.page_allocator.dupe(u8, url) catch |err| {
        log.warn("video_download: couldn't allocate for chat {s}: {t}", .{ msg.chat_id, err });
        std.heap.page_allocator.free(native_chat_id);
        return;
    };
    // Reply-threads the placeholder to the original link message, so it's clear
    // which link is being fetched if several are posted in quick succession.
    const reply_to_dup: ?[]const u8 = if (msg.message_id) |mid| std.heap.page_allocator.dupe(u8, mid) catch null else null;

    const thread = std.Thread.spawn(.{}, videoDownloadWorker, .{ connector, io, config.tmp_dir, native_chat_id, url_dup, reply_to_dup, quality, ts }) catch |err| {
        log.warn("video_download: failed to spawn a download thread for chat {s}: {t}", .{ msg.chat_id, err });
        std.heap.page_allocator.free(native_chat_id);
        std.heap.page_allocator.free(url_dup);
        if (reply_to_dup) |rt| std.heap.page_allocator.free(rt);
        return;
    };
    thread.detach();
}

/// Body of the detached thread `checkVideoDownload` spawns.
fn videoDownloadWorker(connector: iface.Connector, io: Io, tmp_dir: []const u8, native_chat_id: []const u8, url: []const u8, reply_to: ?[]const u8, quality: video_download.Quality, ts: i96) void {
    const a = std.heap.page_allocator;
    defer a.free(native_chat_id);
    defer a.free(url);
    defer if (reply_to) |rt| a.free(rt);

    const placeholder_id = connector.sendMessageReturningId(a, native_chat_id, "⬇️ Downloading…", reply_to) catch |err| blk: {
        log.warn("video_download: couldn't send a placeholder for chat {s}: {t}", .{ native_chat_id, err });
        break :blk null;
    };

    var ticker_thread: ?std.Thread = null;
    var progress_state: ?*VideoProgressState = null;
    if (placeholder_id) |pid| {
        // Lossless mode's own fetch doesn't use `estimateSize`'s ~720p format
        // selector, so its estimate would be meaningless -- only ask for one in lossy
        // mode.
        const estimate = if (quality == .lossy) video_download.estimateSize(a, io, url) else null;

        const s = a.create(VideoProgressState) catch |err| blk: {
            log.warn("video_download: couldn't allocate progress state for chat {s}: {t}", .{ native_chat_id, err });
            break :blk null;
        };
        if (s) |state| {
            state.* = .{ .io = io, .tmp_dir = tmp_dir, .ts = ts, .estimated_total_bytes = estimate, .started_at = Io.Timestamp.now(io, .real) };
            progress_state = state;
            ticker_thread = std.Thread.spawn(.{}, videoProgressTickerLoop, .{ connector, native_chat_id, pid, state }) catch |err| blk: {
                log.warn("video_download: couldn't start the progress ticker for chat {s}: {t}", .{ native_chat_id, err });
                break :blk null;
            };
        }
    }

    const result = video_download.download(a, io, tmp_dir, url, quality, ts);

    // Stop the ticker before touching the placeholder ourselves.
    if (progress_state) |state| {
        state.stop.store(true, .release);
        var waited_ms: i64 = 0;
        while (!state.done.load(.acquire) and waited_ms < 5000) {
            Io.sleep(io, .fromMilliseconds(50), .awake) catch break;
            waited_ms += 50;
        }
        if (ticker_thread) |t| {
            if (state.done.load(.acquire)) {
                t.join();
                a.destroy(state);
            } else {
                log.warn("video_download: progress ticker for chat {s} didn't stop within {d}ms, detaching it", .{ native_chat_id, waited_ms });
                t.detach();
            }
        }
    }

    const download_result = result catch |err| {
        log.info("video_download: not downloading {s} for chat {s}: {t}", .{ url, native_chat_id, err });
        const error_text = "❌ Couldn't download that video — it may be private, age-restricted, geo-blocked, or too large.";
        if (placeholder_id) |pid| {
            if (connector.editMessage(a, native_chat_id, pid, error_text)) |_| {
                log.info("video_download: failure notice edited into placeholder for chat {s}", .{native_chat_id});
            } else |edit_err| {
                log.warn("video_download: editing failure notice into placeholder failed for chat {s}: {t}, sending a new message instead", .{ native_chat_id, edit_err });
                connector.sendMessage(a, native_chat_id, error_text, reply_to);
            }
        } else {
            connector.sendMessage(a, native_chat_id, error_text, reply_to);
        }
        return;
    };
    defer a.free(download_result.bytes);
    defer a.free(download_result.file_name);

    if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
        log.warn("video_download: failed to delete placeholder for chat {s}: {t}", .{ native_chat_id, err });
    };

    if (quality == .lossy and connector.vtable.sendVideo != null) {
        connector.sendVideo(a, native_chat_id, download_result.bytes, download_result.file_name, null);
        log.info("video_download: sent {s} ({d} bytes) as a video to chat {s}", .{ download_result.file_name, download_result.bytes.len, native_chat_id });
    } else {
        connector.sendDocument(a, native_chat_id, download_result.bytes, download_result.file_name, null);
        log.info("video_download: sent {s} ({d} bytes) as a file to chat {s}", .{ download_result.file_name, download_result.bytes.len, native_chat_id });
    }
}

/// How far back `/summary` looks when no window is given.
const default_summary_hours: i64 = 24;
/// Hard ceiling, matching `catch_me_up`'s own (2 weeks) so the two
/// summarization surfaces can't disagree about what "too much history" is.
const max_summary_hours: i64 = 24 * 14;

/// `/summary [hours]`, composing
/// `digest.summarizeWindow`.
fn handleSummaryCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    now: i64,
    max_message_len: usize,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/summary".len..], " ");
    const hours = if (arg.len == 0) default_summary_hours else std.fmt.parseInt(i64, arg, 10) catch {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /summary [hours] — e.g. /summary 3 for the last 3 hours (default 24, max 336).");
        return;
    };
    if (hours < 1 or hours > max_summary_hours) {
        reply(connector, a, msg.chat_id, msg.message_id, "Pick a window between 1 and 336 hours.");
        return;
    }

    const summary = digest.summarizeWindow(llm_provider, a, tool_ctx, pool, chat_id, hours, now) catch |err| {
        log.err("summary: generate failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, msg.chat_id, "Couldn't summarize this chat just now.", msg.message_id);
        return;
    };
    sendTextOrFile(connector, a, msg.chat_id, summary, msg.message_id, max_message_len, "summary.txt");
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
    const pending = reminders.listPending(pool, a, chat_id, .reminder) catch |err| {
        log.err("reminders: list failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't load reminders, try again.", reply_to);
        return;
    };
    connector.sendMessage(a, native_chat_id, formatPendingReminders(a, pool, pending, now), reply_to);
}

/// True when this `/note` is really "save my voice message as a note".
fn isVoiceNoteRequest(kind: ?iface.AttachmentKind, arg: []const u8) bool {
    const k = kind orelse return false;
    if (k != .voice) return false;
    return arg.len == 0 or std.mem.eql(u8, arg, "add");
}

test "isVoiceNoteRequest: a voice attachment with a bare /note (or /note add) is a voice note" {
    try std.testing.expect(isVoiceNoteRequest(.voice, ""));
    try std.testing.expect(isVoiceNoteRequest(.voice, "add"));
}

test "isVoiceNoteRequest: /note with real text is a normal note even on a voice message" {
    // Someone who captions a voice message "/note add buy milk" meant the
    // text, not the audio -- the explicit words win over the attachment.
    try std.testing.expect(!isVoiceNoteRequest(.voice, "add buy milk"));
    try std.testing.expect(!isVoiceNoteRequest(.voice, "list"));
    try std.testing.expect(!isVoiceNoteRequest(.voice, "delete 3"));
}

test "isVoiceNoteRequest: only voice attachments qualify" {
    // A photo or PDF has no audio to transcribe; those keep the old
    // usage-string behaviour rather than silently doing nothing.
    try std.testing.expect(!isVoiceNoteRequest(.photo, ""));
    try std.testing.expect(!isVoiceNoteRequest(.document, ""));
    try std.testing.expect(!isVoiceNoteRequest(.audio, ""));
    try std.testing.expect(!isVoiceNoteRequest(.video, ""));
    try std.testing.expect(!isVoiceNoteRequest(null, ""));
}

/// Transcribes a voice message and stores the transcript as a note.
fn handleVoiceNote(
    connector: iface.Connector,
    a: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    tool_ctx: tool_registry.ToolContext,
    chat_id: i64,
    identity_id: i64,
    now: i64,
    msg: iface.Message,
) void {
    if (!feature_flags.isEnabled(pool, "voice_transcription")) {
        reply(connector, a, msg.chat_id, msg.message_id, "Voice transcription is turned off, so I can't turn that into a note.");
        return;
    }
    const whisper_url = config.whisper_url orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "No transcription server is configured, so I can't turn a voice message into a note. Send /note add <text> instead.");
        return;
    };
    const path = tool_ctx.attachment_path orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "I couldn't get hold of that audio, try sending it again.");
        return;
    };

    // Sent only once the checks above have passed, so a misconfiguration never
    // leaves a "Transcribing…" message stranded.
    const placeholder_id = connector.sendMessageReturningId(a, msg.chat_id, "🎙️ Transcribing your voice note…", msg.message_id) catch |err| blk: {
        log.warn("voice note: couldn't send a placeholder for chat {s}: {t}", .{ msg.chat_id, err });
        break :blk null;
    };

    const transcript = transcribe.transcribe(a, io, whisper_url, config.tmp_dir, path) catch |err| {
        log.warn("voice note: transcription failed for chat {s}: {t}", .{ msg.chat_id, err });
        settleVoiceNote(connector, a, msg, placeholder_id, "Transcription failed, so I didn't save a note. Try again, or use /note add <text>.");
        return;
    };
    if (transcript.len == 0) {
        settleVoiceNote(connector, a, msg, placeholder_id, "I couldn't make out any speech in that, so I didn't save a note.");
        return;
    }

    // A typed `/note` rejects over-long text so the sender can shorten it.
    const stored = truncateUtf8(transcript, max_note_text_len);
    const was_truncated = stored.len < transcript.len;

    const id = notes.create(pool, chat_id, identity_id, stored, now) catch |err| {
        log.err("voice note: failed to create note for chat {d}: {t}", .{ chat_id, err });
        settleVoiceNote(connector, a, msg, placeholder_id, "I transcribed that but couldn't save the note, try again.");
        return;
    };

    const confirm = std.fmt.allocPrint(a, "{s}Note #{d} saved: {s}", .{
        if (was_truncated) "(transcript was long, so I trimmed it) " else "",
        id,
        stored,
    }) catch return;
    settleVoiceNote(connector, a, msg, placeholder_id, confirm);
}

/// Replaces the "Transcribing…" placeholder with the final outcome.
fn settleVoiceNote(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, placeholder_id: ?[]const u8, text: []const u8) void {
    if (placeholder_id) |pid| {
        if (connector.editMessage(a, msg.chat_id, pid, text)) |_| {
            return;
        } else |err| {
            log.warn("voice note: couldn't edit placeholder in chat {s}: {t}", .{ msg.chat_id, err });
        }
    }
    connector.sendMessage(a, msg.chat_id, text, msg.message_id);
}

const max_note_text_len = 1000;

/// `/note add <text>` / `/note delete <id>`.
fn handleNoteCommand(connector: iface.Connector, a: std.mem.Allocator, io: Io, config: *const config_mod.Config, pool: *store_pool.PgPool, tool_ctx: tool_registry.ToolContext, chat_id: i64, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /note add <text>, /note list, or /note delete <id>";
    const arg = std.mem.trim(u8, text["/note".len..], " ");

    // Deferred voice notes: `/note` sent as the *caption* of a voice message
    // means "transcribe this and save it".
    if (isVoiceNoteRequest(if (msg.attachment) |att| att.kind else null, arg)) {
        handleVoiceNote(connector, a, io, config, pool, tool_ctx, chat_id, identity_id, now, msg);
        return;
    }

    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        handleNotesList(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "delete")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /note delete <id> (see /notes for ids).");
            return;
        };
        const note = (notes.get(pool, a, id) catch |err| {
            log.err("note: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that note, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No note with that id.");
            return;
        };
        if (note.chat_id != chat_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "No note with that id.");
            return;
        }
        if (note.identity_id != identity_id and !auth.isOwner(config, connector.platform(), msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever added that note (or the owner) can delete it.");
            return;
        }
        notes.delete(pool, id) catch |err| {
            log.err("note: delete failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't delete that note, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Note deleted.");
        return;
    }

    if (!std.mem.eql(u8, sub, "add")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const note_text = std.mem.trim(u8, it.rest(), " ");
    if (note_text.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    if (note_text.len > max_note_text_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That note is too long (max 1000 bytes).");
        return;
    }

    const id = notes.create(pool, chat_id, identity_id, note_text, now) catch |err| {
        log.err("note: failed to create note for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that note, try again.");
        return;
    };
    const confirmation = std.fmt.allocPrint(a, "Note #{d} added.", .{id}) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn handleNotesList(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const listed = notes.listForChat(pool, a, chat_id) catch |err| {
        log.err("notes: list failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't load notes, try again.", reply_to);
        return;
    };
    connector.sendMessage(a, native_chat_id, formatAllNotes(a, listed), reply_to);
}

/// `/keyword add <word>` / `/keyword list` / `/keyword remove <id>` — see
/// .
fn handleKeywordCommand(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /keyword add <word>, /keyword list, or /keyword remove <id>";
    const arg = std.mem.trim(u8, text["/keyword".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        const listed = keyword_alerts.listForChat(pool, a, chat_id) catch |err| {
            log.err("keyword: list failed for chat {d}: {t}", .{ chat_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't load keyword alerts, try again.");
            return;
        };
        connector.sendMessage(a, msg.chat_id, formatKeywordAlerts(a, listed), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "remove")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /keyword remove <id> (see /keyword list for ids).");
            return;
        };
        const alert = (keyword_alerts.get(pool, a, id) catch |err| {
            log.err("keyword: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look that up, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No keyword alert with that id.");
            return;
        };
        if (alert.chat_id != chat_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "No keyword alert with that id.");
            return;
        }
        if (alert.identity_id != identity_id and !auth.isOwner(config, connector.platform(), msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever added that alert (or the owner) can remove it.");
            return;
        }
        keyword_alerts.remove(pool, id) catch |err| {
            log.err("keyword: remove failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't remove that, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Keyword alert removed.");
        return;
    }

    if (!std.mem.eql(u8, sub, "add")) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    const keyword = std.mem.trim(u8, it.rest(), " ");
    if (keyword.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    if (keyword.len > max_keyword_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That's too long for a keyword (max 100 bytes).");
        return;
    }

    const result = keyword_alerts.add(pool, a, chat_id, identity_id, keyword, now) catch |err| {
        log.err("keyword: failed to add for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that, try again.");
        return;
    };
    switch (result) {
        .already_tracked => reply(connector, a, msg.chat_id, msg.message_id, "That keyword is already tracked in this chat."),
        .added => |id| {
            const confirmation = std.fmt.allocPrint(a, "Keyword alert #{d} added -- I'll flag it here whenever it comes up.", .{id}) catch return;
            connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        },
    }
}

const max_keyword_len = 100;

fn formatKeywordAlerts(a: std.mem.Allocator, listed: []const keyword_alerts.KeywordAlert) []const u8 {
    if (listed.len == 0) return "No keyword alerts yet. Add one with /keyword add <word>.";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Keyword alerts:\n", .{}) catch return "";
    for (listed) |k| w.print("  #{d} {s}\n", .{ k.id, k.keyword }) catch return "";
    return buf.writer.buffered();
}

/// Scans one incoming message's text against `chat_id`'s tracked keyword
/// alerts.
fn checkKeywordAlerts(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) void {
    if (text.len == 0) return;
    const tracked = keyword_alerts.listForChat(pool, a, chat_id) catch |err| {
        log.err("keyword: scan lookup failed for chat {d}: {t}", .{ chat_id, err });
        return;
    };
    if (tracked.len == 0) return;

    var matches: std.ArrayList([]const u8) = .empty;
    for (tracked) |k| {
        if (containsWordIgnoreCase(text, k.keyword)) matches.append(a, k.keyword) catch return;
    }
    if (matches.items.len == 0) return;

    const sender = if (msg.identity) |identity| identity.display_name else msg.username orelse msg.user_id;
    var buf: std.Io.Writer.Allocating = .init(a);
    buf.writer.print("🔔 Keyword alert ({s}) -- mentioned by {s}", .{ std.mem.join(a, ", ", matches.items) catch return, sender }) catch return;
    connector.sendMessage(a, msg.chat_id, buf.writer.buffered(), msg.message_id);
}

/// `/memory list` / `/memory forget <id>`.
fn handleMemoryCommand(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, identity_id: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /memory list, or /memory forget <id>";
    const arg = std.mem.trim(u8, text["/memory".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();

    if (std.mem.eql(u8, sub, "list")) {
        const listed = facts.listForIdentity(pool, a, identity_id) catch |err| {
            log.err("memory: list failed for identity {d}: {t}", .{ identity_id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't load memories, try again.");
            return;
        };
        connector.sendMessage(a, msg.chat_id, formatMemories(a, listed), msg.message_id);
        return;
    }

    if (std.mem.eql(u8, sub, "forget")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /memory forget <id> (see /memory list for ids).");
            return;
        };
        const mem = (facts.get(pool, a, id) catch |err| {
            log.err("memory: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that memory, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No memory with that id.");
            return;
        };
        if (mem.identity_id != identity_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only the person that memory belongs to can forget it.");
            return;
        }
        facts.forget(pool, id) catch |err| {
            log.err("memory: forget failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't forget that memory, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Memory forgotten.");
        return;
    }

    reply(connector, a, msg.chat_id, msg.message_id, usage);
}

/// `/alert <crypto|weather|aqi> <subject> <above|below> <threshold>` sets a
/// standing alert; `/alert cancel <id>` cancels one.
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

/// `/watch <feed_url>` adds an RSS/Atom watch for this chat.
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
/// bypassing its `check_interval_seconds` wait.
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
    // A single-element connector list is enough here.
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

/// Direct entry point to `convert_file`.
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
/// Postgres-backed reminders for one specific message's chat/sender.
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
        const pending = try reminders.listPending(self.pool, allocator, self.chat_id, .reminder);
        return formatPendingReminders(allocator, self.pool, pending, self.now);
    }
};

fn formatAllNotes(a: std.mem.Allocator, listed: []const notes.Note) []const u8 {
    if (listed.len == 0) return "No notes yet. Add one with /note add <text> (or just ask).";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Notes:\n", .{}) catch return "";
    for (listed) |n| w.print("  #{d} {s}\n", .{ n.id, n.text }) catch return "";
    return buf.writer.buffered();
}

/// Wires the `set_note` LLM tool (see `tools/set_note.zig`) to real Postgres-
/// backed notes for one specific message's chat/sender.
const NoteToolAdapter = struct {
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    is_owner: bool,
    now: i64,

    fn sink(self: *NoteToolAdapter) tool_registry.NoteSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.NoteSink.VTable = .{
        .create = createFn,
        .delete = deleteFn,
        .listAll = listAllFn,
    };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!i64 {
        const self: *NoteToolAdapter = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return notes.create(self.pool, self.chat_id, self.identity_id, text, self.now);
    }

    fn deleteFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!tool_registry.NoteSink.DeleteResult {
        const self: *NoteToolAdapter = @ptrCast(@alignCast(ptr));
        const note = (try notes.get(self.pool, allocator, id)) orelse return .not_found;
        if (note.chat_id != self.chat_id) return .not_found;
        if (note.identity_id != self.identity_id and !self.is_owner) return .not_authorized;
        try notes.delete(self.pool, id);
        return .deleted;
    }

    fn listAllFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *NoteToolAdapter = @ptrCast(@alignCast(ptr));
        const listed = try notes.listForChat(self.pool, allocator, self.chat_id);
        return formatAllNotes(allocator, listed);
    }
};

/// Wires the `set_expense` LLM tool (see `tools/set_expense.zig`) to real
/// Postgres-backed expenses.
const ExpenseToolAdapter = struct {
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    is_owner: bool,
    now: i64,

    fn sink(self: *ExpenseToolAdapter) tool_registry.ExpenseSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.ExpenseSink.VTable = .{
        .create = createFn,
        .delete = deleteFn,
        .listAll = listAllFn,
    };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, amount_cents: i64, category: []const u8, description: ?[]const u8) anyerror!i64 {
        const self: *ExpenseToolAdapter = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return expenses.create(self.pool, self.chat_id, self.identity_id, amount_cents, default_currency, category, description, self.now);
    }

    fn deleteFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!tool_registry.ExpenseSink.DeleteResult {
        const self: *ExpenseToolAdapter = @ptrCast(@alignCast(ptr));
        const expense = (try expenses.get(self.pool, allocator, id)) orelse return .not_found;
        if (expense.chat_id != self.chat_id) return .not_found;
        if (expense.identity_id != self.identity_id and !self.is_owner) return .not_authorized;
        try expenses.delete(self.pool, id);
        return .deleted;
    }

    fn listAllFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *ExpenseToolAdapter = @ptrCast(@alignCast(ptr));
        const listed = try expenses.listForChat(self.pool, allocator, self.chat_id, null, null, 20);
        return formatExpenseList(allocator, listed);
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
/// message's chat/sender.
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
/// to the local roster.
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

/// Wires the `catch_me_up` LLM tool (see `tools/catch_me_up.zig`) to this
/// chat's own logged history.
const ChatHistoryToolAdapter = struct {
    pool: *store_pool.PgPool,
    chat_id: i64,
    now: i64,

    fn sink(self: *ChatHistoryToolAdapter) tool_registry.ChatHistorySink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.ChatHistorySink.VTable = .{
        .recentSince = recentSinceFn,
    };

    fn recentSinceFn(ptr: *anyopaque, allocator: std.mem.Allocator, hours_ago: i64) anyerror![]const u8 {
        const self: *ChatHistoryToolAdapter = @ptrCast(@alignCast(ptr));
        const since_ts = self.now - hours_ago * 3600;
        return messages.recentSinceFormatted(self.pool, allocator, self.chat_id, since_ts, catch_me_up_row_limit);
    }
};

/// Hard row ceiling for `catch_me_up`, independent of its own hour-window
/// cap.
const catch_me_up_row_limit = 2000;

/// Hard cap on how many chats `list_personal_chats` hands the model in one
/// call.
const list_personal_chats_limit = 60;

/// Backs the personal-account (TDLib) LLM tools.
const PersonalAccountToolAdapter = struct {
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pool: *store_pool.PgPool,
    io: Io,

    fn sink(self: *PersonalAccountToolAdapter) tool_registry.PersonalAccountSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.PersonalAccountSink.VTable = .{
        .summarizeUnread = summarizeUnreadFn,
        .listChats = listChatsFn,
        .sendMessage = sendMessageFn,
        .sendReply = sendReplyFn,
    };

    fn summarizeUnreadFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, all: bool) anyerror![]const u8 {
        const self: *PersonalAccountToolAdapter = @ptrCast(@alignCast(ptr));
        const conn = self.telegram_user orelse return "The personal-account connector isn't configured on this deployment.";
        if (conn.authState() != .ready) return "The personal account isn't logged in yet.";
        return chat_summary.describeUnreadForModel(conn, self.pool, allocator, self.io, chat_query, all);
    }

    fn listChatsFn(ptr: *anyopaque, allocator: std.mem.Allocator, query: ?[]const u8) anyerror![]const u8 {
        const self: *PersonalAccountToolAdapter = @ptrCast(@alignCast(ptr));
        const conn = self.telegram_user orelse return "The personal-account connector isn't configured on this deployment.";
        if (conn.authState() != .ready) return "The personal account isn't logged in yet.";

        const chat_list = if (query) |q|
            try chat_summary.searchChatsByTitle(conn, allocator, q)
        else
            try chat_summary.allChatsSortedByTitle(conn, allocator);
        return chat_summary.formatChatList(allocator, chat_list, list_personal_chats_limit);
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, message: []const u8) anyerror![]const u8 {
        const self: *PersonalAccountToolAdapter = @ptrCast(@alignCast(ptr));
        const conn = self.telegram_user orelse return "The personal-account connector isn't configured on this deployment.";
        if (conn.authState() != .ready) return "The personal account isn't logged in yet.";

        const resolution = try chat_summary.resolveChat(conn, allocator, chat_query);
        switch (resolution) {
            .none => return "No known chat matches that — try list_personal_chats first to find the right one.",
            .ambiguous => |matches| {
                var out: Io.Writer.Allocating = .init(allocator);
                try out.writer.writeAll("That matches more than one chat — ask which one, then retry with its id:\n");
                for (matches) |m| try out.writer.print("{s} (id {s})\n", .{ m.title, m.native_chat_id });
                return out.writer.buffered();
            },
            .one => |m| {
                conn.connector().sendMessage(allocator, m.native_chat_id, message, null);
                return std.fmt.allocPrint(allocator, "Sent to \"{s}\".", .{m.title});
            },
        }
    }

    fn sendReplyFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, native_message_id: []const u8, message: []const u8) anyerror![]const u8 {
        const self: *PersonalAccountToolAdapter = @ptrCast(@alignCast(ptr));
        const conn = self.telegram_user orelse return "The personal-account connector isn't configured on this deployment.";
        if (conn.authState() != .ready) return "The personal account isn't logged in yet.";

        const resolution = try chat_summary.resolveChat(conn, allocator, chat_query);
        switch (resolution) {
            .none => return "No known chat matches that — try list_personal_chats first to find the right one.",
            .ambiguous => |matches| {
                var out: Io.Writer.Allocating = .init(allocator);
                try out.writer.writeAll("That matches more than one chat — ask which one, then retry with its id:\n");
                for (matches) |m| try out.writer.print("{s} (id {s})\n", .{ m.title, m.native_chat_id });
                return out.writer.buffered();
            },
            .one => |m| {
                conn.connector().sendMessage(allocator, m.native_chat_id, message, native_message_id);
                return std.fmt.allocPrint(allocator, "Replied to message {s} in \"{s}\".", .{ native_message_id, m.title });
            },
        }
    }
};

const MonitoringToolAdapter = struct {
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pool: *store_pool.PgPool,
    owner_identity_id: i64,

    fn sink(self: *MonitoringToolAdapter) tool_registry.MonitoringSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.MonitoringSink.VTable = .{ .setImportance = setImportanceFn, .setDefaultImportance = setDefaultImportanceFn };

    fn setImportanceFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, importance: []const u8) anyerror![]const u8 {
        const self: *MonitoringToolAdapter = @ptrCast(@alignCast(ptr));
        const conn = self.telegram_user orelse return "The personal-account connector isn't configured on this deployment.";
        if (conn.authState() != .ready) return "The personal account isn't logged in yet.";

        const parsed_importance = std.meta.stringToEnum(chat_settings.MonitorImportance, importance) orelse
            return "importance must be one of: low, normal, high, off.";

        const resolution = try chat_summary.resolveChat(conn, allocator, chat_query);
        switch (resolution) {
            .none => return "No known chat matches that — try list_personal_chats first to find the right one.",
            .ambiguous => |matches| {
                var out: Io.Writer.Allocating = .init(allocator);
                try out.writer.writeAll("That matches more than one chat — ask which one, then retry with its id:\n");
                for (matches) |m| try out.writer.print("{s} (id {s})\n", .{ m.title, m.native_chat_id });
                return out.writer.buffered();
            },
            .one => |m| {
                // Monitoring is forward-looking (a subscription to future messages), not a
                // report over history that already exists.
                const chat_id = try chats.upsertChat(self.pool, .telegram_user, m.native_chat_id, null, m.title);
                try chat_settings.setMonitorImportance(self.pool, chat_id, parsed_importance);
                if (parsed_importance == .off) {
                    return std.fmt.allocPrint(allocator, "Stopped monitoring \"{s}\".", .{m.title});
                }
                // The only real consequence of subscribing a chat with no recorded history
                // yet.
                if (!messages.hasAny(self.pool, chat_id)) {
                    return std.fmt.allocPrint(
                        allocator,
                        "Now monitoring \"{s}\" at {s} importance. Note: Warden hasn't recorded any messages from this chat yet, so a bulletin won't have anything from it until a new one arrives.",
                        .{ m.title, @tagName(parsed_importance) },
                    );
                }
                return std.fmt.allocPrint(allocator, "Now monitoring \"{s}\" at {s} importance.", .{ m.title, @tagName(parsed_importance) });
            },
        }
    }

    fn setDefaultImportanceFn(ptr: *anyopaque, allocator: std.mem.Allocator, importance: []const u8) anyerror![]const u8 {
        const self: *MonitoringToolAdapter = @ptrCast(@alignCast(ptr));
        const parsed_importance = std.meta.stringToEnum(chat_settings.MonitorImportance, importance) orelse
            return "importance must be one of: low, normal, high, off.";
        try user_settings.setMonitorAllDefault(self.pool, self.owner_identity_id, parsed_importance);
        return if (parsed_importance != .off)
            std.fmt.allocPrint(allocator, "Now monitoring every chat by default at {s} importance (a chat with its own setting keeps that instead).", .{@tagName(parsed_importance)})
        else
            std.fmt.allocPrint(allocator, "Default monitoring is off again -- only chats explicitly set with set_chat_monitoring are still monitored.", .{});
    }
};

const BulletinToolAdapter = struct {
    pool: *store_pool.PgPool,
    owner_identity_id: i64,
    now: i64,

    fn sink(self: *BulletinToolAdapter) tool_registry.BulletinSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.BulletinSink.VTable = .{ .generate = generateFn };

    fn generateFn(ptr: *anyopaque, allocator: std.mem.Allocator, hours: ?i64) anyerror![]const u8 {
        const self: *BulletinToolAdapter = @ptrCast(@alignCast(ptr));
        return bulletin.gather(self.pool, allocator, self.owner_identity_id, hours, self.now);
    }
};

const memory_search_limit = 5;

fn formatMemories(a: std.mem.Allocator, listed: []const facts.Memory) []const u8 {
    if (listed.len == 0) return "No memories yet. I'll remember things worth keeping as we talk.";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Memories:\n", .{}) catch return "";
    for (listed) |m| w.print("  #{d} {s}\n", .{ m.id, m.text }) catch return "";
    return buf.writer.buffered();
}

/// Wires the `remember_memory` LLM tool (see `tools/remember_memory.zig`) to
/// real Postgres-backed memories for one specific message's sender.
const MemoryToolAdapter = struct {
    pool: *store_pool.PgPool,
    identity_id: i64,
    now: i64,
    embeddings_client: ?*embeddings.EmbeddingsClient,

    fn sink(self: *MemoryToolAdapter) tool_registry.MemorySink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.MemorySink.VTable = .{
        .create = createFn,
        .forget = forgetFn,
        .listAll = listAllFn,
    };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!i64 {
        const self: *MemoryToolAdapter = @ptrCast(@alignCast(ptr));
        // An embedding is an enhancement, not a prerequisite.
        const vector: ?[]const f32 = if (self.embeddings_client) |client|
            client.embed(allocator, text) catch |err| blk: {
                log.warn("memory: embedding failed, storing without a vector (semantic recall will skip it): {t}", .{err});
                break :blk null;
            }
        else
            null;
        return facts.remember(self.pool, allocator, self.identity_id, text, vector, self.now);
    }

    fn forgetFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!tool_registry.MemorySink.ForgetResult {
        const self: *MemoryToolAdapter = @ptrCast(@alignCast(ptr));
        const mem = (try facts.get(self.pool, allocator, id)) orelse return .not_found;
        if (mem.identity_id != self.identity_id) return .not_authorized;
        try facts.forget(self.pool, id);
        return .forgotten;
    }

    fn listAllFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *MemoryToolAdapter = @ptrCast(@alignCast(ptr));
        const listed = try facts.listForIdentity(self.pool, allocator, self.identity_id);
        return formatMemories(allocator, listed);
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
/// platform.
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

        // The only difference between the two kinds at delivery time is the framing
        // and, for announcements, the optional pin -- see `reminders.Kind`.
        const text = switch (r.kind) {
            .reminder => std.fmt.allocPrint(a, "⏰ Reminder: {s}", .{r.message}) catch continue,
            .announcement => std.fmt.allocPrint(a, "📣 {s}", .{r.message}) catch continue,
        };
        if (r.kind == .announcement and chat_settings.getAutopinAnnouncements(pool, r.chat_id)) {
            sendAndPinAnnouncement(connector, a, r.native_chat_id, text);
        } else {
            connector.sendMessage(a, r.native_chat_id, text, null);
        }

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

/// Reverts a timed `/permission <duration> ...` grant/revoke back to the
/// default (unrestricted) bitmask once its `expires_at` passes.
fn checkAndRevertExpiredPermissions(
    connectors: []const iface.Connector,
    gpa: std.mem.Allocator,
    pool: *store_pool.PgPool,
    now: i64,
) void {
    const expired = member_permissions.listExpired(pool, gpa, now) catch |err| {
        log.err("permission: failed to query expired grants: {t}", .{err});
        return;
    };
    defer {
        for (expired) |e| {
            gpa.free(e.native_chat_id);
            gpa.free(e.native_user_id);
        }
        gpa.free(expired);
    }

    for (expired) |e| {
        if (findConnector(connectors, e.platform)) |connector| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            connector.restrictChatMemberPermissions(a, e.native_chat_id, e.native_user_id, iface.MemberPermission.all, 0) catch |err| {
                if (err != error.Unsupported) {
                    log.warn("permission: failed to re-apply default bitmask for {s} in chat {s}: {t}", .{ e.native_user_id, e.native_chat_id, err });
                }
            };
        } else {
            log.warn("permission: no active connector for platform {s}, reverting stored bitmask anyway for chat {d}", .{ @tagName(e.platform), e.chat_id });
        }

        member_permissions.revert(pool, e.chat_id, e.identity_id) catch |err| {
            log.err("permission: failed to clear expired grant for identity {d} in chat {d}: {t}", .{ e.identity_id, e.chat_id, err });
        };
    }
}

/// Posts a scheduled announcement into a chat that has `/autopin on` and pins
/// it, degrading rather than failing at each step that can go wrong.
fn sendAndPinAnnouncement(connector: iface.Connector, a: std.mem.Allocator, native_chat_id: []const u8, text: []const u8) void {
    const sent_id = connector.sendMessageReturningId(a, native_chat_id, text, null) catch |err| {
        log.err("announce: send failed for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };
    const id = sent_id orelse {
        connector.sendMessage(a, native_chat_id, text, null);
        return;
    };
    connector.pinMessage(a, native_chat_id, id) catch |err| {
        log.warn("announce: posted in chat {s} but couldn't pin it ({t}) — do I have pin permission there?", .{ native_chat_id, err });
    };
}

/// Housekeeping retention sweep: hard-deletes any chat that's been marked
/// left.
const chat_retention_seconds: i64 = 30 * 24 * 3600;

fn checkAndPurgeLeftChats(pool: *store_pool.PgPool, now: i64) void {
    const purged = chats.deleteLeftBefore(pool, now - chat_retention_seconds) catch |err| {
        log.err("housekeeping: failed to purge left chats: {t}", .{err});
        return;
    };
    if (purged > 0) log.notice("housekeeping: purged {d} chat(s) left over 30 days ago", .{purged});
}

/// Shown while waiting on the model with nothing more specific to show (see
/// `TickerState`/`tickerLoop`).
const thinking_text = "🤔 Thinking...";
/// Shown by `tickerLoop` once `TickerState.cancelled` flips, overriding
/// whatever status was showing.
const cancelling_text = "🛑 Cancelling...";
/// Telegram's edits are throttled to roughly 1/sec per chat in practice;
/// this keeps a comfortable margin under that.
const ticker_interval_ms: i64 = 1200;

/// Shared between `replyWithAnswer` (which owns it), the ticker task, and the
/// `toolcall.Progress` callback that updates it.
const TreeEntry = union(enum) {
    /// `input_digest` is the fingerprint of the most recent call's arguments (see
    /// `toolcall.hashToolInput`).
    tool: struct { name: []const u8, input_digest: u64, count: u32 },
    retry: struct { attempt: u32, max: u32 },
};

/// Per-tool icon for the progress tree, falling back to the generic wrench
/// for anything not listed (including a tool added later and not mapped here
/// yet — a missing icon should never be a missing line).
fn toolEmoji(name: []const u8) []const u8 {
    const table = .{
        // Reaching out to the network
        .{ "web_search", "🌐" },
        .{ "scrape_site", "🪒" },
        .{ "fetch_url", "🔗" },
        .{ "hackernews_search", "📰" },
        // Asking another model
        .{ "ask_delegate", "🧠" },
        .{ "delegate_generate_image", "🎨" },
        // Reference lookups
        .{ "dictionary", "📖" },
        .{ "urban_dictionary", "🗣" },
        .{ "calculator", "🧮" },
        .{ "currency_convert", "💱" },
        .{ "crypto_price", "🪙" },
        .{ "weather", "🌦" },
        .{ "air_quality", "🌫" },
        // Producing something
        .{ "qr_code", "🔳" },
        .{ "draw_diagram", "📐" },
        .{ "word_cloud", "☁️" },
        .{ "create_poll", "📊" },
        .{ "convert_file", "🔁" },
        .{ "begin_file_conversion", "🔁" },
        // Remembering / recalling
        .{ "remember_memory", "🧷" },
        .{ "set_note", "📝" },
        .{ "catch_me_up", "📚" },
        .{ "get_bulletin", "🗞" },
        // Scheduling and watching
        .{ "set_reminder", "⏰" },
        .{ "set_alert", "🔔" },
        .{ "set_expense", "💰" },
        // The personal account
        .{ "list_personal_chats", "👥" },
        .{ "send_personal_message", "✉️" },
        .{ "reply_to_message", "↩️" },
        .{ "summarize_unread_chat", "📬" },
        .{ "set_chat_monitoring", "👀" },
        .{ "set_default_chat_monitoring", "👀" },
        .{ "find_chat_member", "🔎" },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return "🔧";
}

const TickerState = struct {
    io: Io,
    allocator: std.mem.Allocator,
    /// Cooperative stop signal — `replyWithAnswer` sets this once it's done with
    /// the model call; `tickerLoop` checks it instead of relying on
    /// `Future.cancel()`/preemption.
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by `tickerLoop` right before it returns — `replyWithAnswer` polls this
    /// (bounded) instead of blocking on `std.Thread.join()`.
    done: std.atomic.Value(bool) = .init(false),
    /// Flipped by a "🛑 Cancel" button press, routed through
    /// `features/cancel_request.zig`'s `InFlightRequests` from whichever
    /// `WorkerPool` worker is handling that press — a different one than
    /// whatever's running this request.
    cancelled: std.atomic.Value(bool) = .init(false),
    /// This platform's hard cap on a single message's text (see
    /// `effectiveMaxMessageLength`).
    max_len: usize,
    mutex: Io.Mutex = .init,
    /// What's happened this request, oldest first — rendered as tree-branch child
    /// lines under `thinking_text` by `renderTree`.
    tool_history: std.ArrayList(TreeEntry) = .empty,
    /// Null = show the generic thinking animation; set = show this.
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

    /// Builds `thinking_text` followed by one tree-branch child line per entry in
    /// `tool_history` so far ("├── 🔧 Using x..."/"└── 🔧 Using y...").
    fn renderTree(self: *TickerState, trailing: ?[]const u8) []const u8 {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(self.allocator, thinking_text) catch return thinking_text;
        const child_count = self.tool_history.items.len + @as(usize, if (trailing != null) 1 else 0);
        var shown: usize = 0;
        for (self.tool_history.items) |entry| {
            shown += 1;
            const branch: []const u8 = if (shown == child_count) "\n└── " else "\n├── ";
            buf.appendSlice(self.allocator, branch) catch return thinking_text;
            switch (entry) {
                .tool => |t| {
                    buf.appendSlice(self.allocator, toolEmoji(t.name)) catch return thinking_text;
                    buf.appendSlice(self.allocator, " Using ") catch return thinking_text;
                    buf.appendSlice(self.allocator, t.name) catch return thinking_text;
                    // Only once the model has actually called it more than once with *different*
                    // arguments — a repeat of the identical call never gets here.
                    if (t.count > 1) {
                        const suffix = std.fmt.allocPrint(self.allocator, " (x{d})", .{t.count}) catch return thinking_text;
                        buf.appendSlice(self.allocator, suffix) catch return thinking_text;
                    }
                    buf.appendSlice(self.allocator, "...") catch return thinking_text;
                },
                .retry => |r| {
                    const line = std.fmt.allocPrint(self.allocator, "🔄 API Error: Retrying ({d}/{d})", .{ r.attempt, r.max }) catch return thinking_text;
                    buf.appendSlice(self.allocator, line) catch return thinking_text;
                },
            }
        }
        if (trailing) |t| {
            buf.appendSlice(self.allocator, "\n└── ") catch return thinking_text;
            buf.appendSlice(self.allocator, t) catch return thinking_text;
        }
        const rendered = buf.toOwnedSlice(self.allocator) catch return thinking_text;
        return truncateUtf8(rendered, self.max_len);
    }
};

test "toolEmoji maps known tools and falls back to the wrench for anything else" {
    try std.testing.expectEqualStrings("🌐", toolEmoji("web_search"));
    try std.testing.expectEqualStrings("🪒", toolEmoji("scrape_site"));
    try std.testing.expectEqualStrings("🧠", toolEmoji("ask_delegate"));
    // Not in the table (and a tool added later won't be either) — must
    // still render a line, just with the generic icon.
    try std.testing.expectEqualStrings("🔧", toolEmoji("some_future_tool"));
}

/// A `TickerState` wired to an arena, for exercising `onProgressEvent` +
/// `renderTree` without a connector or a live request.
fn testTicker(arena: std.mem.Allocator) TickerState {
    return .{ .io = std.testing.io, .allocator = arena, .max_len = 4096 };
}

test "progress tree: an identical repeat of the same tool call adds nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var state = testTicker(arena_state.allocator());

    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 7 } });
    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 7 } });

    // The reported bug: several web_search lines stacked under one message.
    try std.testing.expectEqual(@as(usize, 1), state.tool_history.items.len);
    const rendered = state.renderTree(null);
    try std.testing.expectEqualStrings("🤔 Thinking...\n└── 🌐 Using web_search...", rendered);
}

test "progress tree: the same tool with different arguments collapses into a count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var state = testTicker(arena_state.allocator());

    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 1 } });
    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 2 } });
    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 3 } });

    try std.testing.expectEqual(@as(usize, 1), state.tool_history.items.len);
    try std.testing.expectEqualStrings(
        "🤔 Thinking...\n└── 🌐 Using web_search (x3)...",
        state.renderTree(null),
    );
}

test "progress tree: different tools keep their own lines in call order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var state = testTicker(arena_state.allocator());

    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 1 } });
    onProgressEvent(&state, .{ .tool_use = .{ .name = "scrape_site", .input_digest = 2 } });
    // Back to the first tool: a separate line, not merged across the gap,
    // so the tree still reads in the order things actually happened.
    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 3 } });

    try std.testing.expectEqual(@as(usize, 3), state.tool_history.items.len);
    try std.testing.expectEqualStrings(
        "🤔 Thinking...\n├── 🌐 Using web_search...\n├── 🪒 Using scrape_site...\n└── 🌐 Using web_search...",
        state.renderTree(null),
    );
}

test "progress tree: a retry renders as its own line with the attempt count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var state = testTicker(arena_state.allocator());

    onProgressEvent(&state, .{ .tool_use = .{ .name = "web_search", .input_digest = 1 } });
    onProgressEvent(&state, .{ .retry = .{ .attempt = 1, .max = 3, .err = error.RequestTimedOut } });

    try std.testing.expectEqualStrings(
        "🤔 Thinking...\n├── 🌐 Using web_search...\n└── 🔄 API Error: Retrying (1/3)",
        state.renderTree(null),
    );
}

fn onProgressEvent(ptr: *anyopaque, event: toolcall.Progress.Event) void {
    const state: *TickerState = @ptrCast(@alignCast(ptr));
    switch (event) {
        .thinking => {
            // Fires on every turn, including right after a tool call whose child line is
            // already reflected in `status` (set below, by that same `.tool_use` event).
            if (state.tool_history.items.len == 0) state.setStatus(null);
        },
        .tool_use => |use| {
            // Three cases, per the reported bug (identical web_search lines stacking
            // under one message): * same tool, same arguments as the last entry.
            if (state.tool_history.items.len > 0) {
                const last = &state.tool_history.items[state.tool_history.items.len - 1];
                if (last.* == .tool and std.mem.eql(u8, last.tool.name, use.name)) {
                    if (last.tool.input_digest == use.input_digest) return;
                    last.tool.input_digest = use.input_digest;
                    last.tool.count += 1;
                    state.setStatus(state.renderTree(null));
                    return;
                }
            }
            state.tool_history.append(state.allocator, .{ .tool = .{
                .name = use.name,
                .input_digest = use.input_digest,
                .count = 1,
            } }) catch return;
            state.setStatus(state.renderTree(null));
        },
        .retry => |r| {
            state.tool_history.append(state.allocator, .{ .retry = .{
                .attempt = r.attempt,
                .max = r.max,
            } }) catch return;
            state.setStatus(state.renderTree(null));
        },
        .text => |text_so_far| {
            if (text_so_far.len == 0) return; // nothing to show yet, keep the thinking animation
            state.setStatus(state.renderTree(text_so_far));
        },
    }
}

/// UTF-8-boundary-safe truncation to at most `max_len` bytes.
fn truncateUtf8(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    var end = max_len;
    // `text[end]` is the first byte being cut off; back off while it's a UTF-8
    // continuation byte (`10xxxxxx`).
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

/// Runs on its own real, detached `std.Thread`.
fn tickerLoop(connector: iface.Connector, chat_id: []const u8, message_id: []const u8, state: *TickerState) void {
    defer state.done.store(true, .release);
    var last_sent: []const u8 = thinking_text;
    while (!state.stop.load(.acquire)) {
        Io.sleep(state.io, .fromMilliseconds(ticker_interval_ms), .awake) catch return;
        if (state.stop.load(.acquire)) return;

        const text = if (state.cancelled.load(.acquire)) cancelling_text else (state.getStatus() orelse thinking_text);

        if (!std.mem.eql(u8, text, last_sent)) {
            connector.editMessage(std.heap.page_allocator, chat_id, message_id, text) catch |err| {
                log.warn("ticker: edit failed for chat {s}: {t}", .{ chat_id, err });
            };
            last_sent = text;
        }
    }
}

/// Maps an LLM tool's own `.name` (the function-calling identifier) to the
/// `feature_flags` module key that gates it.
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
        .{ .name = "set_note", .key = "notes" },
        .{ .name = "remember_memory", .key = "memory" },
        .{ .name = "begin_file_conversion", .key = "convert" },
        .{ .name = "convert_file", .key = "convert" },
        .{ .name = "catch_me_up", .key = "messaging_modes" },
        .{ .name = "create_poll", .key = "polls" },
        .{ .name = "set_expense", .key = "finance" },
        .{ .name = "summarize_unread_chat", .key = "messaging_modes" },
        .{ .name = "list_personal_chats", .key = "messaging_modes" },
        .{ .name = "send_personal_message", .key = "messaging_modes" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.key;
    }
    return null;
}

/// `false` for a tool whose `ToolContext` sink is null — the owner-only sinks
/// `processMessageTask` leaves unwired for anyone but the owner.
fn toolSinkPresent(ctx: tool_registry.ToolContext, name: []const u8) bool {
    const personal_account = [_][]const u8{ "summarize_unread_chat", "list_personal_chats", "send_personal_message", "reply_to_message" };
    for (personal_account) |n| {
        if (std.mem.eql(u8, n, name)) return ctx.personal_account != null;
    }
    if (std.mem.eql(u8, name, "set_chat_monitoring") or std.mem.eql(u8, name, "set_default_chat_monitoring")) return ctx.monitoring != null;
    if (std.mem.eql(u8, name, "get_bulletin")) return ctx.bulletin != null;
    return true;
}

/// Filters `tools` against `feature_flags` right before handing them to the
/// model.
fn filterEnabledTools(pool: *store_pool.PgPool, a: std.mem.Allocator, ctx: tool_registry.ToolContext, tools: []const tool_registry.ToolDef) []const tool_registry.ToolDef {
    const out = a.alloc(tool_registry.ToolDef, tools.len) catch return tools;
    var n: usize = 0;
    for (tools) |t| {
        if (!toolSinkPresent(ctx, t.name)) continue;
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
    try std.testing.expectEqualStrings("notes", toolModuleKey("set_note").?);
    try std.testing.expectEqualStrings("memory", toolModuleKey("remember_memory").?);
    try std.testing.expectEqualStrings("messaging_modes", toolModuleKey("catch_me_up").?);
    try std.testing.expectEqualStrings("polls", toolModuleKey("create_poll").?);
    try std.testing.expectEqualStrings("finance", toolModuleKey("set_expense").?);
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

    // `filterEnabledTools` is documented to expect an arena.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = tool_registry.ToolContext{ .allocator = arena.allocator(), .io = std.testing.io };
    const filtered = filterEnabledTools(&pool, arena.allocator(), ctx, &tools);
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings("calculator", filtered[0].name);
    try std.testing.expectEqualStrings("air_quality", filtered[1].name);
}

// AUDIT-2026-09-03 CORE-4: the personal-account, monitoring and bulletin
// tools used to be offered to (and wired for) every asker.
test "filterEnabledTools drops the owner-only tools when their sink isn't wired" {
    const test_support = @import("store/test_support.zig");
    var db = try test_support.openTestDb(std.testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(std.testing.allocator, std.testing.io, &db);
    defer pool.deinitTestWrap();

    const dummy_execute = struct {
        fn call(ctx: tool_registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
            _ = ctx;
            _ = input_json;
            return "";
        }
    }.call;
    const tools = [_]tool_registry.ToolDef{
        .{ .name = "calculator", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "summarize_unread_chat", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "list_personal_chats", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "send_personal_message", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "reply_to_message", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "set_chat_monitoring", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "set_default_chat_monitoring", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
        .{ .name = "get_bulletin", .description = "", .input_schema_json = "{}", .execute = dummy_execute },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = tool_registry.ToolContext{ .allocator = arena.allocator(), .io = std.testing.io };
    const filtered = filterEnabledTools(&pool, arena.allocator(), ctx, &tools);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("calculator", filtered[0].name);
}

/// The "🛑 Cancel" button attached to the thinking/tool-use placeholder — a
/// single fixed choice (nothing to pick between, just one action).
const cancel_choices = [_]iface.Choice{.{ .emoji = "🛑", .label = "Cancel", .value = cancel_request.cancel_choice_value }};

/// Sends (or morphs `existing_placeholder_id` into) the thinking placeholder,
/// attaching the Cancel button when.
fn sendOrMorphPlaceholder(connector: iface.Connector, a: std.mem.Allocator, native_chat_id: []const u8, reply_to: ?[]const u8, existing_placeholder_id: ?[]const u8) ?[]const u8 {
    if (existing_placeholder_id) |pid| {
        if (connector.vtable.editChoicePrompt != null) {
            if (connector.editChoicePrompt(a, native_chat_id, pid, thinking_text, &cancel_choices)) |_| {
                return pid;
            } else |err| {
                log.warn("qa: couldn't morph the transcription placeholder with a Cancel button for chat {s}: {t}", .{ native_chat_id, err });
            }
        }
        connector.editMessage(a, native_chat_id, pid, thinking_text) catch |err| {
            log.warn("qa: couldn't morph the transcription placeholder for chat {s}: {t}", .{ native_chat_id, err });
        };
        return pid;
    }

    if (connector.vtable.sendChoicePrompt != null) {
        if (connector.sendChoicePrompt(a, native_chat_id, thinking_text, &cancel_choices, reply_to) catch |err| blk: {
            log.warn("qa: couldn't send a placeholder with a Cancel button for chat {s}: {t}", .{ native_chat_id, err });
            break :blk null;
        }) |id| return id;
    }
    return connector.sendMessageReturningId(a, native_chat_id, thinking_text, reply_to) catch |err| blk: {
        log.warn("qa: couldn't send a placeholder for chat {s}, falling back to a plain reply: {t}", .{ native_chat_id, err });
        break :blk null;
    };
}

/// Replaces the placeholder's text and drops its Cancel button.
fn finalizePlaceholder(connector: iface.Connector, a: std.mem.Allocator, native_chat_id: []const u8, placeholder_id: ?[]const u8, reply_to: ?[]const u8, text: []const u8) void {
    const pid = placeholder_id orelse {
        connector.sendMessage(a, native_chat_id, text, reply_to);
        return;
    };
    if (connector.vtable.editChoicePrompt != null) {
        if (connector.editChoicePrompt(a, native_chat_id, pid, text, &.{})) |_| {
            return;
        } else |_| {
            // Fall through to the plain edit below — same "log once, degrade" shape as
            // everywhere else in this file that tries a richer send/edit first.
        }
    }
    connector.editMessage(a, native_chat_id, pid, text) catch |err| {
        log.warn("qa: couldn't finalize placeholder for chat {s}: {t}", .{ native_chat_id, err });
        connector.sendMessage(a, native_chat_id, text, reply_to);
    };
}

fn replyWithAnswer(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    asker_identity_id: i64,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
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
    vision_enabled: bool,
    documents_enabled: bool,
    length_limits: qa.LengthLimits,
    history_window: i64,
    /// Retries per model call on a transient failure — see
    /// `toolcall.callProviderWithRetry`.
    max_retries: u32,
    in_flight: *cancel_request.InFlightRequests,
) void {
    // The placeholder + ticker only work when the platform supports editing
    // (Telegram does); anything that doesn't falls back to exactly the old
    // behavior.
    const placeholder_id = sendOrMorphPlaceholder(connector, a, native_chat_id, reply_to, existing_placeholder_id);
    log.info("qa: placeholder for chat {s} = {?s}", .{ native_chat_id, placeholder_id });

    // Heap-allocated on `page_allocator`, not stack-local.
    const state = std.heap.page_allocator.create(TickerState) catch |err| blk: {
        log.warn("qa: couldn't allocate ticker state for chat {s}: {t}", .{ native_chat_id, err });
        break :blk null;
    };
    if (state) |s| s.* = .{ .io = io, .allocator = a, .max_len = max_message_len };
    var progress: toolcall.Progress = .{};
    var ticker_thread: ?std.Thread = null;
    if (placeholder_id) |pid| {
        if (state) |s| {
            progress = .{ .ptr = s, .onEvent = onProgressEvent, .cancelled = &s.cancelled };
            // Best-effort: a failure here just means the Cancel button (if shown at all)
            // silently does nothing when pressed.
            in_flight.register(now, native_chat_id, pid, asker.native_id, &s.cancelled) catch |err| {
                log.warn("qa: couldn't register the Cancel button for chat {s}: {t}", .{ native_chat_id, err });
            };
            ticker_thread = std.Thread.spawn(.{}, tickerLoop, .{ connector, native_chat_id, pid, s }) catch |err| blk: {
                log.warn("qa: couldn't start the thinking animation for chat {s}: {t}", .{ native_chat_id, err });
                break :blk null;
            };
        }
    }
    // Runs on every exit path below (normal answer, error, cancelled, empty
    // answer, overlength-to-file).
    defer if (placeholder_id) |pid| in_flight.unregister(native_chat_id, pid);

    log.info("qa: calling the model for chat {s}", .{native_chat_id});
    const enabled_tools = filterEnabledTools(pool, a, tool_ctx, tools);
    const result_or_err = qa.answer(llm_provider, embeddings_client, a, tool_ctx, enabled_tools, pool, chat_id, asker_identity_id, system_prompt, max_message_len, asker, question, replied_to, progress, stream, show_thinking, vision_enabled, documents_enabled, length_limits, history_window, max_retries);

    // Stop the ticker before touching the placeholder ourselves.
    if (state) |s| {
        s.stop.store(true, .release);
        var waited_ms: i64 = 0;
        while (!s.done.load(.acquire) and waited_ms < 5000) {
            Io.sleep(io, .fromMilliseconds(50), .awake) catch break;
            waited_ms += 50;
        }
        if (ticker_thread) |t| {
            if (s.done.load(.acquire)) {
                t.join();
                std.heap.page_allocator.destroy(s);
            } else {
                log.warn("qa: ticker for chat {s} didn't stop within {d}ms, detaching it", .{ native_chat_id, waited_ms });
                t.detach();
            }
        }
    }
    log.info("qa: model call for chat {s} returned", .{native_chat_id});

    const result = result_or_err catch |err| {
        if (err == error.Cancelled) {
            log.info("qa: request cancelled for chat {s}", .{native_chat_id});
            finalizePlaceholder(connector, a, native_chat_id, placeholder_id, reply_to, "🛑 Cancelled.");
            return;
        }
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

    // What the model actually did this turn, kept with its reply in the history.
    const tool_trace = toolcall.formatTrace(a, result.tool_calls) catch null;

    // The loop already nudged the model once for a visible reply (see
    // `toolcall.runDetailed`).
    const trimmed = std.mem.trim(u8, result.text, " \t\r\n");
    const answer = if (trimmed.len > 0) trimmed else blk: {
        log.warn("qa: empty answer for chat {s} after nudge (stop={t}, tools={d}: {s})", .{
            native_chat_id, result.stop_reason, result.tool_calls.len, tool_trace orelse "-",
        });
        break :blk if (result.tool_calls.len > 0) "\u{2705} Done." else "I couldn't put together a reply to that -- could you rephrase or ask again?";
    };
    log.info("qa: answer for chat {s} is {d} bytes (raw {d}, tools {d})", .{ native_chat_id, answer.len, result.text.len, result.tool_calls.len });

    if (answer.len > max_message_len) {
        // Too long for this platform's limit — editing the placeholder in-place with
        // it would just fail the same way sending it fresh would.
        log.info("qa: answer for chat {s} exceeds max_message_len ({d} > {d}), sending as a file", .{ native_chat_id, answer.len, max_message_len });
        if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
            log.warn("qa: failed to delete placeholder before file fallback for chat {s}: {t}", .{ native_chat_id, err });
        };
        sendTextOrFile(connector, a, native_chat_id, answer, reply_to, max_message_len, "answer.txt");
    } else {
        // `finalizePlaceholder` also drops the Cancel button — the request it
        // controlled is done.
        finalizePlaceholder(connector, a, native_chat_id, placeholder_id, reply_to, answer);
        if (placeholder_id != null) log.info("qa: final answer edited into placeholder for chat {s}", .{native_chat_id});
    }

    // Log the bot's own reply too, so follow-up questions see it in the history
    // window (inbound polling never echoes our own sends back).
    const bot_username = connector.selfUsername() orelse "warden";
    const bot_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), connector.selfId() orelse "warden", bot_username, connector.selfUsername(), true, now) catch |err| {
        log.err("qa: failed to resolve bot identity for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };
    recordBotReply(pool, chat_id, bot_identity_id, answer, tool_trace, now, retention_messages);
}

/// `recordMessage` for the bot's own reply, with the tool trace that
/// produced it (see `toolcall.formatTrace`).
fn recordBotReply(pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, text: []const u8, tool_trace: ?[]const u8, ts: i64, retention: i64) void {
    messages.insertWithTrace(pool, chat_id, identity_id, null, text, ts, tool_trace) catch |err| {
        log.err("failed to insert bot reply for chat {d}: {t}", .{ chat_id, err });
        return;
    };
    chat_members.touch(pool, chat_id, identity_id, ts) catch |err| {
        log.err("failed to touch chat_members for chat {d}: {t}", .{ chat_id, err });
    };
    messages.pruneKeepLast(pool, chat_id, retention) catch |err| {
        log.err("prune failed for chat {d}: {t}", .{ chat_id, err });
    };
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
// /menu ActionRunner.

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
    pending_undos: *audit_notify.PendingUndos,
    is_owner: bool,
    is_bot_admin: bool,
    live_admin_cache: *?bool,
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
        .pending_undos = pending_undos,
        .is_owner = is_owner,
        .is_bot_admin = is_bot_admin,
        .live_admin_cache = live_admin_cache,
    };
}

/// `ActionRunner.authorize` — the menu path's permission check, one tier per
/// `menu_tree.MinRole`.
fn menuAuthorize(id: menu_tree.NodeId, ctx: menu.ActionContext) bool {
    return switch (menu_tree.node(id).min_role) {
        .anyone => true,
        .chat_admin => ctx.is_owner or menuIsLiveChatAdmin(ctx),
        .bot_admin => ctx.is_owner or ctx.is_bot_admin,
        .owner => ctx.is_owner,
    };
}

/// The live `getChatMember` half of `.chat_admin`.
fn menuIsLiveChatAdmin(ctx: menu.ActionContext) bool {
    if (ctx.live_admin_cache.*) |cached| return cached;
    const is_admin = ctx.connector.isGroupAdmin(ctx.a, ctx.msg.chat_id, ctx.msg.user_id) catch |err| blk: {
        log.warn("menu: platform admin check failed for user {s} in chat {s}: {t}", .{ ctx.msg.user_id, ctx.msg.chat_id, err });
        break :blk false;
    };
    ctx.live_admin_cache.* = is_admin;
    return is_admin;
}

const menu_runner: menu.ActionRunner = .{
    .authorize = menuAuthorize,
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

/// Distinct, ordered emoji for a `.dynamic_list`'s live entries.
const dynamic_list_emoji = [_][]const u8{ "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣", "🔟" };
fn dynamicEmojiFor(i: usize) []const u8 {
    return dynamic_list_emoji[i % dynamic_list_emoji.len];
}

/// Maps a menu action's `NodeId` to the `feature_flags` module key that gates
/// it — `null` for navigation/settings nodes with no toggle.
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
        .settings_global_blockchat => blk: {
            bot_blocklist.blockChat(ctx.pool, ctx.chat_id, ctx.identity_id) catch |err| {
                log.err("menu: blockchat failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
            };
            break :blk menuSendAndShow(ctx, "This chat is blocked -- only the owner and bot admins get replies here now.", .settings_global);
        },
        .settings_global_unblockchat => blk: {
            bot_blocklist.unblockChat(ctx.pool, ctx.chat_id) catch |err| {
                log.err("menu: unblockchat failed for chat {s}: {t}", .{ ctx.msg.chat_id, err });
            };
            break :blk menuSendAndShow(ctx, "This chat is no longer blocked.", .settings_global);
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
            const pending = reminders.listPending(ctx.pool, ctx.a, ctx.chat_id, .reminder) catch return &.{};
            for (pending, 0..) |r, i| {
                // Each reminder's setter's own timezone/format, not the
                // Viewer's.
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
        .group_admin_mute => group_admin.mute(ctx.connector, ctx.a, ctx.msg, ctx.now, auditCtx(ctx.pool, ctx.pending_undos, ctx.chat_id, ctx.identity_id, ctx.msg)),
        .group_admin_unmute => group_admin.unmute(ctx.connector, ctx.a, ctx.msg, ctx.now, auditCtx(ctx.pool, ctx.pending_undos, ctx.chat_id, ctx.identity_id, ctx.msg)),
        .group_admin_pin => group_admin.pin(ctx.connector, ctx.a, ctx.msg),
        .group_admin_delete => group_admin.deleteMessage(ctx.connector, ctx.a, ctx.msg),
        .group_admin_promote => {
            if (!auth.isOwner(ctx.config, ctx.connector.platform(), ctx.msg.user_id)) {
                ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Bot owner only.", null);
            } else {
                group_admin.promote(ctx.connector, ctx.a, ctx.msg, ctx.now, auditCtx(ctx.pool, ctx.pending_undos, ctx.chat_id, ctx.identity_id, ctx.msg));
            }
        },
        .group_admin_demote => {
            if (!auth.isOwner(ctx.config, ctx.connector.platform(), ctx.msg.user_id)) {
                ctx.connector.sendMessage(ctx.a, ctx.msg.chat_id, "Bot owner only.", null);
            } else {
                group_admin.demote(ctx.connector, ctx.a, ctx.msg, ctx.now, auditCtx(ctx.pool, ctx.pending_undos, ctx.chat_id, ctx.identity_id, ctx.msg));
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
        .settings_global_blockuser => handleBlockUserCommand(ctx.connector, ctx.a, ctx.config, ctx.pool, ctx.identity_id, ctx.now, ctx.msg, menuSyntheticText(ctx, "/blockuser")),
        .settings_global_unblockuser => menuResumeViaText(ctx, "/unblockuser", handleUnblockUserCommand),
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

/// A signed `H[:MM]` UTC offset, e.g. "+3:30", "-5", "+0".
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

/// `ActionRunner.beginWizard` — the reminder wizard's initial draft.
fn menuBeginWizard(id: menu_tree.NodeId, ctx: menu.ActionContext) menu.ReminderDraft {
    _ = id;
    // Deliberately doesn't check `feature_flags` here.
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
/// input resume below feeds to an existing slash-command handler.
fn menuSyntheticText(ctx: menu.ActionContext, comptime cmd: []const u8) []const u8 {
    return std.fmt.allocPrint(ctx.a, cmd ++ " {s}", .{ctx.msg.text orelse ""}) catch cmd;
}

fn menuResumeViaText(ctx: menu.ActionContext, comptime cmd: []const u8, handler: fn (iface.Connector, std.mem.Allocator, *store_pool.PgPool, i64, iface.Message, []const u8) void) void {
    handler(ctx.connector, ctx.a, ctx.pool, ctx.now, ctx.msg, menuSyntheticText(ctx, cmd));
}

fn menuResumeViaTextAdd(ctx: menu.ActionContext, comptime cmd: []const u8, handler: fn (iface.Connector, std.mem.Allocator, *store_pool.PgPool, i64, i64, iface.Message, []const u8) void) void {
    handler(ctx.connector, ctx.a, ctx.pool, ctx.identity_id, ctx.now, ctx.msg, menuSyntheticText(ctx, cmd));
}

fn menuResumeViaCommand(ctx: menu.ActionContext, comptime cmd: []const u8, handler: fn (iface.Connector, std.mem.Allocator, *store_pool.PgPool, i64, i64, *audit_notify.PendingUndos, i64, iface.Message, []const u8) void) void {
    handler(ctx.connector, ctx.a, ctx.pool, ctx.chat_id, ctx.identity_id, ctx.pending_undos, ctx.now, ctx.msg, menuSyntheticText(ctx, cmd));
}

fn handleKickBanCommandKick(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, pending_undos: *audit_notify.PendingUndos, now: i64, msg: iface.Message, text: []const u8) void {
    // `false`: `/menu`'s synthetic text never carries a `-s`/`-p` flag, so
    // whether the caller is a superuser is moot here.
    handleKickBanCommand(connector, a, pool, chat_id, identity_id, pending_undos, false, now, msg, text, "/kick", .kick);
}

fn handleKickBanCommandBan(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, pending_undos: *audit_notify.PendingUndos, now: i64, msg: iface.Message, text: []const u8) void {
    handleKickBanCommand(connector, a, pool, chat_id, identity_id, pending_undos, false, now, msg, text, "/ban", .ban);
}

// Zig's test collector only walks `test` blocks reachable from the file
// passed to `addTest`.
test {
    _ = auth;
    _ = @import("store/pool.zig");
    _ = @import("store/migrate.zig");
    _ = @import("store/identities.zig");
    _ = @import("store/chats.zig");
    _ = @import("store/management_rooms.zig");
    _ = @import("store/chat_members.zig");
    _ = @import("store/chat_settings.zig");
    _ = @import("store/bot_config.zig");
    _ = @import("store/messages.zig");
    _ = @import("store/bot_admins.zig");
    _ = @import("store/bot_blocklist.zig");
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
    _ = @import("api/bot_view.zig");
    _ = @import("api/rate_limit.zig");
    _ = @import("store/admin_directory.zig");
    _ = @import("llm/dynamic_provider.zig");
    _ = @import("store/stats.zig");
    _ = @import("store/reminders.zig");
    _ = @import("store/notes.zig");
    _ = @import("store/keyword_alerts.zig");
    _ = @import("store/expenses.zig");
    _ = @import("store/budgets.zig");
    _ = @import("store/subscriptions.zig");
    _ = @import("store/command_aliases.zig");
    _ = @import("store/prompt_templates.zig");
    _ = @import("store/facts.zig");
    _ = @import("store/daily_digests.zig");
    _ = @import("features/context_assembly.zig");
    _ = @import("features/qa.zig");
    _ = @import("features/reminder_format.zig");
    _ = @import("tools/remind.zig");
    _ = @import("features/convert.zig");
    _ = @import("tools/convert_file.zig");
    _ = @import("store/alerts.zig");
    _ = @import("features/alerts.zig");
    _ = @import("tools/set_alert.zig");
    _ = @import("tools/set_note.zig");
    _ = @import("tools/remember_memory.zig");
    _ = @import("store/feed_watches.zig");
    _ = @import("features/feed_watcher.zig");
    _ = @import("features/feed_parse.zig");
    _ = @import("features/transcribe.zig");
    _ = @import("features/video_download.zig");
    _ = @import("features/storage_sense.zig");
    _ = @import("features/convert_flow.zig");
    _ = @import("tools/begin_conversion.zig");
    _ = @import("tools/find_chat_member.zig");
    _ = @import("tools/catch_me_up.zig");
    _ = @import("tools/create_poll.zig");
    _ = @import("tools/set_expense.zig");
    _ = @import("llm/provider.zig");
    _ = @import("llm/anthropic.zig");
    _ = @import("llm/openai_compat.zig");
    _ = @import("llm/embeddings.zig");
    _ = @import("llm/attachment_content.zig");
    _ = @import("tools/calculator.zig");
    _ = @import("llm/toolcall.zig");
    _ = @import("features/group_admin.zig");
    _ = @import("features/audit_notify.zig");
    _ = @import("features/cancel_request.zig");
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
    _ = @import("platform/telegram/connector.zig");
    _ = @import("platform/telegram/client.zig");
    _ = @import("platform/telegram/markdown_html.zig");
    _ = @import("http_util.zig");
    _ = @import("features/scheduler.zig");
    _ = @import("features/digest.zig");
    _ = @import("features/briefing.zig");
    _ = @import("tools/html_extract.zig");
    _ = @import("tools/scrape_site.zig");
    _ = @import("platform/interface.zig");
    _ = @import("domain/identity.zig");
    _ = @import("domain/telegram_profile.zig");
    _ = @import("platform/matrix/connector.zig");
    _ = @import("platform/matrix/types.zig");
    _ = @import("domain/matrix_profile.zig");
    _ = @import("platform/matrix/olm.zig");
    _ = @import("platform/matrix/verification.zig");
    _ = @import("platform/matrix/crypto.zig");
    _ = @import("store/crypto.zig");
    _ = @import("platform/xmpp/connector.zig");
    _ = @import("platform/reply_redirect.zig");
    _ = @import("platform/telegram/user_connector.zig");
    _ = @import("platform/xmpp/xml.zig");
    _ = @import("platform/xmpp/types.zig");
    _ = @import("platform/xmpp/client.zig");
    _ = @import("domain/xmpp_profile.zig");
    _ = @import("domain/instagram_profile.zig");
    _ = @import("platform/instagram/crypto.zig");
    _ = @import("platform/instagram/transport.zig");
    _ = @import("platform/instagram/auth.zig");
    _ = @import("platform/instagram/session.zig");
    _ = @import("platform/instagram/direct.zig");
    _ = @import("platform/instagram/media.zig");
    _ = @import("platform/instagram/policy.zig");
    _ = @import("platform/instagram/connector.zig");
    _ = @import("store/instagram_sessions.zig");
    _ = @import("worker_pool.zig");
    _ = @import("store/db.zig");
    // AUDIT-2026-09-03 TEXT-6/STORE-4: these seventeen carried tests that no `zig
    // build test` had ever reached.
    _ = @import("auth.zig");
    _ = @import("log.zig");
    _ = @import("features/bulletin.zig");
    _ = @import("features/chat_summary.zig");
    _ = @import("features/reply_drafts.zig");
    _ = @import("llm/delegates.zig");
    _ = @import("store/member_permissions.zig");
    _ = @import("store/rate_limits.zig");
    _ = @import("tools/ask_delegate.zig");
    _ = @import("tools/delegate_generate_image.zig");
    _ = @import("tools/get_bulletin.zig");
    _ = @import("tools/list_personal_chats.zig");
    _ = @import("tools/reply_to_message.zig");
    _ = @import("tools/send_personal_message.zig");
    _ = @import("tools/set_chat_monitoring.zig");
    _ = @import("tools/set_default_chat_monitoring.zig");
    _ = @import("tools/summarize_unread_chat.zig");
}

/// Codepoints that delimit a word for magic-word / keyword matching.
fn isWordBoundaryCodepoint(cp: u21) bool {
    if (cp < 0x80) return !std.ascii.isAlphanumeric(@intCast(cp));
    return switch (cp) {
        0x00A0, 0x00A1, 0x00AB, 0x00B7, 0x00BB, 0x00BF => true, // Latin-1 punctuation
        0x0589, 0x058A, 0x05BE, 0x05C0, 0x05C3, 0x05C6, 0x05F3, 0x05F4 => true, // Armenian/Hebrew
        0x060C, 0x060D, 0x061B, 0x061E, 0x061F => true, // Arabic comma/semicolon/question mark
        0x066A...0x066D => true, // Arabic percent / decimal separators / star
        0x06D4 => true, // Arabic full stop
        0x0964, 0x0965 => true, // Devanagari danda
        0x200B, 0x200E, 0x200F => true, // zero-width space + bidi marks (not ZWNJ/ZWJ)
        0x2010...0x2027 => true, // dashes, quotes, bullet, ellipsis
        0x2028...0x205F => true, // separators, bidi controls, exotic spaces
        0x2190...0x2BFF => true, // arrows, math operators, symbols, dingbats
        0x2E00...0x2E7F => true, // supplemental punctuation
        0x3000...0x303F => true, // CJK punctuation
        0xFE0F, 0xFE10...0xFE19, 0xFE30...0xFE6F => true, // variation selector, vertical/small forms
        0xFF01...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65 => true, // fullwidth punctuation
        0x1F000...0x1FAFF => true, // emoji and pictographs
        else => false,
    };
}

/// Boundary test for the byte *before* `idx`: walks back to the start of the
/// UTF-8 sequence and decodes it.
fn isWordBoundaryBefore(haystack: []const u8, idx: usize) bool {
    if (idx == 0) return true;
    var i = idx;
    while (i > 0 and idx - i < 4) {
        i -= 1;
        if (haystack[i] & 0xC0 == 0x80) continue; // continuation byte
        const len = std.unicode.utf8ByteSequenceLength(haystack[i]) catch return true;
        if (i + len != idx) return true;
        const cp = std.unicode.utf8Decode(haystack[i..idx]) catch return true;
        return isWordBoundaryCodepoint(cp);
    }
    return true;
}

/// Boundary test for the codepoint starting at `idx` (end of the match).
fn isWordBoundaryAt(haystack: []const u8, idx: usize) bool {
    if (idx >= haystack.len) return true;
    const len = std.unicode.utf8ByteSequenceLength(haystack[idx]) catch return true;
    if (idx + len > haystack.len) return true;
    const cp = std.unicode.utf8Decode(haystack[idx..][0..len]) catch return true;
    return isWordBoundaryCodepoint(cp);
}

/// Whole-word, ASCII-case-insensitive search — used for magic-word detection
/// so "Hassan," matches a magic word of "hassan" but "hassanabad" doesn't.
fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;

    var start: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(haystack, start, needle)) |abs_idx| {
        const end_idx = abs_idx + needle.len;

        const left_ok = isWordBoundaryBefore(haystack, abs_idx);
        const right_ok = isWordBoundaryAt(haystack, end_idx);

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

// Regression: Persian punctuation is multi-byte UTF-8.
test "containsWordIgnoreCase treats Persian punctuation as a word boundary" {
    const magic = "وردن";
    try std.testing.expect(containsWordIgnoreCase("وردن، حالت چطوره؟", magic)); // Arabic comma U+060C
    try std.testing.expect(containsWordIgnoreCase("وردن؟", magic)); // Arabic question mark U+061F
    try std.testing.expect(containsWordIgnoreCase("سلام وردن؛ خوبی", magic)); // Arabic semicolon U+061B
    try std.testing.expect(containsWordIgnoreCase("وردن۔", magic)); // Arabic full stop U+06D4
    try std.testing.expect(containsWordIgnoreCase("«وردن» رو صدا کن", magic)); // guillemets
    try std.testing.expect(containsWordIgnoreCase("وردن — یه سوال", magic)); // em dash
    try std.testing.expect(containsWordIgnoreCase("وردن…", magic)); // ellipsis
    try std.testing.expect(containsWordIgnoreCase("وردن👋", magic)); // emoji
    try std.testing.expect(containsWordIgnoreCase("hey وردن, hi", magic)); // ASCII still works

    // A name glued to more letters is still not a match, in either direction.
    try std.testing.expect(!containsWordIgnoreCase("وردنها اومدن", magic));
    try std.testing.expect(!containsWordIgnoreCase("باوردن", magic));
    // ZWNJ joins word parts in Persian, so it must not act as a boundary.
    try std.testing.expect(!containsWordIgnoreCase("وردن\u{200c}ها", magic));
}

test "word-boundary helpers handle malformed UTF-8 without misreading bytes" {
    // A truncated sequence next to the needle counts as a boundary rather
    // than swallowing the match.
    try std.testing.expect(containsWordIgnoreCase("\xd8 وردن", "وردن"));
    try std.testing.expect(containsWordIgnoreCase("وردن\xd8", "وردن"));
    try std.testing.expect(isWordBoundaryBefore("abc", 0));
    try std.testing.expect(isWordBoundaryAt("abc", 3));
    try std.testing.expect(!isWordBoundaryAt("abc", 1));
}

fn replyTarget(msg: iface.Message) ?struct { user_id: []const u8, label: []const u8 } {
    const user_id = msg.reply_to_user_id orelse return null;
    const label = msg.reply_to_username orelse user_id;
    return .{ .user_id = user_id, .label = label };
}

fn reply(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, reply_to: ?[]const u8, comptime txt: []const u8) void {
    connector.sendMessage(a, chat_id, txt, reply_to);
}
