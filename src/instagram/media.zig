//! Instagram media resolution: shortcode -> `media_pk` decoding, and a
//! media-info fetch that tries an unauthenticated call first and falls back
//! to the authenticated private endpoint -- the latter is what makes
//! private-account/geo-gated content the owner follows reachable at all
//! (see `video_download.zig`'s planned fallback integration). Endpoint
//! shapes are this implementation's best-effort current knowledge, same
//! caveat as `auth.zig`'s doc comment.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;
const transport = @import("transport.zig");
const auth = @import("auth.zig");
const log = @import("../log.zig").scoped("instagram");

/// Instagram's shortcode alphabet -- the URL-safe base64 alphabet, applied
/// to the numeric `media_pk` 6 bits per character, most-significant first,
/// with no padding. Public, stable encoding (unlike the private-API request
/// plumbing elsewhere in this connector) -- used by every public gallery/
/// embed URL Instagram has ever generated.
const shortcode_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub const ShortcodeError = error{InvalidShortcode};

/// Decodes an Instagram shortcode (e.g. "CqIbtWpMXtN" from
/// `instagram.com/p/CqIbtWpMXtN/`) into its numeric `media_pk`. Widened to
/// `u128` internally since a long shortcode's raw 6-bits-per-char decode can
/// exceed `u64` even though every real `media_pk` fits comfortably within
/// it -- truncated back down at the end, which is lossless for any actual
/// Instagram media id.
pub fn mediaPkFromShortcode(shortcode: []const u8) ShortcodeError!u64 {
    var acc: u128 = 0;
    for (shortcode) |c| {
        const idx = std.mem.indexOfScalar(u8, shortcode_alphabet, c) orelse return error.InvalidShortcode;
        acc = (acc << 6) | @as(u128, idx);
    }
    return @truncate(acc);
}

/// Extracts the shortcode from a `.../p/<code>/` or `.../reel/<code>/` URL
/// and decodes it. `null` if the URL doesn't match either shape.
pub fn mediaPkFromUrl(url: []const u8) ?u64 {
    const markers = [_][]const u8{ "/p/", "/reel/", "/reels/" };
    for (markers) |marker| {
        const idx = std.mem.indexOf(u8, url, marker) orelse continue;
        const after = url[idx + marker.len ..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const code = after[0..end];
        if (code.len == 0) continue;
        return mediaPkFromShortcode(code) catch continue;
    }
    return null;
}

pub const MediaInfo = struct {
    /// Direct CDN URL for the best-available video, or null for a
    /// photo-only post.
    video_url: ?[]const u8,
    /// Direct CDN URL for the best-available image (present even for a
    /// video post, as its thumbnail/cover).
    image_url: ?[]const u8,

    pub fn dupe(self: MediaInfo, allocator: std.mem.Allocator) !MediaInfo {
        return .{
            .video_url = if (self.video_url) |s| try allocator.dupe(u8, s) else null,
            .image_url = if (self.image_url) |s| try allocator.dupe(u8, s) else null,
        };
    }
};

/// Parses one `items[]` entry from `media/{pk}/info/`'s response into
/// `MediaInfo` -- picks the first (highest-priority, per Instagram's own
/// ordering) `video_versions[]`/`image_versions2.candidates[]` entry.
fn parseMediaItem(allocator: std.mem.Allocator, item: json.ObjectMap) !MediaInfo {
    var video_url: ?[]const u8 = null;
    if (item.get("video_versions")) |vv| if (vv == .array and vv.array.items.len > 0) {
        if (vv.array.items[0] == .object) {
            if (vv.array.items[0].object.get("url")) |u| if (u == .string) {
                video_url = try allocator.dupe(u8, u.string);
            };
        }
    };

    var image_url: ?[]const u8 = null;
    if (item.get("image_versions2")) |iv| if (iv == .object) {
        if (iv.object.get("candidates")) |cands| if (cands == .array and cands.array.items.len > 0) {
            if (cands.array.items[0] == .object) {
                if (cands.array.items[0].object.get("url")) |u| if (u == .string) {
                    image_url = try allocator.dupe(u8, u.string);
                };
            }
        };
    };

    return .{ .video_url = video_url, .image_url = image_url };
}

fn parseMediaInfoBody(allocator: std.mem.Allocator, body: []const u8) !?MediaInfo {
    var parsed = json.parseFromSlice(json.Value, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const items = switch (root.get("items") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (items.items.len == 0 or items.items[0] != .object) return null;
    return try parseMediaItem(allocator, items.items[0].object);
}

/// Fetches media info for `media_pk` via the authenticated private endpoint
/// -- the fallback path when a plain unauthenticated fetch (e.g.
/// `video_download.zig`'s `yt-dlp` attempt) has already failed, meaning the
/// content needs the logged-in session's own visibility (a private account
/// the owner follows, or the owner's own non-public content). `null` if the
/// response doesn't parse or carries no usable candidate.
pub fn fetchMediaInfoAuthenticated(io: Io, allocator: std.mem.Allocator, client: *http.Client, auth_client: *auth.AuthClient, media_pk: u64) !?MediaInfo {
    const url = try std.fmt.allocPrint(allocator, "{s}/media/{d}/info/", .{ transport.base_url, media_pk });
    defer allocator.free(url);

    const resp = transport.request(io, allocator, client, .GET, url, auth_client.profile, auth_client.constants, &auth_client.jar, null) catch |err| {
        log.warn("fetchMediaInfoAuthenticated: request failed for media_pk {d}: {t}", .{ media_pk, err });
        return null;
    };
    defer allocator.free(resp.body);

    if (resp.status.class() != .success) {
        log.warn("fetchMediaInfoAuthenticated: media_pk {d} -> {d}", .{ media_pk, @intFromEnum(resp.status) });
        return null;
    }
    return parseMediaInfoBody(allocator, resp.body);
}

const testing = std.testing;

test "mediaPkFromShortcode decodes a known shortcode" {
    // "B" = index 1 in the alphabet, "A" = index 0 -- "BA" = 0b000001_000000 = 64.
    try testing.expectEqual(@as(u64, 64), try mediaPkFromShortcode("BA"));
}

test "mediaPkFromShortcode rejects a character outside the alphabet" {
    try testing.expectError(error.InvalidShortcode, mediaPkFromShortcode("!!!"));
}

test "mediaPkFromUrl extracts and decodes a /p/ URL's shortcode" {
    const pk = mediaPkFromUrl("https://www.instagram.com/p/BA/") orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 64), pk);
}

test "mediaPkFromUrl extracts and decodes a /reel/ URL's shortcode" {
    const pk = mediaPkFromUrl("https://www.instagram.com/reel/BA/?utm_source=ig") orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 64), pk);
}

test "mediaPkFromUrl returns null for a URL with neither /p/ nor /reel/" {
    try testing.expectEqual(@as(?u64, null), mediaPkFromUrl("https://www.instagram.com/some_user/"));
}

test "parseMediaInfoBody extracts a video candidate" {
    const body =
        \\{"items": [{"video_versions": [{"url": "https://cdn.example/video.mp4"}], "image_versions2": {"candidates": [{"url": "https://cdn.example/thumb.jpg"}]}}]}
    ;
    const info = (try parseMediaInfoBody(testing.allocator, body)) orelse return error.TestExpectedValue;
    defer {
        if (info.video_url) |s| testing.allocator.free(s);
        if (info.image_url) |s| testing.allocator.free(s);
    }
    try testing.expectEqualStrings("https://cdn.example/video.mp4", info.video_url.?);
    try testing.expectEqualStrings("https://cdn.example/thumb.jpg", info.image_url.?);
}

test "parseMediaInfoBody handles a photo-only post (no video_versions)" {
    const body =
        \\{"items": [{"image_versions2": {"candidates": [{"url": "https://cdn.example/photo.jpg"}]}}]}
    ;
    const info = (try parseMediaInfoBody(testing.allocator, body)) orelse return error.TestExpectedValue;
    defer {
        if (info.video_url) |s| testing.allocator.free(s);
        if (info.image_url) |s| testing.allocator.free(s);
    }
    try testing.expectEqual(@as(?[]const u8, null), info.video_url);
    try testing.expectEqualStrings("https://cdn.example/photo.jpg", info.image_url.?);
}

test "parseMediaInfoBody returns null for an empty items array" {
    const body = "{\"items\": []}";
    try testing.expectEqual(@as(?MediaInfo, null), try parseMediaInfoBody(testing.allocator, body));
}

test "MediaInfo.dupe deep-copies both URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();
    const src = MediaInfo{
        .video_url = try src_a.dupe(u8, "https://cdn.example/v.mp4"),
        .image_url = null,
    };
    const dst = try src.dupe(testing.allocator);
    defer testing.allocator.free(dst.video_url.?);
    arena.deinit();
    try testing.expectEqualStrings("https://cdn.example/v.mp4", dst.video_url.?);
    try testing.expectEqual(@as(?[]const u8, null), dst.image_url);
}
