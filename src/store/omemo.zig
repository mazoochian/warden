//! Persistence for XMPP OMEMO state (see migration 0055). Values are opaque
//! text (sealed, base64) — sealing happens in `platform/xmpp/omemo`.
const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

pub const Device = struct {
    device_id: u32,
    registration_id: u32,
    identity_public: []const u8,
    identity_private: []const u8,
    next_prekey_id: u32,
    current_signed_prekey_id: u32,
};

pub fn loadDevice(pool: *PgPool, allocator: std.mem.Allocator, account: []const u8) !?Device {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(
        \\SELECT device_id, registration_id, identity_public, identity_private,
        \\  next_prekey_id, current_signed_prekey_id FROM omemo_device WHERE account = $1;
    );
    defer stmt.finalize();
    stmt.bindText(1, account);
    if (!(try stmt.step())) return null;
    return .{
        .device_id = @intCast(stmt.columnInt64(0)),
        .registration_id = @intCast(stmt.columnInt64(1)),
        .identity_public = try allocator.dupe(u8, stmt.columnText(2)),
        .identity_private = try allocator.dupe(u8, stmt.columnText(3)),
        .next_prekey_id = @intCast(stmt.columnInt64(4)),
        .current_signed_prekey_id = @intCast(stmt.columnInt64(5)),
    };
}

pub fn saveDevice(pool: *PgPool, account: []const u8, d: Device) !void {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(
        \\INSERT INTO omemo_device (account, device_id, registration_id, identity_public, identity_private,
        \\  next_prekey_id, current_signed_prekey_id) VALUES ($7, $1, $2, $3, $4, $5, $6)
        \\ON CONFLICT (account) DO UPDATE SET device_id = excluded.device_id,
        \\  registration_id = excluded.registration_id, identity_public = excluded.identity_public,
        \\  identity_private = excluded.identity_private, next_prekey_id = excluded.next_prekey_id,
        \\  current_signed_prekey_id = excluded.current_signed_prekey_id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, d.device_id);
    stmt.bindInt64(2, d.registration_id);
    stmt.bindText(3, d.identity_public);
    stmt.bindText(4, d.identity_private);
    stmt.bindInt64(5, d.next_prekey_id);
    stmt.bindInt64(6, d.current_signed_prekey_id);
    stmt.bindText(7, account);
    _ = try stmt.step();
}

pub fn setNextPreKeyId(pool: *PgPool, account: []const u8, next: u32) !void {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare("UPDATE omemo_device SET next_prekey_id = $1 WHERE account = $2;");
    defer stmt.finalize();
    stmt.bindInt64(1, next);
    stmt.bindText(2, account);
    _ = try stmt.step();
}

/// Shared shape of the two id-keyed record tables.
pub const KeyTable = enum {
    prekeys,
    signed_prekeys,

    fn name(self: KeyTable) []const u8 {
        return switch (self) {
            .prekeys => "omemo_prekeys",
            .signed_prekeys => "omemo_signed_prekeys",
        };
    }
};

fn sqlFor(comptime table: KeyTable, comptime fmt: []const u8) [:0]const u8 {
    return std.fmt.comptimePrint(fmt, .{comptime table.name()});
}

pub fn loadKey(pool: *PgPool, allocator: std.mem.Allocator, account: []const u8, comptime table: KeyTable, id: u32) !?[]u8 {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(sqlFor(table, "SELECT record FROM {s} WHERE account = $2 AND id = $1;"));
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindText(2, account);
    if (!(try stmt.step())) return null;
    return try allocator.dupe(u8, stmt.columnText(0));
}

pub fn storeKey(pool: *PgPool, account: []const u8, comptime table: KeyTable, id: u32, record: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(sqlFor(table, "INSERT INTO {s} (account, id, record) VALUES ($3, $1, $2) ON CONFLICT (account, id) DO UPDATE SET record = excluded.record;"));
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindText(2, record);
    stmt.bindText(3, account);
    _ = try stmt.step();
}

pub fn removeKey(pool: *PgPool, account: []const u8, comptime table: KeyTable, id: u32) !void {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(sqlFor(table, "DELETE FROM {s} WHERE account = $2 AND id = $1;"));
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindText(2, account);
    _ = try stmt.step();
}

pub const KeyRecord = struct { id: u32, record: []const u8 };

pub fn listKeys(pool: *PgPool, allocator: std.mem.Allocator, account: []const u8, comptime table: KeyTable) ![]KeyRecord {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(sqlFor(table, "SELECT id, record FROM {s} WHERE account = $1 ORDER BY id;"));
    defer stmt.finalize();
    stmt.bindText(1, account);
    var out: std.ArrayList(KeyRecord) = .empty;
    errdefer out.deinit(allocator);
    while (try stmt.step()) {
        try out.append(allocator, .{ .id = @intCast(stmt.columnInt64(0)), .record = try allocator.dupe(u8, stmt.columnText(1)) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn loadSession(pool: *PgPool, allocator: std.mem.Allocator, account: []const u8, jid: []const u8, device_id: i32) !?[]u8 {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare("SELECT record FROM omemo_sessions WHERE account = $1 AND jid = $2 AND device_id = $3;");
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    stmt.bindInt64(3, device_id);
    if (!(try stmt.step())) return null;
    return try allocator.dupe(u8, stmt.columnText(0));
}

pub fn storeSession(pool: *PgPool, account: []const u8, jid: []const u8, device_id: i32, record: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(
        \\INSERT INTO omemo_sessions (account, jid, device_id, record) VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (account, jid, device_id) DO UPDATE SET record = excluded.record, updated_at = now();
    );
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    stmt.bindInt64(3, device_id);
    stmt.bindText(4, record);
    _ = try stmt.step();
}

/// Returns how many sessions were removed; `device_id` null means all of
/// `jid`'s.
pub fn deleteSessions(pool: *PgPool, account: []const u8, jid: []const u8, device_id: ?i32) !usize {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = if (device_id != null)
        try db.prepare("DELETE FROM omemo_sessions WHERE account = $1 AND jid = $2 AND device_id = $3 RETURNING device_id;")
    else
        try db.prepare("DELETE FROM omemo_sessions WHERE account = $1 AND jid = $2 RETURNING device_id;");
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    if (device_id) |d| stmt.bindInt64(3, d);
    var n: usize = 0;
    while (try stmt.step()) n += 1;
    return n;
}

pub fn sessionDevices(pool: *PgPool, allocator: std.mem.Allocator, account: []const u8, jid: []const u8) ![]i32 {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare("SELECT device_id FROM omemo_sessions WHERE account = $1 AND jid = $2 ORDER BY device_id;");
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(allocator);
    while (try stmt.step()) try out.append(allocator, @intCast(stmt.columnInt64(0)));
    return out.toOwnedSlice(allocator);
}

pub fn loadIdentity(pool: *PgPool, allocator: std.mem.Allocator, account: []const u8, jid: []const u8, device_id: i32) !?[]u8 {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare("SELECT identity_key FROM omemo_identities WHERE account = $1 AND jid = $2 AND device_id = $3;");
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    stmt.bindInt64(3, device_id);
    if (!(try stmt.step())) return null;
    return try allocator.dupe(u8, stmt.columnText(0));
}

/// Records a first-seen identity; never overwrites a different stored key.
pub fn saveIdentityIfNew(pool: *PgPool, account: []const u8, jid: []const u8, device_id: i32, identity_key: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(
        \\INSERT INTO omemo_identities (account, jid, device_id, identity_key) VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (account, jid, device_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    stmt.bindInt64(3, device_id);
    stmt.bindText(4, identity_key);
    _ = try stmt.step();
}

/// Forgets a device's identity and session, so its next key is trusted anew.
pub fn resetDevice(pool: *PgPool, account: []const u8, jid: []const u8, device_id: i32) !void {
    _ = try deleteSessions(pool, account, jid, device_id);
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare("DELETE FROM omemo_identities WHERE account = $1 AND jid = $2 AND device_id = $3;");
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    stmt.bindInt64(3, device_id);
    _ = try stmt.step();
}

pub const KnownIdentity = struct { device_id: i32, identity_key: []const u8 };

pub fn listIdentities(pool: *PgPool, allocator: std.mem.Allocator, account: []const u8, jid: []const u8) ![]KnownIdentity {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare("SELECT device_id, identity_key FROM omemo_identities WHERE account = $1 AND jid = $2 ORDER BY device_id;");
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    var out: std.ArrayList(KnownIdentity) = .empty;
    errdefer out.deinit(allocator);
    while (try stmt.step()) {
        try out.append(allocator, .{ .device_id = @intCast(stmt.columnInt64(0)), .identity_key = try allocator.dupe(u8, stmt.columnText(1)) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn setChatEncrypted(pool: *PgPool, account: []const u8, jid: []const u8, encrypted: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare(
        \\INSERT INTO omemo_chats (account, jid, encrypted) VALUES ($1, $2, $3)
        \\ON CONFLICT (account, jid) DO UPDATE SET encrypted = excluded.encrypted, updated_at = now();
    );
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    stmt.bindBool(3, encrypted);
    _ = try stmt.step();
}

pub fn isChatEncrypted(pool: *PgPool, account: []const u8, jid: []const u8) !bool {
    const db = try pool.acquire();
    defer pool.release(db);
    var stmt = try db.prepare("SELECT encrypted FROM omemo_chats WHERE account = $1 AND jid = $2;");
    defer stmt.finalize();
    stmt.bindText(1, account);
    stmt.bindText(2, jid);
    if (!(try stmt.step())) return false;
    return stmt.columnBool(0);
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "omemo store round-trips device, keys, sessions, identities and chat flags per account" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const me = "bot@x";

    try testing.expectEqual(@as(?Device, null), try loadDevice(&pool, a, me));
    try saveDevice(&pool, me, .{ .device_id = 42, .registration_id = 7, .identity_public = "pub", .identity_private = "priv", .next_prekey_id = 101, .current_signed_prekey_id = 1 });
    try setNextPreKeyId(&pool, me, 102);
    const d = (try loadDevice(&pool, a, me)).?;
    try testing.expectEqual(@as(u32, 42), d.device_id);
    try testing.expectEqual(@as(u32, 102), d.next_prekey_id);
    try testing.expectEqual(@as(?Device, null), try loadDevice(&pool, a, "other@x"));

    try storeKey(&pool, me, .prekeys, 5, "r5");
    try storeKey(&pool, me, .prekeys, 6, "r6");
    try storeKey(&pool, "other@x", .prekeys, 5, "theirs");
    try removeKey(&pool, me, .prekeys, 5);
    try testing.expectEqual(@as(?[]u8, null), try loadKey(&pool, a, me, .prekeys, 5));
    try testing.expectEqualStrings("theirs", (try loadKey(&pool, a, "other@x", .prekeys, 5)).?);
    try testing.expectEqual(@as(usize, 1), (try listKeys(&pool, a, me, .prekeys)).len);

    try storeSession(&pool, me, "alice@x", 3, "s1");
    try storeSession(&pool, me, "alice@x", 3, "s2");
    try storeSession(&pool, me, "alice@x", 4, "s3");
    try testing.expectEqualStrings("s2", (try loadSession(&pool, a, me, "alice@x", 3)).?);
    try testing.expectEqual(@as(usize, 2), (try sessionDevices(&pool, a, me, "alice@x")).len);
    try testing.expectEqual(@as(usize, 1), try deleteSessions(&pool, me, "alice@x", 4));

    try saveIdentityIfNew(&pool, me, "alice@x", 3, "k1");
    try saveIdentityIfNew(&pool, me, "alice@x", 3, "k2");
    try testing.expectEqualStrings("k1", (try loadIdentity(&pool, a, me, "alice@x", 3)).?);
    try resetDevice(&pool, me, "alice@x", 3);
    try testing.expectEqual(@as(?[]u8, null), try loadIdentity(&pool, a, me, "alice@x", 3));
    try testing.expectEqual(@as(?[]u8, null), try loadSession(&pool, a, me, "alice@x", 3));

    try testing.expect(!try isChatEncrypted(&pool, me, "alice@x"));
    try setChatEncrypted(&pool, me, "alice@x", true);
    try testing.expect(try isChatEncrypted(&pool, me, "alice@x"));
}
