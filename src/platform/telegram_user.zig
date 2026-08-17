const std = @import("std");
const Io = std.Io;
const json = std.json;

const iface = @import("interface.zig");
const Identity = @import("../domain/identity.zig").Identity;
const log = @import("../log.zig").scoped("telegram_user");

const td = @cImport({
    @cInclude("td/telegram/td_json_client.h");
});

/// How long a single `td_receive` call blocks waiting for the next update —
/// same "bounds one connector's slice of the round-robin poll loop" reasoning
/// as `xmpp.zig`'s `poll_timeout_ns`. Short, since `pollFn` also drains a
/// burst of already-buffered updates per call (see `drain_limit` below) and
/// a long per-call block would stall that.
const receive_timeout_seconds: f64 = 3.0;

/// Upper bound on how many updates one `pollFn` call drains before returning
/// — TDLib can hand back updates faster than they can be converted/returned,
/// and an unbounded drain loop would starve every other connector in
/// `main.zig`'s round-robin poll loop. Matches this codebase's existing
/// "bounded work per poll cycle" convention (see e.g. `messages.zig`'s
/// row-count ceilings).
const drain_limit: usize = 50;

/// TDLib's own authorization-state machine (`updateAuthorizationState`,
/// https://core.telegram.org/tdlib/getting-started#authorization) collapsed
/// to the subset this connector actually branches on. `.ready` is the only
/// state `pollFn` converts updates in; every other state means "waiting on
/// something" — either TDLib itself (`.wait_tdlib_parameters`) or a human
/// (`.wait_phone_number`/`.wait_code`/`.wait_password`, driven by
/// `submitPhoneNumber`/`submitAuthCode`/`submitPassword`).
pub const AuthState = enum {
    none,
    wait_tdlib_parameters,
    wait_phone_number,
    wait_code,
    wait_password,
    ready,
    logging_out,
    closed,
    /// Anything TDLib sent that isn't one of the above (e.g.
    /// `authorizationStateWaitOtherDeviceConfirmation` — QR-code login,
    /// deliberately unsupported since this connector only drives the
    /// phone-number flow). Login can't proceed from here; see `pollFn`'s
    /// log line for what TDLib actually sent.
    unsupported,
};

/// TDLib-backed (MTProto, via TDLib's `tdjson` C interface) implementation of
/// `platform.Connector` for the *owner's own* Telegram account — distinct
/// from `platform/telegram.zig`'s Bot API connector, see `Platform.
/// telegram_user`'s doc comment for why these are separate connectors
/// rather than one with a mode flag.
///
/// Login is inherently a one-time interactive step (phone number -> code
/// Telegram sends to the number's *existing* sessions -> 2FA password if
/// one is set) that TDLib's own state machine drives — this struct exposes
/// that as `authState()` (what's currently being waited on) plus
/// `submitPhoneNumber`/`submitAuthCode`/`submitPassword` (what to call in
/// response), so a caller (the warden-ui login form, or a bot-chat command
/// flow) can drive it without this file needing to know which surface is
/// asking. Once `authState() == .ready`, TDLib persists the session under
/// `session_dir` itself — a later process restart pointed at the same
/// directory reaches `.ready` again with no re-login.
///
/// **Phase A scope, documented rather than silently assumed**: `pollFn`
/// only converts `updateNewMessage` whose content is `messageText` (the
/// common case) into `iface.Message`; photos/documents/voice/replies/
/// group-admin actions are not yet implemented (`sendMessage` is the only
/// outbound vtable method wired up). TDLib's own chat ids are a *different*
/// numbering scheme than the Bot API's for the same real-world chat — this
/// is fine (`store/chats.zig` already keys by `(platform, native_chat_id)`,
/// so `.telegram` and `.telegram_user` rows for "the same" group never
/// collide or need reconciling), but worth knowing before assuming a chat
/// id copied from one connector means anything to the other.
pub const TelegramUserConnector = struct {
    allocator: std.mem.Allocator,
    api_id: i32,
    api_hash: []const u8,
    session_dir: []const u8,
    client_id: ?c_int = null,
    auth_state: AuthState = .none,
    /// Raw `@type` string of an `.unsupported` auth state, for logging —
    /// duped onto `allocator` since the JSON it came from is only valid
    /// until the next `td_receive`/`td_execute` call.
    unsupported_auth_type: ?[]const u8 = null,
    self_user_id: ?[]const u8 = null,
    self_username: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, api_id: i32, api_hash: []const u8, session_dir: []const u8) TelegramUserConnector {
        return .{
            .allocator = allocator,
            .api_id = api_id,
            .api_hash = api_hash,
            .session_dir = session_dir,
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
        // No moderation/media vtable slots yet — see the struct doc
        // comment's "Phase A scope" note. Every one of those falls back to
        // `error.Unsupported`/the plain-text fallback, same as any other
        // connector that doesn't implement an optional method.
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
        // Kicks the state machine — TDLib won't send its first
        // `updateAuthorizationState` (`authorizationStateWaitTdlibParameters`)
        // until something is sent to it.
        self.send(.{ .@"@type" = "getAuthorizationState" });
    }

    /// Sends a request built from an anonymous struct literal, JSON-encoded
    /// via `json.Stringify` (every field here is plain typed data — no raw-
    /// JSON splicing the way `llm/toolcall.zig`'s tool-schema handling
    /// needs, so `Stringify.value` on the struct directly is the right tool,
    /// not a hand-built writer).
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

    /// Answers `authorizationStateWaitPhoneNumber`. `phone_number` is the
    /// full international-format number (e.g. "+15551234567").
    pub fn submitPhoneNumber(self: *TelegramUserConnector, phone_number: []const u8) void {
        self.send(.{
            .@"@type" = "setAuthenticationPhoneNumber",
            .phone_number = phone_number,
        });
    }

    /// Answers `authorizationStateWaitCode`. `code` is whatever the caller
    /// resolved the login code down to — callers accepting it from a
    /// Telegram chat (rather than warden-ui's web form) are responsible for
    /// stripping whatever obfuscation they asked the owner to type it with
    /// (see `platform/interface.zig`'s `Platform.telegram_user` doc comment
    /// and README's login-flow section) *before* calling this; this
    /// function sends exactly the digits it's given.
    pub fn submitAuthCode(self: *TelegramUserConnector, code: []const u8) void {
        self.send(.{
            .@"@type" = "checkAuthenticationCode",
            .code = code,
        });
    }

    /// Answers `authorizationStateWaitPassword` (2FA).
    pub fn submitPassword(self: *TelegramUserConnector, password: []const u8) void {
        self.send(.{
            .@"@type" = "checkAuthenticationPassword",
            .password = password,
        });
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
            // Every other update type (typing indicators, read receipts,
            // chat metadata changes, ...) is silently ignored for now —
            // Phase A scope, see the struct doc comment.
        }

        return try out.toOwnedSlice(allocator);
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

    /// `updateNewMessage.message` -> `iface.Message`, or `null` for a
    /// message shape this pass doesn't handle (non-text content, or one
    /// missing fields it needs) — same "skip, don't crash the poll loop
    /// over one unusual message" posture every other connector already
    /// takes on malformed/unexpected input.
    fn convertNewMessage(_: *TelegramUserConnector, allocator: std.mem.Allocator, update: json.ObjectMap) !?iface.Message {
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

        return .{
            .chat_id = try std.fmt.allocPrint(allocator, "{d}", .{chat_id}),
            .message_id = if (message_id) |m| try std.fmt.allocPrint(allocator, "{d}", .{m}) else null,
            .user_id = try std.fmt.allocPrint(allocator, "{d}", .{user_id}),
            .text = try allocator.dupe(u8, text),
            // Private-chat vs. group/channel isn't distinguished yet — see
            // the struct doc comment's Phase A scope note. Always reported
            // as a 1:1 chat for now, meaning every message gets treated as
            // addressed to the owner, which is at least the safe direction
            // to be wrong in (never silently ignoring a real DM).
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

const testing = std.testing;

test "AuthState starts at .none before ensureClient runs" {
    var conn = TelegramUserConnector.init(testing.allocator, 1, "hash", "/tmp/warden-tdlib-test");
    try testing.expectEqual(AuthState.none, conn.authState());
    try testing.expectEqual(@as(?[]const u8, null), conn.self_user_id);
}

test "platformFn reports .telegram_user" {
    var conn = TelegramUserConnector.init(testing.allocator, 1, "hash", "/tmp/warden-tdlib-test");
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.telegram_user, c.platform());
}
