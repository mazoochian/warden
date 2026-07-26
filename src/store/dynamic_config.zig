const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// The DB-backed subset of today's env-only `Config` fields that are safe
/// to expose as live-editable from warden-ui — see
/// /home/armin/claude/warden-ui/ARCHITECTURE.md §6 for the full
/// secrets-vs-safe-tunables triage. A missing row for a key means "use the
/// env-sourced `Config` default" — every `get*` function here takes that
/// default as a parameter for exactly that reason, mirroring
/// `config.zig`'s own `parseBoolEnv`-style "parse or fall back" shape so
/// callers read the same either way regardless of which source won.
///
/// Deliberately generic (plain string keys, not one function per setting)
/// since the set of dynamic keys is expected to grow — see `config.zig`'s
/// own env var list for the exact keys expected to move here over time
/// (pool/timeout tunables, digest interval, LLM behavior flags, retention,
/// etc. — never secrets, DSNs, or tokens; those stay env-only by design).
/// Fails closed to the caller's default on any pool/query error, same
/// convention as `feature_flags.isEnabled`'s fail-open — a config read
/// failing should silently keep today's behavior, not surface as a crash.
fn getRaw(pool: *PgPool, allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const db = pool.acquire() catch return null;
    defer pool.release(db);

    var stmt = db.prepare("SELECT value FROM dynamic_config WHERE key = $1;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, key);
    const has_row = (stmt.step() catch return null);
    if (!has_row) return null;
    return allocator.dupe(u8, stmt.columnText(0)) catch null;
}

/// Always returns memory owned by `allocator` (including when falling
/// back to `default`, which gets duped too) — a uniform ownership
/// contract so callers can unconditionally `allocator.free()` the result
/// regardless of which source it came from, rather than needing to know
/// whether this particular call hit the DB or the fallback.
pub fn getString(pool: *PgPool, allocator: std.mem.Allocator, key: []const u8, default: []const u8) ![]const u8 {
    return getRaw(pool, allocator, key) orelse try allocator.dupe(u8, default);
}

pub fn getBool(pool: *PgPool, allocator: std.mem.Allocator, key: []const u8, default: bool) bool {
    const raw = getRaw(pool, allocator, key) orelse return default;
    defer allocator.free(raw);
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return default;
}

pub fn getI64(pool: *PgPool, allocator: std.mem.Allocator, key: []const u8, default: i64) i64 {
    const raw = getRaw(pool, allocator, key) orelse return default;
    defer allocator.free(raw);
    return std.fmt.parseInt(i64, raw, 10) catch default;
}

pub fn set(pool: *PgPool, key: []const u8, value: []const u8, updated_by: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO dynamic_config (key, value, updated_by) VALUES ($1, $2, $3)
        \\ON CONFLICT (key) DO UPDATE SET
        \\  value = excluded.value, updated_at = now(), updated_by = excluded.updated_by;
    );
    defer stmt.finalize();
    stmt.bindText(1, key);
    stmt.bindText(2, value);
    stmt.bindInt64(3, updated_by);
    _ = try stmt.step();
}

/// Clears an override, reverting to the env-sourced default.
pub fn unset(pool: *PgPool, key: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM dynamic_config WHERE key = $1;");
    defer stmt.finalize();
    stmt.bindText(1, key);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const identities = @import("identities.zig");

test "get* fall back to the caller's default when no row exists, and reflect set() after" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    try testing.expectEqual(@as(i64, 30), getI64(&pool, a, "WARDEN_DIGEST_INTERVAL_SECONDS", 30));
    try testing.expect(getBool(&pool, a, "WARDEN_LLM_SHOW_THINKING", false) == false);

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try set(&pool, "WARDEN_DIGEST_INTERVAL_SECONDS", "3600", owner);
    try set(&pool, "WARDEN_LLM_SHOW_THINKING", "true", owner);

    try testing.expectEqual(@as(i64, 3600), getI64(&pool, a, "WARDEN_DIGEST_INTERVAL_SECONDS", 30));
    try testing.expect(getBool(&pool, a, "WARDEN_LLM_SHOW_THINKING", false));

    try unset(&pool, "WARDEN_DIGEST_INTERVAL_SECONDS");
    try testing.expectEqual(@as(i64, 30), getI64(&pool, a, "WARDEN_DIGEST_INTERVAL_SECONDS", 30));
}

test "getString round-trips a plain string value" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const fallback = try getString(&pool, a, "WARDEN_LLM_PROVIDER", "anthropic");
    defer a.free(fallback);
    try testing.expectEqualStrings("anthropic", fallback);

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try set(&pool, "WARDEN_LLM_PROVIDER", "openai_compat", owner);
    const overridden = try getString(&pool, a, "WARDEN_LLM_PROVIDER", "anthropic");
    defer a.free(overridden);
    try testing.expectEqualStrings("openai_compat", overridden);
}
