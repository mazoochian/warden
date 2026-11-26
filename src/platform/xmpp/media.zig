//! File sharing over XMPP: HTTP File Upload (XEP-0363) discovery and slot
//! parsing, and classifying inbound file URLs into attachments.
const std = @import("std");
const xml = @import("xml.zig");
const stanza = @import("stanza.zig");
const AttachmentKind = @import("../interface.zig").AttachmentKind;

pub const ns_upload = "urn:xmpp:http:upload:0";
pub const ns_disco_info = "http://jabber.org/protocol/disco#info";
pub const ns_disco_items = "http://jabber.org/protocol/disco#items";

/// The `<put>`/`<get>` pair a slot request returns.
pub const Slot = struct {
    put_url: []const u8,
    get_url: []const u8,
    /// Only the three headers XEP-0363 allows a client to forward.
    authorization: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    expires: ?[]const u8 = null,
};

/// Reads a slot out of an `<iq type='result'>`; slices borrow from `iq`.
pub fn parseSlot(iq: xml.Element) ?Slot {
    const slot = stanza.childNs(iq, "slot", ns_upload) orelse return null;
    const put = slot.child("put") orelse return null;
    const get = slot.child("get") orelse return null;
    var out: Slot = .{
        .put_url = put.attr("url") orelse return null,
        .get_url = get.attr("url") orelse return null,
    };
    for (put.children) |node| switch (node) {
        .element => |h| if (std.mem.eql(u8, h.name, "header")) {
            const name = h.attr("name") orelse continue;
            const value = stanza.firstText(h) orelse continue;
            if (std.ascii.eqlIgnoreCase(name, "Authorization")) out.authorization = value;
            if (std.ascii.eqlIgnoreCase(name, "Cookie")) out.cookie = value;
            if (std.ascii.eqlIgnoreCase(name, "Expires")) out.expires = value;
        },
        .text => {},
    };
    return out;
}

/// Item JIDs from a disco#items result; borrowed from `iq`.
pub fn discoItems(allocator: std.mem.Allocator, iq: xml.Element) ![]const []const u8 {
    const query = stanza.childNs(iq, "query", ns_disco_items) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (query.children) |node| switch (node) {
        .element => |e| if (std.mem.eql(u8, e.name, "item")) {
            if (e.attr("jid")) |j| try out.append(allocator, j);
        },
        .text => {},
    };
    return out.toOwnedSlice(allocator);
}

pub const UploadService = struct {
    /// Null when the service doesn't advertise a limit.
    max_file_size: ?u64,
};

/// Non-null when a disco#info result advertises HTTP File Upload.
pub fn uploadServiceFromInfo(iq: xml.Element) ?UploadService {
    const query = stanza.childNs(iq, "query", ns_disco_info) orelse return null;
    var has_feature = false;
    var max: ?u64 = null;
    for (query.children) |node| switch (node) {
        .element => |e| {
            if (std.mem.eql(u8, e.name, "feature") and std.mem.eql(u8, e.attr("var") orelse "", ns_upload)) has_feature = true;
            if (std.mem.eql(u8, e.name, "x")) max = maxFileSizeField(e) orelse max;
        },
        .text => {},
    };
    if (!has_feature) return null;
    return .{ .max_file_size = max };
}

fn maxFileSizeField(form: xml.Element) ?u64 {
    var is_upload_form = false;
    var max: ?u64 = null;
    for (form.children) |node| switch (node) {
        .element => |f| if (std.mem.eql(u8, f.name, "field")) {
            const v = f.attr("var") orelse continue;
            const value_el = f.child("value") orelse continue;
            const value = stanza.firstText(value_el) orelse continue;
            if (std.mem.eql(u8, v, "FORM_TYPE") and std.mem.eql(u8, value, ns_upload)) is_upload_form = true;
            if (std.mem.eql(u8, v, "max-file-size")) max = std.fmt.parseInt(u64, value, 10) catch null;
        },
        .text => {},
    };
    return if (is_upload_form) max else null;
}

/// Host part of an http(s)/aesgcm URL, lowercased into `buf`.
pub fn urlHost(buf: []u8, url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, host, ']') == null) host = host[0..colon];
    }
    if (host.len == 0 or host.len > buf.len) return null;
    return std.ascii.lowerString(buf[0..host.len], host);
}

pub fn isHttpsUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://");
}

pub fn isAesgcmUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "aesgcm://");
}

/// True when `host` is `domain` or one of its subdomains — how a sender's
/// own upload service is recognized (`upload.example.org` for
/// `alice@example.org`), so a stranger can't point the bot at an arbitrary
/// host.
pub fn hostBelongsTo(host: []const u8, domain: []const u8) bool {
    if (domain.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len) return false;
    const suffix = host[host.len - domain.len ..];
    return host[host.len - domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(suffix, domain);
}

/// The last path segment of a URL (no query or fragment), percent-decoding
/// left to the caller.
pub fn urlFileName(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    const path = rest[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const name = path[slash + 1 ..];
    return if (name.len == 0) null else name;
}

fn extension(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

const ExtInfo = struct { ext: []const u8, mime: []const u8, kind: AttachmentKind };

const ext_table = [_]ExtInfo{
    .{ .ext = "jpg", .mime = "image/jpeg", .kind = .photo },
    .{ .ext = "jpeg", .mime = "image/jpeg", .kind = .photo },
    .{ .ext = "png", .mime = "image/png", .kind = .photo },
    .{ .ext = "gif", .mime = "image/gif", .kind = .photo },
    .{ .ext = "webp", .mime = "image/webp", .kind = .photo },
    .{ .ext = "heic", .mime = "image/heic", .kind = .photo },
    // Conversations/Monocles/Dino record voice messages as m4a, ogg or opus.
    .{ .ext = "m4a", .mime = "audio/mp4", .kind = .voice },
    .{ .ext = "ogg", .mime = "audio/ogg", .kind = .voice },
    .{ .ext = "oga", .mime = "audio/ogg", .kind = .voice },
    .{ .ext = "opus", .mime = "audio/opus", .kind = .voice },
    .{ .ext = "aac", .mime = "audio/aac", .kind = .voice },
    .{ .ext = "amr", .mime = "audio/amr", .kind = .voice },
    .{ .ext = "mp3", .mime = "audio/mpeg", .kind = .audio },
    .{ .ext = "wav", .mime = "audio/wav", .kind = .audio },
    .{ .ext = "flac", .mime = "audio/flac", .kind = .audio },
    .{ .ext = "mp4", .mime = "video/mp4", .kind = .video },
    .{ .ext = "webm", .mime = "video/webm", .kind = .video },
    .{ .ext = "mkv", .mime = "video/x-matroska", .kind = .video },
    .{ .ext = "mov", .mime = "video/quicktime", .kind = .video },
    .{ .ext = "3gp", .mime = "video/3gpp", .kind = .video },
    .{ .ext = "pdf", .mime = "application/pdf", .kind = .document },
    .{ .ext = "txt", .mime = "text/plain", .kind = .document },
    .{ .ext = "svg", .mime = "image/svg+xml", .kind = .document },
    .{ .ext = "zip", .mime = "application/zip", .kind = .document },
};

fn lookup(name: []const u8) ?ExtInfo {
    const ext = extension(name);
    for (ext_table) |e| if (std.ascii.eqlIgnoreCase(e.ext, ext)) return e;
    return null;
}

pub fn kindForName(name: []const u8) AttachmentKind {
    return if (lookup(name)) |e| e.kind else .document;
}

pub fn mimeForName(name: []const u8) []const u8 {
    return if (lookup(name)) |e| e.mime else "application/octet-stream";
}

/// Upload services reject names with path separators or odd bytes; keeps
/// `[A-Za-z0-9._-]` and replaces the rest.
pub fn sanitizeFileName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const base = if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name[i + 1 ..] else name;
    const src = if (base.len == 0) "file" else base;
    const out = try allocator.dupe(u8, src[0..@min(src.len, 120)]);
    for (out) |*c| {
        if (!(std.ascii.isAlphanumeric(c.*) or c.* == '.' or c.* == '_' or c.* == '-')) c.* = '_';
    }
    return out;
}

const testing = std.testing;

test "parseSlot reads put/get URLs and the allowed headers only" {
    var parsed = try xml.parseElement(testing.allocator,
        \\<iq type='result' id='u1'><slot xmlns='urn:xmpp:http:upload:0'>
        \\<put url='https://up.example.org/p/abc/f.png'>
        \\<header name='Authorization'>Basic xyz</header>
        \\<header name='X-Evil'>no</header>
        \\</put><get url='https://up.example.org/g/abc/f.png'/></slot></iq>
    );
    defer parsed.deinit();
    const s = parseSlot(parsed.element).?;
    try testing.expectEqualStrings("https://up.example.org/p/abc/f.png", s.put_url);
    try testing.expectEqualStrings("https://up.example.org/g/abc/f.png", s.get_url);
    try testing.expectEqualStrings("Basic xyz", s.authorization.?);
    try testing.expectEqual(@as(?[]const u8, null), s.cookie);
}

test "uploadServiceFromInfo finds the feature and max-file-size" {
    var parsed = try xml.parseElement(testing.allocator,
        \\<iq type='result'><query xmlns='http://jabber.org/protocol/disco#info'>
        \\<identity category='store' type='file'/>
        \\<feature var='urn:xmpp:http:upload:0'/>
        \\<x type='result' xmlns='jabber:x:data'>
        \\<field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field>
        \\<field var='max-file-size'><value>10485760</value></field></x>
        \\</query></iq>
    );
    defer parsed.deinit();
    const svc = uploadServiceFromInfo(parsed.element).?;
    try testing.expectEqual(@as(?u64, 10485760), svc.max_file_size);

    var other = try xml.parseElement(testing.allocator, "<iq type='result'><query xmlns='http://jabber.org/protocol/disco#info'><feature var='urn:xmpp:ping'/></query></iq>");
    defer other.deinit();
    try testing.expectEqual(@as(?UploadService, null), uploadServiceFromInfo(other.element));
}

test "discoItems lists item JIDs" {
    var parsed = try xml.parseElement(testing.allocator, "<iq type='result'><query xmlns='http://jabber.org/protocol/disco#items'><item jid='upload.example.org'/><item jid='conference.example.org'/></query></iq>");
    defer parsed.deinit();
    const items = try discoItems(testing.allocator, parsed.element);
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("upload.example.org", items[0]);
}

test "urlHost strips scheme, credentials, port and path" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("up.example.org", urlHost(&buf, "https://u:p@UP.example.org:5281/x/y.png?a#b").?);
    try testing.expectEqualStrings("share.example.org", urlHost(&buf, "aesgcm://share.example.org/f#00").?);
    try testing.expectEqual(@as(?[]const u8, null), urlHost(&buf, "not a url"));
}

test "hostBelongsTo accepts the domain and its subdomains only" {
    try testing.expect(hostBelongsTo("upload.example.org", "example.org"));
    try testing.expect(hostBelongsTo("example.org", "example.org"));
    try testing.expect(!hostBelongsTo("evilexample.org", "example.org"));
    try testing.expect(!hostBelongsTo("example.org.evil.net", "example.org"));
}

test "kindForName / mimeForName classify by extension" {
    try testing.expectEqual(AttachmentKind.voice, kindForName("2026-01-01_rec.m4a"));
    try testing.expectEqual(AttachmentKind.photo, kindForName("IMG.JPG"));
    try testing.expectEqual(AttachmentKind.video, kindForName("clip.mp4"));
    try testing.expectEqual(AttachmentKind.document, kindForName("report.docx"));
    try testing.expectEqualStrings("image/png", mimeForName("a.png"));
    try testing.expectEqualStrings("application/octet-stream", mimeForName("a.bin"));
}

test "urlFileName and sanitizeFileName" {
    try testing.expectEqualStrings("f.png", urlFileName("https://h/a/b/f.png?x=1").?);
    try testing.expectEqual(@as(?[]const u8, null), urlFileName("https://h/a/"));
    const s = try sanitizeFileName(testing.allocator, "../my report (1).pdf");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("my_report__1_.pdf", s);
}
