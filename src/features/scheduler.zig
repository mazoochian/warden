const std = @import("std");

/// Tracks which chats have opted into periodic digests. Interval-based
/// (every `interval_seconds` since that chat's last digest), not
/// wall-clock "at 9am" — a real timezone-aware scheduler needs a tz
/// database Zig's std lib doesn't ship, and this is a personal bot for one
/// owner, so "every ~24h" is a deliberate, simpler tradeoff over precise
/// local-time scheduling.
///
/// The enabled-chat set lives in memory (rebuilt at startup via
/// `ChatStore.listExistingChatIds` + each chat's persisted
/// `chat_settings.digest_enabled`), while the actual on/off state and
/// last-sent timestamp are persisted per-chat so they survive restarts.
pub const DigestScheduler = struct {
    allocator: std.mem.Allocator,
    enabled_chats: std.StringHashMap(void),
    interval_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, interval_seconds: i64) DigestScheduler {
        return .{
            .allocator = allocator,
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
        if (self.enabled_chats.contains(chat_id)) return;
        const key = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(key);
        try self.enabled_chats.put(key, {});
    }

    pub fn disable(self: *DigestScheduler, chat_id: []const u8) void {
        if (self.enabled_chats.fetchRemove(chat_id)) |entry| self.allocator.free(entry.key);
    }

    pub fn isEnabled(self: *DigestScheduler, chat_id: []const u8) bool {
        return self.enabled_chats.contains(chat_id);
    }
};

const testing = std.testing;

test "enable/disable/isEnabled" {
    var sched = DigestScheduler.init(testing.allocator, 86400);
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
