//! Shared one-shot GET/POST helpers over `std.http.Client.fetch`, used by the
//! Telegram client and the LLM provider adapters alike so each of them
//! doesn't hand-roll the same response-buffering boilerplate.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const log = @import("log.zig").scoped("http");

/// How much of a failed response's body makes it into the log.
const max_logged_body = 400;

/// The allocator for every byte an abandoned request thread can still touch
/// after `fetchWithTimeout`/`postJsonSSE` has returned to its caller.
const detached_gpa = std.heap.page_allocator;

/// Generous enough to never trip during legitimate slow operations.
const default_timeout_ns: u64 = 45 * std.time.ns_per_s;
/// Budget for `getWithTimeout`, for tool calls made *while the user is
/// actively waiting mid-conversation*.
pub const tool_timeout_ns: u64 = 20 * std.time.ns_per_s;
/// Budget for `postJsonWithTimeout`, used only by the LLM provider adapters
/// (`llm/anthropic.zig`, `llm/openai_compat.zig`).
pub const llm_timeout_ns: u64 = 2 * std.time.ns_per_min;
/// How often the caller checks whether the background fetch finished — bounds
/// how much latency this wrapper adds on top of a fast, healthy request.
const poll_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// Deep-copies the parts of a `FetchOptions` that are borrowed from the
/// caller.
const FetchShared = struct {
    done: std.atomic.Value(bool) = .init(false),
    result: http.Client.FetchError!http.Client.FetchResult = undefined,
    body: Io.Writer.Allocating,
    url: []const u8,
    payload: ?[]const u8,
    extra_headers: []const http.Header,
    /// The request runs on *this* client, not the caller's, for the same lifetime
    /// reason the buffers above are copies.
    client: http.Client,
};

fn dupeHeaders(allocator: std.mem.Allocator, headers: []const http.Header) ![]http.Header {
    const out = try allocator.alloc(http.Header, headers.len);
    for (headers, 0..) |h, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value),
        };
    }
    return out;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const http.Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

fn freeShared(shared: *FetchShared) void {
    shared.client.deinit();
    shared.body.deinit();
    detached_gpa.free(shared.url);
    if (shared.payload) |p| detached_gpa.free(p);
    freeHeaders(detached_gpa, shared.extra_headers);
    detached_gpa.destroy(shared);
}

fn fetchAndFlag(base_options: http.Client.FetchOptions, shared: *FetchShared) void {
    var opts = base_options;
    opts.location = .{ .url = shared.url };
    opts.payload = shared.payload;
    opts.extra_headers = shared.extra_headers;
    opts.response_writer = &shared.body.writer;
    shared.result = shared.client.fetch(opts);
    shared.done.store(true, .release);
}

/// Builds the heap-owned `FetchShared` for one request.
fn buildFetchShared(io: Io, options: http.Client.FetchOptions) !*FetchShared {
    const url = switch (options.location) {
        .url => |u| u,
        .uri => unreachable,
    };

    const shared = try detached_gpa.create(FetchShared);
    errdefer detached_gpa.destroy(shared);
    const url_copy = try detached_gpa.dupe(u8, url);
    errdefer detached_gpa.free(url_copy);
    const payload_copy = if (options.payload) |p| try detached_gpa.dupe(u8, p) else null;
    errdefer if (payload_copy) |p| detached_gpa.free(p);
    const headers_copy = try dupeHeaders(detached_gpa, options.extra_headers);
    errdefer freeHeaders(detached_gpa, headers_copy);
    shared.* = .{
        .body = .init(detached_gpa),
        .url = url_copy,
        .payload = payload_copy,
        .extra_headers = headers_copy,
        .client = .{ .allocator = detached_gpa, .io = io },
    };
    return shared;
}

/// Also its own function for the same reason as `buildFetchShared`.
fn spawnFetch(options: http.Client.FetchOptions, shared: *FetchShared) !std.Thread {
    errdefer freeShared(shared);
    return std.Thread.spawn(.{}, fetchAndFlag, .{ options, shared });
}

/// Runs `client.fetch(options)` with a hard wall-clock deadline of
/// `timeout_ns`.
fn fetchWithTimeout(client: *http.Client, options: http.Client.FetchOptions, timeout_ns: u64) !http.Client.FetchResult {
    const shared = try buildFetchShared(client.io, options);
    const thread = try spawnFetch(options, shared);

    var waited_ns: u64 = 0;
    while (!shared.done.load(.acquire) and waited_ns < timeout_ns) {
        const step = @min(poll_interval_ns, timeout_ns - waited_ns);
        Io.sleep(client.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
        waited_ns += step;
    }

    if (shared.done.load(.acquire)) {
        thread.join();
        defer freeShared(shared);
        const result = try shared.result;
        if (options.response_writer) |w| try w.writeAll(shared.body.writer.buffered());
        return result;
    }

    // Deliberately not joined or freed.
    var url_buf: [512]u8 = undefined;
    log.warn("request timed out after {d}ms, detaching the stalled connection: {s} {s}", .{
        @divTrunc(timeout_ns, std.time.ns_per_ms),
        @tagName(options.method orelse .GET),
        redactUrl(&url_buf, urlOf(options)),
    });
    thread.detach();
    return error.RequestTimedOut;
}

/// Best-effort URL extraction for a log line — `options.location` is always
/// `.url` in practice.
fn urlOf(options: http.Client.FetchOptions) []const u8 {
    return switch (options.location) {
        .url => |u| u,
        .uri => "(uri)",
    };
}

/// Total attempts per request; the delay before each retry grows so a brief
/// outage.
const max_attempts = 3;
const backoff_ms = [max_attempts - 1]i64{ 500, 2000 };

/// Errors where the connection died (or never came up) through no fault of
/// the request itself — the only ones worth retrying.
fn isTransient(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing,
        error.TlsInitializationFailed,
        error.NameServerFailure,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.ConnectionRefused,
        => true,
        else => false,
    };
}

/// Sleeps before retry number `attempt` (0-based count of failures so far).
fn backoff(client: *http.Client, attempt: usize) error{Canceled}!void {
    try Io.sleep(client.io, .fromMilliseconds(backoff_ms[attempt]), .awake);
}

pub fn get(client: *http.Client, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    return getWithTimeout(client, allocator, url, default_timeout_ns);
}

pub fn getWithTimeout(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, timeout_ns: u64) ![]u8 {
    return getWithHeadersTimeout(client, allocator, url, &.{}, timeout_ns);
}

pub fn getWithHeaders(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, extra_headers: []const http.Header) ![]u8 {
    return getWithHeadersTimeout(client, allocator, url, extra_headers, default_timeout_ns);
}

pub fn getWithHeadersTimeout(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, extra_headers: []const http.Header, timeout_ns: u64) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return getOnce(client, allocator, url, extra_headers, timeout_ns) catch |err| {
            if (attempt + 1 >= max_attempts or !isTransient(err)) return err;
            var url_buf: [512]u8 = undefined;
            log.warn("GET {s} failed ({t}), retrying (attempt {d}/{d})", .{ redactUrl(&url_buf, url), err, attempt + 2, max_attempts });
            try backoff(client, attempt);
            continue;
        };
    }
}

fn getOnce(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, extra_headers: []const http.Header, timeout_ns: u64) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try fetchWithTimeout(client, .{
        .location = .{ .url = url },
        .extra_headers = extra_headers,
        .keep_alive = false,
        .response_writer = &response_writer.writer,
    }, timeout_ns);
    try checkStatus("GET", url, result.status, response_writer.writer.buffered());
    return response_writer.toOwnedSlice();
}

pub const StatusAndBody = struct { status: http.Status, body: []u8 };

/// Like `get`, but returns the HTTP status alongside the body instead of
/// treating any non-2xx response as fatal.
pub fn getAllowingAnyStatus(client: *http.Client, allocator: std.mem.Allocator, url: []const u8) !StatusAndBody {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var response_writer: Io.Writer.Allocating = .init(allocator);
        errdefer response_writer.deinit();
        const result = fetchWithTimeout(client, .{
            .location = .{ .url = url },
            .extra_headers = &.{},
            .keep_alive = false,
            .response_writer = &response_writer.writer,
        }, default_timeout_ns) catch |err| {
            if (attempt + 1 >= max_attempts or !isTransient(err)) return err;
            var url_buf: [512]u8 = undefined;
            log.warn("GET {s} failed ({t}), retrying (attempt {d}/{d})", .{ redactUrl(&url_buf, url), err, attempt + 2, max_attempts });
            try backoff(client, attempt);
            continue;
        };
        return .{ .status = result.status, .body = try response_writer.toOwnedSlice() };
    }
}

pub fn postJson(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
) ![]u8 {
    return postJsonTimed(client, allocator, url, extra_headers, payload, default_timeout_ns);
}

/// Like `postJson`, but with a caller-chosen deadline instead of the default
/// — used by the LLM provider adapters.
pub fn postJsonWithTimeout(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
    timeout_ns: u64,
) ![]u8 {
    return postJsonTimed(client, allocator, url, extra_headers, payload, timeout_ns);
}

fn postJsonTimed(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
    timeout_ns: u64,
) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return postJsonOnce(client, allocator, url, extra_headers, payload, timeout_ns) catch |err| {
            if (attempt + 1 >= max_attempts or !isTransient(err)) return err;
            var url_buf: [512]u8 = undefined;
            log.warn("POST {s} failed ({t}), retrying (attempt {d}/{d})", .{ redactUrl(&url_buf, url), err, attempt + 2, max_attempts });
            try backoff(client, attempt);
            continue;
        };
    }
}

fn postJsonOnce(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
    timeout_ns: u64,
) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try fetchWithTimeout(client, .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = extra_headers,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .keep_alive = false,
        .response_writer = &response_writer.writer,
    }, timeout_ns);
    try checkStatus("POST", url, result.status, response_writer.writer.buffered());
    return response_writer.toOwnedSlice();
}

/// Like `postJson`, but for an arbitrary content type (e.g. multipart/form-
/// data with binary bytes) rather than always application/json.
pub fn postRaw(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    content_type: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return postRawOnce(client, allocator, url, content_type, extra_headers, payload) catch |err| {
            if (attempt + 1 >= max_attempts or !isTransient(err)) return err;
            try backoff(client, attempt);
            continue;
        };
    }
}

fn postRawOnce(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    content_type: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try fetchWithTimeout(client, .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = extra_headers,
        .headers = .{ .content_type = .{ .override = content_type } },
        .keep_alive = false,
        .response_writer = &response_writer.writer,
    }, default_timeout_ns);
    try checkStatus("POST", url, result.status, response_writer.writer.buffered());
    return response_writer.toOwnedSlice();
}

/// Like `postJson`, but with `PUT` — Matrix's `/send`/`/state` endpoints use
/// PUT.
pub fn putJson(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return putJsonOnce(client, allocator, url, extra_headers, payload) catch |err| {
            if (attempt + 1 >= max_attempts or !isTransient(err)) return err;
            try backoff(client, attempt);
            continue;
        };
    }
}

fn putJsonOnce(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try fetchWithTimeout(client, .{
        .location = .{ .url = url },
        .method = .PUT,
        .payload = payload,
        .extra_headers = extra_headers,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .keep_alive = false,
        .response_writer = &response_writer.writer,
    }, default_timeout_ns);
    try checkStatus("PUT", url, result.status, response_writer.writer.buffered());
    return response_writer.toOwnedSlice();
}

/// One line read from a Server-Sent-Events response body, handed to
/// `postJsonSSE`'s caller as it arrives.
pub const SseLineSink = struct {
    ptr: *anyopaque,
    onLine: *const fn (ptr: *anyopaque, line: []const u8) anyerror!void,
};

/// Wraps a caller's `SseLineSink` so it can be silenced after the fact.
const SinkGuard = struct {
    inner: SseLineSink,
    abandoned: std.atomic.Value(bool) = .init(false),

    fn sink(self: *SinkGuard) SseLineSink {
        return .{ .ptr = self, .onLine = onLine };
    }
    fn onLine(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *SinkGuard = @ptrCast(@alignCast(ptr));
        if (self.abandoned.load(.acquire)) return;
        return self.inner.onLine(self.inner.ptr, line);
    }
};

const StreamShared = struct {
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!void = undefined,
    url: []const u8,
    payload: []const u8,
    extra_headers: []const http.Header,
    sink_guard: SinkGuard,
    /// Owned for the same reason as `FetchShared.client` — see there.
    client: http.Client,
};

fn freeStreamShared(shared: *StreamShared) void {
    shared.client.deinit();
    detached_gpa.free(shared.url);
    detached_gpa.free(shared.payload);
    freeHeaders(detached_gpa, shared.extra_headers);
    detached_gpa.destroy(shared);
}

fn streamJsonSSEAndFlag(shared: *StreamShared) void {
    shared.result = postJsonSSEOnce(&shared.client, detached_gpa, shared.url, shared.extra_headers, shared.payload, shared.sink_guard.sink());
    shared.done.store(true, .release);
}

/// Split out for the same reason as `fetchWithTimeout`'s
/// `buildFetchShared`/`spawnFetch`.
fn buildStreamShared(io: Io, url: []const u8, extra_headers: []const http.Header, payload: []const u8, sink: SseLineSink) !*StreamShared {
    const shared = try detached_gpa.create(StreamShared);
    errdefer detached_gpa.destroy(shared);
    const url_copy = try detached_gpa.dupe(u8, url);
    errdefer detached_gpa.free(url_copy);
    const payload_copy = try detached_gpa.dupe(u8, payload);
    errdefer detached_gpa.free(payload_copy);
    const headers_copy = try dupeHeaders(detached_gpa, extra_headers);
    errdefer freeHeaders(detached_gpa, headers_copy);
    shared.* = .{
        .url = url_copy,
        .payload = payload_copy,
        .extra_headers = headers_copy,
        .sink_guard = .{ .inner = sink },
        .client = .{ .allocator = detached_gpa, .io = io },
    };
    return shared;
}

fn spawnStream(shared: *StreamShared) !std.Thread {
    errdefer freeStreamShared(shared);
    return std.Thread.spawn(.{}, streamJsonSSEAndFlag, .{shared});
}

/// Like `postJson`, but for a Server-Sent-Events endpoint (`"stream":true`
/// set in `payload` by the caller).
pub fn postJsonSSE(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
    timeout_ns: u64,
    sink: SseLineSink,
) !void {
    _ = allocator;
    const shared = try buildStreamShared(client.io, url, extra_headers, payload, sink);
    const thread = try spawnStream(shared);

    var waited_ns: u64 = 0;
    while (!shared.done.load(.acquire) and waited_ns < timeout_ns) {
        const step = @min(poll_interval_ns, timeout_ns - waited_ns);
        Io.sleep(client.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
        waited_ns += step;
    }

    if (shared.done.load(.acquire)) {
        thread.join();
        defer freeStreamShared(shared);
        return shared.result;
    }

    shared.sink_guard.abandoned.store(true, .release);
    thread.detach();
    return error.RequestTimedOut;
}

fn postJsonSSEOnce(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
    sink: SseLineSink,
) !void {
    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = extra_headers,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(redirect_buffer);
    var response = try req.receiveHead(redirect_buffer);

    if (response.head.status.class() != .success) {
        var err_buf: Io.Writer.Allocating = .init(allocator);
        defer err_buf.deinit();
        var small_transfer_buffer: [64]u8 = undefined;
        const err_reader = response.reader(&small_transfer_buffer);
        _ = err_reader.streamRemaining(&err_buf.writer) catch {};
        const shown = err_buf.writer.buffered();
        var url_buf: [512]u8 = undefined;
        log.err("POST {s} -> {d}: {s}", .{
            redactUrl(&url_buf, url),
            @intFromEnum(response.head.status),
            shown[0..@min(shown.len, max_logged_body)],
        });
        return error.HttpRequestFailed;
    }

    // Sized to comfortably hold one SSE line (a large streamed tool-call argument
    // fragment, say).
    var transfer_buffer: [32 * 1024]u8 = undefined;
    var decompress: http.Decompress = undefined;
    // Same conditional sizing `fetch()` itself uses — most LLM APIs don't
    // compress SSE responses, so this is usually a zero-byte allocation.
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return drainSseLines(reader, sink);
}

test "getWithTimeout returns RequestTimedOut instead of hanging forever when a peer accepts the connection but never responds (regression: production hang 2026-07-21)" {
    const io = testing.io;

    var address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    // Heap-allocated and never deinit'd for the same lifetime reason as `client`
    // below: the acceptor thread is detached and holds this pointer.
    const server = try std.heap.page_allocator.create(Io.net.Server);
    server.* = try address.listen(io, .{ .reuse_address = true });
    const port = server.socket.address.getPort();

    // Accepts the connection and then goes silent forever: no read, no write, no
    // close.
    const Acceptor = struct {
        fn run(srv: *Io.net.Server, accept_io: Io) void {
            var conn = srv.accept(accept_io) catch return;
            defer conn.socket.close(accept_io);
            Io.sleep(accept_io, .fromSeconds(30), .awake) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Acceptor.run, .{ server, io });
    defer thread.detach();

    // A plain stack local with a `defer client.deinit()`, exactly like every real
    // call site (`tools/weather.zig`, `tools/fetch_url.zig`, ...).
    var client: http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    const started = Io.Timestamp.now(io, .real);
    const result = getWithTimeout(&client, testing.allocator, url, 300 * std.time.ns_per_ms);
    const elapsed_ns = Io.Timestamp.now(io, .real).toNanoseconds() - started.toNanoseconds();

    try testing.expectError(error.RequestTimedOut, result);
    // Generous upper bound — this asserts "didn't hang indefinitely," not exact
    // timing.
    try testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

/// Reads `reader` line-by-line until end of stream, handing each one
/// (delimiter stripped) to `sink.onLine`.
fn drainSseLines(reader: *Io.Reader, sink: SseLineSink) !void {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        try sink.onLine(sink.ptr, std.mem.trimEnd(u8, line, "\r\n"));
    }
}

fn checkStatus(method: []const u8, url: []const u8, status: http.Status, body: []const u8) !void {
    if (status.class() == .success) return;
    var url_buf: [512]u8 = undefined;
    const shown = body[0..@min(body.len, max_logged_body)];
    log.err("{s} {s} -> {d}: {s}", .{ method, redactUrl(&url_buf, url), @intFromEnum(status), shown });
    return error.HttpRequestFailed;
}

/// Telegram bot API URLs carry the bot token as a path segment
/// ("…/bot<token>/method") — mask it so error logs never leak the secret.
fn redactUrl(buf: []u8, url: []const u8) []const u8 {
    const marker = "/bot";
    const i = std.mem.indexOf(u8, url, marker) orelse return url;
    const secret_start = i + marker.len;
    const secret_end = std.mem.indexOfScalarPos(u8, url, secret_start, '/') orelse url.len;
    if (secret_end == secret_start) return url;

    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}***{s}", .{ url[0..secret_start], url[secret_end..] }) catch {
        // URL too long for the buffer — the prefix alone (host + "/bot")
        // is already written and contains nothing secret.
    };
    return w.buffered();
}

test "redactUrl masks telegram bot tokens and leaves other urls alone" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.telegram.org/bot***/sendMessage",
        redactUrl(&buf, "https://api.telegram.org/bot123456:AAbbCCdd/sendMessage"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/search?q=warden",
        redactUrl(&buf, "https://example.com/search?q=warden"),
    );
}

/// Percent-encodes `s` for safe use as a single query-string value (e.g. a
/// user-supplied city name or search term embedded in a GET URL).
pub fn encodeQueryComponent(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (s) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            try out.append(allocator, c);
        } else {
            var buf: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&buf, "%{X:0>2}", .{c});
            try out.appendSlice(allocator, &buf);
        }
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

const LineRecorder = struct {
    lines: std.ArrayList([]const u8) = .empty,

    fn sink(self: *LineRecorder) SseLineSink {
        return .{ .ptr = self, .onLine = onLine };
    }
    fn onLine(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *LineRecorder = @ptrCast(@alignCast(ptr));
        // Bounds a would-be regression: an infinite zero-progress loop.
        if (self.lines.items.len > 1000) return error.TooManyLines;
        self.lines.append(std.testing.allocator, line) catch return error.OutOfMemory;
    }
};

test "drainSseLines delivers blank SSE separator lines without looping (regression: takeDelimiterExclusive never consumed the delimiter)" {
    var reader: Io.Reader = .fixed("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n");
    var recorder = LineRecorder{};
    defer recorder.lines.deinit(testing.allocator);

    try drainSseLines(&reader, recorder.sink());

    try testing.expectEqual(@as(usize, 4), recorder.lines.items.len);
    try testing.expectEqualStrings("data: {\"a\":1}", recorder.lines.items[0]);
    try testing.expectEqualStrings("", recorder.lines.items[1]);
    try testing.expectEqualStrings("data: {\"b\":2}", recorder.lines.items[2]);
    try testing.expectEqualStrings("", recorder.lines.items[3]);
}

test "drainSseLines handles many consecutive blank lines without looping" {
    // "data: x" + 3 blank lines + "data: y" + 1 trailing blank line = 6
    // lines total ("data: x\n" + "\n\n\n" + "data: y\n" + "\n").
    var reader: Io.Reader = .fixed("data: x\n\n\n\ndata: y\n\n");
    var recorder = LineRecorder{};
    defer recorder.lines.deinit(testing.allocator);

    try drainSseLines(&reader, recorder.sink());

    try testing.expectEqual(@as(usize, 6), recorder.lines.items.len);
    try testing.expectEqualStrings("data: x", recorder.lines.items[0]);
    try testing.expectEqualStrings("", recorder.lines.items[1]);
    try testing.expectEqualStrings("", recorder.lines.items[2]);
    try testing.expectEqualStrings("", recorder.lines.items[3]);
    try testing.expectEqualStrings("data: y", recorder.lines.items[4]);
    try testing.expectEqualStrings("", recorder.lines.items[5]);
}

test "drainSseLines strips a trailing \\r (CRLF line endings)" {
    var reader: Io.Reader = .fixed("data: x\r\n\r\n");
    var recorder = LineRecorder{};
    defer recorder.lines.deinit(testing.allocator);

    try drainSseLines(&reader, recorder.sink());

    try testing.expectEqual(@as(usize, 2), recorder.lines.items.len);
    try testing.expectEqualStrings("data: x", recorder.lines.items[0]);
    try testing.expectEqualStrings("", recorder.lines.items[1]);
}

test "drainSseLines stops cleanly at end of stream, including an unterminated trailing line" {
    var reader: Io.Reader = .fixed("data: x\n\ndata: partial-no-newline");
    var recorder = LineRecorder{};
    defer recorder.lines.deinit(testing.allocator);

    try drainSseLines(&reader, recorder.sink());

    // The final line has no trailing delimiter.
    try testing.expectEqual(@as(usize, 2), recorder.lines.items.len);
    try testing.expectEqualStrings("data: x", recorder.lines.items[0]);
    try testing.expectEqualStrings("", recorder.lines.items[1]);
}
