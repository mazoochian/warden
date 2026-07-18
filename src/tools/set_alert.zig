const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const Args = struct {
    action: []const u8,
    kind: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    currency: ?[]const u8 = null,
    condition: ?[]const u8 = null,
    threshold: ?f64 = null,
    id: ?i64 = null,
};

pub const tool: registry.ToolDef = .{
    .name = "set_alert",
    .description = "Creates, lists, or cancels standing price/metric alerts for this chat — checked periodically in the background and delivered as a message once the condition becomes true (e.g. \"let me know when bitcoin crosses 70000\", \"alert me if Tehran's air quality gets bad\"). kind=crypto compares a CoinGecko coin id's price (use full ids like \"bitcoin\", not ticker symbols); kind=weather compares a city's current temperature in °C; kind=aqi compares a city's current US AQI. Once triggered, re-notifies only after a cooldown, not on every check. For action=cancel, use the id from action=list or a previous create confirmation.",
    .input_schema_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["create","list","cancel"],"description":"What to do"},"kind":{"type":"string","enum":["crypto","weather","aqi"],"description":"Only for action=create. What kind of thing to watch"},"subject":{"type":"string","description":"Only for action=create. CoinGecko coin id for crypto (e.g. \"bitcoin\"), or a city name for weather/aqi"},"currency":{"type":"string","description":"Only for action=create, crypto only. Quote currency code, default \"usd\""},"condition":{"type":"string","enum":["above","below"],"description":"Only for action=create. Trigger when the value goes above or below threshold"},"threshold":{"type":"number","description":"Only for action=create. The number to compare against"},"id":{"type":"integer","description":"Only for action=cancel. The alert id to cancel"}},"required":["action"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.alerts orelse return error.MissingToolContext;

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
        const id = args.id orelse return "Missing id — use action=list to find the alert's id first.";
        return switch (try sink.cancel(ctx.allocator, id)) {
            .canceled => "Alert canceled.",
            .not_found => "No alert with that id in this chat.",
            .not_authorized => "Only whoever set that alert (or the bot owner) can cancel it.",
        };
    }

    if (!std.mem.eql(u8, args.action, "create")) {
        return "Unknown action — use \"create\", \"list\", or \"cancel\".";
    }

    const kind = args.kind orelse return "Missing kind — use \"crypto\", \"weather\", or \"aqi\".";
    if (!isValidKind(kind)) return "Unknown kind — use \"crypto\", \"weather\", or \"aqi\".";

    const subject = args.subject orelse return "Missing subject — a CoinGecko coin id for crypto, or a city name for weather/aqi.";
    if (subject.len == 0) return "Missing subject — a CoinGecko coin id for crypto, or a city name for weather/aqi.";

    const condition = args.condition orelse return "Missing condition — use \"above\" or \"below\".";
    if (!std.mem.eql(u8, condition, "above") and !std.mem.eql(u8, condition, "below")) {
        return "Unknown condition — use \"above\" or \"below\".";
    }

    const threshold = args.threshold orelse return "Missing threshold — the number to compare against.";

    const is_crypto = std.mem.eql(u8, kind, "crypto");
    const currency: ?[]const u8 = if (is_crypto) (args.currency orelse "usd") else null;

    const id = try sink.create(ctx.allocator, kind, subject, currency, condition, threshold);

    const unit = if (is_crypto) currency.? else if (std.mem.eql(u8, kind, "weather")) "°C" else "AQI";
    return std.fmt.allocPrint(ctx.allocator, "Alert #{d} set: notify when {s} is {s} {d} {s}.", .{ id, subject, condition, threshold, unit });
}

fn isValidKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "crypto") or std.mem.eql(u8, kind, "weather") or std.mem.eql(u8, kind, "aqi");
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    created: ?struct { kind: []const u8, subject: []const u8, currency: ?[]const u8, condition: []const u8, threshold: f64 } = null,
    cancel_result: registry.AlertSink.CancelResult = .canceled,
    list_text: []const u8 = "Alerts:\n  #1 crypto bitcoin above 70000\n",

    fn sink(self: *FakeSink) registry.AlertSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.AlertSink.VTable = .{ .create = createFn, .cancel = cancelFn, .listPending = listPendingFn };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, kind: []const u8, subject: []const u8, currency: ?[]const u8, condition: []const u8, threshold: f64) anyerror!i64 {
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.created = .{
            .kind = try allocator.dupe(u8, kind),
            .subject = try allocator.dupe(u8, subject),
            .currency = if (currency) |c| try allocator.dupe(u8, c) else null,
            .condition = try allocator.dupe(u8, condition),
            .threshold = threshold,
        };
        return 7;
    }
    fn cancelFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!registry.AlertSink.CancelResult {
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

test "execute create validates fields and defaults crypto currency to usd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .alerts = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"kind\":\"crypto\",\"subject\":\"bitcoin\",\"condition\":\"above\",\"threshold\":70000}");
    try testing.expectEqualStrings("Alert #7 set: notify when bitcoin is above 70000 usd.", out);
    try testing.expectEqualStrings("usd", fake.created.?.currency.?);
    try testing.expectEqual(@as(f64, 70000), fake.created.?.threshold);
}

test "execute create rejects an unknown kind or condition without touching the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .alerts = fake.sink() };

    const bad_kind = try execute(ctx, "{\"action\":\"create\",\"kind\":\"stocks\",\"subject\":\"x\",\"condition\":\"above\",\"threshold\":1}");
    try testing.expect(std.mem.indexOf(u8, bad_kind, "Unknown kind") != null);
    try testing.expectEqual(@as(?@TypeOf(fake.created.?), null), fake.created);

    const bad_condition = try execute(ctx, "{\"action\":\"create\",\"kind\":\"weather\",\"subject\":\"Tehran\",\"condition\":\"sideways\",\"threshold\":1}");
    try testing.expect(std.mem.indexOf(u8, bad_condition, "Unknown condition") != null);
    try testing.expectEqual(@as(?@TypeOf(fake.created.?), null), fake.created);
}

test "execute create for weather has no currency and uses the °C unit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .alerts = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"kind\":\"weather\",\"subject\":\"Tehran\",\"condition\":\"above\",\"threshold\":35}");
    try testing.expectEqualStrings("Alert #7 set: notify when Tehran is above 35 °C.", out);
    try testing.expectEqual(@as(?[]const u8, null), fake.created.?.currency);
}

test "execute list forwards straight to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .alerts = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"list\"}");
    try testing.expectEqualStrings(fake.list_text, out);
}

test "execute cancel maps every CancelResult to a distinct message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{ .cancel_result = .not_authorized };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .alerts = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"cancel\",\"id\":7}");
    try testing.expect(std.mem.indexOf(u8, out, "Only whoever set") != null);
}
