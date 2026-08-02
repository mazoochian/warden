const std = @import("std");
const PgPool = @import("pool.zig").PgPool;
const embeddings = @import("../llm/embeddings.zig");

/// One remembered fact about a person — see `0025_memories.sql`'s doc
/// comment and ROADMAP.md's Phase 12 for the "explicit remember/forget,
/// per-identity" scope decision. `embedding` isn't carried on this struct
/// (callers never need it back — only `search`'s own query needs a
/// vector, and that's a parameter, not a return value).
pub const Memory = struct {
    id: i64,
    identity_id: i64,
    text: []const u8,
    created_at: i64,
};

pub fn remember(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, text: []const u8, embedding: []const f32, created_at: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    // Scratch only -- `bindText` (below) copies this into `Stmt`'s own
    // arena immediately, so it's safe to free right after `step()`.
    const vec_literal = try embeddings.formatVectorLiteral(allocator, embedding);
    defer allocator.free(vec_literal);

    var stmt = try db.prepare(
        \\INSERT INTO memories (identity_id, text, embedding, created_at)
        \\VALUES ($1, $2, $3, to_timestamp($4))
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    stmt.bindText(2, text);
    stmt.bindText(3, vec_literal);
    stmt.bindInt64(4, created_at);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// The `limit` closest memories to `query_embedding` for one identity, by
/// cosine distance (pgvector's `<=>` operator — smaller is more similar).
/// No approximate index (see the migration's doc comment on why); a plain
/// sequential scan is fine at the row counts a personal bot's memory
/// table will ever reach.
pub fn search(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, query_embedding: []const f32, limit: u32) ![]Memory {
    const db = try pool.acquire();
    defer pool.release(db);

    // Scratch only -- `bindText` copies this into `Stmt`'s own arena
    // immediately, same reasoning as `remember`'s own vec_literal.
    const vec_literal = try embeddings.formatVectorLiteral(allocator, query_embedding);
    defer allocator.free(vec_literal);

    var stmt = try db.prepare(
        \\SELECT id, text, EXTRACT(EPOCH FROM created_at)::bigint
        \\FROM memories
        \\WHERE identity_id = $1
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

/// Every memory for one identity, oldest first — for `/memory list`.
pub fn listForIdentity(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) ![]Memory {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, text, EXTRACT(EPOCH FROM created_at)::bigint
        \\FROM memories WHERE identity_id = $1
        \\ORDER BY created_at ASC;
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

/// `null` if no such memory exists — used by `/memory forget` to check
/// ownership before deleting, same pattern as `notes.get`.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Memory {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT identity_id, text, EXTRACT(EPOCH FROM created_at)::bigint FROM memories WHERE id = $1;");
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

pub fn forget(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM memories WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

/// Cheap existence check `qa.zig` uses to skip the embed-and-search round
/// trip entirely for an identity with zero memories ever recorded — so
/// someone who's never used this feature never pays its per-question
/// latency/cost.
pub fn hasAny(pool: *PgPool, identity_id: i64) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT 1 FROM memories WHERE identity_id = $1 LIMIT 1;");
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    return try stmt.step();
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

/// The real `memories.embedding` column is `vector(1536)` (see
/// `0025_memories.sql`) and pgvector rejects a mismatched dimension at
/// insert time -- a real Postgres error, not just a SQL-level formality --
/// so test vectors must actually be 1536-wide, not a convenient short
/// stand-in. `hot_index` set to 1.0, everything else 0.0: cheap to build,
/// and two vectors with different `hot_index`es are maximally distant
/// (orthogonal) under cosine distance, which is exactly what the ordering
/// test below needs.
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
