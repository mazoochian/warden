const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;
const civil_time = @import("../text/civil_time.zig");

/// Rough, DST-ignorant "typical UTC offset for this locale" table — the
/// default a personal `utc_offset_minutes` setting starts at before the
/// user ever touches it, derived from Telegram's `language_code` (the only
/// locale hint any connector's API actually exposes; there is no
/// timezone/region field anywhere to key off instead). Matched exactly
/// first (e.g. "en-GB"), then by the base language subtag before any `-`
/// (e.g. "en"). Deliberately small and approximate — a real per-user
/// override (`setUtcOffsetMinutes`) always wins over this, and this is
/// only ever a first guess, not a source of truth.
const language_code_offsets = [_]struct { code: []const u8, offset_minutes: i32 }{
    .{ .code = "en-gb", .offset_minutes = 0 },
    .{ .code = "en-us", .offset_minutes = -300 },
    .{ .code = "en-au", .offset_minutes = 600 },
    .{ .code = "en-ca", .offset_minutes = -300 },
    .{ .code = "en-in", .offset_minutes = 330 },
    .{ .code = "en-nz", .offset_minutes = 720 },
    .{ .code = "en", .offset_minutes = 0 },
    .{ .code = "fa-ir", .offset_minutes = 210 },
    .{ .code = "fa", .offset_minutes = 210 },
    .{ .code = "ar-sa", .offset_minutes = 180 },
    .{ .code = "ar", .offset_minutes = 0 },
    .{ .code = "de", .offset_minutes = 60 },
    .{ .code = "fr", .offset_minutes = 60 },
    .{ .code = "es-mx", .offset_minutes = -360 },
    .{ .code = "es", .offset_minutes = 60 },
    .{ .code = "it", .offset_minutes = 60 },
    .{ .code = "pt-br", .offset_minutes = -180 },
    .{ .code = "pt", .offset_minutes = 0 },
    .{ .code = "ru", .offset_minutes = 180 },
    .{ .code = "ja", .offset_minutes = 540 },
    .{ .code = "zh", .offset_minutes = 480 },
    .{ .code = "ko", .offset_minutes = 540 },
    .{ .code = "hi", .offset_minutes = 330 },
    .{ .code = "tr", .offset_minutes = 180 },
    .{ .code = "nl", .offset_minutes = 60 },
    .{ .code = "pl", .offset_minutes = 60 },
    .{ .code = "sv", .offset_minutes = 60 },
    .{ .code = "id", .offset_minutes = 420 },
    .{ .code = "th", .offset_minutes = 420 },
    .{ .code = "vi", .offset_minutes = 420 },
    .{ .code = "uk", .offset_minutes = 120 },
    .{ .code = "el", .offset_minutes = 120 },
    .{ .code = "he", .offset_minutes = 120 },
};

/// `null` if `language_code` matches nothing in the table above.
pub fn offsetForLanguageCode(a: std.mem.Allocator, language_code: []const u8) ?i32 {
    const lower = std.ascii.allocLowerString(a, language_code) catch return null;
    defer a.free(lower);
    for (language_code_offsets) |entry| {
        if (std.mem.eql(u8, entry.code, lower)) return entry.offset_minutes;
    }
    const base = if (std.mem.indexOfScalar(u8, lower, '-')) |dash| lower[0..dash] else lower;
    for (language_code_offsets) |entry| {
        if (std.mem.eql(u8, entry.code, base)) return entry.offset_minutes;
    }
    return null;
}

fn upsertColumn(pool: *PgPool, identity_id: i64, comptime column: []const u8, value: anytype) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        "INSERT INTO user_settings (identity_id, " ++ column ++ ") VALUES ($1, $2) " ++
            "ON CONFLICT (identity_id) DO UPDATE SET " ++ column ++ " = excluded." ++ column ++ ";",
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    switch (@TypeOf(value)) {
        ?i32 => if (value) |v| stmt.bindInt64(2, v) else stmt.bindNull(2),
        ?[]const u8 => if (value) |v| stmt.bindText(2, v) else stmt.bindNull(2),
        else => @compileError("upsertColumn: unsupported value type"),
    }
    _ = try stmt.step();
}

/// `null` clears the override (falls back to the `language_code` guess).
pub fn setUtcOffsetMinutes(pool: *PgPool, identity_id: i64, value: ?i32) !void {
    try upsertColumn(pool, identity_id, "utc_offset_minutes", value);
}

pub fn setDateFormat(pool: *PgPool, identity_id: i64, format: ?civil_time.DateFormat) !void {
    const value: ?[]const u8 = if (format) |f| @tagName(f) else null;
    try upsertColumn(pool, identity_id, "date_format", value);
}

pub fn setTimeFormat(pool: *PgPool, identity_id: i64, format: ?civil_time.TimeFormat) !void {
    try upsertColumn(pool, identity_id, "time_format", if (format) |f| tagForTimeFormat(f) else null);
}

fn tagForTimeFormat(f: civil_time.TimeFormat) []const u8 {
    return switch (f) {
        .h24 => "24h",
        .h12 => "12h",
    };
}

const Row = struct {
    utc_offset_minutes: ?i32,
    date_format: ?[]const u8,
    time_format: ?[]const u8,
    language_code: ?[]const u8,
};

/// One query joining `user_settings` and `telegram_profiles` — every
/// `getEffective*` function below reads from this instead of round-
/// tripping separately, since they all need the same row.
fn loadRow(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) ?Row {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare(
        \\SELECT us.utc_offset_minutes, us.date_format, us.time_format, tp.language_code
        \\FROM identities i
        \\LEFT JOIN user_settings us ON us.identity_id = i.id
        \\LEFT JOIN telegram_profiles tp ON tp.identity_id = i.id
        \\WHERE i.id = $1;
    ) catch return null;
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    const has_row = stmt.step() catch return null;
    if (!has_row) return null;
    return .{
        .utc_offset_minutes = if (stmt.columnIsNull(0)) null else @intCast(stmt.columnInt64(0)),
        .date_format = if (stmt.columnIsNull(1)) null else allocator.dupe(u8, stmt.columnText(1)) catch null,
        .time_format = if (stmt.columnIsNull(2)) null else allocator.dupe(u8, stmt.columnText(2)) catch null,
        .language_code = if (stmt.columnIsNull(3)) null else allocator.dupe(u8, stmt.columnText(3)) catch null,
    };
}

/// `loadRow` dupes its string fields (so they outlive the statement it read
/// them from) — every `getEffective*` below must free them before
/// returning, since they only ever need to read the row once.
fn freeRow(allocator: std.mem.Allocator, row: Row) void {
    if (row.date_format) |v| allocator.free(v);
    if (row.time_format) |v| allocator.free(v);
    if (row.language_code) |v| allocator.free(v);
}

/// Explicit override, else a `language_code`-derived guess, else UTC (0).
/// Fails closed to UTC on any lookup error — never blocks a reminder over
/// a transient DB hiccup.
pub fn getEffectiveOffsetMinutes(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) i32 {
    const row = loadRow(pool, allocator, identity_id) orelse return 0;
    defer freeRow(allocator, row);
    if (row.utc_offset_minutes) |v| return v;
    const lang = row.language_code orelse return 0;
    return offsetForLanguageCode(allocator, lang) orelse 0;
}

/// Explicit override, else `.mdy` (matches this codebase's existing
/// American-English-oriented tone elsewhere, e.g. `reminder_format.zig`'s
/// own docs/tests already use M/D-shaped examples).
pub fn getEffectiveDateFormat(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) civil_time.DateFormat {
    const row = loadRow(pool, allocator, identity_id) orelse return .mdy;
    defer freeRow(allocator, row);
    const raw = row.date_format orelse return .mdy;
    return std.meta.stringToEnum(civil_time.DateFormat, raw) orelse .mdy;
}

/// Explicit override, else `.h24`.
pub fn getEffectiveTimeFormat(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64) civil_time.TimeFormat {
    const row = loadRow(pool, allocator, identity_id) orelse return .h24;
    defer freeRow(allocator, row);
    const raw = row.time_format orelse return .h24;
    if (std.mem.eql(u8, raw, "12h")) return .h12;
    return .h24;
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

test "offsetForLanguageCode matches exact locale, then base language, else null" {
    const a = testing.allocator;
    try testing.expectEqual(@as(?i32, 0), offsetForLanguageCode(a, "en-GB"));
    try testing.expectEqual(@as(?i32, -300), offsetForLanguageCode(a, "en-US"));
    try testing.expectEqual(@as(?i32, 210), offsetForLanguageCode(a, "fa-XX")); // no exact match, falls back to base "fa"
    try testing.expectEqual(@as(?i32, null), offsetForLanguageCode(a, "xx-yy"));
}

test "getEffectiveOffsetMinutes: override beats language_code guess beats UTC default" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const no_profile = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try testing.expectEqual(@as(i32, 0), getEffectiveOffsetMinutes(&pool, a, no_profile));

    const with_lang = try identities.upsertTelegramUser(&pool, .{
        .identity = .{ .platform = .telegram, .native_id = "2", .display_name = "Bob", .first_seen = 1000, .last_seen = 1000 },
        .language_code = "fa-IR",
    });
    try testing.expectEqual(@as(i32, 210), getEffectiveOffsetMinutes(&pool, a, with_lang));

    try setUtcOffsetMinutes(&pool, with_lang, -180);
    try testing.expectEqual(@as(i32, -180), getEffectiveOffsetMinutes(&pool, a, with_lang));

    try setUtcOffsetMinutes(&pool, with_lang, null);
    try testing.expectEqual(@as(i32, 210), getEffectiveOffsetMinutes(&pool, a, with_lang));
}

test "getEffectiveDateFormat/getEffectiveTimeFormat default then respect an explicit setting" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try testing.expectEqual(civil_time.DateFormat.mdy, getEffectiveDateFormat(&pool, a, id));
    try testing.expectEqual(civil_time.TimeFormat.h24, getEffectiveTimeFormat(&pool, a, id));

    try setDateFormat(&pool, id, .dmy);
    try setTimeFormat(&pool, id, .h12);
    try testing.expectEqual(civil_time.DateFormat.dmy, getEffectiveDateFormat(&pool, a, id));
    try testing.expectEqual(civil_time.TimeFormat.h12, getEffectiveTimeFormat(&pool, a, id));
}
