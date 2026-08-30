//! Backs the "🛑 Cancel" button `main.zig`'s `replyWithAnswer` attaches to
//! the "thinking"/tool-use placeholder while a question is in flight. One
//! entry per (native chat, placeholder message) — several questions could
//! be in flight in the same chat at once (different askers, or the same
//! asker firing off more than one), same "prompt id disambiguates" shape
//! `audit_notify.PendingUndos`/`menu.Sessions` already use for their own
//! button state.
//!
//! Deliberately does not itself stop an in-flight HTTP call to the model —
//! see `llm/toolcall.zig`'s `Progress.cancelled` doc comment for why that's
//! only checked at loop-iteration boundaries. This module's whole job is
//! narrower: remember who's allowed to press Cancel, and flip the atomic
//! flag `replyWithAnswer` is already watching when they do.
const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");

/// The value carried on the "Cancel" button's `Choice` — checked by
/// `handleCancelPicked` so a stray/unrelated `ChoicePicked` (a `/convert`
/// format pick, a `/menu` navigation button) is never mistaken for one.
pub const cancel_choice_value = "warden_cancel_request";

const Entry = struct {
    /// Native id (platform-specific string, e.g. Telegram's numeric user
    /// id) of whoever asked the question this placeholder belongs to — the
    /// only identity allowed to cancel it. Compared against the presser's
    /// own `msg.user_id`, same idiom `/remind cancel`/`/alert cancel` use
    /// for "only whoever set this can cancel it".
    asker_user_id: []const u8,
    /// Points into the `TickerState` `replyWithAnswer` already allocated
    /// for this request (see its own doc comment on why that's safe to
    /// share) — flipping this is the entire effect of a successful cancel;
    /// `toolcall.run` is the one thing that actually acts on it.
    cancel: *std.atomic.Value(bool),
    expires_at: i64,
};

/// In-memory, one entry per (native chat, placeholder message) — see this
/// module's doc comment. `timeout_seconds` is a defensive backstop only
/// (normal flow always calls `unregister` itself, via `replyWithAnswer`'s
/// cleanup path, well before this would ever matter): it bounds how long a
/// leaked entry (a worker that panicked mid-request, say) can linger.
pub const InFlightRequests = struct {
    allocator: std.mem.Allocator,
    io: Io,
    map: std.StringHashMap(Entry),
    mutex: Io.Mutex = .init,
    timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, timeout_seconds: i64) InFlightRequests {
        return .{
            .allocator = allocator,
            .io = io,
            .map = std.StringHashMap(Entry).init(allocator),
            .timeout_seconds = timeout_seconds,
        };
    }

    pub fn deinit(self: *InFlightRequests) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.asker_user_id);
        }
        self.map.deinit();
    }

    fn makeKey(allocator: std.mem.Allocator, native_chat_id: []const u8, placeholder_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ native_chat_id, placeholder_id });
    }

    /// Registers `placeholder_id` as cancellable by `asker_user_id`.
    /// `cancel` must outlive this entry — callers must `unregister` before
    /// letting whatever it points into go away (see `Entry.cancel`'s doc
    /// comment).
    pub fn register(self: *InFlightRequests, now: i64, native_chat_id: []const u8, placeholder_id: []const u8, asker_user_id: []const u8, cancel: *std.atomic.Value(bool)) !void {
        const owned_user = try self.allocator.dupe(u8, asker_user_id);
        errdefer self.allocator.free(owned_user);
        const key = try makeKey(self.allocator, native_chat_id, placeholder_id);
        errdefer self.allocator.free(key);

        const entry = Entry{ .asker_user_id = owned_user, .cancel = cancel, .expires_at = now + self.timeout_seconds };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.asker_user_id);
        }
        try self.map.put(key, entry);
    }

    /// Removes the entry for (native chat, placeholder message), if any —
    /// `replyWithAnswer` calls this once the request is done, cancelled or
    /// not, so a stale Cancel press afterward finds nothing to act on.
    pub fn unregister(self: *InFlightRequests, native_chat_id: []const u8, placeholder_id: []const u8) void {
        const key = makeKey(self.allocator, native_chat_id, placeholder_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.asker_user_id);
        }
    }

    pub const Outcome = enum { cancelled, not_found, not_yours };

    /// Flips the cancel flag for (native chat, placeholder message) if
    /// `presser_user_id` matches whoever it was registered for — one-shot
    /// in effect (the flag only ever transitions false -> true), but
    /// deliberately not removed from the map here: `replyWithAnswer`'s own
    /// cleanup does that once it notices the cancellation, so a second
    /// press before then just re-flips an already-true flag harmlessly.
    pub fn tryCancel(self: *InFlightRequests, now: i64, native_chat_id: []const u8, placeholder_id: []const u8, presser_user_id: []const u8) Outcome {
        const key = makeKey(self.allocator, native_chat_id, placeholder_id) catch return .not_found;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = self.map.get(key) orelse return .not_found;
        if (now > entry.expires_at) return .not_found;
        if (!std.mem.eql(u8, entry.asker_user_id, presser_user_id)) return .not_yours;

        entry.cancel.store(true, .release);
        return .cancelled;
    }

    /// Prunes entries past their defensive timeout — see this struct's doc
    /// comment. Called from `main`'s ~30s scheduler tick, same cadence
    /// `convert_flow.PendingConversions.sweepExpired`/
    /// `menu.Sessions.sweepExpired` already run at.
    pub fn sweepExpired(self: *InFlightRequests, now: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (now > entry.value_ptr.expires_at) {
                expired.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (expired.items) |key| {
            if (self.map.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value.asker_user_id);
            }
        }
    }
};

/// Consumes a `ChoicePicked` arriving anywhere, if (and only if) it is a
/// pick of this module's own "Cancel" button — returns `false` for
/// anything else so `main.zig`'s `handleMessage` can fall through to its
/// other `choice_picked` consumers unchanged, same contract
/// `audit_notify.handleUndoPicked` follows.
pub fn handleCancelPicked(connector: iface.Connector, a: std.mem.Allocator, in_flight: *InFlightRequests, now: i64, msg: iface.Message, picked: iface.ChoicePicked) bool {
    if (!std.mem.eql(u8, picked.value, cancel_choice_value)) return false;

    switch (in_flight.tryCancel(now, msg.chat_id, picked.prompt_message_id, msg.user_id)) {
        // `replyWithAnswer` itself edits the placeholder to say so once it
        // notices — no separate reply needed here.
        .cancelled => {},
        // Already finished (or long expired) by the time this press
        // landed — same "stray pick, say nothing" convention every other
        // choice_picked consumer here follows.
        .not_found => {},
        .not_yours => connector.sendMessage(a, msg.chat_id, "Only the person who asked can cancel this.", msg.message_id),
    }
    return true;
}

const testing = std.testing;

test "register/tryCancel round trip: right asker cancels, wrong asker doesn't" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();

    var flag = std.atomic.Value(bool).init(false);
    try in_flight.register(1000, "chat-1", "msg-1", "alice", &flag);

    try testing.expectEqual(InFlightRequests.Outcome.not_yours, in_flight.tryCancel(1000, "chat-1", "msg-1", "mallory"));
    try testing.expect(!flag.load(.acquire));

    try testing.expectEqual(InFlightRequests.Outcome.cancelled, in_flight.tryCancel(1000, "chat-1", "msg-1", "alice"));
    try testing.expect(flag.load(.acquire));
}

test "tryCancel reports not_found for an unregistered or expired entry" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();

    try testing.expectEqual(InFlightRequests.Outcome.not_found, in_flight.tryCancel(1000, "chat-1", "msg-1", "alice"));

    var flag = std.atomic.Value(bool).init(false);
    try in_flight.register(1000, "chat-1", "msg-1", "alice", &flag);
    try testing.expectEqual(InFlightRequests.Outcome.not_found, in_flight.tryCancel(1000 + 61, "chat-1", "msg-1", "alice"));
}

test "unregister removes the entry so a later press finds nothing" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();

    var flag = std.atomic.Value(bool).init(false);
    try in_flight.register(1000, "chat-1", "msg-1", "alice", &flag);
    in_flight.unregister("chat-1", "msg-1");

    try testing.expectEqual(InFlightRequests.Outcome.not_found, in_flight.tryCancel(1000, "chat-1", "msg-1", "alice"));
}

test "different placeholders in the same chat don't collide" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();

    var flag_a = std.atomic.Value(bool).init(false);
    var flag_b = std.atomic.Value(bool).init(false);
    try in_flight.register(1000, "chat-1", "msg-a", "alice", &flag_a);
    try in_flight.register(1000, "chat-1", "msg-b", "bob", &flag_b);

    try testing.expectEqual(InFlightRequests.Outcome.cancelled, in_flight.tryCancel(1000, "chat-1", "msg-a", "alice"));
    try testing.expect(flag_a.load(.acquire));
    try testing.expect(!flag_b.load(.acquire));
}

test "sweepExpired prunes only entries past their timeout" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();

    var flag_a = std.atomic.Value(bool).init(false);
    var flag_b = std.atomic.Value(bool).init(false);
    try in_flight.register(1000, "chat-1", "msg-a", "alice", &flag_a);
    try in_flight.register(1000, "chat-1", "msg-b", "bob", &flag_b);

    in_flight.sweepExpired(1000 + 61);
    try testing.expectEqual(@as(u32, 0), in_flight.map.count());
}

/// Minimal fake connector for `handleCancelPicked`'s "wrong asker" reply
/// path — same spirit as `audit_notify.zig`'s own local fake, narrowed to
/// just `sendMessage`.
const RecordingConnector = struct {
    sent: ?[]const u8 = null,

    fn connector(self: *RecordingConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
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
        _ = allocator;
        _ = chat_id;
        _ = reply_to_message_id;
        const self: *RecordingConnector = @ptrCast(@alignCast(ptr));
        self.sent = text;
    }
};

test "handleCancelPicked ignores a pick that isn't its own button" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();
    var rec = RecordingConnector{};

    const claimed = handleCancelPicked(rec.connector(), testing.allocator, &in_flight, 1000, .{ .chat_id = "chat-1", .user_id = "alice" }, .{ .prompt_message_id = "msg-1", .value = "something_else" });
    try testing.expect(!claimed);
    try testing.expect(rec.sent == null);
}

test "handleCancelPicked tells off a presser who isn't the original asker" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();
    var flag = std.atomic.Value(bool).init(false);
    try in_flight.register(1000, "chat-1", "msg-1", "alice", &flag);
    var rec = RecordingConnector{};

    const claimed = handleCancelPicked(rec.connector(), testing.allocator, &in_flight, 1000, .{ .chat_id = "chat-1", .user_id = "mallory" }, .{ .prompt_message_id = "msg-1", .value = cancel_choice_value });
    try testing.expect(claimed);
    try testing.expect(!flag.load(.acquire));
    try testing.expectEqualStrings("Only the person who asked can cancel this.", rec.sent.?);
}

test "handleCancelPicked cancels for the original asker with no reply" {
    var in_flight = InFlightRequests.init(testing.allocator, testing.io, 60);
    defer in_flight.deinit();
    var flag = std.atomic.Value(bool).init(false);
    try in_flight.register(1000, "chat-1", "msg-1", "alice", &flag);
    var rec = RecordingConnector{};

    const claimed = handleCancelPicked(rec.connector(), testing.allocator, &in_flight, 1000, .{ .chat_id = "chat-1", .user_id = "alice" }, .{ .prompt_message_id = "msg-1", .value = cancel_choice_value });
    try testing.expect(claimed);
    try testing.expect(flag.load(.acquire));
    try testing.expect(rec.sent == null);
}
