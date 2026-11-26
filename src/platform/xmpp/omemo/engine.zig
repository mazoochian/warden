//! The bot's one OMEMO (0.3, `eu.siacs.conversations.axolotl`) device:
//! identity and pre-key management, peer sessions, and encrypting /
//! decrypting `<encrypted>` elements. libomemo-c does the Signal protocol;
//! its stores are backed by Postgres (`store/omemo.zig`), sealed under the
//! configured key.
const std = @import("std");
const Io = std.Io;

const sig = @import("signal.zig");
const provider = @import("provider.zig");
const xml = @import("../xml.zig");
const stanza = @import("../stanza.zig");
const store = @import("../../../store/omemo.zig");
const PgPool = @import("../../../store/pool.zig").PgPool;
const log = @import("../../../log.zig").scoped("omemo");

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.standard;

pub const ns = stanza.ns_omemo;
pub const devicelist_node = ns ++ ".devicelist";
pub const bundles_node_prefix = ns ++ ".bundles:";

const prekey_target = 100;
/// Below this many unused pre-keys the bundle is topped up and republished.
const prekey_low_water = 80;

pub const Target = struct { jid: []const u8, device_id: i32 };

pub const Decrypted = struct {
    sender_device: i32,
    /// Null for a key-transport message (no payload).
    plaintext: ?[]u8,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: Io,
    pool: *PgPool,
    seal_key: [32]u8,
    own_jid: []const u8,
    crypto_ctx: provider.Context,
    crypto: sig.signal_crypto_provider,
    global: *sig.signal_context,
    store_ctx: *sig.signal_protocol_store_context,
    /// libsignal is not thread-safe; every public call holds this.
    mu: Io.Mutex = .init,
    device_id: u32 = 0,
    registration_id: u32 = 0,
    identity_public: []u8 = &.{},
    identity_private: []u8 = &.{},
    next_prekey_id: u32 = 1,
    signed_prekey_id: u32 = 1,
    /// Set by the pre-key store when a pre-key is consumed.
    prekey_consumed: std.atomic.Value(bool) = .init(false),

    /// `secret` is WARDEN_XMPP_OMEMO_KEY; `own_bare_jid` is the bot's JID.
    pub fn init(allocator: std.mem.Allocator, io: Io, pool: *PgPool, secret: []const u8, own_bare_jid: []const u8) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .pool = pool,
            .seal_key = deriveSealKey(secret),
            .own_jid = try allocator.dupe(u8, own_bare_jid),
            .crypto_ctx = .{ .io = io },
            .crypto = undefined,
            .global = undefined,
            .store_ctx = undefined,
        };
        errdefer allocator.free(self.own_jid);
        self.crypto = provider.provider(&self.crypto_ctx);

        var global: ?*sig.signal_context = null;
        try check(sig.signal_context_create(&global, self));
        self.global = global.?;
        errdefer sig.signal_context_destroy(self.global);
        try check(sig.signal_context_set_crypto_provider(self.global, &self.crypto));
        try check(sig.signal_context_set_log_function(self.global, logFn));

        var sc: ?*sig.signal_protocol_store_context = null;
        try check(sig.signal_protocol_store_context_create(&sc, self.global));
        self.store_ctx = sc.?;
        errdefer sig.signal_protocol_store_context_destroy(self.store_ctx);
        try self.installStores();

        try self.loadOrCreateDevice();
        _ = try self.topUpPreKeys();
        return self;
    }

    pub fn deinit(self: *Engine) void {
        sig.signal_protocol_store_context_destroy(self.store_ctx);
        sig.signal_context_destroy(self.global);
        std.crypto.secureZero(u8, self.identity_private);
        self.allocator.free(self.identity_private);
        self.allocator.free(self.identity_public);
        self.allocator.free(self.own_jid);
        std.crypto.secureZero(u8, &self.seal_key);
        self.allocator.destroy(self);
    }

    fn deriveSealKey(secret: []const u8) [32]u8 {
        var h = Sha256.init(.{});
        h.update("warden-xmpp-omemo-v1:");
        h.update(secret);
        return h.finalResult();
    }

    fn check(rc: c_int) !void {
        if (rc < 0) {
            log.debug("libomemo-c returned {d}", .{rc});
            return switch (rc) {
                sig.SG_ERR_NOMEM => error.OutOfMemory,
                sig.SG_ERR_DUPLICATE_MESSAGE => error.DuplicateMessage,
                sig.SG_ERR_INVALID_KEY, sig.SG_ERR_INVALID_KEY_ID => error.InvalidKey,
                sig.SG_ERR_INVALID_MAC, sig.SG_ERR_INVALID_MESSAGE => error.InvalidMessage,
                sig.SG_ERR_NO_SESSION => error.NoSession,
                sig.SG_ERR_UNTRUSTED_IDENTITY => error.UntrustedIdentity,
                else => error.SignalError,
            };
        }
    }

    fn logFn(level: c_int, message: [*]const u8, len: usize, _: ?*anyopaque) callconv(.c) void {
        if (level <= 1) log.warn("libomemo-c: {s}", .{message[0..len]}) else log.debug("libomemo-c: {s}", .{message[0..len]});
    }

    // --- sealing ---------------------------------------------------------

    /// base64(nonce || ciphertext || tag) under `seal_key`.
    pub fn seal(self: *Engine, allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
        const raw = try allocator.alloc(u8, Aes256Gcm.nonce_length + plain.len + Aes256Gcm.tag_length);
        defer allocator.free(raw);
        const nonce = raw[0..Aes256Gcm.nonce_length];
        self.io.random(nonce);
        const ct = raw[Aes256Gcm.nonce_length..][0..plain.len];
        const tag = raw[Aes256Gcm.nonce_length + plain.len ..][0..Aes256Gcm.tag_length];
        Aes256Gcm.encrypt(ct, tag, plain, "", nonce.*, self.seal_key);
        const out = try allocator.alloc(u8, b64.Encoder.calcSize(raw.len));
        _ = b64.Encoder.encode(out, raw);
        return out;
    }

    pub fn open(self: *Engine, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        const raw = try allocator.alloc(u8, try b64.Decoder.calcSizeForSlice(text));
        defer allocator.free(raw);
        try b64.Decoder.decode(raw, text);
        if (raw.len < Aes256Gcm.nonce_length + Aes256Gcm.tag_length) return error.SealedValueTooShort;
        const n = raw.len - Aes256Gcm.nonce_length - Aes256Gcm.tag_length;
        const out = try allocator.alloc(u8, n);
        errdefer allocator.free(out);
        Aes256Gcm.decrypt(out, raw[Aes256Gcm.nonce_length..][0..n], raw[raw.len - Aes256Gcm.tag_length ..][0..Aes256Gcm.tag_length].*, "", raw[0..Aes256Gcm.nonce_length].*, self.seal_key) catch return error.SealedValueCorrupt;
        return out;
    }

    // --- device identity -------------------------------------------------

    fn loadOrCreateDevice(self: *Engine) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (try store.loadDevice(self.pool, a, self.own_jid)) |d| {
            self.device_id = d.device_id;
            self.registration_id = d.registration_id;
            self.identity_public = try self.allocator.dupe(u8, try decodeB64(a, d.identity_public));
            self.identity_private = try self.open(self.allocator, d.identity_private);
            self.next_prekey_id = d.next_prekey_id;
            self.signed_prekey_id = d.current_signed_prekey_id;
            return;
        }

        var identity: ?*sig.ratchet_identity_key_pair = null;
        try check(sig.signal_protocol_key_helper_generate_identity_key_pair(&identity, self.global));
        defer sig.unref(identity.?);
        try check(sig.signal_protocol_key_helper_generate_registration_id(&self.registration_id, 0, self.global));

        var id_bytes: [4]u8 = undefined;
        self.io.random(&id_bytes);
        self.device_id = (std.mem.readInt(u32, &id_bytes, .little) & 0x7fffffff) | 1;

        var pub_buf: ?*sig.signal_buffer = null;
        try check(sig.ec_public_key_serialize(&pub_buf, sig.ratchet_identity_key_pair_get_public(identity.?)));
        self.identity_public = try sig.takeBuffer(self.allocator, pub_buf.?);
        var priv_buf: ?*sig.signal_buffer = null;
        try check(sig.ec_private_key_serialize(&priv_buf, sig.ratchet_identity_key_pair_get_private(identity.?)));
        self.identity_private = try sig.takeBuffer(self.allocator, priv_buf.?);

        self.signed_prekey_id = 1;
        var spk: ?*sig.session_signed_pre_key = null;
        const now_ms: u64 = @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms));
        try check(sig.signal_protocol_key_helper_generate_signed_pre_key(&spk, identity.?, self.signed_prekey_id, now_ms, self.global));
        defer sig.unref(spk.?);
        var spk_buf: ?*sig.signal_buffer = null;
        try check(sig.session_signed_pre_key_serialize(&spk_buf, spk.?));
        const spk_bytes = try sig.takeBuffer(a, spk_buf.?);
        try store.storeKey(self.pool, self.own_jid, .signed_prekeys, self.signed_prekey_id, try self.seal(a, spk_bytes));

        self.next_prekey_id = 1;
        try store.saveDevice(self.pool, self.own_jid, .{
            .device_id = self.device_id,
            .registration_id = self.registration_id,
            .identity_public = try encodeB64(a, self.identity_public),
            .identity_private = try self.seal(a, self.identity_private),
            .next_prekey_id = self.next_prekey_id,
            .current_signed_prekey_id = self.signed_prekey_id,
        });
        log.notice("created OMEMO device {d}", .{self.device_id});
    }

    /// Generates pre-keys up to `prekey_target`. True when any were added.
    fn topUpPreKeys(self: *Engine) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const existing = try store.listKeys(self.pool, a, self.own_jid, .prekeys);
        if (existing.len >= prekey_low_water and self.next_prekey_id > 1) return false;
        const count: u32 = @intCast(prekey_target - @min(existing.len, prekey_target));
        if (count == 0) return false;

        var head: ?*sig.pre_key_list_node = null;
        try check(sig.signal_protocol_key_helper_generate_pre_keys(&head, self.next_prekey_id, count, self.global));
        defer sig.signal_protocol_key_helper_key_list_free(head);
        var node = head;
        while (node) |n| : (node = sig.signal_protocol_key_helper_key_list_next(n)) {
            const pk = sig.signal_protocol_key_helper_key_list_element(n);
            var buf: ?*sig.signal_buffer = null;
            try check(sig.session_pre_key_serialize(&buf, pk));
            const bytes = try sig.takeBuffer(a, buf.?);
            try store.storeKey(self.pool, self.own_jid, .prekeys, sig.session_pre_key_get_id(pk), try self.seal(a, bytes));
        }
        // Pre-key ids are 24-bit in the wire format; wrap well before that.
        self.next_prekey_id = if (self.next_prekey_id + count >= 0xFFFFFE) 1 else self.next_prekey_id + count;
        try store.setNextPreKeyId(self.pool, self.own_jid, self.next_prekey_id);
        return true;
    }

    /// True (once) when a pre-key was used since the last call; the caller
    /// should republish the bundle. Tops up the pre-keys first.
    pub fn takeRepublishNeeded(self: *Engine) bool {
        if (!self.prekey_consumed.swap(false, .acq_rel)) return false;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        _ = self.topUpPreKeys() catch |err| log.warn("failed to top up pre-keys: {t}", .{err});
        return true;
    }

    /// Conversations' fingerprint display: the 32-byte key, hex, in groups
    /// of eight.
    pub fn fingerprint(self: *Engine, allocator: std.mem.Allocator) ![]u8 {
        return formatFingerprint(allocator, self.identity_public);
    }

    pub fn formatFingerprint(allocator: std.mem.Allocator, serialized_key: []const u8) ![]u8 {
        const key = if (serialized_key.len == 33) serialized_key[1..] else serialized_key;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (key, 0..) |b, i| {
            if (i > 0 and i % 4 == 0) try out.append(allocator, ' ');
            try out.print(allocator, "{x:0>2}", .{b});
        }
        return out.toOwnedSlice(allocator);
    }

    // --- PEP payloads ----------------------------------------------------

    /// The `<bundle>` element to publish at `bundles:<device_id>`.
    pub fn bundleXml(self: *Engine, allocator: std.mem.Allocator) ![]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const spk_sealed = (try store.loadKey(self.pool, a, self.own_jid, .signed_prekeys, self.signed_prekey_id)) orelse return error.NoSignedPreKey;
        const spk_bytes = try self.open(a, spk_sealed);
        var spk: ?*sig.session_signed_pre_key = null;
        try check(sig.session_signed_pre_key_deserialize(&spk, spk_bytes.ptr, spk_bytes.len, self.global));
        defer sig.unref(spk.?);
        var spk_pub: ?*sig.signal_buffer = null;
        try check(sig.ec_public_key_serialize(&spk_pub, sig.ec_key_pair_get_public(sig.session_signed_pre_key_get_key_pair(spk.?))));
        const spk_pub_bytes = try sig.takeBuffer(a, spk_pub.?);
        const signature = sig.session_signed_pre_key_get_signature(spk.?)[0..sig.session_signed_pre_key_get_signature_len(spk.?)];

        var out: Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("<bundle xmlns='" ++ ns ++ "'><signedPreKeyPublic signedPreKeyId='{d}'>{s}</signedPreKeyPublic>", .{ self.signed_prekey_id, try encodeB64(a, spk_pub_bytes) });
        try w.print("<signedPreKeySignature>{s}</signedPreKeySignature>", .{try encodeB64(a, signature)});
        try w.print("<identityKey>{s}</identityKey><prekeys>", .{try encodeB64(a, self.identity_public)});
        for (try store.listKeys(self.pool, a, self.own_jid, .prekeys)) |rec| {
            const bytes = self.open(a, rec.record) catch continue;
            var pk: ?*sig.session_pre_key = null;
            check(sig.session_pre_key_deserialize(&pk, bytes.ptr, bytes.len, self.global)) catch continue;
            defer sig.unref(pk.?);
            var pub_buf: ?*sig.signal_buffer = null;
            check(sig.ec_public_key_serialize(&pub_buf, sig.ec_key_pair_get_public(sig.session_pre_key_get_key_pair(pk.?)))) catch continue;
            const pub_bytes = try sig.takeBuffer(a, pub_buf.?);
            try w.print("<preKeyPublic preKeyId='{d}'>{s}</preKeyPublic>", .{ rec.id, try encodeB64(a, pub_bytes) });
        }
        try w.writeAll("</prekeys></bundle>");
        return out.toOwnedSlice();
    }

    // --- sessions --------------------------------------------------------

    pub fn hasSession(self: *Engine, jid: []const u8, device_id: i32) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const addr: sig.signal_protocol_address = .{ .name = jid.ptr, .name_len = jid.len, .device_id = device_id };
        return sig.signal_protocol_session_contains_session(self.store_ctx, &addr) == 1;
    }

    /// Builds a session with `jid`'s `device_id` from its published bundle
    /// (the `<bundle>` element).
    pub fn processBundle(self: *Engine, jid: []const u8, device_id: i32, bundle: xml.Element) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const spk_el = bundle.child("signedPreKeyPublic") orelse return error.MalformedBundle;
        const spk_id = try std.fmt.parseInt(u32, spk_el.attr("signedPreKeyId") orelse return error.MalformedBundle, 10);
        const spk_bytes = try decodeB64(a, stanza.firstText(spk_el) orelse return error.MalformedBundle);
        const sig_bytes = try decodeB64(a, stanza.firstText(bundle.child("signedPreKeySignature") orelse return error.MalformedBundle) orelse return error.MalformedBundle);
        const ik_bytes = try decodeB64(a, stanza.firstText(bundle.child("identityKey") orelse return error.MalformedBundle) orelse return error.MalformedBundle);

        // A random one of the advertised one-time pre-keys.
        const prekeys_el = bundle.child("prekeys") orelse return error.MalformedBundle;
        var candidates: std.ArrayList(xml.Element) = .empty;
        for (prekeys_el.children) |node| switch (node) {
            .element => |e| if (std.mem.eql(u8, e.name, "preKeyPublic")) try candidates.append(a, e),
            .text => {},
        };
        if (candidates.items.len == 0) return error.MalformedBundle;
        var pick_bytes: [4]u8 = undefined;
        self.io.random(&pick_bytes);
        const pick = candidates.items[std.mem.readInt(u32, &pick_bytes, .little) % candidates.items.len];
        const pk_id = try std.fmt.parseInt(u32, pick.attr("preKeyId") orelse return error.MalformedBundle, 10);
        const pk_bytes = try decodeB64(a, stanza.firstText(pick) orelse return error.MalformedBundle);

        var spk: ?*sig.ec_public_key = null;
        try check(sig.curve_decode_point(&spk, spk_bytes.ptr, spk_bytes.len, self.global));
        defer sig.unref(spk.?);
        var ik: ?*sig.ec_public_key = null;
        try check(sig.curve_decode_point(&ik, ik_bytes.ptr, ik_bytes.len, self.global));
        defer sig.unref(ik.?);
        var pk: ?*sig.ec_public_key = null;
        try check(sig.curve_decode_point(&pk, pk_bytes.ptr, pk_bytes.len, self.global));
        defer sig.unref(pk.?);

        var bundle_obj: ?*sig.session_pre_key_bundle = null;
        try check(sig.session_pre_key_bundle_create(&bundle_obj, 0, device_id, pk_id, pk.?, spk_id, spk.?, sig_bytes.ptr, sig_bytes.len, ik.?));
        defer sig.unref(bundle_obj.?);

        const addr: sig.signal_protocol_address = .{ .name = jid.ptr, .name_len = jid.len, .device_id = device_id };
        var builder: ?*sig.session_builder = null;
        try check(sig.session_builder_create(&builder, self.store_ctx, &addr, self.global));
        defer sig.session_builder_free(builder.?);
        try check(sig.session_builder_process_pre_key_bundle(builder.?, bundle_obj.?));
        log.info("built a session with {s} device {d}", .{ jid, device_id });
    }

    // --- messages --------------------------------------------------------

    /// Encrypts `plaintext` for every target that has a session and returns
    /// the serialized `<encrypted>` element.
    pub fn encrypt(self: *Engine, allocator: std.mem.Allocator, targets: []const Target, plaintext: []const u8) ![]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var key: [16]u8 = undefined;
        var iv: [12]u8 = undefined;
        self.io.random(&key);
        self.io.random(&iv);
        defer std.crypto.secureZero(u8, &key);
        const ct = try a.alloc(u8, plaintext.len);
        var key_material: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &key_material);
        Aes128Gcm.encrypt(ct, key_material[16..32], plaintext, "", iv, key);
        @memcpy(key_material[0..16], &key);

        var out: Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("<encrypted xmlns='" ++ ns ++ "'><header sid='{d}'>", .{self.device_id});
        var keys: usize = 0;
        for (targets) |t| {
            const addr: sig.signal_protocol_address = .{ .name = t.jid.ptr, .name_len = t.jid.len, .device_id = t.device_id };
            if (sig.signal_protocol_session_contains_session(self.store_ctx, &addr) != 1) continue;
            var cipher: ?*sig.session_cipher = null;
            check(sig.session_cipher_create(&cipher, self.store_ctx, &addr, self.global)) catch continue;
            defer sig.session_cipher_free(cipher.?);
            var msg: ?*sig.ciphertext_message = null;
            check(sig.session_cipher_encrypt(cipher.?, &key_material, key_material.len, &msg)) catch |err| {
                log.warn("failed to encrypt for {s} device {d}: {t}", .{ t.jid, t.device_id, err });
                continue;
            };
            defer sig.unref(msg.?);
            const ser = sig.ciphertext_message_get_serialized(msg.?);
            const bytes = sig.signal_buffer_data(ser)[0..sig.signal_buffer_len(ser)];
            const prekey = sig.ciphertext_message_get_type(msg.?) == sig.CIPHERTEXT_PREKEY_TYPE;
            try w.print("<key rid='{d}'{s}>{s}</key>", .{ t.device_id, if (prekey) " prekey='true'" else "", try encodeB64(a, bytes) });
            keys += 1;
        }
        if (keys == 0) return error.NoSessions;
        try w.print("<iv>{s}</iv></header><payload>{s}</payload></encrypted>", .{ try encodeB64(a, &iv), try encodeB64(a, ct) });
        return out.toOwnedSlice();
    }

    /// Decrypts an inbound `<encrypted>` element from `sender_jid` (bare).
    pub fn decrypt(self: *Engine, allocator: std.mem.Allocator, sender_jid: []const u8, encrypted: xml.Element) !Decrypted {
        const header = encrypted.child("header") orelse return error.MalformedMessage;
        const sid = try std.fmt.parseInt(i32, header.attr("sid") orelse return error.MalformedMessage, 10);

        var our_key: ?xml.Element = null;
        var iv_text: ?[]const u8 = null;
        for (header.children) |node| switch (node) {
            .element => |e| {
                if (std.mem.eql(u8, e.name, "key")) {
                    const rid = std.fmt.parseInt(u32, e.attr("rid") orelse continue, 10) catch continue;
                    if (rid == self.device_id) our_key = e;
                } else if (std.mem.eql(u8, e.name, "iv")) {
                    iv_text = stanza.firstText(e);
                }
            },
            .text => {},
        };
        const key_el = our_key orelse return error.NotEncryptedForThisDevice;
        const prekey_attr = key_el.attr("prekey") orelse "";
        const is_prekey = std.mem.eql(u8, prekey_attr, "true") or std.mem.eql(u8, prekey_attr, "1");

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const key_bytes = try decodeB64(a, stanza.firstText(key_el) orelse return error.MalformedMessage);

        const material = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const addr: sig.signal_protocol_address = .{ .name = sender_jid.ptr, .name_len = sender_jid.len, .device_id = sid };
            var cipher: ?*sig.session_cipher = null;
            try check(sig.session_cipher_create(&cipher, self.store_ctx, &addr, self.global));
            defer sig.session_cipher_free(cipher.?);
            var plain: ?*sig.signal_buffer = null;
            if (is_prekey) {
                var m: ?*sig.pre_key_signal_message = null;
                try check(sig.pre_key_signal_message_deserialize(&m, key_bytes.ptr, key_bytes.len, self.global));
                defer sig.unref(m.?);
                try check(sig.session_cipher_decrypt_pre_key_signal_message(cipher.?, m.?, null, &plain));
            } else {
                var m: ?*sig.signal_message = null;
                try check(sig.signal_message_deserialize(&m, key_bytes.ptr, key_bytes.len, self.global));
                defer sig.unref(m.?);
                try check(sig.session_cipher_decrypt_signal_message(cipher.?, m.?, null, &plain));
            }
            break :blk try sig.takeBuffer(a, plain.?);
        };
        defer std.crypto.secureZero(u8, material);

        const payload_el = encrypted.child("payload") orelse return .{ .sender_device = sid, .plaintext = null };
        const payload = try decodeB64(a, stanza.firstText(payload_el) orelse return .{ .sender_device = sid, .plaintext = null });
        const iv = try decodeB64(a, iv_text orelse return error.MalformedMessage);
        if (iv.len != Aes128Gcm.nonce_length) return error.UnsupportedIvLength;
        if (material.len < 16) return error.MalformedMessage;

        // 0.3 carries the GCM tag after the key; very old clients append it
        // to the payload instead.
        var tag: [16]u8 = undefined;
        var ct: []const u8 = payload;
        if (material.len >= 32) {
            tag = material[16..32].*;
        } else {
            if (payload.len < 16) return error.MalformedMessage;
            tag = payload[payload.len - 16 ..][0..16].*;
            ct = payload[0 .. payload.len - 16];
        }
        const out = try allocator.alloc(u8, ct.len);
        errdefer allocator.free(out);
        Aes128Gcm.decrypt(out, ct, tag, "", iv[0..12].*, material[0..16].*) catch return error.PayloadAuthenticationFailed;
        return .{ .sender_device = sid, .plaintext = out };
    }

    // --- store callbacks -------------------------------------------------

    fn installStores(self: *Engine) !void {
        const ud: ?*anyopaque = self;
        try check(sig.signal_protocol_store_context_set_session_store(self.store_ctx, &.{
            .load_session_func = loadSession,
            .get_sub_device_sessions_func = subDeviceSessions,
            .store_session_func = storeSession,
            .contains_session_func = containsSession,
            .delete_session_func = deleteSession,
            .delete_all_sessions_func = deleteAllSessions,
            .destroy_func = null,
            .user_data = ud,
        }));
        try check(sig.signal_protocol_store_context_set_pre_key_store(self.store_ctx, &.{
            .load_pre_key = loadPreKey,
            .store_pre_key = storePreKey,
            .contains_pre_key = containsPreKey,
            .remove_pre_key = removePreKey,
            .destroy_func = null,
            .user_data = ud,
        }));
        try check(sig.signal_protocol_store_context_set_signed_pre_key_store(self.store_ctx, &.{
            .load_signed_pre_key = loadSignedPreKey,
            .store_signed_pre_key = storeSignedPreKey,
            .contains_signed_pre_key = containsSignedPreKey,
            .remove_signed_pre_key = removeSignedPreKey,
            .destroy_func = null,
            .user_data = ud,
        }));
        try check(sig.signal_protocol_store_context_set_identity_key_store(self.store_ctx, &.{
            .get_identity_key_pair = getIdentityKeyPair,
            .get_local_registration_id = getRegistrationId,
            .save_identity = saveIdentity,
            .is_trusted_identity = isTrustedIdentity,
            .destroy_func = null,
            .user_data = ud,
        }));
        try check(sig.signal_protocol_store_context_set_sender_key_store(self.store_ctx, &.{
            .store_sender_key = storeSenderKey,
            .load_sender_key = loadSenderKey,
            .destroy_func = null,
            .user_data = ud,
        }));
    }

    fn fromUd(ud: ?*anyopaque) *Engine {
        return @ptrCast(@alignCast(ud.?));
    }

    fn addrJid(addr: *const sig.signal_protocol_address) []const u8 {
        return addr.name[0..addr.name_len];
    }

    fn bufferFrom(out: *?*sig.signal_buffer, bytes: []const u8) c_int {
        out.* = sig.signal_buffer_create(bytes.ptr, bytes.len) orelse return sig.SG_ERR_NOMEM;
        return sig.SG_SUCCESS;
    }

    fn loadSession(record: *?*sig.signal_buffer, user_record: *?*sig.signal_buffer, addr: *const sig.signal_protocol_address, ud: ?*anyopaque) callconv(.c) c_int {
        _ = user_record;
        const self = fromUd(ud);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const sealed = (store.loadSession(self.pool, arena.allocator(), self.own_jid, addrJid(addr), addr.device_id) catch return sig.SG_ERR_UNKNOWN) orelse return 0;
        const bytes = self.open(arena.allocator(), sealed) catch return sig.SG_ERR_UNKNOWN;
        const rc = bufferFrom(record, bytes);
        return if (rc < 0) rc else 1;
    }

    fn subDeviceSessions(sessions: *?*sig.signal_int_list, name: [*]const u8, name_len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ids = store.sessionDevices(self.pool, arena.allocator(), self.own_jid, name[0..name_len]) catch return sig.SG_ERR_UNKNOWN;
        const list = sig.signal_int_list_alloc() orelse return sig.SG_ERR_NOMEM;
        for (ids) |id| _ = sig.signal_int_list_push_back(list, id);
        sessions.* = list;
        return @intCast(ids.len);
    }

    fn storeSession(addr: *const sig.signal_protocol_address, record: [*]u8, record_len: usize, _: ?[*]u8, _: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const sealed = self.seal(arena.allocator(), record[0..record_len]) catch return sig.SG_ERR_NOMEM;
        store.storeSession(self.pool, self.own_jid, addrJid(addr), addr.device_id, sealed) catch return sig.SG_ERR_UNKNOWN;
        return sig.SG_SUCCESS;
    }

    fn containsSession(addr: *const sig.signal_protocol_address, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const found = store.loadSession(self.pool, arena.allocator(), self.own_jid, addrJid(addr), addr.device_id) catch return 0;
        return if (found != null) 1 else 0;
    }

    fn deleteSession(addr: *const sig.signal_protocol_address, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        const n = store.deleteSessions(self.pool, self.own_jid, addrJid(addr), addr.device_id) catch return sig.SG_ERR_UNKNOWN;
        return @intCast(n);
    }

    fn deleteAllSessions(name: [*]const u8, name_len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        const n = store.deleteSessions(self.pool, self.own_jid, name[0..name_len], null) catch return sig.SG_ERR_UNKNOWN;
        return @intCast(n);
    }

    fn loadKeyInto(self: *Engine, comptime table: store.KeyTable, out: *?*sig.signal_buffer, id: u32) c_int {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const sealed = (store.loadKey(self.pool, arena.allocator(), self.own_jid, table, id) catch return sig.SG_ERR_UNKNOWN) orelse return sig.SG_ERR_INVALID_KEY_ID;
        const bytes = self.open(arena.allocator(), sealed) catch return sig.SG_ERR_UNKNOWN;
        return bufferFrom(out, bytes);
    }

    fn storeKeyFrom(self: *Engine, comptime table: store.KeyTable, id: u32, record: []const u8) c_int {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const sealed = self.seal(arena.allocator(), record) catch return sig.SG_ERR_NOMEM;
        store.storeKey(self.pool, self.own_jid, table, id, sealed) catch return sig.SG_ERR_UNKNOWN;
        return sig.SG_SUCCESS;
    }

    fn containsKey(self: *Engine, comptime table: store.KeyTable, id: u32) c_int {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const found = store.loadKey(self.pool, arena.allocator(), self.own_jid, table, id) catch return 0;
        return if (found != null) 1 else 0;
    }

    fn loadPreKey(record: *?*sig.signal_buffer, id: u32, ud: ?*anyopaque) callconv(.c) c_int {
        return fromUd(ud).loadKeyInto(.prekeys, record, id);
    }
    fn storePreKey(id: u32, record: [*]u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        return fromUd(ud).storeKeyFrom(.prekeys, id, record[0..len]);
    }
    fn containsPreKey(id: u32, ud: ?*anyopaque) callconv(.c) c_int {
        return fromUd(ud).containsKey(.prekeys, id);
    }
    fn removePreKey(id: u32, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        store.removeKey(self.pool, self.own_jid, .prekeys, id) catch return sig.SG_ERR_UNKNOWN;
        self.prekey_consumed.store(true, .release);
        return sig.SG_SUCCESS;
    }
    fn loadSignedPreKey(record: *?*sig.signal_buffer, id: u32, ud: ?*anyopaque) callconv(.c) c_int {
        return fromUd(ud).loadKeyInto(.signed_prekeys, record, id);
    }
    fn storeSignedPreKey(id: u32, record: [*]u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        return fromUd(ud).storeKeyFrom(.signed_prekeys, id, record[0..len]);
    }
    fn containsSignedPreKey(id: u32, ud: ?*anyopaque) callconv(.c) c_int {
        return fromUd(ud).containsKey(.signed_prekeys, id);
    }
    fn removeSignedPreKey(id: u32, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        store.removeKey(self.pool, self.own_jid, .signed_prekeys, id) catch return sig.SG_ERR_UNKNOWN;
        return sig.SG_SUCCESS;
    }

    fn getIdentityKeyPair(public_data: *?*sig.signal_buffer, private_data: *?*sig.signal_buffer, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        const rc = bufferFrom(public_data, self.identity_public);
        if (rc < 0) return rc;
        return bufferFrom(private_data, self.identity_private);
    }

    fn getRegistrationId(ud: ?*anyopaque, registration_id: *u32) callconv(.c) c_int {
        registration_id.* = fromUd(ud).registration_id;
        return sig.SG_SUCCESS;
    }

    fn saveIdentity(addr: *const sig.signal_protocol_address, key_data: ?[*]u8, key_len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        const data = key_data orelse {
            store.resetDevice(self.pool, self.own_jid, addrJid(addr), addr.device_id) catch return sig.SG_ERR_UNKNOWN;
            return sig.SG_SUCCESS;
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const encoded = encodeB64(arena.allocator(), data[0..key_len]) catch return sig.SG_ERR_NOMEM;
        store.saveIdentityIfNew(self.pool, self.own_jid, addrJid(addr), addr.device_id, encoded) catch return sig.SG_ERR_UNKNOWN;
        return sig.SG_SUCCESS;
    }

    /// Trust on first use: an unknown device is trusted, a known one only
    /// with the key it first presented.
    fn isTrustedIdentity(addr: *const sig.signal_protocol_address, key_data: [*]u8, key_len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const stored = (store.loadIdentity(self.pool, a, self.own_jid, addrJid(addr), addr.device_id) catch return sig.SG_ERR_UNKNOWN) orelse {
            const fp = formatFingerprint(a, key_data[0..key_len]) catch "";
            log.notice("trusting new OMEMO device {d} of {s} on first use: {s}", .{ addr.device_id, addrJid(addr), fp });
            return 1;
        };
        const presented = encodeB64(a, key_data[0..key_len]) catch return sig.SG_ERR_NOMEM;
        if (std.mem.eql(u8, stored, presented)) return 1;
        log.warn("OMEMO device {d} of {s} presented a different identity key; refusing it", .{ addr.device_id, addrJid(addr) });
        return 0;
    }

    fn storeSenderKey(_: *const sig.sender_key_name, _: [*]u8, _: usize, _: ?[*]u8, _: usize, _: ?*anyopaque) callconv(.c) c_int {
        return sig.SG_ERR_UNKNOWN;
    }
    fn loadSenderKey(_: *?*sig.signal_buffer, _: *?*sig.signal_buffer, _: *const sig.sender_key_name, _: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }
};

pub fn encodeB64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, b64.Encoder.calcSize(data.len));
    _ = b64.Encoder.encode(out, data);
    return out;
}

/// Tolerates the line breaks some clients put in long base64 values.
pub fn decodeB64(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    for (text) |c| if (!std.ascii.isWhitespace(c)) try clean.append(allocator, c);
    const out = try allocator.alloc(u8, try b64.Decoder.calcSizeForSlice(clean.items));
    errdefer allocator.free(out);
    try b64.Decoder.decode(out, clean.items);
    return out;
}

/// Device ids from a devicelist `<list>` (inside a pubsub `<item>`).
pub fn parseDeviceList(allocator: std.mem.Allocator, list: xml.Element) ![]i32 {
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(allocator);
    for (list.children) |node| switch (node) {
        .element => |e| if (std.mem.eql(u8, e.name, "device")) {
            const id = std.fmt.parseInt(i32, e.attr("id") orelse continue, 10) catch continue;
            if (id > 0) try out.append(allocator, id);
        },
        .text => {},
    };
    return out.toOwnedSlice(allocator);
}

/// Finds `<pubsub><items><item><NAME xmlns=ns>` in an IQ result.
pub fn pubsubPayload(iq: xml.Element, name: []const u8) ?xml.Element {
    const pubsub = iq.child("pubsub") orelse return null;
    const items = pubsub.child("items") orelse return null;
    for (items.children) |node| switch (node) {
        .element => |item| if (std.mem.eql(u8, item.name, "item")) {
            if (stanza.childNs(item, name, ns)) |p| return p;
        },
        .text => {},
    };
    return null;
}

const testing = std.testing;
const test_support = @import("../../../store/test_support.zig");

test "formatFingerprint groups the key (without its type byte) in eights" {
    var key: [33]u8 = undefined;
    key[0] = 0x05;
    for (key[1..], 0..) |*b, i| b.* = @intCast(i);
    const fp = try Engine.formatFingerprint(testing.allocator, &key);
    defer testing.allocator.free(fp);
    try testing.expect(std.mem.startsWith(u8, fp, "00010203 04050607 "));
    try testing.expectEqual(@as(usize, 64 + 7), fp.len);
}

test "parseDeviceList and pubsubPayload read a devicelist result" {
    var parsed = try xml.parseElement(testing.allocator,
        \\<iq type='result'><pubsub xmlns='http://jabber.org/protocol/pubsub'>
        \\<items node='eu.siacs.conversations.axolotl.devicelist'><item id='current'>
        \\<list xmlns='eu.siacs.conversations.axolotl'><device id='123'/><device id='x'/><device id='456'/></list>
        \\</item></items></pubsub></iq>
    );
    defer parsed.deinit();
    const list = pubsubPayload(parsed.element, "list").?;
    const ids = try parseDeviceList(testing.allocator, list);
    defer testing.allocator.free(ids);
    try testing.expectEqualSlices(i32, &.{ 123, 456 }, ids);
}

test "two engines establish a session from a bundle and exchange messages both ways" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const bob = try Engine.init(testing.allocator, testing.io, &pool, "bob-secret", "bob@example.org");
    defer bob.deinit();
    const bob_bundle_xml = try bob.bundleXml(testing.allocator);
    defer testing.allocator.free(bob_bundle_xml);
    const alice = try Engine.init(testing.allocator, testing.io, &pool, "alice-secret", "alice@example.org");
    defer alice.deinit();

    var bundle = try xml.parseElement(testing.allocator, bob_bundle_xml);
    defer bundle.deinit();
    try alice.processBundle("bob@example.org", @intCast(bob.device_id), bundle.element);
    try testing.expect(alice.hasSession("bob@example.org", @intCast(bob.device_id)));

    const enc = try alice.encrypt(testing.allocator, &.{.{ .jid = "bob@example.org", .device_id = @intCast(bob.device_id) }}, "hi bob");
    defer testing.allocator.free(enc);
    try testing.expect(std.mem.indexOf(u8, enc, "prekey='true'") != null);

    var enc_el = try xml.parseElement(testing.allocator, enc);
    defer enc_el.deinit();
    const got = try bob.decrypt(testing.allocator, "alice@example.org", enc_el.element);
    defer testing.allocator.free(got.plaintext.?);
    try testing.expectEqualStrings("hi bob", got.plaintext.?);
    try testing.expectEqual(@as(i32, @intCast(alice.device_id)), got.sender_device);
    try testing.expect(bob.takeRepublishNeeded());

    // Bob answers over the now-established session (a normal message).
    const reply = try bob.encrypt(testing.allocator, &.{.{ .jid = "alice@example.org", .device_id = @intCast(alice.device_id) }}, "hi alice");
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "prekey=") == null);
    var reply_el = try xml.parseElement(testing.allocator, reply);
    defer reply_el.deinit();
    const back = try alice.decrypt(testing.allocator, "bob@example.org", reply_el.element);
    defer testing.allocator.free(back.plaintext.?);
    try testing.expectEqualStrings("hi alice", back.plaintext.?);
}
