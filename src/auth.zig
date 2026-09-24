const std = @import("std");
const Config = @import("config.zig").Config;
const iface = @import("platform/interface.zig");
const Platform = iface.Platform;
const PgPool = @import("store/pool.zig").PgPool;

/// Single choke point for the owner check: every feature handler must be
/// reached only through here.
pub fn isOwner(config: *const Config, platform: Platform, user_id: []const u8) bool {
    for (config.owners) |entry| {
        if (entry.platform == platform and std.mem.eql(u8, entry.owner_id, user_id)) return true;
    }
    return false;
}

/// The permission ladder for group-moderation-tier commands (`/mute /unmute
/// /pin /unpin /delete /kick /ban /confirm /cancel`).
pub fn checkGroupAdminAccess(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const Config,
    pool: *PgPool,
    chat_id: i64,
    identity_id: i64,
    msg: iface.Message,
    sudo_active: bool,
    action_name: []const u8,
) bool {
    _ = pool;
    _ = chat_id;
    _ = identity_id;
    if (isOwner(config, connector.platform(), msg.user_id)) return true;

    if (sudo_active) {
        const display_name = if (msg.identity) |identity| identity.display_name else msg.username orelse msg.user_id;
        const text = std.fmt.allocPrint(a, "{s} has been granted superuser permissions for action: {s}", .{ display_name, action_name }) catch return true;
        connector.sendMessage(a, msg.chat_id, text, msg.message_id);
        return true;
    }

    const is_platform_admin = connector.isGroupAdmin(a, msg.chat_id, msg.user_id) catch |err| blk: {
        std.log.warn("auth: platform admin check failed for user {s} in chat {s}: {t}", .{ msg.user_id, msg.chat_id, err });
        break :blk false;
    };
    return is_platform_admin;
}

/// Gate for a management-room action (`/manage bind`/`/manage unbind`/
/// `/notice`, see `main.zig`'s dispatch chain) — unlike
/// `checkGroupAdminAccess`.
pub fn isOwnerOrLiveAdminOfChat(connector: iface.Connector, a: std.mem.Allocator, config: *const Config, native_chat_id: []const u8, user_id: []const u8) bool {
    if (isOwner(config, connector.platform(), user_id)) return true;
    return connector.isGroupAdmin(a, native_chat_id, user_id) catch false;
}

/// Gate for the six bot-management commands (`/blockuser /unblockuser
/// /blockchat /unblockchat /addadmin /removeadmin`).
pub fn isOwnerOrBotAdmin(config: *const Config, platform: Platform, user_id: []const u8, is_bot_admin: bool) bool {
    return isOwner(config, platform, user_id) or is_bot_admin;
}

/// Gate for `/redact regex` mode specifically.
pub fn isOwnerOrSudoBotAdmin(config: *const Config, platform: Platform, user_id: []const u8, sudo_active: bool) bool {
    return isOwner(config, platform, user_id) or sudo_active;
}

const testing = std.testing;
const test_support = @import("store/test_support.zig");
const identities = @import("store/identities.zig");
const chats = @import("store/chats.zig");

// `comptime owner_id` (not a runtime `[]const u8` param) is load-bearing.
fn testConfig(comptime owner_id: []const u8) Config {
    return Config{
        .telegram_bot_token = "x",
        .owners = &.{.{ .platform = .telegram, .owner_id = owner_id }},
        .postgres_dsn = "postgresql:///warden_test",
        .postgres_pool_size = 1,
        .postgres_acquire_timeout_seconds = 30,
        .postgres_statement_timeout_seconds = 30,
        .workers_per_platform = 2,
        .retention_messages = 20_000,
        .llm = .{ .anthropic = .{ .api_key = "x", .model = "x" } },
        .confirm_timeout_seconds = 60,
        .convert_timeout_seconds = 300,
        .menu_timeout_seconds = 180,
        .tmp_dir = "data/tmp",
        .digest_interval_seconds = 86_400,
        .briefing_interval_seconds = 86_400,
        .system_prompt = null,
        .searxng_url = null,
        .whisper_url = null,
        .embeddings_url = null,
        .embeddings_api_key = "",
        .embeddings_model = "text-embedding-3-small",
        .llm_owner_only = true,
        .llm_show_thinking = false,
        .llm_streaming = false,
        .llm_vision_enabled = true,
        .llm_documents_enabled = true,
    };
}

test "isOwner matches only the configured platform+id pair" {
    const config = testConfig("101573604");
    try testing.expect(isOwner(&config, .telegram, "101573604"));
    try testing.expect(!isOwner(&config, .telegram, "1"));
    try testing.expect(!isOwner(&config, .matrix, "101573604"));
}

/// A minimal `Connector` stub for exercising `checkGroupAdminAccess`/ friends
/// without a real platform.
const StubConnector = struct {
    is_group_admin: bool = false,
    is_group_admin_err: bool = false,
    sent_messages: std.ArrayList([]const u8) = .empty,

    fn connector(self: *StubConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .isGroupAdmin = isGroupAdminFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram;
    }
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }
    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = chat_id;
        _ = reply_to_message_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(allocator, text) catch {};
    }
    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        _ = allocator;
        _ = chat_id;
        _ = user_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        if (self.is_group_admin_err) return error.Unsupported;
        return self.is_group_admin;
    }
};

fn baseMsg() iface.Message {
    return .{ .chat_id = "chat1", .user_id = "42", .username = "alice" };
}

test "checkGroupAdminAccess: owner is always allowed, no platform check" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const config = testConfig("42");
    var stub = StubConnector{};
    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try testing.expect(checkGroupAdminAccess(stub.connector(), a, &config, &pool, chat_id, identity_id, baseMsg(), false, "kick"));
    try testing.expectEqual(@as(usize, 0), stub.sent_messages.items.len);
}

test "checkGroupAdminAccess: sudo_active grants access and sends the grant message" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const config = testConfig("999"); // sender is NOT the owner
    var stub = StubConnector{}; // and NOT a platform admin
    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    var msg = baseMsg();
    msg.identity = .{ .platform = .telegram, .native_id = "42", .display_name = "Armin Mazoochian", .first_seen = 1000, .last_seen = 1000 };

    try testing.expect(checkGroupAdminAccess(stub.connector(), a, &config, &pool, chat_id, identity_id, msg, true, "kick"));
    try testing.expectEqual(@as(usize, 1), stub.sent_messages.items.len);
    try testing.expectEqualStrings("Armin Mazoochian has been granted superuser permissions for action: kick", stub.sent_messages.items[0]);
}

test "checkGroupAdminAccess: without sudo, a non-admin non-owner is denied silently" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const config = testConfig("999");
    var stub = StubConnector{}; // not a platform admin
    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try testing.expect(!checkGroupAdminAccess(stub.connector(), a, &config, &pool, chat_id, identity_id, baseMsg(), false, "kick"));
    try testing.expectEqual(@as(usize, 0), stub.sent_messages.items.len);
}

test "checkGroupAdminAccess: a live platform admin is allowed" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const config = testConfig("999");
    var stub = StubConnector{ .is_group_admin = true };
    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try testing.expect(checkGroupAdminAccess(stub.connector(), a, &config, &pool, chat_id, identity_id, baseMsg(), false, "kick"));
}

test "checkGroupAdminAccess: a failed platform-admin check fails closed, not open" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const config = testConfig("999");
    var stub = StubConnector{ .is_group_admin_err = true };
    const chat_id = try chats.upsertChat(&pool, .telegram, "chat1", null, null);
    const identity_id = try identities.getOrCreateMinimal(&pool, .telegram, "42", "alice", null, false, 1000);

    try testing.expect(!checkGroupAdminAccess(stub.connector(), a, &config, &pool, chat_id, identity_id, baseMsg(), false, "kick"));
}

test "isOwnerOrLiveAdminOfChat: owner or a live admin of the named chat passes, a plain user doesn't" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const owner_config = testConfig("42");
    const other_config = testConfig("999");
    var admin_stub = StubConnector{ .is_group_admin = true };
    var plain_stub = StubConnector{};

    try testing.expect(isOwnerOrLiveAdminOfChat(plain_stub.connector(), a, &owner_config, "target-chat", "42"));
    try testing.expect(isOwnerOrLiveAdminOfChat(admin_stub.connector(), a, &other_config, "target-chat", "42"));
    try testing.expect(!isOwnerOrLiveAdminOfChat(plain_stub.connector(), a, &other_config, "target-chat", "42"));
}

test "isOwnerOrBotAdmin and isOwnerOrSudoBotAdmin" {
    const owner_config = testConfig("42");
    const other_config = testConfig("999");

    try testing.expect(isOwnerOrBotAdmin(&owner_config, .telegram, "42", false));
    try testing.expect(isOwnerOrBotAdmin(&other_config, .telegram, "42", true));
    try testing.expect(!isOwnerOrBotAdmin(&other_config, .telegram, "42", false));

    try testing.expect(isOwnerOrSudoBotAdmin(&owner_config, .telegram, "42", false));
    try testing.expect(isOwnerOrSudoBotAdmin(&other_config, .telegram, "42", true));
    try testing.expect(!isOwnerOrSudoBotAdmin(&other_config, .telegram, "42", false));
}
