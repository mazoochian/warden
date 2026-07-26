const std = @import("std");

/// Every navigable node in the `/menu` tree — the single source of truth
/// for both real navigation (`menu.zig`) and the read-only Help browser,
/// which renders this exact same tree in a different mode rather than
/// maintaining its own parallel list (see `NodeKind` and `MenuSession.mode`
/// in `menu.zig`). Deliberately flat (not nested structs) so a comptime
/// table indexed by `@intFromEnum` can look any node up in O(1).
pub const NodeId = enum {
    root,

    alerts,
    alerts_view,
    alerts_new,

    reminders,
    reminders_view,
    reminders_new,

    watches,
    watches_view,
    watches_new,

    stats,
    stats_text,
    stats_wordcloud,
    stats_piechart,

    convert,

    group_admin,
    group_admin_mute,
    group_admin_unmute,
    group_admin_pin,
    group_admin_unpin,
    group_admin_delete,
    group_admin_kick,
    group_admin_ban,
    group_admin_promote,
    group_admin_demote,
    group_admin_redact,
    group_admin_redact_lastn,
    group_admin_redact_user,
    group_admin_redact_text,
    group_admin_redact_regex,

    settings,
    settings_global,
    settings_global_addadmin,
    settings_global_removeadmin,
    settings_global_adduser,
    settings_global_removeuser,
    settings_global_allowchat,
    settings_global_disallowchat,
    settings_global_whois,
    settings_global_scraper,
    settings_chat,
    settings_chat_magicword,
    settings_chat_persona,
    settings_chat_thinking,
    settings_chat_thinking_on,
    settings_chat_thinking_off,
    settings_chat_thinking_default,
    settings_chat_digest,
    settings_chat_digest_on,
    settings_chat_digest_off,
    settings_personal,
    settings_personal_timezone,
    settings_personal_dateformat,
    settings_personal_dateformat_mdy,
    settings_personal_dateformat_dmy,
    settings_personal_dateformat_ymd,
    settings_personal_timeformat,
    settings_personal_timeformat_24h,
    settings_personal_timeformat_12h,

    help,
};

/// One button shown for a `.branch`/`.dynamic_list` node's child, or for a
/// terminal node's own "confirm this" affordance (e.g. the digest on/off
/// pair). `emoji` doubles as the Matrix reaction key, matching
/// `iface.Choice`.
pub const ChildRef = struct {
    id: NodeId,
    emoji: []const u8,
    label: []const u8,
};

pub const NodeKind = enum {
    /// Shows `children` as buttons; picking one navigates into it. Never
    /// itself performs an action.
    branch,
    /// Performs `ActionRunner.perform(id, ...)` immediately on selection,
    /// then re-renders the parent (or whatever the runner returns).
    action,
    /// Prompts with `prompt`, puts the session into `awaiting_input`, and
    /// hands the next message from the same (chat, user) to
    /// `ActionRunner.resumeAwaitingInput(id, ...)`.
    awaiting_input,
    /// Like `.branch`, but its buttons are produced live by
    /// `ActionRunner.dynamicChoices(id, ...)` (e.g. the actual list of
    /// pending alerts/watches in this chat) instead of from `children`.
    dynamic_list,
    /// Enters the multi-step reminder-creation stepper (see `menu.zig`'s
    /// `Session.stage`'s `.wizard` variant) instead of performing a single
    /// immediate action or a single text prompt.
    wizard,
};

pub const MenuNode = struct {
    id: NodeId,
    parent: ?NodeId,
    title: []const u8,
    /// Shown as the message body under `title` when this node is rendered
    /// as a branch/root — ignored for `.action`/`.awaiting_input` leaves,
    /// which use `prompt`/their own runner-produced text instead.
    body: []const u8 = "",
    kind: NodeKind,
    children: []const ChildRef = &.{},
    /// Only used when `kind == .awaiting_input`.
    prompt: []const u8 = "",
    /// Longer descriptions used only by the Help browser (`help` node and
    /// its descendants in help mode) — never shown during normal use, so
    /// these can be as verbose as actually useful without bloating every
    /// real interaction.
    help_body: []const u8 = "",
    help_example: []const u8 = "",
};

const table = [_]MenuNode{
    .{
        .id = .root,
        .parent = null,
        .title = "Warden",
        .body = "What do you want to do?",
        .kind = .branch,
        .children = &.{
            .{ .id = .alerts, .emoji = "🔔", .label = "Alerts" },
            .{ .id = .reminders, .emoji = "⏰", .label = "Reminders" },
            .{ .id = .watches, .emoji = "📰", .label = "Watches" },
            .{ .id = .stats, .emoji = "📊", .label = "Statistics" },
            .{ .id = .convert, .emoji = "🔄", .label = "Convert" },
            .{ .id = .group_admin, .emoji = "🛡", .label = "Group Administration" },
            .{ .id = .settings, .emoji = "⚙️", .label = "Settings" },
            .{ .id = .help, .emoji = "❓", .label = "Help" },
        },
        .help_body = "The root menu. Every module below is also its own slash command if you'd rather type than tap.",
    },

    // ---- Alerts ----
    .{
        .id = .alerts,
        .parent = .root,
        .title = "🔔 Alerts",
        .body = "Standing watches on crypto/weather/AQI, checked in the background.",
        .kind = .branch,
        .children = &.{
            .{ .id = .alerts_view, .emoji = "📋", .label = "View / cancel" },
            .{ .id = .alerts_new, .emoji = "➕", .label = "New alert" },
        },
        .help_body = "Set a standing watch (e.g. \"notify me when bitcoin is above $70000\") and get pinged once it fires.",
        .help_example = "/alert crypto bitcoin above 70000",
    },
    .{
        .id = .alerts_view,
        .parent = .alerts,
        .title = "🔔 Alerts — view / cancel",
        .body = "Pending alerts in this chat. Tap one to cancel it.",
        .kind = .dynamic_list,
        .help_body = "Lists every alert pending in this chat; tapping one cancels it (same as /alert cancel <id>).",
    },
    .{
        .id = .alerts_new,
        .parent = .alerts,
        .title = "🔔 New alert",
        .body = "Send /alert <crypto|weather|aqi> <subject> <above|below> <value> — or just tell me in plain language, e.g. \"alert me if bitcoin drops below 60000\".",
        .kind = .action,
        .help_body = "Alerts take several parameters, so this stays a typed command (or natural language) rather than a button form.",
        .help_example = "/alert weather Tehran above 35",
    },

    // ---- Reminders ----
    .{
        .id = .reminders,
        .parent = .root,
        .title = "⏰ Reminders",
        .body = "One-off or repeating pings at a time you choose.",
        .kind = .branch,
        .children = &.{
            .{ .id = .reminders_view, .emoji = "📋", .label = "View / cancel" },
            .{ .id = .reminders_new, .emoji = "➕", .label = "New reminder" },
        },
        .help_body = "Set a reminder for a duration from now, a clock time, or a specific date — rendered in your own timezone/format (Settings -> Personal).",
        .help_example = "/remind 5/22 14:30 water the plants",
    },
    .{
        .id = .reminders_view,
        .parent = .reminders,
        .title = "⏰ Reminders — view / cancel",
        .body = "Pending reminders in this chat. Tap one to cancel it.",
        .kind = .dynamic_list,
        .help_body = "Lists every reminder pending in this chat, each shown in its own setter's timezone/format; tapping one cancels it (same as /remind cancel <id>).",
    },
    .{
        .id = .reminders_new,
        .parent = .reminders,
        .title = "⏰ New reminder",
        .kind = .wizard,
        .help_body = "Walks you through picking a date and time with +/- stepper buttons (or just reply with a time/date to jump straight to it), then the message to send.",
    },

    // ---- Watches ----
    .{
        .id = .watches,
        .parent = .root,
        .title = "📰 Watches",
        .body = "RSS/Atom feeds this chat is watching for new items.",
        .kind = .branch,
        .children = &.{
            .{ .id = .watches_view, .emoji = "📋", .label = "View / unwatch" },
            .{ .id = .watches_new, .emoji = "➕", .label = "New watch" },
        },
        .help_body = "Get a short AI-written blurb posted here whenever a watched feed publishes something new.",
        .help_example = "/watch https://example.com/feed.xml",
    },
    .{
        .id = .watches_view,
        .parent = .watches,
        .title = "📰 Watches — view / unwatch",
        .body = "Feeds watched in this chat. Tap one to stop watching it.",
        .kind = .dynamic_list,
        .help_body = "Lists every feed watched in this chat; tapping one unwatches it (same as /unwatch <feed url>).",
    },
    .{
        .id = .watches_new,
        .parent = .watches,
        .title = "📰 New watch",
        .body = "Send /watch <feed url> to start watching it.",
        .kind = .action,
        .help_example = "/watch https://example.com/feed.xml",
    },

    // ---- Statistics ----
    .{
        .id = .stats,
        .parent = .root,
        .title = "📊 Statistics",
        .body = "See how this chat's conversation has been going.",
        .kind = .branch,
        .children = &.{
            .{ .id = .stats_text, .emoji = "🔢", .label = "Text stats" },
            .{ .id = .stats_wordcloud, .emoji = "☁️", .label = "Word cloud" },
            .{ .id = .stats_piechart, .emoji = "🥧", .label = "Top participants (pie chart)" },
        },
    },
    .{
        .id = .stats_text,
        .parent = .stats,
        .title = "📊 Text stats",
        .kind = .action,
        .help_body = "Total messages, distinct participants, and the top few by message count.",
        .help_example = "/stats",
    },
    .{
        .id = .stats_wordcloud,
        .parent = .stats,
        .title = "☁️ Word cloud",
        .kind = .action,
        .help_example = "/wordcloud",
    },
    .{
        .id = .stats_piechart,
        .parent = .stats,
        .title = "🥧 Top participants",
        .kind = .action,
        .help_body = "A pie chart of who's sent the most messages in this chat recently.",
    },

    // ---- Convert ----
    .{
        .id = .convert,
        .parent = .root,
        .title = "🔄 Convert",
        .kind = .action,
        .help_body = "Starts the guided file-conversion flow (send a file, then pick the target format from buttons) — same as /convert alone.",
        .help_example = "/convert",
    },

    // ---- Group Administration ----
    .{
        .id = .group_admin,
        .parent = .root,
        .title = "🛡 Group Administration",
        .body = "Moderation actions for this chat. Same access rules as their slash-command equivalents — tapping a button doesn't grant anything a command couldn't already do.",
        .kind = .branch,
        .children = &.{
            .{ .id = .group_admin_mute, .emoji = "🔇", .label = "Mute" },
            .{ .id = .group_admin_unmute, .emoji = "🔊", .label = "Unmute" },
            .{ .id = .group_admin_pin, .emoji = "📌", .label = "Pin" },
            .{ .id = .group_admin_unpin, .emoji = "📍", .label = "Unpin" },
            .{ .id = .group_admin_delete, .emoji = "🗑", .label = "Delete message" },
            .{ .id = .group_admin_kick, .emoji = "👢", .label = "Kick" },
            .{ .id = .group_admin_ban, .emoji = "⛔", .label = "Ban" },
            .{ .id = .group_admin_promote, .emoji = "⬆️", .label = "Promote to admin" },
            .{ .id = .group_admin_demote, .emoji = "⬇️", .label = "Demote" },
            .{ .id = .group_admin_redact, .emoji = "🧹", .label = "Redact / bulk delete" },
        },
    },
    .{
        .id = .group_admin_mute,
        .parent = .group_admin,
        .title = "🔇 Mute",
        .kind = .awaiting_input,
        .prompt = "Reply to the message of the person you want to mute.",
        .help_example = "reply to their message with /mute",
    },
    .{
        .id = .group_admin_unmute,
        .parent = .group_admin,
        .title = "🔊 Unmute",
        .kind = .awaiting_input,
        .prompt = "Reply to the message of the person you want to unmute.",
    },
    .{
        .id = .group_admin_pin,
        .parent = .group_admin,
        .title = "📌 Pin",
        .kind = .awaiting_input,
        .prompt = "Reply to the message you want to pin.",
    },
    .{
        .id = .group_admin_unpin,
        .parent = .group_admin,
        .title = "📍 Unpin",
        .kind = .action,
        .help_body = "Unpins whatever's currently pinned — no target needed.",
    },
    .{
        .id = .group_admin_delete,
        .parent = .group_admin,
        .title = "🗑 Delete message",
        .kind = .awaiting_input,
        .prompt = "Reply to the message you want deleted.",
    },
    .{
        .id = .group_admin_kick,
        .parent = .group_admin,
        .title = "👢 Kick",
        .kind = .awaiting_input,
        .prompt = "Reply to the message of the person you want to kick, or send their @username or user id.",
        .help_example = "@spammer, or their raw user id",
    },
    .{
        .id = .group_admin_ban,
        .parent = .group_admin,
        .title = "⛔ Ban",
        .kind = .awaiting_input,
        .prompt = "Reply to the message of the person you want to ban, or send their @username or user id.",
    },
    .{
        .id = .group_admin_promote,
        .parent = .group_admin,
        .title = "⬆️ Promote to admin",
        .kind = .awaiting_input,
        .prompt = "Reply to the message of the person you want to promote to admin. Bot owner only.",
    },
    .{
        .id = .group_admin_demote,
        .parent = .group_admin,
        .title = "⬇️ Demote",
        .kind = .awaiting_input,
        .prompt = "Reply to the message of the person you want to demote. Bot owner only.",
    },
    .{
        .id = .group_admin_redact,
        .parent = .group_admin,
        .title = "🧹 Redact / bulk delete",
        .body = "Delete messages in bulk, up to 100 at a time.",
        .kind = .branch,
        .children = &.{
            .{ .id = .group_admin_redact_lastn, .emoji = "🔢", .label = "Last N messages" },
            .{ .id = .group_admin_redact_user, .emoji = "👤", .label = "A user's last N" },
            .{ .id = .group_admin_redact_text, .emoji = "🔤", .label = "Containing text" },
            .{ .id = .group_admin_redact_regex, .emoji = "🧩", .label = "Matching regex (bot admin/owner)" },
        },
    },
    .{
        .id = .group_admin_redact_lastn,
        .parent = .group_admin_redact,
        .title = "🧹 Redact — last N",
        .kind = .awaiting_input,
        .prompt = "Send how many of the most recent messages to delete (up to 100).",
    },
    .{
        .id = .group_admin_redact_user,
        .parent = .group_admin_redact,
        .title = "🧹 Redact — a user's last N",
        .kind = .awaiting_input,
        .prompt = "Reply to that user's message, optionally followed by how many of their messages to delete (default: up to 100).",
    },
    .{
        .id = .group_admin_redact_text,
        .parent = .group_admin_redact,
        .title = "🧹 Redact — containing text",
        .kind = .awaiting_input,
        .prompt = "Send the substring to search for and delete (case-insensitive).",
    },
    .{
        .id = .group_admin_redact_regex,
        .parent = .group_admin_redact,
        .title = "🧹 Redact — matching regex",
        .kind = .awaiting_input,
        .prompt = "Send the regex pattern to match and delete. Bot admin/owner only, even if you got here as a live chat admin.",
    },

    // ---- Settings ----
    .{
        .id = .settings,
        .parent = .root,
        .title = "⚙️ Settings",
        .body = "Bot-wide, per-chat, and personal settings.",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_global, .emoji = "🌐", .label = "Global" },
            .{ .id = .settings_chat, .emoji = "💬", .label = "This chat" },
            .{ .id = .settings_personal, .emoji = "👤", .label = "Personal" },
        },
    },
    .{
        .id = .settings_global,
        .parent = .settings,
        .title = "🌐 Global settings",
        .body = "Bot-wide access control and configuration. Owner/bot admin only.",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_global_addadmin, .emoji = "➕", .label = "Add bot admin" },
            .{ .id = .settings_global_removeadmin, .emoji = "➖", .label = "Remove bot admin" },
            .{ .id = .settings_global_adduser, .emoji = "✅", .label = "Allow a user" },
            .{ .id = .settings_global_removeuser, .emoji = "🚫", .label = "Remove a user" },
            .{ .id = .settings_global_allowchat, .emoji = "🟢", .label = "Allow this chat" },
            .{ .id = .settings_global_disallowchat, .emoji = "🔴", .label = "Disallow this chat" },
            .{ .id = .settings_global_whois, .emoji = "🔎", .label = "Look up a user (/whois)" },
            .{ .id = .settings_global_scraper, .emoji = "🕷", .label = "Scraper config" },
        },
        .help_body = "The owner is always treated as a bot admin here too, everywhere one is checked — no need to add yourself.",
    },
    .{
        .id = .settings_global_addadmin,
        .parent = .settings_global,
        .title = "➕ Add bot admin",
        .kind = .awaiting_input,
        .prompt = "Reply to the user, or send @username or their user id, to make them a bot admin.",
    },
    .{
        .id = .settings_global_removeadmin,
        .parent = .settings_global,
        .title = "➖ Remove bot admin",
        .kind = .awaiting_input,
        .prompt = "Reply to the user, or send @username or their user id, to remove them as a bot admin.",
    },
    .{
        .id = .settings_global_adduser,
        .parent = .settings_global,
        .title = "✅ Allow a user",
        .kind = .awaiting_input,
        .prompt = "Reply to the user, or send @username or their user id, to let them use this bot.",
    },
    .{
        .id = .settings_global_removeuser,
        .parent = .settings_global,
        .title = "🚫 Remove a user",
        .kind = .awaiting_input,
        .prompt = "Reply to the user, or send @username or their user id, to remove them.",
    },
    .{
        .id = .settings_global_allowchat,
        .parent = .settings_global,
        .title = "🟢 Allow this chat",
        .kind = .action,
    },
    .{
        .id = .settings_global_disallowchat,
        .parent = .settings_global,
        .title = "🔴 Disallow this chat",
        .kind = .action,
    },
    .{
        .id = .settings_global_whois,
        .parent = .settings_global,
        .title = "🔎 Look up a user",
        .kind = .awaiting_input,
        .prompt = "Reply to a user, or send @username or their user id, to look them up.",
    },
    .{
        .id = .settings_global_scraper,
        .parent = .settings_global,
        .title = "🕷 Scraper config",
        .kind = .action,
        .help_body = "Shows the current scraper mode/endpoint. Changing it stays a typed command (several independent options) — see /scraper.",
        .help_example = "/scraper mode remote",
    },
    .{
        .id = .settings_chat,
        .parent = .settings,
        .title = "💬 This chat's settings",
        .body = "Per-chat overrides. Viewing is open to anyone; changing is owner-only, same as their slash commands.",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_chat_magicword, .emoji = "🪄", .label = "Magic word" },
            .{ .id = .settings_chat_persona, .emoji = "🎭", .label = "Persona" },
            .{ .id = .settings_chat_thinking, .emoji = "🧠", .label = "Show thinking" },
            .{ .id = .settings_chat_digest, .emoji = "📨", .label = "Daily digest" },
        },
    },
    .{
        .id = .settings_chat_magicword,
        .parent = .settings_chat,
        .title = "🪄 Magic word",
        .kind = .awaiting_input,
        .prompt = "Send the new magic word, or \"off\" to disable it. (Owner only to change.)",
    },
    .{
        .id = .settings_chat_persona,
        .parent = .settings_chat,
        .title = "🎭 Persona",
        .kind = .awaiting_input,
        .prompt = "Send this chat's new persona/system-prompt text, or \"off\" to reset to the default. (Owner only to change.)",
    },
    .{
        .id = .settings_chat_thinking,
        .parent = .settings_chat,
        .title = "🧠 Show thinking",
        .body = "Show the model's reasoning in this chat?",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_chat_thinking_on, .emoji = "✅", .label = "On" },
            .{ .id = .settings_chat_thinking_off, .emoji = "🚫", .label = "Off" },
            .{ .id = .settings_chat_thinking_default, .emoji = "↩️", .label = "Bot-wide default" },
        },
    },
    .{ .id = .settings_chat_thinking_on, .parent = .settings_chat_thinking, .title = "🧠 Show thinking: on", .kind = .action },
    .{ .id = .settings_chat_thinking_off, .parent = .settings_chat_thinking, .title = "🧠 Show thinking: off", .kind = .action },
    .{ .id = .settings_chat_thinking_default, .parent = .settings_chat_thinking, .title = "🧠 Show thinking: bot-wide default", .kind = .action },
    .{
        .id = .settings_chat_digest,
        .parent = .settings_chat,
        .title = "📨 Daily digest",
        .body = "Post a recent-activity summary here on a schedule?",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_chat_digest_on, .emoji = "✅", .label = "On" },
            .{ .id = .settings_chat_digest_off, .emoji = "🚫", .label = "Off" },
        },
    },
    .{ .id = .settings_chat_digest_on, .parent = .settings_chat_digest, .title = "📨 Digest: on", .kind = .action },
    .{ .id = .settings_chat_digest_off, .parent = .settings_chat_digest, .title = "📨 Digest: off", .kind = .action },
    .{
        .id = .settings_personal,
        .parent = .settings,
        .title = "👤 Personal settings",
        .body = "Your own timezone and date/time formatting — used for reminders wherever they show a real date/time.",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_personal_timezone, .emoji = "🌍", .label = "Timezone" },
            .{ .id = .settings_personal_dateformat, .emoji = "📅", .label = "Date format" },
            .{ .id = .settings_personal_timeformat, .emoji = "🕐", .label = "Time format" },
        },
        .help_body = "Defaults to a rough guess from your Telegram language, since Telegram exposes no real location/timezone — always overridable here.",
    },
    .{
        .id = .settings_personal_timezone,
        .parent = .settings_personal,
        .title = "🌍 Timezone",
        .kind = .awaiting_input,
        .prompt = "Send your UTC offset, e.g. +3:30, -5, or +0.",
        .help_body = "A fixed offset, not a real DST-aware zone — good enough for a personal bot, twice-a-year DST drift is an accepted tradeoff.",
        .help_example = "-5:00",
    },
    .{
        .id = .settings_personal_dateformat,
        .parent = .settings_personal,
        .title = "📅 Date format",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_personal_dateformat_mdy, .emoji = "🇺🇸", .label = "M/D/Y" },
            .{ .id = .settings_personal_dateformat_dmy, .emoji = "🇪🇺", .label = "D/M/Y" },
            .{ .id = .settings_personal_dateformat_ymd, .emoji = "📆", .label = "Y-M-D" },
        },
    },
    .{ .id = .settings_personal_dateformat_mdy, .parent = .settings_personal_dateformat, .title = "📅 Date format: M/D/Y", .kind = .action },
    .{ .id = .settings_personal_dateformat_dmy, .parent = .settings_personal_dateformat, .title = "📅 Date format: D/M/Y", .kind = .action },
    .{ .id = .settings_personal_dateformat_ymd, .parent = .settings_personal_dateformat, .title = "📅 Date format: Y-M-D", .kind = .action },
    .{
        .id = .settings_personal_timeformat,
        .parent = .settings_personal,
        .title = "🕐 Time format",
        .kind = .branch,
        .children = &.{
            .{ .id = .settings_personal_timeformat_24h, .emoji = "🕛", .label = "24h" },
            .{ .id = .settings_personal_timeformat_12h, .emoji = "🕧", .label = "12h (AM/PM)" },
        },
    },
    .{ .id = .settings_personal_timeformat_24h, .parent = .settings_personal_timeformat, .title = "🕐 Time format: 24h", .kind = .action },
    .{ .id = .settings_personal_timeformat_12h, .parent = .settings_personal_timeformat, .title = "🕐 Time format: 12h (AM/PM)", .kind = .action },

    // ---- Help ----
    .{
        .id = .help,
        .parent = .root,
        .title = "❓ Help",
        .body = "Browse the same menu read-only — picking a module here explains it instead of doing anything.",
        .kind = .branch,
        .children = &.{
            .{ .id = .alerts, .emoji = "🔔", .label = "Alerts" },
            .{ .id = .reminders, .emoji = "⏰", .label = "Reminders" },
            .{ .id = .watches, .emoji = "📰", .label = "Watches" },
            .{ .id = .stats, .emoji = "📊", .label = "Statistics" },
            .{ .id = .convert, .emoji = "🔄", .label = "Convert" },
            .{ .id = .group_admin, .emoji = "🛡", .label = "Group Administration" },
            .{ .id = .settings, .emoji = "⚙️", .label = "Settings" },
        },
    },
};

comptime {
    // Guards against a copy/paste typo leaving a node out of `table` (or
    // doubling one up) as the tree grows — every `NodeId` must appear
    // exactly once.
    var seen = std.EnumArray(NodeId, bool).initFill(false);
    for (table) |n| {
        if (seen.get(n.id)) @compileError("menu_tree: duplicate node " ++ @tagName(n.id));
        seen.set(n.id, true);
    }
    for (std.enums.values(NodeId)) |id| {
        if (!seen.get(id)) @compileError("menu_tree: node " ++ @tagName(id) ++ " has no table entry");
    }
}

const by_id = blk: {
    var arr: [table.len]MenuNode = undefined;
    for (table) |n| arr[@intFromEnum(n.id)] = n;
    break :blk arr;
};

pub fn node(id: NodeId) *const MenuNode {
    return &by_id[@intFromEnum(id)];
}

const testing = std.testing;

test "every node's parent is reachable from root, and root has no parent" {
    try testing.expectEqual(@as(?NodeId, null), node(.root).parent);
    for (std.enums.values(NodeId)) |id| {
        if (id == .root) continue;
        var cur = id;
        var hops: usize = 0;
        while (node(cur).parent) |p| {
            cur = p;
            hops += 1;
            try testing.expect(hops < 20); // guards against an accidental parent cycle
        }
        try testing.expectEqual(NodeId.root, cur);
    }
}

test "every branch/dynamic_list child's parent field points back at its declaring node" {
    for (table) |n| {
        for (n.children) |c| {
            // `help`'s children intentionally repeat root's real modules
            // (read-only browsing), so their `.parent` legitimately points
            // at `.root`, not `.help` — skip that one node's own check.
            if (n.id == .help) continue;
            try testing.expectEqual(n.id, node(c.id).parent.?);
        }
    }
}

test "awaiting_input nodes carry a non-empty prompt, action/branch nodes don't need one" {
    for (table) |n| {
        if (n.kind == .awaiting_input) try testing.expect(n.prompt.len > 0);
    }
}
