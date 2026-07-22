const std = @import("std");
const Db = @import("db.zig").Db;
const migrate = @import("migrate.zig").migrate;

/// Opens a connection to the test Postgres instance named by
/// `WARDEN_TEST_POSTGRES_DSN`, migrates it, and truncates every table —
/// or returns `null` if that env var isn't set, so store-layer tests can
/// skip (not fail) when a contributor doesn't have a local Postgres
/// running. Unlike the old SQLite tests (a throwaway file per test), tests
/// share one real database and rely on `truncateAll` for isolation.
pub fn openTestDb(allocator: std.mem.Allocator) !?Db {
    const dsn_z = std.c.getenv("WARDEN_TEST_POSTGRES_DSN") orelse return null;
    var db = try Db.open(allocator, std.mem.span(dsn_z), 30);
    try migrate(&db, allocator);
    try truncateAll(&db);
    return db;
}

fn truncateAll(db: *Db) !void {
    try db.exec(
        \\TRUNCATE TABLE messages, chat_members, telegram_profiles, matrix_profiles,
        \\  xmpp_profiles, chat_settings, chats, identities, bot_config,
        \\  crypto_account, crypto_sessions, crypto_megolm_outbound, crypto_megolm_inbound
        \\  RESTART IDENTITY CASCADE;
    );
}
