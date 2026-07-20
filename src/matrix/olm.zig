//! Zig binding for libolm — the audited C library implementing the Olm
//! (per-device Double Ratchet) and Megolm (group ratchet) protocols Matrix
//! E2E encryption is built on. Deliberately bound via FFI rather than
//! reimplemented, same load-bearing decision `ROADMAP.md`'s Phase 2b
//! documents: hand-rolling a cryptographic ratchet from scratch carries
//! real risk of subtly-wrong crypto with no way to catch it short of a
//! security review and test vectors libolm has already been through.
//!
//! libolm's C API is a set of opaque object types the *caller* allocates
//! raw memory for (queried via `olm_account_size()` etc.) and the library
//! initializes in place — a good fit for a thin Zig wrapper: each type here
//! owns its backing `[]u8` (allocated via a caller-supplied allocator) and
//! is deinitialized by clearing (zeroing key material) then freeing it.
//! `olm_error()` is the sentinel nearly every C function returns on
//! failure; `check` below turns that into a Zig error, logging the
//! object-specific `_last_error()` string libolm provides for diagnosis.

const std = @import("std");

const c = struct {
    pub extern fn olm_error() usize;

    pub const CAccount = opaque {};
    extern fn olm_account_size() usize;
    extern fn olm_account(memory: [*]u8) *CAccount;
    extern fn olm_account_last_error(account: *const CAccount) [*:0]const u8;
    extern fn olm_clear_account(account: *CAccount) usize;
    extern fn olm_pickle_account_length(account: *const CAccount) usize;
    extern fn olm_pickle_account(account: *CAccount, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_unpickle_account(account: *CAccount, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_create_account_random_length(account: *const CAccount) usize;
    extern fn olm_create_account(account: *CAccount, random: [*]u8, random_length: usize) usize;
    extern fn olm_account_identity_keys_length(account: *const CAccount) usize;
    extern fn olm_account_identity_keys(account: *CAccount, identity_keys: [*]u8, identity_key_length: usize) usize;
    extern fn olm_account_signature_length(account: *const CAccount) usize;
    extern fn olm_account_sign(account: *CAccount, message: [*]const u8, message_length: usize, signature: [*]u8, signature_length: usize) usize;
    extern fn olm_account_one_time_keys_length(account: *const CAccount) usize;
    extern fn olm_account_one_time_keys(account: *CAccount, one_time_keys: [*]u8, one_time_keys_length: usize) usize;
    extern fn olm_account_mark_keys_as_published(account: *CAccount) usize;
    extern fn olm_account_max_number_of_one_time_keys(account: *const CAccount) usize;
    extern fn olm_account_generate_one_time_keys_random_length(account: *const CAccount, number_of_keys: usize) usize;
    extern fn olm_account_generate_one_time_keys(account: *CAccount, number_of_keys: usize, random: [*]u8, random_length: usize) usize;
    extern fn olm_remove_one_time_keys(account: *CAccount, session: *CSession) usize;
    extern fn olm_account_generate_fallback_key_random_length(account: *const CAccount) usize;
    extern fn olm_account_generate_fallback_key(account: *CAccount, random: [*]u8, random_length: usize) usize;
    extern fn olm_account_unpublished_fallback_key_length(account: *const CAccount) usize;
    extern fn olm_account_unpublished_fallback_key(account: *CAccount, fallback_key: [*]u8, fallback_key_size: usize) usize;
    extern fn olm_account_forget_old_fallback_key(account: *CAccount) void;

    pub const CSession = opaque {};
    extern fn olm_session_size() usize;
    extern fn olm_session(memory: [*]u8) *CSession;
    extern fn olm_session_last_error(session: *const CSession) [*:0]const u8;
    extern fn olm_clear_session(session: *CSession) usize;
    extern fn olm_pickle_session_length(session: *const CSession) usize;
    extern fn olm_pickle_session(session: *CSession, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_unpickle_session(session: *CSession, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_create_outbound_session_random_length(session: *const CSession) usize;
    extern fn olm_create_outbound_session(session: *CSession, account: *const CAccount, their_identity_key: [*]const u8, their_identity_key_length: usize, their_one_time_key: [*]const u8, their_one_time_key_length: usize, random: [*]u8, random_length: usize) usize;
    extern fn olm_create_inbound_session(session: *CSession, account: *CAccount, one_time_key_message: [*]u8, message_length: usize) usize;
    extern fn olm_session_id_length(session: *const CSession) usize;
    extern fn olm_session_id(session: *CSession, id: [*]u8, id_length: usize) usize;
    extern fn olm_matches_inbound_session(session: *CSession, one_time_key_message: [*]u8, message_length: usize) usize;
    extern fn olm_encrypt_message_type(session: *const CSession) usize;
    extern fn olm_encrypt_random_length(session: *const CSession) usize;
    extern fn olm_encrypt_message_length(session: *const CSession, plaintext_length: usize) usize;
    extern fn olm_encrypt(session: *CSession, plaintext: [*]const u8, plaintext_length: usize, random: [*]u8, random_length: usize, message: [*]u8, message_length: usize) usize;
    extern fn olm_decrypt_max_plaintext_length(session: *CSession, message_type: usize, message: [*]u8, message_length: usize) usize;
    extern fn olm_decrypt(session: *CSession, message_type: usize, message: [*]u8, message_length: usize, plaintext: [*]u8, max_plaintext_length: usize) usize;

    pub const CUtility = opaque {};
    extern fn olm_utility_size() usize;
    extern fn olm_utility(memory: [*]u8) *CUtility;
    extern fn olm_utility_last_error(utility: *const CUtility) [*:0]const u8;
    extern fn olm_clear_utility(utility: *CUtility) usize;
    extern fn olm_sha256_length(utility: *const CUtility) usize;
    extern fn olm_sha256(utility: *CUtility, input: [*]const u8, input_length: usize, output: [*]u8, output_length: usize) usize;
    extern fn olm_ed25519_verify(utility: *CUtility, key: [*]const u8, key_length: usize, message: [*]const u8, message_length: usize, signature: [*]u8, signature_length: usize) usize;

    pub const COutboundGroupSession = opaque {};
    extern fn olm_outbound_group_session_size() usize;
    extern fn olm_outbound_group_session(memory: [*]u8) *COutboundGroupSession;
    extern fn olm_outbound_group_session_last_error(session: *const COutboundGroupSession) [*:0]const u8;
    extern fn olm_clear_outbound_group_session(session: *COutboundGroupSession) usize;
    extern fn olm_pickle_outbound_group_session_length(session: *const COutboundGroupSession) usize;
    extern fn olm_pickle_outbound_group_session(session: *COutboundGroupSession, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_unpickle_outbound_group_session(session: *COutboundGroupSession, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_init_outbound_group_session_random_length(session: *const COutboundGroupSession) usize;
    extern fn olm_init_outbound_group_session(session: *COutboundGroupSession, random: [*]u8, random_length: usize) usize;
    extern fn olm_group_encrypt_message_length(session: *COutboundGroupSession, plaintext_length: usize) usize;
    extern fn olm_group_encrypt(session: *COutboundGroupSession, plaintext: [*]const u8, plaintext_length: usize, message: [*]u8, message_length: usize) usize;
    extern fn olm_outbound_group_session_id_length(session: *const COutboundGroupSession) usize;
    extern fn olm_outbound_group_session_id(session: *COutboundGroupSession, id: [*]u8, id_length: usize) usize;
    extern fn olm_outbound_group_session_key_length(session: *const COutboundGroupSession) usize;
    extern fn olm_outbound_group_session_key(session: *COutboundGroupSession, key: [*]u8, key_length: usize) usize;

    pub const CInboundGroupSession = opaque {};
    extern fn olm_inbound_group_session_size() usize;
    extern fn olm_inbound_group_session(memory: [*]u8) *CInboundGroupSession;
    extern fn olm_inbound_group_session_last_error(session: *const CInboundGroupSession) [*:0]const u8;
    extern fn olm_clear_inbound_group_session(session: *CInboundGroupSession) usize;
    extern fn olm_pickle_inbound_group_session_length(session: *const CInboundGroupSession) usize;
    extern fn olm_pickle_inbound_group_session(session: *CInboundGroupSession, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_unpickle_inbound_group_session(session: *CInboundGroupSession, key: [*]const u8, key_length: usize, pickled: [*]u8, pickled_length: usize) usize;
    extern fn olm_init_inbound_group_session(session: *CInboundGroupSession, session_key: [*]const u8, session_key_length: usize) usize;
    extern fn olm_group_decrypt_max_plaintext_length(session: *CInboundGroupSession, message: [*]u8, message_length: usize) usize;
    extern fn olm_group_decrypt(session: *CInboundGroupSession, message: [*]u8, message_length: usize, plaintext: [*]u8, max_plaintext_length: usize, message_index: *u32) usize;
    extern fn olm_inbound_group_session_id_length(session: *const CInboundGroupSession) usize;
    extern fn olm_inbound_group_session_id(session: *CInboundGroupSession, id: [*]u8, id_length: usize) usize;
    extern fn olm_export_inbound_group_session_length(session: *const CInboundGroupSession) usize;
    extern fn olm_export_inbound_group_session(session: *CInboundGroupSession, key: [*]u8, key_length: usize, message_index: u32) usize;
    extern fn olm_inbound_group_session_first_known_index(session: *const CInboundGroupSession) u32;

    pub const CSas = opaque {};
    extern fn olm_sas_size() usize;
    extern fn olm_sas(memory: [*]u8) *CSas;
    extern fn olm_sas_last_error(sas: *const CSas) [*:0]const u8;
    extern fn olm_clear_sas(sas: *CSas) usize;
    extern fn olm_create_sas_random_length(sas: *const CSas) usize;
    extern fn olm_create_sas(sas: *CSas, random: [*]u8, random_length: usize) usize;
    extern fn olm_sas_pubkey_length(sas: *const CSas) usize;
    extern fn olm_sas_get_pubkey(sas: *CSas, pubkey: [*]u8, pubkey_length: usize) usize;
    extern fn olm_sas_set_their_key(sas: *CSas, their_key: [*]u8, their_key_length: usize) usize;
    extern fn olm_sas_generate_bytes(sas: *CSas, info: [*]const u8, info_length: usize, output: [*]u8, output_length: usize) usize;
    extern fn olm_sas_mac_length(sas: *const CSas) usize;
    extern fn olm_sas_calculate_mac_fixed_base64(sas: *CSas, input: [*]const u8, input_length: usize, info: [*]const u8, info_length: usize, mac: [*]u8, mac_length: usize) usize;
};

pub const OlmError = error{OlmOperationFailed};

/// Fills `buf` with cryptographically secure random bytes via the runtime's
/// own entropy source (`std.Io.random`) — libolm never generates its own
/// randomness, every operation that needs it takes a caller-supplied buffer.
fn fillRandom(io: std.Io, allocator: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    io.random(buf);
    return buf;
}

/// Wraps an OlmAccount: this device's long-term Ed25519 identity key, its
/// Curve25519 identity key, and its pool of one-time/fallback Curve25519
/// keys published for other devices to establish Olm sessions with.
pub const Account = struct {
    mem: []u8,
    ptr: *c.CAccount,

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !Account {
        const mem = try allocator.alloc(u8, c.olm_account_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_account(mem.ptr);

        const random = try fillRandom(io, allocator, c.olm_create_account_random_length(ptr));
        defer allocator.free(random);
        _ = try check(c.olm_create_account(ptr, random.ptr, random.len), errString(.account, ptr));

        return .{ .mem = mem, .ptr = ptr };
    }

    /// Restores a previously-pickled account (see `pickle`) — `pickled` is
    /// destroyed (overwritten) by libolm, matching its C contract.
    pub fn unpickle(allocator: std.mem.Allocator, key: []const u8, pickled: []u8) !Account {
        const mem = try allocator.alloc(u8, c.olm_account_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_account(mem.ptr);
        _ = try check(c.olm_unpickle_account(ptr, key.ptr, key.len, pickled.ptr, pickled.len), errString(.account, ptr));
        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn deinit(self: *Account, allocator: std.mem.Allocator) void {
        _ = c.olm_clear_account(self.ptr);
        allocator.free(self.mem);
        self.* = undefined;
    }

    /// Encrypts and base64-encodes the account's full state (identity key,
    /// private one-time keys, ...) under `key` — persist the result so a
    /// restart doesn't lose the ability to decrypt already-shared room
    /// keys.
    pub fn pickle(self: *Account, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        const len = c.olm_pickle_account_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_pickle_account(self.ptr, key.ptr, key.len, out.ptr, out.len), errString(.account, self.ptr));
        return out;
    }

    /// JSON: `{"curve25519": "...", "ed25519": "..."}`.
    pub fn identityKeysJson(self: *Account, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_account_identity_keys_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_account_identity_keys(self.ptr, out.ptr, out.len), errString(.account, self.ptr));
        return out;
    }

    /// Base64-encoded Ed25519 signature over `message`, using this
    /// account's identity signing key — every published one-time/fallback
    /// key and every to-device room-key share is signed with this so the
    /// receiving device can verify authenticity.
    pub fn sign(self: *Account, allocator: std.mem.Allocator, message: []const u8) ![]u8 {
        const len = c.olm_account_signature_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_account_sign(self.ptr, message.ptr, message.len, out.ptr, out.len), errString(.account, self.ptr));
        return out;
    }

    /// Generates `count` new one-time keys (added to, not replacing, any
    /// already unpublished) — call before `oneTimeKeysJson` + `/keys/upload`.
    pub fn generateOneTimeKeys(self: *Account, allocator: std.mem.Allocator, io: std.Io, count: usize) !void {
        const random = try fillRandom(io, allocator, c.olm_account_generate_one_time_keys_random_length(self.ptr, count));
        defer allocator.free(random);
        _ = try check(c.olm_account_generate_one_time_keys(self.ptr, count, random.ptr, random.len), errString(.account, self.ptr));
    }

    /// JSON: `{"curve25519": {"<key id>": "<base64 key>", ...}}` — the
    /// *unpublished* one-time keys only; call `markKeysAsPublished` after a
    /// successful `/keys/upload` so they aren't offered again.
    pub fn oneTimeKeysJson(self: *Account, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_account_one_time_keys_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_account_one_time_keys(self.ptr, out.ptr, out.len), errString(.account, self.ptr));
        return out;
    }

    pub fn markKeysAsPublished(self: *Account) void {
        _ = c.olm_account_mark_keys_as_published(self.ptr);
    }

    pub fn maxOneTimeKeys(self: *Account) usize {
        return c.olm_account_max_number_of_one_time_keys(self.ptr);
    }

    /// Only one fallback key is ever stored — a fresh call replaces
    /// whatever fallback key was there before. A fallback key is the
    /// one-time-key pool's backstop: if every real one-time key has been
    /// claimed and this device has no fallback published, every future
    /// `/keys/claim` against it fails outright (a documented failure mode
    /// in mature Matrix clients too — see matrix-rust-sdk#281) rather than
    /// the account's own `/keys/upload` traffic ever being able to
    /// recover on its own.
    pub fn generateFallbackKey(self: *Account, allocator: std.mem.Allocator, io: std.Io) !void {
        const random = try fillRandom(io, allocator, c.olm_account_generate_fallback_key_random_length(self.ptr));
        defer allocator.free(random);
        _ = try check(c.olm_account_generate_fallback_key(self.ptr, random.ptr, random.len), errString(.account, self.ptr));
    }

    /// JSON: `{"curve25519": {"<key id>": "<base64 key>"}}` — same shape
    /// `oneTimeKeysJson` returns, but for the (single) unpublished
    /// fallback key. Uses `olm_account_unpublished_fallback_key`, not the
    /// deprecated `olm_account_fallback_key` (per libolm's own header
    /// comment).
    pub fn fallbackKeyJson(self: *Account, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_account_unpublished_fallback_key_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_account_unpublished_fallback_key(self.ptr, out.ptr, out.len), errString(.account, self.ptr));
        return out;
    }

    /// Call once the *previous* fallback key is confirmed no longer
    /// needed (a new one has been published and enough time has passed
    /// that no in-flight `/keys/claim` could still be using the old one).
    pub fn forgetOldFallbackKey(self: *Account) void {
        c.olm_account_forget_old_fallback_key(self.ptr);
    }
};

/// Wraps an OlmSession: a per-device Double Ratchet session, used to
/// encrypt/decrypt the to-device `m.room.encrypted` (algorithm
/// `m.olm.v1.curve25519-aes-sha2`) messages room keys are shared through —
/// not room messages themselves (see `OutboundGroupSession`/
/// `InboundGroupSession` for those).
pub const Session = struct {
    mem: []u8,
    ptr: *c.CSession,

    /// Starts a new session for sending to a peer device, given its
    /// identity key and a one-time key claimed from `/keys/claim`.
    pub fn createOutbound(allocator: std.mem.Allocator, io: std.Io, account: *Account, their_identity_key: []const u8, their_one_time_key: []const u8) !Session {
        const mem = try allocator.alloc(u8, c.olm_session_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_session(mem.ptr);

        const random = try fillRandom(io, allocator, c.olm_create_outbound_session_random_length(ptr));
        defer allocator.free(random);
        _ = try check(c.olm_create_outbound_session(ptr, account.ptr, their_identity_key.ptr, their_identity_key.len, their_one_time_key.ptr, their_one_time_key.len, random.ptr, random.len), errString(.session, ptr));

        return .{ .mem = mem, .ptr = ptr };
    }

    /// Starts a new session from an incoming PRE_KEY message (the first
    /// message on a session we didn't initiate) — `one_time_key_message`
    /// is destroyed (overwritten) by libolm.
    pub fn createInbound(allocator: std.mem.Allocator, account: *Account, one_time_key_message: []u8) !Session {
        const mem = try allocator.alloc(u8, c.olm_session_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_session(mem.ptr);
        _ = try check(c.olm_create_inbound_session(ptr, account.ptr, one_time_key_message.ptr, one_time_key_message.len), errString(.session, ptr));
        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn unpickle(allocator: std.mem.Allocator, key: []const u8, pickled: []u8) !Session {
        const mem = try allocator.alloc(u8, c.olm_session_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_session(mem.ptr);
        _ = try check(c.olm_unpickle_session(ptr, key.ptr, key.len, pickled.ptr, pickled.len), errString(.session, ptr));
        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        _ = c.olm_clear_session(self.ptr);
        allocator.free(self.mem);
        self.* = undefined;
    }

    pub fn pickle(self: *Session, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        const len = c.olm_pickle_session_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_pickle_session(self.ptr, key.ptr, key.len, out.ptr, out.len), errString(.session, self.ptr));
        return out;
    }

    pub fn id(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_session_id_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_session_id(self.ptr, out.ptr, out.len), errString(.session, self.ptr));
        return out;
    }

    /// 0 (PRE_KEY, includes the one-time-key handshake) or 1 (ordinary
    /// ratcheted message) — matches Matrix's `m.olm.v1.curve25519-aes-sha2`
    /// ciphertext `type` field.
    pub fn nextMessageType(self: *Session) !usize {
        return check(c.olm_encrypt_message_type(self.ptr), errString(.session, self.ptr));
    }

    pub fn encrypt(self: *Session, allocator: std.mem.Allocator, io: std.Io, plaintext: []const u8) ![]u8 {
        const random = try fillRandom(io, allocator, c.olm_encrypt_random_length(self.ptr));
        defer allocator.free(random);
        const len = c.olm_encrypt_message_length(self.ptr, plaintext.len);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        // `len` is an upper bound, not necessarily the exact ciphertext
        // size — returning the whole buffer unconditionally would pass a
        // garbage-suffixed message to the receiving end's decrypt (found
        // live: this was silently corrupting every round trip).
        const actual_len = try check(c.olm_encrypt(self.ptr, plaintext.ptr, plaintext.len, random.ptr, random.len, out.ptr, out.len), errString(.session, self.ptr));
        return allocator.realloc(out, actual_len);
    }

    /// `message` is destroyed (overwritten) by libolm.
    /// `message` is destroyed (overwritten) by libolm, per its own
    /// contract — but so is `olm_decrypt_max_plaintext_length`'s input,
    /// undocumented as a shared concern between the two calls: sizing the
    /// output first via that call and then decrypting the *same* buffer
    /// silently corrupts the second call's input (found live: decrypt
    /// failed with BAD_MESSAGE_FORMAT even on a byte-for-byte-correct
    /// ciphertext). A scratch copy absorbs the sizing call's destruction so
    /// the real decrypt still gets pristine bytes.
    pub fn decrypt(self: *Session, allocator: std.mem.Allocator, message_type: usize, message: []u8) ![]u8 {
        const size_probe = try allocator.dupe(u8, message);
        defer allocator.free(size_probe);
        const max_len = try check(c.olm_decrypt_max_plaintext_length(self.ptr, message_type, size_probe.ptr, size_probe.len), errString(.session, self.ptr));

        const out = try allocator.alloc(u8, max_len);
        errdefer allocator.free(out);
        const actual_len = try check(c.olm_decrypt(self.ptr, message_type, message.ptr, message.len, out.ptr, out.len), errString(.session, self.ptr));
        return allocator.realloc(out, actual_len);
    }
};

/// This device's outbound Megolm session for one room — encrypts every
/// `m.room.message` sent to that room after the session's key has been
/// shared (via Olm-encrypted to-device messages) with every other device
/// in the room.
pub const OutboundGroupSession = struct {
    mem: []u8,
    ptr: *c.COutboundGroupSession,

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !OutboundGroupSession {
        const mem = try allocator.alloc(u8, c.olm_outbound_group_session_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_outbound_group_session(mem.ptr);

        const random = try fillRandom(io, allocator, c.olm_init_outbound_group_session_random_length(ptr));
        defer allocator.free(random);
        _ = try check(c.olm_init_outbound_group_session(ptr, random.ptr, random.len), errString(.outbound_group, ptr));

        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn unpickle(allocator: std.mem.Allocator, key: []const u8, pickled: []u8) !OutboundGroupSession {
        const mem = try allocator.alloc(u8, c.olm_outbound_group_session_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_outbound_group_session(mem.ptr);
        _ = try check(c.olm_unpickle_outbound_group_session(ptr, key.ptr, key.len, pickled.ptr, pickled.len), errString(.outbound_group, ptr));
        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn deinit(self: *OutboundGroupSession, allocator: std.mem.Allocator) void {
        _ = c.olm_clear_outbound_group_session(self.ptr);
        allocator.free(self.mem);
        self.* = undefined;
    }

    pub fn pickle(self: *OutboundGroupSession, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        const len = c.olm_pickle_outbound_group_session_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_pickle_outbound_group_session(self.ptr, key.ptr, key.len, out.ptr, out.len), errString(.outbound_group, self.ptr));
        return out;
    }

    pub fn encrypt(self: *OutboundGroupSession, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        const len = c.olm_group_encrypt_message_length(self.ptr, plaintext.len);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        // Same "upper bound, not exact size" caveat as `Session.encrypt`.
        const actual_len = try check(c.olm_group_encrypt(self.ptr, plaintext.ptr, plaintext.len, out.ptr, out.len), errString(.outbound_group, self.ptr));
        return allocator.realloc(out, actual_len);
    }

    pub fn id(self: *OutboundGroupSession, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_outbound_group_session_id_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_outbound_group_session_id(self.ptr, out.ptr, out.len), errString(.outbound_group, self.ptr));
        return out;
    }

    /// The base64 ratchet key shared with room members (via per-device Olm
    /// sessions, as an `m.room_key` to-device event) so they can decrypt
    /// this session's future messages.
    pub fn sessionKey(self: *OutboundGroupSession, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_outbound_group_session_key_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_outbound_group_session_key(self.ptr, out.ptr, out.len), errString(.outbound_group, self.ptr));
        return out;
    }
};

/// A received Megolm session for one room — decrypts `m.room.encrypted`
/// room-timeline events. One per `(room, sender device, session id)`: a
/// room with N actively-posting devices needs N inbound sessions to read
/// everyone's messages.
pub const InboundGroupSession = struct {
    mem: []u8,
    ptr: *c.CInboundGroupSession,

    /// `session_key` is the value received in an `m.room_key` to-device
    /// event (itself Olm-decrypted first — see `Session.decrypt`).
    pub fn create(allocator: std.mem.Allocator, session_key: []const u8) !InboundGroupSession {
        const mem = try allocator.alloc(u8, c.olm_inbound_group_session_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_inbound_group_session(mem.ptr);
        _ = try check(c.olm_init_inbound_group_session(ptr, session_key.ptr, session_key.len), errString(.inbound_group, ptr));
        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn unpickle(allocator: std.mem.Allocator, key: []const u8, pickled: []u8) !InboundGroupSession {
        const mem = try allocator.alloc(u8, c.olm_inbound_group_session_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_inbound_group_session(mem.ptr);
        _ = try check(c.olm_unpickle_inbound_group_session(ptr, key.ptr, key.len, pickled.ptr, pickled.len), errString(.inbound_group, ptr));
        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn deinit(self: *InboundGroupSession, allocator: std.mem.Allocator) void {
        _ = c.olm_clear_inbound_group_session(self.ptr);
        allocator.free(self.mem);
        self.* = undefined;
    }

    pub fn pickle(self: *InboundGroupSession, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        const len = c.olm_pickle_inbound_group_session_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_pickle_inbound_group_session(self.ptr, key.ptr, key.len, out.ptr, out.len), errString(.inbound_group, self.ptr));
        return out;
    }

    pub const Decrypted = struct {
        plaintext: []u8,
        message_index: u32,
    };

    /// `message` is destroyed (overwritten) by libolm — see `Session.
    /// decrypt`'s doc comment on why the sizing call also needs its own
    /// scratch copy rather than reusing the same buffer twice.
    pub fn decrypt(self: *InboundGroupSession, allocator: std.mem.Allocator, message: []u8) !Decrypted {
        const size_probe = try allocator.dupe(u8, message);
        defer allocator.free(size_probe);
        const max_len = try check(c.olm_group_decrypt_max_plaintext_length(self.ptr, size_probe.ptr, size_probe.len), errString(.inbound_group, self.ptr));

        const out = try allocator.alloc(u8, max_len);
        errdefer allocator.free(out);
        var message_index: u32 = 0;
        const actual_len = try check(c.olm_group_decrypt(self.ptr, message.ptr, message.len, out.ptr, out.len, &message_index), errString(.inbound_group, self.ptr));
        return .{ .plaintext = try allocator.realloc(out, actual_len), .message_index = message_index };
    }

    pub fn id(self: *InboundGroupSession, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_inbound_group_session_id_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_inbound_group_session_id(self.ptr, out.ptr, out.len), errString(.inbound_group, self.ptr));
        return out;
    }

    /// Re-exports this session's ratchet key at `message_index`, in the
    /// format `olm_import_inbound_group_session`/(client-side)
    /// `m.forwarded_room_key` expects — the mirror image of `create`,
    /// which takes an `m.room_key`'s `session_key`. Used to answer an
    /// `m.room_key_request`: forwarding a session we already hold to
    /// another of the account's own devices that missed the original
    /// share (to-device delivery is best-effort, not guaranteed — see
    /// `State.handleRoomKeyRequest`'s doc comment).
    pub fn exportAt(self: *InboundGroupSession, allocator: std.mem.Allocator, message_index: u32) ![]u8 {
        const len = c.olm_export_inbound_group_session_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        const actual_len = try check(c.olm_export_inbound_group_session(self.ptr, out.ptr, out.len, message_index), errString(.inbound_group, self.ptr));
        return allocator.realloc(out, actual_len);
    }

    /// The earliest message index this session can decrypt — export must
    /// use this (or a later index), not a hardcoded 0: a session imported
    /// partway through its lifetime (e.g. one this device only learned
    /// about via a forwarded share) may never have known index 0 at all.
    pub fn firstKnownIndex(self: *InboundGroupSession) u32 {
        return c.olm_inbound_group_session_first_known_index(self.ptr);
    }
};

/// Ephemeral key-agreement object for one SAS (Short Authentication
/// String, i.e. emoji/decimal) interactive device verification ceremony
/// — see `matrix/verification.zig` for the Matrix-protocol layer built on
/// top of this. Unlike every other type in this file, there's no
/// `olm_pickle_sas`/`olm_unpickle_sas` — by design, a verification
/// ceremony is a single ephemeral, process-lifetime-only object, never
/// meant to survive a restart.
pub const Sas = struct {
    mem: []u8,
    ptr: *c.CSas,

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !Sas {
        const mem = try allocator.alloc(u8, c.olm_sas_size());
        errdefer allocator.free(mem);
        const ptr = c.olm_sas(mem.ptr);

        const random = try fillRandom(io, allocator, c.olm_create_sas_random_length(ptr));
        defer allocator.free(random);
        _ = try check(c.olm_create_sas(ptr, random.ptr, random.len), errString(.sas, ptr));

        return .{ .mem = mem, .ptr = ptr };
    }

    pub fn deinit(self: *Sas, allocator: std.mem.Allocator) void {
        _ = c.olm_clear_sas(self.ptr);
        allocator.free(self.mem);
        self.* = undefined;
    }

    /// This device's ephemeral Curve25519 public key (unpadded base64) —
    /// sent as `m.key.verification.key`'s `key` field.
    pub fn pubkey(self: *Sas, allocator: std.mem.Allocator) ![]u8 {
        const len = c.olm_sas_pubkey_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_sas_get_pubkey(self.ptr, out.ptr, out.len), errString(.sas, self.ptr));
        return out;
    }

    /// `their_key` is the other device's `m.key.verification.key`. Must be
    /// called before `generateBytes`/`calculateMac` (libolm itself
    /// enforces this, erroring `SAS_THEIR_KEY_NOT_SET` otherwise) —
    /// scratch-copies its input defensively before the call, the same
    /// "found live" caution `Session.decrypt`'s doc comment applies
    /// elsewhere in this file: `sas.h` only documents `their_key` as
    /// overwritten, not the MAC calls' `input`/`info`, but a pristine
    /// caller-owned copy costs nothing and avoids relying on which calls
    /// happen to be silent about a destructive contract.
    pub fn setTheirKey(self: *Sas, allocator: std.mem.Allocator, their_key: []const u8) !void {
        const their_key_mut = try allocator.dupe(u8, their_key);
        defer allocator.free(their_key_mut);
        _ = try check(c.olm_sas_set_their_key(self.ptr, their_key_mut.ptr, their_key_mut.len), errString(.sas, self.ptr));
    }

    /// Derives `output_length` bytes from the shared secret via HKDF,
    /// keyed by `info` (`matrix/verification.zig`'s `sasInfo` builds the
    /// exact Matrix-spec info string) — the raw material the emoji/decimal
    /// short authentication string is formatted from. `their_key` must
    /// already be set.
    pub fn generateBytes(self: *Sas, allocator: std.mem.Allocator, info: []const u8, output_length: usize) ![]u8 {
        const out = try allocator.alloc(u8, output_length);
        errdefer allocator.free(out);
        _ = try check(c.olm_sas_generate_bytes(self.ptr, info.ptr, info.len, out.ptr, out.len), errString(.sas, self.ptr));
        return out;
    }

    /// `hkdf-hmac-sha256.v2` MAC (the modern, non-buggy variant — see
    /// `matrix/verification.zig`'s module doc for why the older
    /// `olm_sas_calculate_mac`/`_long_kdf` variants aren't bound at all).
    pub fn calculateMac(self: *Sas, allocator: std.mem.Allocator, input: []const u8, info: []const u8) ![]u8 {
        const len = c.olm_sas_mac_length(self.ptr);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        _ = try check(c.olm_sas_calculate_mac_fixed_base64(self.ptr, input.ptr, input.len, info.ptr, info.len, out.ptr, out.len), errString(.sas, self.ptr));
        return out;
    }
};

const ObjKind = enum { account, session, outbound_group, inbound_group, sas };

fn errString(kind: ObjKind, ptr: *anyopaque) [*:0]const u8 {
    return switch (kind) {
        .account => c.olm_account_last_error(@ptrCast(ptr)),
        .session => c.olm_session_last_error(@ptrCast(ptr)),
        .outbound_group => c.olm_outbound_group_session_last_error(@ptrCast(ptr)),
        .inbound_group => c.olm_inbound_group_session_last_error(@ptrCast(ptr)),
        .sas => c.olm_sas_last_error(@ptrCast(ptr)),
    };
}

/// Every libolm call funnels through here: `result == olm_error()` means
/// failure, in which case the object-specific error string (already
/// fetched by the caller via `errString`, since it has to happen while the
/// object pointer's type is still known) is logged before returning.
fn check(result: usize, last_error: [*:0]const u8) OlmError!usize {
    if (result == c.olm_error()) {
        std.log.err("olm operation failed: {s}", .{last_error});
        return error.OlmOperationFailed;
    }
    return result;
}

const testing = std.testing;

test "Account.create generates identity keys and can pickle/unpickle" {
    var account = try Account.create(testing.allocator, testing.io);
    defer account.deinit(testing.allocator);

    const keys = try account.identityKeysJson(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expect(std.mem.indexOf(u8, keys, "curve25519") != null);
    try testing.expect(std.mem.indexOf(u8, keys, "ed25519") != null);

    const pickled = try account.pickle(testing.allocator, "test-pickle-key");
    defer testing.allocator.free(pickled);

    var restored = try Account.unpickle(testing.allocator, "test-pickle-key", pickled);
    defer restored.deinit(testing.allocator);
    const restored_keys = try restored.identityKeysJson(testing.allocator);
    defer testing.allocator.free(restored_keys);
    try testing.expectEqualStrings(keys, restored_keys);
}

test "Account one-time key generation produces the requested count" {
    var account = try Account.create(testing.allocator, testing.io);
    defer account.deinit(testing.allocator);

    try account.generateOneTimeKeys(testing.allocator, testing.io, 5);
    const otks = try account.oneTimeKeysJson(testing.allocator);
    defer testing.allocator.free(otks);

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, otks, ':');
    while (it.next()) |_| count += 1;
    // 5 keys means 5 "key_id": "value" pairs, so at least 5 colons beyond
    // the wrapping curve25519 object's own — a loose but simple sanity
    // check that generation actually added keys, not an exact-count parse.
    try testing.expect(count > 5);
}

test "Session.createOutbound + createInbound establish a matching PRE_KEY session, decrypting to the original plaintext" {
    var alice = try Account.create(testing.allocator, testing.io);
    defer alice.deinit(testing.allocator);
    var bob = try Account.create(testing.allocator, testing.io);
    defer bob.deinit(testing.allocator);

    try bob.generateOneTimeKeys(testing.allocator, testing.io, 1);
    const bob_otks_json = try bob.oneTimeKeysJson(testing.allocator);
    defer testing.allocator.free(bob_otks_json);
    const bob_otk = try extractFirstCurve25519Value(testing.allocator, bob_otks_json);
    defer testing.allocator.free(bob_otk);

    const bob_identity_json = try bob.identityKeysJson(testing.allocator);
    defer testing.allocator.free(bob_identity_json);
    const bob_curve25519 = try extractJsonStringField(testing.allocator, bob_identity_json, "curve25519");
    defer testing.allocator.free(bob_curve25519);

    var alice_session = try Session.createOutbound(testing.allocator, testing.io, &alice, bob_curve25519, bob_otk);
    defer alice_session.deinit(testing.allocator);

    const plaintext = "hello bob, this is alice";
    const ciphertext = try alice_session.encrypt(testing.allocator, testing.io, plaintext);
    defer testing.allocator.free(ciphertext);
    const msg_type = try alice_session.nextMessageType();
    // First message on a fresh outbound session must be a PRE_KEY message.
    try testing.expectEqual(@as(usize, 0), msg_type);

    const ciphertext_mut = try testing.allocator.dupe(u8, ciphertext);
    defer testing.allocator.free(ciphertext_mut);
    var bob_session = try Session.createInbound(testing.allocator, &bob, ciphertext_mut);
    defer bob_session.deinit(testing.allocator);

    const ciphertext_mut2 = try testing.allocator.dupe(u8, ciphertext);
    defer testing.allocator.free(ciphertext_mut2);
    const decrypted = try bob_session.decrypt(testing.allocator, msg_type, ciphertext_mut2);
    defer testing.allocator.free(decrypted);
    try testing.expectEqualStrings(plaintext, decrypted);
}

test "OutboundGroupSession + InboundGroupSession round-trip a room message" {
    var out_session = try OutboundGroupSession.create(testing.allocator, testing.io);
    defer out_session.deinit(testing.allocator);

    const session_key = try out_session.sessionKey(testing.allocator);
    defer testing.allocator.free(session_key);

    var in_session = try InboundGroupSession.create(testing.allocator, session_key);
    defer in_session.deinit(testing.allocator);

    const plaintext = "hello room, this is a megolm test message";
    const ciphertext = try out_session.encrypt(testing.allocator, plaintext);
    defer testing.allocator.free(ciphertext);

    const ciphertext_mut = try testing.allocator.dupe(u8, ciphertext);
    defer testing.allocator.free(ciphertext_mut);
    const decrypted = try in_session.decrypt(testing.allocator, ciphertext_mut);
    defer testing.allocator.free(decrypted.plaintext);
    try testing.expectEqualStrings(plaintext, decrypted.plaintext);
}

test "OutboundGroupSession.pickle/InboundGroupSession.pickle round-trip" {
    var out_session = try OutboundGroupSession.create(testing.allocator, testing.io);
    defer out_session.deinit(testing.allocator);

    const pickled = try out_session.pickle(testing.allocator, "group-pickle-key");
    defer testing.allocator.free(pickled);
    var restored = try OutboundGroupSession.unpickle(testing.allocator, "group-pickle-key", pickled);
    defer restored.deinit(testing.allocator);

    const id1 = try out_session.id(testing.allocator);
    defer testing.allocator.free(id1);
    const id2 = try restored.id(testing.allocator);
    defer testing.allocator.free(id2);
    try testing.expectEqualStrings(id1, id2);
}

test "Sas: both sides derive the same SAS bytes and the same MAC" {
    var alice = try Sas.create(testing.allocator, testing.io);
    defer alice.deinit(testing.allocator);
    var bob = try Sas.create(testing.allocator, testing.io);
    defer bob.deinit(testing.allocator);

    const alice_pubkey = try alice.pubkey(testing.allocator);
    defer testing.allocator.free(alice_pubkey);
    const bob_pubkey = try bob.pubkey(testing.allocator);
    defer testing.allocator.free(bob_pubkey);

    try alice.setTheirKey(testing.allocator, bob_pubkey);
    try bob.setTheirKey(testing.allocator, alice_pubkey);

    // Same info string on both sides (in a real ceremony this is built
    // identically by both parties from the agreed transaction — see
    // `matrix/verification.zig`'s `sasInfo`), same derived bytes.
    const info = "test-sas-info-string";
    const alice_bytes = try alice.generateBytes(testing.allocator, info, 6);
    defer testing.allocator.free(alice_bytes);
    const bob_bytes = try bob.generateBytes(testing.allocator, info, 6);
    defer testing.allocator.free(bob_bytes);
    try testing.expectEqualSlices(u8, alice_bytes, bob_bytes);

    const mac_info = "test-mac-info-string";
    const alice_mac = try alice.calculateMac(testing.allocator, "some-key-to-mac", mac_info);
    defer testing.allocator.free(alice_mac);
    const bob_mac = try bob.calculateMac(testing.allocator, "some-key-to-mac", mac_info);
    defer testing.allocator.free(bob_mac);
    try testing.expectEqualStrings(alice_mac, bob_mac);
}

// Test-only helpers for picking apart libolm's small hand-rolled-shape JSON
// outputs (`{"curve25519": {"AAAAAA": "..."}}` / `{"curve25519": "..."}`) —
// deliberately not a real JSON parser, mirroring `feed_parse.zig`'s
// "good enough for what this needs" philosophy, since production code will
// go through `std.json` against the actual Matrix API response shapes
// instead of libolm's raw output.
fn extractJsonStringField(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "\"{s}\":\"", .{field});
    const start = (std.mem.indexOf(u8, json, needle) orelse return error.FieldNotFound) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return error.FieldNotFound;
    return allocator.dupe(u8, json[start..end]);
}

fn extractFirstCurve25519Value(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const curve_obj_start = (std.mem.indexOf(u8, json, "\"curve25519\":{") orelse return error.FieldNotFound) + "\"curve25519\":{".len;
    // Skip the key id string, land on the value string.
    const key_colon = std.mem.indexOfScalarPos(u8, json, curve_obj_start, ':') orelse return error.FieldNotFound;
    const val_start = std.mem.indexOfScalarPos(u8, json, key_colon, '"').? + 1;
    const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return error.FieldNotFound;
    return allocator.dupe(u8, json[val_start..val_end]);
}
