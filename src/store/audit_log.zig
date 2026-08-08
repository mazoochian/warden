const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Every mutating warden-ui API call writes one row here — built in from
/// the project's very first mutating endpoint rather than retrofitted
/// later, per /home/armin/claude/warden-ui/ARCHITECTURE.md §4's reasoning.
/// Since Phase 20 (ROADMAP.md), chat-command admin actions
/// (mute/kick/promote/token/credit/...) write here too, via
/// `features/audit_notify.zig`. `account_id` and `identity_id` are two
/// independent nullable actor columns, not alternates of the same thing —
/// `account_id` references warden-ui's `accounts` (a web login),
/// `identity_id` references a chat platform identity; a given row
/// populates whichever namespace it actually came from (occasionally
/// neither, if the actor genuinely can't be resolved), never both. Both
/// nullable so audit logging is never the reason an action fails.
pub fn record(pool: *PgPool, account_id: ?i64, identity_id: ?i64, action: []const u8, target: ?[]const u8, detail_json: ?[]const u8) void {
    recordFallible(pool, account_id, identity_id, action, target, detail_json) catch |err| {
        std.log.scoped(.audit).err("failed to write audit log entry for action '{s}': {t}", .{ action, err });
    };
}

/// Split out from `record` purely so tests can assert on the error path
/// too — every real call site should use `record` (audit logging must
/// never be the reason a request fails), never this directly.
fn recordFallible(pool: *PgPool, account_id: ?i64, identity_id: ?i64, action: []const u8, target: ?[]const u8, detail_json: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO audit_log (account_id, identity_id, action, target, detail) VALUES ($1, $2, $3, $4, $5);
    );
    defer stmt.finalize();
    if (account_id) |id| stmt.bindInt64(1, id) else stmt.bindNull(1);
    if (identity_id) |id| stmt.bindInt64(2, id) else stmt.bindNull(2);
    stmt.bindText(3, action);
    if (target) |t| stmt.bindText(4, t) else stmt.bindNull(4);
    if (detail_json) |d| stmt.bindText(5, d) else stmt.bindNull(5);
    _ = try stmt.step();
}

pub const Entry = struct {
    id: i64,
    account_id: ?i64,
    identity_id: ?i64,
    action: []const u8,
    target: ?[]const u8,
    detail: ?[]const u8,
    at: i64,
};

/// Paginated, newest first — `before_id` (from the previous page's last
/// entry) narrows to strictly older rows; pass `null` for the first page.
/// Optional `action_filter` narrows to exactly one action name.
pub fn list(pool: *PgPool, allocator: std.mem.Allocator, before_id: ?i64, action_filter: ?[]const u8, limit: i64) ![]Entry {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, account_id, identity_id, action, target, detail::text, EXTRACT(EPOCH FROM at)::bigint
        \\FROM audit_log
        \\WHERE ($1::bigint IS NULL OR id < $1)
        \\  AND ($2::text IS NULL OR action = $2)
        \\ORDER BY id DESC
        \\LIMIT $3;
    );
    defer stmt.finalize();
    if (before_id) |id| stmt.bindInt64(1, id) else stmt.bindNull(1);
    if (action_filter) |af| stmt.bindText(2, af) else stmt.bindNull(2);
    stmt.bindInt64(3, limit);

    var out: std.ArrayList(Entry) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .account_id = if (stmt.columnIsNull(1)) null else stmt.columnInt64(1),
            .identity_id = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2),
            .action = try allocator.dupe(u8, stmt.columnText(3)),
            .target = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
            .detail = if (stmt.columnIsNull(5)) null else try allocator.dupe(u8, stmt.columnText(5)),
            .at = stmt.columnInt64(6),
        });
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");
const accounts = @import("accounts.zig");

test "record writes a row that list() can read back, newest first" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    const account_id = try accounts.create(&pool, identity_id, "Owner", null);

    record(&pool, account_id, null, "module.disable", "reminders", "{\"reason\":\"test\"}");
    record(&pool, account_id, null, "config.set", "WARDEN_DIGEST_INTERVAL_SECONDS", null);

    const entries = try list(&pool, a, null, null, 10);
    defer {
        for (entries) |e| {
            a.free(e.action);
            if (e.target) |t| a.free(t);
            if (e.detail) |d| a.free(d);
        }
        a.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
    // Newest first.
    try testing.expectEqualStrings("config.set", entries[0].action);
    try testing.expectEqualStrings("module.disable", entries[1].action);
    try testing.expectEqual(account_id, entries[1].account_id.?);
    try testing.expectEqualStrings("reminders", entries[1].target.?);
}

test "list filters by action and paginates via before_id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    record(&pool, null, null, "a", null, null);
    record(&pool, null, null, "b", null, null);
    record(&pool, null, null, "a", null, null);

    const only_a = try list(&pool, a, null, "a", 10);
    defer {
        for (only_a) |e| {
            a.free(e.action);
        }
        a.free(only_a);
    }
    try testing.expectEqual(@as(usize, 2), only_a.len);

    const all_desc = try list(&pool, a, null, null, 10);
    defer {
        for (all_desc) |e| a.free(e.action);
        a.free(all_desc);
    }
    try testing.expectEqual(@as(usize, 3), all_desc.len);

    const next_page = try list(&pool, a, all_desc[0].id, null, 10);
    defer {
        for (next_page) |e| a.free(e.action);
        a.free(next_page);
    }
    try testing.expectEqual(@as(usize, 2), next_page.len);
}

test "record accepts an identity_id actor independently of account_id, for chat-originated entries" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "mod", null, false, 1000);
    record(&pool, null, identity_id, "chat.action.mute", "spammer", null);

    const entries = try list(&pool, a, null, null, 10);
    defer {
        for (entries) |e| {
            a.free(e.action);
            if (e.target) |t| a.free(t);
        }
        a.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(?i64, null), entries[0].account_id);
    try testing.expectEqual(identity_id, entries[0].identity_id.?);
}
