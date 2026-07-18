const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { location: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "air_quality",
    .description = "Gets current air quality (US AQI, PM2.5, PM10) for a city name. No API key required (Open-Meteo).",
    .input_schema_json =
    \\{"type":"object","properties":{"location":{"type":"string","description":"City name, e.g. \"Tehran\" or \"Beijing\""}},"required":["location"]}
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

const CurrentAirQuality = struct {
    us_aqi: ?f64 = null,
    pm2_5: ?f64 = null,
    pm10: ?f64 = null,
};

const AirQualityResponse = struct {
    current: CurrentAirQuality = .{},
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const reading = (try fetchAirQuality(ctx.allocator, ctx.io, parsed.value.location)) orelse
        return std.fmt.allocPrint(ctx.allocator, "No location found matching '{s}'.", .{parsed.value.location});

    const aqi = reading.us_aqi orelse {
        return std.fmt.allocPrint(ctx.allocator, "No air quality data available for {s}, {s}.", .{ reading.name, reading.country });
    };

    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}, {s}: US AQI {d:.0} ({s}), PM2.5 {d:.1} µg/m³, PM10 {d:.1} µg/m³",
        .{
            reading.name,
            reading.country,
            aqi,
            describeAqi(aqi),
            reading.pm2_5 orelse 0,
            reading.pm10 orelse 0,
        },
    );
}

pub const Reading = struct {
    name: []const u8,
    country: []const u8,
    us_aqi: ?f64,
    pm2_5: ?f64,
    pm10: ?f64,
};

/// Geocodes `location` then fetches its current air quality — same
/// fetch-and-parse-core-extracted-from-execute shape as
/// `weather.fetchWeather`, for the same reason (`features/alerts.zig` reads
/// `us_aqi` directly). Null when the location doesn't geocode to anything.
pub fn fetchAirQuality(allocator: std.mem.Allocator, io: std.Io, location: []const u8) !?Reading {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const encoded_location = try http_util.encodeQueryComponent(allocator, location);
    defer allocator.free(encoded_location);

    const geocode_url = try std.fmt.allocPrint(
        allocator,
        "https://geocoding-api.open-meteo.com/v1/search?count=1&name={s}",
        .{encoded_location},
    );
    defer allocator.free(geocode_url);

    const geocode_body = try http_util.get(&client, allocator, geocode_url);
    defer allocator.free(geocode_body);

    var geocode = try json.parseFromSlice(
        GeocodeResponse,
        allocator,
        geocode_body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer geocode.deinit();

    if (geocode.value.results.len == 0) return null;
    const place = geocode.value.results[0];

    const aq_url = try std.fmt.allocPrint(
        allocator,
        "https://air-quality-api.open-meteo.com/v1/air-quality?latitude={d}&longitude={d}&current=us_aqi,pm2_5,pm10",
        .{ place.latitude, place.longitude },
    );
    defer allocator.free(aq_url);

    const aq_body = try http_util.get(&client, allocator, aq_url);
    defer allocator.free(aq_body);

    var aq = try json.parseFromSlice(
        AirQualityResponse,
        allocator,
        aq_body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer aq.deinit();

    return .{
        .name = try allocator.dupe(u8, place.name),
        .country = try allocator.dupe(u8, place.country),
        .us_aqi = aq.value.current.us_aqi,
        .pm2_5 = aq.value.current.pm2_5,
        .pm10 = aq.value.current.pm10,
    };
}

/// US EPA AQI categories.
fn describeAqi(aqi: f64) []const u8 {
    if (aqi <= 50) return "good";
    if (aqi <= 100) return "moderate";
    if (aqi <= 150) return "unhealthy for sensitive groups";
    if (aqi <= 200) return "unhealthy";
    if (aqi <= 300) return "very unhealthy";
    return "hazardous";
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "describeAqi maps the EPA breakpoints" {
    try testing.expectEqualStrings("good", describeAqi(12));
    try testing.expectEqualStrings("moderate", describeAqi(75));
    try testing.expectEqualStrings("unhealthy for sensitive groups", describeAqi(120));
    try testing.expectEqualStrings("unhealthy", describeAqi(180));
    try testing.expectEqualStrings("very unhealthy", describeAqi(250));
    try testing.expectEqualStrings("hazardous", describeAqi(400));
}
