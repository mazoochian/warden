const std = @import("std");
const Db = @import("db.zig").Db;

/// Simple per-chat key/value settings (digest on/off, last-digest
/// timestamp, etc.), stored in that chat's own `chat_settings` table — so
/// like everything else, settings are local to each chat, not global.
// `getBool`/`getInt` deliberately do NOT factor out a shared "get the raw
// column text" helper that returns before finalizing: `sqlite3_column_text`
// is only valid until the next `step`/`reset`/`finalize` call, so a helper
// that finalized (via `defer`) and then handed back the column's `[]const
// u8` would return a dangling pointer the instant it returned — the caller
// would be comparing/parsing already-freed memory. Each function below
// reads and fully consumes (compares or parses into a plain bool/i64)
// the column text while its own statement is still alive, before its own
// `defer stmt.finalize()` runs.

pub fn getBool(db: *Db, key: []const u8, default: bool) bool {
    var stmt = db.prepare("SELECT value FROM chat_settings WHERE key = ?;") catch return default;
    defer stmt.finalize();
    stmt.bindText(1, key);
    const has_row = stmt.step() catch return default;
    if (!has_row) return default;
    return std.mem.eql(u8, stmt.columnText(0), "1");
}

pub fn setBool(db: *Db, key: []const u8, value: bool) !void {
    return setText(db, key, if (value) "1" else "0");
}

pub fn getInt(db: *Db, key: []const u8, default: i64) i64 {
    var stmt = db.prepare("SELECT value FROM chat_settings WHERE key = ?;") catch return default;
    defer stmt.finalize();
    stmt.bindText(1, key);
    const has_row = stmt.step() catch return default;
    if (!has_row) return default;
    return std.fmt.parseInt(i64, stmt.columnText(0), 10) catch default;
}

pub fn getTokens(db: *Db, user_id: []const u8, default: i64) i64 {
    var stmt = db.prepare("SELECT tokens FROM users WHERE user_id = ?;") catch return default;
    defer stmt.finalize();
    stmt.bindText(1, user_id);
    const has_row = stmt.step() catch return default;
    if (!has_row) return default;
    return std.fmt.parseInt(i64, stmt.columnText(0), 10) catch default;
}

pub fn setTokens(db: *Db, user_id: []const u8, value: i64) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    var stmt = try db.prepare("UPDATE users SET tokens = ? WHERE user_id = ?;");
    defer stmt.finalize();
    stmt.bindText(1, text);
    stmt.bindText(2, user_id);
    _ = try stmt.step();
}

pub fn setInt(db: *Db, key: []const u8, value: i64) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    return setText(db, key, text);
}

/// Returns the setting's value duplicated into `allocator` (the column text
/// itself dies with the statement — see the module comment above), or null
/// when unset/empty. Empty is treated as unset so clearing a setting can be
/// done by writing "".
pub fn getTextAlloc(db: *Db, allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    var stmt = db.prepare("SELECT value FROM chat_settings WHERE key = ?;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, key);
    const has_row = stmt.step() catch return null;
    if (!has_row) return null;
    const value = stmt.columnText(0);
    if (value.len == 0) return null;
    return allocator.dupe(u8, value) catch null;
}

pub fn setText(db: *Db, key: []const u8, value: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO chat_settings (key, value) VALUES (?, ?)
        \\ON CONFLICT(key) DO UPDATE SET value=excluded.value;
    );
    defer stmt.finalize();
    stmt.bindText(1, key);
    stmt.bindText(2, value);
    _ = try stmt.step();
}

const testing = std.testing;

test "getBool/setBool round trip with a default when unset" {
    const dir = "zig-cache-test-settings";
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);

    var db = try Db.open(dir ++ "/settings.db");
    defer db.close();
    try @import("schema.zig").migrate(&db);

    try testing.expect(!getBool(&db, "digest_enabled", false));
    try setBool(&db, "digest_enabled", true);
    try testing.expect(getBool(&db, "digest_enabled", false));

    try testing.expectEqual(@as(i64, 0), getInt(&db, "last_digest_ts", 0));
    try setInt(&db, "last_digest_ts", 12345);
    try testing.expectEqual(@as(i64, 12345), getInt(&db, "last_digest_ts", 0));
}

test "getTextAlloc/setText round trip; empty value reads back as unset" {
    const dir = "zig-cache-test-settings-text";
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);

    var db = try Db.open(dir ++ "/settings.db");
    defer db.close();
    try @import("schema.zig").migrate(&db);

    try testing.expectEqual(@as(?[]const u8, null), getTextAlloc(&db, testing.allocator, "magic_word"));

    try setText(&db, "magic_word", "hassan");
    const value = getTextAlloc(&db, testing.allocator, "magic_word") orelse return error.TestExpectedValue;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("hassan", value);

    try setText(&db, "magic_word", "");
    try testing.expectEqual(@as(?[]const u8, null), getTextAlloc(&db, testing.allocator, "magic_word"));
}
