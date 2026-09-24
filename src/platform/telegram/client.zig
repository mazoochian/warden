const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const types = @import("types.zig");
const http_util = @import("../../http_util.zig");
const markdown_html = @import("markdown_html.zig");
const llm = @import("../../llm/provider.zig");

/// Thin wrapper around the Telegram Bot API.
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

    /// Long-polls for new updates starting after `offset`.
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

        // `alloc_always` forces all strings to be duplicated into the Parsed value's
        // own arena instead of borrowing from `body`.
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
    pub fn sendMessage(self: *Client, allocator: std.mem.Allocator, chat_id: i64, text: []const u8, reply_to_message_id: ?i64) void {
        self.sendMessageErr(allocator, chat_id, text, reply_to_message_id) catch |err| {
            std.log.err("sendMessage failed: {t}", .{err});
        };
    }

    const ReplyParameters = struct {
        message_id: i64,
        allow_sending_without_reply: bool = true,
    };

    /// POSTs `sendMessage` once, either with `parse_mode=HTML` (converting `text`
    /// first via `markdown_html.toHtml`) or as plain text.
    fn postSendMessage(self: *Client, allocator: std.mem.Allocator, url: []const u8, chat_id: i64, text: []const u8, reply_parameters: ?ReplyParameters, html: bool) ![]u8 {
        // The plain branch is a fallback, not a "no formatting needed" path.
        const send_text = if (html)
            markdown_html.toHtml(allocator, text) catch text
        else
            llm.renderThinkingPlain(allocator, text) catch text;
        const parse_mode: ?[]const u8 = if (html) "HTML" else null;

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        // `emit_null_optional_fields = false`.
        try json.Stringify.value(
            .{ .chat_id = chat_id, .text = send_text, .reply_parameters = reply_parameters, .parse_mode = parse_mode },
            .{ .emit_null_optional_fields = false },
            &payload_writer.writer,
        );
        const payload = payload_writer.writer.buffered();
        return http_util.postJson(&self.http_client, allocator, url, &.{}, payload);
    }

    fn sendMessageErr(self: *Client, allocator: std.mem.Allocator, chat_id: i64, text: []const u8, reply_to_message_id: ?i64) !void {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/sendMessage",
            .{self.bot_token},
        );
        defer allocator.free(url);

        const reply_parameters: ?ReplyParameters = if (reply_to_message_id) |id| .{ .message_id = id } else null;

        // Try HTML-formatted first; only retry as plain text when Telegram itself
        // rejected the request.
        if (self.postSendMessage(allocator, url, chat_id, text, reply_parameters, true)) |body| {
            allocator.free(body);
            return;
        } else |err| {
            if (err != error.HttpRequestFailed) return err;
            std.log.warn("sendMessage: HTML send rejected for chat {d}, retrying as plain text", .{chat_id});
        }
        const body = try self.postSendMessage(allocator, url, chat_id, text, reply_parameters, false);
        allocator.free(body);
    }

    const SendMessageResponse = struct {
        ok: bool,
        result: ?struct { message_id: i64 } = null,
        description: ?[]const u8 = null,
    };

    fn parseSendMessageResponse(allocator: std.mem.Allocator, body: []const u8) !i64 {
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

        // Same HTML-then-plain-text fallback as `sendMessageErr` — only retry as
        // plain on an actual Telegram rejection, not a transient network failure.
        if (self.postSendMessage(allocator, url, chat_id, text, reply_parameters, true)) |body| {
            defer allocator.free(body);
            if (parseSendMessageResponse(allocator, body)) |id| return id else |_| {
                std.log.warn("sendMessageReturningId: HTML send rejected for chat {d}, retrying as plain text", .{chat_id});
            }
        } else |err| {
            if (err != error.HttpRequestFailed) return err;
            std.log.warn("sendMessageReturningId: HTML send rejected for chat {d}, retrying as plain text", .{chat_id});
        }

        const body = try self.postSendMessage(allocator, url, chat_id, text, reply_parameters, false);
        defer allocator.free(body);
        return parseSendMessageResponse(allocator, body);
    }

    /// One button on an inline keyboard, in this client's own local shape rather
    /// than `iface.Choice`.
    pub const Button = struct {
        text: []const u8,
        callback_data: []const u8,
    };

    const InlineKeyboardButton = struct {
        text: []const u8,
        callback_data: ?[]const u8 = null,
    };
    const InlineKeyboardMarkup = struct {
        inline_keyboard: []const []const InlineKeyboardButton,
    };

    /// Arranges `buttons` 2 per row (a single long row renders badly once there
    /// are more than a handful of choices) as the nested-slice shape
    /// `InlineKeyboardMarkup` needs.
    fn buildInlineKeyboardRows(allocator: std.mem.Allocator, buttons: []const Button) ![]const []const InlineKeyboardButton {
        const buttons_per_row = 2;
        var rows: std.ArrayList([]const InlineKeyboardButton) = .empty;
        errdefer {
            for (rows.items) |row| allocator.free(row);
            rows.deinit(allocator);
        }
        var i: usize = 0;
        while (i < buttons.len) : (i += buttons_per_row) {
            var row: std.ArrayList(InlineKeyboardButton) = .empty;
            defer row.deinit(allocator);
            const end = @min(i + buttons_per_row, buttons.len);
            for (buttons[i..end]) |b| try row.append(allocator, .{ .text = b.text, .callback_data = b.callback_data });
            try rows.append(allocator, try row.toOwnedSlice(allocator));
        }
        return rows.toOwnedSlice(allocator);
    }

    /// Sends a message with an inline keyboard built from `buttons`.
    pub fn sendChoicePrompt(self: *Client, allocator: std.mem.Allocator, chat_id: i64, text: []const u8, buttons: []const Button, reply_to_message_id: ?i64) !i64 {
        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{self.bot_token});
        defer allocator.free(url);

        const reply_parameters: ?ReplyParameters = if (reply_to_message_id) |id| .{ .message_id = id } else null;

        const rows = try buildInlineKeyboardRows(allocator, buttons);
        defer {
            for (rows) |row| allocator.free(row);
            allocator.free(rows);
        }

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(
            .{ .chat_id = chat_id, .text = text, .reply_parameters = reply_parameters, .reply_markup = InlineKeyboardMarkup{ .inline_keyboard = rows } },
            .{ .emit_null_optional_fields = false },
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
            std.log.err("telegram sendChoicePrompt failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        };
        return result.message_id;
    }

    /// Replaces a message's text AND inline keyboard together in one call
    /// (Telegram's `editMessageText` accepts `reply_markup` directly).
    pub fn editMessageTextWithKeyboard(self: *Client, allocator: std.mem.Allocator, chat_id: i64, message_id: i64, text: []const u8, buttons: []const Button) !void {
        const rows = try buildInlineKeyboardRows(allocator, buttons);
        defer {
            for (rows) |row| allocator.free(row);
            allocator.free(rows);
        }
        return self.callMethod(allocator, "editMessageText", .{
            .chat_id = chat_id,
            .message_id = message_id,
            .text = text,
            .reply_markup = InlineKeyboardMarkup{ .inline_keyboard = rows },
        });
    }

    /// Dismisses the client-side loading spinner Telegram shows on a pressed
    /// button until this is called.
    pub fn answerCallbackQuery(self: *Client, allocator: std.mem.Allocator, callback_query_id: []const u8) void {
        self.callMethod(allocator, "answerCallbackQuery", .{ .callback_query_id = callback_query_id }) catch |err| {
            std.log.err("answerCallbackQuery failed: {t}", .{err});
        };
    }

    /// Replaces the text of a previously-sent message (the "thinking" placeholder
    /// / progressive-answer editing flow — see main.zig's `replyWithAnswer`).
    pub fn editMessage(self: *Client, allocator: std.mem.Allocator, chat_id: i64, message_id: i64, text: []const u8) !void {
        const html_text = markdown_html.toHtml(allocator, text) catch text;
        const parse_mode: ?[]const u8 = "HTML";
        if (self.callMethod(allocator, "editMessageText", .{ .chat_id = chat_id, .message_id = message_id, .text = html_text, .parse_mode = parse_mode })) |_| {
            return;
        } else |err| {
            // Only an actual Telegram rejection is worth retrying as plain text.
            if (err != error.HttpRequestFailed) return err;
            std.log.warn("editMessage: HTML edit rejected for chat {d} message {d}, retrying as plain text", .{ chat_id, message_id });
        }
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

        const resp_body = try http_util.postRaw(&self.http_client, allocator, url, content_type, &.{}, body);
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

    /// Sends a native Telegram poll.
    pub fn sendPoll(self: *Client, allocator: std.mem.Allocator, chat_id: i64, question: []const u8, options: []const []const u8, reply_to_message_id: ?i64) void {
        self.sendPollErr(allocator, chat_id, question, options, reply_to_message_id) catch |err| {
            std.log.err("sendPoll failed: {t}", .{err});
        };
    }

    fn sendPollErr(self: *Client, allocator: std.mem.Allocator, chat_id: i64, question: []const u8, options: []const []const u8, reply_to_message_id: ?i64) !void {
        const PollOption = struct { text: []const u8 };
        const opts = try allocator.alloc(PollOption, options.len);
        defer allocator.free(opts);
        for (options, 0..) |o, i| opts[i] = .{ .text = o };

        const reply_parameters: ?ReplyParameters = if (reply_to_message_id) |id| .{ .message_id = id } else null;

        return self.callMethod(allocator, "sendPoll", .{
            .chat_id = chat_id,
            .question = question,
            .options = opts,
            .reply_parameters = reply_parameters,
        });
    }

    /// Sends an arbitrary file as a document (e.g. a converted file from
    /// `convert_file`, or the text-too-long fallback).
    pub fn sendDocument(self: *Client, allocator: std.mem.Allocator, chat_id: i64, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        self.sendDocumentErr(allocator, chat_id, file_bytes, file_name, caption) catch |err| {
            std.log.err("sendDocument failed: {t}", .{err});
        };
    }

    fn sendDocumentErr(self: *Client, allocator: std.mem.Allocator, chat_id: i64, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) !void {
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
        try w.print("Content-Disposition: form-data; name=\"document\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{file_name});
        try w.writeAll(file_bytes);
        try w.writeAll("\r\n");
        try w.print("--{s}--\r\n", .{boundary});
        const body = w.buffered();

        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendDocument", .{self.bot_token});
        defer allocator.free(url);

        const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer allocator.free(content_type);

        const resp_body = try http_util.postRaw(&self.http_client, allocator, url, content_type, &.{}, body);
        defer allocator.free(resp_body);

        var parsed = try json.parseFromSlice(
            MethodResponse,
            allocator,
            resp_body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        if (!parsed.value.ok) {
            std.log.err("telegram sendDocument failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        }
    }

    /// Sends a native, inline-playable video message (`video_download.zig`'s
    /// lossy delivery path).
    pub fn sendVideo(self: *Client, allocator: std.mem.Allocator, chat_id: i64, video_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        self.sendVideoErr(allocator, chat_id, video_bytes, file_name, caption) catch |err| {
            std.log.err("sendVideo failed: {t}", .{err});
        };
    }

    fn sendVideoErr(self: *Client, allocator: std.mem.Allocator, chat_id: i64, video_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) !void {
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
        try w.print("Content-Disposition: form-data; name=\"video\"; filename=\"{s}\"\r\nContent-Type: video/mp4\r\n\r\n", .{file_name});
        try w.writeAll(video_bytes);
        try w.writeAll("\r\n");
        try w.print("--{s}--\r\n", .{boundary});
        const body = w.buffered();

        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendVideo", .{self.bot_token});
        defer allocator.free(url);

        const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer allocator.free(content_type);

        const resp_body = try http_util.postRaw(&self.http_client, allocator, url, content_type, &.{}, body);
        defer allocator.free(resp_body);

        var parsed = try json.parseFromSlice(
            MethodResponse,
            allocator,
            resp_body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        if (!parsed.value.ok) {
            std.log.err("telegram sendVideo failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        }
    }

    /// Resolves a `file_id` (from an inbound photo/document/voice/audio/ video)
    /// to downloadable bytes — Telegram's two-step process.
    pub fn downloadFile(self: *Client, allocator: std.mem.Allocator, file_id: []const u8) ![]u8 {
        const encoded_id = try http_util.encodeQueryComponent(allocator, file_id);
        defer allocator.free(encoded_id);

        const get_file_url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/getFile?file_id={s}",
            .{ self.bot_token, encoded_id },
        );
        defer allocator.free(get_file_url);

        const body = try http_util.get(&self.http_client, allocator, get_file_url);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(
            types.FileResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        const result = parsed.value.result orelse {
            std.log.err("telegram getFile failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        };
        const file_path = result.file_path orelse return error.TelegramApiError;

        const download_url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/file/bot{s}/{s}",
            .{ self.bot_token, file_path },
        );
        defer allocator.free(download_url);

        return http_util.get(&self.http_client, allocator, download_url);
    }

    pub fn banChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !void {
        return self.callMethod(allocator, "banChatMember", .{ .chat_id = chat_id, .user_id = user_id });
    }

    /// Ban immediately followed by unban.
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

    /// The subset of Telegram's `ChatPermissions` object the granular
    /// `/permission` model actually has bits for.
    pub const ChatPermissionOverrides = struct {
        can_send_messages: bool,
        can_send_audios: bool,
        can_send_documents: bool,
        can_send_photos: bool,
        can_send_videos: bool,
        can_send_video_notes: bool,
        can_send_voice_notes: bool,
        can_send_polls: bool,
        can_send_other_messages: bool,
        can_add_web_page_previews: bool,
        can_change_info: bool,
    };

    /// `until_date` is a Unix timestamp (0 = forever) — same convention as
    /// `restrictChatMember`.
    pub fn restrictChatMemberWithPermissions(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64, until_date: i64, permissions: ChatPermissionOverrides) !void {
        return self.callMethod(allocator, "restrictChatMember", .{
            .chat_id = chat_id,
            .user_id = user_id,
            .until_date = until_date,
            .permissions = permissions,
        });
    }

    /// Sets `user_id`'s custom admin title in `chat_id` (`/tag`).
    pub fn setChatAdministratorCustomTitle(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64, custom_title: []const u8) !void {
        return self.callMethod(allocator, "setChatAdministratorCustomTitle", .{
            .chat_id = chat_id,
            .user_id = user_id,
            .custom_title = custom_title,
        });
    }

    /// `/title` — Bot API `setChatTitle`, 1-128
    /// characters.
    pub fn setChatTitle(self: *Client, allocator: std.mem.Allocator, chat_id: i64, title: []const u8) !void {
        return self.callMethod(allocator, "setChatTitle", .{ .chat_id = chat_id, .title = title });
    }

    /// `/description` — Bot API `setChatDescription`.
    pub fn setChatDescription(self: *Client, allocator: std.mem.Allocator, chat_id: i64, description: []const u8) !void {
        return self.callMethod(allocator, "setChatDescription", .{ .chat_id = chat_id, .description = description });
    }

    /// `/photo remove` — Bot API `deleteChatPhoto`.
    pub fn deleteChatPhoto(self: *Client, allocator: std.mem.Allocator, chat_id: i64) !void {
        return self.callMethod(allocator, "deleteChatPhoto", .{ .chat_id = chat_id });
    }

    /// `/photo` — same multipart shape as `sendPhotoErr`.
    pub fn setChatPhoto(self: *Client, allocator: std.mem.Allocator, chat_id: i64, photo_bytes: []const u8) !void {
        const boundary = "----WardenBoundary7f3a9c2e";

        var body_writer: Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();
        const w = &body_writer.writer;

        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n{d}\r\n", .{chat_id});
        try w.print("--{s}\r\n", .{boundary});
        try w.writeAll("Content-Disposition: form-data; name=\"photo\"; filename=\"image.png\"\r\nContent-Type: image/png\r\n\r\n");
        try w.writeAll(photo_bytes);
        try w.writeAll("\r\n");
        try w.print("--{s}--\r\n", .{boundary});
        const body = w.buffered();

        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/setChatPhoto", .{self.bot_token});
        defer allocator.free(url);
        const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer allocator.free(content_type);

        const resp_body = try http_util.postRaw(&self.http_client, allocator, url, content_type, &.{}, body);
        defer allocator.free(resp_body);

        var parsed = try json.parseFromSlice(
            MethodResponse,
            allocator,
            resp_body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();

        if (!parsed.value.ok) {
            std.log.err("telegram setChatPhoto failed: {?s}", .{parsed.value.description});
            return error.TelegramApiError;
        }
    }

    /// A moderate permission set.
    pub fn promoteChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !void {
        return self.callMethod(allocator, "promoteChatMember", .{
            .chat_id = chat_id,
            .user_id = user_id,
            .can_manage_chat = true,
            .can_delete_messages = true,
            .can_restrict_members = true,
            .can_pin_messages = true,
            .can_invite_users = true,
            .can_change_info = false,
            .can_promote_members = false,
            .can_manage_video_chats = false,
            .can_post_messages = false,
            .can_edit_messages = false,
            .is_anonymous = false,
        });
    }

    /// `promoteChatMember` with every permission false is Telegram's own
    /// idiom for demoting an admin back to an ordinary member.
    pub fn demoteChatMember(self: *Client, allocator: std.mem.Allocator, chat_id: i64, user_id: i64) !void {
        return self.callMethod(allocator, "promoteChatMember", .{
            .chat_id = chat_id,
            .user_id = user_id,
            .can_manage_chat = false,
            .can_delete_messages = false,
            .can_restrict_members = false,
            .can_pin_messages = false,
            .can_invite_users = false,
            .can_change_info = false,
            .can_promote_members = false,
            .can_manage_video_chats = false,
            .can_post_messages = false,
            .can_edit_messages = false,
            .is_anonymous = false,
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
    /// `chat_id` — the live source of truth for group-management gating.
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

    /// One entry in the bot's command menu, in this client's own local shape —
    /// same "no dependency on the adapter layer" reasoning as `Button`.
    pub const BotCommand = struct {
        command: []const u8,
        description: []const u8,
    };

    /// Publishes the bot-wide command menu Telegram clients show in the "/"
    /// autocomplete / attachment-icon menu.
    pub fn setMyCommands(self: *Client, allocator: std.mem.Allocator, commands: []const BotCommand) !void {
        return self.callMethod(allocator, "setMyCommands", .{ .commands = commands });
    }

    /// Every owner/administrator of `chat_id`, full `User` objects included.
    pub fn getChatAdministrators(self: *Client, allocator: std.mem.Allocator, chat_id: i64) !json.Parsed(types.ChatAdministratorsResponse) {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/getChatAdministrators?chat_id={d}",
            .{ self.bot_token, chat_id },
        );
        defer allocator.free(url);

        const body = try http_util.get(&self.http_client, allocator, url);
        defer allocator.free(body);

        return json.parseFromSlice(
            types.ChatAdministratorsResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Whether the bot itself is still a member of a chat, from a
    /// `checkMembership` call.
    pub const Membership = enum { member, gone, unknown };

    /// Checks whether the bot (`self_id`) is still a member of `chat_id`, via
    /// `getChatMember`.
    pub fn checkMembership(self: *Client, allocator: std.mem.Allocator, chat_id: i64, self_id: i64) !Membership {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/getChatMember?chat_id={d}&user_id={d}",
            .{ self.bot_token, chat_id, self_id },
        );
        defer allocator.free(url);

        const resp = http_util.getAllowingAnyStatus(&self.http_client, allocator, url) catch |err| {
            std.log.warn("checkMembership: request failed for chat {d}: {t}", .{ chat_id, err });
            return .unknown;
        };
        defer allocator.free(resp.body);

        switch (resp.status.class()) {
            .success => {},
            .client_error => return .gone,
            else => {
                std.log.warn("checkMembership: unexpected status {d} for chat {d}", .{ @intFromEnum(resp.status), chat_id });
                return .unknown;
            },
        }

        var parsed = json.parseFromSlice(
            types.ChatMemberResponse,
            allocator,
            resp.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |err| {
            std.log.warn("checkMembership: failed to parse response for chat {d}: {t}", .{ chat_id, err });
            return .unknown;
        };
        defer parsed.deinit();

        if (!parsed.value.ok) return .unknown;
        const status = (parsed.value.result orelse return .unknown).status;
        if (std.mem.eql(u8, status, "left") or std.mem.eql(u8, status, "kicked")) return .gone;
        return .member;
    }

    const MethodResponse = struct {
        ok: bool,
        description: ?[]const u8 = null,
    };

    /// Calls a Telegram Bot API method that returns a simple `{ok, result}`
    /// (result ignored) and turns.
    fn callMethod(self: *Client, allocator: std.mem.Allocator, method: []const u8, payload_value: anytype) !void {
        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/{s}", .{ self.bot_token, method });
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        // `emit_null_optional_fields = false` defensively.
        try json.Stringify.value(payload_value, .{ .emit_null_optional_fields = false }, &payload_writer.writer);
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

const testing = std.testing;

test "reply_parameters is omitted entirely when null, not serialized as a literal null Telegram rejects" {
    const reply_parameters: ?Client.ReplyParameters = null;
    var writer: Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try json.Stringify.value(
        .{ .chat_id = @as(i64, 1), .text = "hi", .reply_parameters = reply_parameters },
        .{ .emit_null_optional_fields = false },
        &writer.writer,
    );
    const out = writer.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "reply_parameters") == null);
}

test "reply_parameters serializes as a real object when a reply target is set" {
    const reply_parameters: ?Client.ReplyParameters = .{ .message_id = 42 };
    var writer: Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try json.Stringify.value(
        .{ .chat_id = @as(i64, 1), .text = "hi", .reply_parameters = reply_parameters },
        .{ .emit_null_optional_fields = false },
        &writer.writer,
    );
    const out = writer.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"reply_parameters\":{\"message_id\":42") != null);
}
