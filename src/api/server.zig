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
/// `main.zig`'s connector poll loops and `WorkerPool` itself.
pub fn run(ctx: *const ServerContext, port: u16, worker_count: usize) !void {
    var address = try Io.net.IpAddress.parseIp4("0.0.0.0", port);
    var listener = try address.listen(ctx.io, .{ .reuse_address = true });
    defer listener.deinit(ctx.io);

    const workers = try WorkerPool(ConnectionItem).init(ctx.allocator, ctx.io, worker_count, handleConnection);

    log.info("listening on port {d} ({d} worker(s))", .{ port, worker_count });
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
