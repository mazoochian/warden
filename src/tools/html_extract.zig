//! Minimal, dependency-free HTML → text extraction: strips tags/scripts/
//! styles, decodes common entities, collapses whitespace into readable
//! paragraphs, and pulls out the page title plus a deduplicated list of
//! same-page links (resolved to absolute URLs). Not a spec-compliant HTML
//! parser — a single forward byte scan good enough for "read this page"
//! purposes, in the same spirit as the rest of this codebase's tools.

const std = @import("std");
const Uri = std.Uri;

pub const Page = struct {
    title: []const u8,
    text: []const u8,
    links: [][]const u8,

    pub fn deinit(self: Page, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.text);
        for (self.links) |l| allocator.free(l);
        allocator.free(self.links);
    }
};

pub const ExtractOptions = struct {
    /// Bounds the link list so a page with hundreds of anchors can't blow
    /// up memory or crawl frontiers.
    max_links: usize = 30,
};

/// Extracts readable text/title/links from `html`. `base_url` is the page's
/// own URL, used to resolve relative `href`s to absolute ones; link
/// extraction is silently skipped (empty list) if it doesn't parse.
pub fn extract(allocator: std.mem.Allocator, html: []const u8, base_url: []const u8, opts: ExtractOptions) !Page {
    const base: ?Uri = Uri.parse(base_url) catch null;

    var body_out: TextBuilder = .init(allocator);
    errdefer body_out.deinit();
    var title_out: TextBuilder = .init(allocator);
    errdefer title_out.deinit();

    var links: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (links.items) |l| allocator.free(l);
        links.deinit(allocator);
    }

    var in_title = false;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            const run_end = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            const dest = if (in_title) &title_out else &body_out;
            try dest.writeText(html[i..run_end]);
            i = run_end;
            continue;
        }

        const end = tagEnd(html, i);
        const inner = html[i + 1 .. @min(end, html.len)];
        const closing = isClosingTag(inner);
        const raw_name = tagName(inner);

        var name_buf: [16]u8 = undefined;
        const name = std.ascii.lowerString(&name_buf, raw_name[0..@min(raw_name.len, name_buf.len)]);

        if (isRawTextTag(name)) {
            if (!closing) {
                i = skipRawTextElement(html, end, name) + 1;
                continue;
            }
            i = end + 1;
            continue;
        }

        if (std.mem.eql(u8, name, "title")) {
            in_title = !closing;
            i = end + 1;
            continue;
        }

        if (!closing and std.mem.eql(u8, name, "a") and links.items.len < opts.max_links) {
            if (extractHref(inner)) |href| {
                if (base) |b| {
                    if (try resolveHref(allocator, b, href)) |resolved| {
                        if (containsString(links.items, resolved)) {
                            allocator.free(resolved);
                        } else {
                            try links.append(allocator, resolved);
                        }
                    }
                }
            }
        }

        // A newline on both the open and close of a block tag, not just the
        // close, so two adjacent block elements with no whitespace between
        // them in the source (e.g. "</a><p>") don't run their text together.
        if ((isBlockTag(name) and !std.mem.eql(u8, name, "br")) or (!closing and std.mem.eql(u8, name, "br"))) {
            try body_out.writeNewline();
        }

        i = end + 1;
    }

    const title_text = std.mem.trim(u8, title_out.buffered(), " \t\r\n");
    const title_owned = try allocator.dupe(u8, title_text);
    errdefer allocator.free(title_owned);
    title_out.deinit();

    const body_text = std.mem.trim(u8, body_out.buffered(), " \t\r\n");
    const body_owned = try allocator.dupe(u8, body_text);
    errdefer allocator.free(body_owned);
    body_out.deinit();

    return .{ .title = title_owned, .text = body_owned, .links = try links.toOwnedSlice(allocator) };
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// Accumulates text with runs of whitespace collapsed to a single space and
/// block-tag boundaries collapsed to a single newline, so paragraph
/// structure survives without leaving a wall of blank lines.
const TextBuilder = struct {
    w: std.Io.Writer.Allocating,
    last: enum { start, space, newline, other } = .start,

    fn init(allocator: std.mem.Allocator) TextBuilder {
        return .{ .w = .init(allocator) };
    }

    fn deinit(self: *TextBuilder) void {
        self.w.deinit();
    }

    fn buffered(self: *TextBuilder) []const u8 {
        return self.w.writer.buffered();
    }

    fn writeNewline(self: *TextBuilder) !void {
        if (self.last == .newline or self.last == .start) return;
        try self.w.writer.writeByte('\n');
        self.last = .newline;
    }

    /// For a codepoint decoded from an entity (`&amp;`, `&#233;`, ...) —
    /// always needs UTF-8 encoding since it isn't already source bytes.
    fn writeCodepoint(self: *TextBuilder, cp: u21) !void {
        if (cp < 0x80) return self.writeAsciiByte(@intCast(cp));
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.w.writer.writeAll(buf[0..n]);
        self.last = .other;
    }

    /// For a single ASCII byte from the source (or an entity that decoded
    /// to one) — collapses runs of whitespace, everything else passes
    /// through as-is.
    fn writeAsciiByte(self: *TextBuilder, c: u8) !void {
        switch (c) {
            ' ', '\t', '\r' => {
                if (self.last == .space or self.last == .newline or self.last == .start) return;
                try self.w.writer.writeByte(' ');
                self.last = .space;
            },
            '\n' => try self.writeNewline(),
            else => {
                try self.w.writer.writeByte(c);
                self.last = .other;
            },
        }
    }

    /// Writes a raw HTML text run, decoding entities as it goes. Bytes
    /// >= 0x80 are passed straight through: they're already valid UTF-8 in
    /// the source (this isn't ASCII-only content), not one-byte-per-
    /// codepoint data — re-encoding them individually as codepoints would
    /// mangle every multi-byte character.
    fn writeText(self: *TextBuilder, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '&') {
                if (decodeEntityAt(text, i)) |decoded| {
                    try self.writeCodepoint(decoded.ch);
                    i += decoded.len;
                    continue;
                }
            }
            if (c < 0x80) {
                try self.writeAsciiByte(c);
            } else {
                try self.w.writer.writeByte(c);
                self.last = .other;
            }
            i += 1;
        }
    }
};

/// Finds the index of the `>` that closes the tag starting at `html[start]`
/// (which must be `<`), treating `>` inside a quoted attribute value as
/// content rather than the terminator.
fn tagEnd(html: []const u8, start: usize) usize {
    var i = start + 1;
    var quote: u8 = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '>' => return i,
            else => {},
        }
    }
    return html.len;
}

fn isClosingTag(tag_inner: []const u8) bool {
    return tag_inner.len > 0 and tag_inner[0] == '/';
}

fn tagName(tag_inner: []const u8) []const u8 {
    var i: usize = 0;
    if (i < tag_inner.len and tag_inner[i] == '/') i += 1;
    const start = i;
    while (i < tag_inner.len and std.ascii.isAlphanumeric(tag_inner[i])) : (i += 1) {}
    return tag_inner[start..i];
}

fn isRawTextTag(name: []const u8) bool {
    return std.mem.eql(u8, name, "script") or std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "noscript");
}

const block_tags = [_][]const u8{
    "p", "div", "li", "br", "h1", "h2", "h3", "h4", "h5", "h6",
    "tr", "section", "article", "header", "footer", "nav", "ul", "ol", "table", "blockquote", "pre",
};

fn isBlockTag(name: []const u8) bool {
    for (block_tags) |t| if (std.mem.eql(u8, name, t)) return true;
    return false;
}

/// `html[tag_end]` is the `>` of the just-seen opening `<script>`/`<style>`/
/// `<noscript>` tag; returns the index of the `>` that closes its matching
/// end tag (or `html.len - 1` if the element is never closed).
fn skipRawTextElement(html: []const u8, tag_end: usize, name: []const u8) usize {
    var close_marker_buf: [12]u8 = undefined;
    const close_marker = std.fmt.bufPrint(&close_marker_buf, "</{s}", .{name}) catch return html.len - 1;

    const close_start = std.ascii.findIgnoreCasePos(html, tag_end + 1, close_marker) orelse return html.len - 1;
    return tagEnd(html, close_start);
}

/// Looks for an `href` attribute inside `tag_inner` (the `<a ...>` tag's
/// content, excluding the angle brackets) and returns its raw value.
fn extractHref(tag_inner: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 4 <= tag_inner.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(tag_inner[i .. i + 4], "href")) continue;
        // Reject a match inside a longer attribute name like "data-href".
        if (i > 0 and (std.ascii.isAlphanumeric(tag_inner[i - 1]) or tag_inner[i - 1] == '-')) continue;

        var j = i + 4;
        while (j < tag_inner.len and tag_inner[j] == ' ') : (j += 1) {}
        if (j >= tag_inner.len or tag_inner[j] != '=') continue;
        j += 1;
        while (j < tag_inner.len and tag_inner[j] == ' ') : (j += 1) {}
        if (j >= tag_inner.len) return null;

        if (tag_inner[j] == '"' or tag_inner[j] == '\'') {
            const quote = tag_inner[j];
            const start = j + 1;
            const value_end = std.mem.indexOfScalarPos(u8, tag_inner, start, quote) orelse tag_inner.len;
            return tag_inner[start..value_end];
        }
        const start = j;
        var k = start;
        while (k < tag_inner.len and tag_inner[k] != ' ' and tag_inner[k] != '\t') : (k += 1) {}
        return tag_inner[start..k];
    }
    return null;
}

const ignored_href_schemes = [_][]const u8{ "javascript:", "mailto:", "tel:", "data:", "ftp:" };

/// Resolves `href` (found on the page at `base`) to an absolute http(s)
/// URL, or null for anchors/unsupported schemes/anything that fails to
/// resolve. Deliberately not a full RFC 3986 resolver (no `.`/`..`
/// normalization) — good enough for the anchors real pages actually emit.
fn resolveHref(allocator: std.mem.Allocator, base: Uri, href: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, href, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    for (ignored_href_schemes) |scheme| {
        if (std.ascii.startsWithIgnoreCase(trimmed, scheme)) return null;
    }

    if (std.ascii.startsWithIgnoreCase(trimmed, "http://") or std.ascii.startsWithIgnoreCase(trimmed, "https://")) {
        return try allocator.dupe(u8, trimmed);
    }

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = base.getHost(&host_buf) catch return null;

    var port_buf: [8]u8 = undefined;
    const port_str = if (base.port) |p| (std.fmt.bufPrint(&port_buf, ":{d}", .{p}) catch "") else "";

    if (std.mem.startsWith(u8, trimmed, "//")) {
        return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ base.scheme, trimmed });
    }
    if (trimmed[0] == '/') {
        return try std.fmt.allocPrint(allocator, "{s}://{s}{s}{s}", .{ base.scheme, host.bytes, port_str, trimmed });
    }

    var path_buf: [2048]u8 = undefined;
    const base_path = base.path.toRaw(&path_buf) catch return null;
    const dir = if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |idx| base_path[0 .. idx + 1] else "/";
    return try std.fmt.allocPrint(allocator, "{s}://{s}{s}{s}{s}", .{ base.scheme, host.bytes, port_str, dir, trimmed });
}

const named_entities = .{
    .{ "amp", '&' },  .{ "lt", '<' },   .{ "gt", '>' },
    .{ "quot", '"' }, .{ "apos", '\'' }, .{ "nbsp", ' ' },
};

fn decodeEntityAt(text: []const u8, i: usize) ?struct { ch: u21, len: usize } {
    const rest = text[i + 1 ..];
    const scan_window = rest[0..@min(rest.len, 12)];
    const semi = std.mem.indexOfScalar(u8, scan_window, ';') orelse return null;
    const name = rest[0..semi];
    if (name.len == 0) return null;
    const total_len = 1 + semi + 1;

    if (name[0] == '#') {
        if (name.len < 2) return null;
        const code = if (name[1] == 'x' or name[1] == 'X')
            std.fmt.parseInt(u21, name[2..], 16) catch return null
        else
            std.fmt.parseInt(u21, name[1..], 10) catch return null;
        return .{ .ch = code, .len = total_len };
    }

    inline for (named_entities) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return .{ .ch = pair[1], .len = total_len };
    }
    return null;
}

const testing = std.testing;

test "extract strips tags, scripts and styles, and decodes entities" {
    const html =
        \\<html><head><title>  Example &amp; Co  </title><style>body{color:red}</style></head>
        \\<body><script>alert('x')</script>
        \\<h1>Hello &amp; welcome</h1>
        \\<p>First   paragraph &mdash; unknown entity kept, nbsp:&nbsp;here.</p>
        \\<p>Second paragraph.</p>
        \\</body></html>
    ;
    const page = try extract(testing.allocator, html, "https://example.com/blog/post", .{});
    defer page.deinit(testing.allocator);

    try testing.expectEqualStrings("Example & Co", page.title);
    try testing.expect(std.mem.indexOf(u8, page.text, "<") == null);
    try testing.expect(std.mem.indexOf(u8, page.text, "alert") == null);
    try testing.expect(std.mem.indexOf(u8, page.text, "color:red") == null);
    try testing.expect(std.mem.indexOf(u8, page.text, "Hello & welcome") != null);
    try testing.expect(std.mem.indexOf(u8, page.text, "First paragraph &mdash; unknown entity kept, nbsp: here.") != null);
    try testing.expect(std.mem.indexOf(u8, page.text, "Second paragraph.") != null);
}

test "extract resolves relative, root-relative, protocol-relative and absolute links" {
    const html =
        \\<a href="/about">About</a>
        \\<a href="pricing.html">Pricing</a>
        \\<a href="https://other.example/x">Other</a>
        \\<a href="//cdn.example.com/lib.js">CDN</a>
        \\<a href="#section">Skip</a>
        \\<a href="mailto:hi@example.com">Mail</a>
        \\<a href="/about">Dup</a>
    ;
    const page = try extract(testing.allocator, html, "https://example.com/blog/post", .{});
    defer page.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), page.links.len);
    try testing.expectEqualStrings("https://example.com/about", page.links[0]);
    try testing.expectEqualStrings("https://example.com/blog/pricing.html", page.links[1]);
    try testing.expectEqualStrings("https://other.example/x", page.links[2]);
    try testing.expectEqualStrings("https://cdn.example.com/lib.js", page.links[3]);
}

test "extract caps the number of links collected" {
    var html_buf: std.ArrayList(u8) = .empty;
    defer html_buf.deinit(testing.allocator);
    for (0..50) |n| {
        try html_buf.print(testing.allocator, "<a href=\"/p{d}\">p{d}</a>\n", .{ n, n });
    }
    const page = try extract(testing.allocator, html_buf.items, "https://example.com/", .{ .max_links = 5 });
    defer page.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), page.links.len);
}

test "extract passes multi-byte UTF-8 source text through unmangled" {
    const html = "<p>⚡ Zig is fast — پیام فارسی here.</p>";
    const page = try extract(testing.allocator, html, "https://example.com/", .{});
    defer page.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, page.text, "⚡ Zig is fast") != null);
    try testing.expect(std.mem.indexOf(u8, page.text, "پیام فارسی here.") != null);
}

test "extract handles a page with no matching base url gracefully" {
    const page = try extract(testing.allocator, "<a href=\"/x\">x</a><p>text</p>", "not a url", .{});
    defer page.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), page.links.len);
    try testing.expectEqualStrings("x\ntext", page.text);
}
