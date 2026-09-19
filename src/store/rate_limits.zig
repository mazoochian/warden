const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Warden's own per-chat "slow mode".
pub fn getSlowModeSeconds(pool: *PgPool, chat_id: i64) i64 {
    const db = pool.acquire() catch return 0;
    defer pool.release(db);

    var stmt = db.prepare("SELECT min_seconds_between_messages FROM rate_limits WHERE chat_id = $1;") catch return 0;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return 0;
    if (!has_row) return 0;
    return stmt.columnInt64(0);
}

/// `seconds <= 0` is `/slowmode off` — stored as 0 rather than deleting the
/// row, since either reads back as "disabled" via `getSlowModeSeconds`.
pub fn setSlowModeSeconds(pool: *PgPool, chat_id: i64, seconds: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO rate_limits (chat_id, min_seconds_between_messages) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET min_seconds_between_messages = excluded.min_seconds_between_messages;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, @max(seconds, 0));
    _ = try stmt.step();
}

/// The last *accepted* (not rate-limited) message timestamp for (chat_id,
/// identity_id), or `null` if this member has never had one recorded.
pub fn getLastMessageAt(pool: *PgPool, chat_id: i64, identity_id: i64) ?i64 {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT EXTRACT(EPOCH FROM last_message_at)::bigint FROM member_message_cooldowns WHERE chat_id = $1 AND identity_id = $2;") catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    const has_row = stmt.step() catch return null;
    if (!has_row) return null;
    return stmt.columnInt64(0);
}

pub fn touchLastMessage(pool: *PgPool, chat_id: i64, identity_id: i64, ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO member_message_cooldowns (chat_id, identity_id, last_message_at)
        \\VALUES ($1, $2, to_timestamp($3))
        \\ON CONFLICT (chat_id, identity_id) DO UPDATE SET last_message_at = excluded.last_message_at;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindInt64(3, ts);
    _ = try stmt.step();
}

/// Pure cooldown check, no DB access.
pub fn isRateLimited(last_message_at: ?i64, min_seconds_between_messages: i64, now: i64) bool {
    if (min_seconds_between_messages <= 0) return false;
    const last = last_message_at orelse return false;
    return now - last < min_seconds_between_messages;
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "isRateLimited: off, no prior message, and the cooldown boundary itself" {
    // Slow mode off entirely.
    try testing.expect(!isRateLimited(1000, 0, 1005));
    try testing.expect(!isRateLimited(1000, -5, 1005));

    // No prior accepted message on record -- nothing to violate.
    try testing.expect(!isRateLimited(null, 30, 1000));

    // Well within the cooldown.
    try testing.expect(isRateLimited(1000, 30, 1010));

    // Exactly at the boundary is allowed (strictly-less-than, not less-than-or-
    // equal).
    try testing.expect(!isRateLimited(1000, 30, 1030));

    // Just past the boundary.
    try testing.expect(!isRateLimited(1000, 30, 1031));
}

test "getSlowModeSeconds/setSlowModeSeconds round trip, defaulting to 0 when unset, and 'off' clamps to 0" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expectEqual(@as(i64, 0), getSlowModeSeconds(&pool, chat_id));

    try setSlowModeSeconds(&pool, chat_id, 30);
    try testing.expectEqual(@as(i64, 30), getSlowModeSeconds(&pool, chat_id));

    // `/slowmode off` -- a negative value should never persist as negative.
    try setSlowModeSeconds(&pool, chat_id, -1);
    try testing.expectEqual(@as(i64, 0), getSlowModeSeconds(&pool, chat_id));
}

test "getLastMessageAt/touchLastMessage round trip per (chat, identity), null when unset" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try testing.expectEqual(@as(?i64, null), getLastMessageAt(&pool, chat_id, identity_id));

    try touchLastMessage(&pool, chat_id, identity_id, 1000);
    try testing.expectEqual(@as(?i64, 1000), getLastMessageAt(&pool, chat_id, identity_id));

    try touchLastMessage(&pool, chat_id, identity_id, 2000);
    try testing.expectEqual(@as(?i64, 2000), getLastMessageAt(&pool, chat_id, identity_id));
}
