//! A `Connector` decorator that separates "the chat a command *acts* on"
//! from "the chat its output *goes* to" — the design problem ROADMAP.md's
//! Phase 9 named as the blocker for `/as <chat ref> <command>`.
//!
//! Every admin handler in `main.zig` replies with
//! `connector.sendMessage(a, msg.chat_id, ...)`, so re-dispatching one with
//! `msg.chat_id` swapped to a target chat would correctly *act* on the
//! target but would also post its confirmation there, instead of back into
//! the management room where the operator is sitting. Rather than give
//! every handler a second "where do replies go" parameter (~40 call sites,
//! and every future handler has to remember it), the redirection is done
//! once, underneath them, at the only layer they all already share: the
//! `Connector` vtable.
//!
//! The rule, deliberately narrow:
//!
//!   * **Outbound message sends** (`sendMessage`, `sendPhoto`,
//!     `sendDocument`, `sendPoll`, `sendMessageReturningId`, `editMessage`,
//!     `sendChoicePrompt`, `editChoicePrompt`) addressed to
//!     `action_chat_id` are rewritten to `reply_chat_id`, threaded under
//!     the operator's own `/as` message.
//!   * **Everything else passes through untouched** — `muteUser`,
//!     `kickUser`, `banUser`, `promoteUser`, `demoteUser`, `pinMessage`,
//!     `unpinMessage`, `deleteMessage`, `isGroupAdmin`, `listChatAdmins`.
//!     Those are the *action*, and the action belongs in the target chat.
//!     `isGroupAdmin` passing through unchanged is load-bearing for
//!     security, not just correctness: it means a relayed command's own
//!     `auth.checkGroupAdminAccess` still asks "is this user an admin of
//!     the chat being acted on", never of the control room.
//!   * A send addressed to some *other* chat (not `action_chat_id`) is
//!     also left alone — a handler that deliberately messages a third
//!     party (an owner DM, a reminder delivery) keeps working.
//!
//! Two consequences worth stating, since they fall out of the rule rather
//! than being separately implemented:
//!
//!   * Redirected sends are self-consistent with redirected edits: a
//!     `sendMessageReturningId` to the target returns an id that really
//!     belongs to the *control room*, and the matching `editMessage`
//!     addressed to the target is redirected to the control room too, so
//!     the pair still refers to the same real message. A send-then-*pin*
//!     pair is NOT self-consistent (the pin is an action and isn't
//!     redirected), which is one reason `main.zig` doesn't relay `/notice`
//!     — it has its own command.
//!   * When the underlying connector doesn't implement an optional method,
//!     this decorator doesn't either (the vtable entry stays `null`), so
//!     `Connector`'s own degrade-to-text fallbacks still fire — and,
//!     because those fallbacks call back through *this* connector's
//!     `sendMessage`, the fallback text is redirected as well.
//!
//! ### Alternatives considered
//!
//! * **Add a `reply_chat_id` parameter to every handler.** Most explicit,
//!   but it's a ~40-signature change, every one of which would then carry
//!   a parameter that is the same as `msg.chat_id` in every case but one.
//!   New handlers would silently regress it by forgetting.
//! * **Add a `reply_chat_id` field to `iface.Message`.** Smaller diff, but
//!   it only helps handlers that reply via `msg`; anything replying via a
//!   plain `chat_id: []const u8` argument (`replyWithStats`,
//!   `handleDigestCommand`, `handleRemindersList`, ... all of which take
//!   the native chat id separately) would still need touching, and the
//!   field would be dead weight on every message the connectors build.
//! * **Buffer the relayed command's output and re-emit it.** Would give
//!   the nicest transcript ("here's what happened"), but requires knowing
//!   when a command is "done" — several are asynchronous (ticker edits,
//!   streaming answers) — and would delay or reorder output. Rejected as
//!   more machinery than the problem needs.
//!
//! The decorator won because it is the only option whose blast radius is
//! one file, and because it makes the routing rule a single stated
//! invariant that can be unit-tested against a fake connector rather than
//! a convention spread across every handler.

const std = @import("std");
const iface = @import("interface.zig");
const Identity = @import("../domain/identity.zig").Identity;

/// Wraps `inner`, redirecting sends aimed at `action_chat_id` to
/// `reply_chat_id`. Must not be copied after `connector()` is called — the
/// returned `iface.Connector` borrows `&self.vt` and `self`.
pub const ReplyRedirect = struct {
    inner: iface.Connector,
    /// Native id of the chat the relayed command acts on (the `/as`
    /// target).
    action_chat_id: []const u8,
    /// Native id of the chat replies should surface in (the management
    /// room the operator typed `/as` in).
    reply_chat_id: []const u8,
    /// The operator's own `/as` message, so redirected replies thread
    /// under it. Any `reply_to_message_id` a handler passes alongside a
    /// redirected send is discarded in favour of this: the handler's id
    /// refers to a message in the *target* chat, which would be a dangling
    /// reference in the control room.
    reply_to_message_id: ?[]const u8,
    /// Per-instance so an optional method the inner connector lacks stays
    /// `null` here too (see the module doc) — the entries can't be a
    /// single shared `const`.
    vt: iface.Connector.VTable,

    pub fn init(
        inner: iface.Connector,
        action_chat_id: []const u8,
        reply_chat_id: []const u8,
        reply_to_message_id: ?[]const u8,
    ) ReplyRedirect {
        const in = inner.vtable;
        return .{
            .inner = inner,
            .action_chat_id = action_chat_id,
            .reply_chat_id = reply_chat_id,
            .reply_to_message_id = reply_to_message_id,
            .vt = .{
                .platform = platformFn,
                .poll = pollFn,
                .sendMessage = sendMessageFn,
                .sendPhoto = if (in.sendPhoto != null) sendPhotoFn else null,
                .sendDocument = if (in.sendDocument != null) sendDocumentFn else null,
                .sendPoll = if (in.sendPoll != null) sendPollFn else null,
                .maxMessageLength = if (in.maxMessageLength != null) maxMessageLengthFn else null,
                .downloadFile = if (in.downloadFile != null) downloadFileFn else null,
                .sendMessageReturningId = if (in.sendMessageReturningId != null) sendMessageReturningIdFn else null,
                .editMessage = if (in.editMessage != null) editMessageFn else null,
                .sendChoicePrompt = if (in.sendChoicePrompt != null) sendChoicePromptFn else null,
                .editChoicePrompt = if (in.editChoicePrompt != null) editChoicePromptFn else null,
                .muteUser = if (in.muteUser != null) muteUserFn else null,
                .unmuteUser = if (in.unmuteUser != null) unmuteUserFn else null,
                .kickUser = if (in.kickUser != null) kickUserFn else null,
                .banUser = if (in.banUser != null) banUserFn else null,
                .promoteUser = if (in.promoteUser != null) promoteUserFn else null,
                .demoteUser = if (in.demoteUser != null) demoteUserFn else null,
                .pinMessage = if (in.pinMessage != null) pinMessageFn else null,
                .unpinMessage = if (in.unpinMessage != null) unpinMessageFn else null,
                .deleteMessage = if (in.deleteMessage != null) deleteMessageFn else null,
                .isGroupAdmin = if (in.isGroupAdmin != null) isGroupAdminFn else null,
                .selfUsername = if (in.selfUsername != null) selfUsernameFn else null,
                .selfId = if (in.selfId != null) selfIdFn else null,
                .listChatAdmins = if (in.listChatAdmins != null) listChatAdminsFn else null,
                .setCommands = if (in.setCommands != null) setCommandsFn else null,
            },
        };
    }

    pub fn connector(self: *ReplyRedirect) iface.Connector {
        return .{ .ptr = self, .vtable = &self.vt };
    }

    const Route = struct { chat_id: []const u8, reply_to: ?[]const u8 };

    /// The whole policy, in one place: a send aimed at the chat we're
    /// acting on comes back to the operator instead; anything else is left
    /// exactly as the handler asked for it.
    fn route(self: *const ReplyRedirect, chat_id: []const u8, reply_to: ?[]const u8) Route {
        if (std.mem.eql(u8, chat_id, self.action_chat_id))
            return .{ .chat_id = self.reply_chat_id, .reply_to = self.reply_to_message_id };
        return .{ .chat_id = chat_id, .reply_to = reply_to };
    }

    fn self_(ptr: *anyopaque) *ReplyRedirect {
        return @ptrCast(@alignCast(ptr));
    }

    fn platformFn(ptr: *anyopaque) iface.Platform {
        return self_(ptr).inner.platform();
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        return self_(ptr).inner.poll(allocator);
    }

    // --- redirected: message output ---

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        const self = self_(ptr);
        const r = self.route(chat_id, reply_to_message_id);
        self.inner.sendMessage(allocator, r.chat_id, text, r.reply_to);
    }

    fn sendPhotoFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        const self = self_(ptr);
        self.inner.sendPhoto(allocator, self.route(chat_id, null).chat_id, image_bytes, caption);
    }

    fn sendDocumentFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        const self = self_(ptr);
        self.inner.sendDocument(allocator, self.route(chat_id, null).chat_id, file_bytes, file_name, caption);
    }

    fn sendPollFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, question: []const u8, options: []const []const u8, reply_to_message_id: ?[]const u8) void {
        const self = self_(ptr);
        const r = self.route(chat_id, reply_to_message_id);
        self.inner.sendPoll(allocator, r.chat_id, question, options, r.reply_to);
    }

    fn sendMessageReturningIdFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 {
        const self = self_(ptr);
        const r = self.route(chat_id, reply_to_message_id);
        return (try self.inner.sendMessageReturningId(allocator, r.chat_id, text, r.reply_to)) orelse error.Unsupported;
    }

    fn editMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void {
        const self = self_(ptr);
        return self.inner.editMessage(allocator, self.route(chat_id, null).chat_id, message_id, text);
    }

    fn sendChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const iface.Choice, reply_to_message_id: ?[]const u8) anyerror!?[]const u8 {
        const self = self_(ptr);
        const r = self.route(chat_id, reply_to_message_id);
        return self.inner.sendChoicePrompt(allocator, r.chat_id, text, choices, r.reply_to);
    }

    fn editChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8, choices: []const iface.Choice) anyerror!void {
        const self = self_(ptr);
        return self.inner.editChoicePrompt(allocator, self.route(chat_id, null).chat_id, message_id, text, choices);
    }

    // --- passed through: actions and queries against the target chat ---

    fn maxMessageLengthFn(ptr: *anyopaque) usize {
        return self_(ptr).inner.maxMessageLength() orelse 0;
    }

    fn downloadFileFn(ptr: *anyopaque, allocator: std.mem.Allocator, file_id: []const u8) anyerror![]u8 {
        return self_(ptr).inner.downloadFile(allocator, file_id);
    }

    fn muteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) anyerror!void {
        return self_(ptr).inner.muteUser(allocator, chat_id, user_id, until_unix_time);
    }

    fn unmuteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        return self_(ptr).inner.unmuteUser(allocator, chat_id, user_id);
    }

    fn kickUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        return self_(ptr).inner.kickUser(allocator, chat_id, user_id);
    }

    fn banUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        return self_(ptr).inner.banUser(allocator, chat_id, user_id);
    }

    fn promoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        return self_(ptr).inner.promoteUser(allocator, chat_id, user_id);
    }

    fn demoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        return self_(ptr).inner.demoteUser(allocator, chat_id, user_id);
    }

    fn pinMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        return self_(ptr).inner.pinMessage(allocator, chat_id, message_id);
    }

    fn unpinMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: ?[]const u8) anyerror!void {
        return self_(ptr).inner.unpinMessage(allocator, chat_id, message_id);
    }

    fn deleteMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        return self_(ptr).inner.deleteMessage(allocator, chat_id, message_id);
    }

    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        return self_(ptr).inner.isGroupAdmin(allocator, chat_id, user_id);
    }

    fn selfUsernameFn(ptr: *anyopaque) ?[]const u8 {
        return self_(ptr).inner.selfUsername();
    }

    fn selfIdFn(ptr: *anyopaque) ?[]const u8 {
        return self_(ptr).inner.selfId();
    }

    fn listChatAdminsFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8) anyerror![]Identity {
        return self_(ptr).inner.listChatAdmins(allocator, chat_id);
    }

    fn setCommandsFn(ptr: *anyopaque, allocator: std.mem.Allocator, commands: []const iface.CommandSpec) anyerror!void {
        return self_(ptr).inner.setCommands(allocator, commands);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Records every call the decorator forwards, so a test can assert on both
/// *which* chat id the inner connector saw and *what* it was asked to do.
const RecordingConnector = struct {
    const Call = struct {
        kind: []const u8,
        chat_id: []const u8,
        arg: []const u8,
        reply_to: ?[]const u8,
    };

    calls: std.ArrayList(Call) = .empty,
    allocator: std.mem.Allocator,
    /// Set false to model a platform without image support.
    supports_photo: bool = true,
    is_group_admin: bool = false,
    next_message_id: []const u8 = "sent-1",

    fn deinit(self: *RecordingConnector) void {
        self.calls.deinit(self.allocator);
    }

    fn record(self: *RecordingConnector, kind: []const u8, chat_id: []const u8, arg: []const u8, reply_to: ?[]const u8) void {
        self.calls.append(self.allocator, .{ .kind = kind, .chat_id = chat_id, .arg = arg, .reply_to = reply_to }) catch {};
    }

    fn connector(self: *RecordingConnector) iface.Connector {
        return .{ .ptr = self, .vtable = if (self.supports_photo) &vtable_full else &vtable_no_photo };
    }

    const vtable_full: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendPhoto = sendPhotoFn,
        .sendMessageReturningId = sendMessageReturningIdFn,
        .editMessage = editMessageFn,
        .kickUser = kickUserFn,
        .pinMessage = pinMessageFn,
        .isGroupAdmin = isGroupAdminFn,
    };

    const vtable_no_photo: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .matrix;
    }
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }
    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = allocator;
        self_(ptr).record("sendMessage", chat_id, text, reply_to_message_id);
    }
    fn sendPhotoFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        _ = allocator;
        _ = caption;
        self_(ptr).record("sendPhoto", chat_id, image_bytes, null);
    }
    fn sendMessageReturningIdFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 {
        _ = allocator;
        const self = self_(ptr);
        self.record("sendMessageReturningId", chat_id, text, reply_to_message_id);
        return self.next_message_id;
    }
    fn editMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void {
        _ = allocator;
        _ = text;
        self_(ptr).record("editMessage", chat_id, message_id, null);
    }
    fn kickUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        _ = allocator;
        self_(ptr).record("kickUser", chat_id, user_id, null);
    }
    fn pinMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        _ = allocator;
        self_(ptr).record("pinMessage", chat_id, message_id, null);
    }
    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        _ = allocator;
        const self = self_(ptr);
        self.record("isGroupAdmin", chat_id, user_id, null);
        return self.is_group_admin;
    }

    fn self_(ptr: *anyopaque) *RecordingConnector {
        return @ptrCast(@alignCast(ptr));
    }
};

test "a reply aimed at the target chat comes back to the control room, threaded under the /as message" {
    var rec = RecordingConnector{ .allocator = testing.allocator };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", "op-msg-7");
    const c = redirect.connector();

    // What every handler does: `sendMessage(a, msg.chat_id, ...)`, where
    // the relayed `msg.chat_id` is the target chat.
    c.sendMessage(testing.allocator, "target-chat", "Kicked spammer.", "some-id-in-the-target-chat");

    try testing.expectEqual(@as(usize, 1), rec.calls.items.len);
    try testing.expectEqualStrings("sendMessage", rec.calls.items[0].kind);
    try testing.expectEqualStrings("control-room", rec.calls.items[0].chat_id);
    try testing.expectEqualStrings("Kicked spammer.", rec.calls.items[0].arg);
    // The handler's own reply_to referred to the target chat, so it's
    // replaced with the operator's `/as` message.
    try testing.expectEqualStrings("op-msg-7", rec.calls.items[0].reply_to.?);
}

test "a send aimed at some other chat is left completely alone" {
    var rec = RecordingConnector{ .allocator = testing.allocator };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", "op-msg-7");
    const c = redirect.connector();

    c.sendMessage(testing.allocator, "somewhere-else", "scheduled reminder", "their-msg");

    try testing.expectEqualStrings("somewhere-else", rec.calls.items[0].chat_id);
    try testing.expectEqualStrings("their-msg", rec.calls.items[0].reply_to.?);
}

test "actions against the target chat are NOT redirected" {
    var rec = RecordingConnector{ .allocator = testing.allocator };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", "op-msg-7");
    const c = redirect.connector();

    try c.kickUser(testing.allocator, "target-chat", "user-42");
    try c.pinMessage(testing.allocator, "target-chat", "msg-9");

    try testing.expectEqualStrings("kickUser", rec.calls.items[0].kind);
    try testing.expectEqualStrings("target-chat", rec.calls.items[0].chat_id);
    try testing.expectEqualStrings("pinMessage", rec.calls.items[1].kind);
    try testing.expectEqualStrings("target-chat", rec.calls.items[1].chat_id);
}

test "isGroupAdmin passes through, so a relayed command's auth check still asks about the target chat" {
    var rec = RecordingConnector{ .allocator = testing.allocator, .is_group_admin = true };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", null);
    const c = redirect.connector();

    try testing.expect(try c.isGroupAdmin(testing.allocator, "target-chat", "user-42"));
    try testing.expectEqualStrings("isGroupAdmin", rec.calls.items[0].kind);
    // NOT "control-room": an admin of the room they're sitting in must not
    // thereby become an admin of the chat they're acting on.
    try testing.expectEqualStrings("target-chat", rec.calls.items[0].chat_id);
}

test "a redirected send and its follow-up edit still refer to the same real message" {
    var rec = RecordingConnector{ .allocator = testing.allocator, .next_message_id = "control-msg-3" };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", "op-msg-7");
    const c = redirect.connector();

    const id = (try c.sendMessageReturningId(testing.allocator, "target-chat", "working...", null)).?;
    try testing.expectEqualStrings("control-msg-3", id);
    try testing.expectEqualStrings("control-room", rec.calls.items[0].chat_id);

    try c.editMessage(testing.allocator, "target-chat", id, "done");
    try testing.expectEqualStrings("editMessage", rec.calls.items[1].kind);
    try testing.expectEqualStrings("control-room", rec.calls.items[1].chat_id);
    try testing.expectEqualStrings("control-msg-3", rec.calls.items[1].arg);
}

test "photos are redirected too" {
    var rec = RecordingConnector{ .allocator = testing.allocator };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", null);
    redirect.connector().sendPhoto(testing.allocator, "target-chat", "PNGBYTES", null);

    try testing.expectEqualStrings("sendPhoto", rec.calls.items[0].kind);
    try testing.expectEqualStrings("control-room", rec.calls.items[0].chat_id);
}

test "an optional method the inner connector lacks stays unimplemented, and its text fallback is redirected" {
    var rec = RecordingConnector{ .allocator = testing.allocator, .supports_photo = false };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", "op-msg-7");
    const c = redirect.connector();
    try testing.expect(c.vtable.sendPhoto == null);

    // `Connector.sendPhoto`'s degrade-to-text path calls back through this
    // connector's own sendMessage, so the apology lands in the control
    // room, not the target chat.
    c.sendPhoto(testing.allocator, "target-chat", "PNGBYTES", null);
    try testing.expectEqualStrings("sendMessage", rec.calls.items[0].kind);
    try testing.expectEqualStrings("control-room", rec.calls.items[0].chat_id);
    try testing.expectEqualStrings("op-msg-7", rec.calls.items[0].reply_to.?);
}

test "platform and other pass-through queries reach the inner connector" {
    var rec = RecordingConnector{ .allocator = testing.allocator };
    defer rec.deinit();

    var redirect = ReplyRedirect.init(rec.connector(), "target-chat", "control-room", null);
    try testing.expectEqual(iface.Platform.matrix, redirect.connector().platform());
}
