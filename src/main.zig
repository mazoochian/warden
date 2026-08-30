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
const telegram_user_platform = @import("platform/telegram_user.zig");
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
const notes = @import("store/notes.zig");
const keyword_alerts = @import("store/keyword_alerts.zig");
const expenses = @import("store/expenses.zig");
const budgets = @import("store/budgets.zig");
const subscriptions = @import("store/subscriptions.zig");
const command_aliases = @import("store/command_aliases.zig");
const prompt_templates = @import("store/prompt_templates.zig");
const memories = @import("store/memories.zig");
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
const llm = @import("llm/provider.zig");
const AnthropicProvider = @import("llm/anthropic.zig").AnthropicProvider;
const OpenAiCompatProvider = @import("llm/openai_compat.zig").OpenAiCompatProvider;
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

/// Published via `Connector.setCommands` at startup so commands show up in
/// the platform's own UI (Telegram's "/" autocomplete / attachment menu)
/// instead of only working for people who already know the exact text to
/// type — see `handleHelp`/`help_text` below for the fuller reference,
/// including the owner/bot-admin-only `/token /credit /scraper /adduser
/// /removeuser /allowchat /disallowchat /addadmin /removeadmin /sudo
/// /storage` deliberately left out of this public menu (see their own
/// dispatch-table gates in `handleMessage`).
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

/// Owner-only commands deliberately left out of `public_commands` (see its
/// own doc comment) but still reserved -- an alias must never shadow one
/// of these either.
const reserved_command_names_extra = [_][]const u8{
    "token",     "credit",       "scraper",  "adduser",     "removeuser",
    "allowchat", "disallowchat", "addadmin", "removeadmin", "sudo",
    "storage",
};

/// True if `name` (no leading slash) is a real built-in command -- checked
/// case-insensitively, same as `normalizeCommandMention`'s own qualifier
/// matching. `/alias add`/`/alias`'s expansion-lookup step both use this:
/// an alias may never shadow a real command (ROADMAP.md's Phase 19).
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
    try std.testing.expect(isReservedCommandName("Token"));
    try std.testing.expect(!isReservedCommandName("gm"));
    try std.testing.expect(!isReservedCommandName("standup"));
}

/// `/help`'s reply — kept as a single static string (matches `reply()`'s
/// `comptime txt` parameter) rather than built from `public_commands`, since
/// it also covers the owner-only commands deliberately left out of that
/// public menu, group-chat-only commands, and the free-form LLM path, none
/// of which fit `CommandSpec`'s flat name/description shape.
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
///
/// Splitting was forced rather than chosen: the combined text crossed
/// Telegram's 4096-byte cap when `/as` was added (ROADMAP.md's Phase 9
/// slice 2), and shaving bytes off entries would only have moved the
/// ceiling a few commands further out. The split point is where the
/// audience changes -- everything above is for whoever is using the bot,
/// everything here is moderation, trust and operations -- so each message
/// is coherent on its own rather than being an arbitrary cut at N bytes.
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
    \\Tokens and credits (reply to a user, or pass @username, to view/set)
    \\/token [balance] [@user] -- lets a non-admin run one /kick or /ban
    \\  per token. Chat admins/bot admins can grant these
    \\/credit [balance] [@user] -- 1 credit per LLM question. Bot
    \\  admin/owner only (spends real API cost)
    \\
    \\Bot admins (trusted bot-wide -- owner only to grant/revoke)
    \\/addadmin, /removeadmin, /adduser, /removeuser -- reply to a user,
    \\  or pass @username/id, to grant/revoke that role
    \\/allowchat, /disallowchat -- allow/disallow this whole chat
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

/// Sends `/help` as two messages (see `help_text_admin`), appending a note
/// about the `/command@botusername` qualified form (see
/// `normalizeCommandMention`) to the second one using this connector's
/// *actual* username when known, rather than baking a guessed example into
/// the static text — relevant mainly when two bot instances share one group
/// chat.
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
    // A Telegram username is at most 32 bytes, so 200 bytes of slack is
    // generous for the "Sharing this group..." suffix `handleHelp` appends
    // to the second message.
    try std.testing.expect(help_text.len < 4096);
    try std.testing.expect(help_text_admin.len < 4096 - 200);
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

    // Same shape as Matrix/XMPP above. Unlike them, there's no `deinit()`
    // to call on a clean shutdown — TDLib persists its own session state to
    // `session_dir` as it goes (that's the whole point: a later process
    // restart pointed at the same directory reaches `authorizationStateReady`
    // again with no re-login), so there's nothing this process needs to
    // flush on exit.
    var telegram_user_adapter: ?telegram_user_platform.TelegramUserConnector = if (config.telegram_user) |tc|
        telegram_user_platform.TelegramUserConnector.init(gpa, io, tc.api_id, tc.api_hash, tc.session_dir)
    else
        null;

    var connectors_buf: [4]iface.Connector = undefined;
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

    // 24h, not `config.confirm_timeout_seconds` -- reaching for an audit-log
    // undo well after the fact is a reasonable thing to want, unlike a
    // ban/kick confirmation where seconds matter. See `audit_notify.
    // PendingUndos`'s own doc comment.
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

    // 10 minutes: a purely defensive backstop (normal flow always
    // unregisters itself via `replyWithAnswer`'s own cleanup, well before
    // this) — see `cancel_request.InFlightRequests`'s doc comment.
    var in_flight_requests = cancel_request.InFlightRequests.init(gpa, io, 600);
    defer in_flight_requests.deinit();

    // Phase D of the plan sent to the owner: `reply_autonomy = .draft`
    // drafts a reply through the personal-account connector but holds it
    // here instead of sending it, until `/approve`/`/discard` (see
    // `handleApproveCommand`/`handleDiscardCommand`). 24h, same "reasonable
    // to reach for well after the fact" reasoning as `pending_undos` above
    // — unlike a ban/kick confirmation, replying to a text a few hours
    // later is completely normal for a personal account.
    var pending_drafts = reply_drafts.PendingDrafts.init(gpa, io, 24 * 3600);
    defer pending_drafts.deinit();

    var bot_view_broadcaster = bot_view.Broadcaster.init(gpa, io);
    defer bot_view_broadcaster.deinit();

    // Phase 7 hardening -- see `rate_limit.zig`'s doc comment. Generous
    // limits (this stops naive flooding, not determined abuse from many
    // IPs, since there's no per-IP key yet): 20 auth-flow attempts/min is
    // well above any legitimate login retry pattern, 10 bot-view sends/min
    // per account is well above any legitimate human typing speed for
    // "reply as the bot" messages.
    var auth_limiter = rate_limit.Limiter.init(gpa, io, 20, 60);
    defer auth_limiter.deinit();
    var bot_view_send_limiter = rate_limit.Limiter.init(gpa, io, 10, 60);
    defer bot_view_send_limiter.deinit();

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

    // Same "heap-allocated, process-lifetime singleton" shape as the LLM
    // providers above -- null when `WARDEN_EMBEDDINGS_URL` isn't set,
    // which every downstream consumer (the `remember_memory` tool,
    // `qa.zig`'s retrieval step) treats as "the memory feature is off"
    // rather than an error.
    var embeddings_client: ?*embeddings.EmbeddingsClient = null;
    if (config.embeddings_url) |url| {
        const ec = try gpa.create(embeddings.EmbeddingsClient);
        ec.* = embeddings.EmbeddingsClient.init(gpa, io, url, config.embeddings_api_key, config.embeddings_model);
        embeddings_client = ec;
    }

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
    // Computed once, outside the loop below, and handed identically to
    // every connector's poll loop — `/tdlogin` (see `handleTdloginCommand`)
    // can be typed from whichever connector the owner is actually talking
    // to the bot on (almost always the Bot API one, not the personal
    // account itself, since driving the personal account's own login *from*
    // the personal account makes no sense), not necessarily the one this
    // pointer "belongs to".
    const telegram_user_ptr: ?*telegram_user_platform.TelegramUserConnector = if (telegram_user_adapter) |*t| t else null;

    // A `reply_autonomy = .draft` notification (see `pending_drafts` above)
    // always needs to reach the owner through the Bot API chat they
    // actually operate Warden from, regardless of which connector's poll
    // loop is running `handleMessage` at the time — same "computed once,
    // handed identically to every connector's poll loop" shape as
    // `telegram_user_ptr` right above, for the same reason: the personal
    // connector's own poll loop is exactly the one that needs this most
    // (that's where an incoming message that might need a draft arrives),
    // and it's never the Bot API connector's own loop.
    const owner_notify_connector = telegram_adapter.connector();

    // `storage_sense.tick`'s notification target — resolved once here
    // rather than per-tick, same "computed once, handed identically to
    // every connector's poll loop" shape as `owner_notify_connector` right
    // above. `null` only if, somehow, no `.telegram` owner entry exists
    // (shouldn't happen -- `Config.load` always adds one); the scheduler
    // loop below simply skips `tick` for that tick if so, logging once
    // rather than looping a warning every ~30s forever.
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
        };
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
        checkAndSendDueBriefings(connectors, gpa, io, &config, &pool, &briefing_scheduler, max_message_len, now);
        checkAndSendDueReminders(connectors, gpa, &pool, now);
        checkAndRevertExpiredPermissions(connectors, gpa, &pool, now);
        alert_feature.checkAndDeliverAlerts(connectors, gpa, io, &pool, now);
        feed_watcher.checkAndNotifyFeeds(connectors, gpa, io, &pool, llm_provider, now);
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
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tools: []const tool_registry.ToolDef,
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
                .embeddings_client = embeddings_client,
                .tools = tools,
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
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tools: []const tool_registry.ToolDef,
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

    fn run(self: MessageTask) void {
        processMessageTask(
            self.connector,
            self.config,
            self.pool,
            self.llm_provider,
            self.embeddings_client,
            self.tools,
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
    embeddings_client: ?*embeddings.EmbeddingsClient,
    tools: []const tool_registry.ToolDef,
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

    // Housekeeping: synthetic lifecycle signals from a connector (see
    // `iface.Message.chat_left`/`migrated_to_native_chat_id`/
    // `chat_ingest_only`'s doc comments), not real conversational content —
    // handled and returned early, before identity resolution/recording/LLM
    // dispatch, same as `choice_picked` being excluded from `recordMessage`
    // a few lines below.
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

    // ROADMAP.md's Phase 16: welcome messages. A join service message has
    // no `text`, so it would never reach `handleMessage`'s command
    // dispatch below -- checked here instead, alongside the other
    // housekeeping signals above, before normal message handling.
    sendWelcomeMessages(connector, a, pool, chat_id, msg);

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
        // ROADMAP.md's Phase 24: warden's own slow-mode enforcement, ahead
        // of recordMessage/keyword-alerts/dispatch below -- a rate-limited
        // message is deleted right here and the rest of this task never
        // runs for it (same early-exit shape `choice_picked` gets above).
        // See `checkSlowMode`'s doc comment for why this can't just read
        // `chat_members.last_seen`.
        if (checkSlowMode(connector, a, config, pool, chat_id, identity_id, msg, ts)) return;

        const retention_messages = dynamic_config.getI64(pool, a, "WARDEN_RETENTION_MESSAGES", config.retention_messages);
        recordMessage(pool, chat_id, identity_id, msg.message_id, msg.text, ts, retention_messages);

        // Read-only tap for Bot View's live incoming-message feed (see
        // bot_view.zig's doc comment) -- a cheap no-op when nobody's
        // subscribed to this chat, and never influences how/whether this
        // message actually gets answered.
        const sender_display_name = if (msg.identity) |identity| identity.display_name else msg.username orelse msg.user_id;
        bcast.publish(chat_id, sender_display_name, msg.text, ts);

        // ROADMAP.md's Phase 16: keyword alerts. A plain string scan (no
        // LLM call), fires for any sender -- see `checkKeywordAlerts`'s own
        // doc comment for why this sits at the same "passive content
        // observation" tier as `recordMessage`/`bcast.publish` above rather
        // than behind the owner/credits gates real Q&A uses.
        if (feature_flags.isEnabled(pool, "keyword_alerts")) {
            if (msg.text) |t| checkKeywordAlerts(connector, a, pool, chat_id, msg, t);
        }

        // ROADMAP.md's Phase 25: video auto-download. Same passive-
        // observation tier as `checkKeywordAlerts` right above (no LLM
        // call, fires for any sender), but gated by both the bot-wide
        // `video_download` feature flag and a per-chat opt-in (off by
        // default -- see `chat_settings.getVideoDownloadEnabled`'s doc
        // comment) rather than firing unconditionally the way keyword
        // alerts do, since this changes what happens with any link any
        // member posts, not just something a user asked to be notified
        // about.
        if (feature_flags.isEnabled(pool, "video_download") and chat_settings.getVideoDownloadEnabled(pool, chat_id)) {
            if (msg.text) |t| checkVideoDownload(connector, a, io, config, pool, chat_id, msg, t);
        }
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
    var personal_account_adapter: PersonalAccountToolAdapter = .{
        .telegram_user = telegram_user,
        .pool = pool,
        .io = io,
    };
    var monitoring_adapter: MonitoringToolAdapter = .{
        .telegram_user = telegram_user,
        .pool = pool,
        .owner_identity_id = identity_id,
    };
    var bulletin_adapter: BulletinToolAdapter = .{
        .pool = pool,
        .owner_identity_id = identity_id,
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
        // Null (not just a sink whose calls would fail) whenever the
        // feature isn't configured at all -- matches every other
        // `?Sink = null` field's own "absent means the tool can't run"
        // convention, rather than surfacing a runtime error from inside
        // the tool for something that's a deploy-time config choice.
        .memory = if (embeddings_client != null) memory_adapter.sink() else null,
        .chat_history = chat_history_adapter.sink(),
        .expenses = expense_adapter.sink(),
        .personal_account = personal_account_adapter.sink(),
        .monitoring = monitoring_adapter.sink(),
        .bulletin = bulletin_adapter.sink(),
        .attachment_path = attachment_path,
        .attachment_file_name = if (msg.attachment) |att| att.file_name else null,
        .attachment_mime = if (msg.attachment) |att| att.mime_type else null,
        .attachment_kind = if (msg.attachment) |att| att.kind else null,
    };
    const claimed = handleMessage(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, pending, pending_undos, digest_scheduler, briefing_scheduler, pending_conversions, menu_sessions, in_flight_requests, io, ts, max_message_len, msg, false, telegram_user, pending_drafts, owner_notify);
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

/// ROADMAP.md's Phase 24 slow mode: warden's own per-(chat, member)
/// cooldown between messages — Telegram's Bot API has no method exposing a
/// chat's native slow-mode delay to bots (client-UI-only setting), so this
/// is warden's own logic, enforced the same way on Telegram and Matrix via
/// `Connector.deleteMessage` (already in the vtable for both) and left a
/// no-op on XMPP, whose vtable has no moderation slots at all — the
/// `deleteMessage` call below simply reports `error.Unsupported` there,
/// logged and otherwise harmless.
///
/// Deliberately checked *before* `recordMessage` runs (see the call site in
/// `processMessageTask`): `chat_members.last_seen` gets bumped by
/// `recordMessage`'s own `chat_members.touch` for every inbound message,
/// including the one currently being checked, so reading it here would
/// always see "now" — `store/rate_limits.zig`'s own
/// `member_message_cooldowns` table exists specifically so this check has
/// something to compare against that isn't already clobbered.
///
/// Returns `true` if the message was rate-limited (and thus already
/// deleted — the deletion is the feedback, no separate reply is sent) and
/// the caller should stop processing this message entirely; `false`
/// otherwise (slow mode off, sender exempt, within the cooldown boundary,
/// or no `message_id` to delete).
///
/// Owner and any live platform admin of this chat are exempt — an admin's
/// own moderation commands (e.g. running `/slowmode` itself) shouldn't get
/// rate-limited by a slow mode they just set.
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

/// Same restore-on-restart shape as `loadDigestScheduleFromDisk` above --
/// see its own doc comment.
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

/// One formatted weather line for a chat's default location, or `null` if
/// the chat has none set, the lookup failed, or the place didn't geocode.
///
/// Every failure path returns `null` rather than propagating: a briefing
/// that can't reach Open-Meteo should still deliver its reminders and
/// alerts, not fail wholesale over the one section that needs the network.
/// Kept here rather than inside `briefing.generate` so that function stays
/// pure composition and its tests stay offline -- see its doc comment.
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
/// param that one needs -- `briefing.generate` is pure composition over
/// already-stored data, no tool-call loop involved. `io` is needed only for
/// the optional weather section (see `briefingWeatherLine`).
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
    max_tokens_override: ?u32,
    history_messages: i64,
    skip_trivial_messages: bool,
    vision_enabled: bool,
    documents_enabled: bool,
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
        .vision_enabled = dynamic_config.findBool(rows, "WARDEN_LLM_VISION", config.llm_vision_enabled),
        .documents_enabled = dynamic_config.findBool(rows, "WARDEN_LLM_DOCUMENTS", config.llm_documents_enabled),
    };
}

/// One argument, one piece of text — e.g. `/translate spanish hola` splits
/// into `modifier="spanish"`, `text="hola"`.
const ModeArgSplit = struct {
    modifier: []const u8,
    text: []const u8,
};

/// Parses a "messaging mode" command's argument shape (ROADMAP.md's Phase
/// 14: /translate, /rewrite) — `<modifier> [text...]`, where `modifier` is
/// the first whitespace-delimited token (a target language, a tone) and
/// everything after it is the text to operate on. When no text follows the
/// modifier, falls back to `reply_to_text` — so `/translate spanish` as a
/// reply to someone else's message translates *that* message without
/// needing to repeat it. Returns null when there's neither a modifier, nor
/// any text to fall back to (caller replies with its own usage message).
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
/// /brainstorm, which take just a body of text/topic. Returns null when
/// there's neither.
fn modeArgOrReplyText(arg: []const u8, reply_to_text: ?[]const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len > 0) return trimmed;
    return reply_to_text;
}

/// Shared entry point for the Phase 14 "messaging mode" commands
/// (/translate, /rewrite, /eli5, /brainstorm) — each one just builds a
/// mode-specific instruction as `question` (see the dispatch table in
/// `handleMessage`) and routes it through the exact same LLM-answering
/// pipeline plain addressed Q&A uses: dynamic owner-only/credits gates,
/// /persona and /thinking overrides, the placeholder+ticker flow, tool-
/// calling, streaming — all via `replyWithAnswer`, same as
/// `isAddressedToBot`'s own branch. Deliberately skips that branch's
/// mention-detection and trivial-message short circuit: typing an explicit
/// `/translate ...` is already unambiguous address, and is never itself a
/// trivial greeting. `replied_to` (the "user is replying to your earlier
/// message" framing `qa.answer` adds) is left null here since any relevant
/// replied-to text is already folded straight into `question` by the
/// caller, not carried as separate context.
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

    if (!is_privileged and !(identities.spendCredit(pool, identity_id) catch |err| blk: {
        log.err("qa: credit spend check failed for identity {d}: {t}", .{ identity_id, err });
        break :blk false;
    })) {
        connector.sendMessage(a, msg.chat_id, "You're out of LLM credits — ask the bot owner for more.", msg.message_id);
        return;
    }

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
    replyWithAnswer(connector, a, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, system_prompt, io, now, retention_messages, max_message_len, msg.chat_id, msg.message_id, asker, question, null, null, dyn.streaming, show_thinking, dyn.vision_enabled, dyn.documents_enabled, dyn.max_tokens_override, dyn.history_messages, in_flight);
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
/// whole allocation (`parts`) that `question`/`options` are views into --
/// callers that need to free it (tests using `testing.allocator` directly;
/// production call sites pass a per-message arena and never bother) must
/// free `parts` as a whole, not `options` alone, since `options` is a
/// sub-slice starting at index 1, not its own allocation.
const ParsedPoll = struct {
    question: []const u8,
    options: [][]const u8,
    parts: [][]const u8,
};

/// Parses `/poll <question> | <option1> | <option2> | ...` (ROADMAP.md's
/// Phase 16) into a question and 2-10 trimmed options, or an error string
/// to reply with. `|`-delimited rather than `/remind`-style keyword
/// parsing since a poll question or option could legitimately contain
/// almost any word.
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
    /// True only on the recursive call `/as` makes to replay a command
    /// against another chat (see `resolveAsCommand`). Its one job is to
    /// stop `/as` from relaying `/as`: without it, a `/alias` whose
    /// expansion begins with `/as` would recurse without bound, since
    /// alias expansion re-runs inside every relayed dispatch. Deliberately
    /// a parameter rather than something inferred from `connector`
    /// (`ReplyRedirect` builds a per-instance vtable, so there is no stable
    /// vtable pointer to compare against) or from `msg` (a relayed message
    /// is intentionally indistinguishable from a real one — that's the
    /// whole point of the re-dispatch).
    relayed: bool,
    /// The personal-account connector, if `WARDEN_TELEGRAM_USER_*` is
    /// configured — `null` otherwise. Threaded alongside `connector` rather
    /// than reached for via `config`/a global, same "explicit dependency,
    /// not ambient state" convention every other shared resource here
    /// (`pool`, `pending`, `digest_scheduler`, ...) already follows. Only
    /// `/tdlogin`'s handler touches this; every other command ignores it.
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    /// Phase D's `reply_autonomy = .draft` staging area — see
    /// `reply_drafts.PendingDrafts`'s doc comment. Touched by the
    /// `.telegram_user` auto-reply branch (`handleTelegramUserAutoReply`)
    /// and by `/approve`/`/discard`/`/drafts`.
    pending_drafts: *reply_drafts.PendingDrafts,
    /// The Bot API connector to notify the owner through when a draft is
    /// ready for review — see `main`'s `owner_notify_connector` doc comment
    /// for why this can't just be `connector` (the connector that actually
    /// received the message being drafted for is the *personal* one, not
    /// the one the owner reviews drafts on).
    owner_notify: iface.Connector,
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
        // Phase 20's "Undo" button on an audit-log entry — keyed by
        // (control room, prompt message) rather than (chat, user), so it's
        // checked on its own first rather than folded into the
        // isAwaitingFormat/else split below; returns `false` (not handled)
        // for anything that isn't its own button, so a stray pick still
        // falls through to convert_flow/menu normally.
        if (audit_notify.handleUndoPicked(connector, a, pool, pending_undos, now, msg, picked)) {
            return false;
        }
        // Same "checked on its own first, false for anything not its own"
        // shape again — the "🛑 Cancel" button `replyWithAnswer` attaches
        // to the thinking placeholder (see `features/cancel_request.zig`).
        if (cancel_request.handleCancelPicked(connector, a, in_flight, now, msg, picked)) {
            return false;
        }
        // Same "checked on its own first, false for anything not its own"
        // shape as the Undo button above — the Approve/Discard buttons on a
        // `reply_autonomy = .draft` notification (see
        // `handleTelegramUserAutoReply`/`handleDraftChoicePicked`).
        if (handleDraftChoicePicked(connector, a, telegram_user, pending_drafts, now, msg, picked)) {
            return false;
        }
        // Same shape again — `/tdchats`' Prev/Next pager buttons. Checked
        // by `callback_data` prefix rather than any stored pending state
        // (see `handleTdChatsPagePicked`'s doc comment on why it's
        // stateless), so ordering relative to the two checks above doesn't
        // matter beyond "somewhere before the isAwaitingFormat split".
        if (handleTdChatsPagePicked(connector, a, config, telegram_user, msg, picked)) {
            return false;
        }
        // Both flows key their pending state the same way ((chat, user)),
        // so only one of them should ever actually claim a given pick --
        // `isAwaitingFormat` decides which, rather than trying `menu` only
        // when `convert_flow` misses (that would make convert_flow's own
        // "prompt isn't active anymore" reply fire on a pick that was
        // actually meant for the menu).
        if (pending_conversions.isAwaitingFormat(now, msg.chat_id, msg.user_id)) {
            convert_flow.handleChoicePicked(connector, a, io, config.tmp_dir, pending_conversions, now, msg, picked);
        } else {
            menu_sessions.handleChoicePicked(menu_runner, now, menuCtx(connector, a, pool, config, chat_id, identity_id, now, msg, io, digest_scheduler, pending_conversions, pending_undos), picked);
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

    // Storage sense's flood-watermark sleep mode (`storage_sense.zig`):
    // pauses everything below this point except the owner's own `/storage`
    // commands, so they can check status/disable autopilot/clean up by hand
    // without SSH. `recordMessage`/`bcast.publish`/keyword alerts already
    // ran in `processMessageTask` before `handleMessage` was ever called
    // (see this function's own doc comment on the owner/allowlist gate
    // above), so message history is preserved through a sleep episode --
    // only the write-heavier stuff below (LLM replies, tool calls, command
    // dispatch) is what's actually skipped.
    if (storage_sense.isSleepModeActive(pool, a)) {
        const is_storage_cmd = std.mem.eql(u8, text, "/storage") or std.mem.startsWith(u8, text, "/storage ");
        if (!(is_owner and is_storage_cmd)) {
            if (storage_sense.shouldNotifySleepOnce(io, msg.chat_id)) {
                reply(connector, a, msg.chat_id, msg.message_id, "Temporarily paused for storage maintenance.");
            }
            return false;
        }
    }

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

    // Custom command aliases (ROADMAP.md's Phase 19) -- "/gm" re-dispatches
    // as if the user had typed its saved expansion (plus any trailing text
    // typed after the alias name) directly. Expanded exactly once, not
    // recursively: if the expansion itself happens to start with another
    // alias's name, it's dispatched as literal text from here on rather
    // than re-expanded -- a simple, safe rule that rules out alias loops
    // by construction, not by a depth counter. `isReservedCommandName`
    // means a real built-in command is never shadowable, so this lookup
    // can never change the meaning of an existing command even if the
    // query below returns a row (it never will for one).
    if (feature_flags.isEnabled(pool, "power_tools") and text.len > 1 and text[0] == '/') {
        const cmd_end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
        const cmd_name = text[1..cmd_end];
        if (command_aliases.get(pool, a, chat_id, cmd_name) catch null) |alias| {
            const trailing = std.mem.trim(u8, text[cmd_end..], " ");
            text = if (trailing.len > 0)
                std.fmt.allocPrint(a, "{s} {s}", .{ alias.expansion, trailing }) catch text
            else
                alias.expansion;
        }
    }

    // A plain message (or reply) arriving while (chat, user) has an open
    // `/menu` prompt waiting on free-form input (e.g. Group Administration's
    // "reply with the person you want to kick") — consumed here, before
    // normal dispatch, so it never needs its own slash command. `/cancel`
    // is deliberately exempted so it always reaches its own handler below
    // (one of whose fallback tiers is exactly this session), rather than
    // being swallowed as a failed target-resolution attempt.
    if (!std.mem.eql(u8, text, "/cancel") and
        menu_sessions.handleAwaitingInputMessage(menu_runner, menuCtx(connector, a, pool, config, chat_id, identity_id, now, msg, io, digest_scheduler, pending_conversions, pending_undos)))
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

    // Phase 21: a command typed directly in a room bound to a target chat
    // (`/manage bind`, 1:1 as of Phase 20) runs against that target with no
    // `/as <id>` prefix — same allow-list and authorization `/as` itself
    // uses, via the identical relay/redirect mechanism. Checked once here,
    // before the big dispatch chain, since it needs to match any of
    // `as_relayable_commands` generically rather than one literal string;
    // returns `null` silently for anything that isn't both bound and
    // allow-listed, so ordinary chatting (or an unbound room, or a
    // non-relayable command) falls straight through to normal dispatch
    // below, unchanged. `feature_flags.isEnabled(pool, "management_rooms")`
    // gates this the same as `/manage`/`/as` themselves.
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
            );
        }
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
    } else if (std.mem.eql(u8, text, "/briefing") or std.mem.startsWith(u8, text, "/briefing ")) {
        if (!feature_flags.isEnabled(pool, "briefings")) return false;
        handleBriefingCommand(connector, a, io, pool, chat_id, briefing_scheduler, now, max_message_len, msg.chat_id, msg.message_id, text);
    } else if (std.mem.eql(u8, text, "/summary") or std.mem.startsWith(u8, text, "/summary ")) {
        // Gated with `/digest` rather than on its own flag: it's the same
        // summarizer over a caller-named window (see `handleSummaryCommand`),
        // so a chat that has turned summarization off means both.
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
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "mute")) return false;
        const vis = resolveVisibility(pool, a, chat_id, std.mem.trim(u8, text["/mute".len..], " "), is_bot_admin);
        group_admin.mute(connector, a, msg, now, auditCtxWithVisibility(pool, pending_undos, chat_id, identity_id, msg, vis.visibility));
    } else if (std.mem.eql(u8, text, "/unmute") or std.mem.startsWith(u8, text, "/unmute ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "unmute")) return false;
        const vis = resolveVisibility(pool, a, chat_id, std.mem.trim(u8, text["/unmute".len..], " "), is_bot_admin);
        group_admin.unmute(connector, a, msg, now, auditCtxWithVisibility(pool, pending_undos, chat_id, identity_id, msg, vis.visibility));
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
    } else if (std.mem.eql(u8, text, "/promote") or std.mem.startsWith(u8, text, "/promote ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        // Owner-only, not `checkGroupAdminAccess` — granting real admin
        // rights is more consequential than mute/kick/pin, and Telegram's
        // own admin flag doesn't tell us whether a given admin actually has
        // permission to add further admins themselves (see
        // `group_admin.promote`'s doc comment). Deliberately not extended
        // to bot admins/`/sudo` either, same reasoning.
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
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "kick")) return false;
        handleKickBanCommand(connector, a, pool, chat_id, identity_id, pending_undos, is_bot_admin, now, msg, text, "/kick", .kick);
    } else if (std.mem.eql(u8, text, "/ban") or std.mem.startsWith(u8, text, "/ban ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "ban")) return false;
        handleKickBanCommand(connector, a, pool, chat_id, identity_id, pending_undos, is_bot_admin, now, msg, text, "/ban", .ban);
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
    } else if (std.mem.eql(u8, text, "/slowmode") or std.mem.startsWith(u8, text, "/slowmode ")) {
        // ROADMAP.md's Phase 24. Gated with the same "group_admin" flag as
        // /mute/etc -- it's the same moderation-tier feature set, not its
        // own toggle.
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "slowmode")) return false;
        handleSlowmodeCommand(connector, a, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/permission") or std.mem.startsWith(u8, text, "/permission ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "permission")) return false;
        handlePermissionCommand(connector, a, pool, chat_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/tag") or std.mem.startsWith(u8, text, "/tag ")) {
        if (!feature_flags.isEnabled(pool, "group_admin")) return false;
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, true, "tag")) return false;
        handleTagCommand(connector, a, pool, now, msg, text);
    } else if (std.mem.startsWith(u8, text, "/token")) {
        if (!auth.checkTokenGrantAccess(connector, a, config, msg, is_bot_admin)) return false;
        handleToken(connector, a, pool, chat_id, identity_id, pending_undos, now, msg, text);
    } else if (std.mem.eql(u8, text, "/credit") or std.mem.startsWith(u8, text, "/credit ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleCredit(connector, a, pool, chat_id, identity_id, pending_undos, now, msg, text);
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
    } else if (std.mem.eql(u8, text, "/storage") or std.mem.startsWith(u8, text, "/storage ")) {
        // Hidden, owner-only -- same `/sudo` pattern as
        // `reserved_command_names_extra`'s own doc comment describes:
        // never in `public_commands`, never in `help_text`/`help_text_admin`,
        // reserved only so `/alias` can't shadow it. Strictly owner, not
        // extended to bot admins/`/sudo` -- this can prune/resample real
        // chat history and flip the ladder's autopilot switch, more
        // consequential than anything a bot admin is trusted with elsewhere.
        if (!is_owner) return false;
        handleStorageCommand(connector, a, config, pool, io, llm_provider, chat_id, identity_id, msg, text, now);
    } else if (std.mem.eql(u8, text, "/whois") or std.mem.startsWith(u8, text, "/whois ")) {
        if (!auth.isOwnerOrBotAdmin(config, connector.platform(), msg.user_id, is_bot_admin)) return false;
        handleWhoisCommand(connector, a, config, pool, now, msg, text);
    } else if (std.mem.eql(u8, text, "/chatinfo") or std.mem.startsWith(u8, text, "/chatinfo ")) {
        // Chat-scoped admin tier, not `/whois`'s bot-wide one: this answers
        // a question about *this* chat, and its whole purpose is to feed
        // `/manage bind`, which authorizes against the target chat's admins.
        // No token fallback — a token buys one moderation action (see
        // `checkGroupAdminAccess`), not a lookup.
        if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "chatinfo")) return false;
        handleChatInfoCommand(connector, a, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/manage") or std.mem.startsWith(u8, text, "/manage ")) {
        if (!feature_flags.isEnabled(pool, "management_rooms")) return false;
        handleManageCommand(connector, a, config, pool, chat_id, identity_id, msg, text);
    } else if (std.mem.eql(u8, text, "/as") or std.mem.startsWith(u8, text, "/as ")) {
        // ROADMAP.md's Phase 9 slice 2 (widened in Phase 20: no binding
        // required any more). Everything that can reject the request
        // (parsing, the relayable-command allow-list, and the target-chat
        // admin check) happens in `resolveAsCommand`;
        // if it returns a plan, the command is replayed by calling this
        // very function again, with the *target* chat's ids in place and a
        // `ReplyRedirect`-wrapped connector so the relayed handler's own
        // `sendMessage(a, msg.chat_id, ...)` surfaces back here instead of
        // in the target chat. No handler knows any of this happened.
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
        );
    } else if (std.mem.eql(u8, text, "/redact") or std.mem.startsWith(u8, text, "/redact ")) {
        // Per-mode gating happens inside handleRedactCommand itself (regex
        // mode is stricter than the other modes) rather than here, since
        // which gate applies depends on parsing the mode first.
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
    } else if (std.mem.eql(u8, text, "/drafts")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleDraftsListCommand(connector, a, config, pending_drafts, msg, now);
    } else if (std.mem.eql(u8, text, "/approve") or std.mem.startsWith(u8, text, "/approve ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleApproveCommand(connector, a, config, telegram_user, pending_drafts, msg, text, now);
    } else if (std.mem.eql(u8, text, "/discard") or std.mem.startsWith(u8, text, "/discard ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return false;
        handleDiscardCommand(connector, a, config, pending_drafts, msg, text);
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
        // Phase 14 (ROADMAP.md): messaging assistance modes -- thin,
        // reliable command surfaces over the existing Q&A path (the model
        // already translates zero-shot; this just makes it a documented,
        // predictable command rather than relying on natural language).
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
        // ROADMAP.md's Phase 16: group/Telegram quality-of-life. No LLM call
        // involved (plain string splitting + a native API call), so unlike
        // the messaging-mode commands above this needs no owner/credits
        // gate -- same "open to anyone allowed in the chat" tier as
        // /wordcloud//stats.
        if (!feature_flags.isEnabled(pool, "polls")) return false;
        handlePollCommand(connector, a, msg, text);
    } else if (text.len > 0 and text[0] == '/') {
        // Unrecognized slash command: ignore rather than forwarding to the
        // LLM as if it were a question.
        return false;
    } else if (connector.platform() == .telegram_user) {
        // Phase D: `reply_autonomy` (migration `0043_reply_autonomy.sql`)
        // is the deliberate, explicit gate for any auto-response through
        // this connector — NOT `isAddressedToBot` (every message this
        // connector sees looks like a private 1:1 DM to it right now, and
        // combined with owners bypassing the allowlist/credits gates
        // everywhere, that would mean any message from the owner's own
        // account auto-answers with zero opt-in; confirmed live
        // (2026-08-18) against the owner's own Saved Messages chat before
        // this got built — see git history for that incident). `.off` is
        // both the resolved default and a fail-closed no-op, same as
        // before this existed; `.draft`/`.auto` are opt-in per chat or
        // globally via `/autonomy`.
        handleTelegramUserAutoReply(connector, a, config, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, now, max_message_len, msg, text, owner_notify, pending_drafts);
        return false;
    } else if (isAddressedToBot(a, pool, chat_id, msg, text)) {
        // A message that's *just* a YouTube/Instagram/X link is already
        // handled by `checkVideoDownload` in `processMessageTask` (if
        // enabled) -- asking the LLM to also comment on a bare URL burns a
        // real API call for nothing. Only skips when the link IS the whole
        // message (after trimming whitespace); a link with real commentary
        // around it ("what do you think of this: <url>") still gets a
        // normal answer, since that's a real question, not just a drop.
        if (video_download.findLink(text)) |link| {
            if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), link)) return false;
        }

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
        replyWithAnswer(connector, a, pool, chat_id, identity_id, llm_provider, embeddings_client, tool_ctx, tools, system_prompt, io, now, retention_messages, max_message_len, msg.chat_id, msg.message_id, asker, resolved.text, replied_to, resolved.placeholder_id, dyn.streaming, show_thinking, dyn.vision_enabled, dyn.documents_enabled, dyn.max_tokens_override, dyn.history_messages, in_flight);
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
/// Generous enough for "San Francisco, California, United States" while
/// still bounding what gets sent to the geocoder. Unlike the magic word
/// this deliberately allows spaces -- almost every real place name has one.
const max_location_len = 100;

/// `/location` (view) / `/location <place>` (set) / `/location off`
/// (clear). Viewing is open to anyone in the chat, changing is owner-only,
/// the same split `/magicword` and `/persona` already use.
///
/// The place name is stored verbatim and only resolved at briefing time by
/// Open-Meteo's geocoder, so this deliberately does *not* validate that the
/// place exists: that would mean a network round trip on every `/location`
/// call, and a geocoder outage would then block setting a location at all.
/// A place that never resolves simply produces briefings with no weather
/// section (see `briefingWeatherLine`), which is the same degradation as a
/// transient lookup failure.
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

const max_welcome_len = 1000;

/// `/welcome <text>` / `/welcome off` — see ROADMAP.md's Phase 16. Same
/// view-open-to-anyone/change-owner-only access model as `/persona`: a
/// welcome message posts automatically whenever someone new joins, so
/// letting any chat member rewrite it is a bigger lever than a magic word.
/// `{name}` in `text` is a literal placeholder, substituted per new member
/// at send time by `sendWelcomeMessages` below -- not expanded here.
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
/// joined member in `msg.joined_users` -- called from `processMessageTask`
/// right after the housekeeping checks, before normal dispatch (a join
/// service message has no `text`, so it would never reach `handleMessage`'s
/// command chain anyway). A no-op, not an error, when no welcome message is
/// configured or the chat's `welcome_messages` module is disabled -- most
/// chats never opt in, and this runs on every join regardless.
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

// ---------------------------------------------------------------------
// Phase 17 (ROADMAP.md): finance trackers -- expenses, budgets,
// subscriptions. Shared parsing/formatting helpers for all three below;
// command handlers follow after `handleThinkingCommand`.
// ---------------------------------------------------------------------

const default_currency = "USD";

/// Parses a plain decimal amount ("12", "12.5", "12.50") into integer
/// cents -- real money, so this is a hand-rolled parser rather than
/// `std.fmt.parseFloat` + rounding, which would reintroduce exactly the
/// float-precision risk `0029_expenses.sql`'s doc comment explicitly
/// rejects. Rejects negative/zero, more than 2 fractional digits, and
/// anything that isn't plain digits and at most one `.`.
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
    const cents = whole * 100 + frac;
    if (cents <= 0) return null;
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
}

/// "1250 USD" -> "12.50 USD" -- always shows the ISO currency code rather
/// than guessing a symbol, matching how `tools/currency.zig`/`weather.zig`
/// already handle units elsewhere in this codebase (explicit codes, no
/// locale guessing).
///
/// The fractional part is cast to `u8` before formatting -- zero-padding a
/// *signed* integer via `{d:0>2}` makes Zig 0.16's formatter print an
/// explicit `+` for non-negative values (to stay unambiguous with a
/// zero-padded negative), which every other zero-padded `{d:0>2}` call
/// elsewhere in this codebase (`civil_time.zig`, `menu.zig`, `log.zig`)
/// never hit because they all format already-unsigned `u8` clock fields.
/// Found by this file's own test, not by inspection.
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

/// Parses a subscription's recurrence shorthand -- "30d", "1w", "1mo",
/// "1y" -- into a plain day count. Longest-suffix-first ("mo" checked
/// before a bare unit) so "1mo" doesn't parse as "1m" + trailing "o".
/// Deliberately a different, smaller unit set than
/// `reminder_format.zig`'s own duration parser (seconds/minutes/hours),
/// since a subscription's cadence is always day-or-longer.
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
/// containing `now` -- backs `/expense summary`'s and `/budget list`'s
/// "this month" window. Naive UTC, same tradeoff `ctx.now`'s other
/// consumers (digests, scheduler) already make.
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

/// Generic "creator or the bot owner" authorization for any chat-shared,
/// per-record feature (expenses, subscriptions, aliases, templates) --
/// same "shared, but only whoever added it (or the owner) may remove"
/// model `/note delete`/`/keyword remove` already use.
fn isRecordOwnerOrCreator(config: *const config_mod.Config, connector: iface.Connector, msg: iface.Message, identity_id: i64, record_identity_id: i64) bool {
    return record_identity_id == identity_id or auth.isOwner(config, connector.platform(), msg.user_id);
}

/// Per-chat expense tracker (ROADMAP.md's Phase 17) -- `/expense add
/// <amount> <category> [description...]`, `/expense list [category]`,
/// `/expense summary [all]` (defaults to this calendar month), `/expense
/// delete <id>`. No currency conversion or per-chat currency setting in
/// v1 -- every amount is recorded in `default_currency` (USD) and sums
/// add across whatever's actually recorded, same documented limitation
/// `store/expenses.zig`'s own doc comment flags. Receipt logging ("log
/// this receipt" with a photo attached) needs no separate OCR plumbing
/// here -- Phase 10's vision support already lets the model read the
/// photo during normal Q&A; it just calls `set_expense` (see
/// `tools/set_expense.zig`) with what it read, the same as if the user
/// had typed the amount themselves.
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

/// Per-category breakdown + grand total since `since_ts` (null = all
/// time), each category's line also showing its budget (if one's set)
/// and whether it's over -- reuses `expenses.totalsByCategory`/
/// `budgets.listForChat` rather than a joined SQL query, since both
/// lists are already small (a personal chat's category count) and this
/// keeps `store/expenses.zig`/`store/budgets.zig` independent of each
/// other.
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

/// Per-chat monthly budgets (ROADMAP.md's Phase 17) -- `/budget set
/// <category> <amount>`, `/budget list`, `/budget remove <category>`.
/// Same view-open-to-anyone/change-owner-only access model as `/persona`/
/// `/welcome`: a budget is a shared chat-wide policy, not a personal
/// item, so letting any member rewrite it is a bigger lever than logging
/// their own expense.
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

/// Per-chat subscription/recurring-cost ledger (ROADMAP.md's Phase 17) --
/// `/subscription add <name> <amount> every <interval>`, `/subscription
/// list` (each entry's monthly-equivalent cost plus a running total),
/// `/subscription remove <id>`. See `store/subscriptions.zig`'s doc
/// comment for why this deliberately doesn't also fire its own reminders.
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

    // "<name...> <amount> every <interval>" -- name may be multiple words
    // (e.g. "Amazon Prime"), so this parses from the *end*: the last two
    // tokens must be "every <interval>", the token before that the
    // amount, and everything before that the name. Same "join everything
    // between fixed anchors" shape `/alert`'s own multi-word-subject
    // parsing already uses.
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

// ---------------------------------------------------------------------
// Phase 19 (ROADMAP.md): power-user tools -- custom command aliases and
// saved prompt templates. Joke/riddle/trivia/word-of-day/motivate are
// implemented directly in `handleMessage`'s dispatch chain above (they're
// thin one-liners over the existing `handleModeCommand` from Phase 14,
// with no state of their own worth a dedicated handler function).
// ---------------------------------------------------------------------

/// `/alias add <name> <command/text>` / `/alias list` / `/alias remove
/// <name>` -- see the alias-expansion step in `handleMessage` for how a
/// saved alias actually gets used. Same "shared, but only whoever added
/// it (or the owner) may remove" model `/note delete` already uses.
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

/// `/template save <name> <text>` / `/template list` / `/template use
/// <name> [extra text]` / `/template delete <name>` -- `use` routes the
/// saved text (plus any extra text appended) through the exact same
/// `handleModeCommand` pipeline `/eli5`/`/brainstorm` use, since "use a
/// saved prompt" is just another way of asking a question. Same "shared,
/// but only whoever added it (or the owner) may delete" access model
/// `/alias remove` uses.
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
/// shown — same view-open-to-anyone/change-owner-only access model as
/// `/persona` (a chat member flipping this is a smaller lever than a full
/// persona rewrite, but still not something to leave open to anyone).
/// `/tdlogin status|phone <number>|code <digits>|password <password>` —
/// bot-chat fallback for driving the personal-account connector's login
/// (see `platform/telegram_user.zig`'s doc comment; warden-ui's own login
/// form at `/api/v1/telegram-user/*` is the primary path). Owner-only,
/// checked here rather than at the dispatch site since every sibling
/// owner-only command (`/scraper`, etc.) follows the same "check inside
/// the handler" shape.
///
/// The `code` subcommand strips every non-digit character before passing
/// the result to `submitAuthCode` — this is the obfuscation workaround
/// itself (see `Platform.telegram_user`'s doc comment and the plan sent to
/// the owner): Telegram's own anti-phishing detection can silently
/// invalidate a login code the moment its bare digits appear as a message
/// in *any* Telegram chat, including one with this bot, so the owner is
/// expected to type it with digits separated ("1 2 3 4 5") or otherwise
/// broken up rather than as the bare code Telegram displayed.
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

/// Shared by `/tdlogin logout` and the standalone `/tdlogout` alias (same
/// command, two spellings — `/tdlogout` because that's what got asked for
/// directly, `/tdlogin logout` because it fits the existing status/phone/
/// code/password subcommand family). `.none` is refused rather than
/// forwarded to `conn.logOut()`: the connector's `client_id` is still null
/// at that point (no `ensureClient()` call has run yet), and `send()`
/// unconditionally unwraps `client_id.?` — a real crash, not just a
/// pointless no-op, if this ever raced a fresh startup.
fn performTdLogout(connector: iface.Connector, a: std.mem.Allocator, conn: *telegram_user_platform.TelegramUserConnector, msg: iface.Message) void {
    if (conn.authState() == .none) {
        reply(connector, a, msg.chat_id, msg.message_id, "The personal-account connector hasn't started yet — nothing to log out of.");
        return;
    }
    conn.logOut();
    reply(connector, a, msg.chat_id, msg.message_id, "Logging out of the personal-account session — Telegram will clear it locally and end it server-side, same as removing the device from your active sessions list. Log back in any time with /tdlogin phone <number>.");
}

/// `/sendas <chat_id> <text...>` / `/tdsend <chat_id> <text...>` — same
/// command, two spellings, one implementation (`command_prefix` is which
/// one the caller matched). `/sendas` is Phase C of the plan sent to the
/// owner: a manual, owner-only command that sends a real message through
/// the personal-account connector, proving the send path (and, longer
/// term, rate-limiting) before any auto-drafting/autonomous send existed.
/// `/tdsend` is the same thing under the `/td*` family's naming
/// convention (`/tdlogin`/`/tdchats`/`/tdsearch`/`/tdsummary`/`/tdlogout`),
/// added by direct request once that family existed and `/sendas` was the
/// one outlier not matching it — both are kept working rather than
/// breaking `/sendas` for anyone already using it.
///
/// `chat_id` is TDLib's own native chat id (not the Bot API's — see
/// `Platform.telegram_user`'s doc comment on why these are different
/// numbering schemes for "the same" real-world chat) — findable via
/// `/tdchats`/`/tdsearch`, warden-ui's admin chat list, or simply by seeing
/// which chat a real inbound message from that contact recorded once one
/// arrives, since `store/chats.upsertChat` runs for every connector
/// uniformly. Deliberately id-only, not name-resolved like `/tdsummary`
/// (`chat_summary.resolveChat`): a name can contain spaces, which would
/// make "where does the target end and the message begin" ambiguous for a
/// two-argument command the way it isn't for `/tdsummary`'s single
/// argument. Name-based targeting instead lives in the `send_personal_
/// message` LLM tool, where `chat`/`message` are already separate
/// structured fields with no such ambiguity.
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

/// Chats-per-page for `/tdchats`' pager and its Prev/Next buttons —
/// direct-user-request feature (2026-08-18, an account with "dozens of
/// chats" made the old single-message dump with a "... and N more (not
/// shown)" tail actually lose information). 15 keeps a page's button
/// message comfortably under Telegram's 4096-char limit even for long
/// titles, while still fitting several pages' worth of a merely
/// medium-sized chat list without excessive tapping.
const tdchats_per_page = 15;

/// `callback_data` prefix for a `/tdchats` pager button — see
/// `handleTdChatsPagePicked`. The page number is everything after the
/// colon, so `"tdchats_page:2"` means "render page index 2 (0-based)".
const tdchats_page_prefix = "tdchats_page:";

/// Builds one page's message text + Prev/Next buttons from an already-
/// resolved chat list — shared by `/tdchats`' initial send,
/// `handleTdChatsPagePicked`'s re-render on a button press, and (as a
/// single un-paginated call with `page = 0`) `/tdsearch`'s typically-short
/// result list. `chats` is assumed already sorted (see
/// `chat_summary.allChatsSortedByTitle`) — this function only slices and
/// renders, it never reorders.
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

/// A `/tdchats` pager button press — consumed the same way
/// `handleDraftChoicePicked` consumes a draft Approve/Discard press
/// (checked against `msg.choice_picked` right alongside it in
/// `handleMessage`'s dispatch, "false for anything not mine" contract).
/// Stateless by design: the page number lives entirely in the button's own
/// `callback_data`, so there's no per-owner pager session to expire or
/// leak — a re-render just re-fetches and re-sorts the current chat list
/// fresh, same as a brand new `/tdchats` would.
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
/// paginated (see `tdchats_per_page`) with Prev/Next buttons, so the owner
/// can find a `/sendas`/`/tdsummary` target without already knowing a raw
/// TDLib chat id. Owner-only, same bar as every other `/td*`/`/sendas`
/// command. `/tdsearch <name>` (see `handleTdSearchCommand`) narrows this
/// down directly instead of paging through it.
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

/// `/tdsearch <name>` — direct-user-request companion to `/tdchats`' pager:
/// jump straight to the chats matching a name instead of paging through
/// everything. Deliberately un-paginated (unlike `/tdchats`) — a
/// case-insensitive title substring is expected to narrow things down to a
/// handful of chats, not dozens, so `renderTdChatsPage`'s single-page call
/// here almost always has no Next button at all; a search somehow matching
/// enough to need a second page still gets one (`renderTdChatsPage` doesn't
/// care where its input came from), it just isn't the common case this
/// command is built for.
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

/// `/tdsummary <chat id or name>` — direct-user-request feature: summarize
/// a personal-account chat's unread messages on demand and mark them read,
/// so opening Telegram afterward shows a clean chat rather than a pile the
/// owner already got the gist of from Warden. `<chat>` accepts the same raw
/// TDLib id `/tdchats` prints, or (see `chat_summary.resolveChat`) any
/// case-insensitive substring of a chat's title — ambiguous matches list
/// their titles back rather than guessing.
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

/// Splits a trailing `--all` token off `/tdsummary`'s argument text —
/// direct owner request (2026-08-19) for a way to summarize the last 100
/// messages regardless of read state instead of just unread ones. A
/// trailing, space-separated token specifically (not a bare substring
/// match) so a chat literally named "...--all" can't accidentally trip
/// this — vanishingly unlikely, but free to guard against.
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
/// Telegram) — `null` if, somehow, no `.telegram` entry exists in
/// `config.owners` (shouldn't happen: `Config.load` always adds one
/// unconditionally from `WARDEN_TELEGRAM_OWNER_ID`).
fn ownerTelegramNativeId(config: *const config_mod.Config) ?[]const u8 {
    for (config.owners) |entry| {
        if (entry.platform == .telegram) return entry.owner_id;
    }
    return null;
}

/// The `identities` row for the Bot API owner — the identity
/// `user_settings.reply_autonomy_default` (the global `/autonomy` dial) and
/// every other personal-settings row is keyed on, same identity the
/// settings UI resolves via its own login session. Not cached: this is one
/// cheap upsert-or-fetch, called at most once per incoming personal-account
/// message.
fn resolveOwnerIdentityId(pool: *store_pool.PgPool, config: *const config_mod.Config, now: i64) !i64 {
    const native_id = ownerTelegramNativeId(config) orelse return error.NoTelegramOwnerConfigured;
    return identities.getOrCreateMinimal(pool, .telegram, native_id, "Owner", null, false, now);
}

/// `/autonomy` — Phase D of the plan sent to the owner: the off/draft/auto
/// dial for `reply_autonomy` (migration `0043_reply_autonomy.sql`). Three
/// forms:
///   `/autonomy` — shows the current global default.
///   `/autonomy <off|draft|auto>` — sets the global default.
///   `/autonomy <chat id> <off|draft|auto|clear>` — sets (or clears) a
///     per-chat override. `<chat id>` is TDLib's own native chat id, the
///     same id space `/sendas`/`/tdchats`/`/approve`/`/discard` all use —
///     the override can only attach to a chat Warden already has a `chats`
///     row for (see `store/chats.getByNative`), i.e. one that's exchanged
///     at least one message with the personal account already.
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
        const status = std.fmt.allocPrint(a, "Global reply_autonomy default: {s}\n\nUsage:\n/autonomy <off|draft|auto> — set the global default\n/autonomy <chat id> <off|draft|auto|clear> — per-chat override (see /tdchats for chat ids)", .{@tagName(global)}) catch return;
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
    const level = std.meta.stringToEnum(user_settings.ReplyAutonomy, level_text) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /autonomy <chat id> <off|draft|auto|clear>.");
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
/// `reply_drafts.PendingDrafts`), so the owner doesn't have to remember
/// which chats have one waiting.
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
    out.writer.writeAll("Pending drafts:\n") catch {};
    for (drafts) |d| {
        const preview = if (d.draft_text.len > 200) d.draft_text[0..200] else d.draft_text;
        out.writer.print("\n{s} ({s}):\n{s}\n", .{ d.chat_title, d.native_chat_id, preview }) catch break;
    }
    out.writer.writeAll("\n/approve <chat id> to send, /discard <chat id> to drop.") catch {};
    connector.sendMessage(a, msg.chat_id, out.writer.buffered(), msg.message_id);
}

/// `/approve <chat id>` — sends a pending `reply_autonomy = .draft` draft
/// exactly as generated, through the personal-account connector, and
/// removes it from `pending_drafts`. `<chat id>` is TDLib's native chat id
/// (see /tdchats or /drafts).
fn handleApproveCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    msg: iface.Message,
    text: []const u8,
    now: i64,
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
    const confirmation = std.fmt.allocPrint(a, "Sent to {s}.", .{draft.chat_title}) catch "Sent.";
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

/// `/discard <chat id>` — drops a pending draft without sending it.
fn handleDiscardCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pending_drafts: *reply_drafts.PendingDrafts,
    msg: iface.Message,
    text: []const u8,
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
        reply(connector, a, msg.chat_id, msg.message_id, "Draft discarded.");
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "No pending draft for that chat.");
    }
}

/// The reply-as-me default when no per-chat `/persona` override exists for
/// this chat — deliberately NOT `config.system_prompt`, which describes
/// Warden the bot ("You are Warden, an assistant...") and would produce
/// replies that out themselves as an AI. Used by
/// `handleTelegramUserAutoReply` only.
const default_reply_as_owner_prompt =
    \\You are ghostwriting a reply on behalf of the owner of this Telegram
    \\account, to one of their real contacts, in the owner's voice, as if
    \\the owner typed it themselves. Keep it short and natural, the way a
    \\real person texts -- no AI disclaimers, no "as an AI" framing, no
    \\signing off with a name. If you don't have enough information to
    \\reply confidently, say so briefly rather than guessing or inventing
    \\details.
;

/// `Choice.value` prefixes for the Approve/Discard buttons on a
/// `reply_autonomy = .draft` notification — see `handleTelegramUserAutoReply`
/// (sends them) and `handleDraftChoicePicked` (consumes them). The target
/// native chat id is appended verbatim after the prefix.
const draft_approve_prefix = "draft_approve:";
const draft_discard_prefix = "draft_discard:";

/// Owner-configured `reply_autonomy` for an incoming personal-account
/// message (Phase D of the plan sent to the owner). `.off` (the resolved
/// default until the owner ever touches `/autonomy`) is a pure no-op — see
/// the `.telegram_user` dispatch branch's doc comment in `handleMessage`
/// for exactly why this can't just fall through to `isAddressedToBot`.
/// `.draft` generates a reply and stashes it in `pending_drafts` for
/// `/approve`/`/discard` instead of sending it; `.auto` sends it straight
/// back through `connector` — safe to do unconditionally here since the
/// caller only reaches this function when `connector.platform() ==
/// .telegram_user`.
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
    now: i64,
    max_message_len: usize,
    msg: iface.Message,
    text: []const u8,
    owner_notify: iface.Connector,
    pending_drafts: *reply_drafts.PendingDrafts,
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
        const system_prompt = chat_settings.getSystemPromptOverride(pool, a, chat_id) orelse default_reply_as_owner_prompt;
        const asker: qa.Asker = if (msg.identity) |identity| .{
            .display_name = identity.display_name,
            .username = identity.username,
            .native_id = identity.native_id,
        } else .{
            .display_name = msg.username orelse msg.user_id,
            .username = msg.username,
            .native_id = msg.user_id,
        };
        const enabled_tools = filterEnabledTools(pool, a, tools);
        const raw_answer = qa.answer(llm_provider, embeddings_client, a, tool_ctx, enabled_tools, pool, chat_id, identity_id, system_prompt, max_message_len, asker, text, null, .{}, false, dyn.show_thinking, dyn.vision_enabled, dyn.documents_enabled, dyn.max_tokens_override, dyn.history_messages) catch |err| {
            log.err("reply_autonomy: qa.answer failed for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        break :blk std.mem.trim(u8, raw_answer, " \t\r\n");
    };
    if (answer.len == 0) return;

    switch (autonomy) {
        .off => unreachable,
        .auto => connector.sendMessage(a, msg.chat_id, answer, msg.message_id),
        .draft => {
            const chat_title = msg.chat_title orelse msg.chat_id;
            pending_drafts.set(now, msg.chat_id, chat_title, text, answer, msg.message_id) catch |err| {
                log.err("reply_autonomy: failed to stash a draft for chat {s}: {t}", .{ msg.chat_id, err });
                return;
            };
            const owner_chat_id = ownerTelegramNativeId(config) orelse {
                log.err("reply_autonomy: draft mode is on but no Bot API owner id is configured to notify", .{});
                return;
            };
            const incoming_preview = if (text.len > 300) text[0..300] else text;
            const notify_text = std.fmt.allocPrint(
                a,
                "\u{1f4ac} Draft reply ready\nChat: {s} ({s})\nThey said: \"{s}\"\n\nDraft: \"{s}\"",
                .{ chat_title, msg.chat_id, incoming_preview, answer },
            ) catch return;
            // Buttons, not "type /approve <chat id>" — see
            // `handleDraftChoicePicked` for what picking one does.
            // `Choice.value` becomes Telegram's `callback_data` verbatim
            // (`Connector.sendChoicePrompt`'s doc comment), so the target
            // chat id travels on the button itself; no separate
            // (control chat, prompt message) lookup is needed the way
            // `audit_notify.PendingUndos` needs one; `pending_drafts` is
            // already keyed by this same native chat id.
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
/// `reply_autonomy = .draft` notification (see `handleTelegramUserAutoReply`
/// and the `draft_approve_prefix`/`draft_discard_prefix` doc comment) —
/// returns `false` for anything else (a stray pick, or one of
/// `audit_notify`/`convert_flow`/`menu`'s own buttons) so `handleMessage`
/// falls through to its other `choice_picked` consumers unchanged, same
/// contract as `audit_notify.handleUndoPicked`.
fn handleDraftChoicePicked(
    connector: iface.Connector,
    a: std.mem.Allocator,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    pending_drafts: *reply_drafts.PendingDrafts,
    now: i64,
    msg: iface.Message,
    picked: iface.ChoicePicked,
) bool {
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
        const confirmation = std.fmt.allocPrint(a, "Sent to {s}.", .{draft.chat_title}) catch "Sent.";
        connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        return true;
    }
    if (std.mem.startsWith(u8, picked.value, draft_discard_prefix)) {
        const native_chat_id = picked.value[draft_discard_prefix.len..];
        if (pending_drafts.discard(native_chat_id)) {
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
    identity_id: i64,
    pending_undos: *audit_notify.PendingUndos,
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
    const prev_balance = chat_members.getTokens(pool, chat_id, target.id, 0);
    chat_members.setTokens(pool, chat_id, target.id, count) catch |err| {
        log.err("token: failed to set tokens: {t}", .{err});
        return;
    };
    audit_notify.recordAndNotify(connector, a, pool, pending_undos, now, chat_id, msg.chat_id, identity_id, msg.username orelse msg.user_id, .{ .token_grant = .{ .target_identity_id = target.id, .target_label = target.display_name, .prev_balance = prev_balance, .new_balance = count } });
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
/// checked by the caller. `chat_id` is only used to resolve which bound
/// room (if any) an audit entry posts into — credits themselves aren't
/// chat-scoped.
fn handleCredit(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    pending_undos: *audit_notify.PendingUndos,
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
    const prev_balance = identities.getCredits(pool, target.id, 0);
    identities.setCredits(pool, target.id, count) catch |err| {
        log.err("credit: failed to set credits: {t}", .{err});
        return;
    };
    audit_notify.recordAndNotify(connector, a, pool, pending_undos, now, chat_id, msg.chat_id, identity_id, msg.username orelse msg.user_id, .{ .credit_grant = .{ .target_identity_id = target.id, .target_label = target.display_name, .prev_balance = prev_balance, .new_balance = count } });
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
/// member's messages, `/slowmode off` clears it (stored as 0, same
/// "0/absent both mean unset" convention as `rate_limits.zig`'s doc
/// comment). Permission is already checked by the caller. See
/// `checkSlowMode` (in `processMessageTask`) for where this is actually
/// enforced.
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

/// Order-independent tokenizer for `/permission`'s arg string, same style
/// as `parseBalanceAndUsernameArgs` above -- a `@`-prefixed token is the
/// target, a `+`/`-`-prefixed token is the permission spec, and the first
/// remaining token (there's at most one meaningful one) is the optional
/// duration.
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

/// `/permission [<duration>] <+|-><letters> <@user|reply>` — see
/// `permission_usage` for the full grammar/enforcement-gap text (also sent
/// back verbatim on every successful change, since the plan for this
/// command was explicit that partial enforcement must be said plainly
/// rather than implied to be complete). Permission (admin-tier) is already
/// checked by the caller.
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

    // Best-effort live enforcement -- `error.Unsupported` (no granular
    // permission concept on this platform at all, e.g. XMPP) is expected
    // and not worth alarming about; anything else is a real failure worth
    // a log line, but the bitmask itself is already saved either way (see
    // `interface.zig`'s `restrictChatMemberPermissions` doc comment).
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

/// `/tag @user <text>` / `/tag @user off` (or reply to the target's
/// message instead of `@user`) — Telegram's `setChatAdministratorCustomTitle`,
/// which only works on chat *administrators* (no Bot API concept of a
/// custom title for an ordinary member); Matrix/XMPP have no equivalent
/// primitive at all (`Connector.setChatAdminTitle`'s vtable slot is null
/// for both, so this always reports `error.Unsupported` there). Permission
/// is already checked by the caller.
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

/// `/storage` dispatch — hidden, owner-only (checked by the caller). See
/// `storage_sense.zig`'s module doc comment for the ladder this manages and
/// `storage_usage` above for the exact subcommand shapes.
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
    // No `/storage cleanup versions` -- Docker image/build-cache cleanup
    // stays a host-side ops concern (a cron/script outside the container),
    // not something warden reaches for via a Docker socket it deliberately
    // doesn't have.
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

/// Parses an optional leading `<chat id>` token off `rest` (warden's own
/// internal id, same convention `/manage bind`/`/chatinfo` use), defaulting
/// to the current chat when absent — mirrors `/autonomy`'s existing
/// "no argument means here" convention rather than inventing a `here`
/// keyword. Returns the resolved chat id and whatever's left of `rest`.
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
    };
}

/// `/chatinfo [native chat id]` — the chat-side counterpart to `/whois`.
/// With no argument it reports the chat it was sent in; with one it looks up
/// a chat on this platform by its platform-native id.
///
/// Exists because warden's internal `chats.id` had no discoverable surface.
/// `/manage bind <chat id>` takes that internal id (see
/// `handleManageCommand`'s doc comment for why it can't take a native one),
/// but the only place internal ids were ever printed was `/manage list`,
/// which lists chats *already bound to this room* — so binding the first
/// chat meant querying Postgres by hand to translate a native id nobody
/// could otherwise resolve. That is the gap this closes, and the argument
/// form is the translation step itself.
///
/// Read-only, and deliberately resolves through `chats.getByNative` rather
/// than `upsertChat`: asking about a chat warden has never seen must answer
/// "no record", not create one (same reasoning as `/whois`'s
/// `create_if_missing = false`).
///
/// Platform is always the caller's own — a native id is only meaningful
/// within its platform, and cross-platform management is unsupported
/// everywhere else too (see `handleManageCommand`).
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

/// `/manage bind|unbind <chat id>` / `/manage list` — see ROADMAP.md's
/// Phase 9. `<chat id>` is warden's own internal `chats.id` (see
/// `/manage list`), not the platform-native chat id — no chat has a stable,
/// always-present short handle a human could type otherwise (Telegram
/// channels/private groups often have no public @username). bind/unbind are
/// authorized against the *target* chat's admin status, not the current
/// (control) room's — see `auth.isOwnerOrLiveAdminOfChat`'s doc comment.
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

/// Commands `/as <chat id> <command>` will replay against a chat, and (as
/// of Phase 21) that a bound management room's own direct dispatch
/// (`resolveDirectRoomCommand`) will run with no `/as` prefix at all — an
/// explicit allow-list, not a deny-list, because this is the one surface
/// that lets someone drive an admin action in a chat they aren't sitting
/// in: anything not thought about here fails closed.
///
/// A command qualifies when both of these hold:
///
///   1. Its effect is *chat-scoped* — it acts on, configures, or reports on
///      one chat, which is what "run this against chat #7" can even mean.
///      (`/whois`, `/memory`, `/addadmin` and friends are bot-wide or
///      per-identity; relaying them would be a no-op dressed up as an
///      action.)
///   2. It doesn't need a *message* in the target chat to point at.
///      `asRelayedMessage` carries the operator's reply target *user*
///      across (a user id means the same thing in any chat) but drops the
///      reply target *message* (a message id doesn't), so `/pin` and
///      `/delete` have nothing to bite on and are left out rather than
///      silently misfiring. `/redact` was excluded here too until Phase
///      21 — re-reading `handleRedactCommand`, none of its four modes
///      (regex/text/reply-scoped-last-N/plain-last-N) actually need a
///      *message* id, only ever a user id (via `replyTarget`) or a plain
///      count/pattern, both of which survive the relay fine — so it's
///      included now; the earlier exclusion was overcautious, not a real
///      technical block.
///
/// Deliberately excluded beyond those two rules:
///   * `/as` itself — see `handleMessage`'s `relayed` parameter.
///   * `/sudo` — a privilege prefix, and one whose grant message names the
///     chat it was used in; it must be typed at top level where it is.
///   * `/menu`, `/convert`, `/cancel`, `/confirm` — stateful flows keyed by
///     (chat, user). Relayed, the state would be filed under the target
///     chat while the operator's follow-up message arrives from wherever
///     `/as` was typed, so the flow could be started but never finished.
///   * The LLM-backed commands (`/joke`, `/translate`, `/note`, ...) —
///     they spend real credits and produce conversation, not administration.
///     Nothing about them is unsafe to relay; they're simply out of scope
///     for a management-room surface, and the list is cheap to widen later.
const as_relayable_commands = [_][]const u8{
    // Smoke test for the relay itself — replies "pong" back to wherever
    // `/as` was typed, proving the redirect works, with no effect on the
    // target chat at all.
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
    "allowchat",
    "disallowchat",
    "announce",
    "photo",
    "title",
    "description",
    // Identity/balance grants scoped to *this* chat (`/token`) or the
    // target identity (`/credit`) — chat-scoped in the sense that matters
    // here: the command names a target user via reply/`@username`, which
    // survives the relay exactly like every moderation command above.
    "token",
    "credit",
    // Read-only reports about the target chat.
    "stats",
    "wordcloud",
    "reminders",
    "notes",
    "alerts",
    "watches",
};

/// The bare command name in `text` (no leading `/` or `!`, no
/// `@botusername` qualifier, no arguments), or null if `text` isn't a
/// command at all. Accepts `!` as well as `/` because
/// `normalizeCommandMention` only rewrites the *leading* indicator of the
/// whole message — the relayed half of `!as 7 !kick x` still arrives with
/// its own `!`.
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

/// Parses and fully authorizes `/as <chat id> <command>`, returning the
/// plan for `handleMessage` to replay, or null (having already explained
/// why) if the request is refused. See ROADMAP.md's Phase 9 slice 2 and
/// Phase 20 (which dropped the bound-room requirement below — `/as` now
/// works from any chat or DM, not just a room bound to the target).
///
/// Stacks *on top of* whatever the relayed command checks for itself
/// rather than replacing it:
///
///   1. Not already inside a relay (no `/as` inside `/as`).
///   2. The command is on `as_relayable_commands`.
///   3. The target chat exists and is on this connector's platform
///      (cross-platform `/as` is still unsupported, same as slice 1).
///   4. The sender is the owner or a **live admin of the target chat**,
///      re-checked against the platform on every single `/as`, never
///      cached and never inferred from their standing in whatever chat
///      `/as` was typed in (`auth.isOwnerOrLiveAdminOfChat`). No `/sudo`
///      or token fallback tier here, exactly as `/manage` has none.
///
/// Then the relayed command runs its *own* gate too (e.g. `/kick` still
/// calls `auth.checkGroupAdminAccess`), which — because
/// `ReplyRedirect` passes `isGroupAdmin` through unchanged — asks about the
/// target chat, not the control room. So `/as` is strictly narrowing: it
/// can never authorize something typing the same command in the target
/// chat wouldn't have.
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

/// Bundles what `group_admin.mute`/`unmute`/`promote`/`demote` need to log
/// an audit entry — `msg.username orelse msg.user_id` is a cheap,
/// no-DB-read actor label, good enough for a log line (see
/// `group_admin.AuditContext`'s own doc comment).
fn auditCtx(pool: *store_pool.PgPool, pending_undos: *audit_notify.PendingUndos, chat_id: i64, identity_id: i64, msg: iface.Message) group_admin.AuditContext {
    return .{
        .pool = pool,
        .pending_undos = pending_undos,
        .chat_id = chat_id,
        .actor_identity_id = identity_id,
        .actor_label = msg.username orelse msg.user_id,
    };
}

/// Same as `auditCtx`, plus Phase 23's `-s`/`-p` visibility.
fn auditCtxWithVisibility(pool: *store_pool.PgPool, pending_undos: *audit_notify.PendingUndos, chat_id: i64, identity_id: i64, msg: iface.Message, visibility: group_admin.Visibility) group_admin.AuditContext {
    var ctx = auditCtx(pool, pending_undos, chat_id, identity_id, msg);
    ctx.visibility = visibility;
    return ctx;
}

/// Parses Phase 23's `-s`/`-p` flag out of `arg` (see
/// `group_admin.parseVisibility`'s doc comment for the token-stripping
/// rule and the `-p`-without-superuser downgrade), then folds in the
/// chat's own `/silent on` default (`chat_settings.getSilentByDefault`) —
/// a chat default only ever *upgrades* `.normal` to `.silent`; an explicit
/// `-s`/`-p` flag always wins as typed, and `-p` from a superuser is never
/// downgraded by a chat default that only knows about `-s`.
fn resolveVisibility(pool: *store_pool.PgPool, a: std.mem.Allocator, chat_id: i64, arg: []const u8, is_superuser: bool) struct { visibility: group_admin.Visibility, rest: []const u8 } {
    const parsed = group_admin.parseVisibility(a, arg, is_superuser);
    const visibility: group_admin.Visibility = if (parsed.visibility == .normal and chat_settings.getSilentByDefault(pool, chat_id))
        .silent
    else
        parsed.visibility;
    return .{ .visibility = visibility, .rest = parsed.rest };
}

/// Phase 21: a command typed *directly* in a bound management room, no
/// `/as <id>` prefix needed. Resolves to the same `AsRelay` plan `/as`
/// itself builds — same allow-list, same target-chat authorization,
/// reusing `asRelayedMessage`/`ReplyRedirect` identically — just with the
/// target read from `management_rooms.getBoundTarget` (1:1 as of Phase 20,
/// so "the" target is unambiguous) instead of parsed from an explicit id.
///
/// Returns `null` silently (no reply at all) for anything that should fall
/// through to ordinary same-chat dispatch instead: this chat isn't
/// currently bound to a target, the command isn't on
/// `as_relayable_commands`, or we're already inside a relay (`relayed`,
/// to keep `/as` and direct-room dispatch from compounding). Returns
/// `null` *after* explaining why only for the one case that's bound and
/// allow-listed but still refused: the sender isn't authorized against the
/// target — silently falling through there would risk the command running
/// against the room itself instead, which is never what a denied operator
/// wants.
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
/// should see: same sender, same platform profile, but addressed to the
/// target chat and carrying only the relayed command as its text.
///
/// The field-by-field choices are the interesting part:
///   * `chat_id` becomes the target's native id — this is what makes every
///     handler's `connector.<action>(a, msg.chat_id, ...)` act on the right
///     chat, and what `ReplyRedirect` matches its sends against.
///   * `message_id` stays the operator's own. It's only ever used as a
///     `reply_to` for outbound sends, all of which come back to the control
///     room, where it's exactly the right thing to thread under.
///   * `reply_to_user_id`/`reply_to_username` carry over: "the person I
///     replied to" identifies a human, and a human is the same human in
///     every chat. This is what makes `/as 7 /mute` (as a reply) work.
///   * `reply_to_message_id`/`reply_to_text` are dropped: a message id only
///     means something inside the chat it was sent in, so carrying it over
///     would have `/pin` pin a control-room message id into the target
///     chat. (Those commands are also kept off `as_relayable_commands`;
///     this is the second, structural half of the same decision.)
///   * `chat_type`/`chat_title` are dropped rather than copied — they
///     describe the control room, and `handleMessage` has no business
///     persisting them against the target. `is_group` is forced true: a
///     management target is a group or a channel, never a 1:1.
///   * `attachment`/`choice_picked`/`observed_users`/`joined_users` are
///     dropped — an upload or a button press isn't something `/as` relays.
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
    // Added in Phase 21 -- none of these need a message id (see the
    // allow-list's own doc comment for `/redact`'s re-examined reasoning).
    try std.testing.expect(isRelayableUnderAs("redact"));
    try std.testing.expect(isRelayableUnderAs("announce"));
    try std.testing.expect(isRelayableUnderAs("token"));
    try std.testing.expect(isRelayableUnderAs("credit"));
    // Added in Phase 22 -- none of these act on a message either.
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
    // Guards against a typo in `as_relayable_commands` silently making a
    // command unrelayable (or, worse, looking relayable and then falling
    // through to the unrecognized-command path inside the relay).
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

/// Same on/off/now shape as `handleDigestCommand` above, minus the
/// `llm_provider`/`tool_ctx` params that one needs -- `briefing.generate`
/// is pure composition over already-stored data, no LLM call involved.
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

// ---------------------------------------------------------------------
// Phase 16 (ROADMAP.md), slice 4: scheduled announcements. Deliberately a
// presentation layer over `store/reminders.zig` rather than a second
// scheduler -- see `reminders.Kind` and `0035_announcements.sql`. The
// scheduling grammar below is `/remind`'s, verbatim and on purpose: an
// admin who already knows `/remind every 1d ...` knows this too.
// ---------------------------------------------------------------------

/// Longer than `max_reminder_message_len` (500): an announcement is a
/// prepared broadcast to a whole group -- rules, an event notice, a weekly
/// standup prompt -- not a personal one-liner, and 1000 bytes is the same
/// ceiling `/welcome` and `/persona`-adjacent text settings already use.
const max_announcement_len = 1000;

/// `/announce <text>` sends `<text>` into this chat right now and pins it
/// (Phase 21 merged the old standalone `/notice <chat id> <text>` into
/// this bare-text form -- ROADMAP.md's Phase 9 gave `/notice` its own
/// command specifically because it needed to target a *different* chat
/// than the one the operator was typing in, and its send-then-pin pair
/// wasn't safe to relay through `/as`; both of those blockers are gone now
/// that `/as`/direct-room dispatch (Phase 20/21) can run any relayable
/// command, `/announce` included, against another chat with no separate
/// mechanism needed -- "send a notice to chat #7" is just
/// `/as 7 /announce <text>`). `/announce at <when> <text>` schedules a
/// one-off announcement for later; `/announce every <interval> <text>` a
/// recurring one; `/announce list` and `/announce cancel <id>` manage
/// scheduled ones. The `at`/`every` keywords are what disambiguate "this
/// is a time expression" from "this is just the start of the announcement
/// text" -- a bare `/announce 30 people are coming` sends literally that
/// text now, rather than trying (and failing) to parse "30" as a time.
///
/// **Access**: chat-admin tier via `auth.checkGroupAdminAccess`, with the
/// token fallback *off* -- unlike `/remind` (open to anyone, delivers one
/// message to the person who asked for it), an announcement makes the bot
/// broadcast arbitrary text into the whole group, so it belongs with
/// `/mute`/`/pin` rather than with `/remind`. Token-spending is excluded
/// for the same reason `/redact regex` excludes it: a token buys one
/// moderation action against a known target, not the ability to broadcast
/// bot-authored messages. `list` is exempt from the gate (reading what's
/// scheduled for a chat you're in isn't privileged), matching
/// `/reminders`/`/alerts` being open.
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

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "announce")) return;

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
        // A reminder id passed to `/announce cancel` is told apart from a
        // nonexistent one on purpose -- they're different mistakes, and
        // silently refusing to cancel something that demonstrably exists
        // reads like a bug. `/remind cancel` is the right tool for that id,
        // and it applies its own creator-or-owner check.
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
        // "every <interval>" alone means "first one an interval from now" --
        // same shorthand `/remind every` uses. An admin wanting a recurring
        // announcement to start at a specific wall-clock time schedules the
        // first one with `at` and repeats it with `every` after; documented
        // in ROADMAP.md as a known sharp edge inherited from `/remind`
        // rather than papered over only here.
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
/// `formatPendingReminders` documents, since a chat's announcements can
/// have been scheduled by different admins each meaning their own local
/// "09:00".
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

/// `/autopin` shows this chat's setting; `/autopin on|off` changes it —
/// ROADMAP.md's Phase 16 "auto-pin important messages", built as narrowly
/// as that item can defensibly be built.
///
/// **What it pins**: only a scheduled announcement (see
/// `handleAnnounceCommand`), and only as the bot posts it. That is the
/// whole trigger. It is not a heuristic, it never reads or scores anyone
/// else's messages, and there is no "the bot decided this was important"
/// path at all — every pin traces back to a specific admin having typed a
/// specific `/announce`. Phase 8's backlog rejects spam/toxicity
/// auto-moderation because acting on messages the bot wasn't addressed in
/// is a trust-model change; an "importance" classifier over every message
/// would be the same change wearing a friendlier hat, so it isn't built.
/// The alternatives considered and rejected are recorded in ROADMAP.md.
///
/// Viewing is open to anyone (matching `/persona`/`/welcome`); changing it
/// takes the same chat-admin tier `/announce` itself does, since the two
/// are one feature.
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

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "autopin")) return;

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

/// `/silent on|off` — ROADMAP.md's Phase 23. Sets this chat's default for
/// managerial commands' `-s` flag, so an admin who always wants quiet
/// moderation doesn't have to type it every time. Same shape as
/// `/autopin`; view is open to anyone, changing it is admin-tier.
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

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "silent")) return;

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

/// `/photo` (send an image with this as its caption) sets the chat's
/// photo; `/photo remove` clears it — ROADMAP.md's Phase 22. Only the
/// caption form is supported, not "reply to an existing image with
/// /photo": `iface.Message`'s reply fields carry the replied-to user/text,
/// never a replied-to *attachment*, so there's no plumbing today to fetch
/// bytes for a message this one merely replies to (unlike `/redact`'s
/// reply-scoped mode, which only ever needs a user id). A real gap if it
/// turns out to matter, not solved this phase.
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
    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "photo")) return;
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

/// `/title <text>` — ROADMAP.md's Phase 22. Runnable directly in the group
/// by its own live admins (unlike moderation commands, there's no "keep it
/// out of the group" reason to gate this to a bound room/`/as`), and also
/// relayable through both, same as everything else on
/// `as_relayable_commands`.
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
    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "title")) return;
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

/// `/description <text>` — same shape as `/title`. An empty argument
/// clears the description (Telegram/Matrix both treat an empty
/// description/topic as "no description" natively).
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
    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "description")) return;
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

/// Shared failure reply for the three chat-settings commands above —
/// same "distinguish unsupported-platform from a real failure" shape
/// `group_admin.reportFailure` uses for moderation commands.
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
/// changes it — same shape as `handleAutopinCommand` right above (view is
/// open to anyone, changing it is admin-tier via `auth.checkGroupAdminAccess`,
/// no token fallback, same `chat_settings` `ON CONFLICT` idiom).
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

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "videodownload")) return;

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
/// `/videoquality lossy|lossless` changes it — same shape as
/// `handleVideoDownloadCommand` right above (view is open to anyone,
/// changing it is admin-tier via `auth.checkGroupAdminAccess`, no token
/// fallback, same `chat_settings` `ON CONFLICT` idiom). A sub-setting of
/// `video_download` itself, not a separate feature -- gated on the same
/// `video_download` feature flag at the dispatch site, no flag of its own.
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

    if (!auth.checkGroupAdminAccess(connector, a, config, pool, chat_id, identity_id, msg, sudo_active, false, "videoquality")) return;

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

/// How often `videoProgressTickerLoop` may edit the placeholder message --
/// longer than QA's `ticker_interval_ms` (1200ms) since downloads run far
/// longer than an LLM call and there's no need to poll/edit as often.
const video_progress_ticker_interval_ms: i64 = 3500;

/// Shared between `videoDownloadWorker` (which owns it) and
/// `videoProgressTickerLoop`. Unlike `TickerState`, progress here is
/// *pulled* by the ticker polling the filesystem each tick
/// (`video_download.pollCurrentBytes`) rather than *pushed* by another
/// thread, so no mutex-guarded status field is needed -- otherwise the same
/// shape, heap-allocated on `page_allocator` (not stack-local) for the same
/// reason `TickerState` is; see `tickerLoop`'s doc comment for the full
/// stop/done-atomic rationale, which applies here unchanged.
const VideoProgressState = struct {
    io: Io,
    tmp_dir: []const u8,
    ts: i96,
    estimated_total_bytes: ?u64,
    started_at: Io.Timestamp,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

/// Runs on its own detached `std.Thread`, exactly like `tickerLoop` --
/// cooperative `state.stop` checked before *and* after each sleep,
/// deliberately not `Future.cancel()` (see `tickerLoop`'s doc comment for
/// the production wedge that pattern avoids; the same risk applies to any
/// detached thread blocked in an in-flight `editMessage`). Each tick polls
/// the growing download file's size (`pollCurrentBytes`) and formats a
/// status line (`formatProgressText`), deduping against the last text it
/// actually sent -- unlike `tickerLoop`'s static strings, this text is
/// freshly allocated every tick, so the dedupe copy must be owned and freed
/// here rather than just compared by reference.
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

/// ROADMAP.md's Phase 25: passive auto-download of YouTube/Instagram/X
/// links. Same "passive content observation" tier as `checkKeywordAlerts`
/// (plain substring scan, no LLM call, fires for any sender) — but unlike
/// every other check at that call site, a match here can trigger a
/// genuinely slow, network-bound external process (`yt-dlp`, plus in lossy
/// mode possibly `ffmpeg`/`ffprobe` too), far past `processMessageTask`'s
/// own ~15s expected budget (see its own timing-log comment). So this does
/// not run inline: it hands off to a detached `std.Thread`
/// (`videoDownloadWorker`) and returns immediately, the same "don't occupy
/// a `WorkerPool` worker for a slow background op" reasoning `qa.zig`'s
/// thinking-ticker (`tickerLoop`) already uses for its own detached thread.
///
/// XMPP has no `sendDocument` support at all (see `platform/xmpp.zig`'s
/// vtable — no `sendDocument` slot is wired up there). Checked up front,
/// before spending several minutes on a download nobody could receive —
/// logged plainly rather than left silent. Calling `connector.sendDocument`
/// unconditionally instead would have `Connector.sendDocument`'s own
/// "platform doesn't support this" fallback post a visible chat message for
/// *every* video link a group posts, exactly the per-link error spam this
/// feature's fail-closed philosophy exists to avoid — so that fallback is
/// deliberately never reached here. `sendVideo` (lossy mode's preferred
/// delivery) is intentionally NOT gated the same way: it's strictly
/// additive on top of this baseline check, with `videoDownloadWorker`
/// itself falling back to `sendDocument` when a connector lacks it.
fn checkVideoDownload(connector: iface.Connector, a: std.mem.Allocator, io: Io, config: *const config_mod.Config, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) void {
    const url = video_download.findLink(text) orelse return;

    if (connector.vtable.sendDocument == null) {
        log.info("video_download: {t} has no sendDocument support, skipping {s}", .{ connector.platform(), url });
        return;
    }

    // Reuses `storage_sense.zig` rather than a separate check: once the
    // ladder's own low watermark is hit, a multi-minute video fetch is
    // exactly the kind of write this shouldn't be doing. Lives here (not
    // inside `video_download.zig`) since this call site already owns the
    // `pool`/`dynamic_config` reads, keeping that module free of a `PgPool`
    // dependency. Best-effort: a failed disk check doesn't block the
    // download (same fail-open reasoning `feature_flags.isEnabled` uses) --
    // storage pressure should degrade this feature, not a `df` hiccup.
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
    // Generated here, not inside `video_download.download`, so
    // `videoProgressTickerLoop` (spawned by `videoDownloadWorker`) can poll
    // the same `tmp_dir/video_download_{ts}*` prefix `download` writes to.
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();

    // `page_allocator`-owned dupes, NOT `task_arena`-backed: `task_arena`
    // is destroyed the moment `processMessageTask` returns, long before
    // this detached thread (which can run for several minutes in lossy
    // mode) is done with them — same reasoning `tickerLoop`'s own doc
    // comment gives for never touching the per-message arena from a
    // detached thread.
    const native_chat_id = std.heap.page_allocator.dupe(u8, msg.chat_id) catch |err| {
        log.warn("video_download: couldn't allocate for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    const url_dup = std.heap.page_allocator.dupe(u8, url) catch |err| {
        log.warn("video_download: couldn't allocate for chat {s}: {t}", .{ msg.chat_id, err });
        std.heap.page_allocator.free(native_chat_id);
        return;
    };
    // Reply-threads the placeholder to the original link message, so it's
    // clear which link is being fetched if several are posted in quick
    // succession -- best-effort, `null` (no threading) on any allocation
    // failure rather than aborting the whole download over it.
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

/// Body of the detached thread `checkVideoDownload` spawns. Owns (and
/// frees) `native_chat_id`/`url`/`reply_to`, all `page_allocator` dupes
/// taken before spawning — see `checkVideoDownload`'s doc comment for why
/// they can't be `task_arena`-backed.
///
/// Sends a "⬇️ Downloading…" placeholder immediately, animates it via
/// `videoProgressTickerLoop` while `video_download.download` runs, then on
/// success deletes the placeholder and sends the real result as a fresh
/// message (`editMessage` is text-only and can never attach media to an
/// existing message, so unlike the QA flow's placeholder, this one is
/// never "edited into" the final video). On failure the placeholder is
/// instead edited into a short failure notice, same shape
/// `replyWithAnswer` already uses for its own error case -- a placeholder
/// went out for every trigger-pattern match already, real video or not
/// (see `checkVideoDownload`'s own doc comment), so silently deleting it
/// with zero explanation reads as broken rather than as the intended
/// "ordinary non-video link, nothing to see" case. Previously deleted the
/// placeholder silently instead; changed after a live report of exactly
/// that looking like a bug (2026-08-09).
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
        // Lossless mode's own fetch doesn't use `estimateSize`'s ~720p
        // format selector, so its estimate would be meaningless -- only
        // ask for one in lossy mode, same as `downloadLossy` itself.
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

    // Stop the ticker before touching the placeholder ourselves -- same
    // bounded stop-then-join-or-detach dance `replyWithAnswer` uses for
    // `tickerLoop`, for the same reason (see `tickerLoop`'s doc comment on
    // the production wedge this avoids).
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

/// `/summary [hours]` — ROADMAP.md's Phase 16 "group summaries", composing
/// `digest.summarizeWindow` (the same summarizer `/digest` uses) rather
/// than adding a third prompt.
///
/// **Why it exists next to `/digest now` and `catch_me_up`**: `/digest now`
/// summarizes "since the last digest" and moves that cursor as a side
/// effect, so it can't answer "what happened this morning" without
/// disturbing the schedule; `catch_me_up` is an LLM *tool*, reachable only
/// by addressing the bot in natural language and only when the asker clears
/// the owner-only/credits gate on free-form Q&A. This is the plain,
/// predictable command form: name a window, get a summary, change nothing.
///
/// **Access** deliberately matches `/digest now` (open to anyone allowed in
/// the chat, no credits spent) rather than the messaging-mode commands'
/// owner/credits gate: it summarizes only this chat's own already-logged
/// history and can't be steered into arbitrary generation. The alternative
/// — charging a credit like `/translate` does — is recorded in ROADMAP.md
/// as the obvious knob to turn if this ever gets abused.
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

/// True when this `/note` is really "save my voice message as a note":
/// the message carries a voice attachment and the command was given with no
/// text of its own (bare `/note`, or `/note add` with nothing after it).
///
/// Split out as a pure function purely so it can be tested without a
/// connector, a pool, or a whisper server -- the transcription itself needs
/// all three, so the decision logic is the part worth covering offline.
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
///
/// Every failure replies with something specific rather than the generic
/// usage string -- "whisper isn't configured" and "I couldn't make out any
/// speech" are very different problems for the person holding the phone,
/// and a voice note that silently does nothing is the worst outcome here.
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

    // Sent only once the checks above have passed, so a misconfiguration
    // never leaves a "Transcribing…" message stranded. Everything after
    // this point reports through `settleVoiceNote`, which edits this
    // message rather than adding a second one.
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
    // A transcript can't be edited before sending, and re-recording to fit
    // a byte budget is a miserable ask -- so this truncates instead, on a
    // codepoint boundary (transcripts are routinely non-ASCII), and says so.
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

/// Replaces the "Transcribing…" placeholder with the final outcome, or
/// sends it as a new message when there's no placeholder to edit (a
/// platform without `editMessage`, or a placeholder send that failed).
/// Falls back to sending if the edit itself fails, so the user always gets
/// the result even if the placeholder is somehow gone.
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

/// `/note add <text>` / `/note delete <id>` — see ROADMAP.md's Phase 11.
/// A generic freeform-text knowledge base (notes, shopping lists,
/// wishlists, ...), so unlike `/remind`'s implicit "first word is either
/// `cancel` or a time expression" parsing, this requires an explicit
/// `add`/`delete` keyword — a note's own text could otherwise legitimately
/// start with a word like "list" or "delete" ("delete the old files"),
/// which would be ambiguous under `/remind`'s shape.
fn handleNoteCommand(connector: iface.Connector, a: std.mem.Allocator, io: Io, config: *const config_mod.Config, pool: *store_pool.PgPool, tool_ctx: tool_registry.ToolContext, chat_id: i64, identity_id: i64, now: i64, msg: iface.Message, text: []const u8) void {
    const usage = "Usage: /note add <text>, /note list, or /note delete <id>";
    const arg = std.mem.trim(u8, text["/note".len..], " ");

    // Phase 11's deferred voice notes: `/note` sent as the *caption* of a
    // voice message means "transcribe this and save it". Checked before the
    // empty-arg usage reply below, which is what a bare `/note` would
    // otherwise hit. Telegram delivers a caption in `msg.caption`, which
    // `platform/telegram.zig` maps onto `text` -- so a captioned voice
    // message never reaches `resolveQuestion`'s transcription path (that
    // one only fires for *captionless* attachments), which is exactly why
    // this needed its own hook rather than falling out of the existing one.
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
/// ROADMAP.md's Phase 16. Same add/list/delete-by-id shape as
/// `handleNoteCommand`, including its creator-or-owner delete
/// authorization -- deliberately not open to "anyone in the chat" like
/// `/watch`/`/digest on`, since a keyword alert firing on every mention
/// is more disruptive than a shared feed subscription.
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
/// alerts (whole-word, case-insensitive -- `containsWordIgnoreCase`, same
/// matcher the magic-word check already uses) and, on any hit, posts one
/// combined flag message naming every keyword that matched -- not one
/// message per match, so a message that happens to contain several
/// tracked words doesn't spam the chat. Fires for *any* sender (this is a
/// passive content observation, same "every message is logged regardless
/// of who sent it" tier as recording itself, not a privileged action), and
/// is a plain string scan -- no LLM call, so no credits/owner gate either.
/// Errors loading the tracked list are logged and swallowed, same "never
/// let a side feature block the main flow" convention `bcast.publish`'s
/// own call site uses.
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

/// `/memory list` / `/memory forget <id>` — see ROADMAP.md's Phase 12.
/// Deliberately no `/memory remember <text>` counterpart: creation is
/// meant to happen contextually through conversation (the model deciding
/// what's worth keeping via the `remember_memory` tool), matching the
/// ChatGPT-Memory framing this feature is modeled on, not a manually
/// curated list a person edits directly.
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
        const listed = memories.listForIdentity(pool, a, identity_id) catch |err| {
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
        const mem = (memories.get(pool, a, id) catch |err| {
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
        memories.forget(pool, id) catch |err| {
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

/// Wires the `set_note` LLM tool (see `tools/set_note.zig`) to real
/// Postgres-backed notes for one specific message's chat/sender —
/// constructed fresh per message in `processMessageTask` since `chat_id`/
/// `identity_id`/`is_owner` all vary per sender, then handed to the tool
/// loop as a `registry.NoteSink`. Same shape as `ReminderToolAdapter`.
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
/// Postgres-backed expenses — same shape/reasoning as `NoteToolAdapter`
/// (ROADMAP.md's Phase 17). `amount_cents` arrives already converted from
/// the tool's own dollar-amount input, so this adapter, like `formatAllNotes`'
/// counterpart below, only ever handles the integer-cents unit.
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

/// Wires the `catch_me_up` LLM tool (see `tools/catch_me_up.zig`) to this
/// chat's own logged history — same per-message construction as the other
/// tool adapters above (ROADMAP.md's Phase 14).
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
/// cap — a very chatty chat over even a modest window could otherwise
/// return an unbounded amount of text (see `messages.recentSinceFormatted`'s
/// own doc comment for why both bounds exist together).
const catch_me_up_row_limit = 2000;

/// Hard cap on how many chats `list_personal_chats` hands the model in one
/// call — same "don't blow out the model's context on an account in a lot
/// of chats" reasoning as `catch_me_up_row_limit` above, just for chat
/// count instead of message count.
const list_personal_chats_limit = 60;

/// Backs the personal-account (TDLib) LLM tools —
/// `summarize_unread_chat`/`list_personal_chats`/`send_personal_message` —
/// unlike `ChatHistoryToolAdapter` (this Bot-API chat's own logged
/// Postgres history), these reach the personal-account TDLib connector,
/// which may not be configured at all on this deployment. Always
/// constructed and always wired into `ToolContext` (never gated to `null`
/// the way `.memory` is) so the model gets a plain explanatory string back
/// either way — "not configured"/"not logged in yet" are normal runtime
/// states worth relaying to the owner directly, not a raw tool error to
/// work around.
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
                // Monitoring is forward-looking (a subscription to future
                // messages), not a report over history that already
                // exists -- so unlike e.g. reply_to_message (which
                // inherently needs a real prior message to target),
                // there's no reason to require this chat to have ever
                // recorded one yet. `upsertChat` creates the row if it's
                // missing rather than requiring it already exist (direct
                // owner report, 2026-08-26: the old `getByNative`-or-fail
                // guard here blocked subscribing to a chat with no
                // history, which is a perfectly normal thing to want).
                const chat_id = try chats.upsertChat(self.pool, .telegram_user, m.native_chat_id, null, m.title);
                try chat_settings.setMonitorImportance(self.pool, chat_id, parsed_importance);
                if (parsed_importance == .off) {
                    return std.fmt.allocPrint(allocator, "Stopped monitoring \"{s}\".", .{m.title});
                }
                // The only real consequence of subscribing a chat with no
                // recorded history yet: an immediate get_bulletin has
                // nothing from it until a new message actually arrives --
                // surfaced as a heads-up rather than blocking the
                // subscription itself.
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

fn formatMemories(a: std.mem.Allocator, listed: []const memories.Memory) []const u8 {
    if (listed.len == 0) return "No memories yet. I'll remember things worth keeping as we talk.";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Memories:\n", .{}) catch return "";
    for (listed) |m| w.print("  #{d} {s}\n", .{ m.id, m.text }) catch return "";
    return buf.writer.buffered();
}

/// Wires the `remember_memory` LLM tool (see `tools/remember_memory.zig`)
/// to real Postgres-backed memories for one specific message's sender —
/// constructed fresh per message in `processMessageTask`, same shape as
/// `NoteToolAdapter`, except scoped to `identity_id` alone (no `chat_id`/
/// `is_owner` — see `registry.zig`'s `MemorySink` doc comment for why
/// there's no "or the owner" escape hatch here). `embeddings_client` is
/// `null` exactly when `config.embeddings_url` is unset; `tool_ctx.memory`
/// itself is only ever set to this adapter's sink when it's non-null (see
/// `processMessageTask`), so `createFn` finding it null here would only
/// ever indicate a wiring bug, not a normal "feature disabled" path — it
/// still fails safely rather than asserting, since a tool executing is
/// never a place to crash the whole message-processing task over.
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
        const client = self.embeddings_client orelse return error.EmbeddingsNotConfigured;
        const vector = try client.embed(allocator, text);
        return memories.remember(self.pool, allocator, self.identity_id, text, vector, self.now);
    }

    fn forgetFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!tool_registry.MemorySink.ForgetResult {
        const self: *MemoryToolAdapter = @ptrCast(@alignCast(ptr));
        const mem = (try memories.get(self.pool, allocator, id)) orelse return .not_found;
        if (mem.identity_id != self.identity_id) return .not_authorized;
        try memories.forget(self.pool, id);
        return .forgotten;
    }

    fn listAllFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *MemoryToolAdapter = @ptrCast(@alignCast(ptr));
        const listed = try memories.listForIdentity(self.pool, allocator, self.identity_id);
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

        // The only difference between the two kinds at delivery time is the
        // framing and, for announcements, the optional pin -- see
        // `reminders.Kind`. One loop delivers both because the scheduling
        // half is genuinely identical.
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

/// ROADMAP.md's Phase 24: reverts a timed `/permission <duration> ...`
/// grant/revoke back to the default (unrestricted) bitmask once its
/// `expires_at` passes — same polling-loop shape as
/// `checkAndSendDueReminders` above. Attempts the live platform call
/// first (best-effort, same as `handlePermissionCommand`'s own
/// enforcement — logged, not fatal, since the bitmask itself is the
/// source of truth) and clears the DB row regardless of whether that live
/// call succeeded, so a persistent platform error (e.g. the bot no longer
/// being an admin) can't wedge this in a retry loop forever.
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

/// Posts a scheduled announcement into a chat that has `/autopin on` and
/// pins it, degrading rather than failing at each step that can go wrong:
///
/// - `sendMessageReturningId` is an optional vtable slot that returns null
///   *without sending* when a platform doesn't implement it (Matrix and
///   XMPP today), so the fallback has to do the plain send itself.
/// - The pin can fail on its own — most likely because the bot simply
///   hasn't been given pin permission in that group, which is a
///   configuration fact about the chat, not an error worth losing the
///   announcement over. It's logged at warn and the announcement stands.
///
/// Either way the message goes out exactly once, which is what matters:
/// the delivery loop marks the row delivered (or reschedules it)
/// regardless of whether the pin landed.
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
/// left (see `store/chats.zig`'s `markLeft`, set from a `chat_left`
/// synthetic message — the bot was removed, left, or the chat was
/// deleted) for longer than the retention window. Cascades to every FK'd
/// table via `ON DELETE CASCADE` (`deleteLeftBefore`'s own doc comment
/// has the full list). Runs every scheduler tick like its neighbors — a
/// `DELETE` matching zero rows is cheap, no separate cadence needed.
const chat_retention_seconds: i64 = 30 * 24 * 3600;

fn checkAndPurgeLeftChats(pool: *store_pool.PgPool, now: i64) void {
    const purged = chats.deleteLeftBefore(pool, now - chat_retention_seconds) catch |err| {
        log.err("housekeeping: failed to purge left chats: {t}", .{err});
        return;
    };
    if (purged > 0) log.notice("housekeeping: purged {d} chat(s) left over 30 days ago", .{purged});
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
/// Shown by `tickerLoop` once `TickerState.cancelled` flips, overriding
/// whatever status was showing — the immediate feedback for a "🛑 Cancel"
/// press, ahead of `toolcall.run` actually noticing at its next
/// loop-iteration boundary (see `toolcall.Progress.cancelled`'s doc
/// comment for why that can lag this).
const cancelling_text = "🛑 Cancelling...";
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
///
/// Heap-allocated on `std.heap.page_allocator` by `replyWithAnswer`
/// (**not** stack-local, unlike its pre-2026-08-01 shape) — `stop`/`done`
/// let the ticker thread outlive `replyWithAnswer`'s own stack frame when
/// it can't be joined promptly (see `tickerLoop`'s doc comment), so nothing
/// referencing `state` may be on that frame.
const TickerState = struct {
    io: Io,
    allocator: std.mem.Allocator,
    /// Cooperative stop signal — `replyWithAnswer` sets this once it's done
    /// with the model call; `tickerLoop` checks it instead of relying on
    /// `Future.cancel()`/preemption (see `tickerLoop`'s doc comment for why).
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by `tickerLoop` right before it returns — `replyWithAnswer`
    /// polls this (bounded) instead of blocking on `std.Thread.join()`,
    /// since the ticker may be wedged inside an in-flight edit call for up
    /// to its own 45s internal timeout.
    done: std.atomic.Value(bool) = .init(false),
    /// Flipped by a "🛑 Cancel" button press, routed through
    /// `features/cancel_request.zig`'s `InFlightRequests` from whichever
    /// `WorkerPool` worker is handling that press — a different one than
    /// whatever's running this request. `replyWithAnswer` points
    /// `toolcall.Progress.cancelled` straight at this field, so `toolcall.run`
    /// sees it too (see that field's own doc comment on when it actually
    /// takes effect); `tickerLoop` also watches it directly for the instant
    /// "🛑 Cancelling..." feedback.
    cancelled: std.atomic.Value(bool) = .init(false),
    /// This platform's hard cap on a single message's text (see
    /// `effectiveMaxMessageLength`) — the rendered tree (see `renderTree`)
    /// is truncated to this before being shown, since unlike the *final*
    /// answer (routed to a file when too long via `sendTextOrFile`) the
    /// growing interim preview has no such fallback and would otherwise
    /// eventually 400 out of `editMessage` on a long-running request.
    max_len: usize,
    mutex: Io.Mutex = .init,
    /// Tool names reported via `.tool_use` so far this request, oldest
    /// first — rendered as tree-branch child lines under `thinking_text` by
    /// `renderTree`. Only ever touched from `onProgressEvent`, which (like
    /// this whole struct's `allocator`) runs exclusively on the main
    /// per-message task, never the ticker thread — see this struct's own
    /// doc comment — so it needs no mutex of its own.
    tool_history: std.ArrayList([]const u8) = .empty,
    /// null = show the generic thinking animation; set = show this (already
    /// including the tree so far — see `renderTree`) until the model moves
    /// past whatever produced it.
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

    /// Builds `thinking_text` followed by one tree-branch child line per
    /// entry in `tool_history` so far ("├── 🔧 Using x..."/"└── 🔧 Using
    /// y..."), plus `trailing` (a streaming answer preview) as one final
    /// child line when given. Called from `onProgressEvent` — main task
    /// thread only, same as `tool_history` itself (see its doc comment).
    /// Truncated to `max_len` as a whole, not just `trailing` on its own
    /// (unlike before this tree existed): the accumulated history now
    /// counts against the same platform message-size budget. Falls back to
    /// the bare header on allocation failure — losing the tree for one tick
    /// is better than failing the whole progress report over it.
    fn renderTree(self: *TickerState, trailing: ?[]const u8) []const u8 {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(self.allocator, thinking_text) catch return thinking_text;
        const child_count = self.tool_history.items.len + @as(usize, if (trailing != null) 1 else 0);
        var shown: usize = 0;
        for (self.tool_history.items) |name| {
            shown += 1;
            const branch: []const u8 = if (shown == child_count) "\n└── " else "\n├── ";
            buf.appendSlice(self.allocator, branch) catch return thinking_text;
            buf.appendSlice(self.allocator, "🔧 Using ") catch return thinking_text;
            buf.appendSlice(self.allocator, name) catch return thinking_text;
            buf.appendSlice(self.allocator, "...") catch return thinking_text;
        }
        if (trailing) |t| {
            buf.appendSlice(self.allocator, "\n└── ") catch return thinking_text;
            buf.appendSlice(self.allocator, t) catch return thinking_text;
        }
        const rendered = buf.toOwnedSlice(self.allocator) catch return thinking_text;
        return truncateUtf8(rendered, self.max_len);
    }
};

fn onProgressEvent(ptr: *anyopaque, event: toolcall.Progress.Event) void {
    const state: *TickerState = @ptrCast(@alignCast(ptr));
    switch (event) {
        .thinking => {
            // Fires on every turn, including right after a tool call whose
            // child line is already reflected in `status` (set below, by
            // that same `.tool_use` event) — only reset to the bare header
            // when there's no tree yet to preserve (the very first turn).
            if (state.tool_history.items.len == 0) state.setStatus(null);
        },
        .tool_use => |name| {
            state.tool_history.append(state.allocator, name) catch return;
            state.setStatus(state.renderTree(null));
        },
        .text => |text_so_far| {
            if (text_so_far.len == 0) return; // nothing to show yet, keep the thinking animation
            state.setStatus(state.renderTree(text_so_far));
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

/// Runs on its own real, detached `std.Thread` (see `replyWithAnswer` —
/// deliberately NOT `Io.concurrent`, see below), editing `message_id` no
/// more than once per `ticker_interval_ms` — the generic thinking
/// animation, or whatever `state.status` currently says, whichever's
/// current. Dedupes against the last text it actually sent so a run of
/// identical statuses (or a tick where nothing changed) doesn't trigger a
/// wasted edit — besides being pointless, Telegram rejects a no-op edit
/// ("message is not modified"), which `editMessage` can't distinguish from
/// a real failure (see its doc comment).
///
/// Stops cooperatively via `state.stop`, checked once per tick, rather than
/// via `Future.cancel()` — confirmed live in production (VPS wedge,
/// 2026-07-31/08-01) that when this loop's own `editMessage` call is
/// in-flight at the exact moment its call to `http_util`'s 45s
/// timeout-and-detach escape hatch fires, a caller blocked in
/// `Future.cancel()` waiting for this task to stop can hang forever —
/// permanently stranding whichever `WorkerPool` worker was running that
/// caller. Same class of bug `xmpp.zig`'s `pollFn` hit and was fixed for
/// (see `worker_pool.zig`'s module doc): `Future.cancel()` can't be trusted
/// to unwind through that raw-detached-thread boundary. A plain
/// `std.Thread` + atomic stop flag sidesteps the question entirely — no
/// cancellation to trust, just a flag this loop checks on its own schedule,
/// with `replyWithAnswer` bounding how long it waits rather than blocking
/// unboundedly on a join.
///
/// Deliberately does NOT take the per-message arena `replyWithAnswer` and
/// `qa.answer` use — this runs as a genuinely concurrent task (a real OS
/// thread), and `std.heap.ArenaAllocator` has no internal locking, so two
/// threads allocating from the same arena at once corrupts its bookkeeping.
/// That was the actual cause of an earlier reported hang: no timeout ever
/// fired because the corruption happened inside allocator internals,
/// nowhere near the network code the timeouts guard. Every allocation
/// `editMessage`'s call chain makes is `defer`-freed by itself (no reliance
/// on arena-wholesale-free), so a plain thread-safe allocator works fine
/// here — no arena needed.
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

/// The "🛑 Cancel" button attached to the thinking/tool-use placeholder —
/// a single fixed choice (nothing to pick between, just one action), same
/// shape `audit_notify`'s "Undo" button uses for its own single-choice
/// prompt. See `features/cancel_request.zig`'s module doc comment for the
/// register/press/cancel flow a pick of this feeds into.
const cancel_choices = [_]iface.Choice{.{ .emoji = "🛑", .label = "Cancel", .value = cancel_request.cancel_choice_value }};

/// Sends (or morphs `existing_placeholder_id` into) the thinking
/// placeholder, attaching the Cancel button when — and only when — this
/// connector actually implements the relevant vtable method itself.
/// Deliberately checks `connector.vtable.*` directly rather than going
/// through the `sendChoicePrompt`/`editChoicePrompt` wrapper methods'
/// unconditional fallbacks (a plain-text listing send, `error.Unsupported`)
/// — neither is the right degrade here. A platform with no button support
/// should behave exactly like it did before this feature existed: a plain
/// `sendMessageReturningId`/`editMessage`, or, if even that's unsupported,
/// no placeholder at all (see `sendMessageReturningId`'s own doc comment).
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

/// Replaces the placeholder's text and drops its Cancel button (a no-op
/// button from here on — the request it controlled is already resolved),
/// falling back the same way `sendOrMorphPlaceholder` does when this
/// connector can't edit the keyboard, can't edit at all, or there's no
/// placeholder to begin with.
fn finalizePlaceholder(connector: iface.Connector, a: std.mem.Allocator, native_chat_id: []const u8, placeholder_id: ?[]const u8, reply_to: ?[]const u8, text: []const u8) void {
    const pid = placeholder_id orelse {
        connector.sendMessage(a, native_chat_id, text, reply_to);
        return;
    };
    if (connector.vtable.editChoicePrompt != null) {
        if (connector.editChoicePrompt(a, native_chat_id, pid, text, &.{})) |_| {
            return;
        } else |_| {
            // Fall through to the plain edit below — same "log once,
            // degrade" shape as everywhere else in this file that tries a
            // richer send/edit first.
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
    max_tokens_override: ?u32,
    history_window: i64,
    in_flight: *cancel_request.InFlightRequests,
) void {
    // The placeholder + ticker only work when the platform supports
    // editing (Telegram does); anything that doesn't falls back to
    // exactly the old behavior — one blocking call, one send at the end.
    // `existing_placeholder_id` (from `resolveQuestion`'s "🎙️
    // Transcribing…" placeholder) is reused and morphed rather than
    // sending a second message right after it. See
    // `sendOrMorphPlaceholder`'s own doc comment for the Cancel-button
    // half of this.
    const placeholder_id = sendOrMorphPlaceholder(connector, a, native_chat_id, reply_to, existing_placeholder_id);
    log.info("qa: placeholder for chat {s} = {?s}", .{ native_chat_id, placeholder_id });

    // Heap-allocated on `page_allocator`, not stack-local: `tickerLoop` runs
    // on a real detached thread that this function may have to walk away
    // from (still running) if it doesn't stop promptly — see the bounded
    // stop/join below and `TickerState`'s doc comment. Never freed on that
    // walk-away path (same accepted "detach and abandon" tradeoff
    // `http_util.zig`'s `fetchWithTimeout` already makes for its own
    // stalled-connection case) — a handful of leaked `TickerState`s over a
    // long-running process is a fine trade for never stranding a
    // `WorkerPool` worker again.
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
            // Best-effort: a failure here just means the Cancel button (if
            // shown at all) silently does nothing when pressed — not worth
            // failing the whole answer over.
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
    // answer, overlength-to-file) — a Cancel press after this point finds
    // nothing to act on, same as pressing it on any other already-resolved
    // prompt. Unregistering a placeholder that was never registered (state
    // allocation failed above) is a harmless no-op lookup miss.
    defer if (placeholder_id) |pid| in_flight.unregister(native_chat_id, pid);

    log.info("qa: calling the model for chat {s}", .{native_chat_id});
    const enabled_tools = filterEnabledTools(pool, a, tools);
    const raw_answer_or_err = qa.answer(llm_provider, embeddings_client, a, tool_ctx, enabled_tools, pool, chat_id, asker_identity_id, system_prompt, max_message_len, asker, question, replied_to, progress, stream, show_thinking, vision_enabled, documents_enabled, max_tokens_override, history_window);

    // Stop the ticker before touching the placeholder ourselves. Signaled
    // cooperatively (`state.stop`) and joined with a bound, rather than
    // trusted to `Future.cancel()`/`std.Thread.join()` unbounded — see
    // `tickerLoop`'s doc comment for the production wedge this replaced.
    // 5s comfortably covers a normal stop (next tick is at most
    // `ticker_interval_ms` away) while still being far short of the ticker's
    // own 45s internal HTTP timeout, so this only ever eats the bound on the
    // rare tick that's genuinely wedged in that timeout's tail.
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

    const raw_answer = raw_answer_or_err catch |err| {
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
    } else {
        // `finalizePlaceholder` also drops the Cancel button — the request
        // it controlled is done, so a press on it from here on should find
        // nothing (it's already unregistered above) rather than lingering
        // as a dead-looking button.
        finalizePlaceholder(connector, a, native_chat_id, placeholder_id, reply_to, answer);
        if (placeholder_id != null) log.info("qa: final answer edited into placeholder for chat {s}", .{native_chat_id});
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
    pending_undos: *audit_notify.PendingUndos,
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
            const pending = reminders.listPending(ctx.pool, ctx.a, ctx.chat_id, .reminder) catch return &.{};
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
    _ = @import("store/management_rooms.zig");
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
    _ = @import("store/memories.zig");
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
    _ = @import("platform/telegram.zig");
    _ = @import("telegram/client.zig");
    _ = @import("telegram/markdown_html.zig");
    _ = @import("http_util.zig");
    _ = @import("features/scheduler.zig");
    _ = @import("features/digest.zig");
    _ = @import("features/briefing.zig");
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
    _ = @import("platform/reply_redirect.zig");
    _ = @import("platform/telegram_user.zig");
    _ = @import("xmpp/xml.zig");
    _ = @import("xmpp/types.zig");
    _ = @import("xmpp/client.zig");
    _ = @import("domain/xmpp_profile.zig");
    _ = @import("worker_pool.zig");
    _ = @import("store/db.zig");
}

/// Codepoints that delimit a word for magic-word / keyword matching.
///
/// ASCII is easy: anything non-alphanumeric. Beyond ASCII there's no full
/// Unicode table to consult, so this enumerates the punctuation, symbol and
/// separator blocks that actually turn up in chat -- above all the Persian
/// comma (U+060C) and question mark (U+061F), which is what "وردن،" and
/// "وردن؟" end with. Everything else >= 0x80 stays a word character, so a
/// name embedded in a longer word ("محسن" vs "حسن") still isn't a match.
///
/// ZWNJ/ZWJ (U+200C/U+200D) are deliberately word characters: Persian uses
/// them *inside* words, so treating them as boundaries would match a name
/// glued to a suffix.
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
/// UTF-8 sequence and decodes it. Malformed or misaligned input counts as a
/// boundary -- erring toward answering beats silently ignoring the owner.
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

/// Whole-word, ASCII-case-insensitive search — used for magic-word
/// detection so "Hassan," matches a magic word of "hassan" but
/// "hassanabad" doesn't.
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

// Regression: Persian punctuation is multi-byte UTF-8, so the old
// ASCII-only boundary test saw "وردن،" as one long word and the bot stayed
// silent when it was called by name with normal Persian punctuation.
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
