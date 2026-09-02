const std = @import("std");
const PgPool = @import("pool.zig").PgPool;
const embeddings = @import("../llm/embeddings.zig");

/// One chat's summary for one local day — the design brief's episodic
/// layer. `local_date_unix` is that date's UTC midnight, only ever used to
/// compute a relative age ("4 months ago") for rendering; it is not the
/// actual timestamp of any message in the digest.
pub const Digest = struct {
    id: i64,
    weekday: []const u8,
    summary: []const u8,
    local_date_unix: i64,
};

/// Cheap existence check, same purpose as `facts.hasAny` — lets
/// `context_assembly.zig` skip the embed-and-rank round trip for a chat
/// with no digests yet (true for every chat until the nightly digest job,
/// ROADMAP.md's memory-layer phase, lands).
pub fn hasAny(pool: *PgPool, chat_id: i64) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT 1 FROM daily_digests WHERE chat_id = $1 LIMIT 1;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    return try stmt.step();
}

/// Creates or replaces the digest for `chat_id`/`(year, month, day)` — the
/// nightly digest job's write path (not built yet; this is the store-layer
/// primitive it will call). `topics`/`entities`/`source` extraction isn't
/// implemented in this slice, so those columns are left at their schema
/// defaults (`'{}'`) rather than threaded through here as unused params.
pub fn upsert(
    pool: *PgPool,
    allocator: std.mem.Allocator,
    chat_id: i64,
    year: i32,
    month: u8,
    day: u8,
    weekday: []const u8,
    summary: []const u8,
    min_message_id: i64,
    max_message_id: i64,
    embedding: []const f32,
) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    const vec_literal = try embeddings.formatVectorLiteral(allocator, embedding);
    defer allocator.free(vec_literal);
    // `{d:0>N}` zero-pads a *signed* integer with an explicit sign character
    // (Zig reserves the leading column for it even when positive) --
    // `year` cast to unsigned avoids emitting "+2026-04-14", which Postgres
    // fails to parse as a date (it reads the leading '+' as a timezone
    // sign and errors out entirely, not just on the stray character).
    const date_literal = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(year)), month, day });
    defer allocator.free(date_literal);

    var stmt = try db.prepare(
        \\INSERT INTO daily_digests (chat_id, local_date, weekday, summary, min_message_id, max_message_id, embedding)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7)
        \\ON CONFLICT (chat_id, local_date) DO UPDATE SET
        \\  weekday = excluded.weekday, summary = excluded.summary,
        \\  min_message_id = excluded.min_message_id, max_message_id = excluded.max_message_id,
        \\  embedding = excluded.embedding
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, date_literal);
    stmt.bindText(3, weekday);
    stmt.bindText(4, summary);
    stmt.bindInt64(5, min_message_id);
    stmt.bindInt64(6, max_message_id);
    stmt.bindText(7, vec_literal);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

fn collect(stmt: *@import("db.zig").Stmt, allocator: std.mem.Allocator) ![]Digest {
    var out: std.ArrayList(Digest) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .weekday = try allocator.dupe(u8, stmt.columnText(1)),
            .summary = try allocator.dupe(u8, stmt.columnText(2)),
            .local_date_unix = stmt.columnInt64(3),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// The most recent `n` digests for `chat_id`, newest first — the design
/// brief's mandatory "recency floor": these are always shown regardless of
/// how they'd score against the current question, since continuity beats
/// relevance for recent context.
pub fn mostRecent(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, n: u32) ![]Digest {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, weekday, summary, EXTRACT(EPOCH FROM local_date)::bigint
        \\FROM daily_digests WHERE chat_id = $1
        \\ORDER BY local_date DESC LIMIT $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, n);
    return collect(&stmt, allocator);
}

/// Top-`limit` digests by hybrid score against `query_embedding`/`query_text`
/// — the design brief's "Retrieved episodes" budget block. The brief only
/// gives a scoring formula for facts (scope-dependent half-life); episodes
/// have no such per-row scope, so this uses a flat 30-day half-life
/// (roughly "last month feels current, longer ago needs to rank on
/// relevance instead") rather than inventing an unspecified per-digest
/// scope. `ts_rank_cd` again stands in for the brief's `bm25()`.
pub fn ranked(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, query_embedding: []const f32, query_text: []const u8, limit: u32, now: i64) ![]Digest {
    const db = try pool.acquire();
    defer pool.release(db);

    const vec_literal = try embeddings.formatVectorLiteral(allocator, query_embedding);
    defer allocator.free(vec_literal);

    var stmt = try db.prepare(
        \\SELECT id, weekday, summary, EXTRACT(EPOCH FROM local_date)::bigint,
        \\  (0.5 * (1 - (embedding <=> $2))
        \\ + 0.3 * ts_rank_cd(to_tsvector('english', summary), plainto_tsquery('english', $3))
        \\ + 0.2 * exp(-EXTRACT(EPOCH FROM (to_timestamp($5) - local_date)) / 86400.0 / 30.0)
        \\  ) AS score
        \\FROM daily_digests
        \\WHERE chat_id = $1
        \\ORDER BY score DESC
        \\LIMIT $4;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, vec_literal);
    stmt.bindText(3, query_text);
    stmt.bindInt64(4, limit);
    stmt.bindInt64(5, now);
    return collect(&stmt, allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const embedding_dimensions = @import("../llm/embeddings.zig").embedding_dimensions;

fn testVector(hot_index: usize) [embedding_dimensions]f32 {
    var v: [embedding_dimensions]f32 = @splat(0);
    v[hot_index] = 1.0;
    return v;
}

test "hasAny/upsert/mostRecent, scoped per chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);

    try testing.expect(!try hasAny(&pool, chat1));

    _ = try upsert(&pool, a, chat1, 2026, 4, 14, "Saturday", "Debugged the Airflow DAG retry loop.", 1, 5, &testVector(0));
    _ = try upsert(&pool, a, chat1, 2026, 4, 15, "Sunday", "Deployed the fix.", 6, 9, &testVector(1));

    try testing.expect(try hasAny(&pool, chat1));
    try testing.expect(!try hasAny(&pool, chat2));

    const recent = try mostRecent(&pool, a, chat1, 5);
    defer {
        for (recent) |d| {
            a.free(d.weekday);
            a.free(d.summary);
        }
        a.free(recent);
    }
    try testing.expectEqual(@as(usize, 2), recent.len);
    try testing.expectEqualStrings("Sunday", recent[0].weekday); // newest first
    try testing.expectEqualStrings("Saturday", recent[1].weekday);
}

test "upsert replaces the same chat/date's digest instead of duplicating it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    _ = try upsert(&pool, a, chat1, 2026, 4, 14, "Saturday", "First pass.", 1, 3, &testVector(0));
    _ = try upsert(&pool, a, chat1, 2026, 4, 14, "Saturday", "Revised summary.", 1, 5, &testVector(0));

    const recent = try mostRecent(&pool, a, chat1, 5);
    defer {
        for (recent) |d| {
            a.free(d.weekday);
            a.free(d.summary);
        }
        a.free(recent);
    }
    try testing.expectEqual(@as(usize, 1), recent.len);
    try testing.expectEqualStrings("Revised summary.", recent[0].summary);
}

test "ranked orders by hybrid score against the query" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    _ = try upsert(&pool, a, chat1, 2026, 4, 14, "Saturday", "Debugged the Airflow retry loop", 1, 3, &testVector(0));
    _ = try upsert(&pool, a, chat1, 2026, 1, 2, "Friday", "Unrelated grocery run chat", 4, 6, &testVector(2));

    const results = try ranked(&pool, a, chat1, &testVector(0), "Airflow retry loop", 5, 100_000_000);
    defer {
        for (results) |d| {
            a.free(d.weekday);
            a.free(d.summary);
        }
        a.free(results);
    }
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("Debugged the Airflow retry loop", results[0].summary);
}
