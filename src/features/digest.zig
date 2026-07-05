const std = @import("std");
const llm = @import("../llm/provider.zig");
const toolcall = @import("../llm/toolcall.zig");
const registry = @import("../tools/registry.zig");
const Db = @import("../store/db.zig").Db;
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
pub fn generate(provider: llm.Provider, allocator: std.mem.Allocator, ctx: registry.ToolContext, db: *Db) ![]const u8 {
    const s = try stats.compute(db, allocator, 5);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("Digest: {d} messages, {d} active users since last digest.\n", .{ s.total_messages, s.distinct_users });

    if (s.total_messages == 0) {
        return buf.writer.buffered();
    }

    const history = try messages.recentFormatted(db, allocator, history_window);
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Recent chat history:\n{s}\n\nWrite the digest summary now.",
        .{history},
    );

    const summary = toolcall.run(provider, allocator, ctx, system_prompt, prompt, &.{}) catch |err| blk: {
        std.log.err("digest: llm summary failed: {t}", .{err});
        break :blk "";
    };
    if (summary.len > 0) {
        try w.print("\n{s}\n", .{summary});
    }

    return buf.writer.buffered();
}

const testing = std.testing;

test "generate skips the LLM call entirely when the chat has no messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir = "zig-cache-test-digest";
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);

    var db = try Db.open(dir ++ "/digest.db");
    defer db.close();
    try @import("../store/schema.zig").migrate(&db);

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
    const text = try generate(poison.provider(), a, ctx, &db);
    try testing.expect(std.mem.indexOf(u8, text, "0 messages") != null);
}
