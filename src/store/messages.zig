const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Inserts one message row, scoped to `chat_id`/`identity_id` (the internal
/// FK ids from `chats.upsertChat`/`identities.upsertIdentity`) — replaces
/// the old per-chat-file `messages` table's implicit-by-filename scoping.
pub fn insert(pool: *PgPool, chat_id: i64, identity_id: i64, native_message_id: ?[]const u8, text: ?[]const u8, ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO messages (chat_id, identity_id, native_message_id, text, ts)
        \\VALUES ($1, $2, $3, $4, to_timestamp($5));
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    if (native_message_id) |m| stmt.bindText(3, m) else stmt.bindNull(3);
    if (text) |t| stmt.bindText(4, t) else stmt.bindNull(4);
    stmt.bindInt64(5, ts);
    _ = try stmt.step();
}

/// Deletes everything older than the most recent `keep` messages, scoped to
/// `chat_id`. No-ops if fewer than `keep` rows exist for that chat.
pub fn pruneKeepLast(pool: *PgPool, chat_id: i64, keep: i64) !void {
    std.debug.assert(keep > 0);
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\DELETE FROM messages WHERE chat_id = $1 AND id < (
        \\  SELECT id FROM messages WHERE chat_id = $1 ORDER BY id DESC LIMIT 1 OFFSET $2
        \\);
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, keep - 1);
    _ = try stmt.step();
}

/// Renders the most recent `limit` messages in `chat_id` (oldest first) as
/// "who: text" lines, for grounding free-form LLM questions/digests in this
/// chat's actual local history. Prefers the sender's platform username
/// (matches the old behavior) falling back to their display name, then
/// "unknown" — same fallback chain the old SQLite version used, just
/// resolved through `identities` instead of a denormalized `username`
/// column on `messages` itself.
pub fn recentFormatted(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, limit: i64) ![]const u8 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL
        \\ORDER BY m.id DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, limit);

    var lines: std.ArrayList([]const u8) = .empty;
    while (try stmt.step()) {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ stmt.columnText(0), stmt.columnText(1) }));
    }
    std.mem.reverse([]const u8, lines.items); // rows came back newest-first
    return std.mem.join(allocator, "\n", lines.items);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "insert/recentFormatted/pruneKeepLast scoped correctly per chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .username = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    const carol = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "3",
        .display_name = "Carol",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    try insert(&pool, chat1, alice, "1", "hi", 1000);
    try insert(&pool, chat1, alice, "2", "again", 1001);
    try insert(&pool, chat2, carol, "3", "unrelated", 1002);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const history = try recentFormatted(&pool, a, chat1, 10);
    try testing.expectEqualStrings("alice: hi\nalice: again", history);

    // A separate chat must not see chat1's messages (per-chat isolation).
    const history2 = try recentFormatted(&pool, a, chat2, 10);
    try testing.expectEqualStrings("Carol: unrelated", history2);

    try pruneKeepLast(&pool, chat1, 1);
    const pruned = try recentFormatted(&pool, a, chat1, 10);
    try testing.expectEqualStrings("alice: again", pruned);
}
