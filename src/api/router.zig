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
const bot_admins = @import("../store/bot_admins.zig");
const admin_directory = @import("../store/admin_directory.zig");
const feature_flags = @import("../store/feature_flags.zig");
const dynamic_config = @import("../store/dynamic_config.zig");
const config_mod = @import("../config.zig");
const iface = @import("../platform/interface.zig");
const chats_store = @import("../store/chats.zig");
const chat_members = @import("../store/chat_members.zig");
const chat_settings = @import("../store/chat_settings.zig");
const user_settings = @import("../store/user_settings.zig");
const civil_time = @import("../text/civil_time.zig");
const audit_log = @import("../store/audit_log.zig");
const telegram_login = @import("telegram_login.zig");
/// The bot's own permission-ladder module (owner check) -- aliased since
/// `auth` above already names this file's own session-token module
/// (`api/auth.zig`).
const perm_auth = @import("../auth.zig");
const log = @import("../log.zig").scoped("api");

/// Telegram re-issues `auth_date` on every widget load; anything older than
/// this is treated as a captured/replayed payload rather than a
/// legitimately slow page load.
const telegram_login_max_age_seconds: i64 = 24 * 3600;

const me_sessions_prefix = "/api/v1/me/sessions/";
const admin_chats_prefix = "/api/v1/admin/chats/";
const admin_identities_prefix = "/api/v1/admin/identities/";
const admin_modules_prefix = "/api/v1/admin/modules/";
const admin_config_prefix = "/api/v1/admin/config/";
const chats_prefix = "/api/v1/chats/";
const chat_settings_suffix = "/settings";
const chat_members_suffix = "/members";

/// Default/max page size, matching `API.md`'s pagination convention.
const default_page_limit: i64 = 50;
const max_page_limit: i64 = 200;

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
    /// The resolved session's own id — `null` whenever `account_id` is
    /// `null`. Distinct from `account_id` since `/me/sessions` needs to
    /// mark which listed row is "this device" without a second lookup.
    session_id: ?i64 = null,
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
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/me/sessions")) {
        return handleListSessions(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, me_sessions_prefix)) {
        return handleRevokeSession(ctx, request, path[me_sessions_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/admin/stats/overview")) {
        return handleAdminStatsOverview(ctx, request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/admin/chats")) {
        return handleAdminListChats(ctx, request, target);
    }
    if (method == .GET and std.mem.startsWith(u8, path, admin_chats_prefix)) {
        return handleAdminGetChat(ctx, request, path[admin_chats_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/admin/identities")) {
        return handleAdminListIdentities(ctx, request, target);
    }
    if (method == .GET and std.mem.startsWith(u8, path, admin_identities_prefix)) {
        return handleAdminGetIdentity(ctx, request, path[admin_identities_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/admin/modules")) {
        return handleAdminListModules(ctx, request);
    }
    if (method == .PATCH and std.mem.startsWith(u8, path, admin_modules_prefix)) {
        return handleAdminSetModule(ctx, request, path[admin_modules_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/admin/config")) {
        return handleAdminListConfig(ctx, request);
    }
    if (method == .PATCH and std.mem.startsWith(u8, path, admin_config_prefix)) {
        return handleAdminSetConfig(ctx, request, path[admin_config_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/admin/audit-log")) {
        return handleAdminAuditLog(ctx, request, target);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/chats")) {
        return handleListMyChats(ctx, request);
    }
    if (std.mem.startsWith(u8, path, chats_prefix)) {
        const rest = path[chats_prefix.len..];
        if (std.mem.endsWith(u8, rest, chat_settings_suffix)) {
            const id_str = rest[0 .. rest.len - chat_settings_suffix.len];
            if (method == .GET) return handleGetChatSettings(ctx, request, id_str);
            if (method == .PATCH) return handleSetChatSettings(ctx, request, id_str);
        } else if (std.mem.endsWith(u8, rest, chat_members_suffix)) {
            const id_str = rest[0 .. rest.len - chat_members_suffix.len];
            if (method == .GET) return handleListChatMembers(ctx, request, id_str);
        }
    }
    if (std.mem.eql(u8, path, "/api/v1/me/settings")) {
        if (method == .GET) return handleGetMySettings(ctx, request);
        if (method == .PATCH) return handleSetMySettings(ctx, request);
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

    // Both lookups reading a session's own just-resolved account_id
    // failing would mean the account row vanished between the session
    // being minted and now (never observed, no delete path exists yet) --
    // treated as a hard error rather than silently downgrading to
    // "unauthenticated", since that would mask a real data-integrity bug.
    const account = accounts.getById(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("session: failed to load account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load session");
    } orelse {
        log.err("session: account {d} referenced by a valid session no longer exists", .{account_id});
        return respondError(request, .internal_server_error, "internal", "failed to load session");
    };
    defer ctx.allocator.free(account.display_name);
    defer if (account.avatar_url) |u| ctx.allocator.free(u);

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("session: failed to list identities for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load session");
    };
    defer ctx.allocator.free(identity_ids);

    const roles = computeRoles(ctx, account_id) catch |err| {
        log.err("session: failed to compute roles for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load session");
    };

    return respondJson(ctx, request, .ok, .{
        .authenticated = true,
        .account_id = account_id,
        .display_name = account.display_name,
        .avatar_url = account.avatar_url,
        .identity_ids = identity_ids,
        .roles = roles,
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
    // Must happen before any body read below -- `iterateHeaders` asserts
    // the reader is still in its post-head, pre-body state (see
    // `issueSessionAndRespond`'s doc comment for the crash this caused
    // before user-agent capture was moved here).
    const user_agent = findHeader(request, "user-agent");

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

    return issueSessionAndRespond(ctx, request, account_id, user_agent);
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

    // Must happen before `readJsonBody` below -- see
    // `issueSessionAndRespond`'s doc comment.
    const user_agent = findHeader(request, "user-agent");

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

    return issueSessionAndRespond(ctx, request, account_id, user_agent);
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

/// `GET /api/v1/me/sessions` — every live session for the caller's
/// account, most recent first, with `current: true` on whichever one the
/// request itself is authenticated with (so the frontend can label "this
/// device" instead of making the user guess by user-agent string).
fn handleListSessions(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        return respondError(request, .unauthorized, "unauthorized", "not logged in");
    };

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const sessions = web_sessions.listLiveForAccount(ctx.pool, ctx.allocator, account_id, now) catch |err| {
        log.err("list-sessions: failed for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load sessions");
    };
    defer {
        for (sessions) |s| {
            if (s.user_agent) |ua| ctx.allocator.free(ua);
            if (s.ip) |ip| ctx.allocator.free(ip);
        }
        ctx.allocator.free(sessions);
    }

    const Item = struct {
        id: i64,
        created_at: i64,
        expires_at: i64,
        user_agent: ?[]const u8,
        ip: ?[]const u8,
        current: bool,
    };
    var items = try ctx.allocator.alloc(Item, sessions.len);
    defer ctx.allocator.free(items);
    for (sessions, 0..) |s, i| {
        items[i] = .{
            .id = s.id,
            .created_at = s.created_at,
            .expires_at = s.expires_at,
            .user_agent = s.user_agent,
            .ip = s.ip,
            .current = a.session_id != null and a.session_id.? == s.id,
        };
    }

    return respondJson(ctx, request, .ok, .{ .items = items });
}

/// `DELETE /api/v1/me/sessions/:sessionId` — revokes a session, including
/// (deliberately) the one making the request itself, which is just "log
/// out" — same convention `API.md` documents. Refuses (`404`, not `403`,
/// to avoid confirming *some* session exists at that id to a caller who
/// doesn't own it) if `sessionId` doesn't resolve to a live session owned
/// by the caller's own account.
fn handleRevokeSession(ctx: *const ServerContext, request: *http.Server.Request, session_id_str: []const u8) !void {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        return respondError(request, .unauthorized, "unauthorized", "not logged in");
    };

    const session_id = std.fmt.parseInt(i64, session_id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid session id");
    };

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const session = web_sessions.getValid(ctx.pool, session_id, now) orelse {
        return respondError(request, .not_found, "not_found", "no such session");
    };
    if (session.account_id != account_id) {
        return respondError(request, .not_found, "not_found", "no such session");
    }

    web_sessions.revoke(ctx.pool, session_id, now) catch |err| {
        log.err("revoke-session: failed to revoke session {d}: {t}", .{ session_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to revoke session");
    };
    audit_log.record(ctx.pool, account_id, "auth.session_revoke", session_id_str, null);

    return respondJson(ctx, request, .ok, .{});
}

// ---------------------------------------------------------------------------
// Admin — stats & directory (Phase 2, read-only)
// ---------------------------------------------------------------------------

const Roles = struct { owner: bool, bot_admin: bool };

/// An account's effective role is the union across every `identities` row
/// linked to it (`ARCHITECTURE.md` §7) — most accounts have exactly one
/// linked identity today (no account-linking flow exists yet), but this
/// stays correct once one does.
fn computeRoles(ctx: *const ServerContext, account_id: i64) !Roles {
    const identity_ids = try accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id);
    defer ctx.allocator.free(identity_ids);

    var roles = Roles{ .owner = false, .bot_admin = false };
    for (identity_ids) |identity_id| {
        if (bot_admins.isBotAdmin(ctx.pool, identity_id)) roles.bot_admin = true;
        if (identities.getWhoisInfo(ctx.pool, ctx.allocator, identity_id) catch null) |info| {
            defer ctx.allocator.free(info.native_id);
            defer ctx.allocator.free(info.display_name);
            defer if (info.username) |u| ctx.allocator.free(u);
            if (perm_auth.isOwner(ctx.config, info.platform, info.native_id)) roles.owner = true;
        }
    }
    return roles;
}

/// Every `/api/v1/admin/*` handler starts with this. `null` means a
/// response was already sent (`401` unauthenticated, `403` not owner/bot
/// admin) — the caller just returns.
fn requireAdmin(ctx: *const ServerContext, request: *http.Server.Request) !?i64 {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        try respondError(request, .unauthorized, "unauthorized", "not logged in");
        return null;
    };
    const roles = try computeRoles(ctx, account_id);
    if (!roles.owner and !roles.bot_admin) {
        try respondError(request, .forbidden, "forbidden", "admin access required");
        return null;
    }
    return account_id;
}

/// `?limit=` clamped to `[1, max_page_limit]`, defaulting to
/// `default_page_limit`; `?cursor=` parsed as the last-seen id (`0` — the
/// start of the table — if absent/unparseable).
fn paginationParams(target: []const u8) struct { after_id: i64, limit: i64 } {
    const after_id = if (queryParam(target, "cursor")) |c|
        std.fmt.parseInt(i64, c, 10) catch 0
    else
        0;
    const limit = if (queryParam(target, "limit")) |l|
        std.math.clamp(std.fmt.parseInt(i64, l, 10) catch default_page_limit, 1, max_page_limit)
    else
        default_page_limit;
    return .{ .after_id = after_id, .limit = limit };
}

fn queryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn handleAdminStatsOverview(ctx: *const ServerContext, request: *http.Server.Request) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const stats = admin_directory.overview(ctx.pool, now) catch |err| {
        log.err("admin-stats-overview: failed: {t}", .{err});
        return respondError(request, .internal_server_error, "internal", "failed to load stats");
    };
    return respondJson(ctx, request, .ok, stats);
}

fn handleAdminListChats(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    const page = paginationParams(target);
    const chats = admin_directory.listChats(ctx.pool, ctx.allocator, page.after_id, page.limit) catch |err| {
        log.err("admin-list-chats: failed: {t}", .{err});
        return respondError(request, .internal_server_error, "internal", "failed to load chats");
    };
    defer {
        for (chats) |c| {
            ctx.allocator.free(c.native_chat_id);
            if (c.title) |t| ctx.allocator.free(t);
        }
        ctx.allocator.free(chats);
    }

    const next_cursor: ?i64 = if (chats.len == @as(usize, @intCast(page.limit))) chats[chats.len - 1].id else null;
    return respondJson(ctx, request, .ok, .{ .items = chats, .next_cursor = next_cursor });
}

fn handleAdminGetChat(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    const detail = admin_directory.getChatDetail(ctx.pool, ctx.allocator, chat_id) catch |err| {
        log.err("admin-get-chat: failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load chat");
    } orelse {
        return respondError(request, .not_found, "not_found", "no such chat");
    };
    defer {
        ctx.allocator.free(detail.native_chat_id);
        if (detail.title) |t| ctx.allocator.free(t);
        if (detail.chat_type) |t| ctx.allocator.free(t);
        if (detail.magic_word) |t| ctx.allocator.free(t);
        for (detail.recent_messages) |m| {
            ctx.allocator.free(m.sender_display_name);
            if (m.text) |t| ctx.allocator.free(t);
        }
        ctx.allocator.free(detail.recent_messages);
    }

    return respondJson(ctx, request, .ok, detail);
}

fn handleAdminListIdentities(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    const page = paginationParams(target);
    const list = admin_directory.listIdentities(ctx.pool, ctx.allocator, page.after_id, page.limit) catch |err| {
        log.err("admin-list-identities: failed: {t}", .{err});
        return respondError(request, .internal_server_error, "internal", "failed to load identities");
    };
    defer {
        for (list) |i| {
            ctx.allocator.free(i.display_name);
            if (i.username) |u| ctx.allocator.free(u);
        }
        ctx.allocator.free(list);
    }

    const next_cursor: ?i64 = if (list.len == @as(usize, @intCast(page.limit))) list[list.len - 1].id else null;
    return respondJson(ctx, request, .ok, .{ .items = list, .next_cursor = next_cursor });
}

fn handleAdminGetIdentity(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    const identity_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid identity id");
    };
    const detail = admin_directory.getIdentityDetail(ctx.pool, ctx.allocator, identity_id) catch |err| {
        log.err("admin-get-identity: failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load identity");
    } orelse {
        return respondError(request, .not_found, "not_found", "no such identity");
    };
    defer {
        ctx.allocator.free(detail.native_id);
        ctx.allocator.free(detail.display_name);
        if (detail.username) |u| ctx.allocator.free(u);
    }

    return respondJson(ctx, request, .ok, detail);
}

/// `GET /api/v1/admin/modules` — `known_modules` unioned with whatever's
/// been explicitly toggled in `feature_flags` (a module never touched has
/// no row and defaults to enabled, per `feature_flags.isEnabled`'s doc
/// comment).
fn handleAdminListModules(ctx: *const ServerContext, request: *http.Server.Request) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    const explicit = feature_flags.listExplicit(ctx.pool, ctx.allocator) catch |err| {
        log.err("admin-list-modules: failed: {t}", .{err});
        return respondError(request, .internal_server_error, "internal", "failed to load modules");
    };
    defer {
        for (explicit) |f| ctx.allocator.free(f.module);
        ctx.allocator.free(explicit);
    }

    const Item = struct { key: []const u8, label: []const u8, category: feature_flags.ModuleCategory, enabled: bool };
    var items: [feature_flags.known_modules.len]Item = undefined;
    for (feature_flags.known_modules, 0..) |m, i| {
        var enabled = true;
        for (explicit) |f| {
            if (std.mem.eql(u8, f.module, m.key)) {
                enabled = f.enabled;
                break;
            }
        }
        items[i] = .{ .key = m.key, .label = m.label, .category = m.category, .enabled = enabled };
    }

    return respondJson(ctx, request, .ok, .{ .items = items[0..] });
}

/// `PATCH /api/v1/admin/modules/:module` — body `{"enabled": bool}`.
fn handleAdminSetModule(ctx: *const ServerContext, request: *http.Server.Request, module: []const u8) !void {
    const account_id = (try requireAdmin(ctx, request)) orelse return;

    if (!feature_flags.isKnownModule(module)) {
        return respondError(request, .not_found, "not_found", "no such module");
    }

    const Body = struct { enabled: bool };
    const body = readJsonBody(ctx, request, Body) catch {
        return respondError(request, .bad_request, "bad_request", "expected {\"enabled\": <bool>}");
    };

    feature_flags.setEnabled(ctx.pool, module, body.enabled, account_id) catch |err| {
        log.err("admin-set-module: failed to set {s}={} : {t}", .{ module, body.enabled, err });
        return respondError(request, .internal_server_error, "internal", "failed to update module");
    };
    audit_log.record(ctx.pool, account_id, "module.set", module, if (body.enabled) "{\"enabled\":true}" else "{\"enabled\":false}");

    return respondJson(ctx, request, .ok, .{});
}

/// Never returns any part of `value` verbatim — only its last 4 characters
/// (enough to help someone recognize "yes, that's the right key" without
/// the API ever transmitting a secret that could be captured in a log,
/// screenshot, or browser history). `"(not set)"` for an empty value
/// (matches the `OpenAiCompatConfig.api_key` "empty if unset" convention).
/// Always returns memory owned by `a` (even the fixed-text cases) so
/// callers can unconditionally free every `ConfigEntry.value` the same
/// way regardless of which branch produced it.
fn maskSecret(a: std.mem.Allocator, value: []const u8) []const u8 {
    if (value.len == 0) return a.dupe(u8, "(not set)") catch "(not set)";
    if (value.len <= 4) return a.dupe(u8, "••••") catch "••••";
    return std.fmt.allocPrint(a, "••••{s}", .{value[value.len - 4 ..]}) catch "••••";
}

const ConfigEntry = struct {
    key: []const u8,
    label: []const u8,
    category: []const u8,
    value: []const u8,
    is_override: ?bool,
};

/// `GET /api/v1/admin/config` — per ARCHITECTURE.md §6: secrets (masked,
/// read live from `ctx.config`, never touching `dynamic_config`) plus
/// every `dynamic_config.known_keys` entry with its current effective
/// value and whether a DB override exists. Deliberately doesn't yet list
/// identity/infra/restart-required fields (§6's other two categories) --
/// those aren't editable either way today, and this endpoint's real job
/// is surfacing what's actually live; a display-only catalog of the rest
/// is a reasonable follow-up, not done here.
fn handleAdminListConfig(ctx: *const ServerContext, request: *http.Server.Request) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    var entries: std.ArrayList(ConfigEntry) = .empty;
    defer {
        for (entries.items) |e| ctx.allocator.free(e.value);
        entries.deinit(ctx.allocator);
    }

    const addSecret = struct {
        fn call(list: *std.ArrayList(ConfigEntry), a: std.mem.Allocator, key: []const u8, label: []const u8, value: []const u8) !void {
            try list.append(a, .{ .key = key, .label = label, .category = "secret", .value = maskSecret(a, value), .is_override = null });
        }
    }.call;

    try addSecret(&entries, ctx.allocator, "WARDEN_TELEGRAM_BOT_TOKEN", "Telegram bot token", ctx.config.telegram_bot_token);
    try addSecret(&entries, ctx.allocator, "WARDEN_POSTGRES_DSN", "Postgres connection string", ctx.config.postgres_dsn);
    // Both, not just whichever `config.llm` selected as the startup
    // default -- `WARDEN_LLM_PROVIDER` is hot-swappable now (see
    // `llm/dynamic_provider.zig`), so an admin switching providers needs
    // to see confirmation *both* keys are set, not just the one active
    // when the process started.
    if (ctx.config.llm_anthropic) |c| try addSecret(&entries, ctx.allocator, "WARDEN_ANTHROPIC_API_KEY", "Anthropic API key", c.api_key);
    if (ctx.config.llm_openai_compat) |c| try addSecret(&entries, ctx.allocator, "WARDEN_OPENAI_API_KEY", "OpenAI-compatible API key", c.api_key);
    if (ctx.config.matrix) |m| try addSecret(&entries, ctx.allocator, "WARDEN_MATRIX_ACCESS_TOKEN", "Matrix access token", m.access_token);
    if (ctx.config.xmpp) |x| try addSecret(&entries, ctx.allocator, "WARDEN_XMPP_PASSWORD", "XMPP password", x.password);
    if (ctx.config.matrix_pickle_key) |k| try addSecret(&entries, ctx.allocator, "WARDEN_MATRIX_PICKLE_KEY", "Matrix E2EE pickle key", k);

    const rows = dynamic_config.listAll(ctx.pool, ctx.allocator) catch &.{};
    defer {
        for (rows) |r| {
            ctx.allocator.free(r.key);
            ctx.allocator.free(r.value);
        }
        ctx.allocator.free(rows);
    }

    for (dynamic_config.known_keys) |k| {
        var override_row: ?dynamic_config.KV = null;
        for (rows) |r| {
            if (std.mem.eql(u8, r.key, k.key)) {
                override_row = r;
                break;
            }
        }
        const value = if (override_row) |r|
            try ctx.allocator.dupe(u8, r.value)
        else
            try defaultForKnownKey(ctx.allocator, ctx.config, k.key);
        try entries.append(ctx.allocator, .{
            .key = k.key,
            .label = k.label,
            .category = "dynamic",
            .value = value,
            .is_override = override_row != null,
        });
    }

    return respondJson(ctx, request, .ok, .{ .items = entries.items });
}

/// The env-sourced fallback for one of `dynamic_config.known_keys`,
/// formatted as a string for the uniform `ConfigEntry.value` shape.
fn defaultForKnownKey(a: std.mem.Allocator, config: *const config_mod.Config, key: []const u8) ![]const u8 {
    if (std.mem.eql(u8, key, "WARDEN_RETENTION_MESSAGES")) return std.fmt.allocPrint(a, "{d}", .{config.retention_messages});
    if (std.mem.eql(u8, key, "WARDEN_DIGEST_INTERVAL_SECONDS")) return std.fmt.allocPrint(a, "{d}", .{config.digest_interval_seconds});
    if (std.mem.eql(u8, key, "WARDEN_LLM_OWNER_ONLY")) return std.fmt.allocPrint(a, "{}", .{config.llm_owner_only});
    if (std.mem.eql(u8, key, "WARDEN_LLM_SHOW_THINKING")) return std.fmt.allocPrint(a, "{}", .{config.llm_show_thinking});
    if (std.mem.eql(u8, key, "WARDEN_LLM_STREAMING")) return std.fmt.allocPrint(a, "{}", .{config.llm_streaming});
    if (std.mem.eql(u8, key, "WARDEN_LLM_MAX_TOKENS")) return std.fmt.allocPrint(a, "{d}", .{config.llm_max_tokens_override orelse 0});
    if (std.mem.eql(u8, key, "WARDEN_LLM_HISTORY_MESSAGES")) return std.fmt.allocPrint(a, "{d}", .{config.llm_history_messages});
    if (std.mem.eql(u8, key, "WARDEN_LLM_SKIP_TRIVIAL_MESSAGES")) return std.fmt.allocPrint(a, "{}", .{config.skip_trivial_messages});
    if (std.mem.eql(u8, key, "WARDEN_LLM_PROVIDER")) return a.dupe(u8, if (config.llm == .openai_compat) "openai_compat" else "anthropic");
    return a.dupe(u8, "");
}

/// `PATCH /api/v1/admin/config/:key` — body `{"value": "..."}`. Only
/// accepts keys in `dynamic_config.known_keys`; `403` for anything else
/// (secrets can never be written here — there's no endpoint that accepts
/// them at all, matching "never accepted on write" from ARCHITECTURE.md
/// §6 — and identity/infra/restart-required keys aren't wired to be read
/// back live yet, so accepting a write for them would silently go
/// nowhere).
fn handleAdminSetConfig(ctx: *const ServerContext, request: *http.Server.Request, key: []const u8) !void {
    const account_id = (try requireAdmin(ctx, request)) orelse return;

    const known = dynamic_config.findKnownKey(key) orelse {
        return respondError(request, .forbidden, "forbidden", "this key isn't editable");
    };

    const Body = struct { value: []const u8 };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(4 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(Body, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "expected {\"value\": \"...\"}");
    };

    const valid = switch (known.kind) {
        .bool => std.ascii.eqlIgnoreCase(body.value, "true") or std.mem.eql(u8, body.value, "1") or
            std.ascii.eqlIgnoreCase(body.value, "false") or std.mem.eql(u8, body.value, "0"),
        .i64 => (std.fmt.parseInt(i64, body.value, 10) catch null) != null,
        .string => true,
    };
    if (!valid) {
        return respondError(request, .bad_request, "bad_request", "value doesn't match this key's expected type");
    }

    // WARDEN_LLM_PROVIDER specifically: only a provider that actually has
    // credentials configured is a real value to switch to -- see
    // `llm/dynamic_provider.zig`'s doc comment for why "accept anything,
    // let the runtime silently fall back" would be worse than rejecting
    // the write up front with a clear reason.
    if (std.mem.eql(u8, key, "WARDEN_LLM_PROVIDER")) {
        const configured = if (std.mem.eql(u8, body.value, "anthropic"))
            ctx.config.llm_anthropic != null
        else if (std.mem.eql(u8, body.value, "openai_compat"))
            ctx.config.llm_openai_compat != null
        else
            false;
        if (!configured) {
            return respondError(request, .bad_request, "bad_request", "must be \"anthropic\" or \"openai_compat\", and that provider must have credentials configured");
        }
    }

    dynamic_config.set(ctx.pool, key, body.value, account_id) catch |err| {
        log.err("admin-set-config: failed to set {s}: {t}", .{ key, err });
        return respondError(request, .internal_server_error, "internal", "failed to update config");
    };
    audit_log.record(ctx.pool, account_id, "config.set", key, null);

    return respondJson(ctx, request, .ok, .{});
}

/// `GET /api/v1/admin/audit-log?action=&cursor=&limit=` — thin wrapper
/// over `store/audit_log.zig`'s existing `list` (built in Phase 0, never
/// exposed over HTTP until now). `action` narrows to exactly one action
/// name at a time (matches `list`'s own single-filter shape) — the
/// frontend's "recently changed" widget calls this once per action
/// (`module.set`, `config.set`) and merges client-side; full multi-action
/// filtering/browsing is Phase 7's job, not this endpoint's.
fn handleAdminAuditLog(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    _ = (try requireAdmin(ctx, request)) orelse return;

    // `paginationParams`'s `after_id` field name assumes ascending-by-id
    // listings (`listChats`/`listIdentities`'s "id > cursor" shape) --
    // `audit_log.list` is newest-first ("id < cursor" for the next,
    // older, page) instead, but reusing the same parsed cursor value as
    // its `before_id` argument still produces the correct "next page =
    // strictly older rows" behavior: the SQL itself does `id < $1`
    // regardless of what this local variable is named.
    const page = paginationParams(target);
    const action_filter = queryParam(target, "action");

    const entries = audit_log.list(ctx.pool, ctx.allocator, if (page.after_id > 0) page.after_id else null, action_filter, page.limit) catch |err| {
        log.err("admin-audit-log: failed: {t}", .{err});
        return respondError(request, .internal_server_error, "internal", "failed to load audit log");
    };
    defer {
        for (entries) |e| {
            ctx.allocator.free(e.action);
            if (e.target) |t| ctx.allocator.free(t);
            if (e.detail) |d| ctx.allocator.free(d);
        }
        ctx.allocator.free(entries);
    }

    const next_cursor: ?i64 = if (entries.len == @as(usize, @intCast(page.limit))) entries[entries.len - 1].id else null;
    return respondJson(ctx, request, .ok, .{ .items = entries, .next_cursor = next_cursor });
}

// ---------------------------------------------------------------------------
// Groups (Phase 4) — chat-scoped, gated to owner/bot_admin or a *live*
// platform admin of that specific chat, per ARCHITECTURE.md §7 tier 3.
// ---------------------------------------------------------------------------

fn findConnectorForPlatform(connectors: []const iface.Connector, platform: iface.Platform) ?iface.Connector {
    for (connectors) |c| {
        if (c.platform() == platform) return c;
    }
    return null;
}

/// `true` if any of `identity_ids` is *currently* a live platform admin of
/// `chat` — checked fresh via the matching connector every call, never
/// cached, so a demotion on the platform itself takes effect here
/// immediately (same freshness guarantee `auth.checkGroupAdminAccess`
/// already gives the bot's own commands). An identity on a different
/// platform than `chat`, or with no matching connector currently active,
/// is silently skipped rather than erroring — it simply can't be a live
/// admin of a chat on a platform it doesn't belong to.
fn isLiveAdminOfChat(ctx: *const ServerContext, identity_ids: []const i64, chat: chats_store.ChatRef) bool {
    for (identity_ids) |identity_id| {
        const info = (identities.getWhoisInfo(ctx.pool, ctx.allocator, identity_id) catch null) orelse continue;
        defer {
            ctx.allocator.free(info.native_id);
            ctx.allocator.free(info.display_name);
            if (info.username) |u| ctx.allocator.free(u);
        }
        if (info.platform != chat.platform) continue;
        const connector = findConnectorForPlatform(ctx.connectors, chat.platform) orelse continue;
        const is_admin = connector.isGroupAdmin(ctx.allocator, chat.native_chat_id, info.native_id) catch false;
        if (is_admin) return true;
    }
    return false;
}

/// Every request handler below starts with this. `null` means a response
/// was already sent (`401`/`404`/`403`) — the caller just returns.
/// Ownership: on success, the caller owns `chat.native_chat_id` and must
/// free it.
fn requireChatAccess(ctx: *const ServerContext, request: *http.Server.Request, chat_id: i64) !?chats_store.ChatRef {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        try respondError(request, .unauthorized, "unauthorized", "not logged in");
        return null;
    };

    const chat = (chats_store.getById(ctx.pool, ctx.allocator, chat_id) catch |err| {
        log.err("chat-access: failed to load chat {d}: {t}", .{ chat_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to load chat");
        return null;
    }) orelse {
        try respondError(request, .not_found, "not_found", "no such chat");
        return null;
    };

    const roles = computeRoles(ctx, account_id) catch |err| {
        log.err("chat-access: failed to compute roles for account {d}: {t}", .{ account_id, err });
        ctx.allocator.free(chat.native_chat_id);
        try respondError(request, .internal_server_error, "internal", "failed to check access");
        return null;
    };
    if (roles.owner or roles.bot_admin) return chat;

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("chat-access: failed to list identities for account {d}: {t}", .{ account_id, err });
        ctx.allocator.free(chat.native_chat_id);
        try respondError(request, .internal_server_error, "internal", "failed to check access");
        return null;
    };
    defer ctx.allocator.free(identity_ids);

    if (isLiveAdminOfChat(ctx, identity_ids, chat)) return chat;

    ctx.allocator.free(chat.native_chat_id);
    try respondError(request, .forbidden, "forbidden", "not a live admin of this chat");
    return null;
}

/// `GET /api/v1/chats?mine=true` — every chat the caller can manage: all
/// of them for owner/bot_admin, or only the ones they're currently a live
/// platform admin of otherwise (candidate set narrowed to chats they're
/// at least a *member* of first, via `chat_members.listChatsForIdentity`
/// — cheaper than live-checking every chat in the system, and correct
/// since a live admin of a chat is necessarily also a member of it).
fn handleListMyChats(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        return respondError(request, .unauthorized, "unauthorized", "not logged in");
    };
    const roles = computeRoles(ctx, account_id) catch |err| {
        log.err("list-my-chats: failed to compute roles for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load chats");
    };

    const Item = struct { id: i64, platform: iface.Platform, native_chat_id: []const u8, title: ?[]const u8, is_group_admin: bool };
    var items: std.ArrayList(Item) = .empty;
    defer {
        for (items.items) |it| {
            ctx.allocator.free(it.native_chat_id);
            if (it.title) |t| ctx.allocator.free(t);
        }
        items.deinit(ctx.allocator);
    }

    if (roles.owner or roles.bot_admin) {
        const all = admin_directory.listChats(ctx.pool, ctx.allocator, 0, max_page_limit) catch |err| {
            log.err("list-my-chats: failed to list all chats: {t}", .{err});
            return respondError(request, .internal_server_error, "internal", "failed to load chats");
        };
        defer {
            for (all) |c| {
                ctx.allocator.free(c.native_chat_id);
                if (c.title) |t| ctx.allocator.free(t);
            }
            ctx.allocator.free(all);
        }
        for (all) |c| {
            try items.append(ctx.allocator, .{
                .id = c.id,
                .platform = c.platform,
                .native_chat_id = try ctx.allocator.dupe(u8, c.native_chat_id),
                .title = if (c.title) |t| try ctx.allocator.dupe(u8, t) else null,
                .is_group_admin = true,
            });
        }
    } else {
        const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
            log.err("list-my-chats: failed to list identities for account {d}: {t}", .{ account_id, err });
            return respondError(request, .internal_server_error, "internal", "failed to load chats");
        };
        defer ctx.allocator.free(identity_ids);

        for (identity_ids) |identity_id| {
            const info = (identities.getWhoisInfo(ctx.pool, ctx.allocator, identity_id) catch null) orelse continue;
            defer {
                ctx.allocator.free(info.native_id);
                ctx.allocator.free(info.display_name);
                if (info.username) |u| ctx.allocator.free(u);
            }

            const candidates = chat_members.listChatsForIdentity(ctx.pool, ctx.allocator, identity_id) catch continue;
            defer {
                for (candidates) |c| {
                    ctx.allocator.free(c.native_chat_id);
                    if (c.title) |t| ctx.allocator.free(t);
                }
                ctx.allocator.free(candidates);
            }
            for (candidates) |c| {
                const connector = findConnectorForPlatform(ctx.connectors, c.platform) orelse continue;
                const is_admin = connector.isGroupAdmin(ctx.allocator, c.native_chat_id, info.native_id) catch false;
                if (!is_admin) continue;
                try items.append(ctx.allocator, .{
                    .id = c.id,
                    .platform = c.platform,
                    .native_chat_id = try ctx.allocator.dupe(u8, c.native_chat_id),
                    .title = if (c.title) |t| try ctx.allocator.dupe(u8, t) else null,
                    .is_group_admin = true,
                });
            }
        }
    }

    return respondJson(ctx, request, .ok, .{ .items = items.items });
}

const ChatSettingsBody = struct {
    persona: ?[]const u8,
    magic_word: ?[]const u8,
    digest_enabled: bool,
    thinking_override: ?bool,
};

/// `GET /api/v1/chats/:id/settings`.
fn handleGetChatSettings(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    const chat = (try requireChatAccess(ctx, request, chat_id)) orelse return;
    defer ctx.allocator.free(chat.native_chat_id);

    const persona = chat_settings.getSystemPromptOverride(ctx.pool, ctx.allocator, chat_id);
    defer if (persona) |p| ctx.allocator.free(p);
    const magic_word = chat_settings.getMagicWord(ctx.pool, ctx.allocator, chat_id);
    defer if (magic_word) |m| ctx.allocator.free(m);

    return respondJson(ctx, request, .ok, ChatSettingsBody{
        .persona = persona,
        .magic_word = magic_word,
        .digest_enabled = chat_settings.getDigestEnabled(ctx.pool, chat_id),
        .thinking_override = chat_settings.getShowThinkingOverride(ctx.pool, chat_id),
    });
}

/// `PATCH /api/v1/chats/:id/settings` — body is the *entire* settings
/// object (`ChatSettingsBody`), not a sparse partial update: JSON has no
/// clean way to distinguish "field omitted, leave unchanged" from "field
/// explicitly null, clear it" without a wrapper type, and a settings-form
/// PATCH (the only client this has) naturally submits every field anyway.
/// `null` on `persona`/`magic_word`/`thinking_override` clears that
/// override, matching each store setter's own `null`-clears convention.
fn handleSetChatSettings(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    const chat = (try requireChatAccess(ctx, request, chat_id)) orelse return;
    defer ctx.allocator.free(chat.native_chat_id);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [8 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(8 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(ChatSettingsBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "expected the full chat settings object");
    };

    chat_settings.setSystemPromptOverride(ctx.pool, chat_id, body.persona) catch |err| {
        log.err("set-chat-settings: persona failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };
    chat_settings.setMagicWord(ctx.pool, chat_id, body.magic_word) catch |err| {
        log.err("set-chat-settings: magic_word failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };
    chat_settings.setDigestEnabled(ctx.pool, chat_id, body.digest_enabled) catch |err| {
        log.err("set-chat-settings: digest_enabled failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };
    chat_settings.setShowThinkingOverride(ctx.pool, chat_id, body.thinking_override) catch |err| {
        log.err("set-chat-settings: thinking_override failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };

    const a = resolveAuth(ctx, request);
    audit_log.record(ctx.pool, a.account_id, "chat_settings.set", id_str, null);

    return respondJson(ctx, request, .ok, .{});
}

/// `GET /api/v1/chats/:id/members`.
fn handleListChatMembers(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    const chat = (try requireChatAccess(ctx, request, chat_id)) orelse return;
    ctx.allocator.free(chat.native_chat_id);

    const members = chat_members.listMembers(ctx.pool, ctx.allocator, chat_id, max_page_limit) catch |err| {
        log.err("list-chat-members: failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load members");
    };
    defer {
        for (members) |m| {
            ctx.allocator.free(m.display_name);
            if (m.username) |u| ctx.allocator.free(u);
        }
        ctx.allocator.free(members);
    }

    return respondJson(ctx, request, .ok, .{ .items = members });
}

// ---------------------------------------------------------------------------
// Personal settings (Phase 4) — pure UI on top of store/user_settings.zig,
// already built in full during the reminders/timezone work.
// ---------------------------------------------------------------------------

/// `GET /api/v1/me/settings` — resolves against the caller's *first*
/// linked identity. Accounts can only ever have exactly one linked
/// identity today (no account-linking flow exists yet — see
/// `ARCHITECTURE.md` §3.3/§11), so this is a documented simplification,
/// not a real gap yet; whichever identity ends up "first" once linking
/// exists will need a real decision, not this arbitrary pick.
fn handleGetMySettings(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        return respondError(request, .unauthorized, "unauthorized", "not logged in");
    };

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("get-my-settings: failed to list identities for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load settings");
    };
    defer ctx.allocator.free(identity_ids);
    if (identity_ids.len == 0) {
        return respondError(request, .internal_server_error, "internal", "account has no linked identity");
    }
    const identity_id = identity_ids[0];

    return respondJson(ctx, request, .ok, .{
        .utc_offset_minutes = user_settings.getEffectiveOffsetMinutes(ctx.pool, ctx.allocator, identity_id),
        .date_format = @tagName(user_settings.getEffectiveDateFormat(ctx.pool, ctx.allocator, identity_id)),
        .time_format = @tagName(user_settings.getEffectiveTimeFormat(ctx.pool, ctx.allocator, identity_id)),
    });
}

const MySettingsBody = struct {
    utc_offset_minutes: ?i32,
    date_format: ?[]const u8,
    time_format: ?[]const u8,
};

/// `PATCH /api/v1/me/settings` — same "whole object, null clears" contract
/// as `handleSetChatSettings`.
fn handleSetMySettings(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        return respondError(request, .unauthorized, "unauthorized", "not logged in");
    };

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("set-my-settings: failed to list identities for account {d}: {t}", .{ account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };
    defer ctx.allocator.free(identity_ids);
    if (identity_ids.len == 0) {
        return respondError(request, .internal_server_error, "internal", "account has no linked identity");
    }
    const identity_id = identity_ids[0];

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [2 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(2 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(MySettingsBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "expected the full personal settings object");
    };

    const date_format: ?civil_time.DateFormat = if (body.date_format) |s|
        std.meta.stringToEnum(civil_time.DateFormat, s) orelse {
            return respondError(request, .bad_request, "bad_request", "invalid date_format");
        }
    else
        null;
    const time_format: ?civil_time.TimeFormat = if (body.time_format) |s|
        std.meta.stringToEnum(civil_time.TimeFormat, s) orelse {
            return respondError(request, .bad_request, "bad_request", "invalid time_format");
        }
    else
        null;

    user_settings.setUtcOffsetMinutes(ctx.pool, identity_id, body.utc_offset_minutes) catch |err| {
        log.err("set-my-settings: utc_offset failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };
    user_settings.setDateFormat(ctx.pool, identity_id, date_format) catch |err| {
        log.err("set-my-settings: date_format failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };
    user_settings.setTimeFormat(ctx.pool, identity_id, time_format) catch |err| {
        log.err("set-my-settings: time_format failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to update settings");
    };

    audit_log.record(ctx.pool, account_id, "me.settings.set", null, null);

    return respondJson(ctx, request, .ok, .{});
}

/// `user_agent` must have been captured by the caller *before* it read the
/// request body (if any) — `findHeader`/`iterateHeaders` requires the
/// request reader to still be in its post-head, pre-body state; calling it
/// from here (after callers like `handleDevLogin` already read the body)
/// crashed with `assertion failure` in `std.http.Server.Request.iterateHeaders`
/// (found 2026-07-28, in a local full-DB test run — not the pre-existing
/// http_util.zig flake, a real bug in this file, fixed by moving capture
/// earlier in every caller instead of doing it here).
fn issueSessionAndRespond(ctx: *const ServerContext, request: *http.Server.Request, account_id: i64, user_agent: ?[]const u8) !void {
    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const expires_at = now + 30 * 24 * 3600; // 30 days

    const session_id = web_sessions.create(ctx.pool, account_id, now, expires_at, user_agent, null) catch |err| {
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
    return .{ .account_id = session.account_id, .session_id = session_id };
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

/// First matching header value, or `null`. Used for `User-Agent` when
/// minting a session (see `issueSessionAndRespond`) — IP isn't captured
/// yet since the real client IP behind the eventual reverse proxy needs
/// `X-Forwarded-For` handling, deferred to `ROADMAP.md` Phase 7 rather
/// than recording the proxy's own address as if it were the client's.
fn findHeader(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
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
const test_support = @import("../store/test_support.zig");
const PgPool = @import("../store/pool.zig").PgPool;

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

/// Minimal `Connector` stub for `isLiveAdminOfChat`, same shape as
/// `auth.zig`'s own `StubConnector` (kept separate rather than shared —
/// this file has no existing dependency on `auth.zig`'s test internals,
/// and duplicating ~15 lines here is cheaper than exporting a test-only
/// type across files for one caller).
const StubConnector = struct {
    is_group_admin: bool = false,

    fn connector(self: *StubConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .isGroupAdmin = isGroupAdminFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram;
    }
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }
    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = ptr;
        _ = allocator;
        _ = chat_id;
        _ = text;
        _ = reply_to_message_id;
    }
    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        _ = allocator;
        _ = chat_id;
        _ = user_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        return self.is_group_admin;
    }
};

test "isLiveAdminOfChat: true only when the matching platform's connector confirms it, false for a different platform or no match" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    const telegram_identity = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const matrix_identity = try identities.getOrCreateMinimal(&pool, .matrix, "@alice:server", "alice", null, false, 1000);
    const chat_id = try chats_store.upsertChat(&pool, .telegram, "-100", "supergroup", "Test");
    const chat = (try chats_store.getById(&pool, a, chat_id)) orelse return error.TestExpectedValue;
    defer a.free(chat.native_chat_id);

    const config = testConfigForDefaults();
    var admin_stub = StubConnector{ .is_group_admin = true };
    var non_admin_stub = StubConnector{ .is_group_admin = false };

    // Confirmed admin, telegram identity, telegram connector present.
    {
        var connectors = [_]iface.Connector{admin_stub.connector()};
        const ctx = ServerContext{ .allocator = a, .io = testing.io, .pool = &pool, .config = &config, .connectors = &connectors };
        try testing.expect(isLiveAdminOfChat(&ctx, &.{telegram_identity}, chat));
    }
    // Connector says not an admin.
    {
        var connectors = [_]iface.Connector{non_admin_stub.connector()};
        const ctx = ServerContext{ .allocator = a, .io = testing.io, .pool = &pool, .config = &config, .connectors = &connectors };
        try testing.expect(!isLiveAdminOfChat(&ctx, &.{telegram_identity}, chat));
    }
    // Identity is on a different platform than the chat -- skipped, not
    // matched, even though the stub connector (matched by platform in the
    // slice below) would say "true" if consulted at all.
    {
        var connectors = [_]iface.Connector{admin_stub.connector()};
        const ctx = ServerContext{ .allocator = a, .io = testing.io, .pool = &pool, .config = &config, .connectors = &connectors };
        try testing.expect(!isLiveAdminOfChat(&ctx, &.{matrix_identity}, chat));
    }
    // No connector at all for the chat's platform.
    {
        const ctx = ServerContext{ .allocator = a, .io = testing.io, .pool = &pool, .config = &config, .connectors = &.{} };
        try testing.expect(!isLiveAdminOfChat(&ctx, &.{telegram_identity}, chat));
    }
}

test "maskSecret never returns more than the last 4 characters, and labels empty as not-set" {
    const a = testing.allocator;

    const empty = maskSecret(a, "");
    defer a.free(empty);
    try testing.expectEqualStrings("(not set)", empty);

    const short = maskSecret(a, "abcd");
    defer a.free(short);
    try testing.expectEqualStrings("••••", short);

    const long = maskSecret(a, "sk-verysecretlongkeyab12");
    defer a.free(long);
    try testing.expectEqualStrings("••••ab12", long);
    try testing.expect(std.mem.indexOf(u8, long, "verysecret") == null);
}

fn testConfigForDefaults() config_mod.Config {
    return .{
        .telegram_bot_token = "x",
        .owners = &.{},
        .postgres_dsn = "postgresql:///warden_test",
        .postgres_pool_size = 1,
        .postgres_acquire_timeout_seconds = 30,
        .postgres_statement_timeout_seconds = 30,
        .workers_per_platform = 2,
        .retention_messages = 500,
        .llm = .{ .anthropic = .{ .api_key = "x", .model = "x" } },
        .confirm_timeout_seconds = 60,
        .convert_timeout_seconds = 300,
        .menu_timeout_seconds = 180,
        .tmp_dir = "data/tmp",
        .digest_interval_seconds = 86_400,
        .system_prompt = null,
        .searxng_url = null,
        .whisper_url = null,
        .llm_owner_only = true,
        .llm_show_thinking = false,
        .llm_streaming = true,
        .llm_max_tokens_override = null,
        .llm_history_messages = 20,
        .skip_trivial_messages = true,
    };
}

test "defaultForKnownKey formats every known key's env-sourced default" {
    const a = testing.allocator;
    const config = testConfigForDefaults();

    const cases = [_]struct { key: []const u8, expected: []const u8 }{
        .{ .key = "WARDEN_RETENTION_MESSAGES", .expected = "500" },
        .{ .key = "WARDEN_DIGEST_INTERVAL_SECONDS", .expected = "86400" },
        .{ .key = "WARDEN_LLM_OWNER_ONLY", .expected = "true" },
        .{ .key = "WARDEN_LLM_SHOW_THINKING", .expected = "false" },
        .{ .key = "WARDEN_LLM_STREAMING", .expected = "true" },
        .{ .key = "WARDEN_LLM_MAX_TOKENS", .expected = "0" },
        .{ .key = "WARDEN_LLM_HISTORY_MESSAGES", .expected = "20" },
        .{ .key = "WARDEN_LLM_SKIP_TRIVIAL_MESSAGES", .expected = "true" },
        .{ .key = "WARDEN_LLM_PROVIDER", .expected = "anthropic" },
    };
    for (cases) |c| {
        const got = try defaultForKnownKey(a, &config, c.key);
        defer a.free(got);
        try testing.expectEqualStrings(c.expected, got);
    }
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
