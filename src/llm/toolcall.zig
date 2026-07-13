const std = @import("std");
const llm = @import("provider.zig");
const registry = @import("../tools/registry.zig");

/// Hard cap on model<->tool round trips per question, so a confused model
/// can't loop forever burning tokens. Hitting it doesn't fail the request:
/// the model gets one final wrap-up turn (see end of `run`).
const max_iterations = 6;

/// Lets a caller observe what a `run` call is doing while it's in flight —
/// e.g. main.zig uses this to keep an animated "thinking"/"using X" chat
/// message up to date instead of the user staring at silence until the
/// whole tool-calling loop finishes. `ptr`/`onEvent` null (the default) is
/// a no-op, so existing callers don't need to change.
pub const Progress = struct {
    ptr: *anyopaque = undefined,
    onEvent: ?*const fn (ptr: *anyopaque, event: Event) void = null,

    pub const Event = union(enum) {
        /// About to send a request to the model (first turn or a follow-up
        /// after tool results).
        thinking,
        /// About to execute a tool the model asked for.
        tool_use: []const u8,
    };

    pub fn report(self: Progress, event: Event) void {
        if (self.onEvent) |f| f(self.ptr, event);
    }
};

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
    progress: Progress,
) ![]const u8 {
    const llm_tools = try toLlmTools(allocator, tool_defs);

    var messages: std.ArrayList(llm.ChatMessage) = .empty;
    try messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = user_message }}),
    });

    var i: u32 = 0;
    while (i < max_iterations) : (i += 1) {
        progress.report(.thinking);
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
            progress.report(.{ .tool_use = tu.name });
            const result_text = executeTool(ctx, tool_defs, tu) catch |err| blk: {
                std.log.err("tool '{s}' failed: {t}", .{ tu.name, err });
                break :blk try std.fmt.allocPrint(allocator, "tool error: {t}", .{err});
            };
            const safe_text = try sanitizeUtf8(allocator, result_text);
            try results.append(allocator, .{ .tool_result = .{ .tool_use_id = tu.id, .content = safe_text } });
        }
        try messages.append(allocator, .{ .role = .user, .content = try results.toOwnedSlice(allocator) });
    }

    // Cap hit (usually a model flailing at tools that keep erroring). One
    // last call, told to wrap up, salvages whatever it has learned so far —
    // a partial answer beats surfacing an error after all that work. Tools
    // stay in the request (providers reject conversations containing
    // tool_use blocks without them) but any further calls are ignored.
    try messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(llm.ContentBlock, &.{
        .{ .text = "You have reached the tool-call limit. Do not call any more tools — give your final answer now using what you already have, and say plainly what you couldn't complete." },
    }) });
    const response = try provider.chat(allocator, .{
        .system = system,
        .messages = messages.items,
        .tools = llm_tools,
    });
    const text = try llm.textOf(allocator, response.content);
    if (text.len > 0) return text;
    return error.ToolCallLoopExceeded;
}

/// Tool results can carry arbitrary bytes from external sources — a
/// scraped page served in an unexpected encoding, a botched HTML-entity
/// decode — that aren't valid UTF-8. Zig's `json.Stringify` only emits a
/// `[]const u8` as a JSON string when it validates as UTF-8 (see
/// `std.json.Stringify.write`); otherwise it silently falls back to a raw
/// array of byte integers, which Anthropic's API then rejects outright
/// ("Input should be an object") — surfacing as a confusing 400 on the
/// *next* turn, far from whichever tool actually produced the bad bytes.
/// Replacing anything that doesn't decode cleanly with U+FFFD guarantees
/// every tool result is valid UTF-8 by the time it reaches the wire.
fn sanitizeUtf8(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;

    const replacement = "\u{FFFD}";
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.appendSlice(allocator, replacement);
            i += 1;
            continue;
        };
        const end = i + seq_len;
        if (end <= text.len and std.unicode.utf8ValidateSlice(text[i..end])) {
            try out.appendSlice(allocator, text[i..end]);
            i = end;
        } else {
            try out.appendSlice(allocator, replacement);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
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

    const result = try run(fake.provider(), a, ctx, "system", "what is 2+2?", &.{calculator.tool}, .{});
    try testing.expectEqualStrings("The answer is 4.", result);
    try testing.expectEqual(@as(u32, 2), fake.call_count);
}

/// Requests the calculator on every turn until it sees the wrap-up nudge —
/// exercises the tool-call-limit path in `run`.
const InsatiableProvider = struct {
    call_count: u32 = 0,

    fn provider(self: *InsatiableProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *InsatiableProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;

        const last = request.messages[request.messages.len - 1];
        if (last.content.len == 1 and last.content[0] == .text and
            std.mem.indexOf(u8, last.content[0].text, "tool-call limit") != null)
        {
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "best effort answer" }}),
                .stop_reason = .end_turn,
            };
        }

        const input = try std.json.parseFromSlice(std.json.Value, allocator, "{\"expression\":\"1+1\"}", .{});
        const id = try std.fmt.allocPrint(allocator, "call_{d}", .{self.call_count});
        return .{
            .content = try allocator.dupe(llm.ContentBlock, &.{
                .{ .tool_use = .{ .id = id, .name = "calculator", .input = input.value } },
            }),
            .stop_reason = .tool_use,
        };
    }
};

test "run salvages a final answer when the tool-call cap is hit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = InsatiableProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try run(fake.provider(), a, ctx, "system", "loop forever", &.{calculator.tool}, .{});
    try testing.expectEqualStrings("best effort answer", result);
    // max_iterations tool turns plus the final wrap-up call.
    try testing.expectEqual(@as(u32, 7), fake.call_count);
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

    const result = try run(fake.provider(), a, ctx, null, "hi", &.{}, .{});
    try testing.expectEqualStrings("no tools needed", result);
}

test "sanitizeUtf8 passes valid UTF-8 through untouched" {
    const a = testing.allocator;
    const out = try sanitizeUtf8(a, "=== \u{0635}\u{0641}\u{062d}\u{0647} ===");
    try testing.expectEqualStrings("=== \u{0635}\u{0641}\u{062d}\u{0647} ===", out);
}

test "sanitizeUtf8 replaces invalid bytes with U+FFFD instead of corrupting the string" {
    const a = testing.allocator;
    const bad = "=== \xd8\x00 broken ===";
    const out = try sanitizeUtf8(a, bad);
    defer a.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.indexOf(u8, out, "\u{FFFD}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "broken") != null);
}
