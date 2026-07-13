const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { query: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "hackernews_search",
    .description = "Searches Hacker News stories (Algolia API, no key): tech news, launches, and their discussion threads. Returns title, link, points, and comment count — follow the discussion link with fetch_url if the thread itself matters.",
    .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search terms, e.g. \"zig 1.0\" or \"openwrt\""}},"required":["query"]}
    ,
    .execute = execute,
};

const Hit = struct {
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    points: i64 = 0,
    num_comments: i64 = 0,
    objectID: []const u8 = "",
};

const SearchResponse = struct {
    hits: []Hit = &.{},
};

const max_hits = 5;

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const encoded = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.query);
    defer ctx.allocator.free(encoded);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://hn.algolia.com/api/v1/search?tags=story&hitsPerPage={d}&query={s}",
        .{ max_hits, encoded },
    );
    defer ctx.allocator.free(url);

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const body = try http_util.get(&client, ctx.allocator, url);
    defer ctx.allocator.free(body);

    return formatHits(ctx.allocator, body);
}

/// Renders hits as numbered "title / link / stats" blocks. Ask-HN style
/// stories have no external URL; the discussion link covers those. Split
/// out for offline testing.
fn formatHits(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try json.parseFromSlice(
        SearchResponse,
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    if (parsed.value.hits.len == 0) return allocator.dupe(u8, "No Hacker News stories found.");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    for (parsed.value.hits, 1..) |hit, i| {
        try w.print("{d}. {s} ({d} points, {d} comments)\n", .{ i, hit.title orelse "(untitled)", hit.points, hit.num_comments });
        if (hit.url) |u| try w.print("{s}\n", .{u});
        try w.print("discussion: https://news.ycombinator.com/item?id={s}\n\n", .{hit.objectID});
    }

    return allocator.dupe(u8, std.mem.trimEnd(u8, buf.writer.buffered(), "\n"));
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "formatHits renders stories and falls back to the discussion link" {
    const body =
        \\{"hits":[
        \\  {"title":"Zig 1.0 released","url":"https://ziglang.org/news","points":900,"num_comments":420,"objectID":"1111"},
        \\  {"title":"Ask HN: Routers?","url":null,"points":50,"num_comments":30,"objectID":"2222"}
        \\]}
    ;
    const out = try formatHits(testing.allocator, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "1. Zig 1.0 released (900 points, 420 comments)\nhttps://ziglang.org/news\ndiscussion: https://news.ycombinator.com/item?id=1111\n\n2. Ask HN: Routers? (50 points, 30 comments)\ndiscussion: https://news.ycombinator.com/item?id=2222",
        out,
    );
}
