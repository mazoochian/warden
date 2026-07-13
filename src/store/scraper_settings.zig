const std = @import("std");
const Db = @import("db.zig").Db;
const settings = @import("settings.zig");
const registry = @import("../tools/registry.zig");

/// Bot-wide (not per-chat) scraper configuration lives in the same
/// per-chat-settings mechanism as everything else, just under a reserved
/// chat id no real chat can ever have (Telegram chat ids are always
/// numeric) — avoids standing up a second storage mechanism for one knob
/// the owner needs to change at runtime.
pub const global_chat_id = "_global";

pub const Mode = registry.ScraperMode;
pub const Snapshot = registry.ScraperConfig;

const mode_key = "scraper_mode";
const remote_url_key = "scraper_remote_url";
const remote_api_key_key = "scraper_remote_api_key";

pub fn load(db: *Db, allocator: std.mem.Allocator) Snapshot {
    const mode: Mode = blk: {
        const raw = settings.getTextAlloc(db, allocator, mode_key) orelse break :blk .local;
        defer allocator.free(raw);
        break :blk if (std.mem.eql(u8, raw, "remote")) .remote else .local;
    };
    return .{
        .mode = mode,
        .remote_url = settings.getTextAlloc(db, allocator, remote_url_key),
        .remote_api_key = settings.getTextAlloc(db, allocator, remote_api_key_key),
    };
}

pub fn setMode(db: *Db, mode: Mode) !void {
    try settings.setText(db, mode_key, @tagName(mode));
}

/// Empty `url` clears it (see `settings.setText`'s empty-is-unset rule).
pub fn setRemoteUrl(db: *Db, url: []const u8) !void {
    try settings.setText(db, remote_url_key, url);
}

/// Empty `key` clears it.
pub fn setRemoteApiKey(db: *Db, key: []const u8) !void {
    try settings.setText(db, remote_api_key_key, key);
}

const testing = std.testing;
const schema = @import("schema.zig");
const Io = std.Io;

test "load defaults to local mode with nothing configured" {
    const dir = "zig-cache-test-scraper-settings-default";
    defer Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try Io.Dir.cwd().createDirPath(testing.io, dir);

    var db = try Db.open(dir ++ "/global.db");
    defer db.close();
    try schema.migrate(&db);

    const snap = load(&db, testing.allocator);
    defer {
        if (snap.remote_url) |u| testing.allocator.free(u);
        if (snap.remote_api_key) |k| testing.allocator.free(k);
    }
    try testing.expectEqual(Mode.local, snap.mode);
    try testing.expectEqual(@as(?[]const u8, null), snap.remote_url);
}

test "setMode/setRemoteUrl/setRemoteApiKey round trip through load" {
    const dir = "zig-cache-test-scraper-settings-roundtrip";
    defer Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try Io.Dir.cwd().createDirPath(testing.io, dir);

    var db = try Db.open(dir ++ "/global.db");
    defer db.close();
    try schema.migrate(&db);

    try setMode(&db, .remote);
    try setRemoteUrl(&db, "https://scraper.example/api");
    try setRemoteApiKey(&db, "s3cr3t");

    const snap = load(&db, testing.allocator);
    defer {
        if (snap.remote_url) |u| testing.allocator.free(u);
        if (snap.remote_api_key) |k| testing.allocator.free(k);
    }
    try testing.expectEqual(Mode.remote, snap.mode);
    try testing.expectEqualStrings("https://scraper.example/api", snap.remote_url.?);
    try testing.expectEqualStrings("s3cr3t", snap.remote_api_key.?);

    // Clearing the URL (empty = unset) doesn't clear the mode or key.
    try setRemoteUrl(&db, "");
    const snap2 = load(&db, testing.allocator);
    defer if (snap2.remote_api_key) |k| testing.allocator.free(k);
    try testing.expectEqual(@as(?[]const u8, null), snap2.remote_url);
    try testing.expectEqual(Mode.remote, snap2.mode);
}
