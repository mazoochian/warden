const std = @import("std");
const PgPool = @import("pool.zig").PgPool;
const chats = @import("chats.zig");
const Platform = @import("../platform/interface.zig").Platform;

/// A "management room" binding: `control_chat_id` is authorized to act on
/// `target_chat_id` — see ROADMAP.md's Phase 9 for why this exists
/// (channels have no back-and-forth a member could type commands into, so
/// admin actions/notices for one are issued from a separate control chat
/// instead). **1:1 as of Phase 20**: a control room binds exactly one
/// target, and a target is watched by exactly one room — this is what lets
/// a command typed directly in a bound room (no `/as <id>` prefix, see
/// Phase 21) know its implicit target, and what makes "the" room a target's
/// audit log posts into well-defined. `/as` itself doesn't need a binding
/// at all any more (see `resolveAsCommand` in `main.zig`) — this table now
/// exists purely for the direct-dispatch and audit-routing use cases.
///
/// Rebinding either side clears whatever it was previously bound to first
/// — `/manage bind` re-run against a new target moves the room, it doesn't
/// add a second binding. Idempotent for the exact same pair: binding an
/// already-bound pair is a no-op beyond the clear, not an error.
pub fn bind(pool: *PgPool, control_chat_id: i64, target_chat_id: i64, bound_by_identity_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var clear = try db.prepare(
        \\DELETE FROM management_room_bindings
        \\WHERE control_chat_id = $1 OR target_chat_id = $2;
    );
    defer clear.finalize();
    clear.bindInt64(1, control_chat_id);
    clear.bindInt64(2, target_chat_id);
    _ = try clear.step();

    var stmt = try db.prepare(
        \\INSERT INTO management_room_bindings (control_chat_id, target_chat_id, bound_by_identity_id)
        \\VALUES ($1, $2, $3);
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

/// The actual authorization gate `/notice` checks before acting on a target
/// chat: is *this specific* control room currently bound to it. Doesn't by
/// itself confirm the caller has any standing to act — see
/// `auth.isOwnerOrLiveAdminOfChat`, checked separately and always alongside
/// this. `/as` (Phase 20 onward) no longer uses this at all — it works from
/// any chat regardless of binding.
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

/// The single target `control_chat_id` is currently bound to, if any —
/// what Phase 21's direct-in-room dispatch (a command typed in a bound room
/// with no `/as <id>` prefix) resolves its implicit target from.
pub fn getBoundTarget(pool: *PgPool, allocator: std.mem.Allocator, control_chat_id: i64) !?chats.ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT c.id, c.native_chat_id, c.platform
        \\FROM management_room_bindings m
        \\JOIN chats c ON c.id = m.target_chat_id
        \\WHERE m.control_chat_id = $1;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, control_chat_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
    };
}

/// The single control room bound to `target_chat_id`, if any — where
/// `features/audit_notify.zig` posts a managerial action's log entry.
pub fn getBoundRoom(pool: *PgPool, allocator: std.mem.Allocator, target_chat_id: i64) !?chats.ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT c.id, c.native_chat_id, c.platform
        \\FROM management_room_bindings m
        \\JOIN chats c ON c.id = m.control_chat_id
        \\WHERE m.target_chat_id = $1;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, target_chat_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
    };
}

/// Every chat currently bound to `control_chat_id` (at most one as of
/// Phase 20), for `/manage list`.
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

test "listTargets returns the one chat bound to that control room" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const control1 = try chats.upsertChat(&pool, .telegram, "control1", null, null);
    const target1 = try chats.upsertChat(&pool, .telegram, "target1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try bind(&pool, control1, target1, identity_id);

    const found = try listTargets(&pool, a, control1);
    defer {
        for (found) |r| a.free(r.native_chat_id);
        a.free(found);
    }
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("target1", found[0].native_chat_id);
}

test "bind is 1:1: rebinding a control room to a new target drops the old one, and a target already bound elsewhere is moved" {
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
    // control1 now points at target2 only.
    try testing.expect(!try isBound(&pool, control1, target1));
    try testing.expect(try isBound(&pool, control1, target2));

    // Binding target2 to a different control room moves it there too.
    try bind(&pool, control2, target2, identity_id);
    try testing.expect(!try isBound(&pool, control1, target2));
    try testing.expect(try isBound(&pool, control2, target2));

    const bound_target = (try getBoundTarget(&pool, a, control2)).?;
    defer a.free(bound_target.native_chat_id);
    try testing.expectEqualStrings("target2", bound_target.native_chat_id);

    const bound_room = (try getBoundRoom(&pool, a, target2)).?;
    defer a.free(bound_room.native_chat_id);
    try testing.expectEqualStrings("control2", bound_room.native_chat_id);

    try testing.expect(try getBoundTarget(&pool, a, control1) == null);
}
