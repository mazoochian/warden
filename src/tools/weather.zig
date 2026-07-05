const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { location: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "weather",
    .description = "Gets current weather (temperature, wind) for a city name. No API key required (Open-Meteo).",
    .input_schema_json =
        \\{"type":"object","properties":{"location":{"type":"string","description":"City name, e.g. \"Berlin\" or \"Tokyo\""}},"required":["location"]}
    ,
    .execute = execute,
};

const GeocodeResult = struct {
    name: []const u8 = "",
    latitude: f64 = 0,
    longitude: f64 = 0,
    country: []const u8 = "",
};

const GeocodeResponse = struct {
    results: []GeocodeResult = &.{},
};

const CurrentWeather = struct {
    temperature_2m: f64 = 0,
    wind_speed_10m: f64 = 0,
    weather_code: i64 = -1,
};

const ForecastResponse = struct {
    current: CurrentWeather = .{},
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

    const encoded_location = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.location);
    defer ctx.allocator.free(encoded_location);

    const geocode_url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://geocoding-api.open-meteo.com/v1/search?count=1&name={s}",
        .{encoded_location},
    );
    defer ctx.allocator.free(geocode_url);

    const geocode_body = try http_util.get(&client, ctx.allocator, geocode_url);
    defer ctx.allocator.free(geocode_body);

    var geocode = try json.parseFromSlice(
        GeocodeResponse,
        ctx.allocator,
        geocode_body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer geocode.deinit();

    if (geocode.value.results.len == 0) {
        return std.fmt.allocPrint(ctx.allocator, "No location found matching '{s}'.", .{parsed.value.location});
    }
    const place = geocode.value.results[0];

    const forecast_url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://api.open-meteo.com/v1/forecast?latitude={d}&longitude={d}&current=temperature_2m,wind_speed_10m,weather_code",
        .{ place.latitude, place.longitude },
    );
    defer ctx.allocator.free(forecast_url);

    const forecast_body = try http_util.get(&client, ctx.allocator, forecast_url);
    defer ctx.allocator.free(forecast_body);

    var forecast = try json.parseFromSlice(
        ForecastResponse,
        ctx.allocator,
        forecast_body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer forecast.deinit();

    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}, {s}: {s}, {d:.1}°C, wind {d:.1} km/h",
        .{
            place.name,
            place.country,
            describeWeatherCode(forecast.value.current.weather_code),
            forecast.value.current.temperature_2m,
            forecast.value.current.wind_speed_10m,
        },
    );
}

/// WMO weather codes (https://open-meteo.com/en/docs), condensed to the
/// common cases.
fn describeWeatherCode(code: i64) []const u8 {
    return switch (code) {
        0 => "clear sky",
        1, 2, 3 => "partly cloudy",
        45, 48 => "fog",
        51, 53, 55 => "drizzle",
        61, 63, 65 => "rain",
        71, 73, 75, 77 => "snow",
        80, 81, 82 => "rain showers",
        85, 86 => "snow showers",
        95 => "thunderstorm",
        96, 99 => "thunderstorm with hail",
        else => "unknown conditions",
    };
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
