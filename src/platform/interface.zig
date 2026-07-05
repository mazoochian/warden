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
        /// loop.
        sendMessage: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8) void,
        /// Sends an image (e.g. a rendered word cloud/diagram). Optional
        /// since not every platform this bot might target necessarily
        /// supports rich media the same way.
        sendPhoto: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void = null,

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
    };

    pub fn platform(self: Connector) Platform {
        return self.vtable.platform(self.ptr);
    }

    pub fn poll(self: Connector, allocator: std.mem.Allocator) ![]Message {
        return self.vtable.poll(self.ptr, allocator);
    }

    pub fn sendMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8) void {
        self.vtable.sendMessage(self.ptr, allocator, chat_id, text);
    }

    pub fn sendPhoto(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        const f = self.vtable.sendPhoto orelse {
            self.sendMessage(allocator, chat_id, "This platform doesn't support sending images.");
            return;
        };
        f(self.ptr, allocator, chat_id, image_bytes, caption);
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
};
