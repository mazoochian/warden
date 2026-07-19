const std = @import("std");
const Io = std.Io;

const iface = @import("interface.zig");
const raw = @import("../telegram/client.zig");
const types = @import("../telegram/types.zig");
const Identity = @import("../domain/identity.zig").Identity;
const TelegramProfile = @import("../domain/telegram_profile.zig").TelegramProfile;

/// Telegram implementation of `platform.Connector`, backed by long polling.
pub const TelegramConnector = struct {
    client: raw.Client,
    offset: i64 = 0,
    /// Own identity from `getMe`, fetched lazily on the first poll (and
    /// retried each poll until it succeeds). Both live in the client's
    /// long-lived allocator, not the per-poll arena, since messages keep
    /// getting checked against them for the process lifetime.
    self_id: ?i64 = null,
    self_id_str: ?[]const u8 = null,
    self_username: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, bot_token: []const u8) TelegramConnector {
        return .{ .client = raw.Client.init(allocator, io, bot_token) };
    }

    pub fn deinit(self: *TelegramConnector) void {
        if (self.self_username) |u| self.client.allocator.free(u);
        if (self.self_id_str) |s| self.client.allocator.free(s);
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
        self.self_id_str = std.fmt.allocPrint(self.client.allocator, "{d}", .{user.id}) catch null;
        if (user.username) |u| {
            self.self_username = self.client.allocator.dupe(u8, u) catch null;
        }
    }

    /// Builds just the ancestor `Identity` from a Bot API `User` — the
    /// common core `profileFromUser` below extends with Telegram-specific
    /// fields, and what's used directly for users Warden only glimpses in
    /// passing (a reply target, a text-mention, a join/leave event, an
    /// admin-list entry) where the fuller `TelegramProfile` extension isn't
    /// worth building. Allocates out of `allocator` — same short-lived
    /// poll-cycle arena `profileFromUser`'s callers use.
    fn identityFromUser(allocator: std.mem.Allocator, user: types.User, now: i64) !Identity {
        const native_id = try std.fmt.allocPrint(allocator, "{d}", .{user.id});
        const display_name = if (user.last_name) |last|
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ user.first_name, last })
        else
            try allocator.dupe(u8, user.first_name);

        return .{
            .platform = .telegram,
            .native_id = native_id,
            .display_name = display_name,
            .username = if (user.username) |u| try allocator.dupe(u8, u) else null,
            .is_bot = user.is_bot,
            .first_seen = now,
            .last_seen = now,
        };
    }

    /// Builds the ancestor `Identity` plus Telegram-specific extension from
    /// a fully-parsed Bot API `User` (Telegram sends the whole `User`
    /// object on every message's `from` field, not just id/username, so
    /// this is available per-message, not just from `getMe`/`getChatMember`).
    /// Allocates out of `allocator` — same short-lived poll-cycle arena the
    /// rest of `pollFn` uses; `iface.Message.dupe` deep-copies it into the
    /// per-task arena along with everything else.
    fn profileFromUser(allocator: std.mem.Allocator, user: types.User, now: i64) !TelegramProfile {
        return .{
            .identity = try identityFromUser(allocator, user, now),
            .first_name = try allocator.dupe(u8, user.first_name),
            .last_name = if (user.last_name) |s| try allocator.dupe(u8, s) else null,
            .language_code = if (user.language_code) |s| try allocator.dupe(u8, s) else null,
            .is_premium = user.is_premium,
            .added_to_attachment_menu = user.added_to_attachment_menu,
            .can_join_groups = user.can_join_groups,
            .can_read_all_group_messages = user.can_read_all_group_messages,
            .supports_inline_queries = user.supports_inline_queries,
        };
    }

    /// Collects every identity a message reveals *besides* its own sender —
    /// see `iface.Message.observed_users`'s doc comment for why this exists.
    /// Skips the bot's own account (it's not a "participant" worth
    /// surfacing to `find_chat_member`) and de-dupes by native id within
    /// this one message, since e.g. a reply target who's also
    /// text-mentioned in the same message would otherwise appear twice.
    fn observedUsersFromMessage(self: *TelegramConnector, allocator: std.mem.Allocator, msg: types.Message, now: i64) ![]Identity {
        var out: std.ArrayList(Identity) = .empty;

        const addUser = struct {
            fn call(conn: *TelegramConnector, list: *std.ArrayList(Identity), alloc: std.mem.Allocator, user: types.User, ts: i64) !void {
                if (conn.self_id) |me| if (user.id == me) return;
                var buf: [24]u8 = undefined;
                const id_str = std.fmt.bufPrint(&buf, "{d}", .{user.id}) catch return;
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing.native_id, id_str)) return;
                }
                try list.append(alloc, try identityFromUser(alloc, user, ts));
            }
        }.call;

        if (msg.reply_to_message) |reply| {
            if (reply.from) |from| try addUser(self, &out, allocator, from, now);
        }
        if (msg.entities) |entities| {
            for (entities) |entity| {
                if (!std.mem.eql(u8, entity.type, "text_mention")) continue;
                const user = entity.user orelse continue;
                try addUser(self, &out, allocator, user, now);
            }
        }
        if (msg.new_chat_members) |joined| {
            for (joined) |user| try addUser(self, &out, allocator, user, now);
        }
        if (msg.left_chat_member) |user| try addUser(self, &out, allocator, user, now);

        return out.toOwnedSlice(allocator);
    }

    /// Telegram sends at most one of photo/document/voice/audio/video per
    /// message; checked in this order since only `photo` is ever a list
    /// (multiple resolutions) rather than a single object. Duped into
    /// `allocator` — the same short-lived poll-cycle arena the rest of
    /// `pollFn` uses.
    fn attachmentFromMessage(allocator: std.mem.Allocator, msg: types.Message) !?iface.Attachment {
        if (msg.document) |doc| {
            return .{
                .kind = .document,
                .file_id = try allocator.dupe(u8, doc.file_id),
                .file_name = if (doc.file_name) |n| try allocator.dupe(u8, n) else null,
                .mime_type = if (doc.mime_type) |m| try allocator.dupe(u8, m) else null,
            };
        }
        if (msg.photo) |sizes| {
            if (sizes.len == 0) return null;
            var largest = sizes[0];
            for (sizes[1..]) |s| {
                if (s.width * s.height > largest.width * largest.height) largest = s;
            }
            return .{ .kind = .photo, .file_id = try allocator.dupe(u8, largest.file_id) };
        }
        if (msg.voice) |voice| {
            return .{
                .kind = .voice,
                .file_id = try allocator.dupe(u8, voice.file_id),
                .mime_type = if (voice.mime_type) |m| try allocator.dupe(u8, m) else null,
            };
        }
        if (msg.audio) |audio| {
            return .{
                .kind = .audio,
                .file_id = try allocator.dupe(u8, audio.file_id),
                .file_name = if (audio.file_name) |n| try allocator.dupe(u8, n) else null,
                .mime_type = if (audio.mime_type) |m| try allocator.dupe(u8, m) else null,
            };
        }
        if (msg.video) |video| {
            return .{
                .kind = .video,
                .file_id = try allocator.dupe(u8, video.file_id),
                .file_name = if (video.file_name) |n| try allocator.dupe(u8, n) else null,
                .mime_type = if (video.mime_type) |m| try allocator.dupe(u8, m) else null,
            };
        }
        return null;
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
        .sendDocument = sendDocumentFn,
        .maxMessageLength = maxMessageLengthFn,
        .downloadFile = downloadFileFn,
        .sendMessageReturningId = sendMessageReturningIdFn,
        .editMessage = editMessageFn,
        .sendChoicePrompt = sendChoicePromptFn,
        .muteUser = muteUserFn,
        .unmuteUser = unmuteUserFn,
        .kickUser = kickUserFn,
        .banUser = banUserFn,
        .pinMessage = pinMessageFn,
        .unpinMessage = unpinMessageFn,
        .deleteMessage = deleteMessageFn,
        .isGroupAdmin = isGroupAdminFn,
        .selfUsername = selfUsernameFn,
        .selfId = selfIdFn,
        .listChatAdmins = listChatAdminsFn,
    };

    /// Telegram's documented hard cap on `sendMessage`'s `text` — see
    /// `Connector.VTable.maxMessageLength`'s doc comment for how this feeds
    /// into the cross-platform minimum.
    const max_message_length = 4096;

    fn maxMessageLengthFn(ptr: *anyopaque) usize {
        _ = ptr;
        return max_message_length;
    }

    fn selfUsernameFn(ptr: *anyopaque) ?[]const u8 {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.self_username;
    }

    fn selfIdFn(ptr: *anyopaque) ?[]const u8 {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.self_id_str;
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

            if (update.callback_query) |cq| {
                // Dismisses the client-side spinner regardless of whether
                // the rest of this update is well-formed enough to act on.
                self.client.answerCallbackQuery(allocator, cq.id);
                const cq_message = cq.message orelse continue;
                const from = cq.from orelse continue;
                const data = cq.data orelse continue;

                const chat_id = try std.fmt.allocPrint(allocator, "{d}", .{cq_message.chat.id});
                const message_id = try std.fmt.allocPrint(allocator, "{d}", .{cq_message.message_id});
                const now = Io.Timestamp.now(self.client.io, .real).toSeconds();
                const telegram_profile = try profileFromUser(allocator, from, now);
                const is_group = std.mem.eql(u8, cq_message.chat.type, "group") or
                    std.mem.eql(u8, cq_message.chat.type, "supergroup");

                try messages.append(allocator, .{
                    .chat_id = chat_id,
                    .message_id = message_id,
                    .user_id = telegram_profile.identity.native_id,
                    .username = telegram_profile.identity.username,
                    .is_group = is_group,
                    .chat_type = if (cq_message.chat.type.len > 0) try allocator.dupe(u8, cq_message.chat.type) else null,
                    .chat_title = if (cq_message.chat.title) |t| try allocator.dupe(u8, t) else null,
                    .identity = telegram_profile.identity,
                    .telegram_profile = telegram_profile,
                    .choice_picked = .{
                        .prompt_message_id = message_id,
                        .value = try allocator.dupe(u8, data),
                    },
                });
                continue;
            }

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
            // Telegram puts a caption typed alongside a photo/document/
            // voice/audio/video in `caption`, never `text` — the two are
            // mutually exclusive on any given message, so this always picks
            // the one Telegram actually populated.
            const text = if (msg.text) |t|
                try allocator.dupe(u8, t)
            else if (msg.caption) |c|
                try allocator.dupe(u8, c)
            else
                null;

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

            const telegram_profile = if (msg.from) |from|
                try profileFromUser(allocator, from, msg.date)
            else
                null;

            const attachment = try attachmentFromMessage(allocator, msg);
            const observed_users = try self.observedUsersFromMessage(allocator, msg, msg.date);

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
                .chat_type = if (msg.chat.type.len > 0) try allocator.dupe(u8, msg.chat.type) else null,
                .chat_title = if (msg.chat.title) |t| try allocator.dupe(u8, t) else null,
                .reply_to_is_me = reply_to_is_me,
                .mentions_me = mentions_me,
                .identity = if (telegram_profile) |p| p.identity else null,
                .telegram_profile = telegram_profile,
                .attachment = attachment,
                .observed_users = observed_users,
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

    fn sendChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const iface.Choice, reply_to_message_id: ?[]const u8) anyerror!?[]const u8 {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        const id = try parseId(chat_id);
        const reply_id: ?i64 = if (reply_to_message_id) |r| parseId(r) catch null else null;

        var buttons: std.ArrayList(raw.Client.Button) = .empty;
        defer buttons.deinit(allocator);
        for (choices) |c| {
            const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ c.emoji, c.label });
            try buttons.append(allocator, .{ .text = label, .callback_data = c.value });
        }

        const sent_id = try self.client.sendChoicePrompt(allocator, id, text, buttons.items, reply_id);
        return try std.fmt.allocPrint(allocator, "{d}", .{sent_id});
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

    fn sendDocumentFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        const id = parseChatId(chat_id) orelse return;
        self.client.sendDocument(allocator, id, file_bytes, file_name, caption);
    }

    fn downloadFileFn(ptr: *anyopaque, allocator: std.mem.Allocator, file_id: []const u8) anyerror![]u8 {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        return self.client.downloadFile(allocator, file_id);
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

    fn listChatAdminsFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8) anyerror![]Identity {
        const self: *TelegramConnector = @ptrCast(@alignCast(ptr));
        var parsed = try self.client.getChatAdministrators(allocator, try parseId(chat_id));
        defer parsed.deinit();

        if (!parsed.value.ok) {
            std.log.err("telegram getChatAdministrators not-ok: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        }

        const now = Io.Timestamp.now(self.client.io, .real).toSeconds();
        var out: std.ArrayList(Identity) = .empty;
        for (parsed.value.result) |member| {
            const user = member.user orelse continue;
            try out.append(allocator, try identityFromUser(allocator, user, now));
        }
        return out.toOwnedSlice(allocator);
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

test "attachmentFromMessage prefers document, then the largest photo size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var small_photo = [_]types.PhotoSize{.{ .file_id = "small", .width = 90, .height = 90 }};
    const with_document = types.Message{
        .message_id = 1,
        .chat = .{ .id = 1 },
        .document = .{ .file_id = "doc1", .file_name = "report.pdf", .mime_type = "application/pdf" },
        .photo = small_photo[0..],
    };
    const att1 = (try TelegramConnector.attachmentFromMessage(a, with_document)).?;
    try testing.expectEqual(iface.AttachmentKind.document, att1.kind);
    try testing.expectEqualStrings("doc1", att1.file_id);
    try testing.expectEqualStrings("report.pdf", att1.file_name.?);

    var photo_sizes = [_]types.PhotoSize{
        .{ .file_id = "small", .width = 90, .height = 90 },
        .{ .file_id = "big", .width = 800, .height = 600 },
        .{ .file_id = "medium", .width = 300, .height = 300 },
    };
    const with_photo = types.Message{
        .message_id = 2,
        .chat = .{ .id = 1 },
        .photo = photo_sizes[0..],
    };
    const att2 = (try TelegramConnector.attachmentFromMessage(a, with_photo)).?;
    try testing.expectEqual(iface.AttachmentKind.photo, att2.kind);
    try testing.expectEqualStrings("big", att2.file_id);

    const with_nothing = types.Message{ .message_id = 3, .chat = .{ .id = 1 } };
    try testing.expectEqual(@as(?iface.Attachment, null), try TelegramConnector.attachmentFromMessage(a, with_nothing));
}

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

test "observedUsersFromMessage collects reply target, text-mentions, and join/leave, deduped and self-excluded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conn = TelegramConnector.init(testing.allocator, testing.io, "test-token");
    defer conn.deinit();
    conn.self_id = 999; // the bot's own account, must never show up

    const bob = types.User{ .id = 42, .first_name = "Bob" };
    const carol = types.User{ .id = 7, .first_name = "Carol", .username = "carol_c" };
    const the_bot = types.User{ .id = 999, .first_name = "Warden", .is_bot = true };

    var entities = [_]types.MessageEntity{
        .{ .type = "text_mention", .user = carol },
        // A reply target who's also text-mentioned in the same message
        // must not be double-counted.
        .{ .type = "text_mention", .user = bob },
        .{ .type = "bold" }, // no `user` — must not crash or add a bogus entry
    };
    var joined = [_]types.User{the_bot}; // the join event includes the bot itself

    const msg = types.Message{
        .message_id = 1,
        .chat = .{ .id = 1 },
        .reply_to_message = .{ .message_id = 0, .from = bob },
        .entities = entities[0..],
        .new_chat_members = joined[0..],
    };

    const observed = try conn.observedUsersFromMessage(a, msg, 1000);
    try testing.expectEqual(@as(usize, 2), observed.len);
    try testing.expectEqualStrings("42", observed[0].native_id);
    try testing.expectEqualStrings("Bob", observed[0].display_name);
    try testing.expectEqualStrings("7", observed[1].native_id);
    try testing.expectEqualStrings("carol_c", observed[1].username.?);
}

test "observedUsersFromMessage is empty for a plain message with nothing extra to observe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conn = TelegramConnector.init(testing.allocator, testing.io, "test-token");
    defer conn.deinit();

    const msg = types.Message{ .message_id = 1, .chat = .{ .id = 1 } };
    const observed = try conn.observedUsersFromMessage(a, msg, 1000);
    try testing.expectEqual(@as(usize, 0), observed.len);
}
