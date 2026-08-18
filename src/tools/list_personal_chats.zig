const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    query: ?[]const u8 = null,
};

/// Companion to `summarize_unread_chat`/`send_personal_message` for the
/// personal-account (TDLib) connector: lets the owner ask "which chats do
/// I have with X" or "what chats do you see" and get a real answer instead
/// of having to type `/tdchats`/`/tdsearch` themselves -- also how the
/// model finds a chat's exact id/title before calling
/// `send_personal_message`, when the owner's phrasing alone doesn't
/// resolve cleanly. Same "sink formats its own listing, no nested LLM
/// call" shape as `catch_me_up`/`summarize_unread_chat`.
pub const tool: registry.ToolDef = .{
    .name = "list_personal_chats",
    .description = "Lists the personal Telegram account's known chats (id and title). Pass `query` to narrow it to chats whose title contains that text (case-insensitive); omit it to list everything. Use this to find a chat's exact id/title before calling send_personal_message or summarize_unread_chat, or when the owner just asks what chats exist.",
    .input_schema_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Optional title substring to filter by, case-insensitive."}},"required":[]}
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

    return sink.listChats(ctx.allocator, parsed.value.query);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_query: ?[]const u8 = null,
    called: bool = false,
    result_text: []const u8 = "1 — Alice\n2 — Bob",

    fn sink(self: *FakeSink) registry.PersonalAccountSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.PersonalAccountSink.VTable = .{
        .summarizeUnread = unusedSummarizeFn,
        .listChats = listChatsFn,
        .sendMessage = unusedSendMessageFn,
    };

    fn listChatsFn(ptr: *anyopaque, allocator: std.mem.Allocator, query: ?[]const u8) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.called = true;
        self.requested_query = query;
        return self.result_text;
    }

    fn unusedSummarizeFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = chat_query;
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

test "execute passes an explicit query through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .personal_account = fake.sink() };

    const out = try execute(ctx, "{\"query\":\"alice\"}");
    try testing.expectEqualStrings("alice", fake.requested_query.?);
    try testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
}

test "execute omits the query entirely when the arg is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .personal_account = fake.sink() };

    _ = try execute(ctx, "{}");
    try testing.expect(fake.called);
    try testing.expectEqual(@as(?[]const u8, null), fake.requested_query);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{}"));
}
