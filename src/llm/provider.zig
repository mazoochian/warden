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

pub const ChatRequest = struct {
    /// Top-level system prompt (Anthropic's shape); the OpenAI-compatible
    /// adapter folds this into a leading system-role message instead.
    system: ?[]const u8 = null,
    messages: []const ChatMessage,
    tools: []const Tool = &.{},
    max_tokens: u32 = 1024,
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

/// Vtable-based LLM backend, same ptr+vtable idiom as `platform.Connector`.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        chat: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest) anyerror!ChatResponse,
    };

    pub fn chat(self: Provider, allocator: std.mem.Allocator, request: ChatRequest) !ChatResponse {
        return self.vtable.chat(self.ptr, allocator, request);
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
