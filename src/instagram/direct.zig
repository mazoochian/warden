//! Instagram Direct Messages: inbox/thread polling, per-thread watermark
//! dedup, and text send. Polling-based by design, not Instagram's MQTT
//! "Realtime" push -- see the connector plan's "Why polling, not MQTT"
//! section. Endpoint paths/response shapes are this implementation's
//! best-effort current knowledge (same caveat as `auth.zig`'s doc comment).
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;
const transport = @import("transport.zig");
const auth = @import("auth.zig");
const policy = @import("policy.zig");
const log = @import("../log.zig").scoped("instagram");

pub const DirectMessage = struct {
    thread_id: []const u8,
    item_id: []const u8,
    /// Numeric-as-string sender user id.
    user_id: []const u8,
    text: []const u8,
    timestamp_us: i64,
    /// True when this thread has no other participant besides the
    /// authenticated account itself -- Instagram's "message yourself"
    /// thread, the owner-command channel per the connector plan's "Owner
    /// command routing: self-DM thread" section.
    is_self_thread: bool,

    pub fn dupe(self: DirectMessage, allocator: std.mem.Allocator) !DirectMessage {
        return .{
            .thread_id = try allocator.dupe(u8, self.thread_id),
            .item_id = try allocator.dupe(u8, self.item_id),
            .user_id = try allocator.dupe(u8, self.user_id),
            .text = try allocator.dupe(u8, self.text),
            .timestamp_us = self.timestamp_us,
            .is_self_thread = self.is_self_thread,
        };
    }
};

fn valueToString(allocator: std.mem.Allocator, v: json.Value) !?[]const u8 {
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        else => null,
    };
}

fn valueToI64(v: json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Parses one `inbox.threads[]` entry's `items[]` into `DirectMessage`s
/// newer than `since_ts_us`, appending to `out`. Skips any item this pass
/// doesn't recognize (non-text content, or missing required fields) --
/// same "skip, don't crash the poll loop" posture every other connector's
/// message conversion already takes.
fn collectThreadMessages(allocator: std.mem.Allocator, thread: json.ObjectMap, since_ts_us: i64, out: *std.ArrayList(DirectMessage)) !void {
    const thread_id = switch (thread.get("thread_id") orelse return) {
        .string => |s| s,
        else => return,
    };

    var is_self_thread = false;
    if (thread.get("users")) |users_v| if (users_v == .array) {
        is_self_thread = users_v.array.items.len == 0;
    };

    const items = switch (thread.get("items") orelse return) {
        .array => |a| a,
        else => return,
    };

    for (items.items) |item_v| {
        if (item_v != .object) continue;
        const item = item_v.object;

        const item_type = switch (item.get("item_type") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, item_type, "text")) continue;

        const text = switch (item.get("text") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const item_id = switch (item.get("item_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const user_id = valueToString(allocator, item.get("user_id") orelse json.Value{ .null = {} }) catch null orelse continue;
        errdefer allocator.free(user_id);

        const ts = valueToI64(item.get("timestamp") orelse json.Value{ .null = {} }) orelse 0;
        if (ts <= since_ts_us) {
            allocator.free(user_id);
            continue;
        }

        try out.append(allocator, .{
            .thread_id = try allocator.dupe(u8, thread_id),
            .item_id = try allocator.dupe(u8, item_id),
            .user_id = user_id,
            .text = try allocator.dupe(u8, text),
            .timestamp_us = ts,
            .is_self_thread = is_self_thread,
        });
    }
}

/// One poll cycle: fetches the inbox, returns every text message newer than
/// its thread's watermark (via `watermark_lookup`), across every thread.
/// `watermark_lookup` is a caller-supplied callback (rather than this module
/// reaching into `store/` directly) so it stays testable against synthetic
/// JSON fixtures with no Postgres involved.
pub fn pollInbox(
    io: Io,
    allocator: std.mem.Allocator,
    client: *http.Client,
    auth_client: *auth.AuthClient,
    watermark_lookup: *const fn (thread_id: []const u8) i64,
) ![]DirectMessage {
    const resp = try transport.request(io, allocator, client, .GET, transport.base_url ++ "/direct_v2/inbox/?visual_message_return_type=unseen&persistentBadging=true", auth_client.profile, auth_client.constants, &auth_client.jar, null);
    defer allocator.free(resp.body);

    if (policy.looksLikeChallengeOrBlock(resp.status.class() != .success, resp.body)) {
        return error.ChallengeOrBlock;
    }

    var out: std.ArrayList(DirectMessage) = .empty;
    errdefer {
        for (out.items) |m| {
            allocator.free(m.thread_id);
            allocator.free(m.item_id);
            allocator.free(m.user_id);
            allocator.free(m.text);
        }
        out.deinit(allocator);
    }

    var parsed = json.parseFromSlice(json.Value, allocator, resp.body, .{ .ignore_unknown_fields = true }) catch return try out.toOwnedSlice(allocator);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return try out.toOwnedSlice(allocator),
    };
    const inbox = switch (root.get("inbox") orelse return try out.toOwnedSlice(allocator)) {
        .object => |o| o,
        else => return try out.toOwnedSlice(allocator),
    };
    const threads = switch (inbox.get("threads") orelse return try out.toOwnedSlice(allocator)) {
        .array => |a| a,
        else => return try out.toOwnedSlice(allocator),
    };

    for (threads.items) |thread_v| {
        if (thread_v != .object) continue;
        const thread_id = switch (thread_v.object.get("thread_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const since_ts = watermark_lookup(thread_id);
        try collectThreadMessages(allocator, thread_v.object, since_ts, &out);
    }

    return out.toOwnedSlice(allocator);
}

/// Sends a text message to `thread_id` via `direct_v2/threads/broadcast/text/`.
pub fn sendText(io: Io, allocator: std.mem.Allocator, client: *http.Client, auth_client: *auth.AuthClient, thread_id: []const u8, text: []const u8) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    json.Stringify.value(.{
        .thread_ids = &[_][]const u8{thread_id},
        .text = text,
        .client_context = auth_client.profile.uuid,
    }, .{}, &payload.writer) catch return error.EncodeFailed;

    const resp = try transport.signedPost(io, allocator, client, transport.base_url ++ "/direct_v2/threads/broadcast/text/", auth_client.profile, auth_client.constants, &auth_client.jar, payload.writer.buffered());
    defer allocator.free(resp.body);
    if (resp.status.class() != .success) {
        log.warn("sendText: thread {s} -> {d}: {s}", .{ thread_id, @intFromEnum(resp.status), resp.body[0..@min(resp.body.len, 300)] });
        return error.SendFailed;
    }
}

const testing = std.testing;

fn zeroWatermark(thread_id: []const u8) i64 {
    _ = thread_id;
    return 0;
}

test "collectThreadMessages extracts text items and detects a self-thread by empty users[]" {
    const fixture =
        \\{"thread_id": "t1", "users": [], "items": [
        \\  {"item_id": "i1", "item_type": "text", "text": "hello myself", "user_id": 999, "timestamp": 1000}
        \\]}
    ;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, fixture, .{});
    defer parsed.deinit();

    var out: std.ArrayList(DirectMessage) = .empty;
    defer {
        for (out.items) |m| {
            testing.allocator.free(m.thread_id);
            testing.allocator.free(m.item_id);
            testing.allocator.free(m.user_id);
            testing.allocator.free(m.text);
        }
        out.deinit(testing.allocator);
    }

    try collectThreadMessages(testing.allocator, parsed.value.object, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].is_self_thread);
    try testing.expectEqualStrings("hello myself", out.items[0].text);
    try testing.expectEqualStrings("999", out.items[0].user_id);
}

test "collectThreadMessages marks a thread with other participants as not self" {
    const fixture =
        \\{"thread_id": "t2", "users": [{"pk": 42, "username": "bob"}], "items": [
        \\  {"item_id": "i2", "item_type": "text", "text": "hi", "user_id": 42, "timestamp": 500}
        \\]}
    ;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, fixture, .{});
    defer parsed.deinit();

    var out: std.ArrayList(DirectMessage) = .empty;
    defer {
        for (out.items) |m| {
            testing.allocator.free(m.thread_id);
            testing.allocator.free(m.item_id);
            testing.allocator.free(m.user_id);
            testing.allocator.free(m.text);
        }
        out.deinit(testing.allocator);
    }

    try collectThreadMessages(testing.allocator, parsed.value.object, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(!out.items[0].is_self_thread);
}

test "collectThreadMessages skips items at or before the watermark" {
    const fixture =
        \\{"thread_id": "t3", "users": [], "items": [
        \\  {"item_id": "old", "item_type": "text", "text": "old", "user_id": 1, "timestamp": 100},
        \\  {"item_id": "new", "item_type": "text", "text": "new", "user_id": 1, "timestamp": 200}
        \\]}
    ;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, fixture, .{});
    defer parsed.deinit();

    var out: std.ArrayList(DirectMessage) = .empty;
    defer {
        for (out.items) |m| {
            testing.allocator.free(m.thread_id);
            testing.allocator.free(m.item_id);
            testing.allocator.free(m.user_id);
            testing.allocator.free(m.text);
        }
        out.deinit(testing.allocator);
    }

    try collectThreadMessages(testing.allocator, parsed.value.object, 100, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("new", out.items[0].item_id);
}

test "collectThreadMessages skips non-text item types" {
    const fixture =
        \\{"thread_id": "t4", "users": [], "items": [
        \\  {"item_id": "i1", "item_type": "media", "user_id": 1, "timestamp": 100}
        \\]}
    ;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, fixture, .{});
    defer parsed.deinit();

    var out: std.ArrayList(DirectMessage) = .empty;
    defer out.deinit(testing.allocator);

    try collectThreadMessages(testing.allocator, parsed.value.object, 0, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "DirectMessage.dupe deep-copies into a new allocator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = DirectMessage{
        .thread_id = try src_a.dupe(u8, "t1"),
        .item_id = try src_a.dupe(u8, "i1"),
        .user_id = try src_a.dupe(u8, "1"),
        .text = try src_a.dupe(u8, "hi"),
        .timestamp_us = 1000,
        .is_self_thread = true,
    };
    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.thread_id);
        testing.allocator.free(dst.item_id);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.text);
    }
    arena.deinit();

    try testing.expectEqualStrings("t1", dst.thread_id);
    try testing.expectEqualStrings("hi", dst.text);
    try testing.expect(dst.is_self_thread);
}

test "zeroWatermark helper always returns 0 (sanity check for pollInbox's default test wiring)" {
    try testing.expectEqual(@as(i64, 0), zeroWatermark("anything"));
}
