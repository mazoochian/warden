const std = @import("std");
const Io = std.Io;

/// One reply drafted on the owner's behalf, waiting for `/approve` or
/// `/discard` (Phase D of the plan sent to the owner — see
/// `PendingDrafts`'s doc comment). Everything needed to both show the
/// owner what's pending and actually send it once approved, so `/approve`
/// never has to re-derive anything from `msg`.
const Draft = struct {
    /// TDLib's own chat id (not the Bot API's) — the same id space
    /// `/sendas`/`/tdchats` already use, so a draft's key matches what the
    /// owner sees there too.
    chat_title: []const u8,
    incoming_text: []const u8,
    draft_text: []const u8,
    /// The incoming message's id, so an approved send threads as a reply
    /// in the real chat instead of arriving as a bare new message.
    reply_to: ?[]const u8,
    expires_at: i64,
};

/// One pending "reply on my behalf" draft per personal-account chat,
/// awaiting the owner's `/approve`/`/discard` — the `reply_autonomy = .draft`
/// counterpart to `group_admin.PendingConfirmations`'s ban/kick confirmation
/// (same shape: an in-memory, mutex-guarded map keyed by chat, replaced
/// wholesale by a second draft for the same chat rather than queued).
///
/// A generous default timeout (see the `main.zig` call site) is the right
/// choice here, unlike `PendingConfirmations`'s short one: a ban/kick
/// confirmation is only ever answered in the next few seconds by someone
/// actively at the keyboard, but "reply to this text a few hours later
/// when I actually see it" is completely normal for a personal account.
///
/// Accessed from concurrently-running per-message tasks (the connector
/// that receives the incoming message and the connector the owner types
/// `/approve` on are almost always different threads) — `lockUncancelable`
/// since these are quick in-memory operations, matching
/// `PendingConfirmations`'s own reasoning.
pub const PendingDrafts = struct {
    allocator: std.mem.Allocator,
    io: Io,
    map: std.StringHashMap(Draft),
    mutex: Io.Mutex = .init,
    timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, timeout_seconds: i64) PendingDrafts {
        return .{
            .allocator = allocator,
            .io = io,
            .map = std.StringHashMap(Draft).init(allocator),
            .timeout_seconds = timeout_seconds,
        };
    }

    pub fn deinit(self: *PendingDrafts) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.freeEntry(entry.key_ptr.*, entry.value_ptr.*);
        self.map.deinit();
    }

    fn freeEntry(self: *PendingDrafts, key: []const u8, draft: Draft) void {
        self.allocator.free(key);
        self.allocator.free(draft.chat_title);
        self.allocator.free(draft.incoming_text);
        self.allocator.free(draft.draft_text);
        if (draft.reply_to) |r| self.allocator.free(r);
    }

    /// Replaces any existing pending draft for `native_chat_id`.
    pub fn set(self: *PendingDrafts, now: i64, native_chat_id: []const u8, chat_title: []const u8, incoming_text: []const u8, draft_text: []const u8, reply_to: ?[]const u8) !void {
        const owned_title = try self.allocator.dupe(u8, chat_title);
        errdefer self.allocator.free(owned_title);
        const owned_incoming = try self.allocator.dupe(u8, incoming_text);
        errdefer self.allocator.free(owned_incoming);
        const owned_draft = try self.allocator.dupe(u8, draft_text);
        errdefer self.allocator.free(owned_draft);
        const owned_reply_to = if (reply_to) |r| try self.allocator.dupe(u8, r) else null;
        errdefer if (owned_reply_to) |r| self.allocator.free(r);

        const draft = Draft{
            .chat_title = owned_title,
            .incoming_text = owned_incoming,
            .draft_text = owned_draft,
            .reply_to = owned_reply_to,
            .expires_at = now + self.timeout_seconds,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.fetchRemove(native_chat_id)) |old| self.freeEntry(old.key, old.value);

        const key = try self.allocator.dupe(u8, native_chat_id);
        errdefer self.allocator.free(key);
        try self.map.put(key, draft);
    }

    /// Removes and returns the pending draft for `native_chat_id` if one
    /// exists and hasn't expired (an expired one is just dropped, not
    /// returned) — the caller owns the returned strings and must free them.
    pub fn take(self: *PendingDrafts, allocator: std.mem.Allocator, now: i64, native_chat_id: []const u8) ?struct { chat_title: []const u8, incoming_text: []const u8, draft_text: []const u8, reply_to: ?[]const u8 } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = self.map.fetchRemove(native_chat_id) orelse return null;
        defer self.freeEntry(entry.key, entry.value);

        if (now > entry.value.expires_at) return null;
        return .{
            .chat_title = allocator.dupe(u8, entry.value.chat_title) catch return null,
            .incoming_text = allocator.dupe(u8, entry.value.incoming_text) catch return null,
            .draft_text = allocator.dupe(u8, entry.value.draft_text) catch return null,
            .reply_to = if (entry.value.reply_to) |r| (allocator.dupe(u8, r) catch return null) else null,
        };
    }

    pub fn discard(self: *PendingDrafts, native_chat_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const old = self.map.fetchRemove(native_chat_id) orelse return false;
        self.freeEntry(old.key, old.value);
        return true;
    }

    pub const Listed = struct {
        native_chat_id: []const u8,
        chat_title: []const u8,
        draft_text: []const u8,
    };

    /// Every non-expired pending draft, for `/drafts` — expired ones are
    /// skipped but deliberately not evicted here (a read shouldn't mutate
    /// the map); they get cleaned up the next time `set`/`take` touches
    /// their key, same lazy-expiry convention `PendingConfirmations.take`
    /// uses.
    pub fn list(self: *PendingDrafts, allocator: std.mem.Allocator, now: i64) ![]Listed {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(Listed) = .empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (now > entry.value_ptr.expires_at) continue;
            try out.append(allocator, .{
                .native_chat_id = try allocator.dupe(u8, entry.key_ptr.*),
                .chat_title = try allocator.dupe(u8, entry.value_ptr.chat_title),
                .draft_text = try allocator.dupe(u8, entry.value_ptr.draft_text),
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

const testing = std.testing;

test "PendingDrafts: set then take round-trips, a second take sees nothing" {
    const io = testing.io;
    var pending = PendingDrafts.init(testing.allocator, io, 3600);
    defer pending.deinit();

    try pending.set(1000, "chat-1", "Alice", "hey are you free tonight?", "Yeah, free after 7", "msg-42");
    const got = pending.take(testing.allocator, 1001, "chat-1").?;
    defer testing.allocator.free(got.chat_title);
    defer testing.allocator.free(got.incoming_text);
    defer testing.allocator.free(got.draft_text);
    defer if (got.reply_to) |r| testing.allocator.free(r);
    try testing.expectEqualStrings("Alice", got.chat_title);
    try testing.expectEqualStrings("Yeah, free after 7", got.draft_text);
    try testing.expectEqualStrings("msg-42", got.reply_to.?);

    try testing.expectEqual(@as(?@TypeOf(got), null), pending.take(testing.allocator, 1002, "chat-1"));
}

test "PendingDrafts: a second set for the same chat replaces the first, not queues" {
    const io = testing.io;
    var pending = PendingDrafts.init(testing.allocator, io, 3600);
    defer pending.deinit();

    try pending.set(1000, "chat-1", "Alice", "first message", "first draft", null);
    try pending.set(1000, "chat-1", "Alice", "second message", "second draft", null);

    const got = pending.take(testing.allocator, 1000, "chat-1").?;
    defer testing.allocator.free(got.chat_title);
    defer testing.allocator.free(got.incoming_text);
    defer testing.allocator.free(got.draft_text);
    try testing.expectEqualStrings("second draft", got.draft_text);
}

test "PendingDrafts: take past the timeout returns null" {
    const io = testing.io;
    var pending = PendingDrafts.init(testing.allocator, io, 60);
    defer pending.deinit();

    try pending.set(1000, "chat-1", "Alice", "hey", "hi!", null);
    try testing.expectEqual(@as(?struct { chat_title: []const u8, incoming_text: []const u8, draft_text: []const u8, reply_to: ?[]const u8 }, null), pending.take(testing.allocator, 1061, "chat-1"));
}

test "PendingDrafts: discard removes a pending draft, reporting whether one existed" {
    const io = testing.io;
    var pending = PendingDrafts.init(testing.allocator, io, 3600);
    defer pending.deinit();

    try testing.expect(!pending.discard("chat-1"));
    try pending.set(1000, "chat-1", "Alice", "hey", "hi!", null);
    try testing.expect(pending.discard("chat-1"));
    try testing.expect(!pending.discard("chat-1"));
}

test "PendingDrafts: list returns every non-expired draft" {
    const io = testing.io;
    var pending = PendingDrafts.init(testing.allocator, io, 60);
    defer pending.deinit();

    try pending.set(1000, "chat-1", "Alice", "hey", "hi Alice!", null);
    try pending.set(1000, "chat-2", "Bob", "yo", "hey Bob!", null);

    const listed = try pending.list(testing.allocator, 1000);
    defer {
        for (listed) |l| {
            testing.allocator.free(l.native_chat_id);
            testing.allocator.free(l.chat_title);
            testing.allocator.free(l.draft_text);
        }
        testing.allocator.free(listed);
    }
    try testing.expectEqual(@as(usize, 2), listed.len);
}
