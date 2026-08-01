const std = @import("std");
const civil_time = @import("../text/civil_time.zig");

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

const weekday_names = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };

fn parseWeekdayName(text: []const u8) ?civil_time.Weekday {
    for (weekday_names, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(text, name)) return @enumFromInt(@as(u3, @intCast(i)));
    }
    return null;
}

/// Time of day a bare weekday name resolves to when the user didn't also
/// give a clock time ("remind me Friday") — a reminder needs *some* time,
/// and a quiet early-morning default reads as "sometime that day" rather
/// than implying anything more specific was meant.
const default_weekday_hour: u8 = 6;

/// Parses a weekday name ("friday"), optionally followed by a space and a
/// 24h clock time ("friday 18:00"), and resolves it to the next absolute
/// unix timestamp at or after `now` that lands on that weekday — today if
/// today *is* that weekday and the time (default `default_weekday_hour`:00
/// if none given) hasn't passed yet, otherwise the coming occurrence a week
/// out at most. This is what makes "remind me this Friday" correct without
/// the caller (the LLM, for `tools/remind.zig`) ever having to know what
/// day of the week today is — the model has no reliable notion of the
/// current date, so asking it to compute "Friday is N days from now"
/// itself was silently landing on the wrong day (including today, if its
/// guess for today's weekday happened to already be Friday). Same
/// "deliberately naive about timezones" tradeoff as `parseAbsoluteTime`.
pub fn parseWeekdayWhen(text: []const u8, now: i64) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    var day_text: []const u8 = trimmed;
    var hour: u8 = default_weekday_hour;
    var minute: u8 = 0;
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        day_text = trimmed[0..sp];
        const clock = parseClockTime(std.mem.trim(u8, trimmed[sp + 1 ..], " \t")) orelse return null;
        hour = clock.hour;
        minute = clock.minute;
    }
    const target = parseWeekdayName(day_text) orelse return null;

    const seconds_per_day = 86400;
    const today_days = @divFloor(now, seconds_per_day);
    const today = civil_time.weekdayFromDays(today_days);
    var delta_days: i64 = @as(i64, @intFromEnum(target)) - @as(i64, @intFromEnum(today));
    if (delta_days < 0) delta_days += 7;

    const day_start = today_days * seconds_per_day;
    const candidate = day_start + delta_days * seconds_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
    return if (candidate > now) candidate else candidate + 7 * seconds_per_day;
}

/// Unified entry point for anything that names a single point in time to
/// fire at: tries the relative-duration shorthand first (`parseDuration`,
/// returning `now + that many seconds`), then a "HH:MM" absolute clock time
/// (`parseAbsoluteTime`), then a weekday name (`parseWeekdayWhen`). Returns
/// an absolute unix timestamp either way, or null if `text` matches none of
/// those shapes.
pub fn parseWhen(text: []const u8, now: i64) ?i64 {
    if (parseDuration(text)) |secs| return now + secs;
    if (parseAbsoluteTime(text, now)) |ts| return ts;
    return parseWeekdayWhen(text, now);
}

pub const DateParts = struct { year: ?i32, month: u8, day: u8 };

/// Parses a date with no time component: ISO `Y-M-D` (always available,
/// `-`-separated), or `/`-separated `M/D[/Y]`/`D/M[/Y]` per `format` (`.ymd`
/// falls back to `Y/M/D` for the `/` form, mirroring the `-` one). Year is
/// optional only in the `/` form; a 2-digit year is treated as 2000+yy.
/// `null` on anything malformed — deliberately not validating day-of-month
/// against the actual days in `month` (`civil_time.daysFromCivil` already
/// normalizes an out-of-range day rather than rejecting it, same tradeoff).
/// Exported (not just used internally by `parseWhenLocal`) since `menu.zig`'s
/// reminder wizard reuses it for its "reply with a date to jump there" text
/// shortcut.
pub fn parseDatePart(text: []const u8, format: civil_time.DateFormat) ?DateParts {
    if (std.mem.indexOfScalar(u8, text, '-') != null) {
        var it = std.mem.splitScalar(u8, text, '-');
        const y = it.next() orelse return null;
        const m = it.next() orelse return null;
        const d = it.next() orelse return null;
        if (it.next() != null) return null;
        const year = std.fmt.parseInt(i32, y, 10) catch return null;
        const month = std.fmt.parseInt(u8, m, 10) catch return null;
        const day = std.fmt.parseInt(u8, d, 10) catch return null;
        if (month < 1 or month > 12 or day < 1 or day > 31) return null;
        return .{ .year = year, .month = month, .day = day };
    }
    if (std.mem.indexOfScalar(u8, text, '/') != null) {
        var it = std.mem.splitScalar(u8, text, '/');
        const first = it.next() orelse return null;
        const second = it.next() orelse return null;
        const third = it.next();
        if (third != null and it.next() != null) return null;

        const first_val = std.fmt.parseInt(u8, first, 10) catch return null;
        const second_val = std.fmt.parseInt(u8, second, 10) catch return null;
        var month: u8 = undefined;
        var day: u8 = undefined;
        switch (format) {
            .dmy => {
                day = first_val;
                month = second_val;
            },
            .mdy, .ymd => {
                month = first_val;
                day = second_val;
            },
        }
        if (month < 1 or month > 12 or day < 1 or day > 31) return null;

        var year: ?i32 = null;
        if (third) |t| {
            const y_val = std.fmt.parseInt(i32, t, 10) catch return null;
            year = if (y_val < 100) 2000 + y_val else y_val;
        }
        return .{ .year = year, .month = month, .day = day };
    }
    return null;
}

/// Parses a bare 24h clock time like "9:00" or "14:30" into its components
/// (no date, no rollover — just validates ranges). Exported for
/// `menu.zig`'s reminder wizard's "reply with a time to jump there" text
/// shortcut; `parseWhenLocal` below uses it too instead of duplicating the
/// same two lines.
pub fn parseClockTime(text: []const u8) ?struct { hour: u8, minute: u8 } {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const hour = std.fmt.parseInt(u8, text[0..colon], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[colon + 1 ..], 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    return .{ .hour = hour, .minute = minute };
}

/// Timezone-aware, date-capable sibling of `parseWhen` — the wizard/`/menu`
/// era's entry point, tried by `/remind`/`/reminders` instead of the naive
/// version above (which stays for `tools/remind.zig`'s LLM tool, which
/// already gets an absolute-feeling instruction and has no per-user offset
/// wired to it). `offset_minutes`/`date_format` come from
/// `store/user_settings.zig`'s `getEffectiveOffsetMinutes`/
/// `getEffectiveDateFormat` for whoever is setting the reminder.
///
/// Accepted shapes, tried in order:
///  - relative duration (`30m`/`2h`/`1d`) — unchanged, timezone-irrelevant.
///  - bare `HH:MM` — resolves against *local* now (today if not yet passed,
///    else tomorrow), same rollover rule `parseAbsoluteTime` uses.
///  - `<date> HH:MM` — an explicit calendar date (see `parseDatePart`)
///    followed by a time, both interpreted in the local offset. A year
///    omitted from `<date>` defaults to the local current year, rolling to
///    next year if that local moment has already passed (mirroring the
///    bare-time rollover one level up); an explicit year is trusted as-is
///    even if it's already past.
///  - a bare date with no time defaults to 09:00 local — good enough for
///    anyone who doesn't care about the exact time; the wizard is the real
///    path for that.
pub fn parseWhenLocal(text: []const u8, now: i64, offset_minutes: i32, date_format: civil_time.DateFormat) ?i64 {
    if (parseDuration(text)) |secs| return now + secs;

    const trimmed = std.mem.trim(u8, text, " \t");
    var date_text: ?[]const u8 = null;
    var time_text: []const u8 = trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        date_text = trimmed[0..sp];
        time_text = std.mem.trim(u8, trimmed[sp + 1 ..], " \t");
    } else if (std.mem.indexOfScalar(u8, trimmed, ':') == null and
        (std.mem.indexOfScalar(u8, trimmed, '/') != null or std.mem.indexOfScalar(u8, trimmed, '-') != null))
    {
        date_text = trimmed;
        time_text = "09:00";
    }

    const clock = parseClockTime(time_text) orelse return null;
    const hour = clock.hour;
    const minute = clock.minute;

    const local_now = civil_time.localFromUnix(now, offset_minutes);

    if (date_text) |dt| {
        const parts = parseDatePart(dt, date_format) orelse return null;
        const year = parts.year orelse local_now.year;
        const civil: civil_time.Civil = .{ .year = year, .month = parts.month, .day = parts.day, .hour = hour, .minute = minute };
        const ts = civil_time.unixFromLocal(civil, offset_minutes);
        if (parts.year == null and ts <= now) {
            const rolled: civil_time.Civil = .{ .year = year + 1, .month = parts.month, .day = parts.day, .hour = hour, .minute = minute };
            return civil_time.unixFromLocal(rolled, offset_minutes);
        }
        return ts;
    }

    const candidate: civil_time.Civil = .{ .year = local_now.year, .month = local_now.month, .day = local_now.day, .hour = hour, .minute = minute };
    const ts = civil_time.unixFromLocal(candidate, offset_minutes);
    return if (ts > now) ts else ts + 86400;
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

test "parseWeekdayWhen resolves the next occurrence of a named weekday, defaulting to 6am" {
    // now = 1970-01-01 12:00:00 UTC — day 0, a Thursday.
    const thu_noon: i64 = 12 * 3600;

    // Friday is tomorrow regardless of the time of day right now.
    try testing.expectEqual(@as(?i64, 86400 + 6 * 3600), parseWeekdayWhen("friday", thu_noon));
    // Case-insensitive.
    try testing.expectEqual(@as(?i64, 86400 + 6 * 3600), parseWeekdayWhen("Friday", thu_noon));

    // Today (Thursday) with its default 6am already passed this morning
    // rolls to *next* Thursday, not later today or right now.
    try testing.expectEqual(@as(?i64, 6 * 3600 + 7 * 86400), parseWeekdayWhen("thursday", thu_noon));

    // Today (Thursday) with an explicit time still ahead of `now` stays today.
    try testing.expectEqual(@as(?i64, 18 * 3600), parseWeekdayWhen("thursday 18:00", thu_noon));

    try testing.expectEqual(@as(?i64, null), parseWeekdayWhen("funday", thu_noon));
    try testing.expectEqual(@as(?i64, null), parseWeekdayWhen("friday 25:00", thu_noon));
}

test "parseWhen falls back to a weekday name after duration and absolute-time both miss" {
    const thu_noon: i64 = 12 * 3600;
    try testing.expectEqual(@as(?i64, 86400 + 6 * 3600), parseWhen("friday", thu_noon));
    try testing.expectEqual(@as(?i64, 18 * 3600), parseWhen("thursday 18:00", thu_noon));
}

test "parseWhenLocal: duration shorthand ignores offset entirely" {
    try testing.expectEqual(@as(?i64, 1000 + 1800), parseWhenLocal("30m", 1000, 210, .mdy));
}

test "parseWhenLocal: bare HH:MM resolves against local now, not server now" {
    // now = 2026-05-22 12:00 local at +3:30.
    const now = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 12, .minute = 0 }, 210);

    const later_today = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 14, .minute = 30 }, 210);
    try testing.expectEqual(@as(?i64, later_today), parseWhenLocal("14:30", now, 210, .mdy));

    const tomorrow = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 23, .hour = 9, .minute = 0 }, 210);
    try testing.expectEqual(@as(?i64, tomorrow), parseWhenLocal("9:00", now, 210, .mdy));
}

test "parseWhenLocal: explicit date + time, mdy vs dmy vs ISO all agree" {
    const now: i64 = 0;
    const expected = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 13, .minute = 37 }, 0);

    try testing.expectEqual(@as(?i64, expected), parseWhenLocal("5/22/2026 13:37", now, 0, .mdy));
    try testing.expectEqual(@as(?i64, expected), parseWhenLocal("22/5/2026 13:37", now, 0, .dmy));
    try testing.expectEqual(@as(?i64, expected), parseWhenLocal("2026-05-22 13:37", now, 0, .mdy));
    try testing.expectEqual(@as(?i64, expected), parseWhenLocal("2026-05-22 13:37", now, 0, .dmy)); // ISO ignores format
}

test "parseWhenLocal: a 2-digit year shorthand means 2000+yy" {
    const expected = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 13, .minute = 37 }, 0);
    try testing.expectEqual(@as(?i64, expected), parseWhenLocal("5/22/26 13:37", 0, 0, .mdy));
}

test "parseWhenLocal: an omitted year rolls to next year once the local moment has passed, else stays" {
    // now = 2026-05-22 12:00 local, no offset.
    const now = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 12, .minute = 0 }, 0);

    // 09:00 on 5/22 already passed today -> rolls to 2027.
    const rolled = civil_time.unixFromLocal(.{ .year = 2027, .month = 5, .day = 22, .hour = 9, .minute = 0 }, 0);
    try testing.expectEqual(@as(?i64, rolled), parseWhenLocal("5/22 09:00", now, 0, .mdy));

    // 15:00 on 5/22 hasn't passed yet today -> stays this year.
    const same_year = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 15, .minute = 0 }, 0);
    try testing.expectEqual(@as(?i64, same_year), parseWhenLocal("5/22 15:00", now, 0, .mdy));
}

test "parseWhenLocal: an explicit year is trusted as-is even if already past" {
    const now = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 12, .minute = 0 }, 0);
    const past = civil_time.unixFromLocal(.{ .year = 2020, .month = 1, .day = 1, .hour = 0, .minute = 0 }, 0);
    try testing.expectEqual(@as(?i64, past), parseWhenLocal("1/1/2020 00:00", now, 0, .mdy));
}

test "parseWhenLocal: a bare date with no time defaults to 09:00 local" {
    const expected = civil_time.unixFromLocal(.{ .year = 2026, .month = 5, .day = 22, .hour = 9, .minute = 0 }, 0);
    try testing.expectEqual(@as(?i64, expected), parseWhenLocal("5/22/2026", 0, 0, .mdy));
    try testing.expectEqual(@as(?i64, expected), parseWhenLocal("2026-05-22", 0, 0, .mdy));
}

test "parseWhenLocal: rejects garbage and malformed dates/times" {
    try testing.expectEqual(@as(?i64, null), parseWhenLocal("nonsense", 0, 0, .mdy));
    try testing.expectEqual(@as(?i64, null), parseWhenLocal("13/45/2026 25:00", 0, 0, .mdy));
    try testing.expectEqual(@as(?i64, null), parseWhenLocal("5/22/2026 25:00", 0, 0, .mdy));
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
