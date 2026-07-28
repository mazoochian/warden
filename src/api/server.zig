//! HTTP+WebSocket accept loop for warden-ui's API (see
//! /home/armin/claude/warden-ui/ARCHITECTURE.md §1) — built on
//! `std.http.Server` (confirmed present in this Zig toolchain, including
//! native WebSocket upgrade support), not a hand-rolled HTTP parser.
//!
//! Mirrors `worker_pool.zig`'s existing `WorkerPool` shape (one accept
//! loop feeding a bounded pool of real OS threads) rather than inventing
//! new concurrency machinery — same reasoning as the per-connector
//! message-processing pools already in `main.zig`: a slow/stuck API
//! request should occupy one worker, never the whole API surface, and
//! `accept()`'s own loop should never itself block on request handling.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const WorkerPool = @import("../worker_pool.zig").WorkerPool;
const store_pool = @import("../store/pool.zig");
const config_mod = @import("../config.zig");
const iface = @import("../platform/interface.zig");
const bot_view = @import("bot_view.zig");
const rate_limit = @import("rate_limit.zig");
const router = @import("router.zig");
const log = @import("../log.zig").scoped("api");

/// Everything a request handler needs — deliberately a plain passthrough
/// bundle, same `ptr`-bag convention as `menu.zig`'s `ActionContext`
/// (never reached into directly by `server.zig`'s own accept-loop code,
/// just carried from `main.zig`'s startup through to `router.zig`'s
/// handlers).
pub const ServerContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    pool: *store_pool.PgPool,
    config: *const config_mod.Config,
    /// Live platform connectors, for handlers that need to check *current*
    /// platform-admin status (Phase 4's group settings) rather than
    /// anything cached in the DB — see `ARCHITECTURE.md` §7's "Group
    /// admin" tier. Defaults to empty so existing tests that don't touch
    /// group-admin-gated endpoints don't need updating.
    connectors: []const iface.Connector = &.{},
    /// Phase 6 "Bot View" -- `null` until `main.zig` hands in the
    /// process-lifetime broadcaster it also feeds from the message-
    /// recording tap. Optional (not a plain pointer) so existing tests that
    /// never touch Bot View's endpoints don't need updating; those
    /// endpoints themselves treat `null` as "feature unavailable" (500),
    /// which should never actually happen outside tests since `main.zig`
    /// always sets this before starting the API server.
    bot_view: ?*bot_view.Broadcaster = null,
    /// Phase 7 hardening (see `rate_limit.zig`'s doc comment). `null` in
    /// every test that doesn't specifically exercise rate limiting means
    /// "not limited" (fail open), not "feature unavailable" -- unlike
    /// `bot_view` above, a missing limiter is a safe default, not a
    /// broken one. `auth_limiter` covers the anonymous auth-flow
    /// endpoints (dev-login, OIDC start/callback); `bot_view_send_limiter`
    /// covers `POST /api/v1/bot-view/send`, keyed per-account since that
    /// endpoint is already authenticated by the time it runs.
    auth_limiter: ?*rate_limit.Limiter = null,
    bot_view_send_limiter: ?*rate_limit.Limiter = null,
};

const ConnectionItem = struct {
    ctx: *const ServerContext,
    stream: Io.net.Stream,
};

/// Binds `port` and runs the accept loop forever — never returns under
/// normal operation, same "long-lived, no shutdown path" shape as
/// `main.zig`'s connector poll loops and `WorkerPool` itself. Thin
/// wrapper around `bind`+`serve`, split apart so a test can bind port `0`
/// (kernel-assigned) and read back the real port before starting `serve`
/// on its own thread — see this file's tests.
pub fn run(ctx: *const ServerContext, port: u16, worker_count: usize) !void {
    var listener = try bind(ctx.io, port);
    defer listener.deinit(ctx.io);
    serve(ctx, &listener, worker_count);
}

pub fn bind(io: Io, port: u16) !Io.net.Server {
    var address = try Io.net.IpAddress.parseIp4("0.0.0.0", port);
    return address.listen(io, .{ .reuse_address = true });
}

/// The accept loop itself — never returns under normal operation.
pub fn serve(ctx: *const ServerContext, listener: *Io.net.Server, worker_count: usize) void {
    const workers = WorkerPool(ConnectionItem).init(ctx.allocator, ctx.io, worker_count, handleConnection) catch |err| {
        log.err("failed to start worker pool: {t}", .{err});
        return;
    };

    log.info("listening ({d} worker(s))", .{worker_count});
    while (true) {
        const stream = listener.accept(ctx.io) catch |err| {
            log.warn("accept failed: {t}", .{err});
            continue;
        };
        workers.push(.{ .ctx = ctx, .stream = stream }) catch |err| {
            log.warn("failed to enqueue connection: {t}", .{err});
            stream.close(ctx.io);
        };
    }
}

/// One request/response cycle over one accepted TCP connection — no
/// keep-alive/pipelining across multiple requests yet (the simplest
/// correct thing; see `ROADMAP.md`'s Phase 0 notes for revisiting this if
/// connection-per-request overhead ever actually matters at warden-ui's
/// traffic scale, which is unlikely to be the bottleneck any time soon).
fn handleConnection(item: ConnectionItem) void {
    defer item.stream.close(item.ctx.io);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = item.stream.reader(item.ctx.io, &recv_buf);
    var stream_writer = item.stream.writer(item.ctx.io, &send_buf);
    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    const started = Io.Timestamp.now(item.ctx.io, .real);
    var request = http_server.receiveHead() catch |err| {
        // A closed/reset connection before any bytes arrive is routine
        // (browsers/load balancers probe and disconnect) — not worth
        // logging at warn.
        log.debug("failed to receive request head: {t}", .{err});
        return;
    };
    // One line per request -- method, path, outcome, elapsed -- through
    // the same tabular logger every other subsystem uses (Phase 7's
    // "production observability" item), not a second logging convention.
    // The individual handler-level `log.err`/`log.warn` calls already
    // scattered through `router.zig` stay as-is for the *why* on failure;
    // this is just the *that a request happened at all* line, since none
    // existed before at any level besides "receive/handling failed".
    const method_name = @tagName(request.head.method);
    const target = item.ctx.allocator.dupe(u8, request.head.target) catch request.head.target;
    defer if (target.ptr != request.head.target.ptr) item.ctx.allocator.free(target);

    const dispatch_result = router.dispatch(item.ctx, &request);
    if (dispatch_result) |_| {
        const elapsed_ms = @divTrunc(Io.Timestamp.now(item.ctx.io, .real).toNanoseconds() - started.toNanoseconds(), std.time.ns_per_ms);
        log.debug("{s} {s} ok {d}ms", .{ method_name, target, elapsed_ms });
    } else |err| {
        log.warn("request handling failed for {s} {s}: {t}", .{ method_name, target, err });
        request.respond("{\"error\":{\"code\":\"internal\",\"message\":\"internal error\"}}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch {};
    }
}

const testing = std.testing;
const Db = @import("../store/db.zig").Db;
const PgPool = store_pool.PgPool;
const test_support = @import("../store/test_support.zig");
const identities = @import("../store/identities.zig");
const chats_store = @import("../store/chats.zig");

fn testConfig() config_mod.Config {
    return .{
        .telegram_bot_token = "x",
        .owners = &.{},
        .postgres_dsn = "postgresql:///warden_test",
        .postgres_pool_size = 1,
        .postgres_acquire_timeout_seconds = 30,
        .postgres_statement_timeout_seconds = 30,
        .workers_per_platform = 2,
        .retention_messages = 20_000,
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
        .llm_streaming = false,
        .api_session_secret = "test-secret-for-server-zig-tests",
        .api_dev_login = true,
    };
}

fn readBody(response: *http.Client.Response, allocator: std.mem.Allocator) ![]const u8 {
    var buf: [256]u8 = undefined;
    const reader = response.reader(&buf);
    return reader.allocRemaining(allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
}

fn findSetCookie(head: http.Client.Response.Head) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) return h.value;
    }
    return null;
}

// Exercises the real accept loop over an actual loopback TCP socket --
// `bind`/`serve` are called directly (not `run`, and never through
// `main()`/`Config.load`), so this needs no Telegram bot token/real
// credentials at all, sidestepping the one reason this couldn't be
// smoke-tested by just running the real bot locally tonight (a second
// live long-poller on the same token would 409-conflict with the
// already-deployed production instance).
//
// Everything the detached `serve` thread below touches (`ctx`, `pool`,
// `db`, `listener`) is heap-allocated via `page_allocator` and
// deliberately never freed/closed/joined -- the exact same tradeoff
// `worker_pool.zig`'s own tests already establish and justify: a
// stack-local value here would be a real use-after-free the moment the
// accept loop's thread wakes up after this function returns, since
// there is no shutdown path for `serve` (by design, same as every other
// long-lived loop in this codebase).
test "full HTTP round trip: unauthenticated session, dev-login, authenticated session, logout" {
    const gpa = std.heap.page_allocator;

    const db = try gpa.create(Db);
    db.* = try test_support.openTestDb(gpa) orelse return error.SkipZigTest;

    const pool = try gpa.create(PgPool);
    pool.* = try PgPool.wrapForTest(gpa, testing.io, db);

    const identity_id = try identities.getOrCreateMinimal(pool, .telegram, "999", "Test User", null, false, 1000);

    const config = try gpa.create(config_mod.Config);
    config.* = testConfig();

    const ctx = try gpa.create(ServerContext);
    ctx.* = .{ .allocator = gpa, .io = testing.io, .pool = pool, .config = config };

    const listener = try gpa.create(Io.net.Server);
    listener.* = try bind(testing.io, 0);
    const port = listener.socket.address.getPort();

    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2) });
    thread.detach();

    var client: http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;

    // 1. Unauthenticated session check.
    {
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/session", .{port});
        var req = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
        const body = try readBody(&response, testing.allocator);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"authenticated\":false") != null);
    }

    // 2. Dev-login — mints a real session and returns it as a cookie.
    var cookie: []const u8 = undefined;
    {
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/dev-login", .{port});
        var payload_buf: [64]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buf, "{{\"identity_id\":{d}}}", .{identity_id});
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try req.connection.?.flush();
        const response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);

        const raw_cookie = findSetCookie(response.head) orelse return error.TestExpectedValue;
        const semi = std.mem.indexOfScalar(u8, raw_cookie, ';') orelse raw_cookie.len;
        cookie = try testing.allocator.dupe(u8, raw_cookie[0..semi]);
    }
    defer testing.allocator.free(cookie);

    // 3. Authenticated session check, using the cookie from step 2.
    {
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/session", .{port});
        var req = try client.request(.GET, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "cookie", .value = cookie }},
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
        const body = try readBody(&response, testing.allocator);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"authenticated\":true") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"account_id\":") != null);
    }

    // 4. Logout — revokes the session.
    {
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/logout", .{port});
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "cookie", .value = cookie }},
        });
        defer req.deinit();
        // POST always asserts `requestHasBody()` even for a zero-length
        // body -- unlike GET, `sendBodiless()` isn't valid here (found the
        // hard way: `assert(!r.method.requestHasBody())` inside
        // `std.http.Client.Request.sendBodilessUnflushed` aborts otherwise).
        req.transfer_encoding = .{ .content_length = 0 };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.end();
        try req.connection.?.flush();
        const response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
    }

    // 5. Session check again with the same (now-revoked) cookie — back to unauthenticated.
    {
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/session", .{port});
        var req = try client.request(.GET, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "cookie", .value = cookie }},
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
        const body = try readBody(&response, testing.allocator);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "\"authenticated\":false") != null);
    }
}

/// Stands in for a real platform connector -- just enough of `iface.Connector`
/// for Bot View's send endpoint (`platform`/`poll`/`sendMessage`; every other
/// vtable entry is optional and left null). Same shape as `auth.zig`'s own
/// `StubConnector`.
const BotViewStubConnector = struct {
    /// Used for `sent_messages`' own storage -- deliberately *not* the
    /// `allocator` a `sendMessage` call is given, which is the calling
    /// handler's own short-lived per-request arena (freed the moment that
    /// handler returns). Storing into/appending text pointing into that
    /// arena would be a real use-after-free the moment a test reads
    /// `sent_messages` back afterward -- found the hard way, via a real
    /// segfault, before this field existed.
    store_allocator: std.mem.Allocator,
    sent_messages: std.ArrayList([]const u8) = .empty,

    fn connector(self: *BotViewStubConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
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
        _ = allocator;
        _ = chat_id;
        _ = reply_to_message_id;
        const self: *BotViewStubConnector = @ptrCast(@alignCast(ptr));
        const owned_text = self.store_allocator.dupe(u8, text) catch return;
        self.sent_messages.append(self.store_allocator, owned_text) catch {};
    }
};

fn devLogin(client: *http.Client, port: u16, identity_id: i64) ![]const u8 {
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/dev-login", .{port});
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"identity_id\":{d}}}", .{identity_id});
    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();
    const response = try req.receiveHead(&.{});
    try testing.expectEqual(.ok, response.head.status);

    const raw_cookie = findSetCookie(response.head) orelse return error.TestExpectedValue;
    const semi = std.mem.indexOfScalar(u8, raw_cookie, ';') orelse raw_cookie.len;
    return try testing.allocator.dupe(u8, raw_cookie[0..semi]);
}

/// Reads exactly one WebSocket frame's payload off `reader`, asserting it's
/// a text frame. `reader` is the raw stream reader -- server frames are
/// never masked (only client-to-server frames are, per RFC 6455), so no
/// unmasking is needed here, unlike `Server.WebSocket.readSmallMessage`.
fn readOneWsTextFrame(allocator: std.mem.Allocator, reader: *Io.Reader) ![]u8 {
    const header = try reader.takeArray(2);
    const opcode = header[0] & 0x0f;
    try testing.expectEqual(@as(u8, 1), opcode);
    const len7: u8 = header[1] & 0x7f;
    const len: usize = switch (len7) {
        126 => try reader.takeInt(u16, .big),
        127 => @intCast(try reader.takeInt(u64, .big)),
        else => len7,
    };
    const payload = try reader.take(len);
    return try allocator.dupe(u8, payload);
}

// Same "everything heap-allocated via page_allocator, deliberately never
// freed" tradeoff as the round-trip test above -- `serve`'s thread has no
// shutdown path, so nothing it might still touch can be stack-local or
// torn down when this function returns.
test "bot view: WS is owner-only and delivers a published event; send posts through the connector" {
    const gpa = std.heap.page_allocator;

    const db = try gpa.create(Db);
    db.* = try test_support.openTestDb(gpa) orelse return error.SkipZigTest;
    const pool = try gpa.create(PgPool);
    pool.* = try PgPool.wrapForTest(gpa, testing.io, db);

    const owner_identity_id = try identities.getOrCreateMinimal(pool, .telegram, "111", "Owner", null, false, 1000);
    const other_identity_id = try identities.getOrCreateMinimal(pool, .telegram, "222", "NotOwner", null, false, 1000);
    const chat_id = try chats_store.upsertChat(pool, .telegram, "chat-1", "group", "Test Chat");

    const config = try gpa.create(config_mod.Config);
    config.* = testConfig();
    config.owners = &.{.{ .platform = .telegram, .owner_id = "111" }};

    const stub = try gpa.create(BotViewStubConnector);
    stub.* = .{ .store_allocator = gpa };
    const connectors = try gpa.dupe(iface.Connector, &.{stub.connector()});

    const broadcaster = try gpa.create(bot_view.Broadcaster);
    broadcaster.* = bot_view.Broadcaster.init(gpa, testing.io);

    const ctx = try gpa.create(ServerContext);
    ctx.* = .{ .allocator = gpa, .io = testing.io, .pool = pool, .config = config, .connectors = connectors, .bot_view = broadcaster };

    const listener = try gpa.create(Io.net.Server);
    listener.* = try bind(testing.io, 0);
    const port = listener.socket.address.getPort();

    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2) });
    thread.detach();

    var client: http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const owner_cookie = try devLogin(&client, port, owner_identity_id);
    defer testing.allocator.free(owner_cookie);
    const other_cookie = try devLogin(&client, port, other_identity_id);
    defer testing.allocator.free(other_cookie);

    // Non-owner: forbidden, even before any WS upgrade is attempted (the
    // role check runs before `upgradeRequested` in `handleBotViewWs`).
    {
        var url_buf: [160]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/bot-view/ws?chat_id={d}", .{ port, chat_id });
        var req = try client.request(.GET, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "cookie", .value = other_cookie }},
        });
        defer req.deinit();
        try req.sendBodiless();
        const response = try req.receiveHead(&.{});
        try testing.expectEqual(.forbidden, response.head.status);
    }

    // Non-owner: send-as-bot is forbidden too.
    {
        var url_buf: [160]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/bot-view/send", .{port});
        const payload = try std.fmt.allocPrint(testing.allocator, "{{\"chat_id\":{d},\"text\":\"hi\"}}", .{chat_id});
        defer testing.allocator.free(payload);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "cookie", .value = other_cookie },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try req.connection.?.flush();
        const response = try req.receiveHead(&.{});
        try testing.expectEqual(.forbidden, response.head.status);
        try testing.expectEqual(@as(usize, 0), stub.sent_messages.items.len);
    }

    // Owner: real WS handshake over a raw socket (`std.http.Client` has no
    // WebSocket support), then a server-side `publish` must arrive as a
    // JSON text frame.
    {
        const host_name = try Io.net.HostName.init("127.0.0.1");
        const stream = try host_name.connect(testing.io, port, .{ .mode = .stream });
        defer stream.close(testing.io);

        var send_buf: [1024]u8 = undefined;
        var stream_writer = stream.writer(testing.io, &send_buf);
        const path = try std.fmt.allocPrint(testing.allocator, "/api/v1/bot-view/ws?chat_id={d}", .{chat_id});
        defer testing.allocator.free(path);
        try stream_writer.interface.print(
            "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nCookie: {s}\r\n\r\n",
            .{ path, owner_cookie },
        );
        try stream_writer.interface.flush();

        var recv_buf: [1024]u8 = undefined;
        var stream_reader = stream.reader(testing.io, &recv_buf);
        // `takeDelimiterExclusive` does NOT consume the delimiter itself
        // (confirmed reading the stdlib source -- it tosses only the
        // returned, delimiter-excluded slice), so it desyncs a multi-line
        // parse: the next call would immediately see the previous line's
        // leftover '\n' and return an empty slice without ever advancing
        // into the following header line. `takeDelimiterInclusive`
        // consumes through and past the delimiter, which is what a
        // line-by-line parse actually needs.
        const status_line = try stream_reader.interface.takeDelimiterInclusive('\n');
        try testing.expect(std.mem.indexOf(u8, status_line, "101") != null);
        while (true) {
            const line = try stream_reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
        }

        // The 101 response completing (just parsed above) only proves the
        // handshake itself is done, not that `handleBotViewWs`'s own
        // `subscribe` call (a couple lines later, server-side) has run yet
        // -- give it a moment before publishing. A publish issued before
        // `subscribe` completes would simply never be delivered (same as
        // real production pub/sub semantics, no replay/queueing for a
        // not-yet-registered subscriber), so this is a real, if generous,
        // wait rather than an arbitrary sleep.
        Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
        broadcaster.publish(chat_id, "alice", "hello there", 12345);

        const payload = try readOneWsTextFrame(testing.allocator, &stream_reader.interface);
        defer testing.allocator.free(payload);
        try testing.expect(std.mem.indexOf(u8, payload, "hello there") != null);
        try testing.expect(std.mem.indexOf(u8, payload, "\"sender\":\"alice\"") != null);
        var buf: [32]u8 = undefined;
        const chat_id_str = try std.fmt.bufPrint(&buf, "\"chat_id\":{d}", .{chat_id});
        try testing.expect(std.mem.indexOf(u8, payload, chat_id_str) != null);
    }

    // Closing the raw socket above only unblocks *this* thread's next
    // step -- `handleBotViewWs`'s own reader loop (on a worker-pool
    // thread) needs a moment to notice the close, join its writer thread,
    // and return, before that worker's stack-local buffers (`server.zig`'s
    // `handleConnection`) are safe to consider done with this connection.
    // A generous wait here, not a synchronization primitive, since there's
    // no handle back to that specific worker thread from a test.
    Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};

    // Owner: send-as-bot calls straight through to the connector and
    // audit-logs the action.
    {
        var url_buf: [160]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/bot-view/send", .{port});
        const payload = try std.fmt.allocPrint(testing.allocator, "{{\"chat_id\":{d},\"text\":\"reply from the owner\"}}", .{chat_id});
        defer testing.allocator.free(payload);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "cookie", .value = owner_cookie },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try req.connection.?.flush();
        const response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
    }

    // Give the send above a moment to land on the stub before asserting --
    // `handleBotViewSend` finishes (and the response is sent) synchronously
    // with the `sendMessage` call itself, so this is really just here for
    // clarity, not because of any real race.
    try testing.expectEqual(@as(usize, 1), stub.sent_messages.items.len);
    try testing.expectEqualStrings("reply from the owner", stub.sent_messages.items[0]);
}
