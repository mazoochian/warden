const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    chat: []const u8,
    message_id: []const u8,
    text: []const u8,
};

/// Threaded-reply counterpart to `send_personal_message`: replies to one
/// specific message in a personal-account chat rather than just posting
/// into the chat generally, so the recipient sees which message it's
/// answering. `message_id` is expected to be a `native_message_id` the
/// model already saw in a bracketed `[id]` line from `get_bulletin` or
/// `summarize_unread_chat` -- this tool doesn't validate the id against
/// anything itself (the underlying `sendMessage` call simply fails
/// silently server-side on a stale/invalid one, same as any other
/// `reply_to_message_id` the connector layer accepts), so the model must
/// only ever pass one it actually read, never invent one.
pub const tool: registry.ToolDef = .{
    .name = "reply_to_message",
    .description = "Replies to one specific message in a personal-account chat, threaded so the recipient sees which message it's answering. `chat` is a TDLib chat id or any substring of the chat's title. `message_id` must be one of the bracketed ids returned by get_bulletin or summarize_unread_chat -- never guess or invent one. Only call this when the owner has explicitly asked you to reply to that specific message.",
    .input_schema_json =
    \\{"type":"object","properties":{"chat":{"type":"string","description":"The chat to reply in -- a TDLib chat id, or any substring of the chat's title."},"message_id":{"type":"string","description":"The bracketed message id to reply to, as seen in get_bulletin or summarize_unread_chat output."},"text":{"type":"string","description":"The reply text."}},"required":["chat","message_id","text"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.personal_account orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    return sink.sendReply(ctx.allocator, parsed.value.chat, parsed.value.message_id, parsed.value.text);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_chat: ?[]const u8 = null,
    requested_message_id: ?[]const u8 = null,
    requested_text: ?[]const u8 = null,
    result_text: []const u8 = "Replied to message 42 in \"Alice\".",

    fn sink(self: *FakeSink) registry.PersonalAccountSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.PersonalAccountSink.VTable = .{
        .summarizeUnread = unusedSummarizeFn,
        .listChats = unusedListChatsFn,
        .sendMessage = unusedSendMessageFn,
        .sendReply = sendReplyFn,
    };

    fn sendReplyFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, native_message_id: []const u8, message: []const u8) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.requested_chat = chat_query;
        self.requested_message_id = native_message_id;
        self.requested_text = message;
        return self.result_text;
    }

    fn unusedSummarizeFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, all: bool) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = chat_query;
        _ = all;
        return error.Unsupported;
    }

    fn unusedListChatsFn(ptr: *anyopaque, allocator: std.mem.Allocator, query: ?[]const u8) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = query;
        return error.Unsupported;
    }

    fn unusedSendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, message: []const u8) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = chat_query;
        _ = message;
        return error.Unsupported;
    }
};

test "execute passes chat, message_id, and text through to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .personal_account = fake.sink() };

    const out = try execute(ctx, "{\"chat\":\"alice\",\"message_id\":\"42\",\"text\":\"on my way\"}");
    try testing.expectEqualStrings("alice", fake.requested_chat.?);
    try testing.expectEqualStrings("42", fake.requested_message_id.?);
    try testing.expectEqualStrings("on my way", fake.requested_text.?);
    try testing.expect(std.mem.indexOf(u8, out, "Replied") != null);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{\"chat\":\"alice\",\"message_id\":\"42\",\"text\":\"hi\"}"));
}
