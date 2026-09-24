const std = @import("std");
const json = std.json;

pub const Role = enum { user, assistant };

pub const ToolUse = struct {
    /// Provider-issued id; must be echoed back in the matching `ToolResult`.
    id: []const u8,
    name: []const u8,
    /// Arguments the model wants to call the tool with.
    input: json.Value,
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

/// A base64-encoded image, attached alongside a `.text` block in the same
/// message's `content`.
pub const ImageBlock = struct {
    media_type: []const u8,
    base64_data: []const u8,
};

/// A base64-encoded document (currently only PDF), attached alongside a
/// `.text` block the same way `ImageBlock` is.
pub const DocumentBlock = struct {
    media_type: []const u8,
    base64_data: []const u8,
};

/// Which wire field a backend used to carry a reasoning model's chain-of-
/// thought.
pub const ReasoningField = enum { reasoning_content, reasoning };

/// A reasoning model's chain-of-thought for one assistant turn, kept in the
/// conversation so it can be handed back on the next turn.
pub const ThinkingBlock = struct {
    text: []const u8,
    field: ReasoningField,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    thinking: ThinkingBlock,
    image: ImageBlock,
    document: DocumentBlock,
    tool_use: ToolUse,
    tool_result: ToolResult,
};

pub const ChatMessage = struct {
    role: Role,
    content: []const ContentBlock,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON Schema object text, e.g.
    /// `{"type":"object","properties":{"x":{"type":"string"}},"required":["x"]}`.
    input_schema_json: []const u8,
};

/// `max_tokens`: the response was cut off by the request's token budget
/// (Anthropic `max_tokens`, OpenAI-style `length`).
pub const StopReason = enum { end_turn, tool_use, max_tokens, other };

/// Wraps a span of answer text that represents a reasoning model's chain-of-
/// thought.
pub const thinking_start = "\x02";
pub const thinking_end = "\x03";

/// Fallback rendering of thinking spans for any surface that can't do
/// something richer with them — the marker bytes are control characters.
pub fn renderThinkingPlain(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, thinking_start) == null and
        std.mem.indexOf(u8, text, thinking_end) == null) return text;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], thinking_start)) {
            try out.appendSlice(allocator, "\u{1F4AD} ");
            i += thinking_start.len;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], thinking_end)) {
            i += thinking_end.len;
            // Only separate the thought from what follows if anything actually does.
            if (i < text.len) try out.appendSlice(allocator, "\n\n");
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "renderThinkingPlain turns a thinking span into a thought paragraph" {
    const a = std.testing.allocator;
    const out = try renderThinkingPlain(a, thinking_start ++ "pondering" ++ thinking_end ++ "the answer is 4");
    defer a.free(out);
    try std.testing.expectEqualStrings("\u{1F4AD} pondering\n\nthe answer is 4", out);
}

test "renderThinkingPlain leaves text with no markers untouched and allocates nothing" {
    const a = std.testing.allocator;
    const plain = "just an answer";
    // Returned by reference, so there is nothing to free -- the common case
    // must not pay for a copy.
    try std.testing.expectEqual(plain.ptr, (try renderThinkingPlain(a, plain)).ptr);
}

test "renderThinkingPlain handles an unterminated span rather than dropping it" {
    const a = std.testing.allocator;
    const out = try renderThinkingPlain(a, thinking_start ++ "still thinking");
    defer a.free(out);
    try std.testing.expectEqualStrings("\u{1F4AD} still thinking", out);
}

pub const ChatRequest = struct {
    /// Top-level system prompt (Anthropic's shape); the OpenAI-compatible
    /// adapter folds this into a leading system-role message instead.
    system: ?[]const u8 = null,
    messages: []const ChatMessage,
    tools: []const Tool = &.{},
    max_tokens: u32 = 1024,
    /// Whether a reasoning model's chain-of-thought is passed through to the
    /// caller.
    show_thinking: bool = false,
};

/// `content` (specifically any `ToolUse.input`) borrows from an internal
/// arena the adapter deliberately never frees.
pub const ChatResponse = struct {
    content: []const ContentBlock,
    stop_reason: StopReason,
};

/// Reports progressively-generated answer text during a `Provider.chatStream`
/// call.
pub const StreamSink = struct {
    ptr: *anyopaque = undefined,
    onText: ?*const fn (ptr: *anyopaque, text_so_far: []const u8) void = null,

    pub fn report(self: StreamSink, text_so_far: []const u8) void {
        if (self.onText) |f| f(self.ptr, text_so_far);
    }
};

/// Vtable-based LLM backend, same ptr+vtable idiom as `platform.Connector`.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        chat: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest) anyerror!ChatResponse,
        /// Optional streaming variant.
        chatStream: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, sink: StreamSink) anyerror!ChatResponse = null,
    };

    pub fn chat(self: Provider, allocator: std.mem.Allocator, request: ChatRequest) !ChatResponse {
        return self.vtable.chat(self.ptr, allocator, request);
    }

    pub fn chatStream(self: Provider, allocator: std.mem.Allocator, request: ChatRequest, sink: StreamSink) !ChatResponse {
        const f = self.vtable.chatStream orelse {
            const response = try self.chat(allocator, request);
            sink.report(try textOf(allocator, response.content));
            return response;
        };
        return f(self.ptr, allocator, request, sink);
    }
};

/// Concatenates all `text` blocks; every other block type contributes
/// nothing.
pub fn textOf(allocator: std.mem.Allocator, content: []const ContentBlock) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (content) |block| {
        switch (block) {
            .text => |t| try buf.appendSlice(allocator, t),
            .thinking, .image, .document, .tool_use, .tool_result => {},
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Like `textOf`, but with every `thinking` block rendered ahead of the text
/// as a `thinking_start`/`thinking_end` span.
pub fn textWithThinkingOf(allocator: std.mem.Allocator, content: []const ContentBlock) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (content) |block| {
        switch (block) {
            .thinking => |t| if (t.text.len > 0) try buf.print(allocator, "{s}{s}{s}\n\n", .{ thinking_start, t.text, thinking_end }),
            else => {},
        }
    }
    for (content) |block| {
        switch (block) {
            .text => |t| try buf.appendSlice(allocator, t),
            else => {},
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Total length of every `thinking` block -- for the log line that
/// explains an empty visible answer.
pub fn thinkingLenOf(content: []const ContentBlock) usize {
    var n: usize = 0;
    for (content) |block| {
        if (block == .thinking) n += block.thinking.text.len;
    }
    return n;
}

const testing = std.testing;

test "Provider.chatStream falls back to chat() plus one final sink.report() when chatStream isn't implemented" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NonStreamingProvider = struct {
        fn provider(self: *@This()) Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: Provider.VTable = .{ .chat = chatFn };
        fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest) anyerror!ChatResponse {
            _ = ptr;
            _ = request;
            return .{
                .content = try allocator.dupe(ContentBlock, &.{.{ .text = "hello" }}),
                .stop_reason = .end_turn,
            };
        }
    };

    const Recorder = struct {
        reports: std.ArrayList([]const u8) = .empty,
        fn sink(self: *@This()) StreamSink {
            return .{ .ptr = self, .onText = onText };
        }
        fn onText(ptr: *anyopaque, text_so_far: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.reports.append(std.testing.allocator, text_so_far) catch {};
        }
    };

    var non_streaming = NonStreamingProvider{};
    var recorder = Recorder{};
    defer recorder.reports.deinit(testing.allocator);

    const response = try non_streaming.provider().chatStream(a, .{ .messages = &.{} }, recorder.sink());
    try testing.expectEqualStrings("hello", try textOf(a, response.content));
    try testing.expectEqual(@as(usize, 1), recorder.reports.items.len);
    try testing.expectEqualStrings("hello", recorder.reports.items[0]);
}

test "textWithThinkingOf renders thinking ahead of the text; textOf leaves it out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content: []const ContentBlock = &.{
        .{ .thinking = .{ .text = "hmm", .field = .reasoning_content } },
        .{ .text = "four" },
    };
    try testing.expectEqualStrings("four", try textOf(a, content));
    try testing.expectEqualStrings(thinking_start ++ "hmm" ++ thinking_end ++ "\n\nfour", try textWithThinkingOf(a, content));
    try testing.expectEqual(@as(usize, 3), thinkingLenOf(content));
}
