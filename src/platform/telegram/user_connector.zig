const std = @import("std");
const Io = std.Io;
const json = std.json;

const iface = @import("../interface.zig");
const Identity = @import("../../domain/identity.zig").Identity;
const log = @import("../../log.zig").scoped("telegram_user");

const td = @cImport({
    @cInclude("td/telegram/td_json_client.h");
});

/// How long a single `td_receive` call blocks waiting for the next update.
const receive_timeout_seconds: f64 = 3.0;

/// Upper bound on how many updates one `pollFn` call drains before returning.
const drain_limit: usize = 50;

/// Upper bound `waitForResponse` blocks a calling thread for a single TDLib
/// request/response round trip (`getChat`/`getChatHistory`/ `viewMessages`).
const request_timeout_seconds: f64 = 15.0;

/// TDLib's own authorization-state machine.
pub const AuthState = enum {
    none,
    wait_tdlib_parameters,
    wait_phone_number,
    wait_code,
    wait_password,
    ready,
    logging_out,
    closed,
    /// Anything TDLib sent that isn't one of the above.
    unsupported,
};

/// TDLib-backed (MTProto, via TDLib's `tdjson` C interface) implementation of
/// `platform.Connector` for the *owner's own* Telegram account.
pub const ChatInfo = struct {
    chat_id: []const u8,
    title: []const u8,

    fn dupe(self: ChatInfo, allocator: std.mem.Allocator) !ChatInfo {
        return .{
            .chat_id = try allocator.dupe(u8, self.chat_id),
            .title = try allocator.dupe(u8, self.title),
        };
    }
};

pub const TelegramUserConnector = struct {
    allocator: std.mem.Allocator,
    io: Io,
    api_id: i32,
    api_hash: []const u8,
    session_dir: []const u8,
    client_id: ?c_int = null,
    auth_state: AuthState = .none,
    /// Raw `@type` string of an `.unsupported` auth state, for logging.
    unsupported_auth_type: ?[]const u8 = null,
    self_user_id: ?[]const u8 = null,
    self_username: ?[]const u8 = null,
    /// Chat id -> title, built up from `updateNewChat`/`updateChatTitle` updates
    /// as `pollFn` sees them (TDLib sends a burst of `updateNewChat` for every
    /// chat it knows about shortly after login, unprompted — no explicit
    /// `getChats` request needed to populate this).
    known_chats: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Same primitive/lock idiom `features/group_admin.zig`'s
    /// `PendingConfirmations` and `worker_pool.zig` already use — an `Io`-aware
    /// mutex.
    known_chats_mu: Io.Mutex = .init,
    /// Every outbound request `send()` makes is fire-and-forget.
    pending_responses: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    pending_responses_mu: Io.Mutex = .init,
    next_extra_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn init(allocator: std.mem.Allocator, io: Io, api_id: i32, api_hash: []const u8, session_dir: []const u8) TelegramUserConnector {
        return .{
            .allocator = allocator,
            .io = io,
            .api_id = api_id,
            .api_hash = api_hash,
            .session_dir = session_dir,
        };
    }

    /// Duped copies of every currently-known (chat id, title) pair, in no
    /// particular order — caller owns the returned slice and every string in it.
    pub fn knownChats(self: *TelegramUserConnector, allocator: std.mem.Allocator) ![]ChatInfo {
        self.known_chats_mu.lockUncancelable(self.io);
        defer self.known_chats_mu.unlock(self.io);

        var out = try std.ArrayList(ChatInfo).initCapacity(allocator, self.known_chats.count());
        errdefer out.deinit(allocator);
        var it = self.known_chats.iterator();
        while (it.next()) |entry| {
            const info = try (ChatInfo{ .chat_id = entry.key_ptr.*, .title = entry.value_ptr.* }).dupe(allocator);
            out.appendAssumeCapacity(info);
        }
        return out.toOwnedSlice(allocator);
    }

    /// This chat's title from the `updateNewChat`/`updateChatTitle` cache, duped
    /// onto `allocator`, or `null` if TDLib hasn't told us about the chat yet.
    fn knownChatTitle(self: *TelegramUserConnector, allocator: std.mem.Allocator, chat_id: []const u8) ?[]const u8 {
        self.known_chats_mu.lockUncancelable(self.io);
        defer self.known_chats_mu.unlock(self.io);

        const title = self.known_chats.get(chat_id) orelse return null;
        return allocator.dupe(u8, title) catch null;
    }

    fn setKnownChatTitle(self: *TelegramUserConnector, chat_id: []const u8, title: []const u8) void {
        self.known_chats_mu.lockUncancelable(self.io);
        defer self.known_chats_mu.unlock(self.io);

        if (self.known_chats.getEntry(chat_id)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = self.allocator.dupe(u8, title) catch return;
            return;
        }
        const owned_id = self.allocator.dupe(u8, chat_id) catch return;
        const owned_title = self.allocator.dupe(u8, title) catch {
            self.allocator.free(owned_id);
            return;
        };
        self.known_chats.put(self.allocator, owned_id, owned_title) catch {
            self.allocator.free(owned_id);
            self.allocator.free(owned_title);
        };
    }

    pub fn connector(self: *TelegramUserConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .selfId = selfIdFn,
        .selfUsername = selfUsernameFn,
        // No moderation/media vtable slots yet.
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram_user;
    }

    fn selfIdFn(ptr: *anyopaque) ?[]const u8 {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        return self.self_user_id;
    }

    fn selfUsernameFn(ptr: *anyopaque) ?[]const u8 {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        return self.self_username;
    }

    pub fn authState(self: *const TelegramUserConnector) AuthState {
        return self.auth_state;
    }

    fn ensureClient(self: *TelegramUserConnector) void {
        if (self.client_id != null) return;
        self.client_id = td.td_create_client_id();
        self.send(.{ .@"@type" = "getAuthorizationState" });
    }

    /// Sends a request built from an anonymous struct literal, JSON-encoded via
    /// `json.Stringify`.
    fn send(self: *TelegramUserConnector, request: anytype) void {
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        json.Stringify.value(request, .{}, &out.writer) catch |err| {
            log.err("send: failed to encode request: {t}", .{err});
            return;
        };
        const body = out.writer.buffered();
        const body_z = self.allocator.dupeZ(u8, body) catch return;
        defer self.allocator.free(body_z);
        td.td_send(self.client_id.?, body_z.ptr);
    }

    fn nextExtraId(self: *TelegramUserConnector) u64 {
        return self.next_extra_id.fetchAdd(1, .monotonic);
    }

    fn storePendingResponse(self: *TelegramUserConnector, io: Io, extra_id: u64, raw: []const u8) void {
        const owned = self.allocator.dupe(u8, raw) catch return;
        self.pending_responses_mu.lockUncancelable(io);
        defer self.pending_responses_mu.unlock(io);
        self.pending_responses.put(self.allocator, extra_id, owned) catch self.allocator.free(owned);
    }

    /// Blocks the calling thread.
    fn waitForResponse(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, extra_id: u64, timeout_seconds: f64) !?[]const u8 {
        const poll_interval_ms = 50;
        const timeout_ms: usize = @intFromFloat(timeout_seconds * 1000.0);
        var waited_ms: usize = 0;
        while (waited_ms < timeout_ms) : (waited_ms += poll_interval_ms) {
            self.pending_responses_mu.lockUncancelable(io);
            const found = self.pending_responses.fetchRemove(extra_id);
            self.pending_responses_mu.unlock(io);
            if (found) |entry| {
                defer self.allocator.free(entry.value);
                return try allocator.dupe(u8, entry.value);
            }
            Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake) catch break;
        }
        return null;
    }

    /// One chat's freshly-fetched unread state.
    pub const ChatMeta = struct {
        title: []const u8,
        unread_count: i64,
        /// The chat's newest message id, if TDLib reports one (`getChat`'s
        /// `last_message` field — absent for a brand new chat with no messages yet).
        last_message_id: ?i64,
    };

    /// `getChat` — resolves `chat_id` to its current title + unread count.
    pub fn requestChatMeta(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64) !?ChatMeta {
        const extra_id = self.nextExtraId();
        self.send(.{ .@"@type" = "getChat", .chat_id = chat_id, .@"@extra" = extra_id });
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("requestChatMeta: getChat timed out for chat {d}", .{chat_id});
            return null;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("requestChatMeta: failed to parse getChat response: {t}", .{err});
            return null;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return null,
        };
        if (obj.get("@type")) |v| if (v == .string and std.mem.eql(u8, v.string, "error")) {
            log.warn("requestChatMeta: getChat error for chat {d}: {s}", .{ chat_id, raw });
            return null;
        };
        const title = switch (obj.get("title") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        const unread_count = switch (obj.get("unread_count") orelse return null) {
            .integer => |n| n,
            else => return null,
        };
        const last_message_id: ?i64 = if (obj.get("last_message")) |lm_v| switch (lm_v) {
            .object => |lm| switch (lm.get("id") orelse json.Value{ .null = {} }) {
                .integer => |n| n,
                else => null,
            },
            else => null,
        } else null;
        return .{
            .title = try allocator.dupe(u8, title),
            .unread_count = unread_count,
            .last_message_id = last_message_id,
        };
    }

    /// Same `viewMessages` request as `markMessagesRead`, for exactly one
    /// message, but never waits for (or even tags) a response.
    fn markSeenFireAndForget(self: *TelegramUserConnector, chat_id: i64, message_id: i64) void {
        self.send(.{
            .@"@type" = "viewMessages",
            .chat_id = chat_id,
            .message_ids = &[_]i64{message_id},
            .force_read = true,
        });
    }

    /// `viewMessages(chat_id, message_ids, force_read=true)` — marks exactly the
    /// given messages viewed.
    pub fn markMessagesRead(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64, message_ids: []const i64) !bool {
        if (message_ids.len == 0) return true;
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "viewMessages",
            .chat_id = chat_id,
            .message_ids = message_ids,
            .force_read = true,
            .@"@extra" = extra_id,
        });
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("markMessagesRead: viewMessages timed out for chat {d}", .{chat_id});
            return false;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("markMessagesRead: failed to parse viewMessages response: {t}", .{err});
            return false;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        const type_str = switch (obj.get("@type") orelse return false) {
            .string => |s| s,
            else => return false,
        };
        if (!std.mem.eql(u8, type_str, "ok")) {
            log.warn("markMessagesRead: viewMessages error for chat {d}: {s}", .{ chat_id, raw });
            return false;
        }
        return true;
    }

    /// One post pulled from a channel's history by `fetchRecentPosts`.
    pub const Post = struct {
        id: i64,
        date: i64,
        /// `messageText` body, or a media message's caption.
        text: []const u8,
    };

    /// The most recent `limit` posts in `chat_id`, newest first.
    pub fn fetchRecentPosts(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64, limit: u32) ![]Post {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "getChatHistory",
            .chat_id = chat_id,
            .from_message_id = 0,
            .offset = 0,
            .limit = limit,
            .only_local = false,
            .@"@extra" = extra_id,
        });
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("fetchRecentPosts: getChatHistory timed out for chat {d}", .{chat_id});
            return &.{};
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("fetchRecentPosts: failed to parse getChatHistory response: {t}", .{err});
            return &.{};
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return &.{},
        };
        if (obj.get("@type")) |v| if (v == .string and std.mem.eql(u8, v.string, "error")) {
            log.warn("fetchRecentPosts: getChatHistory error for chat {d}: {s}", .{ chat_id, raw });
            return &.{};
        };
        const messages = switch (obj.get("messages") orelse return &.{}) {
            .array => |arr| arr,
            else => return &.{},
        };

        var out: std.ArrayList(Post) = .empty;
        errdefer out.deinit(allocator);
        for (messages.items) |item| {
            const m = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const id = switch (m.get("id") orelse continue) {
                .integer => |n| n,
                else => continue,
            };
            const date = switch (m.get("date") orelse json.Value{ .null = {} }) {
                .integer => |n| n,
                else => 0,
            };
            const text = postText(m) orelse continue;
            try out.append(allocator, .{
                .id = id,
                .date = date,
                .text = try allocator.dupe(u8, text),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// A post's readable body: `messageText`'s text.
    fn postText(message: json.ObjectMap) ?[]const u8 {
        const content = switch (message.get("content") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const formatted = switch (content.get("text") orelse content.get("caption") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const text = switch (formatted.get("text") orelse return null) {
            .string => |str| str,
            else => return null,
        };
        return if (text.len > 0) text else null;
    }

    /// Reads whatever is currently sitting in `chat_id`'s Telegram composer.
    pub fn fetchComposerDraft(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64) !?[]const u8 {
        const extra_id = self.nextExtraId();
        self.send(.{ .@"@type" = "getChat", .chat_id = chat_id, .@"@extra" = extra_id });
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("fetchComposerDraft: getChat timed out for chat {d}", .{chat_id});
            return null;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("fetchComposerDraft: failed to parse getChat response: {t}", .{err});
            return null;
        };
        defer parsed.deinit();

        // GetChat -> chat.draft_message.input_message_text.text.text, with every
        // level optional.
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const draft = switch (obj.get("draft_message") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const input = switch (draft.get("input_message_text") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        if (input.get("@type")) |v| if (!(v == .string and std.mem.eql(u8, v.string, "inputMessageText"))) return null;
        const formatted = switch (input.get("text") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const text = switch (formatted.get("text") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (text.len == 0) return null;
        return try allocator.dupe(u8, text);
    }

    /// Writes `text` into `chat_id`'s Telegram composer as a draft.
    pub fn setChatDraft(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64, text: []const u8, date: i64) bool {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "setChatDraftMessage",
            .chat_id = chat_id,
            .draft_message = .{
                .@"@type" = "draftMessage",
                .date = @as(i32, @truncate(date)),
                .input_message_text = .{
                    .@"@type" = "inputMessageText",
                    .text = .{ .@"@type" = "formattedText", .text = text },
                },
            },
            .@"@extra" = extra_id,
        });
        return self.awaitOk(allocator, io, extra_id, "setChatDraftMessage", chat_id);
    }

    /// Empties `chat_id`'s Telegram composer (`draft_message: null`) — used once
    /// an AI draft has been approved and sent, or discarded.
    pub fn clearChatDraft(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64) bool {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "setChatDraftMessage",
            .chat_id = chat_id,
            .draft_message = @as(?u8, null),
            .@"@extra" = extra_id,
        });
        return self.awaitOk(allocator, io, extra_id, "setChatDraftMessage(clear)", chat_id);
    }

    /// Shared tail of the two composer-draft writes: waits for `extra_id`'s
    /// response and reports whether it was a plain `ok`, logging anything else.
    fn awaitOk(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, extra_id: u64, what: []const u8, chat_id: i64) bool {
        const raw = (self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) catch |err| {
            log.warn("{s}: waiting for a response failed for chat {d}: {t}", .{ what, chat_id, err });
            return false;
        }) orelse {
            log.warn("{s}: timed out for chat {d}", .{ what, chat_id });
            return false;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("{s}: failed to parse response for chat {d}: {t}", .{ what, chat_id, err });
            return false;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        const type_str = switch (obj.get("@type") orelse return false) {
            .string => |s| s,
            else => return false,
        };
        if (!std.mem.eql(u8, type_str, "ok")) {
            log.warn("{s}: error for chat {d}: {s}", .{ what, chat_id, raw });
            return false;
        }
        return true;
    }

    /// Answers `authorizationStateWaitPhoneNumber`.
    pub const AuthStepOutcome = union(enum) {
        /// TDLib accepted the step; the real confirmation is whatever
        /// `updateAuthorizationState` fires next.
        ok,
        /// TDLib rejected the step outright — the human-readable reason it gave (e.g.
        /// "PASSWORD_HASH_INVALID"), duped onto the caller's allocator.
        rejected: []const u8,
        /// No response arrived within `request_timeout_seconds` (already logged).
        timed_out,
    };

    /// Shared response wait+classify for the three auth-step submissions below.
    fn awaitAuthStep(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, extra_id: u64, what: []const u8) !AuthStepOutcome {
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("{s}: timed out waiting for a response", .{what});
            return .timed_out;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("{s}: failed to parse response: {t}", .{ what, err });
            return .timed_out;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .timed_out,
        };
        const type_str = switch (obj.get("@type") orelse return .timed_out) {
            .string => |s| s,
            else => return .timed_out,
        };
        if (!std.mem.eql(u8, type_str, "error")) return .ok;

        const message = switch (obj.get("message") orelse json.Value{ .null = {} }) {
            .string => |s| s,
            else => "unknown error",
        };
        log.warn("{s}: rejected: {s}", .{ what, message });
        return .{ .rejected = try allocator.dupe(u8, message) };
    }

    /// Answers `authorizationStateWaitPhoneNumber`.
    pub fn submitPhoneNumber(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, phone_number: []const u8) !AuthStepOutcome {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "setAuthenticationPhoneNumber",
            .phone_number = phone_number,
            .@"@extra" = extra_id,
        });
        return self.awaitAuthStep(allocator, io, extra_id, "submitPhoneNumber");
    }

    /// Answers `authorizationStateWaitCode`.
    pub fn submitAuthCode(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, code: []const u8) !AuthStepOutcome {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "checkAuthenticationCode",
            .code = code,
            .@"@extra" = extra_id,
        });
        return self.awaitAuthStep(allocator, io, extra_id, "submitAuthCode");
    }

    /// Answers `authorizationStateWaitPassword` (2FA).
    pub fn submitPassword(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, password: []const u8) !AuthStepOutcome {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "checkAuthenticationPassword",
            .password = password,
            .@"@extra" = extra_id,
        });
        return self.awaitAuthStep(allocator, io, extra_id, "submitPassword");
    }

    /// TDLib's `logOut` — clears the account's session both locally
    /// (`session_dir` on disk) and server-side.
    pub fn logOut(self: *TelegramUserConnector) void {
        self.send(.{ .@"@type" = "logOut" });
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        _ = allocator;
        const chat_id_int = std.fmt.parseInt(i64, chat_id, 10) catch {
            log.err("sendMessageFn: chat_id '{s}' isn't a valid integer", .{chat_id});
            return;
        };
        const reply_id_int: i64 = if (reply_to_message_id) |r| std.fmt.parseInt(i64, r, 10) catch 0 else 0;
        self.send(.{
            .@"@type" = "sendMessage",
            .chat_id = chat_id_int,
            .reply_to = if (reply_id_int != 0) .{ .@"@type" = "inputMessageReplyToMessage", .message_id = reply_id_int } else null,
            .input_message_content = .{
                .@"@type" = "inputMessageText",
                .text = .{ .@"@type" = "formattedText", .text = text },
            },
        });
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        self.ensureClient();

        var out: std.ArrayList(iface.Message) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < drain_limit) : (i += 1) {
            const timeout = if (i == 0) receive_timeout_seconds else 0.0;
            const raw_result = td.td_receive(timeout);
            if (raw_result == null) break;
            const raw_slice = std.mem.span(raw_result);

            var parsed = json.parseFromSlice(json.Value, allocator, raw_slice, .{}) catch |err| {
                log.warn("pollFn: failed to parse update as JSON: {t}", .{err});
                continue;
            };
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const type_name = if (obj.get("@type")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            // A response to a request `send()` tagged with `.@"@extra"` (see
            // `requestChatMeta`/`markMessagesRead`).
            if (obj.get("@extra")) |extra_v| if (extra_v == .integer) {
                self.storePendingResponse(self.io, @intCast(extra_v.integer), raw_slice);
                continue;
            };

            if (std.mem.eql(u8, type_name, "updateAuthorizationState")) {
                self.handleAuthorizationState(obj);
                continue;
            }
            if (std.mem.eql(u8, type_name, "updateNewMessage")) {
                if (try self.convertNewMessage(allocator, obj)) |msg| {
                    try out.append(allocator, msg);
                }
                continue;
            }
            if (std.mem.eql(u8, type_name, "updateNewChat")) {
                self.handleUpdateNewChat(obj);
                continue;
            }
            if (std.mem.eql(u8, type_name, "updateChatTitle")) {
                self.handleUpdateChatTitle(obj);
                continue;
            }
            // Every other update type (typing indicators, read receipts, ...) is silently
            // Ignored for now — Phase A scope.
        }

        return try out.toOwnedSlice(allocator);
    }

    fn handleUpdateNewChat(self: *TelegramUserConnector, update: json.ObjectMap) void {
        const chat = switch (update.get("chat") orelse return) {
            .object => |o| o,
            else => return,
        };
        const chat_id = switch (chat.get("id") orelse return) {
            .integer => |n| n,
            else => return,
        };
        const title = switch (chat.get("title") orelse return) {
            .string => |s| s,
            else => return,
        };
        if (title.len == 0) return; // e.g. a not-yet-resolved private chat
        var buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&buf, "{d}", .{chat_id}) catch return;
        self.setKnownChatTitle(id_str, title);
    }

    fn handleUpdateChatTitle(self: *TelegramUserConnector, update: json.ObjectMap) void {
        const chat_id = switch (update.get("chat_id") orelse return) {
            .integer => |n| n,
            else => return,
        };
        const title = switch (update.get("title") orelse return) {
            .string => |s| s,
            else => return,
        };
        var buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&buf, "{d}", .{chat_id}) catch return;
        self.setKnownChatTitle(id_str, title);
    }

    fn handleAuthorizationState(self: *TelegramUserConnector, update: json.ObjectMap) void {
        const state_obj = switch (update.get("authorization_state") orelse return) {
            .object => |o| o,
            else => return,
        };
        const state_type = switch (state_obj.get("@type") orelse return) {
            .string => |s| s,
            else => return,
        };

        if (std.mem.eql(u8, state_type, "authorizationStateWaitTdlibParameters")) {
            self.auth_state = .wait_tdlib_parameters;
            self.sendTdlibParameters();
        } else if (std.mem.eql(u8, state_type, "authorizationStateWaitPhoneNumber")) {
            self.auth_state = .wait_phone_number;
            log.info("waiting for the owner's phone number — call submitPhoneNumber()", .{});
        } else if (std.mem.eql(u8, state_type, "authorizationStateWaitCode")) {
            self.auth_state = .wait_code;
            log.info("waiting for the login code Telegram just sent — call submitAuthCode()", .{});
        } else if (std.mem.eql(u8, state_type, "authorizationStateWaitPassword")) {
            self.auth_state = .wait_password;
            log.info("waiting for the account's 2FA password — call submitPassword()", .{});
        } else if (std.mem.eql(u8, state_type, "authorizationStateReady")) {
            self.auth_state = .ready;
            log.info("personal-account connector authenticated and ready", .{});
            self.send(.{ .@"@type" = "getMe" });
            // Without an explicit request, TDLib only proactively pushes `updateNewChat`
            // for however many chats it decides to eagerly load on its own.
            self.send(.{ .@"@type" = "loadChats", .chat_list = .{ .@"@type" = "chatListMain" }, .limit = 200 });
            self.send(.{ .@"@type" = "loadChats", .chat_list = .{ .@"@type" = "chatListArchive" }, .limit = 200 });
        } else if (std.mem.eql(u8, state_type, "authorizationStateLoggingOut")) {
            self.auth_state = .logging_out;
        } else if (std.mem.eql(u8, state_type, "authorizationStateClosed")) {
            self.auth_state = .closed;
            self.client_id = null; // next ensureClient() call creates a fresh instance
        } else {
            self.auth_state = .unsupported;
            if (self.unsupported_auth_type) |old| self.allocator.free(old);
            self.unsupported_auth_type = self.allocator.dupe(u8, state_type) catch null;
            log.err("unsupported authorization state '{s}' — login can't proceed from here (QR-code/other-device login isn't implemented, only the phone-number flow)", .{state_type});
        }
    }

    fn sendTdlibParameters(self: *TelegramUserConnector) void {
        self.send(.{
            .@"@type" = "setTdlibParameters",
            .database_directory = self.session_dir,
            .use_message_database = true,
            .use_secret_chats = false,
            .api_id = self.api_id,
            .api_hash = self.api_hash,
            .system_language_code = "en",
            .device_model = "Warden",
            .application_version = "1.0",
        });
    }

    /// `updateNewMessage.message` -> `iface.Message`, or `null` for a message
    /// shape this pass doesn't handle.
    fn convertNewMessage(self: *TelegramUserConnector, allocator: std.mem.Allocator, update: json.ObjectMap) !?iface.Message {
        const message = switch (update.get("message") orelse return null) {
            .object => |o| o,
            else => return null,
        };

        // Echo of the account's own outgoing message (e.g. sent from
        // another device) — not an inbound message to react to.
        if (message.get("is_outgoing")) |v| if (v == .bool and v.bool) return null;

        const chat_id = switch (message.get("chat_id") orelse return null) {
            .integer => |n| n,
            else => return null,
        };

        // The owner reads every message through Warden, so it's already been "seen"
        // the moment it arrives here.

        // I am diabling the mark as seen feature for now since it has caused multiple
        // issues for me.

        const content = switch (message.get("content") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const content_type = switch (content.get("@type") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (!std.mem.eql(u8, content_type, "messageText")) return null; // Phase A scope
        const formatted_text = switch (content.get("text") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const text = switch (formatted_text.get("text") orelse return null) {
            .string => |s| s,
            else => return null,
        };

        const sender = switch (message.get("sender_id") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const sender_user_id: ?i64 = switch (sender.get("user_id") orelse json.Value{ .null = {} }) {
            .integer => |n| n,
            else => null,
        };
        const user_id = sender_user_id orelse return null; // messages sent as a channel/anonymous admin — not attributable to a user, skip for now

        const message_id: ?i64 = switch (message.get("id") orelse json.Value{ .null = {} }) {
            .integer => |n| n,
            else => null,
        };

        const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{chat_id});
        return .{
            .chat_id = chat_id_str,
            .message_id = if (message_id) |m| try std.fmt.allocPrint(allocator, "{d}", .{m}) else null,
            .user_id = try std.fmt.allocPrint(allocator, "{d}", .{user_id}),
            .text = try allocator.dupe(u8, text),
            // Left null before this, which meant everything downstream fell back to the
            // raw numeric chat id -- a `reply_autonomy = .draft` notification read "Chat.
            .chat_title = self.knownChatTitle(allocator, chat_id_str),
            // Private-chat vs. group/channel isn't distinguished yet.
            .is_group = false,
            .identity = .{
                .platform = .telegram_user,
                .native_id = try std.fmt.allocPrint(allocator, "{d}", .{user_id}),
                .display_name = try std.fmt.allocPrint(allocator, "{d}", .{user_id}), // resolving a real name needs a getUser call — not made yet, see Phase A scope
                .first_seen = 0,
                .last_seen = 0,
            },
        };
    }
};

/// Best-effort "empty this chat's Telegram composer", tolerant of every
/// reason it might not be possible.
pub fn clearComposerDraftFor(conn: ?*TelegramUserConnector, allocator: std.mem.Allocator, io: Io, native_chat_id: []const u8) void {
    const c = conn orelse return;
    const chat_id = std.fmt.parseInt(i64, native_chat_id, 10) catch {
        log.warn("clearComposerDraftFor: not a numeric TDLib chat id: {s}", .{native_chat_id});
        return;
    };
    _ = c.clearChatDraft(allocator, io, chat_id);
}

const testing = std.testing;

test "AuthState starts at .none before ensureClient runs" {
    var conn = TelegramUserConnector.init(testing.allocator, testing.io, 1, "hash", "/tmp/warden-tdlib-test");
    try testing.expectEqual(AuthState.none, conn.authState());
    try testing.expectEqual(@as(?[]const u8, null), conn.self_user_id);
}

test "platformFn reports .telegram_user" {
    var conn = TelegramUserConnector.init(testing.allocator, testing.io, 1, "hash", "/tmp/warden-tdlib-test");
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.telegram_user, c.platform());
}
