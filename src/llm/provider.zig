const std = @import("std");
const json = std.json;

pub const Role = enum { user, assistant };

pub const ToolUse = struct {
    /// Provider-issued id; must be echoed back in the matching `ToolResult`.
    id: []const u8,
    name: []const u8,
    /// Arguments the model wants to call the tool with. Borrows from
    /// whatever arena backs the response that produced it — see the note
    /// on `ChatResponse`.
    input: json.Value,
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
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

pub const StopReason = enum { end_turn, tool_use, other };

/// Wraps a span of answer text that represents a reasoning model's
/// chain-of-thought (see `llm/openai_compat.zig`'s use in place of the old
/// bare "💭 " prefix) — platform-neutral on purpose: what a *renderer* does
/// with a wrapped span (Telegram: an expandable blockquote, see
/// `telegram/markdown_html.zig`; a platform with no special treatment yet:
/// nothing, or strip the markers and show it plain) is that renderer's own
/// decision, not something an LLM provider adapter should know about.
/// Control bytes, never legitimately present in real model output, so they
/// can't collide with anything the model writes and need no escaping.
pub const thinking_start = "\x02";
pub const thinking_end = "\x03";

pub const ChatRequest = struct {
    /// Top-level system prompt (Anthropic's shape); the OpenAI-compatible
    /// adapter folds this into a leading system-role message instead.
    system: ?[]const u8 = null,
    messages: []const ChatMessage,
    tools: []const Tool = &.{},
    max_tokens: u32 = 1024,
    /// Whether a reasoning model's chain-of-thought is passed through to
    /// the caller. Per-request (not per-provider) since it's now a
    /// per-chat-overridable setting (see `chat_settings.getShowThinkingOverride`)
    /// and providers are long-lived singletons shared across every chat —
    /// only `llm/openai_compat.zig` currently interprets this (filtering
    /// `reasoning_content`/`reasoning` fields and inline `<think>` tags, see
    /// its `stripThinkingBlock`); Anthropic ignores it, same as it already
    /// ignores fields it has no equivalent concept for.
    show_thinking: bool = false,
};

/// `content` (specifically any `ToolUse.input`) borrows from an internal
/// arena the adapter deliberately never frees — callers are expected to run
/// requests against an arena allocator themselves (as `main.zig`'s poll
/// loop does per cycle) so this rides along and gets reclaimed for free.
/// Don't call this with `std.testing.allocator` directly without wrapping
/// it in your own arena first.
pub const ChatResponse = struct {
    content: []const ContentBlock,
    stop_reason: StopReason,
};

/// Reports progressively-generated answer text during a `Provider.chatStream`
/// call. `text_so_far` is the *cumulative* visible text at each report (not
/// a delta), so callers (see `toolcall.Progress`) can display it as-is
/// without concatenating anything themselves. Same ptr+fn shape as
/// `toolcall.Progress`, deliberately defined here rather than there: this
/// module must not depend on `toolcall.zig` (the dependency runs the other
/// way), but a provider adapter needs a sink type to report through.
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
        /// Optional streaming variant: reports growing cumulative text via
        /// `sink` as it arrives, but still returns the same full
        /// `ChatResponse` at the end (tool_use blocks are assembled whole,
        /// same as `chat` — only visible text streams). A provider that
        /// doesn't implement this leaves the slot null; `chatStream`'s
        /// wrapper below falls back to one blocking `chat()` call plus a
        /// single final `sink.report()`, so every caller can call
        /// `chatStream` unconditionally regardless of provider support —
        /// same "optional slot, dumb fallback" convention as
        /// `platform.Connector.sendPhoto`.
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

/// Concatenates all `text` blocks; tool_use/tool_result blocks contribute
/// nothing (a response that's pure tool calls has no visible text yet).
pub fn textOf(allocator: std.mem.Allocator, content: []const ContentBlock) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (content) |block| {
        switch (block) {
            .text => |t| try buf.appendSlice(allocator, t),
            .tool_use, .tool_result => {},
        }
    }
    return buf.toOwnedSlice(allocator);
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
