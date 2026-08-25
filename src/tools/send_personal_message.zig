const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    chat: []const u8,
    message: []const u8,
};

/// Companion to `/tdsend`/`/sendas` for the personal-account (TDLib)
/// connector: lets the owner ask Warden to send a message on their behalf
/// in natural language ("tell Alice I'll be 10 min late") instead of
/// typing a raw chat id. `chat` accepts a TDLib chat id or any title
/// substring (`chat_summary.resolveChat`) -- unlike the slash commands,
/// there's no "where does the target end and the message begin" ambiguity
/// here, since `chat`/`message` already arrive as separate structured
/// tool-call fields rather than one space-delimited string, so name-based
/// targeting is safe to allow directly. Same "the sink actually sends and
/// reports what happened" shape `send_personal_message`'s doc comment on
/// `PersonalAccountSink.sendMessage` describes -- an ambiguous or
/// unresolvable `chat` never sends anything, it just says so.
pub const tool: registry.ToolDef = .{
    .name = "send_personal_message",
    .description = "Sends a message through the owner's personal Telegram account to one chat, on the owner's behalf. `chat` can be a TDLib chat id or any substring of the chat's title/name (case-insensitive) -- use list_personal_chats first if you're not sure of the exact match. Only call this when the owner has actually asked you to send something -- never proactively.",
    .input_schema_json =
    \\{"type":"object","properties":{"chat":{"type":"string","description":"The chat to send to -- a TDLib chat id, or any substring of the chat's title."},"message":{"type":"string","description":"The message text to send."}},"required":["chat","message"]}
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

    return sink.sendMessage(ctx.allocator, parsed.value.chat, parsed.value.message);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_chat: ?[]const u8 = null,
    requested_message: ?[]const u8 = null,
    result_text: []const u8 = "Sent to \"Alice\".",

    fn sink(self: *FakeSink) registry.PersonalAccountSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.PersonalAccountSink.VTable = .{
        .summarizeUnread = unusedSummarizeFn,
        .listChats = unusedListChatsFn,
        .sendMessage = sendMessageFn,
        .sendReply = unusedSendReplyFn,
    };

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, message: []const u8) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.requested_chat = chat_query;
        self.requested_message = message;
        return self.result_text;
    }

    fn unusedSummarizeFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = chat_query;
        return error.Unsupported;
    }

    fn unusedListChatsFn(ptr: *anyopaque, allocator: std.mem.Allocator, query: ?[]const u8) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = query;
        return error.Unsupported;
    }

    fn unusedSendReplyFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, native_message_id: []const u8, message: []const u8) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = chat_query;
        _ = native_message_id;
        _ = message;
        return error.Unsupported;
    }
};

test "execute passes chat and message through to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .personal_account = fake.sink() };

    const out = try execute(ctx, "{\"chat\":\"alice\",\"message\":\"running late\"}");
    try testing.expectEqualStrings("alice", fake.requested_chat.?);
    try testing.expectEqualStrings("running late", fake.requested_message.?);
    try testing.expect(std.mem.indexOf(u8, out, "Sent") != null);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{\"chat\":\"alice\",\"message\":\"hi\"}"));
}
