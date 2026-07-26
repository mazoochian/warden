const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// A web login session — DB-backed (not a stateless JWT) so it can be
/// revoked server-side. See src/api/auth.zig for how the browser cookie
/// (session id + an HMAC-SHA256 tag) maps onto this row, and
/// /home/armin/claude/warden-ui/ARCHITECTURE.md §3.2 for why DB-backed was
/// chosen over a pure stateless token.
pub const Session = struct {
    id: i64,
    account_id: i64,
    expires_at: i64,
    revoked_at: ?i64,
};

pub fn create(pool: *PgPool, account_id: i64, now: i64, expires_at: i64, user_agent: ?[]const u8, ip: ?[]const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO web_sessions (account_id, created_at, expires_at, user_agent, ip)
        \\VALUES ($1, to_timestamp($2), to_timestamp($3), $4, $5)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, account_id);
    stmt.bindInt64(2, now);
    stmt.bindInt64(3, expires_at);
    if (user_agent) |u| stmt.bindText(4, u) else stmt.bindNull(4);
    if (ip) |i| stmt.bindText(5, i) else stmt.bindNull(5);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// `null` if the session doesn't exist, is revoked, or has expired — the
/// one function `src/api/auth.zig`'s middleware calls on every request, so
/// "not currently valid" collapses to a single `null` case rather than
/// making every caller separately check `revoked_at`/`expires_at`.
pub fn getValid(pool: *PgPool, id: i64, now: i64) ?Session {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare(
        \\SELECT account_id, EXTRACT(EPOCH FROM expires_at)::bigint
        \\FROM web_sessions
        \\WHERE id = $1 AND revoked_at IS NULL AND expires_at > to_timestamp($2);
    ) catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, now);
    const has_row = stmt.step() catch return null;
    if (!has_row) return null;
    return .{
        .id = id,
        .account_id = stmt.columnInt64(0),
        .expires_at = stmt.columnInt64(1),
        .revoked_at = null,
    };
}

pub fn revoke(pool: *PgPool, id: i64, now: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE web_sessions SET revoked_at = to_timestamp($2) WHERE id = $1 AND revoked_at IS NULL;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, now);
    _ = try stmt.step();
}

/// Revokes every live session for an account — "log out everywhere."
pub fn revokeAllForAccount(pool: *PgPool, account_id: i64, now: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE web_sessions SET revoked_at = to_timestamp($2) WHERE account_id = $1 AND revoked_at IS NULL;");
    defer stmt.finalize();
    stmt.bindInt64(1, account_id);
    stmt.bindInt64(2, now);
    _ = try stmt.step();
}

pub const SessionSummary = struct {
    id: i64,
    created_at: i64,
    expires_at: i64,
    user_agent: ?[]const u8,
    ip: ?[]const u8,
};

/// Every live (unrevoked, unexpired) session for an account — the "log
/// out everywhere" / active-sessions list surface.
pub fn listLiveForAccount(pool: *PgPool, allocator: std.mem.Allocator, account_id: i64, now: i64) ![]SessionSummary {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, EXTRACT(EPOCH FROM created_at)::bigint, EXTRACT(EPOCH FROM expires_at)::bigint, user_agent, ip
        \\FROM web_sessions
        \\WHERE account_id = $1 AND revoked_at IS NULL AND expires_at > to_timestamp($2)
        \\ORDER BY created_at DESC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, account_id);
    stmt.bindInt64(2, now);

    var out: std.ArrayList(SessionSummary) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .created_at = stmt.columnInt64(1),
            .expires_at = stmt.columnInt64(2),
            .user_agent = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
            .ip = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
        });
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");
const accounts = @import("accounts.zig");

test "create/getValid round-trips a session, revoke and expiry both invalidate it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const account_id = try accounts.create(&pool, identity_id, "Alice", null);

    const session_id = try create(&pool, account_id, 1000, 2000, "test-agent", "127.0.0.1");

    const valid = getValid(&pool, session_id, 1500) orelse return error.TestExpectedValue;
    try testing.expectEqual(account_id, valid.account_id);

    // Past expiry.
    try testing.expectEqual(@as(?Session, null), getValid(&pool, session_id, 2001));

    // A second session, revoked explicitly.
    const session2 = try create(&pool, account_id, 1000, 5000, null, null);
    try testing.expect(getValid(&pool, session2, 1500) != null);
    try revoke(&pool, session2, 1500);
    try testing.expectEqual(@as(?Session, null), getValid(&pool, session2, 1500));
}

test "revokeAllForAccount invalidates every live session but not other accounts'" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const alice_identity = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const alice_account = try accounts.create(&pool, alice_identity, "Alice", null);
    const bob_identity = try identities.getOrCreateMinimal(&pool, .telegram, "2", "bob", null, false, 1000);
    const bob_account = try accounts.create(&pool, bob_identity, "Bob", null);

    const alice_session1 = try create(&pool, alice_account, 1000, 5000, null, null);
    const alice_session2 = try create(&pool, alice_account, 1000, 5000, null, null);
    const bob_session = try create(&pool, bob_account, 1000, 5000, null, null);

    try revokeAllForAccount(&pool, alice_account, 1500);

    try testing.expectEqual(@as(?Session, null), getValid(&pool, alice_session1, 1500));
    try testing.expectEqual(@as(?Session, null), getValid(&pool, alice_session2, 1500));
    try testing.expect(getValid(&pool, bob_session, 1500) != null);
}

test "listLiveForAccount excludes revoked and expired sessions" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const account_id = try accounts.create(&pool, identity_id, "Alice", null);

    const live = try create(&pool, account_id, 1000, 5000, "chrome", "1.2.3.4");
    const expired = try create(&pool, account_id, 1000, 1100, null, null);
    const revoked = try create(&pool, account_id, 1000, 5000, null, null);
    try revoke(&pool, revoked, 1500);

    const sessions = try listLiveForAccount(&pool, a, account_id, 1500);
    defer {
        for (sessions) |s| {
            if (s.user_agent) |ua| a.free(ua);
            if (s.ip) |ip| a.free(ip);
        }
        a.free(sessions);
    }
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqual(live, sessions[0].id);
    try testing.expectEqualStrings("chrome", sessions[0].user_agent.?);
    _ = expired;
}
