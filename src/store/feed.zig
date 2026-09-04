const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One channel the curated feed reads. See `0051_curated_feed.sql` for why
/// sources are opt-in rather than "every channel the account follows".
pub const Source = struct {
    id: i64,
    native_chat_id: []const u8,
    title: []const u8,
    last_seen_message_id: i64,
    enabled: bool,
};

/// The feed's single-row configuration. `target_native_chat_id` and
/// `policy` are both required before the feed does anything at all — a feed
/// with no policy would mean "forward everything", which is the opposite of
/// the point, and one with no destination has nowhere to post.
pub const Settings = struct {
    target_native_chat_id: ?[]const u8,
    policy: ?[]const u8,
    interval_seconds: i64,
    enabled: bool,
    last_run_at: i64,

    /// Whether a scheduled pass should actually do anything. Checked in one
    /// place so the command handlers, the scheduler and the web API can't
    /// drift on what "configured" means.
    pub fn isRunnable(self: Settings) bool {
        return self.enabled and self.target_native_chat_id != null and self.policy != null;
    }
};

/// Adds (or re-enables) a source. Idempotent on `native_chat_id`: adding a
/// channel already followed refreshes its title and turns it back on
/// without resetting the watermark, so re-adding never replays a backlog.
pub fn addSource(pool: *PgPool, native_chat_id: []const u8, title: []const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO feed_sources (native_chat_id, title) VALUES ($1, $2)
        \\ON CONFLICT (native_chat_id) DO UPDATE SET title = excluded.title, enabled = TRUE
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindText(1, native_chat_id);
    stmt.bindText(2, title);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Returns whether a source was actually removed, so a caller can tell
/// "removed" from "wasn't being watched in the first place".
pub fn removeSource(pool: *PgPool, native_chat_id: []const u8) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM feed_sources WHERE native_chat_id = $1 RETURNING 1;");
    defer stmt.finalize();
    stmt.bindText(1, native_chat_id);
    return stmt.step() catch false;
}

/// Every source, oldest first. `enabled_only` for the scheduler; the full
/// list for `/feed list` and the web UI, which should still show a source
/// that's been paused.
pub fn listSources(pool: *PgPool, allocator: std.mem.Allocator, enabled_only: bool) ![]Source {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, native_chat_id, title, last_seen_message_id, enabled
        \\FROM feed_sources
        \\WHERE ($1 = FALSE OR enabled)
        \\ORDER BY added_at;
    );
    defer stmt.finalize();
    stmt.bindBool(1, enabled_only);

    var out: std.ArrayList(Source) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .title = try allocator.dupe(u8, stmt.columnText(2)),
            .last_seen_message_id = stmt.columnInt64(3),
            .enabled = stmt.columnBool(4),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Moves a source's watermark forward. Deliberately `GREATEST`, never a
/// plain assignment: passes can overlap (a slow LLM pass while the next
/// tick fires) and a stale pass writing its lower id back would replay
/// posts that were already summarised.
pub fn setWatermark(pool: *PgPool, id: i64, last_seen_message_id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE feed_sources SET last_seen_message_id = GREATEST(last_seen_message_id, $2) WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, last_seen_message_id);
    _ = try stmt.step();
}

pub fn setSourceEnabled(pool: *PgPool, native_chat_id: []const u8, enabled: bool) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE feed_sources SET enabled = $2 WHERE native_chat_id = $1 RETURNING 1;");
    defer stmt.finalize();
    stmt.bindText(1, native_chat_id);
    stmt.bindBool(2, enabled);
    return stmt.step() catch false;
}

pub fn getSettings(pool: *PgPool, allocator: std.mem.Allocator) !Settings {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT target_native_chat_id, policy, interval_seconds, enabled,
        \\       COALESCE(EXTRACT(EPOCH FROM last_run_at)::bigint, 0)
        \\FROM feed_settings WHERE id = 1;
    );
    defer stmt.finalize();
    if (!try stmt.step()) return .{
        .target_native_chat_id = null,
        .policy = null,
        .interval_seconds = 3600,
        .enabled = false,
        .last_run_at = 0,
    };
    return .{
        .target_native_chat_id = if (stmt.columnIsNull(0)) null else try allocator.dupe(u8, stmt.columnText(0)),
        .policy = if (stmt.columnIsNull(1)) null else try allocator.dupe(u8, stmt.columnText(1)),
        .interval_seconds = stmt.columnInt64(2),
        .enabled = stmt.columnBool(3),
        .last_run_at = stmt.columnInt64(4),
    };
}

pub fn setTarget(pool: *PgPool, native_chat_id: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE feed_settings SET target_native_chat_id = $1 WHERE id = 1;");
    defer stmt.finalize();
    if (native_chat_id) |c| stmt.bindText(1, c) else stmt.bindNull(1);
    _ = try stmt.step();
}

pub fn setPolicy(pool: *PgPool, policy: ?[]const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE feed_settings SET policy = $1 WHERE id = 1;");
    defer stmt.finalize();
    if (policy) |p| stmt.bindText(1, p) else stmt.bindNull(1);
    _ = try stmt.step();
}

pub fn setEnabled(pool: *PgPool, enabled: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE feed_settings SET enabled = $1 WHERE id = 1;");
    defer stmt.finalize();
    stmt.bindBool(1, enabled);
    _ = try stmt.step();
}

pub fn setIntervalSeconds(pool: *PgPool, interval_seconds: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE feed_settings SET interval_seconds = $1 WHERE id = 1;");
    defer stmt.finalize();
    stmt.bindInt64(1, interval_seconds);
    _ = try stmt.step();
}

/// Stamps a completed pass. Called even when a pass produced no digest —
/// "we looked and there was nothing" is still a run, and not recording it
/// would make the scheduler retry every tick.
pub fn markRun(pool: *PgPool, now: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE feed_settings SET last_run_at = to_timestamp($1) WHERE id = 1;");
    defer stmt.finalize();
    stmt.bindInt64(1, now);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");

fn freeSources(items: []Source) void {
    for (items) |s| {
        testing.allocator.free(s.native_chat_id);
        testing.allocator.free(s.title);
    }
    testing.allocator.free(items);
}

fn freeSettings(s: Settings) void {
    if (s.target_native_chat_id) |t| testing.allocator.free(t);
    if (s.policy) |p| testing.allocator.free(p);
}

test "addSource is idempotent and never rewinds a watermark" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const id = try addSource(&pool, "-100123", "World News");
    try setWatermark(&pool, id, 500);

    // Re-adding refreshes the title but must not replay the backlog.
    const again = try addSource(&pool, "-100123", "World News HD");
    try testing.expectEqual(id, again);

    const listed = try listSources(&pool, a, false);
    defer freeSources(listed);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("World News HD", listed[0].title);
    try testing.expectEqual(@as(i64, 500), listed[0].last_seen_message_id);
}

test "setWatermark only ever moves forward" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const id = try addSource(&pool, "-100123", "World News");
    try setWatermark(&pool, id, 500);
    // A slow pass finishing after a newer one must not rewind and cause
    // already-summarised posts to be replayed.
    try setWatermark(&pool, id, 200);

    const listed = try listSources(&pool, a, false);
    defer freeSources(listed);
    try testing.expectEqual(@as(i64, 500), listed[0].last_seen_message_id);
}

test "listSources can exclude disabled sources" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    _ = try addSource(&pool, "-100123", "World News");
    _ = try addSource(&pool, "-100456", "Sports");
    try testing.expect(try setSourceEnabled(&pool, "-100456", false));

    const enabled = try listSources(&pool, a, true);
    defer freeSources(enabled);
    try testing.expectEqual(@as(usize, 1), enabled.len);
    try testing.expectEqualStrings("World News", enabled[0].title);

    // ...but a paused source still shows in the full list, so it can be
    // turned back on rather than silently disappearing.
    const all = try listSources(&pool, a, false);
    defer freeSources(all);
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "removeSource reports whether anything was watched" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try testing.expect(!try removeSource(&pool, "-100123"));
    _ = try addSource(&pool, "-100123", "World News");
    try testing.expect(try removeSource(&pool, "-100123"));
    try testing.expect(!try removeSource(&pool, "-100123"));
}

test "settings default to inert, and stay inert until both target and policy are set" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    {
        const s = try getSettings(&pool, a);
        defer freeSettings(s);
        try testing.expect(!s.enabled);
        try testing.expect(!s.isRunnable());
        try testing.expectEqual(@as(i64, 3600), s.interval_seconds);
    }

    // Enabled alone is not enough: with no destination and no policy there
    // is nothing sensible to do, and "post everything somewhere" is exactly
    // the failure mode to avoid.
    try setEnabled(&pool, true);
    {
        const s = try getSettings(&pool, a);
        defer freeSettings(s);
        try testing.expect(!s.isRunnable());
    }

    try setTarget(&pool, "-100999");
    {
        const s = try getSettings(&pool, a);
        defer freeSettings(s);
        try testing.expect(!s.isRunnable());
    }

    try setPolicy(&pool, "international news only");
    {
        const s = try getSettings(&pool, a);
        defer freeSettings(s);
        try testing.expect(s.isRunnable());
        try testing.expectEqualStrings("-100999", s.target_native_chat_id.?);
        try testing.expectEqualStrings("international news only", s.policy.?);
    }
}

test "markRun stamps the pass so the scheduler doesn't retry every tick" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    try markRun(&pool, 1700000000);
    const s = try getSettings(&pool, a);
    defer freeSettings(s);
    try testing.expectEqual(@as(i64, 1700000000), s.last_run_at);
}
