const std = @import("std");
const Identity = @import("identity.zig").Identity;

/// Matrix-specific extension of `Identity`, populated by
/// `src/platform/matrix.zig`'s `pollFn`. `avatar_url` stays null for now —
/// Matrix event content doesn't carry the sender's avatar directly, and
/// resolving it needs an extra `/profile/{userId}` call `matrix/client.zig`
/// doesn't implement yet.
pub const MatrixProfile = struct {
    identity: Identity,
    homeserver: []const u8 = "",
    avatar_url: ?[]const u8 = null,

    /// Deep-copies every string field (including nested `identity`) into
    /// `allocator` — see `Identity.dupe`.
    pub fn dupe(self: MatrixProfile, allocator: std.mem.Allocator) !MatrixProfile {
        return .{
            .identity = try self.identity.dupe(allocator),
            .homeserver = try allocator.dupe(u8, self.homeserver),
            .avatar_url = if (self.avatar_url) |s| try allocator.dupe(u8, s) else null,
        };
    }
};

const testing = std.testing;

test "MatrixProfile embeds Identity as its first field" {
    const profile = MatrixProfile{
        .identity = .{
            .platform = .matrix,
            .native_id = "@alice:example.org",
            .display_name = "Alice",
            .first_seen = 1000,
            .last_seen = 2000,
        },
        .homeserver = "https://example.org",
    };
    try testing.expectEqualStrings("@alice:example.org", profile.identity.native_id);
    try testing.expectEqualStrings("https://example.org", profile.homeserver);
    try testing.expectEqual(@as(?[]const u8, null), profile.avatar_url);
}

test "MatrixProfile.dupe deep-copies into a new allocator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = MatrixProfile{
        .identity = .{
            .platform = .matrix,
            .native_id = try src_a.dupe(u8, "@alice:example.org"),
            .display_name = try src_a.dupe(u8, "Alice"),
            .first_seen = 1000,
            .last_seen = 2000,
        },
        .homeserver = try src_a.dupe(u8, "https://example.org"),
        .avatar_url = try src_a.dupe(u8, "mxc://example.org/abc"),
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.identity.native_id);
        testing.allocator.free(dst.identity.display_name);
        testing.allocator.free(dst.homeserver);
        testing.allocator.free(dst.avatar_url.?);
    }

    arena.deinit();

    try testing.expectEqualStrings("@alice:example.org", dst.identity.native_id);
    try testing.expectEqualStrings("https://example.org", dst.homeserver);
    try testing.expectEqualStrings("mxc://example.org/abc", dst.avatar_url.?);
}
