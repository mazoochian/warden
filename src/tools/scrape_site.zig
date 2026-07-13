//! Extracts clean, readable text from a web page — unlike `fetch_url`,
//! which hands back raw markup, this strips tags/scripts/nav and can
//! follow same-site links a couple of pages deep. Two backends, selected
//! by the owner via `/scraper` (see `store/scraper_settings.zig`):
//!
//!  - `local` (default): fetches and parses HTML on-device with
//!    `html_extract.zig`. No third-party dependency, works out of the box.
//!  - `remote`: POSTs `{"url", "max_pages"}` as JSON to an owner-configured
//!    endpoint and returns its response body verbatim. Lets the owner
//!    delegate to a headless-browser/JS-rendering scraping service
//!    (Firecrawl, ScrapingBee, a self-hosted browserless+readability
//!    setup, a katana-based crawler, etc.) for sites the local extractor
//!    can't handle (client-side-rendered pages, bot-walled sites).

const std = @import("std");
const http = std.http;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");
const html_extract = @import("html_extract.zig");

const Args = struct {
    url: []const u8,
    /// How many same-site pages to visit, breadth-first from `url`
    /// following the links found on each page. Clamped to [1, max_pages_cap].
    max_pages: i64 = 1,
};

const max_pages_cap: i64 = 5;
/// Per-page text cap before concatenation, so one bloated page in a
/// multi-page crawl can't crowd out the rest.
const max_page_text_len = 4000;
/// Overall cap on the local-mode result.
const max_total_len = 12000;
/// Cap on a remote scraper's response body.
const max_remote_body_len = 12000;
/// How many extra same-page links to surface for follow-up when only one
/// page was scraped (skipped for multi-page crawls — the frontier already
/// consumed the interesting ones).
const max_shown_links = 8;

pub const tool: registry.ToolDef = .{
    .name = "scrape_site",
    .description = "Fetches a web page and returns clean readable text (title + body, with tags/scripts/nav markup stripped) instead of raw HTML — prefer this over fetch_url when you want to actually read a page's content. Optionally crawls a few same-site pages breadth-first via max_pages. Runs on-device by default; the bot owner can point it at an external scraping service instead via /scraper.",
    .input_schema_json =
        \\{"type":"object","properties":{"url":{"type":"string","description":"A fully-qualified http(s) URL"},"max_pages":{"type":"integer","description":"How many same-site pages to visit, following links breadth-first from url (1-5, default 1)."}},"required":["url"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try std.json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const url = parsed.value.url;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.UnsupportedUrlScheme;
    }

    var mp = parsed.value.max_pages;
    if (mp < 1) mp = 1;
    if (mp > max_pages_cap) mp = max_pages_cap;
    const max_pages: usize = @intCast(mp);

    if (ctx.scraper.mode == .remote) {
        const endpoint = ctx.scraper.remote_url orelse return error.RemoteScraperNotConfigured;
        return scrapeRemote(ctx, endpoint, ctx.scraper.remote_api_key, url, max_pages);
    }
    return scrapeLocal(ctx, url, max_pages);
}

const Fetched = struct { url: []const u8, page: html_extract.Page };

/// The seed page has to be fetched (and its links extracted) before we
/// know what else is even worth fetching, so it alone is sequential; every
/// page after that is an independent sibling in the crawl frontier (all
/// discovered from the seed page's own links, not each other's), so they
/// fan out concurrently instead of one after another. This matters a lot
/// for total latency: sequential, `max_pages` slow/unreachable pages sum
/// their timeouts (5 x `tool_timeout_ns` is nearly 2 minutes for one tool
/// call); concurrent, the whole fan-out takes as long as the single
/// slowest page, not the sum — confirmed in production as the actual cause
/// of a "stuck thinking" report that was really just a multi-page scrape
/// taking minutes the sequential way.
fn scrapeLocal(ctx: registry.ToolContext, start_url: []const u8, max_pages: usize) ![]const u8 {
    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const seed_body = try http_util.getWithTimeout(&client, ctx.allocator, start_url, http_util.tool_timeout_ns);
    defer ctx.allocator.free(seed_body);
    const seed_page = try html_extract.extract(ctx.allocator, seed_body, start_url, .{});

    var fetched: std.ArrayList(Fetched) = .empty;
    try fetched.append(ctx.allocator, .{ .url = start_url, .page = seed_page });

    if (max_pages > 1) {
        var targets: std.ArrayList([]const u8) = .empty;
        for (seed_page.links) |link| {
            if (targets.items.len >= max_pages - 1) break;
            if (!sameHost(start_url, link)) continue;
            // A link back to the seed page itself (e.g. a "Home" nav link
            // to "/"), or the same link appearing twice on the page,
            // would otherwise be fetched again as if it were a distinct
            // page — dropped this dedup when the crawl stopped being
            // sequential-with-a-`visited`-list; still needed here.
            if (std.mem.eql(u8, link, start_url) or containsString(targets.items, link)) continue;
            try targets.append(ctx.allocator, link);
        }
        if (targets.items.len > 0) {
            try fetchConcurrently(ctx.allocator, ctx.io, &client, targets.items, &fetched);
        }
    }

    return formatPages(ctx.allocator, fetched.items, max_pages);
}

/// Result of one concurrently-fetched page. Deliberately allocator-free of
/// `ctx.allocator` (the caller's arena) — see `fetchOnePage`'s doc comment.
const ConcurrentFetchResult = struct { url: []const u8, page: ?html_extract.Page };

/// Runs on a real OS thread (spawned via `Io.concurrent`) alongside every
/// other in-flight fetch, so — same reasoning as `main.zig`'s ticker fix —
/// it must NOT touch `ctx.allocator` (the per-message arena): concurrent
/// allocation into an arena from multiple threads corrupts its bookkeeping
/// with no error or crash to point at, just a mysteriously broken result.
/// `std.heap.page_allocator` is thread-safe and every allocation here is
/// explicitly freed by the caller once collected back on the single
/// calling thread (see `fetchConcurrently`), so nothing leaks.
fn fetchOnePage(client: *http.Client, url: []const u8) ConcurrentFetchResult {
    const pa = std.heap.page_allocator;
    const body = http_util.getWithTimeout(client, pa, url, http_util.tool_timeout_ns) catch {
        return .{ .url = url, .page = null };
    };
    defer pa.free(body);
    const page = html_extract.extract(pa, body, url, .{}) catch {
        return .{ .url = url, .page = null };
    };
    return .{ .url = url, .page = page };
}

/// Fetches every URL in `targets` concurrently and appends successes to
/// `out` (dupe'd into `allocator` — the caller's arena, safe here since by
/// the time each `Future.await` returns, that specific task has already
/// fully finished and nothing is touching `page_allocator`-owned memory
/// concurrently with this thread anymore). A page that fails just doesn't
/// appear in `out` — best-effort, matching the old sequential crawl's
/// "one fewer page in the result" behavior for a mid-crawl failure.
fn fetchConcurrently(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *http.Client,
    targets: []const []const u8,
    out: *std.ArrayList(Fetched),
) !void {
    var futures = try allocator.alloc(std.Io.Future(ConcurrentFetchResult), targets.len);
    for (targets, 0..) |target_url, i| {
        futures[i] = try std.Io.concurrent(io, fetchOnePage, .{ client, target_url });
    }
    for (futures) |*f| {
        const result = f.await(io);
        const page = result.page orelse continue;
        defer page.deinit(std.heap.page_allocator);
        try out.append(allocator, .{
            .url = try allocator.dupe(u8, result.url),
            .page = .{
                .title = try allocator.dupe(u8, page.title),
                .text = try allocator.dupe(u8, page.text),
                .links = try dupeLinks(allocator, page.links),
            },
        });
    }
}

fn dupeLinks(allocator: std.mem.Allocator, links: [][]const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, links.len);
    for (links, 0..) |l, i| out[i] = try allocator.dupe(u8, l);
    return out;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

fn sameHost(url_a: []const u8, url_b: []const u8) bool {
    const a = std.Uri.parse(url_a) catch return false;
    const b = std.Uri.parse(url_b) catch return false;
    var a_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var b_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_a = a.getHost(&a_buf) catch return false;
    const host_b = b.getHost(&b_buf) catch return false;
    return std.ascii.eqlIgnoreCase(host_a.bytes, host_b.bytes);
}

/// Renders fetched pages as the tool's text result. Split from
/// `scrapeLocal` so it's testable without a live HTTP fetch.
fn formatPages(allocator: std.mem.Allocator, pages: []const Fetched, requested_max_pages: usize) ![]const u8 {
    if (pages.len == 0) return error.ScrapeFailed;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    for (pages, 0..) |f, idx| {
        if (idx > 0) try w.writeAll("\n\n");
        const title = if (f.page.title.len > 0) f.page.title else "(untitled)";
        const text = if (f.page.text.len > max_page_text_len) f.page.text[0..max_page_text_len] else f.page.text;
        try w.print("=== {s} ({s}) ===\n{s}", .{ title, f.url, text });
        if (f.page.text.len > max_page_text_len) try w.writeAll("\n[page truncated]");
    }

    // Only worth surfacing follow-up links when the crawl didn't already
    // exhaust the frontier itself.
    if (pages.len == 1 and requested_max_pages == 1 and pages[0].page.links.len > 0) {
        try w.writeAll("\n\nOther links on this page:\n");
        const links = pages[0].page.links;
        const shown = @min(links.len, max_shown_links);
        for (links[0..shown]) |link| try w.print("- {s}\n", .{link});
    }

    const out = buf.writer.buffered();
    if (out.len <= max_total_len) return allocator.dupe(u8, out);
    return std.fmt.allocPrint(allocator, "{s}\n\n[truncated, {d} bytes total]", .{ out[0..max_total_len], out.len });
}

fn scrapeRemote(
    ctx: registry.ToolContext,
    endpoint: []const u8,
    api_key: ?[]const u8,
    url: []const u8,
    max_pages: usize,
) ![]const u8 {
    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const payload = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .url = url, .max_pages = max_pages }, .{});
    defer ctx.allocator.free(payload);

    var headers_buf: [1]http.Header = undefined;
    var headers: []const http.Header = &.{};
    var auth_value: ?[]const u8 = null;
    defer if (auth_value) |v| ctx.allocator.free(v);
    if (api_key) |key| {
        auth_value = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{key});
        headers_buf[0] = .{ .name = "Authorization", .value = auth_value.? };
        headers = headers_buf[0..1];
    }

    const body = try http_util.postJson(&client, ctx.allocator, endpoint, headers, payload);
    defer ctx.allocator.free(body);

    if (body.len <= max_remote_body_len) return ctx.allocator.dupe(u8, body);
    return std.fmt.allocPrint(ctx.allocator, "{s}\n\n[truncated, {d} bytes total]", .{ body[0..max_remote_body_len], body.len });
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "execute rejects a non-http(s) url before touching the network" {
    const ctx = registry.ToolContext{ .allocator = testing.allocator, .io = testing.io };
    try testing.expectError(error.UnsupportedUrlScheme, execute(ctx, "{\"url\":\"ftp://example.com\"}"));
}

test "execute in remote mode without a configured endpoint fails clearly" {
    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = testing.io,
        .scraper = .{ .mode = .remote, .remote_url = null },
    };
    try testing.expectError(error.RemoteScraperNotConfigured, execute(ctx, "{\"url\":\"https://example.com\"}"));
}

test "formatPages renders title/url/text blocks and appends follow-up links for a single page" {
    var page = try html_extract.extract(
        testing.allocator,
        "<title>Home</title><p>Welcome.</p><a href=\"/about\">About</a>",
        "https://example.com/",
        .{},
    );
    defer page.deinit(testing.allocator);

    const pages = [_]Fetched{.{ .url = "https://example.com/", .page = page }};
    const out = try formatPages(testing.allocator, &pages, 1);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "=== Home (https://example.com/) ===") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Welcome.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Other links on this page:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.com/about") != null);
}

test "formatPages omits the follow-up link list for a multi-page crawl" {
    var page = try html_extract.extract(testing.allocator, "<title>P1</title><p>one</p>", "https://example.com/a", .{});
    defer page.deinit(testing.allocator);
    var page2 = try html_extract.extract(testing.allocator, "<title>P2</title><p>two</p>", "https://example.com/b", .{});
    defer page2.deinit(testing.allocator);

    const pages = [_]Fetched{
        .{ .url = "https://example.com/a", .page = page },
        .{ .url = "https://example.com/b", .page = page2 },
    };
    const out = try formatPages(testing.allocator, &pages, 2);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "=== P1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "=== P2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Other links on this page:") == null);
}

test "formatPages errors when nothing was fetched" {
    try testing.expectError(error.ScrapeFailed, formatPages(testing.allocator, &.{}, 1));
}

test "sameHost matches identical hosts and rejects different ones" {
    try testing.expect(sameHost("https://example.com/a", "https://example.com/b"));
    try testing.expect(sameHost("https://Example.com/a", "https://EXAMPLE.com/b"));
    try testing.expect(!sameHost("https://example.com/a", "https://other.example/b"));
}
