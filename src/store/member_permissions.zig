const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const iface = @import("../platform/interface.zig");
const Platform = iface.Platform;
const MemberPermission = iface.MemberPermission;

/// The granular per-member permission model (`/permission`, ROADMAP.md's
/// Phase 24) — `(chat_id, identity_id) -> permission_bits` (a
/// `MemberPermission` bitmask), with an optional `expires_at` for a timed
/// grant/revoke (`/permission <duration> +/-<letters> @user`) that reverts
/// to the full/default bitmask once it lapses (see `revertExpired` below,
/// polled the same way `main.zig`'s `checkAndSendDueReminders` is).
///
/// A member with no row here has the implicit default bitmask
/// (`MemberPermission.all`, i.e. unrestricted) — same "absent row means the
/// default" convention `feature_flags.isEnabled`/`chat_settings.
/// getDigestEnabled` already use, rather than a migration needing to seed a
/// row per existing member.
pub fn getBits(pool: *PgPool, chat_id: i64, identity_id: i64) u32 {
    const db = pool.acquire() catch return MemberPermission.all;
    defer pool.release(db);

    var stmt = db.prepare("SELECT permission_bits FROM member_permissions WHERE chat_id = $1 AND identity_id = $2;") catch return MemberPermission.all;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    const has_row = stmt.step() catch return MemberPermission.all;
    if (!has_row) return MemberPermission.all;
    return @intCast(stmt.columnInt64(0));
}

/// `expires_at` null means permanent (until the next explicit
/// `/permission` change); set means this row auto-reverts to
/// `MemberPermission.all` once `revertExpired` next runs past it.
pub fn setBits(pool: *PgPool, chat_id: i64, identity_id: i64, bits: u32, expires_at: ?i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    // `to_timestamp` is a strict Postgres builtin -- a NULL `$4` (via
    // `bindNull` below) yields a NULL `expires_at`, no CASE needed, same as
    // every other nullable-timestamp insert in this codebase.
    var stmt = try db.prepare(
        \\INSERT INTO member_permissions (chat_id, identity_id, permission_bits, expires_at)
        \\VALUES ($1, $2, $3, to_timestamp($4))
        \\ON CONFLICT (chat_id, identity_id) DO UPDATE SET
        \\  permission_bits = excluded.permission_bits, expires_at = excluded.expires_at;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindInt64(3, @intCast(bits));
    if (expires_at) |e| stmt.bindInt64(4, e) else stmt.bindNull(4);
    _ = try stmt.step();
}

/// One row `revertExpired`/`listExpired` needs enough of to both clear the
/// DB state and re-apply the (now-default) bitmask on the live platform —
/// see `main.zig`'s `checkAndRevertExpiredPermissions`, which mirrors
/// `checkAndSendDueReminders`'s polling-loop shape.
pub const Expired = struct {
    chat_id: i64,
    identity_id: i64,
    native_chat_id: []const u8,
    platform: Platform,
    native_user_id: []const u8,
};

/// Every `member_permissions` row whose `expires_at` has passed `now` —
/// joins through to `chats`/`identities` for the native ids
/// `checkAndRevertExpiredPermissions` needs to re-apply the default
/// bitmask through the right connector.
pub fn listExpired(pool: *PgPool, allocator: std.mem.Allocator, now: i64) ![]Expired {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT mp.chat_id, mp.identity_id, c.native_chat_id, c.platform, i.native_id
        \\FROM member_permissions mp
        \\JOIN chats c ON c.id = mp.chat_id
        \\JOIN identities i ON i.id = mp.identity_id
        \\WHERE mp.expires_at IS NOT NULL AND mp.expires_at <= to_timestamp($1);
    );
    defer stmt.finalize();
    stmt.bindInt64(1, now);

    var out: std.ArrayList(Expired) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .chat_id = stmt.columnInt64(0),
            .identity_id = stmt.columnInt64(1),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(2)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(3)) orelse .telegram,
            .native_user_id = try allocator.dupe(u8, stmt.columnText(4)),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Reverts one member back to the default (unrestricted) bitmask and
/// clears `expires_at` — called once per `Expired` entry after
/// `checkAndRevertExpiredPermissions` has attempted to re-apply the
/// default bitmask on the live platform (attempted regardless of whether
/// that live call succeeded, same "don't retry forever on a transient
/// platform error" reasoning `checkAndSendDueReminders` applies to a
/// missing connector).
pub fn revert(pool: *PgPool, chat_id: i64, identity_id: i64) !void {
    return setBits(pool, chat_id, identity_id, MemberPermission.all, null);
}

pub const ParseError = error{
    /// The spec didn't start with `+` or `-`.
    MissingSign,
    /// No letters followed the sign.
    EmptyLetters,
    /// A letter that isn't in the `rwpvfmodslaeti` grammar.
    UnknownLetter,
};

pub const Change = struct {
    /// `true` for `+<letters>` (grant), `false` for `-<letters>` (revoke).
    grant: bool,
    bits: u32,
};

/// Parses the `+<letters>`/`-<letters>` half of `/permission` (e.g.
/// `"+rwpvfmodslaeti"`, `"-w"`) — see `iface.MemberPermission.bitForLetter`
/// for the letter grammar. Duplicate letters are harmless (OR'd together).
pub fn parseChange(text: []const u8) ParseError!Change {
    if (text.len == 0) return error.MissingSign;
    const grant = switch (text[0]) {
        '+' => true,
        '-' => false,
        else => return error.MissingSign,
    };
    if (text.len < 2) return error.EmptyLetters;

    var bits: u32 = 0;
    for (text[1..]) |c| {
        const bit = MemberPermission.bitForLetter(c) orelse return error.UnknownLetter;
        bits |= bit;
    }
    return .{ .grant = grant, .bits = bits };
}

/// Applies a parsed `Change` to an existing bitmask — `+` ORs the new bits
/// in, `-` clears them.
pub fn applyChange(current_bits: u32, change: Change) u32 {
    return if (change.grant) current_bits | change.bits else current_bits & ~change.bits;
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "parseChange: grant/revoke, multi-letter, and every rejection case" {
    const grant_all = try parseChange("+rwpvfmodslaeti");
    try testing.expect(grant_all.grant);
    try testing.expectEqual(MemberPermission.all, grant_all.bits);

    const revoke_write = try parseChange("-w");
    try testing.expect(!revoke_write.grant);
    try testing.expectEqual(MemberPermission.write, revoke_write.bits);

    const revoke_multi = try parseChange("-wp");
    try testing.expectEqual(MemberPermission.write | MemberPermission.photos, revoke_multi.bits);

    try testing.expectError(error.MissingSign, parseChange(""));
    try testing.expectError(error.MissingSign, parseChange("w"));
    try testing.expectError(error.EmptyLetters, parseChange("+"));
    try testing.expectError(error.EmptyLetters, parseChange("-"));
    try testing.expectError(error.UnknownLetter, parseChange("+z"));
    try testing.expectError(error.UnknownLetter, parseChange("+wz"));
}

test "applyChange grants OR revokes bits without disturbing the rest of the mask" {
    const base = MemberPermission.write | MemberPermission.photos;
    try testing.expectEqual(base | MemberPermission.videos, applyChange(base, .{ .grant = true, .bits = MemberPermission.videos }));
    try testing.expectEqual(MemberPermission.photos, applyChange(base, .{ .grant = false, .bits = MemberPermission.write }));
}

test "getBits defaults to MemberPermission.all when unset, setBits round trips" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try testing.expectEqual(MemberPermission.all, getBits(&pool, chat_id, identity_id));

    const restricted = MemberPermission.all & ~MemberPermission.write;
    try setBits(&pool, chat_id, identity_id, restricted, null);
    try testing.expectEqual(restricted, getBits(&pool, chat_id, identity_id));
}

test "listExpired finds only rows past their expires_at, revert clears back to default" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const expired_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const not_yet_id = try identities.getOrCreateMinimal(&pool, .telegram, "2", "bob", null, false, 1000);
    const permanent_id = try identities.getOrCreateMinimal(&pool, .telegram, "3", "carol", null, false, 1000);

    try setBits(&pool, chat_id, expired_id, MemberPermission.all & ~MemberPermission.write, 1500);
    try setBits(&pool, chat_id, not_yet_id, MemberPermission.all & ~MemberPermission.write, 5000);
    try setBits(&pool, chat_id, permanent_id, MemberPermission.all & ~MemberPermission.write, null);

    const expired = try listExpired(&pool, a, 2000);
    defer {
        for (expired) |e| {
            a.free(e.native_chat_id);
            a.free(e.native_user_id);
        }
        a.free(expired);
    }
    try testing.expectEqual(@as(usize, 1), expired.len);
    try testing.expectEqual(expired_id, expired[0].identity_id);
    try testing.expectEqualStrings("1", expired[0].native_chat_id);
    try testing.expectEqual(Platform.telegram, expired[0].platform);
    try testing.expectEqualStrings("1", expired[0].native_user_id);

    try revert(&pool, chat_id, expired_id);
    try testing.expectEqual(MemberPermission.all, getBits(&pool, chat_id, expired_id));

    // Still-pending and permanent rows are untouched.
    try testing.expectEqual(MemberPermission.all & ~MemberPermission.write, getBits(&pool, chat_id, not_yet_id));
    try testing.expectEqual(MemberPermission.all & ~MemberPermission.write, getBits(&pool, chat_id, permanent_id));
}
