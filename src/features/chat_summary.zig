const std = @import("std");
const Io = std.Io;

const telegram_user_platform = @import("../platform/telegram_user.zig");
const TelegramUserConnector = telegram_user_platform.TelegramUserConnector;
const llm = @import("../llm/provider.zig");
const registry = @import("../tools/registry.zig");
const digest = @import("digest.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const chats_store = @import("../store/chats.zig");
const messages = @import("../store/messages.zig");

const log = @import("../log.zig").scoped("chat_summary");

/// Defensive ceiling on how many of a chat's unread messages `fetchUnread`
/// pulls from the DB in one call — not TDLib's `getChatHistory` limit (this
/// connector's messages are already persisted into `messages` by the same
/// generic `recordMessage` path every other connector uses, so there's no
/// TDLib round trip on this side any more), just a "don't let a wildly
/// stale unread count pull an unbounded amount of history into one prompt"
/// bound, same reasoning as `catch_me_up.zig`'s `max_hours`.
const max_unread_fetch: i64 = 2000;

/// Prompt-size bound for `fetchRecent`'s "last N messages regardless of
/// read state" mode — a deliberate choice now, not a TDLib artifact (see
/// `max_unread_fetch`'s doc comment). Matches `digest.zig`'s own
/// `window_message_limit` sizing.
const recent_window_limit: i64 = 500;

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

/// Every known chat, alphabetized by title (case-insensitive) — the
/// `/tdchats` pager's data source. Sorted rather than left in
/// `knownChats()`'s hashmap-iteration order so paging forward/backward
/// shows a stable, predictable sequence instead of one that could reorder
/// itself between two page requests.
pub fn allChatsSortedByTitle(telegram_user: *TelegramUserConnector, allocator: std.mem.Allocator) ![]ChatMatch {
    const chats = try telegram_user.knownChats(allocator);
    const matches = try allocator.alloc(ChatMatch, chats.len);
    for (chats, 0..) |c, i| matches[i] = .{ .native_chat_id = c.chat_id, .title = c.title };
    std.mem.sort(ChatMatch, matches, {}, titleLessThanIgnoreCase);
    return matches;
}

fn titleLessThanIgnoreCase(_: void, a: ChatMatch, b: ChatMatch) bool {
    return std.ascii.orderIgnoreCase(a.title, b.title) == .lt;
}

/// Every chat whose title contains `query` (case-insensitive), alphabetized
/// — `/tdsearch`'s data source. Unlike `resolveChat`, this never treats a
/// numeric query as an id lookup and never collapses to a single "the"
/// match: it's a browsing tool, not a targeting one, so it always returns
/// the full match set (even zero or one result) for the caller to list.
pub fn searchChatsByTitle(telegram_user: *TelegramUserConnector, allocator: std.mem.Allocator, query: []const u8) ![]ChatMatch {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    const all = try allChatsSortedByTitle(telegram_user, allocator);
    if (trimmed.len == 0) return all;

    var out: std.ArrayList(ChatMatch) = .empty;
    for (all) |c| {
        if (containsIgnoreCase(c.title, trimmed)) try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
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
    /// `true` means the DB's retention window holds fewer rows than TDLib
    /// reports as unread — some of the unread backlog was pruned locally
    /// before it could be shown (`marked_read`, if it succeeded, still
    /// covers all of it regardless — see `TelegramUserConnector.
    /// markMessagesRead`'s single-cursor doc comment).
    capped: bool,
    /// Oldest-first rows covering the unread window, sourced from the local
    /// `messages` table (this connector's own messages are recorded there
    /// by the same generic `recordMessage` path every other connector
    /// uses) rather than a live TDLib fetch — empty when there's nothing
    /// summarizable (no unread messages, or the unread backlog is entirely
    /// non-text content this connector doesn't convert — see Phase A scope
    /// in `platform/telegram_user.zig`). Callers format these themselves:
    /// `summarizeChat` wants plain prose input, `describeUnreadForModel`
    /// wants ids attached so a model can cite one back via
    /// `reply_to_message`.
    rows: []const messages.HistoryRow,
    marked_read: bool,
};

/// Fetches `native_chat_id`'s currently-unread messages from the local DB
/// (grounded in TDLib's own live unread *count* — never a locally cached
/// counter, see `ChatMeta`'s doc comment — but the message *text* itself
/// comes from `messages`, not a live `getChatHistory` call), and marks the
/// whole unread run read via `viewMessages` on just the chat's newest
/// message id as a side effect (TDLib's read state is a single forward
/// cursor per chat, so one id covers the entire backlog — see
/// `markMessagesRead`'s doc comment). `unread_count == 0` short-circuits to
/// an empty, already-`marked_read` result with no DB/view calls made.
/// `null` means TDLib couldn't be reached in time (already logged by the
/// underlying request) or `native_chat_id` isn't a valid chat id.
pub fn fetchUnread(telegram_user: *TelegramUserConnector, pool: *PgPool, allocator: std.mem.Allocator, io: Io, native_chat_id: []const u8) !?UnreadSummary {
    const chat_id_int = std.fmt.parseInt(i64, native_chat_id, 10) catch return null;

    const meta = try telegram_user.requestChatMeta(allocator, io, chat_id_int) orelse return null;
    if (meta.unread_count == 0) {
        return UnreadSummary{
            .native_chat_id = native_chat_id,
            .chat_title = meta.title,
            .unread_count = 0,
            .fetched_count = 0,
            .capped = false,
            .rows = &.{},
            .marked_read = true,
        };
    }

    const internal_chat = try chats_store.getByNative(pool, allocator, .telegram_user, native_chat_id);
    const rows: []const messages.HistoryRow = if (internal_chat) |c|
        try messages.recentRows(pool, allocator, c.id, @min(meta.unread_count, max_unread_fetch))
    else
        &.{};
    const capped = @as(i64, @intCast(rows.len)) < meta.unread_count;

    const marked_read = if (meta.last_message_id) |last_id|
        telegram_user.markMessagesRead(allocator, io, chat_id_int, &.{last_id}) catch |err| blk: {
            log.err("fetchUnread: markMessagesRead failed for chat {s}: {t}", .{ native_chat_id, err });
            break :blk false;
        }
    else
        false;

    return UnreadSummary{
        .native_chat_id = native_chat_id,
        .chat_title = meta.title,
        .unread_count = meta.unread_count,
        .fetched_count = rows.len,
        .capped = capped,
        .rows = rows,
        .marked_read = marked_read,
    };
}

pub const RecentSummary = struct {
    native_chat_id: []const u8,
    chat_title: []const u8,
    fetched_count: usize,
    /// Oldest-first rows, empty when the chat has nothing summarizable yet
    /// — see `UnreadSummary.rows`'s doc comment for the same DB-backed
    /// reasoning and the "callers format these themselves" split.
    rows: []const messages.HistoryRow,
};

/// Fetches the most recent `recent_window_limit` messages in a chat, any
/// read state, from the local DB — the `--all` mode's counterpart to
/// `fetchUnread`, direct owner request (2026-08-19) for "summarize the
/// last N messages" rather than only ever unread ones. Read-only: never
/// calls `markMessagesRead`, since there's no "unread" concept driving this
/// fetch to begin with — same "no side effects" contract
/// `features/digest.zig`'s own `summarizeWindow` already keeps for
/// `/summary [hours]`. `null` means TDLib couldn't be reached in time (only
/// `requestChatMeta`, for the title, still touches TDLib here).
pub fn fetchRecent(telegram_user: *TelegramUserConnector, pool: *PgPool, allocator: std.mem.Allocator, io: Io, native_chat_id: []const u8) !?RecentSummary {
    const chat_id_int = std.fmt.parseInt(i64, native_chat_id, 10) catch return null;
    const meta = try telegram_user.requestChatMeta(allocator, io, chat_id_int) orelse return null;

    const internal_chat = try chats_store.getByNative(pool, allocator, .telegram_user, native_chat_id);
    const rows: []const messages.HistoryRow = if (internal_chat) |c|
        try messages.recentRows(pool, allocator, c.id, recent_window_limit)
    else
        &.{};

    return RecentSummary{
        .native_chat_id = native_chat_id,
        .chat_title = meta.title,
        .fetched_count = rows.len,
        .rows = rows,
    };
}

fn formatRowsPlain(allocator: std.mem.Allocator, rows: []const messages.HistoryRow) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (rows) |r| {
        try lines.append(allocator, if (r.is_summary)
            try std.fmt.allocPrint(allocator, "summary: {s}", .{r.text})
        else
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ r.who, r.text }));
    }
    return std.mem.join(allocator, "\n", lines.items);
}

/// Same as `formatRowsPlain`, with each line prefixed by its
/// `native_message_id` in brackets — for tool-facing output only
/// (`describeUnreadForModel`), so a model reading this as a live tool
/// result can cite a message back via the `reply_to_message` tool. Never
/// fed into `digest.summarizeHistory`'s prompt (`formatRowsPlain` is, for
/// `summarizeChat`/`summarizeChatAll`) — the human-facing `/tdsummary`
/// prose has no use for raw ids.
fn formatRowsWithIds(allocator: std.mem.Allocator, rows: []const messages.HistoryRow) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (rows) |r| {
        const id_part = r.native_message_id orelse "?";
        try lines.append(allocator, if (r.is_summary)
            try std.fmt.allocPrint(allocator, "[{s}] summary: {s}", .{ id_part, r.text })
        else
            try std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{ id_part, r.who, r.text }));
    }
    return std.mem.join(allocator, "\n", lines.items);
}

/// `/tdsummary <chat>` end to end: resolve, fetch+mark-read, then the same
/// `digest.summarizeHistory` LLM round trip `/digest`/`/summary` already
/// use, wrapped with the two things a chat-window summary doesn't need to
/// say but this one does — how many were unread, and (see
/// `UnreadSummary.capped`'s doc comment) whether marking read reached
/// further than what got summarized. `null` chat_id means TDLib couldn't be
/// reached; the caller
/// tells the owner to try again rather than treating it as "no chat found"
/// (that's `resolveChat`'s job, already run before this is called).
/// `all = true` switches to `fetchRecent`/`summarizeChatAll` instead —
/// the last `recent_window_limit` messages regardless of read state, no
/// mark-as-read side effect.
pub fn summarizeChat(
    telegram_user: *TelegramUserConnector,
    pool: *PgPool,
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    io: Io,
    ctx: registry.ToolContext,
    native_chat_id: []const u8,
    all: bool,
) ![]const u8 {
    if (all) return summarizeChatAll(telegram_user, pool, provider, allocator, io, ctx, native_chat_id);

    const unread = try fetchUnread(telegram_user, pool, allocator, io, native_chat_id) orelse
        return "Couldn't reach the personal account's Telegram session in time — try again in a moment.";

    if (unread.unread_count == 0) {
        return std.fmt.allocPrint(allocator, "No unread messages in \"{s}\".", .{unread.chat_title});
    }
    if (unread.rows.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "\"{s}\" has {d} unread message(s), but none of them are plain text yet (photos/stickers/etc. aren't summarized) — left unread.",
            .{ unread.chat_title, unread.unread_count },
        );
    }

    const formatted = try formatRowsPlain(allocator, unread.rows);
    const summary = digest.summarizeHistory(provider, allocator, ctx, formatted);
    if (summary.len == 0) return error.SummaryFailed;

    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.print("\"{s}\" — {d} unread message(s):\n\n{s}", .{ unread.chat_title, unread.unread_count, summary });
    if (unread.capped) {
        try out.writer.print(
            "\n\n⚠️ Only {d} of the {d} unread message(s) are still in Warden's local history and got summarized — the rest were already pruned, but marking this chat read still covered all of them on Telegram.",
            .{ unread.fetched_count, unread.unread_count },
        );
    }
    if (!unread.marked_read) {
        try out.writer.writeAll("\n\n⚠️ Couldn't confirm these were marked read — they may still show unread in Telegram.");
    }
    return out.writer.buffered();
}

/// `summarizeChat(all = true)`'s actual implementation — split out rather
/// than one function branching on `all` at every step, since the two modes
/// share only `digest.summarizeHistory`'s call shape, not any of the
/// unread-specific bookkeeping (`capped`/`marked_read`) `summarizeChat`
/// itself has to report.
fn summarizeChatAll(
    telegram_user: *TelegramUserConnector,
    pool: *PgPool,
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    io: Io,
    ctx: registry.ToolContext,
    native_chat_id: []const u8,
) ![]const u8 {
    const recent = try fetchRecent(telegram_user, pool, allocator, io, native_chat_id) orelse
        return "Couldn't reach the personal account's Telegram session in time — try again in a moment.";
    if (recent.rows.len == 0) {
        return std.fmt.allocPrint(allocator, "\"{s}\" has no plain-text messages yet to summarize.", .{recent.chat_title});
    }

    const formatted = try formatRowsPlain(allocator, recent.rows);
    const summary = digest.summarizeHistory(provider, allocator, ctx, formatted);
    if (summary.len == 0) return error.SummaryFailed;

    return std.fmt.allocPrint(allocator, "\"{s}\" — last {d} message(s):\n\n{s}", .{ recent.chat_title, recent.fetched_count, summary });
}

/// Plain-text "id — title" lines, one per chat, capped at `limit` with a
/// "...and N more" tail — the LLM-tool-facing counterpart to `main.zig`'s
/// `renderTdChatsPage` (which builds Telegram-specific button UI instead
/// of plain text a model can read). Backs `list_personal_chats`.
pub fn formatChatList(allocator: std.mem.Allocator, chat_list: []const ChatMatch, limit: usize) ![]const u8 {
    if (chat_list.len == 0) return "No chats found.";

    var out: Io.Writer.Allocating = .init(allocator);
    const shown = @min(chat_list.len, limit);
    for (chat_list[0..shown]) |c| {
        try out.writer.print("{s} — {s}\n", .{ c.native_chat_id, c.title });
    }
    if (chat_list.len > shown) {
        try out.writer.print("...and {d} more (narrow your query to see them).", .{chat_list.len - shown});
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
pub fn describeUnreadForModel(telegram_user: *TelegramUserConnector, pool: *PgPool, allocator: std.mem.Allocator, io: Io, query: []const u8, all: bool) ![]const u8 {
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
            if (all) {
                const recent = try fetchRecent(telegram_user, pool, allocator, io, m.native_chat_id) orelse
                    return "Couldn't reach the personal account's Telegram session in time — try again in a moment.";
                if (recent.rows.len == 0) {
                    return std.fmt.allocPrint(allocator, "\"{s}\" has no plain-text messages yet to show.", .{recent.chat_title});
                }
                const formatted = try formatRowsWithIds(allocator, recent.rows);
                return std.fmt.allocPrint(allocator, "\"{s}\" — last {d} message(s):\n{s}", .{ recent.chat_title, recent.fetched_count, formatted });
            }

            const unread = try fetchUnread(telegram_user, pool, allocator, io, m.native_chat_id) orelse
                return "Couldn't reach the personal account's Telegram session in time — try again in a moment.";
            if (unread.unread_count == 0) {
                return std.fmt.allocPrint(allocator, "No unread messages in \"{s}\".", .{unread.chat_title});
            }
            if (unread.rows.len == 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "\"{s}\" has {d} unread message(s), but none are plain text yet (photos/stickers/etc. aren't read) — left unread.",
                    .{ unread.chat_title, unread.unread_count },
                );
            }
            const formatted = try formatRowsWithIds(allocator, unread.rows);
            var out: Io.Writer.Allocating = .init(allocator);
            try out.writer.print("\"{s}\" — {d} unread message(s), now marked read:\n{s}", .{ unread.chat_title, unread.unread_count, formatted });
            if (unread.capped) {
                try out.writer.print(
                    "\n(Only {d} of the {d} unread message(s) above are still in local history -- the rest were already pruned, but marking read still covered all of them on Telegram.)",
                    .{ unread.fetched_count, unread.unread_count },
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
