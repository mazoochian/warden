//! Minimal `multipart/form-data` request-body parser — Zig's `std.http`
//! has no built-in support for this (only the outgoing multipart builder
//! `http_util.zig`/`telegram/client.zig` use, for uploading files *to* a
//! platform), and Convert (Phase 5c) is the first endpoint that needs to
//! *receive* a file upload. Deliberately hand-rolled and scoped to exactly
//! what a browser's `FormData` + `fetch` actually produces (RFC 2046's
//! general case — nested multipart, non-ASCII header folding, etc. — is
//! never emitted by that path), matching this codebase's existing
//! preference for a small purpose-built parser over a general-purpose
//! dependency.
const std = @import("std");

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8,
    content: []const u8,
};

pub const ParseError = error{
    MissingBoundary,
    MalformedBody,
};

/// Extracts the `boundary=` parameter from a `Content-Type` header value
/// (e.g. `multipart/form-data; boundary=----WebKitFormBoundaryXYZ`, quotes
/// around the value optional). `null` if the header isn't multipart or has
/// no boundary parameter.
pub fn boundaryFromContentType(content_type: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/")) return null;

    var it = std.mem.splitScalar(u8, content_type, ';');
    _ = it.next(); // the "multipart/form-data" media type itself
    while (it.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = std.mem.trim(u8, param[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "boundary")) continue;
        var value = std.mem.trim(u8, param[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

/// Parses every part out of `body`, given the boundary already extracted
/// from the request's `Content-Type` header. Every returned slice borrows
/// from `body` directly — no copies, no allocator needed, matching
/// `readJsonBodyLeaky`'s "borrow from the arena-owned raw body" convention
/// elsewhere in this file.
pub fn parse(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) ![]Part {
    const delim = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delim);

    var parts: std.ArrayList(Part) = .empty;

    var it = std.mem.splitSequence(u8, body, delim);
    _ = it.next() orelse return error.MalformedBody; // preamble before the first boundary

    while (it.next()) |chunk_raw| {
        // The terminal boundary is followed by "--"; every other boundary
        // is followed by "\r\n" then this part's headers.
        if (std.mem.startsWith(u8, chunk_raw, "--")) break;

        var chunk = chunk_raw;
        if (std.mem.startsWith(u8, chunk, "\r\n")) chunk = chunk[2..];
        // Strip the single trailing "\r\n" that's really the leading CRLF
        // of the *next* boundary marker, not part of this part's content.
        if (std.mem.endsWith(u8, chunk, "\r\n")) chunk = chunk[0 .. chunk.len - 2];

        const header_end = std.mem.indexOf(u8, chunk, "\r\n\r\n") orelse return error.MalformedBody;
        const headers_text = chunk[0..header_end];
        const content = chunk[header_end + 4 ..];

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;

        var header_it = std.mem.splitSequence(u8, headers_text, "\r\n");
        while (header_it.next()) |header_line| {
            const colon = std.mem.indexOfScalar(u8, header_line, ':') orelse continue;
            const header_name = std.mem.trim(u8, header_line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(header_name, "content-disposition")) continue;
            const header_value = header_line[colon + 1 ..];
            name = dispositionParam(header_value, "name");
            filename = dispositionParam(header_value, "filename");
        }

        const part_name = name orelse continue; // an unnamed part is unusable -- skip it
        try parts.append(allocator, .{ .name = part_name, .filename = filename, .content = content });
    }

    return parts.toOwnedSlice(allocator);
}

/// Finds `key="value"` inside a `Content-Disposition` header value (e.g.
/// `form-data; name="file"; filename="photo.png"`) — same quoted-parameter
/// shape as `boundaryFromContentType`'s, just scanning for a specific key.
fn dispositionParam(header_value: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header_value, ';');
    while (it.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const param_key = std.mem.trim(u8, param[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(param_key, key)) continue;
        var value = std.mem.trim(u8, param[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        return value;
    }
    return null;
}

pub fn find(parts: []const Part, name: []const u8) ?Part {
    for (parts) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

const testing = std.testing;

test "boundaryFromContentType extracts unquoted and quoted boundaries" {
    try testing.expectEqualStrings(
        "----WebKitFormBoundary7MA4YWxkTrZu0gW",
        boundaryFromContentType("multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW").?,
    );
    try testing.expectEqualStrings("abc123", boundaryFromContentType("multipart/form-data; boundary=\"abc123\"").?);
    try testing.expectEqual(@as(?[]const u8, null), boundaryFromContentType("application/json"));
    try testing.expectEqual(@as(?[]const u8, null), boundaryFromContentType("multipart/form-data"));
}

test "parse extracts a text field and a file part from a real-shaped FormData body" {
    const boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW";
    const body = "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"target_format\"\r\n" ++
        "\r\n" ++
        "pdf\r\n" ++
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"photo.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "\x89PNG\x0d\x0abinarygarbage\x00\x01\x02" ++ "\r\n" ++
        "--" ++ boundary ++ "--\r\n";

    const parts = try parse(testing.allocator, body, boundary);
    defer testing.allocator.free(parts);

    try testing.expectEqual(@as(usize, 2), parts.len);

    const field = find(parts, "target_format").?;
    try testing.expectEqual(@as(?[]const u8, null), field.filename);
    try testing.expectEqualStrings("pdf", field.content);

    const file = find(parts, "file").?;
    try testing.expectEqualStrings("photo.png", file.filename.?);
    try testing.expectEqualStrings("\x89PNG\x0d\x0abinarygarbage\x00\x01\x02", file.content);
}

test "find returns null for a missing part name" {
    const boundary = "b";
    const body = "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\n" ++
        "x\r\n" ++
        "--" ++ boundary ++ "--\r\n";
    const parts = try parse(testing.allocator, body, boundary);
    defer testing.allocator.free(parts);
    try testing.expectEqual(@as(?Part, null), find(parts, "nonexistent"));
}
