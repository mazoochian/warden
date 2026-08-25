const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    hours: ?i64 = null,
};

/// On-demand only -- no scheduler, no automatic delivery. Deliberately
/// returns raw grouped-by-chat, id-tagged lines for the model to rank and
/// write the actual bulletin from itself, the same "we just fetch, the
/// model summarizes" shape `catch_me_up.zig`'s own doc comment already
/// establishes -- there's no nested LLM call in `features/bulletin.zig`.
pub const tool: registry.ToolDef = .{
    .name = "get_bulletin",
    .description = "Fetches raw recent messages from every personal-account chat the owner has marked as monitored (set_chat_monitoring), grouped by chat and ordered by importance (high, then normal, then low), since the last bulletin was generated (or the last N hours if given, default 24 if no bulletin has ever run). Returns raw \"[id] who: text\" lines for you to rank and write the actual bulletin from -- don't just dump this back verbatim. Cite an id with reply_to_message if the owner wants to respond to something specific.",
    .input_schema_json =
    \\{"type":"object","properties":{"hours":{"type":"integer","description":"Look back this many hours instead of using the since-last-bulletin cursor. An explicit value never moves the cursor."}},"required":[]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.bulletin orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    return sink.generate(ctx.allocator, parsed.value.hours);
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    called: bool = false,
    requested_hours: ?i64 = null,
    result_text: []const u8 = "=== Family [high] ===\n[1] mom: dinner at 7?",

    fn sink(self: *FakeSink) registry.BulletinSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.BulletinSink.VTable = .{ .generate = generateFn };

    fn generateFn(ptr: *anyopaque, allocator: std.mem.Allocator, hours: ?i64) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.called = true;
        self.requested_hours = hours;
        return self.result_text;
    }
};

test "execute defaults hours to null (sink decides the cursor)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .bulletin = fake.sink() };

    const out = try execute(ctx, "{}");
    try testing.expect(fake.called);
    try testing.expectEqual(@as(?i64, null), fake.requested_hours);
    try testing.expect(std.mem.indexOf(u8, out, "Family") != null);
}

test "execute passes an explicit hours value through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .bulletin = fake.sink() };

    _ = try execute(ctx, "{\"hours\":6}");
    try testing.expectEqual(@as(?i64, 6), fake.requested_hours);
}

test "execute errors when the sink isn't configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{}"));
}
