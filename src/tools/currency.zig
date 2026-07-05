const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct {
    amount: f64 = 1,
    from: []const u8,
    to: []const u8,
};

pub const tool: registry.ToolDef = .{
    .name = "currency_convert",
    .description = "Converts an amount between currencies using current exchange rates. No API key required (Frankfurter/ECB rates). Use ISO 4217 codes like USD, EUR, JPY.",
    .input_schema_json =
        \\{"type":"object","properties":{"amount":{"type":"number","description":"Amount to convert, defaults to 1"},"from":{"type":"string","description":"Source currency code, e.g. USD"},"to":{"type":"string","description":"Target currency code, e.g. EUR"}},"required":["from","to"]}
    ,
    .execute = execute,
};

const FrankfurterResponse = struct {
    amount: f64 = 0,
    base: []const u8 = "",
    date: []const u8 = "",
    rates: std.json.ArrayHashMap(f64) = .{},
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://api.frankfurter.dev/v1/latest?amount={d}&from={s}&to={s}",
        .{ parsed.value.amount, parsed.value.from, parsed.value.to },
    );
    defer ctx.allocator.free(url);

    const body = try http_util.get(&client, ctx.allocator, url);
    defer ctx.allocator.free(body);

    var resp = try json.parseFromSlice(
        FrankfurterResponse,
        ctx.allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer resp.deinit();

    const rate = resp.value.rates.map.get(parsed.value.to) orelse {
        return std.fmt.allocPrint(
            ctx.allocator,
            "No rate found for {s} -> {s} (check the currency codes).",
            .{ parsed.value.from, parsed.value.to },
        );
    };

    return std.fmt.allocPrint(
        ctx.allocator,
        "{d} {s} = {d:.2} {s} (as of {s})",
        .{ parsed.value.amount, parsed.value.from, rate, parsed.value.to, resp.value.date },
    );
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
