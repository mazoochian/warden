const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");
const store_pool = @import("../store/pool.zig");
const audit_notify = @import("audit_notify.zig");

pub const ActionKind = enum { ban, kick };

/// Bundles what `mute`/`unmute`/`promote`/`demote` need to log an audit
/// entry (Phase 20, ROADMAP.md) alongside the action itself — a small
/// struct rather than four more positional parameters on each function,
/// since each is already called from more than one site (the main dispatch
/// chain and `/menu`'s resume-awaiting-input path).
pub const AuditContext = struct {
    pool: *store_pool.PgPool,
    pending_undos: *audit_notify.PendingUndos,
    /// Warden's internal id for `msg.chat_id` — what `audit_notify`'s
    /// store-layer calls need (`chats.id`, not the platform-native id).
    chat_id: i64,
    actor_identity_id: i64,
    /// Cheap, no-DB-read actor label for the log line — `msg.username
    /// orelse msg.user_id` at the call site is enough; a resolved display
    /// name isn't worth an extra query here.
    actor_label: []const u8,
};

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

pub fn mute(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, now: i64, audit: AuditContext) void {
    const target = replyTarget(msg) orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to mute.", msg.message_id);
        return;
    };
    const until = now + default_mute_seconds;
    connector.muteUser(a, msg.chat_id, target.user_id, until) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "mute", err);
        return;
    };
    audit_notify.recordAndNotify(connector, a, audit.pool, audit.pending_undos, now, audit.chat_id, msg.chat_id, audit.actor_identity_id, audit.actor_label, .{ .mute = .{ .target_user_id = target.user_id, .target_label = target.label, .until_unix_time = until } });
    reply(connector, a, msg.chat_id, msg.message_id, "Muted {s} for 1 hour.", .{target.label});
}

pub fn unmute(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, now: i64, audit: AuditContext) void {
    const target = replyTarget(msg) orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to unmute.", msg.message_id);
        return;
    };
    connector.unmuteUser(a, msg.chat_id, target.user_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "unmute", err);
        return;
    };
    // Not undoable (see `audit_notify.AuditAction.undoable`'s doc comment)
    // -- logged for the record regardless.
    audit_notify.recordAndNotify(connector, a, audit.pool, audit.pending_undos, now, audit.chat_id, msg.chat_id, audit.actor_identity_id, audit.actor_label, .{ .unmute = .{ .target_user_id = target.user_id, .target_label = target.label } });
    reply(connector, a, msg.chat_id, msg.message_id, "Unmuted {s}.", .{target.label});
}

/// Grants real platform admin/moderator standing — unlike every other
/// command in this file, gated owner-only rather than open to any
/// existing chat admin (see `main.zig`'s dispatch: it checks
/// `auth.isOwner` directly here instead of `isAuthorizedForGroupAdmin`).
/// Deliberately immediate, no `/confirm` step — the owner is already
/// fully trusted for everything else, and a confirm step mainly guards
/// against a *different* admin acting rashly, which doesn't apply once
/// this is owner-only.
pub fn promote(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, now: i64, audit: AuditContext) void {
    const target = replyTarget(msg) orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to promote.", msg.message_id);
        return;
    };
    // Read before mutating -- this is the "before" state `audit_notify`
    // needs both to log accurately and to know whether an Undo (demote)
    // would actually reverse something (see `AuditAction.undoable`).
    const was_admin_before = connector.isGroupAdmin(a, msg.chat_id, target.user_id) catch false;
    connector.promoteUser(a, msg.chat_id, target.user_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "promote", err);
        return;
    };
    audit_notify.recordAndNotify(connector, a, audit.pool, audit.pending_undos, now, audit.chat_id, msg.chat_id, audit.actor_identity_id, audit.actor_label, .{ .promote = .{ .target_user_id = target.user_id, .target_label = target.label, .was_admin_before = was_admin_before } });
    reply(connector, a, msg.chat_id, msg.message_id, "Promoted {s} to admin.", .{target.label});
}

pub fn demote(connector: iface.Connector, a: std.mem.Allocator, msg: iface.Message, now: i64, audit: AuditContext) void {
    const target = replyTarget(msg) orelse {
        connector.sendMessage(a, msg.chat_id, "Reply to the message of the person you want to demote.", msg.message_id);
        return;
    };
    const was_admin_before = connector.isGroupAdmin(a, msg.chat_id, target.user_id) catch true;
    connector.demoteUser(a, msg.chat_id, target.user_id) catch |err| {
        reportFailure(connector, a, msg.chat_id, msg.message_id, "demote", err);
        return;
    };
    audit_notify.recordAndNotify(connector, a, audit.pool, audit.pending_undos, now, audit.chat_id, msg.chat_id, audit.actor_identity_id, audit.actor_label, .{ .demote = .{ .target_user_id = target.user_id, .target_label = target.label, .was_admin_before = was_admin_before } });
    reply(connector, a, msg.chat_id, msg.message_id, "Demoted {s}.", .{target.label});
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

/// Runs the ban/kick action immediately against `target_user_id` — a native
/// platform id the caller has already resolved (reply target, `@username`,
/// or a raw id; see `main.zig`'s `resolveTargetIdentity`/
/// `handleKickBanCommand`). Targeting used to be this function's own job,
/// hardcoded to `replyTarget(msg)` alone — the bug that made `/kick
/// @username` and `/kick <user_id>` silently do nothing (no dispatch branch
/// even matched them; see `handleMessage`'s old exact-`eql` match). Resolving
/// the target is now entirely the caller's job, same division as
/// permission: (owner / sudo bot admin / live platform admin / spend-a-token
/// fallback) is checked once by `main.zig` via `auth.checkGroupAdminAccess`
/// before this ever runs, and this function no longer touches the database
/// at all.
pub fn requestConfirmation(
    connector: iface.Connector,
    a: std.mem.Allocator,
    msg: iface.Message,
    kind: ActionKind,
    target_user_id: []const u8,
    target_label: []const u8,
    now: i64,
    audit: AuditContext,
) void {
    if (kind == .kick) {
        connector.kickUser(a, msg.chat_id, target_user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, msg.message_id, "kick", err);
            return;
        };
        audit_notify.recordAndNotify(connector, a, audit.pool, audit.pending_undos, now, audit.chat_id, msg.chat_id, audit.actor_identity_id, audit.actor_label, .{ .kick = .{ .target_user_id = target_user_id, .target_label = target_label } });
    } else if (kind == .ban) {
        connector.banUser(a, msg.chat_id, target_user_id) catch |err| {
            reportFailure(connector, a, msg.chat_id, msg.message_id, "ban", err);
            return;
        };
        audit_notify.recordAndNotify(connector, a, audit.pool, audit.pending_undos, now, audit.chat_id, msg.chat_id, audit.actor_identity_id, audit.actor_label, .{ .ban = .{ .target_user_id = target_user_id, .target_label = target_label } });
    }
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
