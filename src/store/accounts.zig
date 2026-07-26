const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// warden-ui's "one browser-facing person" — distinct from `identities`
/// (one real person *per platform*, which is all the bot itself has ever
/// needed). See /home/armin/claude/warden-ui/ARCHITECTURE.md §3.3 for the
/// full reasoning: logging in via the Telegram Login Widget resolves
/// straight to an existing `identities` row (no account exists yet for
/// most admins the first time they visit the panel — `getOrCreateForIdentity`
/// below handles that); logging in via Google/generic OIDC for the first
/// time has no existing identity to reuse, so it creates both a fresh
/// `identities` row (done by the caller, in the login handler — this
/// module only ever deals with already-resolved `identity_id`s) and the
/// `accounts` row here.
pub const Account = struct {
    id: i64,
    display_name: []const u8,
    avatar_url: ?[]const u8,
};

/// `null` if `identity_id` isn't linked to any account yet.
pub fn findByIdentity(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) !?Account {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT a.id, a.display_name, a.avatar_url
        \\FROM accounts a
        \\JOIN account_identities ai ON ai.account_id = a.id
        \\WHERE ai.identity_id = $1;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .display_name = try allocator.dupe(u8, stmt.columnText(1)),
        .avatar_url = if (stmt.columnIsNull(2)) null else try allocator.dupe(u8, stmt.columnText(2)),
    };
}

/// Creates a fresh account linked to `identity_id` in one round trip (a
/// data-modifying CTE, not a manually-managed transaction — Postgres
/// guarantees the two inserts either both happen or neither does).
/// Callers must check `findByIdentity` first — this does not itself guard
/// against `identity_id` already being linked elsewhere (that would
/// surface as the `account_identities.identity_id` UNIQUE constraint
/// erroring, which is the correct behavior: an already-linked identity
/// logging in again should resolve via `findByIdentity`, never re-create).
pub fn create(pool: *PgPool, identity_id: i64, display_name: []const u8, avatar_url: ?[]const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\WITH new_account AS (
        \\  INSERT INTO accounts (display_name, avatar_url) VALUES ($1, $2) RETURNING id
        \\)
        \\INSERT INTO account_identities (account_id, identity_id)
        \\SELECT id, $3 FROM new_account
        \\RETURNING account_id;
    );
    defer stmt.finalize();
    stmt.bindText(1, display_name);
    if (avatar_url) |u| stmt.bindText(2, u) else stmt.bindNull(2);
    stmt.bindInt64(3, identity_id);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Links an additional identity onto an already-existing account (the
/// "add another login method" flow) — errors if `identity_id` is already
/// linked to any account (including this one), matching
/// `account_identities.identity_id`'s UNIQUE constraint.
pub fn linkIdentity(pool: *PgPool, account_id: i64, identity_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("INSERT INTO account_identities (account_id, identity_id) VALUES ($1, $2);");
    defer stmt.finalize();
    stmt.bindInt64(1, account_id);
    stmt.bindInt64(2, identity_id);
    _ = try stmt.step();
}

/// Every `identities.id` linked to `account_id`, used to compute a
/// session's effective permissions (the union of whatever each linked
/// identity is independently authorized for — see `auth.zig`).
pub fn listIdentityIds(pool: *PgPool, allocator: std.mem.Allocator, account_id: i64) ![]i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT identity_id FROM account_identities WHERE account_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, account_id);

    var out: std.ArrayList(i64) = .empty;
    while (try stmt.step()) try out.append(allocator, stmt.columnInt64(0));
    return out.toOwnedSlice(allocator);
}

/// `false` (refuses) if `identity_id` is the account's only remaining
/// linked identity — an account must always keep at least one way to log
/// back in. Returns whether the unlink actually happened.
pub fn unlinkIdentity(pool: *PgPool, account_id: i64, identity_id: i64) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var count_stmt = try db.prepare("SELECT count(*) FROM account_identities WHERE account_id = $1;");
    defer count_stmt.finalize();
    count_stmt.bindInt64(1, account_id);
    _ = try count_stmt.step();
    if (count_stmt.columnInt64(0) <= 1) return false;

    var stmt = try db.prepare("DELETE FROM account_identities WHERE account_id = $1 AND identity_id = $2;");
    defer stmt.finalize();
    stmt.bindInt64(1, account_id);
    stmt.bindInt64(2, identity_id);
    _ = try stmt.step();
    return true;
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

test "create/findByIdentity/listIdentityIds round-trip a fresh account" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const telegram_identity = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try testing.expectEqual(@as(?Account, null), try findByIdentity(&pool, a, telegram_identity));

    const account_id = try create(&pool, telegram_identity, "Alice", null);

    const found = (try findByIdentity(&pool, a, telegram_identity)) orelse return error.TestExpectedValue;
    defer a.free(found.display_name);
    try testing.expectEqual(account_id, found.id);
    try testing.expectEqualStrings("Alice", found.display_name);
    try testing.expectEqual(@as(?[]const u8, null), found.avatar_url);

    const ids = try listIdentityIds(&pool, a, account_id);
    defer a.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(telegram_identity, ids[0]);
}

test "linkIdentity adds a second identity to the same account; unlinkIdentity refuses to remove the last one" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const telegram_identity = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const google_identity = try identities.getOrCreateMinimal(&pool, .telegram, "google-sub-123", "alice", null, false, 1000);
    const account_id = try create(&pool, telegram_identity, "Alice", null);

    try linkIdentity(&pool, account_id, google_identity);
    const ids = try listIdentityIds(&pool, a, account_id);
    defer a.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);

    // Unlinking one of two succeeds.
    try testing.expect(try unlinkIdentity(&pool, account_id, google_identity));
    const remaining = try listIdentityIds(&pool, a, account_id);
    defer a.free(remaining);
    try testing.expectEqual(@as(usize, 1), remaining.len);

    // Unlinking the last one is refused.
    try testing.expect(!try unlinkIdentity(&pool, account_id, telegram_identity));
    const still_there = try listIdentityIds(&pool, a, account_id);
    defer a.free(still_there);
    try testing.expectEqual(@as(usize, 1), still_there.len);
}
