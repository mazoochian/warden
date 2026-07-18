const std = @import("std");

/// Parses a duration like "30m"/"2h"/"1d" into seconds. Deliberately
/// relative-only (no absolute "9am" times) — see the `0002_reminders.sql`
/// migration comment on why that sidesteps needing a timezone database.
/// Shared by the `/remind` command (`main.zig`) and the `set_reminder` LLM
/// tool (`tools/remind.zig`), which asks the model to translate whatever
/// natural-language time the user gave into this shorthand.
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
