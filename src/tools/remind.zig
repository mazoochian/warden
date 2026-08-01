const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");
const reminder_format = @import("../features/reminder_format.zig");
const civil_time = @import("../text/civil_time.zig");

const max_reminder_message_len = 500;

const Args = struct {
    action: []const u8,
    duration: ?[]const u8 = null,
    recur: ?[]const u8 = null,
    message: ?[]const u8 = null,
    id: ?i64 = null,
};

pub const tool: registry.ToolDef = .{
    .name = "set_reminder",
    .description = "Creates, lists, or cancels reminders for this chat — the friendly natural-language front end for warden's reminder system. For action=create, translate whatever time the user gave into `duration`: a relative shorthand <number>m/h/d (minutes/hours/days), e.g. \"20m\", \"2h\", \"1d\" (for \"in 20 minutes\", \"tomorrow\", \"in a couple hours\"); a 24h clock time like \"14:30\" (for \"at 2:30pm\", \"at 9\") which resolves to the next time that clock time occurs; or a weekday name like \"friday\" (for \"this Friday\", \"on Monday\", \"next Tuesday\") which resolves to the coming occurrence of that day — today if today already is that day and the time hasn't passed yet, otherwise the next one, at most a week out. IMPORTANT: for a weekday name, pass just the day (plus an optional clock time, e.g. \"friday 18:00\") and nothing else — do NOT try to compute how many days away that is yourself, since you do not reliably know what day of the week today is; the server resolves the real calendar date. If the user names a day but no specific time (\"remind me Friday\", \"remind me to do X on Monday\"), pass the day alone — it defaults to 06:00 that day, a reasonable stand-in for \"sometime that day\" rather than firing at whatever second `duration` is being decided. `duration` always sets the first firing. To make it repeat after that (\"every day\", \"every 2 hours\"), also set `recur` to a relative shorthand interval — e.g. duration=\"1h\", recur=\"1d\" first fires in an hour, then every day after. For action=cancel, use the id from action=list or a previous create confirmation.",
    .input_schema_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["create","list","cancel"],"description":"What to do"},"duration":{"type":"string","description":"Only for action=create. Relative duration as <number>m/h/d (e.g. \"20m\", \"2h\", \"1d\"); a 24h clock time like \"14:30\"; or a weekday name like \"friday\" (optionally followed by a clock time, e.g. \"friday 18:00\") — never compute a day-count yourself for a named weekday, just pass the day name and let the server resolve it"},"recur":{"type":"string","description":"Only for action=create, and only if the user wants it to repeat. Relative shorthand for the repeat interval, e.g. \"1d\" for daily"},"message":{"type":"string","description":"Only for action=create. What to remind the user about"},"id":{"type":"integer","description":"Only for action=cancel. The reminder id to cancel"}},"required":["action"]}
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

    const duration_str = args.duration orelse return "Missing duration — e.g. \"20m\", \"2h\", \"1d\", or a clock time like \"14:30\".";
    const message = args.message orelse return "Missing message — say what to remind them about.";
    if (message.len == 0) return "Missing message — say what to remind them about.";
    if (message.len > max_reminder_message_len) return "That reminder text is too long (max 500 bytes).";

    const recur_interval: ?i64 = if (args.recur) |r|
        reminder_format.parseDuration(r) orelse return "Couldn't parse that recurrence interval — use e.g. 30m, 2h, or 1d."
    else
        null;

    // `duration` always determines the first firing (relative or absolute);
    // `recur`, when set, is the independent repeat cadence after that.
    const due_at = reminder_format.parseWhen(duration_str, ctx.now) orelse
        return "Couldn't parse that time — use a relative duration like 30m/2h/1d, a 24h clock time like 14:30, or a weekday name like \"friday\".";

    const id = try sink.create(ctx.allocator, message, due_at, recur_interval);

    if (recur_interval) |interval| {
        return std.fmt.allocPrint(ctx.allocator, "Reminder #{d} set, repeating every {s}.", .{ id, reminder_format.formatInterval(ctx.allocator, interval) });
    }
    if (reminder_format.parseDuration(duration_str) != null) {
        return std.fmt.allocPrint(ctx.allocator, "Reminder #{d} set for {s} from now.", .{ id, duration_str });
    }
    // A weekday name (unlike the bare-clock-time case just below) silently
    // applies a default time-of-day when the caller didn't give one
    // (`reminder_format.parseWeekdayWhen`'s doc comment) — echo the actual
    // resolved date/time/weekday back rather than the raw input text so
    // that default isn't a surprise.
    if (reminder_format.parseWeekdayWhen(duration_str, ctx.now) != null) {
        const local = civil_time.localFromUnix(due_at, 0);
        const date_str = civil_time.formatDate(ctx.allocator, local, .ymd);
        const time_str = civil_time.formatTime(ctx.allocator, local, .h24);
        const weekday = civil_time.weekdayFromDays(@divFloor(due_at, 86400));
        return std.fmt.allocPrint(ctx.allocator, "Reminder #{d} set for {s} {s} ({s}).", .{ id, date_str, time_str, civil_time.weekdayName(weekday) });
    }
    return std.fmt.allocPrint(ctx.allocator, "Reminder #{d} set for {s}.", .{ id, duration_str });
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    created: ?struct { message: []const u8, due_at: i64, recur_interval_seconds: ?i64 } = null,
    cancel_result: registry.ReminderSink.CancelResult = .canceled,
    list_text: []const u8 = "Pending reminders:\n  #1 in 5m: test\n",

    fn sink(self: *FakeSink) registry.ReminderSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.ReminderSink.VTable = .{ .create = createFn, .cancel = cancelFn, .listPending = listPendingFn };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) anyerror!i64 {
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.created = .{ .message = try allocator.dupe(u8, message), .due_at = due_at, .recur_interval_seconds = recur_interval_seconds };
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

test "execute create with recur produces a recurring reminder due one interval out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .now = 1000, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"duration\":\"1h\",\"recur\":\"1d\",\"message\":\"stretch\"}");
    try testing.expectEqualStrings("Reminder #42 set, repeating every 1d.", out);
    try testing.expectEqual(@as(i64, 1000 + 3600), fake.created.?.due_at);
    try testing.expectEqual(@as(?i64, 86400), fake.created.?.recur_interval_seconds);
}

test "execute create accepts an absolute clock time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .now = 0, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"duration\":\"14:30\",\"message\":\"call mom\"}");
    try testing.expectEqualStrings("Reminder #42 set for 14:30.", out);
    try testing.expectEqual(@as(i64, 14 * 3600 + 30 * 60), fake.created.?.due_at);
    try testing.expectEqual(@as(?i64, null), fake.created.?.recur_interval_seconds);
}

test "execute create accepts a weekday name, defaults to 6am, and echoes the resolved date" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    // now = 0 is 1970-01-01 00:00:00, a Thursday.
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .now = 0, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"duration\":\"friday\",\"message\":\"call mom\"}");
    try testing.expectEqualStrings("Reminder #42 set for 1970-01-02 06:00 (Friday).", out);
    try testing.expectEqual(@as(i64, 86400 + 6 * 3600), fake.created.?.due_at);
}

test "execute create rejects a weekday name that isn't real" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .now = 0, .reminders = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"duration\":\"funday\",\"message\":\"x\"}");
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
