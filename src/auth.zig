const std = @import("std");
const Config = @import("config.zig").Config;
const Platform = @import("platform/interface.zig").Platform;

/// Single choke point for access control: every feature handler must be
/// reached only through here. Checked by native platform user id only,
/// never username/display name.
pub fn isOwner(config: *const Config, platform: Platform, user_id: []const u8) bool {
    for (config.owners) |entry| {
        if (entry.platform == platform and std.mem.eql(u8, entry.owner_id, user_id)) return true;
    }
    return false;
}

const testing = std.testing;

test "isOwner matches only the configured platform+id pair" {
    const config = Config{
        .telegram_bot_token = "x",
        .owners = &.{.{ .platform = .telegram, .owner_id = "101573604" }},
        .data_dir = "data/chats",
        .retention_messages = 20_000,
        .llm = .{ .anthropic = .{ .api_key = "x", .model = "x" } },
        .confirm_timeout_seconds = 60,
        .tmp_dir = "data/tmp",
        .digest_interval_seconds = 86_400,
        .system_prompt = null,
        .searxng_url = null,
    };
    try testing.expect(isOwner(&config, .telegram, "101573604"));
    try testing.expect(!isOwner(&config, .telegram, "1"));
    try testing.expect(!isOwner(&config, .matrix, "101573604"));
}
