const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    chat: []const u8,
    importance: []const u8,
};

/// The LLM-tool front end for `chat_settings.monitor_importance`
/// (`0045_chat_monitoring.sql`) -- an owner-declared, static per-chat
/// setting, not a classifier that reads a chat's own content. `chat`
/// accepts a TDLib chat id or any title substring, same resolution as
/// `send_personal_message`. `importance: off` clears monitoring.
pub const tool: registry.ToolDef = .{
    .name = "set_chat_monitoring",
    .description = "Sets whether Warden actively monitors a personal-account chat for bulletins (get_bulletin), and how important it is. `chat` is a TDLib chat id or any substring of the chat's title (use list_personal_chats first if unsure). `importance: off` stops monitoring it. Only call this when the owner has explicitly asked to enable/adjust/disable monitoring for a chat -- never proactively, and never based on reading the chat's own content.",
    .input_schema_json =
    \\{"type":"object","properties":{"chat":{"type":"string","description":"The chat to set -- a TDLib chat id, or any substring of the chat's title."},"importance":{"type":"string","enum":["low","normal","high","off"],"description":"Monitoring level -- \"off\" stops monitoring this chat entirely."}},"required":["chat","importance"]}
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

    return sink.setImportance(ctx.allocator, parsed.value.chat, parsed.value.importance);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_chat: ?[]const u8 = null,
    requested_importance: ?[]const u8 = null,
    result_text: []const u8 = "Now monitoring \"Alice\" at high importance.",

    fn sink(self: *FakeSink) registry.MonitoringSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.MonitoringSink.VTable = .{ .setImportance = setImportanceFn };

    fn setImportanceFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, importance: []const u8) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.requested_chat = chat_query;
        self.requested_importance = importance;
        return self.result_text;
    }
};

test "execute passes chat and importance through to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .monitoring = fake.sink() };

    const out = try execute(ctx, "{\"chat\":\"alice\",\"importance\":\"high\"}");
    try testing.expectEqualStrings("alice", fake.requested_chat.?);
    try testing.expectEqualStrings("high", fake.requested_importance.?);
    try testing.expect(std.mem.indexOf(u8, out, "monitoring") != null);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{\"chat\":\"alice\",\"importance\":\"off\"}"));
}
