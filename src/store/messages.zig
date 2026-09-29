const std = @import("std");
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;
const PgPool = @import("pool.zig").PgPool;

/// Whether `chat_id` has ever had a single message recorded.
pub fn hasAny(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM messages WHERE chat_id = $1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    return (stmt.step() catch return false);
}

/// Inserts one message row, scoped to `chat_id`/`identity_id` (the internal
/// FK ids from `chats.upsertChat`/`identities.upsertIdentity`).
pub fn insert(pool: *PgPool, chat_id: i64, identity_id: i64, native_message_id: ?[]const u8, text: ?[]const u8, ts: i64) !void {
    return insertWithTrace(pool, chat_id, identity_id, native_message_id, text, ts, null);
}

/// `insert` for the bot's own replies, with the tool calls that produced it.
pub fn insertWithTrace(pool: *PgPool, chat_id: i64, identity_id: i64, native_message_id: ?[]const u8, text: ?[]const u8, ts: i64, tool_trace: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO messages (chat_id, identity_id, native_message_id, text, ts, tool_trace)
        \\VALUES ($1, $2, $3, $4, to_timestamp($5), $6);
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    if (native_message_id) |m| stmt.bindText(3, m) else stmt.bindNull(3);
    if (text) |t| stmt.bindText(4, t) else stmt.bindNull(4);
    stmt.bindInt64(5, ts);
    if (tool_trace) |tr| stmt.bindText(6, tr) else stmt.bindNull(6);
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

/// Deletes every message in `chat_id` older than `cutoff_ts` (unix seconds),
/// regardless of `text`/`is_summary`.
pub fn deleteOlderThan(pool: *PgPool, chat_id: i64, cutoff_ts: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\DELETE FROM messages WHERE chat_id = $1 AND ts < to_timestamp($2) RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, cutoff_ts);

    var count: i64 = 0;
    while (try stmt.step()) count += 1;
    return count;
}

/// Unix seconds of the oldest stored message in `chat_id` (every chat when
/// `null`), or `null` if there are none.
pub fn oldestTs(pool: *PgPool, chat_id: ?i64) !?i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT EXTRACT(EPOCH FROM MIN(ts))::BIGINT FROM messages WHERE $1::BIGINT IS NULL OR chat_id = $1;
    );
    defer stmt.finalize();
    if (chat_id) |id| stmt.bindInt64(1, id) else stmt.bindNull(1);
    if (!try stmt.step()) return null;
    if (stmt.columnIsNull(0)) return null;
    return stmt.columnInt64(0);
}

pub const SummaryBatch = struct {
    /// Oldest-first "who: text" lines, the same shape `recentFormatted`
    /// produces — fed straight into `digest.summarizeHistory`.
    text: []const u8,
    min_id: i64,
    max_id: i64,
    /// The batch's newest message's own `ts` — `resampleOldMessages` stamps the
    /// synthetic summary row with this instead of "now".
    newest_ts: i64,
    count: usize,
};

/// The oldest `batch_size` non-summary, texted messages in `chat_id` —
/// `storage_sense.zig`'s `resampleOldMessages` compacts these into one LLM
/// summary.
pub fn oldestBatchForSummary(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, batch_size: i64) !?SummaryBatch {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT m.id, COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text, EXTRACT(EPOCH FROM m.ts)::BIGINT
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL AND m.is_summary = false
        \\ORDER BY m.id ASC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, batch_size);

    var lines: std.ArrayList([]const u8) = .empty;
    var min_id: i64 = 0;
    var max_id: i64 = 0;
    var newest_ts: i64 = 0;
    var count: usize = 0;
    while (try stmt.step()) {
        const id = stmt.columnInt64(0);
        if (count == 0) min_id = id;
        max_id = id;
        newest_ts = stmt.columnInt64(3);
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ stmt.columnText(1), stmt.columnText(2) }));
        count += 1;
    }
    if (count == 0) return null;
    return .{
        .text = try std.mem.join(allocator, "\n", lines.items),
        .min_id = min_id,
        .max_id = max_id,
        .newest_ts = newest_ts,
        .count = count,
    };
}

/// Atomically replaces `[min_id, max_id]` in `chat_id` with a single
/// `is_summary = true` row carrying `summary_text`.
pub fn replaceRangeWithSummary(pool: *PgPool, chat_id: i64, identity_id: i64, min_id: i64, max_id: i64, summary_text: []const u8, ts: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    try db.exec("BEGIN;");
    errdefer db.exec("ROLLBACK;") catch |err| {
        std.log.err("messages: rollback failed after a replaceRangeWithSummary error: {t}", .{err});
    };

    var del = try db.prepare("DELETE FROM messages WHERE chat_id = $1 AND id >= $2 AND id <= $3;");
    del.bindInt64(1, chat_id);
    del.bindInt64(2, min_id);
    del.bindInt64(3, max_id);
    _ = try del.step();
    del.finalize();

    // Reuses `min_id` (just freed by the delete above) as the summary row's own
    // id instead of letting `BIGSERIAL` hand it a fresh one.
    var ins = try db.prepare(
        \\INSERT INTO messages (id, chat_id, identity_id, native_message_id, text, ts, is_summary)
        \\VALUES ($1, $2, $3, NULL, $4, to_timestamp($5), true);
    );
    ins.bindInt64(1, min_id);
    ins.bindInt64(2, chat_id);
    ins.bindInt64(3, identity_id);
    ins.bindText(4, summary_text);
    ins.bindInt64(5, ts);
    _ = try ins.step();
    ins.finalize();

    try db.exec("COMMIT;");
}

/// Renders one "who: text"/"summary: text" line.
fn formatLine(allocator: std.mem.Allocator, who: []const u8, text: []const u8, is_summary: bool, tool_trace: ?[]const u8) ![]const u8 {
    if (is_summary) return std.fmt.allocPrint(allocator, "summary: {s}", .{text});
    if (tool_trace) |trace| {
        if (trace.len > 0) return std.fmt.allocPrint(allocator, "{s}: [used: {s}] {s}", .{ who, trace, text });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ who, text });
}

/// Renders the most recent `limit` messages in `chat_id` (oldest first) as
/// "who.
pub fn recentFormatted(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, limit: i64) ![]const u8 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text, m.is_summary, m.tool_trace
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL
        \\ORDER BY m.id DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, limit);

    var lines: std.ArrayList([]const u8) = .empty;
    while (try stmt.step()) {
        try lines.append(allocator, try formatLine(allocator, stmt.columnText(0), stmt.columnText(1), stmt.columnBool(2), if (stmt.columnIsNull(3)) null else stmt.columnText(3)));
    }
    std.mem.reverse([]const u8, lines.items); // rows came back newest-first
    return std.mem.join(allocator, "\n", lines.items);
}

/// Same "who: text" formatting as `recentFormatted`, but windowed by wall-
/// clock time (`since_ts`, unix seconds) rather than a flat row count.
pub fn recentSinceFormatted(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, since_ts: i64, limit: i64) ![]const u8 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text, m.is_summary, m.tool_trace
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
        try lines.append(allocator, try formatLine(allocator, stmt.columnText(0), stmt.columnText(1), stmt.columnBool(2), if (stmt.columnIsNull(3)) null else stmt.columnText(3)));
    }
    std.mem.reverse([]const u8, lines.items); // rows came back newest-first
    return std.mem.join(allocator, "\n", lines.items);
}

pub const HistoryRow = struct {
    native_message_id: ?[]const u8,
    who: []const u8,
    text: []const u8,
    is_summary: bool,
};

/// Same rows `recentFormatted` joins into "who: text" lines, but returned
/// unformatted with `native_message_id` included -- for callers.
pub fn recentRows(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, limit: i64) ![]HistoryRow {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text, m.is_summary, m.native_message_id
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL
        \\ORDER BY m.id DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, limit);

    var rows: std.ArrayList(HistoryRow) = .empty;
    while (try stmt.step()) {
        try rows.append(allocator, .{
            .who = try allocator.dupe(u8, stmt.columnText(0)),
            .text = try allocator.dupe(u8, stmt.columnText(1)),
            .is_summary = stmt.columnBool(2),
            .native_message_id = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
        });
    }
    std.mem.reverse(HistoryRow, rows.items); // rows came back newest-first
    return rows.toOwnedSlice(allocator);
}

/// Same time-windowed shape as `recentSinceFormatted`, unformatted.
pub fn recentSinceRows(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, since_ts: i64, limit: i64) ![]HistoryRow {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text, m.is_summary, m.native_message_id
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL AND m.ts >= to_timestamp($2)
        \\ORDER BY m.id DESC LIMIT $3;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, since_ts);
    stmt.bindInt64(3, limit);

    var rows: std.ArrayList(HistoryRow) = .empty;
    while (try stmt.step()) {
        try rows.append(allocator, .{
            .who = try allocator.dupe(u8, stmt.columnText(0)),
            .text = try allocator.dupe(u8, stmt.columnText(1)),
            .is_summary = stmt.columnBool(2),
            .native_message_id = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
        });
    }
    std.mem.reverse(HistoryRow, rows.items); // rows came back newest-first
    return rows.toOwnedSlice(allocator);
}

pub const MessageRef = struct {
    id: i64,
    native_message_id: []const u8,
    text: ?[]const u8,
};

/// Escapes `%`, `_`, and `\` for safe embedding in a `LIKE ... ESCAPE '\'`
/// pattern.
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
/// messages, newest first — backs `/redact text <substring>`.
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
/// for `/redact regex <pattern>`.
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

test "hasAny is false for a chat with no messages, true once one is inserted, scoped per chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram_user, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram_user, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "alice", null, false, 1000);

    try testing.expect(!hasAny(&pool, chat1));

    try insert(&pool, chat1, alice, "1", "hi", 1000);
    try testing.expect(hasAny(&pool, chat1));
    try testing.expect(!hasAny(&pool, chat2));
}

test "oldestTs is scoped per chat, spans every chat for null, and is null with no messages" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try testing.expectEqual(@as(?i64, null), try oldestTs(&pool, null));

    try insert(&pool, chat1, alice, "1", "newer", 5000);
    try insert(&pool, chat2, alice, "2", "older", 2000);
    try testing.expectEqual(@as(?i64, 5000), try oldestTs(&pool, chat1));
    try testing.expectEqual(@as(?i64, 2000), try oldestTs(&pool, null));
}

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

    // The bot's own reply carries what it did; an empty trace renders like
    // no trace at all.
    try insertWithTrace(&pool, chat2, carol, "4", "12°C in Berlin", 1003, "weather({\"location\":\"Berlin\"}) -> 12°C");
    try insertWithTrace(&pool, chat2, carol, "5", "plain", 1004, "");
    const traced = try recentFormatted(&pool, a, chat2, 10);
    try testing.expectEqualStrings("Carol: unrelated\nCarol: [used: weather({\"location\":\"Berlin\"}) -> 12°C] 12°C in Berlin\nCarol: plain", traced);

    try pruneKeepLast(&pool, chat1, 1);
    const pruned = try recentFormatted(&pool, a, chat1, 10);
    try testing.expectEqualStrings("alice: again", pruned);
}

test "recentRows returns unformatted rows oldest-first, with native_message_id carried through" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram_user, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "alice", null, false, 1000);

    try insert(&pool, chat1, alice, "501", "hi", 1000);
    try insert(&pool, chat1, alice, null, "no native id", 1001);
    try insert(&pool, chat1, alice, "503", "again", 1002);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = try recentRows(&pool, a, chat1, 10);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("501", rows[0].native_message_id.?);
    try testing.expectEqualStrings("hi", rows[0].text);
    try testing.expectEqual(@as(?[]const u8, null), rows[1].native_message_id);
    try testing.expectEqualStrings("503", rows[2].native_message_id.?);

    const limited = try recentRows(&pool, a, chat1, 1);
    try testing.expectEqual(@as(usize, 1), limited.len);
    try testing.expectEqualStrings("503", limited[0].native_message_id.?);
}

test "recentSinceRows windows by timestamp and marks compacted summary rows via is_summary" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram_user, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "alice", null, false, 1000);
    const warden = try identities.getOrCreateMinimal(&pool, .telegram_user, "warden_system", "Warden", null, true, 1000);

    try insert(&pool, chat1, alice, "1", "too old", 500);
    try insert(&pool, chat1, alice, "2", "in window", 1500);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const batch = (try oldestBatchForSummary(&pool, a, chat1, 1)) orelse return error.TestExpectedValue;
    try replaceRangeWithSummary(&pool, chat1, warden, batch.min_id, batch.max_id, "Talked about old stuff.", 600);

    const windowed = try recentSinceRows(&pool, a, chat1, 400, 100);
    try testing.expectEqual(@as(usize, 2), windowed.len);
    try testing.expect(windowed[0].is_summary);
    try testing.expectEqualStrings("Talked about old stuff.", windowed[0].text);
    try testing.expectEqual(@as(?[]const u8, null), windowed[0].native_message_id);
    try testing.expect(!windowed[1].is_summary);
    try testing.expectEqualStrings("in window", windowed[1].text);
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

    // Only 1 message exists, well under a 2000 scan_limit.
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

test "deleteOlderThan removes only messages before the cutoff, scoped to one chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try insert(&pool, chat1, alice, "1", "old", 1000);
    try insert(&pool, chat1, alice, "2", "also old", 1500);
    try insert(&pool, chat1, alice, "3", "recent", 3000);
    try insert(&pool, chat2, alice, "4", "unrelated chat, also old", 1000);

    const deleted = try deleteOlderThan(&pool, chat1, 2000);
    try testing.expectEqual(@as(i64, 2), deleted);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const left = try recentFormatted(&pool, a, chat1, 10);
    try testing.expectEqualStrings("alice: recent", left);

    // A different chat's messages older than the same cutoff are untouched.
    const other = try recentFormatted(&pool, a, chat2, 10);
    try testing.expectEqualStrings("alice: unrelated chat, also old", other);
}

test "oldestBatchForSummary returns the oldest non-summary messages as an id range, null once nothing's left" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try insert(&pool, chat1, alice, "1", "first", 1000);
    try insert(&pool, chat1, alice, "2", "second", 1001);
    try insert(&pool, chat1, alice, "3", "third", 1002);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const batch = (try oldestBatchForSummary(&pool, a, chat1, 2)) orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("alice: first\nalice: second", batch.text);
    try testing.expectEqual(@as(usize, 2), batch.count);
    try testing.expectEqual(@as(i64, 1001), batch.newest_ts);

    try testing.expectEqual(@as(?SummaryBatch, null), try oldestBatchForSummary(&pool, a, 999, 2));
}

test "replaceRangeWithSummary atomically swaps an id range for one is_summary row, sorted by the batch's newest ts" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const warden = try identities.getOrCreateMinimal(&pool, .telegram, "warden_system", "Warden", null, true, 1000);

    try insert(&pool, chat1, alice, "1", "first", 1000);
    try insert(&pool, chat1, alice, "2", "second", 1001);
    try insert(&pool, chat1, alice, "3", "third, kept", 2000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const batch = (try oldestBatchForSummary(&pool, a, chat1, 2)) orelse return error.TestExpectedValue;
    try replaceRangeWithSummary(&pool, chat1, warden, batch.min_id, batch.max_id, "They discussed the first two things.", batch.newest_ts);

    const history = try recentFormatted(&pool, a, chat1, 10);
    try testing.expectEqualStrings("summary: They discussed the first two things.\nalice: third, kept", history);
}
