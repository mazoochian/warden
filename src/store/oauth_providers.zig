const std = @import("std");
const Db = @import("db.zig").Db;
const PgPool = @import("pool.zig").PgPool;

/// Admin-configured generic-OIDC login providers (Google gets its own
/// well-known env-based config, same as every other external integration
/// — see config.zig; this table is only for "any other OIDC IdP" per
/// /home/armin/claude/warden-ui/ARCHITECTURE.md §3.1/§4). `client_secret`
/// must never be serialized back to an API response — `PublicProvider`
/// below is the shape anything client-facing should actually return.
pub const Provider = struct {
    id: i64,
    name: []const u8,
    issuer_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    enabled: bool,
};

/// The subset safe to hand to a browser (the login-page provider list) —
/// deliberately a distinct type from `Provider`, not just "the same struct
/// minus a field the caller promises not to read," so a future call site
/// can't accidentally serialize the wrong one.
pub const PublicProvider = struct {
    id: i64,
    name: []const u8,
};

pub fn create(pool: *PgPool, name: []const u8, issuer_url: []const u8, client_id: []const u8, client_secret: []const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO oauth_providers (name, issuer_url, client_id, client_secret) VALUES ($1, $2, $3, $4)
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindText(1, name);
    stmt.bindText(2, issuer_url);
    stmt.bindText(3, client_id);
    stmt.bindText(4, client_secret);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

pub fn setEnabled(pool: *PgPool, id: i64, enabled: bool) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("UPDATE oauth_providers SET enabled = $2 WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    stmt.bindBool(2, enabled);
    _ = try stmt.step();
}

pub fn delete(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM oauth_providers WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

/// `null` if `id` doesn't exist — used server-side only (the login
/// callback handler needs the real `client_secret` to complete the code
/// exchange), never returned directly to a client.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Provider {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT name, issuer_url, client_id, client_secret, enabled FROM oauth_providers WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .name = try allocator.dupe(u8, stmt.columnText(0)),
        .issuer_url = try allocator.dupe(u8, stmt.columnText(1)),
        .client_id = try allocator.dupe(u8, stmt.columnText(2)),
        .client_secret = try allocator.dupe(u8, stmt.columnText(3)),
        .enabled = stmt.columnBool(4),
    };
}

/// Every enabled provider, secret-free — the login page's provider list.
pub fn listEnabledPublic(pool: *PgPool, allocator: std.mem.Allocator) ![]PublicProvider {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, name FROM oauth_providers WHERE enabled = TRUE ORDER BY name;");
    defer stmt.finalize();

    var out: std.ArrayList(PublicProvider) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .name = try allocator.dupe(u8, stmt.columnText(1)),
        });
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "create/get round-trips a provider including its secret; listEnabledPublic never includes it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const id = try create(&pool, "Authentik", "https://auth.example.com", "client-123", "shh-secret");

    const provider = (try get(&pool, a, id)) orelse return error.TestExpectedValue;
    defer {
        a.free(provider.name);
        a.free(provider.issuer_url);
        a.free(provider.client_id);
        a.free(provider.client_secret);
    }
    try testing.expectEqualStrings("Authentik", provider.name);
    try testing.expectEqualStrings("shh-secret", provider.client_secret);
    try testing.expect(provider.enabled);

    const public_list = try listEnabledPublic(&pool, a);
    defer {
        for (public_list) |p| a.free(p.name);
        a.free(public_list);
    }
    try testing.expectEqual(@as(usize, 1), public_list.len);
    try testing.expectEqualStrings("Authentik", public_list[0].name);
}

test "setEnabled(false) removes a provider from listEnabledPublic without deleting it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const id = try create(&pool, "Keycloak", "https://kc.example.com", "cid", "secret");
    try setEnabled(&pool, id, false);

    try testing.expectEqual(@as(usize, 0), (try listEnabledPublic(&pool, a)).len);

    const provider = (try get(&pool, a, id)) orelse return error.TestExpectedValue;
    defer {
        a.free(provider.name);
        a.free(provider.issuer_url);
        a.free(provider.client_id);
        a.free(provider.client_secret);
    }
    try testing.expect(!provider.enabled);
}

test "delete removes a provider entirely" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const id = try create(&pool, "Zitadel", "https://zt.example.com", "cid", "secret");
    try delete(&pool, id);
    try testing.expectEqual(@as(?Provider, null), try get(&pool, a, id));
}
