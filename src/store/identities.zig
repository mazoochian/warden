const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Identity = @import("../domain/identity.zig").Identity;
const TelegramProfile = @import("../domain/telegram_profile.zig").TelegramProfile;
const MatrixProfile = @import("../domain/matrix_profile.zig").MatrixProfile;
const XmppProfile = @import("../domain/xmpp_profile.zig").XmppProfile;

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

/// Upserts a Matrix-specific profile extension for an already-upserted
/// identity (see `MatrixProfile`'s doc comment).
pub fn upsertMatrixProfile(pool: *PgPool, identity_id: i64, profile: MatrixProfile) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO matrix_profiles (identity_id, homeserver, avatar_url)
        \\VALUES ($1, $2, $3)
        \\ON CONFLICT (identity_id) DO UPDATE SET
        \\  homeserver = excluded.homeserver,
        \\  avatar_url = excluded.avatar_url;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindText(2, profile.homeserver);
    if (profile.avatar_url) |s| stmt.bindText(3, s) else stmt.bindNull(3);
    _ = try stmt.step();
}

/// Upserts an XMPP-specific profile extension for an already-upserted
/// identity (see `XmppProfile`'s doc comment).
pub fn upsertXmppProfile(pool: *PgPool, identity_id: i64, profile: XmppProfile) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO xmpp_profiles (identity_id, jid_resource)
        \\VALUES ($1, $2)
        \\ON CONFLICT (identity_id) DO UPDATE SET
        \\  jid_resource = excluded.jid_resource;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    if (profile.jid_resource) |s| stmt.bindText(2, s) else stmt.bindNull(2);
    _ = try stmt.step();
}

const Platform = @import("../platform/interface.zig").Platform;

/// Resolves an identity by (platform, native_id), creating a minimal
/// placeholder row if none exists yet — used when a command targets a user
/// by id alone (e.g. replying to ban/kick/token, or the bot resolving its
/// own identity to log its own replies) without a full `Identity` already
/// in hand. Unlike `upsertIdentity`, never overwrites an existing row's
/// `display_name`/`is_bot` (`is_bot` therefore only takes effect the first
/// time a given (platform, native_id) is seen) — but `username` IS
/// backfilled on conflict when the existing row doesn't have one yet
/// (`COALESCE(identities.username, excluded.username)`), never overwriting
/// a real value that's already there. Without this backfill, an identity
/// first created through a reply-based command (which only ever has the
/// target's native id in hand, not necessarily their username) could never
/// be resolved by `@username` afterward even once a caller *did* supply
/// one — confirmed live: `/adduser` via reply on a never-before-seen user,
/// then `/adduser @username`/`/removeuser @username` on that same person,
/// failed every time because the first call's row had `username = NULL`
/// and nothing ever went back to fill it in.
pub fn getOrCreateMinimal(pool: *PgPool, platform: Platform, native_id: []const u8, fallback_display_name: []const u8, username: ?[]const u8, is_bot: bool, now: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO identities (platform, native_id, display_name, username, is_bot, first_seen, last_seen)
        \\VALUES ($1, $2, $3, $4, $5, to_timestamp($6), to_timestamp($6))
        \\ON CONFLICT (platform, native_id) DO UPDATE SET
        \\  username = COALESCE(identities.username, excluded.username)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, native_id);
    stmt.bindText(3, fallback_display_name);
    if (username) |u| stmt.bindText(4, u) else stmt.bindNull(4);
    stmt.bindBool(5, is_bot);
    stmt.bindInt64(6, now);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

pub const IdentityRef = struct {
    id: i64,
    display_name: []const u8,
    native_id: []const u8,
};

/// Exact-match (case-insensitive) username lookup, scoped to `platform` —
/// usernames aren't guaranteed unique across platforms, so a bare username
/// alone isn't enough to resolve an identity. Backs `@username` targeting
/// for `/token`, `/credit`, `/adduser`, `/removeuser`, `/addadmin`,
/// `/removeadmin` — the leading `@` is stripped by the caller (command-
/// argument-parsing concern, not a store concern), same shape as
/// `handleToken`'s own arg trimming. Unlike `chat_members.search`, this is
/// NOT fuzzy and NOT chat-scoped: those commands act bot-wide (bot admin
/// grants, global credits) or need a specific single target, not a list of
/// candidates. Bot accounts are excluded, matching `chat_members.search`.
/// `null` when no identity on this platform has that username.
pub fn findByUsername(pool: *PgPool, allocator: std.mem.Allocator, platform: Platform, username: []const u8) !?IdentityRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, display_name, native_id FROM identities
        \\WHERE platform = $1 AND NOT is_bot AND lower(username) = lower($2)
        \\LIMIT 1;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, username);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .display_name = try allocator.dupe(u8, stmt.columnText(1)),
        .native_id = try allocator.dupe(u8, stmt.columnText(2)),
    };
}

/// Exact lookup by (platform, native_id) — unlike `getOrCreateMinimal`,
/// never creates a placeholder row. Backs read-only by-id lookups (e.g.
/// `/whois`, and `resolveTargetIdentity`'s non-mutating callers) where
/// fabricating a row for an id the bot has genuinely never seen would be a
/// surprising side effect for what's meant to be a plain info command.
/// `null` when no identity on this platform has that native id.
pub fn findByNativeId(pool: *PgPool, allocator: std.mem.Allocator, platform: Platform, native_id: []const u8) !?IdentityRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, display_name, native_id FROM identities
        \\WHERE platform = $1 AND native_id = $2
        \\LIMIT 1;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, native_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .display_name = try allocator.dupe(u8, stmt.columnText(1)),
        .native_id = try allocator.dupe(u8, stmt.columnText(2)),
    };
}

pub const WhoisInfo = struct {
    platform: Platform,
    native_id: []const u8,
    display_name: []const u8,
    username: ?[]const u8,
    is_bot: bool,
};

/// Full identity row by internal id — backs `/whois`, which needs every
/// shared field (unlike `IdentityRef`'s minimal id/display_name/native_id,
/// enough for targeting but not for a full profile view). `null` if `id`
/// doesn't exist (shouldn't happen in practice: callers only ever have an
/// `id` in hand via a prior successful lookup).
pub fn getWhoisInfo(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?WhoisInfo {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT platform, native_id, display_name, username, is_bot FROM identities WHERE id = $1;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(0)) orelse .telegram,
        .native_id = try allocator.dupe(u8, stmt.columnText(1)),
        .display_name = try allocator.dupe(u8, stmt.columnText(2)),
        .username = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
        .is_bot = stmt.columnBool(4),
    };
}

/// Global (not per-chat, unlike `chat_members.tokens`) LLM credit balance —
/// see `0012_identities_credits.sql`. `default` is only returned on a
/// pool/query error (an `identities` row is always guaranteed to exist by
/// the time any handler calls this — `resolveSenderIdentity` runs before
/// `handleMessage` for every message), matching `chat_members.getTokens`'s
/// shape.
pub fn getCredits(pool: *PgPool, identity_id: i64, default: i64) i64 {
    const db = pool.acquire() catch return default;
    defer pool.release(db);

    var stmt = db.prepare("SELECT credits FROM identities WHERE id = $1;") catch return default;
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    const has_row = stmt.step() catch return default;
    if (!has_row) return default;
    return stmt.columnInt64(0);
}

/// Plain `UPDATE`, not an upsert like `chat_members.setTokens` — an
/// `identities` row is always guaranteed to exist already (see
/// `getCredits`'s doc comment).
pub fn setCredits(pool: *PgPool, identity_id: i64, value: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE identities SET credits = $2 WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindInt64(2, value);
    _ = try stmt.step();
}

/// Atomically decrements `credits` by 1 iff it's currently positive —
/// unlike the pre-existing token spend (`chat_members.getTokens` then
/// `setTokens`, a non-atomic read-modify-write with a real TOCTOU race
/// under concurrent per-message tasks), this is a single conditional
/// `UPDATE ... RETURNING`, so two concurrent spends against a balance of 1
/// can't both succeed. Returns `true` if a credit was spent, `false` if the
/// balance was already 0 (or on any pool/query error — fails closed, so a
/// DB hiccup denies a free LLM answer rather than granting one).
pub fn spendCredit(pool: *PgPool, identity_id: i64) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\UPDATE identities SET credits = credits - 1
        \\WHERE id = $1 AND credits > 0
        \\RETURNING credits;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    return try stmt.step();
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

test "upsertMatrixProfile writes a matrix_profiles row keyed by identity_id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();

    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const identity_id = try upsertIdentity(&pool, .{
        .platform = .matrix,
        .native_id = "@alice:example.org",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    try upsertMatrixProfile(&pool, identity_id, .{
        .identity = .{
            .platform = .matrix,
            .native_id = "@alice:example.org",
            .display_name = "Alice",
            .first_seen = 1000,
            .last_seen = 1000,
        },
        .homeserver = "https://example.org",
        .avatar_url = "mxc://example.org/abc",
    });

    var stmt = try db.prepare("SELECT homeserver, avatar_url FROM matrix_profiles WHERE identity_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("https://example.org", stmt.columnText(0));
    try testing.expectEqualStrings("mxc://example.org/abc", stmt.columnText(1));
}

test "upsertXmppProfile writes an xmpp_profiles row keyed by identity_id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();

    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const identity_id = try upsertIdentity(&pool, .{
        .platform = .xmpp,
        .native_id = "alice@example.org",
        .display_name = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    try upsertXmppProfile(&pool, identity_id, .{
        .identity = .{
            .platform = .xmpp,
            .native_id = "alice@example.org",
            .display_name = "alice",
            .first_seen = 1000,
            .last_seen = 1000,
        },
        .jid_resource = "phone",
    });

    var stmt = try db.prepare("SELECT jid_resource FROM xmpp_profiles WHERE identity_id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("phone", stmt.columnText(0));
}

test "getOrCreateMinimal creates a placeholder once, then resolves without overwriting" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id1 = try getOrCreateMinimal(&pool, .telegram, "99", "spammer", null, false, 1000);

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
    const id2 = try getOrCreateMinimal(&pool, .telegram, "99", "spammer", null, false, 3000);
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

    const bot_id = try getOrCreateMinimal(&pool, .telegram, "1", "warden", null, true, 1000);
    const human_id = try getOrCreateMinimal(&pool, .telegram, "2", "alice", null, false, 1000);

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

test "getOrCreateMinimal persists username on first creation, and backfills it later if it was never set" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Username supplied on first creation is persisted immediately.
    const id1 = try getOrCreateMinimal(&pool, .telegram, "1", "Alice", "alice_tg", false, 1000);
    const found1 = (try findByUsername(&pool, a, .telegram, "alice_tg")).?;
    try testing.expectEqual(id1, found1.id);

    // A reply-based command that only has a native id in hand (e.g. Telegram
    // didn't surface a username for that reply) creates the row with no
    // username at all — this is the exact shape that broke `@username`
    // resolution for anyone first seen this way.
    const id2 = try getOrCreateMinimal(&pool, .telegram, "2", "Bob", null, false, 1000);
    try testing.expect(try findByUsername(&pool, a, .telegram, "bob_tg") == null);

    // The same person is resolved again later, this time with their real
    // username in hand (e.g. they were `@username`-targeted, or replied to
    // again with Telegram now supplying it) — must backfill, not silently
    // stay unresolvable forever.
    const id2_again = try getOrCreateMinimal(&pool, .telegram, "2", "Bob", "bob_tg", false, 2000);
    try testing.expectEqual(id2, id2_again);
    const found2 = (try findByUsername(&pool, a, .telegram, "bob_tg")).?;
    try testing.expectEqual(id2, found2.id);

    // But a real, already-set username must never be clobbered by a later
    // call passing a different (or no) one.
    const id1_again = try getOrCreateMinimal(&pool, .telegram, "1", "Alice", "someone_elses_new_handle", false, 3000);
    try testing.expectEqual(id1, id1_again);
    try testing.expect((try findByUsername(&pool, a, .telegram, "alice_tg")) != null);
    try testing.expect((try findByUsername(&pool, a, .telegram, "someone_elses_new_handle")) == null);
}

test "findByUsername matches case-insensitively, is platform-scoped, and excludes bots" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tg_alice = try upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .username = "Alice_TG",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    // Same username, different platform — must not resolve here.
    _ = try upsertIdentity(&pool, .{
        .platform = .matrix,
        .native_id = "@alice:example.org",
        .display_name = "Alice (Matrix)",
        .username = "Alice_TG",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    _ = try upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "3",
        .display_name = "Some Bot",
        .username = "alice_tg_bot",
        .is_bot = true,
        .first_seen = 1000,
        .last_seen = 1000,
    });

    const found = (try findByUsername(&pool, a, .telegram, "alice_tg")).?;
    try testing.expectEqual(tg_alice, found.id);
    try testing.expectEqualStrings("Alice", found.display_name);

    try testing.expect(try findByUsername(&pool, a, .xmpp, "alice_tg") == null);
    try testing.expect(try findByUsername(&pool, a, .telegram, "no_such_user") == null);
}

test "findByNativeId matches exactly, is platform-scoped, and never creates a row" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const alice = try getOrCreateMinimal(&pool, .telegram, "42", "Alice", null, false, 1000);

    const found = (try findByNativeId(&pool, a, .telegram, "42")).?;
    try testing.expectEqual(alice, found.id);
    try testing.expectEqualStrings("Alice", found.display_name);

    // Different platform, same native id string — must not match.
    try testing.expect(try findByNativeId(&pool, a, .matrix, "42") == null);
    // Never seen at all — null, and (implicitly, since a second lookup below
    // still finds nothing) no row was created as a side effect.
    try testing.expect(try findByNativeId(&pool, a, .telegram, "99999") == null);
    try testing.expect(try findByNativeId(&pool, a, .telegram, "99999") == null);
}

test "getWhoisInfo returns every shared field, including a null username" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bot_id = try getOrCreateMinimal(&pool, .telegram, "1", "SomeBot", "some_bot", true, 1000);
    const human_id = try getOrCreateMinimal(&pool, .telegram, "2", "Bob", null, false, 1000);

    const bot_info = (try getWhoisInfo(&pool, a, bot_id)).?;
    try testing.expectEqual(Platform.telegram, bot_info.platform);
    try testing.expectEqualStrings("1", bot_info.native_id);
    try testing.expectEqualStrings("SomeBot", bot_info.display_name);
    try testing.expectEqualStrings("some_bot", bot_info.username.?);
    try testing.expect(bot_info.is_bot);

    const human_info = (try getWhoisInfo(&pool, a, human_id)).?;
    try testing.expectEqual(@as(?[]const u8, null), human_info.username);
    try testing.expect(!human_info.is_bot);
}

test "getCredits/setCredits/spendCredit round-trip and spendCredit fails at zero without going negative" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id = try getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try testing.expectEqual(@as(i64, 0), getCredits(&pool, id, 0));

    try setCredits(&pool, id, 2);
    try testing.expectEqual(@as(i64, 2), getCredits(&pool, id, 0));

    try testing.expect(try spendCredit(&pool, id));
    try testing.expectEqual(@as(i64, 1), getCredits(&pool, id, 0));

    try testing.expect(try spendCredit(&pool, id));
    try testing.expectEqual(@as(i64, 0), getCredits(&pool, id, 0));

    // Balance is now 0 — spending again must fail, not go negative.
    try testing.expect(!try spendCredit(&pool, id));
    try testing.expectEqual(@as(i64, 0), getCredits(&pool, id, 0));
}
