const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;
const ChatRef = @import("chats.zig").ChatRef;

/// Ensures a `chat_members` row exists for (chat_id, identity_id) and bumps
/// its `last_seen` — called once per inbound message, replacing the old
/// per-chat `users` upsert. `tokens` is left untouched on conflict (defaults
/// to 0 only on first insert), matching the old behavior.
pub fn touch(pool: *PgPool, chat_id: i64, identity_id: i64, ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_members (chat_id, identity_id, last_seen)
        \\VALUES ($1, $2, to_timestamp($3))
        \\ON CONFLICT (chat_id, identity_id) DO UPDATE SET last_seen = excluded.last_seen;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindInt64(3, ts);
    _ = try stmt.step();
}

/// `true` if this identity has a `chat_members` row for this chat — the
/// API layer's stand-in for "is this person actually part of this chat",
/// gating who may create reminders/alerts/watches on their own behalf
/// (see `api/router.zig`'s Phase 5a handlers).
pub fn isMember(pool: *PgPool, chat_id: i64, identity_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM chat_members WHERE chat_id = $1 AND identity_id = $2;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    return stmt.step() catch false;
}

/// Ensures a `chat_members` row exists for (chat_id, identity_id), but
/// unlike `touch` never bumps `last_seen` — for identities Warden only
/// learned about *passively* (a reply target, a text-mention, a join/leave
/// event, an admin-list entry: see `iface.Message.observed_users` and
/// `MemberDirectoryToolAdapter` in `main.zig`), not because they actually
/// said something just now. Keeps `last_seen` meaning "last time this
/// person spoke", while still registering them so `search` below can find
/// them.
pub fn ensureKnown(pool: *PgPool, chat_id: i64, identity_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_members (chat_id, identity_id)
        \\VALUES ($1, $2)
        \\ON CONFLICT (chat_id, identity_id) DO NOTHING;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    _ = try stmt.step();
}

/// Own shape rather than reusing `chats.ChatRef` — the warden-ui API's
/// "My Groups" listing needs `title` too, and adding it to `ChatRef`
/// itself would ripple into every other caller's cleanup code for a field
/// only this one query actually needs.
pub const MemberChatRef = struct {
    id: i64,
    native_chat_id: []const u8,
    platform: Platform,
    title: ?[]const u8,
};

/// Every chat this identity has a `chat_members` row in — the candidate
/// set for the warden-ui API's "My Groups" listing (`GET /api/v1/chats?
/// mine=true`, Phase 4): cheaper than live-checking admin status against
/// *every* chat in the system, and correct since a live platform admin of
/// a chat is necessarily also a member of it.
pub fn listChatsForIdentity(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) ![]MemberChatRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT c.id, c.native_chat_id, c.platform, c.title
        \\FROM chat_members cm JOIN chats c ON c.id = cm.chat_id
        \\WHERE cm.identity_id = $1;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);

    var out: std.ArrayList(MemberChatRef) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
            .title = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub const Match = struct {
    display_name: []const u8,
    username: ?[]const u8,
    native_id: []const u8,
};

pub const Member = struct {
    identity_id: i64,
    display_name: []const u8,
    username: ?[]const u8,
    last_seen: ?i64,
};

/// Every known member of a chat (not filtered by query, unlike `search`)
/// — backs the warden-ui API's `GET /api/v1/chats/:id/members` (Phase 4).
/// Bots excluded, same convention `search` already uses.
pub fn listMembers(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, limit: i64) ![]Member {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT i.id, i.display_name, i.username, EXTRACT(EPOCH FROM cm.last_seen)::bigint
        \\FROM chat_members cm JOIN identities i ON i.id = cm.identity_id
        \\WHERE cm.chat_id = $1 AND NOT i.is_bot
        \\ORDER BY cm.last_seen DESC NULLS LAST
        \\LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, limit);

    var out: std.ArrayList(Member) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .identity_id = stmt.columnInt64(0),
            .display_name = try allocator.dupe(u8, stmt.columnText(1)),
            .username = if (stmt.columnIsNull(2)) null else try allocator.dupe(u8, stmt.columnText(2)),
            .last_seen = if (stmt.columnIsNull(3)) null else stmt.columnInt64(3),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Escapes `%`, `_`, and `\` for safe embedding in a `LIKE ... ESCAPE '\'`
/// pattern, then wraps `query` in `%...%` for a substring match — so a
/// query containing those characters searches for them literally instead of
/// being interpreted as wildcards.
fn likePattern(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(allocator, '%');
    for (query) |c| {
        if (c == '\\' or c == '%' or c == '_') try buf.append(allocator, '\\');
        try buf.append(allocator, c);
    }
    try buf.append(allocator, '%');
    return buf.toOwnedSlice(allocator);
}

/// Fuzzy (case-insensitive substring) lookup of this chat's known
/// participants by display name or `@username` — the backing query for the
/// `find_chat_member` LLM tool (see `tools/find_chat_member.zig`). Matches
/// against everyone `chat_members` has a row for, not just recent senders —
/// see `ensureKnown`'s doc comment for the other ways someone ends up with a
/// row here. Most-recently-active matches first (nulls, i.e. purely
/// passively-observed members, last).
pub fn search(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, query: []const u8, limit: i64) ![]Match {
    const db = try pool.acquire();
    defer pool.release(db);

    const pattern = try likePattern(allocator, query);
    defer allocator.free(pattern);

    var stmt = try db.prepare(
        \\SELECT i.display_name, i.username, i.native_id
        \\FROM chat_members cm JOIN identities i ON i.id = cm.identity_id
        \\WHERE cm.chat_id = $1 AND NOT i.is_bot
        \\  AND (i.display_name ILIKE $2 ESCAPE '\' OR i.username ILIKE $2 ESCAPE '\')
        \\ORDER BY cm.last_seen DESC NULLS LAST
        \\LIMIT $3;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, pattern);
    stmt.bindInt64(3, limit);

    var out: std.ArrayList(Match) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .display_name = try allocator.dupe(u8, stmt.columnText(0)),
            .username = if (stmt.columnIsNull(1)) null else try allocator.dupe(u8, stmt.columnText(1)),
            .native_id = try allocator.dupe(u8, stmt.columnText(2)),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn getTokens(pool: *PgPool, chat_id: i64, identity_id: i64, default: i64) i64 {
    const db = pool.acquire() catch return default;
    defer pool.release(db);

    var stmt = db.prepare("SELECT tokens FROM chat_members WHERE chat_id = $1 AND identity_id = $2;") catch return default;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    const has_row = stmt.step() catch return default;
    if (!has_row) return default;
    return stmt.columnInt64(0);
}

/// Unlike the old SQLite `settings.setTokens` (a plain `UPDATE`, which
/// silently affected zero rows for a user who'd never sent a message), this
/// upserts — a `chat_members` row is guaranteed to exist afterward.
pub fn setTokens(pool: *PgPool, chat_id: i64, identity_id: i64, value: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO chat_members (chat_id, identity_id, tokens) VALUES ($1, $2, $3)
        \\ON CONFLICT (chat_id, identity_id) DO UPDATE SET tokens = excluded.tokens;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindInt64(3, value);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");
const chats = @import("chats.zig");

test "getTokens defaults when no row exists; setTokens upserts even for a never-seen user" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try testing.expectEqual(@as(i64, 0), getTokens(&pool, chat_id, identity_id, 0));

    try setTokens(&pool, chat_id, identity_id, 5);
    try testing.expectEqual(@as(i64, 5), getTokens(&pool, chat_id, identity_id, 0));
}

test "touch creates a chat_members row and updates last_seen without touching tokens" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try setTokens(&pool, chat_id, identity_id, 3);
    try touch(&pool, chat_id, identity_id, 2000);
    try testing.expectEqual(@as(i64, 3), getTokens(&pool, chat_id, identity_id, 0));
}

test "ensureKnown registers a member without claiming they've ever actually spoken" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "99",
        .display_name = "Courtney Hale",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    try ensureKnown(&pool, chat_id, identity_id);
    // Calling it again (e.g. re-observed via a second mention) must stay a
    // no-op rather than erroring on the primary key conflict.
    try ensureKnown(&pool, chat_id, identity_id);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const matches = try search(&pool, arena.allocator(), chat_id, "Courtney", 5);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("Courtney Hale", matches[0].display_name);
}

test "listChatsForIdentity lists only chats that identity is a member of" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, "Chat One");
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    try touch(&pool, chat1, alice, 1000);

    const found = try listChatsForIdentity(&pool, a, alice);
    defer {
        for (found) |c| {
            a.free(c.native_chat_id);
            if (c.title) |t| a.free(t);
        }
        a.free(found);
    }
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(chat1, found[0].id);
    try testing.expectEqualStrings("Chat One", found[0].title.?);
    _ = chat2;
}

test "search matches display_name or username case-insensitively, most-recently-active first" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    const courtney = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Courtney Hale",
        .username = "courtney_h",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    const bob = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "2",
        .display_name = "Bob",
        .username = "courtneyfan99",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    const bot = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "3",
        .display_name = "Courtney's Bot",
        .is_bot = true,
        .first_seen = 1000,
        .last_seen = 1000,
    });

    // Bob was active more recently than Courtney; ensureKnown never sets
    // last_seen at all.
    try touch(&pool, chat_id, courtney, 1000);
    try touch(&pool, chat_id, bob, 2000);
    try ensureKnown(&pool, chat_id, bot);

    // Case-insensitive substring on display_name, both handle-and-name hits
    // returned, bot excluded, most recently active first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const matches = try search(&pool, arena.allocator(), chat_id, "courtney", 5);
    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqualStrings("Bob", matches[0].display_name);
    try testing.expectEqualStrings("Courtney Hale", matches[1].display_name);
}

test "search treats % and _ in the query as literal characters, not wildcards" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "100% Real",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    try ensureKnown(&pool, chat_id, id);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const literal_hit = try search(&pool, a, chat_id, "100%", 5);
    try testing.expectEqual(@as(usize, 1), literal_hit.len);

    // "_" would otherwise wildcard-match any single character (e.g. "100x").
    const no_such_user = try search(&pool, a, chat_id, "1_0", 5);
    try testing.expectEqual(@as(usize, 0), no_such_user.len);
}

test "listMembers excludes bots, orders most-recently-active first" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.upsertIdentity(&pool, .{ .platform = .telegram, .native_id = "1", .display_name = "Alice", .first_seen = 1000, .last_seen = 1000 });
    const bob = try identities.upsertIdentity(&pool, .{ .platform = .telegram, .native_id = "2", .display_name = "Bob", .first_seen = 1000, .last_seen = 1000 });
    const bot = try identities.upsertIdentity(&pool, .{ .platform = .telegram, .native_id = "3", .display_name = "TheBot", .is_bot = true, .first_seen = 1000, .last_seen = 1000 });

    try touch(&pool, chat_id, alice, 1000);
    try touch(&pool, chat_id, bob, 2000);
    try ensureKnown(&pool, chat_id, bot);

    const members = try listMembers(&pool, a, chat_id, 50);
    defer {
        for (members) |m| {
            a.free(m.display_name);
            if (m.username) |u| a.free(u);
        }
        a.free(members);
    }
    try testing.expectEqual(@as(usize, 2), members.len);
    try testing.expectEqualStrings("Bob", members[0].display_name);
    try testing.expectEqualStrings("Alice", members[1].display_name);
    try testing.expectEqual(@as(?i64, 2000), members[0].last_seen);
}
