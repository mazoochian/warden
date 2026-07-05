const std = @import("std");
const registry = @import("registry.zig");
const diagram = @import("../features/diagram.zig");

const Args = struct { mermaid: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "draw_diagram",
    .description = "Renders a Mermaid diagram (flowchart, sequence diagram, class diagram, timeline, etc.) and sends it as an image directly to this chat. Provide valid Mermaid syntax. Use this whenever a diagram would explain something better than text — e.g. summarizing a process, decision flow, or structure discussed in the chat.",
    .input_schema_json =
        \\{"type":"object","properties":{"mermaid":{"type":"string","description":"Valid Mermaid diagram source, e.g. \"flowchart TD\\n  A --> B\""}},"required":["mermaid"]}
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

    const png = diagram.render(ctx.allocator, ctx.io, tmp_dir, parsed.value.mermaid) catch |err| {
        std.log.err("draw_diagram: render failed: {t}", .{err});
        return std.fmt.allocPrint(
            ctx.allocator,
            "Failed to render that diagram (the Mermaid syntax may be invalid): {t}",
            .{err},
        );
    };

    connector.sendPhoto(ctx.allocator, chat_id, png, null);
    return "Diagram sent to the chat.";
}

test "tool schema is valid JSON" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
