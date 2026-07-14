const std = @import("std");
const Platform = @import("../platform/interface.zig").Platform;

/// Shared fields every platform's user carries, regardless of which platform
/// they came from. Platform-specific structs (`TelegramProfile`,
/// `MatrixProfile`, `XmppProfile`) embed this as their first field rather than
/// inheriting from it — Zig has no class inheritance, so composition plus
/// reaching through `.identity.*` is the idiomatic stand-in for an "ancestor"
/// type here.
pub const Identity = struct {
    platform: Platform,
    /// The platform's own id for this user, as a string — Telegram: decimal
    /// i64; Matrix: "@user:server"; XMPP: bare JID; Discord: u64 snowflake;
    /// WhatsApp: phone number. Never parsed to a native int in shared code
    /// since the shape varies per platform (mirrors `iface.Message.user_id`).
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
    /// `iface.Message.dupe`, for the same reason: detaching from a
    /// short-lived poll-cycle arena into a per-task one.
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
