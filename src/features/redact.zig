const std = @import("std");
const iface = @import("../platform/interface.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const messages = @import("../store/messages.zig");
const safe_regex = @import("../text/safe_regex.zig");
const log = @import("../log.zig").scoped("redact");

/// Hard cap on how many messages a single `/redact` invocation can delete,
/// across every mode — bulk-deleting chat history is more destructive than
/// a single `/kick`, so this stays well below what a group-admin-tier
/// action would otherwise be trusted to do unbounded.
pub const max_redact_count: i64 = 100;
/// How far back into a chat's history `text`/`regex` mode will look for
/// matches — bounds the work a single invocation can force regardless of
/// how deep in history a match might be (see `store/messages.zig`'s
/// `searchDeletable`/`recentForScan`).
pub const max_scan_window: i64 = 2000;

/// Best-effort: one failed deletion (message already gone, bot lost admin
/// rights mid-batch, ...) doesn't abort the rest — matches
/// `group_admin.zig`'s "log and continue" spirit for individual-action
/// failures, just applied across a batch instead of a single action.
fn deleteAll(connector: iface.Connector, a: std.mem.Allocator, chat_id_native: []const u8, refs: []const messages.MessageRef) usize {
    var deleted: usize = 0;
    for (refs) |ref| {
        connector.deleteMessage(a, chat_id_native, ref.native_message_id) catch |err| {
            log.warn("failed to delete message {s}: {t}", .{ ref.native_message_id, err });
            continue;
        };
        deleted += 1;
    }
    return deleted;
}

fn reportDeleted(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, deleted: usize, total_candidates: usize) void {
    if (total_candidates == 0) {
        connector.sendMessage(a, msg.chat_id, "Nothing to redact.", msg.message_id);
        return;
    }
    const text = std.fmt.allocPrint(a, "Deleted {d} message(s).", .{deleted}) catch return;
    connector.sendMessage(a, msg.chat_id, text, msg.message_id);
}

/// `/redact <N>` (no reply target) — deletes the last `n` messages in the
/// chat, clamped to `max_redact_count`.
pub fn redactLastN(connector: iface.Connector, a: std.mem.Allocator, pool: *PgPool, chat_id: i64, msg: iface.Message, n: i64) void {
    const count = @min(@max(n, 0), max_redact_count);
    if (count == 0) {
        connector.sendMessage(a, msg.chat_id, "Nothing to redact.", msg.message_id);
        return;
    }
    const refs = messages.recentDeletable(pool, a, chat_id, count) catch |err| {
        log.err("failed to fetch recent messages: {t}", .{err});
        return;
    };
    reportDeleted(connector, a, msg, deleteAll(connector, a, msg.chat_id, refs), refs.len);
}

/// `/redact [N]` as a reply to a user's message — deletes that sender's
/// last `n` messages (or up to `max_redact_count` if `n` is absent/
/// non-positive).
pub fn redactUserLastN(connector: iface.Connector, a: std.mem.Allocator, pool: *PgPool, chat_id: i64, msg: iface.Message, target_identity_id: i64, n: i64) void {
    const count = if (n <= 0) max_redact_count else @min(n, max_redact_count);
    const refs = messages.recentDeletableByIdentity(pool, a, chat_id, target_identity_id, count) catch |err| {
        log.err("failed to fetch recent messages for identity {d}: {t}", .{ target_identity_id, err });
        return;
    };
    reportDeleted(connector, a, msg, deleteAll(connector, a, msg.chat_id, refs), refs.len);
}

/// `/redact text <substring>` — literal, case-insensitive substring match.
pub fn redactText(connector: iface.Connector, a: std.mem.Allocator, pool: *PgPool, chat_id: i64, msg: iface.Message, substring: []const u8) void {
    if (substring.len == 0) {
        connector.sendMessage(a, msg.chat_id, "Usage: /redact text <substring>", msg.message_id);
        return;
    }
    const refs = messages.searchDeletable(pool, a, chat_id, substring, max_redact_count, max_scan_window) catch |err| {
        log.err("failed to search messages: {t}", .{err});
        return;
    };
    reportDeleted(connector, a, msg, deleteAll(connector, a, msg.chat_id, refs), refs.len);
}

/// `/redact regex <pattern>` — see `text/safe_regex.zig` for why this is
/// safe against a hostile/careless pattern (ReDoS-immune by construction,
/// plus its own compile-time length/complexity caps). Matching happens
/// client-side (Postgres can't run this engine), scanning up to
/// `max_scan_window` recent messages and stopping once `max_redact_count`
/// matches are found.
pub fn redactRegex(connector: iface.Connector, a: std.mem.Allocator, pool: *PgPool, chat_id: i64, msg: iface.Message, pattern: []const u8) void {
    if (pattern.len == 0) {
        connector.sendMessage(a, msg.chat_id, "Usage: /redact regex <pattern>", msg.message_id);
        return;
    }
    var regex = safe_regex.compile(a, pattern) catch |err| {
        const text = std.fmt.allocPrint(a, "That pattern isn't usable: {t}", .{err}) catch return;
        connector.sendMessage(a, msg.chat_id, text, msg.message_id);
        return;
    };
    defer regex.deinit();

    const candidates = messages.recentForScan(pool, a, chat_id, max_scan_window) catch |err| {
        log.err("failed to fetch messages to scan: {t}", .{err});
        return;
    };

    var matched: std.ArrayList(messages.MessageRef) = .empty;
    for (candidates) |ref| {
        if (matched.items.len >= max_redact_count) break;
        const text = ref.text orelse continue;
        if (regex.isMatch(text)) matched.append(a, ref) catch break;
    }

    reportDeleted(connector, a, msg, deleteAll(connector, a, msg.chat_id, matched.items), matched.items.len);
}

const testing = std.testing;
const test_support = @import("../store/test_support.zig");
const identities = @import("../store/identities.zig");
const chats = @import("../store/chats.zig");
const msg_insert = @import("../store/messages.zig").insert;

/// Minimal `Connector` stub — records every `sendMessage`/`deleteMessage`
/// call so tests can assert on them, and can be told to fail specific
/// message ids to exercise `deleteAll`'s "one failure doesn't abort the
/// batch" behavior. Same shape as `auth.zig`'s own `StubConnector`.
const StubConnector = struct {
    fail_ids: []const []const u8 = &.{},
    deleted_ids: std.ArrayList([]const u8) = .empty,
    sent_messages: std.ArrayList([]const u8) = .empty,

    fn connector(self: *StubConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .deleteMessage = deleteMessageFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram;
    }
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }
    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = chat_id;
        _ = reply_to_message_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(allocator, text) catch {};
    }
    fn deleteMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        _ = chat_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        for (self.fail_ids) |bad| {
            if (std.mem.eql(u8, bad, message_id)) return error.Unsupported;
        }
        self.deleted_ids.append(allocator, message_id) catch {};
    }
};

fn baseMsg() iface.Message {
    return .{ .chat_id = "chat1", .user_id = "1" };
}

test "redactLastN deletes up to max_redact_count, newest first" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try msg_insert(&pool, chat_id, alice, "1", "one", 1000);
    try msg_insert(&pool, chat_id, alice, "2", "two", 1001);
    try msg_insert(&pool, chat_id, alice, "3", "three", 1002);

    var stub = StubConnector{};
    redactLastN(stub.connector(), a, &pool, chat_id, baseMsg(), 2);

    try testing.expectEqual(@as(usize, 2), stub.deleted_ids.items.len);
    try testing.expectEqualStrings("3", stub.deleted_ids.items[0]);
    try testing.expectEqualStrings("2", stub.deleted_ids.items[1]);
    try testing.expectEqualStrings("Deleted 2 message(s).", stub.sent_messages.items[0]);
}

test "redactLastN clamps a request above max_redact_count" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        var buf: [8]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        try msg_insert(&pool, chat_id, alice, id, "spam", 1000 + i);
    }

    var stub = StubConnector{};
    // Ask for far more than exist and far more than the cap — should just
    // get everything that actually exists (5), not error or hang.
    redactLastN(stub.connector(), a, &pool, chat_id, baseMsg(), 999_999);
    try testing.expectEqual(@as(usize, 5), stub.deleted_ids.items.len);
}

test "redactLastN(0) and negative n redact nothing" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try msg_insert(&pool, chat_id, alice, "1", "one", 1000);

    var stub = StubConnector{};
    redactLastN(stub.connector(), a, &pool, chat_id, baseMsg(), 0);
    redactLastN(stub.connector(), a, &pool, chat_id, baseMsg(), -5);
    try testing.expectEqual(@as(usize, 0), stub.deleted_ids.items.len);
}

test "redactUserLastN only deletes the target sender's messages" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const bob = try identities.getOrCreateMinimal(&pool, .telegram, "2", "bob", null, false, 1000);
    try msg_insert(&pool, chat_id, alice, "1", "alice", 1000);
    try msg_insert(&pool, chat_id, bob, "2", "bob", 1001);
    try msg_insert(&pool, chat_id, alice, "3", "alice again", 1002);

    var stub = StubConnector{};
    redactUserLastN(stub.connector(), a, &pool, chat_id, baseMsg(), alice, 0);
    try testing.expectEqual(@as(usize, 2), stub.deleted_ids.items.len);
    try testing.expect(!std.mem.eql(u8, stub.deleted_ids.items[0], "2"));
    try testing.expect(!std.mem.eql(u8, stub.deleted_ids.items[1], "2"));
}

test "redactText matches literal substrings and reports nothing-to-do when there are no matches" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try msg_insert(&pool, chat_id, alice, "1", "buy cheap watches", 1000);
    try msg_insert(&pool, chat_id, alice, "2", "totally normal message", 1001);

    var stub = StubConnector{};
    redactText(stub.connector(), a, &pool, chat_id, baseMsg(), "cheap");
    try testing.expectEqual(@as(usize, 1), stub.deleted_ids.items.len);
    try testing.expectEqualStrings("1", stub.deleted_ids.items[0]);

    var stub2 = StubConnector{};
    redactText(stub2.connector(), a, &pool, chat_id, baseMsg(), "no such substring");
    try testing.expectEqual(@as(usize, 0), stub2.deleted_ids.items.len);
    try testing.expectEqualStrings("Nothing to redact.", stub2.sent_messages.items[0]);
}

test "redactRegex deletes matches and replies with a usable-pattern error on a bad pattern" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try msg_insert(&pool, chat_id, alice, "1", "call 555-1234 now", 1000);
    try msg_insert(&pool, chat_id, alice, "2", "no digits here", 1001);

    var stub = StubConnector{};
    redactRegex(stub.connector(), a, &pool, chat_id, baseMsg(), "[0-9]{3}-[0-9]{4}");
    try testing.expectEqual(@as(usize, 1), stub.deleted_ids.items.len);
    try testing.expectEqualStrings("1", stub.deleted_ids.items[0]);

    var stub2 = StubConnector{};
    redactRegex(stub2.connector(), a, &pool, chat_id, baseMsg(), "(unbalanced");
    try testing.expectEqual(@as(usize, 0), stub2.deleted_ids.items.len);
    try testing.expect(stub2.sent_messages.items.len == 1);
}

test "deleteAll: one failed deletion doesn't abort the rest of the batch" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try msg_insert(&pool, chat_id, alice, "1", "one", 1000);
    try msg_insert(&pool, chat_id, alice, "2", "two", 1001);
    try msg_insert(&pool, chat_id, alice, "3", "three", 1002);

    var stub = StubConnector{ .fail_ids = &.{"2"} };
    redactLastN(stub.connector(), a, &pool, chat_id, baseMsg(), 3);
    // "2" failed, "1" and "3" still got deleted, and the report counts only
    // the successes.
    try testing.expectEqual(@as(usize, 2), stub.deleted_ids.items.len);
    try testing.expectEqualStrings("Deleted 2 message(s).", stub.sent_messages.items[0]);
}
