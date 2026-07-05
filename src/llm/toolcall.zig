const std = @import("std");
const llm = @import("provider.zig");
const registry = @import("../tools/registry.zig");

/// Hard cap on model<->tool round trips per question, so a confused model
/// can't loop forever burning tokens.
const max_iterations = 6;

/// Drives one provider-agnostic conversation: sends `user_message`, and as
/// long as the model keeps asking for tools, executes them against
/// `tool_defs` and feeds the results back, until it produces a final text
/// answer (or the iteration cap is hit).
pub fn run(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    ctx: registry.ToolContext,
    system: ?[]const u8,
    user_message: []const u8,
    tool_defs: []const registry.ToolDef,
) ![]const u8 {
    const llm_tools = try toLlmTools(allocator, tool_defs);

    var messages: std.ArrayList(llm.ChatMessage) = .empty;
    try messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = user_message }}),
    });

    var i: u32 = 0;
    while (i < max_iterations) : (i += 1) {
        const response = try provider.chat(allocator, .{
            .system = system,
            .messages = messages.items,
            .tools = llm_tools,
        });

        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        var tool_uses: std.ArrayList(llm.ToolUse) = .empty;
        for (response.content) |block| {
            switch (block) {
                .tool_use => |tu| try tool_uses.append(allocator, tu),
                .text, .tool_result => {},
            }
        }

        if (tool_uses.items.len == 0) {
            return llm.textOf(allocator, response.content);
        }

        var results: std.ArrayList(llm.ContentBlock) = .empty;
        for (tool_uses.items) |tu| {
            const result_text = executeTool(ctx, tool_defs, tu) catch |err| blk: {
                std.log.err("tool '{s}' failed: {t}", .{ tu.name, err });
                break :blk try std.fmt.allocPrint(allocator, "tool error: {t}", .{err});
            };
            try results.append(allocator, .{ .tool_result = .{ .tool_use_id = tu.id, .content = result_text } });
        }
        try messages.append(allocator, .{ .role = .user, .content = try results.toOwnedSlice(allocator) });
    }
    return error.ToolCallLoopExceeded;
}

fn executeTool(ctx: registry.ToolContext, tool_defs: []const registry.ToolDef, tu: llm.ToolUse) ![]const u8 {
    const def = registry.find(tool_defs, tu.name) orelse return error.UnknownTool;
    const input_json = try std.json.Stringify.valueAlloc(ctx.allocator, tu.input, .{});
    return def.execute(ctx, input_json);
}

fn toLlmTools(allocator: std.mem.Allocator, defs: []const registry.ToolDef) ![]const llm.Tool {
    var list: std.ArrayList(llm.Tool) = .empty;
    for (defs) |d| {
        try list.append(allocator, .{
            .name = d.name,
            .description = d.description,
            .input_schema_json = d.input_schema_json,
        });
    }
    return list.toOwnedSlice(allocator);
}

const testing = std.testing;
const calculator = @import("../tools/calculator.zig");

/// Stands in for a real provider: first turn asks for the calculator tool,
/// second turn checks the tool's result actually made it back into the
/// conversation before returning a final answer. Exercises the loop's
/// dispatch/threading logic with no network involved.
const FakeProvider = struct {
    call_count: u32 = 0,

    fn provider(self: *FakeProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;

        if (self.call_count == 1) {
            const input = try std.json.parseFromSlice(std.json.Value, allocator, "{\"expression\":\"2+2\"}", .{});
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{
                    .{ .tool_use = .{ .id = "call_1", .name = "calculator", .input = input.value } },
                }),
                .stop_reason = .tool_use,
            };
        }

        var saw_result = false;
        for (request.messages) |m| {
            for (m.content) |block| {
                if (block == .tool_result and std.mem.eql(u8, block.tool_result.tool_use_id, "call_1")) {
                    try testing.expectEqualStrings("4", block.tool_result.content);
                    saw_result = true;
                }
            }
        }
        try testing.expect(saw_result);

        return .{
            .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "The answer is 4." }}),
            .stop_reason = .end_turn,
        };
    }
};

test "run executes a tool call and threads its result back to the model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try run(fake.provider(), a, ctx, "system", "what is 2+2?", &.{calculator.tool});
    try testing.expectEqualStrings("The answer is 4.", result);
    try testing.expectEqual(@as(u32, 2), fake.call_count);
}

test "run returns the model's answer directly when it never calls a tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NoToolProvider = struct {
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = request;
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "no tools needed" }}),
                .stop_reason = .end_turn,
            };
        }
    };
    var fake = NoToolProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try run(fake.provider(), a, ctx, null, "hi", &.{});
    try testing.expectEqualStrings("no tools needed", result);
}
