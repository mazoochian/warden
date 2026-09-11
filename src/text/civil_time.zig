const std = @import("std");

pub const DateFormat = enum { mdy, dmy, ymd };
pub const TimeFormat = enum { h24, h12 };

pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
};

pub const Weekday = enum(u3) { sunday, monday, tuesday, wednesday, thursday, friday, saturday };

/// Day of the week for a `daysFromCivil`-style day count. 1970-01-01 (day
/// 0) was a Thursday, so `days + 4` lands Sunday=0..Saturday=6; `@mod` on a
/// positive divisor is always non-negative in Zig regardless of `days`'
/// sign, so this holds for pre-epoch dates too.
pub fn weekdayFromDays(days: i64) Weekday {
    return @enumFromInt(@as(u3, @intCast(@mod(days + 4, 7))));
}

pub fn weekdayName(w: Weekday) []const u8 {
    return switch (w) {
        .sunday => "Sunday",
        .monday => "Monday",
        .tuesday => "Tuesday",
        .wednesday => "Wednesday",
        .thursday => "Thursday",
        .friday => "Friday",
        .saturday => "Saturday",
    };
}

/// Days since the Unix epoch (1970-01-01) for a given proleptic-Gregorian
/// civil date — Howard Hinnant's well-known constant-time algorithm
/// (public domain: http://howardhinnant.github.io/date_algorithms.html),
/// correct for any year (including negative ones) and exact leap-year
/// handling, without a loop or a lookup table. No calendar math existed
/// anywhere in this codebase before — see `reminder_format.zig`'s own
/// "deliberately naive about timezones" doc comment, which this replaces
/// for anything that now cares about a per-user offset/format.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else @as(i64, year);
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = @mod(@as(i64, month) + 9, 12); // [0, 11], Mar=0 .. Feb=11
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Inverse of `daysFromCivil` — same algorithm, same source.
pub fn civilFromDays(days: i64) struct { year: i32, month: u8, day: u8 } {
    const z = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp: i64 = @divFloor(5 * doy + 2, 153); // [0, 11]
    const day: i64 = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const month: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    const year: i64 = if (month <= 2) y + 1 else y;
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

const seconds_per_day: i64 = 86400;

/// The widest unix timestamps `localFromUnix` will render — 0001-01-01 and
/// 9999-12-31, the range a four-digit year covers. Anything outside is
/// clamped to the nearest end rather than converted.
///
/// Clamped rather than asserted because these timestamps arrive from
/// Postgres rows and from arithmetic on user input, not from constants: a
/// `reminders.due_at` written by hand, or one `reminder_format.nextOccurrence`
/// saturated to `maxInt(i64)` on an absurd recur interval, used to abort the
/// process here instead of showing a date — `civilFromDays` would hand a year
/// around 2.9e11 to an `i32`, and the offset addition below overflowed i64
/// outright. That turned every listing that touches the row (`/reminders`,
/// `GET /api/v1/reminders`, the menu's reminder list) into a crash, which is
/// exactly the path a stuck row is supposed to be fixed from.
pub const min_unix: i64 = -62135596800;
pub const max_unix: i64 = 253402300799;

/// Splits a unix timestamp into local calendar/clock components under a
/// fixed UTC offset (see `civil_time.zig`'s module doc comment for why a
/// fixed offset, not a real DST-aware zone). Out-of-range timestamps are
/// clamped to `min_unix`/`max_unix` — see their doc comment.
pub fn localFromUnix(unix_ts: i64, offset_minutes: i32) Civil {
    // Clamped before the offset is applied as well as after, so the addition
    // itself can't overflow: the clamped value leaves i64 room to spare for
    // any offset a timezone can hold.
    const clamped = std.math.clamp(unix_ts, min_unix, max_unix);
    const local_ts = std.math.clamp(clamped + @as(i64, offset_minutes) * 60, min_unix, max_unix);
    const days = @divFloor(local_ts, seconds_per_day);
    const secs_of_day = local_ts - days * seconds_per_day;
    const ymd = civilFromDays(days);
    return .{
        .year = ymd.year,
        .month = ymd.month,
        .day = ymd.day,
        .hour = @intCast(@divFloor(secs_of_day, 3600)),
        .minute = @intCast(@mod(@divFloor(secs_of_day, 60), 60)),
        .second = @intCast(@mod(secs_of_day, 60)),
    };
}

/// Inverse of `localFromUnix`.
pub fn unixFromLocal(c: Civil, offset_minutes: i32) i64 {
    const days = daysFromCivil(c.year, c.month, c.day);
    const local_ts = days * seconds_per_day + @as(i64, c.hour) * 3600 + @as(i64, c.minute) * 60 + c.second;
    return local_ts - @as(i64, offset_minutes) * 60;
}

/// Adds `delta_days` to a civil date, correctly rolling over month/year
/// boundaries either direction — the date-stepper wizard's ±1-day button.
pub fn addDays(c: Civil, delta_days: i64) Civil {
    var out = c;
    const ymd = civilFromDays(daysFromCivil(c.year, c.month, c.day) + delta_days);
    out.year = ymd.year;
    out.month = ymd.month;
    out.day = ymd.day;
    return out;
}

pub fn formatDate(a: std.mem.Allocator, c: Civil, format: DateFormat) []const u8 {
    return switch (format) {
        .mdy => std.fmt.allocPrint(a, "{d}/{d}/{d}", .{ c.month, c.day, c.year }) catch "?",
        .dmy => std.fmt.allocPrint(a, "{d}/{d}/{d}", .{ c.day, c.month, c.year }) catch "?",
        .ymd => std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ c.year, c.month, c.day }) catch "?",
    };
}

pub fn formatTime(a: std.mem.Allocator, c: Civil, format: TimeFormat) []const u8 {
    return switch (format) {
        .h24 => std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ c.hour, c.minute }) catch "?",
        .h12 => blk: {
            const is_pm = c.hour >= 12;
            var hour12 = c.hour % 12;
            if (hour12 == 0) hour12 = 12;
            break :blk std.fmt.allocPrint(a, "{d}:{d:0>2} {s}", .{ hour12, c.minute, if (is_pm) "PM" else "AM" }) catch "?";
        },
    };
}

const testing = std.testing;

test "daysFromCivil/civilFromDays round-trip known dates, including the epoch and pre-epoch dates" {
    const cases = [_]struct { y: i32, m: u8, d: u8, days: i64 }{
        .{ .y = 1970, .m = 1, .d = 1, .days = 0 },
        .{ .y = 1969, .m = 12, .d = 31, .days = -1 },
        .{ .y = 2000, .m = 2, .d = 29, .days = 11016 }, // leap day
        .{ .y = 2026, .m = 5, .d = 22, .days = 20595 },
        .{ .y = 1900, .m = 3, .d = 1, .days = -25508 }, // 1900 is NOT a leap year (divisible by 100, not 400)
    };
    for (cases) |c| {
        try testing.expectEqual(c.days, daysFromCivil(c.y, c.m, c.d));
        const back = civilFromDays(c.days);
        try testing.expectEqual(c.y, back.year);
        try testing.expectEqual(c.m, back.month);
        try testing.expectEqual(c.d, back.day);
    }
}

test "weekdayFromDays matches known weekdays, including pre-epoch dates" {
    // 1970-01-01 (day 0) was a Thursday.
    try testing.expectEqual(Weekday.thursday, weekdayFromDays(0));
    try testing.expectEqual(Weekday.friday, weekdayFromDays(1));
    try testing.expectEqual(Weekday.wednesday, weekdayFromDays(-1));
    try testing.expectEqual(Weekday.sunday, weekdayFromDays(-4));
    // 2026-08-01 is a Saturday.
    try testing.expectEqual(Weekday.saturday, weekdayFromDays(daysFromCivil(2026, 8, 1)));
}

test "weekdayName covers every day" {
    try testing.expectEqualStrings("Sunday", weekdayName(.sunday));
    try testing.expectEqualStrings("Saturday", weekdayName(.saturday));
}

test "localFromUnix/unixFromLocal round-trip across positive, negative, and half-hour offsets" {
    const offsets = [_]i32{ 0, 210, -300, -330 }; // UTC, +3:30 (Tehran), -5:00 (EST), -5:30
    const ts: i64 = 1_774_000_000; // some arbitrary real-ish instant
    for (offsets) |off| {
        const c = localFromUnix(ts, off);
        try testing.expectEqual(ts, unixFromLocal(c, off));
    }
}

test "localFromUnix clamps an out-of-range timestamp instead of aborting" {
    // Both of these used to panic rather than return: the first on
    // `civilFromDays`'s `@intCast` to an `i32` year, the second on the
    // offset addition overflowing i64 before it even got there. Reachable
    // from a `reminders.due_at` that `nextOccurrence` parked at `maxInt`.
    const far_future = localFromUnix(std.math.maxInt(i64), 0);
    try testing.expectEqual(@as(i32, 9999), far_future.year);
    try testing.expectEqual(@as(u8, 12), far_future.month);
    try testing.expectEqual(@as(u8, 31), far_future.day);

    const with_offset = localFromUnix(std.math.maxInt(i64), 210);
    try testing.expectEqual(@as(i32, 9999), with_offset.year);

    const far_past = localFromUnix(std.math.minInt(i64), -300);
    try testing.expectEqual(@as(i32, 1), far_past.year);
    try testing.expectEqual(@as(u8, 1), far_past.month);
    try testing.expectEqual(@as(u8, 1), far_past.day);

    // In-range timestamps are untouched by the clamp.
    try testing.expectEqual(@as(i32, 1970), localFromUnix(0, 0).year);
}

test "localFromUnix applies the offset before splitting into calendar components" {
    // 1970-01-01 00:30 UTC, offset -60 (one hour behind) -> still 1969-12-31 23:30 local.
    const c = localFromUnix(30 * 60, -60);
    try testing.expectEqual(@as(i32, 1969), c.year);
    try testing.expectEqual(@as(u8, 12), c.month);
    try testing.expectEqual(@as(u8, 31), c.day);
    try testing.expectEqual(@as(u8, 23), c.hour);
    try testing.expectEqual(@as(u8, 30), c.minute);
}

test "addDays rolls over month and year boundaries in both directions" {
    const jan1: Civil = .{ .year = 2026, .month = 1, .day = 1 };
    const dec31_prev = addDays(jan1, -1);
    try testing.expectEqual(@as(i32, 2025), dec31_prev.year);
    try testing.expectEqual(@as(u8, 12), dec31_prev.month);
    try testing.expectEqual(@as(u8, 31), dec31_prev.day);

    const feb28: Civil = .{ .year = 2026, .month = 2, .day = 28 };
    const mar1 = addDays(feb28, 1);
    try testing.expectEqual(@as(u8, 3), mar1.month);
    try testing.expectEqual(@as(u8, 1), mar1.day);
}

test "formatDate renders mdy/dmy/ymd correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: Civil = .{ .year = 2026, .month = 5, .day = 22, .hour = 13, .minute = 37 };

    try testing.expectEqualStrings("5/22/2026", formatDate(a, c, .mdy));
    try testing.expectEqualStrings("22/5/2026", formatDate(a, c, .dmy));
    try testing.expectEqualStrings("2026-05-22", formatDate(a, c, .ymd));
}

test "formatTime renders 24h and 12h correctly, including midnight/noon edge cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("13:37", formatTime(a, .{ .year = 0, .month = 1, .day = 1, .hour = 13, .minute = 37 }, .h24));
    try testing.expectEqualStrings("1:37 PM", formatTime(a, .{ .year = 0, .month = 1, .day = 1, .hour = 13, .minute = 37 }, .h12));
    try testing.expectEqualStrings("12:00 AM", formatTime(a, .{ .year = 0, .month = 1, .day = 1, .hour = 0, .minute = 0 }, .h12));
    try testing.expectEqualStrings("12:00 PM", formatTime(a, .{ .year = 0, .month = 1, .day = 1, .hour = 12, .minute = 0 }, .h12));
}
