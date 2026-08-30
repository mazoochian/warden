const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");
const llm = @import("../llm/provider.zig");
const delegates_mod = @import("../llm/delegates.zig");

const Args = struct {
    delegate: []const u8,
    prompt: []const u8,
    system: ?[]const u8 = null,
};

/// Generous headroom for a delegated task's answer — not tied to any
/// messaging platform's length cap (unlike `qa.zig`'s `answerMaxTokens`)
/// since a delegate's reply gets folded back into Warden's own answer as
/// tool-result text, never sent as its own chat message.
const delegate_max_tokens: u32 = 2048;

pub const tool: registry.ToolDef = .{
    .name = "ask_delegate",
    .description = "Sends a question or task to another configured AI model (e.g. ChatGPT, a second Claude persona, a local model) and returns its answer as text. Use this to get a second opinion, to hand off a task another model is better suited for, or when the user explicitly asks to consult/ask a specific model by name. You may rewrite or expand the prompt you send — add context, be more specific, or restructure the ask — to get the best answer from that model; the delegate never sees the rest of this conversation unless you include it in the prompt yourself.",
    .input_schema_json =
    \\{"type":"object","properties":{"delegate":{"type":"string","description":"Name of the configured delegate to ask."},"prompt":{"type":"string","description":"The question or task to send. Rewrite/expand the user's original request as needed to get a good answer."},"system":{"type":"string","description":"Optional system prompt/persona/constraints for the delegate to answer under."}},"required":["delegate","prompt"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const args = parsed.value;

    const delegate = delegates_mod.find(ctx.delegates, args.delegate) orelse {
        const available = try delegates_mod.describeAll(ctx.allocator, ctx.delegates);
        return std.fmt.allocPrint(
            ctx.allocator,
            "No delegate named '{s}' is configured. Available delegates: {s}.",
            .{ args.delegate, available },
        );
    };

    if (args.prompt.len == 0) return "The prompt sent to the delegate can't be empty.";

    const response = try delegate.provider.chat(ctx.allocator, .{
        .system = args.system,
        .messages = &.{.{ .role = .user, .content = &.{.{ .text = args.prompt }} }},
        .max_tokens = delegate_max_tokens,
    });

    const text = try llm.textOf(ctx.allocator, response.content);
    if (text.len == 0) return std.fmt.allocPrint(ctx.allocator, "'{s}' returned an empty response.", .{delegate.name});
    return text;
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "execute reports unknown delegates by name, listing what's available" {
    // Arena, not testing.allocator directly: `execute` builds the "no such
    // delegate" text out of two separate allocations (the list from
    // `describeAll`, then the wrapping message) and only the final one is
    // handed back to the caller — same "assume an arena" convention every
    // other tool's `execute` relies on (see e.g. `web_search.zig`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const S = struct {
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = allocator;
            _ = request;
            return error.UnexpectedCall;
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
    };
    const delegates = [_]delegates_mod.Delegate{
        .{ .name = "chatgpt", .description = "OpenAI's flagship model", .provider = .{ .ptr = undefined, .vtable = &S.vt } },
    };
    const ctx = registry.ToolContext{ .allocator = arena.allocator(), .io = testing.io, .delegates = &delegates };

    const out = try execute(ctx, "{\"delegate\":\"claude\",\"prompt\":\"hi\"}");
    try testing.expect(std.mem.indexOf(u8, out, "No delegate named 'claude'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "chatgpt (OpenAI's flagship model)") != null);
}

test "execute sends the prompt/system through to the resolved delegate's provider and returns its text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Recorder = struct {
        seen_system: ?[]const u8 = null,
        seen_prompt: []const u8 = "",

        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.seen_system = request.system;
            self.seen_prompt = request.messages[0].content[0].text;
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "42" }}),
                .stop_reason = .end_turn,
            };
        }
    };
    var recorder = Recorder{};
    const delegates = [_]delegates_mod.Delegate{
        .{ .name = "chatgpt", .description = "", .provider = recorder.provider() },
    };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .delegates = &delegates };

    const out = try execute(ctx, "{\"delegate\":\"ChatGPT\",\"prompt\":\"what is 6*7?\",\"system\":\"Answer with just the number.\"}");
    try testing.expectEqualStrings("42", out);
    try testing.expectEqualStrings("what is 6*7?", recorder.seen_prompt);
    try testing.expectEqualStrings("Answer with just the number.", recorder.seen_system.?);
}
