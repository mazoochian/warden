const std = @import("std");
const PgPool = @import("../store/pool.zig").PgPool;
const reminders = @import("../store/reminders.zig");
const alert_store = @import("../store/alerts.zig");
const reminder_format = @import("reminder_format.zig");

/// Proactive daily briefing -- pure composition, no LLM call.
pub fn generate(allocator: std.mem.Allocator, pool: *PgPool, chat_id: i64, now: i64, weather_line: ?[]const u8) ![]const u8 {
    // Reminders only, not scheduled announcements.
    const pending_reminders = try reminders.listPending(pool, allocator, chat_id, .reminder);
    const pending_alerts = try alert_store.listPending(pool, allocator, chat_id);

    // Weather alone is enough to make a briefing worth sending -- a chat with a
    // default location set and nothing pending still wants to know the forecast.
    if (pending_reminders.len == 0 and pending_alerts.len == 0 and weather_line == null) {
        return "Briefing: nothing pending -- no reminders or alerts currently active in this chat.";
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("Briefing\n", .{});

    if (weather_line) |line| {
        try w.print("\nWeather:\n  {s}\n", .{line});
    }

    if (pending_reminders.len > 0) {
        try w.print("\nReminders:\n", .{});
        for (pending_reminders) |r| {
            if (r.recur_interval_seconds) |interval| {
                try w.print("  #{d} in {s} (repeats every {s}): {s}\n", .{ r.id, reminder_format.formatRemaining(allocator, r.due_at - now), reminder_format.formatInterval(allocator, interval), r.message });
            } else {
                try w.print("  #{d} in {s}: {s}\n", .{ r.id, reminder_format.formatRemaining(allocator, r.due_at - now), r.message });
            }
        }
    }

    if (pending_alerts.len > 0) {
        try w.print("\nAlerts:\n", .{});
        for (pending_alerts) |al| {
            const unit = if (al.currency) |c| c else if (al.kind == .weather) "°C" else "AQI";
            try w.print("  #{d} {s} {s} {s} {d} {s}\n", .{ al.id, @tagName(al.kind), al.subject, @tagName(al.condition), al.threshold, unit });
        }
    }

    return buf.writer.buffered();
}

const testing = std.testing;
const test_support = @import("../store/test_support.zig");
const chats = @import("../store/chats.zig");

test "generate returns a nothing-pending message when a chat has no reminders or alerts" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    const text = try generate(testing.allocator, &pool, chat_id, 1000, null);
    try testing.expect(std.mem.indexOf(u8, text, "nothing pending") != null);
}

test "generate composes pending reminders and alerts into one briefing" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try @import("../store/identities.zig").upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    _ = try reminders.create(&pool, chat_id, identity_id, "take the bread out", 2000, null);
    _ = try alert_store.create(&pool, chat_id, identity_id, .crypto, "btc", "USD", .above, 100000);

    // An arena, not `testing.allocator` directly -- `generate`'s returned slice
    // is a `Writer.Allocating.buffered()` sub-slice.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(), &pool, chat_id, 1000, null);
    try testing.expect(std.mem.indexOf(u8, text, "take the bread out") != null);
    try testing.expect(std.mem.indexOf(u8, text, "btc") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Reminders:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Alerts:") != null);
}

test "generate includes a weather section when given a weather line" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try @import("../store/identities.zig").upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });
    _ = try reminders.create(&pool, chat_id, identity_id, "take the bread out", 2000, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(), &pool, chat_id, 1000, "Berlin, Germany: clear sky, 14.0°C, wind 8.0 km/h");
    try testing.expect(std.mem.indexOf(u8, text, "Weather:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Berlin, Germany") != null);
    // The other sections are unaffected by the new one.
    try testing.expect(std.mem.indexOf(u8, text, "take the bread out") != null);
}

test "generate sends a weather-only briefing rather than 'nothing pending'" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    // A chat with a default location but nothing pending still wants the
    // forecast -- weather alone must not fall through to the empty message.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(), &pool, chat_id, 1000, "Berlin, Germany: clear sky, 14.0°C, wind 8.0 km/h");
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, text, "nothing pending"));
    try testing.expect(std.mem.indexOf(u8, text, "Weather:") != null);
}

test "generate still reports nothing pending when there is no weather either" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    const text = try generate(testing.allocator, &pool, chat_id, 1000, null);
    try testing.expect(std.mem.indexOf(u8, text, "nothing pending") != null);
}
