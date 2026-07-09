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
const tool_registry = @import("tools/registry.zig");
const group_admin = @import("features/group_admin.zig");
const wordcloud = @import("features/wordcloud.zig");
const digest = @import("features/digest.zig");
const scheduler = @import("features/scheduler.zig");
const settings = @import("store/settings.zig");

const all_tools = [_]tool_registry.ToolDef{
    @import("tools/calculator.zig").tool,
    @import("tools/weather.zig").tool,
    @import("tools/currency.zig").tool,
    @import("tools/fetch_url.zig").tool,
    @import("tools/draw_diagram.zig").tool,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const config = config_mod.Config.load(init.environ_map, init.arena.allocator()) catch |err| {
        std.log.err("config error: {t} (did you set WARDEN_TELEGRAM_BOT_TOKEN?)", .{err});
        return err;
    };

    // Only Telegram is wired up today. Adding another platform means
    // constructing its connector here too and looping over all of them —
    // `handleMessage` below is already platform-agnostic.
    var telegram_adapter = telegram_platform.TelegramConnector.init(gpa, io, config.telegram_bot_token);
    defer telegram_adapter.deinit();
    const connectors = [_]iface.Connector{telegram_adapter.connector()};

    var chat_store = ChatStore.init(gpa, io, config.data_dir, config.retention_messages);
    defer chat_store.deinit();

    var pending_confirmations = group_admin.PendingConfirmations.init(gpa, config.confirm_timeout_seconds);
    defer pending_confirmations.deinit();

    var digest_scheduler = scheduler.DigestScheduler.init(gpa, config.digest_interval_seconds);
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

    while (true) {
        for (connectors) |connector| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();

            const messages = connector.poll(a) catch |err| {
                std.log.err("poll failed: {t}", .{err});
                continue;
            };

            for (messages) |msg| {
                const ts = Io.Timestamp.now(io, .real).toSeconds();

                // Every group member's message counts toward this chat's
                // local record (stats/content recall), regardless of who
                // sent it — only replies/actions are owner-gated below.
                chat_store.record(msg.chat_id, msg, ts);

                const tool_ctx = tool_registry.ToolContext{
                    .allocator = a,
                    .io = io,
                    .connector = connector,
                    .chat_id = msg.chat_id,
                    .tmp_dir = config.tmp_dir,
                };
                handleMessage(connector, a, &config, &chat_store, llm_provider, tool_ctx, &pending_confirmations, &digest_scheduler, io, ts, msg);
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
    var it = digest_scheduler.enabled_chats.keyIterator();
    while (it.next()) |chat_id_ptr| {
        const chat_id = chat_id_ptr.*;

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
        };
        const digest_text = digest.generate(llm_provider, a, tool_ctx, db) catch |err| {
            std.log.err("digest: generate failed for chat {s}: {t}", .{ chat_id, err });
            continue;
        };
        connector.sendMessage(a, chat_id, digest_text);
        settings.setInt(db, "last_digest_ts", now) catch |err| {
            std.log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ chat_id, err });
        };
    }
}

fn handleMessage(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    chat_store: *ChatStore,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    io: Io,
    now: i64,
    msg: iface.Message,
) void {
    const text = msg.text orelse return;
    if (text.len == 0) return;
    // var seed: u64 = undefined;
    // io.random(std.mem.asBytes(&seed));
    // var prng = std.Random.DefaultPrng.init(seed);
    // const random = prng.random();
    // const n = random.intRangeLessThan(u8, 0, 100);

    if (std.mem.eql(u8, text, "/ping")) {
        connector.sendMessage(a, msg.chat_id, "pong");
    } else if (std.mem.eql(u8, text, "/stats")) {
        replyWithStats(connector, a, chat_store, msg.chat_id);
    } else if (std.mem.eql(u8, text, "/wordcloud")) {
        replyWithWordcloud(connector, a, chat_store, config.tmp_dir, io, msg.chat_id);
    } else if (std.mem.eql(u8, text, "/digest") or std.mem.startsWith(u8, text, "/digest ")) {
        handleDigestCommand(connector, a, chat_store, digest_scheduler, llm_provider, tool_ctx, now, msg.chat_id, text);
    } else if (std.mem.eql(u8, text, "/mute")) {
        group_admin.mute(connector, a, msg, now);
    } else if (std.mem.eql(u8, text, "/unmute")) {
        group_admin.unmute(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/pin")) {
        group_admin.pin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/unpin")) {
        group_admin.unpin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/delete")) {
        group_admin.deleteMessage(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/kick")) {
        group_admin.requestConfirmation(connector, a, chat_store, msg, .kick); // pending, now commented for now
    } else if (std.mem.eql(u8, text, "/ban")) {
        group_admin.requestConfirmation(connector, a, chat_store, msg, .ban);
    } else if (std.mem.eql(u8, text, "/confirm")) {
        group_admin.confirm(connector, a, pending, now, msg);
    } else if (std.mem.eql(u8, text, "/cancel")) {
        group_admin.cancel(connector, a, pending, msg);
    } else if (std.mem.startsWith(u8, text, "/token")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return;
        handleToken(connector, a, chat_store, msg, text);
    } else if (text[0] == '/') {
        // Unrecognized slash command: ignore rather than forwarding to the
        // LLM as if it were a question.
        return;
    } else {
        // if (!containsAnyWord(text, &[_][]const u8{ "@ameli_hassan_bot", "Hassan", "hassan", "حسن" }) or (msg.reply_to_username != null and std.mem.eql(u8, msg.reply_to_username.?, "@ameli_hassan_bot"))) return;
        // if(n < 30)
        // {
        // replyWithAnswer(connector, a, chat_store, llm_provider, tool_ctx, msg.chat_id, text);
        // }
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
        reply(connector, a, msg.chat_id, "Reply to the user you want to view/change tokens for.");
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
        connector.sendMessage(a, msg.chat_id, message);
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
        connector.sendMessage(a, msg.chat_id, message);
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
            connector.sendMessage(a, chat_id, "Couldn't enable digests, try again.");
            return;
        };
        settings.setBool(db, "digest_enabled", true) catch |err| {
            std.log.err("digest: failed to persist enabled flag for chat {s}: {t}", .{ chat_id, err });
        };
        const hours = @divTrunc(digest_scheduler.interval_seconds, 3600);
        const msg_text = std.fmt.allocPrint(a, "Digest enabled — I'll post one roughly every {d}h.", .{hours}) catch return;
        connector.sendMessage(a, chat_id, msg_text);
    } else if (std.mem.eql(u8, arg, "off")) {
        digest_scheduler.disable(chat_id);
        settings.setBool(db, "digest_enabled", false) catch |err| {
            std.log.err("digest: failed to persist disabled flag for chat {s}: {t}", .{ chat_id, err });
        };
        connector.sendMessage(a, chat_id, "Digest disabled.");
    } else if (std.mem.eql(u8, arg, "now")) {
        const digest_text = digest.generate(llm_provider, a, tool_ctx, db) catch |err| {
            std.log.err("digest: generate failed for chat {s}: {t}", .{ chat_id, err });
            connector.sendMessage(a, chat_id, "Couldn't generate a digest just now.");
            return;
        };
        connector.sendMessage(a, chat_id, digest_text);
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
        connector.sendMessage(a, chat_id, msg_text);
    }
}

fn replyWithAnswer(
    connector: iface.Connector,
    a: std.mem.Allocator,
    chat_store: *ChatStore,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    chat_id: []const u8,
    question: []const u8,
) void {
    const db = chat_store.get(chat_id) catch |err| {
        std.log.err("qa: failed to open db for chat {s}: {t}", .{ chat_id, err });
        return;
    };
    const answer = qa.answer(llm_provider, a, tool_ctx, &all_tools, db, question) catch |err| {
        std.log.err("qa: failed to answer in chat {s}: {t}", .{ chat_id, err });
        connector.sendMessage(a, chat_id, "Sorry, I couldn't reach the model just now.");
        return;
    };
    connector.sendMessage(a, chat_id, answer);
}

fn replyWithWordcloud(
    connector: iface.Connector,
    a: std.mem.Allocator,
    chat_store: *ChatStore,
    tmp_dir: []const u8,
    io: Io,
    chat_id: []const u8,
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
        connector.sendMessage(a, chat_id, "Not enough logged messages yet to build a word cloud.");
        return;
    }
    const png = wordcloud.render(a, io, tmp_dir, words) catch |err| {
        std.log.err("wordcloud: render failed for chat {s}: {t}", .{ chat_id, err });
        connector.sendMessage(a, chat_id, "Couldn't render the word cloud (is Node installed?).");
        return;
    };
    connector.sendPhoto(a, chat_id, png, "Word cloud of recent messages");
}

fn replyWithStats(connector: iface.Connector, a: std.mem.Allocator, chat_store: *ChatStore, chat_id: []const u8) void {
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

    connector.sendMessage(a, chat_id, buf.writer.buffered());
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
    _ = @import("store/settings.zig");
    _ = @import("features/scheduler.zig");
    _ = @import("features/digest.zig");
}

fn isWordBoundary(c: u8) bool {
    return !std.ascii.isAlphanumeric(c);
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;

    var start: usize = 0;

    while (std.mem.indexOf(u8, haystack[start..], needle)) |idx| {
        const abs_idx = start + idx;
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

fn containsAnyWord(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsWord(haystack, needle)) {
            return true;
        }
    }
    return false;
}

fn replyTarget(msg: iface.Message) ?struct { user_id: []const u8, label: []const u8 } {
    const user_id = msg.reply_to_user_id orelse return null;
    const label = msg.reply_to_username orelse user_id;
    return .{ .user_id = user_id, .label = label };
}

fn reply(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, comptime txt: []const u8) void {
    connector.sendMessage(a, chat_id, txt);
}
