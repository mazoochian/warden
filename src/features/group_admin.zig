const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");

pub const ActionKind = enum { ban, kick };

const PendingAction = struct {
    kind: ActionKind,
    target_user_id: []const u8,
    /// Username if known, else the raw user id — for the confirmation
    /// prompt and final reply.
    target_label: []const u8,
    expires_at: i64,
};

/// Ban/kick require the owner to confirm before they actually happen —
/// mute/pin/delete are reversible enough (or low-blast-radius enough) to
/// act on immediately. One pending action per chat: a second confirmable
/// command in the same chat simply replaces whatever was pending.
pub const PendingConfirmations = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(PendingAction),
    timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, timeout_seconds: i64) PendingConfirmations {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(PendingAction).init(allocator),
            .timeout_seconds = timeout_seconds,
        };
    }

    pub fn deinit(self: *PendingConfirmations) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.freeEntry(entry.key_ptr.*, entry.value_ptr.*);
        self.map.deinit();
    }

    fn freeEntry(self: *PendingConfirmations, key: []const u8, action: PendingAction) void {
        self.allocator.free(key);
        self.allocator.free(action.target_user_id);
        self.allocator.free(action.target_label);
    }

    /// Replaces any existing pending action for `chat_id`.
    pub fn set(self: *PendingConfirmations, now: i64, chat_id: []const u8, kind: ActionKind, target_user_id: []const u8, target_label: []const u8) !void {
        const owned_user_id = try self.allocator.dupe(u8, target_user_id);
        errdefer self.allocator.free(owned_user_id);
        const owned_label = try self.allocator.dupe(u8, target_label);
        errdefer self.allocator.free(owned_label);

        const action = PendingAction{
            .kind = kind,
            .target_user_id = owned_user_id,
            .target_label = owned_label,
            .expires_at = now + self.timeout_seconds,
        };

        if (self.map.fetchRemove(chat_id)) |old| self.freeEntry(old.key, old.value);

        const key = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(key);
        try self.map.put(key, action);
    }

    /// Removes and returns the pending action for `chat_id` if one exists
    /// and hasn't expired (an expired one is just dropped, not returned).
    pub fn take(self: *PendingConfirmations, now: i64, chat_id: []const u8) ?struct { kind: ActionKind, target_user_id: []const u8, target_label: []const u8 } {
        const entry = self.map.fetchRemove(chat_id) orelse return null;
        defer self.freeEntry(entry.key, entry.value);

        if (now > entry.value.expires_at) return null;
        return .{
            .kind = entry.value.kind,
            .target_user_id = self.allocator.dupe(u8, entry.value.target_user_id) catch return null,
            .target_label = self.allocator.dupe(u8, entry.value.target_label) catch return null,
        };
    }

    pub fn clear(self: *PendingConfirmations, chat_id: []const u8) void {
        if (self.map.fetchRemove(chat_id)) |old| self.freeEntry(old.key, old.value);
    }
};

/// A command that names/targets a user (everything except mute's implicit
/// duration) needs a reply to resolve who it's about — Telegram messages
/// don't carry structured "@mention" targeting in a way we parse, so
/// replying to the target's message is the one reliable mechanism.
fn replyTarget(msg: iface.Message) ?struct { user_id: []const u8, label: []const u8 } {
    const user_id = msg.reply_to_user_id orelse return null;
    const label = msg.reply_to_username orelse user_id;
    return .{ .user_id = user_id, .label = label };
}

const default_mute_seconds: i64 = 3600;

pub fn mute(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, now: i64) void {
    const target = replyTarget(msg) orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to mute.");
        return;
    };
    connector.muteUser(a, msg.chat_id, target.user_id, now + default_mute_seconds) catch |err| {
        reportFailure(connector, a, msg.chat_id, "mute", err);
        return;
    };
    reply(connector, a, msg.chat_id, "Muted {s} for 1 hour.", .{target.label});
}

pub fn unmute(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    const target = replyTarget(msg) orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to unmute.");
        return;
    };
    connector.unmuteUser(a, msg.chat_id, target.user_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, "unmute", err);
        return;
    };
    reply(connector, a, msg.chat_id, "Unmuted {s}.", .{target.label});
}

pub fn pin(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    const message_id = msg.reply_to_message_id orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message you want to pin.");
        return;
    };
    connector.pinMessage(a, msg.chat_id, message_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, "pin", err);
        return;
    };
    connector.sendMessage(a, msg.chat_id, "Pinned.");
}

pub fn unpin(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    // No reply needed: absent one, unpins whatever's currently pinned.
    connector.unpinMessage(a, msg.chat_id, msg.reply_to_message_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, "unpin", err);
        return;
    };
    connector.sendMessage(a, msg.chat_id, "Unpinned.");
}

pub fn deleteMessage(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    const message_id = msg.reply_to_message_id orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message you want deleted.");
        return;
    };
    connector.deleteMessage(a, msg.chat_id, message_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, "delete", err);
        return;
    };
    connector.sendMessage(a, msg.chat_id, "Deleted.");
}

/// Starts the confirm-before-acting flow for ban/kick — does not perform
/// the action yet.
pub fn requestConfirmation(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pending: *PendingConfirmations,
    now: i64,
    msg: iface.Message,
    kind: ActionKind,
) void {
    const target = replyTarget(msg) orelse {
        reply(connector, a, msg.chat_id, "Reply to the message of the person you want to {s}.", .{@tagName(kind)});
        return;
    };
    pending.set(now, msg.chat_id, kind, target.user_id, target.label) catch |err| {
        std.log.err("group_admin: failed to record pending {s}: {t}", .{ @tagName(kind), err });
        connector.sendMessage(a, msg.chat_id, "Something went wrong queuing that — try again.");
        return;
    };
    reply(
        connector,
        a,
        msg.chat_id,
        "{s} {s}? Send /confirm within {d}s to proceed, or /cancel.",
        .{ actionVerbTitled(kind), target.label, pending.timeout_seconds },
    );
}

pub fn confirm(connector: iface.Connector, a: std.mem.Allocator, pending: *PendingConfirmations, now: i64, msg: iface.Message) void {
    const action = pending.take(now, msg.chat_id) orelse {
        connector.sendMessage(a, msg.chat_id, "Nothing to confirm.");
        return;
    };
    switch (action.kind) {
        .ban => connector.banUser(a, msg.chat_id, action.target_user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, "ban", err);
            return;
        },
        .kick => connector.kickUser(a, msg.chat_id, action.target_user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, "kick", err);
            return;
        },
    }
    reply(connector, a, msg.chat_id, "{s} {s}.", .{ actionVerbPast(action.kind), action.target_label });
}

pub fn cancel(connector: iface.Connector, a: std.mem.Allocator, pending: *PendingConfirmations, msg: iface.Message) void {
    pending.clear(msg.chat_id);
    connector.sendMessage(a, msg.chat_id, "Cancelled.");
}

fn actionVerbTitled(kind: ActionKind) []const u8 {
    return switch (kind) {
        .ban => "Ban",
        .kick => "Kick",
    };
}

fn actionVerbPast(kind: ActionKind) []const u8 {
    return switch (kind) {
        .ban => "Banned",
        .kick => "Kicked",
    };
}

fn reportFailure(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, action: []const u8, err: anyerror) void {
    std.log.err("group_admin: {s} failed: {t}", .{ action, err });
    if (err == error.Unsupported) {
        connector.sendMessage(a, chat_id, "That action isn't supported on this platform.");
    } else {
        connector.sendMessage(a, chat_id, "That failed — check the bot is an admin in this group with the right permissions.");
    }
}

fn reply(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(a, fmt, args) catch return;
    connector.sendMessage(a, chat_id, text);
}

const testing = std.testing;

test "PendingConfirmations set/take round trip and expiry" {
    var pending = PendingConfirmations.init(testing.allocator, 60);
    defer pending.deinit();

    try pending.set(1000, "chat1", .ban, "42", "spammer");
    const taken = pending.take(1010, "chat1").?;
    defer {
        testing.allocator.free(taken.target_user_id);
        testing.allocator.free(taken.target_label);
    }
    try testing.expectEqual(ActionKind.ban, taken.kind);
    try testing.expectEqualStrings("42", taken.target_user_id);
    try testing.expectEqualStrings("spammer", taken.target_label);

    // Consumed by take(): a second take() finds nothing.
    try testing.expect(pending.take(1010, "chat1") == null);
}

test "PendingConfirmations expires old actions" {
    var pending = PendingConfirmations.init(testing.allocator, 60);
    defer pending.deinit();

    try pending.set(1000, "chat1", .kick, "42", "spammer");
    try testing.expect(pending.take(1000 + 61, "chat1") == null);
}

test "PendingConfirmations.set replaces an existing pending action for the same chat" {
    var pending = PendingConfirmations.init(testing.allocator, 60);
    defer pending.deinit();

    try pending.set(1000, "chat1", .ban, "42", "first");
    try pending.set(1000, "chat1", .kick, "43", "second");

    const taken = pending.take(1000, "chat1").?;
    defer {
        testing.allocator.free(taken.target_user_id);
        testing.allocator.free(taken.target_label);
    }
    try testing.expectEqual(ActionKind.kick, taken.kind);
    try testing.expectEqualStrings("43", taken.target_user_id);
}
