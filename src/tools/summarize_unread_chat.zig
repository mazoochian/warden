const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    chat: []const u8,
};

/// Companion to `catch_me_up` for the personal-account (TDLib) connector:
/// lets the owner ask "what's up in <chat>" / "summarize my unread in X"
/// and get an answer grounded in that chat's actual currently-unread
/// messages, fetched fresh from Telegram and marked read as a side effect
/// — the `/tdsummary` command's natural-language counterpart. Same "just
/// fetch, let the model summarize" shape as `catch_me_up`: no nested LLM
/// call happens inside `ChatSummarySink.summarizeUnread`.
pub const tool: registry.ToolDef = .{
    .name = "summarize_unread_chat",
    .description = "Fetches the personal Telegram account's currently-unread messages in one chat and marks them read. `chat` can be a TDLib chat id or any substring of the chat's title/name (case-insensitive) -- use whatever the owner called it. Returns raw \"sender id: text\" lines for you to summarize yourself in your reply, not a summary -- write the actual summary yourself. Use this when the owner asks what's new/unread in a specific chat, or asks you to catch them up on it.",
    .input_schema_json =
    \\{"type":"object","properties":{"chat":{"type":"string","description":"The chat to summarize -- a TDLib chat id, or any substring of the chat's title."}},"required":["chat"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.chat_summary orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    return sink.summarizeUnread(ctx.allocator, parsed.value.chat);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_chat: ?[]const u8 = null,
    result_text: []const u8 = "\"Alice\" -- 2 unread message(s), now marked read:\nalice: hey\nalice: you around?",

    fn sink(self: *FakeSink) registry.ChatSummarySink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.ChatSummarySink.VTable = .{ .summarizeUnread = summarizeUnreadFn };

    fn summarizeUnreadFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.requested_chat = chat_query;
        return self.result_text;
    }
};

test "execute passes the chat argument through and returns the sink's text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .chat_summary = fake.sink() };

    const out = try execute(ctx, "{\"chat\":\"alice\"}");
    try testing.expectEqualStrings("alice", fake.requested_chat.?);
    try testing.expect(std.mem.indexOf(u8, out, "now marked read") != null);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{\"chat\":\"alice\"}"));
}
