const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const types = @import("types.zig");
const http_util = @import("../http_util.zig");

/// Thin wrapper around the Telegram Bot API. Uses long polling (`getUpdates`)
/// rather than webhooks, since Warden runs local/dev without a public HTTPS
/// endpoint.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    http_client: http.Client,
    bot_token: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, bot_token: []const u8) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
            .bot_token = bot_token,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// Long-polls for new updates starting after `offset`. Blocks for up to
    /// `timeout_secs` seconds if there are none yet. Caller owns the returned
    /// `Parsed` value and must call `.deinit()` on it.
    pub fn getUpdates(
        self: *Client,
        allocator: std.mem.Allocator,
        offset: i64,
        timeout_secs: u32,
    ) !json.Parsed(types.UpdatesResponse) {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout={d}",
            .{ self.bot_token, offset, timeout_secs },
        );
        defer allocator.free(url);

        const body = try http_util.get(&self.http_client, allocator, url);
        defer allocator.free(body);

        // `alloc_always` forces all strings to be duplicated into the
        // Parsed value's own arena instead of borrowing from `body`, which
        // we free right after this call returns.
        return json.parseFromSlice(
            types.UpdatesResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Fetches the bot's own identity (id + username). Caller owns the
    /// returned `Parsed` value and must call `.deinit()` on it.
    pub fn getMe(self: *Client, allocator: std.mem.Allocator) !json.Parsed(types.MeResponse) {
        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/getMe", .{self.bot_token});
        defer allocator.free(url);

        const body = try http_util.get(&self.http_client, allocator, url);
        defer allocator.free(body);

        return json.parseFromSlice(
            types.MeResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Sends a plain text message, threaded as a reply to `reply_to_message_id`
    /// when set (`allow_sending_without_reply` so a reply target that's since
    /// been deleted degrades to a plain message instead of failing outright).
    /// Fire-and-forget: logs failures rather than propagating them, since a
    /// failed reply shouldn't crash the poll loop.
    pub fn sendMessage(self: *Client, allocator: std.mem.Allocator, chat_id: i64, text: []const u8, reply_to_message_id: ?i64) void {
        self.sendMessageErr(allocator, chat_id, text, reply_to_message_id) catch |err| {
            std.log.err("sendMessage failed: {t}", .{err});
        };
    }

    const ReplyParameters = struct {
        message_id: i64,
        allow_sending_without_reply: bool = true,
    };

    fn sendMessageErr(self: *Client, allocator: std.mem.Allocator, chat_id: i64, text: []const u8, reply_to_message_id: ?i64) !void {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/sendMessage",
            .{self.bot_token},
        );
        defer allocator.free(url);

        const reply_parameters: ?ReplyParameters = if (reply_to_message_id) |id| .{ .message_id = id } else null;

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(
            .{ .chat_id = chat_id, .text = text, .reply_parameters = reply_parameters },
            .{},
            &payload_writer.writer,
        );
        const payload = payload_writer.writer.buffered();

        const body = try http_util.postJson(&self.http_client, allocator, url, &.{}, payload);
        defer allocator.free(body);
    }

    const SendMessageResponse = struct {
        ok: bool,
        result: ?struct { message_id: i64 } = null,
        description: ?[]const u8 = null,
    };

    /// Like `sendMessage`, but returns the sent message's id (needed to
    /// edit it later — see `editMessage`) instead of being fire-and-forget.
    pub fn sendMessageReturningId(self: *Client, allocator: std.mem.Allocator, chat_id: i64, text: []const u8, reply_to_message_id: ?i64) !i64 {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/sendMessage",
            .{self.bot_token},
        );
        defer allocator.free(url);

        const reply_parameters: ?ReplyParameters = if (reply_to_message_id) |id| .{ .message_id = id } else null;

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(
            .{ .chat_id = chat_id, .text = text, .reply_parameters = reply_parameters },
            .{},
            &payload_writer.writer,
        );
        const payload = payload_writer.writer.buffered();

        const body = try http_util.postJson(&self.http_client, allocator, url, &.{}, payload);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(
            SendMessageResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        const result = parsed.value.result orelse {
            std.log.err("telegram sendMessage failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        };
        return result.message_id;
    }

    /// Replaces the text of a previously-sent message (the "thinking"
    /// placeholder / progressive-answer editing flow — see main.zig's
    /// `replyWithAnswer`). Telegram rejects an edit whose text is
    /// byte-for-byte identical to the message's current content ("message
    /// is not modified", HTTP 400) — `http_util`'s non-2xx handling
    /// discards the response body, so that specific case can't be told
    /// apart from a real failure here; callers must avoid sending an
    /// identical edit in the first place (main.zig's ticker tracks the
    /// last text it actually sent and skips a no-op edit).
    pub fn editMessage(self: *Client, allocator: std.mem.Allocator, chat_id: i64, message_id: i64, text: []const u8) !void {
        return self.callMethod(allocator, "editMessageText", .{ .chat_id = chat_id, .message_id = message_id, .text = text });
    }

    /// Sends a photo (e.g. a rendered word cloud/diagram). Fire-and-forget
    /// like `sendMessage`.
    pub fn sendPhoto(self: *Client, allocator: std.mem.Allocator, chat_id: i64, image_bytes: []const u8, caption: ?[]const u8) void {
        self.sendPhotoErr(allocator, chat_id, image_bytes, caption) catch |err| {
            std.log.err("sendPhoto failed: {t}", .{err});
        };
    }

    fn sendPhotoErr(self: *Client, allocator: std.mem.Allocator, chat_id: i64, image_bytes: []const u8, caption: ?[]const u8) !void {
        const boundary = "----WardenBoundary7f3a9c2e";

        var body_writer: Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();
        const w = &body_writer.writer;

        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n{d}\r\n", .{chat_id});

        if (caption) |c| {
            try w.print("--{s}\r\n", .{boundary});
            try w.print("Content-Disposition: form-data; name=\"caption\"\r\n\r\n{s}\r\n", .{c});
        }

        try w.print("--{s}\r\n", .{boundary});
        try w.writeAll("Content-Disposition: form-data; name=\"photo\"; filename=\"image.png\"\r\nContent-Type: image/png\r\n\r\n");
        try w.writeAll(image_bytes);
        try w.writeAll("\r\n");
        try w.print("--{s}--\r\n", .{boundary});
        const body = w.buffered();

        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendPhoto", .{self.bot_token});
        defer allocator.free(url);

        const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer allocator.free(content_type);

        const resp_body = try http_util.postRaw(&self.http_client, allocator, url, content_type, body);
        defer allocator.free(resp_body);

        var parsed = try json.parseFromSlice(
            MethodResponse,
            allocator,
            resp_body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        if (!parsed.value.ok) {
            std.log.err("telegram sendPhoto failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        }
    }

    pub fn banChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !void {
        return self.callMethod(allocator, "banChatMember", .{ .chat_id = chat_id, .user_id = user_id });
    }

    /// Ban immediately followed by unban — Telegram's standard idiom for a
    /// "kick" (removes them now, but they're free to rejoin), as opposed to
    /// `banChatMember` alone which is permanent.
    pub fn kickChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !void {
        try self.callMethod(allocator, "banChatMember", .{ .chat_id = chat_id, .user_id = user_id });
        try self.callMethod(allocator, "unbanChatMember", .{ .chat_id = chat_id, .user_id = user_id, .only_if_banned = true });
    }

    pub fn unbanChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !void {
        return self.callMethod(allocator, "unbanChatMember", .{ .chat_id = chat_id, .user_id = user_id, .only_if_banned = true });
    }

    /// `until_date` is a Unix timestamp (0 = forever, until explicitly
    /// unmuted). All permissions are restricted, not just text messages.
    pub fn restrictChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64, until_date: i64) !void {
        return self.callMethod(allocator, "restrictChatMember", .{
            .chat_id = chat_id,
            .user_id = user_id,
            .until_date = until_date,
            .permissions = .{
                .can_send_messages = false,
                .can_send_audios = false,
                .can_send_documents = false,
                .can_send_photos = false,
                .can_send_videos = false,
                .can_send_video_notes = false,
                .can_send_voice_notes = false,
                .can_send_polls = false,
                .can_send_other_messages = false,
                .can_add_web_page_previews = false,
            },
        });
    }

    /// Best-effort restoration of ordinary member permissions.
    pub fn unrestrictChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !void {
        return self.callMethod(allocator, "restrictChatMember", .{
            .chat_id = chat_id,
            .user_id = user_id,
            .permissions = .{
                .can_send_messages = true,
                .can_send_audios = true,
                .can_send_documents = true,
                .can_send_photos = true,
                .can_send_videos = true,
                .can_send_video_notes = true,
                .can_send_voice_notes = true,
                .can_send_polls = true,
                .can_send_other_messages = true,
                .can_add_web_page_previews = true,
            },
        });
    }

    pub fn pinChatMessage(self: *Client, allocator: std.mem.Allocator, chat_id: i64, message_id: i64) !void {
        return self.callMethod(allocator, "pinChatMessage", .{ .chat_id = chat_id, .message_id = message_id });
    }

    /// `message_id` null unpins whatever's currently pinned.
    pub fn unpinChatMessage(self: *Client, allocator: std.mem.Allocator, chat_id: i64, message_id: ?i64) !void {
        if (message_id) |mid| {
            return self.callMethod(allocator, "unpinChatMessage", .{ .chat_id = chat_id, .message_id = mid });
        }
        return self.callMethod(allocator, "unpinChatMessage", .{ .chat_id = chat_id });
    }

    pub fn deleteMessage(self: *Client, allocator: std.mem.Allocator, chat_id: i64, message_id: i64) !void {
        return self.callMethod(allocator, "deleteMessage", .{ .chat_id = chat_id, .message_id = message_id });
    }

    /// True if `user_id` is currently the creator or an administrator of
    /// `chat_id` — the live source of truth for group-management gating
    /// (see `group_admin.zig`), queried fresh each time rather than cached
    /// since admin status can change at any moment.
    pub fn isChatAdmin(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !bool {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/getChatMember?chat_id={d}&user_id={d}",
            .{ self.bot_token, chat_id, user_id },
        );
        defer allocator.free(url);

        const body = try http_util.get(&self.http_client, allocator, url);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(
            types.ChatMemberResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        const member = parsed.value.result orelse {
            std.log.err("telegram getChatMember failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        };
        return std.mem.eql(u8, member.status, "administrator") or std.mem.eql(u8, member.status, "creator");
    }

    const MethodResponse = struct {
        ok: bool,
        description: ?[]const u8 = null,
    };

    /// Calls a Telegram Bot API method that returns a simple `{ok, result}`
    /// (result ignored) and turns `ok: false` into a real error, unlike
    /// `sendMessage` which is deliberately fire-and-forget — admin actions
    /// need their caller to know whether they actually happened (e.g. the
    /// bot not being an admin in the group) so it can report back to the
    /// owner instead of silently doing nothing.
    fn callMethod(self: *Client, allocator: std.mem.Allocator, method: []const u8, payload_value: anytype) !void {
        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/{s}", .{ self.bot_token, method });
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(payload_value, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const body = try http_util.postJson(&self.http_client, allocator, url, &.{}, payload);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(
            MethodResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        if (!parsed.value.ok) {
            std.log.err("telegram {s} failed: {?s}", .{ method, parsed.value.description });
            return error.TelegramApiError;
        }
    }
};
