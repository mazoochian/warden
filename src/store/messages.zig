const std = @import("std");
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;
const PgPool = @import("pool.zig").PgPool;

/// Whether `chat_id` has ever had a single message recorded — cheap
/// existence check (no row data pulled back) for callers that just need to
/// know whether there's any history yet, e.g. `set_chat_monitoring`
/// warning the owner that a freshly-subscribed chat has nothing for
/// `get_bulletin` to show until new messages actually arrive. Fails closed
/// to `false` on a lookup error, same as this file's other boolean-return
/// helpers.
pub fn hasAny(pool: *PgPool, chat_id: i64) bool {
    const db = pool.acquire() catch return false;
    defer pool.release(db);

    var stmt = db.prepare("SELECT 1 FROM messages WHERE chat_id = $1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    return (stmt.step() catch return false);
}

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

/// Deletes every message in `chat_id` older than `cutoff_ts` (unix seconds),
/// regardless of `text`/`is_summary` — `storage_sense.zig`'s age-based
/// counterpart to `pruneKeepLast`'s count-based one, backing both the
/// watermark ladder's automatic pruning and `/storage cleanup messages
/// --before`. A summary row aging past `cutoff_ts` is deleted the same as
/// any other row rather than special-cased: it's already a compaction of
/// older history, so once it's old enough itself there's nothing left worth
/// preserving. Returns the number of rows actually deleted (via `RETURNING
/// id`, same counting idiom `recentDeletable`'s callers use elsewhere) so
/// callers can report a real number rather than a bare "done".
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

pub const SummaryBatch = struct {
    /// Oldest-first "who: text" lines, the same shape `recentFormatted`
    /// produces — fed straight into `digest.summarizeHistory`.
    text: []const u8,
    min_id: i64,
    max_id: i64,
    /// The batch's newest message's own `ts` — `resampleOldMessages` stamps
    /// the synthetic summary row with this instead of "now", so it sorts
    /// into place among later real messages rather than jumping to the
    /// front of history.
    newest_ts: i64,
    count: usize,
};

/// The oldest `batch_size` non-summary, texted messages in `chat_id` —
/// `storage_sense.zig`'s `resampleOldMessages` compacts these into one LLM
/// summary. `null` if the chat has nothing left to compact. Bounded to
/// `[min_id, max_id]` rather than a time cutoff so the caller can delete
/// exactly this range afterward without racing a message that arrives
/// mid-summarization (see `replaceRangeWithSummary`).
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
/// `is_summary = true` row carrying `summary_text` — the id range comes
/// from `oldestBatchForSummary`, so this only ever removes exactly the rows
/// that were actually summarized, not "everything older than now" (which
/// would drop a message that arrived while the LLM call was in flight).
/// `db.zig`/`pool.zig` have no shared transaction helper yet (checked before
/// writing this) — `BEGIN`/`COMMIT`/`ROLLBACK` run as plain statements
/// through the same `Db.exec` every other multi-statement call here already
/// uses, on the one connection held for the duration rather than two
/// separate pool acquisitions.
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

    // Reuses `min_id` (just freed by the delete above) as the summary row's
    // own id instead of letting `BIGSERIAL` hand it a fresh one.
    // `recentFormatted`/`recentSinceFormatted`/`pruneKeepLast` all order by
    // `id` as a stand-in for chronological order, which holds for real
    // messages (always inserted in arrival order) but would break here: a
    // freshly-sequenced id is larger than every id already in the table, so
    // a summary of the *oldest* messages would sort as the *newest* one.
    // Claiming the just-freed `min_id` keeps it sorted exactly where the
    // oldest message in the batch used to sit.
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

/// Renders one "who: text"/"summary: text" line — shared by `recentFormatted`
/// and `recentSinceFormatted` so the two don't drift on how a
/// `storage_sense.zig`-written summary row (see `0044_storage_sense.sql`'s
/// `is_summary` column) is told apart from a real message. A summary isn't
/// attributed to whichever identity its row happens to carry (see
/// `storage_sense.zig`'s `resampleOldMessages` doc comment on why that's a
/// synthetic system identity, not a real chat participant) — the LLM/
/// `/summary` reader only needs to know this line is compacted history, not
/// who "sent" it.
fn formatLine(allocator: std.mem.Allocator, who: []const u8, text: []const u8, is_summary: bool) ![]const u8 {
    return if (is_summary)
        std.fmt.allocPrint(allocator, "summary: {s}", .{text})
    else
        std.fmt.allocPrint(allocator, "{s}: {s}", .{ who, text });
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
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text, m.is_summary
        \\FROM messages m JOIN identities i ON i.id = m.identity_id
        \\WHERE m.chat_id = $1 AND m.text IS NOT NULL
        \\ORDER BY m.id DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, limit);

    var lines: std.ArrayList([]const u8) = .empty;
    while (try stmt.step()) {
        try lines.append(allocator, try formatLine(allocator, stmt.columnText(0), stmt.columnText(1), stmt.columnBool(2)));
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
        \\SELECT COALESCE(i.username, NULLIF(i.display_name, ''), 'unknown'), m.text, m.is_summary
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
        try lines.append(allocator, try formatLine(allocator, stmt.columnText(0), stmt.columnText(1), stmt.columnBool(2)));
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
/// unformatted with `native_message_id` included -- for callers (the
/// personal-account chat-summary tool, the bulletin feature) that need to
/// let the model cite a specific message id back, which a pre-joined string
/// can't carry. `recentFormatted`/`recentSinceFormatted` stay as they are
/// for callers (`digest.zig`) that only ever want prose-ready text.
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

/// Same time-windowed shape as `recentSinceFormatted`, unformatted -- see
/// `recentRows`'s doc comment for why.
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
