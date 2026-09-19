const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

/// A reminder due for delivery, joined with `chats` for the native chat id
/// `connector.sendMessage` needs.
pub const DueReminder = struct {
    id: i64,
    chat_id: i64,
    native_chat_id: []const u8,
    platform: Platform,
    message: []const u8,
    due_at: i64,
    recur_interval_seconds: ?i64,
    kind: Kind,
};

/// What a row in this table *is*, as opposed to how it's scheduled — see the
/// `0035_announcements.sql` migration comment.
pub const Kind = enum {
    reminder,
    announcement,

    /// Parsed leniently: an unrecognized value degrades to `.reminder`.
    pub fn fromDb(text: []const u8) Kind {
        return std.meta.stringToEnum(Kind, text) orelse .reminder;
    }

    pub fn toDb(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// One row for `/reminders` — `due_at` is an absolute unix timestamp; the
/// caller formats it relative to its own `now`.
pub const PendingReminder = struct {
    id: i64,
    identity_id: i64,
    message: []const u8,
    due_at: i64,
    recur_interval_seconds: ?i64,
    kind: Kind,
};

/// Enough to authorize a `/remind cancel`.
pub const Reminder = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    message: []const u8,
    kind: Kind,
};

/// `recur_interval_seconds` null creates a normal one-off reminder; set, it
/// creates a recurring one.
pub fn create(pool: *PgPool, chat_id: i64, identity_id: i64, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) !i64 {
    return createOfKind(pool, chat_id, identity_id, message, due_at, recur_interval_seconds, .reminder);
}

/// `create` with an explicit `kind` — the announcement path's entry point
/// (see `Kind`).
pub fn createOfKind(pool: *PgPool, chat_id: i64, identity_id: i64, message: []const u8, due_at: i64, recur_interval_seconds: ?i64, kind: Kind) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO reminders (chat_id, identity_id, message, due_at, recur_interval_seconds, kind)
        \\VALUES ($1, $2, $3, to_timestamp($4), $5, $6)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, message);
    stmt.bindInt64(4, due_at);
    if (recur_interval_seconds) |v| stmt.bindInt64(5, v) else stmt.bindNull(5);
    stmt.bindText(6, kind.toDb());
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Every undelivered reminder whose `due_at` has passed, across all chats —
/// the poll loop calls this once per cycle.
pub fn dueUndelivered(pool: *PgPool, allocator: std.mem.Allocator, now: i64) ![]DueReminder {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT r.id, c.native_chat_id, c.platform, r.message, EXTRACT(EPOCH FROM r.due_at)::bigint, r.recur_interval_seconds, r.kind, r.chat_id
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
            .kind = Kind.fromDb(stmt.columnText(6)),
            .chat_id = stmt.columnInt64(7),
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
/// `reminder_format.nextOccurrence`) instead of marking it delivered.
pub fn reschedule(pool: *PgPool, id: i64, new_due_at: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE reminders SET due_at = to_timestamp($2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, new_due_at);
    _ = try stmt.step();
}

/// One row for the web API's `GET /api/v1/reminders` — identity-scoped.
pub const PendingReminderForIdentity = struct {
    id: i64,
    chat_id: i64,
    chat_title: ?[]const u8,
    message: []const u8,
    due_at: i64,
    recur_interval_seconds: ?i64,
};

/// Pending reminders for one identity, optionally narrowed to one chat.
pub fn listForIdentities(pool: *PgPool, allocator: std.mem.Allocator, identity_ids: []const i64, chat_id: ?i64) ![]PendingReminderForIdentity {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT r.id, r.chat_id, c.title, r.message, EXTRACT(EPOCH FROM r.due_at)::bigint, r.recur_interval_seconds
        \\FROM reminders r JOIN chats c ON c.id = r.chat_id
        \\WHERE r.delivered_at IS NULL AND r.kind = 'reminder' AND r.identity_id = ANY($1::bigint[]) AND ($2::bigint IS NULL OR r.chat_id = $2)
        \\ORDER BY r.due_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64Array(1, identity_ids);
    if (chat_id) |c| stmt.bindInt64(2, c) else stmt.bindNull(2);

    var out: std.ArrayList(PendingReminderForIdentity) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = stmt.columnInt64(1),
            .chat_title = if (stmt.columnIsNull(2)) null else try allocator.dupe(u8, stmt.columnText(2)),
            .message = try allocator.dupe(u8, stmt.columnText(3)),
            .due_at = stmt.columnInt64(4),
            .recur_interval_seconds = if (stmt.columnIsNull(5)) null else stmt.columnInt64(5),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Pending (undelivered) rows of one `kind` for one chat, soonest-due first.
pub fn listPending(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, kind: Kind) ![]PendingReminder {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, identity_id, message, EXTRACT(EPOCH FROM due_at)::bigint, recur_interval_seconds, kind
        \\FROM reminders WHERE chat_id = $1 AND delivered_at IS NULL AND kind = $2
        \\ORDER BY due_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, kind.toDb());

    var out: std.ArrayList(PendingReminder) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .identity_id = stmt.columnInt64(1),
            .message = try allocator.dupe(u8, stmt.columnText(2)),
            .due_at = stmt.columnInt64(3),
            .recur_interval_seconds = if (stmt.columnIsNull(4)) null else stmt.columnInt64(4),
            .kind = Kind.fromDb(stmt.columnText(5)),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` if no such pending (undelivered) row exists — used by `/remind
/// cancel`/`/announce cancel` to check chat/creator/kind before deleting.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Reminder {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT chat_id, identity_id, message, kind FROM reminders WHERE id = $1 AND delivered_at IS NULL;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .chat_id = stmt.columnInt64(0),
        .identity_id = stmt.columnInt64(1),
        .message = try allocator.dupe(u8, stmt.columnText(2)),
        .kind = Kind.fromDb(stmt.columnText(3)),
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

    const pending = try listPending(&pool, a, chat_id, .reminder);
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
    const pending = try listPending(&pool, a, chat_id, .reminder);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(@as(i64, 2000 + 3600), pending[0].due_at);
    try testing.expectEqual(@as(?i64, 3600), pending[0].recur_interval_seconds);

    const due_again = try dueUndelivered(&pool, a, 2000 + 3600);
    try testing.expectEqual(@as(usize, 1), due_again.len);
}

test "listForIdentities scopes by identity across chats, optionally narrowed to one" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, "Chat One");
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, "Chat Two");
    const alice = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    const bob = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "2",
        .display_name = "Bob",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try create(&pool, chat1, alice, "alice in chat1", 2000, null);
    _ = try create(&pool, chat2, alice, "alice in chat2", 3000, null);
    _ = try create(&pool, chat1, bob, "bob in chat1", 4000, null);

    const alice_all = try listForIdentities(&pool, a, &.{alice}, null);
    try testing.expectEqual(@as(usize, 2), alice_all.len);
    try testing.expectEqualStrings("Chat One", alice_all[0].chat_title.?);

    const alice_chat1 = try listForIdentities(&pool, a, &.{alice}, chat1);
    try testing.expectEqual(@as(usize, 1), alice_chat1.len);
    try testing.expectEqualStrings("alice in chat1", alice_chat1[0].message);

    const bob_all = try listForIdentities(&pool, a, &.{bob}, null);
    try testing.expectEqual(@as(usize, 1), bob_all.len);
}

test "announcements share the table but never leak into a reminder listing (or vice versa)" {
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

    const rem_id = try create(&pool, chat_id, identity_id, "water the plants", 2000, null);
    const ann_id = try createOfKind(&pool, chat_id, identity_id, "standup at 10", 2000, 86400, .announcement);

    // Each list shows exactly its own kind.
    const rems = try listPending(&pool, a, chat_id, .reminder);
    try testing.expectEqual(@as(usize, 1), rems.len);
    try testing.expectEqual(rem_id, rems[0].id);
    try testing.expectEqual(Kind.reminder, rems[0].kind);

    const anns = try listPending(&pool, a, chat_id, .announcement);
    try testing.expectEqual(@as(usize, 1), anns.len);
    try testing.expectEqual(ann_id, anns[0].id);
    try testing.expectEqual(Kind.announcement, anns[0].kind);
    try testing.expectEqual(@as(?i64, 86400), anns[0].recur_interval_seconds);

    // `get` is deliberately kind-agnostic so the caller can tell "wrong
    // Kind" apart from "no such id".
    const fetched = (try get(&pool, a, ann_id)) orelse return error.TestExpectedValue;
    try testing.expectEqual(Kind.announcement, fetched.kind);

    // The delivery query returns both kinds (one loop delivers everything),
    // tagged so the sender can pick the right framing.
    const due = try dueUndelivered(&pool, a, 2000);
    try testing.expectEqual(@as(usize, 2), due.len);
    var saw_announcement = false;
    for (due) |d| {
        try testing.expectEqual(chat_id, d.chat_id);
        if (d.kind == .announcement) saw_announcement = true;
    }
    try testing.expect(saw_announcement);

    // The web panel's identity-scoped view stays reminders-only.
    const mine = try listForIdentities(&pool, a, &.{identity_id}, null);
    try testing.expectEqual(@as(usize, 1), mine.len);
    try testing.expectEqual(rem_id, mine[0].id);
}

test "Kind.fromDb degrades an unrecognized value to .reminder rather than failing" {
    try testing.expectEqual(Kind.reminder, Kind.fromDb("reminder"));
    try testing.expectEqual(Kind.announcement, Kind.fromDb("announcement"));
    try testing.expectEqual(Kind.reminder, Kind.fromDb("something_a_future_version_added"));
    try testing.expectEqualStrings("announcement", Kind.announcement.toDb());
}
