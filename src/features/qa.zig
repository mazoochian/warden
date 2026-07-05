const std = @import("std");
const llm = @import("../llm/provider.zig");
const toolcall = @import("../llm/toolcall.zig");
const registry = @import("../tools/registry.zig");
const Db = @import("../store/db.zig").Db;
const messages = @import("../store/messages.zig");

const system_prompt =
    \\You are Warden, an assistant embedded in a Telegram chat. You are given
    \\a window of that chat's recent message history below. Answer the
    \\question using that history when it's relevant, and say plainly when
    \\the answer isn't in it rather than guessing. You also have tools
    \\available (weather, currency conversion, a calculator, and fetching a
    \\URL's raw content) — use them when they'd give a better answer than
    \\guessing.
;

const history_window = 200;

/// Grounded free-form Q&A: pulls recent local chat history (not model
/// memory) as context, then runs the tool-calling loop so the model can
/// also reach for weather/currency/calculator/fetch_url as needed.
pub fn answer(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    ctx: registry.ToolContext,
    tool_defs: []const registry.ToolDef,
    db: *Db,
    question: []const u8,
) ![]const u8 {
    const history = try messages.recentFormatted(db, allocator, history_window);

    const user_content = try std.fmt.allocPrint(
        allocator,
        "Recent chat history:\n{s}\n\nQuestion: {s}",
        .{ history, question },
    );

    return toolcall.run(provider, allocator, ctx, system_prompt, user_content, tool_defs);
}
