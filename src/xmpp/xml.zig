//! A deliberately small, hand-rolled XML parser for the specific stanza
//! shapes XMPP's client-server protocol needs — same "purpose-built, not
//! general" philosophy as `features/feed_parse.zig`'s RSS/Atom parser: no
//! namespace handling (`xmlns` is just another attribute), no DTD/comment/
//! CDATA support, and both attribute quote styles plus the five standard
//! entities and numeric character references, since those genuinely appear
//! in real servers' output.
//!
//! Operates on a complete in-memory buffer rather than a true streaming
//! reader: `xmpp/client.zig` accumulates bytes from the socket into a
//! growing buffer and repeatedly calls `parseElement`, which returns
//! `error.Incomplete` (not a real error) until the buffer holds one full
//! top-level element — the caller reads more bytes and retries. This keeps
//! the parser itself simple and independently testable against fixed
//! strings.

const std = @import("std");

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = union(enum) {
    element: Element,
    text: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attrs: []const Attr,
    children: []const Node,

    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    /// First direct child element with this name, if any — doesn't look
    /// inside grandchildren (every stanza shape this parser targets only
    /// ever needs one level of nesting to inspect at a time).
    pub fn child(self: Element, name: []const u8) ?Element {
        for (self.children) |node| switch (node) {
            .element => |e| if (std.mem.eql(u8, e.name, name)) return e,
            .text => {},
        };
        return null;
    }

    /// Concatenation of every direct text child — e.g. a `<body>`'s message
    /// text. Nested elements' text doesn't contribute.
    pub fn text(self: Element, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.children) |node| switch (node) {
            .text => |t| try out.appendSlice(allocator, t),
            .element => {},
        };
        return out.toOwnedSlice(allocator);
    }
};

pub const ParseError = error{ Incomplete, Malformed } || std.mem.Allocator.Error;

/// Owns the arena every allocation in `element` came from — mirrors
/// `std.json.Parsed(T)`, the pattern `matrix/types.zig` already uses for
/// parsed results elsewhere in this codebase.
pub const ParsedElement = struct {
    arena: std.heap.ArenaAllocator,
    element: Element,
    /// Bytes of the input buffer this element consumed, including its
    /// closing tag — the caller advances its read buffer by this much.
    consumed: usize,

    pub fn deinit(self: *ParsedElement) void {
        self.arena.deinit();
    }
};

fn isNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ':' or c == '-' or c == '_' or c == '.';
}

fn skipWs(buf: []const u8, pos: usize) usize {
    var p = pos;
    while (p < buf.len and std.ascii.isWhitespace(buf[p])) p += 1;
    return p;
}

/// Skips a leading `<?xml ... ?>` declaration, if present — real servers
/// include one before their own stream-open tag.
fn skipXmlDecl(buf: []const u8, pos: usize) usize {
    var p = skipWs(buf, pos);
    if (std.mem.startsWith(u8, buf[p..], "<?xml")) {
        if (std.mem.indexOfPos(u8, buf, p, "?>")) |end| {
            p = skipWs(buf, end + 2);
        }
    }
    return p;
}

fn parseName(buf: []const u8, pos: usize) ParseError!struct { name: []const u8, next: usize } {
    const start = pos;
    var p = pos;
    while (p < buf.len and isNameByte(buf[p])) p += 1;
    if (p >= buf.len) return error.Incomplete;
    if (p == start) return error.Malformed;
    return .{ .name = buf[start..p], .next = p };
}

const AttrsResult = struct { attrs: []const Attr, next: usize, self_close: bool };

/// Parses `name="value"` pairs (either quote style) up to the tag's closing
/// `>` or self-closing `/>`. `pos` must point just past the element name.
fn parseAttrs(allocator: std.mem.Allocator, buf: []const u8, pos: usize) ParseError!AttrsResult {
    var list: std.ArrayList(Attr) = .empty;
    var p = pos;
    while (true) {
        p = skipWs(buf, p);
        if (p >= buf.len) return error.Incomplete;
        if (buf[p] == '/') {
            if (p + 1 >= buf.len) return error.Incomplete;
            if (buf[p + 1] != '>') return error.Malformed;
            return .{ .attrs = try list.toOwnedSlice(allocator), .next = p + 2, .self_close = true };
        }
        if (buf[p] == '>') {
            return .{ .attrs = try list.toOwnedSlice(allocator), .next = p + 1, .self_close = false };
        }

        const name_res = try parseName(buf, p);
        p = skipWs(buf, name_res.next);
        if (p >= buf.len) return error.Incomplete;
        if (buf[p] != '=') return error.Malformed;
        p = skipWs(buf, p + 1);
        if (p >= buf.len) return error.Incomplete;
        const quote = buf[p];
        if (quote != '\'' and quote != '"') return error.Malformed;
        p += 1;
        const val_end = std.mem.indexOfScalarPos(u8, buf, p, quote) orelse return error.Incomplete;
        const value = try decodeEntities(allocator, buf[p..val_end]);
        try list.append(allocator, .{ .name = try allocator.dupe(u8, name_res.name), .value = value });
        p = val_end + 1;
    }
}

/// Parses one element (its name, attributes, and — if not self-closing —
/// children up to its matching end tag). `pos` must point just past the
/// element's opening `<`.
fn parseElementBody(allocator: std.mem.Allocator, buf: []const u8, pos: usize) ParseError!struct { element: Element, next: usize } {
    const name_res = try parseName(buf, pos);
    const name = try allocator.dupe(u8, name_res.name);
    const attrs_res = try parseAttrs(allocator, buf, name_res.next);

    if (attrs_res.self_close) {
        return .{ .element = .{ .name = name, .attrs = attrs_res.attrs, .children = &.{} }, .next = attrs_res.next };
    }

    var children: std.ArrayList(Node) = .empty;
    var p = attrs_res.next;
    var text_start = p;
    while (true) {
        if (p >= buf.len) return error.Incomplete;
        if (buf[p] != '<') {
            p += 1;
            continue;
        }

        if (p > text_start) {
            const decoded = try decodeEntities(allocator, buf[text_start..p]);
            if (decoded.len > 0) try children.append(allocator, .{ .text = decoded });
        }

        if (p + 1 < buf.len and buf[p + 1] == '/') {
            const close_name_start = p + 2;
            const gt = std.mem.indexOfScalarPos(u8, buf, close_name_start, '>') orelse return error.Incomplete;
            if (!std.mem.eql(u8, buf[close_name_start..gt], name)) return error.Malformed;
            return .{ .element = .{ .name = name, .attrs = attrs_res.attrs, .children = try children.toOwnedSlice(allocator) }, .next = gt + 1 };
        }
        if (p + 1 >= buf.len) return error.Incomplete;

        const child_res = try parseElementBody(allocator, buf, p + 1);
        try children.append(allocator, .{ .element = child_res.element });
        p = child_res.next;
        text_start = p;
    }
}

/// Parses one complete top-level element (e.g. `<message>...</message>`,
/// `<iq .../>`) from the start of `buf`, skipping leading whitespace.
/// `error.Incomplete` means `buf` doesn't yet hold a full element — the
/// normal outcome mid-stream, not a real failure; the caller should read
/// more bytes and retry with the same (or a longer) buffer.
pub fn parseElement(child_allocator: std.mem.Allocator, buf: []const u8) ParseError!ParsedElement {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const pos = skipWs(buf, 0);
    if (pos >= buf.len) return error.Incomplete;
    if (buf[pos] != '<') return error.Malformed;
    const body = try parseElementBody(a, buf, pos + 1);

    return .{ .arena = arena, .element = body.element, .consumed = body.next };
}

pub const OpenTag = struct {
    name: []const u8,
    attrs: []const Attr,

    pub fn attr(self: OpenTag, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

/// Owns the arena `open`'s fields were allocated from — same pattern as
/// `ParsedElement`.
pub const ParsedOpenTag = struct {
    arena: std.heap.ArenaAllocator,
    open: OpenTag,
    consumed: usize,

    pub fn deinit(self: *ParsedOpenTag) void {
        self.arena.deinit();
    }
};

/// Parses a start tag that is never expected to self-close or have its
/// matching end tag show up in the same buffer — the XMPP stream root
/// (`<stream:stream ...>`), which stays open for the connection's whole
/// lifetime. Skips a leading `<?xml ... ?>` declaration if present.
pub fn parseStreamOpenTag(child_allocator: std.mem.Allocator, buf: []const u8) ParseError!ParsedOpenTag {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const pos = skipXmlDecl(buf, 0);
    if (pos >= buf.len) return error.Incomplete;
    if (buf[pos] != '<') return error.Malformed;
    const name_res = try parseName(buf, pos + 1);
    const name = try a.dupe(u8, name_res.name);
    const attrs_res = try parseAttrs(a, buf, name_res.next);
    if (attrs_res.self_close) return error.Malformed;
    return .{ .arena = arena, .open = .{ .name = name, .attrs = attrs_res.attrs }, .consumed = attrs_res.next };
}

/// Unescapes the five standard XML entities plus numeric character
/// references (`&#NN;`/`&#xNN;`) — generous on the inbound-decode side
/// since we don't control what a real server sends.
fn decodeEntities(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return allocator.dupe(u8, raw);

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(allocator, raw[i]);
            i += 1;
            continue;
        }

        const named = [_]struct { name: []const u8, value: u8 }{
            .{ .name = "&amp;", .value = '&' },
            .{ .name = "&lt;", .value = '<' },
            .{ .name = "&gt;", .value = '>' },
            .{ .name = "&quot;", .value = '"' },
            .{ .name = "&apos;", .value = '\'' },
        };
        var matched = false;
        for (named) |e| {
            if (std.mem.startsWith(u8, raw[i..], e.name)) {
                try out.append(allocator, e.value);
                i += e.name.len;
                matched = true;
                break;
            }
        }
        if (!matched and std.mem.startsWith(u8, raw[i..], "&#")) {
            if (std.mem.indexOfScalarPos(u8, raw, i, ';')) |semi| {
                const digits_start = i + 2;
                const is_hex = digits_start < semi and (raw[digits_start] == 'x' or raw[digits_start] == 'X');
                const digits = if (is_hex) raw[digits_start + 1 .. semi] else raw[digits_start..semi];
                const codepoint = std.fmt.parseInt(u21, digits, if (is_hex) 16 else 10) catch null;
                if (codepoint) |cp| {
                    var utf8_buf: [4]u8 = undefined;
                    if (std.unicode.utf8Encode(cp, &utf8_buf)) |len| {
                        try out.appendSlice(allocator, utf8_buf[0..len]);
                        i = semi + 1;
                        matched = true;
                    } else |_| {}
                }
            }
        }
        if (!matched) {
            try out.append(allocator, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Escapes the characters unsafe inside a quoted XML attribute value.
pub fn writeEscapedAttr(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '\'' => try writer.writeAll("&apos;"),
        '<' => try writer.writeAll("&lt;"),
        else => try writer.writeByte(c),
    };
}

/// Escapes the characters unsafe inside XML element text content.
pub fn writeEscapedText(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        else => try writer.writeByte(c),
    };
}

const testing = std.testing;

test "parseElement parses a self-closing tag with no children" {
    var parsed = try parseElement(testing.allocator, "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
    defer parsed.deinit();
    try testing.expectEqualStrings("starttls", parsed.element.name);
    try testing.expectEqualStrings("urn:ietf:params:xml:ns:xmpp-tls", parsed.element.attr("xmlns").?);
    try testing.expectEqual(@as(usize, 0), parsed.element.children.len);
    try testing.expectEqual(@as(usize, 51), parsed.consumed);
}

test "parseElement handles both attribute quote styles" {
    var parsed = try parseElement(testing.allocator, "<iq type=\"set\" id='bind1'/>");
    defer parsed.deinit();
    try testing.expectEqualStrings("set", parsed.element.attr("type").?);
    try testing.expectEqualStrings("bind1", parsed.element.attr("id").?);
}

test "parseElement parses nested elements and text content" {
    var parsed = try parseElement(testing.allocator,
        "<message to='a@b' type='chat'><body>hi &amp; bye</body></message>tail");
    defer parsed.deinit();
    try testing.expectEqualStrings("message", parsed.element.name);
    try testing.expectEqualStrings("chat", parsed.element.attr("type").?);
    const body = parsed.element.child("body").?;
    const text = try body.text(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hi & bye", text);
    // Doesn't consume the trailing "tail" after the matched close tag.
    try testing.expectEqualStrings("tail", "<message to='a@b' type='chat'><body>hi &amp; bye</body></message>tail"[parsed.consumed..]);
}

test "parseElement decodes numeric character references" {
    var parsed = try parseElement(testing.allocator, "<body>a&#65;&#x42;b</body>");
    defer parsed.deinit();
    const text = try parsed.element.text(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("aABb", text);
}

test "parseElement reports Incomplete for a truncated buffer, not an error" {
    try testing.expectError(error.Incomplete, parseElement(testing.allocator, "<message to='a@b'><body>hi"));
    try testing.expectError(error.Incomplete, parseElement(testing.allocator, "<message"));
}

test "parseElement reports Malformed for a mismatched close tag" {
    try testing.expectError(error.Malformed, parseElement(testing.allocator, "<a></b>"));
}

test "parseStreamOpenTag skips an XML declaration and stops at the open tag's '>'" {
    const buf = "<?xml version='1.0'?><stream:stream from='localhost' id='abc' version='1.0'><stream:features>";
    var parsed = try parseStreamOpenTag(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqualStrings("stream:stream", parsed.open.name);
    try testing.expectEqualStrings("localhost", parsed.open.attr("from").?);
    try testing.expectEqualStrings("<stream:features>", buf[parsed.consumed..]);
}

test "parseStreamOpenTag rejects a self-closing stream root" {
    try testing.expectError(error.Malformed, parseStreamOpenTag(testing.allocator, "<stream:stream/>"));
}
