const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Bot-admin role: a DB-backed permission tier distinct from any platform's
/// own group-admin flag — see `auth.checkGroupAdminAccess`'s doc comment for
/// how it plugs into the permission ladder. Keyed purely on `identity_id`
/// (not platform+native_id): every call site already has an internal id in
/// hand by the time it needs to check this (the message sender's
/// `identity_id` is a `handleMessage` parameter already; command targets are
/// always resolved through `identities.getOrCreateMinimal`/`findByUsername`
/// first).
///
/// `isBotAdmin` fails closed (returns `false`) on any pool/query error,
/// matching `chat_members.getTokens`'s and `auth.isAuthorizedForGroupAdmin`'s
/// existing "an unreachable check means not authorized" convention.
pub fn isBotAdmin(pool: *PgPool, identity_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM bot_admins WHERE identity_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    return stmt.step() catch false;
}

/// Idempotent: granting an already-admin identity again is a no-op (does not
/// update `granted_by`/`granted_at` to the second grant's values).
pub fn addBotAdmin(pool: *PgPool, identity_id: i64, granted_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO bot_admins (identity_id, granted_by) VALUES ($1, $2)
        \\ON CONFLICT (identity_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindInt64(2, granted_by);
    _ = try stmt.step();
}

/// No-op if `identity_id` isn't a bot admin.
pub fn removeBotAdmin(pool: *PgPool, identity_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM bot_admins WHERE identity_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

test "isBotAdmin is false by default, true after addBotAdmin, false again after removeBotAdmin" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);

    try testing.expect(!isBotAdmin(&pool, alice));

    try addBotAdmin(&pool, alice, owner);
    try testing.expect(isBotAdmin(&pool, alice));

    try removeBotAdmin(&pool, alice);
    try testing.expect(!isBotAdmin(&pool, alice));
}

test "addBotAdmin is idempotent — granting twice does not error or duplicate" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);

    try addBotAdmin(&pool, alice, owner);
    try addBotAdmin(&pool, alice, owner);
    try testing.expect(isBotAdmin(&pool, alice));
}

test "removeBotAdmin on someone who was never an admin is a no-op, not an error" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);
    try removeBotAdmin(&pool, alice);
    try testing.expect(!isBotAdmin(&pool, alice));
}
