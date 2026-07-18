const std = @import("std");
const Db = @import("db.zig").Db;

const Migration = struct {
    version: i64,
    name: []const u8,
    sql: [:0]const u8,
};

/// Ordered, one-way schema migrations — a real replacement for the old
/// `schema.zig`'s idempotent `CREATE TABLE IF NOT EXISTS` (which doubled as
/// "the migration system" back when every chat had its own SQLite file).
/// Add new entries here, never edit an already-shipped one.
const migrations = [_]Migration{
    .{ .version = 1, .name = "0001_init", .sql = @embedFile("migrations/0001_init.sql") },
    .{ .version = 2, .name = "0002_reminders", .sql = @embedFile("migrations/0002_reminders.sql") },
    .{ .version = 3, .name = "0003_reminders_recurrence", .sql = @embedFile("migrations/0003_reminders_recurrence.sql") },
    .{ .version = 4, .name = "0004_alerts", .sql = @embedFile("migrations/0004_alerts.sql") },
    .{ .version = 5, .name = "0005_feed_watches", .sql = @embedFile("migrations/0005_feed_watches.sql") },
};

/// Applies every migration not yet recorded in `schema_migrations`, each
/// wrapped (migration body + its own version-recording INSERT) in a single
/// transaction so a mid-migration failure can never leave a schema change
/// applied without being recorded (which would otherwise make it get
/// re-applied, and fail, on the next start).
pub fn migrate(db: *Db, allocator: std.mem.Allocator) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version BIGINT PRIMARY KEY,
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
        \\);
    );

    for (migrations) |m| {
        if (try isApplied(db, m.version)) continue;

        std.log.info("applying migration {d} ({s})", .{ m.version, m.name });
        const combined = try std.fmt.allocPrintSentinel(
            allocator,
            "BEGIN;\n{s}\nINSERT INTO schema_migrations (version) VALUES ({d});\nCOMMIT;\n",
            .{ m.sql, m.version },
            0,
        );
        defer allocator.free(combined);
        try db.exec(combined);
    }
}

fn isApplied(db: *Db, version: i64) !bool {
    var stmt = try db.prepare("SELECT 1 FROM schema_migrations WHERE version = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, version);
    return try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "migrate creates every table and is idempotent on a second run" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();

    // test_support.openTestDb already ran migrate() once; running it again
    // here must be a no-op (already-applied versions are skipped), not an
    // error from re-creating existing tables.
    try migrate(&db, testing.allocator);

    var stmt = try db.prepare("SELECT count(*) FROM identities;");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
}
