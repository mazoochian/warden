const std = @import("std");
const Io = std.Io;
const Platform = @import("../platform/interface.zig").Platform;

/// Tracks which chats have opted into periodic digests. Interval-based
/// (every `interval_seconds` since that chat's last digest), not
/// wall-clock "at 9am" — a real timezone-aware scheduler needs a tz
/// database Zig's std lib doesn't ship, and this is a personal bot for one
/// owner, so "every ~24h" is a deliberate, simpler tradeoff over precise
/// local-time scheduling.
///
/// The enabled-chat set lives in memory (rebuilt at startup via
/// `chats.listAll` + each chat's persisted `chat_settings.digest_enabled`),
/// while the actual on/off state and last-sent timestamp are persisted
/// per-chat so they survive restarts.
///
/// Accessed from concurrently-running per-message tasks (see `PgPool`'s
/// doc comment for why), so `enabled_chats` needs a lock.
pub const DigestScheduler = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Keyed by `compositeKey(platform, native_chat_id)`, not bare
    /// `native_chat_id` — two different platforms' chats can otherwise
    /// collide on the same native id string (e.g. a numeric-looking Matrix
    /// alias matching a Telegram chat id), and even where they can't, every
    /// chat still needs its platform recorded so `checkAndSendDueDigests`
    /// knows which connector to deliver through once more than one is
    /// active.
    enabled_chats: std.StringHashMap(void),
    mutex: Io.Mutex = .init,
    interval_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, interval_seconds: i64) DigestScheduler {
        return .{
            .allocator = allocator,
            .io = io,
            .enabled_chats = std.StringHashMap(void).init(allocator),
            .interval_seconds = interval_seconds,
        };
    }

    pub fn deinit(self: *DigestScheduler) void {
        var it = self.enabled_chats.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.enabled_chats.deinit();
    }

    /// `platform` tag plus native id, joined on a NUL byte — chosen over a
    /// human-readable separator like ":" since Matrix's own native ids
    /// already contain colons ("!room:server").
    fn compositeKey(allocator: std.mem.Allocator, platform: Platform, native_chat_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ @tagName(platform), native_chat_id });
    }

    pub fn enable(self: *DigestScheduler, platform: Platform, native_chat_id: []const u8) !void {
        const key = try compositeKey(self.allocator, platform, native_chat_id);
        errdefer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.enabled_chats.contains(key)) {
            self.allocator.free(key);
            return;
        }
        try self.enabled_chats.put(key, {});
    }

    pub fn disable(self: *DigestScheduler, allocator: std.mem.Allocator, platform: Platform, native_chat_id: []const u8) void {
        const key = compositeKey(allocator, platform, native_chat_id) catch return;
        defer allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.enabled_chats.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    pub fn isEnabled(self: *DigestScheduler, allocator: std.mem.Allocator, platform: Platform, native_chat_id: []const u8) bool {
        const key = compositeKey(allocator, platform, native_chat_id) catch return false;
        defer allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.enabled_chats.contains(key);
    }

    pub const ChatKey = struct { platform: Platform, native_chat_id: []const u8 };

    /// Returns a snapshot of currently-enabled chats, duped into
    /// `allocator`. Iterating `enabled_chats` directly from outside would
    /// race with `enable`/`disable` running concurrently on another
    /// message-handling task; this is the safe way to walk the set.
    pub fn snapshotEnabledChatIds(self: *DigestScheduler, allocator: std.mem.Allocator) ![]ChatKey {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(ChatKey) = .empty;
        errdefer {
            for (out.items) |k| allocator.free(k.native_chat_id);
            out.deinit(allocator);
        }
        var it = self.enabled_chats.keyIterator();
        while (it.next()) |k| {
            const sep = std.mem.indexOfScalar(u8, k.*, 0) orelse continue;
            const platform = std.meta.stringToEnum(Platform, k.*[0..sep]) orelse continue;
            try out.append(allocator, .{ .platform = platform, .native_chat_id = try allocator.dupe(u8, k.*[sep + 1 ..]) });
        }
        return out.toOwnedSlice(allocator);
    }
};

const testing = std.testing;

test "enable/disable/isEnabled" {
    var sched = DigestScheduler.init(testing.allocator, testing.io, 86400);
    defer sched.deinit();
    const a = testing.allocator;

    try testing.expect(!sched.isEnabled(a, .telegram, "chat1"));
    try sched.enable(.telegram, "chat1");
    try testing.expect(sched.isEnabled(a, .telegram, "chat1"));
    // Enabling twice must not leak a second copy of the key.
    try sched.enable(.telegram, "chat1");
    try testing.expect(sched.isEnabled(a, .telegram, "chat1"));

    sched.disable(a, .telegram, "chat1");
    try testing.expect(!sched.isEnabled(a, .telegram, "chat1"));
    // Disabling something not present is a no-op, not an error.
    sched.disable(a, .telegram, "chat1");
}

test "the same native chat id on two different platforms doesn't collide" {
    var sched = DigestScheduler.init(testing.allocator, testing.io, 86400);
    defer sched.deinit();
    const a = testing.allocator;

    try sched.enable(.telegram, "123");
    try testing.expect(!sched.isEnabled(a, .matrix, "123"));

    try sched.enable(.matrix, "123");
    try testing.expect(sched.isEnabled(a, .telegram, "123"));
    try testing.expect(sched.isEnabled(a, .matrix, "123"));

    sched.disable(a, .telegram, "123");
    try testing.expect(!sched.isEnabled(a, .telegram, "123"));
    try testing.expect(sched.isEnabled(a, .matrix, "123"));
}

test "snapshotEnabledChatIds recovers platform and native id from the composite key" {
    var sched = DigestScheduler.init(testing.allocator, testing.io, 86400);
    defer sched.deinit();
    const a = testing.allocator;

    try sched.enable(.telegram, "1");
    try sched.enable(.matrix, "!room:server");

    const snap = try sched.snapshotEnabledChatIds(a);
    defer {
        for (snap) |k| a.free(k.native_chat_id);
        a.free(snap);
    }
    try testing.expectEqual(@as(usize, 2), snap.len);
    for (snap) |k| {
        if (k.platform == .telegram) {
            try testing.expectEqualStrings("1", k.native_chat_id);
        } else {
            try testing.expectEqual(Platform.matrix, k.platform);
            try testing.expectEqualStrings("!room:server", k.native_chat_id);
        }
    }
}
