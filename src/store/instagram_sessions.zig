const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// Everything `instagram/session.zig` needs to resume a logged-in session
/// without re-authenticating -- device identity plus session cookies. See
/// `0047_instagram_sessions.sql`'s doc comment for why this is a single
/// fixed-id row (one personal account per deployment, not multi-tenant).
pub const StoredSession = struct {
    ig_username: []const u8,
    ig_user_id: []const u8,
    android_device_id: []const u8,
    phone_id: []const u8,
    device_uuid: []const u8,
    advertising_id: []const u8,
    session_id_cookie: []const u8,
    csrf_token: []const u8,
    mid_cookie: []const u8,
};

/// Returns the persisted session, if any -- `null` means no successful
/// login has ever completed (or `clearSession` was called since).
pub fn loadSession(pool: *PgPool, allocator: std.mem.Allocator) ?StoredSession {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare(
        \\SELECT ig_username, ig_user_id, android_device_id, phone_id, device_uuid,
        \\       advertising_id, session_id_cookie, csrf_token, mid_cookie
        \\FROM instagram_sessions WHERE id = 1;
    ) catch return null;
    defer stmt.finalize();
    const has_row = stmt.step() catch return null;
    if (!has_row) return null;

    return .{
        .ig_username = allocator.dupe(u8, stmt.columnText(0)) catch return null,
        .ig_user_id = allocator.dupe(u8, stmt.columnText(1)) catch return null,
        .android_device_id = allocator.dupe(u8, stmt.columnText(2)) catch return null,
        .phone_id = allocator.dupe(u8, stmt.columnText(3)) catch return null,
        .device_uuid = allocator.dupe(u8, stmt.columnText(4)) catch return null,
        .advertising_id = allocator.dupe(u8, stmt.columnText(5)) catch return null,
        .session_id_cookie = allocator.dupe(u8, stmt.columnText(6)) catch return null,
        .csrf_token = allocator.dupe(u8, stmt.columnText(7)) catch return null,
        .mid_cookie = allocator.dupe(u8, stmt.columnText(8)) catch return null,
    };
}

/// Upserts the single session row -- called once right after a successful
/// login, and again whenever the session cookies rotate (Instagram reissues
/// `sessionid` periodically even without a fresh login).
pub fn saveSession(pool: *PgPool, session: StoredSession) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO instagram_sessions
        \\  (id, ig_username, ig_user_id, android_device_id, phone_id, device_uuid,
        \\   advertising_id, session_id_cookie, csrf_token, mid_cookie, updated_at)
        \\VALUES (1, $1, $2, $3, $4, $5, $6, $7, $8, $9, now())
        \\ON CONFLICT (id) DO UPDATE SET
        \\  ig_username = excluded.ig_username,
        \\  ig_user_id = excluded.ig_user_id,
        \\  android_device_id = excluded.android_device_id,
        \\  phone_id = excluded.phone_id,
        \\  device_uuid = excluded.device_uuid,
        \\  advertising_id = excluded.advertising_id,
        \\  session_id_cookie = excluded.session_id_cookie,
        \\  csrf_token = excluded.csrf_token,
        \\  mid_cookie = excluded.mid_cookie,
        \\  updated_at = now();
    );
    defer stmt.finalize();
    stmt.bindText(1, session.ig_username);
    stmt.bindText(2, session.ig_user_id);
    stmt.bindText(3, session.android_device_id);
    stmt.bindText(4, session.phone_id);
    stmt.bindText(5, session.device_uuid);
    stmt.bindText(6, session.advertising_id);
    stmt.bindText(7, session.session_id_cookie);
    stmt.bindText(8, session.csrf_token);
    stmt.bindText(9, session.mid_cookie);
    _ = try stmt.step();
}

/// `/iglogin logout` -- clears the persisted session so the next login
/// starts fresh server-side too (the device profile is intentionally NOT
/// cleared by this alone; see `instagram/session.zig`'s `logOut`, which
/// decides whether to keep or regenerate the device identity).
pub fn clearSession(pool: *PgPool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM instagram_sessions WHERE id = 1;");
    defer stmt.finalize();
    _ = try stmt.step();
}

/// Last-seen-item timestamp for `thread_id`, or 0 if never recorded (so the
/// very first poll of a thread treats every item in it as new -- same
/// "0 means never" convention as `chat_settings.getLastDigestTs`).
pub fn getThreadWatermark(pool: *PgPool, thread_id: []const u8) i64 {
    const db = pool.acquire() catch return 0;
    defer pool.release(db);

    var stmt = db.prepare("SELECT last_item_ts FROM instagram_thread_watermarks WHERE thread_id = $1;") catch return 0;
    defer stmt.finalize();
    stmt.bindText(1, thread_id);
    const has_row = stmt.step() catch return 0;
    if (!has_row) return 0;
    return stmt.columnInt64(0);
}

pub fn setThreadWatermark(pool: *PgPool, thread_id: []const u8, last_item_ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO instagram_thread_watermarks (thread_id, last_item_ts) VALUES ($1, $2)
        \\ON CONFLICT (thread_id) DO UPDATE SET last_item_ts = excluded.last_item_ts
        \\  WHERE excluded.last_item_ts > instagram_thread_watermarks.last_item_ts;
    );
    defer stmt.finalize();
    stmt.bindText(1, thread_id);
    stmt.bindInt64(2, last_item_ts);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "loadSession returns null before any session is saved, then round-trips every field" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expectEqual(@as(?StoredSession, null), loadSession(&pool, testing.allocator));

    const session = StoredSession{
        .ig_username = "example_user",
        .ig_user_id = "123456789",
        .android_device_id = "android-0011223344556677",
        .phone_id = "00000000-0000-4000-8000-000000000000",
        .device_uuid = "00000000-0000-4000-8000-000000000001",
        .advertising_id = "00000000-0000-4000-8000-000000000002",
        .session_id_cookie = "sess%3Aabc123",
        .csrf_token = "csrftoken123",
        .mid_cookie = "midvalue123",
    };
    try saveSession(&pool, session);

    const loaded = loadSession(&pool, testing.allocator) orelse return error.TestExpectedValue;
    defer {
        testing.allocator.free(loaded.ig_username);
        testing.allocator.free(loaded.ig_user_id);
        testing.allocator.free(loaded.android_device_id);
        testing.allocator.free(loaded.phone_id);
        testing.allocator.free(loaded.device_uuid);
        testing.allocator.free(loaded.advertising_id);
        testing.allocator.free(loaded.session_id_cookie);
        testing.allocator.free(loaded.csrf_token);
        testing.allocator.free(loaded.mid_cookie);
    }
    try testing.expectEqualStrings("example_user", loaded.ig_username);
    try testing.expectEqualStrings("123456789", loaded.ig_user_id);
    try testing.expectEqualStrings("sess%3Aabc123", loaded.session_id_cookie);
}

test "saveSession upserts in place -- a second save overwrites, doesn't duplicate" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const first = StoredSession{
        .ig_username = "old_user",
        .ig_user_id = "1",
        .android_device_id = "android-1",
        .phone_id = "p1",
        .device_uuid = "u1",
        .advertising_id = "a1",
        .session_id_cookie = "s1",
        .csrf_token = "c1",
        .mid_cookie = "m1",
    };
    try saveSession(&pool, first);

    const second = StoredSession{
        .ig_username = "new_user",
        .ig_user_id = "2",
        .android_device_id = "android-1",
        .phone_id = "p1",
        .device_uuid = "u1",
        .advertising_id = "a1",
        .session_id_cookie = "s2",
        .csrf_token = "c2",
        .mid_cookie = "m2",
    };
    try saveSession(&pool, second);

    const loaded = loadSession(&pool, testing.allocator) orelse return error.TestExpectedValue;
    defer {
        testing.allocator.free(loaded.ig_username);
        testing.allocator.free(loaded.ig_user_id);
        testing.allocator.free(loaded.android_device_id);
        testing.allocator.free(loaded.phone_id);
        testing.allocator.free(loaded.device_uuid);
        testing.allocator.free(loaded.advertising_id);
        testing.allocator.free(loaded.session_id_cookie);
        testing.allocator.free(loaded.csrf_token);
        testing.allocator.free(loaded.mid_cookie);
    }
    try testing.expectEqualStrings("new_user", loaded.ig_username);
    try testing.expectEqualStrings("s2", loaded.session_id_cookie);
}

test "clearSession removes the row" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try saveSession(&pool, .{
        .ig_username = "u",
        .ig_user_id = "1",
        .android_device_id = "android-1",
        .phone_id = "p",
        .device_uuid = "u",
        .advertising_id = "a",
        .session_id_cookie = "s",
        .csrf_token = "c",
        .mid_cookie = "m",
    });
    const before = loadSession(&pool, testing.allocator) orelse return error.TestExpectedValue;
    testing.allocator.free(before.ig_username);
    testing.allocator.free(before.ig_user_id);
    testing.allocator.free(before.android_device_id);
    testing.allocator.free(before.phone_id);
    testing.allocator.free(before.device_uuid);
    testing.allocator.free(before.advertising_id);
    testing.allocator.free(before.session_id_cookie);
    testing.allocator.free(before.csrf_token);
    testing.allocator.free(before.mid_cookie);

    try clearSession(&pool);
    try testing.expectEqual(@as(?StoredSession, null), loadSession(&pool, testing.allocator));
}

test "thread watermark defaults to 0 and only ever moves forward" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expectEqual(@as(i64, 0), getThreadWatermark(&pool, "thread-1"));

    try setThreadWatermark(&pool, "thread-1", 1000);
    try testing.expectEqual(@as(i64, 1000), getThreadWatermark(&pool, "thread-1"));

    // A stale (older) watermark write never regresses the stored value.
    try setThreadWatermark(&pool, "thread-1", 500);
    try testing.expectEqual(@as(i64, 1000), getThreadWatermark(&pool, "thread-1"));

    try setThreadWatermark(&pool, "thread-1", 2000);
    try testing.expectEqual(@as(i64, 2000), getThreadWatermark(&pool, "thread-1"));
}
