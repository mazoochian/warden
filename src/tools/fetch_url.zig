const std = @import("std");
const http = std.http;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { url: []const u8 };

/// Cap so a huge page/feed can't blow up context or memory; the model gets
/// a truncated prefix and is expected to work with that.
const max_body_len = 8000;

pub const tool: registry.ToolDef = .{
    .name = "fetch_url",
    .description = "Fetches the raw text content of a URL (an article, RSS/Atom feed, or any other http(s) page) so you can read and summarize it yourself. Returns raw content, not a summary.",
    .input_schema_json =
        \\{"type":"object","properties":{"url":{"type":"string","description":"A fully-qualified http(s) URL"}},"required":["url"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try std.json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const url = parsed.value.url;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.UnsupportedUrlScheme;
    }

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const body = try http_util.get(&client, ctx.allocator, url);
    defer ctx.allocator.free(body);

    if (body.len <= max_body_len) return ctx.allocator.dupe(u8, body);
    return std.fmt.allocPrint(ctx.allocator, "{s}\n\n[truncated, {d} bytes total]", .{ body[0..max_body_len], body.len });
}

test "tool schema is valid JSON" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
