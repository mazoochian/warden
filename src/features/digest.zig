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

/// Local (non-LLM) stats + an LLM-written summary of recent discussion,
/// grounded in this chat's own logged history. If nothing's been said
/// since the last digest, skips the LLM call entirely.
pub fn generate(provider: llm.Provider, allocator: std.mem.Allocator, ctx: registry.ToolContext, pool: *PgPool, chat_id: i64) ![]const u8 {
    const s = try stats.compute(pool, allocator, chat_id, 5);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("Digest: {d} messages, {d} active users since last digest.\n", .{ s.total_messages, s.distinct_users });

    if (s.total_messages == 0) {
        return buf.writer.buffered();
    }

    const history = try messages.recentFormatted(pool, allocator, chat_id, history_window);
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Recent chat history:\n{s}\n\nWrite the digest summary now.",
        .{history},
    );

    // Not a live chat reply anyone's watching mid-generation (no ticker/
    // Progress consumer is wired up here anyway — `.{}` above is a no-op
    // Progress), so streaming would have zero visible effect either way.
    // show_thinking=false regardless of any chat's own preference — a wall
    // of chain-of-thought has no place in a summary digest. max_tokens
    // matches ChatRequest's own pre-existing default (unset before this
    // became an explicit `toolcall.run` parameter).
    const summary = toolcall.run(provider, allocator, ctx, system_prompt, prompt, &.{}, .{}, false, false, 1024) catch |err| blk: {
        std.log.err("digest: llm summary failed: {t}", .{err});
        break :blk "";
    };
    if (summary.len > 0) {
        try w.print("\n{s}\n", .{summary});
    }

    return buf.writer.buffered();
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
