const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const max_memory_text_len = 500;

const Args = struct {
    action: []const u8,
    text: ?[]const u8 = null,
    id: ?i64 = null,
};

pub const tool: registry.ToolDef = .{
    .name = "remember_memory",
    .description = "Saves, lists, or forgets a short fact about the person you're talking to -- a long-term memory that follows them across every chat, not just this one (preferences, ongoing projects, their name/role, writing style, anything worth remembering between conversations). Use action=create sparingly and only for something genuinely worth recalling later, not every detail of the current message -- a few words to a sentence, not a running log. For action=forget, use the id from action=list.",
    .input_schema_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["create","list","forget"],"description":"What to do"},"text":{"type":"string","description":"Only for action=create. The fact to remember, stated plainly (e.g. \"Prefers concise answers\", \"Works on a Zig project called warden\")"},"id":{"type":"integer","description":"Only for action=forget. The memory id to forget"}},"required":["action"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.memory orelse return error.MissingToolContext;

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

    if (std.mem.eql(u8, args.action, "forget")) {
        const id = args.id orelse return "Missing id — use action=list to find the memory's id first.";
        return switch (try sink.forget(ctx.allocator, id)) {
            .forgotten => "Memory forgotten.",
            .not_found => "No memory with that id.",
            .not_authorized => "Only the person that memory belongs to can forget it.",
        };
    }

    if (!std.mem.eql(u8, args.action, "create")) {
        return "Unknown action — use \"create\", \"list\", or \"forget\".";
    }

    const text = args.text orelse return "Missing text — say what to remember.";
    if (text.len == 0) return "Missing text — say what to remember.";
    if (text.len > max_memory_text_len) return "That's too long to remember as one fact (max 500 bytes) — try summarizing it.";

    const id = try sink.create(ctx.allocator, text);
    return std.fmt.allocPrint(ctx.allocator, "Memory #{d} saved.", .{id});
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    created_text: ?[]const u8 = null,
    forget_result: registry.MemorySink.ForgetResult = .forgotten,
    list_text: []const u8 = "Memories:\n  #1 prefers concise answers\n",

    fn sink(self: *FakeSink) registry.MemorySink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.MemorySink.VTable = .{ .create = createFn, .forget = forgetFn, .listAll = listAllFn };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!i64 {
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.created_text = try allocator.dupe(u8, text);
        return 42;
    }
    fn forgetFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!registry.MemorySink.ForgetResult {
        _ = allocator;
        _ = id;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        return self.forget_result;
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
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .memory = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"text\":\"prefers concise answers\"}");
    try testing.expectEqualStrings("Memory #42 saved.", out);
    try testing.expectEqualStrings("prefers concise answers", fake.created_text.?);
}

test "execute create rejects empty or oversized text without touching the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .memory = fake.sink() };

    const empty = try execute(ctx, "{\"action\":\"create\",\"text\":\"\"}");
    try testing.expect(std.mem.indexOf(u8, empty, "Missing text") != null);
    try testing.expectEqual(@as(?[]const u8, null), fake.created_text);
}

test "execute list forwards straight to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .memory = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"list\"}");
    try testing.expectEqualStrings(fake.list_text, out);
}

test "execute forget maps every ForgetResult to a distinct message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{ .forget_result = .not_authorized };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .memory = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"forget\",\"id\":7}");
    try testing.expect(std.mem.indexOf(u8, out, "Only the person that memory belongs to") != null);
}
