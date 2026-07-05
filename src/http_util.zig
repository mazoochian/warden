const std = @import("std");
const Io = std.Io;
const http = std.http;

/// Shared one-shot GET/POST helpers over `std.http.Client.fetch`, used by
/// the Telegram client and the LLM provider adapters alike so each of them
/// doesn't hand-roll the same response-buffering boilerplate.
pub fn get(client: *http.Client, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_writer.writer,
    });
    if (result.status != .ok) {
        std.log.err("GET {s} -> {d}: {s}", .{ url, @intFromEnum(result.status), response_writer.writer.buffered() });
    }
    return response_writer.toOwnedSlice();
}

pub fn postJson(
    client: *http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const http.Header,
    payload: []const u8,
) ![]u8 {
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = extra_headers,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &response_writer.writer,
    });
    if (result.status != .ok) {
        std.log.err("POST {s} -> {d}: {s}", .{ url, @intFromEnum(result.status), response_writer.writer.buffered() });
    }
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
    var response_writer: Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = content_type } },
        .response_writer = &response_writer.writer,
    });
    if (result.status != .ok) {
        std.log.err("POST {s} -> {d}: {s}", .{ url, @intFromEnum(result.status), response_writer.writer.buffered() });
    }
    return response_writer.toOwnedSlice();
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
