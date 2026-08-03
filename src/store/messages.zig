const std = @import("std");
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;
const PgPool = @import("pool.zig").PgPool;

/// Inserts one message row, scoped to `chat_id`/`identity_id` (the internal
/// FK ids from `chats.upsertChat`/`identities.upsertIdentity`) — replaces
/// the old per-chat-file `messages` table's implicit-by-filename scoping.
pub fn insert(pool: *PgPool, chat_id: i64, identity_id: i64, native_message_id: ?[]const u8, text: ?[]const u8, ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO messages (chat_id, identity_id, native_message_id, text, ts)
        \\VALUES ($1, $2, $3, $4, to_timestamp($5));
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    if (native_message_id) |m| stmt.bindText(3, m) else stmt.bindNull(3);
    if (text) |t| stmt.bindText(4, t) else stmt.bindNull(4);
    stmt.bindInt64(5, ts);
    _ = try stmt.step();
}

/// Deletes everything older than the most recent `keep` messages, scoped to
/// `chat_id`. No-ops if fewer than `keep` rows exist for that chat.
pub fn pruneKeepLast(pool: *PgPool, chat_id: i64, keep: i64) !void {
    std.debug.assert(keep > 0);
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\DELETE FROM messages WHERE chat_id = $1 AND id < (
        \\  SELECT id FROM messages WHERE chat_id = $1 ORDER BY id DESC LIMIT 1 OFFSET $2
        \\);
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, keep - 1);
    _ = try stmt.step();
}

/// Renders the most recent `limit` messages in `chat_id` (oldest first) as
/// "who: text" lines, for grounding free-form LLM questions/digests in this
/// chat's actual local history. Prefers the sender's platform username
/// (matches the old behavior) falling back to their display name, then
/// "unknown" — same fallback chain the old SQLite version used, just
/// resolved through `identities` instead of a denormalized `username`
/// column on `messages` itself.
pub fn recentFormatted(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, limit: i64) ![]const u8 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL
        \\ORDER BY m.id DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, limit);

    var lines: std.ArrayList([]const u8) = .empty;
    while (try stmt.step()) {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ stmt.columnText(0), stmt.columnText(1) }));
    }
    std.mem.reverse([]const u8, lines.items); // rows came back newest-first
    return std.mem.join(allocator, "\n", lines.items);
}

/// Same "who: text" formatting as `recentFormatted`, but windowed by wall-
/// clock time (`since_ts`, unix seconds) rather than a flat row count —
/// backs the `catch_me_up` LLM tool (ROADMAP.md's Phase 14), which needs
/// "everything since N hours ago" rather than "the last N messages" so a
/// quiet chat's catch-up isn't padded with days-old context and a noisy
/// one isn't truncated mid-conversation. Still capped by `limit` as a hard
/// ceiling (a very chatty chat over a long window could otherwise return
/// an unbounded amount of text) — same belt-and-suspenders shape
/// `recentDeletable`'s `scan_limit`/`match_limit` pair already uses for a
/// different combination of bounds.
pub fn recentSinceFormatted(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, since_ts: i64, limit: i64) ![]const u8 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL AND m.ts >= to_timestamp($2)
        \\ORDER BY m.id DESC LIMIT $3;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, since_ts);
    stmt.bindInt64(3, limit);

    var lines: std.ArrayList([]const u8) = .empty;
    while (try stmt.step()) {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ stmt.columnText(0), stmt.columnText(1) }));
    }
    std.mem.reverse([]const u8, lines.items); // rows came back newest-first
    return std.mem.join(allocator, "\n", lines.items);
}

pub const MessageRef = struct {
    id: i64,
    native_message_id: []const u8,
    text: ?[]const u8,
};

/// Escapes `%`, `_`, and `\` for safe embedding in a `LIKE ... ESCAPE '\'`
/// pattern — same approach as `chat_members.zig`'s private `likePattern`,
/// duplicated here rather than shared cross-module (small, self-contained,
/// matches this codebase's existing preference for module-local helpers
/// over a shared utils file — see e.g. `http_util.zig`'s own `redactUrl`).
fn escapeLikeLiteral(allocator: std.mem.Allocator, substring: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(allocator, '%');
    for (substring) |c| {
        if (c == '\\' or c == '%' or c == '_') try buf.append(allocator, '\\');
        try buf.append(allocator, c);
    }
    try buf.append(allocator, '%');
    return buf.toOwnedSlice(allocator);
}

fn collectDeletable(stmt: *Stmt, allocator: std.mem.Allocator) ![]MessageRef {
    var out: std.ArrayList(MessageRef) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_message_id = try allocator.dupe(u8, stmt.columnText(1)),
            .text = if (stmt.columnIsNull(2)) null else try allocator.dupe(u8, stmt.columnText(2)),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Most recent `limit` deletable (`native_message_id IS NOT NULL`) messages
/// in `chat_id`, newest first — backs `/redact <N>`.
pub fn recentDeletable(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, limit: i64) ![]MessageRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, native_message_id, text FROM messages
        \\WHERE chat_id = $1 AND native_message_id IS NOT NULL
        \\ORDER BY id DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, limit);
    return collectDeletable(&stmt, allocator);
}

/// Same as `recentDeletable`, scoped to one sender — backs
/// "`/redact [N]` as a reply to a user's message".
pub fn recentDeletableByIdentity(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, identity_id: i64, limit: i64) ![]MessageRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, native_message_id, text FROM messages
        \\WHERE chat_id = $1 AND identity_id = $2 AND native_message_id IS NOT NULL
        \\ORDER BY id DESC LIMIT $3;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindInt64(3, limit);
    return collectDeletable(&stmt, allocator);
}

/// Literal (non-regex) case-insensitive substring search among deletable
/// messages, newest first — backs `/redact text <substring>`. Bounded by
/// BOTH `match_limit` (how many matches to return) and `scan_limit` (how
/// far back into history to look), using the same id-offset-subquery idiom
/// `pruneKeepLast` uses to bound its own window — `COALESCE(..., 0)` makes
/// "fewer than `scan_limit` messages exist" mean "scan everything" rather
/// than `pruneKeepLast`'s opposite convention of no-op-ing in that case (the
/// two functions want opposite fallback behavior from the same NULL-when-
/// insufficient-rows subquery result, so this isn't reusable as one helper).
pub fn searchDeletable(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, substring: []const u8, match_limit: i64, scan_limit: i64) ![]MessageRef {
    const db = try pool.acquire();
    defer pool.release(db);

    const pattern = try escapeLikeLiteral(allocator, substring);
    defer allocator.free(pattern);

    var stmt = try db.prepare(
        \\SELECT id, native_message_id, text FROM messages
        \\WHERE chat_id = $1 AND native_message_id IS NOT NULL AND text ILIKE $2 ESCAPE '\'
        \\  AND id >= COALESCE((SELECT id FROM messages WHERE chat_id = $1 ORDER BY id DESC LIMIT 1 OFFSET $4), 0)
        \\ORDER BY id DESC LIMIT $3;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, pattern);
    stmt.bindInt64(3, match_limit);
    stmt.bindInt64(4, scan_limit - 1);
    return collectDeletable(&stmt, allocator);
}

/// Up to `scan_limit` most recent deletable+texted messages, newest first —
/// for `/redact regex <pattern>`, which must filter client-side
/// (`text/safe_regex.zig`'s matcher; Postgres can't run it). Callers stop
/// consuming once they've collected enough matches or exhausted this slice,
/// whichever comes first.
pub fn recentForScan(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, scan_limit: i64) ![]MessageRef {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, native_message_id, text FROM messages
        \\WHERE chat_id = $1 AND native_message_id IS NOT NULL AND text IS NOT NULL
        \\ORDER BY id DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, scan_limit);
    return collectDeletable(&stmt, allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "insert/recentFormatted/pruneKeepLast scoped correctly per chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .username = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    const carol = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "3",
        .display_name = "Carol",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    try insert(&pool, chat1, alice, "1", "hi", 1000);
    try insert(&pool, chat1, alice, "2", "again", 1001);
    try insert(&pool, chat2, carol, "3", "unrelated", 1002);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const history = try recentFormatted(&pool, a, chat1, 10);
    try testing.expectEqualStrings("alice: hi\nalice: again", history);

    // A separate chat must not see chat1's messages (per-chat isolation).
    const history2 = try recentFormatted(&pool, a, chat2, 10);
    try testing.expectEqualStrings("Carol: unrelated", history2);

    try pruneKeepLast(&pool, chat1, 1);
    const pruned = try recentFormatted(&pool, a, chat1, 10);
    try testing.expectEqualStrings("alice: again", pruned);
}

test "recentSinceFormatted windows by timestamp, respects the row limit, and returns newest-first input in oldest-first output" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try insert(&pool, chat1, alice, "1", "too old", 500);
    try insert(&pool, chat1, alice, "2", "in window one", 1500);
    try insert(&pool, chat1, alice, "3", "in window two", 2000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const windowed = try recentSinceFormatted(&pool, a, chat1, 1000, 100);
    try testing.expectEqualStrings("alice: in window one\nalice: in window two", windowed);

    const capped = try recentSinceFormatted(&pool, a, chat1, 1000, 1);
    try testing.expectEqualStrings("alice: in window two", capped);

    const nothing_before_anything = try recentSinceFormatted(&pool, a, chat1, 9999, 100);
    try testing.expectEqualStrings("", nothing_before_anything);
}

test "recentDeletable excludes messages with no native_message_id, newest first" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try insert(&pool, chat1, alice, "1", "first", 1000);
    try insert(&pool, chat1, alice, null, "undeletable (no native id)", 1001);
    try insert(&pool, chat1, alice, "3", "third", 1002);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const refs = try recentDeletable(&pool, a, chat1, 10);
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("3", refs[0].native_message_id);
    try testing.expectEqualStrings("1", refs[1].native_message_id);
}

test "recentDeletableByIdentity scopes to one sender within a chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const bob = try identities.getOrCreateMinimal(&pool, .telegram, "2", "bob", null, false, 1000);

    try insert(&pool, chat1, alice, "1", "alice says hi", 1000);
    try insert(&pool, chat1, bob, "2", "bob says hi", 1001);
    try insert(&pool, chat1, alice, "3", "alice again", 1002);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const refs = try recentDeletableByIdentity(&pool, a, chat1, alice, 10);
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("3", refs[0].native_message_id);
    try testing.expectEqualStrings("1", refs[1].native_message_id);
}

test "searchDeletable matches literal substrings case-insensitively and respects the match limit" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try insert(&pool, chat1, alice, "1", "buy CHEAP watches now", 1000);
    try insert(&pool, chat1, alice, "2", "totally unrelated", 1001);
    try insert(&pool, chat1, alice, "3", "cheap watches again", 1002);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const all_matches = try searchDeletable(&pool, a, chat1, "cheap watches", 10, 100);
    try testing.expectEqual(@as(usize, 2), all_matches.len);

    const limited = try searchDeletable(&pool, a, chat1, "cheap watches", 1, 100);
    try testing.expectEqual(@as(usize, 1), limited.len);
}

test "searchDeletable's scan window still finds everything when fewer messages exist than scan_limit" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try insert(&pool, chat1, alice, "1", "spam here", 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Only 1 message exists, well under a 2000 scan_limit — the COALESCE
    // fallback must still find it rather than the lower-bound subquery
    // returning NULL and matching nothing.
    const matches = try searchDeletable(&pool, a, chat1, "spam", 100, 2000);
    try testing.expectEqual(@as(usize, 1), matches.len);
}

test "searchDeletable treats % and _ in the query as literal characters, not wildcards" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try insert(&pool, chat1, alice, "1", "100% real deal", 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const literal_hit = try searchDeletable(&pool, a, chat1, "100%", 10, 100);
    try testing.expectEqual(@as(usize, 1), literal_hit.len);

    const no_such = try searchDeletable(&pool, a, chat1, "1_0", 10, 100);
    try testing.expectEqual(@as(usize, 0), no_such.len);
}

test "recentForScan excludes null-text and undeletable messages, respects scan_limit" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try insert(&pool, chat1, alice, "1", "one", 1000);
    try insert(&pool, chat1, alice, null, "two (no native id)", 1001);
    try insert(&pool, chat1, alice, "3", null, 1002);
    try insert(&pool, chat1, alice, "4", "four", 1003);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const refs = try recentForScan(&pool, a, chat1, 100);
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("4", refs[0].native_message_id);
    try testing.expectEqualStrings("1", refs[1].native_message_id);

    const capped = try recentForScan(&pool, a, chat1, 1);
    try testing.expectEqual(@as(usize, 1), capped.len);
    try testing.expectEqualStrings("4", capped[0].native_message_id);
}
