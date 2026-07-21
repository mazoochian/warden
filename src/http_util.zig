//! Shared one-shot GET/POST helpers over `std.http.Client.fetch`, used by
//! the Telegram client and the LLM provider adapters alike so each of them
//! doesn't hand-roll the same response-buffering boilerplate. The one
//! exception is `postJsonSSE`, built on `std.http.Client`'s lower-level
//! request/receiveHead/reader primitives instead of `fetch` — it streams
//! the response line-by-line for Server-Sent-Events endpoints rather than
//! buffering the whole body; see its own doc comment for how its retry/
//! timeout story differs from everything else here.
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
//! it off.
//!
//! `fetchWithTimeout` runs the fetch on a real `std.Thread` and polls a
//! completion flag from the caller; on timeout it **detaches and abandons**
//! that thread rather than trying to cancel it. An earlier version used
//! `Io.concurrent` + `Future.cancel` instead, on the theory that `cancel`
//! "genuinely interrupts the stuck operation" — that's true only for calls
//! that pass through an `Io`-native cancellation point. `std.http.Client`
//! doesn't: `ConnectTcpOptions.timeout` is declared but never read anywhere
//! in `std/http/Client.zig`, and `Client.fetch` has no way to bound a
//! socket read at all. Confirmed live 2026-07-21: a remote peer that
//! accepted the connection and then went silent (no data, no close) left
//! `cancel()` blocked *waiting for a task to unwind that never would*,
//! which froze the entire bot for 5+ minutes at 0% CPU with no error ever
//! logged — worse than not having a timeout at all, since it looked like a
//! deadline was enforced when it wasn't. Detaching trades that unbounded
//! wait for a small, bounded leak (the request's cloned inputs plus
//! whatever the orphaned thread manages to buffer) on the rare occasions a
//! peer actually stalls like this — see `FetchShared`'s doc comment for how
//! the leak is kept safe rather than a use-after-free.

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

/// Deep-copies the parts of a `FetchOptions` that are borrowed from the
/// caller (a URL built with `std.fmt.allocPrint` into an arena, a JSON
/// payload, per-request headers) into memory this module owns outright,
/// plus a private response buffer instead of writing into the caller's own
/// `response_writer`. Needed because `fetchWithTimeout` may detach the
/// thread running the actual request and return to the caller — which can
/// then free its arena/stack frame — while that thread keeps running. Every
/// byte the thread touches from this point on must be reachable only
/// through `FetchShared`, never through the original `FetchOptions`, or an
/// abandoned request becomes a use-after-free instead of a plain memory
/// leak. On the normal (non-timeout) path this is freed right away by
/// `freeShared`; on timeout it's deliberately never freed (see module doc).
const FetchShared = struct {
    done: std.atomic.Value(bool) = .init(false),
    result: http.Client.FetchError!http.Client.FetchResult = undefined,
    body: Io.Writer.Allocating,
    url: []const u8,
    payload: ?[]const u8,
    extra_headers: []const http.Header,
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

fn freeShared(allocator: std.mem.Allocator, shared: *FetchShared) void {
    shared.body.deinit();
    allocator.free(shared.url);
    if (shared.payload) |p| allocator.free(p);
    freeHeaders(allocator, shared.extra_headers);
    allocator.destroy(shared);
}

fn fetchAndFlag(client: *http.Client, base_options: http.Client.FetchOptions, shared: *FetchShared) void {
    var opts = base_options;
    opts.location = .{ .url = shared.url };
    opts.payload = shared.payload;
    opts.extra_headers = shared.extra_headers;
    opts.response_writer = &shared.body.writer;
    shared.result = client.fetch(opts);
    shared.done.store(true, .release);
}

/// Builds the heap-owned `FetchShared` for one request. Split out from
/// `fetchWithTimeout` so its `errdefer`s stay scoped to just the cloning
/// itself: an `errdefer` guards everything from its declaration to the end
/// of the *enclosing function*, so if these lived inline in
/// `fetchWithTimeout` they'd still be armed all the way through
/// `try shared.result` far below — double-freeing `shared`'s contents
/// alongside the later, correct `defer freeShared(...)` on any request
/// that legitimately fails (a very ordinary outcome, not a bug on its own)
/// instead of only on a real setup-time allocation failure. Confirmed live
/// by this file's own test suite: two matrix crypto tests whose HTTP send
/// fails as expected crashed with a general-protection fault inside a
/// second, spurious `freeHeaders` call.
fn buildFetchShared(gpa: std.mem.Allocator, options: http.Client.FetchOptions) !*FetchShared {
    const url = switch (options.location) {
        .url => |u| u,
        .uri => unreachable,
    };

    const shared = try gpa.create(FetchShared);
    errdefer gpa.destroy(shared);
    const url_copy = try gpa.dupe(u8, url);
    errdefer gpa.free(url_copy);
    const payload_copy = if (options.payload) |p| try gpa.dupe(u8, p) else null;
    errdefer if (payload_copy) |p| gpa.free(p);
    const headers_copy = try dupeHeaders(gpa, options.extra_headers);
    errdefer freeHeaders(gpa, headers_copy);
    shared.* = .{ .body = .init(gpa), .url = url_copy, .payload = payload_copy, .extra_headers = headers_copy };
    return shared;
}

/// Also its own function for the same reason as `buildFetchShared`: an
/// `errdefer` here needs to free `shared` only if spawning genuinely
/// fails, without staying armed into `fetchWithTimeout`'s later, normal
/// `defer freeShared(...)` on the request-completed-but-failed path.
fn spawnFetch(client: *http.Client, options: http.Client.FetchOptions, shared: *FetchShared) !std.Thread {
    errdefer freeShared(client.allocator, shared);
    return std.Thread.spawn(.{}, fetchAndFlag, .{ client, options, shared });
}

/// Runs `client.fetch(options)` with a hard wall-clock deadline of
/// `timeout_ns` (see module doc for why this exists, and why it detaches
/// rather than cancels). Returns `error.RequestTimedOut` if it doesn't
/// finish in time. `options.location` must be `.url` — the only variant
/// this module ever builds.
fn fetchWithTimeout(client: *http.Client, options: http.Client.FetchOptions, timeout_ns: u64) !http.Client.FetchResult {
    const gpa = client.allocator;
    const shared = try buildFetchShared(gpa, options);
    const thread = try spawnFetch(client, options, shared);

    var waited_ns: u64 = 0;
    while (!shared.done.load(.acquire) and waited_ns < timeout_ns) {
        const step = @min(poll_interval_ns, timeout_ns - waited_ns);
        Io.sleep(client.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
        waited_ns += step;
    }

    if (shared.done.load(.acquire)) {
        thread.join();
        defer freeShared(gpa, shared);
        const result = try shared.result;
        if (options.response_writer) |w| try w.writeAll(shared.body.writer.buffered());
        return result;
    }

    // Deliberately not joined or freed — see module doc and `FetchShared`'s
    // doc comment for why this is a bounded leak, not a use-after-free.
    thread.detach();
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
    return getWithHeadersTimeout(client, allocator, url, &.{}, timeout_ns);
}

/// Like `get`, but with extra headers (e.g. an `Authorization: Bearer ...`
/// a bot-token-in-the-URL API like Telegram's doesn't need, but Matrix's
/// does on every request).
pub fn getWithHeaders(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, extra_headers: []const http.Header) ![]u8 {
    return getWithHeadersTimeout(client, allocator, url, extra_headers, default_timeout_ns);
}

pub fn getWithHeadersTimeout(client: *http.Client, allocator: std.mem.Allocator, url: []const u8, extra_headers: []const http.Header, timeout_ns: u64) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return getOnce(client, allocator, url, extra_headers, timeout_ns) catch |err| {
            if (attempt + 1 >= max_attempts or !isTransient(err)) return err;
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
/// application/json. `extra_headers` is almost always `&.{}` (Telegram
/// needs nothing extra); Matrix's media upload needs its bearer token here
/// since it can't embed one in the URL the way Telegram's bot token is.
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
/// PUT (the client picks the transaction/state key, making the request
/// naturally idempotent), unlike Telegram's POST-only Bot API.
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
/// `postJsonSSE`'s caller as it arrives. `ptr`/`onLine` rather than a plain
/// closure — same ptr+fn idiom used throughout this codebase (see
/// `platform.Connector`) since Zig has no capturing closures.
pub const SseLineSink = struct {
    ptr: *anyopaque,
    onLine: *const fn (ptr: *anyopaque, line: []const u8) anyerror!void,
};

/// Wraps a caller's `SseLineSink` so it can be silenced after the fact:
/// once `abandoned` is set, `onLine` becomes a no-op instead of touching
/// `inner.ptr` — needed because `postJsonSSE` may detach the thread that
/// calls it and return to a caller who then frees whatever `inner.ptr`
/// pointed at. `abandoned` is set right before detaching, so every
/// subsequent call becomes safe; the one call that might already be
/// in-flight at that exact instant is the only window this can't close —
/// same inherent limit as any non-preemptive cancellation, see this file's
/// module doc for why a real (blocking, wait-for-unwind) cancel isn't safe
/// to rely on here either.
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

/// See `FetchShared`'s doc comment for the general reasoning — same idea
/// for the streaming path. `url`/`payload`/`extra_headers` are owned
/// copies rather than the caller's own memory. Internal buffers
/// (`postJsonSSEOnce`'s redirect/decompress buffers) are allocated from
/// `client.allocator` rather than the caller-supplied allocator once this
/// runs on its own thread, since that allocator may be an arena the caller
/// frees the moment `postJsonSSE` returns `error.RequestTimedOut`.
const StreamShared = struct {
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!void = undefined,
    url: []const u8,
    payload: []const u8,
    extra_headers: []const http.Header,
    sink_guard: SinkGuard,
};

fn freeStreamShared(allocator: std.mem.Allocator, shared: *StreamShared) void {
    allocator.free(shared.url);
    allocator.free(shared.payload);
    freeHeaders(allocator, shared.extra_headers);
    allocator.destroy(shared);
}

fn streamJsonSSEAndFlag(client: *http.Client, gpa: std.mem.Allocator, shared: *StreamShared) void {
    shared.result = postJsonSSEOnce(client, gpa, shared.url, shared.extra_headers, shared.payload, shared.sink_guard.sink());
    shared.done.store(true, .release);
}

/// Split out for the same reason as `fetchWithTimeout`'s
/// `buildFetchShared`/`spawnFetch` — see those doc comments. An `errdefer`
/// declared inline in `postJsonSSE` would still be armed by the time
/// `shared.result` (an ordinary request failure, not a bug) propagates out
/// near the bottom of that function, double-freeing alongside the later
/// `defer freeStreamShared(...)`.
fn buildStreamShared(gpa: std.mem.Allocator, url: []const u8, extra_headers: []const http.Header, payload: []const u8, sink: SseLineSink) !*StreamShared {
    const shared = try gpa.create(StreamShared);
    errdefer gpa.destroy(shared);
    const url_copy = try gpa.dupe(u8, url);
    errdefer gpa.free(url_copy);
    const payload_copy = try gpa.dupe(u8, payload);
    errdefer gpa.free(payload_copy);
    const headers_copy = try dupeHeaders(gpa, extra_headers);
    errdefer freeHeaders(gpa, headers_copy);
    shared.* = .{ .url = url_copy, .payload = payload_copy, .extra_headers = headers_copy, .sink_guard = .{ .inner = sink } };
    return shared;
}

fn spawnStream(client: *http.Client, gpa: std.mem.Allocator, shared: *StreamShared) !std.Thread {
    errdefer freeStreamShared(gpa, shared);
    return std.Thread.spawn(.{}, streamJsonSSEAndFlag, .{ client, gpa, shared });
}

/// Like `postJson`, but for a Server-Sent-Events endpoint (`"stream":true`
/// set in `payload` by the caller) — invokes `sink.onLine` once per line
/// read from the response body as it arrives, instead of buffering the
/// whole response before returning. Each caller (the LLM provider adapters)
/// owns interpreting the lines itself, since SSE payload shapes differ per
/// API; this only handles the shared transport mechanics (connect, send,
/// read-loop, timeout) — same detach-on-timeout pattern as
/// `fetchWithTimeout`, just wrapping a read-loop instead of one blocking
/// `client.fetch()` call. See this file's module doc for why detaching
/// (not a blocking `Future.cancel`) is the safe choice here.
///
/// Unlike every other helper in this file, this does NOT retry on a
/// transient connection error once streaming has begun (any line already
/// reached `sink`) — retrying from scratch after the caller has already
/// acted on partial data (e.g. edited it into a chat message, or started
/// accumulating a tool call's arguments) would silently corrupt whatever
/// state it's built up so far. A failure after the first line is a hard
/// error, same as any other request failure the caller (`toolcall.run` via
/// the LLM provider adapters) already knows how to surface.
///
/// `allocator` is accepted for API-compatibility with existing callers but
/// deliberately unused — see `StreamShared`'s doc comment for why the
/// implementation only ever uses `client.allocator` now.
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
    const gpa = client.allocator;
    const shared = try buildStreamShared(gpa, url, extra_headers, payload, sink);
    const thread = try spawnStream(client, gpa, shared);

    var waited_ns: u64 = 0;
    while (!shared.done.load(.acquire) and waited_ns < timeout_ns) {
        const step = @min(poll_interval_ns, timeout_ns - waited_ns);
        Io.sleep(client.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
        waited_ns += step;
    }

    if (shared.done.load(.acquire)) {
        thread.join();
        defer freeStreamShared(gpa, shared);
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
        // Matches `fetch()`'s own POST-with-payload default (it overrides
        // `RequestOptions`'s plain "follow 3 redirects" default to
        // `.unhandled` whenever a payload is present) — re-sending a POST
        // body after a redirect isn't something to do implicitly.
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
        std.log.err("POST {s} -> {d}: {s}", .{
            redactUrl(&url_buf, url),
            @intFromEnum(response.head.status),
            shown[0..@min(shown.len, max_logged_body)],
        });
        return error.HttpRequestFailed;
    }

    // Sized to comfortably hold one SSE line (a large streamed tool-call
    // argument fragment, say) — `takeDelimiterExclusive` fails with
    // `error.StreamTooLong` if a single line exceeds this.
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
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // Accepts the connection and then goes silent forever: no read, no
    // write, no close. This is exactly what the real remote peer did in
    // production — not a connection error (which already retries/fails
    // fast), but a peer that looks alive and simply never answers. That's
    // the one failure mode `std.http.Client` has no way to bound on its
    // own (see this file's module doc), and the one the old
    // `Io.concurrent` + `Future.cancel` implementation couldn't actually
    // escape either, since cancellation only fires at `Io`-native
    // cancelation points that a stuck raw socket read never reaches.
    const Acceptor = struct {
        fn run(srv: *Io.net.Server, accept_io: Io) void {
            var conn = srv.accept(accept_io) catch return;
            defer conn.socket.close(accept_io);
            Io.sleep(accept_io, .fromSeconds(30), .awake) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Acceptor.run, .{ &server, io });
    defer thread.detach();

    // Deliberately not `testing.allocator` and no `client.deinit()` below:
    // this test's whole point is that the fetch thread gets abandoned
    // still holding a live connection out of `client`'s pool, which is
    // exactly the state `deinit()` asserts never happens
    // (`connection_pool.used.first == null`) and which `testing.allocator`
    // would report as a leak. Both are correct, expected consequences of
    // this one deliberate, bounded leak — see this file's module doc — not
    // bugs to paper over.
    var client: http.Client = .{ .allocator = std.heap.page_allocator, .io = io };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    const started = Io.Timestamp.now(io, .real);
    const result = getWithTimeout(&client, testing.allocator, url, 300 * std.time.ns_per_ms);
    const elapsed_ns = Io.Timestamp.now(io, .real).toNanoseconds() - started.toNanoseconds();

    try testing.expectError(error.RequestTimedOut, result);
    // Generous upper bound — this asserts "didn't hang indefinitely," not
    // exact timing. Failing here means the timeout mechanism regressed
    // back to blocking on the stuck peer instead of detaching from it.
    try testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

/// Reads `reader` line-by-line until end of stream, handing each one
/// (delimiter stripped) to `sink.onLine`. Split out from `postJsonSSEOnce`
/// so it's testable against an in-memory reader — no real socket needed —
/// since this exact loop previously had a real, severe bug: using
/// `takeDelimiterExclusive` instead of `takeDelimiterInclusive`.
/// `takeDelimiterExclusive` does NOT consume the delimiter itself (see its
/// own doc comment: advances "up to but not past" it), so every line's
/// `\n` was left sitting unconsumed in the buffer — the next call re-found
/// that same already-buffered byte and returned an empty match instantly,
/// forever: a genuine zero-progress spin burning 100% CPU. Confirmed live
/// against the real router: thousands of 0-byte "lines" per millisecond
/// after the first real chunk, every time a blank SSE separator line
/// (`data: {...}\n\n` — completely normal, standard SSE framing) was hit.
/// `takeDelimiterInclusive` actually advances past the delimiter each call,
/// so real progress is always made; the delimiter (and a preceding `\r`,
/// if present) is trimmed off below instead of relied on to be absent.
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

const testing = std.testing;

const LineRecorder = struct {
    lines: std.ArrayList([]const u8) = .empty,

    fn sink(self: *LineRecorder) SseLineSink {
        return .{ .ptr = self, .onLine = onLine };
    }
    fn onLine(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *LineRecorder = @ptrCast(@alignCast(ptr));
        // Bounds a would-be regression: an infinite zero-progress loop
        // (see `drainSseLines`'s doc comment) would blow way past any
        // real SSE stream's line count long before a test runner's own
        // timeout ever kicked in, so failing fast here turns "the test
        // suite hangs" into a normal, readable assertion failure.
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

    // The final line has no trailing delimiter, so it's silently dropped
    // (matches `takeDelimiterInclusive`'s documented EndOfStream
    // behavior) rather than looped on or fabricated — real SSE streams
    // always end on a clean blank line, so this only matters for a
    // connection that dies mid-line, where there's nothing sensible to
    // return anyway.
    try testing.expectEqual(@as(usize, 2), recorder.lines.items.len);
    try testing.expectEqualStrings("data: x", recorder.lines.items[0]);
    try testing.expectEqualStrings("", recorder.lines.items[1]);
}
