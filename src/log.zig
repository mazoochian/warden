//! Warden's own leveled, scoped logger. Exists because `std.log`'s 4 levels
//! (err/warn/info/debug) can't express the "something is unrecoverable, exit
//! now" (FATAL) vs. "worth a human's attention but not an error" (NOTICE)
//! distinction the operator asked for, and because `std.log`'s own filtering
//! (`std.options.log_level`) is a `comptime` value baked in at build time —
//! there's no way to flip verbosity at runtime from an env var through that
//! path alone.
//!
//! Every line renders as fixed-width columns (timestamp, level, scope,
//! message) so `journalctl`/`docker logs` output stays readable and
//! greppable instead of one giant unstructured sentence per line. Output
//! goes through `std.debug.lockStderr`/`unlockStderr` — the same primitive
//! `std.log`'s own `defaultLog` uses — which is already safe to call
//! concurrently from any thread (recursive lock), so every poll-loop thread,
//! worker-pool thread, and the scheduler loop can log without stepping on
//! each other's output mid-line.
//!
//! Two ways in:
//!   1. `scoped("name")` gives a per-module logger with `.debug`/`.info`/
//!      `.notice`/`.warn`/`.err`/`.fatal` methods — use this for anything
//!      new.
//!   2. `stdLogFn` is wired in as `std_options.logFn` (see `main.zig`), so
//!      pre-existing `std.log.err`/`.warn`/`.info`/`.debug` call sites
//!      elsewhere in the codebase render through the exact same tabular
//!      formatter and runtime level filter without needing to be rewritten.
//!
//! Verbosity is controlled by `WARDEN_LOG_LEVEL` (debug/info/notice/warn/
//! error/fatal, case-insensitive; defaults to "info") — see `init`, called
//! once at the very top of `main`.
const std = @import("std");
const Io = std.Io;

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    notice = 2,
    warn = 3,
    err = 4,
    /// Always shown regardless of `WARDEN_LOG_LEVEL`, and always followed by
    /// process termination — see `scoped(..).fatal`.
    fatal = 5,

    fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .notice => "NOTICE",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    fn color(self: Level) std.Io.Terminal.Color {
        return switch (self) {
            .debug => .bright_black,
            .info => .green,
            .notice => .cyan,
            .warn => .yellow,
            .err => .red,
            .fatal => .bright_red,
        };
    }
};

/// Width the SCOPE column is padded/aligned to. Longest scope name in use
/// today is "worker_pool" (11) — 12 leaves one space of natural separation
/// even for that one before the two literal padding spaces below.
const scope_width = 12;

/// `main` sets this via `init` before anything else runs (even before
/// `Config.load`, so config-load failures themselves get a real timestamp
/// too). Reading a timestamp needs an `Io` instance in this Zig version
/// (see `Io.Timestamp`) — there is no longer a plain `std.time.timestamp()`
/// that works without one.
var g_io: Io = undefined;
var g_io_ready: std.atomic.Value(bool) = .init(false);

/// Default `.info` so a build that somehow logs before `init` runs (there
/// shouldn't be one) still filters out debug spam rather than failing open.
var g_min_level: std.atomic.Value(u8) = .init(@intFromEnum(Level.info));

/// Call once, as the very first thing in `main`, before `Config.load` —
/// logging (including `Config.load`'s own error paths) should work even if
/// the rest of config loading fails. `env` is the same
/// `init.environ_map` every other config read in this codebase uses.
pub fn init(io: Io, env: *const std.process.Environ.Map) void {
    g_io = io;
    g_io_ready.store(true, .release);
    const raw = env.get("WARDEN_LOG_LEVEL") orelse "info";
    const level = parseLevel(raw) orelse blk: {
        // Logged directly (not via `emit`, which would depend on
        // `g_min_level` already being set) so a typo'd env var is visible
        // instead of silently falling back.
        writeLine(.warn, "log", "unrecognized WARDEN_LOG_LEVEL '{s}', defaulting to info (want: debug|info|notice|warn|error|fatal)", .{raw});
        break :blk .info;
    };
    g_min_level.store(@intFromEnum(level), .release);
}

/// The currently-configured minimum level — used e.g. by `main.zig` to log
/// its own effective verbosity once at startup, so "why am I not seeing
/// DEBUG lines" is answerable by reading the log itself.
pub fn currentLevel() Level {
    return @enumFromInt(g_min_level.load(.acquire));
}

fn parseLevel(raw: []const u8) ?Level {
    if (std.ascii.eqlIgnoreCase(raw, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(raw, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(raw, "notice")) return .notice;
    if (std.ascii.eqlIgnoreCase(raw, "warn") or std.ascii.eqlIgnoreCase(raw, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(raw, "error") or std.ascii.eqlIgnoreCase(raw, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(raw, "fatal")) return .fatal;
    return null;
}

/// Returns a namespace of logging functions tagged with `name` in the SCOPE
/// column, e.g. `const log = @import("log.zig").scoped("postgres");`.
pub fn scoped(comptime name: []const u8) type {
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            emit(.debug, name, fmt, args);
        }
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            emit(.info, name, fmt, args);
        }
        /// Worth a human's attention on a quick log skim, but not a
        /// malfunction — e.g. a feature being disabled by configuration, a
        /// connector coming back up after a transient drop.
        pub fn notice(comptime fmt: []const u8, args: anytype) void {
            emit(.notice, name, fmt, args);
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            emit(.warn, name, fmt, args);
        }
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            emit(.err, name, fmt, args);
        }
        /// Logs unconditionally (bypasses `WARDEN_LOG_LEVEL`) and then
        /// terminates the process — for startup/invariant failures the bot
        /// has no reasonable way to keep running past (e.g. config load
        /// failure, DB pool init failure). Prefer this over a bare
        /// `std.process.exit` so the reason is never silent.
        pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
            writeLine(.fatal, name, fmt, args);
            std.process.exit(1);
        }
    };
}

fn emit(level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < g_min_level.load(.acquire)) return;
    writeLine(level, scope, fmt, args);
}

fn writeLine(level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    // Matches `std.log.defaultLog`'s own buffer size — this is just the
    // underlying writer's flush chunk size, not a line-length cap; `print`
    // below flushes and continues as needed for longer lines.
    var buffer: [128]u8 = undefined;
    const t = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    writeLineTerminal(level, scope, fmt, args, t) catch {};
}

fn writeLineTerminal(level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype, t: std.Io.Terminal) std.Io.Writer.Error!void {
    try writeTimestamp(t.writer);
    try t.writer.writeAll("  ");

    t.setColor(level.color()) catch {};
    t.setColor(.bold) catch {};
    try t.writer.print("{s: <6}", .{level.label()});
    t.setColor(.reset) catch {};
    try t.writer.writeAll("  ");

    t.setColor(.dim) catch {};
    try t.writer.print("{s: <[1]}", .{ scope, scope_width });
    t.setColor(.reset) catch {};
    try t.writer.writeAll("  ");

    try t.writer.print(fmt ++ "\n", args);
}

fn writeTimestamp(w: *Io.Writer) std.Io.Writer.Error!void {
    if (!g_io_ready.load(.acquire)) {
        try w.writeAll("-------------------");
        return;
    }
    const secs = Io.Timestamp.now(g_io, .real).toSeconds();
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, secs)) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// Wired in as `std_options.logFn` (see `main.zig`) so every pre-existing
/// `std.log.err`/`.warn`/`.info`/`.debug` call site elsewhere in the
/// codebase renders through the same tabular formatter and the same runtime
/// `WARDEN_LOG_LEVEL` filter, without needing to be individually rewritten.
/// `std_options.log_level` is left at `.debug` (see `main.zig`) so
/// `std.log`'s own comptime filter never intercepts a message before it
/// reaches here — filtering happens once, at runtime, in `emit`.
pub fn stdLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level: Level = switch (message_level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    const scope_name = if (scope == .default) "default" else @tagName(scope);
    emit(level, scope_name, fmt, args);
}

const testing = std.testing;

test "every level renders through scoped() and stdLogFn without crashing" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("WARDEN_LOG_LEVEL", "debug");
    init(testing.io, &env);

    const log = scoped("test");
    log.debug("debug line {d}", .{1});
    log.info("info line {s}", .{"x"});
    log.notice("notice line", .{});
    log.warn("warn line", .{});
    log.err("err line: {t}", .{error.Oops});

    stdLogFn(.info, .default, "via std.log default scope", .{});
    stdLogFn(.err, .some_other_scope, "via std.log named scope", .{});
}

test "parseLevel accepts every documented spelling, case-insensitively" {
    try testing.expectEqual(Level.debug, parseLevel("DEBUG").?);
    try testing.expectEqual(Level.info, parseLevel("info").?);
    try testing.expectEqual(Level.notice, parseLevel("Notice").?);
    try testing.expectEqual(Level.warn, parseLevel("warn").?);
    try testing.expectEqual(Level.warn, parseLevel("warning").?);
    try testing.expectEqual(Level.err, parseLevel("error").?);
    try testing.expectEqual(Level.fatal, parseLevel("fatal").?);
    try testing.expect(parseLevel("bogus") == null);
}

test "WARDEN_LOG_LEVEL gates emit() without affecting fatal's always-on behavior" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("WARDEN_LOG_LEVEL", "err");
    init(testing.io, &env);
    try testing.expectEqual(@intFromEnum(Level.err), g_min_level.load(.acquire));

    const log = scoped("test");
    // Below-threshold levels must not be filtered out by crashing or
    // otherwise misbehaving — there's no observable return value here, this
    // just exercises the early-return path in `emit`.
    log.debug("should be filtered out", .{});
    log.info("should be filtered out", .{});
    log.err("should still print", .{});

    // Reset to the default so later tests in this file (if run in a
    // different order) aren't affected by this test's override.
    try env.put("WARDEN_LOG_LEVEL", "info");
    init(testing.io, &env);
}
