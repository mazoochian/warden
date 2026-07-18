const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");
const convert = @import("convert.zig");

/// A file has been claimed for conversion — the prompt's choices are kept
/// (owned copies) since Matrix's pick needs the original list to resolve a
/// reacted emoji back to a target format (see `resolveTargetFormat`).
pub const AwaitingFormat = struct {
    attachment_path: []const u8,
    attachment_file_name: ?[]const u8,
    prompt_message_id: []const u8,
    choices: []const iface.Choice,
};

pub const Stage = union(enum) {
    /// User expressed intent, no file yet.
    awaiting_file,
    /// File claimed, choice prompt sent, waiting for a pick.
    awaiting_format: AwaitingFormat,
};

const PendingEntry = struct {
    stage: Stage,
    expires_at: i64,
};

/// One pending conversion per (chat, user) — composite-key technique
/// (`DigestScheduler`'s, not `PendingConfirmations`' chat-only key), since
/// two different users converting files in the same group must not clobber
/// each other. Unlike `PendingConfirmations` (which owns no disk resource,
/// so lazy expiry-on-read was fine), an `awaiting_format` entry owns a real
/// downloaded temp file — that needs *proactive* expiry (`sweepExpired`) or
/// an abandoned entry leaks its file forever.
pub const PendingConversions = struct {
    allocator: std.mem.Allocator,
    io: Io,
    map: std.StringHashMap(PendingEntry),
    mutex: Io.Mutex = .init,
    timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, timeout_seconds: i64) PendingConversions {
        return .{
            .allocator = allocator,
            .io = io,
            .map = std.StringHashMap(PendingEntry).init(allocator),
            .timeout_seconds = timeout_seconds,
        };
    }

    pub fn deinit(self: *PendingConversions) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.freeEntryDeletingFile(entry.key_ptr.*, entry.value_ptr.*);
        self.map.deinit();
    }

    fn compositeKey(allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ chat_id, user_id });
    }

    /// Frees a removed map entry's key and (for `awaiting_format`) its
    /// claimed file on disk plus every owned field — the one place file
    /// deletion+deallocation happens, shared by `deinit`/`cancel`/`sweepExpired`.
    fn freeEntryDeletingFile(self: *PendingConversions, key: []const u8, entry: PendingEntry) void {
        self.allocator.free(key);
        switch (entry.stage) {
            .awaiting_file => {},
            .awaiting_format => |af| {
                Io.Dir.cwd().deleteFile(self.io, af.attachment_path) catch {};
                self.allocator.free(af.attachment_path);
                if (af.attachment_file_name) |n| self.allocator.free(n);
                self.allocator.free(af.prompt_message_id);
                for (af.choices) |c| {
                    self.allocator.free(c.emoji);
                    self.allocator.free(c.label);
                    self.allocator.free(c.value);
                }
                self.allocator.free(af.choices);
            },
        }
    }

    /// Starts (or restarts) the flow for (chat_id, user_id) — "send me a
    /// file." Replaces any existing pending entry for this (chat, user),
    /// deleting/freeing whatever it owned (e.g. an abandoned earlier
    /// attempt's claimed file).
    pub fn beginAwaitingFile(self: *PendingConversions, now: i64, chat_id: []const u8, user_id: []const u8) !void {
        const key = try compositeKey(self.allocator, chat_id, user_id);
        errdefer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.fetchRemove(key)) |old| self.freeEntryDeletingFile(old.key, old.value);
        try self.map.put(key, .{ .stage = .awaiting_file, .expires_at = now + self.timeout_seconds });
    }

    /// True if (chat_id, user_id) currently has an unexpired
    /// `awaiting_file` entry — read-only, doesn't consume it. Used by the
    /// dispatch-time "does this attachment belong to a pending flow" guard.
    pub fn isAwaitingFile(self: *PendingConversions, allocator: std.mem.Allocator, now: i64, chat_id: []const u8, user_id: []const u8) bool {
        const key = compositeKey(allocator, chat_id, user_id) catch return false;
        defer allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = self.map.get(key) orelse return false;
        if (now > entry.expires_at) return false;
        return switch (entry.stage) {
            .awaiting_file => true,
            .awaiting_format => false,
        };
    }

    /// Transitions `awaiting_file` -> `awaiting_format`, taking ownership
    /// of duped copies of everything passed in (the caller's originals
    /// typically live in a per-message arena that goes away when this
    /// task ends). Returns `false` (no-op, frees nothing new) if there
    /// wasn't actually an unexpired `awaiting_file` entry — a race is
    /// possible across concurrent per-message tasks for the same user, so
    /// callers must treat `false` as "someone else already claimed or
    /// canceled it," not an error.
    pub fn claimFile(
        self: *PendingConversions,
        allocator: std.mem.Allocator,
        now: i64,
        chat_id: []const u8,
        user_id: []const u8,
        attachment_path: []const u8,
        attachment_file_name: ?[]const u8,
        prompt_message_id: []const u8,
        choices: []const iface.Choice,
    ) !bool {
        const lookup_key = try compositeKey(allocator, chat_id, user_id);
        defer allocator.free(lookup_key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const current = self.map.get(lookup_key) orelse return false;
        if (now > current.expires_at) return false;
        switch (current.stage) {
            .awaiting_file => {},
            .awaiting_format => return false,
        }

        const owned_path = try self.allocator.dupe(u8, attachment_path);
        errdefer self.allocator.free(owned_path);
        const owned_name = if (attachment_file_name) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (owned_name) |n| self.allocator.free(n);
        const owned_prompt_id = try self.allocator.dupe(u8, prompt_message_id);
        errdefer self.allocator.free(owned_prompt_id);

        var owned_choices: std.ArrayList(iface.Choice) = .empty;
        errdefer {
            for (owned_choices.items) |c| {
                self.allocator.free(c.emoji);
                self.allocator.free(c.label);
                self.allocator.free(c.value);
            }
            owned_choices.deinit(self.allocator);
        }
        for (choices) |c| {
            const emoji = try self.allocator.dupe(u8, c.emoji);
            errdefer self.allocator.free(emoji);
            const label = try self.allocator.dupe(u8, c.label);
            errdefer self.allocator.free(label);
            const value = try self.allocator.dupe(u8, c.value);
            try owned_choices.append(self.allocator, .{ .emoji = emoji, .label = label, .value = value });
        }

        const old = self.map.fetchRemove(lookup_key).?;
        self.allocator.free(old.key);

        const stored_key = try compositeKey(self.allocator, chat_id, user_id);
        errdefer self.allocator.free(stored_key);
        try self.map.put(stored_key, .{
            .stage = .{ .awaiting_format = .{
                .attachment_path = owned_path,
                .attachment_file_name = owned_name,
                .prompt_message_id = owned_prompt_id,
                .choices = try owned_choices.toOwnedSlice(self.allocator),
            } },
            .expires_at = now + self.timeout_seconds,
        });
        return true;
    }

    /// Consumes an `awaiting_format` entry for (chat_id, user_id) if it
    /// exists, matches `prompt_message_id`, and hasn't expired — a stale
    /// pick (a superseded prompt, or one arriving after expiry) is a no-op
    /// (null), not an error. The caller takes ownership of the returned
    /// value's fields (and the file they name) and must free/delete them —
    /// via `self.allocator` for the strings, since that's what allocated
    /// them, not necessarily the caller's own allocator.
    pub fn takeAwaitingFormat(
        self: *PendingConversions,
        allocator: std.mem.Allocator,
        now: i64,
        chat_id: []const u8,
        user_id: []const u8,
        prompt_message_id: []const u8,
    ) ?AwaitingFormat {
        const key = compositeKey(allocator, chat_id, user_id) catch return null;
        defer allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = self.map.get(key) orelse return null;
        if (now > entry.expires_at) return null;
        const af = switch (entry.stage) {
            .awaiting_format => |af| af,
            .awaiting_file => return null,
        };
        if (!std.mem.eql(u8, af.prompt_message_id, prompt_message_id)) return null;

        const removed = self.map.fetchRemove(key).?;
        self.allocator.free(removed.key);
        return af;
    }

    /// Clears whatever's pending for (chat_id, user_id), regardless of
    /// stage, deleting any claimed file — used by `/cancel` and by
    /// `beginAwaitingFile` replacing a stale entry. Returns whether
    /// anything was actually pending.
    pub fn cancel(self: *PendingConversions, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) bool {
        const key = compositeKey(allocator, chat_id, user_id) catch return false;
        defer allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const removed = self.map.fetchRemove(key) orelse return false;
        self.freeEntryDeletingFile(removed.key, removed.value);
        return true;
    }

    /// Evicts every expired entry, deleting any claimed file — called once
    /// per main-loop iteration alongside `checkAndSendDueReminders` et al.
    pub fn sweepExpired(self: *PendingConversions, allocator: std.mem.Allocator, now: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var expired_keys: std.ArrayList([]const u8) = .empty;
        defer expired_keys.deinit(allocator);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (now > entry.value_ptr.expires_at) expired_keys.append(allocator, entry.key_ptr.*) catch continue;
        }
        for (expired_keys.items) |k| {
            const removed = self.map.fetchRemove(k) orelse continue;
            self.freeEntryDeletingFile(removed.key, removed.value);
        }
    }
};

/// Resolves a `ChoicePicked.value` back to a target format string, using
/// the choice list this specific prompt was built with. Telegram's value
/// already IS the target format (matched against `choice.value`, the
/// already-resolved `callback_data`); Matrix's value is the raw reaction
/// emoji (matched against `choice.emoji`) — see `iface.ChoicePicked`'s doc
/// comment for why this asymmetry is unavoidable.
pub fn resolveTargetFormat(platform: iface.Platform, choices: []const iface.Choice, picked_value: []const u8) ?[]const u8 {
    return switch (platform) {
        .telegram => blk: {
            for (choices) |c| if (std.mem.eql(u8, c.value, picked_value)) break :blk c.value;
            break :blk null;
        },
        .matrix => blk: {
            for (choices) |c| if (std.mem.eql(u8, c.emoji, picked_value)) break :blk c.value;
            break :blk null;
        },
        else => null,
    };
}

/// Distinct, ordered emoji used to label each format choice — index-based
/// rather than per-format, so "every supported format" (up to ~11 for
/// audio/video) doesn't need a hand-curated emoji per exact extension.
const choice_emoji = [_][]const u8{ "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣", "🔟", "🔢", "➕" };

fn emojiForIndex(i: usize) []const u8 {
    return choice_emoji[i % choice_emoji.len];
}

/// Edits `placeholder_id` to `text` if present, falling back to a plain
/// `sendMessage` on any edit failure or if no placeholder was ever sent —
/// same degrade convention as `replyWithAnswer`'s final-answer edit.
/// Shared by `main.zig`'s direct `/convert` command and this file's own
/// `handleChoicePicked`.
pub fn finalizePlaceholder(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, placeholder_id: ?[]const u8, reply_to: ?[]const u8, text: []const u8) void {
    if (placeholder_id) |pid| {
        if (connector.editMessage(a, chat_id, pid, text)) |_| return else |_| {}
    }
    connector.sendMessage(a, chat_id, text, reply_to);
}

/// Stage 1: bare `/convert` (or the `begin_file_conversion` LLM tool, which
/// calls `PendingConversions.beginAwaitingFile` directly instead of this —
/// see `tools/begin_conversion.zig`) with no attachment yet. Registers
/// `awaiting_file` and replies asking for a file.
pub fn beginConvertFlow(connector: iface.Connector, a: std.mem.Allocator, pending: *PendingConversions, now: i64, msg: iface.Message) void {
    pending.beginAwaitingFile(now, msg.chat_id, msg.user_id) catch |err| {
        std.log.err("convert_flow: failed to begin flow for chat {s}: {t}", .{ msg.chat_id, err });
        connector.sendMessage(a, msg.chat_id, "Couldn't start that, try again.", msg.message_id);
        return;
    };
    connector.sendMessage(a, msg.chat_id, "Send me the file you want to convert.", msg.message_id);
}

/// Stage 2: an attachment arrived while (chat, user) has a pending
/// `awaiting_file` entry. Builds the choice list via
/// `convert.candidateTargets`, sends the choice prompt, transitions to
/// `awaiting_format`. Returns whether the attachment was claimed — the
/// caller must not delete the file itself when this returns `true` (see
/// `main.zig`'s `processMessageTask` defer-skip).
pub fn claimAttachmentForConvert(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pending: *PendingConversions,
    now: i64,
    msg: iface.Message,
    attachment_path: []const u8,
    attachment_file_name: ?[]const u8,
) bool {
    const source_ext = convert.extensionOf(attachment_path);
    const targets = convert.candidateTargets(a, source_ext) catch |err| {
        std.log.err("convert_flow: failed to enumerate targets for {s}: {t}", .{ attachment_path, err });
        connector.sendMessage(a, msg.chat_id, "Couldn't figure out what to convert that file to — try /convert <format> as its caption instead.", msg.message_id);
        return false;
    };
    if (targets.len == 0) {
        connector.sendMessage(a, msg.chat_id, "I don't know how to convert that kind of file.", msg.message_id);
        return false;
    }

    var choices: std.ArrayList(iface.Choice) = .empty;
    for (targets, 0..) |t, i| {
        choices.append(a, .{ .emoji = emojiForIndex(i), .label = t, .value = t }) catch continue;
    }

    const prompt_id = (connector.sendChoicePrompt(a, msg.chat_id, "What format do you want to convert it to?", choices.items, msg.message_id) catch |err| {
        std.log.err("convert_flow: failed to send choice prompt for chat {s}: {t}", .{ msg.chat_id, err });
        connector.sendMessage(a, msg.chat_id, "Couldn't ask you that, try again.", msg.message_id);
        return false;
    }) orelse {
        // No prompt id means the platform has no button/reaction concept
        // (the wrapper already sent a plain-text fallback listing the
        // choices) — nothing to attach a later pick to, so don't claim the
        // file; point back at the one-shot caption command instead.
        connector.sendMessage(a, msg.chat_id, "This platform can't show pick-a-format prompts — send the file again with /convert <format> as its caption instead.", msg.message_id);
        return false;
    };

    const claimed = pending.claimFile(a, now, msg.chat_id, msg.user_id, attachment_path, attachment_file_name, prompt_id, choices.items) catch |err| {
        std.log.err("convert_flow: failed to claim file for chat {s}: {t}", .{ msg.chat_id, err });
        return false;
    };
    if (!claimed) {
        // Lost a race with another concurrent message for the same
        // (chat, user) — e.g. the flow was canceled or superseded between
        // the earlier `isAwaitingFile` check and now.
        connector.sendMessage(a, msg.chat_id, "That conversion request isn't active anymore.", msg.message_id);
    }
    return claimed;
}

/// Stage 3: a choice_picked message arrived. Resolves the format, runs the
/// conversion with a send-once/edit-once progress placeholder, sends the
/// result, and cleans up the pending entry (including deleting the claimed
/// temp file) regardless of outcome.
pub fn handleChoicePicked(
    connector: iface.Connector,
    a: std.mem.Allocator,
    io: Io,
    tmp_dir: []const u8,
    pending: *PendingConversions,
    now: i64,
    msg: iface.Message,
    picked: iface.ChoicePicked,
) void {
    const af = pending.takeAwaitingFormat(a, now, msg.chat_id, msg.user_id, picked.prompt_message_id) orelse {
        connector.sendMessage(a, msg.chat_id, "That conversion prompt isn't active anymore.", null);
        return;
    };
    defer {
        Io.Dir.cwd().deleteFile(io, af.attachment_path) catch {};
        pending.allocator.free(af.attachment_path);
        if (af.attachment_file_name) |n| pending.allocator.free(n);
        pending.allocator.free(af.prompt_message_id);
        for (af.choices) |c| {
            pending.allocator.free(c.emoji);
            pending.allocator.free(c.label);
            pending.allocator.free(c.value);
        }
        pending.allocator.free(af.choices);
    }

    const target_format = resolveTargetFormat(connector.platform(), af.choices, picked.value) orelse {
        connector.sendMessage(a, msg.chat_id, "Couldn't figure out which format you picked, try again.", null);
        return;
    };

    const placeholder_id = connector.sendMessageReturningId(a, msg.chat_id, "🔄 Converting your file…", null) catch |err| blk: {
        std.log.warn("convert_flow: couldn't send a placeholder for chat {s}: {t}", .{ msg.chat_id, err });
        break :blk null;
    };

    const result = convert.convert(a, io, tmp_dir, af.attachment_path, target_format) catch |err| {
        const text = switch (err) {
            error.UnsupportedTargetFormat => "That format isn't one I can produce.",
            error.UnsupportedConversion => "Can't convert between those two formats.",
            error.ConversionFailed => "The conversion failed — the file may be corrupt, unsupported, or in an unexpected format.",
            else => "Something went wrong converting that file, try again.",
        };
        finalizePlaceholder(connector, a, msg.chat_id, placeholder_id, null, text);
        return;
    };

    connector.sendDocument(a, msg.chat_id, result.bytes, result.file_name, null);
    const confirmation = std.fmt.allocPrint(a, "Converted to {s} and sent to the chat.", .{result.file_name}) catch "Converted and sent to the chat.";
    finalizePlaceholder(connector, a, msg.chat_id, placeholder_id, null, confirmation);
}

const testing = std.testing;

test "beginAwaitingFile then claimFile then takeAwaitingFormat round trip" {
    var pending = PendingConversions.init(testing.allocator, testing.io, 300);
    defer pending.deinit();
    const a = testing.allocator;

    try pending.beginAwaitingFile(1000, "chat1", "user1");
    try testing.expect(pending.isAwaitingFile(a, 1000, "chat1", "user1"));
    try testing.expect(!pending.isAwaitingFile(a, 1000, "chat1", "user2"));

    const choices = [_]iface.Choice{
        .{ .emoji = "1️⃣", .label = "png", .value = "png" },
        .{ .emoji = "2️⃣", .label = "jpg", .value = "jpg" },
    };
    try testing.expect(try pending.claimFile(a, 1000, "chat1", "user1", "/tmp/foo.png", "foo.png", "prompt1", &choices));
    try testing.expect(!pending.isAwaitingFile(a, 1000, "chat1", "user1"));

    // A stale prompt id doesn't match.
    try testing.expectEqual(@as(?AwaitingFormat, null), pending.takeAwaitingFormat(a, 1000, "chat1", "user1", "wrong-prompt"));

    const af = pending.takeAwaitingFormat(a, 1000, "chat1", "user1", "prompt1") orelse return error.TestExpectedValue;
    defer {
        pending.allocator.free(af.attachment_path);
        pending.allocator.free(af.attachment_file_name.?);
        pending.allocator.free(af.prompt_message_id);
        for (af.choices) |c| {
            pending.allocator.free(c.emoji);
            pending.allocator.free(c.label);
            pending.allocator.free(c.value);
        }
        pending.allocator.free(af.choices);
    }
    try testing.expectEqualStrings("/tmp/foo.png", af.attachment_path);
    try testing.expectEqual(@as(usize, 2), af.choices.len);

    // Already consumed: a second take finds nothing.
    try testing.expectEqual(@as(?AwaitingFormat, null), pending.takeAwaitingFormat(a, 1000, "chat1", "user1", "prompt1"));
}

test "claimFile fails when there's no pending awaiting_file entry" {
    var pending = PendingConversions.init(testing.allocator, testing.io, 300);
    defer pending.deinit();
    const a = testing.allocator;

    try testing.expect(!(try pending.claimFile(a, 1000, "chat1", "user1", "/tmp/x", null, "prompt1", &.{})));
}

test "cancel clears either stage and reports whether anything was pending" {
    var pending = PendingConversions.init(testing.allocator, testing.io, 300);
    defer pending.deinit();
    const a = testing.allocator;

    try testing.expect(!pending.cancel(a, "chat1", "user1"));

    try pending.beginAwaitingFile(1000, "chat1", "user1");
    try testing.expect(pending.cancel(a, "chat1", "user1"));
    try testing.expect(!pending.isAwaitingFile(a, 1000, "chat1", "user1"));
}

test "sweepExpired evicts only entries past their deadline" {
    var pending = PendingConversions.init(testing.allocator, testing.io, 300);
    defer pending.deinit();
    const a = testing.allocator;

    try pending.beginAwaitingFile(1000, "chat1", "user1");
    pending.sweepExpired(a, 1000 + 299);
    try testing.expect(pending.isAwaitingFile(a, 1000 + 299, "chat1", "user1"));

    pending.sweepExpired(a, 1000 + 301);
    try testing.expect(!pending.isAwaitingFile(a, 1000 + 301, "chat1", "user1"));
}

test "resolveTargetFormat matches Telegram by value and Matrix by emoji" {
    const choices = [_]iface.Choice{
        .{ .emoji = "1️⃣", .label = "png", .value = "png" },
        .{ .emoji = "2️⃣", .label = "jpg", .value = "jpg" },
    };
    try testing.expectEqualStrings("jpg", resolveTargetFormat(.telegram, &choices, "jpg").?);
    try testing.expectEqualStrings("png", resolveTargetFormat(.matrix, &choices, "1️⃣").?);
    try testing.expectEqual(@as(?[]const u8, null), resolveTargetFormat(.telegram, &choices, "2️⃣"));
}
