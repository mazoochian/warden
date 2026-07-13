const std = @import("std");

/// Chat platforms Warden can be wired up to. Only `.telegram` has an
/// implementation right now; the others exist so config/auth code can
/// already be written against a stable enum instead of raw strings.
pub const Platform = enum {
    telegram,
    matrix,
    discord,
    whatsapp,
};

/// A platform-agnostic inbound message. Adapters translate their native
/// wire format into this shape. IDs are kept as strings since native ID
/// types vary wildly (Telegram: i64, Matrix: "!room:server"/"@user:server",
/// Discord: u64 snowflake, WhatsApp: phone number) — adapters own the
/// parsing/formatting round trip to their own native type.
pub const Message = struct {
    chat_id: []const u8,
    /// This message's own id — pass back to `sendMessage`'s
    /// `reply_to_message_id` so the bot's answer shows up threaded under
    /// the message that prompted it, rather than as a bare new message.
    message_id: ?[]const u8 = null,
    user_id: []const u8,
    username: ?[]const u8 = null,
    text: ?[]const u8 = null,
    /// Populated when this message is a direct reply to another one — the
    /// primary way group-admin commands target a user/message (e.g. reply
    /// to someone's message with "/ban" rather than needing to resolve a
    /// username or user id by hand).
    reply_to_message_id: ?[]const u8 = null,
    reply_to_user_id: ?[]const u8 = null,
    reply_to_username: ?[]const u8 = null,
    /// Text of the message being replied to, when the platform provides it.
    /// Lets a reply to one of the bot's own answers carry the context of
    /// what it's following up on.
    reply_to_text: ?[]const u8 = null,
    /// True in a multi-user chat, false in a 1:1 conversation with the bot.
    /// Drives the "don't answer everything in a group" gating: DMs always
    /// get a response.
    is_group: bool = false,
    /// True when this message is a direct reply to something the bot sent.
    /// Set by the adapter, which knows its own platform identity.
    reply_to_is_me: bool = false,
    /// True when the message addresses the bot by name in the platform's
    /// native way (e.g. "@botusername" on Telegram). Set by the adapter.
    mentions_me: bool = false,

    /// Deep-copies every string field into `allocator`. The poll loop
    /// spawns one concurrent task per message, each owning its own arena;
    /// this detaches a message from the short-lived arena `poll()` used to
    /// build the batch, which gets freed as soon as every message in it
    /// has been handed off to its own task.
    pub fn dupe(self: Message, allocator: std.mem.Allocator) !Message {
        return .{
            .chat_id = try allocator.dupe(u8, self.chat_id),
            .message_id = if (self.message_id) |s| try allocator.dupe(u8, s) else null,
            .user_id = try allocator.dupe(u8, self.user_id),
            .username = if (self.username) |s| try allocator.dupe(u8, s) else null,
            .text = if (self.text) |s| try allocator.dupe(u8, s) else null,
            .reply_to_message_id = if (self.reply_to_message_id) |s| try allocator.dupe(u8, s) else null,
            .reply_to_user_id = if (self.reply_to_user_id) |s| try allocator.dupe(u8, s) else null,
            .reply_to_username = if (self.reply_to_username) |s| try allocator.dupe(u8, s) else null,
            .reply_to_text = if (self.reply_to_text) |s| try allocator.dupe(u8, s) else null,
            .is_group = self.is_group,
            .reply_to_is_me = self.reply_to_is_me,
            .mentions_me = self.mentions_me,
        };
    }
};

/// Vtable-based connector interface, one implementation per platform.
/// Modeled after `std.mem.Allocator`/`std.Io`'s ptr+vtable pattern.
///
/// Admin actions are optional (default to `null`): a platform that can't or
/// doesn't yet implement one (e.g. a future Matrix connector without
/// moderation power levels wired up) simply reports `error.Unsupported`
/// rather than every connector needing a stub implementation.
pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        platform: *const fn (ptr: *anyopaque) Platform,
        /// Blocks until at least one message arrives or a poll cycle times
        /// out (returning an empty slice is fine). Allocates out of
        /// `allocator`, which callers are expected to reset per cycle
        /// (e.g. an arena).
        poll: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Message,
        /// Best-effort send: adapters log failures themselves rather than
        /// propagating them, since a failed reply shouldn't crash the poll
        /// loop. `reply_to_message_id`, when set, threads the message as a
        /// platform-native reply to that message id instead of a bare new
        /// message; adapters that don't support it may ignore it.
        sendMessage: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void,
        /// Sends an image (e.g. a rendered word cloud/diagram). Optional
        /// since not every platform this bot might target necessarily
        /// supports rich media the same way.
        sendPhoto: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void = null,
        /// Like `sendMessage`, but returns the id of the sent message so it
        /// can later be `editMessage`d — the "thinking" placeholder /
        /// progressive-answer flow. Optional: a platform without a message-
        /// editing concept just doesn't get animated replies (`editMessage`
        /// null too), falling back to the plain send-when-done behavior.
        sendMessageReturningId: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 = null,
        /// Replaces the text of a previously-sent message.
        editMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void = null,

        /// Restricts a user from sending messages until `until_unix_time`
        /// (0 = forever, until explicitly unmuted).
        muteUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) anyerror!void = null,
        unmuteUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        /// Removes a user but allows them back in (ban immediately followed
        /// by unban, Telegram's standard "kick" idiom).
        kickUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        /// Permanent removal — stays banned until explicitly unbanned.
        banUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        pinMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void = null,
        /// `message_id` null unpins whatever's currently pinned.
        unpinMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: ?[]const u8) anyerror!void = null,
        deleteMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void = null,
        /// True if `user_id` currently has admin/owner standing in
        /// `chat_id` on this platform — the source of truth `group_admin.zig`
        /// gates moderation commands on. Optional: a platform without a
        /// group-admin concept (e.g. a 1:1-only platform) just has every
        /// group-management command report `error.Unsupported`.
        isGroupAdmin: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool = null,
        /// The bot's own username on this platform, if known (adapters may
        /// only learn it after their first API round trip). The returned
        /// slice must stay valid for the connector's lifetime — used e.g.
        /// to attribute the bot's own answers in the chat log.
        selfUsername: ?*const fn (ptr: *anyopaque) ?[]const u8 = null,
    };

    pub fn platform(self: Connector) Platform {
        return self.vtable.platform(self.ptr);
    }

    pub fn poll(self: Connector, allocator: std.mem.Allocator) ![]Message {
        return self.vtable.poll(self.ptr, allocator);
    }

    pub fn sendMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        self.vtable.sendMessage(self.ptr, allocator, chat_id, text, reply_to_message_id);
    }

    pub fn sendPhoto(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        const f = self.vtable.sendPhoto orelse {
            self.sendMessage(allocator, chat_id, "This platform doesn't support sending images.", null);
            return;
        };
        f(self.ptr, allocator, chat_id, image_bytes, caption);
    }

    /// Returns `null` when the platform doesn't support it (caller should
    /// fall back to a plain `sendMessage`), or propagates a real send error.
    pub fn sendMessageReturningId(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) !?[]const u8 {
        const f = self.vtable.sendMessageReturningId orelse return null;
        return try f(self.ptr, allocator, chat_id, text, reply_to_message_id);
    }

    pub fn editMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) !void {
        const f = self.vtable.editMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id, text);
    }

    pub fn muteUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) !void {
        const f = self.vtable.muteUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id, until_unix_time);
    }

    pub fn unmuteUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.unmuteUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn kickUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.kickUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn banUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.banUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn pinMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) !void {
        const f = self.vtable.pinMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id);
    }

    pub fn unpinMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: ?[]const u8) !void {
        const f = self.vtable.unpinMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id);
    }

    pub fn deleteMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) !void {
        const f = self.vtable.deleteMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id);
    }

    pub fn isGroupAdmin(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !bool {
        const f = self.vtable.isGroupAdmin orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn selfUsername(self: Connector) ?[]const u8 {
        const f = self.vtable.selfUsername orelse return null;
        return f(self.ptr);
    }
};

const testing = std.testing;

test "Message.dupe deep-copies every string field into the new allocator" {
    // Not deferred: deinited explicitly mid-test (see below) to prove
    // `dst` doesn't alias it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    // Built with allocations from an arena the caller will free right
    // after `dupe` returns, to prove the result doesn't alias `src`.
    const src = Message{
        .chat_id = try src_a.dupe(u8, "123"),
        .message_id = try src_a.dupe(u8, "555"),
        .user_id = try src_a.dupe(u8, "42"),
        .username = try src_a.dupe(u8, "alice"),
        .text = try src_a.dupe(u8, "hello"),
        .reply_to_message_id = try src_a.dupe(u8, "554"),
        .reply_to_user_id = try src_a.dupe(u8, "43"),
        .reply_to_username = try src_a.dupe(u8, "bob"),
        .reply_to_text = try src_a.dupe(u8, "earlier text"),
        .is_group = true,
        .reply_to_is_me = true,
        .mentions_me = true,
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.message_id.?);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.username.?);
        testing.allocator.free(dst.text.?);
        testing.allocator.free(dst.reply_to_message_id.?);
        testing.allocator.free(dst.reply_to_user_id.?);
        testing.allocator.free(dst.reply_to_username.?);
        testing.allocator.free(dst.reply_to_text.?);
    }

    // Freeing the source arena now (before any assertions) proves `dst`
    // doesn't merely borrow `src`'s pointers — a UAF would corrupt these
    // reads on most allocators.
    arena.deinit();

    try testing.expectEqualStrings("123", dst.chat_id);
    try testing.expectEqualStrings("555", dst.message_id.?);
    try testing.expectEqualStrings("42", dst.user_id);
    try testing.expectEqualStrings("alice", dst.username.?);
    try testing.expectEqualStrings("hello", dst.text.?);
    try testing.expectEqualStrings("554", dst.reply_to_message_id.?);
    try testing.expectEqualStrings("43", dst.reply_to_user_id.?);
    try testing.expectEqualStrings("bob", dst.reply_to_username.?);
    try testing.expectEqualStrings("earlier text", dst.reply_to_text.?);
    try testing.expect(dst.is_group);
    try testing.expect(dst.reply_to_is_me);
    try testing.expect(dst.mentions_me);
}

test "Message.dupe passes through null optional fields as null" {
    const src = Message{ .chat_id = "1", .user_id = "2" };
    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
    }
    try testing.expectEqual(@as(?[]const u8, null), dst.message_id);
    try testing.expectEqual(@as(?[]const u8, null), dst.username);
    try testing.expectEqual(@as(?[]const u8, null), dst.text);
}
