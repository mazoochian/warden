//! Phase 2 read-only admin surface: global stats, chat directory, identity
//! directory — see /home/armin/claude/warden-ui/API.md's "Admin — stats &
//! directory" section and ROADMAP.md Phase 2. Every query here is
//! read-only; nothing in this module mutates anything.
const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

pub const OverviewStats = struct {
    total_messages: i64,
    total_chats: i64,
    total_identities: i64,
    messages_last_24h: i64,
    messages_last_7d: i64,
    active_chats_last_7d: i64,
};

/// `now` is the caller's own clock reading (`Io.Timestamp.now`), not
/// `now()` inside the query — keeps this testable with a fixed instant
/// instead of depending on wall-clock time at test-run time.
pub fn overview(pool: *PgPool, now: i64) !OverviewStats {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT
        \\  (SELECT COUNT(*) FROM messages),
        \\  (SELECT COUNT(*) FROM chats),
        \\  (SELECT COUNT(*) FROM identities WHERE NOT is_bot),
        \\  (SELECT COUNT(*) FROM messages WHERE ts > to_timestamp($1)),
        \\  (SELECT COUNT(*) FROM messages WHERE ts > to_timestamp($2)),
        \\  (SELECT COUNT(DISTINCT chat_id) FROM messages WHERE ts > to_timestamp($2));
    );
    defer stmt.finalize();
    stmt.bindInt64(1, now - 24 * 3600);
    stmt.bindInt64(2, now - 7 * 24 * 3600);
    _ = try stmt.step();
    return .{
        .total_messages = stmt.columnInt64(0),
        .total_chats = stmt.columnInt64(1),
        .total_identities = stmt.columnInt64(2),
        .messages_last_24h = stmt.columnInt64(3),
        .messages_last_7d = stmt.columnInt64(4),
        .active_chats_last_7d = stmt.columnInt64(5),
    };
}

pub const ChatSummary = struct {
    id: i64,
    platform: Platform,
    native_chat_id: []const u8,
    title: ?[]const u8,
    member_count: i64,
    message_count: i64,
    digest_enabled: bool,
};

/// Paginated by internal id, ascending — `after_id` is the last id seen
/// (0 for the first page), matching `API.md`'s cursor convention (the
/// caller turns `next_cursor` back into `after_id` on the following
/// request; the id itself makes a perfectly good opaque cursor here since
/// ids are already monotonically assigned and never reused).
///
/// Excludes chats the bot has left (`left_at` set — see
/// `store/chats.zig`'s `markLeft`): this backs both the admin chat
/// directory and, via `router.zig`'s `handleListMyChats`, the owner/
/// bot_admin branch of `GET /api/v1/chats?mine=true` (the dropdown source
/// for Bot View/reminders/alerts/group-admin pickers) — a left chat isn't
/// a valid destination for anything new, even though its historical data
/// stays queryable by id until the retention sweep purges it.
pub fn listChats(pool: *PgPool, allocator: std.mem.Allocator, after_id: i64, limit: i64) ![]ChatSummary {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT c.id, c.platform, c.native_chat_id, c.title,
        \\  (SELECT COUNT(*) FROM chat_members cm WHERE cm.chat_id = c.id),
        \\  (SELECT COUNT(*) FROM messages m WHERE m.chat_id = c.id),
        \\  COALESCE(cs.digest_enabled, false)
        \\FROM chats c
        \\LEFT JOIN chat_settings cs ON cs.chat_id = c.id
        \\WHERE c.id > $1 AND c.left_at IS NULL
        \\ORDER BY c.id
        \\LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, after_id);
    stmt.bindInt64(2, limit);

    var out: std.ArrayList(ChatSummary) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(1)) orelse .telegram,
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(2)),
            .title = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
            .member_count = stmt.columnInt64(4),
            .message_count = stmt.columnInt64(5),
            .digest_enabled = stmt.columnBool(6),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub const RecentMessage = struct {
    sender_display_name: []const u8,
    text: ?[]const u8,
    ts: i64,
};

pub const ChatDetail = struct {
    id: i64,
    platform: Platform,
    native_chat_id: []const u8,
    title: ?[]const u8,
    chat_type: ?[]const u8,
    digest_enabled: bool,
    magic_word: ?[]const u8,
    member_count: i64,
    message_count: i64,
    recent_messages: []RecentMessage,
};

pub fn getChatDetail(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) !?ChatDetail {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT c.id, c.platform, c.native_chat_id, c.title, c.chat_type,
        \\  COALESCE(cs.digest_enabled, false), cs.magic_word,
        \\  (SELECT COUNT(*) FROM chat_members cm WHERE cm.chat_id = c.id),
        \\  (SELECT COUNT(*) FROM messages m WHERE m.chat_id = c.id)
        \\FROM chats c
        \\LEFT JOIN chat_settings cs ON cs.chat_id = c.id
        \\WHERE c.id = $1;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (!try stmt.step()) return null;

    const id = stmt.columnInt64(0);
    const platform = std.meta.stringToEnum(Platform, stmt.columnText(1)) orelse .telegram;
    const native_chat_id = try allocator.dupe(u8, stmt.columnText(2));
    const title: ?[]const u8 = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3));
    const chat_type: ?[]const u8 = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4));
    const digest_enabled = stmt.columnBool(5);
    const magic_word: ?[]const u8 = if (stmt.columnIsNull(6)) null else try allocator.dupe(u8, stmt.columnText(6));
    const member_count = stmt.columnInt64(7);
    const message_count = stmt.columnInt64(8);

    var recent_stmt = try db.prepare(
        \\SELECT COALESCE(i.display_name, ''), m.text, EXTRACT(EPOCH FROM m.ts)::bigint
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1
        \\ORDER BY m.id DESC
        \\LIMIT 10;
    );
    defer recent_stmt.finalize();
    recent_stmt.bindInt64(1, chat_id);

    var recent: std.ArrayList(RecentMessage) = .empty;
    while (try recent_stmt.step()) {
        try recent.append(allocator, .{
            .sender_display_name = try allocator.dupe(u8, recent_stmt.columnText(0)),
            .text = if (recent_stmt.columnIsNull(1)) null else try allocator.dupe(u8, recent_stmt.columnText(1)),
            .ts = recent_stmt.columnInt64(2),
        });
    }

    return .{
        .id = id,
        .platform = platform,
        .native_chat_id = native_chat_id,
        .title = title,
        .chat_type = chat_type,
        .digest_enabled = digest_enabled,
        .magic_word = magic_word,
        .member_count = member_count,
        .message_count = message_count,
        .recent_messages = try recent.toOwnedSlice(allocator),
    };
}

pub const IdentitySummary = struct {
    id: i64,
    platform: Platform,
    display_name: []const u8,
    username: ?[]const u8,
    is_bot_admin: bool,
    is_allowed: bool,
    credits: i64,
    last_seen: ?i64,
};

/// Excludes bot accounts (`is_bot`) — matches `identities.findByUsername`'s
/// own convention that bot-facing directories aren't interesting targets
/// here. Paginated the same way as `listChats`.
pub fn listIdentities(pool: *PgPool, allocator: std.mem.Allocator, after_id: i64, limit: i64) ![]IdentitySummary {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT i.id, i.platform, i.display_name, i.username, i.credits,
        \\  EXTRACT(EPOCH FROM i.last_seen)::bigint,
        \\  (ba.identity_id IS NOT NULL),
        \\  (au.identity_id IS NOT NULL)
        \\FROM identities i
        \\LEFT JOIN bot_admins ba ON ba.identity_id = i.id
        \\LEFT JOIN bot_allowed_users au ON au.identity_id = i.id
        \\WHERE i.id > $1 AND NOT i.is_bot
        \\ORDER BY i.id
        \\LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, after_id);
    stmt.bindInt64(2, limit);

    var out: std.ArrayList(IdentitySummary) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(1)) orelse .telegram,
            .display_name = try allocator.dupe(u8, stmt.columnText(2)),
            .username = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
            .credits = stmt.columnInt64(4),
            .last_seen = if (stmt.columnIsNull(5)) null else stmt.columnInt64(5),
            .is_bot_admin = stmt.columnBool(6),
            .is_allowed = stmt.columnBool(7),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub const IdentityDetail = struct {
    id: i64,
    platform: Platform,
    native_id: []const u8,
    display_name: []const u8,
    username: ?[]const u8,
    is_bot_admin: bool,
    is_allowed: bool,
    credits: i64,
    last_seen: ?i64,
};

pub fn getIdentityDetail(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) !?IdentityDetail {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT i.id, i.platform, i.native_id, i.display_name, i.username, i.credits,
        \\  EXTRACT(EPOCH FROM i.last_seen)::bigint,
        \\  (ba.identity_id IS NOT NULL),
        \\  (au.identity_id IS NOT NULL)
        \\FROM identities i
        \\LEFT JOIN bot_admins ba ON ba.identity_id = i.id
        \\LEFT JOIN bot_allowed_users au ON au.identity_id = i.id
        \\WHERE i.id = $1;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    if (!try stmt.step()) return null;

    return .{
        .id = stmt.columnInt64(0),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(1)) orelse .telegram,
        .native_id = try allocator.dupe(u8, stmt.columnText(2)),
        .display_name = try allocator.dupe(u8, stmt.columnText(3)),
        .username = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
        .credits = stmt.columnInt64(5),
        .last_seen = if (stmt.columnIsNull(6)) null else stmt.columnInt64(6),
        .is_bot_admin = stmt.columnBool(7),
        .is_allowed = stmt.columnBool(8),
    };
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");
const messages = @import("messages.zig");
const chat_members = @import("chat_members.zig");
const bot_admins = @import("bot_admins.zig");
const bot_allowlist = @import("bot_allowlist.zig");

fn seedBasics(pool: *PgPool) !struct { chat: i64, alice: i64, bob: i64 } {
    const chat = try chats.upsertChat(pool, .telegram, "-100", "supergroup", "Test Chat");
    const alice = try identities.upsertIdentity(pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .username = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    const bob = try identities.upsertIdentity(pool, .{
        .platform = .telegram,
        .native_id = "2",
        .display_name = "Bob",
        .username = "bob",
        .first_seen = 1000,
        .last_seen = 2000,
    });
    try chat_members.touch(pool, chat, alice, 1000);
    try chat_members.touch(pool, chat, bob, 1000);
    try messages.insert(pool, chat, alice, null, "hi", 1000);
    try messages.insert(pool, chat, bob, null, "hello", 2000);
    return .{ .chat = chat, .alice = alice, .bob = bob };
}

test "overview counts messages/chats/identities and recency windows" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    // Deliberately realistic-scale epoch timestamps here (not the small
    // 1000/2000 offsets `seedBasics` uses elsewhere in this file) -- the
    // 24h/7d windows subtract 86400/604800 from `now`, so tiny offsets
    // make the cutoff go deeply negative and every message spuriously
    // counts as "recent" regardless of the window being tested. Found via
    // a real full-DB test run: this test originally used 1000/2000 and
    // passed locally by accident, then failed under CI-adjacent
    // conditions once the cutoff math was actually exercised correctly.
    const chat = try chats.upsertChat(&pool, .telegram, "-100", "supergroup", "Test Chat");
    const alice = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1_700_000_000,
        .last_seen = 1_700_000_000,
    });
    const bob = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "2",
        .display_name = "Bob",
        .first_seen = 1_700_000_000,
        .last_seen = 1_700_000_000,
    });

    const now: i64 = 1_700_100_000;
    const recent_ts = now - 3600; // 1 hour ago -- inside both windows.
    const medium_ts = now - 3 * 24 * 3600; // 3 days ago -- inside 7d, outside 24h.
    try messages.insert(&pool, chat, alice, null, "recent", recent_ts);
    try messages.insert(&pool, chat, bob, null, "medium", medium_ts);

    const stats = try overview(&pool, now);
    try testing.expectEqual(@as(i64, 2), stats.total_messages);
    try testing.expectEqual(@as(i64, 1), stats.total_chats);
    try testing.expectEqual(@as(i64, 2), stats.total_identities);
    try testing.expectEqual(@as(i64, 1), stats.messages_last_24h);
    try testing.expectEqual(@as(i64, 2), stats.messages_last_7d);
    try testing.expectEqual(@as(i64, 1), stats.active_chats_last_7d);
}

test "listChats paginates by id and reports member/message counts" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const seed = try seedBasics(&pool);

    const page = try listChats(&pool, a, 0, 50);
    defer {
        for (page) |c| {
            a.free(c.native_chat_id);
            if (c.title) |t| a.free(t);
        }
        a.free(page);
    }
    try testing.expectEqual(@as(usize, 1), page.len);
    try testing.expectEqual(seed.chat, page[0].id);
    try testing.expectEqual(@as(i64, 2), page[0].member_count);
    try testing.expectEqual(@as(i64, 2), page[0].message_count);
    try testing.expectEqualStrings("Test Chat", page[0].title.?);

    const empty_page = try listChats(&pool, a, seed.chat, 50);
    defer a.free(empty_page);
    try testing.expectEqual(@as(usize, 0), empty_page.len);
}

test "listChats excludes chats the bot has left" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const seed = try seedBasics(&pool);
    try chats.markLeft(&pool, seed.chat, 1000);

    const page = try listChats(&pool, a, 0, 50);
    defer a.free(page);
    try testing.expectEqual(@as(usize, 0), page.len);
}

test "getChatDetail returns settings, counts, and recent messages newest-first" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const seed = try seedBasics(&pool);

    const detail = (try getChatDetail(&pool, a, seed.chat)) orelse return error.TestExpectedValue;
    defer {
        a.free(detail.native_chat_id);
        if (detail.title) |t| a.free(t);
        if (detail.chat_type) |t| a.free(t);
        if (detail.magic_word) |t| a.free(t);
        for (detail.recent_messages) |m| {
            a.free(m.sender_display_name);
            if (m.text) |t| a.free(t);
        }
        a.free(detail.recent_messages);
    }
    try testing.expectEqual(@as(i64, 2), detail.member_count);
    try testing.expectEqual(@as(i64, 2), detail.message_count);
    try testing.expectEqual(@as(usize, 2), detail.recent_messages.len);
    try testing.expectEqualStrings("Bob", detail.recent_messages[0].sender_display_name);
    try testing.expectEqualStrings("Alice", detail.recent_messages[1].sender_display_name);

    try testing.expectEqual(@as(?ChatDetail, null), try getChatDetail(&pool, a, seed.chat + 999));
}

test "listIdentities excludes bots and reports admin/allowlist/credits flags" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const seed = try seedBasics(&pool);
    _ = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "999",
        .display_name = "TheBot",
        .is_bot = true,
        .first_seen = 1000,
        .last_seen = 1000,
    });
    try bot_admins.addBotAdmin(&pool, seed.alice, seed.bob);
    try bot_allowlist.addAllowedUser(&pool, seed.bob, seed.alice);

    const page = try listIdentities(&pool, a, 0, 50);
    defer {
        for (page) |i| {
            a.free(i.display_name);
            if (i.username) |u| a.free(u);
        }
        a.free(page);
    }
    try testing.expectEqual(@as(usize, 2), page.len); // bot excluded
    try testing.expect(page[0].is_bot_admin);
    try testing.expect(!page[0].is_allowed);
    try testing.expect(!page[1].is_bot_admin);
    try testing.expect(page[1].is_allowed);
}

test "getIdentityDetail returns full profile or null" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const seed = try seedBasics(&pool);

    const detail = (try getIdentityDetail(&pool, a, seed.alice)) orelse return error.TestExpectedValue;
    defer {
        a.free(detail.native_id);
        a.free(detail.display_name);
        if (detail.username) |u| a.free(u);
    }
    try testing.expectEqualStrings("Alice", detail.display_name);
    try testing.expectEqualStrings("1", detail.native_id);
    try testing.expectEqual(Platform.telegram, detail.platform);

    try testing.expectEqual(@as(?IdentityDetail, null), try getIdentityDetail(&pool, a, seed.alice + 999));
}
