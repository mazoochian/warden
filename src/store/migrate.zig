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
    .{ .version = 6, .name = "0006_persona", .sql = @embedFile("migrations/0006_persona.sql") },
    .{ .version = 7, .name = "0007_show_thinking", .sql = @embedFile("migrations/0007_show_thinking.sql") },
    .{ .version = 8, .name = "0008_matrix_crypto", .sql = @embedFile("migrations/0008_matrix_crypto.sql") },
    .{ .version = 9, .name = "0009_feed_watches_seen_guids", .sql = @embedFile("migrations/0009_feed_watches_seen_guids.sql") },
    .{ .version = 10, .name = "0010_bot_admins", .sql = @embedFile("migrations/0010_bot_admins.sql") },
    .{ .version = 11, .name = "0011_bot_allowlist", .sql = @embedFile("migrations/0011_bot_allowlist.sql") },
    .{ .version = 12, .name = "0012_identities_credits", .sql = @embedFile("migrations/0012_identities_credits.sql") },
    .{ .version = 13, .name = "0013_identities_username_lookup_index", .sql = @embedFile("migrations/0013_identities_username_lookup_index.sql") },
    .{ .version = 14, .name = "0014_bot_pending_grants", .sql = @embedFile("migrations/0014_bot_pending_grants.sql") },
    .{ .version = 15, .name = "0015_user_settings", .sql = @embedFile("migrations/0015_user_settings.sql") },
    .{ .version = 16, .name = "0016_web_accounts", .sql = @embedFile("migrations/0016_web_accounts.sql") },
    .{ .version = 17, .name = "0017_web_sessions", .sql = @embedFile("migrations/0017_web_sessions.sql") },
    .{ .version = 18, .name = "0018_oauth_providers", .sql = @embedFile("migrations/0018_oauth_providers.sql") },
    .{ .version = 19, .name = "0019_feature_flags", .sql = @embedFile("migrations/0019_feature_flags.sql") },
    .{ .version = 20, .name = "0020_dynamic_config", .sql = @embedFile("migrations/0020_dynamic_config.sql") },
    .{ .version = 21, .name = "0021_audit_log", .sql = @embedFile("migrations/0021_audit_log.sql") },
    .{ .version = 22, .name = "0022_chats_left_at", .sql = @embedFile("migrations/0022_chats_left_at.sql") },
    .{ .version = 23, .name = "0023_management_rooms", .sql = @embedFile("migrations/0023_management_rooms.sql") },
    .{ .version = 24, .name = "0024_notes", .sql = @embedFile("migrations/0024_notes.sql") },
    .{ .version = 25, .name = "0025_memories", .sql = @embedFile("migrations/0025_memories.sql") },
    .{ .version = 26, .name = "0026_briefings", .sql = @embedFile("migrations/0026_briefings.sql") },
    .{ .version = 27, .name = "0027_keyword_alerts", .sql = @embedFile("migrations/0027_keyword_alerts.sql") },
    .{ .version = 28, .name = "0028_welcome_message", .sql = @embedFile("migrations/0028_welcome_message.sql") },
    .{ .version = 29, .name = "0029_expenses", .sql = @embedFile("migrations/0029_expenses.sql") },
    .{ .version = 30, .name = "0030_budgets", .sql = @embedFile("migrations/0030_budgets.sql") },
    .{ .version = 31, .name = "0031_subscriptions", .sql = @embedFile("migrations/0031_subscriptions.sql") },
    .{ .version = 32, .name = "0032_command_aliases", .sql = @embedFile("migrations/0032_command_aliases.sql") },
    .{ .version = 33, .name = "0033_prompt_templates", .sql = @embedFile("migrations/0033_prompt_templates.sql") },
    .{ .version = 34, .name = "0034_default_location", .sql = @embedFile("migrations/0034_default_location.sql") },
    .{ .version = 35, .name = "0035_announcements", .sql = @embedFile("migrations/0035_announcements.sql") },
    .{ .version = 36, .name = "0036_autopin_announcements", .sql = @embedFile("migrations/0036_autopin_announcements.sql") },
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
