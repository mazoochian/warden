const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Bot-wide module enable/disable — see
/// /home/armin/claude/warden-ui/ARCHITECTURE.md §5 for the split between
/// "standalone command features" (checked directly in `main.zig`'s
/// dispatch) and "LLM-tool-shaped features" (filtered out of
/// `tools/registry.zig`'s list instead), and §4/the `0019_feature_flags`
/// migration's comment for why there are deliberately no seed rows: a
/// missing row means enabled, checked here rather than via migration-time
/// data, so a test's `TRUNCATE ... CASCADE` can never permanently erase
/// "every module starts on."
///
/// Fails open (`true`) on any pool/query error — a DB hiccup should never
/// look like every module got disabled at once; that would be a far
/// louder failure mode than a stale "enabled" reading for one request.
pub fn isEnabled(pool: *PgPool, module: []const u8) bool {
    const db = pool.acquire() catch return true;
    defer pool.release(db);

    var stmt = db.prepare("SELECT enabled FROM feature_flags WHERE module = $1;") catch return true;
    defer stmt.finalize();
    stmt.bindText(1, module);
    const has_row = stmt.step() catch return true;
    if (!has_row) return true;
    return stmt.columnBool(0);
}

pub fn setEnabled(pool: *PgPool, module: []const u8, enabled: bool, updated_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO feature_flags (module, enabled, updated_by) VALUES ($1, $2, $3)
        \\ON CONFLICT (module) DO UPDATE SET
        \\  enabled = excluded.enabled, updated_at = now(), updated_by = excluded.updated_by;
    );
    defer stmt.finalize();
    stmt.bindText(1, module);
    stmt.bindBool(2, enabled);
    stmt.bindInt64(3, updated_by);
    _ = try stmt.step();
}

pub const Flag = struct {
    module: []const u8,
    enabled: bool,
};

/// Every module that has ever had an explicit row written — a module
/// never touched from the panel simply won't appear here (it's enabled by
/// default, per `isEnabled`'s doc comment), so the caller building the
/// modules page must union this against its own comptime list of known
/// module names to render a complete on/off list.
pub fn listExplicit(pool: *PgPool, allocator: std.mem.Allocator) ![]Flag {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT module, enabled FROM feature_flags;");
    defer stmt.finalize();

    var out: std.ArrayList(Flag) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .module = try allocator.dupe(u8, stmt.columnText(0)),
            .enabled = stmt.columnBool(1),
        });
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

test "isEnabled defaults true for a module with no row, and reflects setEnabled after" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expect(isEnabled(&pool, "reminders"));

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try setEnabled(&pool, "reminders", false, owner);
    try testing.expect(!isEnabled(&pool, "reminders"));

    try setEnabled(&pool, "reminders", true, owner);
    try testing.expect(isEnabled(&pool, "reminders"));
}

test "listExplicit only returns modules that have had an explicit row written" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    try testing.expectEqual(@as(usize, 0), (try listExplicit(&pool, a)).len);

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try setEnabled(&pool, "alerts", false, owner);

    const flags = try listExplicit(&pool, a);
    defer {
        for (flags) |f| a.free(f.module);
        a.free(flags);
    }
    try testing.expectEqual(@as(usize, 1), flags.len);
    try testing.expectEqualStrings("alerts", flags[0].module);
    try testing.expect(!flags[0].enabled);
}
