//! Method+path dispatch, JSON helpers, and session resolution for
//! warden-ui's API — see /home/armin/claude/warden-ui/API.md for the
//! endpoint contract this is built against. Deliberately a small
//! hand-rolled matcher (a handful of exact-path `if`s), not a routing
//! framework — the endpoint count doesn't remotely justify one yet, and
//! this file is exactly the place to grow one later if it ever does.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const server_mod = @import("server.zig");
const auth = @import("auth.zig");
const ServerContext = server_mod.ServerContext;
const web_sessions = @import("../store/web_sessions.zig");
const accounts = @import("../store/accounts.zig");
const identities = @import("../store/identities.zig");
const audit_log = @import("../store/audit_log.zig");
const telegram_login = @import("telegram_login.zig");
const log = @import("../log.zig").scoped("api");

/// Telegram re-issues `auth_date` on every widget load; anything older than
/// this is treated as a captured/replayed payload rather than a
/// legitimately slow page load.
const telegram_login_max_age_seconds: i64 = 24 * 3600;

/// One request's resolved caller — `null` `account_id` means
/// unauthenticated (a missing/invalid/expired session cookie), which is a
/// normal outcome for public endpoints (`GET /api/v1/auth/providers`,
/// login callbacks), not itself an error. Endpoints that require auth
/// check this themselves and respond `401` — there's no blanket
/// auth-required-by-default middleware, matching how warden's own
/// command handlers each apply their own `auth.zig` gate rather than a
/// single global one.
const RequestAuth = struct {
    account_id: ?i64,
};

pub fn dispatch(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    const method = request.head.method;

    if (method == .GET and std.mem.eql(u8, path, "/api/v1/auth/session")) {
        return handleGetSession(ctx, request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/auth/providers")) {
        return handleGetProviders(ctx, request);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/auth/telegram/callback")) {
        return handleTelegramCallback(ctx, request);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/auth/dev-login")) {
        return handleDevLogin(ctx, request);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/auth/logout")) {
        return handleLogout(ctx, request);
    }

    try respondError(request, .not_found, "not_found", "no such endpoint");
}

// ---------------------------------------------------------------------------
// Endpoint handlers
// ---------------------------------------------------------------------------

/// `GET /api/v1/auth/session` — see API.md. The one endpoint that has to
/// exist to prove the whole cookie -> session row -> account -> linked
/// identities chain works end to end, even before any real login method
/// is wired up.
fn handleGetSession(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        return respondJson(ctx, request, .ok, .{ .authenticated = false });
    };

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("session: failed to list identities for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load session");
    };
    defer ctx.allocator.free(identity_ids);

    return respondJson(ctx, request, .ok, .{
        .authenticated = true,
        .account_id = account_id,
        .identity_ids = identity_ids,
    });
}

/// `GET /api/v1/auth/providers` — public, no auth required. Lets the
/// login page render itself without hardcoding which login methods are
/// actually configured server-side (see API.md). Google/generic OIDC
/// aren't wired up yet (Phase 1 in progress), so those always come back
/// empty for now.
fn handleGetProviders(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const TelegramProvider = struct { bot_username: []const u8 };
    const OidcProvider = struct { id: []const u8, name: []const u8 };
    const Response = struct {
        telegram: ?TelegramProvider,
        google: ?struct {} = null,
        oidc: []const OidcProvider = &.{},
    };
    return respondJson(ctx, request, .ok, Response{
        .telegram = if (ctx.config.telegram_bot_username) |username|
            TelegramProvider{ .bot_username = username }
        else
            null,
    });
}

/// `POST /api/v1/auth/telegram/callback` — see API.md and
/// `ARCHITECTURE.md` §3.1/§3.3. Body: the Telegram Login Widget's own
/// returned fields (`telegram_login.Payload`). Verifies `hash`, resolves
/// straight to the bot's existing `identities` row for that Telegram user
/// (no linking step needed — see §3.3 for why this is the one login
/// method that doesn't need a fresh `identities` row most of the time),
/// finds-or-creates the linked `accounts` row, issues a session.
fn handleTelegramCallback(ctx: *const ServerContext, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [8 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(8 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const payload = std.json.parseFromSliceLeaky(telegram_login.Payload, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid telegram login payload");
    };

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const ok = telegram_login.verify(ctx.allocator, payload, ctx.config.telegram_bot_token, now, telegram_login_max_age_seconds) catch |err| {
        log.err("telegram-login: verify errored: {t}", .{err});
        return respondError(request, .internal_server_error, "internal", "failed to verify login");
    };
    if (!ok) {
        return respondError(request, .unauthorized, "invalid_login", "telegram login verification failed");
    }

    var id_buf: [20]u8 = undefined;
    const native_id = std.fmt.bufPrint(&id_buf, "{d}", .{payload.id}) catch unreachable;

    const identity_id = identities.getOrCreateMinimal(ctx.pool, .telegram, native_id, payload.first_name, payload.username, false, now) catch |err| {
        log.err("telegram-login: failed to resolve identity for telegram id {d}: {t}", .{ payload.id, err });
        return respondError(request, .internal_server_error, "internal", "failed to resolve identity");
    };

    const account_id = blk: {
        if (accounts.findByIdentity(ctx.pool, ctx.allocator, identity_id) catch null) |existing| {
            ctx.allocator.free(existing.display_name);
            if (existing.avatar_url) |u| ctx.allocator.free(u);
            break :blk existing.id;
        }
        break :blk accounts.create(ctx.pool, identity_id, payload.first_name, payload.photo_url) catch |err| {
            log.err("telegram-login: failed to create account for identity {d}: {t}", .{ identity_id, err });
            return respondError(request, .internal_server_error, "internal", "failed to create account");
        };
    };

    return issueSessionAndRespond(ctx, request, account_id);
}

/// `POST /api/v1/auth/dev-login` — see `Config.api_dev_login`'s doc
/// comment for why this exists and why it must never be reachable
/// outside a contributor's own machine. Body: `{"identity_id": <int>}`.
/// Resolves or creates an account for that identity, mints a session,
/// sets the cookie.
fn handleDevLogin(ctx: *const ServerContext, request: *http.Server.Request) !void {
    if (!ctx.config.api_dev_login) {
        return respondError(request, .not_found, "not_found", "no such endpoint");
    }

    const Body = struct { identity_id: i64 };
    const body = readJsonBody(ctx, request, Body) catch {
        return respondError(request, .bad_request, "bad_request", "expected {\"identity_id\": <int>}");
    };

    const account_id = blk: {
        if (accounts.findByIdentity(ctx.pool, ctx.allocator, body.identity_id) catch null) |existing| {
            ctx.allocator.free(existing.display_name);
            if (existing.avatar_url) |u| ctx.allocator.free(u);
            break :blk existing.id;
        }
        break :blk accounts.create(ctx.pool, body.identity_id, "Dev Login", null) catch |err| {
            log.err("dev-login: failed to create account for identity {d}: {t}", .{ body.identity_id, err });
            return respondError(request, .internal_server_error, "internal", "failed to create account");
        };
    };

    return issueSessionAndRespond(ctx, request, account_id);
}

fn handleLogout(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const a = resolveAuth(ctx, request);
    if (a.account_id) |account_id| {
        if (findCookie(request, auth.cookie_name)) |token| {
            const secret = ctx.config.api_session_secret orelse "";
            if (auth.verify(token, secret)) |session_id| {
                const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
                web_sessions.revoke(ctx.pool, session_id, now) catch |err| {
                    log.warn("logout: failed to revoke session {d}: {t}", .{ session_id, err });
                };
                audit_log.record(ctx.pool, account_id, "auth.logout", null, null);
            }
        }
    }
    try request.respond("{}", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "set-cookie", .value = auth.cookie_name ++ "=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0" },
        },
    });
}

fn issueSessionAndRespond(ctx: *const ServerContext, request: *http.Server.Request, account_id: i64) !void {
    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const expires_at = now + 30 * 24 * 3600; // 30 days

    const session_id = web_sessions.create(ctx.pool, account_id, now, expires_at, null, null) catch |err| {
        log.err("failed to create session for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to create session");
    };
    audit_log.record(ctx.pool, account_id, "auth.login", null, null);

    const secret = ctx.config.api_session_secret orelse {
        // Unreachable in practice: `Config.load` refuses to start the API
        // at all without this set (see config.zig) — this branch exists
        // only so the type system doesn't need an artificial `.?`.
        return respondError(request, .internal_server_error, "internal", "session signing not configured");
    };
    const token = auth.sign(ctx.allocator, session_id, secret) catch {
        return respondError(request, .internal_server_error, "internal", "failed to sign session");
    };
    defer ctx.allocator.free(token);

    const cookie_value = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}={s}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000",
        .{ auth.cookie_name, token },
    );
    defer ctx.allocator.free(cookie_value);

    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .account_id = account_id }, .{});
    defer ctx.allocator.free(body);

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "set-cookie", .value = cookie_value },
        },
    });
}

// ---------------------------------------------------------------------------
// Session resolution
// ---------------------------------------------------------------------------

fn resolveAuth(ctx: *const ServerContext, request: *http.Server.Request) RequestAuth {
    const secret = ctx.config.api_session_secret orelse return .{ .account_id = null };
    const token = findCookie(request, auth.cookie_name) orelse return .{ .account_id = null };
    const session_id = auth.verify(token, secret) orelse return .{ .account_id = null };
    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const session = web_sessions.getValid(ctx.pool, session_id, now) orelse return .{ .account_id = null };
    return .{ .account_id = session.account_id };
}

/// Scans the request's `Cookie` header(s) for `name=value`, returning the
/// raw value (not yet URL-decoded — session tokens here are already
/// URL-safe base64 plus digits/a dot, so decoding was never needed). Thin
/// wrapper around `parseCookieValue` (split out so the actual parsing
/// logic is unit-testable without needing a real `http.Server.Request`).
fn findCookie(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "cookie")) continue;
        if (parseCookieValue(header.value, name)) |value| return value;
    }
    return null;
}

fn parseCookieValue(cookie_header_value: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, cookie_header_value, ';');
    while (pairs.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
    }
    return null;
}

const testing = std.testing;

test "parseCookieValue finds a named cookie among several, ignores others" {
    const header = "foo=bar; warden_session=abc123.def456; baz=qux";
    try testing.expectEqualStrings("abc123.def456", parseCookieValue(header, "warden_session").?);
    try testing.expectEqualStrings("bar", parseCookieValue(header, "foo").?);
    try testing.expectEqual(@as(?[]const u8, null), parseCookieValue(header, "missing"));
}

test "parseCookieValue handles a single cookie, extra whitespace, and an empty header" {
    try testing.expectEqualStrings("solo", parseCookieValue("warden_session=solo", "warden_session").?);
    try testing.expectEqualStrings("spaced", parseCookieValue("  warden_session=spaced  ", "warden_session").?);
    try testing.expectEqual(@as(?[]const u8, null), parseCookieValue("", "warden_session"));
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn respondJson(ctx: *const ServerContext, request: *http.Server.Request, status: http.Status, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, value, .{});
    defer ctx.allocator.free(body);
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// The `{"error":{"code","message"}}` shape from API.md's conventions
/// section.
fn respondError(request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    std.json.Stringify.value(.{ .@"error" = .{ .code = code, .message = message } }, .{}, &stream) catch {};
    try request.respond(stream.buffered(), .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// Reads and parses the full request body as JSON `T` — fine for the
/// small control-plane payloads this API deals with (nothing here is a
/// large file upload; Convert's multipart handling will need its own
/// streaming path when Phase 5c gets built, not this).
///
/// CAUTION: only safe for `T`s made entirely of value types (ints, bools,
/// enums) — the parsed result is returned *after* `parsed.deinit()` frees
/// the arena backing any `[]const u8`/nested-allocation fields, so a `T`
/// with a string field would return a dangling slice. None of Phase 0's
/// bodies need strings yet; the first caller that does must switch to
/// `std.json.parseFromSliceLeaky` with its own caller-supplied arena
/// instead of reaching for this helper unchanged.
fn readJsonBody(ctx: *const ServerContext, request: *http.Server.Request, comptime T: type) !T {
    var buf: [16 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = try reader.allocRemaining(ctx.allocator, .limited(16 * 1024));
    defer ctx.allocator.free(raw);
    const parsed = try std.json.parseFromSlice(T, ctx.allocator, raw, .{});
    defer parsed.deinit();
    return parsed.value;
}
