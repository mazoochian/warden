const std = @import("std");
const http = std.http;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { query: []const u8 };

/// How many results to hand back to the model. SearXNG typically returns
/// dozens; past the first handful they stop adding signal and just burn
/// context.
const max_results = 8;
/// Snippets are clipped so one verbose result can't crowd out the rest.
const max_snippet_len = 400;

pub const tool: registry.ToolDef = .{
    .name = "web_search",
    .description = "Searches the web and returns the top results (title, URL, snippet). Use this whenever the answer needs facts beyond the chat history — current events, prices, docs, anything you're not sure about. Follow up with fetch_url to read a promising result in full.",
    .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"The search query"}},"required":["query"]}
    ,
    .execute = execute,
};

/// Subset of SearXNG's `format=json` response shape.
const SearxResponse = struct {
    results: []const SearxResult = &.{},
};

const SearxResult = struct {
    url: []const u8 = "",
    title: []const u8 = "",
    content: []const u8 = "",
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const base_url = ctx.searxng_url orelse return error.WebSearchNotConfigured;

    var parsed = try std.json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const encoded = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.query);
    defer ctx.allocator.free(encoded);

    const url = try std.fmt.allocPrint(ctx.allocator, "{s}/search?q={s}&format=json", .{ base_url, encoded });
    defer ctx.allocator.free(url);

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const body = try http_util.get(&client, ctx.allocator, url);
    defer ctx.allocator.free(body);

    return formatResults(ctx.allocator, body);
}

/// Parses a SearXNG JSON response body and renders the top results as
/// numbered "title / url / snippet" blocks for the model. Split from
/// `execute` so it's testable without a live instance.
fn formatResults(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(
        SearxResponse,
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch {
        // Most common cause: the instance has `format=json` disabled and
        // answered with an HTML error page. Say so instead of a bare parse
        // error, since it's an instance-config problem, not a query problem.
        return error.SearxngBadResponse;
    };
    defer parsed.deinit();

    const results = parsed.value.results;
    if (results.len == 0) return allocator.dupe(u8, "No results found.");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    const shown = @min(results.len, max_results);
    for (results[0..shown], 1..) |r, i| {
        const snippet = if (r.content.len > max_snippet_len) r.content[0..max_snippet_len] else r.content;
        try w.print("{d}. {s}\n{s}\n", .{ i, r.title, r.url });
        if (snippet.len > 0) try w.print("{s}\n", .{snippet});
        try w.writeAll("\n");
    }
    return allocator.dupe(u8, std.mem.trimEnd(u8, buf.writer.buffered(), "\n"));
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "formatResults renders numbered results and tolerates extra fields" {
    const body =
        \\{"query":"zig","number_of_results":2,"results":[
        \\  {"url":"https://ziglang.org","title":"Zig","content":"A language.","engine":"ddg","score":9.1},
        \\  {"url":"https://example.com","title":"Other","content":""}
        \\],"answers":[],"suggestions":["ziggurat"]}
    ;
    const out = try formatResults(testing.allocator, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "1. Zig\nhttps://ziglang.org\nA language.\n\n2. Other\nhttps://example.com",
        out,
    );
}

test "formatResults reports empty result sets plainly" {
    const out = try formatResults(testing.allocator, "{\"results\":[]}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("No results found.", out);
}

test "formatResults surfaces a config error on an HTML (non-JSON) response" {
    try testing.expectError(error.SearxngBadResponse, formatResults(testing.allocator, "<html>403</html>"));
}

test "execute without a configured instance returns a clear error" {
    const ctx = registry.ToolContext{ .allocator = testing.allocator, .io = testing.io };
    try testing.expectError(error.WebSearchNotConfigured, execute(ctx, "{\"query\":\"x\"}"));
}
