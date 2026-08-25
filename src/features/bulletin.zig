const std = @import("std");
const Io = std.Io;

const PgPool = @import("../store/pool.zig").PgPool;
const chat_settings = @import("../store/chat_settings.zig");
const messages = @import("../store/messages.zig");
const user_settings = @import("../store/user_settings.zig");

/// Bound on how many rows one monitored chat can contribute to a single
/// bulletin -- so one noisy chat can't drown out every other monitored
/// chat's own activity. Same "belt-and-suspenders bound" reasoning as
/// `chat_summary.zig`'s `max_unread_fetch`.
const per_chat_limit: i64 = 200;

const default_lookback_hours: i64 = 24;

/// `get_bulletin`'s implementation: gathers raw, id-tagged message text
/// from every chat the owner has marked as monitored (`set_chat_monitoring`
/// / `chat_settings.monitor_importance`), grouped by chat and ordered by
/// importance, for the calling model to rank and turn into an actual
/// bulletin itself -- no LLM call happens in here (same "just fetch, model
/// summarizes" shape `tools/catch_me_up.zig` already establishes).
///
/// `hours = null` uses the owner's `last_bulletin_ts` cursor (or the last
/// `default_lookback_hours` if a bulletin has never been generated before),
/// and advances that cursor to `now` as a side effect -- same "the read has
/// a side effect" precedent `chat_summary.fetchUnread`'s mark-as-read
/// already sets. An explicit `hours` is a stateless ad-hoc probe: it never
/// touches the cursor, so asking "what happened in the last 3 hours" can't
/// disturb the next on-demand bulletin's own window.
pub fn gather(pool: *PgPool, allocator: std.mem.Allocator, owner_identity_id: i64, hours: ?i64, now: i64) ![]const u8 {
    const monitored = try chat_settings.listMonitored(pool, allocator, .telegram_user, owner_identity_id);
    if (monitored.len == 0) {
        return "No chats are being monitored yet — ask to enable monitoring for a chat first.";
    }

    const since_ts = if (hours) |h|
        now - h * 3600
    else blk: {
        const last = user_settings.getLastBulletinTs(pool, owner_identity_id);
        break :blk if (last == 0) now - default_lookback_hours * 3600 else last;
    };

    var out: Io.Writer.Allocating = .init(allocator);
    var any_activity = false;
    for (monitored) |chat| {
        const rows = try messages.recentSinceRows(pool, allocator, chat.chat_id, since_ts, per_chat_limit);
        if (rows.len == 0) continue;
        any_activity = true;
        try out.writer.print("=== {s} [{s}] ===\n", .{ chat.title, @tagName(chat.importance) });
        for (rows) |r| {
            const id_part = r.native_message_id orelse "?";
            if (r.is_summary) {
                try out.writer.print("[{s}] summary: {s}\n", .{ id_part, r.text });
            } else {
                try out.writer.print("[{s}] {s}: {s}\n", .{ id_part, r.who, r.text });
            }
        }
        try out.writer.writeAll("\n");
    }

    if (!any_activity) {
        return "No new activity in monitored chats since the last bulletin.";
    }

    if (hours == null) {
        user_settings.setLastBulletinTs(pool, owner_identity_id, now) catch |err| {
            std.log.err("bulletin: failed to advance last_bulletin_ts for identity {d}: {t}", .{ owner_identity_id, err });
        };
    }

    return out.writer.buffered();
}

const testing = std.testing;
const test_support = @import("../store/test_support.zig");
const chats = @import("../store/chats.zig");
const identities = @import("../store/identities.zig");
const messages_store = @import("../store/messages.zig");

test "gather reports nothing monitored when no chat has opted in" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const owner = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "owner", null, false, 1000);
    const text = try gather(&pool, a, owner, null, 100_000);
    try testing.expect(std.mem.indexOf(u8, text, "No chats are being monitored") != null);
}

test "gather reports no new activity when monitored chats have nothing since the cursor" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const owner = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "owner", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram_user, "10", null, "Family");
    try chat_settings.setMonitorImportance(&pool, chat_id, .high);

    const text = try gather(&pool, a, owner, null, 100_000);
    try testing.expect(std.mem.indexOf(u8, text, "No new activity") != null);
}

test "gather groups messages by chat with bracketed ids, ordered by importance, and advances the cursor" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const owner = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "owner", null, false, 1000);
    const sender = try identities.getOrCreateMinimal(&pool, .telegram_user, "2", "alice", null, false, 1000);

    const high_chat = try chats.upsertChat(&pool, .telegram_user, "10", null, "Family");
    const normal_chat = try chats.upsertChat(&pool, .telegram_user, "11", null, "Book Club");
    try chat_settings.setMonitorImportance(&pool, high_chat, .high);
    try chat_settings.setMonitorImportance(&pool, normal_chat, .normal);

    const now: i64 = 100_000;
    try messages_store.insert(&pool, high_chat, sender, "501", "dinner at 7?", now - 1800);
    try messages_store.insert(&pool, normal_chat, sender, "601", "meeting moved to Friday", now - 1800);

    const text = try gather(&pool, a, owner, null, now);
    const family_idx = std.mem.indexOf(u8, text, "Family [high]") orelse return error.TestExpectedValue;
    const book_idx = std.mem.indexOf(u8, text, "Book Club [normal]") orelse return error.TestExpectedValue;
    try testing.expect(family_idx < book_idx);
    try testing.expect(std.mem.indexOf(u8, text, "[501] alice: dinner at 7?") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[601] alice: meeting moved to Friday") != null);

    try testing.expectEqual(@as(i64, now), user_settings.getLastBulletinTs(&pool, owner));
}

test "gather with an explicit hours window never advances the cursor" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const owner = try identities.getOrCreateMinimal(&pool, .telegram_user, "1", "owner", null, false, 1000);
    const sender = try identities.getOrCreateMinimal(&pool, .telegram_user, "2", "alice", null, false, 1000);
    const chat_id = try chats.upsertChat(&pool, .telegram_user, "10", null, "Family");
    try chat_settings.setMonitorImportance(&pool, chat_id, .high);

    const now: i64 = 100_000;
    try messages_store.insert(&pool, chat_id, sender, "501", "hi", now - 1800);

    _ = try gather(&pool, a, owner, 6, now);
    try testing.expectEqual(@as(i64, 0), user_settings.getLastBulletinTs(&pool, owner));
}
