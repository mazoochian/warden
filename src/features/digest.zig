const std = @import("std");
const llm = @import("../llm/provider.zig");
const toolcall = @import("../llm/toolcall.zig");
const registry = @import("../tools/registry.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const messages = @import("../store/messages.zig");
const stats = @import("../store/stats.zig");

const system_prompt =
    \\You write short digest summaries of a group chat's recent discussion
    \\for the group owner, who may not have been reading along. In 3-5
    \\sentences, summarize what was actually discussed using the message
    \\history given to you. Do not invent topics that aren't in the
    \\history, and do not comment on message counts or active users —
    \\that's reported separately.
;

const history_window = 300;

/// Visible summary budget plus the reasoning reserve: at a flat 1024 a
/// reasoning model routinely spent it all thinking, and every summary (daily
/// digest, /summary, Storage Sense resample) came back empty.
const summary_max_tokens: u32 = toolcall.thinking_token_reserve + 1024;

/// Local (non-LLM) stats + an LLM-written summary of recent discussion,
/// grounded in this chat's own logged history.
pub fn generate(provider: llm.Provider, allocator: std.mem.Allocator, ctx: registry.ToolContext, pool: *PgPool, chat_id: i64) ![]const u8 {
    const s = try stats.compute(pool, allocator, chat_id, 5);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("Digest: {d} messages, {d} active users since last digest.\n", .{ s.total_messages, s.distinct_users });

    if (s.total_messages == 0) {
        return buf.writer.buffered();
    }

    const history = try messages.recentFormatted(pool, allocator, chat_id, history_window);
    const summary = summarizeHistory(provider, allocator, ctx, history);
    if (summary.len > 0) {
        try w.print("\n{s}\n", .{summary});
    }

    return buf.writer.buffered();
}

/// The one LLM round trip both `generate` and `summarizeWindow` make.
pub fn summarizeHistory(provider: llm.Provider, allocator: std.mem.Allocator, ctx: registry.ToolContext, history: []const u8) []const u8 {
    const prompt = std.fmt.allocPrint(
        allocator,
        "Recent chat history:\n{s}\n\nWrite the digest summary now.",
        .{history},
    ) catch return "";

    return toolcall.run(provider, allocator, ctx, system_prompt, prompt, &.{}, .{}, false, false, false, false, summary_max_tokens, default_max_retries) catch |err| blk: {
        std.log.err("digest: llm summary failed: {t}", .{err});
        break :blk "";
    };
}

/// Hard ceiling on how many messages a windowed summary pulls into the
/// model's context.
const window_message_limit = 500;

/// The `/summary [hours]` surface.
pub fn summarizeWindow(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    ctx: registry.ToolContext,
    pool: *PgPool,
    chat_id: i64,
    hours: i64,
    now: i64,
) ![]const u8 {
    const history = try messages.recentSinceFormatted(pool, allocator, chat_id, now - hours * 3600, window_message_limit);
    if (history.len == 0) {
        return std.fmt.allocPrint(allocator, "Nothing to summarize — no messages in the last {d}h.", .{hours});
    }

    const summary = summarizeHistory(provider, allocator, ctx, history);
    if (summary.len == 0) return error.SummaryFailed;
    return std.fmt.allocPrint(allocator, "Summary of the last {d}h:\n\n{s}", .{ hours, summary });
}

const testing = std.testing;
const test_support = @import("../store/test_support.zig");
const chats = @import("../store/chats.zig");

test "generate skips the LLM call entirely when the chat has no messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    // Errors if ever actually called — proves the empty-chat short circuit
    // in `generate` really does skip the LLM, not just usually does.
    const PoisonProvider = struct {
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = allocator;
            _ = request;
            return error.ShouldNotBeCalled;
        }
    };
    var poison = PoisonProvider{};

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    const text = try generate(poison.provider(), a, ctx, &pool, chat_id);
    try testing.expect(std.mem.indexOf(u8, text, "0 messages") != null);
}

const identities = @import("../store/identities.zig");
const messages_store = @import("../store/messages.zig");

/// Retries for this background summariser's own model call.
const default_max_retries: u32 = @intCast(@import("../config.zig").Config.default_llm_max_retries);

/// Records the prompt it was handed and answers with a fixed sentence.
const StubProvider = struct {
    last_prompt: ?[]const u8 = null,
    answer: []const u8 = "They argued about tabs versus spaces.",

    fn provider(self: *StubProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: llm.Provider.VTable = .{ .chat = chat };
    fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *StubProvider = @ptrCast(@alignCast(ptr));
        for (request.messages) |m| {
            for (m.content) |block| {
                if (block == .text) self.last_prompt = try allocator.dupe(u8, block.text);
            }
        }
        const blocks = try allocator.alloc(llm.ContentBlock, 1);
        blocks[0] = .{ .text = self.answer };
        return .{ .content = blocks, .stop_reason = .end_turn };
    }
};

test "summarizeWindow skips the LLM entirely for an empty window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);

    const PoisonProvider = struct {
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = allocator;
            _ = request;
            return error.ShouldNotBeCalled;
        }
    };
    var poison = PoisonProvider{};

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    const text = try summarizeWindow(poison.provider(), a, ctx, &pool, chat_id, 3, 100_000);
    try testing.expect(std.mem.indexOf(u8, text, "Nothing to summarize") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3h") != null);
}

test "summarizeWindow summarizes only messages inside the requested window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat_id = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const identity_id = try identities.upsertIdentity(&pool, .{
        .platform = .telegram,
        .native_id = "1",
        .display_name = "Alice",
        .username = "alice",
        .first_seen = 1000,
        .last_seen = 1000,
    });

    const now: i64 = 100_000;
    // Inside a 2h window (30m ago), and well outside it (10h ago).
    try messages_store.insert(&pool, chat_id, identity_id, null, "inside the window", now - 1800);
    try messages_store.insert(&pool, chat_id, identity_id, null, "ancient history", now - 10 * 3600);

    var stub = StubProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    const text = try summarizeWindow(stub.provider(), a, ctx, &pool, chat_id, 2, now);

    const prompt = stub.last_prompt orelse return error.TestExpectedValue;
    try testing.expect(std.mem.indexOf(u8, prompt, "inside the window") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "ancient history") == null);

    // The window is named in the reply, and the model's text is passed
    // through verbatim rather than re-wrapped in digest stats.
    try testing.expect(std.mem.indexOf(u8, text, "last 2h") != null);
    try testing.expect(std.mem.indexOf(u8, text, "tabs versus spaces") != null);
    try testing.expect(std.mem.indexOf(u8, text, "messages,") == null);
}
