//! Every managerial action against a chat that has a bound management room
//! posts a structured log entry there — actor, action, before/after state,
//! and, for actions with a clean inverse, an "Undo" button. The persistent
//! `audit_log` row is written whether or not a room is bound.
const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");
const store_pool = @import("../store/pool.zig");
const management_rooms = @import("../store/management_rooms.zig");
const audit_log = @import("../store/audit_log.zig");
const identities = @import("../store/identities.zig");

const log = std.log.scoped(.audit_notify);

/// The value carried on the "Undo" button's `Choice`.
const undo_choice_value = "audit_undo";

pub const AuditAction = union(enum) {
    mute: struct { target_user_id: []const u8, target_label: []const u8, until_unix_time: i64 },
    unmute: struct { target_user_id: []const u8, target_label: []const u8 },
    promote: struct { target_user_id: []const u8, target_label: []const u8, was_admin_before: bool },
    demote: struct { target_user_id: []const u8, target_label: []const u8, was_admin_before: bool },
    kick: struct { target_user_id: []const u8, target_label: []const u8 },
    ban: struct { target_user_id: []const u8, target_label: []const u8 },
    /// None of these three act on a *member*, so there's no `target_user_id`;
    /// `new_*`/`removed` doubles as the audit-log "target" text.
    title_change: struct { new_title: []const u8 },
    description_change: struct { new_description: []const u8 },
    photo_change: struct { removed: bool },

    fn actionName(self: AuditAction) []const u8 {
        return switch (self) {
            .mute => "chat.action.mute",
            .unmute => "chat.action.unmute",
            .promote => "chat.action.promote",
            .demote => "chat.action.demote",
            .kick => "chat.action.kick",
            .ban => "chat.action.ban",
            .title_change => "chat.action.title",
            .description_change => "chat.action.description",
            .photo_change => "chat.action.photo",
        };
    }

    fn titleText(self: AuditAction) []const u8 {
        return switch (self) {
            .mute => "Muted",
            .unmute => "Unmuted",
            .promote => "Promoted",
            .demote => "Demoted",
            .kick => "Kicked",
            .ban => "Banned",
            .title_change => "Title changed",
            .description_change => "Description changed",
            .photo_change => |p| if (p.removed) "Photo removed" else "Photo changed",
        };
    }

    fn targetLabel(self: AuditAction) []const u8 {
        return switch (self) {
            .mute => |x| x.target_label,
            .unmute => |x| x.target_label,
            .promote => |x| x.target_label,
            .demote => |x| x.target_label,
            .kick => |x| x.target_label,
            .ban => |x| x.target_label,
            .title_change => |x| x.new_title,
            .description_change => |x| x.new_description,
            .photo_change => |x| if (x.removed) "removed" else "changed",
        };
    }

    fn undoable(self: AuditAction) bool {
        return switch (self) {
            .mute => true,
            .promote => |p| !p.was_admin_before,
            .demote => |d| d.was_admin_before,
            .unmute, .kick, .ban, .title_change, .description_change, .photo_change => false,
        };
    }
};

fn dupeAction(a: std.mem.Allocator, action: AuditAction) !AuditAction {
    return switch (action) {
        .mute => |m| .{ .mute = .{ .target_user_id = try a.dupe(u8, m.target_user_id), .target_label = try a.dupe(u8, m.target_label), .until_unix_time = m.until_unix_time } },
        .unmute => |m| .{ .unmute = .{ .target_user_id = try a.dupe(u8, m.target_user_id), .target_label = try a.dupe(u8, m.target_label) } },
        .promote => |m| .{ .promote = .{ .target_user_id = try a.dupe(u8, m.target_user_id), .target_label = try a.dupe(u8, m.target_label), .was_admin_before = m.was_admin_before } },
        .demote => |m| .{ .demote = .{ .target_user_id = try a.dupe(u8, m.target_user_id), .target_label = try a.dupe(u8, m.target_label), .was_admin_before = m.was_admin_before } },
        .kick => |m| .{ .kick = .{ .target_user_id = try a.dupe(u8, m.target_user_id), .target_label = try a.dupe(u8, m.target_label) } },
        .ban => |m| .{ .ban = .{ .target_user_id = try a.dupe(u8, m.target_user_id), .target_label = try a.dupe(u8, m.target_label) } },
        .title_change => |m| .{ .title_change = .{ .new_title = try a.dupe(u8, m.new_title) } },
        .description_change => |m| .{ .description_change = .{ .new_description = try a.dupe(u8, m.new_description) } },
        .photo_change => |m| .{ .photo_change = .{ .removed = m.removed } },
    };
}

fn freeAction(a: std.mem.Allocator, action: AuditAction) void {
    switch (action) {
        .mute => |m| {
            a.free(m.target_user_id);
            a.free(m.target_label);
        },
        .unmute => |m| {
            a.free(m.target_user_id);
            a.free(m.target_label);
        },
        .promote => |m| {
            a.free(m.target_user_id);
            a.free(m.target_label);
        },
        .demote => |m| {
            a.free(m.target_user_id);
            a.free(m.target_label);
        },
        .kick => |m| {
            a.free(m.target_user_id);
            a.free(m.target_label);
        },
        .ban => |m| {
            a.free(m.target_user_id);
            a.free(m.target_label);
        },
        .title_change => |m| a.free(m.new_title),
        .description_change => |m| a.free(m.new_description),
        .photo_change => {},
    }
}

/// Builds the message text posted into the bound room — actor, action title,
/// and whatever before/after detail that `AuditAction` variant carries.
fn formatLogText(a: std.mem.Allocator, actor_label: []const u8, action: AuditAction) []const u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    buf.writer.print("🛡️ {s}\nBy: {s}\n", .{ action.titleText(), actor_label }) catch {};
    switch (action) {
        .mute => |m| buf.writer.print("Target: {s}\nMuted until (unix): {d}", .{ m.target_label, m.until_unix_time }) catch {},
        .unmute => |m| buf.writer.print("Target: {s}", .{m.target_label}) catch {},
        .promote => |m| buf.writer.print("Target: {s}\nWas admin before: {s}", .{ m.target_label, if (m.was_admin_before) "yes" else "no" }) catch {},
        .demote => |m| buf.writer.print("Target: {s}\nWas admin before: {s}", .{ m.target_label, if (m.was_admin_before) "yes" else "no" }) catch {},
        .kick => |m| buf.writer.print("Target: {s}", .{m.target_label}) catch {},
        .ban => |m| buf.writer.print("Target: {s}", .{m.target_label}) catch {},
        .title_change => |m| buf.writer.print("New title: {s}", .{m.new_title}) catch {},
        .description_change => |m| buf.writer.print("New description: {s}", .{m.new_description}) catch {},
        .photo_change => {},
    }
    return buf.writer.buffered();
}

const UndoEntry = struct {
    target_chat_id: i64,
    target_native_chat_id: []const u8,
    actor_identity_id: i64,
    actor_label: []const u8,
    action: AuditAction,
    expires_at: i64,
};

/// In-memory, one entry per (control room, prompt message).
pub const PendingUndos = struct {
    allocator: std.mem.Allocator,
    io: Io,
    map: std.StringHashMap(UndoEntry),
    mutex: Io.Mutex = .init,
    timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, timeout_seconds: i64) PendingUndos {
        return .{
            .allocator = allocator,
            .io = io,
            .map = std.StringHashMap(UndoEntry).init(allocator),
            .timeout_seconds = timeout_seconds,
        };
    }

    pub fn deinit(self: *PendingUndos) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.freeEntry(entry.key_ptr.*, entry.value_ptr.*);
        self.map.deinit();
    }

    fn freeEntry(self: *PendingUndos, key: []const u8, entry: UndoEntry) void {
        self.allocator.free(key);
        self.allocator.free(entry.target_native_chat_id);
        self.allocator.free(entry.actor_label);
        freeAction(self.allocator, entry.action);
    }

    fn makeKey(allocator: std.mem.Allocator, control_native_chat_id: []const u8, prompt_message_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ control_native_chat_id, prompt_message_id });
    }

    pub fn set(
        self: *PendingUndos,
        now: i64,
        control_native_chat_id: []const u8,
        prompt_message_id: []const u8,
        target_chat_id: i64,
        target_native_chat_id: []const u8,
        actor_identity_id: i64,
        actor_label: []const u8,
        action: AuditAction,
    ) !void {
        const owned_action = try dupeAction(self.allocator, action);
        errdefer freeAction(self.allocator, owned_action);
        const owned_native = try self.allocator.dupe(u8, target_native_chat_id);
        errdefer self.allocator.free(owned_native);
        const owned_label = try self.allocator.dupe(u8, actor_label);
        errdefer self.allocator.free(owned_label);
        const map_key = try makeKey(self.allocator, control_native_chat_id, prompt_message_id);
        errdefer self.allocator.free(map_key);

        const entry = UndoEntry{
            .target_chat_id = target_chat_id,
            .target_native_chat_id = owned_native,
            .actor_identity_id = actor_identity_id,
            .actor_label = owned_label,
            .action = owned_action,
            .expires_at = now + self.timeout_seconds,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.fetchRemove(map_key)) |old| self.freeEntry(old.key, old.value);
        try self.map.put(map_key, entry);
    }

    /// Removes and returns the pending undo for this (room, prompt) pair, if one
    /// exists and hasn't expired — one-shot, same as `PendingConfirmations.take`.
    pub fn take(self: *PendingUndos, now: i64, control_native_chat_id: []const u8, prompt_message_id: []const u8) ?UndoEntry {
        const map_key = makeKey(self.allocator, control_native_chat_id, prompt_message_id) catch return null;
        defer self.allocator.free(map_key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.map.fetchRemove(map_key) orelse return null;
        defer self.freeEntry(found.key, found.value);

        if (now > found.value.expires_at) return null;
        return .{
            .target_chat_id = found.value.target_chat_id,
            .target_native_chat_id = self.allocator.dupe(u8, found.value.target_native_chat_id) catch return null,
            .actor_identity_id = found.value.actor_identity_id,
            .actor_label = self.allocator.dupe(u8, found.value.actor_label) catch return null,
            .action = dupeAction(self.allocator, found.value.action) catch return null,
            .expires_at = found.value.expires_at,
        };
    }
};

/// Writes the permanent `audit_log` row (always, regardless of whether a room
/// is bound) and.
pub fn recordAndNotify(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    pending_undos: *PendingUndos,
    now: i64,
    target_chat_id: i64,
    target_native_chat_id: []const u8,
    actor_identity_id: i64,
    actor_label: []const u8,
    action: AuditAction,
) void {
    audit_log.record(pool, null, actor_identity_id, action.actionName(), action.targetLabel(), null);

    const room = (management_rooms.getBoundRoom(pool, a, target_chat_id) catch |err| {
        log.err("getBoundRoom failed for chat {d}: {t}", .{ target_chat_id, err });
        return;
    }) orelse return;
    defer a.free(room.native_chat_id);

    const text = formatLogText(a, actor_label, action);

    if (action.undoable()) {
        const choices = [_]iface.Choice{.{ .emoji = "\xe2\x86\xa9\xef\xb8\x8f", .label = "Undo", .value = undo_choice_value }};
        const prompt_id = connector.sendChoicePrompt(a, room.native_chat_id, text, &choices, null) catch |err| {
            log.warn("sendChoicePrompt failed for room #{d}, action not undoable from there: {t}", .{ room.id, err });
            return;
        };
        if (prompt_id) |pid| {
            pending_undos.set(now, room.native_chat_id, pid, target_chat_id, target_native_chat_id, actor_identity_id, actor_label, action) catch |err| {
                log.err("failed to remember undo state for room #{d}: {t}", .{ room.id, err });
            };
        }
        // `prompt_id == null` means the platform has no choice-prompt support (e.g.
        // XMPP).
        return;
    }

    connector.sendMessage(a, room.native_chat_id, text, null);
}

fn applyUndo(connector: iface.Connector, a: std.mem.Allocator, entry: UndoEntry) !void {
    switch (entry.action) {
        .mute => |m| try connector.unmuteUser(a, entry.target_native_chat_id, m.target_user_id),
        .promote => |p| {
            if (p.was_admin_before) return error.NothingToUndo;
            try connector.demoteUser(a, entry.target_native_chat_id, p.target_user_id);
        },
        .demote => |d| {
            if (!d.was_admin_before) return error.NothingToUndo;
            try connector.promoteUser(a, entry.target_native_chat_id, d.target_user_id);
        },
        .unmute, .kick, .ban, .title_change, .description_change, .photo_change => return error.NotUndoable,
    }
}

/// Consumes a `ChoicePicked` arriving in a bound room, if (and only if) it is
/// a pick of this module's own "Undo" button on a still-live prompt.
pub fn handleUndoPicked(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pending_undos: *PendingUndos,
    now: i64,
    msg: iface.Message,
    picked: iface.ChoicePicked,
) bool {
    if (!std.mem.eql(u8, picked.value, undo_choice_value)) return false;
    const entry = pending_undos.take(now, msg.chat_id, picked.prompt_message_id) orelse return false;
    defer {
        a.free(entry.target_native_chat_id);
        a.free(entry.actor_label);
        freeAction(a, entry.action);
    }

    applyUndo(connector, a, entry) catch |err| {
        log.err("undo failed: {t}", .{err});
        connector.sendMessage(a, msg.chat_id, "Couldn't undo that — it may need to be reverted manually.", msg.message_id);
        return true;
    };

    connector.sendMessage(a, msg.chat_id, "Undone.", msg.message_id);
    return true;
}

const testing = std.testing;
const test_support = @import("../store/test_support.zig");
const chats = @import("../store/chats.zig");

test "PendingUndos set/take round trip and expiry" {
    var pending = PendingUndos.init(testing.allocator, testing.io, 60);
    defer pending.deinit();

    try pending.set(1000, "control-room", "prompt-1", 7, "target-native", 42, "alice", .{ .mute = .{ .target_user_id = "9", .target_label = "bob", .until_unix_time = 5000 } });

    const taken = pending.take(1010, "control-room", "prompt-1").?;
    defer {
        testing.allocator.free(taken.target_native_chat_id);
        testing.allocator.free(taken.actor_label);
        freeAction(testing.allocator, taken.action);
    }
    try testing.expectEqual(@as(i64, 7), taken.target_chat_id);
    try testing.expectEqualStrings("target-native", taken.target_native_chat_id);
    try testing.expectEqualStrings("alice", taken.actor_label);
    try testing.expectEqualStrings("bob", taken.action.mute.target_label);

    // One-shot: a second take() finds nothing.
    try testing.expect(pending.take(1010, "control-room", "prompt-1") == null);
}

test "PendingUndos expires old entries, and different prompts in the same room don't collide" {
    var pending = PendingUndos.init(testing.allocator, testing.io, 60);
    defer pending.deinit();

    try pending.set(1000, "control-room", "prompt-1", 7, "target-a", 1, "alice", .{ .kick = .{ .target_user_id = "1", .target_label = "x" } });
    try pending.set(1000, "control-room", "prompt-2", 8, "target-b", 1, "alice", .{ .kick = .{ .target_user_id = "2", .target_label = "y" } });

    try testing.expect(pending.take(1000 + 61, "control-room", "prompt-1") == null);

    const still_live = pending.take(1000, "control-room", "prompt-2").?;
    defer {
        testing.allocator.free(still_live.target_native_chat_id);
        testing.allocator.free(still_live.actor_label);
        freeAction(testing.allocator, still_live.action);
    }
    try testing.expectEqualStrings("target-b", still_live.target_native_chat_id);
}

test "AuditAction.undoable reflects the documented scope" {
    try testing.expect((AuditAction{ .mute = .{ .target_user_id = "1", .target_label = "x", .until_unix_time = 0 } }).undoable());
    try testing.expect(!(AuditAction{ .unmute = .{ .target_user_id = "1", .target_label = "x" } }).undoable());
    try testing.expect(!(AuditAction{ .kick = .{ .target_user_id = "1", .target_label = "x" } }).undoable());
    try testing.expect(!(AuditAction{ .ban = .{ .target_user_id = "1", .target_label = "x" } }).undoable());
    try testing.expect((AuditAction{ .promote = .{ .target_user_id = "1", .target_label = "x", .was_admin_before = false } }).undoable());
    try testing.expect(!(AuditAction{ .promote = .{ .target_user_id = "1", .target_label = "x", .was_admin_before = true } }).undoable());
    try testing.expect((AuditAction{ .demote = .{ .target_user_id = "1", .target_label = "x", .was_admin_before = true } }).undoable());
    try testing.expect(!(AuditAction{ .demote = .{ .target_user_id = "1", .target_label = "x", .was_admin_before = false } }).undoable());
}

/// Minimal fake connector for `recordAndNotify`/`handleUndoPicked` tests —
/// records calls and hands back a fixed prompt id from `sendChoicePrompt`.
const FakeConnector = struct {
    const Call = struct { kind: []const u8, chat_id: []const u8, arg: []const u8 };

    calls: std.ArrayList(Call) = .empty,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator = undefined,
    next_prompt_id: []const u8 = "prompt-1",

    fn init(allocator: std.mem.Allocator) FakeConnector {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *FakeConnector) void {
        self.calls.deinit(self.allocator);
        self.arena.deinit();
    }

    fn record(self: *FakeConnector, kind: []const u8, chat_id: []const u8, arg: []const u8) void {
        const a = self.arena.allocator();
        self.calls.append(self.allocator, .{
            .kind = a.dupe(u8, kind) catch kind,
            .chat_id = a.dupe(u8, chat_id) catch chat_id,
            .arg = a.dupe(u8, arg) catch arg,
        }) catch {};
    }

    fn connector(self: *FakeConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendChoicePrompt = sendChoicePromptFn,
        .unmuteUser = unmuteUserFn,
        .promoteUser = promoteUserFn,
        .demoteUser = demoteUserFn,
    };

    fn self_(ptr: *anyopaque) *FakeConnector {
        return @ptrCast(@alignCast(ptr));
    }
    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram;
    }
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }
    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = allocator;
        _ = reply_to_message_id;
        self_(ptr).record("sendMessage", chat_id, text);
    }
    fn sendChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const iface.Choice, reply_to_message_id: ?[]const u8) anyerror!?[]const u8 {
        _ = allocator;
        _ = choices;
        _ = reply_to_message_id;
        const self = self_(ptr);
        self.record("sendChoicePrompt", chat_id, text);
        return self.next_prompt_id;
    }
    fn unmuteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        _ = allocator;
        self_(ptr).record("unmuteUser", chat_id, user_id);
    }
    fn promoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        _ = allocator;
        self_(ptr).record("promoteUser", chat_id, user_id);
    }
    fn demoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        _ = allocator;
        self_(ptr).record("demoteUser", chat_id, user_id);
    }
};

test "recordAndNotify writes an audit_log row unconditionally, and posts+registers an undo prompt only when a room is bound" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    // `recordAndNotify` frees its own temporary buffers (the resolved room, the
    // formatted text) via `defer` before returning.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unbound_target = try chats.upsertChat(&pool, .telegram, "unbound-target", null, null);
    const bound_target = try chats.upsertChat(&pool, .telegram, "bound-target", null, null);
    const control = try chats.upsertChat(&pool, .telegram, "control-native", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    try management_rooms.bind(&pool, control, bound_target, identity_id);

    var pending = PendingUndos.init(a, testing.io, 60);
    defer pending.deinit();

    var fake = FakeConnector.init(a);
    defer fake.deinit();

    // No room bound to `unbound_target` — no message sent, but the audit
    // row is still written.
    recordAndNotify(fake.connector(), a, &pool, &pending, 1000, unbound_target, "unbound-target", identity_id, "alice", .{ .kick = .{ .target_user_id = "9", .target_label = "spammer" } });
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);

    // Bound + undoable action -> a choice prompt lands in the control
    // room's native chat id, and the undo state is registered under it.
    recordAndNotify(fake.connector(), a, &pool, &pending, 1000, bound_target, "bound-target", identity_id, "alice", .{ .mute = .{ .target_user_id = "5", .target_label = "chatty", .until_unix_time = 5000 } });
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try testing.expectEqualStrings("sendChoicePrompt", fake.calls.items[0].kind);
    try testing.expectEqualStrings("control-native", fake.calls.items[0].chat_id);

    const entries = try audit_log.list(&pool, a, null, null, 10);
    defer {
        for (entries) |e| {
            a.free(e.action);
            if (e.target) |t| a.free(t);
        }
        a.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "handleUndoPicked applies the inverse action and consumes the pending entry" {
    const a = testing.allocator;

    var pending = PendingUndos.init(a, testing.io, 60);
    defer pending.deinit();
    var fake = FakeConnector.init(a);
    defer fake.deinit();

    try pending.set(1000, "control-native", "prompt-1", 7, "target-native", 1, "alice", .{ .mute = .{ .target_user_id = "5", .target_label = "chatty", .until_unix_time = 5000 } });

    const msg = iface.Message{ .chat_id = "control-native", .user_id = "1", .message_id = "op-msg" };
    const picked = iface.ChoicePicked{ .prompt_message_id = "prompt-1", .value = undo_choice_value };

    try testing.expect(handleUndoPicked(fake.connector(), a, &pending, 1010, msg, picked));

    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try testing.expectEqualStrings("unmuteUser", fake.calls.items[0].kind);
    try testing.expectEqualStrings("target-native", fake.calls.items[0].chat_id);
    try testing.expectEqualStrings("5", fake.calls.items[0].arg);
    try testing.expectEqualStrings("sendMessage", fake.calls.items[1].kind);

    // One-shot: the pending entry was consumed, so a second pick is a no-op.
    try testing.expect(!handleUndoPicked(fake.connector(), a, &pending, 1010, msg, picked));
}

test "handleUndoPicked returns false for a pick that isn't this module's own undo button" {
    var pending = PendingUndos.init(testing.allocator, testing.io, 60);
    defer pending.deinit();
    var fake = FakeConnector.init(testing.allocator);
    defer fake.deinit();

    const msg = iface.Message{ .chat_id = "chat", .user_id = "1" };
    const picked = iface.ChoicePicked{ .prompt_message_id = "prompt-1", .value = "some_other_flow" };
    try testing.expect(!handleUndoPicked(fake.connector(), testing.allocator, &pending, 1000, msg, picked));
}

const PgPool = store_pool.PgPool;
