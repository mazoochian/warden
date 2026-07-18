const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct {
    coins: []const u8,
    currency: []const u8 = "usd",
};

pub const tool: registry.ToolDef = .{
    .name = "crypto_price",
    .description = "Gets current cryptocurrency prices with 24h change from CoinGecko (no API key). Use full CoinGecko ids, not ticker symbols: \"bitcoin\", \"ethereum\", \"solana\", \"dogecoin\", \"tether\" — comma-separated for several at once.",
    .input_schema_json =
    \\{"type":"object","properties":{"coins":{"type":"string","description":"Comma-separated CoinGecko coin ids, e.g. \"bitcoin,ethereum\""},"currency":{"type":"string","description":"Quote currency code, default \"usd\""}},"required":["coins"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const coins = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.coins);
    defer ctx.allocator.free(coins);
    const currency = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.currency);
    defer ctx.allocator.free(currency);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://api.coingecko.com/api/v3/simple/price?ids={s}&vs_currencies={s}&include_24hr_change=true",
        .{ coins, currency },
    );
    defer ctx.allocator.free(url);

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const body = try http_util.get(&client, ctx.allocator, url);
    defer ctx.allocator.free(body);

    return formatPrices(ctx.allocator, body, parsed.value.currency);
}

/// Fetches a single coin's current price — the plain, non-LLM-tool-call
/// path `features/alerts.zig` uses so checking a price alert doesn't need
/// to go through the tool-call loop for something this simple.
pub fn fetchPrice(allocator: std.mem.Allocator, io: std.Io, coin: []const u8, currency: []const u8) !f64 {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const encoded_coin = try http_util.encodeQueryComponent(allocator, coin);
    defer allocator.free(encoded_coin);
    const encoded_currency = try http_util.encodeQueryComponent(allocator, currency);
    defer allocator.free(encoded_currency);

    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.coingecko.com/api/v3/simple/price?ids={s}&vs_currencies={s}",
        .{ encoded_coin, encoded_currency },
    );
    defer allocator.free(url);

    const body = try http_util.get(&client, allocator, url);
    defer allocator.free(body);

    var parsed = try json.parseFromSlice(json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.PriceNotFound;
    const coin_obj = parsed.value.object.get(coin) orelse return error.PriceNotFound;
    if (coin_obj != .object) return error.PriceNotFound;
    return asF64(coin_obj.object.get(currency)) orelse error.PriceNotFound;
}

/// Renders CoinGecko's `{"bitcoin":{"usd":63685,"usd_24h_change":-0.72}}`
/// shape as one line per coin. Split out for offline testing.
fn formatPrices(allocator: std.mem.Allocator, body: []const u8, currency: []const u8) ![]const u8 {
    var parsed = try json.parseFromSlice(json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() == 0) {
        return allocator.dupe(u8, "No prices found — make sure you used CoinGecko ids (e.g. \"bitcoin\", not \"btc\").");
    }

    const change_key = try std.fmt.allocPrint(allocator, "{s}_24h_change", .{currency});
    defer allocator.free(change_key);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const coin = entry.value_ptr.*;
        if (coin != .object) continue;
        const price = asF64(coin.object.get(currency)) orelse continue;
        try w.print("{s}: {d} {s}", .{ entry.key_ptr.*, price, currency });
        if (asF64(coin.object.get(change_key))) |change| {
            try w.print(" ({s}{d:.2}% 24h)", .{ if (change >= 0) "+" else "", change });
        }
        try w.writeAll("\n");
    }

    const out = std.mem.trimEnd(u8, buf.writer.buffered(), "\n");
    if (out.len == 0) return allocator.dupe(u8, "No prices found — make sure you used CoinGecko ids (e.g. \"bitcoin\", not \"btc\").");
    return allocator.dupe(u8, out);
}

fn asF64(value: ?json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "formatPrices renders one line per coin with 24h change" {
    const body =
        \\{"bitcoin":{"usd":63685,"usd_24h_change":-0.723},"ethereum":{"usd":1798.11,"usd_24h_change":1.5}}
    ;
    const out = try formatPrices(testing.allocator, body, "usd");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "bitcoin: 63685 usd (-0.72% 24h)\nethereum: 1798.11 usd (+1.50% 24h)",
        out,
    );
}

test "formatPrices explains empty responses (bad coin ids)" {
    const out = try formatPrices(testing.allocator, "{}", "usd");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "CoinGecko ids") != null);
}
