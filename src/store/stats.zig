const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

pub const TopUser = struct {
    /// Platform-native id (`identities.native_id`), not the internal FK.
    user_id: []const u8,
    /// Empty if the user has no username set.
    username: []const u8,
    message_count: i64,
};

pub const Stats = struct {
    total_messages: i64,
    distinct_users: i64,
    top_users: []TopUser,
};

/// Pure aggregate queries scoped to one chat — no LLM involved, so this
/// can't hallucinate counts and costs nothing to call.
pub fn compute(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, top_n: usize) !Stats {
    const db = try pool.acquire();
    defer pool.release(db);

    const total = try scalarInt(db, "SELECT COUNT(*) FROM messages WHERE chat_id = $1;", chat_id);
    const distinct = try scalarInt(db, "SELECT COUNT(DISTINCT identity_id) FROM messages WHERE chat_id = $1;", chat_id);

    var stmt = try db.prepare(
        \\SELECT i.native_id, COALESCE(i.username, '') AS username, COUNT(*) AS message_count
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1
        \\GROUP BY i.native_id, i.username ORDER BY message_count DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, @intCast(top_n));

    var top_users: std.ArrayList(TopUser) = .empty;
    while (try stmt.step()) {
        try top_users.append(allocator, .{
            .user_id = try allocator.dupe(u8, stmt.columnText(0)),
            .username = try allocator.dupe(u8, stmt.columnText(1)),
            .message_count = stmt.columnInt64(2),
        });
    }

    return .{
        .total_messages = total,
        .distinct_users = distinct,
        .top_users = try top_users.toOwnedSlice(allocator),
    };
}

fn scalarInt(db: *Db, sql: [:0]const u8, chat_id: i64) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");
const messages = @import("messages.zig");

test "compute aggregates per chat, ranked by message count" {
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
    const bob = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "2",
        .display_name = "Bob",
        .username = "bob",
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

    try messages.insert(&pool, chat1, alice, null, "hi", 1000);
    try messages.insert(&pool, chat1, alice, null, "again", 1001);
    try messages.insert(&pool, chat1, bob, null, "hello", 1002);
    try messages.insert(&pool, chat2, carol, null, "unrelated", 1003);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s1 = try compute(&pool, a, chat1, 5);
    try testing.expectEqual(@as(i64, 3), s1.total_messages);
    try testing.expectEqual(@as(i64, 2), s1.distinct_users);
    try testing.expectEqual(@as(i64, 2), s1.top_users[0].message_count);
    try testing.expectEqualStrings("alice", s1.top_users[0].username);

    const s2 = try compute(&pool, a, chat2, 5);
    try testing.expectEqual(@as(i64, 1), s2.total_messages);
}
