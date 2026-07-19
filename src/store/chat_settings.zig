const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Typed replacement for the old stringly-typed per-chat `chat_settings` KV
/// table (`digest_enabled`/`last_digest_ts`/`magic_word` used to be
/// `key`/`value` string rows; now real columns). Also drops the old
/// SQLite-era "empty string means unset" convention for `magic_word` — a
/// real Postgres `NULL` now means unset, since `null`/`""` are no longer
/// forced to collapse into the same thing the way SQLite's `columnText` did.
pub fn getDigestEnabled(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT digest_enabled FROM chat_settings WHERE chat_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    return stmt.columnBool(0);
}

pub fn setDigestEnabled(pool: *PgPool, chat_id: i64, value: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, digest_enabled) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET digest_enabled = excluded.digest_enabled;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindBool(2, value);
    _ = try stmt.step();
}

pub fn getLastDigestTs(pool: *PgPool, chat_id: i64) i64 {
    const db = pool.acquire() catch return 0;
    defer pool.release(db);

    var stmt = db.prepare("SELECT EXTRACT(EPOCH FROM last_digest_ts)::bigint FROM chat_settings WHERE chat_id = $1;") catch return 0;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return 0;
    if (!has_row or stmt.columnIsNull(0)) return 0;
    return stmt.columnInt64(0);
}

pub fn setLastDigestTs(pool: *PgPool, chat_id: i64, ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, last_digest_ts) VALUES ($1, to_timestamp($2))
        \\ON CONFLICT (chat_id) DO UPDATE SET last_digest_ts = excluded.last_digest_ts;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, ts);
    _ = try stmt.step();
}

/// Returns the magic word duped into `allocator`, or `null` if unset.
pub fn getMagicWord(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ?[]const u8 {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT magic_word FROM chat_settings WHERE chat_id = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return null;
    if (!has_row or stmt.columnIsNull(0)) return null;
    return allocator.dupe(u8, stmt.columnText(0)) catch null;
}

/// `null` clears it.
pub fn setMagicWord(pool: *PgPool, chat_id: i64, word: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, magic_word) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET magic_word = excluded.magic_word;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (word) |w| stmt.bindText(2, w) else stmt.bindNull(2);
    _ = try stmt.step();
}

/// Returns the per-chat system-prompt override duped into `allocator`, or
/// `null` if unset (the caller falls back to `config.system_prompt`) — see
/// the `0006_persona.sql` migration comment.
pub fn getSystemPromptOverride(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ?[]const u8 {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT system_prompt FROM chat_settings WHERE chat_id = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return null;
    if (!has_row or stmt.columnIsNull(0)) return null;
    return allocator.dupe(u8, stmt.columnText(0)) catch null;
}

/// `null` clears it (falls back to the global default again).
pub fn setSystemPromptOverride(pool: *PgPool, chat_id: i64, prompt: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, system_prompt) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET system_prompt = excluded.system_prompt;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (prompt) |p| stmt.bindText(2, p) else stmt.bindNull(2);
    _ = try stmt.step();
}

/// Returns the per-chat show-thinking override, or `null` if unset (the
/// caller falls back to `config.llm_show_thinking`) — see the
/// `0007_show_thinking.sql` migration comment.
pub fn getShowThinkingOverride(pool: *PgPool, chat_id: i64) ?bool {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT show_thinking FROM chat_settings WHERE chat_id = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return null;
    if (!has_row or stmt.columnIsNull(0)) return null;
    return stmt.columnBool(0);
}

/// `null` clears it (falls back to the global default again).
pub fn setShowThinkingOverride(pool: *PgPool, chat_id: i64, value: ?bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, show_thinking) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET show_thinking = excluded.show_thinking;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (value) |v| stmt.bindBool(2, v) else stmt.bindNull(2);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");

test "digest_enabled/last_digest_ts/magic_word round trip with defaults when unset" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expect(!getDigestEnabled(&pool, chat_id));
    try setDigestEnabled(&pool, chat_id, true);
    try testing.expect(getDigestEnabled(&pool, chat_id));

    try testing.expectEqual(@as(i64, 0), getLastDigestTs(&pool, chat_id));
    try setLastDigestTs(&pool, chat_id, 12345);
    try testing.expectEqual(@as(i64, 12345), getLastDigestTs(&pool, chat_id));

    try testing.expectEqual(@as(?[]const u8, null), getMagicWord(&pool, testing.allocator, chat_id));
    try setMagicWord(&pool, chat_id, "hassan");
    const word = getMagicWord(&pool, testing.allocator, chat_id) orelse return error.TestExpectedValue;
    defer testing.allocator.free(word);
    try testing.expectEqualStrings("hassan", word);

    try setMagicWord(&pool, chat_id, null);
    try testing.expectEqual(@as(?[]const u8, null), getMagicWord(&pool, testing.allocator, chat_id));
}

test "system_prompt override round trips and clears back to null" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expectEqual(@as(?[]const u8, null), getSystemPromptOverride(&pool, testing.allocator, chat_id));

    try setSystemPromptOverride(&pool, chat_id, "You are a pirate.");
    const prompt = getSystemPromptOverride(&pool, testing.allocator, chat_id) orelse return error.TestExpectedValue;
    defer testing.allocator.free(prompt);
    try testing.expectEqualStrings("You are a pirate.", prompt);

    try setSystemPromptOverride(&pool, chat_id, null);
    try testing.expectEqual(@as(?[]const u8, null), getSystemPromptOverride(&pool, testing.allocator, chat_id));
}

test "show_thinking override round trips through true, false, and clears back to null" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expectEqual(@as(?bool, null), getShowThinkingOverride(&pool, chat_id));

    try setShowThinkingOverride(&pool, chat_id, true);
    try testing.expectEqual(@as(?bool, true), getShowThinkingOverride(&pool, chat_id));

    try setShowThinkingOverride(&pool, chat_id, false);
    try testing.expectEqual(@as(?bool, false), getShowThinkingOverride(&pool, chat_id));

    try setShowThinkingOverride(&pool, chat_id, null);
    try testing.expectEqual(@as(?bool, null), getShowThinkingOverride(&pool, chat_id));
}
