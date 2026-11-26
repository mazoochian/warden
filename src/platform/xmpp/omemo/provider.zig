//! The `signal_crypto_provider` libomemo-c calls back into: HMAC-SHA256,
//! SHA-512, AES-CBC/PKCS#7 and AES-CTR, and randomness, all on std.crypto.
const std = @import("std");
const sig = @import("signal.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Aes128 = std.crypto.core.aes.Aes128;
const Aes256 = std.crypto.core.aes.Aes256;

/// `user_data` for every callback; `random_func` needs the `Io`.
pub const Context = struct {
    io: std.Io,
};

const heap = std.heap.c_allocator;

pub fn provider(ctx: *Context) sig.signal_crypto_provider {
    return .{
        .random_func = randomFn,
        .hmac_sha256_init_func = hmacInit,
        .hmac_sha256_update_func = hmacUpdate,
        .hmac_sha256_final_func = hmacFinal,
        .hmac_sha256_cleanup_func = hmacCleanup,
        .sha512_digest_init_func = shaInit,
        .sha512_digest_update_func = shaUpdate,
        .sha512_digest_final_func = shaFinal,
        .sha512_digest_cleanup_func = shaCleanup,
        .encrypt_func = encryptFn,
        .decrypt_func = decryptFn,
        .user_data = ctx,
    };
}

fn randomFn(data: [*]u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *Context = @ptrCast(@alignCast(user_data orelse return sig.SG_ERR_INVAL));
    ctx.io.random(data[0..len]);
    return sig.SG_SUCCESS;
}

fn hmacInit(out: *?*anyopaque, key: [*]const u8, key_len: usize, _: ?*anyopaque) callconv(.c) c_int {
    const h = heap.create(HmacSha256) catch return sig.SG_ERR_NOMEM;
    h.* = HmacSha256.init(key[0..key_len]);
    out.* = h;
    return sig.SG_SUCCESS;
}

fn hmacUpdate(ctx: ?*anyopaque, data: [*]const u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
    const h: *HmacSha256 = @ptrCast(@alignCast(ctx orelse return sig.SG_ERR_INVAL));
    h.update(data[0..len]);
    return sig.SG_SUCCESS;
}

fn hmacFinal(ctx: ?*anyopaque, output: *?*sig.signal_buffer, _: ?*anyopaque) callconv(.c) c_int {
    const h: *HmacSha256 = @ptrCast(@alignCast(ctx orelse return sig.SG_ERR_INVAL));
    var mac: [HmacSha256.mac_length]u8 = undefined;
    h.final(&mac);
    output.* = sig.signal_buffer_create(&mac, mac.len) orelse return sig.SG_ERR_NOMEM;
    return sig.SG_SUCCESS;
}

fn hmacCleanup(ctx: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const h: *HmacSha256 = @ptrCast(@alignCast(ctx orelse return));
    std.crypto.secureZero(u8, std.mem.asBytes(h));
    heap.destroy(h);
}

fn shaInit(out: *?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const h = heap.create(Sha512) catch return sig.SG_ERR_NOMEM;
    h.* = Sha512.init(.{});
    out.* = h;
    return sig.SG_SUCCESS;
}

fn shaUpdate(ctx: ?*anyopaque, data: [*]const u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
    const h: *Sha512 = @ptrCast(@alignCast(ctx orelse return sig.SG_ERR_INVAL));
    h.update(data[0..len]);
    return sig.SG_SUCCESS;
}

/// libsignal reuses the context after `final`, so it is reset here.
fn shaFinal(ctx: ?*anyopaque, output: *?*sig.signal_buffer, _: ?*anyopaque) callconv(.c) c_int {
    const h: *Sha512 = @ptrCast(@alignCast(ctx orelse return sig.SG_ERR_INVAL));
    var digest: [Sha512.digest_length]u8 = undefined;
    h.final(&digest);
    h.* = Sha512.init(.{});
    output.* = sig.signal_buffer_create(&digest, digest.len) orelse return sig.SG_ERR_NOMEM;
    return sig.SG_SUCCESS;
}

fn shaCleanup(ctx: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const h: *Sha512 = @ptrCast(@alignCast(ctx orelse return));
    heap.destroy(h);
}

fn encryptFn(output: *?*sig.signal_buffer, cipher: c_int, key: [*]const u8, key_len: usize, iv: [*]const u8, iv_len: usize, plaintext: [*]const u8, plaintext_len: usize, _: ?*anyopaque) callconv(.c) c_int {
    const out = runCipher(.encrypt, cipher, key[0..key_len], iv[0..iv_len], plaintext[0..plaintext_len]) catch |err| return errCode(err);
    defer {
        std.crypto.secureZero(u8, out);
        heap.free(out);
    }
    output.* = sig.signal_buffer_create(out.ptr, out.len) orelse return sig.SG_ERR_NOMEM;
    return sig.SG_SUCCESS;
}

fn decryptFn(output: *?*sig.signal_buffer, cipher: c_int, key: [*]const u8, key_len: usize, iv: [*]const u8, iv_len: usize, ciphertext: [*]const u8, ciphertext_len: usize, _: ?*anyopaque) callconv(.c) c_int {
    const out = runCipher(.decrypt, cipher, key[0..key_len], iv[0..iv_len], ciphertext[0..ciphertext_len]) catch |err| return errCode(err);
    defer {
        std.crypto.secureZero(u8, out);
        heap.free(out);
    }
    output.* = sig.signal_buffer_create(out.ptr, out.len) orelse return sig.SG_ERR_NOMEM;
    return sig.SG_SUCCESS;
}

fn errCode(err: anyerror) c_int {
    return if (err == error.OutOfMemory) sig.SG_ERR_NOMEM else sig.SG_ERR_UNKNOWN;
}

const Direction = enum { encrypt, decrypt };

/// Output is `heap`-allocated.
pub fn runCipher(dir: Direction, cipher: c_int, key: []const u8, iv: []const u8, input: []const u8) ![]u8 {
    if (iv.len != 16) return error.InvalidIv;
    return switch (key.len) {
        16 => runWith(Aes128, dir, cipher, key[0..16].*, iv[0..16].*, input),
        32 => runWith(Aes256, dir, cipher, key[0..32].*, iv[0..16].*, input),
        else => error.InvalidKeyLength,
    };
}

fn runWith(comptime Aes: type, dir: Direction, cipher: c_int, key: [Aes.key_bits / 8]u8, iv: [16]u8, input: []const u8) ![]u8 {
    switch (cipher) {
        sig.SG_CIPHER_AES_CTR_NOPADDING => {
            const out = try heap.alloc(u8, input.len);
            const ctx = Aes.initEnc(key);
            std.crypto.core.modes.ctr(@TypeOf(ctx), ctx, out, input, iv, .big);
            return out;
        },
        sig.SG_CIPHER_AES_CBC_PKCS5 => return switch (dir) {
            .encrypt => cbcEncrypt(Aes, key, iv, input),
            .decrypt => cbcDecrypt(Aes, key, iv, input),
        },
        else => return error.UnsupportedCipher,
    }
}

fn cbcEncrypt(comptime Aes: type, key: [Aes.key_bits / 8]u8, iv: [16]u8, input: []const u8) ![]u8 {
    const pad: usize = 16 - input.len % 16;
    const out = try heap.alloc(u8, input.len + pad);
    const ctx = Aes.initEnc(key);
    var prev = iv;
    var i: usize = 0;
    while (i < out.len) : (i += 16) {
        var block: [16]u8 = undefined;
        for (0..16) |j| {
            const b = if (i + j < input.len) input[i + j] else @as(u8, @intCast(pad));
            block[j] = b ^ prev[j];
        }
        ctx.encrypt(out[i..][0..16], &block);
        prev = out[i..][0..16].*;
    }
    return out;
}

fn cbcDecrypt(comptime Aes: type, key: [Aes.key_bits / 8]u8, iv: [16]u8, input: []const u8) ![]u8 {
    if (input.len == 0 or input.len % 16 != 0) return error.InvalidCiphertext;
    const out = try heap.alloc(u8, input.len);
    errdefer heap.free(out);
    const ctx = Aes.initDec(key);
    var prev = iv;
    var i: usize = 0;
    while (i < input.len) : (i += 16) {
        var block: [16]u8 = undefined;
        ctx.decrypt(&block, input[i..][0..16]);
        for (0..16) |j| out[i + j] = block[j] ^ prev[j];
        prev = input[i..][0..16].*;
    }
    const pad = out[out.len - 1];
    if (pad == 0 or pad > 16) return error.InvalidPadding;
    for (out[out.len - pad ..]) |b| if (b != pad) return error.InvalidPadding;
    const trimmed = try heap.realloc(out, out.len - pad);
    return trimmed;
}

const testing = std.testing;

fn hexBytes(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "AES-128-CBC matches NIST SP 800-38A F.2.1 (first block) and round-trips with PKCS#7" {
    const key = hexBytes("2b7e151628aed2a6abf7158809cf4f3c");
    const iv = hexBytes("000102030405060708090a0b0c0d0e0f");
    const pt = hexBytes("6bc1bee22e409f96e93d7e117393172a");
    const ct = try runCipher(.encrypt, sig.SG_CIPHER_AES_CBC_PKCS5, &key, &iv, &pt);
    defer heap.free(ct);
    try testing.expectEqual(@as(usize, 32), ct.len); // one full pad block
    try testing.expectEqualSlices(u8, &hexBytes("7649abac8119b246cee98e9b12e9197d"), ct[0..16]);
    const back = try runCipher(.decrypt, sig.SG_CIPHER_AES_CBC_PKCS5, &key, &iv, ct);
    defer heap.free(back);
    try testing.expectEqualSlices(u8, &pt, back);
}

test "AES-256-CBC round-trips odd lengths and rejects bad padding" {
    const key = hexBytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    const iv = hexBytes("000102030405060708090a0b0c0d0e0f");
    const ct = try runCipher(.encrypt, sig.SG_CIPHER_AES_CBC_PKCS5, &key, &iv, "hello omemo");
    defer heap.free(ct);
    try testing.expectEqual(@as(usize, 16), ct.len);
    const back = try runCipher(.decrypt, sig.SG_CIPHER_AES_CBC_PKCS5, &key, &iv, ct);
    defer heap.free(back);
    try testing.expectEqualStrings("hello omemo", back);

    var tampered: [16]u8 = ct[0..16].*;
    tampered[15] ^= 0xff;
    try testing.expectError(error.InvalidPadding, runCipher(.decrypt, sig.SG_CIPHER_AES_CBC_PKCS5, &key, &iv, &tampered));
}

test "AES-128-CTR matches NIST SP 800-38A F.5.1 (first block)" {
    const key = hexBytes("2b7e151628aed2a6abf7158809cf4f3c");
    const iv = hexBytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
    const pt = hexBytes("6bc1bee22e409f96e93d7e117393172a");
    const ct = try runCipher(.encrypt, sig.SG_CIPHER_AES_CTR_NOPADDING, &key, &iv, &pt);
    defer heap.free(ct);
    try testing.expectEqualSlices(u8, &hexBytes("874d6191b620e3261bef6864990db6ce"), ct);
}
