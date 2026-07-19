const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const llm = @import("provider.zig");
const http_util = @import("../http_util.zig");

const ApiError = struct {
    type: []const u8 = "",
    message: []const u8 = "",
};

/// `content` and `stop_reason` are parsed generically (as `json.Value`) since
/// content blocks have per-type shapes (text vs tool_use) that don't map to
/// one static struct.
const RawResponse = struct {
    content: json.Value = .null,
    stop_reason: []const u8 = "",
    @"error": ?ApiError = null,
};

/// Anthropic Messages API (https://api.anthropic.com/v1/messages) adapter.
pub const AnthropicProvider = struct {
    http_client: http.Client,
    api_key: []const u8,
    model: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, api_key: []const u8, model: []const u8) AnthropicProvider {
        return .{
            .http_client = .{ .allocator = allocator, .io = io },
            .api_key = api_key,
            .model = model,
        };
    }

    pub fn deinit(self: *AnthropicProvider) void {
        self.http_client.deinit();
    }

    pub fn provider(self: *AnthropicProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn, .chatStream = chatStreamFn };

    const anthropic_url = "https://api.anthropic.com/v1/messages";

    fn authHeaders(self: *const AnthropicProvider) [2]http.Header {
        return .{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };
    }

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        const payload = try buildPayload(allocator, self, request, false);
        const headers = self.authHeaders();

        const body = try http_util.postJsonWithTimeout(
            &self.http_client,
            allocator,
            anthropic_url,
            &headers,
            payload,
            http_util.llm_timeout_ns,
        );
        defer allocator.free(body);

        // Deliberately never `.deinit()`'d: `ToolUse.input` below borrows
        // from this parse's arena, and callers are expected to run
        // requests through an arena allocator themselves (main.zig's poll
        // loop resets one per cycle), so this rides along for free. See the
        // note on `llm.ChatResponse`.
        const parsed = try json.parseFromSlice(
            RawResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );

        if (parsed.value.@"error") |err| {
            std.log.err("anthropic api error: {s}: {s}", .{ err.type, err.message });
            return error.AnthropicApiError;
        }

        return .{
            .content = try parseContentBlocks(allocator, parsed.value.content),
            .stop_reason = parseStopReason(parsed.value.stop_reason),
        };
    }

    fn chatStreamFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest, sink: llm.StreamSink) anyerror!llm.ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        const payload = try buildPayload(allocator, self, request, true);
        const headers = self.authHeaders();

        var state: StreamState = .{ .allocator = allocator, .stream_sink = sink };
        try http_util.postJsonSSE(
            &self.http_client,
            allocator,
            anthropic_url,
            &headers,
            payload,
            http_util.llm_timeout_ns,
            state.sink(),
        );

        if (state.err) |err| {
            std.log.err("anthropic streaming api error: {s}: {s}", .{ err.type, err.message });
            return error.AnthropicApiError;
        }

        return .{
            .content = try state.blocks.toOwnedSlice(allocator),
            .stop_reason = state.stop_reason,
        };
    }
};

/// Shared request-body builder for both `chatFn` and `chatStreamFn` — the
/// only difference between the two is `"stream":true`. Duped into a fresh
/// allocation before returning (rather than handing back
/// `payload_writer.buffered()` directly) since `payload_writer` is a local
/// that goes out of scope here; the non-streaming call site used to build
/// this inline specifically to keep the writer's buffer alive across the
/// HTTP call within one function body — factoring it out means that trick
/// no longer applies.
fn buildPayload(allocator: std.mem.Allocator, self: *const AnthropicProvider, request: llm.ChatRequest, stream: bool) ![]const u8 {
    var payload_writer: Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();
    const w = &payload_writer.writer;

    try w.writeAll("{\"model\":");
    try json.Stringify.value(self.model, .{}, w);
    try w.print(",\"max_tokens\":{d}", .{request.max_tokens});
    // `system: null` is rejected by the API ("should be a valid string"),
    // so the field is omitted entirely rather than sent as JSON null when
    // there isn't one.
    if (request.system) |system| {
        try w.writeAll(",\"system\":");
        try json.Stringify.value(system, .{}, w);
    }
    try w.writeAll(",\"messages\":");
    try writeMessages(w, request.messages);
    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":");
        try writeTools(allocator, w, request.tools);
    }
    if (stream) try w.writeAll(",\"stream\":true");
    try w.writeByte('}');
    return allocator.dupe(u8, w.buffered());
}

fn parseStopReason(raw: []const u8) llm.StopReason {
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, raw, "end_turn")) return .end_turn;
    return .other;
}

fn writeMessages(w: *Io.Writer, messages: []const llm.ChatMessage) !void {
    try w.writeByte('[');
    for (messages, 0..) |m, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"role\":");
        try json.Stringify.value(@tagName(m.role), .{}, w);
        try w.writeAll(",\"content\":");
        try writeContentBlocks(w, m.content);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn writeContentBlocks(w: *Io.Writer, content: []const llm.ContentBlock) !void {
    try w.writeByte('[');
    for (content, 0..) |block, idx| {
        if (idx != 0) try w.writeByte(',');
        switch (block) {
            .text => |t| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try json.Stringify.value(t, .{}, w);
                try w.writeByte('}');
            },
            .tool_use => |tu| {
                try w.writeAll("{\"type\":\"tool_use\",\"id\":");
                try json.Stringify.value(tu.id, .{}, w);
                try w.writeAll(",\"name\":");
                try json.Stringify.value(tu.name, .{}, w);
                try w.writeAll(",\"input\":");
                try json.Stringify.value(tu.input, .{}, w);
                try w.writeByte('}');
            },
            .tool_result => |tr| {
                try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                try json.Stringify.value(tr.tool_use_id, .{}, w);
                try w.writeAll(",\"content\":");
                try json.Stringify.value(tr.content, .{}, w);
                if (tr.is_error) try w.writeAll(",\"is_error\":true");
                try w.writeByte('}');
            },
        }
    }
    try w.writeByte(']');
}

fn writeTools(allocator: std.mem.Allocator, w: *Io.Writer, tools: []const llm.Tool) !void {
    try w.writeByte('[');
    for (tools, 0..) |t, idx| {
        if (idx != 0) try w.writeByte(',');
        // Parsed fresh per tool into a throwaway arena-backed value: the
        // schema needs to be embedded as a real JSON object (not a quoted
        // string), and `json.Value` is the type `Stringify` knows how to
        // splice in as-is.
        var schema = try json.parseFromSlice(json.Value, allocator, t.input_schema_json, .{});
        defer schema.deinit();

        try w.writeAll("{\"name\":");
        try json.Stringify.value(t.name, .{}, w);
        try w.writeAll(",\"description\":");
        try json.Stringify.value(t.description, .{}, w);
        try w.writeAll(",\"input_schema\":");
        try json.Stringify.value(schema.value, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn parseContentBlocks(allocator: std.mem.Allocator, value: json.Value) ![]const llm.ContentBlock {
    if (value != .array) return &.{};

    var blocks: std.ArrayList(llm.ContentBlock) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const block_type = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";

        if (std.mem.eql(u8, block_type, "text")) {
            const text = if (obj.get("text")) |t| (if (t == .string) t.string else "") else "";
            try blocks.append(allocator, .{ .text = text });
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            const id = if (obj.get("id")) |v| (if (v == .string) v.string else "") else "";
            const name = if (obj.get("name")) |v| (if (v == .string) v.string else "") else "";
            const input: json.Value = obj.get("input") orelse .{ .null = {} };
            try blocks.append(allocator, .{ .tool_use = .{ .id = id, .name = name, .input = input } });
        }
    }
    return blocks.toOwnedSlice(allocator);
}

fn jsonStr(obj: json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// Incrementally assembles a `llm.ChatResponse` from Anthropic's streaming
/// SSE events (https://docs.anthropic.com/en/api/messages-streaming),
/// content-block by content-block. Anthropic's stream is a single ordered
/// sequence — at most one content block is ever "open" at a time (a
/// `content_block_stop` always precedes the next `content_block_start`) —
/// so tracking just the *current* block's state (reset on each start,
/// finalized on each stop) is enough; no need to key state by `index` the
/// way `openai_compat.zig`'s parser has to (OpenAI-style tool_call deltas
/// don't come with the same "one thing open at a time" guarantee).
const StreamState = struct {
    const CurrentBlock = union(enum) {
        none,
        text: std.ArrayList(u8),
        tool_use: struct {
            id: []const u8,
            name: []const u8,
            /// Raw JSON string accumulated from `input_json_delta`
            /// fragments — parsed into a real `json.Value` only once the
            /// block closes, matching how the non-streaming path parses
            /// `input` whole (see `parseContentBlocks`).
            json_buf: std.ArrayList(u8),
        },
    };

    allocator: std.mem.Allocator,
    stream_sink: llm.StreamSink,
    blocks: std.ArrayList(llm.ContentBlock) = .empty,
    /// Cumulative visible text across the *whole turn* so far (all closed
    /// text blocks plus whatever's been streamed of the current one) —
    /// reported to `stream_sink` on every delta. Separate from any single
    /// content block's own text (see `CurrentBlock.text` below), which
    /// only needs to span one block for `blocks` to come out correctly
    /// ordered/split.
    visible_text: std.ArrayList(u8) = .empty,
    stop_reason: llm.StopReason = .other,
    err: ?ApiError = null,
    current: CurrentBlock = .none,

    fn sink(self: *StreamState) http_util.SseLineSink {
        return .{ .ptr = self, .onLine = onLine };
    }

    fn onLine(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *StreamState = @ptrCast(@alignCast(ptr));
        if (!std.mem.startsWith(u8, line, "data:")) return; // skip event:/id:/blank/comment lines
        const data = std.mem.trim(u8, line["data:".len..], " ");
        if (data.len == 0) return;

        // `.alloc_always` so nothing in `parsed.value` aliases `data`,
        // which itself aliases the SSE reader's transfer buffer — about to
        // be overwritten by the next line read, so anything from this
        // parse that needs to outlive this one call must be copied out via
        // `self.allocator` before returning (see the `dupe` calls below).
        var parsed = json.parseFromSlice(json.Value, self.allocator, data, .{ .allocate = .alloc_always }) catch |err| {
            std.log.warn("anthropic stream: unparseable SSE data line ({t}): {s}", .{ err, data[0..@min(data.len, 200)] });
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const event_type = jsonStr(obj, "type");

        if (std.mem.eql(u8, event_type, "error")) {
            const e = obj.get("error") orelse return;
            if (e != .object) return;
            self.err = .{
                .type = try self.allocator.dupe(u8, jsonStr(e.object, "type")),
                .message = try self.allocator.dupe(u8, jsonStr(e.object, "message")),
            };
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const cb = obj.get("content_block") orelse return;
            if (cb != .object) return;
            if (std.mem.eql(u8, jsonStr(cb.object, "type"), "tool_use")) {
                self.current = .{ .tool_use = .{
                    .id = try self.allocator.dupe(u8, jsonStr(cb.object, "id")),
                    .name = try self.allocator.dupe(u8, jsonStr(cb.object, "name")),
                    .json_buf = .empty,
                } };
            } else {
                self.current = .{ .text = .empty };
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const delta = obj.get("delta") orelse return;
            if (delta != .object) return;
            const delta_type = jsonStr(delta.object, "type");
            if (std.mem.eql(u8, delta_type, "text_delta") and self.current == .text) {
                const text = jsonStr(delta.object, "text");
                if (text.len == 0) return;
                try self.current.text.appendSlice(self.allocator, text);
                try self.visible_text.appendSlice(self.allocator, text);
                self.stream_sink.report(try self.allocator.dupe(u8, self.visible_text.items));
            } else if (std.mem.eql(u8, delta_type, "input_json_delta") and self.current == .tool_use) {
                const partial = jsonStr(delta.object, "partial_json");
                try self.current.tool_use.json_buf.appendSlice(self.allocator, partial);
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_stop")) {
            switch (self.current) {
                .none => {},
                .text => |t| try self.blocks.append(self.allocator, .{ .text = t.items }),
                .tool_use => |tu| {
                    const src = if (tu.json_buf.items.len == 0) "{}" else tu.json_buf.items;
                    var input_value: json.Value = .null;
                    if (json.parseFromSlice(json.Value, self.allocator, src, .{ .allocate = .alloc_always })) |parsed_input| {
                        input_value = parsed_input.value;
                    } else |err| {
                        std.log.warn("anthropic stream: unparseable tool_use input for '{s}' ({t}): {s}", .{ tu.name, err, src[0..@min(src.len, 200)] });
                    }
                    try self.blocks.append(self.allocator, .{ .tool_use = .{ .id = tu.id, .name = tu.name, .input = input_value } });
                },
            }
            self.current = .none;
            return;
        }

        if (std.mem.eql(u8, event_type, "message_delta")) {
            const delta = obj.get("delta") orelse return;
            if (delta != .object) return;
            const raw = jsonStr(delta.object, "stop_reason");
            if (raw.len > 0) self.stop_reason = parseStopReason(raw);
            return;
        }

        // message_start/ping/message_stop and anything else carry nothing
        // this loop needs.
    }
};

const testing = std.testing;

// These parse canned response bodies rather than hitting the real API:
// deterministic and offline, unlike a live call (which was used once by
// hand to confirm the wire format/headers/error-path against the real
// Anthropic API with an invalid key — got back and correctly parsed a real
// `401 {"type":"error","error":{"type":"authentication_error",...}}`).

test "parses a plain text response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"hello world"}],"stop_reason":"end_turn"}
    ;
    const parsed = try json.parseFromSlice(RawResponse, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    try testing.expect(parsed.value.@"error" == null);

    const blocks = try parseContentBlocks(a, parsed.value.content);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqualStrings("hello world", blocks[0].text);
}

test "parses a tool_use response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"weather","input":{"location":"Tokyo"}}],"stop_reason":"tool_use"}
    ;
    const parsed = try json.parseFromSlice(RawResponse, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

    const blocks = try parseContentBlocks(a, parsed.value.content);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqualStrings("toolu_1", blocks[0].tool_use.id);
    try testing.expectEqualStrings("weather", blocks[0].tool_use.name);
    try testing.expectEqualStrings("Tokyo", blocks[0].tool_use.input.object.get("location").?.string);
}

test "parses the api error shape" {
    const body =
        \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
    ;
    var parsed = try json.parseFromSlice(
        RawResponse,
        testing.allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expect(parsed.value.@"error" != null);
    try testing.expectEqualStrings("authentication_error", parsed.value.@"error".?.type);
    try testing.expectEqualStrings("invalid x-api-key", parsed.value.@"error".?.message);
}

test "writeContentBlocks/writeMessages/writeTools produce valid embedded JSON" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeMessages(&out.writer, &.{
        .{ .role = .user, .content = &.{.{ .text = "hi" }} },
        .{ .role = .assistant, .content = &.{.{ .tool_use = .{ .id = "t1", .name = "weather", .input = .{ .null = {} } } }} },
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "t1", .content = "sunny" } }} },
    });

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, out.writer.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
}

// `StreamState.onLine` is fed canned SSE lines directly (one `sink.onLine`
// call per line, matching what `postJsonSSE` would do) — deterministic and
// offline, same philosophy as the response-body tests above, just at the
// SSE-event granularity instead of one whole JSON body.

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

test "StreamState assembles multi-chunk text_delta events into one text block, reporting cumulative text each time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink() };

    try feedLines(&state, &.{
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\", world\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "",
        "event: message_delta",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
        "",
        "event: message_stop",
        "data: {\"type\":\"message_stop\"}",
    });

    try testing.expectEqual(@as(usize, 1), state.blocks.items.len);
    try testing.expectEqualStrings("Hello, world", state.blocks.items[0].text);
    try testing.expectEqual(llm.StopReason.end_turn, state.stop_reason);

    try testing.expectEqual(@as(usize, 2), recorder.reports.items.len);
    try testing.expectEqualStrings("Hello", recorder.reports.items[0]);
    try testing.expectEqualStrings("Hello, world", recorder.reports.items[1]);
}

test "StreamState reassembles a tool call streamed across several input_json_delta fragments, without reporting it to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink() };

    try feedLines(&state, &.{
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"weather\",\"input\":{}}}",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"locat\"}}",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"ion\\\":\\\"Tokyo\\\"}\"}}",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}",
    });

    try testing.expectEqual(@as(usize, 1), state.blocks.items.len);
    const tu = state.blocks.items[0].tool_use;
    try testing.expectEqualStrings("toolu_1", tu.id);
    try testing.expectEqualStrings("weather", tu.name);
    try testing.expectEqualStrings("Tokyo", tu.input.object.get("location").?.string);
    try testing.expectEqual(llm.StopReason.tool_use, state.stop_reason);
    try testing.expectEqual(@as(usize, 0), recorder.reports.items.len);
}

test "StreamState preserves text/tool_use interleaving order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink() };

    try feedLines(&state, &.{
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Let me check.\"}}",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"weather\",\"input\":{}}}",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}",
        "data: {\"type\":\"content_block_stop\",\"index\":1}",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}",
    });

    try testing.expectEqual(@as(usize, 2), state.blocks.items.len);
    try testing.expectEqualStrings("Let me check.", state.blocks.items[0].text);
    try testing.expectEqualStrings("weather", state.blocks.items[1].tool_use.name);
}

test "StreamState captures a mid-stream error event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink() };

    try feedLines(&state, &.{
        "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
    });

    try testing.expect(state.err != null);
    try testing.expectEqualStrings("overloaded_error", state.err.?.type);
    try testing.expectEqualStrings("Overloaded", state.err.?.message);
}

test "StreamState ignores non-data SSE lines and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);
    var state = StreamState{ .allocator = a, .stream_sink = recorder.sink() };

    try feedLines(&state, &.{ "", "event: ping", "data: {\"type\":\"ping\"}", ": comment" });

    try testing.expectEqual(@as(usize, 0), state.blocks.items.len);
    try testing.expectEqual(@as(usize, 0), recorder.reports.items.len);
}
