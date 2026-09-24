//! Request plumbing shared by every Instagram private-API endpoint: the per-
//! session Android device identity, the header set that makes requests look
//! like the real app, the `signed_body` HMAC-signing convention, and a
//! minimal cookie jar (`std.http.Client` in this Zig version has no built-in
//! one).
const std = @import("std");
const Io = std.Io;
const http = std.http;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const log = @import("../../log.zig").scoped("instagram");

/// A v4 (random) UUID, formatted lowercase with hyphens ("xxxxxxxx-xxxx-4xxx-
/// yxxx-xxxxxxxxxxxx").
pub fn randomUuidV4(io: Io, buf: *[36]u8) []const u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    }) catch unreachable;
}

/// Instagram's `android_device_id` is its own format, not a UUID:
/// `"android-"` followed by 16 lowercase hex digits.
pub fn randomAndroidDeviceId(io: Io, buf: *[24]u8) []const u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bufPrint(buf, "android-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
    }) catch unreachable;
}

/// A single, consistent Android device identity for one Instagram session.
pub const DeviceProfile = struct {
    android_device_id: []const u8,
    phone_id: []const u8,
    uuid: []const u8,
    advertising_id: []const u8,
    manufacturer: []const u8 = "samsung",
    model: []const u8 = "SM-G990B",
    device: []const u8 = "z3q",
    android_version: []const u8 = "33",
    android_release: []const u8 = "13",
    dpi: []const u8 = "420dpi",
    resolution: []const u8 = "1080x2210",
    cpu: []const u8 = "exynos2100",

    /// Generates a fresh, internally-consistent profile. Caller owns and
    /// must free the four allocated id fields.
    pub fn generate(io: Io, allocator: std.mem.Allocator) !DeviceProfile {
        var device_id_buf: [24]u8 = undefined;
        var phone_id_buf: [36]u8 = undefined;
        var uuid_buf: [36]u8 = undefined;
        var adid_buf: [36]u8 = undefined;
        return .{
            .android_device_id = try allocator.dupe(u8, randomAndroidDeviceId(io, &device_id_buf)),
            .phone_id = try allocator.dupe(u8, randomUuidV4(io, &phone_id_buf)),
            .uuid = try allocator.dupe(u8, randomUuidV4(io, &uuid_buf)),
            .advertising_id = try allocator.dupe(u8, randomUuidV4(io, &adid_buf)),
        };
    }

    pub fn deinit(self: DeviceProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.android_device_id);
        allocator.free(self.phone_id);
        allocator.free(self.uuid);
        allocator.free(self.advertising_id);
    }
};

/// Protocol constants Instagram's private API expects but rotates
/// periodically without notice.
pub const RotatingConstants = struct {
    sig_key: []const u8 = "9193488027538fd3450b83b7d05286d4ca9599a0f7eeed90d8c85925698a05f",
    sig_key_version: []const u8 = "4",
    ig_app_id: []const u8 = "567067343352427",
    ig_capabilities: []const u8 = "3brTv10=",
    app_version: []const u8 = "269.0.0.18.75",
    app_version_code: []const u8 = "314665256",
    /// The RSA public key id/DER-bytes-as-base64 Instagram's login endpoint
    /// expects `enc_password` to be encrypted under.
    password_encryption_key_id: []const u8 = "",
    password_encryption_pubkey_der_b64: []const u8 = "",
};

/// `"Instagram {app_version} Android (...)"` — the private API's User-Agent
/// format, documented consistently across independent public interop sources.
pub fn buildUserAgent(allocator: std.mem.Allocator, profile: DeviceProfile, constants: RotatingConstants) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Instagram {s} Android ({s}/{s}; {s}; {s}; {s}; {s}; {s}; {s}; en_US; {s})",
        .{
            constants.app_version,
            profile.android_version,
            profile.android_release,
            profile.dpi,
            profile.resolution,
            profile.manufacturer,
            profile.model,
            profile.device,
            profile.cpu,
            constants.app_version_code,
        },
    );
}

/// Percent-encodes every byte outside RFC 3986's unreserved set (`ALPHA /
/// DIGIT / "-" / "." / "_" / "~"`).
fn isUnreservedFormChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Builds Instagram's `signed_body=<hex hmac>.<url-encoded json>&
/// ig_sig_key_version=<version>` POST body.
pub fn signedBody(allocator: std.mem.Allocator, sig_key: []const u8, sig_key_version: []const u8, payload_json: []const u8) ![]const u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, payload_json, sig_key);
    const mac_hex = std.fmt.bytesToHex(mac, .lower);

    var encoded_payload: std.Io.Writer.Allocating = .init(allocator);
    errdefer encoded_payload.deinit();
    try std.Uri.Component.percentEncode(&encoded_payload.writer, payload_json, isUnreservedFormChar);
    const encoded_payload_owned = try encoded_payload.toOwnedSlice();
    defer allocator.free(encoded_payload_owned);

    return std.fmt.allocPrint(allocator, "signed_body={s}.{s}&ig_sig_key_version={s}", .{ &mac_hex, encoded_payload_owned, sig_key_version });
}

/// Minimal cookie jar: `std.http.Client` (this Zig version) has no built-in
/// one.
pub const CookieJar = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CookieJar) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn get(self: CookieJar, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    /// Sets a cookie directly (not from a `Set-Cookie` header) -- takes ownership
    /// of both `name` and `value`.
    pub fn putOwned(self: *CookieJar, name: []const u8, value: []const u8) !void {
        if (self.map.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        try self.map.put(self.allocator, name_owned, value);
    }

    /// Parses every `Set-Cookie` header out of a raw HTTP response head (.
    pub fn updateFromHeaders(self: *CookieJar, headers: std.http.HeaderIterator) !void {
        var it = headers;
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
            const semi = std.mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
            const kv = header.value[0..semi];
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const name = std.mem.trim(u8, kv[0..eq], " ");
            const value = std.mem.trim(u8, kv[eq + 1 ..], " ");
            if (name.len == 0) continue;

            const name_owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_owned);
            const value_owned = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_owned);

            if (self.map.fetchRemove(name)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
            try self.map.put(self.allocator, name_owned, value_owned);
        }
    }

    /// Renders every stored cookie as one `Cookie:` request-header value
    /// (`"k1=v1; k2=v2"`). Caller owns and frees the returned string.
    pub fn toCookieHeaderValue(self: CookieJar, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();
        var it = self.map.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try buf.writer.writeAll("; ");
            first = false;
            try buf.writer.print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return buf.toOwnedSlice();
    }
};

/// Base URL for Instagram's private mobile-app API.
pub const base_url = "https://i.instagram.com/api/v1";

pub const RequestError = error{
    HttpRequestFailed,
    ReadFailed,
} || http.Client.RequestError || http.Client.Request.ReceiveHeadError || std.mem.Allocator.Error || Io.Writer.Error || std.Uri.ParseError;

pub const Response = struct {
    status: http.Status,
    body: []u8,
};

/// One authenticated (or pre-auth, e.g. the login call itself) request to
/// Instagram's private API.
pub fn request(
    io: Io,
    allocator: std.mem.Allocator,
    client: *http.Client,
    method: http.Method,
    url: []const u8,
    profile: DeviceProfile,
    constants: RotatingConstants,
    jar: *CookieJar,
    body: ?[]const u8,
) RequestError!Response {
    _ = io; // not yet used -- kept in the signature for a future retry/backoff pass, same shape as every call site already carrying `io` around.
    const uri = try std.Uri.parse(url);

    const user_agent = try buildUserAgent(allocator, profile, constants);
    defer allocator.free(user_agent);
    const cookie_header = try jar.toCookieHeaderValue(allocator);
    defer allocator.free(cookie_header);

    var extra_headers_buf: [6]http.Header = undefined;
    var n: usize = 0;
    extra_headers_buf[n] = .{ .name = "X-IG-App-ID", .value = constants.ig_app_id };
    n += 1;
    extra_headers_buf[n] = .{ .name = "X-IG-Capabilities", .value = constants.ig_capabilities };
    n += 1;
    extra_headers_buf[n] = .{ .name = "X-IG-Connection-Type", .value = "WIFI" };
    n += 1;
    if (jar.get("mid")) |mid| {
        extra_headers_buf[n] = .{ .name = "X-MID", .value = mid };
        n += 1;
    }
    if (cookie_header.len > 0) {
        extra_headers_buf[n] = .{ .name = "Cookie", .value = cookie_header };
        n += 1;
    }

    var req = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = extra_headers_buf[0..n],
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = user_agent },
        },
        .keep_alive = false,
    });
    defer req.deinit();

    const payload = body orelse "";
    req.transfer_encoding = .{ .content_length = payload.len };
    var send_body = try req.sendBodyUnflushed(&.{});
    try send_body.writer.writeAll(payload);
    try send_body.end();
    try req.connection.?.flush();

    const head_buffer = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(head_buffer);
    var response = try req.receiveHead(head_buffer);

    try jar.updateFromHeaders(response.head.iterateHeaders());

    var transfer_buffer: [16 * 1024]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.HttpRequestFailed,
    };
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = reader.streamRemaining(&out.writer) catch |err| {
        if (err != error.EndOfStream) return error.ReadFailed;
    };

    return .{ .status = response.head.status, .body = try out.toOwnedSlice() };
}

/// `signedBody`'s `POST`-with-payload convenience over `request` above.
pub fn signedPost(
    io: Io,
    allocator: std.mem.Allocator,
    client: *http.Client,
    url: []const u8,
    profile: DeviceProfile,
    constants: RotatingConstants,
    jar: *CookieJar,
    payload_json: []const u8,
) RequestError!Response {
    const body = signedBody(allocator, constants.sig_key, constants.sig_key_version, payload_json) catch return error.HttpRequestFailed;
    defer allocator.free(body);
    return request(io, allocator, client, .POST, url, profile, constants, jar, body);
}

const testing = std.testing;

test "buildUserAgent formats the private API's expected shape" {
    const profile = DeviceProfile{
        .android_device_id = "android-0011223344556677",
        .phone_id = "00000000-0000-4000-8000-000000000000",
        .uuid = "00000000-0000-4000-8000-000000000001",
        .advertising_id = "00000000-0000-4000-8000-000000000002",
    };
    const ua = try buildUserAgent(testing.allocator, profile, .{});
    defer testing.allocator.free(ua);

    try testing.expect(std.mem.startsWith(u8, ua, "Instagram 269.0.0.18.75 Android (33/13; 420dpi; 1080x2210; samsung; SM-G990B; z3q; exynos2100; en_US; 314665256)"));
}

test "randomUuidV4 produces a well-formed, version-4 UUID string" {
    var buf: [36]u8 = undefined;
    const uuid = randomUuidV4(testing.io, &buf);
    try testing.expectEqual(@as(usize, 36), uuid.len);
    try testing.expectEqual(@as(u8, '-'), uuid[8]);
    try testing.expectEqual(@as(u8, '-'), uuid[13]);
    try testing.expectEqual(@as(u8, '4'), uuid[14]);
    try testing.expectEqual(@as(u8, '-'), uuid[18]);
    try testing.expectEqual(@as(u8, '-'), uuid[23]);
}

test "randomAndroidDeviceId produces the android-<16 hex> format" {
    var buf: [24]u8 = undefined;
    const id = randomAndroidDeviceId(testing.io, &buf);
    try testing.expectEqual(@as(usize, 24), id.len);
    try testing.expect(std.mem.startsWith(u8, id, "android-"));
}

test "signedBody matches a fixed HMAC-SHA256 vector" {
    // Computed independently with `printf '%s' '{"a":1}' | openssl dgst
    // -sha256 -hmac "test_sig_key"`.
    const body = try signedBody(testing.allocator, "test_sig_key", "4", "{\"a\":1}");
    defer testing.allocator.free(body);

    try testing.expectEqualStrings(
        "signed_body=8051759404fd19e04a5a74f736fab60631740c219b5085dbe572b2075e3f0714.%7B%22a%22%3A1%7D&ig_sig_key_version=4",
        body,
    );
}

test "CookieJar parses Set-Cookie headers and renders them back as a Cookie header" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    const raw = "200 OK\r\nSet-Cookie: sessionid=abc123; Path=/; HttpOnly\r\nSet-Cookie: csrftoken=xyz789; Secure\r\n\r\n";
    const head_iter = std.http.HeaderIterator.init(raw);
    try jar.updateFromHeaders(head_iter);

    try testing.expectEqualStrings("abc123", jar.get("sessionid").?);
    try testing.expectEqualStrings("xyz789", jar.get("csrftoken").?);

    const header_value = try jar.toCookieHeaderValue(testing.allocator);
    defer testing.allocator.free(header_value);
    try testing.expect(std.mem.indexOf(u8, header_value, "sessionid=abc123") != null);
    try testing.expect(std.mem.indexOf(u8, header_value, "csrftoken=xyz789") != null);
    try testing.expect(std.mem.indexOf(u8, header_value, "; ") != null);
}

test "CookieJar.updateFromHeaders overwrites an existing cookie with the same name" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    const first = std.http.HeaderIterator.init("200 OK\r\nSet-Cookie: sessionid=old\r\n\r\n");
    try jar.updateFromHeaders(first);
    const second = std.http.HeaderIterator.init("200 OK\r\nSet-Cookie: sessionid=new\r\n\r\n");
    try jar.updateFromHeaders(second);

    try testing.expectEqualStrings("new", jar.get("sessionid").?);
}

test "CookieJar ignores non-cookie headers and ill-formed Set-Cookie values" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    const it = std.http.HeaderIterator.init("200 OK\r\nContent-Type: application/json\r\nSet-Cookie: noequalssign\r\n\r\n");
    try jar.updateFromHeaders(it);

    try testing.expectEqual(@as(?[]const u8, null), jar.get("Content-Type"));
    try testing.expectEqual(@as(usize, 0), jar.map.count());
}
