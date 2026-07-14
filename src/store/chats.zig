const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

/// Upserts a chat row (keyed by platform + native chat id) and returns its
/// internal `chats.id` — the FK `messages`/`chat_members`/`chat_settings`
/// key on, replacing the old "one SQLite file per chat" partitioning.
///
/// `chat_type`/`title` are `null` whenever the caller doesn't have fresh
/// metadata handy (e.g. resolving a chat by id alone for a scheduled
/// digest) — `COALESCE` keeps whatever was already stored in that case
/// rather than clobbering it with NULL.
pub fn upsertChat(pool: *PgPool, platform: Platform, native_chat_id: []const u8, chat_type: ?[]const u8, title: ?[]const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chats (platform, native_chat_id, chat_type, title)
        \\VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (platform, native_chat_id) DO UPDATE SET
        \\  chat_type = COALESCE(excluded.chat_type, chats.chat_type),
        \\  title = COALESCE(excluded.title, chats.title)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, native_chat_id);
    if (chat_type) |t| stmt.bindText(3, t) else stmt.bindNull(3);
    if (title) |t| stmt.bindText(4, t) else stmt.bindNull(4);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

pub const ChatRef = struct {
    id: i64,
    native_chat_id: []const u8,
};

/// Lists every known chat — replaces `ChatStore.listExistingChatIds`'s
/// directory scan (used at startup to restore digest scheduling).
pub fn listAll(pool: *PgPool, allocator: std.mem.Allocator) ![]ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, native_chat_id FROM chats;");
    defer stmt.finalize();

    var out: std.ArrayList(ChatRef) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        });
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "upsertChat inserts then updates on conflict, preserving fields when null is passed" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id1 = try upsertChat(&pool, .telegram, "-100123", "supergroup", "My Group");
    const id2 = try upsertChat(&pool, .telegram, "-100123", null, null);
    try testing.expectEqual(id1, id2);

    var stmt = try db.prepare("SELECT chat_type, title FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id1);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("supergroup", stmt.columnText(0));
    try testing.expectEqualStrings("My Group", stmt.columnText(1));
}

test "listAll returns every chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    _ = try upsertChat(&pool, .telegram, "1", null, null);
    _ = try upsertChat(&pool, .telegram, "2", null, null);

    const refs = try listAll(&pool, testing.allocator);
    defer {
        for (refs) |r| testing.allocator.free(r.native_chat_id);
        testing.allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 2), refs.len);
}
