const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const registry = @import("../tools/registry.zig");

/// Bot-wide (not per-chat) config — replaces the old `scraper_settings.zig`,
/// which stored these same values in the per-chat KV mechanism under a
/// reserved fake chat id (`"_global"`) purely because there was no other
/// storage mechanism available. A real `bot_config` table needs no such
/// workaround.
pub const Mode = registry.ScraperMode;
pub const Snapshot = registry.ScraperConfig;

const mode_key = "scraper_mode";
const remote_url_key = "scraper_remote_url";
const remote_api_key_key = "scraper_remote_api_key";

pub fn getText(pool: *PgPool, allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT value FROM bot_config WHERE key = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, key);
    const has_row = stmt.step() catch return null;
    if (!has_row) return null;
    return allocator.dupe(u8, stmt.columnText(0)) catch null;
}

pub fn setText(pool: *PgPool, key: []const u8, value: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO bot_config (key, value) VALUES ($1, $2)
        \\ON CONFLICT (key) DO UPDATE SET value = excluded.value;
    );
    defer stmt.finalize();
    stmt.bindText(1, key);
    stmt.bindText(2, value);
    _ = try stmt.step();
}

pub fn clear(pool: *PgPool, key: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM bot_config WHERE key = $1;");
    defer stmt.finalize();
    stmt.bindText(1, key);
    _ = try stmt.step();
}

pub fn loadScraperConfig(pool: *PgPool, allocator: std.mem.Allocator) Snapshot {
    const mode: Mode = blk: {
        const raw = getText(pool, allocator, mode_key) orelse break :blk .local;
        defer allocator.free(raw);
        break :blk if (std.mem.eql(u8, raw, "remote")) .remote else .local;
    };
    return .{
        .mode = mode,
        .remote_url = getText(pool, allocator, remote_url_key),
        .remote_api_key = getText(pool, allocator, remote_api_key_key),
    };
}

pub fn setScraperMode(pool: *PgPool, mode: Mode) !void {
    try setText(pool, mode_key, @tagName(mode));
}

/// `null` clears it.
pub fn setScraperRemoteUrl(pool: *PgPool, url: ?[]const u8) !void {
    if (url) |u| try setText(pool, remote_url_key, u) else try clear(pool, remote_url_key);
}

/// `null` clears it.
pub fn setScraperRemoteApiKey(pool: *PgPool, key: ?[]const u8) !void {
    if (key) |k| try setText(pool, remote_api_key_key, k) else try clear(pool, remote_api_key_key);
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "loadScraperConfig defaults to local mode with nothing configured" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const snap = loadScraperConfig(&pool, testing.allocator);
    defer {
        if (snap.remote_url) |u| testing.allocator.free(u);
        if (snap.remote_api_key) |k| testing.allocator.free(k);
    }
    try testing.expectEqual(Mode.local, snap.mode);
    try testing.expectEqual(@as(?[]const u8, null), snap.remote_url);
}

test "setScraperMode/setScraperRemoteUrl/setScraperRemoteApiKey round trip through loadScraperConfig" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    try setScraperMode(&pool, .remote);
    try setScraperRemoteUrl(&pool, "https://scraper.example/api");
    try setScraperRemoteApiKey(&pool, "s3cr3t");

    const snap = loadScraperConfig(&pool, testing.allocator);
    defer {
        if (snap.remote_url) |u| testing.allocator.free(u);
        if (snap.remote_api_key) |k| testing.allocator.free(k);
    }
    try testing.expectEqual(Mode.remote, snap.mode);
    try testing.expectEqualStrings("https://scraper.example/api", snap.remote_url.?);
    try testing.expectEqualStrings("s3cr3t", snap.remote_api_key.?);

    try setScraperRemoteUrl(&pool, null);
    const snap2 = loadScraperConfig(&pool, testing.allocator);
    defer if (snap2.remote_api_key) |k| testing.allocator.free(k);
    try testing.expectEqual(@as(?[]const u8, null), snap2.remote_url);
    try testing.expectEqual(Mode.remote, snap2.mode);
}
