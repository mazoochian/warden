const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const Platform = @import("../platform/interface.zig").Platform;

pub const default_check_interval_seconds: i64 = 900;

/// A watch due to be re-checked, joined with `chats` for the native chat id
/// and platform `checkAndNotifyFeeds` needs to pick the right connector
/// (same reasoning as `reminders.DueReminder`/`alerts.AlertToCheck`).
/// `seen_guids` null means this feed has never been checked before —
/// distinct from an empty (but non-null) slice, which means it *was*
/// checked and genuinely had nothing.
///
/// A set, not a single watermark — found live 2026-07-20: a feed whose
/// `<item>`s aren't reliably newest-first (a pinned/featured story sitting
/// at position 0 regardless of publish date) broke the old
/// scan-from-the-top-stop-at-the-watermark dedup permanently, since the
/// stale pinned item never moved off position 0. Set membership doesn't
/// care about item order at all.
pub const DueFeedWatch = struct {
    id: i64,
    native_chat_id: []const u8,
    platform: Platform,
    feed_url: []const u8,
    seen_guids: ?[]const []const u8,
};

/// One row for `/watches`.
pub const FeedWatchRow = struct {
    id: i64,
    feed_url: []const u8,
};

/// Adds a watch, or does nothing if this chat is already watching this
/// exact URL — returns whether a new row was actually created (a caller
/// can tell "just started watching" from "already watching this one").
pub fn create(pool: *PgPool, chat_id: i64, identity_id: i64, feed_url: []const u8) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO feed_watches (chat_id, identity_id, feed_url)
        \\VALUES ($1, $2, $3)
        \\ON CONFLICT (chat_id, feed_url) DO NOTHING
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, feed_url);
    return try stmt.step();
}

/// Removes a watch by its natural key (chat + URL) — open to anyone in the
/// chat, same as `/digest on|off`, not restricted to whoever added it.
/// Returns whether a row actually existed to remove.
pub fn remove(pool: *PgPool, chat_id: i64, feed_url: []const u8) !bool {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM feed_watches WHERE chat_id = $1 AND feed_url = $2 RETURNING id;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, feed_url);
    return try stmt.step();
}

/// Every watch for one chat.
pub fn listPending(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]FeedWatchRow {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, feed_url FROM feed_watches WHERE chat_id = $1 ORDER BY id ASC;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(FeedWatchRow) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .feed_url = try allocator.dupe(u8, stmt.columnText(1)),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Every watch whose check interval has elapsed (or has never been
/// checked), across all chats — same shape/reasoning as
/// `alerts.dueForCheck`.
pub fn dueForCheck(pool: *PgPool, allocator: std.mem.Allocator, now: i64) ![]DueFeedWatch {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT f.id, c.native_chat_id, c.platform, f.feed_url, f.seen_guids_json
        \\FROM feed_watches f JOIN chats c ON c.id = f.chat_id
        \\WHERE f.last_checked_at IS NULL
        \\   OR EXTRACT(EPOCH FROM (to_timestamp($1) - f.last_checked_at)) >= f.check_interval_seconds;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, now);

    var out: std.ArrayList(DueFeedWatch) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
            .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
            .feed_url = try allocator.dupe(u8, stmt.columnText(3)),
            .seen_guids = if (stmt.columnIsNull(4)) null else try parseSeenGuidsJson(allocator, stmt.columnText(4)),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Looks up exactly one watch by its natural key, regardless of whether
/// it's actually due for a check yet — the manual `/watchcheck <url>` path
/// uses this instead of `dueForCheck`, since forcing an immediate check is
/// the whole point (see `features/feed_watcher.zig`'s `checkOne`, shared
/// by both the scheduled batch loop and the manual command so they can
/// never drift apart).
pub fn getOne(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, feed_url: []const u8) !?DueFeedWatch {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT f.id, c.native_chat_id, c.platform, f.feed_url, f.seen_guids_json
        \\FROM feed_watches f JOIN chats c ON c.id = f.chat_id
        \\WHERE f.chat_id = $1 AND f.feed_url = $2;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, feed_url);
    if (!(try stmt.step())) return null;

    return .{
        .id = stmt.columnInt64(0),
        .native_chat_id = try allocator.dupe(u8, stmt.columnText(1)),
        .platform = std.meta.stringToEnum(Platform, stmt.columnText(2)) orelse .telegram,
        .feed_url = try allocator.dupe(u8, stmt.columnText(3)),
        .seen_guids = if (stmt.columnIsNull(4)) null else try parseSeenGuidsJson(allocator, stmt.columnText(4)),
    };
}

/// Records that this feed was just checked and which item guids it
/// currently has (so the next check can diff against this set) — called
/// regardless of whether any new items were actually found or announced.
/// Caller should cap `guids` to a reasonable window (see
/// `feed_watcher.zig`'s `max_tracked_guids`) — this just persists whatever
/// it's given.
pub fn markChecked(pool: *PgPool, allocator: std.mem.Allocator, id: i64, now: i64, guids: []const []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    const json_text = try serializeSeenGuidsJson(allocator, guids);
    defer allocator.free(json_text);

    var stmt = try db.prepare("UPDATE feed_watches SET last_checked_at = to_timestamp($2), seen_guids_json = $3 WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindInt64(2, now);
    stmt.bindText(3, json_text);
    _ = try stmt.step();
}

fn parseSeenGuidsJson(allocator: std.mem.Allocator, json_text: []const u8) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice([]const []const u8, allocator, json_text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const out = try allocator.alloc([]const u8, parsed.value.len);
    for (parsed.value, 0..) |g, i| out[i] = try allocator.dupe(u8, g);
    return out;
}

fn serializeSeenGuidsJson(allocator: std.mem.Allocator, guids: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(guids, .{}, &out.writer);
    return out.toOwnedSlice();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "create/dueForCheck/markChecked/listPending/remove" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // First add: created.
    try testing.expect(try create(&pool, chat_id, identity_id, "https://example.com/feed.xml"));
    // Same chat + URL again: not created (already watching).
    try testing.expect(!(try create(&pool, chat_id, identity_id, "https://example.com/feed.xml")));

    const due = try dueForCheck(&pool, a, 1000);
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqualStrings("https://example.com/feed.xml", due[0].feed_url);
    try testing.expectEqual(@as(?[]const []const u8, null), due[0].seen_guids);

    try markChecked(&pool, a, due[0].id, 1000, &.{ "guid-1", "guid-2" });
    try testing.expectEqual(@as(usize, 0), (try dueForCheck(&pool, a, 1010)).len);
    const due2 = try dueForCheck(&pool, a, 1000 + default_check_interval_seconds + 1);
    try testing.expectEqual(@as(usize, 2), due2[0].seen_guids.?.len);
    try testing.expectEqualStrings("guid-1", due2[0].seen_guids.?[0]);
    try testing.expectEqualStrings("guid-2", due2[0].seen_guids.?[1]);

    // getOne finds it regardless of due-status (it's not due again until
    // default_check_interval_seconds has passed).
    const found = (try getOne(&pool, a, chat_id, "https://example.com/feed.xml")).?;
    try testing.expectEqual(due[0].id, found.id);
    try testing.expectEqual(@as(?DueFeedWatch, null), try getOne(&pool, a, chat_id, "https://example.com/nonexistent.xml"));

    const pending = try listPending(&pool, a, chat_id);
    try testing.expectEqual(@as(usize, 1), pending.len);

    try testing.expect(try remove(&pool, chat_id, "https://example.com/feed.xml"));
    try testing.expectEqual(@as(usize, 0), (try listPending(&pool, a, chat_id)).len);
    // Removing again: nothing to remove.
    try testing.expect(!(try remove(&pool, chat_id, "https://example.com/feed.xml")));
}
