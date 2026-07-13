const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { term: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "urban_dictionary",
    .description = "Looks up slang, memes, and internet expressions on Urban Dictionary (no API key). Use for informal words a normal dictionary won't have. Definitions are user-submitted and often crude — summarize tastefully.",
    .input_schema_json =
        \\{"type":"object","properties":{"term":{"type":"string","description":"The slang term or phrase, e.g. \"rizz\""}},"required":["term"]}
    ,
    .execute = execute,
};

const UrbanEntry = struct {
    definition: []const u8 = "",
    example: []const u8 = "",
    thumbs_up: i64 = 0,
};

const UrbanResponse = struct {
    list: []UrbanEntry = &.{},
};

const max_entries = 2;

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const encoded = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.term);
    defer ctx.allocator.free(encoded);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://api.urbandictionary.com/v0/define?term={s}",
        .{encoded},
    );
    defer ctx.allocator.free(url);

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const body = try http_util.get(&client, ctx.allocator, url);
    defer ctx.allocator.free(body);

    return formatEntries(ctx.allocator, body, parsed.value.term);
}

/// Renders the top definitions. Urban Dictionary cross-links terms with
/// [square brackets] inline; those are stripped for readability. Split out
/// for offline testing.
fn formatEntries(allocator: std.mem.Allocator, body: []const u8, term: []const u8) ![]const u8 {
    var parsed = try json.parseFromSlice(
        UrbanResponse,
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    if (parsed.value.list.len == 0) {
        return std.fmt.allocPrint(allocator, "Urban Dictionary has nothing for \"{s}\".", .{term});
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    const shown = @min(parsed.value.list.len, max_entries);
    for (parsed.value.list[0..shown], 1..) |entry, i| {
        const definition = try stripBrackets(allocator, entry.definition);
        defer allocator.free(definition);
        try w.print("{d}. ({d} upvotes) {s}\n", .{ i, entry.thumbs_up, definition });
        if (entry.example.len > 0) {
            const example = try stripBrackets(allocator, entry.example);
            defer allocator.free(example);
            try w.print("   e.g. {s}\n", .{example});
        }
    }

    return allocator.dupe(u8, std.mem.trimEnd(u8, buf.writer.buffered(), "\n"));
}

fn stripBrackets(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (s) |c| {
        if (c == '[' or c == ']') continue;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "formatEntries strips cross-link brackets and caps the list" {
    const body =
        \\{"list":[
        \\  {"definition":"How good you are with [pulling] people.","example":"he has [rizz]","thumbs_up":9000},
        \\  {"definition":"Charisma, shortened.","example":"","thumbs_up":100},
        \\  {"definition":"Past the cap.","example":"","thumbs_up":1}
        \\]}
    ;
    const out = try formatEntries(testing.allocator, body, "rizz");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "1. (9000 upvotes) How good you are with pulling people.\n   e.g. he has rizz\n2. (100 upvotes) Charisma, shortened.",
        out,
    );
}

test "formatEntries reports unknown terms plainly" {
    const out = try formatEntries(testing.allocator, "{\"list\":[]}", "xyzzy123");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "nothing") != null);
}
