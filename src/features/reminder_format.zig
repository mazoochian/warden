const std = @import("std");

/// Parses a duration like "30m"/"2h"/"1d" into seconds. Deliberately
/// relative-only (no timezone conversion) — see `parseAbsoluteTime`'s doc
/// comment on why absolute times stay a simple clock-time match rather than
/// a real calendar/timezone computation. Shared by the `/remind` command
/// (`main.zig`) and the `set_reminder` LLM tool (`tools/remind.zig`), which
/// asks the model to translate whatever natural-language time the user gave
/// into this shorthand.
pub fn parseDuration(text: []const u8) ?i64 {
    if (text.len < 2) return null;
    const unit = text[text.len - 1];
    const n = std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch return null;
    if (n <= 0) return null;
    const multiplier: i64 = switch (unit) {
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return null,
    };
    return n * multiplier;
}

/// Parses a 24h clock time like "9:00" or "14:30" and resolves it to the
/// next absolute unix timestamp at or after `now` that matches that
/// time-of-day — today if it hasn't passed yet, tomorrow otherwise.
/// Deliberately naive about timezones: `now` is treated as already being in
/// whatever clock the operator cares about (server-local or UTC, same
/// tradeoff `scheduler.zig`'s doc comment makes for digests) rather than
/// doing a real tz-database conversion — good enough for a personal bot
/// with one owner, not a multi-timezone scheduling system.
pub fn parseAbsoluteTime(text: []const u8, now: i64) ?i64 {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const hour = std.fmt.parseInt(i64, text[0..colon], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[colon + 1 ..], 10) catch return null;
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59) return null;

    const seconds_per_day = 86400;
    const day_start = @divFloor(now, seconds_per_day) * seconds_per_day;
    const candidate = day_start + hour * 3600 + minute * 60;
    return if (candidate > now) candidate else candidate + seconds_per_day;
}

/// Unified entry point for anything that names a single point in time to
/// fire at: tries the relative-duration shorthand first (`parseDuration`,
/// returning `now + that many seconds`), then a "HH:MM" absolute clock time
/// (`parseAbsoluteTime`). Returns an absolute unix timestamp either way, or
/// null if `text` matches neither shape.
pub fn parseWhen(text: []const u8, now: i64) ?i64 {
    if (parseDuration(text)) |secs| return now + secs;
    return parseAbsoluteTime(text, now);
}

/// Advances a recurring reminder's `due_at` to the next occurrence strictly
/// after `now`, jumping past however many intervals have already elapsed in
/// one step — so a reminder that missed several firings (bot was down,
/// clock skew) doesn't fire once per missed interval in a burst, just once
/// for "now" and resumes its normal cadence from there.
pub fn nextOccurrence(due_at: i64, interval_seconds: i64, now: i64) i64 {
    if (interval_seconds <= 0 or due_at > now) return due_at;
    const overdue_by = now - due_at;
    const missed = @divFloor(overdue_by, interval_seconds) + 1;
    return due_at + missed * interval_seconds;
}

/// Renders a recur interval back into compact shorthand ("1d", "2h", "30m")
/// for `/reminders`' "(repeats every ...)" display — picks the largest unit
/// that divides evenly, falling back to seconds for anything that doesn't
/// (which shouldn't happen for anything `parseDuration` itself produced).
pub fn formatInterval(a: std.mem.Allocator, interval_seconds: i64) []const u8 {
    if (@mod(interval_seconds, 86400) == 0) return std.fmt.allocPrint(a, "{d}d", .{@divExact(interval_seconds, 86400)}) catch "some time";
    if (@mod(interval_seconds, 3600) == 0) return std.fmt.allocPrint(a, "{d}h", .{@divExact(interval_seconds, 3600)}) catch "some time";
    if (@mod(interval_seconds, 60) == 0) return std.fmt.allocPrint(a, "{d}m", .{@divExact(interval_seconds, 60)}) catch "some time";
    return std.fmt.allocPrint(a, "{d}s", .{interval_seconds}) catch "some time";
}

/// Renders seconds-until-due as a compact human string ("45s", "12m",
/// "3h 5m", "2d 1h"). Negative/zero clamps to 0 rather than showing a
/// confusing negative duration for a reminder that's about to fire.
pub fn formatRemaining(a: std.mem.Allocator, remaining_seconds: i64) []const u8 {
    const secs = @max(remaining_seconds, 0);
    if (secs < 60) return std.fmt.allocPrint(a, "{d}s", .{secs}) catch "soon";
    const minutes = @divTrunc(secs, 60);
    if (minutes < 60) return std.fmt.allocPrint(a, "{d}m", .{minutes}) catch "soon";
    const hours = @divTrunc(minutes, 60);
    if (hours < 24) return std.fmt.allocPrint(a, "{d}h {d}m", .{ hours, @mod(minutes, 60) }) catch "soon";
    const days = @divTrunc(hours, 24);
    return std.fmt.allocPrint(a, "{d}d {d}h", .{ days, @mod(hours, 24) }) catch "soon";
}

const testing = std.testing;

test "parseDuration accepts m/h/d shorthand and rejects garbage" {
    try testing.expectEqual(@as(?i64, 1800), parseDuration("30m"));
    try testing.expectEqual(@as(?i64, 7200), parseDuration("2h"));
    try testing.expectEqual(@as(?i64, 86400), parseDuration("1d"));
    try testing.expectEqual(@as(?i64, null), parseDuration("30"));
    try testing.expectEqual(@as(?i64, null), parseDuration("m"));
    try testing.expectEqual(@as(?i64, null), parseDuration("0m"));
    try testing.expectEqual(@as(?i64, null), parseDuration("-5m"));
    try testing.expectEqual(@as(?i64, null), parseDuration("5x"));
}

test "parseAbsoluteTime resolves today if not yet passed, tomorrow otherwise" {
    // now = 1970-01-01 12:00:00 UTC (43200s into day 0).
    const noon: i64 = 12 * 3600;
    // 14:30 hasn't happened yet today.
    try testing.expectEqual(@as(?i64, 14 * 3600 + 30 * 60), parseAbsoluteTime("14:30", noon));
    // 9:00 already passed today, so it resolves to tomorrow.
    try testing.expectEqual(@as(?i64, 86400 + 9 * 3600), parseAbsoluteTime("9:00", noon));
    // Exactly now is treated as already passed (must be strictly after).
    try testing.expectEqual(@as(?i64, 86400 + noon), parseAbsoluteTime("12:00", noon));

    try testing.expectEqual(@as(?i64, null), parseAbsoluteTime("25:00", noon));
    try testing.expectEqual(@as(?i64, null), parseAbsoluteTime("14:60", noon));
    try testing.expectEqual(@as(?i64, null), parseAbsoluteTime("garbage", noon));
    try testing.expectEqual(@as(?i64, null), parseAbsoluteTime("2h", noon));
}

test "parseWhen tries a relative duration before an absolute time" {
    try testing.expectEqual(@as(?i64, 1000 + 1800), parseWhen("30m", 1000));
    try testing.expectEqual(@as(?i64, 14 * 3600 + 30 * 60), parseWhen("14:30", 0));
    try testing.expectEqual(@as(?i64, null), parseWhen("nonsense", 0));
}

test "nextOccurrence jumps straight past every missed interval in one step" {
    // Not yet due: unchanged.
    try testing.expectEqual(@as(i64, 2000), nextOccurrence(2000, 3600, 1000));
    // Due exactly now: advances by exactly one interval.
    try testing.expectEqual(@as(i64, 1000 + 3600), nextOccurrence(1000, 3600, 1000));
    // Missed several firings while "down": jumps to the first occurrence
    // strictly after `now`, not one-by-one.
    try testing.expectEqual(@as(i64, 0 + 5 * 3600), nextOccurrence(0, 3600, 4 * 3600 + 10));
}

test "formatInterval picks the largest evenly-dividing unit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("1d", formatInterval(a, 86400));
    try testing.expectEqualStrings("2h", formatInterval(a, 7200));
    try testing.expectEqualStrings("30m", formatInterval(a, 1800));
    try testing.expectEqualStrings("90s", formatInterval(a, 90));
}

test "formatRemaining scales units and clamps negatives to 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("0s", formatRemaining(a, -10));
    try testing.expectEqualStrings("45s", formatRemaining(a, 45));
    try testing.expectEqualStrings("12m", formatRemaining(a, 12 * 60));
    try testing.expectEqualStrings("3h 5m", formatRemaining(a, 3 * 3600 + 5 * 60));
    try testing.expectEqualStrings("2d 1h", formatRemaining(a, 2 * 86400 + 3600));
}
