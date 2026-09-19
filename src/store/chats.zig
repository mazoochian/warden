const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

/// Upserts a chat row (keyed by platform + native chat id) and returns its
/// internal `chats.id`.
pub fn upsertChat(pool: *PgPool, platform: Platform, native_chat_id: []const u8, chat_type: ?[]const u8, title: ?[]const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chats (platform, native_chat_id, chat_type, title)
        \\VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (platform, native_chat_id) DO UPDATE SET
        \\  chat_type = COALESCE(excluded.chat_type, chats.chat_type),
        \\  title = COALESCE(excluded.title, chats.title),
        \\  left_at = NULL
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
    /// Which connector this chat belongs to.
    platform: Platform,
};

/// Single-chat lookup by internal id — `null` if it doesn't exist.
pub fn getById(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) !?ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, native_chat_id, platform FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
    };
}

/// Single-chat lookup by the *platform-native* id.
pub fn getByNative(pool: *PgPool, allocator: std.mem.Allocator, platform: Platform, native_chat_id: []const u8) !?ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, native_chat_id, platform FROM chats WHERE platform = $1 AND native_chat_id = $2;");
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, native_chat_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
    };
}

/// What `/chatinfo` reports.
pub const ChatInfo = struct {
    id: i64,
    native_chat_id: []const u8,
    platform: Platform,
    chat_type: ?[]const u8,
    title: ?[]const u8,
    /// Set when the bot has left/been removed and no message has arrived since
    /// (see `markLeft`/`upsertChat`).
    left: bool,
};

/// Backs `/chatinfo`. Returns `null` for an unknown id rather than
/// erroring — "no such chat" is an ordinary answer here, not a failure.
pub fn getInfoById(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) !?ChatInfo {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, native_chat_id, platform, chat_type, title, left_at IS NOT NULL FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
        .chat_type = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
        .title = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
        .left = stmt.columnBool(5),
    };
}

/// Marks a chat as no longer active — the bot left, was kicked, or the chat
/// was deleted.
pub fn markLeft(pool: *PgPool, chat_id: i64, at: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE chats SET left_at = to_timestamp($2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, at);
    _ = try stmt.step();
}

/// In-place id rename for Telegram's basic-group -> supergroup upgrade (see
/// `platform/telegram/connector.zig`'s handling of `migrate_to_chat_id`).
pub fn renameNativeChatId(pool: *PgPool, chat_id: i64, new_native_id: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE chats SET native_chat_id = $2, left_at = NULL WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, new_native_id);
    _ = try stmt.step();
}

/// Hard-deletes every chat that's been left for longer than the retention
/// window.
pub fn deleteLeftBefore(pool: *PgPool, cutoff: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM chats WHERE left_at IS NOT NULL AND left_at < to_timestamp($1) RETURNING id;");
    defer stmt.finalize();
    stmt.bindInt64(1, cutoff);

    var count: i64 = 0;
    while (try stmt.step()) count += 1;
    return count;
}

/// Hard-deletes a single chat by internal id, immediately (no `left_at` grace
/// period) — same FK cascade as `deleteLeftBefore`.
pub fn deleteById(pool: *PgPool, chat_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    _ = try stmt.step();
}

/// Lists every known, currently-active (not left) chat.
pub fn listAll(pool: *PgPool, allocator: std.mem.Allocator) ![]ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, native_chat_id, platform FROM chats WHERE left_at IS NULL;");
    defer stmt.finalize();

    var out: std.ArrayList(ChatRef) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
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

test "getByNative resolves a native id to the internal row without creating one" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id = try upsertChat(&pool, .telegram, "-100555", "supergroup", "Ops");

    const found = (try getByNative(&pool, testing.allocator, .telegram, "-100555")).?;
    defer testing.allocator.free(found.native_chat_id);
    try testing.expectEqual(id, found.id);
    try testing.expectEqual(Platform.telegram, found.platform);

    // The whole point of not reusing `upsertChat` for this: a miss must
    // stay a miss, not quietly insert the chat it was asked about.
    try testing.expect(try getByNative(&pool, testing.allocator, .telegram, "-100999") == null);
    var count = try db.prepare("SELECT count(*) FROM chats;");
    defer count.finalize();
    try testing.expect(try count.step());
    try testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "getByNative keys on platform too, so identical native ids on different platforms don't collide" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const tg = try upsertChat(&pool, .telegram, "shared-id", null, null);
    const mx = try upsertChat(&pool, .matrix, "shared-id", null, null);
    try testing.expect(tg != mx);

    const found_tg = (try getByNative(&pool, testing.allocator, .telegram, "shared-id")).?;
    defer testing.allocator.free(found_tg.native_chat_id);
    const found_mx = (try getByNative(&pool, testing.allocator, .matrix, "shared-id")).?;
    defer testing.allocator.free(found_mx.native_chat_id);
    try testing.expectEqual(tg, found_tg.id);
    try testing.expectEqual(mx, found_mx.id);
}

test "getInfoById reports type, title and left state, and null for an unknown id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id = try upsertChat(&pool, .telegram, "-100777", "supergroup", "Weekend Plans");

    {
        const info = (try getInfoById(&pool, testing.allocator, id)).?;
        defer testing.allocator.free(info.native_chat_id);
        defer if (info.chat_type) |t| testing.allocator.free(t);
        defer if (info.title) |t| testing.allocator.free(t);
        try testing.expectEqual(id, info.id);
        try testing.expectEqualStrings("-100777", info.native_chat_id);
        try testing.expectEqualStrings("supergroup", info.chat_type.?);
        try testing.expectEqualStrings("Weekend Plans", info.title.?);
        try testing.expect(!info.left);
    }

    try markLeft(&pool, id, 1000);
    {
        const info = (try getInfoById(&pool, testing.allocator, id)).?;
        defer testing.allocator.free(info.native_chat_id);
        defer if (info.chat_type) |t| testing.allocator.free(t);
        defer if (info.title) |t| testing.allocator.free(t);
        try testing.expect(info.left);
    }

    try testing.expect(try getInfoById(&pool, testing.allocator, id + 12345) == null);
}

test "getInfoById tolerates a chat with no type or title recorded" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id = try upsertChat(&pool, .telegram, "42", null, null);
    const info = (try getInfoById(&pool, testing.allocator, id)).?;
    defer testing.allocator.free(info.native_chat_id);
    try testing.expect(info.chat_type == null);
    try testing.expect(info.title == null);
}

test "listAll returns every active chat, excluding ones marked left" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    _ = try upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try upsertChat(&pool, .telegram, "2", null, null);
    try markLeft(&pool, chat2, 1000);

    const refs = try listAll(&pool, testing.allocator);
    defer {
        for (refs) |r| testing.allocator.free(r.native_chat_id);
        testing.allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("1", refs[0].native_chat_id);
}

test "markLeft sets left_at, upsertChat clears it again on rejoin" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try upsertChat(&pool, .telegram, "1", null, null);
    try markLeft(&pool, chat_id, 1000);

    var stmt = try db.prepare("SELECT left_at IS NOT NULL FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    try testing.expect(try stmt.step());
    try testing.expect(stmt.columnBool(0));

    _ = try upsertChat(&pool, .telegram, "1", null, null);

    var stmt2 = try db.prepare("SELECT left_at IS NOT NULL FROM chats WHERE id = $1;");
    defer stmt2.finalize();
    stmt2.bindInt64(1, chat_id);
    try testing.expect(try stmt2.step());
    try testing.expect(!stmt2.columnBool(0));
}

test "renameNativeChatId preserves the internal id (and its FK'd data) under a new native id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat_id = try upsertChat(&pool, .telegram, "-100111", "group", "Old Basic Group");
    try renameNativeChatId(&pool, chat_id, "-100999");

    const found = (try getById(&pool, a, chat_id)) orelse return error.TestExpectedValue;
    defer a.free(found.native_chat_id);
    try testing.expectEqualStrings("-100999", found.native_chat_id);

    // No new row was created for the new id -- same internal id resolves.
    const refs = try listAll(&pool, a);
    defer {
        for (refs) |r| a.free(r.native_chat_id);
        a.free(refs);
    }
    try testing.expectEqual(@as(usize, 1), refs.len);
}

test "deleteLeftBefore purges only chats left before the cutoff" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const still_active = try upsertChat(&pool, .telegram, "1", null, null);
    const left_long_ago = try upsertChat(&pool, .telegram, "2", null, null);
    const left_recently = try upsertChat(&pool, .telegram, "3", null, null);
    try markLeft(&pool, left_long_ago, 1000);
    try markLeft(&pool, left_recently, 5000);

    const deleted = try deleteLeftBefore(&pool, 3000);
    try testing.expectEqual(@as(i64, 1), deleted);

    if (try getById(&pool, testing.allocator, still_active)) |r| {
        testing.allocator.free(r.native_chat_id);
    } else {
        return error.TestExpectedValue;
    }
    try testing.expectEqual(@as(?ChatRef, null), try getById(&pool, testing.allocator, left_long_ago));
    if (try getById(&pool, testing.allocator, left_recently)) |r| {
        testing.allocator.free(r.native_chat_id);
    } else {
        return error.TestExpectedValue;
    }
}

test "getById finds an existing chat and returns null for an unknown id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat_id = try upsertChat(&pool, .telegram, "-100", "supergroup", "Test");

    const found = (try getById(&pool, a, chat_id)) orelse return error.TestExpectedValue;
    defer a.free(found.native_chat_id);
    try testing.expectEqual(chat_id, found.id);
    try testing.expectEqualStrings("-100", found.native_chat_id);
    try testing.expectEqual(Platform.telegram, found.platform);

    try testing.expectEqual(@as(?ChatRef, null), try getById(&pool, a, chat_id + 999));
}

test "deleteById removes an active chat immediately, without needing left_at set" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat_id = try upsertChat(&pool, .telegram, "-100", "supergroup", "Test");
    try deleteById(&pool, chat_id);
    try testing.expectEqual(@as(?ChatRef, null), try getById(&pool, a, chat_id));
}
