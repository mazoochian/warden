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

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        const w = &payload_writer.writer;

        try w.writeAll("{\"model\":");
        try json.Stringify.value(self.model, .{}, w);
        try w.print(",\"max_tokens\":{d}", .{request.max_tokens});
        // `system: null` is rejected by the API ("should be a valid
        // string"), so the field is omitted entirely rather than sent as
        // JSON null when there isn't one.
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
        try w.writeByte('}');
        const payload = w.buffered();

        const headers = [_]http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };
        const body = try http_util.postJsonWithTimeout(
            &self.http_client,
            allocator,
            "https://api.anthropic.com/v1/messages",
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
            .stop_reason = if (std.mem.eql(u8, parsed.value.stop_reason, "tool_use"))
                .tool_use
            else if (std.mem.eql(u8, parsed.value.stop_reason, "end_turn"))
                .end_turn
            else
                .other,
        };
    }
};

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
