const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    chat: []const u8,
    all: bool = false,
};

/// Companion to `catch_me_up` for the personal-account (TDLib) connector:
/// lets the owner ask "what's up in <chat>" / "summarize my unread in X"
/// and get an answer grounded in that chat's actual currently-unread
/// messages, fetched fresh from Telegram and marked read as a side effect
/// — the `/tdsummary` command's natural-language counterpart. Same "just
/// fetch, let the model summarize" shape as `catch_me_up`: no nested LLM
/// call happens inside `ChatSummarySink.summarizeUnread`. `all` switches to
/// the last 100 messages regardless of read state (no mark-as-read side
/// effect in that mode) — the `/tdsummary <chat> --all` companion, direct
/// owner request (2026-08-19).
pub const tool: registry.ToolDef = .{
    .name = "summarize_unread_chat",
    .description = "Fetches messages from one of the personal Telegram account's chats. By default fetches only currently-unread messages and marks them read; pass all=true to instead fetch the last 100 messages regardless of read state (no mark-as-read side effect in that mode). `chat` can be a TDLib chat id or any substring of the chat's title/name (case-insensitive) -- use whatever the owner called it. Returns raw \"sender id: text\" lines for you to summarize yourself in your reply, not a summary -- write the actual summary yourself. Use this when the owner asks what's new/unread in a specific chat, asks you to catch them up on it, or asks for a summary of its recent/last messages.",
    .input_schema_json =
    \\{"type":"object","properties":{"chat":{"type":"string","description":"The chat to summarize -- a TDLib chat id, or any substring of the chat's title."},"all":{"type":"boolean","description":"true to summarize the last 100 messages regardless of read state, instead of just unread ones. Defaults to false."}},"required":["chat"]}
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

    return sink.summarizeUnread(ctx.allocator, parsed.value.chat, parsed.value.all);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_chat: ?[]const u8 = null,
    requested_all: ?bool = null,
    result_text: []const u8 = "\"Alice\" -- 2 unread message(s), now marked read:\nalice: hey\nalice: you around?",

    fn sink(self: *FakeSink) registry.PersonalAccountSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.PersonalAccountSink.VTable = .{
        .summarizeUnread = summarizeUnreadFn,
        .listChats = unusedListChatsFn,
        .sendMessage = unusedSendMessageFn,
    };

    fn summarizeUnreadFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, all: bool) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.requested_chat = chat_query;
        self.requested_all = all;
        return self.result_text;
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

test "execute passes the chat argument through and returns the sink's text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .personal_account = fake.sink() };

    const out = try execute(ctx, "{\"chat\":\"alice\"}");
    try testing.expectEqualStrings("alice", fake.requested_chat.?);
    try testing.expectEqual(false, fake.requested_all.?);
    try testing.expect(std.mem.indexOf(u8, out, "now marked read") != null);
}

test "execute passes all=true through when set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .personal_account = fake.sink() };

    _ = try execute(ctx, "{\"chat\":\"alice\",\"all\":true}");
    try testing.expectEqual(true, fake.requested_all.?);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{\"chat\":\"alice\"}"));
}
