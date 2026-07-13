//! Shared one-shot GET/POST helpers over `std.http.Client.fetch`, used by
//! the Telegram client and the LLM provider adapters alike so each of them
//! doesn't hand-roll the same response-buffering boilerplate.
//!
//! All helpers request `keep_alive = false` and additionally retry transient
//! connection errors (see `isTransient`) up to two more times with a short
//! backoff between attempts. Both measures exist because middleboxes
//! (VPN tunnels/exit nodes, NAT timeouts) kill idle connections without
//! close-notify: no reuse means a request can't land on a connection that
//! died in the pool, and the retries cover one being killed mid-request
//! (e.g. during a 30s Telegram long poll). The backoff gives a flaky link a
//! moment to recover instead of failing two attempts back-to-back within
//! milliseconds. Retrying is safe even for non-idempotent Telegram sends,
//! since the failed attempt died before a response — worst case is a
//! duplicated chat message, preferred over a silently dropped one.
//! Non-2xx responses are an error (`error.HttpRequestFailed`) rather than
//! a body handed back as if it were the real content; the body prefix is
//! logged for diagnosis, capped so an HTML error page can't flood the log.
//!
//! Every request also runs under `fetchWithTimeout`: `std.http.Client` has
//! no built-in per-request deadline, and warden's poll loop is single-
//! threaded and single-connector, so one stalled socket (dead connection,
//! a resolver that hangs instead of erroring) would otherwise freeze the
//! entire bot indefinitely — confirmed in production: a DNS hiccup left a
//! `getUpdates` connection sitting open for minutes with no timeout to cut
//! it off. `fetchWithTimeout` runs the fetch on an `Io.concurrent` task and
//! polls a completion flag from the caller; on timeout it calls
//! `Future.cancel`, which genuinely interrupts the stuck operation (unlike
//! abandoning a raw thread, which would leak the socket) and blocks until
//! the task has actually unwound, so it's safe for the response writer to
//! live on the caller's stack.

const std = @import("std");
const Io = std.Io;
const http = std.http;

/// How much of a failed response's body makes it into the log.
const max_logged_body = 400;

/// Generous enough to never trip during legitimate slow operations (a 25s
/// Telegram long poll, a quick tool API call) while still bounding a truly
/// stuck connection to a finite wait instead of forever. NOT used for LLM
/// provider calls — see `llm_timeout_ns`: CPU-only local inference can
/// legitimately take minutes to process a large prompt (warden's full tool
/// schemas + chat history easily runs to thousands of tokens), which blew
/// straight through this budget in production and got canceled mid-flight
/// before it ever had a chance to finish.
const default_timeout_ns: u64 = 45 * std.time.ns_per_s;
/// Budget for `getWithTimeout`, for tool calls made *while the user is
/// actively waiting mid-conversation* (`scrape_site`'s per-page fetches
/// especially — up to `max_pages` of these can chain in one tool call, so
/// each one individually needs to stay well under `default_timeout_ns` or
/// the compound worst case balloons: 5 pages x 45s each is nearly 4
/// minutes for ONE tool call, and `toolcall.run` can invoke tools across up
/// to 6 iterations. Confirmed in production: a single scrape_site call
/// chaining several slow/unreachable pages was the actual cause of a
/// "stuck thinking" report that turned out to still be running, just very
/// slowly, well past the point a chat reply should ever take.
pub const tool_timeout_ns: u64 = 20 * std.time.ns_per_s;
/// Budget for `postJsonWithTimeout`, used only by the LLM provider adapters
/// (`llm/anthropic.zig`, `llm/openai_compat.zig`). Was 5 minutes while
/// running a slow CPU-only local model with large prompts; back down to a
/// couple minutes now that the active provider is a fast cloud model
/// (Anthropic) — a real hang should surface quickly, not leave the "thinking"
/// placeholder sitting for minutes before anyone finds out something's wrong.
/// Still well above normal latency (a tool-heavy multi-turn answer is
/// typically single-digit seconds), just not "accommodate a slow CPU" long.
pub const llm_timeout_ns: u64 = 2 * std.time.ns_per_min;
/// How often the caller checks whether the background fetch finished —
/// bounds how much latency this wrapper adds on top of a fast, healthy
/// request.
const poll_interval_ns: u64 = 100 * std.time.ns_per_ms;

const FetchShared = struct {
    done: std.atomic.Value(bool) = .init(false),
};

fn fetchAndFlag(
    client: *http.Client,
    options: http.Client.FetchOptions,
    shared: *FetchShared,
    out: *(http.Client.FetchError!http.Client.FetchResult),
) void {
    out.* = client.fetch(options);
    shared.done.store(true, .release);
}

/// Runs `client.fetch(options)` with a hard wall-clock deadline of
/// `timeout_ns` (see module doc for why this exists at all). Returns
/// `error.RequestTimedOut` if it doesn't finish in time.
fn fetchWithTimeout(client: *http.Client, options: http.Client.FetchOptions, timeout_ns: u64) !http.Client.FetchResult {
    const io = client.io;
    var shared: FetchShared = .{};
    var out: http.Client.FetchError!http.Client.FetchResult = undefined;

    var future = try Io.concurrent(io, fetchAndFlag, .{ client, options, &shared, &out });

    var waited_ns: u64 = 0;
    while (!shared.done.load(.acquire) and waited_ns < timeout_ns) {
        const step = @min(poll_interval_ns, timeout_ns - waited_ns);
        Io.sleep(io, .fromNanoseconds(@intCast(step)), .awake) catch break;
        waited_ns += step;
    }

    if (shared.done.load(.acquire)) {
        _ = future.await(io);
        return out;
    }
    // Blocks until the task actually unwinds (see module doc) — safe for
    // `options.response_writer` to keep pointing at the caller's stack.
    _ = future.cancel(io);
    return error.RequestTimedOut;
}

/// Total attempts per request; the delay before each retry grows so a brief
/// outage (VPN reroute, WiFi blip) can pass instead of burning all attempts
/// within milliseconds of each other.
const max_attempts = 3;
const backoff_ms = [max_attempts - 1]i64{ 500, 2000 };

/// Errors where the connection died (or never came up) through no fault of
/// the request itself — the only ones worth retrying. `RequestTimedOut` is
/// deliberately NOT here: retrying a request that was merely slow (not
/// broken) just multiplies the wait for no benefit — up to 3x with nothing
/// to show for it — instead of surfacing a clear failure after one full,
/// already-generous budget.
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

/// Like `get`, but with a caller-chosen deadline — see `tool_timeout_ns`'s
/// doc comment for why an interactive-tool fetch needs a much shorter
/// budget than this module's other callers.
pub fn getWithTimeout(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, timeout_ns: u64) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return getOnce(client, allocator, url, timeout_ns) catch |err| {
            if (attempt + 1 >= max_attempts or !isTransient(err)) return err;
            try backoff(client, attempt);
            continue;
        };
    }
}

fn getOnce(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, timeout_ns: u64) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try fetchWithTimeout(client, .{
        .location = .{ .url = url },
        .keep_alive = false,
        .response_writer = &response_writer.writer,
    }, timeout_ns);
    try checkStatus("GET", url, result.status, response_writer.writer.buffered());
    return response_writer.toOwnedSlice();
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

/// Like `postJson`, but with a caller-chosen deadline instead of the
/// default — used by the LLM provider adapters, which need a much longer
/// budget than everything else calling into this module (see
/// `llm_timeout_ns`'s doc comment).
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

/// Like `postJson`, but for an arbitrary content type (e.g.
/// multipart/form-data with binary bytes) rather than always
/// application/json.
pub fn postRaw(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    content_type: []const u8,
    payload: []const u8,
) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return postRawOnce(client, allocator, url, content_type, payload) catch |err| {
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
    payload: []const u8,
) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try fetchWithTimeout(client, .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = content_type } },
        .keep_alive = false,
        .response_writer = &response_writer.writer,
    }, default_timeout_ns);
    try checkStatus("POST", url, result.status, response_writer.writer.buffered());
    return response_writer.toOwnedSlice();
}

fn checkStatus(method: []const u8, url: []const u8, status: http.Status, body: []const u8) !void {
    if (status.class() == .success) return;
    var url_buf: [512]u8 = undefined;
    const shown = body[0..@min(body.len, max_logged_body)];
    std.log.err("{s} {s} -> {d}: {s}", .{ method, redactUrl(&url_buf, url), @intFromEnum(status), shown });
    return error.HttpRequestFailed;
}

/// Telegram bot API URLs carry the bot token as a path segment
/// ("…/bot<token>/method") — mask it so error logs never leak the secret.
/// Returns `url` unchanged when there's nothing to redact.
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
