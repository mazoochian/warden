const std = @import("std");
const PgPool = @import("pool.zig").PgPool;
const chats = @import("chats.zig");
const Platform = @import("../platform/interface.zig").Platform;

/// A "management room" binding: `control_chat_id` is authorized to act on
/// `target_chat_id` — see ROADMAP.md's Phase 9 for why this exists
/// (channels have no back-and-forth a member could type commands into, so
/// admin actions/notices for one are issued from a separate control chat
/// instead). Not exclusive in either direction: one control room can bind
/// several targets, and one target can be bound to more than one control
/// room.
///
/// Idempotent — binding an already-bound pair is a no-op, not an error,
/// since `/manage bind` re-run by a second admin (or the same one, twice)
/// shouldn't fail.
pub fn bind(pool: *PgPool, control_chat_id: i64, target_chat_id: i64, bound_by_identity_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO management_room_bindings (control_chat_id, target_chat_id, bound_by_identity_id)
        \\VALUES ($1, $2, $3)
        \\ON CONFLICT (control_chat_id, target_chat_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, control_chat_id);
    stmt.bindInt64(2, target_chat_id);
    stmt.bindInt64(3, bound_by_identity_id);
    _ = try stmt.step();
}

/// Removes a binding, if one exists. Returns whether a row was actually
/// removed, so `/manage unbind` can tell the caller "wasn't bound" apart
/// from "unbound".
pub fn unbind(pool: *PgPool, control_chat_id: i64, target_chat_id: i64) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\DELETE FROM management_room_bindings
        \\WHERE control_chat_id = $1 AND target_chat_id = $2
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, control_chat_id);
    stmt.bindInt64(2, target_chat_id);
    return try stmt.step();
}

/// The actual authorization gate `/notice` (and any future management-room
/// action) checks before acting on a target chat: is *this specific* control
/// room currently bound to it. Doesn't by itself confirm the caller has any
/// standing to act — see `auth.isOwnerOrLiveAdminOfChat`, checked
/// separately and always alongside this.
pub fn isBound(pool: *PgPool, control_chat_id: i64, target_chat_id: i64) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT 1 FROM management_room_bindings
        \\WHERE control_chat_id = $1 AND target_chat_id = $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, control_chat_id);
    stmt.bindInt64(2, target_chat_id);
    return try stmt.step();
}

/// Every chat currently bound to `control_chat_id`, for `/manage list`.
pub fn listTargets(pool: *PgPool, allocator: std.mem.Allocator, control_chat_id: i64) ![]chats.ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT c.id, c.native_chat_id, c.platform
        \\FROM management_room_bindings m
        \\JOIN chats c ON c.id = m.target_chat_id
        \\WHERE m.control_chat_id = $1
        \\ORDER BY m.created_at;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, control_chat_id);

    var out: std.ArrayList(chats.ChatRef) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
        });
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

test "bind is idempotent, isBound reflects state, unbind reports whether a row existed" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const control = try chats.upsertChat(&pool, .telegram, "control", null, null);
    const target = try chats.upsertChat(&pool, .telegram, "target", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try testing.expect(!try isBound(&pool, control, target));

    try bind(&pool, control, target, identity_id);
    try testing.expect(try isBound(&pool, control, target));

    // Re-binding the same pair is a no-op, not an error.
    try bind(&pool, control, target, identity_id);
    try testing.expect(try isBound(&pool, control, target));

    try testing.expect(try unbind(&pool, control, target));
    try testing.expect(!try isBound(&pool, control, target));
    try testing.expect(!try unbind(&pool, control, target));
}

test "listTargets returns only chats bound to that control room, in bind order" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const control1 = try chats.upsertChat(&pool, .telegram, "control1", null, null);
    const control2 = try chats.upsertChat(&pool, .telegram, "control2", null, null);
    const target1 = try chats.upsertChat(&pool, .telegram, "target1", null, null);
    const target2 = try chats.upsertChat(&pool, .telegram, "target2", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try bind(&pool, control1, target1, identity_id);
    try bind(&pool, control1, target2, identity_id);
    try bind(&pool, control2, target1, identity_id);

    const found = try listTargets(&pool, a, control1);
    defer {
        for (found) |r| a.free(r.native_chat_id);
        a.free(found);
    }
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("target1", found[0].native_chat_id);
    try testing.expectEqualStrings("target2", found[1].native_chat_id);
}
