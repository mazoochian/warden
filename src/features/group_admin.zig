const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const identities = @import("../store/identities.zig");
const chat_members = @import("../store/chat_members.zig");

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
///
/// Accessed from concurrently-running per-message tasks (see `PgPool`'s
/// doc comment for why), so `map` needs a lock; `lockUncancelable` is used
/// throughout since these are quick in-memory operations, not I/O, and
/// keeping `set`/`take`/`clear`'s existing signatures (no new error to
/// propagate) avoids rippling `try`/`catch` into every call site.
pub const PendingConfirmations = struct {
    allocator: std.mem.Allocator,
    io: Io,
    map: std.StringHashMap(PendingAction),
    mutex: Io.Mutex = .init,
    timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, timeout_seconds: i64) PendingConfirmations {
        return .{
            .allocator = allocator,
            .io = io,
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

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.fetchRemove(chat_id)) |old| self.freeEntry(old.key, old.value);

        const key = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(key);
        try self.map.put(key, action);
    }

    /// Removes and returns the pending action for `chat_id` if one exists
    /// and hasn't expired (an expired one is just dropped, not returned).
    pub fn take(self: *PendingConfirmations, now: i64, chat_id: []const u8) ?struct { kind: ActionKind, target_user_id: []const u8, target_label: []const u8 } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to mute.", msg.message_id);
        return;
    };
    connector.muteUser(a, msg.chat_id, target.user_id, now + default_mute_seconds) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "mute", err);
        return;
    };
    reply(connector, a, msg.chat_id, msg.message_id, "Muted {s} for 1 hour.", .{target.label});
}

pub fn unmute(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    const target = replyTarget(msg) orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to unmute.", msg.message_id);
        return;
    };
    connector.unmuteUser(a, msg.chat_id, target.user_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "unmute", err);
        return;
    };
    reply(connector, a, msg.chat_id, msg.message_id, "Unmuted {s}.", .{target.label});
}

pub fn pin(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    const message_id = msg.reply_to_message_id orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message you want to pin.", msg.message_id);
        return;
    };
    connector.pinMessage(a, msg.chat_id, message_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "pin", err);
        return;
    };
    connector.sendMessage(a, msg.chat_id, "Pinned.", msg.message_id);
}

pub fn unpin(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    // No reply needed: absent one, unpins whatever's currently pinned.
    connector.unpinMessage(a, msg.chat_id, msg.reply_to_message_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "unpin", err);
        return;
    };
    connector.sendMessage(a, msg.chat_id, "Unpinned.", msg.message_id);
}

pub fn deleteMessage(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message) void {
    const message_id = msg.reply_to_message_id orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message you want deleted.", msg.message_id);
        return;
    };
    connector.deleteMessage(a, msg.chat_id, message_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "delete", err);
        return;
    };
    connector.sendMessage(a, msg.chat_id, "Deleted.", msg.message_id);
}

/// Starts the confirm-before-acting flow for ban/kick — does not perform
/// the action yet.
pub fn requestConfirmation(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *PgPool,
    chat_id: i64,
    now: i64,
    msg: iface.Message,
    kind: ActionKind,
) void {
    const target = replyTarget(msg) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the message of the person you want to {s}.", .{@tagName(kind)});
        return;
    };
    // The actor (not the target) is who spends a token — resolved via
    // `getOrCreateMinimal` rather than assuming they've already been seen,
    // since token gating shouldn't depend on message-logging order.
    const actor_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), msg.user_id, msg.username orelse msg.user_id, false, now) catch |err| {
        std.log.err("token: failed to resolve identity for user {s}: {t}", .{ msg.user_id, err });
        return;
    };
    var count = chat_members.getTokens(pool, chat_id, actor_identity_id, 0);
    if (count <= 0) {
        connector.sendMessage(a, msg.chat_id, "You do not have enough tokens to perform this action", msg.message_id);
        return;
    }
    if (kind == .kick) {
        connector.kickUser(a, msg.chat_id, target.user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, msg.message_id, "kick", err);
            return;
        };
    } else if (kind == .ban) {
        connector.banUser(a, msg.chat_id, target.user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, msg.message_id, "ban", err);
            return;
        };
    }
    count -= 1;
    chat_members.setTokens(pool, chat_id, actor_identity_id, count) catch |err| {
        std.log.err("Could not update user's token count: {}", .{err});
    };
}

pub fn confirm(connector: iface.Connector, a: std.mem.Allocator, pending: *PendingConfirmations, now: i64, msg: iface.Message) void {
    const action = pending.take(now, msg.chat_id) orelse {
        connector.sendMessage(a, msg.chat_id, "Nothing to confirm.", msg.message_id);
        return;
    };
    switch (action.kind) {
        .ban => connector.banUser(a, msg.chat_id, action.target_user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, msg.message_id, "ban", err);
            return;
        },
        .kick => connector.kickUser(a, msg.chat_id, action.target_user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, msg.message_id, "kick", err);
            return;
        },
    }
    reply(connector, a, msg.chat_id, msg.message_id, "{s} {s}.", .{ actionVerbPast(action.kind), action.target_label });
}

pub fn cancel(connector: iface.Connector, a: std.mem.Allocator, pending: *PendingConfirmations, msg: iface.Message) void {
    pending.clear(msg.chat_id);
    connector.sendMessage(a, msg.chat_id, "Cancelled.", msg.message_id);
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

fn reportFailure(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, reply_to: ?[]const u8, action: []const u8, err: anyerror) void {
    std.log.err("group_admin: {s} failed: {t}", .{ action, err });
    if (err == error.Unsupported) {
        connector.sendMessage(a, chat_id, "That action isn't supported on this platform.", reply_to);
    } else {
        connector.sendMessage(a, chat_id, "That failed — check the bot is an admin in this group with the right permissions.", reply_to);
    }
}

fn reply(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, reply_to: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(a, fmt, args) catch return;
    connector.sendMessage(a, chat_id, text, reply_to);
}

const testing = std.testing;

test "PendingConfirmations set/take round trip and expiry" {
    var pending = PendingConfirmations.init(testing.allocator, testing.io, 60);
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
    var pending = PendingConfirmations.init(testing.allocator, testing.io, 60);
    defer pending.deinit();

    try pending.set(1000, "chat1", .kick, "42", "spammer");
    try testing.expect(pending.take(1000 + 61, "chat1") == null);
}

test "PendingConfirmations.set replaces an existing pending action for the same chat" {
    var pending = PendingConfirmations.init(testing.allocator, testing.io, 60);
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
