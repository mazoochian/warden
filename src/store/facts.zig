const std = @import("std");
const PgPool = @import("pool.zig").PgPool;
const embeddings = @import("../llm/embeddings.zig");

/// Legacy-shaped view kept for API compatibility (`/memory list`, the
/// `GET/DELETE /api/v1/memory` web endpoints, the `remember_memory` LLM
/// tool) — none of those care about the bitemporal/supersession machinery
/// below, only "id, whose it is, what it says, when". `text` is a fact's
/// `statement`; `created_at` is `recorded_at` (equal to `valid_from` for
/// every fact this file creates today, since nothing here backdates one).
pub const Memory = struct {
    id: i64,
    identity_id: i64,
    text: []const u8,
    created_at: i64,
};

/// A fact as read back for ranking/rendering (`features/context_assembly.zig`)
/// — carries the fields the rendered prompt needs (confidence markers,
/// dates) that `Memory` deliberately doesn't.
pub const RankedFact = struct {
    statement: []const u8,
    status: []const u8,
    confirmations: i32,
    valid_from: i64,
    last_confirmed_at: i64,
};

/// Explicit `remember` (the `remember_memory` tool's `action=create`, or a
/// future `/memory remember`) — always `status='pinned'`: a person asking to
/// remember something is already-confirmed, not a tentative LLM guess, so it
/// should never be swept up by the nightly retirement job. Predicate/object
/// are a degenerate triple (`predicate='remembers'`, `object=text`) since an
/// explicit remember doesn't come pre-parsed into subject/predicate/object
/// the way an auto-extracted fact eventually will (ROADMAP.md's memory-layer
/// phase, extractor slice) — `scope='preference'` for the same reason: a
/// reasonable default until real scope classification exists.
/// `embedding` is optional: a fact is worth storing whether or not this
/// deployment has an embeddings endpoint configured. Without one the row
/// simply has no vector, and the 0.40 similarity term of the hybrid score
/// drops out for it (see `hybrid_score_expr`) -- it stays findable by
/// keyword, recency and salience, and `pinnedForIdentity` (which is what
/// an explicitly-remembered fact goes into) never needed a vector at all.
///
/// This used to take a non-optional `[]const f32`, which combined with the
/// column's NOT NULL and `main.zig` only wiring the memory tool when an
/// embeddings client existed meant that remembering anything was silently
/// impossible without WARDEN_EMBEDDINGS_URL. See
/// `0050_optional_embeddings.sql`.
pub fn remember(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, text: []const u8, embedding: ?[]const f32, created_at: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    const vec_literal: ?[]const u8 = if (embedding) |e| try embeddings.formatVectorLiteral(allocator, e) else null;
    defer if (vec_literal) |v| allocator.free(v);

    var stmt = try db.prepare(
        \\INSERT INTO facts (identity_id, scope, predicate, object, statement, valid_from, recorded_at, last_confirmed_at, status, embedding)
        \\VALUES ($1, 'preference', 'remembers', $2, $2, to_timestamp($3), to_timestamp($3), to_timestamp($3), 'pinned', $4::vector)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindText(2, text);
    stmt.bindInt64(3, created_at);
    if (vec_literal) |v| stmt.bindText(4, v) else stmt.bindNull(4);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// The `limit` closest active (non-retired, currently-valid) facts to
/// `query_embedding` for one identity, by cosine distance — the plain
/// vector-only search `qa.zig` used to call directly. Superseded for actual
/// prompt assembly by `rankedStable`/`rankedTentative` (hybrid-scored, status-
/// aware), kept here as the simpler primitive other future callers can still
/// reach for. No approximate index (see `0048_memory_layer.sql`'s doc
/// comment on why) — a plain sequential scan is fine at the row counts a
/// personal bot's fact table will ever reach.
pub fn search(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, query_embedding: []const f32, limit: u32) ![]Memory {
    const db = try pool.acquire();
    defer pool.release(db);

    const vec_literal = try embeddings.formatVectorLiteral(allocator, query_embedding);
    defer allocator.free(vec_literal);

    var stmt = try db.prepare(
        \\SELECT id, statement, EXTRACT(EPOCH FROM recorded_at)::bigint
        \\FROM facts
        \\WHERE identity_id = $1 AND valid_to IS NULL AND status != 'retired'
        \\  AND embedding IS NOT NULL
        \\ORDER BY embedding <=> $2
        \\LIMIT $3;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindText(2, vec_literal);
    stmt.bindInt64(3, limit);

    var out: std.ArrayList(Memory) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .identity_id = identity_id,
            .text = try allocator.dupe(u8, stmt.columnText(1)),
            .created_at = stmt.columnInt64(2),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Every active fact for one identity, oldest first — for `/memory list`.
pub fn listForIdentity(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) ![]Memory {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, statement, EXTRACT(EPOCH FROM recorded_at)::bigint
        \\FROM facts WHERE identity_id = $1 AND status != 'retired'
        \\ORDER BY recorded_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);

    var out: std.ArrayList(Memory) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .identity_id = identity_id,
            .text = try allocator.dupe(u8, stmt.columnText(1)),
            .created_at = stmt.columnInt64(2),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` for a retired or nonexistent fact — used by `/memory forget` to
/// check ownership before deleting, same pattern as `notes.get`. Filtering
/// out `status='retired'` here (not just in `listForIdentity`) matches the
/// old `memories` table's behavior, where a forgotten row was gone outright:
/// `get` on an already-forgotten id must still read back as "no such
/// memory", not resurrect it for a second `/memory forget`.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Memory {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT identity_id, statement, EXTRACT(EPOCH FROM recorded_at)::bigint FROM facts WHERE id = $1 AND status != 'retired';");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .identity_id = stmt.columnInt64(0),
        .text = try allocator.dupe(u8, stmt.columnText(1)),
        .created_at = stmt.columnInt64(2),
    };
}

/// Retires a fact (`status='retired'`, `valid_to=now()`) and writes a
/// tombstone recording what it said — never a hard delete, so provenance
/// survives (failure mode 4's "history is preserved" rule) and a future
/// auto-extraction pass can't silently resurrect the same statement (the
/// design brief's "honor forget absolutely" rule). Both writes happen in one
/// transaction, same `BEGIN`/`COMMIT`/`ROLLBACK`-as-plain-statements idiom
/// `messages.replaceRangeWithSummary` already uses (no shared transaction
/// helper exists yet). A nonexistent/already-retired id is a silent no-op —
/// callers (`main.zig`, `api/router.zig`) already call `get` first and only
/// reach here once ownership is confirmed.
pub fn forget(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var lookup = try db.prepare("SELECT identity_id, statement FROM facts WHERE id = $1 AND status != 'retired';");
    lookup.bindInt64(1, id);
    const found = try lookup.step();
    const identity_id: i64 = if (found) lookup.columnInt64(0) else 0;
    const statement: []const u8 = if (found) try db.allocator.dupe(u8, lookup.columnText(1)) else "";
    lookup.finalize();
    defer if (found) db.allocator.free(statement);
    if (!found) return;

    try db.exec("BEGIN;");
    errdefer db.exec("ROLLBACK;") catch |err| {
        std.log.err("facts: rollback failed after a forget error: {t}", .{err});
    };

    var retire = try db.prepare("UPDATE facts SET status = 'retired', valid_to = now() WHERE id = $1;");
    retire.bindInt64(1, id);
    _ = try retire.step();
    retire.finalize();

    var tomb = try db.prepare("INSERT INTO fact_tombstones (identity_id, pattern, reason, created_at) VALUES ($1, $2, 'explicit forget', now());");
    tomb.bindInt64(1, identity_id);
    tomb.bindText(2, statement);
    _ = try tomb.step();
    tomb.finalize();

    try db.exec("COMMIT;");
}

/// Cheap existence check `qa.zig`/`context_assembly.zig` use to skip the
/// embed-and-search round trip entirely for an identity with zero active
/// facts ever recorded — so someone who's never used this feature never
/// pays its per-question latency/cost.
pub fn hasAny(pool: *PgPool, identity_id: i64) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT 1 FROM facts WHERE identity_id = $1 AND status != 'retired' LIMIT 1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    return try stmt.step();
}

/// Every currently-pinned fact for one identity — the design brief's
/// "Pinned" context budget block: stable identity facts and standing
/// directives, always shown, never ranked (there are meant to be few of
/// these). Oldest first, matching `listForIdentity`.
pub fn pinnedForIdentity(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) ![]RankedFact {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT statement, status, confirmations, EXTRACT(EPOCH FROM valid_from)::bigint, EXTRACT(EPOCH FROM last_confirmed_at)::bigint
        \\FROM facts
        \\WHERE identity_id = $1 AND status = 'pinned' AND valid_to IS NULL
        \\ORDER BY valid_from ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    return collectRanked(&stmt, allocator);
}

fn collectRanked(stmt: *@import("db.zig").Stmt, allocator: std.mem.Allocator) ![]RankedFact {
    var out: std.ArrayList(RankedFact) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .statement = try allocator.dupe(u8, stmt.columnText(0)),
            .status = try allocator.dupe(u8, stmt.columnText(1)),
            .confirmations = @intCast(stmt.columnInt64(2)),
            .valid_from = stmt.columnInt64(3),
            .last_confirmed_at = stmt.columnInt64(4),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// The hybrid ranking formula shared by `rankedStable`/`rankedTentative` --
/// `0.40*vector_similarity + 0.25*fts_rank + 0.20*recency + 0.15*salience`,
/// the design brief's scoring formula. `ts_rank_cd` over a `tsvector` stands
/// in for the brief's `bm25()` term -- Postgres has no real BM25 built in.
/// Recency half-life is scope-dependent (identity facts effectively never
/// decay; projects decay fastest) and salience blends confirmation count
/// with a status multiplier, both computed in SQL rather than pulled back
/// and blended in Zig, since Postgres already has every input in scope.
/// The vector term is COALESCEd to 0 rather than used bare, which covers
/// both ways it can now be absent: a *row* with no embedding (stored on a
/// deployment with no embeddings endpoint -- see `remember`) and a *query*
/// with none (`$2` bound NULL for the same reason). Either makes `<=>`
/// yield NULL, which without this would poison the whole sum to NULL and
/// sort that row arbitrarily. Contributing 0 instead means such rows rank
/// on keyword, recency and salience alone. When no query vector is given at
/// all the term is 0 for every row uniformly, and since this is only ever
/// used for `ORDER BY score DESC`, dropping a constant from every row
/// leaves the ordering untouched -- no renormalising of the other weights
/// needed.
const hybrid_score_expr =
    \\(0.40 * COALESCE(1 - (embedding <=> $2::vector), 0)
    \\ + 0.25 * ts_rank_cd(to_tsvector('english', statement), plainto_tsquery('english', $3))
    \\ + 0.20 * exp(-EXTRACT(EPOCH FROM (to_timestamp($5) - valid_from)) / 86400.0 /
    \\     (CASE scope WHEN 'identity' THEN 36500.0 WHEN 'project' THEN 30.0 ELSE 90.0 END))
    \\ + 0.15 * (LEAST(1.0, confirmations / 3.0) *
    \\     (CASE status WHEN 'tentative' THEN 0.5 WHEN 'pinned' THEN 1.5 ELSE 1.0 END))
    \\) AS score
;

/// Top-`limit` `status='stable'` facts by hybrid score — the design brief's
/// "Retrieved facts" budget block, rendered alongside pinned facts under one
/// "About (stable)" heading by `context_assembly.zig`.
pub fn rankedStable(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, query_embedding: ?[]const f32, query_text: []const u8, limit: u32, now: i64) ![]RankedFact {
    return rankedByStatus(pool, allocator, identity_id, query_embedding, query_text, "stable", limit, now);
}

/// Top-`limit` `status='tentative'` facts by hybrid score -- the design
/// brief's "tentative suppression" filter: called with a small fixed
/// `limit` (see `context_assembly.zig`'s `tentative_facts_limit`), so only a
/// one-off remark that already ranks in the top few for *this* question ever
/// enters the prompt, under its own "possibly relevant, may be stale"
/// heading rather than blended in as settled fact (failure mode 3).
pub fn rankedTentative(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, query_embedding: ?[]const f32, query_text: []const u8, limit: u32, now: i64) ![]RankedFact {
    return rankedByStatus(pool, allocator, identity_id, query_embedding, query_text, "tentative", limit, now);
}

fn rankedByStatus(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, query_embedding: ?[]const f32, query_text: []const u8, status: []const u8, limit: u32, now: i64) ![]RankedFact {
    const db = try pool.acquire();
    defer pool.release(db);

    const vec_literal: ?[]const u8 = if (query_embedding) |q| try embeddings.formatVectorLiteral(allocator, q) else null;
    defer if (vec_literal) |v| allocator.free(v);

    const sql = try std.fmt.allocPrintSentinel(
        allocator,
        \\SELECT statement, status, confirmations, EXTRACT(EPOCH FROM valid_from)::bigint, EXTRACT(EPOCH FROM last_confirmed_at)::bigint, {s}
        \\FROM facts
        \\WHERE identity_id = $1 AND valid_to IS NULL AND status = '{s}'
        \\ORDER BY score DESC
        \\LIMIT $4;
    ,
        .{ hybrid_score_expr, status },
        0,
    );
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    if (vec_literal) |v| stmt.bindText(2, v) else stmt.bindNull(2);
    stmt.bindText(3, query_text);
    stmt.bindInt64(4, limit);
    stmt.bindInt64(5, now);
    return collectRanked(&stmt, allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

fn testIdentity(pool: *PgPool, native_id: []const u8) !i64 {
    return identities.upsertIdentity(pool, .{
        .platform = .telegram,
        .native_id = native_id,
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
}

/// The real `facts.embedding` column is `vector(1536)` and pgvector rejects
/// a mismatched dimension at insert time -- a real Postgres error, not just
/// a SQL-level formality -- so test vectors must actually be 1536-wide, not
/// a convenient short stand-in. `hot_index` set to 1.0, everything else
/// 0.0: cheap to build, and two vectors with different `hot_index`es are
/// maximally distant (orthogonal) under cosine distance, which is exactly
/// what the ordering tests below need.
const embedding_dimensions = @import("../llm/embeddings.zig").embedding_dimensions;

fn testVector(hot_index: usize) [embedding_dimensions]f32 {
    var v: [embedding_dimensions]f32 = @splat(0);
    v[hot_index] = 1.0;
    return v;
}

test "remember/listForIdentity/get/forget/hasAny" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const alice = try testIdentity(&pool, "1");

    try testing.expect(!try hasAny(&pool, alice));

    const id1 = try remember(&pool, a, alice, "prefers concise answers", &testVector(0), 1000);
    const id2 = try remember(&pool, a, alice, "working on a Zig project", &testVector(1), 2000);

    try testing.expect(try hasAny(&pool, alice));

    const listed = try listForIdentity(&pool, a, alice);
    defer {
        for (listed) |m| a.free(m.text);
        a.free(listed);
    }
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("prefers concise answers", listed[0].text);

    const mem = (try get(&pool, a, id1)) orelse return error.TestExpectedValue;
    defer a.free(mem.text);
    try testing.expectEqual(alice, mem.identity_id);
    try testing.expectEqualStrings("prefers concise answers", mem.text);

    try forget(&pool, id1);
    try testing.expectEqual(@as(?Memory, null), try get(&pool, a, id1));
    try forget(&pool, id2);
    try testing.expect(!try hasAny(&pool, alice));
}

test "forget retires the fact and writes a tombstone instead of deleting it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const alice = try testIdentity(&pool, "1");
    const id = try remember(&pool, a, alice, "hates cilantro", &testVector(0), 1000);
    try forget(&pool, id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    var row_stmt = try conn.prepare("SELECT status, valid_to IS NOT NULL FROM facts WHERE id = $1;");
    defer row_stmt.finalize();
    row_stmt.bindInt64(1, id);
    try testing.expect(try row_stmt.step());
    try testing.expectEqualStrings("retired", row_stmt.columnText(0));
    try testing.expect(row_stmt.columnBool(1));

    var tomb_stmt = try conn.prepare("SELECT pattern FROM fact_tombstones WHERE identity_id = $1;");
    defer tomb_stmt.finalize();
    tomb_stmt.bindInt64(1, alice);
    try testing.expect(try tomb_stmt.step());
    try testing.expectEqualStrings("hates cilantro", tomb_stmt.columnText(0));
}

test "search orders by cosine similarity to the query vector, scoped to one identity" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const alice = try testIdentity(&pool, "1");
    const bob = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "2",
        .display_name = "Bob",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    // Not a unit vector (magnitude sqrt(2)) -- cosine distance is
    // scale-invariant, so this is still closer to hot_index=0 than
    // hot_index=2 is, which is all the ordering assertion below needs.
    var close_vec = testVector(0);
    close_vec[5] = 0.9;

    _ = try remember(&pool, a, alice, "close match", &close_vec, 1000);
    _ = try remember(&pool, a, alice, "far match", &testVector(2), 2000);
    _ = try remember(&pool, a, bob, "bob's own memory, same vector as the close match", &close_vec, 1000);

    const results = try search(&pool, a, alice, &testVector(0), 5);
    defer {
        for (results) |m| a.free(m.text);
        a.free(results);
    }
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("close match", results[0].text);
    try testing.expectEqualStrings("far match", results[1].text);

    const top1 = try search(&pool, a, alice, &testVector(0), 1);
    defer {
        for (top1) |m| a.free(m.text);
        a.free(top1);
    }
    try testing.expectEqual(@as(usize, 1), top1.len);
}

test "pinnedForIdentity returns only pinned, active facts, oldest first" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const alice = try testIdentity(&pool, "1");
    _ = try remember(&pool, a, alice, "first pinned", &testVector(0), 1000);
    _ = try remember(&pool, a, alice, "second pinned", &testVector(1), 2000);

    const conn = try pool.acquire();
    // A tentative, non-pinned row (as an auto-extracted fact would look)
    // must not show up in the pinned block.
    var insert_tentative = try conn.prepare(
        \\INSERT INTO facts (identity_id, scope, predicate, object, statement, valid_from, recorded_at, last_confirmed_at, status, embedding)
        \\VALUES ($1, 'project', 'considering', 'Dagster', 'Considered switching to Dagster', to_timestamp(3000), to_timestamp(3000), to_timestamp(3000), 'tentative', $2);
    );
    const vec_literal = try embeddings.formatVectorLiteral(a, &testVector(2));
    defer a.free(vec_literal);
    insert_tentative.bindInt64(1, alice);
    insert_tentative.bindText(2, vec_literal);
    _ = try insert_tentative.step();
    insert_tentative.finalize();
    pool.release(conn);

    const pinned = try pinnedForIdentity(&pool, a, alice);
    defer {
        for (pinned) |f| {
            a.free(f.statement);
            a.free(f.status);
        }
        a.free(pinned);
    }
    try testing.expectEqual(@as(usize, 2), pinned.len);
    try testing.expectEqualStrings("first pinned", pinned[0].statement);
    try testing.expectEqualStrings("second pinned", pinned[1].statement);
}

test "rankedStable/rankedTentative split by status and rank by hybrid score" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const alice = try testIdentity(&pool, "1");
    const conn = try pool.acquire();

    const stable_vec = try embeddings.formatVectorLiteral(a, &testVector(0));
    defer a.free(stable_vec);
    var stable = try conn.prepare(
        \\INSERT INTO facts (identity_id, scope, predicate, object, statement, valid_from, recorded_at, last_confirmed_at, status, confirmations, embedding)
        \\VALUES ($1, 'preference', 'works_at', 'Ardent Logistics', 'Works at Ardent Logistics', to_timestamp(1000), to_timestamp(1000), to_timestamp(1000), 'stable', 5, $2);
    );
    stable.bindInt64(1, alice);
    stable.bindText(2, stable_vec);
    _ = try stable.step();
    stable.finalize();

    const tentative_vec = try embeddings.formatVectorLiteral(a, &testVector(1));
    defer a.free(tentative_vec);
    var tentative = try conn.prepare(
        \\INSERT INTO facts (identity_id, scope, predicate, object, statement, valid_from, recorded_at, last_confirmed_at, status, confirmations, embedding)
        \\VALUES ($1, 'project', 'considering', 'Dagster', 'Considered switching to Dagster', to_timestamp(2000), to_timestamp(2000), to_timestamp(2000), 'tentative', 1, $2);
    );
    tentative.bindInt64(1, alice);
    tentative.bindText(2, tentative_vec);
    _ = try tentative.step();
    tentative.finalize();
    pool.release(conn);

    const stable_results = try rankedStable(&pool, a, alice, &testVector(0), "Ardent Logistics", 5, 100_000);
    defer {
        for (stable_results) |f| {
            a.free(f.statement);
            a.free(f.status);
        }
        a.free(stable_results);
    }
    try testing.expectEqual(@as(usize, 1), stable_results.len);
    try testing.expectEqualStrings("Works at Ardent Logistics", stable_results[0].statement);

    const tentative_results = try rankedTentative(&pool, a, alice, &testVector(1), "Dagster", 3, 100_000);
    defer {
        for (tentative_results) |f| {
            a.free(f.statement);
            a.free(f.status);
        }
        a.free(tentative_results);
    }
    try testing.expectEqual(@as(usize, 1), tentative_results.len);
    try testing.expectEqualStrings("Considered switching to Dagster", tentative_results[0].statement);
}

test "remember works with no embedding at all, and the fact stays listable and rankable" {
    // The regression this guards: memory used to require an embeddings
    // endpoint. `remember` took a non-optional vector, the column was NOT
    // NULL, and `main.zig` only wired the tool up when a client existed --
    // so with no WARDEN_EMBEDDINGS_URL nothing could ever be stored, and
    // nothing said so. Storing a fact must not depend on that endpoint.
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const alice = try testIdentity(&pool, "1");
    const id = try remember(&pool, a, alice, "prefers concise answers", null, 1000);
    try testing.expect(id > 0);
    try testing.expect(try hasAny(&pool, alice));

    const listed = try listForIdentity(&pool, a, alice);
    defer {
        for (listed) |m| a.free(m.text);
        a.free(listed);
    }
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("prefers concise answers", listed[0].text);

    // remember() stores as 'pinned', which is the block an explicitly
    // remembered fact is meant to land in for prompt assembly.
    const pinned = try pinnedForIdentity(&pool, a, alice);
    defer {
        for (pinned) |f| {
            a.free(f.statement);
            a.free(f.status);
        }
        a.free(pinned);
    }
    try testing.expectEqual(@as(usize, 1), pinned.len);
    try testing.expectEqualStrings("prefers concise answers", pinned[0].statement);
}

test "ranking works with no query vector, and with rows that have no embedding" {
    // Both halves of "the vector is optional": a null query embedding (no
    // endpoint configured) and rows stored without one. Either makes the
    // `<=>` term NULL, which before the COALESCE in hybrid_score_expr would
    // have made the whole score NULL and ordered these rows arbitrarily --
    // here they must still come back, ranked on the remaining terms.
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const alice = try testIdentity(&pool, "1");

    var stmt = try db.prepare(
        \\INSERT INTO facts (identity_id, scope, predicate, object, statement, valid_from, recorded_at, last_confirmed_at, status, embedding)
        \\VALUES ($1, 'preference', 'likes', 'zig', 'writes Zig daily', to_timestamp(1000), to_timestamp(1000), to_timestamp(1000), 'stable', NULL);
    );
    defer stmt.finalize();
    stmt.bindInt64(1, alice);
    _ = try stmt.step();

    const stable = try rankedStable(&pool, a, alice, null, "what language do they use", 5, 2000);
    defer {
        for (stable) |f| {
            a.free(f.statement);
            a.free(f.status);
        }
        a.free(stable);
    }
    try testing.expectEqual(@as(usize, 1), stable.len);
    try testing.expectEqualStrings("writes Zig daily", stable[0].statement);

    // A query vector against rows that have none must behave the same way
    // rather than dropping them.
    const with_vector = try rankedStable(&pool, a, alice, &testVector(0), "what language do they use", 5, 2000);
    defer {
        for (with_vector) |f| {
            a.free(f.statement);
            a.free(f.status);
        }
        a.free(with_vector);
    }
    try testing.expectEqual(@as(usize, 1), with_vector.len);
}
