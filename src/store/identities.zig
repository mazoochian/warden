const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Identity = @import("../domain/identity.zig").Identity;
const TelegramProfile = @import("../domain/telegram_profile.zig").TelegramProfile;

/// Upserts the platform-neutral ancestor identity row (see `Identity`'s doc
/// comment) and returns its internal `identities.id` — the FK every other
/// store module (chats, chat_members, messages) keys on, replacing the old
/// per-chat-file `users` table's raw `user_id` string.
pub fn upsertIdentity(pool: *PgPool, identity: Identity) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);
    return upsertIdentityDb(db, identity);
}

fn upsertIdentityDb(db: *Db, identity: Identity) !i64 {
    var stmt = try db.prepare(
        \\INSERT INTO identities (platform, native_id, display_name, username, is_bot, first_seen, last_seen)
        \\VALUES ($1, $2, $3, $4, $5, to_timestamp($6), to_timestamp($7))
        \\ON CONFLICT (platform, native_id) DO UPDATE SET
        \\  display_name = excluded.display_name,
        \\  username = excluded.username,
        \\  is_bot = excluded.is_bot,
        \\  last_seen = excluded.last_seen
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(identity.platform));
    stmt.bindText(2, identity.native_id);
    stmt.bindText(3, identity.display_name);
    if (identity.username) |u| stmt.bindText(4, u) else stmt.bindNull(4);
    stmt.bindBool(5, identity.is_bot);
    stmt.bindInt64(6, identity.first_seen);
    stmt.bindInt64(7, identity.last_seen);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Upserts a Telegram-specific profile extension for an already-upserted
/// identity (see `TelegramProfile`'s doc comment).
pub fn upsertTelegramProfile(pool: *PgPool, identity_id: i64, profile: TelegramProfile) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO telegram_profiles (identity_id, first_name, last_name, language_code, is_premium, added_to_attachment_menu, can_join_groups, can_read_all_group_messages, supports_inline_queries)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        \\ON CONFLICT (identity_id) DO UPDATE SET
        \\  first_name = excluded.first_name,
        \\  last_name = excluded.last_name,
        \\  language_code = excluded.language_code,
        \\  is_premium = excluded.is_premium,
        \\  added_to_attachment_menu = excluded.added_to_attachment_menu,
        \\  can_join_groups = excluded.can_join_groups,
        \\  can_read_all_group_messages = excluded.can_read_all_group_messages,
        \\  supports_inline_queries = excluded.supports_inline_queries;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindText(2, profile.first_name);
    if (profile.last_name) |s| stmt.bindText(3, s) else stmt.bindNull(3);
    if (profile.language_code) |s| stmt.bindText(4, s) else stmt.bindNull(4);
    stmt.bindBool(5, profile.is_premium);
    stmt.bindBool(6, profile.added_to_attachment_menu);
    if (profile.can_join_groups) |v| stmt.bindBool(7, v) else stmt.bindNull(7);
    if (profile.can_read_all_group_messages) |v| stmt.bindBool(8, v) else stmt.bindNull(8);
    if (profile.supports_inline_queries) |v| stmt.bindBool(9, v) else stmt.bindNull(9);
    _ = try stmt.step();
}

/// Convenience for the common case: upserts both the ancestor identity and
/// its Telegram-specific extension together, returning the identity id.
pub fn upsertTelegramUser(pool: *PgPool, profile: TelegramProfile) !i64 {
    const identity_id = try upsertIdentity(pool, profile.identity);
    try upsertTelegramProfile(pool, identity_id, profile);
    return identity_id;
}

const Platform = @import("../platform/interface.zig").Platform;

/// Resolves an identity by (platform, native_id), creating a minimal
/// placeholder row if none exists yet — used when a command targets a user
/// by id alone (e.g. replying to ban/kick/token, or the bot resolving its
/// own identity to log its own replies) without a full `Identity` already
/// in hand. Unlike `upsertIdentity`, never overwrites an existing row's
/// fields (the `DO UPDATE SET native_id = excluded.native_id` is a no-op
/// update purely so `RETURNING` still works on conflict — Postgres's `DO
/// NOTHING` doesn't return the pre-existing row) — `is_bot` therefore only
/// takes effect the first time a given (platform, native_id) is seen.
pub fn getOrCreateMinimal(pool: *PgPool, platform: Platform, native_id: []const u8, fallback_display_name: []const u8, is_bot: bool, now: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO identities (platform, native_id, display_name, is_bot, first_seen, last_seen)
        \\VALUES ($1, $2, $3, $4, to_timestamp($5), to_timestamp($5))
        \\ON CONFLICT (platform, native_id) DO UPDATE SET native_id = excluded.native_id
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, native_id);
    stmt.bindText(3, fallback_display_name);
    stmt.bindBool(4, is_bot);
    stmt.bindInt64(5, now);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "upsertIdentity inserts then updates on conflict" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();

    const id1 = try upsertIdentityDb(&db, .{
        .platform = .telegram,
        .native_id = "42",
        .display_name = "Alice",
        .username = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    const id2 = try upsertIdentityDb(&db, .{
        .platform = .telegram,
        .native_id = "42",
        .display_name = "Alice Smith",
        .username = "alice2",
        .first_seen = 1000,
        .last_seen = 2000,
    });

    try testing.expectEqual(id1, id2);

    var stmt = try db.prepare("SELECT display_name, username FROM identities WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id1);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("Alice Smith", stmt.columnText(0));
    try testing.expectEqualStrings("alice2", stmt.columnText(1));
}

test "upsertTelegramUser writes both identities and telegram_profiles rows" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();

    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const identity_id = try upsertTelegramUser(&pool, .{
        .identity = .{
            .platform = .telegram,
            .native_id = "42",
            .display_name = "Alice",
            .username = "alice",
            .first_seen = 1000,
            .last_seen = 1000,
        },
        .first_name = "Alice",
        .is_premium = true,
        .language_code = "en",
    });

    var stmt = try db.prepare("SELECT first_name, is_premium, language_code FROM telegram_profiles WHERE identity_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("Alice", stmt.columnText(0));
    try testing.expect(stmt.columnBool(1));
    try testing.expectEqualStrings("en", stmt.columnText(2));
}

test "getOrCreateMinimal creates a placeholder once, then resolves without overwriting" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id1 = try getOrCreateMinimal(&pool, .telegram, "99", "spammer", false, 1000);

    // A real message from this user later fills in the full profile...
    _ = try upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "99",
        .display_name = "Real Name",
        .username = "realuser",
        .first_seen = 1000,
        .last_seen = 2000,
    });

    // ...and resolving the placeholder again afterward must not stomp it.
    const id2 = try getOrCreateMinimal(&pool, .telegram, "99", "spammer", false, 3000);
    try testing.expectEqual(id1, id2);

    var stmt = try db.prepare("SELECT display_name FROM identities WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id1);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("Real Name", stmt.columnText(0));
}

test "getOrCreateMinimal persists is_bot on first creation" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const bot_id = try getOrCreateMinimal(&pool, .telegram, "1", "warden", true, 1000);
    const human_id = try getOrCreateMinimal(&pool, .telegram, "2", "alice", false, 1000);

    var stmt = try db.prepare("SELECT is_bot FROM identities WHERE id = $1;");
    defer stmt.finalize();

    stmt.bindInt64(1, bot_id);
    try testing.expect(try stmt.step());
    try testing.expect(stmt.columnBool(0));

    var stmt2 = try db.prepare("SELECT is_bot FROM identities WHERE id = $1;");
    defer stmt2.finalize();
    stmt2.bindInt64(1, human_id);
    try testing.expect(try stmt2.step());
    try testing.expect(!stmt2.columnBool(0));
}
