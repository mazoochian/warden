const std = @import("std");
const PgPool = @import("../store/pool.zig").PgPool;
const reminders = @import("../store/reminders.zig");
const alert_store = @import("../store/alerts.zig");
const reminder_format = @import("reminder_format.zig");

/// Phase 13's proactive daily briefing -- pure composition, no LLM call
/// (unlike `digest.zig`, which writes narrative prose; a briefing is just
/// a status list of what's still pending, so plain formatting is simpler
/// and more reliable). Composes exactly two sections this pass: a chat's
/// pending reminders and pending alerts, both already queried by
/// `/reminders`/`/alerts` today (`reminders.listPending`/
/// `alert_store.listPending`) -- no new store queries needed for either.
///
/// `weather_line` is one already-formatted line (e.g. "Berlin: 14°C, wind
/// 8 km/h") or `null` when this chat has no default location set, the
/// lookup failed, or the place didn't geocode. It's passed *in* rather than
/// fetched here on purpose: fetching means real network I/O, and keeping
/// that at the call site (see `main.zig`'s two briefing paths) leaves this
/// function pure composition -- which is both the framing Phase 13 chose
/// and what keeps `zig build test` fully offline, the same policy the word
/// cloud/diagram/live-API work in this project already follows. A failed
/// weather lookup therefore degrades to a briefing without a weather
/// section rather than failing the whole briefing.
///
/// **Still deferred**: a "new feed items since last briefing" section
/// (`store/feed_watches.zig` only tracks seen guids for dedup, not
/// readable item text, so reconstructing "what was new" after the fact
/// isn't available without duplicating `feed_watcher.zig`'s own live-fetch
/// logic). Flagged here rather than silently dropped, same convention this
/// project's `ROADMAP.md` uses elsewhere (e.g. Phase 11's deferred voice
/// notes, Phase 9's deferred `/as` relay).
pub fn generate(allocator: std.mem.Allocator, pool: *PgPool, chat_id: i64, now: i64, weather_line: ?[]const u8) ![]const u8 {
    // Reminders only, not scheduled announcements (Phase 16) — a briefing
    // is "what's coming up for you", and an announcement is a broadcast the
    // chat will see for itself when it fires, so listing it here would just
    // spoil it a day early.
    const pending_reminders = try reminders.listPending(pool, allocator, chat_id, .reminder);
    const pending_alerts = try alert_store.listPending(pool, allocator, chat_id);

    // Weather alone is enough to make a briefing worth sending -- a chat
    // with a default location set and nothing pending still wants to know
    // the forecast, so this is not folded into the empty check below.
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

    // An arena, not `testing.allocator` directly -- `generate`'s returned
    // slice is a `Writer.Allocating.buffered()` sub-slice, not something
    // safe to hand straight to a strict allocator's leak check without
    // either freeing it explicitly or (as here) letting an arena reclaim
    // it in bulk, same convention `digest.zig`'s own test uses.
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
