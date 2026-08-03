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
const reminders = @import("../store/reminders.zig");
const alert_store = @import("../store/alerts.zig");
const feed_watches = @import("../store/feed_watches.zig");
const notes_store = @import("../store/notes.zig");
const expenses_store = @import("../store/expenses.zig");
const budgets_store = @import("../store/budgets.zig");
const subscriptions_store = @import("../store/subscriptions.zig");
const group_admin = @import("../features/group_admin.zig");
const redact_feature = @import("../features/redact.zig");
const convert_feature = @import("../features/convert.zig");
const multipart = @import("multipart.zig");
const audit_log = @import("../store/audit_log.zig");
/// The bot's own permission-ladder module (owner check) -- aliased since
/// `auth` above already names this file's own session-token module
/// (`api/auth.zig`).
const perm_auth = @import("../auth.zig");
const oauth_providers = @import("../store/oauth_providers.zig");
const oidc = @import("oidc.zig");
const bot_view = @import("bot_view.zig");
const rate_limit = @import("rate_limit.zig");
const http_util = @import("../http_util.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const log = @import("../log.zig").scoped("api");

const me_sessions_prefix = "/api/v1/me/sessions/";
const oidc_auth_prefix = "/api/v1/auth/oidc/";
const admin_chats_prefix = "/api/v1/admin/chats/";
const admin_identities_prefix = "/api/v1/admin/identities/";
const admin_modules_prefix = "/api/v1/admin/modules/";
const admin_config_prefix = "/api/v1/admin/config/";
const chats_prefix = "/api/v1/chats/";
const chat_settings_suffix = "/settings";
const chat_members_suffix = "/members";
const chat_actions_infix = "/actions/";
const reminders_prefix = "/api/v1/reminders/";
const alerts_prefix = "/api/v1/alerts/";
const watches_prefix = "/api/v1/watches/";
const notes_prefix = "/api/v1/notes/";
const expenses_prefix = "/api/v1/expenses/";
const budgets_prefix = "/api/v1/budgets/";
const subscriptions_prefix = "/api/v1/subscriptions/";

/// Reminder-message length cap -- mirrors `main.zig`'s own
/// `max_reminder_message_len` for `/remind` (kept as a separate constant
/// since `main.zig` is the one that imports this file, not the other way
/// around -- importing it back here would be circular).
const max_reminder_message_len = 500;

/// Note-text length cap -- mirrors `main.zig`'s own `max_note_text_len`
/// for `/note add`, same "kept separate to avoid a circular import" reason
/// as `max_reminder_message_len` above.
const max_note_text_len = 1000;

/// Currency every finance row defaults to when a request omits one --
/// mirrors `main.zig`'s own `default_currency` for `/expense`/`/budget`/
/// `/subscription`, same "kept separate to avoid a circular import" reason
/// as the two caps above. Also matches the `DEFAULT 'USD'` in migrations
/// `0029`/`0030`/`0031`.
const default_currency = "USD";

/// API-level caps on the finance free-text fields. The `expenses`/
/// `budgets`/`subscriptions` tables all declare these columns as bare
/// `TEXT` with no length constraint (the bot's own command parsers bound
/// them implicitly, by taking a single line of chat input), so without
/// these an authenticated `POST` could store an arbitrarily large blob.
const max_expense_category_len = 64;
const max_expense_description_len = 500;
const max_subscription_name_len = 128;
const max_currency_len = 8;

/// A hard ceiling on any single stored amount, in cents -- ~$1 trillion,
/// far above any plausible real entry while still leaving `i64` arithmetic
/// (`subscriptions.monthlyEquivalentCents` multiplies by 30, and
/// `expenses.totalsByCategory` sums across rows) nowhere near overflow.
/// The DB's own `CHECK (amount_cents > 0)` covers the lower bound; this is
/// the upper one it has no opinion about.
const max_amount_cents: i64 = 100_000_000_000_000;

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
    if (method == .GET and std.mem.startsWith(u8, path, oidc_auth_prefix)) {
        const rest = path[oidc_auth_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse {
            return respondError(request, .not_found, "not_found", "no such endpoint");
        };
        const provider_id_str = rest[0..slash];
        const action = rest[slash + 1 ..];
        if (std.mem.eql(u8, action, "start")) return handleOidcStart(ctx, request, provider_id_str);
        if (std.mem.eql(u8, action, "callback")) return handleOidcCallback(ctx, request, provider_id_str, target);
        return respondError(request, .not_found, "not_found", "no such endpoint");
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
        } else if (std.mem.indexOf(u8, rest, chat_actions_infix)) |idx| {
            if (method != .POST) {
                return respondError(request, .not_found, "not_found", "no such endpoint");
            }
            const id_str = rest[0..idx];
            const action = rest[idx + chat_actions_infix.len ..];
            if (std.mem.eql(u8, action, "kick")) return handleChatActionKick(ctx, request, id_str);
            if (std.mem.eql(u8, action, "ban")) return handleChatActionBan(ctx, request, id_str);
            if (std.mem.eql(u8, action, "mute")) return handleChatActionMute(ctx, request, id_str);
            if (std.mem.eql(u8, action, "unmute")) return handleChatActionUnmute(ctx, request, id_str);
            if (std.mem.eql(u8, action, "promote")) return handleChatActionPromote(ctx, request, id_str);
            if (std.mem.eql(u8, action, "demote")) return handleChatActionDemote(ctx, request, id_str);
            if (std.mem.eql(u8, action, "pin")) return handleChatActionPin(ctx, request, id_str);
            if (std.mem.eql(u8, action, "unpin")) return handleChatActionUnpin(ctx, request, id_str);
            if (std.mem.eql(u8, action, "redact")) return handleChatActionRedact(ctx, request, id_str);
        }
    }
    if (std.mem.eql(u8, path, "/api/v1/me/settings")) {
        if (method == .GET) return handleGetMySettings(ctx, request);
        if (method == .PATCH) return handleSetMySettings(ctx, request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/reminders")) {
        return handleListReminders(ctx, request, target);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/reminders")) {
        return handleCreateReminder(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, reminders_prefix)) {
        return handleCancelReminder(ctx, request, path[reminders_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/alerts")) {
        return handleListAlerts(ctx, request, target);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/alerts")) {
        return handleCreateAlert(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, alerts_prefix)) {
        return handleCancelAlert(ctx, request, path[alerts_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/watches")) {
        return handleListWatches(ctx, request, target);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/watches")) {
        return handleCreateWatch(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, watches_prefix)) {
        return handleDeleteWatch(ctx, request, path[watches_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/notes")) {
        return handleListNotes(ctx, request, target);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/notes")) {
        return handleCreateNote(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, notes_prefix)) {
        return handleDeleteNote(ctx, request, path[notes_prefix.len..]);
    }
    // Finance (ROADMAP.md Phase 17). `/expenses/summary` is matched before
    // the `expenses_prefix` catch-all below only incidentally -- that one
    // is `DELETE`-only, so the two can't collide regardless of order.
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/expenses")) {
        return handleListExpenses(ctx, request, target);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/expenses/summary")) {
        return handleExpenseSummary(ctx, request, target);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/expenses")) {
        return handleCreateExpense(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, expenses_prefix)) {
        return handleDeleteExpense(ctx, request, path[expenses_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/budgets")) {
        return handleListBudgets(ctx, request, target);
    }
    if (method == .PUT and std.mem.eql(u8, path, "/api/v1/budgets")) {
        return handleSetBudget(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, budgets_prefix)) {
        return handleDeleteBudget(ctx, request, path[budgets_prefix.len..]);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/subscriptions")) {
        return handleListSubscriptions(ctx, request, target);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/subscriptions")) {
        return handleCreateSubscription(ctx, request);
    }
    if (method == .DELETE and std.mem.startsWith(u8, path, subscriptions_prefix)) {
        return handleDeleteSubscription(ctx, request, path[subscriptions_prefix.len..]);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/convert")) {
        return handleConvert(ctx, request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/bot-view/ws")) {
        return handleBotViewWs(ctx, request, target);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/bot-view/send")) {
        return handleBotViewSend(ctx, request);
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
/// The Telegram Login Widget (HMAC-signed, `telegram_login.zig`) is gone
/// as of 2026-07-28 -- Telegram itself now describes it as legacy/
/// archived in favor of the real OIDC provider `oidc.zig` implements (see
/// https://core.telegram.org/bots/telegram-login), and once that was
/// live and confirmed working there was no reason to keep a second,
/// weaker login path around. `google` stays for API-shape compatibility
/// with what warden-ui's `Providers` type already expects.
fn handleGetProviders(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const OidcProvider = struct { id: []const u8, name: []const u8 };
    const Response = struct {
        google: ?struct {} = null,
        oidc: []const OidcProvider = &.{},
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const providers = oauth_providers.listEnabledPublic(ctx.pool, arena) catch |err| {
        log.err("get-providers: failed to list oauth providers: {t}", .{err});
        return respondError(request, .internal_server_error, "internal", "failed to load providers");
    };
    const oidc_items = try arena.alloc(OidcProvider, providers.len);
    for (providers, 0..) |p, i| {
        oidc_items[i] = .{ .id = try std.fmt.allocPrint(arena, "{d}", .{p.id}), .name = p.name };
    }

    return respondJson(ctx, request, .ok, Response{ .oidc = oidc_items });
}

/// Resolves (or creates) the warden account for a verified external login.
/// Only the OIDC callback below calls this today (the older Telegram
/// Login Widget that used to share it was removed 2026-07-28 in favor of
/// OIDC), but this stays its own function rather than getting inlined --
/// "how a verified external identity becomes a warden account" is exactly
/// the kind of thing a future second login mechanism would need again
/// unchanged. `null` means a response was already sent.
fn resolveOrCreateAccountForLogin(
    ctx: *const ServerContext,
    request: *http.Server.Request,
    platform: iface.Platform,
    native_id: []const u8,
    display_name: []const u8,
    username: ?[]const u8,
    avatar_url: ?[]const u8,
    now: i64,
) !?i64 {
    const identity_id = identities.getOrCreateMinimal(ctx.pool, platform, native_id, display_name, username, false, now) catch |err| {
        log.err("login: failed to resolve identity for {t} id {s}: {t}", .{ platform, native_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to resolve identity");
        return null;
    };

    if (accounts.findByIdentity(ctx.pool, ctx.allocator, identity_id) catch null) |existing| {
        ctx.allocator.free(existing.display_name);
        if (existing.avatar_url) |u| ctx.allocator.free(u);
        return existing.id;
    }
    return accounts.create(ctx.pool, identity_id, display_name, avatar_url) catch |err| {
        log.err("login: failed to create account for identity {d}: {t}", .{ identity_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to create account");
        return null;
    };
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
    if (!try checkRateLimit(ctx, request, ctx.auth_limiter, "dev-login")) return;

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
    if (std.mem.eql(u8, key, "WARDEN_BRIEFING_INTERVAL_SECONDS")) return std.fmt.allocPrint(a, "{d}", .{config.briefing_interval_seconds});
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

/// `true` if `account_id` is the owner, or is currently a live admin of
/// `chat` — deliberately narrower than `requireChatAccess`'s "owner or
/// bot_admin or live admin" ladder (see its doc comment): `bot_admin`
/// isn't accepted here. Factored out for Bot View's send/ws gates (Phase
/// 9's "Admin notices" — see `handleBotViewSend`), which need the same
/// live-admin-of-a-specific-chat check `requireChatAccess` already does,
/// but with `bot_admin` staying excluded per Bot View's own 2026-07-28
/// scoping decision.
fn isOwnerOrLiveAdminOfChatAccount(ctx: *const ServerContext, account_id: i64, roles: Roles, chat: chats_store.ChatRef) bool {
    if (roles.owner) return true;
    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("bot-view-access: failed to list identities for account {d}: {t}", .{ account_id, err });
        return false;
    };
    defer ctx.allocator.free(identity_ids);
    return isLiveAdminOfChat(ctx, identity_ids, chat);
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
    if (roles.bot_admin or isOwnerOrLiveAdminOfChatAccount(ctx, account_id, roles, chat)) return chat;

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
// Group Administration actions (Phase 5b) — kick/ban/mute/unmute/pin/unpin/
// promote/demote/redact, each routed through the *exact* existing
// `auth.checkGroupAdminAccess`/`isOwnerOrSudoBotAdmin` functions the slash
// commands and `/menu` already use — this endpoint is simply a third
// independent entry point to the same actions (see API.md). Two deliberate
// adaptations for the web, both judgment calls made here rather than
// spelled out in API.md's original sketch:
//   - `sudo_active` (normally "the sender is a bot admin AND prefixed their
//     command with /sudo") maps to plain `roles.bot_admin` here — there's no
//     text-prefix ritual in a web form, so being logged in as a bot admin
//     and clicking the button *is* the deliberate elevation. Still sends the
//     same "granted superuser permissions" message into the real chat, so
//     the elevation is never silent, matching the original design intent.
//   - `allow_token_fallback` is always `false` — API.md's own description of
//     this ladder lists exactly three tiers (platform admin / bot admin /
//     owner), no token-spend tier, and spending a per-chat token is a
//     conversational-command mechanic that doesn't map cleanly onto a web
//     form (the "not enough tokens" reply would land in the real chat as an
//     unexplained bot message, attributed to nothing the chat itself saw).
// ---------------------------------------------------------------------------

const ChatActionCtx = struct {
    ra: RequesterAuth,
    chat: chats_store.ChatRef,
    connector: iface.Connector,
    actor_msg: iface.Message,
    actor_identity_id: i64,
};

/// Every action handler below starts with this: logged in, the
/// `group_admin` module enabled (same gate the slash commands and `/menu`
/// both already apply), the chat exists and has an active connector, and a
/// synthetic `iface.Message` standing in for "a message from the caller in
/// this chat" -- built from the caller's own first linked identity (native
/// id/platform; `.identity` populated too, for the sudo-grant message's
/// display name). Everything here is allocated from `arena`, including
/// `chat.native_chat_id` -- no manual frees needed. `null` means a response
/// was already sent.
fn beginChatAction(ctx: *const ServerContext, request: *http.Server.Request, arena: std.mem.Allocator, chat_id: i64) !?ChatActionCtx {
    const ra = (try requireLoggedIn(ctx, request)) orelse return null;

    if (!feature_flags.isEnabled(ctx.pool, "group_admin")) {
        try respondError(request, .forbidden, "forbidden", "the group administration module is disabled");
        return null;
    }

    const chat = (chats_store.getById(ctx.pool, arena, chat_id) catch |err| {
        log.err("chat-action: failed to load chat {d}: {t}", .{ chat_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to load chat");
        return null;
    }) orelse {
        try respondError(request, .not_found, "not_found", "no such chat");
        return null;
    };

    const connector = findConnectorForPlatform(ctx.connectors, chat.platform) orelse {
        try respondError(request, .internal_server_error, "internal", "no active connector for this chat's platform");
        return null;
    };

    const identity_ids = accounts.listIdentityIds(ctx.pool, arena, ra.account_id) catch |err| {
        log.err("chat-action: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to resolve caller identity");
        return null;
    };
    if (identity_ids.len == 0) {
        try respondError(request, .internal_server_error, "internal", "account has no linked identity");
        return null;
    }
    const actor_info = (identities.getWhoisInfo(ctx.pool, arena, identity_ids[0]) catch |err| {
        log.err("chat-action: failed to load whois for identity {d}: {t}", .{ identity_ids[0], err });
        try respondError(request, .internal_server_error, "internal", "failed to resolve caller identity");
        return null;
    }) orelse {
        try respondError(request, .internal_server_error, "internal", "failed to resolve caller identity");
        return null;
    };

    const actor_msg = iface.Message{
        .chat_id = chat.native_chat_id,
        .user_id = actor_info.native_id,
        .username = actor_info.username,
        .identity = .{
            .platform = actor_info.platform,
            .native_id = actor_info.native_id,
            .display_name = actor_info.display_name,
            .username = actor_info.username,
            .is_bot = actor_info.is_bot,
            .first_seen = 0,
            .last_seen = 0,
        },
    };

    return .{ .ra = ra, .chat = chat, .connector = connector, .actor_msg = actor_msg, .actor_identity_id = identity_ids[0] };
}

fn resolveTargetNativeId(ctx: *const ServerContext, request: *http.Server.Request, arena: std.mem.Allocator, target_identity_id: i64) !?[]const u8 {
    const info = (identities.getWhoisInfo(ctx.pool, arena, target_identity_id) catch |err| {
        log.err("chat-action: failed to load target identity {d}: {t}", .{ target_identity_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to resolve target");
        return null;
    }) orelse {
        try respondError(request, .not_found, "not_found", "no such identity");
        return null;
    };
    return info.native_id;
}

fn readJsonBodyLeaky(request: *http.Server.Request, arena: std.mem.Allocator, comptime T: type, max_len: usize) !?T {
    var buf: [4 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(max_len)) catch {
        try respondError(request, .bad_request, "bad_request", "failed to read body");
        return null;
    };
    return std.json.parseFromSliceLeaky(T, arena, raw, .{}) catch {
        try respondError(request, .bad_request, "bad_request", "invalid request body");
        return null;
    };
}

const ModTargetBody = struct { identity_id: i64 };

/// Mirrors `group_admin.zig`'s own private `default_mute_seconds` -- kept as
/// a separate constant since `main.zig` is what imports this file, not the
/// other way around (see `max_reminder_message_len`'s doc comment for the
/// same reasoning).
const default_mute_seconds: i64 = 3600;
const MuteBody = struct { identity_id: i64, duration_seconds: ?i64 = null };
const PinBody = struct { message_id: []const u8 };
const RedactBody = struct {
    mode: []const u8,
    n: ?i64 = null,
    identity_id: ?i64 = null,
    substring: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
};

fn handleChatActionKick(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, ModTargetBody, 1024)) orelse return;

    if (!perm_auth.checkGroupAdminAccess(ac.connector, arena, ctx.config, ctx.pool, chat_id, ac.actor_identity_id, ac.actor_msg, ac.ra.roles.bot_admin, false, "kick")) {
        return respondError(request, .forbidden, "forbidden", "not authorized to kick in this chat");
    }
    const target_native_id = (try resolveTargetNativeId(ctx, request, arena, body.identity_id)) orelse return;

    ac.connector.kickUser(arena, ac.chat.native_chat_id, target_native_id) catch |err| {
        log.err("chat-action-kick: failed for chat {d} target {d}: {t}", .{ chat_id, body.identity_id, err });
        return respondError(request, .internal_server_error, "internal", "kick failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.kick", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

fn handleChatActionBan(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, ModTargetBody, 1024)) orelse return;

    if (!perm_auth.checkGroupAdminAccess(ac.connector, arena, ctx.config, ctx.pool, chat_id, ac.actor_identity_id, ac.actor_msg, ac.ra.roles.bot_admin, false, "ban")) {
        return respondError(request, .forbidden, "forbidden", "not authorized to ban in this chat");
    }
    const target_native_id = (try resolveTargetNativeId(ctx, request, arena, body.identity_id)) orelse return;

    ac.connector.banUser(arena, ac.chat.native_chat_id, target_native_id) catch |err| {
        log.err("chat-action-ban: failed for chat {d} target {d}: {t}", .{ chat_id, body.identity_id, err });
        return respondError(request, .internal_server_error, "internal", "ban failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.ban", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

fn handleChatActionMute(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, MuteBody, 1024)) orelse return;

    if (!perm_auth.checkGroupAdminAccess(ac.connector, arena, ctx.config, ctx.pool, chat_id, ac.actor_identity_id, ac.actor_msg, ac.ra.roles.bot_admin, false, "mute")) {
        return respondError(request, .forbidden, "forbidden", "not authorized to mute in this chat");
    }
    const target_native_id = (try resolveTargetNativeId(ctx, request, arena, body.identity_id)) orelse return;

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const duration = body.duration_seconds orelse default_mute_seconds;
    ac.connector.muteUser(arena, ac.chat.native_chat_id, target_native_id, now + duration) catch |err| {
        log.err("chat-action-mute: failed for chat {d} target {d}: {t}", .{ chat_id, body.identity_id, err });
        return respondError(request, .internal_server_error, "internal", "mute failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.mute", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

fn handleChatActionUnmute(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, ModTargetBody, 1024)) orelse return;

    if (!perm_auth.checkGroupAdminAccess(ac.connector, arena, ctx.config, ctx.pool, chat_id, ac.actor_identity_id, ac.actor_msg, ac.ra.roles.bot_admin, false, "unmute")) {
        return respondError(request, .forbidden, "forbidden", "not authorized to unmute in this chat");
    }
    const target_native_id = (try resolveTargetNativeId(ctx, request, arena, body.identity_id)) orelse return;

    ac.connector.unmuteUser(arena, ac.chat.native_chat_id, target_native_id) catch |err| {
        log.err("chat-action-unmute: failed for chat {d} target {d}: {t}", .{ chat_id, body.identity_id, err });
        return respondError(request, .internal_server_error, "internal", "unmute failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.unmute", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

/// Owner-only, not `checkGroupAdminAccess` -- mirrors `group_admin.promote`'s
/// doc comment exactly: granting real platform admin/moderator standing is
/// more consequential than mute/kick/pin, and deliberately isn't extended to
/// bot admins either.
fn handleChatActionPromote(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, ModTargetBody, 1024)) orelse return;

    if (!ac.ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only the owner can promote");
    }
    const target_native_id = (try resolveTargetNativeId(ctx, request, arena, body.identity_id)) orelse return;

    ac.connector.promoteUser(arena, ac.chat.native_chat_id, target_native_id) catch |err| {
        log.err("chat-action-promote: failed for chat {d} target {d}: {t}", .{ chat_id, body.identity_id, err });
        return respondError(request, .internal_server_error, "internal", "promote failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.promote", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

/// Owner-only -- see `handleChatActionPromote`'s doc comment.
fn handleChatActionDemote(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, ModTargetBody, 1024)) orelse return;

    if (!ac.ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only the owner can demote");
    }
    const target_native_id = (try resolveTargetNativeId(ctx, request, arena, body.identity_id)) orelse return;

    ac.connector.demoteUser(arena, ac.chat.native_chat_id, target_native_id) catch |err| {
        log.err("chat-action-demote: failed for chat {d} target {d}: {t}", .{ chat_id, body.identity_id, err });
        return respondError(request, .internal_server_error, "internal", "demote failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.demote", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

/// `{message_id}` -- a native platform message id, typed/pasted in by the
/// caller. No message-browser UI backs this yet (the only place a chat's
/// recent messages are exposed today, `GET /api/v1/admin/chats/:id`, is
/// owner/bot-admin-only, while pin itself is open to any live platform
/// admin of the chat too -- building that picker is follow-up work, not a
/// blocker for the endpoint existing).
fn handleChatActionPin(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, PinBody, 1024)) orelse return;

    if (!perm_auth.checkGroupAdminAccess(ac.connector, arena, ctx.config, ctx.pool, chat_id, ac.actor_identity_id, ac.actor_msg, ac.ra.roles.bot_admin, false, "pin")) {
        return respondError(request, .forbidden, "forbidden", "not authorized to pin in this chat");
    }

    ac.connector.pinMessage(arena, ac.chat.native_chat_id, body.message_id) catch |err| {
        log.err("chat-action-pin: failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "pin failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.pin", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

/// No body needed -- unpins whatever's currently pinned, same as `/unpin`.
fn handleChatActionUnpin(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;

    if (!perm_auth.checkGroupAdminAccess(ac.connector, arena, ctx.config, ctx.pool, chat_id, ac.actor_identity_id, ac.actor_msg, ac.ra.roles.bot_admin, false, "unpin")) {
        return respondError(request, .forbidden, "forbidden", "not authorized to unpin in this chat");
    }

    ac.connector.unpinMessage(arena, ac.chat.native_chat_id, null) catch |err| {
        log.err("chat-action-unpin: failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "unpin failed");
    };

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.unpin", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

/// `{mode: "lastn"|"user"|"text"|"regex", ...}` -- see API.md. `regex` mode
/// keeps its own stricter gate (`isOwnerOrSudoBotAdmin` -- excludes even a
/// live platform admin), unchanged from `/redact regex`'s behavior; the
/// other three modes use the same ladder as every other action here.
fn handleChatActionRedact(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const chat_id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat id");
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ac = (try beginChatAction(ctx, request, arena, chat_id)) orelse return;
    const body = (try readJsonBodyLeaky(request, arena, RedactBody, 4 * 1024)) orelse return;

    if (std.mem.eql(u8, body.mode, "regex")) {
        if (!perm_auth.isOwnerOrSudoBotAdmin(ctx.config, ac.chat.platform, ac.actor_msg.user_id, ac.ra.roles.bot_admin)) {
            return respondError(request, .forbidden, "forbidden", "regex redact requires the owner or a bot admin");
        }
        const pattern = body.pattern orelse {
            return respondError(request, .bad_request, "bad_request", "pattern is required for regex mode");
        };
        redact_feature.redactRegex(ac.connector, arena, ctx.pool, chat_id, ac.actor_msg, pattern);
    } else {
        if (!perm_auth.checkGroupAdminAccess(ac.connector, arena, ctx.config, ctx.pool, chat_id, ac.actor_identity_id, ac.actor_msg, ac.ra.roles.bot_admin, false, "redact")) {
            return respondError(request, .forbidden, "forbidden", "not authorized to redact in this chat");
        }
        if (std.mem.eql(u8, body.mode, "text")) {
            const substring = body.substring orelse {
                return respondError(request, .bad_request, "bad_request", "substring is required for text mode");
            };
            redact_feature.redactText(ac.connector, arena, ctx.pool, chat_id, ac.actor_msg, substring);
        } else if (std.mem.eql(u8, body.mode, "user")) {
            const target_identity_id = body.identity_id orelse {
                return respondError(request, .bad_request, "bad_request", "identity_id is required for user mode");
            };
            redact_feature.redactUserLastN(ac.connector, arena, ctx.pool, chat_id, ac.actor_msg, target_identity_id, body.n orelse 0);
        } else if (std.mem.eql(u8, body.mode, "lastn")) {
            redact_feature.redactLastN(ac.connector, arena, ctx.pool, chat_id, ac.actor_msg, body.n orelse 0);
        } else {
            return respondError(request, .bad_request, "bad_request", "mode must be lastn, user, text, or regex");
        }
    }

    audit_log.record(ctx.pool, ac.ra.account_id, "chat.action.redact", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

// ---------------------------------------------------------------------------
// Convert (Phase 5c) — not chat-scoped at all, unlike everything above:
// `features/convert.zig`'s `convert()` is a stateless file-in/file-out
// utility with no chat/persistence side effects, same as `tools/
// convert_file.zig`'s LLM-tool wrapper around it. Just needs a login and
// the `convert` module enabled, matching `/convert`'s own gate.
// ---------------------------------------------------------------------------

/// Matches `features/convert.zig`'s own extension tables — used only to
/// pick a `Content-Type` for the response; `result.file_name` is always
/// `"converted" + one of those known extensions` (see `convert()`'s doc
/// comment), never attacker-influenced, since any target format that
/// doesn't match a known extension is rejected by `convert()` itself
/// before a file_name is ever constructed.
fn mimeTypeForExt(ext: []const u8) []const u8 {
    const Entry = struct { ext: []const u8, mime: []const u8 };
    const table = [_]Entry{
        .{ .ext = ".txt", .mime = "text/plain" },
        .{ .ext = ".md", .mime = "text/markdown" },
        .{ .ext = ".html", .mime = "text/html" },
        .{ .ext = ".htm", .mime = "text/html" },
        .{ .ext = ".docx", .mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
        .{ .ext = ".odt", .mime = "application/vnd.oasis.opendocument.text" },
        .{ .ext = ".rtf", .mime = "application/rtf" },
        .{ .ext = ".pdf", .mime = "application/pdf" },
        .{ .ext = ".jpg", .mime = "image/jpeg" },
        .{ .ext = ".jpeg", .mime = "image/jpeg" },
        .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".webp", .mime = "image/webp" },
        .{ .ext = ".gif", .mime = "image/gif" },
        .{ .ext = ".bmp", .mime = "image/bmp" },
        .{ .ext = ".tiff", .mime = "image/tiff" },
        .{ .ext = ".mp3", .mime = "audio/mpeg" },
        .{ .ext = ".wav", .mime = "audio/wav" },
        .{ .ext = ".ogg", .mime = "audio/ogg" },
        .{ .ext = ".opus", .mime = "audio/opus" },
        .{ .ext = ".flac", .mime = "audio/flac" },
        .{ .ext = ".aac", .mime = "audio/aac" },
        .{ .ext = ".m4a", .mime = "audio/mp4" },
        .{ .ext = ".mp4", .mime = "video/mp4" },
        .{ .ext = ".webm", .mime = "video/webm" },
        .{ .ext = ".mov", .mime = "video/quicktime" },
        .{ .ext = ".mkv", .mime = "video/x-matroska" },
        .{ .ext = ".avi", .mime = "video/x-msvideo" },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(e.ext, ext)) return e.mime;
    }
    return "application/octet-stream";
}

fn respondFile(request: *http.Server.Request, status: http.Status, content_type: []const u8, filename: []const u8, bytes: []const u8) !void {
    var buf: [512]u8 = undefined;
    const disposition = std.fmt.bufPrint(&buf, "attachment; filename=\"{s}\"", .{filename}) catch "attachment";
    try request.respond(bytes, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "content-disposition", .value = disposition },
        },
    });
}

/// Max total request body (multipart headers/boundary overhead plus the
/// file itself) -- matches `convert()`'s own 50MB cap on reading back the
/// converted output, plus a little headroom for multipart framing.
const max_convert_upload_bytes: usize = 51 * 1024 * 1024;

/// `POST /api/v1/convert` -- multipart with a `file` part (needs a
/// `filename`) and a `target_format` text field; synchronous response is
/// the converted file's bytes, same "one-shot, no interactive flow" shape
/// as `/convert <format>` used as a caption (see API.md).
fn handleConvert(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "convert")) {
        return respondError(request, .forbidden, "forbidden", "the convert module is disabled");
    }

    const content_type = findHeader(request, "content-type") orelse {
        return respondError(request, .bad_request, "bad_request", "missing content-type header");
    };
    const boundary = multipart.boundaryFromContentType(content_type) orelse {
        return respondError(request, .bad_request, "bad_request", "expected a multipart/form-data body");
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `boundary` above borrows straight from `request.head_buffer` (via
    // `findHeader`/`iterateHeaders`). `readerExpectNone` reuses that same
    // connection-level read buffer for the body once it needs more bytes
    // than `receiveHead` already had buffered — for any upload past a
    // couple hundred bytes, that clobbers `boundary` out from under us
    // *before* `multipart.parse` below ever reads it (confirmed by hand:
    // a >~450-byte upload turned a real `----formdata-undici-...` boundary
    // into garbage like `85--formdata-undici-...`, mid-string, which then
    // never matches anything in the body and silently yields zero parts —
    // surfacing as "missing a \"file\" part" for every upload past that
    // size). Copying it into the arena *before* touching the body reader
    // is the fix.
    const boundary_owned = try arena.dupe(u8, boundary);

    var buf: [16 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(max_convert_upload_bytes)) catch {
        return respondError(request, .payload_too_large, "payload_too_large", "upload too large (max 50MB)");
    };

    const parts = multipart.parse(arena, raw, boundary_owned) catch {
        return respondError(request, .bad_request, "bad_request", "malformed multipart body");
    };

    const file_part = multipart.find(parts, "file") orelse {
        return respondError(request, .bad_request, "bad_request", "missing a \"file\" part");
    };
    const filename = file_part.filename orelse {
        return respondError(request, .bad_request, "bad_request", "the \"file\" part needs a filename");
    };
    const format_part = multipart.find(parts, "target_format") orelse {
        return respondError(request, .bad_request, "bad_request", "missing a \"target_format\" field");
    };

    const source_ext = convert_feature.extensionOf(filename);
    if (source_ext.len == 0 or source_ext.len > 10 or std.mem.indexOfAny(u8, source_ext, "/\\") != null) {
        return respondError(request, .bad_request, "bad_request", "the uploaded file needs a plain extension");
    }

    Io.Dir.cwd().createDirPath(ctx.io, ctx.config.tmp_dir) catch |err| {
        log.err("convert: failed to create tmp_dir {s}: {t}", .{ ctx.config.tmp_dir, err });
        return respondError(request, .internal_server_error, "internal", "failed to stage upload");
    };
    const now_ns = Io.Timestamp.now(ctx.io, .real).toNanoseconds();
    const upload_path = try std.fmt.allocPrint(arena, "{s}/api_upload_{d}{s}", .{ ctx.config.tmp_dir, now_ns, source_ext });

    {
        var file = Io.Dir.cwd().createFile(ctx.io, upload_path, .{}) catch |err| {
            log.err("convert: failed to create upload temp file {s}: {t}", .{ upload_path, err });
            return respondError(request, .internal_server_error, "internal", "failed to stage upload");
        };
        defer file.close(ctx.io);
        var w = file.writer(ctx.io, &.{});
        w.interface.writeAll(file_part.content) catch |err| {
            log.err("convert: failed to write upload temp file {s}: {t}", .{ upload_path, err });
            return respondError(request, .internal_server_error, "internal", "failed to stage upload");
        };
        w.interface.flush() catch {};
    }
    defer Io.Dir.cwd().deleteFile(ctx.io, upload_path) catch {};

    const result = convert_feature.convert(arena, ctx.io, ctx.config.tmp_dir, upload_path, format_part.content) catch |err| {
        return switch (err) {
            error.UnsupportedTargetFormat => respondError(request, .bad_request, "bad_request", "that target format isn't supported"),
            error.UnsupportedConversion => respondError(request, .bad_request, "bad_request", "can't convert between those two formats"),
            error.ConversionFailed => respondError(request, .internal_server_error, "internal", "conversion failed -- the file may be corrupt or unsupported"),
            else => err,
        };
    };

    audit_log.record(ctx.pool, ra.account_id, "convert", filename, null);

    return respondFile(request, .ok, mimeTypeForExt(convert_feature.extensionOf(result.file_name)), result.file_name, result.bytes);
}

// ---------------------------------------------------------------------------
// "Bot View" (Phase 6) -- lets the owner watch a chat's live incoming
// messages and reply in the bot's own voice. Originally owner-only, not
// extended to bot_admins -- see ARCHITECTURE.md §7/§8, decided 2026-07-28
// (Armin) given how sensitive impersonating the bot's own voice is.
//
// Widened in Phase 9 ("Admin notices", see ROADMAP.md) to also admit a
// chat's own live platform admins, scoped to only that chat -- `bot_admin`
// stays excluded, same as before, since the 2026-07-28 reasoning about
// impersonation sensitivity didn't change. The owner's own access/behavior
// is completely unchanged: the newly-admitted admin tier is the one that
// gets the "auto-pinned notice" treatment (see `handleBotViewSend` below)
// to keep it visually distinct from the owner's plain sends.
// ---------------------------------------------------------------------------

const BotViewSendBody = struct { chat_id: i64, text: []const u8 };

/// `POST /api/v1/bot-view/send` — calls the exact same `connector.sendMessage`
/// (owner tier) or `sendMessageReturningId`+`pinMessage` (admin tier, an
/// "admin notice" per Phase 9 — pin failures are logged and swallowed
/// rather than failing the whole send, since not every chat grants the bot
/// pin rights) any real automated reply already goes through (no parallel
/// send path to keep in sync). Always audit-logged: who, which chat, the
/// text.
fn handleBotViewSend(ctx: *const ServerContext, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    var rate_key_buf: [32]u8 = undefined;
    const rate_key = std.fmt.bufPrint(&rate_key_buf, "{d}", .{ra.account_id}) catch "?";
    if (!try checkRateLimit(ctx, request, ctx.bot_view_send_limiter, rate_key)) return;

    const body = (try readJsonBodyLeaky(request, arena, BotViewSendBody, 8192)) orelse return;
    if (body.text.len == 0) {
        return respondError(request, .bad_request, "bad_request", "text must not be empty");
    }

    const chat = (chats_store.getById(ctx.pool, arena, body.chat_id) catch |err| {
        log.err("bot-view-send: failed to load chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load chat");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such chat");
    };

    if (!ra.roles.owner and !isOwnerOrLiveAdminOfChatAccount(ctx, ra.account_id, ra.roles, chat)) {
        return respondError(request, .forbidden, "forbidden", "only the owner, or a live admin of this chat, can send as the bot");
    }

    const connector = findConnectorForPlatform(ctx.connectors, chat.platform) orelse {
        return respondError(request, .internal_server_error, "internal", "no active connector for this chat's platform");
    };

    if (ra.roles.owner) {
        connector.sendMessage(arena, chat.native_chat_id, body.text, null);
    } else {
        const sent_id = connector.sendMessageReturningId(arena, chat.native_chat_id, body.text, null) catch |err| {
            log.err("bot-view-send: admin-notice send failed for chat {d}: {t}", .{ body.chat_id, err });
            return respondError(request, .internal_server_error, "internal", "failed to send notice");
        };
        if (sent_id) |sid| {
            connector.pinMessage(arena, chat.native_chat_id, sid) catch |err| {
                log.warn("bot-view-send: admin notice sent to chat {d} but pin failed: {t}", .{ body.chat_id, err });
            };
        } else {
            // This platform's connector doesn't implement
            // `sendMessageReturningId` (no id to pin) -- still deliver the
            // text via the plain path rather than silently dropping it.
            connector.sendMessage(arena, chat.native_chat_id, body.text, null);
        }
    }

    var target_buf: [32]u8 = undefined;
    const target_str = std.fmt.bufPrint(&target_buf, "{d}", .{body.chat_id}) catch "?";
    const detail_json = std.json.Stringify.valueAlloc(arena, .{ .text = body.text }, .{}) catch null;
    audit_log.record(ctx.pool, ra.account_id, "bot_view.send", target_str, detail_json);

    return respondJson(ctx, request, .ok, .{});
}

const BotViewEventJson = struct { chat_id: i64, sender: []const u8, text: ?[]const u8, ts: i64 };

/// Runs on its own thread for the lifetime of one Bot View WS connection --
/// pops events off `sub`'s queue (blocking on its condition when empty) and
/// forwards each as a JSON text frame, until `sub` is closed (see
/// `bot_view.zig`'s `Subscriber.nextEvent`) or the write itself fails
/// (client gone). The paired connection's own worker thread runs the
/// read side (see `handleBotViewWs` below) purely to detect that.
fn botViewWriterLoop(allocator: std.mem.Allocator, ws: *http.Server.WebSocket, sub: *bot_view.Subscriber, io: Io) void {
    while (sub.nextEvent(io)) |ev| {
        defer sub.freeEvent(ev);
        const json = std.json.Stringify.valueAlloc(allocator, BotViewEventJson{
            .chat_id = ev.chat_id,
            .sender = ev.sender_display_name,
            .text = ev.text,
            .ts = ev.ts,
        }, .{}) catch continue;
        defer allocator.free(json);
        ws.writeMessage(json, .text) catch return;
    }
}

/// `GET /api/v1/bot-view/ws?chat_id=<id>` — WebSocket upgrade streaming
/// `bot_view.Broadcaster`'s live incoming-message feed for one chat. Auth
/// happens on the plain HTTP request *before* the 101 upgrade -- once
/// upgraded, a normal JSON error response can no longer be sent, so
/// anything that can fail (login, role, chat_id) is checked first.
///
/// Concurrency: the calling worker thread becomes the "reader" -- it just
/// blocks on `readSmallMessage` to detect the client closing/erroring,
/// discarding whatever it reads (Bot View is send-only from the client's
/// perspective; replies go through `handleBotViewSend` instead, over a
/// normal HTTP POST, same as every other mutating action in this API).
/// `botViewWriterLoop` runs on a second, spawned thread for the actual
/// data path. Deliberately not `Io.Group.async`/`Io.concurrent` -- see
/// `worker_pool.zig`'s module doc on why this codebase moved off those for
/// exactly this kind of long-lived per-connection work.
fn handleBotViewWs(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;

    const chat_id_str = queryParam(target, "chat_id") orelse {
        return respondError(request, .bad_request, "bad_request", "chat_id is required");
    };
    const chat_id = std.fmt.parseInt(i64, chat_id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat_id");
    };

    if (!ra.roles.owner) {
        const chat = (chats_store.getById(ctx.pool, ctx.allocator, chat_id) catch |err| {
            log.err("bot-view-ws: failed to load chat {d}: {t}", .{ chat_id, err });
            return respondError(request, .internal_server_error, "internal", "failed to load chat");
        }) orelse {
            return respondError(request, .not_found, "not_found", "no such chat");
        };
        defer ctx.allocator.free(chat.native_chat_id);
        if (!isOwnerOrLiveAdminOfChatAccount(ctx, ra.account_id, ra.roles, chat)) {
            return respondError(request, .forbidden, "forbidden", "only the owner, or a live admin of this chat, can use bot view");
        }
    }

    const key = switch (request.upgradeRequested()) {
        .websocket => |maybe_key| maybe_key orelse {
            return respondError(request, .bad_request, "bad_request", "missing sec-websocket-key");
        },
        else => return respondError(request, .bad_request, "bad_request", "expected a websocket upgrade request"),
    };

    const broadcaster = ctx.bot_view orelse {
        return respondError(request, .internal_server_error, "internal", "bot view unavailable");
    };

    var ws = try request.respondWebSocket(.{ .key = key });
    // `respondWebSocket` only writes the 101 response into the buffered
    // writer, it never flushes it (confirmed reading the stdlib source --
    // the *next* flush is `writeMessage`'s own, on the first outgoing
    // frame). Without this, a client's handshake would hang until this
    // chat's first published message, rather than completing immediately.
    try ws.output.flush();

    const sub = broadcaster.subscribe(chat_id) catch return;
    defer broadcaster.unsubscribe(chat_id, sub);

    const writer_thread = std.Thread.spawn(.{}, botViewWriterLoop, .{ ctx.allocator, &ws, sub, ctx.io }) catch {
        broadcaster.close(sub);
        return;
    };
    defer writer_thread.join();
    defer broadcaster.close(sub);

    while (true) {
        _ = ws.readSmallMessage() catch break;
    }
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

// ---------------------------------------------------------------------------
// Reminders / Alerts / Watches (Phase 5a) -- chat-scoped like Groups above,
// but "open to anyone actually in the chat" like `/remind`/`/alert`/`/watch`
// already are, not `requireChatAccess`'s group-admin ladder. Identity-scoped
// by default (own reminders/alerts/watches across every chat); `chat_id`
// narrows, `identity_id` (owner/bot_admin only) views/acts on behalf of
// someone else -- see API.md's "Feature parity" section.
// ---------------------------------------------------------------------------

const RequesterAuth = struct { account_id: i64, roles: Roles };

/// Every reminders/alerts/watches handler starts with this. `null` means a
/// response was already sent (`401`).
fn requireLoggedIn(ctx: *const ServerContext, request: *http.Server.Request) !?RequesterAuth {
    const a = resolveAuth(ctx, request);
    const account_id = a.account_id orelse {
        try respondError(request, .unauthorized, "unauthorized", "not logged in");
        return null;
    };
    const roles = computeRoles(ctx, account_id) catch |err| {
        log.err("require-logged-in: failed to compute roles for account {d}: {t}", .{ account_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to check access");
        return null;
    };
    return .{ .account_id = account_id, .roles = roles };
}

fn callersOwnIdentity(ctx: *const ServerContext, request: *http.Server.Request, account_id: i64) !?i64 {
    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, account_id) catch |err| {
        log.err("callers-own-identity: failed to list identities for account {d}: {t}", .{ account_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to resolve identity");
        return null;
    };
    defer ctx.allocator.free(identity_ids);
    if (identity_ids.len == 0) {
        try respondError(request, .internal_server_error, "internal", "account has no linked identity");
        return null;
    }
    return identity_ids[0];
}

/// Resolves the identity to scope a `GET` list by: an explicit
/// `?identity_id=` (owner/bot_admin only -- viewing on behalf of someone
/// else), else the caller's own first linked identity (same "exactly one
/// identity per account today" simplification as `handleGetMySettings`).
fn resolveListIdentity(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8, ra: RequesterAuth) !?i64 {
    if (queryParam(target, "identity_id")) |id_str| {
        if (!ra.roles.owner and !ra.roles.bot_admin) {
            try respondError(request, .forbidden, "forbidden", "admin access required to view on behalf of another identity");
            return null;
        }
        return std.fmt.parseInt(i64, id_str, 10) catch {
            try respondError(request, .bad_request, "bad_request", "invalid identity_id");
            return null;
        };
    }
    return try callersOwnIdentity(ctx, request, ra.account_id);
}

/// Resolves the creator identity for a `POST` (create): an explicit
/// `identity_id` in the body (owner/bot_admin only), else whichever of the
/// caller's own identities is a member of `chat_id` -- mirroring
/// `/remind`/`/alert`/`/watch`'s own "open to anyone currently in the
/// chat" authorization. Also verifies `chat_id` names a real chat.
fn resolveCreateIdentity(ctx: *const ServerContext, request: *http.Server.Request, ra: RequesterAuth, chat_id: i64, explicit_identity_id: ?i64) !?i64 {
    const chat = (chats_store.getById(ctx.pool, ctx.allocator, chat_id) catch |err| {
        log.err("resolve-create-identity: failed to load chat {d}: {t}", .{ chat_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to load chat");
        return null;
    }) orelse {
        try respondError(request, .not_found, "not_found", "no such chat");
        return null;
    };
    ctx.allocator.free(chat.native_chat_id);

    if (explicit_identity_id) |id| {
        if (!ra.roles.owner and !ra.roles.bot_admin) {
            try respondError(request, .forbidden, "forbidden", "admin access required to act on behalf of another identity");
            return null;
        }
        return id;
    }

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, ra.account_id) catch |err| {
        log.err("resolve-create-identity: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to resolve identity");
        return null;
    };
    defer ctx.allocator.free(identity_ids);
    for (identity_ids) |id| {
        if (chat_members.isMember(ctx.pool, chat_id, id)) return id;
    }
    try respondError(request, .forbidden, "forbidden", "not a member of this chat");
    return null;
}

// --- Reminders ---

const ReminderWhenBody = struct {
    kind: []const u8,
    seconds: ?i64 = null,
    year: ?i32 = null,
    month: ?u8 = null,
    day: ?u8 = null,
    hour: ?u8 = null,
    minute: ?u8 = null,
    second: ?u8 = null,
};

const CreateReminderBody = struct {
    chat_id: i64,
    identity_id: ?i64 = null,
    message: []const u8,
    recur_interval_seconds: ?i64 = null,
    when: ReminderWhenBody,
};

/// `GET /api/v1/reminders?chat_id=&identity_id=` -- see API.md. Scoped to
/// one identity (default: the caller's own) unlike the bot's own in-chat
/// `/reminders`, which lists every setter's pending reminders in that one
/// chat -- a deliberate difference documented in API.md.
fn handleListReminders(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const identity_id = (try resolveListIdentity(ctx, request, target, ra)) orelse return;
    const chat_id: ?i64 = if (queryParam(target, "chat_id")) |c|
        std.fmt.parseInt(i64, c, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid chat_id");
        }
    else
        null;

    const items = reminders.listForIdentity(ctx.pool, ctx.allocator, identity_id, chat_id) catch |err| {
        log.err("list-reminders: failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load reminders");
    };
    defer {
        for (items) |it| {
            if (it.chat_title) |t| ctx.allocator.free(t);
            ctx.allocator.free(it.message);
        }
        ctx.allocator.free(items);
    }

    const date_format = user_settings.getEffectiveDateFormat(ctx.pool, ctx.allocator, identity_id);
    const time_format = user_settings.getEffectiveTimeFormat(ctx.pool, ctx.allocator, identity_id);
    const offset_minutes = user_settings.getEffectiveOffsetMinutes(ctx.pool, ctx.allocator, identity_id);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Item = struct {
        id: i64,
        chat_id: i64,
        chat_title: ?[]const u8,
        message: []const u8,
        due_at: i64,
        due_at_date: []const u8,
        due_at_time: []const u8,
        recur_interval_seconds: ?i64,
    };
    const out = try arena.alloc(Item, items.len);
    for (items, 0..) |it, i| {
        const local = civil_time.localFromUnix(it.due_at, offset_minutes);
        out[i] = .{
            .id = it.id,
            .chat_id = it.chat_id,
            .chat_title = it.chat_title,
            .message = it.message,
            .due_at = it.due_at,
            .due_at_date = civil_time.formatDate(arena, local, date_format),
            .due_at_time = civil_time.formatTime(arena, local, time_format),
            .recur_interval_seconds = it.recur_interval_seconds,
        };
    }

    return respondJson(ctx, request, .ok, .{ .items = out });
}

/// `POST /api/v1/reminders` -- see API.md; `when` mirrors the `/menu`
/// wizard's own step data (see `menu.zig`'s `ReminderDraft`) so this form
/// and the wizard describe the same underlying moment two different ways.
fn handleCreateReminder(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "reminders")) {
        return respondError(request, .forbidden, "forbidden", "the reminders module is disabled");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(4 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(CreateReminderBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid request body");
    };

    if (body.message.len == 0 or body.message.len > max_reminder_message_len) {
        return respondError(request, .bad_request, "bad_request", "message must be 1-500 bytes");
    }
    if (body.recur_interval_seconds) |interval| {
        if (interval <= 0) {
            return respondError(request, .bad_request, "bad_request", "recur_interval_seconds must be positive");
        }
    }

    const identity_id = (try resolveCreateIdentity(ctx, request, ra, body.chat_id, body.identity_id)) orelse return;

    var due_at: i64 = undefined;
    if (std.mem.eql(u8, body.when.kind, "duration")) {
        const seconds = body.when.seconds orelse {
            return respondError(request, .bad_request, "bad_request", "when.seconds required for a duration reminder");
        };
        if (seconds <= 0) {
            return respondError(request, .bad_request, "bad_request", "when.seconds must be positive");
        }
        const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
        due_at = now + seconds;
    } else if (std.mem.eql(u8, body.when.kind, "absolute")) {
        const year = body.when.year orelse {
            return respondError(request, .bad_request, "bad_request", "when.year required for an absolute reminder");
        };
        const month = body.when.month orelse {
            return respondError(request, .bad_request, "bad_request", "when.month required for an absolute reminder");
        };
        const day = body.when.day orelse {
            return respondError(request, .bad_request, "bad_request", "when.day required for an absolute reminder");
        };
        const hour = body.when.hour orelse 0;
        const minute = body.when.minute orelse 0;
        const second = body.when.second orelse 0;
        if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) {
            return respondError(request, .bad_request, "bad_request", "invalid date/time");
        }
        const offset_minutes = user_settings.getEffectiveOffsetMinutes(ctx.pool, ctx.allocator, identity_id);
        due_at = civil_time.unixFromLocal(.{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second }, offset_minutes);
    } else {
        return respondError(request, .bad_request, "bad_request", "when.kind must be \"duration\" or \"absolute\"");
    }

    const id = reminders.create(ctx.pool, body.chat_id, identity_id, body.message, due_at, body.recur_interval_seconds) catch |err| {
        log.err("create-reminder: failed for chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to create reminder");
    };

    audit_log.record(ctx.pool, ra.account_id, "reminder.create", null, null);

    return respondJson(ctx, request, .ok, .{ .id = id, .due_at = due_at });
}

/// `DELETE /api/v1/reminders/:id` -- same authorization as `/remind
/// cancel`: whoever set it, or the bot owner (not bot_admin -- mirrors
/// `handleRemindCommand`'s `auth.isOwner` check exactly).
fn handleCancelReminder(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid reminder id");
    };

    const rem = (reminders.get(ctx.pool, ctx.allocator, id) catch |err| {
        log.err("cancel-reminder: lookup failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to look up reminder");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such reminder");
    };
    defer ctx.allocator.free(rem.message);

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, ra.account_id) catch |err| {
        log.err("cancel-reminder: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to check access");
    };
    defer ctx.allocator.free(identity_ids);
    const is_setter = std.mem.indexOfScalar(i64, identity_ids, rem.identity_id) != null;
    if (!is_setter and !ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only whoever set this reminder, or the owner, can cancel it");
    }

    reminders.cancel(ctx.pool, id) catch |err| {
        log.err("cancel-reminder: failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to cancel reminder");
    };
    audit_log.record(ctx.pool, ra.account_id, "reminder.cancel", id_str, null);

    return respondJson(ctx, request, .ok, .{});
}

// --- Alerts ---

const CreateAlertBody = struct {
    chat_id: i64,
    identity_id: ?i64 = null,
    kind: []const u8,
    subject: []const u8,
    condition: []const u8,
    threshold: f64,
};

/// `GET /api/v1/alerts?chat_id=&identity_id=` -- same scoping rules as
/// `handleListReminders`.
fn handleListAlerts(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const identity_id = (try resolveListIdentity(ctx, request, target, ra)) orelse return;
    const chat_id: ?i64 = if (queryParam(target, "chat_id")) |c|
        std.fmt.parseInt(i64, c, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid chat_id");
        }
    else
        null;

    const items = alert_store.listForIdentity(ctx.pool, ctx.allocator, identity_id, chat_id) catch |err| {
        log.err("list-alerts: failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load alerts");
    };
    defer {
        for (items) |it| {
            if (it.chat_title) |t| ctx.allocator.free(t);
            ctx.allocator.free(it.subject);
            if (it.currency) |c| ctx.allocator.free(c);
        }
        ctx.allocator.free(items);
    }

    const Item = struct {
        id: i64,
        chat_id: i64,
        chat_title: ?[]const u8,
        kind: []const u8,
        subject: []const u8,
        currency: ?[]const u8,
        condition: []const u8,
        threshold: f64,
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try arena.alloc(Item, items.len);
    for (items, 0..) |it, i| {
        out[i] = .{
            .id = it.id,
            .chat_id = it.chat_id,
            .chat_title = it.chat_title,
            .kind = @tagName(it.kind),
            .subject = it.subject,
            .currency = it.currency,
            .condition = @tagName(it.condition),
            .threshold = it.threshold,
        };
    }
    return respondJson(ctx, request, .ok, .{ .items = out });
}

/// `POST /api/v1/alerts` -- see API.md. `currency` isn't accepted from the
/// client, same as `/alert`: always `"usd"` for `crypto`, `null`
/// otherwise (see `handleAlertCommand`).
fn handleCreateAlert(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "alerts")) {
        return respondError(request, .forbidden, "forbidden", "the alerts module is disabled");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [2 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(2 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(CreateAlertBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid request body");
    };

    const kind = std.meta.stringToEnum(alert_store.Kind, body.kind) orelse {
        return respondError(request, .bad_request, "bad_request", "kind must be crypto, weather, or aqi");
    };
    const condition = std.meta.stringToEnum(alert_store.Condition, body.condition) orelse {
        return respondError(request, .bad_request, "bad_request", "condition must be above or below");
    };
    if (body.subject.len == 0) {
        return respondError(request, .bad_request, "bad_request", "subject is required");
    }

    const identity_id = (try resolveCreateIdentity(ctx, request, ra, body.chat_id, body.identity_id)) orelse return;

    const currency: ?[]const u8 = if (kind == .crypto) "usd" else null;
    const id = alert_store.create(ctx.pool, body.chat_id, identity_id, kind, body.subject, currency, condition, body.threshold) catch |err| {
        log.err("create-alert: failed for chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to create alert");
    };
    audit_log.record(ctx.pool, ra.account_id, "alert.create", null, null);
    return respondJson(ctx, request, .ok, .{ .id = id });
}

/// `DELETE /api/v1/alerts/:id` -- same authorization as `/alert cancel`:
/// whoever set it, or the bot owner.
fn handleCancelAlert(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid alert id");
    };

    const al = (alert_store.get(ctx.pool, ctx.allocator, id) catch |err| {
        log.err("cancel-alert: lookup failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to look up alert");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such alert");
    };

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, ra.account_id) catch |err| {
        log.err("cancel-alert: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to check access");
    };
    defer ctx.allocator.free(identity_ids);
    const is_setter = std.mem.indexOfScalar(i64, identity_ids, al.identity_id) != null;
    if (!is_setter and !ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only whoever set this alert, or the owner, can cancel it");
    }

    alert_store.cancel(ctx.pool, id) catch |err| {
        log.err("cancel-alert: failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to cancel alert");
    };
    audit_log.record(ctx.pool, ra.account_id, "alert.cancel", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

// --- Watches ---

const CreateWatchBody = struct {
    chat_id: i64,
    identity_id: ?i64 = null,
    feed_url: []const u8,
};

/// `GET /api/v1/watches?chat_id=&identity_id=` -- same scoping rules as
/// `handleListReminders`; note this shows watches *added by* the scoped
/// identity, but (matching `/unwatch`) removing one isn't restricted to
/// its adder -- see `handleDeleteWatch`.
fn handleListWatches(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const identity_id = (try resolveListIdentity(ctx, request, target, ra)) orelse return;
    const chat_id: ?i64 = if (queryParam(target, "chat_id")) |c|
        std.fmt.parseInt(i64, c, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid chat_id");
        }
    else
        null;

    const items = feed_watches.listForIdentity(ctx.pool, ctx.allocator, identity_id, chat_id) catch |err| {
        log.err("list-watches: failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load watches");
    };
    defer {
        for (items) |it| {
            if (it.chat_title) |t| ctx.allocator.free(t);
            ctx.allocator.free(it.feed_url);
        }
        ctx.allocator.free(items);
    }
    return respondJson(ctx, request, .ok, .{ .items = items });
}

/// `POST /api/v1/watches` -- see API.md.
fn handleCreateWatch(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "watches")) {
        return respondError(request, .forbidden, "forbidden", "the watches module is disabled");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [2 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(2 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(CreateWatchBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid request body");
    };

    if (!std.mem.startsWith(u8, body.feed_url, "http://") and !std.mem.startsWith(u8, body.feed_url, "https://")) {
        return respondError(request, .bad_request, "bad_request", "feed_url must be an http(s) URL");
    }

    const identity_id = (try resolveCreateIdentity(ctx, request, ra, body.chat_id, body.identity_id)) orelse return;

    const created = feed_watches.create(ctx.pool, body.chat_id, identity_id, body.feed_url) catch |err| {
        log.err("create-watch: failed for chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to create watch");
    };
    audit_log.record(ctx.pool, ra.account_id, "watch.create", null, null);
    return respondJson(ctx, request, .ok, .{ .created = created });
}

/// `DELETE /api/v1/watches/:id` -- open to anyone currently in the watch's
/// chat, not restricted to whoever added it (mirrors `/unwatch`'s own
/// authorization -- see `feed_watches.remove`'s doc comment).
fn handleDeleteWatch(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid watch id");
    };

    const watch = (feed_watches.getById(ctx.pool, ctx.allocator, id) catch |err| {
        log.err("delete-watch: lookup failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to look up watch");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such watch");
    };
    defer ctx.allocator.free(watch.feed_url);

    if (!ra.roles.owner and !ra.roles.bot_admin) {
        const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, ra.account_id) catch |err| {
            log.err("delete-watch: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
            return respondError(request, .internal_server_error, "internal", "failed to check access");
        };
        defer ctx.allocator.free(identity_ids);
        var is_member = false;
        for (identity_ids) |member_identity_id| {
            if (chat_members.isMember(ctx.pool, watch.chat_id, member_identity_id)) {
                is_member = true;
                break;
            }
        }
        if (!is_member) {
            return respondError(request, .forbidden, "forbidden", "not a member of this chat");
        }
    }

    feed_watches.removeById(ctx.pool, id) catch |err| {
        log.err("delete-watch: failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to delete watch");
    };
    audit_log.record(ctx.pool, ra.account_id, "watch.delete", id_str, null);
    return respondJson(ctx, request, .ok, .{});
}

// --- Notes (Phase 11) -- same identity-scoped-by-default shape as
// Reminders/Alerts/Watches above; deletion is creator-or-owner, same as
// `/note delete` (`handleNoteCommand` in main.zig), not "anyone in the
// chat" like Watches' removal is. ---

const CreateNoteBody = struct {
    chat_id: i64,
    identity_id: ?i64 = null,
    text: []const u8,
};

/// `GET /api/v1/notes?chat_id=&identity_id=` -- same scoping rules as
/// `handleListReminders`. Unlike the bot's own in-chat `/notes` (chat-scoped,
/// every contributor's notes together), this is "my notes across every
/// chat" by default -- see `notes_store.NoteForIdentity`'s doc comment.
fn handleListNotes(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const identity_id = (try resolveListIdentity(ctx, request, target, ra)) orelse return;
    const chat_id: ?i64 = if (queryParam(target, "chat_id")) |c|
        std.fmt.parseInt(i64, c, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid chat_id");
        }
    else
        null;

    const items = notes_store.listForIdentity(ctx.pool, ctx.allocator, identity_id, chat_id) catch |err| {
        log.err("list-notes: failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load notes");
    };
    defer {
        for (items) |it| {
            if (it.chat_title) |t| ctx.allocator.free(t);
            ctx.allocator.free(it.text);
        }
        ctx.allocator.free(items);
    }
    return respondJson(ctx, request, .ok, .{ .items = items });
}

/// `POST /api/v1/notes` -- see API.md. Mirrors `/note add <text>`.
fn handleCreateNote(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "notes")) {
        return respondError(request, .forbidden, "forbidden", "the notes module is disabled");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [2 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(2 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(CreateNoteBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid request body");
    };

    if (body.text.len == 0 or body.text.len > max_note_text_len) {
        return respondError(request, .bad_request, "bad_request", "text must be 1-1000 bytes");
    }

    const identity_id = (try resolveCreateIdentity(ctx, request, ra, body.chat_id, body.identity_id)) orelse return;

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const id = notes_store.create(ctx.pool, body.chat_id, identity_id, body.text, now) catch |err| {
        log.err("create-note: failed for chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to create note");
    };

    audit_log.record(ctx.pool, ra.account_id, "note.create", null, null);

    return respondJson(ctx, request, .ok, .{ .id = id });
}

/// `DELETE /api/v1/notes/:id` -- same authorization as `/note delete`:
/// whoever added it, or the bot owner (not bot_admin -- mirrors
/// `handleNoteCommand`'s `auth.isOwner` check exactly).
fn handleDeleteNote(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid note id");
    };

    const note = (notes_store.get(ctx.pool, ctx.allocator, id) catch |err| {
        log.err("delete-note: lookup failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to look up note");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such note");
    };
    defer ctx.allocator.free(note.text);

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, ra.account_id) catch |err| {
        log.err("delete-note: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to check access");
    };
    defer ctx.allocator.free(identity_ids);
    const is_creator = std.mem.indexOfScalar(i64, identity_ids, note.identity_id) != null;
    if (!is_creator and !ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only whoever added this note, or the owner, can delete it");
    }

    notes_store.delete(ctx.pool, id) catch |err| {
        log.err("delete-note: failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to delete note");
    };
    audit_log.record(ctx.pool, ra.account_id, "note.delete", id_str, null);

    return respondJson(ctx, request, .ok, .{});
}

// --- Finance: expenses, budgets, subscriptions (ROADMAP.md Phase 17) ---

/// Percent-decodes a query-parameter value into `arena`. `queryParam`
/// returns the raw, still-encoded slice; every caller written before this
/// one only ever parsed integers out of it, where encoding can't matter,
/// but the expense `category` filter is free text -- "eating out & drinks"
/// arrives as `eating%20out%20%26%20drinks` and would match no row at all
/// without this. `+` decodes to a space too, since form-encoded query
/// strings still use it. Malformed escapes (a trailing `%`, non-hex
/// digits) are passed through as literal characters rather than raising --
/// a filter value is not worth failing a whole request over, and a
/// nonsense category simply matches nothing.
fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '+') {
            try out.append(arena, ' ');
            i += 1;
            continue;
        }
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(arena, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(arena, s[i]);
                i += 1;
                continue;
            };
            try out.append(arena, @as(u8, hi) * 16 + @as(u8, lo));
            i += 3;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Chat-scoped *read* access for the finance endpoints: true if the caller
/// is a member of `chat_id` through any of their linked identities, or is
/// owner/bot_admin. `false` means a response was already sent.
///
/// Deliberately **not** `requireChatAccess` -- that one means "live
/// platform admin of this chat," the right bar for changing a chat's
/// settings but the wrong one for reading a shared ledger every member can
/// already see in-chat via `/expense summary`/`/budget list` (both of
/// which are open to the whole chat; only *changing* a budget is
/// owner-gated). Reuses the same `chat_members.isMember` primitive
/// `resolveCreateIdentity` already authorizes finance *writes* with, so
/// this is that existing check reused for reads, not a second
/// authorization path.
fn requireChatMember(ctx: *const ServerContext, request: *http.Server.Request, ra: RequesterAuth, chat_id: i64) !bool {
    const chat = (chats_store.getById(ctx.pool, ctx.allocator, chat_id) catch |err| {
        log.err("chat-member: failed to load chat {d}: {t}", .{ chat_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to load chat");
        return false;
    }) orelse {
        try respondError(request, .not_found, "not_found", "no such chat");
        return false;
    };
    ctx.allocator.free(chat.native_chat_id);

    if (ra.roles.owner or ra.roles.bot_admin) return true;

    const identity_ids = accounts.listIdentityIds(ctx.pool, ctx.allocator, ra.account_id) catch |err| {
        log.err("chat-member: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        try respondError(request, .internal_server_error, "internal", "failed to check access");
        return false;
    };
    defer ctx.allocator.free(identity_ids);
    for (identity_ids) |id| {
        if (chat_members.isMember(ctx.pool, chat_id, id)) return true;
    }
    try respondError(request, .forbidden, "forbidden", "not a member of this chat");
    return false;
}

/// Validates a client-supplied amount. Every finance amount crosses this
/// API as an **integer cent count**, never a decimal string or float --
/// the client does its own string -> cents conversion (see warden-ui's
/// `parseAmountCents` in `src/lib/money.ts`) so that no float ever touches
/// a money value on either side of the wire, which is the same standard
/// ROADMAP.md Phase 17 held the bot-side code to.
fn validAmountCents(cents: i64) bool {
    return cents > 0 and cents <= max_amount_cents;
}

/// `null` (with a response already sent) if the body's currency is present
/// but unusable; otherwise the currency to store.
fn resolveCurrency(request: *http.Server.Request, supplied: ?[]const u8) !?[]const u8 {
    const cur = supplied orelse return default_currency;
    if (cur.len == 0 or cur.len > max_currency_len) {
        try respondError(request, .bad_request, "bad_request", "currency must be 1-8 characters");
        return null;
    }
    return cur;
}

const CreateExpenseBody = struct {
    chat_id: i64,
    identity_id: ?i64 = null,
    amount_cents: i64,
    category: []const u8,
    description: ?[]const u8 = null,
    currency: ?[]const u8 = null,
};

const SetBudgetBody = struct {
    chat_id: i64,
    category: []const u8,
    amount_cents: i64,
    currency: ?[]const u8 = null,
};

const CreateSubscriptionBody = struct {
    chat_id: i64,
    identity_id: ?i64 = null,
    name: []const u8,
    amount_cents: i64,
    interval_days: i64,
    currency: ?[]const u8 = null,
};

/// `GET /api/v1/expenses?chat_id=&identity_id=&category=&since=&limit=` --
/// same identity scoping as `handleListNotes` ("my spending across every
/// chat" by default). Unlike the bot's own `/expense list`, which is
/// chat-scoped and shows every contributor's entries together.
fn handleListExpenses(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const identity_id = (try resolveListIdentity(ctx, request, target, ra)) orelse return;

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chat_id: ?i64 = if (queryParam(target, "chat_id")) |c|
        std.fmt.parseInt(i64, c, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid chat_id");
        }
    else
        null;
    const since: ?i64 = if (queryParam(target, "since")) |s|
        std.fmt.parseInt(i64, s, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid since");
        }
    else
        null;
    const category: ?[]const u8 = if (queryParam(target, "category")) |c|
        try percentDecode(arena, c)
    else
        null;

    const items = expenses_store.listForIdentity(
        ctx.pool,
        arena,
        identity_id,
        chat_id,
        category,
        since,
        paginationParams(target).limit,
    ) catch |err| {
        log.err("list-expenses: failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load expenses");
    };
    return respondJson(ctx, request, .ok, .{ .items = items });
}

/// `GET /api/v1/expenses/summary?chat_id=&since=` -- chat-scoped totals by
/// category cross-referenced against that chat's budgets, the web version
/// of `/expense summary`. Chat-scoped (not identity-scoped like the list
/// above) because a budget is chat-wide policy: "am I over budget" is only
/// a meaningful question against the whole chat's spending, which is
/// exactly what the bot's own summary reports.
///
/// `since` is required from the caller rather than defaulted to "this
/// calendar month" server-side the way `/expense summary` does -- the
/// month boundary depends on the viewer's UTC offset, which the frontend
/// already knows from `GET /api/v1/me/settings`; guessing it here would
/// silently report the wrong window for anyone not on UTC. Omitting it
/// means all time.
fn handleExpenseSummary(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;

    const chat_id = std.fmt.parseInt(i64, queryParam(target, "chat_id") orelse {
        return respondError(request, .bad_request, "bad_request", "chat_id is required");
    }, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat_id");
    };
    if (!try requireChatMember(ctx, request, ra, chat_id)) return;

    const since: ?i64 = if (queryParam(target, "since")) |s|
        std.fmt.parseInt(i64, s, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid since");
        }
    else
        null;

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const totals = expenses_store.totalsByCategory(ctx.pool, arena, chat_id, since) catch |err| {
        log.err("expense-summary: totals failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load summary");
    };
    const budget_rows = budgets_store.listForChat(ctx.pool, arena, chat_id) catch |err| {
        log.err("expense-summary: budgets failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load summary");
    };

    const Row = struct {
        category: []const u8,
        total_cents: i64,
        budget_cents: ?i64,
        over: bool,
    };
    var rows: std.ArrayList(Row) = .empty;

    // Spending first (already highest-total-first from the query), each
    // matched against a budget for the same category if one exists.
    for (totals) |t| {
        var budget_cents: ?i64 = null;
        for (budget_rows) |b| {
            if (std.mem.eql(u8, b.category, t.category)) {
                budget_cents = b.amount_cents;
                break;
            }
        }
        try rows.append(arena, .{
            .category = t.category,
            .total_cents = t.total_cents,
            .budget_cents = budget_cents,
            .over = if (budget_cents) |b| t.total_cents > b else false,
        });
    }
    // Then any budget with no spending at all in this window -- `/budget
    // list` shows these too, and dropping them would make a configured
    // budget silently vanish from the panel until someone spends against
    // it.
    for (budget_rows) |b| {
        var already = false;
        for (totals) |t| {
            if (std.mem.eql(u8, b.category, t.category)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try rows.append(arena, .{
            .category = b.category,
            .total_cents = 0,
            .budget_cents = b.amount_cents,
            .over = false,
        });
    }

    const total_cents = expenses_store.totalForChat(ctx.pool, chat_id, since) catch |err| {
        log.err("expense-summary: total failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load summary");
    };

    return respondJson(ctx, request, .ok, .{
        .chat_id = chat_id,
        .total_cents = total_cents,
        .categories = rows.items,
    });
}

/// `POST /api/v1/expenses` -- mirrors `/expense add <amount> <category>
/// [description]`, open to anyone in the chat (same
/// `resolveCreateIdentity` authorization as reminders/alerts/notes).
fn handleCreateExpense(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "finance")) {
        return respondError(request, .forbidden, "forbidden", "the finance module is disabled");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [2 * 1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(2 * 1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(CreateExpenseBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid request body");
    };

    if (!validAmountCents(body.amount_cents)) {
        return respondError(request, .bad_request, "bad_request", "amount_cents must be a positive integer number of cents");
    }
    if (body.category.len == 0 or body.category.len > max_expense_category_len) {
        return respondError(request, .bad_request, "bad_request", "category must be 1-64 bytes");
    }
    if (body.description) |d| {
        if (d.len > max_expense_description_len) {
            return respondError(request, .bad_request, "bad_request", "description must be at most 500 bytes");
        }
    }
    const currency = (try resolveCurrency(request, body.currency)) orelse return;

    const identity_id = (try resolveCreateIdentity(ctx, request, ra, body.chat_id, body.identity_id)) orelse return;

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const id = expenses_store.create(
        ctx.pool,
        body.chat_id,
        identity_id,
        body.amount_cents,
        currency,
        body.category,
        body.description,
        now,
    ) catch |err| {
        log.err("create-expense: failed for chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to create expense");
    };

    audit_log.record(ctx.pool, ra.account_id, "expense.create", null, null);

    return respondJson(ctx, request, .ok, .{ .id = id });
}

/// `DELETE /api/v1/expenses/:id` -- same authorization as `/expense
/// delete`: whoever recorded it, or the bot owner (not bot_admin --
/// mirrors `handleExpenseCommand`'s `auth.isOwner` check exactly, same as
/// `handleDeleteNote`).
fn handleDeleteExpense(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid expense id");
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const expense = (expenses_store.get(ctx.pool, arena, id) catch |err| {
        log.err("delete-expense: lookup failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to look up expense");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such expense");
    };

    const identity_ids = accounts.listIdentityIds(ctx.pool, arena, ra.account_id) catch |err| {
        log.err("delete-expense: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to check access");
    };
    const is_creator = std.mem.indexOfScalar(i64, identity_ids, expense.identity_id) != null;
    if (!is_creator and !ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only whoever recorded this expense, or the owner, can delete it");
    }

    expenses_store.delete(ctx.pool, id) catch |err| {
        log.err("delete-expense: failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to delete expense");
    };
    audit_log.record(ctx.pool, ra.account_id, "expense.delete", id_str, null);

    return respondJson(ctx, request, .ok, .{});
}

/// `GET /api/v1/budgets?chat_id=` -- chat-scoped, readable by any member,
/// exactly like the bot's own `/budget list`. No identity scoping at all:
/// a budget is chat-wide policy, not a personal record.
fn handleListBudgets(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;

    const chat_id = std.fmt.parseInt(i64, queryParam(target, "chat_id") orelse {
        return respondError(request, .bad_request, "bad_request", "chat_id is required");
    }, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid chat_id");
    };
    if (!try requireChatMember(ctx, request, ra, chat_id)) return;

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = budgets_store.listForChat(ctx.pool, arena, chat_id) catch |err| {
        log.err("list-budgets: failed for chat {d}: {t}", .{ chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load budgets");
    };
    return respondJson(ctx, request, .ok, .{ .items = items });
}

/// `PUT /api/v1/budgets` -- upsert keyed by `(chat_id, category)`, mirroring
/// `/budget set <category> <amount>`. `PUT`, not `POST`, because
/// `budgets.set` is an upsert rather than a create: sending the same
/// category twice replaces the amount instead of adding a second row.
///
/// **Owner only** -- `handleBudgetCommand` gates set/remove behind
/// `auth.isOwner` (not bot_admin), since a budget is chat-wide policy in
/// the same tier as a system-prompt override. Viewing stays open, above.
fn handleSetBudget(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "finance")) {
        return respondError(request, .forbidden, "forbidden", "the finance module is disabled");
    }
    if (!ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only the bot owner can change a chat's budgets");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(SetBudgetBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid request body");
    };

    if (!validAmountCents(body.amount_cents)) {
        return respondError(request, .bad_request, "bad_request", "amount_cents must be a positive integer number of cents");
    }
    if (body.category.len == 0 or body.category.len > max_expense_category_len) {
        return respondError(request, .bad_request, "bad_request", "category must be 1-64 bytes");
    }
    const currency = (try resolveCurrency(request, body.currency)) orelse return;

    // Owner-only above, so there's no membership question left to answer --
    // but the chat still has to exist, or this would create a budget
    // dangling off a nonexistent chat id.
    if (!try requireChatMember(ctx, request, ra, body.chat_id)) return;

    const id = budgets_store.set(ctx.pool, body.chat_id, body.category, body.amount_cents, currency) catch |err| {
        log.err("set-budget: failed for chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to set budget");
    };

    audit_log.record(ctx.pool, ra.account_id, "budget.set", body.category, null);

    return respondJson(ctx, request, .ok, .{ .id = id });
}

/// `DELETE /api/v1/budgets/:id` -- owner only, same as `handleSetBudget`.
/// Addressed by integer id rather than by category the way `/budget remove
/// <category>` is; see `budgets.getById`'s doc comment for why.
fn handleDeleteBudget(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only the bot owner can change a chat's budgets");
    }
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid budget id");
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = (budgets_store.getById(ctx.pool, arena, id) catch |err| {
        log.err("delete-budget: lookup failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to look up budget");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such budget");
    };

    budgets_store.removeById(ctx.pool, id) catch |err| {
        log.err("delete-budget: failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to delete budget");
    };
    audit_log.record(ctx.pool, ra.account_id, "budget.remove", id_str, null);

    return respondJson(ctx, request, .ok, .{});
}

/// `GET /api/v1/subscriptions?chat_id=&identity_id=` -- same identity
/// scoping as `handleListNotes`. Each row carries `monthly_equivalent_cents`
/// so the panel doesn't have to reimplement
/// `subscriptions.monthlyEquivalentCents`'s 30-day-month normalization and
/// risk drifting from what `/subscription list` reports in chat.
fn handleListSubscriptions(ctx: *const ServerContext, request: *http.Server.Request, target: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const identity_id = (try resolveListIdentity(ctx, request, target, ra)) orelse return;

    const chat_id: ?i64 = if (queryParam(target, "chat_id")) |c|
        std.fmt.parseInt(i64, c, 10) catch {
            return respondError(request, .bad_request, "bad_request", "invalid chat_id");
        }
    else
        null;

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = subscriptions_store.listForIdentity(ctx.pool, arena, identity_id, chat_id) catch |err| {
        log.err("list-subscriptions: failed for identity {d}: {t}", .{ identity_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load subscriptions");
    };

    const Row = struct {
        id: i64,
        chat_id: i64,
        chat_title: ?[]const u8,
        name: []const u8,
        amount_cents: i64,
        currency: []const u8,
        interval_days: i64,
        monthly_equivalent_cents: i64,
        created_at: i64,
    };
    var items: std.ArrayList(Row) = .empty;
    var monthly_total: i64 = 0;
    for (rows) |s| {
        const monthly = subscriptions_store.monthlyEquivalentCents(s.amount_cents, s.interval_days);
        monthly_total += monthly;
        try items.append(arena, .{
            .id = s.id,
            .chat_id = s.chat_id,
            .chat_title = s.chat_title,
            .name = s.name,
            .amount_cents = s.amount_cents,
            .currency = s.currency,
            .interval_days = s.interval_days,
            .monthly_equivalent_cents = monthly,
            .created_at = s.created_at,
        });
    }

    return respondJson(ctx, request, .ok, .{
        .items = items.items,
        .monthly_total_cents = monthly_total,
    });
}

/// `POST /api/v1/subscriptions` -- mirrors `/subscription add <name>
/// <amount> every <interval>`. Takes `interval_days` as an integer rather
/// than the bot's `1mo`/`2w` shorthand: `parseIntervalDays` lives in
/// `main.zig` (which imports this file, so importing it back would be
/// circular), and a picker in the panel is a better fit for the web than
/// re-parsing a shorthand string here.
fn handleCreateSubscription(ctx: *const ServerContext, request: *http.Server.Request) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    if (!feature_flags.isEnabled(ctx.pool, "finance")) {
        return respondError(request, .forbidden, "forbidden", "the finance module is disabled");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [1024]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const raw = reader.allocRemaining(arena, .limited(1024)) catch {
        return respondError(request, .bad_request, "bad_request", "failed to read body");
    };
    const body = std.json.parseFromSliceLeaky(CreateSubscriptionBody, arena, raw, .{}) catch {
        return respondError(request, .bad_request, "bad_request", "invalid request body");
    };

    if (!validAmountCents(body.amount_cents)) {
        return respondError(request, .bad_request, "bad_request", "amount_cents must be a positive integer number of cents");
    }
    if (body.name.len == 0 or body.name.len > max_subscription_name_len) {
        return respondError(request, .bad_request, "bad_request", "name must be 1-128 bytes");
    }
    // Upper bound mirrors `parseIntervalDays`'s own reachable maximum
    // (`/subscription add ... every 100y`-scale input) while keeping
    // `monthlyEquivalentCents`'s `amount_cents * 30` division safe.
    if (body.interval_days <= 0 or body.interval_days > 36_500) {
        return respondError(request, .bad_request, "bad_request", "interval_days must be between 1 and 36500");
    }
    const currency = (try resolveCurrency(request, body.currency)) orelse return;

    const identity_id = (try resolveCreateIdentity(ctx, request, ra, body.chat_id, body.identity_id)) orelse return;

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const id = subscriptions_store.create(
        ctx.pool,
        body.chat_id,
        identity_id,
        body.name,
        body.amount_cents,
        currency,
        body.interval_days,
        now,
    ) catch |err| {
        log.err("create-subscription: failed for chat {d}: {t}", .{ body.chat_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to create subscription");
    };

    audit_log.record(ctx.pool, ra.account_id, "subscription.create", null, null);

    return respondJson(ctx, request, .ok, .{ .id = id });
}

/// `DELETE /api/v1/subscriptions/:id` -- same authorization as
/// `/subscription remove`: whoever added it, or the bot owner.
fn handleDeleteSubscription(ctx: *const ServerContext, request: *http.Server.Request, id_str: []const u8) !void {
    const ra = (try requireLoggedIn(ctx, request)) orelse return;
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid subscription id");
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sub = (subscriptions_store.get(ctx.pool, arena, id) catch |err| {
        log.err("delete-subscription: lookup failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to look up subscription");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such subscription");
    };

    const identity_ids = accounts.listIdentityIds(ctx.pool, arena, ra.account_id) catch |err| {
        log.err("delete-subscription: failed to list identities for account {d}: {t}", .{ ra.account_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to check access");
    };
    const is_creator = std.mem.indexOfScalar(i64, identity_ids, sub.identity_id) != null;
    if (!is_creator and !ra.roles.owner) {
        return respondError(request, .forbidden, "forbidden", "only whoever added this subscription, or the owner, can remove it");
    }

    subscriptions_store.remove(ctx.pool, id) catch |err| {
        log.err("delete-subscription: failed for id {d}: {t}", .{ id, err });
        return respondError(request, .internal_server_error, "internal", "failed to remove subscription");
    };
    audit_log.record(ctx.pool, ra.account_id, "subscription.delete", id_str, null);

    return respondJson(ctx, request, .ok, .{});
}

test "percentDecode handles escapes, plus-as-space, and passes malformed escapes through" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("food", try percentDecode(a, "food"));
    try std.testing.expectEqualStrings("eating out & drinks", try percentDecode(a, "eating%20out%20%26%20drinks"));
    try std.testing.expectEqualStrings("eating out", try percentDecode(a, "eating+out"));
    try std.testing.expectEqualStrings("caf\u{00e9}", try percentDecode(a, "caf%C3%A9")); // multi-byte UTF-8
    // Malformed: a trailing '%' and a non-hex escape both survive as literals
    // rather than failing the request.
    try std.testing.expectEqualStrings("100%", try percentDecode(a, "100%"));
    try std.testing.expectEqualStrings("%zz", try percentDecode(a, "%zz"));
}

/// `user_agent` must have been captured by the caller *before* it read the
/// request body (if any) — `findHeader`/`iterateHeaders` requires the
/// request reader to still be in its post-head, pre-body state; calling it
/// from here (after callers like `handleDevLogin` already read the body)
/// crashed with `assertion failure` in `std.http.Server.Request.iterateHeaders`
/// (found 2026-07-28, in a local full-DB test run — not the pre-existing
/// http_util.zig flake, a real bug in this file, fixed by moving capture
/// earlier in every caller instead of doing it here).
///
/// Returns the `Set-Cookie` header value for the new session, or `null` if
/// minting failed (a response has NOT been sent in that case — every
/// caller must still send one). Shared core of `issueSessionAndRespond`
/// (a JSON body, for the widget's `fetch()`-driven login) and
/// `issueSessionAndRedirect` (a 302, for a browser-navigation login like
/// the OIDC callback) — both mint the exact same kind of session, they
/// just need to hand it back to the browser two different ways.
fn mintSessionCookie(ctx: *const ServerContext, account_id: i64, user_agent: ?[]const u8) !?[]const u8 {
    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const expires_at = now + 30 * 24 * 3600; // 30 days

    const session_id = web_sessions.create(ctx.pool, account_id, now, expires_at, user_agent, null) catch |err| {
        log.err("failed to create session for account {d}: {t}", .{ account_id, err });
        return null;
    };
    audit_log.record(ctx.pool, account_id, "auth.login", null, null);

    const secret = ctx.config.api_session_secret orelse {
        // Unreachable in practice: `Config.load` refuses to start the API
        // at all without this set (see config.zig) — this branch exists
        // only so the type system doesn't need an artificial `.?`.
        return null;
    };
    const token = auth.sign(ctx.allocator, session_id, secret) catch return null;
    defer ctx.allocator.free(token);

    return try std.fmt.allocPrint(
        ctx.allocator,
        "{s}={s}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000",
        .{ auth.cookie_name, token },
    );
}

fn issueSessionAndRespond(ctx: *const ServerContext, request: *http.Server.Request, account_id: i64, user_agent: ?[]const u8) !void {
    const cookie_value = (try mintSessionCookie(ctx, account_id, user_agent)) orelse {
        return respondError(request, .internal_server_error, "internal", "failed to create session");
    };
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

/// The OIDC callback's sibling to `issueSessionAndRespond`: the browser
/// itself navigated here (following the provider's redirect), so the
/// response is a 302 back into the app, not a JSON body for a `fetch()`
/// caller to parse.
fn issueSessionAndRedirect(ctx: *const ServerContext, request: *http.Server.Request, account_id: i64, user_agent: ?[]const u8, location: []const u8) !void {
    const cookie_value = (try mintSessionCookie(ctx, account_id, user_agent)) orelse {
        return respondError(request, .internal_server_error, "internal", "failed to create session");
    };
    defer ctx.allocator.free(cookie_value);

    try request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
            .{ .name = "set-cookie", .value = cookie_value },
        },
    });
}

// ---------------------------------------------------------------------------
// Generic OIDC login (`oauth_providers`, `oidc.zig`) — Authorization Code
// + PKCE against a provider stored in `oauth_providers`. The in-flight
// flow's PKCE verifier and anti-CSRF state travel in a short-lived,
// HMAC-signed cookie (`oidc_pkce_cookie_name`) between `.../start` and
// `.../callback` — no server-side session-in-progress table needed, same
// "we're the only ones who need to trust this" reasoning as
// `api/auth.zig`'s session token signing.
// ---------------------------------------------------------------------------

const oidc_pkce_cookie_name = "warden_oidc_pkce";
/// How long the PKCE cookie survives — generous for a real login flow
/// (Telegram's own authorization page, a user reading/approving it) but
/// still short enough that a leaked/replayed cookie is only ever a
/// narrow window.
const oidc_flow_max_age_seconds: i64 = 600;

/// Packs `provider_id:state:verifier` and HMAC-signs it — same
/// `<payload>.<base64url(HMAC-SHA256)>` shape as `api/auth.zig`'s session
/// tokens. `state`/`verifier` are themselves base64url (see `oidc.zig`'s
/// `generateState`/`generateVerifier`), so they can never contain `:` —
/// safe to split the payload on that character with no escaping needed.
fn signOidcFlowCookie(allocator: std.mem.Allocator, provider_id: i64, state: []const u8, verifier: []const u8, secret: []const u8) ![]const u8 {
    const payload = try std.fmt.allocPrint(allocator, "{d}:{s}:{s}", .{ provider_id, state, verifier });

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, payload, secret);
    var mac_b64_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(HmacSha256.mac_length)]u8 = undefined;
    const mac_b64 = std.base64.url_safe_no_pad.Encoder.encode(&mac_b64_buf, &mac);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ payload, mac_b64 });
}

const OidcFlowState = struct { provider_id: i64, state: []const u8, verifier: []const u8 };

/// `null` if `cookie_value` is malformed or its signature doesn't match —
/// every field borrows directly from `cookie_value`, no allocation.
fn verifyOidcFlowCookie(cookie_value: []const u8, secret: []const u8) ?OidcFlowState {
    const dot = std.mem.lastIndexOfScalar(u8, cookie_value, '.') orelse return null;
    const payload = cookie_value[0..dot];
    const given_mac_b64 = cookie_value[dot + 1 ..];

    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_mac, payload, secret);
    const b64_len = comptime std.base64.url_safe_no_pad.Encoder.calcSize(HmacSha256.mac_length);
    var expected_mac_b64_buf: [b64_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expected_mac_b64_buf, &expected_mac);

    if (given_mac_b64.len != b64_len) return null;
    var given_mac_b64_buf: [b64_len]u8 = undefined;
    @memcpy(&given_mac_b64_buf, given_mac_b64);
    if (!std.crypto.timing_safe.eql([b64_len]u8, expected_mac_b64_buf, given_mac_b64_buf)) return null;

    var parts = std.mem.splitScalar(u8, payload, ':');
    const provider_id_str = parts.next() orelse return null;
    const state = parts.next() orelse return null;
    const verifier = parts.next() orelse return null;
    if (parts.next() != null) return null; // exactly 3 fields

    const provider_id = std.fmt.parseInt(i64, provider_id_str, 10) catch return null;
    return .{ .provider_id = provider_id, .state = state, .verifier = verifier };
}

/// Our own callback URL for `provider_id` — reconstructed from the
/// inbound request's own `Host` header (trusted: production is one
/// reverse-proxied domain terminating TLS in front of this process, see
/// ARCHITECTURE.md §2) rather than a hardcoded config value, so this
/// works unmodified behind whatever domain Traefik/the proxy is actually
/// serving. Always `https://` — a provider's "Allowed URLs" registration
/// (BotFather, for Telegram) only ever lists the real production origin.
fn oidcRedirectUri(allocator: std.mem.Allocator, host: []const u8, provider_id: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "https://{s}/api/v1/auth/oidc/{d}/callback", .{ host, provider_id });
}

/// `GET /api/v1/auth/oidc/:providerId/start` — see API.md. Looks up the
/// provider, fetches its OIDC discovery document, generates a fresh PKCE
/// verifier/challenge and anti-CSRF state, stashes them in a signed
/// cookie, and 302s the browser to the provider's own authorization page.
fn handleOidcStart(ctx: *const ServerContext, request: *http.Server.Request, provider_id_str: []const u8) !void {
    if (!try checkRateLimit(ctx, request, ctx.auth_limiter, "oidc-start")) return;
    const host = findHeader(request, "host") orelse {
        return respondError(request, .bad_request, "bad_request", "missing host header");
    };
    const provider_id = std.fmt.parseInt(i64, provider_id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid provider id");
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = (oauth_providers.get(ctx.pool, arena, provider_id) catch |err| {
        log.err("oidc-start: failed to load provider {d}: {t}", .{ provider_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load provider");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such provider");
    };
    if (!provider.enabled) {
        return respondError(request, .not_found, "not_found", "no such provider");
    }

    const discovery = oidc.discover(arena, ctx.io, provider.issuer_url) catch |err| {
        log.err("oidc-start: discovery failed for provider {d} ({s}): {t}", .{ provider_id, provider.issuer_url, err });
        return respondError(request, .internal_server_error, "internal", "failed to reach the login provider");
    };

    const verifier = try oidc.generateVerifier(arena, ctx.io);
    const challenge = try oidc.challengeFromVerifier(arena, verifier);
    const state = try oidc.generateState(arena, ctx.io);
    const redirect_uri = try oidcRedirectUri(arena, host, provider_id);

    const auth_url = try std.fmt.allocPrint(
        arena,
        "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope=openid+profile&state={s}&code_challenge={s}&code_challenge_method=S256",
        .{
            discovery.authorization_endpoint,
            try http_util.encodeQueryComponent(arena, provider.client_id),
            try http_util.encodeQueryComponent(arena, redirect_uri),
            state,
            challenge,
        },
    );

    const secret = ctx.config.api_session_secret orelse {
        return respondError(request, .internal_server_error, "internal", "session signing not configured");
    };
    const cookie_value = try signOidcFlowCookie(arena, provider_id, state, verifier, secret);
    const cookie_header = try std.fmt.allocPrint(
        arena,
        "{s}={s}; Path=/api/v1/auth/oidc/; HttpOnly; Secure; SameSite=Lax; Max-Age={d}",
        .{ oidc_pkce_cookie_name, cookie_value, oidc_flow_max_age_seconds },
    );

    try request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = auth_url },
            .{ .name = "set-cookie", .value = cookie_header },
        },
    });
}

/// `GET /api/v1/auth/oidc/:providerId/callback` — see API.md. Verifies
/// the PKCE cookie set by `.../start` (signature, provider match, `state`
/// match against the query param), exchanges `code` at the provider's
/// token endpoint, verifies the returned `id_token` against the
/// provider's own JWKS (`oidc.verifyIdToken` — ES256 only, see that
/// file's module doc comment), then resolves/creates an account exactly
/// like the Telegram widget does.
///
/// Telegram-issuer special case: Telegram's own OIDC provider shares the
/// *same* user-id space as the bot platform itself (the `id` claim IS a
/// real Telegram user id) — so a login through this provider resolves to
/// a real `.telegram` identity, the same row the widget or the bot itself
/// would use for that person, not a separate "web-only" identity. A
/// genuinely external IdP (Google, some other org's SSO) has no
/// corresponding bot platform to map onto and would need the account-
/// *linking* path (`POST /api/v1/auth/link/:method/start` in API.md's
/// sketch) instead — not implemented yet, and out of scope for what this
/// provider needs, so this handler refuses any issuer it doesn't
/// recognize rather than guessing.
fn handleOidcCallback(ctx: *const ServerContext, request: *http.Server.Request, provider_id_str: []const u8, target: []const u8) !void {
    if (!try checkRateLimit(ctx, request, ctx.auth_limiter, "oidc-callback")) return;
    // Must happen before any body-touching call -- none needed for this
    // GET, but captured up front anyway to match the established
    // convention (see `issueSessionAndRespond`'s doc comment).
    const user_agent = findHeader(request, "user-agent");
    const host = findHeader(request, "host") orelse {
        return respondError(request, .bad_request, "bad_request", "missing host header");
    };
    const cookie_header = findHeader(request, "cookie") orelse "";

    const provider_id = std.fmt.parseInt(i64, provider_id_str, 10) catch {
        return respondError(request, .bad_request, "bad_request", "invalid provider id");
    };
    const code = queryParam(target, "code") orelse {
        return respondError(request, .bad_request, "bad_request", "missing code");
    };
    const given_state = queryParam(target, "state") orelse {
        return respondError(request, .bad_request, "bad_request", "missing state");
    };

    const secret = ctx.config.api_session_secret orelse {
        return respondError(request, .internal_server_error, "internal", "session signing not configured");
    };
    const pkce_cookie_value = parseCookieValue(cookie_header, oidc_pkce_cookie_name) orelse {
        return respondError(request, .bad_request, "bad_request", "missing or expired login flow cookie");
    };
    const flow = verifyOidcFlowCookie(pkce_cookie_value, secret) orelse {
        return respondError(request, .bad_request, "bad_request", "invalid login flow cookie");
    };
    if (flow.provider_id != provider_id) {
        return respondError(request, .bad_request, "bad_request", "provider mismatch");
    }
    if (!std.mem.eql(u8, flow.state, given_state)) {
        return respondError(request, .bad_request, "bad_request", "state mismatch");
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = (oauth_providers.get(ctx.pool, arena, provider_id) catch |err| {
        log.err("oidc-callback: failed to load provider {d}: {t}", .{ provider_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to load provider");
    }) orelse {
        return respondError(request, .not_found, "not_found", "no such provider");
    };
    if (!provider.enabled) {
        return respondError(request, .not_found, "not_found", "no such provider");
    }
    // See this function's doc comment -- only Telegram's own OIDC issuer
    // is understood right now.
    if (std.mem.indexOf(u8, provider.issuer_url, "telegram") == null) {
        log.err("oidc-callback: provider {d} has an unsupported (non-Telegram) issuer {s}", .{ provider_id, provider.issuer_url });
        return respondError(request, .internal_server_error, "internal", "this login provider isn't supported yet");
    }

    const discovery = oidc.discover(arena, ctx.io, provider.issuer_url) catch |err| {
        log.err("oidc-callback: discovery failed for provider {d}: {t}", .{ provider_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to reach the login provider");
    };

    const redirect_uri = try oidcRedirectUri(arena, host, provider_id);
    const form_body = try std.fmt.allocPrint(
        arena,
        "grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}",
        .{
            try http_util.encodeQueryComponent(arena, code),
            try http_util.encodeQueryComponent(arena, redirect_uri),
            try http_util.encodeQueryComponent(arena, flow.verifier),
        },
    );

    const basic_auth_raw = try std.fmt.allocPrint(arena, "{s}:{s}", .{ provider.client_id, provider.client_secret });
    const basic_auth_b64_buf = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(basic_auth_raw.len));
    const basic_auth_b64 = std.base64.standard.Encoder.encode(basic_auth_b64_buf, basic_auth_raw);
    const authorization_header = try std.fmt.allocPrint(arena, "Basic {s}", .{basic_auth_b64});

    var client: http.Client = .{ .allocator = arena, .io = ctx.io };
    const token_response_body = http_util.postRaw(
        &client,
        arena,
        discovery.token_endpoint,
        "application/x-www-form-urlencoded",
        &.{.{ .name = "authorization", .value = authorization_header }},
        form_body,
    ) catch |err| {
        log.err("oidc-callback: token exchange failed for provider {d}: {t}", .{ provider_id, err });
        return respondError(request, .unauthorized, "invalid_login", "login failed");
    };

    const TokenResponse = struct { id_token: []const u8 };
    const token_response = std.json.parseFromSliceLeaky(TokenResponse, arena, token_response_body, .{ .ignore_unknown_fields = true }) catch {
        log.err("oidc-callback: malformed token response for provider {d}", .{provider_id});
        return respondError(request, .internal_server_error, "internal", "malformed response from login provider");
    };

    const jwks = oidc.fetchJwks(arena, ctx.io, discovery.jwks_uri) catch |err| {
        log.err("oidc-callback: jwks fetch failed for provider {d}: {t}", .{ provider_id, err });
        return respondError(request, .internal_server_error, "internal", "failed to verify login");
    };

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const claims = oidc.verifyIdToken(arena, token_response.id_token, jwks, discovery.issuer, provider.client_id, now, 60) catch |err| {
        log.warn("oidc-callback: id token verification failed for provider {d}: {t}", .{ provider_id, err });
        return respondError(request, .unauthorized, "invalid_login", "login verification failed");
    };

    const display_name = claims.name orelse claims.preferred_username orelse claims.id;
    const account_id = (try resolveOrCreateAccountForLogin(ctx, request, .telegram, claims.id, display_name, claims.preferred_username, claims.picture, now)) orelse return;

    return issueSessionAndRedirect(ctx, request, account_id, user_agent, "/");
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
        .briefing_interval_seconds = 86_400,
        .system_prompt = null,
        .searxng_url = null,
        .whisper_url = null,
        .embeddings_url = null,
        .embeddings_api_key = "",
        .embeddings_model = "text-embedding-3-small",
        .llm_owner_only = true,
        .llm_show_thinking = false,
        .llm_streaming = true,
        .llm_vision_enabled = true,
        .llm_documents_enabled = true,
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

/// `true` if `key` is under `limiter`'s budget (and this call counts
/// toward it) -- `false` means a `429` was already sent and the caller
/// should return immediately. `limiter == null` (every test that doesn't
/// specifically exercise rate limiting, see `ServerContext.auth_limiter`'s
/// doc comment) always allows.
fn checkRateLimit(ctx: *const ServerContext, request: *http.Server.Request, limiter: ?*rate_limit.Limiter, key: []const u8) !bool {
    const l = limiter orelse return true;
    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    if (l.allow(key, now)) return true;
    try respondError(request, .too_many_requests, "too_many_requests", "rate limit exceeded, try again shortly");
    return false;
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
