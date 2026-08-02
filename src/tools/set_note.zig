const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const max_note_text_len = 1000;

const Args = struct {
    action: []const u8,
    text: ?[]const u8 = null,
    id: ?i64 = null,
};

pub const tool: registry.ToolDef = .{
    .name = "set_note",
    .description = "Adds, lists, or deletes freeform notes for this chat -- a general-purpose personal knowledge base covering notes, shopping lists, reading lists, wishlists, packing lists, bucket lists, meeting notes, or anything else the user wants remembered as a short line of text. There is no structure beyond plain text -- for a shopping list, each item is its own note (action=create called once per item, or one note per line if the user gives you several at once). For action=delete, use the id from action=list.",
    .input_schema_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["create","list","delete"],"description":"What to do"},"text":{"type":"string","description":"Only for action=create. The note's text"},"id":{"type":"integer","description":"Only for action=delete. The note id to delete"}},"required":["action"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.notes orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.eql(u8, args.action, "list")) {
        return sink.listAll(ctx.allocator);
    }

    if (std.mem.eql(u8, args.action, "delete")) {
        const id = args.id orelse return "Missing id — use action=list to find the note's id first.";
        return switch (try sink.delete(ctx.allocator, id)) {
            .deleted => "Note deleted.",
            .not_found => "No note with that id in this chat.",
            .not_authorized => "Only whoever added that note (or the bot owner) can delete it.",
        };
    }

    if (!std.mem.eql(u8, args.action, "create")) {
        return "Unknown action — use \"create\", \"list\", or \"delete\".";
    }

    const text = args.text orelse return "Missing text — say what to note down.";
    if (text.len == 0) return "Missing text — say what to note down.";
    if (text.len > max_note_text_len) return "That note is too long (max 1000 bytes).";

    const id = try sink.create(ctx.allocator, text);
    return std.fmt.allocPrint(ctx.allocator, "Note #{d} added.", .{id});
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    created_text: ?[]const u8 = null,
    delete_result: registry.NoteSink.DeleteResult = .deleted,
    list_text: []const u8 = "Notes:\n  #1 milk\n",

    fn sink(self: *FakeSink) registry.NoteSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.NoteSink.VTable = .{ .create = createFn, .delete = deleteFn, .listAll = listAllFn };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!i64 {
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.created_text = try allocator.dupe(u8, text);
        return 42;
    }
    fn deleteFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!registry.NoteSink.DeleteResult {
        _ = allocator;
        _ = id;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        return self.delete_result;
    }
    fn listAllFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        return self.list_text;
    }
};

test "execute create returns the new id and forwards the text verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .notes = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"text\":\"buy milk\"}");
    try testing.expectEqualStrings("Note #42 added.", out);
    try testing.expectEqualStrings("buy milk", fake.created_text.?);
}

test "execute create rejects empty or oversized text without touching the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .notes = fake.sink() };

    const empty = try execute(ctx, "{\"action\":\"create\",\"text\":\"\"}");
    try testing.expect(std.mem.indexOf(u8, empty, "Missing text") != null);
    try testing.expectEqual(@as(?[]const u8, null), fake.created_text);
}

test "execute list forwards straight to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .notes = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"list\"}");
    try testing.expectEqualStrings(fake.list_text, out);
}

test "execute delete maps every DeleteResult to a distinct message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{ .delete_result = .not_authorized };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .notes = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"delete\",\"id\":7}");
    try testing.expect(std.mem.indexOf(u8, out, "Only whoever added") != null);
}
