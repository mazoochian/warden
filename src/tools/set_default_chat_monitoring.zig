const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    importance: []const u8,
};

/// The LLM-tool front end for `user_settings.monitor_all_default`
/// (`0046_monitor_all_default.sql`) -- the owner's global monitoring
/// default, applied to every personal-account chat that has no override of
/// its own (`set_chat_monitoring`). Reading is low-risk (`get_bulletin`
/// never sends anything, unlike replying, which stays opt-in per chat via
/// `reply_autonomy`), so this is meant to be reachable for "monitor
/// everything" in one call rather than requiring per-chat opt-in.
pub const tool: registry.ToolDef = .{
    .name = "set_default_chat_monitoring",
    .description = "Sets the owner's default monitoring level, applied to every personal-account chat that doesn't have its own override from set_chat_monitoring. \"off\" (the starting default) means only chats explicitly opted in via set_chat_monitoring are monitored. Setting this to low/normal/high monitors every chat at that level for get_bulletin -- individual chats can still be excluded (or raised/lowered) with set_chat_monitoring regardless of this default. Only call this when the owner has explicitly asked to change their default monitoring level.",
    .input_schema_json =
    \\{"type":"object","properties":{"importance":{"type":"string","enum":["off","low","normal","high"],"description":"The default monitoring level for chats with no override of their own."}},"required":["importance"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.monitoring orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    return sink.setDefaultImportance(ctx.allocator, parsed.value.importance);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_importance: ?[]const u8 = null,
    result_text: []const u8 = "Now monitoring every chat by default at normal importance.",

    fn sink(self: *FakeSink) registry.MonitoringSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.MonitoringSink.VTable = .{ .setImportance = unusedSetImportanceFn, .setDefaultImportance = setDefaultImportanceFn };

    fn setDefaultImportanceFn(ptr: *anyopaque, allocator: std.mem.Allocator, importance: []const u8) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.requested_importance = importance;
        return self.result_text;
    }

    fn unusedSetImportanceFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, importance: []const u8) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = chat_query;
        _ = importance;
        return error.Unsupported;
    }
};

test "execute passes importance through to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .monitoring = fake.sink() };

    const out = try execute(ctx, "{\"importance\":\"normal\"}");
    try testing.expectEqualStrings("normal", fake.requested_importance.?);
    try testing.expect(std.mem.indexOf(u8, out, "every chat") != null);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{\"importance\":\"off\"}"));
}
