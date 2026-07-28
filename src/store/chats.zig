const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

/// Upserts a chat row (keyed by platform + native chat id) and returns its
/// internal `chats.id` — the FK `messages`/`chat_members`/`chat_settings`
/// key on, replacing the old "one SQLite file per chat" partitioning.
///
/// `chat_type`/`title` are `null` whenever the caller doesn't have fresh
/// metadata handy (e.g. resolving a chat by id alone for a scheduled
/// digest) — `COALESCE` keeps whatever was already stored in that case
/// rather than clobbering it with NULL.
///
/// Always clears `left_at` on conflict — this is called for every real
/// incoming message (see `main.zig`'s `processMessageTask`), so a chat the
/// bot was previously marked as having left (see `markLeft`) automatically
/// un-marks itself the moment the bot is re-added and a message arrives,
/// with no separate "rejoin" code path needed.
pub fn upsertChat(pool: *PgPool, platform: Platform, native_chat_id: []const u8, chat_type: ?[]const u8, title: ?[]const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chats (platform, native_chat_id, chat_type, title)
        \\VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (platform, native_chat_id) DO UPDATE SET
        \\  chat_type = COALESCE(excluded.chat_type, chats.chat_type),
        \\  title = COALESCE(excluded.title, chats.title),
        \\  left_at = NULL
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindText(1, @tagName(platform));
    stmt.bindText(2, native_chat_id);
    if (chat_type) |t| stmt.bindText(3, t) else stmt.bindNull(3);
    if (title) |t| stmt.bindText(4, t) else stmt.bindNull(4);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

pub const ChatRef = struct {
    id: i64,
    native_chat_id: []const u8,
    /// Which connector this chat belongs to — needed so a scheduled feature
    /// (digests, reminders) can find the right connector to deliver through
    /// once more than one platform is active, instead of assuming whichever
    /// connector happens to be polling matches every chat_id it sees.
    platform: Platform,
};

/// Single-chat lookup by internal id — `null` if it doesn't exist. Backs
/// the warden-ui API's per-chat settings endpoints (Phase 4), which
/// receive a chat by internal id from the URL and need its platform +
/// native id to run a live group-admin check via the matching connector.
pub fn getById(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) !?ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, native_chat_id, platform FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
    };
}

/// Marks a chat as no longer active — the bot left, was kicked, or the
/// chat was deleted (see `main.zig`'s `processMessageTask`, which calls
/// this on a synthetic `chat_left` message from a connector). Doesn't
/// delete anything itself; see `deleteLeftBefore` for the actual retention
/// sweep, and `upsertChat`'s doc comment for how this gets auto-cleared on
/// rejoin.
pub fn markLeft(pool: *PgPool, chat_id: i64, at: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE chats SET left_at = to_timestamp($2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, at);
    _ = try stmt.step();
}

/// In-place id rename for Telegram's basic-group -> supergroup upgrade
/// (see `platform/telegram.zig`'s handling of `migrate_to_chat_id`):
/// Telegram mints a brand-new chat id for the same real-world group, and
/// without this the old row would go stale while a second row got created
/// for the new id the moment the next message arrived — the actual cause
/// of "duplicate" chats, not title changes (which `upsertChat`'s
/// `ON CONFLICT` already handles correctly). Preserves the internal
/// `chats.id` (and therefore every FK'd row: messages, reminders, alerts,
/// settings, ...) under the new native id instead of losing history to a
/// fresh row.
///
/// If a row already exists under `new_native_id` (a rare race: another
/// worker-pool thread already processed a message addressed to the new id
/// before this rename ran — `chats`'s poll loop has no per-chat ordering
/// guarantee across workers), the `UNIQUE (platform, native_chat_id)`
/// constraint makes this fail; the caller logs and moves on rather than
/// attempting a full data merge, an accepted edge case for a
/// once-per-group-ever event.
pub fn renameNativeChatId(pool: *PgPool, chat_id: i64, new_native_id: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE chats SET native_chat_id = $2, left_at = NULL WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, new_native_id);
    _ = try stmt.step();
}

/// Hard-deletes every chat that's been left for longer than the retention
/// window — cascades to every FK'd table (`messages`, `chat_members`,
/// `reminders`, `alerts`, `feed_watches`, `chat_settings`,
/// `bot_allowlist`, all `ON DELETE CASCADE`). Returns the number of chats
/// purged, purely for logging (see `main.zig`'s `checkAndPurgeLeftChats`).
pub fn deleteLeftBefore(pool: *PgPool, cutoff: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM chats WHERE left_at IS NOT NULL AND left_at < to_timestamp($1) RETURNING id;");
    defer stmt.finalize();
    stmt.bindInt64(1, cutoff);

    var count: i64 = 0;
    while (try stmt.step()) count += 1;
    return count;
}

/// Lists every known, currently-active (not left) chat — replaces
/// `ChatStore.listExistingChatIds`'s directory scan (used at startup to
/// restore digest scheduling; no point reconnecting a digest loop for a
/// chat the bot isn't in anymore).
pub fn listAll(pool: *PgPool, allocator: std.mem.Allocator) ![]ChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, native_chat_id, platform FROM chats WHERE left_at IS NULL;");
    defer stmt.finalize();

    var out: std.ArrayList(ChatRef) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
        });
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "upsertChat inserts then updates on conflict, preserving fields when null is passed" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const id1 = try upsertChat(&pool, .telegram, "-100123", "supergroup", "My Group");
    const id2 = try upsertChat(&pool, .telegram, "-100123", null, null);
    try testing.expectEqual(id1, id2);

    var stmt = try db.prepare("SELECT chat_type, title FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id1);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("supergroup", stmt.columnText(0));
    try testing.expectEqualStrings("My Group", stmt.columnText(1));
}

test "listAll returns every active chat, excluding ones marked left" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    _ = try upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try upsertChat(&pool, .telegram, "2", null, null);
    try markLeft(&pool, chat2, 1000);

    const refs = try listAll(&pool, testing.allocator);
    defer {
        for (refs) |r| testing.allocator.free(r.native_chat_id);
        testing.allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("1", refs[0].native_chat_id);
}

test "markLeft sets left_at, upsertChat clears it again on rejoin" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try upsertChat(&pool, .telegram, "1", null, null);
    try markLeft(&pool, chat_id, 1000);

    var stmt = try db.prepare("SELECT left_at IS NOT NULL FROM chats WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    try testing.expect(try stmt.step());
    try testing.expect(stmt.columnBool(0));

    _ = try upsertChat(&pool, .telegram, "1", null, null);

    var stmt2 = try db.prepare("SELECT left_at IS NOT NULL FROM chats WHERE id = $1;");
    defer stmt2.finalize();
    stmt2.bindInt64(1, chat_id);
    try testing.expect(try stmt2.step());
    try testing.expect(!stmt2.columnBool(0));
}

test "renameNativeChatId preserves the internal id (and its FK'd data) under a new native id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat_id = try upsertChat(&pool, .telegram, "-100111", "group", "Old Basic Group");
    try renameNativeChatId(&pool, chat_id, "-100999");

    const found = (try getById(&pool, a, chat_id)) orelse return error.TestExpectedValue;
    defer a.free(found.native_chat_id);
    try testing.expectEqualStrings("-100999", found.native_chat_id);

    // No new row was created for the new id -- same internal id resolves.
    const refs = try listAll(&pool, a);
    defer {
        for (refs) |r| a.free(r.native_chat_id);
        a.free(refs);
    }
    try testing.expectEqual(@as(usize, 1), refs.len);
}

test "deleteLeftBefore purges only chats left before the cutoff" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const still_active = try upsertChat(&pool, .telegram, "1", null, null);
    const left_long_ago = try upsertChat(&pool, .telegram, "2", null, null);
    const left_recently = try upsertChat(&pool, .telegram, "3", null, null);
    try markLeft(&pool, left_long_ago, 1000);
    try markLeft(&pool, left_recently, 5000);

    const deleted = try deleteLeftBefore(&pool, 3000);
    try testing.expectEqual(@as(i64, 1), deleted);

    if (try getById(&pool, testing.allocator, still_active)) |r| {
        testing.allocator.free(r.native_chat_id);
    } else {
        return error.TestExpectedValue;
    }
    try testing.expectEqual(@as(?ChatRef, null), try getById(&pool, testing.allocator, left_long_ago));
    if (try getById(&pool, testing.allocator, left_recently)) |r| {
        testing.allocator.free(r.native_chat_id);
    } else {
        return error.TestExpectedValue;
    }
}

test "getById finds an existing chat and returns null for an unknown id" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat_id = try upsertChat(&pool, .telegram, "-100", "supergroup", "Test");

    const found = (try getById(&pool, a, chat_id)) orelse return error.TestExpectedValue;
    defer a.free(found.native_chat_id);
    try testing.expectEqual(chat_id, found.id);
    try testing.expectEqualStrings("-100", found.native_chat_id);
    try testing.expectEqual(Platform.telegram, found.platform);

    try testing.expectEqual(@as(?ChatRef, null), try getById(&pool, a, chat_id + 999));
}
