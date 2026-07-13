const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { word: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "dictionary",
    .description = "Looks up an English word: definitions by part of speech, phonetics, and usage examples (dictionaryapi.dev, no API key).",
    .input_schema_json =
        \\{"type":"object","properties":{"word":{"type":"string","description":"A single English word, e.g. \"serendipity\""}},"required":["word"]}
    ,
    .execute = execute,
};

const Definition = struct {
    definition: []const u8 = "",
    example: ?[]const u8 = null,
};

const Meaning = struct {
    partOfSpeech: []const u8 = "",
    definitions: []Definition = &.{},
};

const Entry = struct {
    word: []const u8 = "",
    phonetic: ?[]const u8 = null,
    meanings: []Meaning = &.{},
};

const max_meanings = 3;
const max_definitions_per_meaning = 2;

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const encoded = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.word);
    defer ctx.allocator.free(encoded);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://api.dictionaryapi.dev/api/v2/entries/en/{s}",
        .{encoded},
    );
    defer ctx.allocator.free(url);

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    // The API answers 404 for unknown words, which `get` turns into an
    // error — report that as a normal "not found" rather than failing.
    const body = http_util.get(&client, ctx.allocator, url) catch {
        return std.fmt.allocPrint(ctx.allocator, "No dictionary entry found for \"{s}\".", .{parsed.value.word});
    };
    defer ctx.allocator.free(body);

    return formatEntries(ctx.allocator, body);
}

/// Renders the first entry's meanings compactly. Split out for offline
/// testing.
fn formatEntries(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try json.parseFromSlice(
        []Entry,
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    if (parsed.value.len == 0) return allocator.dupe(u8, "No dictionary entry found.");
    const entry = parsed.value[0];

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.print("{s}", .{entry.word});
    if (entry.phonetic) |p| try w.print(" {s}", .{p});
    try w.writeAll("\n");

    for (entry.meanings, 0..) |meaning, i| {
        if (i >= max_meanings) break;
        try w.print("{s}:\n", .{meaning.partOfSpeech});
        for (meaning.definitions, 0..) |def, j| {
            if (j >= max_definitions_per_meaning) break;
            try w.print("- {s}\n", .{def.definition});
            if (def.example) |ex| try w.print("  e.g. \"{s}\"\n", .{ex});
        }
    }

    return allocator.dupe(u8, std.mem.trimEnd(u8, buf.writer.buffered(), "\n"));
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "formatEntries renders word, phonetic, and capped meanings" {
    const body =
        \\[{"word":"test","phonetic":"/tɛst/","meanings":[
        \\  {"partOfSpeech":"noun","definitions":[
        \\    {"definition":"A challenge, trial.","example":"a test of strength"},
        \\    {"definition":"An examination."},
        \\    {"definition":"Ignored, past the cap."}
        \\  ]},
        \\  {"partOfSpeech":"verb","definitions":[{"definition":"To challenge."}]}
        \\]}]
    ;
    const out = try formatEntries(testing.allocator, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "test /tɛst/\nnoun:\n- A challenge, trial.\n  e.g. \"a test of strength\"\n- An examination.\nverb:\n- To challenge.",
        out,
    );
}
