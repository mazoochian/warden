//! HTTP+WebSocket accept loop for the web API (see docs/web-api.md), built
//! on `std.http.Server` including its native WebSocket upgrade.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const WorkerPool = @import("../worker_pool.zig").WorkerPool;
const store_pool = @import("../store/pool.zig");
const config_mod = @import("../config.zig");
const iface = @import("../platform/interface.zig");
const telegram_user_platform = @import("../platform/telegram/user_connector.zig");
const reply_drafts = @import("../features/reply_drafts.zig");
const bot_view = @import("bot_view.zig");
const llm = @import("../llm/provider.zig");
const rate_limit = @import("rate_limit.zig");
const router = @import("router.zig");
const log = @import("../log.zig").scoped("api");

/// Everything a request handler needs — deliberately a plain passthrough
/// bundle.
pub const ServerContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    pool: *store_pool.PgPool,
    config: *const config_mod.Config,
    /// Live platform connectors, for handlers that need to check *current*
    /// platform-admin status (the group settings) rather than anything cached in
    /// the DB — see `ARCHITECTURE.md` §7's "Group admin" tier.
    connectors: []const iface.Connector = &.{},
    /// "Bot View" -- `null` until `main.zig` hands in the process- lifetime
    /// broadcaster it also feeds from the message- recording tap.
    bot_view: ?*bot_view.Broadcaster = null,
    auth_limiter: ?*rate_limit.Limiter = null,
    bot_view_send_limiter: ?*rate_limit.Limiter = null,
    /// The personal-account (TDLib) connector, if `WARDEN_TELEGRAM_USER_*` is
    /// configured — `null` otherwise.
    telegram_user: ?*telegram_user_platform.TelegramUserConnector = null,
    /// The bot's LLM provider — needed by the `/api/v1/telegram-user/
    /// chats/summarize` endpoint (see `router.zig`'s `handleTelegramUser
    /// SummarizeChat`).
    llm_provider: ?llm.Provider = null,
    pending_drafts: ?*reply_drafts.PendingDrafts = null,
};

const ConnectionItem = struct {
    ctx: *const ServerContext,
    stream: Io.net.Stream,
};

/// Binds `port` and runs the accept loop forever — never returns under normal
/// operation.
pub fn run(ctx: *const ServerContext, port: u16, worker_count: usize) !void {
    var listener = try bind(ctx.io, port);
    defer listener.deinit(ctx.io);
    serve(ctx, &listener, worker_count, null);
}

pub fn bind(io: Io, port: u16) !Io.net.Server {
    var address = try Io.net.IpAddress.parseIp4("0.0.0.0", port);
    return address.listen(io, .{ .reuse_address = true });
}

/// Cooperative stop signal for `serve`.
pub const Stop = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn shouldStop(self: *const Stop) bool {
        return self.flag.load(.acquire);
    }

    /// Signals `serve` to stop and then makes one throwaway connection to `port`
    /// purely to wake the blocked `accept`.
    pub fn shutdown(self: *Stop, io: Io, port: u16) void {
        self.flag.store(true, .release);
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
        const stream = address.connect(io, .{ .mode = .stream }) catch return;
        stream.close(io);
    }
};

/// The accept loop itself — never returns under normal operation, and only
/// returns at all when handed a `Stop` (see that type).
pub fn serve(ctx: *const ServerContext, listener: *Io.net.Server, worker_count: usize, stop: ?*const Stop) void {
    const workers = WorkerPool(ConnectionItem).init(ctx.allocator, ctx.io, worker_count, handleConnection) catch |err| {
        log.err("failed to start worker pool: {t}", .{err});
        return;
    };
    defer if (stop != null) workers.deinit();

    log.info("listening ({d} worker(s))", .{worker_count});
    while (true) {
        if (stop) |s| if (s.shouldStop()) return;
        const stream = listener.accept(ctx.io) catch |err| {
            if (stop) |s| if (s.shouldStop()) return;
            log.warn("accept failed: {t}", .{err});
            continue;
        };
        // Checked again after `accept` returns because the connection that just
        // arrived is usually `Stop.shutdown`'s own throwaway one.
        if (stop) |s| if (s.shouldStop()) {
            stream.close(ctx.io);
            return;
        };
        workers.push(.{ .ctx = ctx, .stream = stream }) catch |err| {
            log.warn("failed to enqueue connection: {t}", .{err});
            stream.close(ctx.io);
        };
    }
}

/// One request/response cycle over one accepted TCP connection — no keep-
/// alive/pipelining across multiple requests yet.
fn handleConnection(item: ConnectionItem) void {
    defer item.stream.close(item.ctx.io);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = item.stream.reader(item.ctx.io, &recv_buf);
    var stream_writer = item.stream.writer(item.ctx.io, &send_buf);
    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    const started = Io.Timestamp.now(item.ctx.io, .real);
    var request = http_server.receiveHead() catch |err| {
        // A closed/reset connection before any bytes arrive is routine (browsers/load
        // balancers probe and disconnect) — not worth logging at warn.
        log.debug("failed to receive request head: {t}", .{err});
        return;
    };
    // Two upstream asserts in `std.http.Server` turn a malformed request head
    // into a process abort, and `-Doptimize=ReleaseSafe`.
    if (request.head.method.requestHasBody() and
        request.head.transfer_encoding == .none and request.head.content_length == null)
    {
        respondFatalHeadError(&request, .length_required, "length_required", "content-length or transfer-encoding is required");
        return;
    }
    if (request.head.expect != null) {
        request.writeExpectContinue() catch |err| switch (err) {
            error.HttpExpectationFailed => {
                respondFatalHeadError(&request, .expectation_failed, "expectation_failed", "unsupported expect header");
                return;
            },
            error.WriteFailed => {
                log.debug("failed to write 100-continue", .{});
                return;
            },
        };
        stream_writer.interface.flush() catch |err| {
            log.debug("failed to flush 100-continue: {t}", .{err});
            return;
        };
    }

    // One line per request -- method, path, outcome, elapsed.
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

/// A refusal sent before any handler runs, for a request head this server
/// can't safely process at all.
fn respondFatalHeadError(request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) void {
    // Clearing `expect` is what makes the 417 above actually reach the client.
    request.head.expect = null;

    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(buf[0..], "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ code, message }) catch return;
    log.warn("rejected request head: {s}", .{code});
    request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {};
}

const testing = std.testing;
const Db = @import("../store/db.zig").Db;
const PgPool = store_pool.PgPool;
const test_support = @import("../store/test_support.zig");
const identities = @import("../store/identities.zig");
const chats_store = @import("../store/chats.zig");
const bot_admins = @import("../store/bot_admins.zig");
const convert = @import("../features/convert.zig");
const notes_store = @import("../store/notes.zig");

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
        .briefing_interval_seconds = 86_400,
        .system_prompt = null,
        .searxng_url = null,
        .whisper_url = null,
        .embeddings_url = null,
        .embeddings_api_key = "",
        .embeddings_model = "text-embedding-3-small",
        .llm_owner_only = true,
        .llm_show_thinking = false,
        .llm_streaming = false,
        .llm_vision_enabled = true,
        .llm_documents_enabled = true,
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

// Exercises the real accept loop over an actual loopback TCP socket.
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

    var stop: Stop = .{};
    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2), &stop });
    // Registered before the request-side defers below so it runs after them: the
    // client is finished with the server by the time the loop is told to stop.
    defer {
        stop.shutdown(testing.io, port);
        thread.join();
    }

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
        // POST always asserts `requestHasBody()` even for a zero-length body --
        // unlike GET, `sendBodiless()` isn't valid here.
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

/// Stands in for a real platform connector.
const BotViewStubConnector = struct {
    /// Used for `sent_messages`' own storage -- deliberately *not* the
    /// `allocator` a `sendMessage` call is given.
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

/// Reads exactly one WebSocket frame's payload off `reader`, asserting it's a
/// text frame.
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
// freed" tradeoff as the round-trip test above.
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

    var stop: Stop = .{};
    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2), &stop });
    // Registered before the request-side defers below so it runs after them: the
    // client is finished with the server by the time the loop is told to stop.
    defer {
        stop.shutdown(testing.io, port);
        thread.join();
    }

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
    // WebSocket support).
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
        // `takeDelimiterExclusive` does NOT consume the delimiter itself.
        const status_line = try stream_reader.interface.takeDelimiterInclusive('\n');
        try testing.expect(std.mem.indexOf(u8, status_line, "101") != null);
        while (true) {
            const line = try stream_reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
        }

        // The 101 response completing (just parsed above) only proves the handshake
        // itself is done.
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

    // Closing the raw socket above only unblocks *this* thread's next step.
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

    // Give the send above a moment to land on the stub before asserting.
    try testing.expectEqual(@as(usize, 1), stub.sent_messages.items.len);
    try testing.expectEqualStrings("reply from the owner", stub.sent_messages.items[0]);
}

// Regression test for a real bug (found by hand testing the web panel's
// Convert page against a real browser).
test "convert endpoint: a real multipart POST whose body exceeds one buffered read still finds the file part" {
    const gpa = std.heap.page_allocator;

    // This posts a real txt -> md conversion, which shells out to pandoc (see
    // `features/convert.zig`).
    {
        var probe = std.heap.ArenaAllocator.init(testing.allocator);
        defer probe.deinit();
        if (!convert.binaryAvailable(probe.allocator(), testing.io, &.{ "pandoc", "--version" })) return error.SkipZigTest;
    }

    const db = try gpa.create(Db);
    db.* = try test_support.openTestDb(gpa) orelse return error.SkipZigTest;
    const pool = try gpa.create(PgPool);
    pool.* = try PgPool.wrapForTest(gpa, testing.io, db);

    const identity_id = try identities.getOrCreateMinimal(pool, .telegram, "555", "Convert Test User", null, false, 1000);

    const config = try gpa.create(config_mod.Config);
    config.* = testConfig();

    const ctx = try gpa.create(ServerContext);
    ctx.* = .{ .allocator = gpa, .io = testing.io, .pool = pool, .config = config };

    const listener = try gpa.create(Io.net.Server);
    listener.* = try bind(testing.io, 0);
    const port = listener.socket.address.getPort();

    var stop: Stop = .{};
    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2), &stop });
    // Registered before the request-side defers below so it runs after them: the
    // client is finished with the server by the time the loop is told to stop.
    defer {
        stop.shutdown(testing.io, port);
        thread.join();
    }

    var client: http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const cookie = try devLogin(&client, port, identity_id);
    defer testing.allocator.free(cookie);

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/convert", .{port});

    const boundary = "----RegressionTestBoundary1234567890";
    const file_content = "x" ** (32 * 1024); // past the 16KB connection buffer.
    const body = "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"big.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        file_content ++ "\r\n" ++
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"target_format\"\r\n" ++
        "\r\n" ++
        "md\r\n" ++
        "--" ++ boundary ++ "--\r\n";

    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "multipart/form-data; boundary=" ++ boundary },
            .{ .name = "cookie", .value = cookie },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});

    try testing.expectEqual(.ok, response.head.status);
    const resp_body = try readBody(&response, testing.allocator);
    defer testing.allocator.free(resp_body);
    try testing.expectEqualStrings(file_content ++ "\n", resp_body);
}

/// Sends `raw` verbatim over a fresh TCP connection to the test server and
/// returns everything it writes back.
fn rawRequest(allocator: std.mem.Allocator, port: u16, raw: []const u8) ![]u8 {
    var address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    const stream = try address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);

    var send_buf: [1024]u8 = undefined;
    var stream_writer = stream.writer(testing.io, &send_buf);
    try stream_writer.interface.writeAll(raw);
    try stream_writer.interface.flush();

    var recv_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(testing.io, &recv_buf);

    // Accumulated chunk by chunk rather than with `allocRemaining`, which
    // discards everything it read if the stream ends in a reset -- and it does
    // here.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (out.items.len < 64 * 1024) {
        stream_reader.interface.fillMore() catch break;
        const data = stream_reader.interface.buffered();
        if (data.len == 0) break;
        try out.appendSlice(allocator, data);
        stream_reader.interface.toss(data.len);
    }
    return out.toOwnedSlice(allocator);
}

// AUDIT-2026-09-03 API-1/API-2.
test "a malformed request head is refused instead of aborting the process" {
    const gpa = std.heap.page_allocator;

    const db = try gpa.create(Db);
    db.* = try test_support.openTestDb(gpa) orelse return error.SkipZigTest;
    const pool = try gpa.create(PgPool);
    pool.* = try PgPool.wrapForTest(gpa, testing.io, db);

    const config = try gpa.create(config_mod.Config);
    config.* = testConfig();

    const ctx = try gpa.create(ServerContext);
    ctx.* = .{ .allocator = gpa, .io = testing.io, .pool = pool, .config = config };

    const listener = try gpa.create(Io.net.Server);
    listener.* = try bind(testing.io, 0);
    const port = listener.socket.address.getPort();

    var stop: Stop = .{};
    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2), &stop });
    // Registered before the request-side defers below so it runs after them: the
    // client is finished with the server by the time the loop is told to stop.
    defer {
        stop.shutdown(testing.io, port);
        thread.join();
    }

    // API-1: a body method with neither content-length nor transfer-encoding.
    {
        const response = try rawRequest(testing.allocator, port, "POST /api/v1/notes HTTP/1.1\r\nHost: x\r\n\r\n");
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 411 Length Required"));
    }

    // API-2: an expectation this server can't satisfy.
    {
        const response = try rawRequest(testing.allocator, port, "POST /api/v1/notes HTTP/1.1\r\nHost: x\r\ncontent-length: 2\r\nexpect: something-else\r\n\r\n{}");
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 417 Expectation Failed"));
    }

    // `expect: 100-continue` is answered with the continuation and then served
    // normally -- 401 here (no session cookie), not a panic.
    {
        const response = try rawRequest(testing.allocator, port, "POST /api/v1/notes HTTP/1.1\r\nHost: x\r\ncontent-length: 2\r\nexpect: 100-continue\r\n\r\n{}");
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 100 Continue"));
        try testing.expect(std.mem.indexOf(u8, response, "401") != null);
    }

    // Still alive and serving.
    {
        var client: http.Client = .{ .allocator = testing.allocator, .io = testing.io };
        defer client.deinit();
        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/session", .{port});
        var req = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
        defer req.deinit();
        try req.sendBodiless();
        const response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
    }
}

/// One authenticated JSON request with a body, for the handlers below that
/// read one. `keep_alive = false` like every other test request here.
fn jsonRequest(client: *http.Client, port: u16, method: http.Method, path: []const u8, cookie: []const u8, body: []const u8) !http.Status {
    var url_buf: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    var req = try client.request(method, try std.Uri.parse(url), .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cookie", .value = cookie },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
    const response = try req.receiveHead(&.{});
    return response.head.status;
}

// AUDIT-2026-09-03 API-5: both handlers called `resolveAuth` again after
// taking the body reader, to re-check the owner tier and to stamp the audit
// row.
test "settings PATCH and announcement POST answer instead of aborting after the body read" {
    const gpa = std.heap.page_allocator;

    const db = try gpa.create(Db);
    db.* = try test_support.openTestDb(gpa) orelse return error.SkipZigTest;
    const pool = try gpa.create(PgPool);
    pool.* = try PgPool.wrapForTest(gpa, testing.io, db);

    // A bot admin passes `requireChatAccess` for any chat without a live
    // platform admin lookup, which the stub-free test server can't answer.
    const identity_id = try identities.getOrCreateMinimal(pool, .telegram, "556", "Settings Test Admin", null, false, 1000);
    try bot_admins.addBotAdmin(pool, identity_id, identity_id);
    const chat_id = try chats_store.upsertChat(pool, .telegram, "-1005560000", "supergroup", "Settings Test Chat");

    const config = try gpa.create(config_mod.Config);
    config.* = testConfig();

    const ctx = try gpa.create(ServerContext);
    ctx.* = .{ .allocator = gpa, .io = testing.io, .pool = pool, .config = config };

    const listener = try gpa.create(Io.net.Server);
    listener.* = try bind(testing.io, 0);
    const port = listener.socket.address.getPort();

    var stop: Stop = .{};
    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2), &stop });
    // Registered before the request-side defers below so it runs after them: the
    // client is finished with the server by the time the loop is told to stop.
    defer {
        stop.shutdown(testing.io, port);
        thread.join();
    }

    var client: http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const cookie = try devLogin(&client, port, identity_id);
    defer testing.allocator.free(cookie);

    var path_buf: [96]u8 = undefined;

    // The whole-object PATCH with nothing owner-gated changing: reaches the
    // audit-row `resolveAuth` at the very end.
    {
        const path = try std.fmt.bufPrint(&path_buf, "/api/v1/chats/{d}/settings", .{chat_id});
        const body =
            \\{"persona":null,"magic_word":null,"digest_enabled":false,"thinking_override":null,
            \\"briefing_enabled":false,"default_location":null,"welcome_message":null,
            \\"autopin_announcements":false,"video_download_enabled":false,
            \\"video_download_lossy":false,"slowmode_seconds":0}
        ;
        try testing.expectEqual(.ok, try jsonRequest(&client, port, .PATCH, path, cookie, body));
    }

    // Changing the welcome message reaches the owner re-check, which is a
    // 403 for a bot admin -- an answer, not an abort.
    {
        const path = try std.fmt.bufPrint(&path_buf, "/api/v1/chats/{d}/settings", .{chat_id});
        const body =
            \\{"persona":null,"magic_word":null,"digest_enabled":false,"thinking_override":null,
            \\"briefing_enabled":false,"default_location":null,"welcome_message":"hi",
            \\"autopin_announcements":false,"video_download_enabled":false,
            \\"video_download_lossy":false,"slowmode_seconds":0}
        ;
        try testing.expectEqual(.forbidden, try jsonRequest(&client, port, .PATCH, path, cookie, body));
    }

    {
        const path = try std.fmt.bufPrint(&path_buf, "/api/v1/chats/{d}/announcements", .{chat_id});
        const body =
            \\{"message":"still here","when":{"kind":"duration","seconds":3600}}
        ;
        try testing.expectEqual(.ok, try jsonRequest(&client, port, .POST, path, cookie, body));
    }

    // Still alive and serving.
    {
        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/auth/session", .{port});
        var req = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
        defer req.deinit();
        try req.sendBodiless();
        const response = try req.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
    }
}

// The owner logs in through one platform's identity (OIDC vouches for the
// Telegram account), but writes notes from every platform the bot is on.
test "my notes list covers every one of the owner's platform identities, not just the logged-in one" {
    const gpa = std.heap.page_allocator;

    const db = try gpa.create(Db);
    db.* = try test_support.openTestDb(gpa) orelse return error.SkipZigTest;
    const pool = try gpa.create(PgPool);
    pool.* = try PgPool.wrapForTest(gpa, testing.io, db);

    const telegram_owner = try identities.getOrCreateMinimal(pool, .telegram, "777", "Owner", null, false, 1000);
    const matrix_owner = try identities.getOrCreateMinimal(pool, .matrix, "@owner:example.org", "Owner", null, false, 1000);
    const stranger = try identities.getOrCreateMinimal(pool, .telegram, "778", "Stranger", null, false, 1000);
    const tg_chat = try chats_store.upsertChat(pool, .telegram, "-1007770000", "supergroup", "TG Chat");
    const mx_chat = try chats_store.upsertChat(pool, .matrix, "!room:example.org", "room", "MX Room");

    _ = try notes_store.create(pool, tg_chat, telegram_owner, "from telegram", 1000);
    _ = try notes_store.create(pool, mx_chat, matrix_owner, "from matrix", 2000);
    _ = try notes_store.create(pool, tg_chat, stranger, "not mine", 3000);

    const config = try gpa.create(config_mod.Config);
    config.* = testConfig();
    config.owners = &.{
        .{ .platform = .telegram, .owner_id = "777" },
        .{ .platform = .matrix, .owner_id = "@owner:example.org" },
    };

    const ctx = try gpa.create(ServerContext);
    ctx.* = .{ .allocator = gpa, .io = testing.io, .pool = pool, .config = config };

    const listener = try gpa.create(Io.net.Server);
    listener.* = try bind(testing.io, 0);
    const port = listener.socket.address.getPort();

    var stop: Stop = .{};
    const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2), &stop });
    defer {
        stop.shutdown(testing.io, port);
        thread.join();
    }

    var client: http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    // Logged in as the Telegram identity only -- the Matrix one is never
    // linked to the account, same as production.
    const cookie = try devLogin(&client, port, telegram_owner);
    defer testing.allocator.free(cookie);

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/notes", .{port});
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

    try testing.expect(std.mem.indexOf(u8, body, "\"from telegram\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"from matrix\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"not mine\"") == null);
}
