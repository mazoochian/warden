const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

pub const Kind = enum { crypto, weather, aqi };
pub const Condition = enum { above, below };

pub const default_check_interval_seconds: i64 = 300;
pub const default_cooldown_seconds: i64 = 3600;

/// An alert due to actually be re-checked against its external source (see
/// the `0004_alerts.sql` migration comment on why this is gated separately
/// from `cooldown_seconds`). Joined with `chats` for the native chat id and
/// platform `checkAndDeliverAlerts` needs to pick the right connector (same
/// reasoning as `reminders.DueReminder`).
pub const AlertToCheck = struct {
    id: i64,
    native_chat_id: []const u8,
    platform: Platform,
    kind: Kind,
    subject: []const u8,
    currency: ?[]const u8,
    condition: Condition,
    threshold: f64,
    cooldown_seconds: i64,
    last_triggered_at: ?i64,
};

/// One row for `/alerts` — no chat/platform info needed since it's already
/// scoped to one chat by the caller.
pub const PendingAlert = struct {
    id: i64,
    kind: Kind,
    subject: []const u8,
    currency: ?[]const u8,
    condition: Condition,
    threshold: f64,
};

/// Enough to authorize an `/alert cancel` — same shape/reasoning as
/// `reminders.Reminder`.
pub const Alert = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
};

pub fn create(
    pool: *PgPool,
    chat_id: i64,
    identity_id: i64,
    kind: Kind,
    subject: []const u8,
    currency: ?[]const u8,
    condition: Condition,
    threshold: f64,
) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO alerts (chat_id, identity_id, kind, subject, currency, condition, threshold)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, @tagName(kind));
    stmt.bindText(4, subject);
    if (currency) |c| stmt.bindText(5, c) else stmt.bindNull(5);
    stmt.bindText(6, @tagName(condition));
    stmt.bindFloat64(7, threshold);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Every alert whose check interval has elapsed (or has never been
/// checked), across all chats — the poll loop calls this once per cycle
/// (see `checkAndDeliverAlerts` in `features/alerts.zig`). A row whose
/// `kind`/`condition` doesn't parse (shouldn't happen — both are only ever
/// written via `@tagName` above) is skipped rather than guessed at.
pub fn dueForCheck(pool: *PgPool, allocator: std.mem.Allocator, now: i64) ![]AlertToCheck {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT a.id, c.native_chat_id, c.platform, a.kind, a.subject, a.currency, a.condition, a.threshold,
        \\       a.cooldown_seconds, EXTRACT(EPOCH FROM a.last_triggered_at)::bigint
        \\FROM alerts a JOIN chats c ON c.id = a.chat_id
        \\WHERE a.last_checked_at IS NULL
        \\   OR EXTRACT(EPOCH FROM (to_timestamp($1) - a.last_checked_at)) >= a.check_interval_seconds;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, now);

    var out: std.ArrayList(AlertToCheck) = .empty;
    while (try stmt.step()) {
        const kind = std.meta.stringToEnum(Kind, stmt.columnText(3)) orelse continue;
        const condition = std.meta.stringToEnum(Condition, stmt.columnText(6)) orelse continue;
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
            .kind = kind,
            .subject = try allocator.dupe(u8, stmt.columnText(4)),
            .currency = if (stmt.columnIsNull(5)) null else try allocator.dupe(u8, stmt.columnText(5)),
            .condition = condition,
            .threshold = stmt.columnFloat64(7),
            .cooldown_seconds = stmt.columnInt64(8),
            .last_triggered_at = if (stmt.columnIsNull(9)) null else stmt.columnInt64(9),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Records that this alert's external source was just checked, regardless
/// of whether the condition was true — keeps a persistently-false (or
/// persistently-erroring) alert from being re-fetched every poll cycle.
pub fn markChecked(pool: *PgPool, id: i64, now: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE alerts SET last_checked_at = to_timestamp($2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, now);
    _ = try stmt.step();
}

/// Records an actual notification — also bumps `last_checked_at` so the
/// same poll cycle doesn't separately need `markChecked` too.
pub fn markTriggered(pool: *PgPool, id: i64, now: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE alerts SET last_triggered_at = to_timestamp($2), last_checked_at = to_timestamp($2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, now);
    _ = try stmt.step();
}

/// All alerts for one chat, oldest first.
pub fn listPending(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]PendingAlert {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, kind, subject, currency, condition, threshold
        \\FROM alerts WHERE chat_id = $1 ORDER BY id ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(PendingAlert) = .empty;
    while (try stmt.step()) {
        const kind = std.meta.stringToEnum(Kind, stmt.columnText(1)) orelse continue;
        const condition = std.meta.stringToEnum(Condition, stmt.columnText(4)) orelse continue;
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .kind = kind,
            .subject = try allocator.dupe(u8, stmt.columnText(2)),
            .currency = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
            .condition = condition,
            .threshold = stmt.columnFloat64(5),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` if no such alert exists — used by `/alert cancel` to check
/// chat/creator before deleting.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Alert {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT chat_id, identity_id FROM alerts WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    _ = allocator;
    return .{
        .id = id,
        .chat_id = stmt.columnInt64(0),
        .identity_id = stmt.columnInt64(1),
    };
}

pub fn cancel(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM alerts WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "create/dueForCheck/markChecked/markTriggered/listPending/get/cancel" {
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

    const id = try create(&pool, chat_id, identity_id, .crypto, "bitcoin", "usd", .above, 70000);

    // Never checked yet: immediately due.
    const due = try dueForCheck(&pool, a, 1000);
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqual(Kind.crypto, due[0].kind);
    try testing.expectEqualStrings("bitcoin", due[0].subject);
    try testing.expectEqualStrings("usd", due[0].currency.?);
    try testing.expectEqual(Condition.above, due[0].condition);
    try testing.expectEqual(@as(f64, 70000), due[0].threshold);
    try testing.expectEqual(@as(?i64, null), due[0].last_triggered_at);

    try markChecked(&pool, id, 1000);
    // Just checked: not due again immediately (default interval is 300s).
    try testing.expectEqual(@as(usize, 0), (try dueForCheck(&pool, a, 1010)).len);
    // But is due once the interval has passed.
    try testing.expectEqual(@as(usize, 1), (try dueForCheck(&pool, a, 1000 + 301)).len);

    try markTriggered(&pool, id, 2000);
    const due2 = try dueForCheck(&pool, a, 2000 + 301);
    try testing.expectEqual(@as(usize, 1), due2.len);
    try testing.expectEqual(@as(?i64, 2000), due2[0].last_triggered_at);

    const pending = try listPending(&pool, a, chat_id);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("bitcoin", pending[0].subject);

    const alert = (try get(&pool, a, id)) orelse return error.TestExpectedValue;
    try testing.expectEqual(chat_id, alert.chat_id);
    try testing.expectEqual(identity_id, alert.identity_id);

    try cancel(&pool, id);
    try testing.expectEqual(@as(?Alert, null), try get(&pool, a, id));
    try testing.expectEqual(@as(usize, 0), (try listPending(&pool, a, chat_id)).len);
}
