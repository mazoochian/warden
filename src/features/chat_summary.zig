const std = @import("std");
const Io = std.Io;

const telegram_user_platform = @import("../platform/telegram_user.zig");
const TelegramUserConnector = telegram_user_platform.TelegramUserConnector;
const llm = @import("../llm/provider.zig");
const registry = @import("../tools/registry.zig");
const digest = @import("digest.zig");

const log = @import("../log.zig").scoped("chat_summary");

/// Hard ceiling on how many of a chat's unread messages get fetched and
/// summarized in one call. Pinned to TDLib's own hard cap on
/// `getChatHistory`'s `limit` (rejects anything over 100 as invalid — see
/// `requestChatHistory`'s doc comment) rather than an independently-chosen
/// number, so this can never silently ask for more than TDLib will serve.
/// Has a sharper consequence than a typical "bound the prompt" ceiling
/// (contrast `features/digest.zig`'s own `window_message_limit`): TDLib's
/// read state is a single forward cursor per chat (see
/// `TelegramUserConnector.markMessagesRead`'s doc comment), so marking
/// only the newest `max_fetch` of a larger unread backlog read also
/// silently advances past every older, never-shown message.
/// `UnreadSummary.capped` exists so callers surface that plainly instead
/// of letting it pass unnoticed.
const max_fetch: i64 = 100;

pub const ChatMatch = struct {
    native_chat_id: []const u8,
    title: []const u8,
};

pub const ChatResolution = union(enum) {
    none,
    one: ChatMatch,
    ambiguous: []const ChatMatch,
};

/// Resolves an owner-typed `query` — a raw TDLib chat id, or any
/// case-insensitive substring of a known chat's title — against
/// `telegram_user.knownChats()`, the same list `/tdchats` already prints
/// for the owner to copy an id from. Accepting a name too means "summarize
/// the Alice chat" works without memorizing a numeric id first. A query
/// that parses as an integer is matched as an id outright (even if it
/// would also substring-match some chat's title) rather than falling
/// through to a name search.
pub fn resolveChat(telegram_user: *TelegramUserConnector, allocator: std.mem.Allocator, query: []const u8) !ChatResolution {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return .none;

    const chats = try telegram_user.knownChats(allocator);

    if (std.fmt.parseInt(i64, trimmed, 10)) |_| {
        for (chats) |c| {
            if (std.mem.eql(u8, c.chat_id, trimmed)) return .{ .one = .{ .native_chat_id = c.chat_id, .title = c.title } };
        }
        return .none;
    } else |_| {}

    var matches: std.ArrayList(ChatMatch) = .empty;
    for (chats) |c| {
        if (containsIgnoreCase(c.title, trimmed)) {
            try matches.append(allocator, .{ .native_chat_id = c.chat_id, .title = c.title });
        }
    }
    return switch (matches.items.len) {
        0 => .none,
        1 => .{ .one = matches.items[0] },
        else => .{ .ambiguous = try matches.toOwnedSlice(allocator) },
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const UnreadSummary = struct {
    native_chat_id: []const u8,
    chat_title: []const u8,
    unread_count: i64,
    fetched_count: usize,
    /// See `max_fetch`'s doc comment — `true` means `marked_read` (if it
    /// succeeded) covered more messages than `formatted` actually shows.
    capped: bool,
    /// "sender id: text" lines, oldest-first; empty when there's nothing
    /// summarizable (no unread messages, or the unread backlog is entirely
    /// non-text content this connector doesn't convert — see Phase A scope
    /// in `platform/telegram_user.zig`).
    formatted: []const u8,
    marked_read: bool,
};

/// Fetches `native_chat_id`'s currently-unread messages fresh from TDLib
/// (never from a locally cached counter — see `ChatMeta`'s doc comment),
/// formats them for an LLM to turn into prose, and marks read exactly the
/// messages it fetched as a side effect. `unread_count == 0` short-circuits
/// to an empty, already-`marked_read` result with no history/view calls
/// made. `null` means TDLib couldn't be reached in time (already logged by
/// the underlying request) or `native_chat_id` isn't a valid chat id.
pub fn fetchUnread(telegram_user: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, native_chat_id: []const u8) !?UnreadSummary {
    const chat_id_int = std.fmt.parseInt(i64, native_chat_id, 10) catch return null;

    const meta = try telegram_user.requestChatMeta(allocator, io, chat_id_int) orelse return null;
    if (meta.unread_count == 0) {
        return UnreadSummary{
            .native_chat_id = native_chat_id,
            .chat_title = meta.title,
            .unread_count = 0,
            .fetched_count = 0,
            .capped = false,
            .formatted = "",
            .marked_read = true,
        };
    }

    const fetch_limit = @min(meta.unread_count, max_fetch);
    const capped = meta.unread_count > max_fetch;
    const history = try telegram_user.requestChatHistory(allocator, io, chat_id_int, fetch_limit) orelse return null;

    var ids: std.ArrayList(i64) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    for (history) |m| {
        try ids.append(allocator, m.message_id);
        const who = if (m.sender_user_id) |uid|
            try std.fmt.allocPrint(allocator, "{d}", .{uid})
        else
            try allocator.dupe(u8, "unknown");
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ who, m.text }));
    }
    std.mem.reverse([]const u8, lines.items); // TDLib returns newest-first

    const marked_read = telegram_user.markMessagesRead(allocator, io, chat_id_int, ids.items) catch |err| blk: {
        log.err("fetchUnread: markMessagesRead failed for chat {s}: {t}", .{ native_chat_id, err });
        break :blk false;
    };

    return UnreadSummary{
        .native_chat_id = native_chat_id,
        .chat_title = meta.title,
        .unread_count = meta.unread_count,
        .fetched_count = history.len,
        .capped = capped,
        .formatted = try std.mem.join(allocator, "\n", lines.items),
        .marked_read = marked_read,
    };
}

/// `/tdsummary <chat>` end to end: resolve, fetch+mark-read, then the same
/// `digest.summarizeHistory` LLM round trip `/digest`/`/summary` already
/// use, wrapped with the two things a chat-window summary doesn't need to
/// say but this one does — how many were unread, and (see `max_fetch`'s
/// doc comment) whether marking read reached further than what got
/// summarized. `null` chat_id means TDLib couldn't be reached; the caller
/// tells the owner to try again rather than treating it as "no chat found"
/// (that's `resolveChat`'s job, already run before this is called).
pub fn summarizeChat(
    telegram_user: *TelegramUserConnector,
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    io: Io,
    ctx: registry.ToolContext,
    native_chat_id: []const u8,
) ![]const u8 {
    const unread = try fetchUnread(telegram_user, allocator, io, native_chat_id) orelse
        return "Couldn't reach the personal account's Telegram session in time — try again in a moment.";

    if (unread.unread_count == 0) {
        return std.fmt.allocPrint(allocator, "No unread messages in \"{s}\".", .{unread.chat_title});
    }
    if (unread.formatted.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "\"{s}\" has {d} unread message(s), but none of them are plain text yet (photos/stickers/etc. aren't summarized) — left unread.",
            .{ unread.chat_title, unread.unread_count },
        );
    }

    const summary = digest.summarizeHistory(provider, allocator, ctx, unread.formatted);
    if (summary.len == 0) return error.SummaryFailed;

    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.print("\"{s}\" — {d} unread message(s):\n\n{s}", .{ unread.chat_title, unread.unread_count, summary });
    if (unread.capped) {
        try out.writer.print(
            "\n\n⚠️ Only the most recent {d} were summarized — Telegram's read state is a single cursor, so marking those read also marked the older {d} read without showing them to you.",
            .{ unread.fetched_count, unread.unread_count - @as(i64, @intCast(unread.fetched_count)) },
        );
    }
    if (!unread.marked_read) {
        try out.writer.writeAll("\n\n⚠️ Couldn't confirm these were marked read — they may still show unread in Telegram.");
    }
    return out.writer.buffered();
}

/// Natural-language-tool counterpart to `summarizeChat`: same resolve +
/// fetch+mark-read, but returns raw formatted lines (or a short status
/// line for the empty/ambiguous/no-such-chat cases) instead of running its
/// own LLM summarization pass. Used by `summarize_unread_chat`'s tool
/// adapter — the model making the tool call is itself already generating
/// a reply to the owner this turn, so a second, nested LLM round trip here
/// would be redundant — same "just fetch, let the model summarize" shape
/// `tools/catch_me_up.zig`'s own doc comment already establishes.
pub fn describeUnreadForModel(telegram_user: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, query: []const u8) ![]const u8 {
    const resolution = try resolveChat(telegram_user, allocator, query);
    switch (resolution) {
        .none => return "No known chat matches that — ask again naming the chat exactly, or check /tdchats.",
        .ambiguous => |matches| {
            var out: Io.Writer.Allocating = .init(allocator);
            try out.writer.writeAll("That matches more than one chat — ask again naming one specifically:\n");
            for (matches) |m| try out.writer.print("{s} (id {s})\n", .{ m.title, m.native_chat_id });
            return out.writer.buffered();
        },
        .one => |m| {
            const unread = try fetchUnread(telegram_user, allocator, io, m.native_chat_id) orelse
                return "Couldn't reach the personal account's Telegram session in time — try again in a moment.";
            if (unread.unread_count == 0) {
                return std.fmt.allocPrint(allocator, "No unread messages in \"{s}\".", .{unread.chat_title});
            }
            if (unread.formatted.len == 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "\"{s}\" has {d} unread message(s), but none are plain text yet (photos/stickers/etc. aren't read) — left unread.",
                    .{ unread.chat_title, unread.unread_count },
                );
            }
            var out: Io.Writer.Allocating = .init(allocator);
            try out.writer.print("\"{s}\" — {d} unread message(s), now marked read:\n{s}", .{ unread.chat_title, unread.unread_count, unread.formatted });
            if (unread.capped) {
                try out.writer.print(
                    "\n(Only the most recent {d} are shown above — Telegram's read state is a single cursor, so the older {d} were marked read too without being shown.)",
                    .{ unread.fetched_count, unread.unread_count - @as(i64, @intCast(unread.fetched_count)) },
                );
            }
            return out.writer.buffered();
        },
    }
}

const testing = std.testing;

fn makeConnector() TelegramUserConnector {
    return TelegramUserConnector.init(testing.allocator, testing.io, 1, "hash", "/tmp/warden-tdlib-test");
}

// Every test below runs its `resolveChat` call under an arena — matches
// `features/digest.zig`'s own test convention for the same reason:
// `resolveChat` returns `ChatMatch` values that alias strings owned by its
// internal `knownChats()` dupe (itself never explicitly freed, by design —
// production call sites are always one per-message arena end to end), so
// a strict leak-checking allocator would flag that intermediate as a leak
// even though it's the intended shape.

test "resolveChat: exact numeric id match wins even over a title substring collision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conn = makeConnector();
    try conn.known_chats.put(a, try a.dupe(u8, "42"), try a.dupe(u8, "42 the Group"));
    try conn.known_chats.put(a, try a.dupe(u8, "99"), try a.dupe(u8, "Alice"));

    const got = try resolveChat(&conn, a, "42");
    try testing.expect(got == .one);
    try testing.expectEqualStrings("42", got.one.native_chat_id);
}

test "resolveChat: case-insensitive title substring match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conn = makeConnector();
    try conn.known_chats.put(a, try a.dupe(u8, "7"), try a.dupe(u8, "Work Friends"));

    const got = try resolveChat(&conn, a, "work");
    try testing.expect(got == .one);
    try testing.expectEqualStrings("7", got.one.native_chat_id);
}

test "resolveChat: multiple title matches report ambiguous, no matches report none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conn = makeConnector();
    try conn.known_chats.put(a, try a.dupe(u8, "1"), try a.dupe(u8, "Alice Work"));
    try conn.known_chats.put(a, try a.dupe(u8, "2"), try a.dupe(u8, "Alice Home"));

    const ambiguous = try resolveChat(&conn, a, "alice");
    try testing.expect(ambiguous == .ambiguous);
    try testing.expectEqual(@as(usize, 2), ambiguous.ambiguous.len);

    const none = try resolveChat(&conn, a, "bob");
    try testing.expect(none == .none);
}

test "resolveChat: empty/whitespace query resolves to none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var conn = makeConnector();
    const got = try resolveChat(&conn, arena.allocator(), "   ");
    try testing.expect(got == .none);
}
