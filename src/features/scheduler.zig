const std = @import("std");
const Io = std.Io;

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

    pub fn enable(self: *DigestScheduler, chat_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.enabled_chats.contains(chat_id)) return;
        const key = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(key);
        try self.enabled_chats.put(key, {});
    }

    pub fn disable(self: *DigestScheduler, chat_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.enabled_chats.fetchRemove(chat_id)) |entry| self.allocator.free(entry.key);
    }

    pub fn isEnabled(self: *DigestScheduler, chat_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.enabled_chats.contains(chat_id);
    }

    /// Returns a snapshot of currently-enabled chat ids, duped into
    /// `allocator`. Iterating `enabled_chats` directly from outside would
    /// race with `enable`/`disable` running concurrently on another
    /// message-handling task; this is the safe way to walk the set.
    pub fn snapshotEnabledChatIds(self: *DigestScheduler, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| allocator.free(id);
            ids.deinit(allocator);
        }
        var it = self.enabled_chats.keyIterator();
        while (it.next()) |k| try ids.append(allocator, try allocator.dupe(u8, k.*));
        return ids.toOwnedSlice(allocator);
    }
};

const testing = std.testing;

test "enable/disable/isEnabled" {
    var sched = DigestScheduler.init(testing.allocator, testing.io, 86400);
    defer sched.deinit();

    try testing.expect(!sched.isEnabled("chat1"));
    try sched.enable("chat1");
    try testing.expect(sched.isEnabled("chat1"));
    // Enabling twice must not leak a second copy of the key.
    try sched.enable("chat1");
    try testing.expect(sched.isEnabled("chat1"));

    sched.disable("chat1");
    try testing.expect(!sched.isEnabled("chat1"));
    // Disabling something not present is a no-op, not an error.
    sched.disable("chat1");
}
