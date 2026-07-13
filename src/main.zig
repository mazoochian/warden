const std = @import("std");
const Io = std.Io;

const config_mod = @import("config.zig");
const auth = @import("auth.zig");
const iface = @import("platform/interface.zig");
const telegram_platform = @import("platform/telegram.zig");
const ChatStore = @import("store/chat_store.zig").ChatStore;
const stats = @import("store/stats.zig");
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
const settings = @import("store/settings.zig");
const scraper_settings = @import("store/scraper_settings.zig");

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
};
const web_search_tool = @import("tools/web_search.zig").tool;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const config = config_mod.Config.load(init.environ_map, init.arena.allocator(), io) catch |err| {
        std.log.err("config error: {t} (did you set WARDEN_TELEGRAM_BOT_TOKEN?)", .{err});
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

    // Only Telegram is wired up today. Adding another platform means
    // constructing its connector here too and looping over all of them —
    // `handleMessage` below is already platform-agnostic.
    var telegram_adapter = telegram_platform.TelegramConnector.init(gpa, io, config.telegram_bot_token);
    defer telegram_adapter.deinit();
    const connectors = [_]iface.Connector{telegram_adapter.connector()};

    var chat_store = ChatStore.init(gpa, io, config.data_dir, config.retention_messages);
    defer chat_store.deinit();

    var pending_confirmations = group_admin.PendingConfirmations.init(gpa, io, config.confirm_timeout_seconds);
    defer pending_confirmations.deinit();

    var digest_scheduler = scheduler.DigestScheduler.init(gpa, io, config.digest_interval_seconds);
    defer digest_scheduler.deinit();
    loadDigestScheduleFromDisk(gpa, &chat_store, &digest_scheduler);

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

    // Long-lived: every message spawns a task into this group (never
    // awaited/canceled during normal operation — see `Group`'s doc comment
    // on why that's fine for a repeatedly-added-to, long-lived group). This
    // is what keeps one slow chat (a stuck LLM call, a slow tool) from
    // blocking polling or any other chat: the loop below only ever does the
    // fast, sequential parts (poll, group by nothing — spawn per message,
    // check digests) and never blocks on `handleMessage` itself.
    var worker_group: Io.Group = .init;

    while (true) {
        for (connectors) |connector| {
            var poll_arena = std.heap.ArenaAllocator.init(gpa);
            defer poll_arena.deinit();
            const poll_a = poll_arena.allocator();

            const messages = connector.poll(poll_a) catch |err| {
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
                // would otherwise spin against a dead network. Cool off
                // before the next attempt.
                Io.sleep(io, .fromSeconds(5), .awake) catch {};
                continue;
            };

            for (messages) |msg| {
                const ts = Io.Timestamp.now(io, .real).toSeconds();

                // Each task owns an arena for its whole lifetime, created
                // here (not shared with `poll_arena`, which this cycle
                // frees as soon as every message in it has been spawned
                // off) and freed by the task itself when it's done. `msg`
                // is duped into it right away, before `poll_arena` can be
                // freed out from under a task that hasn't started yet.
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
                    &config,
                    &chat_store,
                    llm_provider,
                    active_tools,
                    &pending_confirmations,
                    &digest_scheduler,
                    io,
                    gpa,
                    ts,
                    task_arena,
                    duped_msg,
                });
            }

            // Piggybacks on the poll loop's natural ~30s cadence (Telegram's
            // long-poll timeout) rather than a separate timer/thread — fine
            // granularity for a daily-ish interval. Only sends via this one
            // connector; see `checkAndSendDueDigests`'s doc comment for the
            // multi-platform caveat.
            const now = Io.Timestamp.now(io, .real).toSeconds();
            checkAndSendDueDigests(connector, gpa, io, &config, &chat_store, &digest_scheduler, llm_provider, now);
        }
    }
}

/// Body of one spawned per-message task (see `worker_group` above). Owns
/// `task_arena` end-to-end: created by the caller right before spawning
/// (so `duped_msg` has somewhere stable to live), destroyed here once this
/// message is fully handled.
fn processMessageTask(
    connector: iface.Connector,
    config: *const config_mod.Config,
    chat_store: *ChatStore,
    llm_provider: llm.Provider,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    io: Io,
    gpa: std.mem.Allocator,
    ts: i64,
    task_arena: *std.heap.ArenaAllocator,
    msg: iface.Message,
) void {
    defer {
        task_arena.deinit();
        gpa.destroy(task_arena);
    }
    const a = task_arena.allocator();

    // Every group member's message counts toward this chat's local record
    // (stats/content recall), regardless of who sent it — only
    // replies/actions are owner-gated below.
    chat_store.record(msg.chat_id, msg, ts);

    const tool_ctx = tool_registry.ToolContext{
        .allocator = a,
        .io = io,
        .connector = connector,
        .chat_id = msg.chat_id,
        .tmp_dir = config.tmp_dir,
        .searxng_url = config.searxng_url,
        .scraper = loadScraperSnapshot(chat_store, a),
    };
    handleMessage(connector, a, config, chat_store, llm_provider, tool_ctx, tools, pending, digest_scheduler, io, ts, msg);
}

/// Rebuilds the in-memory enabled-chat set from each existing chat db's
/// persisted `chat_settings.digest_enabled` — so digests opted into before
/// a restart keep firing rather than silently going quiet.
fn loadDigestScheduleFromDisk(gpa: std.mem.Allocator, chat_store: *ChatStore, digest_scheduler: *scheduler.DigestScheduler) void {
    const ids = chat_store.listExistingChatIds(gpa) catch |err| {
        std.log.err("digest: failed to scan existing chats: {t}", .{err});
        return;
    };
    defer {
        for (ids) |id| gpa.free(id);
        gpa.free(ids);
    }

    for (ids) |chat_id| {
        const db = chat_store.get(chat_id) catch |err| {
            std.log.err("digest: failed to open db for chat {s}: {t}", .{ chat_id, err });
            continue;
        };
        if (settings.getBool(db, "digest_enabled", false)) {
            digest_scheduler.enable(chat_id) catch |err| {
                std.log.err("digest: failed to restore schedule for chat {s}: {t}", .{ chat_id, err });
            };
        }
    }
}

/// Only sends via `connector` — correct as long as there's exactly one
/// connector (true today). Once a second platform is wired up, the
/// scheduler will need to track which connector each chat_id belongs to
/// (chat_id alone isn't namespaced by platform anywhere in this codebase
/// yet) rather than assuming a single global connector.
fn checkAndSendDueDigests(
    connector: iface.Connector,
    gpa: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    chat_store: *ChatStore,
    digest_scheduler: *scheduler.DigestScheduler,
    llm_provider: llm.Provider,
    now: i64,
) void {
    const enabled_chat_ids = digest_scheduler.snapshotEnabledChatIds(gpa) catch |err| {
        std.log.err("digest: failed to snapshot enabled chats: {t}", .{err});
        return;
    };
    defer {
        for (enabled_chat_ids) |id| gpa.free(id);
        gpa.free(enabled_chat_ids);
    }

    for (enabled_chat_ids) |chat_id| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const db = chat_store.get(chat_id) catch |err| {
            std.log.err("digest: failed to open db for chat {s}: {t}", .{ chat_id, err });
            continue;
        };

        const last_sent = settings.getInt(db, "last_digest_ts", 0);
        if (now - last_sent < config.digest_interval_seconds) continue;

        const tool_ctx = tool_registry.ToolContext{
            .allocator = a,
            .io = io,
            .connector = connector,
            .chat_id = chat_id,
            .tmp_dir = config.tmp_dir,
            .searxng_url = config.searxng_url,
            .scraper = loadScraperSnapshot(chat_store, a),
        };
        const digest_text = digest.generate(llm_provider, a, tool_ctx, db) catch |err| {
            std.log.err("digest: generate failed for chat {s}: {t}", .{ chat_id, err });
            continue;
        };
        connector.sendMessage(a, chat_id, digest_text, null);
        settings.setInt(db, "last_digest_ts", now) catch |err| {
            std.log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ chat_id, err });
        };
    }
}

/// Reads the owner's current `/scraper` configuration for the `scrape_site`
/// tool. Loaded fresh per message (rather than cached at startup) so a
/// runtime change via `/scraper` takes effect on the very next message.
fn loadScraperSnapshot(chat_store: *ChatStore, allocator: std.mem.Allocator) tool_registry.ScraperConfig {
    const db = chat_store.get(scraper_settings.global_chat_id) catch |err| {
        std.log.err("scraper: failed to open global settings db: {t}", .{err});
        return .{};
    };
    return scraper_settings.load(db, allocator);
}

fn handleMessage(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    chat_store: *ChatStore,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    io: Io,
    now: i64,
    msg: iface.Message,
) void {
    const text = msg.text orelse return;
    if (text.len == 0) return;

    if (std.mem.eql(u8, text, "/ping")) {
        connector.sendMessage(a, msg.chat_id, "pong", msg.message_id);
    } else if (std.mem.eql(u8, text, "/stats")) {
        replyWithStats(connector, a, chat_store, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/wordcloud")) {
        replyWithWordcloud(connector, a, chat_store, config.tmp_dir, io, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/digest") or std.mem.startsWith(u8, text, "/digest ")) {
        handleDigestCommand(connector, a, chat_store, digest_scheduler, llm_provider, tool_ctx, now, msg.chat_id, msg.message_id, text);
    } else if (std.mem.eql(u8, text, "/mute")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.mute(connector, a, msg, now);
    } else if (std.mem.eql(u8, text, "/unmute")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.unmute(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/pin")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.pin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/unpin")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.unpin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/delete")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.deleteMessage(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/kick")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.requestConfirmation(connector, a, chat_store, msg, .kick); // pending, now commented for now
    } else if (std.mem.eql(u8, text, "/ban")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.requestConfirmation(connector, a, chat_store, msg, .ban);
    } else if (std.mem.eql(u8, text, "/confirm")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.confirm(connector, a, pending, now, msg);
    } else if (std.mem.eql(u8, text, "/cancel")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.cancel(connector, a, pending, msg);
    } else if (std.mem.startsWith(u8, text, "/token")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return;
        handleToken(connector, a, chat_store, msg, text);
    } else if (std.mem.eql(u8, text, "/magicword") or std.mem.startsWith(u8, text, "/magicword ")) {
        handleMagicWord(connector, a, config, chat_store, msg, text);
    } else if (std.mem.eql(u8, text, "/scraper") or std.mem.startsWith(u8, text, "/scraper ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return;
        handleScraperCommand(connector, a, chat_store, msg, text);
    } else if (text[0] == '/') {
        // Unrecognized slash command: ignore rather than forwarding to the
        // LLM as if it were a question.
        return;
    } else if (isAddressedToBot(a, chat_store, msg, text)) {
        // The bot's free-form LLM Q&A is owner-only — every other command
        // above this stays open to anyone (unchanged). Silent, not an
        // error reply: an unaddressed mention from someone else shouldn't
        // announce "I only answer my owner" to the whole group.
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return;
        const replied_to = if (msg.reply_to_is_me) msg.reply_to_text else null;
        replyWithAnswer(connector, a, chat_store, llm_provider, tool_ctx, tools, config.system_prompt, io, now, msg.chat_id, msg.message_id, text, replied_to);
    }
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
fn isAddressedToBot(a: std.mem.Allocator, chat_store: *ChatStore, msg: iface.Message, text: []const u8) bool {
    if (!msg.is_group) return true;
    if (msg.mentions_me or msg.reply_to_is_me) return true;

    const db = chat_store.get(msg.chat_id) catch return false;
    const magic = settings.getTextAlloc(db, a, magic_word_key) orelse return false;
    return containsWordIgnoreCase(text, magic);
}

const magic_word_key = "magic_word";
const max_magic_word_len = 64;

fn handleMagicWord(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    chat_store: *ChatStore,
    msg: iface.Message,
    text: []const u8,
) void {
    const db = chat_store.get(msg.chat_id) catch |err| {
        std.log.err("magicword: failed to open db for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    const arg = std.mem.trim(u8, text["/magicword".len..], " ");

    if (arg.len == 0) {
        const reply_text = if (settings.getTextAlloc(db, a, magic_word_key)) |word|
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
        settings.setText(db, magic_word_key, "") catch |err| {
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

    settings.setText(db, magic_word_key, arg) catch |err| {
        std.log.err("magicword: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    const confirmation = std.fmt.allocPrint(a, "Magic word set to \"{s}\" — I'll answer any message that contains it.", .{arg}) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

/// Owner-only, unlike /magicword: the whole command (including viewing) is
/// gated in the dispatcher above, since the config here can include a
/// remote endpoint/API key that shouldn't be visible to random chat
/// members. Bot-wide, not per-chat — see `scraper_settings.global_chat_id`.
fn handleScraperCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    chat_store: *ChatStore,
    msg: iface.Message,
    text: []const u8,
) void {
    const db = chat_store.get(scraper_settings.global_chat_id) catch |err| {
        std.log.err("scraper: failed to open global settings db: {t}", .{err});
        return;
    };
    const arg = std.mem.trim(u8, text["/scraper".len..], " ");

    if (arg.len == 0) {
        const snap = scraper_settings.load(db, a);
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
            const snap = scraper_settings.load(db, a);
            if (snap.remote_url == null) {
                reply(connector, a, msg.chat_id, msg.message_id, "Set a remote endpoint first with /scraper url <endpoint>.");
                return;
            }
            scraper_settings.setMode(db, .remote) catch |err| {
                std.log.err("scraper: failed to set mode for global settings: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update the scraper mode, try again.");
                return;
            };
            const confirmation = std.fmt.allocPrint(a, "Scraper mode set to remote ({s}).", .{snap.remote_url.?}) catch return;
            connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        } else if (std.mem.eql(u8, rest, "local")) {
            scraper_settings.setMode(db, .local) catch |err| {
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
        scraper_settings.setRemoteUrl(db, rest) catch |err| {
            std.log.err("scraper: failed to set remote url: {t}", .{err});
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that endpoint, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper endpoint saved. Switch to it with /scraper mode remote.");
    } else if (std.mem.eql(u8, sub, "apikey")) {
        if (rest.len == 0 or std.mem.eql(u8, rest, "off")) {
            scraper_settings.setRemoteApiKey(db, "") catch |err| {
                std.log.err("scraper: failed to clear remote api key: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't clear the API key, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper API key cleared.");
        } else {
            scraper_settings.setRemoteApiKey(db, rest) catch |err| {
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
    chat_store: *ChatStore,
    msg: iface.Message,
    text: []const u8,
) void {
    const target = replyTarget(msg) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user you want to view/change tokens for.");
        return;
    };
    const arg = std.mem.trim(u8, text["/token".len..], " ");
    const db = chat_store.get(msg.chat_id) catch |err| {
        std.log.err("token: failed to open db for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    // If there is no argument, get the current token count and reply with it.
    if (arg.len == 0) {
        const count = settings.getTokens(db, target.user_id, 0);
        const message = std.fmt.allocPrint(a, "Current token count: {}", .{count}) catch |err| {
            std.debug.print("Failed to allocate message string: {}\n", .{err});
            return; // Exit the function early since we couldn't format the message
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        // replyWithAnswer(connector, a, chat_store, llm_provider, tool_ctx, chat_id, std.fmt.allocPrint(a, "Current token count: {}", .{count}) catch "");
        return;
    }
    // Else just set the token count to the parsed value and reply with a confirmation.
    else {
        const count = std.fmt.parseInt(i64, arg, 10) catch 0;
        std.log.info("Detected the count to be {}", .{count});
        settings.setTokens(db, target.user_id, count) catch |err| {
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
    chat_store: *ChatStore,
    digest_scheduler: *scheduler.DigestScheduler,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    now: i64,
    chat_id: []const u8,
    reply_to: ?[]const u8,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/digest".len..], " ");

    const db = chat_store.get(chat_id) catch |err| {
        std.log.err("digest: failed to open db for chat {s}: {t}", .{ chat_id, err });
        return;
    };

    if (std.mem.eql(u8, arg, "on")) {
        digest_scheduler.enable(chat_id) catch |err| {
            std.log.err("digest: failed to enable for chat {s}: {t}", .{ chat_id, err });
            connector.sendMessage(a, chat_id, "Couldn't enable digests, try again.", reply_to);
            return;
        };
        settings.setBool(db, "digest_enabled", true) catch |err| {
            std.log.err("digest: failed to persist enabled flag for chat {s}: {t}", .{ chat_id, err });
        };
        const hours = @divTrunc(digest_scheduler.interval_seconds, 3600);
        const msg_text = std.fmt.allocPrint(a, "Digest enabled — I'll post one roughly every {d}h.", .{hours}) catch return;
        connector.sendMessage(a, chat_id, msg_text, reply_to);
    } else if (std.mem.eql(u8, arg, "off")) {
        digest_scheduler.disable(chat_id);
        settings.setBool(db, "digest_enabled", false) catch |err| {
            std.log.err("digest: failed to persist disabled flag for chat {s}: {t}", .{ chat_id, err });
        };
        connector.sendMessage(a, chat_id, "Digest disabled.", reply_to);
    } else if (std.mem.eql(u8, arg, "now")) {
        const digest_text = digest.generate(llm_provider, a, tool_ctx, db) catch |err| {
            std.log.err("digest: generate failed for chat {s}: {t}", .{ chat_id, err });
            connector.sendMessage(a, chat_id, "Couldn't generate a digest just now.", reply_to);
            return;
        };
        connector.sendMessage(a, chat_id, digest_text, reply_to);
        settings.setInt(db, "last_digest_ts", now) catch |err| {
            std.log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ chat_id, err });
        };
    } else {
        const enabled = digest_scheduler.isEnabled(chat_id);
        const last = settings.getInt(db, "last_digest_ts", 0);
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
        connector.sendMessage(a, chat_id, msg_text, reply_to);
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
    }
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
    chat_store: *ChatStore,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    system_prompt: ?[]const u8,
    io: Io,
    now: i64,
    chat_id: []const u8,
    reply_to: ?[]const u8,
    question: []const u8,
    replied_to: ?[]const u8,
) void {
    const db = chat_store.get(chat_id) catch |err| {
        std.log.err("qa: failed to open db for chat {s}: {t}", .{ chat_id, err });
        return;
    };

    // The placeholder + ticker only work when the platform supports
    // editing (Telegram does); anything that doesn't falls back to
    // exactly the old behavior — one blocking call, one send at the end.
    const placeholder_id = connector.sendMessageReturningId(a, chat_id, thinking_text, reply_to) catch |err| blk: {
        std.log.warn("qa: couldn't send a placeholder for chat {s}, falling back to a plain reply: {t}", .{ chat_id, err });
        break :blk null;
    };
    std.log.info("qa: placeholder for chat {s} = {?s}", .{ chat_id, placeholder_id });

    var state = TickerState{ .io = io, .allocator = a };
    var progress: toolcall.Progress = .{};
    var ticker_future: ?Io.Future(void) = null;
    if (placeholder_id) |pid| {
        progress = .{ .ptr = &state, .onEvent = onProgressEvent };
        ticker_future = Io.concurrent(io, tickerLoop, .{ connector, chat_id, pid, &state }) catch |err| blk: {
            std.log.warn("qa: couldn't start the thinking animation for chat {s}: {t}", .{ chat_id, err });
            break :blk null;
        };
    }

    std.log.info("qa: calling the model for chat {s}", .{chat_id});
    const raw_answer_or_err = qa.answer(llm_provider, a, tool_ctx, tools, db, system_prompt, question, replied_to, progress);

    // Stop the ticker before touching the placeholder ourselves — it's the
    // sole owner of that Future until this point (see `Future.cancel`'s
    // "not threadsafe" note), and cancel() blocks until it has actually
    // stopped, so there's no risk of it clobbering the final edit below.
    if (ticker_future) |*f| _ = f.cancel(io);
    std.log.info("qa: model call for chat {s} returned", .{chat_id});

    const raw_answer = raw_answer_or_err catch |err| {
        std.log.err("qa: failed to answer in chat {s}: {t}", .{ chat_id, err });
        const error_text = "Sorry, I couldn't reach the model just now.";
        if (placeholder_id) |pid| {
            if (connector.editMessage(a, chat_id, pid, error_text)) |_| {
                std.log.info("qa: error message edited into placeholder for chat {s}", .{chat_id});
            } else |edit_err| {
                std.log.warn("qa: editing error message into placeholder failed for chat {s}: {t}, sending a new message instead", .{ chat_id, edit_err });
                connector.sendMessage(a, chat_id, error_text, reply_to);
            }
        } else {
            connector.sendMessage(a, chat_id, error_text, reply_to);
        }
        return;
    };

    // Models occasionally produce a whitespace-only answer (e.g. after a
    // photo-sending tool already did the visible work); Telegram rejects
    // empty text with a 400, so don't try to send it — and don't leave the
    // placeholder stuck showing "thinking" forever either.
    const answer = std.mem.trim(u8, raw_answer, " \t\r\n");
    std.log.info("qa: answer for chat {s} is {d} bytes (raw {d})", .{ chat_id, answer.len, raw_answer.len });
    if (answer.len == 0) {
        std.log.info("qa: empty answer for chat {s}, deleting placeholder", .{chat_id});
        if (placeholder_id) |pid| connector.deleteMessage(a, chat_id, pid) catch |err| {
            // Previously swallowed silently — if this fails (network
            // hiccup, message already gone), the placeholder is stuck
            // showing "thinking" forever with zero trace of why. At least
            // log it; there's no good fallback text to edit in instead
            // since there was never a real answer to show.
            std.log.warn("qa: failed to delete empty-answer placeholder for chat {s}: {t}", .{ chat_id, err });
        };
        return;
    }

    if (placeholder_id) |pid| {
        if (connector.editMessage(a, chat_id, pid, answer)) |_| {
            std.log.info("qa: final answer edited into placeholder for chat {s}", .{chat_id});
        } else |err| {
            std.log.warn("qa: final edit failed for chat {s}, sending a new message instead: {t}", .{ chat_id, err });
            connector.sendMessage(a, chat_id, answer, reply_to);
        }
    } else {
        connector.sendMessage(a, chat_id, answer, reply_to);
    }

    // Log the bot's own reply too, so follow-up questions see it in the
    // history window (inbound polling never echoes our own sends back).
    const bot_username = connector.selfUsername() orelse "warden";
    chat_store.record(chat_id, iface.Message{
        .chat_id = chat_id,
        .user_id = "warden",
        .username = bot_username,
        .text = answer,
    }, now);
}

fn replyWithWordcloud(
    connector: iface.Connector,
    a: std.mem.Allocator,
    chat_store: *ChatStore,
    tmp_dir: []const u8,
    io: Io,
    chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const db = chat_store.get(chat_id) catch |err| {
        std.log.err("wordcloud: failed to open db for chat {s}: {t}", .{ chat_id, err });
        return;
    };
    const words = wordcloud.topWords(a, db, 60) catch |err| {
        std.log.err("wordcloud: tokenize failed for chat {s}: {t}", .{ chat_id, err });
        return;
    };
    if (words.len == 0) {
        connector.sendMessage(a, chat_id, "Not enough logged messages yet to build a word cloud.", reply_to);
        return;
    }
    const png = wordcloud.render(a, io, tmp_dir, words) catch |err| {
        std.log.err("wordcloud: render failed for chat {s}: {t}", .{ chat_id, err });
        connector.sendMessage(a, chat_id, "Couldn't render the word cloud (is Node installed?).", reply_to);
        return;
    };
    connector.sendPhoto(a, chat_id, png, "Word cloud of recent messages");
}

fn replyWithStats(connector: iface.Connector, a: std.mem.Allocator, chat_store: *ChatStore, chat_id: []const u8, reply_to: ?[]const u8) void {
    const db = chat_store.get(chat_id) catch |err| {
        std.log.err("stats: failed to open db for chat {s}: {t}", .{ chat_id, err });
        return;
    };
    const s = stats.compute(db, a, 5) catch |err| {
        std.log.err("stats: query failed for chat {s}: {t}", .{ chat_id, err });
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

    connector.sendMessage(a, chat_id, buf.writer.buffered(), reply_to);
}

// Zig's test collector only walks `test` blocks reachable from the file
// passed to `addTest` — it does NOT transitively pull in tests from files
// that are merely `@import`ed for their declarations. Each module below
// that has its own `test` blocks must be explicitly re-referenced here (or
// `zig build test` silently runs zero of its tests, no error, no warning).
test {
    _ = auth;
    _ = @import("store/chat_store.zig");
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
    _ = @import("store/settings.zig");
    _ = @import("http_util.zig");
    _ = @import("features/scheduler.zig");
    _ = @import("features/digest.zig");
    _ = @import("tools/html_extract.zig");
    _ = @import("tools/scrape_site.zig");
    _ = @import("store/scraper_settings.zig");
    _ = @import("platform/interface.zig");
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
