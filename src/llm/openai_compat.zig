const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const llm = @import("provider.zig");
const http_util = @import("../http_util.zig");

const ToolCallFunction = struct {
    name: []const u8 = "",
    /// A JSON-encoded *string* per OpenAI's function-calling shape (unlike
    /// Anthropic, which embeds `input` as a real JSON object) — parsed into
    /// a `json.Value` ourselves after the outer response parse.
    arguments: []const u8 = "",
};

const RawToolCall = struct {
    id: []const u8 = "",
    function: ToolCallFunction = .{},
};

const RawMessage = struct {
    content: ?[]const u8 = null,
    tool_calls: []RawToolCall = &.{},
};

const Choice = struct {
    message: RawMessage = .{},
    finish_reason: []const u8 = "",
};

const ApiError = struct {
    message: []const u8 = "",
    type: []const u8 = "",
};

const ChatCompletionResponse = struct {
    choices: []Choice = &.{},
    @"error": ?ApiError = null,
};

/// Generic OpenAI-compatible `/v1/chat/completions` adapter. Covers Ollama,
/// llama.cpp server, LM Studio, vLLM, etc. transparently since they all
/// speak this same wire shape — no per-runtime adapter needed.
pub const OpenAiCompatProvider = struct {
    http_client: http.Client,
    /// e.g. "http://localhost:11434/v1" — no trailing slash.
    base_url: []const u8,
    /// Empty string means no Authorization header is sent (fine for most
    /// local runtimes, which don't check one).
    api_key: []const u8,
    model: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, base_url: []const u8, api_key: []const u8, model: []const u8) OpenAiCompatProvider {
        return .{
            .http_client = .{ .allocator = allocator, .io = io },
            .base_url = base_url,
            .api_key = api_key,
            .model = model,
        };
    }

    pub fn deinit(self: *OpenAiCompatProvider) void {
        self.http_client.deinit();
    }

    pub fn provider(self: *OpenAiCompatProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *OpenAiCompatProvider = @ptrCast(@alignCast(ptr));

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        const w = &payload_writer.writer;

        try w.writeAll("{\"model\":");
        try json.Stringify.value(self.model, .{}, w);
        try w.print(",\"max_tokens\":{d}", .{request.max_tokens});
        try w.writeAll(",\"messages\":");
        try writeMessages(allocator, w, request.system, request.messages);
        if (request.tools.len > 0) {
            try w.writeAll(",\"tools\":");
            try writeTools(allocator, w, request.tools);
        }
        try w.writeByte('}');
        const payload = w.buffered();

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
        defer allocator.free(url);

        var auth_header_buf: [8 + 255]u8 = undefined;
        const headers: []const http.Header = if (self.api_key.len > 0) blk: {
            const value = try std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{self.api_key});
            break :blk &.{.{ .name = "Authorization", .value = value }};
        } else &.{};

        const body = try http_util.postJson(&self.http_client, allocator, url, headers, payload);
        defer allocator.free(body);

        // Deliberately never `.deinit()`'d — see the note on
        // `llm.ChatResponse`; content (and each tool call's parsed
        // `arguments`) borrows from this arena and from a nested one built
        // below, both reclaimed together whenever the caller's own arena
        // resets.
        const parsed = try json.parseFromSlice(
            ChatCompletionResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );

        if (parsed.value.@"error") |err| {
            std.log.err("openai-compatible api error: {s}: {s}", .{ err.type, err.message });
            return error.OpenAiCompatApiError;
        }
        if (parsed.value.choices.len == 0) return error.OpenAiCompatEmptyResponse;
        const choice = parsed.value.choices[0];

        var blocks: std.ArrayList(llm.ContentBlock) = .empty;
        if (choice.message.content) |c| {
            if (c.len > 0) try blocks.append(allocator, .{ .text = c });
        }
        for (choice.message.tool_calls) |tc| {
            const args = try json.parseFromSlice(json.Value, allocator, tc.function.arguments, .{});
            try blocks.append(allocator, .{ .tool_use = .{ .id = tc.id, .name = tc.function.name, .input = args.value } });
        }

        const stop_reason: llm.StopReason = if (choice.message.tool_calls.len > 0 or std.mem.eql(u8, choice.finish_reason, "tool_calls"))
            .tool_use
        else if (std.mem.eql(u8, choice.finish_reason, "stop"))
            .end_turn
        else
            .other;

        return .{ .content = try blocks.toOwnedSlice(allocator), .stop_reason = stop_reason };
    }
};

/// Unlike Anthropic (one bundled `tool_result` array per turn), OpenAI
/// expects one standalone `{"role":"tool",...}` message per result — so a
/// single logical `ChatMessage` full of `tool_result` blocks expands into
/// several JSON messages here.
fn writeMessages(
    allocator: std.mem.Allocator,
    w: *Io.Writer,
    system: ?[]const u8,
    messages: []const llm.ChatMessage,
) !void {
    try w.writeByte('[');
    var first = true;

    if (system) |s| {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try json.Stringify.value(s, .{}, w);
        try w.writeByte('}');
        first = false;
    }

    for (messages) |m| {
        var text_parts: std.ArrayList(u8) = .empty;
        defer text_parts.deinit(allocator);
        var tool_calls: std.ArrayList(llm.ToolUse) = .empty;
        defer tool_calls.deinit(allocator);
        var tool_results: std.ArrayList(llm.ToolResult) = .empty;
        defer tool_results.deinit(allocator);

        for (m.content) |block| {
            switch (block) {
                .text => |t| try text_parts.appendSlice(allocator, t),
                .tool_use => |tu| try tool_calls.append(allocator, tu),
                .tool_result => |tr| try tool_results.append(allocator, tr),
            }
        }

        for (tool_results.items) |tr| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
            try json.Stringify.value(tr.tool_use_id, .{}, w);
            try w.writeAll(",\"content\":");
            try json.Stringify.value(tr.content, .{}, w);
            try w.writeByte('}');
        }

        if (text_parts.items.len == 0 and tool_calls.items.len == 0) continue;

        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"role\":");
        try json.Stringify.value(@tagName(m.role), .{}, w);
        try w.writeAll(",\"content\":");
        if (text_parts.items.len > 0) {
            try json.Stringify.value(text_parts.items, .{}, w);
        } else {
            try w.writeAll("null");
        }
        if (tool_calls.items.len > 0) {
            try w.writeAll(",\"tool_calls\":[");
            for (tool_calls.items, 0..) |tc, idx| {
                if (idx != 0) try w.writeByte(',');
                try w.writeAll("{\"id\":");
                try json.Stringify.value(tc.id, .{}, w);
                try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try json.Stringify.value(tc.name, .{}, w);
                try w.writeAll(",\"arguments\":");
                // `arguments` is itself a JSON *string* containing JSON, so
                // this is a deliberate double-encode.
                const args_json = try json.Stringify.valueAlloc(allocator, tc.input, .{});
                defer allocator.free(args_json);
                try json.Stringify.value(args_json, .{}, w);
                try w.writeAll("}}");
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn writeTools(allocator: std.mem.Allocator, w: *Io.Writer, tools: []const llm.Tool) !void {
    try w.writeByte('[');
    for (tools, 0..) |t, idx| {
        if (idx != 0) try w.writeByte(',');
        var schema = try json.parseFromSlice(json.Value, allocator, t.input_schema_json, .{});
        defer schema.deinit();

        try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try json.Stringify.value(t.name, .{}, w);
        try w.writeAll(",\"description\":");
        try json.Stringify.value(t.description, .{}, w);
        try w.writeAll(",\"parameters\":");
        try json.Stringify.value(schema.value, .{}, w);
        try w.writeAll("}}");
    }
    try w.writeByte(']');
}

const testing = std.testing;

test "ChatCompletionResponse parses a successful choice" {
    const body =
        \\{"id":"chatcmpl-1","choices":[{"index":0,"message":{"role":"assistant","content":"hello world"},"finish_reason":"stop"}]}
    ;
    var parsed = try json.parseFromSlice(
        ChatCompletionResponse,
        testing.allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expect(parsed.value.@"error" == null);
    try testing.expectEqual(@as(usize, 1), parsed.value.choices.len);
    try testing.expectEqualStrings("hello world", parsed.value.choices[0].message.content.?);
}

test "ChatCompletionResponse parses a tool call with string-encoded arguments" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\"location\":\"Tokyo\"}"}}]},"finish_reason":"tool_calls"}]}
    ;
    var parsed = try json.parseFromSlice(
        ChatCompletionResponse,
        testing.allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.choices[0].message.tool_calls.len);
    const tc = parsed.value.choices[0].message.tool_calls[0];
    try testing.expectEqualStrings("weather", tc.function.name);

    var args = try json.parseFromSlice(json.Value, testing.allocator, tc.function.arguments, .{});
    defer args.deinit();
    try testing.expectEqualStrings("Tokyo", args.value.object.get("location").?.string);
}

test "ChatCompletionResponse parses the api error shape" {
    const body =
        \\{"error":{"message":"model not found","type":"invalid_request_error"}}
    ;
    var parsed = try json.parseFromSlice(
        ChatCompletionResponse,
        testing.allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expect(parsed.value.@"error" != null);
    try testing.expectEqualStrings("model not found", parsed.value.@"error".?.message);
}

test "writeMessages expands tool_result blocks into standalone tool messages" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeMessages(testing.allocator, &out.writer, "be helpful", &.{
        .{ .role = .user, .content = &.{.{ .text = "what's the weather" }} },
        .{ .role = .assistant, .content = &.{.{ .tool_use = .{ .id = "call_1", .name = "weather", .input = .{ .null = {} } } }} },
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "call_1", .content = "sunny" } }} },
    });

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, out.writer.buffered(), .{});
    defer parsed.deinit();
    // system + user + assistant(tool_calls) + tool(result) = 4 messages.
    try testing.expectEqual(@as(usize, 4), parsed.value.array.items.len);
    try testing.expectEqualStrings("tool", parsed.value.array.items[3].object.get("role").?.string);
}
