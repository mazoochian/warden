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
    return parseBool(raw, default);
}

pub fn getI64(pool: *PgPool, allocator: std.mem.Allocator, key: []const u8, default: i64) i64 {
    const raw = getRaw(pool, allocator, key) orelse return default;
    defer allocator.free(raw);
    return parseI64(raw, default);
}

/// Split out from `getBool` so callers that already have a raw value in
/// hand (`listAll`'s bulk fetch, used where several keys are read together
/// on one hot path — see `main.zig`'s `resolveLlmDynamicSettings`) don't
/// need a second round trip through `getRaw` just to parse it.
pub fn parseBool(raw: []const u8, default: bool) bool {
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return default;
}

/// See `parseBool`'s doc comment — same reasoning.
pub fn parseI64(raw: []const u8, default: i64) i64 {
    return std.fmt.parseInt(i64, raw, 10) catch default;
}

pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// Every row in `dynamic_config`, in one query — for hot paths that read
/// several keys together (e.g. every free-form LLM turn reads six of
/// them), where six separate `pool.acquire()`/query round trips per
/// message would be real, not theoretical, overhead (this codebase has
/// already hit Postgres pool exhaustion under load once — see
/// `warden-hang-fix-2026-07-22` territory). Callers own the returned
/// slice and each `KV`'s strings.
pub fn listAll(pool: *PgPool, allocator: std.mem.Allocator) ![]KV {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT key, value FROM dynamic_config;");
    defer stmt.finalize();

    var out: std.ArrayList(KV) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .key = try allocator.dupe(u8, stmt.columnText(0)),
            .value = try allocator.dupe(u8, stmt.columnText(1)),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Finds `key` in a `listAll`-fetched row set and parses it as a bool,
/// falling back to `default` if absent or unparseable — the bulk-fetch
/// equivalent of `getBool`.
pub fn findBool(rows: []const KV, key: []const u8, default: bool) bool {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key, key)) return parseBool(row.value, default);
    }
    return default;
}

/// See `findBool`'s doc comment — same shape, for `i64`.
pub fn findI64(rows: []const KV, key: []const u8, default: i64) i64 {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key, key)) return parseI64(row.value, default);
    }
    return default;
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

pub const ValueKind = enum { bool, i64 };

pub const KnownKey = struct {
    key: []const u8,
    label: []const u8,
    kind: ValueKind,
};

/// Every `dynamic_config` key this build actually reads back live — see
/// `main.zig`'s `resolveLlmDynamicSettings` and the two single-key reads
/// next to `recordMessage`/the digest-interval check. The single source
/// of truth the admin config API (`GET`/`PATCH /api/v1/admin/config`)
/// checks against: only these are ever accepted on `PATCH` — everything
/// else (secrets, identity, restart-required tunables) is display-only,
/// per /home/armin/claude/warden-ui/ARCHITECTURE.md §6.
pub const known_keys = [_]KnownKey{
    .{ .key = "WARDEN_RETENTION_MESSAGES", .label = "Message retention (per chat)", .kind = .i64 },
    .{ .key = "WARDEN_DIGEST_INTERVAL_SECONDS", .label = "Digest interval (seconds)", .kind = .i64 },
    .{ .key = "WARDEN_LLM_OWNER_ONLY", .label = "LLM Q&A owner-only", .kind = .bool },
    .{ .key = "WARDEN_LLM_SHOW_THINKING", .label = "Show LLM thinking by default", .kind = .bool },
    .{ .key = "WARDEN_LLM_STREAMING", .label = "Stream LLM responses", .kind = .bool },
    .{ .key = "WARDEN_LLM_MAX_TOKENS", .label = "LLM max tokens override (0 = none)", .kind = .i64 },
    .{ .key = "WARDEN_LLM_HISTORY_MESSAGES", .label = "LLM conversation history window", .kind = .i64 },
    .{ .key = "WARDEN_LLM_SKIP_TRIVIAL_MESSAGES", .label = "Skip LLM call for trivial messages", .kind = .bool },
};

pub fn findKnownKey(key: []const u8) ?KnownKey {
    for (known_keys) |k| {
        if (std.mem.eql(u8, k.key, key)) return k;
    }
    return null;
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

test "listAll fetches every row, findBool/findI64 parse from it with the same fallback semantics as get*" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try set(&pool, "WARDEN_LLM_SHOW_THINKING", "true", owner);
    try set(&pool, "WARDEN_LLM_HISTORY_MESSAGES", "12", owner);

    const rows = try listAll(&pool, a);
    defer {
        for (rows) |r| {
            a.free(r.key);
            a.free(r.value);
        }
        a.free(rows);
    }
    try testing.expectEqual(@as(usize, 2), rows.len);

    try testing.expect(findBool(rows, "WARDEN_LLM_SHOW_THINKING", false));
    try testing.expectEqual(@as(i64, 12), findI64(rows, "WARDEN_LLM_HISTORY_MESSAGES", 20));
    // Absent key -- falls back, doesn't error or match anything spuriously.
    try testing.expect(!findBool(rows, "WARDEN_LLM_STREAMING", false));
    try testing.expectEqual(@as(i64, 999), findI64(rows, "WARDEN_LLM_MAX_TOKENS", 999));
}

test "findKnownKey finds known keys and rejects unknown ones" {
    const found = findKnownKey("WARDEN_LLM_STREAMING") orelse return error.TestExpectedValue;
    try testing.expectEqual(ValueKind.bool, found.kind);
    try testing.expectEqual(@as(?KnownKey, null), findKnownKey("WARDEN_TELEGRAM_BOT_TOKEN"));
}

test "parseBool/parseI64 fall back to default on unparseable input" {
    try testing.expect(parseBool("not-a-bool", true));
    try testing.expect(!parseBool("not-a-bool", false));
    try testing.expectEqual(@as(i64, 7), parseI64("not-a-number", 7));
    try testing.expectEqual(@as(i64, 42), parseI64("42", 7));
}
