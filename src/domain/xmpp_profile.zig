const std = @import("std");
const Identity = @import("identity.zig").Identity;

/// XMPP-specific extension of `Identity`, populated by
/// `src/platform/xmpp.zig`'s `pollFn`. `jid_resource` is the resource part
/// of whichever full JID a message was addressed from — null for a MUC
/// message's synthetic room+nick sender, where the room's `identity.
/// native_id` already carries the nick as its "resource" (see
/// `platform/xmpp.zig`'s `messagesFromElement`).
pub const XmppProfile = struct {
    identity: Identity,
    jid_resource: ?[]const u8 = null,

    /// Deep-copies every string field (including nested `identity`) into
    /// `allocator` — see `Identity.dupe`.
    pub fn dupe(self: XmppProfile, allocator: std.mem.Allocator) !XmppProfile {
        return .{
            .identity = try self.identity.dupe(allocator),
            .jid_resource = if (self.jid_resource) |s| try allocator.dupe(u8, s) else null,
        };
    }
};

const testing = std.testing;

test "XmppProfile embeds Identity as its first field" {
    const profile = XmppProfile{
        .identity = .{
            .platform = .xmpp,
            .native_id = "alice@example.org",
            .display_name = "alice",
            .first_seen = 1000,
            .last_seen = 2000,
        },
        .jid_resource = "phone",
    };
    try testing.expectEqualStrings("alice@example.org", profile.identity.native_id);
    try testing.expectEqualStrings("phone", profile.jid_resource.?);
}

test "XmppProfile.dupe deep-copies into a new allocator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = XmppProfile{
        .identity = .{
            .platform = .xmpp,
            .native_id = try src_a.dupe(u8, "alice@example.org"),
            .display_name = try src_a.dupe(u8, "alice"),
            .first_seen = 1000,
            .last_seen = 2000,
        },
        .jid_resource = try src_a.dupe(u8, "phone"),
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.identity.native_id);
        testing.allocator.free(dst.identity.display_name);
        testing.allocator.free(dst.jid_resource.?);
    }

    arena.deinit();

    try testing.expectEqualStrings("alice@example.org", dst.identity.native_id);
    try testing.expectEqualStrings("phone", dst.jid_resource.?);
}

test "XmppProfile.dupe passes through a null jid_resource" {
    const src = XmppProfile{
        .identity = .{
            .platform = .xmpp,
            .native_id = "room@conference.example.org/nick",
            .display_name = "nick",
            .first_seen = 1000,
            .last_seen = 1000,
        },
    };
    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.identity.native_id);
        testing.allocator.free(dst.identity.display_name);
    }
    try testing.expectEqual(@as(?[]const u8, null), dst.jid_resource);
}
