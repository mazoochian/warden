//! In-memory pub/sub broadcaster for Bot View's live incoming-message feed
//! (see /home/armin/claude/warden-ui/ARCHITECTURE.md §8) — fed by a
//! read-only tap at the same point `main.zig`'s own message-recording
//! already runs (right next to `recordMessage`/`recordObservedUsers`),
//! fans new messages out to any WebSocket clients currently subscribed to
//! that chat. Nothing about message *processing* changes: `publish` never
//! influences whether/how a message gets answered, and a publish with zero
//! subscribers is a cheap no-op.
//!
//! One `Broadcaster` lives for the process's lifetime (owned by
//! `main.zig`, handed into `ServerContext`). Each WebSocket connection
//! owns exactly one `Subscriber`, registered via `subscribe`/removed via
//! `unsubscribe` -- see `router.zig`'s Bot View WS handler for the
//! reader/writer-thread split this is built for (append+signal from
//! `publish` must never block on a slow network write, so the WS writer
//! side only ever touches its own `Subscriber`'s queue, never the wire,
//! while holding a lock).
const std = @import("std");
const Io = std.Io;

pub const Event = struct {
    chat_id: i64,
    sender_display_name: []const u8,
    text: ?[]const u8,
    ts: i64,
};

pub const Subscriber = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(Event) = .empty,
    closed: bool = false,

    pub fn freeEvent(self: *Subscriber, ev: Event) void {
        self.allocator.free(ev.sender_display_name);
        if (ev.text) |t| self.allocator.free(t);
    }

    /// Blocks until an event is available or the subscriber is closed (see
    /// `Broadcaster.close`) -- returns `null` once closed with nothing left
    /// queued, the writer loop's cue to exit. Caller owns the returned
    /// event's strings.
    pub fn nextEvent(self: *Subscriber, io: Io) ?Event {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.queue.items.len == 0 and !self.closed) {
            self.cond.wait(io, &self.mutex) catch return null;
        }
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }
};

/// `chat_id -> subscriber list`, guarded by its own mutex — deliberately
/// separate from each `Subscriber`'s own mutex so publishing to one chat's
/// subscribers never contends with a brand new subscription on a
/// different chat.
pub const Broadcaster = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    subscribers: std.AutoHashMapUnmanaged(i64, std.ArrayList(*Subscriber)) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: Io) Broadcaster {
        return .{ .allocator = allocator, .io = io };
    }

    /// Never actually reached in production (`main.zig` never returns) --
    /// provided for test/scoped-usage symmetry with every other shared-state
    /// struct in this codebase. Does not free individual `Subscriber`s;
    /// those are owned by whichever WS handler `subscribe`d them and must
    /// already have been `unsubscribe`d by the time this runs.
    pub fn deinit(self: *Broadcaster) void {
        var it = self.subscribers.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.subscribers.deinit(self.allocator);
    }

    /// Caller owns the returned pointer and must call `unsubscribe` exactly
    /// once when done (typically when the WS connection closes).
    pub fn subscribe(self: *Broadcaster, chat_id: i64) !*Subscriber {
        const sub = try self.allocator.create(Subscriber);
        sub.* = .{ .allocator = self.allocator };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = try self.subscribers.getOrPut(self.allocator, chat_id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.allocator, sub);
        return sub;
    }

    /// Marks `sub` closed (waking its writer loop, see `Subscriber.nextEvent`)
    /// and unregisters + frees it. Safe to call even if the writer loop
    /// hasn't observed the close yet -- the WS handler is expected to signal
    /// close, join the writer thread, then call this, in that order.
    pub fn unsubscribe(self: *Broadcaster, chat_id: i64, sub: *Subscriber) void {
        self.mutex.lockUncancelable(self.io);
        if (self.subscribers.getPtr(chat_id)) |list| {
            for (list.items, 0..) |s, i| {
                if (s == sub) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }
        self.mutex.unlock(self.io);

        sub.mutex.lockUncancelable(self.io);
        for (sub.queue.items) |ev| sub.freeEvent(ev);
        sub.queue.deinit(self.allocator);
        sub.mutex.unlock(self.io);
        self.allocator.destroy(sub);
    }

    /// Wakes `sub`'s writer loop with no more events coming -- call before
    /// `unsubscribe` so the writer thread has a chance to exit cleanly
    /// (see the WS handler's defer order).
    pub fn close(self: *Broadcaster, sub: *Subscriber) void {
        sub.mutex.lockUncancelable(self.io);
        sub.closed = true;
        sub.cond.signal(self.io);
        sub.mutex.unlock(self.io);
    }

    /// Fans a new message out to every current subscriber of `chat_id`.
    /// Never blocks on network I/O: each subscriber just gets its own
    /// heap-owned copy appended to its own queue under its own lock, woken
    /// via its own condition -- the actual (potentially slow) WS write
    /// happens later, on that subscriber's own writer thread.
    pub fn publish(self: *Broadcaster, chat_id: i64, sender_display_name: []const u8, text: ?[]const u8, ts: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const list = self.subscribers.get(chat_id) orelse return;
        for (list.items) |sub| {
            const name_copy = self.allocator.dupe(u8, sender_display_name) catch continue;
            const text_copy = if (text) |t| (self.allocator.dupe(u8, t) catch null) else null;

            sub.mutex.lockUncancelable(self.io);
            defer sub.mutex.unlock(self.io);
            if (sub.closed) {
                self.allocator.free(name_copy);
                if (text_copy) |t| self.allocator.free(t);
                continue;
            }
            sub.queue.append(self.allocator, .{ .chat_id = chat_id, .sender_display_name = name_copy, .text = text_copy, .ts = ts }) catch {
                self.allocator.free(name_copy);
                if (text_copy) |t| self.allocator.free(t);
                continue;
            };
            sub.cond.signal(self.io);
        }
    }
};

const testing = std.testing;

test "publish with no subscribers is a no-op" {
    var b = Broadcaster.init(testing.allocator, testing.io);
    defer b.deinit();
    b.publish(1, "alice", "hi", 1000);
}

test "subscribe then publish delivers the event" {
    var b = Broadcaster.init(testing.allocator, testing.io);
    defer b.deinit();
    const sub = try b.subscribe(42);
    defer b.unsubscribe(42, sub);

    b.publish(42, "alice", "hello there", 1234);
    const ev = sub.nextEvent(testing.io) orelse return error.TestExpectedValue;
    defer sub.freeEvent(ev);
    try testing.expectEqual(@as(i64, 42), ev.chat_id);
    try testing.expectEqualStrings("alice", ev.sender_display_name);
    try testing.expectEqualStrings("hello there", ev.text.?);
    try testing.expectEqual(@as(i64, 1234), ev.ts);
}

test "publish to a different chat_id is not delivered" {
    var b = Broadcaster.init(testing.allocator, testing.io);
    defer b.deinit();
    const sub = try b.subscribe(1);
    defer b.unsubscribe(1, sub);

    b.publish(2, "alice", "hi", 1000);

    sub.mutex.lockUncancelable(testing.io);
    const empty = sub.queue.items.len == 0;
    sub.mutex.unlock(testing.io);
    try testing.expect(empty);
}

test "close then nextEvent drains remaining queue before returning null" {
    var b = Broadcaster.init(testing.allocator, testing.io);
    defer b.deinit();
    const sub = try b.subscribe(1);
    defer b.unsubscribe(1, sub);

    b.publish(1, "alice", "first", 1);
    b.publish(1, "alice", "second", 2);
    b.close(sub);

    const first = sub.nextEvent(testing.io) orelse return error.TestExpectedValue;
    defer sub.freeEvent(first);
    try testing.expectEqualStrings("first", first.text.?);

    const second = sub.nextEvent(testing.io) orelse return error.TestExpectedValue;
    defer sub.freeEvent(second);
    try testing.expectEqualStrings("second", second.text.?);

    try testing.expect(sub.nextEvent(testing.io) == null);
}

test "closing an idle subscriber unblocks nextEvent from another thread" {
    var b = Broadcaster.init(testing.allocator, testing.io);
    defer b.deinit();
    const sub = try b.subscribe(1);
    defer b.unsubscribe(1, sub);

    const Closer = struct {
        fn run(bc: *Broadcaster, s: *Subscriber) void {
            bc.close(s);
        }
    };
    const thread = try std.Thread.spawn(.{}, Closer.run, .{ &b, sub });
    defer thread.join();

    try testing.expect(sub.nextEvent(testing.io) == null);
}

test "multiple subscribers to the same chat both receive the event" {
    var b = Broadcaster.init(testing.allocator, testing.io);
    defer b.deinit();
    const sub1 = try b.subscribe(7);
    defer b.unsubscribe(7, sub1);
    const sub2 = try b.subscribe(7);
    defer b.unsubscribe(7, sub2);

    b.publish(7, "bob", "hey both", 99);

    const ev1 = sub1.nextEvent(testing.io) orelse return error.TestExpectedValue;
    defer sub1.freeEvent(ev1);
    const ev2 = sub2.nextEvent(testing.io) orelse return error.TestExpectedValue;
    defer sub2.freeEvent(ev2);
    try testing.expectEqualStrings("hey both", ev1.text.?);
    try testing.expectEqualStrings("hey both", ev2.text.?);
}

test "publish with null text is delivered as null, not an empty string" {
    var b = Broadcaster.init(testing.allocator, testing.io);
    defer b.deinit();
    const sub = try b.subscribe(1);
    defer b.unsubscribe(1, sub);

    b.publish(1, "alice", null, 1);
    const ev = sub.nextEvent(testing.io) orelse return error.TestExpectedValue;
    defer sub.freeEvent(ev);
    try testing.expect(ev.text == null);
}
