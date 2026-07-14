const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

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
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", false, 1000);

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
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", false, 1000);

    try setTokens(&pool, chat_id, identity_id, 3);
    try touch(&pool, chat_id, identity_id, 2000);
    try testing.expectEqual(@as(i64, 3), getTokens(&pool, chat_id, identity_id, 0));
}
