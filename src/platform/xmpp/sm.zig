//! XEP-0198 stream management state: stanza counters and the queue of sent
//! stanzas the server hasn't acknowledged yet. Survives reconnects, so a
//! resumed (or replaced) stream can resend what the old one may have lost.
const std = @import("std");
const Io = std.Io;

pub const ns = "urn:xmpp:sm:3";
pub const enable_xml = "<enable xmlns='" ++ ns ++ "' resume='true'/>";
pub const request_xml = "<r xmlns='" ++ ns ++ "'/>";

/// Unacknowledged stanzas kept at most; the oldest go first beyond this.
pub const max_queue = 500;

pub const StreamMgmt = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    /// Counting on the current stream (set once `<enable/>` is sent).
    recording: bool = false,
    /// The server confirmed `<enabled/>` on the current stream.
    enabled: bool = false,
    /// Resumption id from `<enabled resume='true'/>`; null when not resumable.
    resume_id: ?[]u8 = null,
    /// Stanzas received from the server on this session.
    h_in: u32 = 0,
    /// Stanzas the server has acknowledged.
    acked: u32 = 0,
    /// Sent but unacknowledged stanzas, oldest first; entry i is stanza
    /// `acked + 1 + i`.
    queue: std.ArrayList([]u8) = .empty,
    /// Wall-clock seconds of the oldest unanswered `<r/>`, 0 when none.
    r_pending_since: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: Io) StreamMgmt {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *StreamMgmt) void {
        self.clearQueueLocked();
        self.queue.deinit(self.allocator);
        if (self.resume_id) |r| self.allocator.free(r);
    }

    pub fn isStanza(bytes: []const u8) bool {
        return std.mem.startsWith(u8, bytes, "<message") or
            std.mem.startsWith(u8, bytes, "<iq") or
            std.mem.startsWith(u8, bytes, "<presence");
    }

    /// Called with the client's write lock held, before the write itself, so
    /// queue order matches wire order. Returns whether to follow up with `<r/>`.
    pub fn recordSent(self: *StreamMgmt, bytes: []const u8) bool {
        if (!isStanza(bytes)) return false;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (!self.recording) return false;
        self.appendLocked(bytes);
        // Only messages are followed by `<r/>`; other stanzas get acked with them.
        if (!std.mem.startsWith(u8, bytes, "<message")) return false;
        if (self.r_pending_since == 0) self.r_pending_since = self.now();
        return true;
    }

    /// Queues a stanza while disconnected from a resumable session; false
    /// when there is no session to resume.
    pub fn queueOffline(self: *StreamMgmt, bytes: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.resume_id == null) return false;
        self.appendLocked(bytes);
        return true;
    }

    fn appendLocked(self: *StreamMgmt, bytes: []const u8) void {
        const copy = self.allocator.dupe(u8, bytes) catch return;
        if (self.queue.items.len >= max_queue) {
            self.allocator.free(self.queue.orderedRemove(0));
            self.acked +%= 1;
        }
        self.queue.append(self.allocator, copy) catch self.allocator.free(copy);
    }

    pub fn countInbound(self: *StreamMgmt) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.enabled) self.h_in +%= 1;
    }

    pub fn inboundCount(self: *StreamMgmt) u32 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.h_in;
    }

    /// Applies the server's `h`: drops every stanza it has acknowledged.
    pub fn handleAck(self: *StreamMgmt, h: u32) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.ackLocked(h);
        self.r_pending_since = 0;
    }

    fn ackLocked(self: *StreamMgmt, h: u32) void {
        const n = h -% self.acked;
        // An `h` beyond what we sent is a server bug; ignore it.
        if (n > self.queue.items.len) return;
        for (self.queue.items[0..n]) |b| self.allocator.free(b);
        const rest = self.queue.items.len - n;
        std.mem.copyForwards([]u8, self.queue.items[0..rest], self.queue.items[n..]);
        self.queue.shrinkRetainingCapacity(rest);
        self.acked = h;
    }

    pub fn onEnabled(self: *StreamMgmt, resume_id: ?[]const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.enabled = true;
        if (self.resume_id) |r| self.allocator.free(r);
        self.resume_id = if (resume_id) |r| self.allocator.dupe(u8, r) catch null else null;
    }

    /// The server refused `<enable/>`: nothing on this stream is counted.
    pub fn onEnableFailed(self: *StreamMgmt) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.recording = false;
        self.enabled = false;
        self.clearQueueLocked();
    }

    /// Starts counting a fresh session (right before `<enable/>` goes out).
    pub fn beginSession(self: *StreamMgmt) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.recording = true;
        self.enabled = false;
        self.h_in = 0;
        self.acked = 0;
        self.r_pending_since = 0;
        if (self.resume_id) |r| self.allocator.free(r);
        self.resume_id = null;
    }

    /// The previous session is gone for good. Returns its unacknowledged
    /// `<message>` stanzas (owned, oldest first) to resend on the new one;
    /// IQs and presences from it are meaningless now.
    pub fn abandonSession(self: *StreamMgmt, h: ?u32) ![][]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (h) |v| self.ackLocked(v);
        var keep: std.ArrayList([]u8) = .empty;
        errdefer {
            for (keep.items) |b| self.allocator.free(b);
            keep.deinit(self.allocator);
        }
        for (self.queue.items) |b| {
            if (std.mem.startsWith(u8, b, "<message")) {
                try keep.append(self.allocator, b);
            } else self.allocator.free(b);
        }
        self.queue.clearRetainingCapacity();
        self.recording = false;
        self.enabled = false;
        if (self.resume_id) |r| self.allocator.free(r);
        self.resume_id = null;
        return keep.toOwnedSlice(self.allocator);
    }

    /// After `<resumed h=…/>`: drops what the server got and returns the
    /// rest (borrowed; valid until the next mutation) to write verbatim.
    pub fn resumed(self: *StreamMgmt, h: u32) []const []u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.ackLocked(h);
        self.recording = true;
        self.enabled = true;
        self.r_pending_since = if (self.queue.items.len > 0) self.now() else 0;
        return self.queue.items;
    }

    /// The connection dropped: stop counting until the next stream.
    pub fn onDisconnect(self: *StreamMgmt) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.recording = false;
        self.enabled = false;
        self.r_pending_since = 0;
    }

    pub fn resumeId(self: *StreamMgmt, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return if (self.resume_id) |r| try allocator.dupe(u8, r) else null;
    }

    /// Seconds an `<r/>` has gone unanswered, 0 when none is outstanding.
    pub fn ackOverdueSeconds(self: *StreamMgmt) i64 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (!self.enabled or self.r_pending_since == 0) return 0;
        return self.now() - self.r_pending_since;
    }

    pub fn noteRequestSent(self: *StreamMgmt) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.r_pending_since == 0) self.r_pending_since = self.now();
    }

    pub fn enabledNow(self: *StreamMgmt) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.enabled;
    }

    pub fn queued(self: *StreamMgmt) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.queue.items.len;
    }

    fn clearQueueLocked(self: *StreamMgmt) void {
        for (self.queue.items) |b| self.allocator.free(b);
        self.queue.clearRetainingCapacity();
    }

    fn now(self: *StreamMgmt) i64 {
        return Io.Timestamp.now(self.io, .real).toSeconds();
    }
};

const testing = std.testing;

test "acks drop exactly the acknowledged prefix, with u32 wraparound" {
    var sm = StreamMgmt.init(testing.allocator, testing.io);
    defer sm.deinit();
    sm.beginSession();
    sm.acked = std.math.maxInt(u32) - 1;
    try testing.expect(sm.recordSent("<message id='1'/>"));
    try testing.expect(!sm.recordSent("<iq id='2'/>"));
    try testing.expect(!sm.recordSent(" "));
    try testing.expect(sm.recordSent("<message id='3'/>"));
    try testing.expectEqual(@as(usize, 3), sm.queued());

    sm.handleAck(std.math.maxInt(u32)); // the first one
    try testing.expectEqual(@as(usize, 2), sm.queued());
    sm.handleAck(1); // wrapped past zero: the second and third
    try testing.expectEqual(@as(usize, 0), sm.queued());
    // An ack past what was sent is ignored.
    sm.handleAck(9);
    try testing.expectEqual(@as(u32, 1), sm.acked);
}

test "resume hands back the unacked tail; abandoning keeps only messages" {
    var sm = StreamMgmt.init(testing.allocator, testing.io);
    defer sm.deinit();
    sm.beginSession();
    _ = sm.recordSent("<message id='a'/>");
    _ = sm.recordSent("<iq id='b'/>");
    _ = sm.recordSent("<message id='c'/>");
    sm.onEnabled("sess-1");
    sm.onDisconnect();
    try testing.expect(!sm.recordSent("<message id='lost'/>"));
    try testing.expect(sm.queueOffline("<message id='d'/>"));

    const rest = sm.resumed(1);
    try testing.expectEqual(@as(usize, 3), rest.len);
    try testing.expectEqualStrings("<iq id='b'/>", rest[0]);
    try testing.expectEqualStrings("<message id='d'/>", rest[2]);

    const again = try sm.abandonSession(2);
    defer {
        for (again) |b| testing.allocator.free(b);
        testing.allocator.free(again);
    }
    try testing.expectEqual(@as(usize, 2), again.len);
    try testing.expectEqualStrings("<message id='c'/>", again[0]);
    try testing.expect(!sm.queueOffline("<message id='e'/>"));
}

test "inbound stanzas count only once enabled" {
    var sm = StreamMgmt.init(testing.allocator, testing.io);
    defer sm.deinit();
    sm.beginSession();
    sm.countInbound();
    sm.onEnabled(null);
    sm.countInbound();
    sm.countInbound();
    try testing.expectEqual(@as(u32, 2), sm.inboundCount());
}
