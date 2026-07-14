const std = @import("std");
const Identity = @import("identity.zig").Identity;

/// Telegram-specific extension of `Identity` — fields the Bot API's `User`
/// object carries that no other platform has an equivalent of. Embeds
/// `identity` as its first field rather than inheriting from it (see
/// `identity.zig`'s doc comment).
pub const TelegramProfile = struct {
    identity: Identity,
    /// Telegram's raw `first_name` field — kept distinct from
    /// `identity.display_name` (which combines first+last into one "best
    /// display string" for platform-neutral consumers) since the
    /// `telegram_profiles` table mirrors the Bot API's `User` object shape
    /// directly.
    first_name: []const u8 = "",
    last_name: ?[]const u8 = null,
    language_code: ?[]const u8 = null,
    is_premium: bool = false,
    added_to_attachment_menu: bool = false,
    /// Bot-only fields (per Telegram's docs); null for human users.
    can_join_groups: ?bool = null,
    can_read_all_group_messages: ?bool = null,
    supports_inline_queries: ?bool = null,

    /// Deep-copies every string field (including nested `identity`) into
    /// `allocator` — see `Identity.dupe`.
    pub fn dupe(self: TelegramProfile, allocator: std.mem.Allocator) !TelegramProfile {
        return .{
            .identity = try self.identity.dupe(allocator),
            .first_name = try allocator.dupe(u8, self.first_name),
            .last_name = if (self.last_name) |s| try allocator.dupe(u8, s) else null,
            .language_code = if (self.language_code) |s| try allocator.dupe(u8, s) else null,
            .is_premium = self.is_premium,
            .added_to_attachment_menu = self.added_to_attachment_menu,
            .can_join_groups = self.can_join_groups,
            .can_read_all_group_messages = self.can_read_all_group_messages,
            .supports_inline_queries = self.supports_inline_queries,
        };
    }
};

const testing = std.testing;

test "TelegramProfile embeds Identity as its first field" {
    const profile = TelegramProfile{
        .identity = .{
            .platform = .telegram,
            .native_id = "42",
            .display_name = "Alice",
            .username = "alice",
            .first_seen = 1000,
            .last_seen = 2000,
        },
        .language_code = "en",
        .is_premium = true,
    };
    try testing.expectEqualStrings("42", profile.identity.native_id);
    try testing.expectEqualStrings("en", profile.language_code.?);
    try testing.expect(profile.is_premium);
    try testing.expectEqual(@as(?bool, null), profile.can_join_groups);
}
