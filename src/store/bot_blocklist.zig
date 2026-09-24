const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Coarse gate on whether the bot responds to a message at all — the bot
/// answers everyone by default, and this is the list of who it doesn't.
pub fn isUserBlocked(pool: *PgPool, identity_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM bot_blocked_users WHERE identity_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    return stmt.step() catch false;
}

pub fn blockUser(pool: *PgPool, identity_id: i64, blocked_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO bot_blocked_users (identity_id, blocked_by) VALUES ($1, $2)
        \\ON CONFLICT (identity_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindInt64(2, blocked_by);
    _ = try stmt.step();
}

/// No-op if `identity_id` wasn't blocked.
pub fn unblockUser(pool: *PgPool, identity_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM bot_blocked_users WHERE identity_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    _ = try stmt.step();
}

pub fn isChatBlocked(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM bot_blocked_chats WHERE chat_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    return stmt.step() catch false;
}

pub fn blockChat(pool: *PgPool, chat_id: i64, blocked_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO bot_blocked_chats (chat_id, blocked_by) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, blocked_by);
    _ = try stmt.step();
}

/// No-op if `chat_id` wasn't blocked.
pub fn unblockChat(pool: *PgPool, chat_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM bot_blocked_chats WHERE chat_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");
const chats = @import("chats.zig");

test "isUserBlocked is false by default, true after blockUser, false again after unblockUser" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);

    try testing.expect(!isUserBlocked(&pool, alice));
    try blockUser(&pool, alice, owner);
    try testing.expect(isUserBlocked(&pool, alice));
    try unblockUser(&pool, alice);
    try testing.expect(!isUserBlocked(&pool, alice));
}

test "isChatBlocked is false by default, true after blockChat, false again after unblockChat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram, "100", null, null);

    try testing.expect(!isChatBlocked(&pool, chat_id));
    try blockChat(&pool, chat_id, owner);
    try testing.expect(isChatBlocked(&pool, chat_id));
    try unblockChat(&pool, chat_id);
    try testing.expect(!isChatBlocked(&pool, chat_id));
}

test "block is idempotent for both users and chats; unblocking something never blocked is a no-op" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram, "100", null, null);

    try unblockUser(&pool, alice);
    try unblockChat(&pool, chat_id);

    try blockUser(&pool, alice, owner);
    try blockUser(&pool, alice, owner);
    try testing.expect(isUserBlocked(&pool, alice));

    try blockChat(&pool, chat_id, owner);
    try blockChat(&pool, chat_id, owner);
    try testing.expect(isChatBlocked(&pool, chat_id));
}
