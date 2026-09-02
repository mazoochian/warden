//! Cryptographic primitives Instagram's private mobile-app API requires for
//! its password-encryption login step: AES-256-GCM (already in
//! `std.crypto.aead.aes_gcm`, just not otherwise used in this codebase yet)
//! plus RSA-PKCS1v1.5 *encryption*, which `std.crypto` in this Zig version
//! (0.16.0) does NOT expose — it only ships RSA signature-verification
//! primitives (`std.crypto.Certificate.rsa`), built on the public bignum
//! modexp in `std.crypto.ff`. This file hand-rolls RSAES-PKCS1-V1_5-ENCRYPT
//! per RFC 8017 §7.2.1 on top of that same public `std.crypto.ff` primitive
//! — the highest-risk code in the whole Instagram connector, since a subtle
//! bug here doesn't throw, it just produces plausible-looking wrong output.
//! See the RSA tests below for how correctness is cross-checked.
const std = @import("std");
const Io = std.Io;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const GcmResult = struct {
    ciphertext: []u8,
    tag: [Aes256Gcm.tag_length]u8,
};

/// AES-256-GCM encrypt. `ciphertext` is allocated and returned alongside the
/// 16-byte tag; caller owns and frees `result.ciphertext`.
pub fn gcmEncrypt(
    allocator: std.mem.Allocator,
    key: [Aes256Gcm.key_length]u8,
    iv: [Aes256Gcm.nonce_length]u8,
    aad: []const u8,
    plaintext: []const u8,
) !GcmResult {
    const ciphertext = try allocator.alloc(u8, plaintext.len);
    errdefer allocator.free(ciphertext);
    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    Aes256Gcm.encrypt(ciphertext, &tag, plaintext, aad, iv, key);
    return .{ .ciphertext = ciphertext, .tag = tag };
}

/// AES-256-GCM decrypt/verify. Returns `error.AuthenticationFailed` if
/// `tag` doesn't match — caller owns and frees the returned plaintext.
pub fn gcmDecrypt(
    allocator: std.mem.Allocator,
    key: [Aes256Gcm.key_length]u8,
    iv: [Aes256Gcm.nonce_length]u8,
    aad: []const u8,
    ciphertext: []const u8,
    tag: [Aes256Gcm.tag_length]u8,
) ![]u8 {
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    try Aes256Gcm.decrypt(plaintext, ciphertext, tag, aad, iv, key);
    return plaintext;
}

/// Upper bound on RSA modulus size this module supports — comfortably above
/// any RSA key size Instagram's login endpoint has ever been observed
/// using (2048-bit / 256-byte moduli), with headroom in case that ever
/// changes. `std.crypto.ff.Modulus`/`Fe` need this as a comptime bound; the
/// actual modulus byte length used at runtime comes from `modulus_bytes.len`
/// below, not from this constant.
const max_rsa_bits = 4096;
const RsaModulus = std.crypto.ff.Modulus(max_rsa_bits);
const RsaFe = RsaModulus.Fe;

pub const RsaError = error{
    /// `message.len` doesn't leave room for the minimum 11 bytes of
    /// RFC 8017 §7.2.1 padding overhead within the given modulus size.
    MessageTooLong,
} || std.crypto.ff.Error || std.mem.Allocator.Error;

/// RSAES-PKCS1-V1_5-ENCRYPT (RFC 8017 §7.2.1): encrypts `message` with the
/// RSA public key `(modulus_bytes, exponent)`. `modulus_bytes` is the
/// modulus `n` as a big-endian byte string (no leading sign byte);
/// `exponent` is the public exponent `e` (typically 65537). Returns a
/// ciphertext exactly `modulus_bytes.len` bytes long — caller owns and
/// frees it.
///
/// This is Instagram's `enc_password` scheme's RSA step: the AES-256-GCM
/// session key gets RSA-PKCS1v1.5-encrypted with a public key Instagram's
/// login endpoint hands out fresh per request (see `instagram/transport.zig`
/// for the request that fetches `(modulus_bytes, exponent)` and the
/// `key_id` that travels alongside it in the final payload).
pub fn rsaPkcs1v15Encrypt(
    io: Io,
    allocator: std.mem.Allocator,
    modulus_bytes: []const u8,
    exponent: u32,
    message: []const u8,
) RsaError![]u8 {
    const k = modulus_bytes.len;
    if (message.len + 11 > k) return error.MessageTooLong;

    // EM = 0x00 || 0x02 || PS || 0x00 || M, exactly k bytes.
    const em = try allocator.alloc(u8, k);
    defer allocator.free(em);
    em[0] = 0x00;
    em[1] = 0x02;
    const ps = em[2 .. k - message.len - 1];
    // PS must contain no zero bytes (RFC 8017 §7.2.1) — that's a real
    // padding-format requirement (a stray zero byte would be
    // indistinguishable from the 0x00 separator on decrypt), not
    // cosmetic, so zero bytes are rejected and redrawn rather than
    // merely avoided-by-probability. Randomness comes from the runtime's
    // entropy source (`std.Io.random`), matching this codebase's existing
    // convention (e.g. `matrix/olm.zig`'s `fillRandom`).
    var i: usize = 0;
    while (i < ps.len) {
        var chunk: [64]u8 = undefined;
        const n = @min(chunk.len, ps.len - i);
        io.random(chunk[0..n]);
        for (chunk[0..n]) |b| {
            if (b == 0) continue;
            ps[i] = b;
            i += 1;
        }
    }
    em[k - message.len - 1] = 0x00;
    @memcpy(em[k - message.len ..], message);

    const modulus = try RsaModulus.fromBytes(modulus_bytes, .big);
    const m = try RsaFe.fromBytes(modulus, em, .big);
    const e = try RsaFe.fromPrimitive(u32, modulus, exponent);
    const c = try modulus.powPublic(m, e);

    const ciphertext = try allocator.alloc(u8, k);
    errdefer allocator.free(ciphertext);
    try c.toBytes(ciphertext, .big);
    return ciphertext;
}

/// Test-only RSA decrypt: same modexp primitive as `rsaPkcs1v15Encrypt`,
/// just with the private exponent `d` instead of the public one, used
/// below to self-verify `rsaPkcs1v15Encrypt`'s round trip without needing
/// OpenSSL available at `zig build test` time. NOT constant-time with
/// respect to `d` (uses `powPublic`, which is only safe when the exponent
/// is genuinely public) — never call this outside a test with a
/// throwaway keypair.
fn testOnlyRsaPkcs1v15Decrypt(allocator: std.mem.Allocator, modulus_bytes: []const u8, private_exponent_bytes: []const u8, ciphertext: []const u8) ![]u8 {
    const k = modulus_bytes.len;
    std.debug.assert(ciphertext.len == k);

    const modulus = try RsaModulus.fromBytes(modulus_bytes, .big);
    const c = try RsaFe.fromBytes(modulus, ciphertext, .big);
    const d = try RsaFe.fromBytes(modulus, private_exponent_bytes, .big);
    const m = try modulus.powPublic(c, d);

    const em = try allocator.alloc(u8, k);
    defer allocator.free(em);
    try m.toBytes(em, .big);

    if (em[0] != 0x00 or em[1] != 0x02) return error.InvalidPadding;
    const sep = std.mem.indexOfScalarPos(u8, em, 2, 0x00) orelse return error.InvalidPadding;
    return allocator.dupe(u8, em[sep + 1 ..]);
}

const testing = std.testing;

test "gcmEncrypt/gcmDecrypt round trip recovers the original plaintext" {
    const key = [_]u8{0x42} ** Aes256Gcm.key_length;
    const iv = [_]u8{0x24} ** Aes256Gcm.nonce_length;
    const aad = "1735689600"; // e.g. a unix timestamp, as Instagram's enc_password uses
    const plaintext = "hunter2-but-a-real-password-would-be-longer";

    const enc = try gcmEncrypt(testing.allocator, key, iv, aad, plaintext);
    defer testing.allocator.free(enc.ciphertext);

    const dec = try gcmDecrypt(testing.allocator, key, iv, aad, enc.ciphertext, enc.tag);
    defer testing.allocator.free(dec);

    try testing.expectEqualStrings(plaintext, dec);
}

test "gcmDecrypt rejects a tampered ciphertext" {
    const key = [_]u8{0x11} ** Aes256Gcm.key_length;
    const iv = [_]u8{0x22} ** Aes256Gcm.nonce_length;
    const enc = try gcmEncrypt(testing.allocator, key, iv, "", "some secret");
    defer testing.allocator.free(enc.ciphertext);

    enc.ciphertext[0] ^= 0xff;
    try testing.expectError(error.AuthenticationFailed, gcmDecrypt(testing.allocator, key, iv, "", enc.ciphertext, enc.tag));
}

test "gcmEncrypt matches std.crypto.aead.aes_gcm's own known-answer test vector" {
    // Same key/nonce/message/ad std lib uses in aes_gcm.zig's
    // "Message and associated data" test — cross-checks our thin wrapper
    // against std's own KAT rather than just round-tripping against itself.
    const key: [Aes256Gcm.key_length]u8 = [_]u8{0x69} ** Aes256Gcm.key_length;
    const nonce: [Aes256Gcm.nonce_length]u8 = [_]u8{0x42} ** Aes256Gcm.nonce_length;
    const m = "Test with message";
    const ad = "Test with associated data";

    const enc = try gcmEncrypt(testing.allocator, key, nonce, ad, m);
    defer testing.allocator.free(enc.ciphertext);

    var expected_c: [m.len]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_c, "5ca1642d90009fea33d01f78cf6eefaf01");
    var expected_tag: [Aes256Gcm.tag_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_tag, "64accec679d444e2373bd9f6796c0d2c");

    try testing.expectEqualSlices(u8, &expected_c, enc.ciphertext);
    try testing.expectEqualSlices(u8, &expected_tag, &enc.tag);
}

// Fixture 2048-bit RSA keypair, generated locally with
// `openssl genrsa 2048` purely for this test (never used for anything
// real). n/e/d extracted with `openssl asn1parse` on the PKCS#1
// RSAPrivateKey DER structure. Manually cross-checked once at
// implementation time: encrypted a fixed plaintext with
// `rsaPkcs1v15Encrypt` below, wrote the ciphertext to a file, and ran
// `openssl pkeyutl -decrypt -inkey <this keypair's priv.pem> -in
// <ciphertext>` — it recovered the plaintext byte-for-byte, confirming
// this implementation is wire-compatible with a real RSA implementation.
// The in-suite test below re-verifies the same round trip using only
// `std.crypto.ff` (via `testOnlyRsaPkcs1v15Decrypt`) so it doesn't depend
// on OpenSSL being installed wherever `zig build test` runs.
const test_rsa_n_hex =
    "AC88D10ED5B6A4029DAAD38BBE957AEF4395B9931B1F088058887533219AFF" ++
    "87E7C756AE8A85953BD9BC46296DF6A66B3D9858AB90A098115F43FB8581BB9" ++
    "A5C00AB89665F199A5FCBEC755ECA585F5DDF0722088369E69D3DF262F26A07" ++
    "06D38B4D79ED9A5C3AD5BA2462A83D25C757961C88430EBE4E01E7534285AAD" ++
    "51DD8C00BCE11515B0F3FF6270AAFB4D0F13718735A9C7338A9E17C98365E40" ++
    "4278B920C2053359DF083E6AD2D69DF30827137E2CE2A895230485C1C79E7EB" ++
    "292AF497E66F1C7DD0849999CDBA67D9FB78D379D0BE0F3D806A6E49739E197" ++
    "C9322D1408DE46638B17F405FE8926C6DD615ACF1B2BB02DA434B8E9A135CA6" ++
    "F4DC6E09B";
const test_rsa_e: u32 = 65537;
const test_rsa_d_hex =
    "20814A39AC43D3947695E7730D7DE6024BCE5A7EFF7E1240F3ED097F8F963F0C2" ++
    "0BBAA7609BCEF07AE96CCF5233573D7026CC04FDA58972DB6AFFD2402F41039C3" ++
    "1A8E314E3B699D20B334CD9DFB9643FE2FBED6B1C372E22EF88A71B74E0998334" ++
    "76E703843A605FC22BCBF8B7DA197BBBD3662C3D550A70528E7807D55D7605E3B" ++
    "63D0A7F69C328CA8DF6B86B03F73B67AE8727C571D6799EF8D12DA29CAD09C13A" ++
    "D79B426F8E66B969BE742659B8CF5164B9869871410AA6846321F4C1B0763AF3E" ++
    "7547D8209D36B90C68D25121D614B635E94F883CE62DB649D22A960EA2AAEF532" ++
    "2A02EF6DA07F01862E989A6F56F563B96485E17B9004610D0C5A68DC9";

fn testRsaFixture(allocator: std.mem.Allocator) !struct { n: []u8, d: []u8 } {
    const n = try allocator.alloc(u8, test_rsa_n_hex.len / 2);
    _ = try std.fmt.hexToBytes(n, test_rsa_n_hex);
    const d = try allocator.alloc(u8, test_rsa_d_hex.len / 2);
    _ = try std.fmt.hexToBytes(d, test_rsa_d_hex);
    return .{ .n = n, .d = d };
}

test "rsaPkcs1v15Encrypt round-trips through a fixture keypair's private exponent" {
    const fixture = try testRsaFixture(testing.allocator);
    defer testing.allocator.free(fixture.n);
    defer testing.allocator.free(fixture.d);

    const plaintext = "0123456789abcdef0123456789abcdef"; // a 32-byte AES-256 session key, in shape
    const ciphertext = try rsaPkcs1v15Encrypt(testing.io, testing.allocator, fixture.n, test_rsa_e, plaintext);
    defer testing.allocator.free(ciphertext);

    try testing.expectEqual(fixture.n.len, ciphertext.len);

    const recovered = try testOnlyRsaPkcs1v15Decrypt(testing.allocator, fixture.n, fixture.d, ciphertext);
    defer testing.allocator.free(recovered);

    try testing.expectEqualStrings(plaintext, recovered);
}

test "rsaPkcs1v15Encrypt produces different ciphertexts each call (randomized padding)" {
    const fixture = try testRsaFixture(testing.allocator);
    defer testing.allocator.free(fixture.n);
    defer testing.allocator.free(fixture.d);

    const plaintext = "same message every time";
    const c1 = try rsaPkcs1v15Encrypt(testing.io, testing.allocator, fixture.n, test_rsa_e, plaintext);
    defer testing.allocator.free(c1);
    const c2 = try rsaPkcs1v15Encrypt(testing.io, testing.allocator, fixture.n, test_rsa_e, plaintext);
    defer testing.allocator.free(c2);

    try testing.expect(!std.mem.eql(u8, c1, c2));

    const r1 = try testOnlyRsaPkcs1v15Decrypt(testing.allocator, fixture.n, fixture.d, c1);
    defer testing.allocator.free(r1);
    const r2 = try testOnlyRsaPkcs1v15Decrypt(testing.allocator, fixture.n, fixture.d, c2);
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings(plaintext, r1);
    try testing.expectEqualStrings(plaintext, r2);
}

test "rsaPkcs1v15Encrypt rejects a message with no room for padding" {
    const fixture = try testRsaFixture(testing.allocator);
    defer testing.allocator.free(fixture.n);
    defer testing.allocator.free(fixture.d);

    const too_long = try testing.allocator.alloc(u8, fixture.n.len - 10); // needs >= 11 bytes overhead
    defer testing.allocator.free(too_long);
    @memset(too_long, 'x');

    try testing.expectError(error.MessageTooLong, rsaPkcs1v15Encrypt(testing.io, testing.allocator, fixture.n, test_rsa_e, too_long));
}

test "rsaPkcs1v15Encrypt's padding string never contains a zero byte" {
    const fixture = try testRsaFixture(testing.allocator);
    defer testing.allocator.free(fixture.n);
    defer testing.allocator.free(fixture.d);

    // A short message maximizes PS length, giving zero-byte rejection the
    // most opportunities to matter across repeated runs.
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        const ciphertext = try rsaPkcs1v15Encrypt(testing.io, testing.allocator, fixture.n, test_rsa_e, "x");
        defer testing.allocator.free(ciphertext);
        const recovered = try testOnlyRsaPkcs1v15Decrypt(testing.allocator, fixture.n, fixture.d, ciphertext);
        defer testing.allocator.free(recovered);
        try testing.expectEqualStrings("x", recovered);
    }
}
