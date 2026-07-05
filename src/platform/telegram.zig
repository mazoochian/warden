const std = @import("std");
const Io = std.Io;

const iface = @import("interface.zig");
const raw = @import("../telegram/client.zig");

/// Telegram implementation of `platform.Connector`, backed by long polling.
pub const TelegramConnector = struct {
    client: raw.Client,
    offset: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: Io, bot_token: []const u8) TelegramConnector {
        return .{ .client = raw.Client.init(allocator, io, bot_token) };
    }

    pub fn deinit(self: *TelegramConnector) void {
        self.client.deinit();
    }

    pub fn connector(self: *TelegramConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendPhoto = sendPhotoFn,
        .muteUser = muteUserFn,
        .unmuteUser = unmuteUserFn,
        .kickUser = kickUserFn,
        .banUser = banUserFn,
        .pinMessage = pinMessageFn,
        .unpinMessage = unpinMessageFn,
        .deleteMessage = deleteMessageFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram;
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));

        var updates = try self.client.getUpdates(allocator, self.offset, 30);
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
            if (msg.reply_to_message) |reply| {
                reply_to_message_id = try std.fmt.allocPrint(allocator, "{d}", .{reply.message_id});
                if (reply.from) |from| {
                    reply_to_user_id = try std.fmt.allocPrint(allocator, "{d}", .{from.id});
                    reply_to_username = if (from.username) |u| try allocator.dupe(u8, u) else null;
                }
            }

            try messages.append(allocator, .{
                .chat_id = chat_id,
                .user_id = user_id,
                .username = username,
                .text = text,
                .reply_to_message_id = reply_to_message_id,
                .reply_to_user_id = reply_to_user_id,
                .reply_to_username = reply_to_username,
            });
        }
        return messages.toOwnedSlice(allocator);
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8) void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        const id = parseChatId(chat_id) orelse return;
        self.client.sendMessage(allocator, id, text);
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
