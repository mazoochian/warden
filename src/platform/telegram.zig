const std = @import("std");
const Io = std.Io;

const iface = @import("interface.zig");
const raw = @import("../telegram/client.zig");

/// Telegram implementation of `platform.Connector`, backed by long polling.
pub const TelegramConnector = struct {
    client: raw.Client,
    offset: i64 = 0,
    /// Own identity from `getMe`, fetched lazily on the first poll (and
    /// retried each poll until it succeeds). Both live in the client's
    /// long-lived allocator, not the per-poll arena, since messages keep
    /// getting checked against them for the process lifetime.
    self_id: ?i64 = null,
    self_username: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, bot_token: []const u8) TelegramConnector {
        return .{ .client = raw.Client.init(allocator, io, bot_token) };
    }

    pub fn deinit(self: *TelegramConnector) void {
        if (self.self_username) |u| self.client.allocator.free(u);
        self.client.deinit();
    }

    fn ensureSelfInfo(self: *TelegramConnector, allocator: std.mem.Allocator) void {
        if (self.self_id != null) return;
        var me = self.client.getMe(allocator) catch |err| {
            std.log.warn("telegram getMe failed (mention detection degraded until it succeeds): {t}", .{err});
            return;
        };
        defer me.deinit();
        const user = me.value.result orelse return;
        self.self_id = user.id;
        if (user.username) |u| {
            self.self_username = self.client.allocator.dupe(u8, u) catch null;
        }
    }

    /// Case-insensitive "@botusername" scan with a right-boundary check, so
    /// "@warden_bot" matches but "@warden_bot2" (a different account) does
    /// not. Telegram usernames are [A-Za-z0-9_], so ASCII handling suffices.
    fn textMentions(text: []const u8, username: []const u8) bool {
        if (username.len == 0) return false;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '@')) |at| {
            start = at + 1;
            const rest = text[at + 1 ..];
            if (rest.len < username.len) return false;
            if (!std.ascii.eqlIgnoreCase(rest[0..username.len], username)) continue;
            const after = rest[username.len..];
            if (after.len == 0 or !(std.ascii.isAlphanumeric(after[0]) or after[0] == '_')) return true;
        }
        return false;
    }

    pub fn connector(self: *TelegramConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendPhoto = sendPhotoFn,
        .sendMessageReturningId = sendMessageReturningIdFn,
        .editMessage = editMessageFn,
        .muteUser = muteUserFn,
        .unmuteUser = unmuteUserFn,
        .kickUser = kickUserFn,
        .banUser = banUserFn,
        .pinMessage = pinMessageFn,
        .unpinMessage = unpinMessageFn,
        .deleteMessage = deleteMessageFn,
        .isGroupAdmin = isGroupAdminFn,
        .selfUsername = selfUsernameFn,
    };

    fn selfUsernameFn(ptr: *anyopaque) ?[]const u8 {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.self_username;
    }

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram;
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));

        self.ensureSelfInfo(allocator);

        // 25s rather than 30: middleboxes commonly reap connections at a
        // round 30s of idleness, which is exactly how long a quiet long
        // poll holds the connection with zero bytes moving.
        var updates = try self.client.getUpdates(allocator, self.offset, 25);
        defer updates.deinit();

        if (!updates.value.ok) {
            std.log.err("telegram getUpdates not-ok: {?s}", .{updates.value.description});
            return &.{};
        }

        var messages: std.ArrayList(iface.Message) = .empty;
        for (updates.value.result) |update| {
            self.offset = @max(self.offset, update.update_id + 1);
            const msg = update.message orelse continue;

            // `updates` (and any strings it owns) is freed via `defer` above,
            // so anything we keep must be duplicated into `allocator`.
            const chat_id = try std.fmt.allocPrint(allocator, "{d}", .{msg.chat.id});
            const message_id = try std.fmt.allocPrint(allocator, "{d}", .{msg.message_id});
            const user_id = if (msg.from) |from|
                try std.fmt.allocPrint(allocator, "{d}", .{from.id})
            else
                "";
            const username = if (msg.from) |from|
                (if (from.username) |u| try allocator.dupe(u8, u) else null)
            else
                null;
            const text = if (msg.text) |t| try allocator.dupe(u8, t) else null;

            var reply_to_message_id: ?[]const u8 = null;
            var reply_to_user_id: ?[]const u8 = null;
            var reply_to_username: ?[]const u8 = null;
            var reply_to_text: ?[]const u8 = null;
            var reply_to_is_me = false;
            if (msg.reply_to_message) |reply| {
                reply_to_message_id = try std.fmt.allocPrint(allocator, "{d}", .{reply.message_id});
                reply_to_text = if (reply.text) |t| try allocator.dupe(u8, t) else null;
                if (reply.from) |from| {
                    reply_to_user_id = try std.fmt.allocPrint(allocator, "{d}", .{from.id});
                    reply_to_username = if (from.username) |u| try allocator.dupe(u8, u) else null;
                    reply_to_is_me = if (self.self_id) |me| from.id == me else false;
                }
            }

            const is_group = std.mem.eql(u8, msg.chat.type, "group") or
                std.mem.eql(u8, msg.chat.type, "supergroup");

            const mentions_me = if (text) |t|
                (if (self.self_username) |me| textMentions(t, me) else false)
            else
                false;

            try messages.append(allocator, .{
                .chat_id = chat_id,
                .message_id = message_id,
                .user_id = user_id,
                .username = username,
                .text = text,
                .reply_to_message_id = reply_to_message_id,
                .reply_to_user_id = reply_to_user_id,
                .reply_to_username = reply_to_username,
                .reply_to_text = reply_to_text,
                .is_group = is_group,
                .reply_to_is_me = reply_to_is_me,
                .mentions_me = mentions_me,
            });
        }
        return messages.toOwnedSlice(allocator);
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        const id = parseChatId(chat_id) orelse return;
        const reply_id: ?i64 = if (reply_to_message_id) |r| parseId(r) catch null else null;
        self.client.sendMessage(allocator, id, text, reply_id);
    }

    fn sendMessageReturningIdFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        const id = try parseId(chat_id);
        const reply_id: ?i64 = if (reply_to_message_id) |r| parseId(r) catch null else null;
        const sent_id = try self.client.sendMessageReturningId(allocator, id, text, reply_id);
        return std.fmt.allocPrint(allocator, "{d}", .{sent_id});
    }

    fn editMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.editMessage(allocator, try parseId(chat_id), try parseId(message_id), text);
    }

    fn sendPhotoFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        const id = parseChatId(chat_id) orelse return;
        self.client.sendPhoto(allocator, id, image_bytes, caption);
    }

    fn muteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.restrictChatMember(allocator, try parseId(chat_id), try parseId(user_id), until_unix_time);
    }

    fn unmuteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.unrestrictChatMember(allocator, try parseId(chat_id), try parseId(user_id));
    }

    fn kickUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.kickChatMember(allocator, try parseId(chat_id), try parseId(user_id));
    }

    fn banUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.banChatMember(allocator, try parseId(chat_id), try parseId(user_id));
    }

    fn pinMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.pinChatMessage(allocator, try parseId(chat_id), try parseId(message_id));
    }

    fn unpinMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: ?[]const u8) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        const mid: ?i64 = if (message_id) |m| try parseId(m) else null;
        return self.client.unpinChatMessage(allocator, try parseId(chat_id), mid);
    }

    fn deleteMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.deleteMessage(allocator, try parseId(chat_id), try parseId(message_id));
    }

    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.isChatAdmin(allocator, try parseId(chat_id), try parseId(user_id));
    }

    fn parseId(s: []const u8) !i64 {
        return std.fmt.parseInt(i64, s, 10);
    }

    fn parseChatId(chat_id: []const u8) ?i64 {
        return parseId(chat_id) catch {
            std.log.err("telegram: invalid chat_id '{s}'", .{chat_id});
            return null;
        };
    }
};

const testing = std.testing;

test "textMentions matches @username case-insensitively at word boundaries" {
    const mentions = TelegramConnector.textMentions;
    try testing.expect(mentions("hey @warden_bot what's up", "warden_bot"));
    try testing.expect(mentions("@Warden_Bot ping", "warden_bot"));
    try testing.expect(mentions("ends with @warden_bot", "warden_bot"));
    try testing.expect(mentions("@warden_bot, comma right after", "warden_bot"));
    // A longer username that merely starts with ours is someone else.
    try testing.expect(!mentions("hey @warden_bot2", "warden_bot"));
    try testing.expect(!mentions("no mention here", "warden_bot"));
    // Bare name without the @ is not a Telegram mention.
    try testing.expect(!mentions("warden_bot without at-sign", "warden_bot"));
    // Earlier non-matching @ must not stop the scan.
    try testing.expect(mentions("@someone and @warden_bot", "warden_bot"));
    try testing.expect(!mentions("anything", ""));
}
