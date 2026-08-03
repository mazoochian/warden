const std = @import("std");
const registry = @import("registry.zig");

const min_options = 2;
const max_options = 10;

const Args = struct {
    question: []const u8,
    options: []const []const u8,
};

/// ROADMAP.md's Phase 16 (group/Telegram quality-of-life): lets the user
/// ask for a poll in natural language ("make a poll asking pizza or
/// sushi") and get a real native poll, not just a text listing --
/// `/poll` (see `main.zig`) covers the explicit-command case, this covers
/// the natural-language one, both landing on the same
/// `Connector.sendPoll`.
pub const tool: registry.ToolDef = .{
    .name = "create_poll",
    .description = "Creates and sends a native poll to this chat with a question and 2-10 answer options. Use this whenever the user asks for a poll, a vote, or to poll the group on something.",
    .input_schema_json =
    \\{"type":"object","properties":{"question":{"type":"string","description":"The poll question"},"options":{"type":"array","items":{"type":"string"},"minItems":2,"maxItems":10,"description":"2-10 answer options"}},"required":["question","options"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const connector = ctx.connector orelse return error.MissingToolContext;
    const chat_id = ctx.chat_id orelse return error.MissingToolContext;

    var parsed = try std.json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    if (parsed.value.question.len == 0) return "Missing question -- say what the poll should ask.";
    if (parsed.value.options.len < min_options) return "A poll needs at least 2 options.";
    if (parsed.value.options.len > max_options) return "A poll can have at most 10 options.";

    connector.sendPoll(ctx.allocator, chat_id, parsed.value.question, parsed.value.options, null);
    return "Poll sent to the chat.";
}

test "tool schema is valid JSON" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const RecordingConnectorState = struct {
    sent_question: ?[]const u8 = null,
    sent_options: ?[]const []const u8 = null,
};

fn sendPollFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, question: []const u8, options: []const []const u8, reply_to_message_id: ?[]const u8) void {
    _ = chat_id;
    _ = reply_to_message_id;
    const state: *RecordingConnectorState = @ptrCast(@alignCast(ptr));
    state.sent_question = allocator.dupe(u8, question) catch return;
    state.sent_options = allocator.dupe([]const u8, options) catch return;
}

const iface = @import("../platform/interface.zig");

fn testConnector(state: *RecordingConnectorState) iface.Connector {
    const vt = struct {
        const vtable: iface.Connector.VTable = .{
            .platform = platformFn,
            .poll = pollFn,
            .sendMessage = sendMessageFn,
            .sendPoll = sendPollFn,
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
            _ = ptr;
            _ = allocator;
            _ = chat_id;
            _ = text;
            _ = reply_to_message_id;
        }
    };
    return .{ .ptr = state, .vtable = &vt.vtable };
}

test "execute forwards the question and options to Connector.sendPoll" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = RecordingConnectorState{};
    const ctx = registry.ToolContext{
        .allocator = a,
        .io = testing.io,
        .connector = testConnector(&state),
        .chat_id = "123",
    };

    const out = try execute(ctx, "{\"question\":\"pizza or sushi?\",\"options\":[\"pizza\",\"sushi\"]}");
    try testing.expectEqualStrings("Poll sent to the chat.", out);
    try testing.expectEqualStrings("pizza or sushi?", state.sent_question.?);
    try testing.expectEqual(@as(usize, 2), state.sent_options.?.len);
    try testing.expectEqualStrings("pizza", state.sent_options.?[0]);
}

test "execute rejects too few or too many options without calling the connector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = RecordingConnectorState{};
    const ctx = registry.ToolContext{
        .allocator = a,
        .io = testing.io,
        .connector = testConnector(&state),
        .chat_id = "123",
    };

    const too_few = try execute(ctx, "{\"question\":\"q\",\"options\":[\"only one\"]}");
    try testing.expect(std.mem.indexOf(u8, too_few, "at least 2") != null);
    try testing.expectEqual(@as(?[]const u8, null), state.sent_question);
}
