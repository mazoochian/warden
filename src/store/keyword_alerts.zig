const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One tracked word for a chat (ROADMAP.md's Phase 16) -- whenever any
/// chat member's message contains it (whole-word, case-insensitive, same
/// matching `main.zig`'s magic-word check already uses via
/// `containsWordIgnoreCase`), the bot flags it right in the chat. Chat-
/// scoped and visible to the whole chat, same "shared, but only the
/// creator or the bot owner may delete" model `notes.zig`/`reminders.zig`
/// already use.
pub const KeywordAlert = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    keyword: []const u8,
    created_at: i64,
};

pub const AddResult = union(enum) {
    added: i64,
    /// A keyword already tracked in this chat (case-insensitively) --
    /// `keyword` is normalized to lowercase before the uniqueness check, so
    /// "Urgent" and "urgent" collide rather than creating two functionally
    /// identical rows.
    already_tracked,
};

/// Adds `keyword` (lowercased before storage -- see `AddResult`'s doc
/// comment) to `chat_id`'s tracked list.
pub fn add(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, identity_id: i64, keyword: []const u8, created_at: i64) !AddResult {
    const lower = try std.ascii.allocLowerString(allocator, keyword);
    defer allocator.free(lower);

    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO keyword_alerts (chat_id, identity_id, keyword, created_at)
        \\VALUES ($1, $2, $3, to_timestamp($4))
        \\ON CONFLICT (chat_id, keyword) DO NOTHING
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, lower);
    stmt.bindInt64(4, created_at);
    if (!try stmt.step()) return .already_tracked;
    return .{ .added = stmt.columnInt64(0) };
}

/// Every tracked keyword in one chat, oldest first -- backs `/keyword
/// list` and the per-message scan hook in `main.zig`.
pub fn listForChat(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]KeywordAlert {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, identity_id, keyword, EXTRACT(EPOCH FROM created_at)::bigint
        \\FROM keyword_alerts WHERE chat_id = $1
        \\ORDER BY created_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(KeywordAlert) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = chat_id,
            .identity_id = stmt.columnInt64(1),
            .keyword = try allocator.dupe(u8, stmt.columnText(2)),
            .created_at = stmt.columnInt64(3),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` if no such alert exists -- used by `/keyword remove` to check
/// chat/creator before deleting, same pattern as `notes.get`.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?KeywordAlert {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT chat_id, identity_id, keyword, EXTRACT(EPOCH FROM created_at)::bigint FROM keyword_alerts WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .chat_id = stmt.columnInt64(0),
        .identity_id = stmt.columnInt64(1),
        .keyword = try allocator.dupe(u8, stmt.columnText(2)),
        .created_at = stmt.columnInt64(3),
    };
}

pub fn remove(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM keyword_alerts WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "add/listForChat/get/remove round trip, scoped per chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try add(&pool, a, chat1, alice, "URGENT", 1000);
    try testing.expect(result == .added);
    const id = result.added;
    _ = try add(&pool, a, chat2, alice, "urgent", 1000);

    const listed1 = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 1), listed1.len);
    try testing.expectEqualStrings("urgent", listed1[0].keyword); // stored lowercase

    const listed2 = try listForChat(&pool, a, chat2);
    try testing.expectEqual(@as(usize, 1), listed2.len); // scoped per chat

    const fetched = (try get(&pool, a, id)).?;
    try testing.expectEqual(chat1, fetched.chat_id);
    try testing.expectEqualStrings("urgent", fetched.keyword);

    try remove(&pool, id);
    try testing.expectEqual(@as(?KeywordAlert, null), try get(&pool, a, id));
}

test "add is idempotent per chat regardless of case" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try add(&pool, a, chat1, alice, "urgent", 1000);
    try testing.expect(first == .added);

    const second = try add(&pool, a, chat1, alice, "Urgent", 1001);
    try testing.expect(second == .already_tracked);

    const listed = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 1), listed.len);
}
