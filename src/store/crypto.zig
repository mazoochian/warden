const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Persistence for the bot's one process-wide Olm account (see
/// `src/matrix/olm.zig`'s doc comment on why there's only ever one row,
/// keyed by the fixed id `'self'`).
pub const StoredAccount = struct {
    device_id: []const u8,
    pickled_account: []const u8,
};

/// Null when no account has been created yet (first run).
pub fn loadAccount(pool: *PgPool, allocator: std.mem.Allocator) !?StoredAccount {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT device_id, pickled_account FROM crypto_account WHERE id = 'self';");
    defer stmt.finalize();
    if (!(try stmt.step())) return null;
    return .{
        .device_id = try allocator.dupe(u8, stmt.columnText(0)),
        .pickled_account = try allocator.dupe(u8, stmt.columnText(1)),
    };
}

pub fn saveAccount(pool: *PgPool, device_id: []const u8, pickled_account: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO crypto_account (id, device_id, pickled_account) VALUES ('self', $1, $2)
        \\ON CONFLICT (id) DO UPDATE SET
        \\  device_id = excluded.device_id,
        \\  pickled_account = excluded.pickled_account;
    );
    defer stmt.finalize();
    stmt.bindText(1, device_id);
    stmt.bindText(2, pickled_account);
    _ = try stmt.step();
}

/// Persistence for a per-device Olm session (see `matrix/olm.zig`'s
/// `Session`). Deliberately one session per sender identity key, not a
/// multi-session-per-sender model real clients eventually need (trying
/// every known session until one decrypts) — a reasonable simplification
/// for a fresh device whose very first message from any given sender is
/// always a PRE_KEY (session-establishing) message anyway.
pub const StoredSession = struct {
    session_id: []const u8,
    pickled_session: []const u8,
};

/// Null when no session has been established with this identity key yet.
pub fn loadSession(pool: *PgPool, allocator: std.mem.Allocator, their_identity_key: []const u8) !?StoredSession {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT session_id, pickled_session FROM crypto_sessions
        \\WHERE their_identity_key = $1 ORDER BY updated_at DESC LIMIT 1;
    );
    defer stmt.finalize();
    stmt.bindText(1, their_identity_key);
    if (!(try stmt.step())) return null;
    return .{
        .session_id = try allocator.dupe(u8, stmt.columnText(0)),
        .pickled_session = try allocator.dupe(u8, stmt.columnText(1)),
    };
}

pub fn saveSession(pool: *PgPool, their_identity_key: []const u8, session_id: []const u8, pickled_session: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO crypto_sessions (their_identity_key, session_id, pickled_session, updated_at)
        \\VALUES ($1, $2, $3, now())
        \\ON CONFLICT (their_identity_key, session_id) DO UPDATE SET
        \\  pickled_session = excluded.pickled_session,
        \\  updated_at = now();
    );
    defer stmt.finalize();
    stmt.bindText(1, their_identity_key);
    stmt.bindText(2, session_id);
    stmt.bindText(3, pickled_session);
    _ = try stmt.step();
}

/// Persistence for a received Megolm session (see `matrix/olm.zig`'s
/// `InboundGroupSession`) — one per `(room, sending device, session id)`.
pub fn loadInboundGroupSession(pool: *PgPool, allocator: std.mem.Allocator, room_id: []const u8, sender_key: []const u8, session_id: []const u8) !?[]const u8 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT pickled_session FROM crypto_megolm_inbound
        \\WHERE room_id = $1 AND sender_key = $2 AND session_id = $3;
    );
    defer stmt.finalize();
    stmt.bindText(1, room_id);
    stmt.bindText(2, sender_key);
    stmt.bindText(3, session_id);
    if (!(try stmt.step())) return null;
    return try allocator.dupe(u8, stmt.columnText(0));
}

pub fn saveInboundGroupSession(pool: *PgPool, room_id: []const u8, sender_key: []const u8, session_id: []const u8, pickled_session: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO crypto_megolm_inbound (room_id, sender_key, session_id, pickled_session, updated_at)
        \\VALUES ($1, $2, $3, $4, now())
        \\ON CONFLICT (room_id, sender_key, session_id) DO UPDATE SET
        \\  pickled_session = excluded.pickled_session,
        \\  updated_at = now();
    );
    defer stmt.finalize();
    stmt.bindText(1, room_id);
    stmt.bindText(2, sender_key);
    stmt.bindText(3, session_id);
    stmt.bindText(4, pickled_session);
    _ = try stmt.step();
}

/// Persistence for this device's outbound Megolm session for one room (see
/// `matrix/olm.zig`'s `OutboundGroupSession`).
pub const StoredOutboundSession = struct {
    pickled_session: []const u8,
    shared_with_json: []const u8,
    /// Unix seconds — when this *session* (not this row) was first
    /// created. The upsert in `saveOutboundGroupSession` never touches
    /// this column, only `pickled_session`/`shared_with_json`, so it
    /// stays fixed across every message sent with the session and only
    /// moves forward when the session itself rotates. Drives
    /// `crypto.zig`'s `State.encryptForRoom` rotation check.
    created_at_unix: i64,
};

pub fn loadOutboundGroupSession(pool: *PgPool, allocator: std.mem.Allocator, room_id: []const u8) !?StoredOutboundSession {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT pickled_session, shared_with_json, extract(epoch from created_at)::bigint FROM crypto_megolm_outbound WHERE room_id = $1;");
    defer stmt.finalize();
    stmt.bindText(1, room_id);
    if (!(try stmt.step())) return null;
    return .{
        .pickled_session = try allocator.dupe(u8, stmt.columnText(0)),
        .shared_with_json = try allocator.dupe(u8, stmt.columnText(1)),
        .created_at_unix = stmt.columnInt64(2),
    };
}

pub fn saveOutboundGroupSession(pool: *PgPool, room_id: []const u8, pickled_session: []const u8, shared_with_json: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO crypto_megolm_outbound (room_id, pickled_session, shared_with_json) VALUES ($1, $2, $3)
        \\ON CONFLICT (room_id) DO UPDATE SET
        \\  pickled_session = excluded.pickled_session,
        \\  shared_with_json = excluded.shared_with_json;
    );
    defer stmt.finalize();
    stmt.bindText(1, room_id);
    stmt.bindText(2, pickled_session);
    stmt.bindText(3, shared_with_json);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "loadAccount returns null before any account is saved, then round-trips after saveAccount" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expectEqual(@as(?StoredAccount, null), try loadAccount(&pool, testing.allocator));

    try saveAccount(&pool, "DEVICEID", "pickled-blob-v1");
    const loaded = (try loadAccount(&pool, testing.allocator)).?;
    defer {
        testing.allocator.free(loaded.device_id);
        testing.allocator.free(loaded.pickled_account);
    }
    try testing.expectEqualStrings("DEVICEID", loaded.device_id);
    try testing.expectEqualStrings("pickled-blob-v1", loaded.pickled_account);

    // A second save (e.g. after uploading fresh one-time keys) updates the
    // same singleton row rather than erroring or creating a second one.
    try saveAccount(&pool, "DEVICEID", "pickled-blob-v2");
    const reloaded = (try loadAccount(&pool, testing.allocator)).?;
    defer {
        testing.allocator.free(reloaded.device_id);
        testing.allocator.free(reloaded.pickled_account);
    }
    try testing.expectEqualStrings("pickled-blob-v2", reloaded.pickled_account);
}

test "loadSession/saveSession round-trip, keyed by identity key" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expectEqual(@as(?StoredSession, null), try loadSession(&pool, testing.allocator, "THEIRKEY"));

    try saveSession(&pool, "THEIRKEY", "SESSIONID1", "pickled-session-v1");
    const loaded = (try loadSession(&pool, testing.allocator, "THEIRKEY")).?;
    defer {
        testing.allocator.free(loaded.session_id);
        testing.allocator.free(loaded.pickled_session);
    }
    try testing.expectEqualStrings("SESSIONID1", loaded.session_id);
    try testing.expectEqualStrings("pickled-session-v1", loaded.pickled_session);
}

test "loadInboundGroupSession/saveInboundGroupSession round-trip, keyed by room+sender+session" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expectEqual(@as(?[]const u8, null), try loadInboundGroupSession(&pool, testing.allocator, "!room:server", "SENDERKEY", "SESSIONID"));

    try saveInboundGroupSession(&pool, "!room:server", "SENDERKEY", "SESSIONID", "pickled-group-session");
    const loaded = (try loadInboundGroupSession(&pool, testing.allocator, "!room:server", "SENDERKEY", "SESSIONID")).?;
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings("pickled-group-session", loaded);
}

test "loadOutboundGroupSession/saveOutboundGroupSession round-trip, keyed by room" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expectEqual(@as(?StoredOutboundSession, null), try loadOutboundGroupSession(&pool, testing.allocator, "!room:server"));

    try saveOutboundGroupSession(&pool, "!room:server", "pickled-outbound", "[\"DEVICE1\"]");
    const loaded = (try loadOutboundGroupSession(&pool, testing.allocator, "!room:server")).?;
    defer {
        testing.allocator.free(loaded.pickled_session);
        testing.allocator.free(loaded.shared_with_json);
    }
    try testing.expectEqualStrings("pickled-outbound", loaded.pickled_session);
    try testing.expectEqualStrings("[\"DEVICE1\"]", loaded.shared_with_json);
}
