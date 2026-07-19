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
    /// Reasoning-model backends surface chain-of-thought either as inline
    /// `<think>`/`<thinking>` tags inside `content`, or as a separate field
    /// — `reasoning_content` (DeepSeek, vLLM's reasoning parser) or
    /// `reasoning` (OpenRouter). We check both field names; whichever one a
    /// given backend actually sends, the other stays null and is ignored.
    reasoning_content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
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
    /// Whether a reasoning model's chain-of-thought is passed through to
    /// the caller. See `filterThinking` for what gets stripped when false.
    show_thinking: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, base_url: []const u8, api_key: []const u8, model: []const u8, show_thinking: bool) OpenAiCompatProvider {
        return .{
            .http_client = .{ .allocator = allocator, .io = io },
            .base_url = base_url,
            .api_key = api_key,
            .model = model,
            .show_thinking = show_thinking,
        };
    }

    pub fn deinit(self: *OpenAiCompatProvider) void {
        self.http_client.deinit();
    }

    pub fn provider(self: *OpenAiCompatProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn, .chatStream = chatStreamFn };

    /// Shared request-body builder for both `chatFn` and `chatStreamFn` —
    /// the only difference between the two is `"stream":true`. Duped into a
    /// fresh allocation before returning rather than handing back
    /// `payload_writer.buffered()` directly, since `payload_writer` goes
    /// out of scope here (see `anthropic.zig`'s `buildPayload`, same
    /// reasoning).
    fn buildPayload(allocator: std.mem.Allocator, self: *const OpenAiCompatProvider, request: llm.ChatRequest, stream: bool) ![]const u8 {
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
        if (stream) try w.writeAll(",\"stream\":true");
        try w.writeByte('}');
        return allocator.dupe(u8, w.buffered());
    }

    /// Writes the "Bearer ..." value into `auth_header_buf` and the header
    /// itself into `headers_buf[0]`, returning a slice into `headers_buf` —
    /// both caller-owned buffers, so the returned slice's storage is the
    /// *caller's* stack frame, not this function's (which would leave a
    /// dangling slice into memory that's gone the instant this returns —
    /// confirmed the hard way: an earlier version of this returned `&.{...}`
    /// directly and segfaulted on the very first request, `extra_headers`
    /// already garbage by the time `std.http.Client.request` read it).
    fn buildHeaders(self: *const OpenAiCompatProvider, auth_header_buf: []u8, headers_buf: *[1]http.Header) ![]const http.Header {
        if (self.api_key.len == 0) return &.{};
        const value = try std.fmt.bufPrint(auth_header_buf, "Bearer {s}", .{self.api_key});
        headers_buf[0] = .{ .name = "Authorization", .value = value };
        return headers_buf[0..1];
    }

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *OpenAiCompatProvider = @ptrCast(@alignCast(ptr));
        const payload = try buildPayload(allocator, self, request, false);

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
        defer allocator.free(url);

        var auth_header_buf: [8 + 255]u8 = undefined;
        var headers_buf: [1]http.Header = undefined;
        const headers = try self.buildHeaders(&auth_header_buf, &headers_buf);

        const body = try http_util.postJsonWithTimeout(&self.http_client, allocator, url, headers, payload, http_util.llm_timeout_ns);
        defer allocator.free(body);

        // Deliberately never `.deinit()`'d — see the note on
        // `llm.ChatResponse`; content (and each tool call's parsed
        // `arguments`) borrows from this arena and from a nested one built
        // below, both reclaimed together whenever the caller's own arena
        // resets.
        const parsed = json.parseFromSlice(
            ChatCompletionResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |err| {
            std.log.err("openai-compatible response unparseable ({t}): {s}", .{ err, body[0..@min(body.len, 400)] });
            return err;
        };

        if (parsed.value.@"error") |err| {
            std.log.err("openai-compatible api error: {s}: {s}", .{ err.type, err.message });
            return error.OpenAiCompatApiError;
        }
        if (parsed.value.choices.len == 0) return error.OpenAiCompatEmptyResponse;
        const choice = parsed.value.choices[0];

        var blocks: std.ArrayList(llm.ContentBlock) = .empty;
        const reasoning = choice.message.reasoning_content orelse choice.message.reasoning;
        if (self.show_thinking) {
            if (reasoning) |r| {
                if (r.len > 0) try blocks.append(allocator, .{ .text = try std.fmt.allocPrint(allocator, "\u{1F4AD} {s}\n\n", .{r}) });
            }
            if (choice.message.content) |c| {
                if (c.len > 0) try blocks.append(allocator, .{ .text = c });
            }
        } else {
            // reasoning/reasoning_content is dropped outright; inline
            // <think>/<thinking> tags inside `content` are stripped instead
            // of dropped, since the surrounding text is the real answer.
            if (choice.message.content) |c0| {
                var c = try stripThinkingBlock(allocator, c0, "think");
                c = try stripThinkingBlock(allocator, c, "thinking");
                c = std.mem.trim(u8, c, " \t\r\n");
                if (c.len > 0) try blocks.append(allocator, .{ .text = c });
            }
        }
        for (choice.message.tool_calls) |tc| {
            // Some models emit an empty string (not "{}") for no-argument
            // tool calls; treat it as an empty object instead of failing
            // the entire answer on a JSON parse of "".
            const args_src = if (tc.function.arguments.len == 0) "{}" else tc.function.arguments;
            const args = json.parseFromSlice(json.Value, allocator, args_src, .{}) catch |err| {
                std.log.err("tool call '{s}' has unparseable arguments ({t}): {s}", .{
                    tc.function.name, err, args_src[0..@min(args_src.len, 400)],
                });
                return err;
            };
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

    fn chatStreamFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest, sink: llm.StreamSink) anyerror!llm.ChatResponse {
        const self: *OpenAiCompatProvider = @ptrCast(@alignCast(ptr));
        const payload = try buildPayload(allocator, self, request, true);

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
        defer allocator.free(url);

        var auth_header_buf: [8 + 255]u8 = undefined;
        var headers_buf: [1]http.Header = undefined;
        const headers = try self.buildHeaders(&auth_header_buf, &headers_buf);

        var state: StreamState = .{ .allocator = allocator, .stream_sink = sink, .show_thinking = self.show_thinking };
        try http_util.postJsonSSE(&self.http_client, allocator, url, headers, payload, http_util.llm_timeout_ns, state.sink());

        if (state.err) |err| {
            std.log.err("openai-compatible streaming api error: {s}: {s}", .{ err.type, err.message });
            return error.OpenAiCompatApiError;
        }

        return try state.finalize(allocator);
    }
};

/// Removes every `<tag>...</tag>` span from `content` (used to strip
/// `<think>`/`<thinking>` chain-of-thought some reasoning models inline
/// directly into their answer text). An unterminated opening tag drops
/// everything from that point on rather than leaking a half-written
/// thinking block. Returns `content` unchanged (no allocation) when the
/// open tag never appears.
fn stripThinkingBlock(allocator: std.mem.Allocator, content: []const u8, comptime tag: []const u8) ![]const u8 {
    const open_tag = "<" ++ tag ++ ">";
    const close_tag = "</" ++ tag ++ ">";

    if (std.mem.indexOf(u8, content, open_tag) == null) return content;

    var out: std.ArrayList(u8) = .empty;
    var rest = content;
    while (std.mem.indexOf(u8, rest, open_tag)) |start| {
        try out.appendSlice(allocator, rest[0..start]);
        const after_open = rest[start + open_tag.len ..];
        if (std.mem.indexOf(u8, after_open, close_tag)) |end| {
            rest = after_open[end + close_tag.len ..];
        } else {
            rest = "";
            break;
        }
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn jsonStr(obj: json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// Incrementally assembles a `llm.ChatResponse` from an OpenAI-compatible
/// `chat.completion.chunk` SSE stream. Unlike Anthropic's stream (see
/// `anthropic.zig`'s `StreamState` doc comment), tool-call deltas carry
/// their own `index` and aren't guaranteed to arrive one-at-a-time, so
/// in-progress tool calls are tracked in a small list keyed by that index
/// rather than assuming only one is ever open.
const StreamState = struct {
    const ToolCallAccum = struct {
        index: i64,
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        /// Fragments concatenate into a JSON string, parsed once complete
        /// (see `finalize`) — same reasoning as the non-streaming path's
        /// `tc.function.arguments`.
        arguments: std.ArrayList(u8) = .empty,
    };

    allocator: std.mem.Allocator,
    stream_sink: llm.StreamSink,
    show_thinking: bool,
    /// Raw `content` deltas concatenated as they arrive — reported to
    /// `stream_sink` unconditionally (regardless of `show_thinking`) as
    /// they grow, since safely stripping `<think>` tags out of a live,
    /// still-growing stream isn't reliable (a tag can straddle two SSE
    /// chunks) — see `finalize`, which is where the `show_thinking=false`
    /// cleanup actually gets applied, same as the non-streaming path.
    visible_text: std.ArrayList(u8) = .empty,
    reasoning_text: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(ToolCallAccum) = .empty,
    saw_tool_calls_finish: bool = false,
    stop_reason_str: []const u8 = "",
    err: ?ApiError = null,

    fn sink(self: *StreamState) http_util.SseLineSink {
        return .{ .ptr = self, .onLine = onLine };
    }

    fn findOrCreateToolCall(self: *StreamState, index: i64) !*ToolCallAccum {
        for (self.tool_calls.items) |*tc| {
            if (tc.index == index) return tc;
        }
        try self.tool_calls.append(self.allocator, .{ .index = index });
        return &self.tool_calls.items[self.tool_calls.items.len - 1];
    }

    fn onLine(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *StreamState = @ptrCast(@alignCast(ptr));
        if (!std.mem.startsWith(u8, line, "data:")) return; // skip blank lines, comments
        const data = std.mem.trim(u8, line["data:".len..], " ");
        if (data.len == 0) return;
        if (std.mem.eql(u8, data, "[DONE]")) return;

        // `.alloc_always` so nothing in `parsed.value` aliases `data`,
        // which aliases the SSE reader's transfer buffer — see
        // `anthropic.zig`'s `StreamState.onLine` for the same note.
        var parsed = json.parseFromSlice(json.Value, self.allocator, data, .{ .allocate = .alloc_always }) catch |err| {
            std.log.warn("openai-compatible stream: unparseable SSE data line ({t}): {s}", .{ err, data[0..@min(data.len, 200)] });
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        if (obj.get("error")) |e| {
            if (e == .object) {
                self.err = .{
                    .type = try self.allocator.dupe(u8, jsonStr(e.object, "type")),
                    .message = try self.allocator.dupe(u8, jsonStr(e.object, "message")),
                };
            }
            return;
        }

        const choices = obj.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return;

        if (choice.object.get("finish_reason")) |fr| {
            if (fr == .string and fr.string.len > 0) {
                self.stop_reason_str = try self.allocator.dupe(u8, fr.string);
            }
        }

        const delta = choice.object.get("delta") orelse return;
        if (delta != .object) return;

        if (delta.object.get("content")) |c| {
            if (c == .string and c.string.len > 0) {
                try self.visible_text.appendSlice(self.allocator, c.string);
                self.stream_sink.report(try self.allocator.dupe(u8, self.visible_text.items));
            }
        }
        const reasoning = delta.object.get("reasoning_content") orelse delta.object.get("reasoning");
        if (reasoning) |r| {
            if (r == .string and r.string.len > 0) try self.reasoning_text.appendSlice(self.allocator, r.string);
        }

        if (delta.object.get("tool_calls")) |tcs| {
            if (tcs == .array) {
                for (tcs.array.items) |item| {
                    if (item != .object) continue;
                    self.saw_tool_calls_finish = true;
                    const idx: i64 = if (item.object.get("index")) |iv| (if (iv == .integer) iv.integer else 0) else 0;
                    const accum = try self.findOrCreateToolCall(idx);
                    if (item.object.get("id")) |idv| {
                        if (idv == .string and idv.string.len > 0) try accum.id.appendSlice(self.allocator, idv.string);
                    }
                    if (item.object.get("function")) |fnv| {
                        if (fnv == .object) {
                            if (fnv.object.get("name")) |nv| {
                                if (nv == .string and nv.string.len > 0) try accum.name.appendSlice(self.allocator, nv.string);
                            }
                            if (fnv.object.get("arguments")) |av| {
                                if (av == .string) try accum.arguments.appendSlice(self.allocator, av.string);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Assembles the final `llm.ChatResponse` once the stream has ended —
    /// mirrors `chatFn`'s own block-building tail exactly (same
    /// `show_thinking` branches, same empty-arguments-becomes-`{}`
    /// handling), just reading from accumulated stream state instead of one
    /// parsed `ChatCompletionResponse`.
    fn finalize(self: *StreamState, allocator: std.mem.Allocator) !llm.ChatResponse {
        var blocks: std.ArrayList(llm.ContentBlock) = .empty;

        if (self.show_thinking) {
            if (self.reasoning_text.items.len > 0) {
                try blocks.append(allocator, .{ .text = try std.fmt.allocPrint(allocator, "\u{1F4AD} {s}\n\n", .{self.reasoning_text.items}) });
            }
            if (self.visible_text.items.len > 0) try blocks.append(allocator, .{ .text = self.visible_text.items });
        } else if (self.visible_text.items.len > 0) {
            var c = try stripThinkingBlock(allocator, self.visible_text.items, "think");
            c = try stripThinkingBlock(allocator, c, "thinking");
            c = std.mem.trim(u8, c, " \t\r\n");
            if (c.len > 0) try blocks.append(allocator, .{ .text = c });
        }

        for (self.tool_calls.items) |tc| {
            const args_src = if (tc.arguments.items.len == 0) "{}" else tc.arguments.items;
            const args = json.parseFromSlice(json.Value, allocator, args_src, .{ .allocate = .alloc_always }) catch |err| {
                std.log.err("tool call '{s}' has unparseable streamed arguments ({t}): {s}", .{
                    tc.name.items, err, args_src[0..@min(args_src.len, 400)],
                });
                return err;
            };
            try blocks.append(allocator, .{ .tool_use = .{ .id = tc.id.items, .name = tc.name.items, .input = args.value } });
        }

        const stop_reason: llm.StopReason = if (self.saw_tool_calls_finish or std.mem.eql(u8, self.stop_reason_str, "tool_calls"))
            .tool_use
        else if (std.mem.eql(u8, self.stop_reason_str, "stop"))
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

test "stripThinkingBlock removes a single <think> span" {
    const out = try stripThinkingBlock(testing.allocator, "<think>pondering...</think>the answer is 4", "think");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("the answer is 4", out);
}

test "stripThinkingBlock removes multiple spans and leaves surrounding text" {
    const out = try stripThinkingBlock(testing.allocator, "a<think>x</think>b<think>y</think>c", "think");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc", out);
}

test "stripThinkingBlock drops everything after an unterminated tag" {
    const out = try stripThinkingBlock(testing.allocator, "before<think>never closes", "think");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("before", out);
}

test "stripThinkingBlock returns the input unchanged when the tag never appears" {
    const input = "just a normal reply";
    const out = try stripThinkingBlock(testing.allocator, input, "think");
    try testing.expectEqualStrings(input, out);
}

// `StreamState.onLine` is fed canned SSE lines directly, same "deterministic
// and offline" philosophy as the response-body tests above, at the
// SSE-chunk granularity instead of one whole JSON body.

const Recorder = struct {
    reports: std.ArrayList([]const u8) = .empty,

    fn sink(self: *Recorder) llm.StreamSink {
        return .{ .ptr = self, .onText = onText };
    }
    fn onText(ptr: *anyopaque, text_so_far: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.reports.append(testing.allocator, text_so_far) catch {};
    }
};

fn feedLines(state: *StreamState, lines: []const []const u8) !void {
    const line_sink = state.sink();
    for (lines) |line| try line_sink.onLine(line_sink.ptr, line);
}

test "StreamState assembles multi-chunk content deltas, reporting cumulative text each time, until [DONE]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink(), .show_thinking = true };

    try feedLines(&state, &.{
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\", world\"}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
        "data: [DONE]",
    });

    const response = try state.finalize(a);
    try testing.expectEqual(@as(usize, 1), response.content.len);
    try testing.expectEqualStrings("Hello, world", response.content[0].text);
    try testing.expectEqual(llm.StopReason.end_turn, response.stop_reason);

    try testing.expectEqual(@as(usize, 2), recorder.reports.items.len);
    try testing.expectEqualStrings("Hello", recorder.reports.items[0]);
    try testing.expectEqualStrings("Hello, world", recorder.reports.items[1]);
}

test "StreamState reassembles a tool call streamed across several argument fragments, keyed by index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink(), .show_thinking = true };

    try feedLines(&state, &.{
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"weather\",\"arguments\":\"\"}}]}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"locat\"}}]}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"ion\\\":\\\"Tokyo\\\"}\"}}]}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
        "data: [DONE]",
    });

    const response = try state.finalize(a);
    try testing.expectEqual(@as(usize, 1), response.content.len);
    const tu = response.content[0].tool_use;
    try testing.expectEqualStrings("call_1", tu.id);
    try testing.expectEqualStrings("weather", tu.name);
    try testing.expectEqualStrings("Tokyo", tu.input.object.get("location").?.string);
    try testing.expectEqual(llm.StopReason.tool_use, response.stop_reason);
    try testing.expectEqual(@as(usize, 0), recorder.reports.items.len);
}

test "StreamState streams raw content live but strips <think> tags from the finalized response when show_thinking is false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink(), .show_thinking = false };

    try feedLines(&state, &.{
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"<think>pondering\"}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"...</think>the answer is 4\"}}]}",
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
    });

    // Live reporting is unconditional (see `StreamState.visible_text`'s doc
    // comment) — the raw, untrimmed tag is visible mid-stream...
    try testing.expectEqual(@as(usize, 2), recorder.reports.items.len);
    try testing.expect(std.mem.indexOf(u8, recorder.reports.items[0], "<think>") != null);

    // ...but the finalized response has it cleaned up, same as the
    // non-streaming path.
    const response = try state.finalize(a);
    try testing.expectEqual(@as(usize, 1), response.content.len);
    try testing.expectEqualStrings("the answer is 4", response.content[0].text);
}

test "StreamState captures a mid-stream error event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink(), .show_thinking = true };

    try feedLines(&state, &.{
        "data: {\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad request\"}}",
    });

    try testing.expect(state.err != null);
    try testing.expectEqualStrings("invalid_request_error", state.err.?.type);
    try testing.expectEqualStrings("bad request", state.err.?.message);
}
