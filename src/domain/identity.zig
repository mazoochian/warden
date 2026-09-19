const std = @import("std");
const Platform = @import("../platform/interface.zig").Platform;

/// Shared fields every platform's user carries, regardless of which platform
/// they came from.
pub const Identity = struct {
    platform: Platform,
    /// The platform's own id for this user, as a string — Telegram.
    native_id: []const u8,
    /// Best available display name: Telegram first[+last] name, Matrix
    /// displayname, XMPP nickname.
    display_name: []const u8,
    /// Shared "handle" concept where the platform has one (Telegram
    /// @username, Matrix/XMPP don't always).
    username: ?[]const u8 = null,
    is_bot: bool = false,
    first_seen: i64,
    last_seen: i64,

    /// Deep-copies every string field into `allocator` — mirrors
    /// `iface.Message.dupe`, for the same reason.
    pub fn dupe(self: Identity, allocator: std.mem.Allocator) !Identity {
        return .{
            .platform = self.platform,
            .native_id = try allocator.dupe(u8, self.native_id),
            .display_name = try allocator.dupe(u8, self.display_name),
            .username = if (self.username) |s| try allocator.dupe(u8, s) else null,
            .is_bot = self.is_bot,
            .first_seen = self.first_seen,
            .last_seen = self.last_seen,
        };
    }
};

const testing = std.testing;

test "Identity holds shared fields regardless of platform" {
    const id = Identity{
        .platform = .telegram,
        .native_id = "42",
        .display_name = "Alice",
        .username = "alice",
        .is_bot = false,
        .first_seen = 1000,
        .last_seen = 2000,
    };
    try testing.expectEqual(Platform.telegram, id.platform);
    try testing.expectEqualStrings("42", id.native_id);
    try testing.expectEqualStrings("Alice", id.display_name);
    try testing.expectEqualStrings("alice", id.username.?);
}
