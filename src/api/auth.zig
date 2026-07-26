//! Session cookie signing/verification — see
//! /home/armin/claude/warden-ui/ARCHITECTURE.md §3.2 for why this is a
//! plain HMAC-signed opaque token, not a JWT: warden is both the sole
//! issuer and sole verifier of its own session tokens, so JWT's format
//! complexity (header/claims encoding, algorithm negotiation) buys
//! nothing here — just a `<session_id>.<base64url(HMAC-SHA256)>` pair,
//! checked with a timing-safe comparison. The actual session state
//! (account, expiry, revocation) lives in `store/web_sessions.zig`, keyed
//! by the id half of this token — this module only proves "this id came
//! from us and wasn't tampered with," not "this session is still valid."
const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const cookie_name = "warden_session";

/// Signs `session_id` into a token suitable for a cookie value. `secret`
/// is `Config.api_session_secret` — required to be set whenever the API
/// is enabled at all (see `config.zig`'s `Config.load`).
pub fn sign(allocator: std.mem.Allocator, session_id: i64, secret: []const u8) ![]const u8 {
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{session_id}) catch unreachable;

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, id_str, secret);

    var mac_b64_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(HmacSha256.mac_length)]u8 = undefined;
    const mac_b64 = std.base64.url_safe_no_pad.Encoder.encode(&mac_b64_buf, &mac);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ id_str, mac_b64 });
}

/// `null` if `token` is malformed or its signature doesn't match — the
/// caller (the API's session middleware) still needs to look the
/// returned id up in `store/web_sessions.zig` to confirm it's not
/// expired/revoked; a verified signature only proves authenticity, not
/// current validity.
pub fn verify(token: []const u8, secret: []const u8) ?i64 {
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const id_str = token[0..dot];
    const given_mac_b64 = token[dot + 1 ..];

    const session_id = std.fmt.parseInt(i64, id_str, 10) catch return null;

    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_mac, id_str, secret);
    const b64_len = comptime std.base64.url_safe_no_pad.Encoder.calcSize(HmacSha256.mac_length);
    var expected_mac_b64_buf: [b64_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expected_mac_b64_buf, &expected_mac);

    // `timing_safe.eql` needs two same-size arrays, not slices — copy the
    // caller-supplied signature into a fixed buffer first (only reachable
    // once the length check above already matched, so this is a same-size
    // copy, not truncation).
    if (given_mac_b64.len != b64_len) return null;
    var given_mac_b64_buf: [b64_len]u8 = undefined;
    @memcpy(&given_mac_b64_buf, given_mac_b64);
    if (!std.crypto.timing_safe.eql([b64_len]u8, expected_mac_b64_buf, given_mac_b64_buf)) return null;

    return session_id;
}

const testing = std.testing;

test "sign/verify round-trips a session id" {
    const token = try sign(testing.allocator, 42, "test-secret");
    defer testing.allocator.free(token);

    try testing.expectEqual(@as(?i64, 42), verify(token, "test-secret"));
}

test "verify rejects a token signed with a different secret" {
    const token = try sign(testing.allocator, 42, "test-secret");
    defer testing.allocator.free(token);

    try testing.expectEqual(@as(?i64, null), verify(token, "wrong-secret"));
}

test "verify rejects a tampered session id even if the signature part is untouched-looking" {
    const token = try sign(testing.allocator, 42, "test-secret");
    defer testing.allocator.free(token);

    const tampered = try std.fmt.allocPrint(testing.allocator, "43{s}", .{token[2..]});
    defer testing.allocator.free(tampered);
    try testing.expectEqual(@as(?i64, null), verify(tampered, "test-secret"));
}

test "verify rejects malformed tokens (no dot, garbage id)" {
    try testing.expectEqual(@as(?i64, null), verify("no-dot-here", "test-secret"));
    try testing.expectEqual(@as(?i64, null), verify("not-a-number.abc123", "test-secret"));
}
