const std = @import("std");
const Db = @import("db.zig").Db;
const migrate = @import("migrate.zig").migrate;

/// Opens a connection to the test Postgres instance named by
/// `WARDEN_TEST_POSTGRES_DSN`, migrates it, and truncates every table.
pub fn openTestDb(allocator: std.mem.Allocator) !?Db {
    const dsn_z = std.c.getenv("WARDEN_TEST_POSTGRES_DSN") orelse return null;
    var db = try Db.open(allocator, std.testing.io, std.mem.span(dsn_z), 30);
    try migrate(&db, allocator);
    try truncateAll(&db);
    return db;
}

fn truncateAll(db: *Db) !void {
    try db.exec(
        \\TRUNCATE TABLE messages, chat_members, telegram_profiles, matrix_profiles,
        \\  xmpp_profiles, chat_settings, chats, identities, bot_config,
        \\  crypto_account, crypto_sessions, crypto_megolm_outbound, crypto_megolm_inbound,
        \\  bot_admins, bot_blocked_users, bot_blocked_chats, bot_pending_grants,
        \\  accounts, oauth_providers, management_room_bindings, notes,
        \\  facts, fact_tombstones, daily_digests, period_rollups, retrieval_log,
        \\  instagram_sessions, instagram_thread_watermarks, reply_drafts, feed_sources,
        \\  feed_settings
        \\  RESTART IDENTITY CASCADE;
    );
    // `feed_settings` holds a single seeded row (id = 1) rather than a row per
    // anything, so truncating it alone doesn't restore the post-migration state.
    try db.exec("INSERT INTO feed_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;");
}
