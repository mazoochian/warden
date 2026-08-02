const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One note/list entry — chat-scoped and visible to the whole chat (same
/// "shared within the chat, only the creator or owner may delete" model
/// `reminders.zig`/`alerts.zig` already use), covering notes, shopping
/// lists, wishlists, packing lists, etc. as one flat freeform primitive
/// rather than several typed structures — see the `0024_notes.sql`
/// migration comment.
pub const Note = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    text: []const u8,
    created_at: i64,
};

pub fn create(pool: *PgPool, chat_id: i64, identity_id: i64, text: []const u8, created_at: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO notes (chat_id, identity_id, text, created_at)
        \\VALUES ($1, $2, $3, to_timestamp($4))
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, text);
    stmt.bindInt64(4, created_at);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Every note in one chat, oldest first (a shopping list reads naturally
/// in the order items were added).
pub fn listForChat(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]Note {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, identity_id, text, EXTRACT(EPOCH FROM created_at)::bigint
        \\FROM notes WHERE chat_id = $1
        \\ORDER BY created_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(Note) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = chat_id,
            .identity_id = stmt.columnInt64(1),
            .text = try allocator.dupe(u8, stmt.columnText(2)),
            .created_at = stmt.columnInt64(3),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` if no such note exists — used by `/note delete` to check
/// chat/creator before deleting, same pattern as `reminders.get`.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Note {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT chat_id, identity_id, text, EXTRACT(EPOCH FROM created_at)::bigint FROM notes WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .chat_id = stmt.columnInt64(0),
        .identity_id = stmt.columnInt64(1),
        .text = try allocator.dupe(u8, stmt.columnText(2)),
        .created_at = stmt.columnInt64(3),
    };
}

pub fn delete(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM notes WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "create/listForChat/get/delete" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .username = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id1 = try create(&pool, chat_id, identity_id, "milk", 1000);
    const id2 = try create(&pool, chat_id, identity_id, "eggs", 2000);

    const listed = try listForChat(&pool, a, chat_id);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("milk", listed[0].text);
    try testing.expectEqualStrings("eggs", listed[1].text);

    const note = (try get(&pool, a, id1)) orelse return error.TestExpectedValue;
    try testing.expectEqual(chat_id, note.chat_id);
    try testing.expectEqual(identity_id, note.identity_id);
    try testing.expectEqualStrings("milk", note.text);

    try delete(&pool, id1);
    try testing.expectEqual(@as(?Note, null), try get(&pool, a, id1));
    try testing.expectEqual(@as(usize, 1), (try listForChat(&pool, a, chat_id)).len);

    try delete(&pool, id2);
    try testing.expectEqual(@as(usize, 0), (try listForChat(&pool, a, chat_id)).len);
}

test "listForChat scopes by chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const identity_id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try create(&pool, chat1, identity_id, "chat1 note", 1000);
    _ = try create(&pool, chat2, identity_id, "chat2 note", 1000);

    try testing.expectEqual(@as(usize, 1), (try listForChat(&pool, a, chat1)).len);
    try testing.expectEqual(@as(usize, 1), (try listForChat(&pool, a, chat2)).len);
}
