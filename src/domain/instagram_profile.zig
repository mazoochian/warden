const std = @import("std");
const Identity = @import("identity.zig").Identity;

/// Instagram-specific extension of `Identity`, populated by
/// `src/platform/instagram.zig`'s poll loop. `full_name` is Instagram's
/// separate display-name field (distinct from `identity.username`, the
/// `@handle`); `is_private` reflects whether the account's posts are
/// visible to non-followers, which matters for `instagram/media.zig`'s
/// public-then-authenticated media-info fallback.
pub const InstagramProfile = struct {
    identity: Identity,
    full_name: ?[]const u8 = null,
    is_private: bool = false,

    /// Deep-copies every string field (including nested `identity`) into
    /// `allocator` — see `Identity.dupe`.
    pub fn dupe(self: InstagramProfile, allocator: std.mem.Allocator) !InstagramProfile {
        return .{
            .identity = try self.identity.dupe(allocator),
            .full_name = if (self.full_name) |s| try allocator.dupe(u8, s) else null,
            .is_private = self.is_private,
        };
    }
};

const testing = std.testing;

test "InstagramProfile embeds Identity as its first field" {
    const profile = InstagramProfile{
        .identity = .{
            .platform = .instagram,
            .native_id = "123456",
            .display_name = "alice",
            .first_seen = 1000,
            .last_seen = 2000,
        },
        .full_name = "Alice Example",
        .is_private = true,
    };
    try testing.expectEqualStrings("123456", profile.identity.native_id);
    try testing.expectEqualStrings("Alice Example", profile.full_name.?);
    try testing.expect(profile.is_private);
}

test "InstagramProfile.dupe deep-copies into a new allocator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = InstagramProfile{
        .identity = .{
            .platform = .instagram,
            .native_id = try src_a.dupe(u8, "123456"),
            .display_name = try src_a.dupe(u8, "alice"),
            .first_seen = 1000,
            .last_seen = 2000,
        },
        .full_name = try src_a.dupe(u8, "Alice Example"),
        .is_private = false,
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.identity.native_id);
        testing.allocator.free(dst.identity.display_name);
        testing.allocator.free(dst.full_name.?);
    }

    arena.deinit();

    try testing.expectEqualStrings("123456", dst.identity.native_id);
    try testing.expectEqualStrings("Alice Example", dst.full_name.?);
    try testing.expect(!dst.is_private);
}

test "InstagramProfile.dupe passes through a null full_name" {
    const src = InstagramProfile{
        .identity = .{
            .platform = .instagram,
            .native_id = "123456",
            .display_name = "alice",
            .first_seen = 1000,
            .last_seen = 1000,
        },
    };
    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.identity.native_id);
        testing.allocator.free(dst.identity.display_name);
    }
    try testing.expectEqual(@as(?[]const u8, null), dst.full_name);
}
