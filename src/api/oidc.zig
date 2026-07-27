//! Generic OIDC login (Authorization Code + PKCE, ES256-signed ID tokens)
//! — backs `oauth_providers` rows. Telegram's own OIDC provider
//! (https://core.telegram.org/bots/telegram-login) is the one production
//! use of this today; it replaced the old HMAC-signed Telegram Login
//! Widget outright (removed 2026-07-28), which Telegram itself now
//! describes as legacy/archived in favor of this.
//!
//! Only ES256 (ECDSA P-256 + SHA-256) is supported, not the RS256 most
//! OIDC providers default to -- Zig's standard library has no RSA
//! implementation at all (by design: safe constant-time RSA is a large
//! attack surface this stdlib has never taken on), while
//! `std.crypto.sign.ecdsa.EcdsaP256Sha256` covers ES256 directly. Every
//! provider using this module must have its signing algorithm switched to
//! ES256 (Telegram: BotFather's Web Login settings) -- there is
//! deliberately no fallback to "trust the token unverified" for an
//! unsupported algorithm.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const http_util = @import("../http_util.zig");

pub const Discovery = struct {
    /// The document's own declared `issuer` -- used as `verifyIdToken`'s
    /// `expected_issuer` (spec-correct: what matters is that the token's
    /// `iss` matches what the provider itself claims here, not that it
    /// happens to match whatever exact string we stored/requested).
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    jwks_uri: []const u8,
};

/// Fetches and parses `{issuer_url}/.well-known/openid-configuration`.
/// `allocator` should be an arena -- every field borrows from the parsed
/// JSON's own backing allocation.
pub fn discover(allocator: std.mem.Allocator, io: Io, issuer_url: []const u8) !Discovery {
    const url = try std.fmt.allocPrint(allocator, "{s}/.well-known/openid-configuration", .{issuer_url});
    var client: http.Client = .{ .allocator = allocator, .io = io };
    const body = try http_util.get(&client, allocator, url);

    const Raw = struct {
        issuer: []const u8,
        authorization_endpoint: []const u8,
        token_endpoint: []const u8,
        jwks_uri: []const u8,
    };
    const parsed = try std.json.parseFromSliceLeaky(Raw, allocator, body, .{ .ignore_unknown_fields = true });
    return .{
        .issuer = parsed.issuer,
        .authorization_endpoint = parsed.authorization_endpoint,
        .token_endpoint = parsed.token_endpoint,
        .jwks_uri = parsed.jwks_uri,
    };
}

pub const JwkKey = struct {
    kid: []const u8,
    /// Raw SEC-1 uncompressed public key bytes (`0x04 || x || y`, 65 bytes
    /// for P-256) -- decoded once at fetch time so `verifyIdToken` doesn't
    /// redo base64 decoding per candidate key.
    sec1: [65]u8,
};

/// Fetches `jwks_uri` and decodes every EC/P-256 key in the set (any other
/// `kty`/`crv` is silently skipped -- this module only ever verifies
/// ES256, so a key it could never use isn't an error, just irrelevant).
pub fn fetchJwks(allocator: std.mem.Allocator, io: Io, jwks_uri: []const u8) ![]JwkKey {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    const body = try http_util.get(&client, allocator, jwks_uri);

    const RawKey = struct {
        kty: []const u8,
        crv: ?[]const u8 = null,
        kid: []const u8,
        x: ?[]const u8 = null,
        y: ?[]const u8 = null,
    };
    const RawSet = struct { keys: []RawKey };
    const parsed = try std.json.parseFromSliceLeaky(RawSet, allocator, body, .{ .ignore_unknown_fields = true });

    var out: std.ArrayList(JwkKey) = .empty;
    for (parsed.keys) |k| {
        if (!std.mem.eql(u8, k.kty, "EC")) continue;
        if (k.crv == null or !std.mem.eql(u8, k.crv.?, "P-256")) continue;
        const x = k.x orelse continue;
        const y = k.y orelse continue;

        var x_buf: [32]u8 = undefined;
        var y_buf: [32]u8 = undefined;
        std.base64.url_safe_no_pad.Decoder.decode(&x_buf, x) catch continue;
        std.base64.url_safe_no_pad.Decoder.decode(&y_buf, y) catch continue;

        var sec1: [65]u8 = undefined;
        sec1[0] = 0x04;
        @memcpy(sec1[1..33], &x_buf);
        @memcpy(sec1[33..65], &y_buf);
        try out.append(allocator, .{ .kid = k.kid, .sec1 = sec1 });
    }
    return out.toOwnedSlice(allocator);
}

pub const IdTokenClaims = struct {
    /// The provider's own user id (Telegram: `id`, the numeric Telegram
    /// user id -- also mirrored into the standard `sub` claim, but `id`
    /// is used directly since it's documented as the stable identifier).
    id: []const u8,
    preferred_username: ?[]const u8 = null,
    name: ?[]const u8 = null,
    picture: ?[]const u8 = null,
};

pub const VerifyError = error{
    MalformedToken,
    UnsupportedAlgorithm,
    UnknownKey,
    InvalidSignature,
    InvalidIssuer,
    InvalidAudience,
    Expired,
    NotYetValid,
};

/// Verifies a compact JWT (`header.payload.signature`, all base64url) --
/// ES256 signature against one of `jwks`'s keys (matched by `kid`), plus
/// `iss`/`aud`/`exp`/`iat` per the OIDC core spec. `allocator` should be
/// an arena. `clock_skew_seconds` gives `exp`/`iat` a little slack for
/// clock drift between this host and the provider.
pub fn verifyIdToken(
    allocator: std.mem.Allocator,
    id_token: []const u8,
    jwks: []const JwkKey,
    expected_issuer: []const u8,
    expected_audience: []const u8,
    now: i64,
    clock_skew_seconds: i64,
) !IdTokenClaims {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    var it = std.mem.splitScalar(u8, id_token, '.');
    const header_b64 = it.next() orelse return error.MalformedToken;
    const payload_b64 = it.next() orelse return error.MalformedToken;
    const sig_b64 = it.next() orelse return error.MalformedToken;
    if (it.next() != null) return error.MalformedToken; // exactly 3 segments

    const header_json = try b64Decode(allocator, header_b64);
    const Header = struct { alg: []const u8, kid: ?[]const u8 = null };
    const header = std.json.parseFromSliceLeaky(Header, allocator, header_json, .{ .ignore_unknown_fields = true }) catch return error.MalformedToken;
    if (!std.mem.eql(u8, header.alg, "ES256")) return error.UnsupportedAlgorithm;

    const sig_bytes_slice = try b64Decode(allocator, sig_b64);
    if (sig_bytes_slice.len != Ecdsa.Signature.encoded_length) return error.MalformedToken;
    var sig_bytes: [Ecdsa.Signature.encoded_length]u8 = undefined;
    @memcpy(&sig_bytes, sig_bytes_slice);
    const signature = Ecdsa.Signature.fromBytes(sig_bytes);

    const signing_input = id_token[0 .. header_b64.len + 1 + payload_b64.len];

    var verified = false;
    for (jwks) |key| {
        if (header.kid) |kid| {
            if (!std.mem.eql(u8, key.kid, kid)) continue;
        }
        const public_key = Ecdsa.PublicKey.fromSec1(&key.sec1) catch continue;
        signature.verify(signing_input, public_key) catch continue;
        verified = true;
        break;
    }
    if (!verified) return error.InvalidSignature;

    const payload_json = try b64Decode(allocator, payload_b64);
    const Payload = struct {
        iss: []const u8,
        aud: []const u8,
        exp: i64,
        iat: i64,
        id: ?i64 = null,
        sub: ?[]const u8 = null,
        preferred_username: ?[]const u8 = null,
        name: ?[]const u8 = null,
        picture: ?[]const u8 = null,
    };
    const payload = std.json.parseFromSliceLeaky(Payload, allocator, payload_json, .{ .ignore_unknown_fields = true }) catch return error.MalformedToken;

    if (!std.mem.eql(u8, payload.iss, expected_issuer)) return error.InvalidIssuer;
    if (!std.mem.eql(u8, payload.aud, expected_audience)) return error.InvalidAudience;
    if (now > payload.exp + clock_skew_seconds) return error.Expired;
    if (payload.iat > now + clock_skew_seconds) return error.NotYetValid;

    const id = if (payload.id) |numeric_id|
        try std.fmt.allocPrint(allocator, "{d}", .{numeric_id})
    else if (payload.sub) |sub|
        sub
    else
        return error.MalformedToken;

    return .{ .id = id, .preferred_username = payload.preferred_username, .name = payload.name, .picture = payload.picture };
}

fn b64Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.MalformedToken;
    const out = try allocator.alloc(u8, len);
    std.base64.url_safe_no_pad.Decoder.decode(out, encoded) catch return error.MalformedToken;
    return out;
}

/// A fresh PKCE code verifier -- 32 random bytes, base64url-encoded (43
/// chars, well within the spec's required 43-128 char range).
pub fn generateVerifier(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);
    return b64Encode(allocator, &bytes);
}

/// `S256` code challenge: `base64url(sha256(verifier))`.
pub fn challengeFromVerifier(allocator: std.mem.Allocator, verifier: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return b64Encode(allocator, &digest);
}

/// An opaque anti-CSRF `state` value -- carries no meaning of its own,
/// just needs to be unguessable and round-trip through the redirect.
pub fn generateState(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    var bytes: [24]u8 = undefined;
    io.random(&bytes);
    return b64Encode(allocator, &bytes);
}

fn b64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const len = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, len);
    return std.base64.url_safe_no_pad.Encoder.encode(out, bytes);
}

const testing = std.testing;

test "generateVerifier produces spec-length output, and challengeFromVerifier is deterministic" {
    const a = testing.allocator;
    const verifier = try generateVerifier(a, testing.io);
    defer a.free(verifier);
    try testing.expect(verifier.len >= 43 and verifier.len <= 128);

    const c1 = try challengeFromVerifier(a, verifier);
    defer a.free(c1);
    const c2 = try challengeFromVerifier(a, verifier);
    defer a.free(c2);
    try testing.expectEqualStrings(c1, c2);
}

test "challengeFromVerifier matches RFC 7636's own worked example" {
    // https://www.rfc-editor.org/rfc/rfc7636#appendix-B
    const a = testing.allocator;
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = try challengeFromVerifier(a, verifier);
    defer a.free(challenge);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge);
}

test "generateState produces distinct values" {
    const a = testing.allocator;
    const s1 = try generateState(a, testing.io);
    defer a.free(s1);
    const s2 = try generateState(a, testing.io);
    defer a.free(s2);
    try testing.expect(!std.mem.eql(u8, s1, s2));
}

fn b64UrlNoPad(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return b64Encode(a, bytes);
}

/// Builds a real ES256-signed JWT for test purposes -- mirrors exactly
/// what a real OIDC provider produces, so `verifyIdToken`'s tests exercise
/// the real decode/verify path, not a mocked shortcut.
fn makeTestToken(
    a: std.mem.Allocator,
    key_pair: std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair,
    kid: []const u8,
    header_alg: []const u8,
    iss: []const u8,
    aud: []const u8,
    numeric_id: i64,
    iat: i64,
    exp: i64,
) ![]const u8 {
    const header_json = try std.fmt.allocPrint(a, "{{\"alg\":\"{s}\",\"kid\":\"{s}\",\"typ\":\"JWT\"}}", .{ header_alg, kid });
    const payload_json = try std.fmt.allocPrint(
        a,
        "{{\"iss\":\"{s}\",\"aud\":\"{s}\",\"id\":{d},\"iat\":{d},\"exp\":{d},\"preferred_username\":\"alice\",\"name\":\"Alice\"}}",
        .{ iss, aud, numeric_id, iat, exp },
    );
    const header_b64 = try b64UrlNoPad(a, header_json);
    const payload_b64 = try b64UrlNoPad(a, payload_json);
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_b64, payload_b64 });

    var noise: [32]u8 = undefined;
    testing.io.random(&noise);
    const sig = try key_pair.sign(signing_input, noise);
    const sig_b64 = try b64UrlNoPad(a, &sig.toBytes());

    return std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, sig_b64 });
}

fn testJwks(a: std.mem.Allocator, key_pair: std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair, kid: []const u8) ![]JwkKey {
    const sec1 = key_pair.public_key.toUncompressedSec1();
    var out = try a.alloc(JwkKey, 1);
    out[0] = .{ .kid = try a.dupe(u8, kid), .sec1 = sec1 };
    return out;
}

test "verifyIdToken accepts a validly-signed, in-window token and extracts claims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const jwks = try testJwks(a, key_pair, "key1");
    const now: i64 = 1_800_000_000;
    const token = try makeTestToken(a, key_pair, "key1", "ES256", "https://oauth.telegram.org", "client-123", 555, now - 10, now + 3600);

    const claims = try verifyIdToken(a, token, jwks, "https://oauth.telegram.org", "client-123", now, 60);
    try testing.expectEqualStrings("555", claims.id);
    try testing.expectEqualStrings("alice", claims.preferred_username.?);
    try testing.expectEqualStrings("Alice", claims.name.?);
}

test "verifyIdToken rejects a token signed by an unknown key (wrong kid)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const signing_key = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const other_key = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const jwks = try testJwks(a, other_key, "key1"); // JWKS only has the *other* key
    const now: i64 = 1_800_000_000;
    const token = try makeTestToken(a, signing_key, "key1", "ES256", "https://oauth.telegram.org", "client-123", 555, now - 10, now + 3600);

    try testing.expectError(error.InvalidSignature, verifyIdToken(a, token, jwks, "https://oauth.telegram.org", "client-123", now, 60));
}

test "verifyIdToken rejects a tampered payload even with a valid-looking signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const jwks = try testJwks(a, key_pair, "key1");
    const now: i64 = 1_800_000_000;
    const token = try makeTestToken(a, key_pair, "key1", "ES256", "https://oauth.telegram.org", "client-123", 555, now - 10, now + 3600);

    // Flip one base64url character in the payload segment without
    // re-signing -- the classic "attacker edits the JWT and hopes nobody
    // checks" attempt. Editing the *encoded* token (not the pre-encoding
    // JSON) matters: base64 doesn't preserve substrings byte-for-byte
    // across the 3-bytes-in/4-chars-out grouping, so searching the token
    // for literal decoded text like "555" would usually find nothing to
    // replace and silently test an unmodified (still validly-signed)
    // token instead -- confirmed the hard way, this test passed for the
    // wrong reason before this fix.
    const tampered = try a.dupe(u8, token);
    const first_dot = std.mem.indexOfScalar(u8, tampered, '.').?;
    const second_dot = std.mem.indexOfScalarPos(u8, tampered, first_dot + 1, '.').?;
    const mid = first_dot + (second_dot - first_dot) / 2;
    tampered[mid] = if (tampered[mid] == 'A') 'B' else 'A';

    try testing.expectError(error.InvalidSignature, verifyIdToken(a, tampered, jwks, "https://oauth.telegram.org", "client-123", now, 60));
}

test "verifyIdToken rejects alg=none and any non-ES256 algorithm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const jwks = try testJwks(a, key_pair, "key1");
    const now: i64 = 1_800_000_000;

    const none_token = try makeTestToken(a, key_pair, "key1", "none", "https://oauth.telegram.org", "client-123", 555, now - 10, now + 3600);
    try testing.expectError(error.UnsupportedAlgorithm, verifyIdToken(a, none_token, jwks, "https://oauth.telegram.org", "client-123", now, 60));

    const rs256_token = try makeTestToken(a, key_pair, "key1", "RS256", "https://oauth.telegram.org", "client-123", 555, now - 10, now + 3600);
    try testing.expectError(error.UnsupportedAlgorithm, verifyIdToken(a, rs256_token, jwks, "https://oauth.telegram.org", "client-123", now, 60));
}

test "verifyIdToken rejects wrong issuer and wrong audience" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const jwks = try testJwks(a, key_pair, "key1");
    const now: i64 = 1_800_000_000;

    const token = try makeTestToken(a, key_pair, "key1", "ES256", "https://evil.example.com", "client-123", 555, now - 10, now + 3600);
    try testing.expectError(error.InvalidIssuer, verifyIdToken(a, token, jwks, "https://oauth.telegram.org", "client-123", now, 60));

    const token2 = try makeTestToken(a, key_pair, "key1", "ES256", "https://oauth.telegram.org", "someone-elses-client", 555, now - 10, now + 3600);
    try testing.expectError(error.InvalidAudience, verifyIdToken(a, token2, jwks, "https://oauth.telegram.org", "client-123", now, 60));
}

test "verifyIdToken rejects an expired token, tolerating clock skew" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const jwks = try testJwks(a, key_pair, "key1");
    const now: i64 = 1_800_000_000;

    // Expired 120s ago -- beyond the 60s skew allowance.
    const expired = try makeTestToken(a, key_pair, "key1", "ES256", "https://oauth.telegram.org", "client-123", 555, now - 3600, now - 120);
    try testing.expectError(error.Expired, verifyIdToken(a, expired, jwks, "https://oauth.telegram.org", "client-123", now, 60));

    // Expired 30s ago -- within the 60s skew allowance, still accepted.
    const barely_expired = try makeTestToken(a, key_pair, "key1", "ES256", "https://oauth.telegram.org", "client-123", 555, now - 3600, now - 30);
    _ = try verifyIdToken(a, barely_expired, jwks, "https://oauth.telegram.org", "client-123", now, 60);
}

test "verifyIdToken rejects a malformed token (wrong number of segments)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.MalformedToken, verifyIdToken(a, "not.a.jwt.at.all", &.{}, "iss", "aud", 0, 60));
    try testing.expectError(error.MalformedToken, verifyIdToken(a, "onlyonepart", &.{}, "iss", "aud", 0, 60));
}

test "discover parses a real-shaped OIDC discovery document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Raw = struct {
        issuer: []const u8,
        authorization_endpoint: []const u8,
        token_endpoint: []const u8,
        jwks_uri: []const u8,
    };
    const json =
        \\{"issuer":"https://oauth.telegram.org","authorization_endpoint":"https://oauth.telegram.org/auth",
        \\"token_endpoint":"https://oauth.telegram.org/token","jwks_uri":"https://oauth.telegram.org/.well-known/jwks.json",
        \\"response_types_supported":["code"],"scopes_supported":["openid","profile","phone"]}
    ;
    const parsed = try std.json.parseFromSliceLeaky(Raw, a, json, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("https://oauth.telegram.org", parsed.issuer);
    try testing.expectEqualStrings("https://oauth.telegram.org/auth", parsed.authorization_endpoint);
    try testing.expectEqualStrings("https://oauth.telegram.org/token", parsed.token_endpoint);
    try testing.expectEqualStrings("https://oauth.telegram.org/.well-known/jwks.json", parsed.jwks_uri);
}

test "fetchJwks-shaped parsing: EC/P-256 keys decode, other kty/crv are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate(testing.io);
    const sec1 = key_pair.public_key.toUncompressedSec1();
    const x_b64 = try b64UrlNoPad(a, sec1[1..33]);
    const y_b64 = try b64UrlNoPad(a, sec1[33..65]);

    const RawKey = struct {
        kty: []const u8,
        crv: ?[]const u8 = null,
        kid: []const u8,
        x: ?[]const u8 = null,
        y: ?[]const u8 = null,
    };
    const RawSet = struct { keys: []const RawKey };

    const raw = RawSet{ .keys = &.{
        .{ .kty = "EC", .crv = "P-256", .kid = "good", .x = x_b64, .y = y_b64 },
        .{ .kty = "RSA", .crv = null, .kid = "ignored-rsa", .x = null, .y = null },
        .{ .kty = "EC", .crv = "P-384", .kid = "ignored-p384", .x = x_b64, .y = y_b64 },
    } };
    const body = try std.json.Stringify.valueAlloc(a, raw, .{});

    // Mirrors fetchJwks's own parse+filter body without a real HTTP call.
    const parsed = try std.json.parseFromSliceLeaky(RawSet, a, body, .{ .ignore_unknown_fields = true });
    var out: std.ArrayList(JwkKey) = .empty;
    for (parsed.keys) |k| {
        if (!std.mem.eql(u8, k.kty, "EC")) continue;
        if (k.crv == null or !std.mem.eql(u8, k.crv.?, "P-256")) continue;
        const kx = k.x orelse continue;
        const ky = k.y orelse continue;
        var x_buf: [32]u8 = undefined;
        var y_buf: [32]u8 = undefined;
        std.base64.url_safe_no_pad.Decoder.decode(&x_buf, kx) catch continue;
        std.base64.url_safe_no_pad.Decoder.decode(&y_buf, ky) catch continue;
        var out_sec1: [65]u8 = undefined;
        out_sec1[0] = 0x04;
        @memcpy(out_sec1[1..33], &x_buf);
        @memcpy(out_sec1[33..65], &y_buf);
        try out.append(a, .{ .kid = k.kid, .sec1 = out_sec1 });
    }
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("good", out.items[0].kid);
    try testing.expectEqualSlices(u8, &sec1, &out.items[0].sec1);
}
