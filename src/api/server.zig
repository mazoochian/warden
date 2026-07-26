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

    var request = http_server.receiveHead() catch |err| {
        // A closed/reset connection before any bytes arrive is routine
        // (browsers/load balancers probe and disconnect) — not worth
        // logging at warn.
        log.debug("failed to receive request head: {t}", .{err});
        return;
    };

    router.dispatch(item.ctx, &request) catch |err| {
        log.warn("request handling failed for {s}: {t}", .{ request.head.target, err });
        request.respond("{\"error\":{\"code\":\"internal\",\"message\":\"internal error\"}}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch {};
    };
}

const testing = std.testing;
const Db = @import("../store/db.zig").Db;
const PgPool = store_pool.PgPool;
const test_support = @import("../store/test_support.zig");
const identities = @import("../store/identities.zig");

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
