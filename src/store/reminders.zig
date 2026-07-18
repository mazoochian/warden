const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

/// A reminder due for delivery, joined with `chats` for the native chat id
/// `connector.sendMessage` needs — the delivery path never touches the
/// internal `chats.id`. `platform` lets the caller pick the matching
/// connector once more than one is active (see `chats.ChatRef`'s doc
/// comment for the same reasoning). `due_at`/`recur_interval_seconds` let
/// the caller (`checkAndSendDueReminders`) decide whether to mark this
/// delivered for good or reschedule it (see `reschedule`).
pub const DueReminder = struct {
    id: i64,
    native_chat_id: []const u8,
    platform: Platform,
    message: []const u8,
    due_at: i64,
    recur_interval_seconds: ?i64,
};

/// One row for `/reminders` — `due_at` is an absolute unix timestamp; the
/// caller formats it relative to its own `now`. `recur_interval_seconds`
/// set means this reminder repeats (see `reminder_format.formatInterval`
/// for rendering it back to shorthand).
pub const PendingReminder = struct {
    id: i64,
    message: []const u8,
    due_at: i64,
    recur_interval_seconds: ?i64,
};

/// Enough to authorize a `/remind cancel` — the requester must be either
/// this reminder's own creator (`identity_id`) or the bot owner, and it must
/// belong to the chat the cancel command was issued in.
pub const Reminder = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    message: []const u8,
};

/// `recur_interval_seconds` null creates a normal one-off reminder; set,
/// it creates a recurring one (see the `0003_reminders_recurrence.sql`
/// migration comment).
pub fn create(pool: *PgPool, chat_id: i64, identity_id: i64, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO reminders (chat_id, identity_id, message, due_at, recur_interval_seconds)
        \\VALUES ($1, $2, $3, to_timestamp($4), $5)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, message);
    stmt.bindInt64(4, due_at);
    if (recur_interval_seconds) |v| stmt.bindInt64(5, v) else stmt.bindNull(5);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Every undelivered reminder whose `due_at` has passed, across all chats —
/// the poll loop calls this once per cycle (see `checkAndSendDueReminders`
/// in `main.zig`).
pub fn dueUndelivered(pool: *PgPool, allocator: std.mem.Allocator, now: i64) ![]DueReminder {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT r.id, c.native_chat_id, c.platform, r.message, EXTRACT(EPOCH FROM r.due_at)::bigint, r.recur_interval_seconds
        \\FROM reminders r JOIN chats c ON c.id = r.chat_id
        \\WHERE r.delivered_at IS NULL AND r.due_at <= to_timestamp($1);
    );
    defer stmt.finalize();
    stmt.bindInt64(1, now);

    var out: std.ArrayList(DueReminder) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
            .message = try allocator.dupe(u8, stmt.columnText(3)),
            .due_at = stmt.columnInt64(4),
            .recur_interval_seconds = if (stmt.columnIsNull(5)) null else stmt.columnInt64(5),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Marks a one-off reminder permanently delivered.
pub fn markDelivered(pool: *PgPool, id: i64, now: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE reminders SET delivered_at = to_timestamp($2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, now);
    _ = try stmt.step();
}

/// Advances a recurring reminder's `due_at` to `new_due_at` (see
/// `reminder_format.nextOccurrence`) instead of marking it delivered, so it
/// stays pending and fires again next cycle.
pub fn reschedule(pool: *PgPool, id: i64, new_due_at: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE reminders SET due_at = to_timestamp($2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, new_due_at);
    _ = try stmt.step();
}

/// Pending (undelivered) reminders for one chat, soonest-due first.
pub fn listPending(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]PendingReminder {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, message, EXTRACT(EPOCH FROM due_at)::bigint, recur_interval_seconds
        \\FROM reminders WHERE chat_id = $1 AND delivered_at IS NULL
        \\ORDER BY due_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(PendingReminder) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .message = try allocator.dupe(u8, stmt.columnText(1)),
            .due_at = stmt.columnInt64(2),
            .recur_interval_seconds = if (stmt.columnIsNull(3)) null else stmt.columnInt64(3),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` if no such pending (undelivered) reminder exists — used by
/// `/remind cancel` to check chat/creator before deleting.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Reminder {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT chat_id, identity_id, message FROM reminders WHERE id = $1 AND delivered_at IS NULL;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .chat_id = stmt.columnInt64(0),
        .identity_id = stmt.columnInt64(1),
        .message = try allocator.dupe(u8, stmt.columnText(2)),
    };
}

pub fn cancel(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM reminders WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "create/dueUndelivered/markDelivered/listPending/get/cancel" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .username = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id1 = try create(&pool, chat_id, identity_id, "take out trash", 2000, null);
    const id2 = try create(&pool, chat_id, identity_id, "future thing", 9999, null);

    // Neither is due yet at ts=1500.
    try testing.expectEqual(@as(usize, 0), (try dueUndelivered(&pool, a, 1500)).len);

    const pending = try listPending(&pool, a, chat_id);
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqualStrings("take out trash", pending[0].message);

    const rem = (try get(&pool, a, id1)) orelse return error.TestExpectedValue;
    try testing.expectEqual(chat_id, rem.chat_id);
    try testing.expectEqual(identity_id, rem.identity_id);
    try testing.expectEqualStrings("take out trash", rem.message);

    // At ts=2000, id1 is due but id2 (due 9999) isn't.
    const due = try dueUndelivered(&pool, a, 2000);
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqual(id1, due[0].id);
    try testing.expectEqualStrings("1", due[0].native_chat_id);

    try markDelivered(&pool, id1, 2000);
    try testing.expectEqual(@as(usize, 0), (try dueUndelivered(&pool, a, 2000)).len);
    try testing.expectEqual(@as(?Reminder, null), try get(&pool, a, id1));

    try cancel(&pool, id2);
    try testing.expectEqual(@as(?Reminder, null), try get(&pool, a, id2));
}

test "a recurring reminder reschedules instead of being marked delivered" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = try create(&pool, chat_id, identity_id, "stretch", 2000, 3600);

    const due = try dueUndelivered(&pool, a, 2000);
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqual(@as(i64, 2000), due[0].due_at);
    try testing.expectEqual(@as(?i64, 3600), due[0].recur_interval_seconds);

    try reschedule(&pool, id, 2000 + 3600);

    // Still pending (not delivered) — just moved further out.
    try testing.expectEqual(@as(usize, 0), (try dueUndelivered(&pool, a, 2000)).len);
    const pending = try listPending(&pool, a, chat_id);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(@as(i64, 2000 + 3600), pending[0].due_at);
    try testing.expectEqual(@as(?i64, 3600), pending[0].recur_interval_seconds);

    const due_again = try dueUndelivered(&pool, a, 2000 + 3600);
    try testing.expectEqual(@as(usize, 1), due_again.len);
}
