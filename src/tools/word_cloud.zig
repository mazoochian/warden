const std = @import("std");
const registry = @import("registry.zig");
const wordcloud = @import("../features/wordcloud.zig");

const Args = struct { text: []const u8 = "" };

/// Matches the `/wordcloud` command's own cap (see `main.zig`'s
/// `replyWithWordcloud`), so clouds look consistent regardless of source.
const max_words = 60;

pub const tool: registry.ToolDef = .{
    .name = "word_cloud",
    .description = "Builds a word-cloud image out of text you provide (an article you fetched or scraped, pasted content, etc.) and sends it directly to this chat as a photo. You must inline the full text itself in the `text` field — not a reference to an earlier tool result — since each tool call is otherwise stateless. For the group's own chat history, the user has a separate /wordcloud command instead — don't use this tool for that.",
    .input_schema_json =
        \\{"type":"object","properties":{"text":{"type":"string","description":"The full text to build the word cloud from, inlined here (not referenced from an earlier message) — the more of it, the better the cloud."}},"required":["text"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const connector = ctx.connector orelse return error.MissingToolContext;
    const chat_id = ctx.chat_id orelse return error.MissingToolContext;
    const tmp_dir = ctx.tmp_dir orelse return error.MissingToolContext;

    var parsed = try std.json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    if (parsed.value.text.len == 0) {
        return "No text was included in the tool call — pass the actual text to build the cloud from in the `text` field, not just a reference to it.";
    }

    const words = try wordcloud.topWordsFromText(ctx.allocator, parsed.value.text, max_words);
    if (words.len == 0) return "That text didn't have enough real words left to build a cloud from.";

    const png = wordcloud.render(ctx.allocator, ctx.io, tmp_dir, words) catch |err| {
        std.log.err("word_cloud: render failed: {t}", .{err});
        return std.fmt.allocPrint(ctx.allocator, "Failed to render a word cloud from that text: {t}", .{err});
    };

    connector.sendPhoto(ctx.allocator, chat_id, png, null);
    return "Word cloud sent to the chat.";
}

test "tool schema is valid JSON" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "execute without tool context (chat_id/connector/tmp_dir) fails clearly" {
    const ctx = registry.ToolContext{ .allocator = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(error.MissingToolContext, execute(ctx, "{\"text\":\"hello world\"}"));
}
