const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");
const reminder_format = @import("../features/reminder_format.zig");

const max_reminder_message_len = 500;

const Args = struct {
    action: []const u8,
    duration: ?[]const u8 = null,
    message: ?[]const u8 = null,
    id: ?i64 = null,
};

pub const tool: registry.ToolDef = .{
    .name = "set_reminder",
    .description = "Creates, lists, or cancels reminders for this chat — the friendly natural-language front end for warden's reminder system. For action=create, translate whatever time the user gave (\"in 20 minutes\", \"tomorrow\", \"in a couple hours\") into the required shorthand duration yourself: <number>m/h/d (minutes/hours/days), e.g. \"20m\", \"2h\", \"1d\" — only relative durations are supported, not specific clock times. For action=cancel, use the id from action=list or a previous create confirmation.",
    .input_schema_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["create","list","cancel"],"description":"What to do"},"duration":{"type":"string","description":"Only for action=create. Relative duration as <number>m/h/d, e.g. \"20m\", \"2h\", \"1d\""},"message":{"type":"string","description":"Only for action=create. What to remind the user about"},"id":{"type":"integer","description":"Only for action=cancel. The reminder id to cancel"}},"required":["action"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.reminders orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.eql(u8, args.action, "list")) {
        return sink.listPending(ctx.allocator);
    }

    if (std.mem.eql(u8, args.action, "cancel")) {
        const id = args.id orelse return "Missing id — use action=list to find the reminder's id first.";
        return switch (try sink.cancel(ctx.allocator, id)) {
            .canceled => "Reminder canceled.",
            .not_found => "No pending reminder with that id in this chat.",
            .not_authorized => "Only whoever set that reminder (or the bot owner) can cancel it.",
        };
    }

    if (!std.mem.eql(u8, args.action, "create")) {
        return "Unknown action — use \"create\", \"list\", or \"cancel\".";
    }

    const duration_str = args.duration orelse return "Missing duration — e.g. \"20m\", \"2h\", or \"1d\".";
    const message = args.message orelse return "Missing message — say what to remind them about.";
    if (message.len == 0) return "Missing message — say what to remind them about.";
    if (message.len > max_reminder_message_len) return "That reminder text is too long (max 500 bytes).";

    const duration_seconds = reminder_format.parseDuration(duration_str) orelse
        return "Couldn't parse that duration — use e.g. 30m, 2h, or 1d.";

    const id = try sink.create(ctx.allocator, message, ctx.now + duration_seconds);
    return std.fmt.allocPrint(ctx.allocator, "Reminder #{d} set for {s} from now.", .{ id, duration_str });
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    created: ?struct { message: []const u8, due_at: i64 } = null,
    cancel_result: registry.ReminderSink.CancelResult = .canceled,
    list_text: []const u8 = "Pending reminders:\n  #1 in 5m: test\n",

    fn sink(self: *FakeSink) registry.ReminderSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.ReminderSink.VTable = .{ .create = createFn, .cancel = cancelFn, .listPending = listPendingFn };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, message: []const u8, due_at: i64) anyerror!i64 {
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.created = .{ .message = try allocator.dupe(u8, message), .due_at = due_at };
        return 42;
    }
    fn cancelFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!registry.ReminderSink.CancelResult {
        _ = allocator;
        _ = id;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        return self.cancel_result;
    }
    fn listPendingFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        return self.list_text;
    }
};

test "execute create parses duration, applies now, and returns the new id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .now = 1000, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"duration\":\"30m\",\"message\":\"call mom\"}");
    try testing.expectEqualStrings("Reminder #42 set for 30m from now.", out);
    try testing.expectEqualStrings("call mom", fake.created.?.message);
    try testing.expectEqual(@as(i64, 1000 + 1800), fake.created.?.due_at);
}

test "execute create rejects an unparseable duration without touching the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"duration\":\"soon\",\"message\":\"x\"}");
    try testing.expect(std.mem.indexOf(u8, out, "Couldn't parse") != null);
    try testing.expectEqual(@as(?@TypeOf(fake.created.?), null), fake.created);
}

test "execute list forwards straight to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"list\"}");
    try testing.expectEqualStrings(fake.list_text, out);
}

test "execute cancel maps every CancelResult to a distinct message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{ .cancel_result = .not_authorized };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"cancel\",\"id\":7}");
    try testing.expect(std.mem.indexOf(u8, out, "Only whoever set") != null);
}
