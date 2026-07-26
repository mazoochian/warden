const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

/// Which grant a pending-by-username row promises — see this module's
/// callers (`main.zig`'s `/adduser`/`/addadmin` handlers, which queue one of
/// these; `resolveSenderIdentity`, which completes it once the identity is
/// known) for the full flow.
pub const Kind = enum {
    allowed_user,
    bot_admin,

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .allowed_user => "allowed_user",
            .bot_admin => "bot_admin",
        };
    }
};

/// Queues a grant for a `@username` the bot has no identity row for yet —
/// idempotent (re-queueing the same platform/username/kind is a no-op, not
/// an error).
pub fn addPending(pool: *PgPool, platform: Platform, username: []const u8, kind: Kind, added_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO bot_pending_grants (platform, username_lower, kind, added_by)
        \\VALUES ($1, lower($2), $3, $4)
        \\ON CONFLICT (platform, username_lower, kind) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, username);
    stmt.bindText(3, kind.label());
    stmt.bindInt64(4, added_by);
    _ = try stmt.step();
}

/// Cancels a pending grant before it's ever completed — no-op if there
/// wasn't one. Used by `/removeuser`/`/removeadmin` when the target still
/// has no resolvable identity (nothing else to "remove" in that case).
pub fn removePending(pool: *PgPool, platform: Platform, username: []const u8, kind: Kind) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\DELETE FROM bot_pending_grants
        \\WHERE platform = $1 AND username_lower = lower($2) AND kind = $3;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, username);
    stmt.bindText(3, kind.label());
    _ = try stmt.step();
}

/// Atomically removes and returns the granter's identity id for a pending
/// (platform, username, kind) grant, or `null` if none is queued — the
/// `DELETE ... RETURNING` makes "check and consume" a single round trip,
/// so two concurrent messages from the same brand-new username can't both
/// claim (and double-apply) the same pending grant.
pub fn takePending(pool: *PgPool, platform: Platform, username: []const u8, kind: Kind) !?i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\DELETE FROM bot_pending_grants
        \\WHERE platform = $1 AND username_lower = lower($2) AND kind = $3
        \\RETURNING added_by;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, username);
    stmt.bindText(3, kind.label());
    if (!try stmt.step()) return null;
    return stmt.columnInt64(0);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

test "addPending is idempotent; takePending consumes it exactly once" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);

    try addPending(&pool, .telegram, "Newcomer", .allowed_user, owner);
    try addPending(&pool, .telegram, "Newcomer", .allowed_user, owner); // idempotent re-queue

    // Case-insensitive: queued as "Newcomer", found via "newcomer".
    const found = try takePending(&pool, .telegram, "newcomer", .allowed_user);
    try testing.expectEqual(owner, found.?);

    // Consumed — a second take finds nothing.
    try testing.expect(try takePending(&pool, .telegram, "newcomer", .allowed_user) == null);
}

test "allowed_user and bot_admin pending grants for the same username are independent" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);

    try addPending(&pool, .telegram, "alice", .allowed_user, owner);
    try addPending(&pool, .telegram, "alice", .bot_admin, owner);

    try testing.expect(try takePending(&pool, .telegram, "alice", .allowed_user) != null);
    // The bot_admin grant is untouched by consuming the allowed_user one.
    try testing.expect(try takePending(&pool, .telegram, "alice", .bot_admin) != null);
}

test "removePending cancels a queued grant without ever completing it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);

    try addPending(&pool, .telegram, "alice", .allowed_user, owner);
    try removePending(&pool, .telegram, "alice", .allowed_user);
    try testing.expect(try takePending(&pool, .telegram, "alice", .allowed_user) == null);
}

test "removePending on something never queued is a no-op, not an error" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try removePending(&pool, .telegram, "nobody", .allowed_user);
}

test "pending grants are platform-scoped" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try addPending(&pool, .telegram, "alice", .allowed_user, owner);

    try testing.expect(try takePending(&pool, .matrix, "alice", .allowed_user) == null);
    try testing.expect(try takePending(&pool, .telegram, "alice", .allowed_user) != null);
}
