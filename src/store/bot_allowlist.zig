const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Coarse gate on whether the bot responds to a message at all — bundles
/// both the per-user and per-chat allowlists in one module since every call
/// site checks them together (see `main.zig`'s `handleMessage` top-of-
/// function gate: `isUserAllowed(...) or isChatAllowed(...)`). Owners and
/// bot admins bypass this entirely and never call into here; message
/// recording/stats (`recordMessage`/`recordObservedUsers`) run earlier in
/// `processMessageTask` and are unaffected by any of this — this only gates
/// whether `handleMessage` takes further action.
///
/// Both `isX` checks fail closed (return `false`) on any pool/query error,
/// matching `bot_admins.isBotAdmin`'s convention.
pub fn isUserAllowed(pool: *PgPool, identity_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM bot_allowed_users WHERE identity_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    return stmt.step() catch false;
}

pub fn addAllowedUser(pool: *PgPool, identity_id: i64, added_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO bot_allowed_users (identity_id, added_by) VALUES ($1, $2)
        \\ON CONFLICT (identity_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindInt64(2, added_by);
    _ = try stmt.step();
}

/// No-op if `identity_id` wasn't allowed.
pub fn removeAllowedUser(pool: *PgPool, identity_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM bot_allowed_users WHERE identity_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    _ = try stmt.step();
}

pub fn isChatAllowed(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM bot_allowed_chats WHERE chat_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    return stmt.step() catch false;
}

pub fn addAllowedChat(pool: *PgPool, chat_id: i64, added_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO bot_allowed_chats (chat_id, added_by) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, added_by);
    _ = try stmt.step();
}

/// No-op if `chat_id` wasn't allowed.
pub fn removeAllowedChat(pool: *PgPool, chat_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM bot_allowed_chats WHERE chat_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");
const chats = @import("chats.zig");

test "isUserAllowed is false by default, true after addAllowedUser, false again after removeAllowedUser" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);

    try testing.expect(!isUserAllowed(&pool, alice));
    try addAllowedUser(&pool, alice, owner);
    try testing.expect(isUserAllowed(&pool, alice));
    try removeAllowedUser(&pool, alice);
    try testing.expect(!isUserAllowed(&pool, alice));
}

test "isChatAllowed is false by default, true after addAllowedChat, false again after removeAllowedChat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram, "100", null, null);

    try testing.expect(!isChatAllowed(&pool, chat_id));
    try addAllowedChat(&pool, chat_id, owner);
    try testing.expect(isChatAllowed(&pool, chat_id));
    try removeAllowedChat(&pool, chat_id);
    try testing.expect(!isChatAllowed(&pool, chat_id));
}

test "add is idempotent for both users and chats" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram, "100", null, null);

    try addAllowedUser(&pool, alice, owner);
    try addAllowedUser(&pool, alice, owner);
    try testing.expect(isUserAllowed(&pool, alice));

    try addAllowedChat(&pool, chat_id, owner);
    try addAllowedChat(&pool, chat_id, owner);
    try testing.expect(isChatAllowed(&pool, chat_id));
}

test "remove on something never allowed is a no-op, not an error" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram, "100", null, null);

    try removeAllowedUser(&pool, alice);
    try removeAllowedChat(&pool, chat_id);
    try testing.expect(!isUserAllowed(&pool, alice));
    try testing.expect(!isChatAllowed(&pool, chat_id));
}
