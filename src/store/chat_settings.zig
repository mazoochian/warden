const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const user_settings = @import("user_settings.zig");
const ReplyAutonomy = user_settings.ReplyAutonomy;

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

/// Same shape as `getDigestEnabled`/`setDigestEnabled` above -- a separate
/// pair rather than reusing the digest ones since a chat can opt into
/// digests, briefings, both, or neither independently (see
/// `0026_briefings.sql`).
pub fn getBriefingEnabled(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT briefing_enabled FROM chat_settings WHERE chat_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    return stmt.columnBool(0);
}

pub fn setBriefingEnabled(pool: *PgPool, chat_id: i64, value: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, briefing_enabled) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET briefing_enabled = excluded.briefing_enabled;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindBool(2, value);
    _ = try stmt.step();
}

pub fn getLastBriefingTs(pool: *PgPool, chat_id: i64) i64 {
    const db = pool.acquire() catch return 0;
    defer pool.release(db);

    var stmt = db.prepare("SELECT EXTRACT(EPOCH FROM last_briefing_ts)::bigint FROM chat_settings WHERE chat_id = $1;") catch return 0;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return 0;
    if (!has_row or stmt.columnIsNull(0)) return 0;
    return stmt.columnInt64(0);
}

pub fn setLastBriefingTs(pool: *PgPool, chat_id: i64, ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, last_briefing_ts) VALUES ($1, to_timestamp($2))
        \\ON CONFLICT (chat_id) DO UPDATE SET last_briefing_ts = excluded.last_briefing_ts;
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

/// This chat's explicit "reply on my behalf" override, or `null` if it just
/// inherits the owner's global default (`user_settings.
/// getEffectiveReplyAutonomyDefault`) — see `resolveReplyAutonomy` for the
/// combined result callers actually want, and migration
/// `0043_reply_autonomy.sql`'s doc comment for what each level means.
pub fn getReplyAutonomy(pool: *PgPool, chat_id: i64) ?ReplyAutonomy {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT reply_autonomy FROM chat_settings WHERE chat_id = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return null;
    if (!has_row or stmt.columnIsNull(0)) return null;
    return std.meta.stringToEnum(ReplyAutonomy, stmt.columnText(0));
}

/// `null` clears the override (falls back to the owner's global default).
pub fn setReplyAutonomy(pool: *PgPool, chat_id: i64, value: ?ReplyAutonomy) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, reply_autonomy) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET reply_autonomy = excluded.reply_autonomy;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (value) |v| stmt.bindText(2, @tagName(v)) else stmt.bindNull(2);
    _ = try stmt.step();
}

/// The autonomy level a "reply on my behalf" draft for `chat_id` should
/// actually use: this chat's override if it has one, else the owner's
/// global default. The one function `features/`-layer code calling into
/// this should use — `getReplyAutonomy`/`user_settings.
/// getEffectiveReplyAutonomyDefault` individually are for the settings UI
/// (which needs to show "unset, inheriting X" rather than just X) and for
/// each other's tests.
pub fn resolveReplyAutonomy(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, owner_identity_id: i64) ReplyAutonomy {
    if (getReplyAutonomy(pool, chat_id)) |override| return override;
    return user_settings.getEffectiveReplyAutonomyDefault(pool, allocator, owner_identity_id);
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

/// Returns the per-chat welcome-message text duped into `allocator`, or
/// `null` if unset (welcome messages are opt-in — see the
/// `0028_welcome_message.sql` migration comment). May contain a literal
/// `{name}` placeholder, substituted per new member by whichever caller
/// sends it.
pub fn getWelcomeMessage(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ?[]const u8 {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT welcome_message FROM chat_settings WHERE chat_id = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return null;
    if (!has_row or stmt.columnIsNull(0)) return null;
    return allocator.dupe(u8, stmt.columnText(0)) catch null;
}

/// `null` disables welcome messages for this chat again.
pub fn setWelcomeMessage(pool: *PgPool, chat_id: i64, text: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, welcome_message) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET welcome_message = excluded.welcome_message;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (text) |t| stmt.bindText(2, t) else stmt.bindNull(2);
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
const identities = @import("identities.zig");

test "resolveReplyAutonomy: no override inherits the owner's global default, override beats it, clearing restores inheritance" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const owner_id = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "owner", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram_user, "100", null, null);

    // Nothing set anywhere yet -> fails closed to .off.
    try testing.expectEqual(ReplyAutonomy.off, resolveReplyAutonomy(&pool, a, chat_id, owner_id));

    // Global default set, no per-chat override -> inherits it.
    try user_settings.setReplyAutonomyDefault(&pool, owner_id, .draft);
    try testing.expectEqual(@as(?ReplyAutonomy, null), getReplyAutonomy(&pool, chat_id));
    try testing.expectEqual(ReplyAutonomy.draft, resolveReplyAutonomy(&pool, a, chat_id, owner_id));

    // Per-chat override beats the global default.
    try setReplyAutonomy(&pool, chat_id, .off);
    try testing.expectEqual(ReplyAutonomy.off, resolveReplyAutonomy(&pool, a, chat_id, owner_id));

    // Clearing the override falls back to inheriting the global default again.
    try setReplyAutonomy(&pool, chat_id, null);
    try testing.expectEqual(ReplyAutonomy.draft, resolveReplyAutonomy(&pool, a, chat_id, owner_id));
}

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

test "briefing_enabled/last_briefing_ts round trip with defaults when unset" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expect(!getBriefingEnabled(&pool, chat_id));
    try setBriefingEnabled(&pool, chat_id, true);
    try testing.expect(getBriefingEnabled(&pool, chat_id));

    try testing.expectEqual(@as(i64, 0), getLastBriefingTs(&pool, chat_id));
    try setLastBriefingTs(&pool, chat_id, 54321);
    try testing.expectEqual(@as(i64, 54321), getLastBriefingTs(&pool, chat_id));
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

test "welcome_message round trips and clears back to null" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expectEqual(@as(?[]const u8, null), getWelcomeMessage(&pool, testing.allocator, chat_id));

    try setWelcomeMessage(&pool, chat_id, "Welcome, {name}!");
    const msg = getWelcomeMessage(&pool, testing.allocator, chat_id) orelse return error.TestExpectedValue;
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("Welcome, {name}!", msg);

    try setWelcomeMessage(&pool, chat_id, null);
    try testing.expectEqual(@as(?[]const u8, null), getWelcomeMessage(&pool, testing.allocator, chat_id));
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

/// Returns this chat's default location (the raw place name the user set,
/// e.g. "Berlin") duped into `allocator`, or `null` if unset — see the
/// `0034_default_location.sql` migration comment for why the text is stored
/// rather than resolved coordinates.
pub fn getDefaultLocation(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ?[]const u8 {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT default_location FROM chat_settings WHERE chat_id = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return null;
    if (!has_row or stmt.columnIsNull(0)) return null;
    return allocator.dupe(u8, stmt.columnText(0)) catch null;
}

/// `null` clears it.
pub fn setDefaultLocation(pool: *PgPool, chat_id: i64, location: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, default_location) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET default_location = excluded.default_location;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (location) |l| stmt.bindText(2, l) else stmt.bindNull(2);
    _ = try stmt.step();
}

/// Whether this chat wants scheduled announcements pinned as they're
/// posted (ROADMAP.md's Phase 16 auto-pin item) — false unless the chat
/// explicitly opted in via `/autopin on`, same shape as
/// `getDigestEnabled`/`getBriefingEnabled` and the same "off until asked"
/// default as `welcome_message`.
///
/// The name is narrower than "auto-pin" on purpose: the only thing this
/// ever pins is an announcement the bot itself posted, from a schedule a
/// chat admin explicitly created. It is never a judgment about someone
/// else's message — see `0036_autopin_announcements.sql`.
pub fn getAutopinAnnouncements(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT autopin_announcements FROM chat_settings WHERE chat_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    return stmt.columnBool(0);
}

pub fn setAutopinAnnouncements(pool: *PgPool, chat_id: i64, value: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, autopin_announcements) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET autopin_announcements = excluded.autopin_announcements;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindBool(2, value);
    _ = try stmt.step();
}

/// Whether managerial commands (`/redact`, `/kick`, `/ban`, `/promote`,
/// `/demote`, `/mute`, `/unmute`, `/photo`, `/title`, `/description`)
/// default to `-s` (silent) in this chat without the flag being typed —
/// ROADMAP.md's Phase 23. Off by default, same shape as
/// `getAutopinAnnouncements`.
pub fn getSilentByDefault(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT silent_by_default FROM chat_settings WHERE chat_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    return stmt.columnBool(0);
}

pub fn setSilentByDefault(pool: *PgPool, chat_id: i64, value: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, silent_by_default) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET silent_by_default = excluded.silent_by_default;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindBool(2, value);
    _ = try stmt.step();
}

test "silent_by_default is off until a chat opts in, and toggles back off" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expect(!getSilentByDefault(&pool, chat_id));
    try setSilentByDefault(&pool, chat_id, true);
    try testing.expect(getSilentByDefault(&pool, chat_id));
    try setSilentByDefault(&pool, chat_id, false);
    try testing.expect(!getSilentByDefault(&pool, chat_id));
}

test "autopin_announcements is off until a chat opts in, and toggles back off" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expect(!getAutopinAnnouncements(&pool, chat_id));
    try setAutopinAnnouncements(&pool, chat_id, true);
    try testing.expect(getAutopinAnnouncements(&pool, chat_id));
    try setAutopinAnnouncements(&pool, chat_id, false);
    try testing.expect(!getAutopinAnnouncements(&pool, chat_id));
}

/// Whether this chat wants YouTube/Instagram/X video links auto-downloaded
/// and reposted (ROADMAP.md's Phase 25) -- false unless a chat admin
/// explicitly opted in via `/videodownload on`, same "off until asked"
/// default as `getAutopinAnnouncements`/`welcome_message`. Off by default
/// on purpose: unlike `keyword_alerts` (a word a user opts *themselves*
/// into tracking), this changes what the bot does with a link *any*
/// member posts -- see `0037_video_download.sql`.
pub fn getVideoDownloadEnabled(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT video_download_enabled FROM chat_settings WHERE chat_id = $1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    return stmt.columnBool(0);
}

pub fn setVideoDownloadEnabled(pool: *PgPool, chat_id: i64, value: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, video_download_enabled) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET video_download_enabled = excluded.video_download_enabled;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindBool(2, value);
    _ = try stmt.step();
}

/// Whether video auto-download delivers a compressed native video (lossy,
/// the default) or the original-quality file capped at 50MB (lossless, an
/// opt-in) -- see `video_download.Quality` and `0042_video_download_lossy.sql`.
/// Unlike `getVideoDownloadEnabled`, the no-row fallback here is `true`,
/// not `false` -- this setting only matters once a chat has already opted
/// into `video_download_enabled` itself, and among chats that have, lossy
/// is the better default, matching the column's own `DEFAULT TRUE`.
pub fn getVideoDownloadLossy(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return true;
    defer pool.release(db);

    var stmt = db.prepare("SELECT video_download_lossy FROM chat_settings WHERE chat_id = $1;") catch return true;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    const has_row = stmt.step() catch return true;
    if (!has_row) return true;
    return stmt.columnBool(0);
}

pub fn setVideoDownloadLossy(pool: *PgPool, chat_id: i64, value: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (chat_id, video_download_lossy) VALUES ($1, $2)
        \\ON CONFLICT (chat_id) DO UPDATE SET video_download_lossy = excluded.video_download_lossy;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindBool(2, value);
    _ = try stmt.step();
}

test "video_download_lossy defaults to true and toggles both ways" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expect(getVideoDownloadLossy(&pool, chat_id));
    try setVideoDownloadLossy(&pool, chat_id, false);
    try testing.expect(!getVideoDownloadLossy(&pool, chat_id));
    try setVideoDownloadLossy(&pool, chat_id, true);
    try testing.expect(getVideoDownloadLossy(&pool, chat_id));
}

test "video_download_enabled is off until a chat opts in, and toggles back off" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expect(!getVideoDownloadEnabled(&pool, chat_id));
    try setVideoDownloadEnabled(&pool, chat_id, true);
    try testing.expect(getVideoDownloadEnabled(&pool, chat_id));
    try setVideoDownloadEnabled(&pool, chat_id, false);
    try testing.expect(!getVideoDownloadEnabled(&pool, chat_id));
}

test "default location round-trips, is null by default, and clears back to null" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    try testing.expectEqual(@as(?[]const u8, null), getDefaultLocation(&pool, testing.allocator, chat_id));

    try setDefaultLocation(&pool, chat_id, "San Francisco, California");
    const got = getDefaultLocation(&pool, testing.allocator, chat_id) orelse return error.TestExpectedValue;
    defer testing.allocator.free(got);
    // Spaces and commas survive verbatim -- unlike the magic word, a place
    // name is expected to contain them.
    try testing.expectEqualStrings("San Francisco, California", got);

    try setDefaultLocation(&pool, chat_id, null);
    try testing.expectEqual(@as(?[]const u8, null), getDefaultLocation(&pool, testing.allocator, chat_id));
}
