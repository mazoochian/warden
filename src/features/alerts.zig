const std = @import("std");
const Io = std.Io;

const iface = @import("../platform/interface.zig");
const store_pool = @import("../store/pool.zig");
const alerts = @import("../store/alerts.zig");
const crypto_price = @import("../tools/crypto_price.zig");
const weather = @import("../tools/weather.zig");
const air_quality = @import("../tools/air_quality.zig");

/// Fetches the single numeric value an alert's condition is compared
/// against — the plain, non-LLM-tool-call path each source tool exposes
/// (`crypto_price.fetchPrice`, `weather.fetchWeather`, `air_quality.fetchAirQuality`)
/// so checking an alert doesn't need a model round trip. Null (not an
/// error) when the subject doesn't resolve to anything (e.g. a
/// weather/aqi city that stopped geocoding) — treated the same as "not
/// triggered" by the caller rather than a hard failure, since a transient
/// geocoding hiccup shouldn't spam error logs every check cycle.
fn fetchValue(allocator: std.mem.Allocator, io: Io, kind: alerts.Kind, subject: []const u8, currency: ?[]const u8) !?f64 {
    return switch (kind) {
        .crypto => try crypto_price.fetchPrice(allocator, io, subject, currency orelse "usd"),
        .weather => if (try weather.fetchWeather(allocator, io, subject)) |r| r.temperature_2m else null,
        .aqi => if (try air_quality.fetchAirQuality(allocator, io, subject)) |r| r.us_aqi else null,
    };
}

fn conditionMet(condition: alerts.Condition, value: f64, threshold: f64) bool {
    return switch (condition) {
        .above => value > threshold,
        .below => value < threshold,
    };
}

fn unitFor(kind: alerts.Kind, currency: ?[]const u8) []const u8 {
    return switch (kind) {
        .crypto => currency orelse "usd",
        .weather => "°C",
        .aqi => "AQI",
    };
}

/// Finds the connector whose platform matches `platform` — duplicated from
/// `main.zig`'s own `findConnector` rather than exported, to keep this
/// feature file's only dependency on `main.zig` at zero (matches how
/// `digest.zig`/`scheduler.zig` don't reach back into `main.zig` either).
fn findConnector(connectors: []const iface.Connector, platform: iface.Platform) ?iface.Connector {
    for (connectors) |c| {
        if (c.platform() == platform) return c;
    }
    return null;
}

/// Checks every alert whose check interval has elapsed and delivers a
/// notification for any whose condition is now true and isn't still in its
/// cooldown window — the poll-loop hook wired in next to
/// `checkAndSendDueDigests`/`checkAndSendDueReminders` in `main.zig`.
pub fn checkAndDeliverAlerts(connectors: []const iface.Connector, gpa: std.mem.Allocator, io: Io, pool: *store_pool.PgPool, now: i64) void {
    const due = alerts.dueForCheck(pool, gpa, now) catch |err| {
        std.log.err("alerts: failed to query due alerts: {t}", .{err});
        return;
    };
    defer {
        for (due) |al| {
            gpa.free(al.native_chat_id);
            gpa.free(al.subject);
            if (al.currency) |c| gpa.free(c);
        }
        gpa.free(due);
    }

    for (due) |al| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const value = fetchValue(a, io, al.kind, al.subject, al.currency) catch |err| {
            std.log.warn("alerts: failed to check alert {d} ({s} '{s}'): {t}", .{ al.id, @tagName(al.kind), al.subject, err });
            alerts.markChecked(pool, al.id, now) catch |mc_err| {
                std.log.err("alerts: failed to mark alert {d} checked: {t}", .{ al.id, mc_err });
            };
            continue;
        } orelse {
            alerts.markChecked(pool, al.id, now) catch |err| {
                std.log.err("alerts: failed to mark alert {d} checked: {t}", .{ al.id, err });
            };
            continue;
        };

        if (!conditionMet(al.condition, value, al.threshold)) {
            alerts.markChecked(pool, al.id, now) catch |err| {
                std.log.err("alerts: failed to mark alert {d} checked: {t}", .{ al.id, err });
            };
            continue;
        }

        const cooldown_ok = if (al.last_triggered_at) |last| now - last >= al.cooldown_seconds else true;
        if (!cooldown_ok) {
            alerts.markChecked(pool, al.id, now) catch |err| {
                std.log.err("alerts: failed to mark alert {d} checked: {t}", .{ al.id, err });
            };
            continue;
        }

        const connector = findConnector(connectors, al.platform) orelse {
            std.log.warn("alerts: no active connector for platform {s}, leaving alert {d} unfired", .{ @tagName(al.platform), al.id });
            continue;
        };

        const text = std.fmt.allocPrint(
            a,
            "🔔 Alert: {s} is {s} {d:.2} {s} (threshold: {s} {d:.2})",
            .{ al.subject, if (al.condition == .above) "above" else "below", value, unitFor(al.kind, al.currency), @tagName(al.condition), al.threshold },
        ) catch continue;
        connector.sendMessage(a, al.native_chat_id, text, null);

        alerts.markTriggered(pool, al.id, now) catch |err| {
            std.log.err("alerts: failed to mark alert {d} triggered: {t}", .{ al.id, err });
        };
    }
}
