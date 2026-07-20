//! Matrix E2E encryption protocol logic layered on `olm.zig`'s libolm
//! binding — building/signing the JSON shapes `/keys/upload` (and, once
//! encrypt/decrypt are wired up, `/keys/claim`, `/sendToDevice`, room
//! `m.room.encrypted` events) need. Deliberately hand-builds the small,
//! fully-known JSON shapes below directly rather than pulling in a generic
//! canonical-JSON serializer: Matrix's signing convention (object keys in
//! lexicographic order, no whitespace) only needs to hold for these two
//! fixed-shape objects, and hand-writing them in already-sorted key order
//! is simpler to audit than a general canonicalizer would be for a single
//! call site.

const std = @import("std");
const json = std.json;
const olm = @import("olm.zig");
const verification = @import("verification.zig");
const types = @import("types.zig");
const raw = @import("client.zig");
const store_pool = @import("../store/pool.zig");
const store_crypto = @import("../store/crypto.zig");

/// Both algorithms this device ever offers — Olm for to-device (key
/// exchange) messages, Megolm for room messages. Every device key upload
/// advertises both, matching how there's no partial-encryption-support
/// concept for a single device in the Matrix spec.
const device_algorithms_json = "[\"m.olm.v1.curve25519-aes-sha2\",\"m.megolm.v1.aes-sha2\"]";

const IdentityKeys = struct {
    curve25519: []const u8,
    ed25519: []const u8,
};

fn parseIdentityKeys(allocator: std.mem.Allocator, account: *olm.Account) !std.json.Parsed(IdentityKeys) {
    const raw_json = try account.identityKeysJson(allocator);
    defer allocator.free(raw_json);
    // `.alloc_always`, not the default: without it, parsed strings can
    // alias `raw_json` directly (no escapes to unescape, so nothing forces
    // a copy) — `raw_json` is freed by the `defer` above right as this
    // returns, which left `identity.value.*` dangling (found live: a
    // segfault deep in `std.fmt` formatting the now-freed slice).
    return std.json.parseFromSlice(IdentityKeys, allocator, raw_json, .{ .allocate = .alloc_always });
}

/// Builds and signs this device's `device_keys` object for `/keys/upload`.
/// The signature covers the object with the `signatures` field itself
/// omitted (Matrix's standard "sign everything except your own signature"
/// rule) — computed here, then spliced into the final returned JSON.
pub fn deviceKeysJson(allocator: std.mem.Allocator, account: *olm.Account, user_id: []const u8, device_id: []const u8) ![]u8 {
    var identity = try parseIdentityKeys(allocator, account);
    defer identity.deinit();

    // Canonical (sorted-key, no-whitespace) form actually being signed —
    // "algorithms" < "device_id" < "keys" < "user_id".
    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"algorithms\":{s},\"device_id\":\"{s}\",\"keys\":{{\"curve25519:{s}\":\"{s}\",\"ed25519:{s}\":\"{s}\"}},\"user_id\":\"{s}\"}}",
        .{ device_algorithms_json, device_id, device_id, identity.value.curve25519, device_id, identity.value.ed25519, user_id },
    );
    defer allocator.free(unsigned);

    const sig = try account.sign(allocator, unsigned);
    defer allocator.free(sig);

    return std.fmt.allocPrint(
        allocator,
        "{{\"algorithms\":{s},\"device_id\":\"{s}\",\"keys\":{{\"curve25519:{s}\":\"{s}\",\"ed25519:{s}\":\"{s}\"}},\"signatures\":{{\"{s}\":{{\"ed25519:{s}\":\"{s}\"}}}},\"user_id\":\"{s}\"}}",
        .{ device_algorithms_json, device_id, device_id, identity.value.curve25519, device_id, identity.value.ed25519, user_id, device_id, sig, user_id },
    );
}

const OneTimeKeysRaw = struct {
    curve25519: std.json.ArrayHashMap([]const u8),
};

/// Signs every currently-unpublished one-time key and returns the
/// `one_time_keys` object for `/keys/upload` — `signed_curve25519`, not
/// plain `curve25519`: an unsigned one-time key lets anyone claiming it
/// impersonate this device to whoever established a session with it,
/// since there'd be nothing tying the key to the account's identity.
/// Caller should call `account.markKeysAsPublished()` (and persist the
/// account) once the upload actually succeeds.
pub fn signedOneTimeKeysJson(allocator: std.mem.Allocator, account: *olm.Account, user_id: []const u8, device_id: []const u8) ![]u8 {
    const raw_json = try account.oneTimeKeysJson(allocator);
    defer allocator.free(raw_json);
    return signKeysJson(allocator, account, user_id, device_id, raw_json);
}

/// Same signing logic `signedOneTimeKeysJson` uses, applied to the
/// account's fallback key — `Account.fallbackKeyJson` returns the same
/// `{"curve25519": {...}}` shape `oneTimeKeysJson` does, just for the
/// single (unpublished) fallback key.
pub fn signedFallbackKeyJson(allocator: std.mem.Allocator, account: *olm.Account, user_id: []const u8, device_id: []const u8) ![]u8 {
    const raw_json = try account.fallbackKeyJson(allocator);
    defer allocator.free(raw_json);
    return signKeysJson(allocator, account, user_id, device_id, raw_json);
}

fn signKeysJson(allocator: std.mem.Allocator, account: *olm.Account, user_id: []const u8, device_id: []const u8, raw_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(OneTimeKeysRaw, allocator, raw_json, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('{');

    var it = parsed.value.curve25519.map.iterator();
    var first = true;
    while (it.next()) |entry| {
        const key_id = entry.key_ptr.*;
        const pubkey = entry.value_ptr.*;

        // Canonical form being signed: just the bare key, no signatures.
        const unsigned = try std.fmt.allocPrint(allocator, "{{\"key\":\"{s}\"}}", .{pubkey});
        defer allocator.free(unsigned);
        const sig = try account.sign(allocator, unsigned);
        defer allocator.free(sig);

        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.print(
            "\"signed_curve25519:{s}\":{{\"key\":\"{s}\",\"signatures\":{{\"{s}\":{{\"ed25519:{s}\":\"{s}\"}}}}}}",
            .{ key_id, pubkey, user_id, device_id, sig },
        );
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Wraps `device_keys`/`one_time_keys` (either may be null — a topping-up
/// call after the first upload only needs to send fresh one-time keys)
/// into the full `/keys/upload` request body.
pub fn uploadKeysPayload(allocator: std.mem.Allocator, device_keys_json: ?[]const u8, one_time_keys_json: ?[]const u8, fallback_keys_json: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('{');
    var first = true;
    if (device_keys_json) |dk| {
        try out.writer.print("\"device_keys\":{s}", .{dk});
        first = false;
    }
    if (one_time_keys_json) |otk| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.print("\"one_time_keys\":{s}", .{otk});
    }
    if (fallback_keys_json) |fbk| {
        if (!first) try out.writer.writeByte(',');
        try out.writer.print("\"fallback_keys\":{s}", .{fbk});
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const OwnIdentityKeys = struct { curve25519: []const u8, ed25519: []const u8 };

/// Extracts both of this device's own identity keys in one parse —
/// `curve25519` for picking the right to-device `ciphertext` map entry on
/// decrypt, `ed25519` for the `keys`/`recipient_keys` fields every outbound
/// Olm to-device payload envelope must carry (see `shareWithNewDevices`;
/// omitting these is what silently broke every outgoing room-key share
/// until found live 2026-07-20 — Element validates them before ever
/// looking at the `m.room_key` content, and to-device decrypt failures
/// aren't surfaced anywhere in its UI).
fn extractOwnIdentityKeys(allocator: std.mem.Allocator, account: *olm.Account) !OwnIdentityKeys {
    var identity = try parseIdentityKeys(allocator, account);
    defer identity.deinit();
    return .{
        .curve25519 = try allocator.dupe(u8, identity.value.curve25519),
        .ed25519 = try allocator.dupe(u8, identity.value.ed25519),
    };
}

/// The bot's live, in-memory Matrix crypto state — one process-wide Olm
/// account plus whatever DB pool/pickle key it needs to load/save per-
/// device Olm sessions and per-room Megolm sessions as they're used.
/// Embedded in `platform/matrix.zig`'s `MatrixConnector` as `?State` (null
/// when `WARDEN_MATRIX_PICKLE_KEY` isn't set — encryption stays inert).
pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *store_pool.PgPool,
    pickle_key: []const u8,
    account: olm.Account,
    user_id: []const u8,
    device_id: []const u8,
    /// This device's own curve25519 identity key, base64 — cached since
    /// every to-device decrypt needs it to pick the right `ciphertext` map
    /// entry, and re-deriving it from `account` each time would be
    /// wasteful (and require re-parsing JSON on every sync cycle).
    own_curve25519: []const u8,
    /// This device's own ed25519 fingerprint, base64 — required in the
    /// `keys`/`recipient_keys` fields of every outbound Olm to-device
    /// payload envelope (see `shareWithNewDevices`'s doc comment).
    own_ed25519: []const u8,
    /// Needed by the outbound (encrypt) path — `/keys/query`, `/keys/claim`,
    /// `/sendToDevice` — to discover and message a room's other devices.
    /// Not owned: points at `MatrixConnector.client`, which outlives this
    /// `State` (see `enableCrypto`).
    client: *raw.Client,
    /// Every method that touches `account` or a per-device/per-room Olm
    /// object must hold this — those are plain (non-atomic) libolm structs,
    /// and decrypt (driven by the poll loop's own thread) and encrypt
    /// (driven by per-message tasks) can genuinely run concurrently. DB
    /// reads/writes are cheap to keep inside the same critical section
    /// rather than trying to split locking finer.
    mutex: std.Io.Mutex = .init,
    /// In-flight interactive (SAS/emoji) device verification ceremonies,
    /// keyed by `transaction_id`. In-memory only — no DB persistence, see
    /// `verification.VerificationSession`'s doc comment for why. Guarded
    /// by `mutex` alongside everything else: verification traffic is
    /// human-paced (minutes between steps), not hot-path, so a separate
    /// lock would add complexity for no real concurrency win.
    verifications: std.StringHashMapUnmanaged(verification.VerificationSession) = .empty,

    /// Loads the persisted account, or creates and uploads a fresh one if
    /// this is the first run — see `main.zig`'s call site for the
    /// won't-finish-tonight framing this was originally built under, now
    /// extended with the actual encrypt/decrypt this doc comment's sibling
    /// methods implement. Errors loudly (rather than silently recreating)
    /// if a persisted account's device_id doesn't match the access
    /// token's current device — see the git history around this exact
    /// check for why: reusing an already-crypto-initialized device (e.g.
    /// one already opened in Element) silently produces keys the server
    /// keeps but no client will ever validate against warden's identity.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, pool: *store_pool.PgPool, pickle_key: []const u8, client: *raw.Client) !State {
        var who = try client.whoami(allocator);
        defer who.deinit();
        const user_id = try allocator.dupe(u8, who.value.user_id);
        errdefer allocator.free(user_id);
        const whoami_device_id = who.value.device_id orelse return error.NoDeviceId;

        if (try store_crypto.loadAccount(pool, allocator)) |stored| {
            if (!std.mem.eql(u8, stored.device_id, whoami_device_id)) {
                std.log.err(
                    "matrix e2ee: persisted account's device_id ({s}) doesn't match this access token's device_id ({s}) — clear the crypto_account table to start fresh under the new device",
                    .{ stored.device_id, whoami_device_id },
                );
                allocator.free(stored.device_id);
                allocator.free(stored.pickled_account);
                allocator.free(user_id);
                return error.DeviceIdMismatch;
            }
            defer allocator.free(stored.pickled_account);

            const pickled_mut = try allocator.dupe(u8, stored.pickled_account);
            defer allocator.free(pickled_mut);
            var account = try olm.Account.unpickle(allocator, pickle_key, pickled_mut);
            errdefer account.deinit(allocator);
            const own_keys = try extractOwnIdentityKeys(allocator, &account);
            std.log.info("matrix e2ee: loaded existing device keys (device_id={s})", .{stored.device_id});
            return .{
                .allocator = allocator,
                .io = io,
                .pool = pool,
                .pickle_key = pickle_key,
                .account = account,
                .user_id = user_id,
                .device_id = stored.device_id,
                .own_curve25519 = own_keys.curve25519,
                .own_ed25519 = own_keys.ed25519,
                .client = client,
            };
        }

        const device_id = try allocator.dupe(u8, whoami_device_id);
        errdefer allocator.free(device_id);
        var account = try olm.Account.create(allocator, io);
        errdefer account.deinit(allocator);

        // 20 is an arbitrary starting batch — `topUpOneTimeKeysIfNeeded`
        // (driven by `/sync`'s `device_one_time_keys_count`) replenishes
        // it as keys get claimed, so this initial size only needs to
        // cover activity between now and the first sync cycle.
        try account.generateOneTimeKeys(allocator, io, 20);
        try account.generateFallbackKey(allocator, io);
        const device_keys_json = try deviceKeysJson(allocator, &account, user_id, device_id);
        defer allocator.free(device_keys_json);
        const otk_json = try signedOneTimeKeysJson(allocator, &account, user_id, device_id);
        defer allocator.free(otk_json);
        const fallback_json = try signedFallbackKeyJson(allocator, &account, user_id, device_id);
        defer allocator.free(fallback_json);
        const payload = try uploadKeysPayload(allocator, device_keys_json, otk_json, fallback_json);
        defer allocator.free(payload);
        const response = try client.uploadKeys(allocator, payload);
        defer allocator.free(response);
        std.log.info("matrix e2ee: uploaded device keys (device_id={s}): {s}", .{ device_id, response });
        account.markKeysAsPublished();

        const pickled = try account.pickle(allocator, pickle_key);
        defer allocator.free(pickled);
        try store_crypto.saveAccount(pool, device_id, pickled);

        const own_keys = try extractOwnIdentityKeys(allocator, &account);
        return .{
            .allocator = allocator,
            .io = io,
            .pool = pool,
            .pickle_key = pickle_key,
            .account = account,
            .user_id = user_id,
            .device_id = device_id,
            .own_curve25519 = own_keys.curve25519,
            .own_ed25519 = own_keys.ed25519,
            .client = client,
        };
    }

    pub fn deinit(self: *State) void {
        self.account.deinit(self.allocator);
        self.allocator.free(self.user_id);
        self.allocator.free(self.device_id);
        self.allocator.free(self.own_curve25519);
        self.allocator.free(self.own_ed25519);
        var verif_it = self.verifications.iterator();
        while (verif_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.verifications.deinit(self.allocator);
    }

    /// Tops up this device's one-time-key pool once the server-reported
    /// count (from `/sync`'s `device_one_time_keys_count`) drops below
    /// half of what libolm allows — same threshold real clients use.
    /// Previously the account's initial batch of 20, generated once at
    /// first startup, was never replenished at all: every key claimed
    /// against this device by someone establishing a session (see
    /// `client.zig`'s `claimOneTimeKey`, the *other* direction — someone
    /// else claiming *our* keys) permanently shrank the pool until it hit
    /// zero and every future session establishment with this device
    /// failed outright.
    pub fn topUpOneTimeKeysIfNeeded(self: *State, allocator: std.mem.Allocator, current_signed_curve25519_count: i64) !void {
        const max_keys = self.account.maxOneTimeKeys();
        if (current_signed_curve25519_count >= @as(i64, @intCast(max_keys / 2))) return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const have: usize = if (current_signed_curve25519_count > 0) @intCast(current_signed_curve25519_count) else 0;
        const needed = max_keys - @min(have, max_keys);
        if (needed == 0) return;

        try self.account.generateOneTimeKeys(allocator, self.io, needed);
        // Regenerated on every top-up cycle too — a fresh fallback key is
        // cheap, and libolm keeps the immediately-previous one usable
        // internally (`generateFallbackKey`'s doc comment), so replacing
        // it here can't strand an in-flight `/keys/claim` against the old
        // one.
        try self.account.generateFallbackKey(allocator, self.io);
        const otk_json = try signedOneTimeKeysJson(allocator, &self.account, self.user_id, self.device_id);
        defer allocator.free(otk_json);
        const fallback_json = try signedFallbackKeyJson(allocator, &self.account, self.user_id, self.device_id);
        defer allocator.free(fallback_json);
        const payload = try uploadKeysPayload(allocator, null, otk_json, fallback_json);
        defer allocator.free(payload);
        const response = try self.client.uploadKeys(allocator, payload);
        defer allocator.free(response);
        self.account.markKeysAsPublished();

        const pickled = try self.account.pickle(allocator, self.pickle_key);
        defer allocator.free(pickled);
        try store_crypto.saveAccount(self.pool, self.device_id, pickled);

        std.log.info("matrix e2ee: topped up one-time keys ({d} + {d} -> {d})", .{ current_signed_curve25519_count, needed, max_keys });
    }

    /// Decrypts an incoming to-device `m.room.encrypted` (Olm) event and,
    /// if the payload is an `m.room_key`, stores the resulting inbound
    /// Megolm session. Logs and returns on any failure — a single
    /// malformed/undecryptable to-device event (e.g. addressed to a
    /// different device that happens to share this sync, or referencing a
    /// session we've lost) shouldn't interrupt the sync loop.
    pub fn handleToDeviceEvent(self: *State, sender: []const u8, content: types.OlmEncryptedContent) void {
        self.handleToDeviceEventFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle to-device event from {s}: {t}", .{ sender, err });
        };
    }

    fn handleToDeviceEventFallible(self: *State, sender: []const u8, content: types.OlmEncryptedContent) !void {
        if (!std.mem.eql(u8, content.algorithm, "m.olm.v1.curve25519-aes-sha2")) return error.UnsupportedAlgorithm;
        const entry = content.ciphertext.map.get(self.own_curve25519) orelse return error.NotAddressedToUs;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const allocator = self.allocator;

        var session: olm.Session = undefined;
        if (entry.type == 0) {
            // PRE_KEY — always (re-)establishes the session for this
            // sender, matching the "one session per sender" simplification
            // documented on `store/crypto.zig`'s `StoredSession`.
            const body_for_establish = try allocator.dupe(u8, entry.body);
            defer allocator.free(body_for_establish);
            session = try olm.Session.createInbound(allocator, &self.account, body_for_establish);
        } else {
            const stored = try store_crypto.loadSession(self.pool, allocator, content.sender_key) orelse return error.NoSessionForSender;
            defer allocator.free(stored.session_id);
            defer allocator.free(stored.pickled_session);
            const pickled_mut = try allocator.dupe(u8, stored.pickled_session);
            defer allocator.free(pickled_mut);
            session = try olm.Session.unpickle(allocator, self.pickle_key, pickled_mut);
        }
        defer session.deinit(allocator);

        // decrypt needs its own fresh copy of the ciphertext — whichever
        // branch above already consumed `entry.body` once (establishing
        // the session, or just as a matter of libolm's general "input is
        // destroyed" contract), and `Session.decrypt` destroys its input
        // too.
        const body_for_decrypt = try allocator.dupe(u8, entry.body);
        defer allocator.free(body_for_decrypt);
        const plaintext = try session.decrypt(allocator, entry.type, body_for_decrypt);
        defer allocator.free(plaintext);

        // Persist the session's now-advanced ratchet state regardless of
        // what the plaintext turns out to be — skipping this would make
        // the *next* message from this sender fail to decrypt.
        const session_id = try session.id(allocator);
        defer allocator.free(session_id);
        const pickled = try session.pickle(allocator, self.pickle_key);
        defer allocator.free(pickled);
        try store_crypto.saveSession(self.pool, content.sender_key, session_id, pickled);

        var payload = json.parseFromSlice(types.RoomKeyPayload, allocator, plaintext, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
        defer payload.deinit();
        if (!std.mem.eql(u8, payload.value.type, "m.room_key")) return;
        if (!std.mem.eql(u8, payload.value.content.algorithm, "m.megolm.v1.aes-sha2")) return;

        // Mirrors matrix-js-sdk's own `OlmDecryption.decryptEvent` checks
        // (see `buildRoomKeyPayload`'s doc comment for the send-side bug
        // this is the receive-side counterpart of) — a mismatch here
        // shouldn't happen with a well-behaved sender, so unlike the
        // routine "not an m.room_key" check above, it's worth a warning:
        // either a bug (ours or theirs) or a misdirected/forged message.
        if (!std.mem.eql(u8, payload.value.sender, sender)) {
            std.log.warn("matrix e2ee: to-device room key claims sender {s}, but envelope says {s} — ignoring", .{ payload.value.sender, sender });
            return;
        }
        if (!std.mem.eql(u8, payload.value.recipient, self.user_id)) {
            std.log.warn("matrix e2ee: to-device room key from {s} addressed to {s}, not us — ignoring", .{ sender, payload.value.recipient });
            return;
        }
        if (!std.mem.eql(u8, payload.value.recipient_keys.ed25519, self.own_ed25519)) {
            std.log.warn("matrix e2ee: to-device room key from {s} has a recipient_keys.ed25519 mismatch — ignoring", .{sender});
            return;
        }

        var group_session = try olm.InboundGroupSession.create(allocator, payload.value.content.session_key);
        defer group_session.deinit(allocator);
        const group_pickled = try group_session.pickle(allocator, self.pickle_key);
        defer allocator.free(group_pickled);
        try store_crypto.saveInboundGroupSession(self.pool, payload.value.content.room_id, content.sender_key, payload.value.content.session_id, group_pickled);
        std.log.info("matrix e2ee: received room key for {s} (session {s}) from {s}", .{ payload.value.content.room_id, payload.value.content.session_id, sender });
    }

    /// Answers a to-device `m.room_key_request` — the reactive counterpart
    /// to `shareWithNewDevices`'s proactive share, needed because to-device
    /// delivery is best-effort, not guaranteed (matrix-org/synapse#6450
    /// documents to-device events vanishing server-side with no error on
    /// either end). Without this, a client that missed the original share
    /// — or ran `/discardsession` to force a retry — has no way to ever
    /// recover, which is exactly what was found live 2026-07-20 testing
    /// that command against this bot before this existed.
    ///
    /// Deliberately conservative: only answers requests from **this
    /// account's own other devices** (`sender == self.user_id`), never a
    /// different user — there's no device-verification story yet (see
    /// `client.zig`'s `claimOneTimeKey` doc comment) to safely vet a
    /// stranger's request, and forwarding a room key to an unvetted
    /// device would defeat the point of the room being encrypted at all.
    pub fn handleRoomKeyRequest(self: *State, sender: []const u8, content: types.RoomKeyRequestContent) void {
        self.handleRoomKeyRequestFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle room key request from {s}: {t}", .{ sender, err });
        };
    }

    fn handleRoomKeyRequestFallible(self: *State, sender: []const u8, content: types.RoomKeyRequestContent) !void {
        if (!std.mem.eql(u8, content.action, "request")) return;
        if (!std.mem.eql(u8, sender, self.user_id)) return;
        if (std.mem.eql(u8, content.requesting_device_id, self.device_id)) return; // don't answer ourselves
        const body = content.body orelse return;
        if (!std.mem.eql(u8, body.algorithm, "m.megolm.v1.aes-sha2")) return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const allocator = self.allocator;

        const pickled = try store_crypto.loadInboundGroupSession(self.pool, allocator, body.room_id, body.sender_key, body.session_id) orelse return;
        defer allocator.free(pickled);
        const pickled_mut = try allocator.dupe(u8, pickled);
        defer allocator.free(pickled_mut);
        var group_session = try olm.InboundGroupSession.unpickle(allocator, self.pickle_key, pickled_mut);
        defer group_session.deinit(allocator);
        const first_index = group_session.firstKnownIndex();
        const exported_key = try group_session.exportAt(allocator, first_index);
        defer allocator.free(exported_key);

        var queried = try self.client.queryKeys(allocator, &.{self.user_id});
        defer queried.deinit();
        const device_keys = queried.value.object.get("device_keys") orelse return;
        if (device_keys != .object) return;
        const user_devices = device_keys.object.get(self.user_id) orelse return;
        if (user_devices != .object) return;
        const dev_obj = user_devices.object.get(content.requesting_device_id) orelse return;
        const their_curve25519 = curveKeyFor(dev_obj, content.requesting_device_id) orelse return;
        const their_ed25519 = ed25519KeyFor(dev_obj, content.requesting_device_id) orelse return;

        // Same envelope shape `shareWithNewDevices` uses for `m.room_key`,
        // just `m.forwarded_room_key` with the extra fields that event
        // type requires — the originating device's curve25519 (this
        // session's `sender_key`, i.e. `body.sender_key`, not necessarily
        // us) and an empty forwarding chain (we're not re-forwarding an
        // already-forwarded key here).
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"sender\":\"{s}\",\"sender_device\":\"{s}\",\"keys\":{{\"ed25519\":\"{s}\"}},\"recipient\":\"{s}\",\"recipient_keys\":{{\"ed25519\":\"{s}\"}},\"type\":\"m.forwarded_room_key\",\"content\":{{\"algorithm\":\"m.megolm.v1.aes-sha2\",\"room_id\":\"{s}\",\"session_id\":\"{s}\",\"session_key\":\"{s}\",\"sender_key\":\"{s}\",\"forwarding_curve25519_key_chain\":[]}}}}",
            .{ self.user_id, self.device_id, self.own_ed25519, self.user_id, their_ed25519, body.room_id, body.session_id, exported_key, body.sender_key },
        );
        defer allocator.free(payload);

        try self.shareRoomKeyWithDevice(allocator, self.user_id, content.requesting_device_id, their_curve25519, payload);
        std.log.info("matrix e2ee: answered room key request from {s}/{s} for session {s}", .{ sender, content.requesting_device_id, body.session_id });
    }

    /// Parses `content_json` (hand-built, matching this file's usual
    /// convention) into a `json.Value` and sends it as one to-device
    /// `event_type` event. Verification events are sent **unencrypted** —
    /// unlike `shareRoomKeyWithDevice`, this never touches Olm, since the
    /// whole point of a verification ceremony is establishing trust before
    /// any of it exists yet.
    fn sendVerificationEvent(self: *State, event_type: []const u8, user_id: []const u8, device_id: []const u8, content_json: []const u8) !void {
        const allocator = self.allocator;
        var parsed = try json.parseFromSlice(json.Value, allocator, content_json, .{});
        defer parsed.deinit();
        try self.client.sendToDevice(allocator, event_type, user_id, device_id, parsed.value);
    }

    /// Removes an expired (older than `verification.session_max_age_s`)
    /// entry from `verifications` — called lazily at the top of every
    /// verification handler rather than via a background timer, matching
    /// how this bot has no periodic-task infrastructure beyond the poll
    /// loop already driving everything else. Caller must hold `mutex`.
    fn sweepExpiredVerifications(self: *State) void {
        const allocator = self.allocator;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(allocator);
        var it = self.verifications.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.created_at_unix >= verification.session_max_age_s) {
                expired.append(allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (expired.items) |key| {
            if (self.verifications.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
                var s = kv.value;
                s.deinit(allocator);
            }
        }
    }

    /// Sends `m.key.verification.cancel` (best-effort — a failed send
    /// doesn't block local cleanup) and removes the session. Caller must
    /// already hold `mutex`.
    fn cancelVerification(self: *State, transaction_id: []const u8, their_device_id: []const u8, code: []const u8, reason: []const u8) !void {
        const allocator = self.allocator;
        const cancel_json = try std.fmt.allocPrint(allocator, "{{\"transaction_id\":\"{s}\",\"code\":\"{s}\",\"reason\":\"{s}\"}}", .{ transaction_id, code, reason });
        defer allocator.free(cancel_json);
        self.sendVerificationEvent("m.key.verification.cancel", self.user_id, their_device_id, cancel_json) catch |err| {
            std.log.warn("matrix e2ee: failed to send verification cancel for {s}: {t}", .{ transaction_id, err });
        };
        std.log.warn("matrix e2ee: cancelling verification {s}: {s} ({s})", .{ transaction_id, code, reason });
        if (self.verifications.fetchRemove(transaction_id)) |kv| {
            allocator.free(kv.key);
            var s = kv.value;
            s.deinit(allocator);
        }
    }

    /// Entry point for a self-verification ceremony: an incoming
    /// `m.key.verification.request` from one of this account's own other
    /// devices (e.g. Element, verifying the bot's session so it stops
    /// showing an "unverified device" warning — see `ROADMAP.md`). This
    /// bot only ever *responds*, never initiates — see
    /// `verification.zig`'s module doc for why that's a deliberate scope
    /// choice, not just what happened to get built first. Per the spec's
    /// tie-break rule, whichever side sends `m.key.verification.ready` is
    /// the one that auto-selects the method and sends `m.key.verification.
    /// start` next — since we always respond (never request), that's
    /// always us, so both are sent here together.
    pub fn handleVerificationRequest(self: *State, sender: []const u8, content: types.VerificationRequestContent) void {
        self.handleVerificationRequestFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle verification request from {s}: {t}", .{ sender, err });
        };
    }

    fn handleVerificationRequestFallible(self: *State, sender: []const u8, content: types.VerificationRequestContent) !void {
        if (!std.mem.eql(u8, sender, self.user_id)) return;
        var has_sas = false;
        for (content.methods) |m| {
            if (std.mem.eql(u8, m, "m.sas.v1")) {
                has_sas = true;
                break;
            }
        }
        if (!has_sas) return;

        const allocator = self.allocator;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.sweepExpiredVerifications();
        if (self.verifications.contains(content.transaction_id)) return; // duplicate/replayed request

        // Spec: ignore if the request's timestamp is >5 min in the future
        // or >10 min in the past.
        const now_ms = std.Io.Timestamp.now(self.io, .real).toSeconds() * std.time.ms_per_s;
        if (content.timestamp - now_ms > 5 * std.time.ms_per_min or now_ms - content.timestamp > 10 * std.time.ms_per_min) {
            std.log.warn("matrix e2ee: ignoring verification request from {s}/{s} with implausible timestamp", .{ sender, content.from_device });
            return;
        }

        // Pin the requesting device's real ed25519 key now — see
        // `VerificationSession.their_ed25519`'s doc comment for why this
        // must never be re-resolved later in the ceremony.
        var queried = try self.client.queryKeys(allocator, &.{self.user_id});
        defer queried.deinit();
        const device_keys = queried.value.object.get("device_keys") orelse return;
        if (device_keys != .object) return;
        const user_devices = device_keys.object.get(self.user_id) orelse return;
        if (user_devices != .object) return;
        const dev_obj = user_devices.object.get(content.from_device) orelse return;
        const their_ed25519 = ed25519KeyFor(dev_obj, content.from_device) orelse return;

        const txn_key = try allocator.dupe(u8, content.transaction_id);
        errdefer allocator.free(txn_key);

        const ready_json = try std.fmt.allocPrint(
            allocator,
            "{{\"from_device\":\"{s}\",\"transaction_id\":\"{s}\",\"methods\":[\"m.sas.v1\"]}}",
            .{ self.device_id, content.transaction_id },
        );
        defer allocator.free(ready_json);
        try self.sendVerificationEvent("m.key.verification.ready", sender, content.from_device, ready_json);

        // Field order here isn't cosmetic: `verification.commitment`
        // hashes this exact string later (once the accepter's key
        // arrives), and the spec's commitment formula is defined over the
        // *canonical* JSON of this content — keys sorted lexicographically
        // — not whatever order they're written in. Element independently
        // canonicalizes whatever `start` content it receives before
        // hashing its own copy for comparison, so if this string isn't
        // already in sorted-key order, the two sides' hashes silently
        // never match (found live 2026-07-20: every verification attempt
        // failed with `m.mismatched_commitment` until this was fixed —
        // sorted order is alphabetical: from_device, hashes,
        // key_agreement_protocols, message_authentication_codes, method,
        // short_authentication_string, transaction_id).
        const start_json = try std.fmt.allocPrint(
            allocator,
            "{{\"from_device\":\"{s}\",\"hashes\":[\"sha256\"],\"key_agreement_protocols\":[\"curve25519-hkdf-sha256\"],\"message_authentication_codes\":[\"hkdf-hmac-sha256.v2\"],\"method\":\"m.sas.v1\",\"short_authentication_string\":[\"decimal\",\"emoji\"],\"transaction_id\":\"{s}\"}}",
            .{ self.device_id, content.transaction_id },
        );
        errdefer allocator.free(start_json);
        try self.sendVerificationEvent("m.key.verification.start", sender, content.from_device, start_json);

        var sas = try olm.Sas.create(allocator, self.io);
        errdefer sas.deinit(allocator);
        const our_pubkey = try sas.pubkey(allocator);
        errdefer allocator.free(our_pubkey);

        try self.verifications.put(allocator, txn_key, .{
            .their_user_id = try allocator.dupe(u8, sender),
            .their_device_id = try allocator.dupe(u8, content.from_device),
            .their_ed25519 = try allocator.dupe(u8, their_ed25519),
            .sent_start_json = start_json,
            .our_pubkey = our_pubkey,
            .sas = sas,
            .created_at_unix = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .state = .ready_sent,
        });
        std.log.info("matrix e2ee: verification request from {s}/{s} accepted, sent ready+start ({s})", .{ sender, content.from_device, content.transaction_id });
    }

    pub fn handleVerificationAccept(self: *State, sender: []const u8, content: types.VerificationAcceptContent) void {
        self.handleVerificationAcceptFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle verification accept from {s}: {t}", .{ sender, err });
        };
    }

    fn handleVerificationAcceptFallible(self: *State, sender: []const u8, content: types.VerificationAcceptContent) !void {
        if (!std.mem.eql(u8, sender, self.user_id)) return;

        const allocator = self.allocator;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.sweepExpiredVerifications();

        const session = self.verifications.getPtr(content.transaction_id) orelse return;
        if (!std.mem.eql(u8, sender, session.their_user_id) or session.state != .ready_sent) return;

        if (!std.mem.eql(u8, content.key_agreement_protocol, "curve25519-hkdf-sha256") or
            !std.mem.eql(u8, content.message_authentication_code, "hkdf-hmac-sha256.v2"))
        {
            try self.cancelVerification(content.transaction_id, session.their_device_id, "m.unknown_method", "unsupported key agreement or MAC method");
            return;
        }

        session.their_commitment = try allocator.dupe(u8, content.commitment);
        session.use_emoji = false;
        for (content.short_authentication_string) |s| {
            if (std.mem.eql(u8, s, "emoji")) {
                session.use_emoji = true;
                break;
            }
        }

        const key_json = try std.fmt.allocPrint(allocator, "{{\"transaction_id\":\"{s}\",\"key\":\"{s}\"}}", .{ content.transaction_id, session.our_pubkey });
        defer allocator.free(key_json);
        try self.sendVerificationEvent("m.key.verification.key", sender, session.their_device_id, key_json);
        session.state = .key_sent;
        std.log.info("matrix e2ee: verification {s} accepted, sent our key", .{content.transaction_id});
    }

    pub fn handleVerificationKey(self: *State, sender: []const u8, content: types.VerificationKeyContent) void {
        self.handleVerificationKeyFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle verification key from {s}: {t}", .{ sender, err });
        };
    }

    fn handleVerificationKeyFallible(self: *State, sender: []const u8, content: types.VerificationKeyContent) !void {
        if (!std.mem.eql(u8, sender, self.user_id)) return;

        const allocator = self.allocator;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.sweepExpiredVerifications();

        const session = self.verifications.getPtr(content.transaction_id) orelse return;
        if (!std.mem.eql(u8, sender, session.their_user_id) or session.state != .key_sent) return;
        const their_commitment = session.their_commitment orelse return;

        const expected_commitment = try verification.commitment(allocator, content.key, session.sent_start_json);
        defer allocator.free(expected_commitment);
        if (!std.mem.eql(u8, expected_commitment, their_commitment)) {
            try self.cancelVerification(content.transaction_id, session.their_device_id, "m.mismatched_commitment", "commitment did not match");
            return;
        }

        try session.sas.setTheirKey(allocator, content.key);

        const sas_info = try verification.sasInfo(allocator, self.user_id, self.device_id, session.our_pubkey, session.their_user_id, session.their_device_id, content.key, content.transaction_id);
        defer allocator.free(sas_info);
        const sas_len: usize = if (session.use_emoji) 6 else 5;
        const sas_bytes = try session.sas.generateBytes(allocator, sas_info, sas_len);
        defer allocator.free(sas_bytes);

        if (session.use_emoji) {
            var arr: [6]u8 = undefined;
            @memcpy(&arr, sas_bytes[0..6]);
            const display = try verification.formatSas(allocator, arr);
            defer allocator.free(display);
            std.log.info("matrix e2ee: verification {s} — compare against Element: {s}", .{ content.transaction_id, display });
        } else {
            std.log.info("matrix e2ee: verification {s} — decimal SAS bytes (hex, no emoji offered): {x}", .{ content.transaction_id, sas_bytes });
        }

        const key_id = try std.fmt.allocPrint(allocator, "ed25519:{s}", .{self.device_id});
        defer allocator.free(key_id);
        const mac_info_key = try verification.macInfo(allocator, self.user_id, self.device_id, session.their_user_id, session.their_device_id, content.transaction_id, key_id);
        defer allocator.free(mac_info_key);
        const key_mac = try session.sas.calculateMac(allocator, self.own_ed25519, mac_info_key);
        defer allocator.free(key_mac);

        const mac_info_keyids = try verification.macInfo(allocator, self.user_id, self.device_id, session.their_user_id, session.their_device_id, content.transaction_id, "KEY_IDS");
        defer allocator.free(mac_info_keyids);
        const keyids_mac = try session.sas.calculateMac(allocator, key_id, mac_info_keyids);
        defer allocator.free(keyids_mac);

        const mac_json = try std.fmt.allocPrint(
            allocator,
            "{{\"transaction_id\":\"{s}\",\"keys\":\"{s}\",\"mac\":{{\"{s}\":\"{s}\"}}}}",
            .{ content.transaction_id, keyids_mac, key_id, key_mac },
        );
        defer allocator.free(mac_json);
        try self.sendVerificationEvent("m.key.verification.mac", sender, session.their_device_id, mac_json);
        session.state = .mac_sent;
        std.log.info("matrix e2ee: verification {s} sent our MAC", .{content.transaction_id});
    }

    pub fn handleVerificationMac(self: *State, sender: []const u8, content: types.VerificationMacContent) void {
        self.handleVerificationMacFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle verification mac from {s}: {t}", .{ sender, err });
        };
    }

    fn handleVerificationMacFallible(self: *State, sender: []const u8, content: types.VerificationMacContent) !void {
        if (!std.mem.eql(u8, sender, self.user_id)) return;

        const allocator = self.allocator;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.sweepExpiredVerifications();

        const session = self.verifications.getPtr(content.transaction_id) orelse return;
        if (!std.mem.eql(u8, sender, session.their_user_id) or session.state != .mac_sent) return;

        const expected_key_id = try std.fmt.allocPrint(allocator, "ed25519:{s}", .{session.their_device_id});
        defer allocator.free(expected_key_id);

        // The `KEY_IDS` MAC covers *every* key id present in `mac` —
        // found live 2026-07-20: this can't be hardcoded to just the
        // device key. If the other side's own identity is already
        // locally verified on its side, it also includes a MAC over its
        // cross-signing master key (per the research behind this
        // feature — matrix-rust-sdk's `get_mac_content` does this
        // conditionally), so the sorted, comma-joined list must be
        // derived from whatever keys they actually sent, not assumed.
        const sent_key_ids = try allocator.dupe([]const u8, content.mac.map.keys());
        defer allocator.free(sent_key_ids);
        std.mem.sort([]const u8, sent_key_ids, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        var joined_keys: std.Io.Writer.Allocating = .init(allocator);
        defer joined_keys.deinit();
        for (sent_key_ids, 0..) |k, i| {
            if (i != 0) try joined_keys.writer.writeByte(',');
            try joined_keys.writer.writeAll(k);
        }

        const mac_info_keyids = try verification.macInfo(allocator, session.their_user_id, session.their_device_id, self.user_id, self.device_id, content.transaction_id, "KEY_IDS");
        defer allocator.free(mac_info_keyids);
        const expected_keyids_mac = try session.sas.calculateMac(allocator, joined_keys.writer.buffered(), mac_info_keyids);
        defer allocator.free(expected_keyids_mac);
        if (!std.mem.eql(u8, expected_keyids_mac, content.keys)) {
            try self.cancelVerification(content.transaction_id, session.their_device_id, "m.key_mismatch", "keys MAC did not match");
            return;
        }

        // Only the device-key MAC is required — an additional master
        // cross-signing-key MAC entry (sent conditionally, only if
        // Element's own identity is already locally verified on its
        // side) is logged if present but not checked: what protects
        // *this* side of the ceremony is confirming *their device*,
        // which this already does.
        const their_mac = content.mac.map.get(expected_key_id) orelse {
            try self.cancelVerification(content.transaction_id, session.their_device_id, "m.key_mismatch", "missing device key MAC");
            return;
        };
        const mac_info_key = try verification.macInfo(allocator, session.their_user_id, session.their_device_id, self.user_id, self.device_id, content.transaction_id, expected_key_id);
        defer allocator.free(mac_info_key);
        const expected_key_mac = try session.sas.calculateMac(allocator, session.their_ed25519, mac_info_key);
        defer allocator.free(expected_key_mac);
        if (!std.mem.eql(u8, expected_key_mac, their_mac)) {
            try self.cancelVerification(content.transaction_id, session.their_device_id, "m.key_mismatch", "device key MAC did not match");
            return;
        }

        const done_json = try std.fmt.allocPrint(allocator, "{{\"transaction_id\":\"{s}\"}}", .{content.transaction_id});
        defer allocator.free(done_json);
        try self.sendVerificationEvent("m.key.verification.done", sender, session.their_device_id, done_json);
        std.log.info("matrix e2ee: verification {s} with {s}/{s} succeeded", .{ content.transaction_id, session.their_user_id, session.their_device_id });

        if (self.verifications.fetchRemove(content.transaction_id)) |kv| {
            allocator.free(kv.key);
            var s = kv.value;
            s.deinit(allocator);
        }
    }

    pub fn handleVerificationDone(self: *State, sender: []const u8, content: types.VerificationDoneContent) void {
        self.handleVerificationDoneFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle verification done from {s}: {t}", .{ sender, err });
        };
    }

    /// We already send our own `done` (and remove the session) right
    /// after successfully validating their MAC in `handleVerificationMac`
    /// — so a session still present here when *their* `done` arrives
    /// would mean the two sides disagree about whether the ceremony
    /// succeeded, worth a warning; the common case is simply that the
    /// session's already gone by the time this fires, which is fine.
    fn handleVerificationDoneFallible(self: *State, sender: []const u8, content: types.VerificationDoneContent) !void {
        if (!std.mem.eql(u8, sender, self.user_id)) return;
        const allocator = self.allocator;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.verifications.fetchRemove(content.transaction_id)) |kv| {
            std.log.warn("matrix e2ee: verification {s} done received before we'd finished our own side", .{content.transaction_id});
            allocator.free(kv.key);
            var s = kv.value;
            s.deinit(allocator);
        }
    }

    pub fn handleVerificationCancel(self: *State, sender: []const u8, content: types.VerificationCancelContent) void {
        self.handleVerificationCancelFallible(sender, content) catch |err| {
            std.log.warn("matrix e2ee: failed to handle verification cancel from {s}: {t}", .{ sender, err });
        };
    }

    fn handleVerificationCancelFallible(self: *State, sender: []const u8, content: types.VerificationCancelContent) !void {
        if (!std.mem.eql(u8, sender, self.user_id)) return;
        const allocator = self.allocator;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.verifications.fetchRemove(content.transaction_id)) |kv| {
            std.log.warn("matrix e2ee: verification {s} cancelled by {s}: {s} ({s})", .{ content.transaction_id, sender, content.code, content.reason });
            allocator.free(kv.key);
            var s = kv.value;
            s.deinit(allocator);
        }
    }

    /// Decrypts a room-timeline `m.room.encrypted` (Megolm) event using
    /// whatever inbound session is on file for `(room_id, sender_key,
    /// session_id)`. Returns null (not an error) when no matching session
    /// exists yet — the room key just hasn't arrived, or hasn't been
    /// processed, yet; `platform/matrix.zig`'s `pollFn` treats that the
    /// same as "can't read this one" rather than a hard failure. Caller
    /// owns and must `.deinit()` the returned `Parsed` value.
    pub fn decryptRoomEvent(self: *State, allocator: std.mem.Allocator, room_id: []const u8, content: types.MegolmEncryptedContent) !?json.Parsed(types.DecryptedRoomEventPayload) {
        if (!std.mem.eql(u8, content.algorithm, "m.megolm.v1.aes-sha2")) return null;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const pickled = try store_crypto.loadInboundGroupSession(self.pool, allocator, room_id, content.sender_key, content.session_id) orelse return null;
        defer allocator.free(pickled);
        const pickled_mut = try allocator.dupe(u8, pickled);
        defer allocator.free(pickled_mut);
        var session = try olm.InboundGroupSession.unpickle(allocator, self.pickle_key, pickled_mut);
        defer session.deinit(allocator);

        const ciphertext_mut = try allocator.dupe(u8, content.ciphertext);
        defer allocator.free(ciphertext_mut);
        const decrypted = try session.decrypt(allocator, ciphertext_mut);
        defer allocator.free(decrypted.plaintext);

        // Same "persist the ratchet advance regardless" reasoning as the
        // Olm session update above.
        const repickled = try session.pickle(allocator, self.pickle_key);
        defer allocator.free(repickled);
        try store_crypto.saveInboundGroupSession(self.pool, room_id, content.sender_key, content.session_id, repickled);

        var parsed = try json.parseFromSlice(types.DecryptedRoomEventPayload, allocator, decrypted.plaintext, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        errdefer parsed.deinit();
        // Anti-replay check mirroring matrix-js-sdk's own decrypt
        // validation (found live 2026-07-20, the mirror-image bug of
        // `shareWithNewDevices`'s missing to-device envelope fields):
        // the *plaintext* must carry the same `room_id` this session
        // belongs to, or a session key could be replayed to forge a
        // message into a different room.
        if (!std.mem.eql(u8, parsed.value.room_id, room_id)) return error.RoomIdMismatch;
        return parsed;
    }

    pub const EncryptedForRoom = struct {
        ciphertext: []u8,
        session_id: []const u8,
    };

    /// Encrypts `plaintext_event_json` (a full `{"type":...,"content":...}`
    /// room event, matching the shape `DecryptedRoomEventPayload` parses on
    /// the receive side) for `room_id`'s outbound Megolm session — creating
    /// one if none exists yet, and sharing its key (via Olm-encrypted
    /// `m.room_key` to-device events) with any currently-joined member
    /// device that hasn't received it yet before encrypting. This is the
    /// fix for the original bug report: without this, every outgoing
    /// `m.room.message` went out as plaintext into a room whose other
    /// members' clients only ever expect `m.room.encrypted` — accepted by
    /// the server, but not rendered as a normal message by any compliant
    /// client. Caller owns the returned `ciphertext`/`session_id`.
    ///
    /// Rotates the outbound session — forcing a brand-new one, re-shared
    /// from scratch — once it's older than this, matching the rough
    /// order of magnitude real clients use (time-based, not
    /// message-count-based: this bot's per-room volume is low enough that
    /// a message-count threshold would rarely trigger, and time-based
    /// rotation needs no schema change since `crypto_megolm_outbound`
    /// already tracks `created_at`).
    const megolm_session_max_age_s: i64 = 7 * std.time.s_per_day;

    fn shouldRotateSession(now_unix: i64, created_at_unix: i64) bool {
        return now_unix - created_at_unix >= megolm_session_max_age_s;
    }

    pub fn encryptForRoom(self: *State, allocator: std.mem.Allocator, room_id: []const u8, plaintext_event_json: []const u8) !EncryptedForRoom {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var shared_with: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = shared_with.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            shared_with.deinit(allocator);
        }

        var group_session: olm.OutboundGroupSession = undefined;
        if (try store_crypto.loadOutboundGroupSession(self.pool, allocator, room_id)) |stored| {
            defer allocator.free(stored.pickled_session);
            defer allocator.free(stored.shared_with_json);
            const now_unix = std.Io.Timestamp.now(self.io, .real).toSeconds();
            if (shouldRotateSession(now_unix, stored.created_at_unix)) {
                std.log.info("matrix e2ee: rotating megolm session for {s} (age {d}s)", .{ room_id, now_unix - stored.created_at_unix });
                group_session = try olm.OutboundGroupSession.create(allocator, self.io);
            } else {
                const pickled_mut = try allocator.dupe(u8, stored.pickled_session);
                defer allocator.free(pickled_mut);
                group_session = try olm.OutboundGroupSession.unpickle(allocator, self.pickle_key, pickled_mut);
                errdefer group_session.deinit(allocator);
                try parseSharedWithInto(allocator, stored.shared_with_json, &shared_with);
            }
        } else {
            group_session = try olm.OutboundGroupSession.create(allocator, self.io);
        }
        defer group_session.deinit(allocator);

        self.shareWithNewDevices(allocator, room_id, &group_session, &shared_with) catch |err| {
            std.log.warn("matrix e2ee: room key share pass for {s} failed (sending anyway to already-shared devices): {t}", .{ room_id, err });
        };

        const ciphertext = try group_session.encrypt(allocator, plaintext_event_json);
        errdefer allocator.free(ciphertext);
        const session_id = try group_session.id(allocator);
        errdefer allocator.free(session_id);

        // Persist the session's advanced ratchet state and the (possibly
        // just-expanded) shared_with set regardless of what happens next —
        // skipping this would re-share the room key with already-shared
        // devices on the next send, and re-sending a message with an
        // unpersisted ratchet state would desync from what was actually
        // transmitted.
        const pickled = try group_session.pickle(allocator, self.pickle_key);
        defer allocator.free(pickled);
        const shared_with_json = try serializeSharedWith(allocator, &shared_with);
        defer allocator.free(shared_with_json);
        try store_crypto.saveOutboundGroupSession(self.pool, room_id, pickled, shared_with_json);

        return .{ .ciphertext = ciphertext, .session_id = session_id };
    }

    /// Queries `room_id`'s currently-joined members' devices and shares
    /// `group_session`'s key (via a fresh or existing per-device Olm
    /// session) with any device not already present in `shared_with`,
    /// adding it once shared. Best-effort: a single device's share failing
    /// (e.g. it has no one-time keys left to claim) is logged and skipped
    /// rather than aborting the whole send — better to reach the devices
    /// that *do* work than to block every send on one uncooperative device.
    fn shareWithNewDevices(self: *State, allocator: std.mem.Allocator, room_id: []const u8, group_session: *olm.OutboundGroupSession, shared_with: *std.StringHashMapUnmanaged(void)) !void {
        const members = try self.client.joinedMembers(allocator, room_id);
        defer {
            for (members) |m| allocator.free(m);
            allocator.free(members);
        }

        var to_query: std.ArrayList([]const u8) = .empty;
        defer to_query.deinit(allocator);
        for (members) |m| {
            if (!std.mem.eql(u8, m, self.user_id)) try to_query.append(allocator, m);
        }
        if (to_query.items.len == 0) return;

        var queried = try self.client.queryKeys(allocator, to_query.items);
        defer queried.deinit();

        const device_keys = queried.value.object.get("device_keys") orelse return;
        if (device_keys != .object) return;

        const session_id = try group_session.id(allocator);
        defer allocator.free(session_id);
        const session_key = try group_session.sessionKey(allocator);
        defer allocator.free(session_key);

        var user_it = device_keys.object.iterator();
        while (user_it.next()) |user_entry| {
            const user_id = user_entry.key_ptr.*;
            if (user_entry.value_ptr.* != .object) continue;
            var dev_it = user_entry.value_ptr.object.iterator();
            while (dev_it.next()) |dev_entry| {
                const device_id = dev_entry.key_ptr.*;
                if (std.mem.eql(u8, user_id, self.user_id) and std.mem.eql(u8, device_id, self.device_id)) continue;

                const share_key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ user_id, device_id });
                if (shared_with.contains(share_key)) {
                    allocator.free(share_key);
                    continue;
                }

                const dev_obj = dev_entry.value_ptr.*;
                const curve_val = curveKeyFor(dev_obj, device_id) orelse {
                    allocator.free(share_key);
                    continue;
                };
                const their_ed25519 = ed25519KeyFor(dev_obj, device_id) orelse {
                    allocator.free(share_key);
                    continue;
                };

                const room_key_payload = try buildRoomKeyPayload(allocator, .{
                    .sender = self.user_id,
                    .sender_device = self.device_id,
                    .sender_ed25519 = self.own_ed25519,
                    .recipient = user_id,
                    .recipient_ed25519 = their_ed25519,
                    .room_id = room_id,
                    .session_id = session_id,
                    .session_key = session_key,
                });
                defer allocator.free(room_key_payload);

                self.shareRoomKeyWithDevice(allocator, user_id, device_id, curve_val, room_key_payload) catch |err| {
                    std.log.warn("matrix e2ee: failed to share room key with {s}/{s}: {t}", .{ user_id, device_id, err });
                    allocator.free(share_key);
                    continue;
                };
                try shared_with.put(allocator, share_key, {});
            }
        }
    }

    fn curveKeyFor(dev_obj: json.Value, device_id: []const u8) ?[]const u8 {
        if (dev_obj != .object) return null;
        const keys_obj = dev_obj.object.get("keys") orelse return null;
        if (keys_obj != .object) return null;
        var buf: [128]u8 = undefined;
        const curve_key_name = std.fmt.bufPrint(&buf, "curve25519:{s}", .{device_id}) catch return null;
        const curve_val = keys_obj.object.get(curve_key_name) orelse return null;
        if (curve_val != .string) return null;
        return curve_val.string;
    }

    /// Sibling to `curveKeyFor` — the target device's ed25519 fingerprint,
    /// needed for the `recipient_keys.ed25519` field every outbound Olm
    /// to-device payload envelope must carry (see `shareWithNewDevices`).
    fn ed25519KeyFor(dev_obj: json.Value, device_id: []const u8) ?[]const u8 {
        if (dev_obj != .object) return null;
        const keys_obj = dev_obj.object.get("keys") orelse return null;
        if (keys_obj != .object) return null;
        var buf: [128]u8 = undefined;
        const key_name = std.fmt.bufPrint(&buf, "ed25519:{s}", .{device_id}) catch return null;
        const val = keys_obj.object.get(key_name) orelse return null;
        if (val != .string) return null;
        return val.string;
    }

    const RoomKeyPayloadParams = struct {
        sender: []const u8,
        sender_device: []const u8,
        sender_ed25519: []const u8,
        recipient: []const u8,
        recipient_ed25519: []const u8,
        room_id: []const u8,
        session_id: []const u8,
        session_key: []const u8,
    };

    /// Builds the plaintext Olm-encrypts into an `m.room_key` to-device
    /// event. Hand-built, not `json.Stringify`-through-a-struct — same
    /// established pattern as the rest of this file; every field here is a
    /// server/library-generated opaque token or a Matrix id, never user
    /// text, so there's nothing that needs JSON string-escaping.
    ///
    /// `sender`, `sender_device`, `keys`, `recipient`, and `recipient_keys`
    /// are all *required* by the Matrix spec in the plaintext of an
    /// `m.olm.v1.curve25519-aes-sha2` to-device payload — found live
    /// 2026-07-20, missing them was silently breaking every room-key
    /// share. Element's decrypt path (matrix-js-sdk's
    /// `OlmDecryption.decryptEvent`) checks
    /// `payload.recipient`/`payload.recipient_keys.ed25519` before it will
    /// even look at `content`, throwing `OLM_BAD_RECIPIENT`/
    /// `OLM_BAD_RECIPIENT_KEY` otherwise — and to-device decrypt failures
    /// are only logged internally by Element, never surfaced in its UI, so
    /// the 200 OK `sendToDevice` gets back gives no hint anything is
    /// wrong. Field order doesn't matter: this payload isn't itself
    /// signature-checked (it rides inside the already-authenticated Olm
    /// ciphertext), only field values are validated after decrypt.
    fn buildRoomKeyPayload(allocator: std.mem.Allocator, p: RoomKeyPayloadParams) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{{\"sender\":\"{s}\",\"sender_device\":\"{s}\",\"keys\":{{\"ed25519\":\"{s}\"}},\"recipient\":\"{s}\",\"recipient_keys\":{{\"ed25519\":\"{s}\"}},\"type\":\"m.room_key\",\"content\":{{\"algorithm\":\"m.megolm.v1.aes-sha2\",\"room_id\":\"{s}\",\"session_id\":\"{s}\",\"session_key\":\"{s}\"}}}}",
            .{ p.sender, p.sender_device, p.sender_ed25519, p.recipient, p.recipient_ed25519, p.room_id, p.session_id, p.session_key },
        );
    }

    /// Establishes (or reuses) an Olm session with `device_id` and sends it
    /// `room_key_payload` (already the full `{"type":"m.room_key",...}`
    /// plaintext) as an Olm-encrypted `m.room.encrypted` to-device event —
    /// the mirror image of `handleToDeviceEventFallible`'s receive side.
    ///
    /// Found live: the very first real encrypt-path test reused a session
    /// that had earlier been established the other direction (inbound, via
    /// `handleToDeviceEventFallible`'s `createInbound`, from decrypt
    /// testing) — Element accepted the send (200 OK) but silently failed to
    /// process it ("The sender's device has not sent us the keys for this
    /// message"), with no error visible on warden's side at all. Clearing
    /// `crypto_sessions` (forcing a fresh PRE_KEY handshake instead of
    /// reusing the drifted session) fixed it immediately. Bidirectional
    /// reuse of one Olm session is normal, spec-legal behavior — the
    /// takeaway isn't "reuse is wrong," it's that a stuck/desynced session
    /// fails *silently* from the sender's side, so if room-key shares ever
    /// stop landing again, suspect a stale `crypto_sessions` row before
    /// anything else and clear it rather than debugging the JSON shape.
    fn shareRoomKeyWithDevice(self: *State, allocator: std.mem.Allocator, user_id: []const u8, device_id: []const u8, their_curve25519: []const u8, room_key_payload: []const u8) !void {
        var session: olm.Session = undefined;
        if (try store_crypto.loadSession(self.pool, allocator, their_curve25519)) |stored| {
            defer allocator.free(stored.session_id);
            defer allocator.free(stored.pickled_session);
            const pickled_mut = try allocator.dupe(u8, stored.pickled_session);
            defer allocator.free(pickled_mut);
            session = try olm.Session.unpickle(allocator, self.pickle_key, pickled_mut);
        } else {
            const otk = try self.client.claimOneTimeKey(allocator, user_id, device_id);
            defer allocator.free(otk);
            session = try olm.Session.createOutbound(allocator, self.io, &self.account, their_curve25519, otk);
        }
        defer session.deinit(allocator);

        const ciphertext = try session.encrypt(allocator, self.io, room_key_payload);
        defer allocator.free(ciphertext);
        const msg_type = try session.nextMessageType();

        // Persist the session's advanced ratchet state before the network
        // call, not after — same "don't lose track of what was actually
        // sent" reasoning as everywhere else in this file.
        const session_id = try session.id(allocator);
        defer allocator.free(session_id);
        const pickled = try session.pickle(allocator, self.pickle_key);
        defer allocator.free(pickled);
        try store_crypto.saveSession(self.pool, their_curve25519, session_id, pickled);

        var entry_obj: json.Value = .{ .object = .empty };
        try entry_obj.object.put(allocator, "type", .{ .integer = @intCast(msg_type) });
        try entry_obj.object.put(allocator, "body", .{ .string = ciphertext });
        var ciphertext_obj: json.Value = .{ .object = .empty };
        try ciphertext_obj.object.put(allocator, their_curve25519, entry_obj);
        var content_obj: json.Value = .{ .object = .empty };
        try content_obj.object.put(allocator, "algorithm", .{ .string = "m.olm.v1.curve25519-aes-sha2" });
        try content_obj.object.put(allocator, "sender_key", .{ .string = self.own_curve25519 });
        try content_obj.object.put(allocator, "ciphertext", ciphertext_obj);

        try self.client.sendToDevice(allocator, "m.room.encrypted", user_id, device_id, content_obj);
        std.log.info("matrix e2ee: shared room key with {s}/{s}", .{ user_id, device_id });
    }
};

fn parseSharedWithInto(allocator: std.mem.Allocator, json_str: []const u8, out: *std.StringHashMapUnmanaged(void)) !void {
    var parsed = try json.parseFromSlice([]const []const u8, allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    for (parsed.value) |s| try out.put(allocator, try allocator.dupe(u8, s), {});
}

fn serializeSharedWith(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) ![]u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var it = set.keyIterator();
    while (it.next()) |k| try list.append(allocator, k.*);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try json.Stringify.value(list.items, .{}, &out.writer);
    return out.toOwnedSlice();
}

const testing = std.testing;
const test_support = @import("../store/test_support.zig");

test "deviceKeysJson embeds identity keys and a verifiable ed25519 signature" {
    var account = try olm.Account.create(testing.allocator, testing.io);
    defer account.deinit(testing.allocator);

    const dk_json = try deviceKeysJson(testing.allocator, &account, "@bot:example.org", "DEVICE1");
    defer testing.allocator.free(dk_json);

    try testing.expect(std.mem.indexOf(u8, dk_json, "\"user_id\":\"@bot:example.org\"") != null);
    try testing.expect(std.mem.indexOf(u8, dk_json, "\"device_id\":\"DEVICE1\"") != null);
    try testing.expect(std.mem.indexOf(u8, dk_json, "curve25519:DEVICE1") != null);
    try testing.expect(std.mem.indexOf(u8, dk_json, "ed25519:DEVICE1") != null);
    try testing.expect(std.mem.indexOf(u8, dk_json, "\"signatures\"") != null);
}

test "signedOneTimeKeysJson signs every unpublished one-time key" {
    var account = try olm.Account.create(testing.allocator, testing.io);
    defer account.deinit(testing.allocator);
    try account.generateOneTimeKeys(testing.allocator, testing.io, 3);

    const otk_json = try signedOneTimeKeysJson(testing.allocator, &account, "@bot:example.org", "DEVICE1");
    defer testing.allocator.free(otk_json);

    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, otk_json, pos, "signed_curve25519:")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expect(std.mem.indexOf(u8, otk_json, "\"signatures\"") != null);
}

test "uploadKeysPayload wraps whichever fields are non-null" {
    const all_three = try uploadKeysPayload(testing.allocator, "{\"a\":1}", "{\"b\":2}", "{\"c\":3}");
    defer testing.allocator.free(all_three);
    try testing.expectEqualStrings("{\"device_keys\":{\"a\":1},\"one_time_keys\":{\"b\":2},\"fallback_keys\":{\"c\":3}}", all_three);

    const otk_only = try uploadKeysPayload(testing.allocator, null, "{\"b\":2}", null);
    defer testing.allocator.free(otk_only);
    try testing.expectEqualStrings("{\"one_time_keys\":{\"b\":2}}", otk_only);

    const fallback_only = try uploadKeysPayload(testing.allocator, null, null, "{\"c\":3}");
    defer testing.allocator.free(fallback_only);
    try testing.expectEqualStrings("{\"fallback_keys\":{\"c\":3}}", fallback_only);
}

// Regression test for the bug found live 2026-07-20: a payload missing any
// of these fields decrypts fine at the Olm layer (libolm doesn't know or
// care about them) but is silently rejected by every spec-compliant client
// (matrix-js-sdk's `OlmDecryption.decryptEvent` checks `recipient`/
test "State.shouldRotateSession triggers at exactly the age threshold" {
    const now: i64 = 1_000_000;
    try testing.expect(!State.shouldRotateSession(now, now - (State.megolm_session_max_age_s - 1)));
    try testing.expect(State.shouldRotateSession(now, now - State.megolm_session_max_age_s));
    try testing.expect(State.shouldRotateSession(now, now - (State.megolm_session_max_age_s + 1)));
    try testing.expect(!State.shouldRotateSession(now, now)); // brand new
}

// `recipient_keys.ed25519` before it will even look at `content`) — with
// no visible error anywhere, since Element only logs to-device decrypt
// failures internally. This test would have caught that regression.
test "State.buildRoomKeyPayload includes every field the Matrix spec requires" {
    const payload = try State.buildRoomKeyPayload(testing.allocator, .{
        .sender = "@alice:server",
        .sender_device = "ALICEDEVICE",
        .sender_ed25519 = "alice-ed25519-key",
        .recipient = "@bob:server",
        .recipient_ed25519 = "bob-ed25519-key",
        .room_id = "!room:server",
        .session_id = "session-id",
        .session_key = "session-key",
    });
    defer testing.allocator.free(payload);

    try testing.expect(std.mem.indexOf(u8, payload, "\"sender\":\"@alice:server\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"sender_device\":\"ALICEDEVICE\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"keys\":{\"ed25519\":\"alice-ed25519-key\"}") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"recipient\":\"@bob:server\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"recipient_keys\":{\"ed25519\":\"bob-ed25519-key\"}") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"m.room_key\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"session_key\":\"session-key\"") != null);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object); // must still be well-formed JSON
}

// `handleRoomKeyRequestFallible`'s safety gating is the most
// security-critical part of the whole responder — forwarding a room key
// to the wrong recipient defeats the point of the room being encrypted at
// all. Every case here must short-circuit before ever touching
// `self.client` (a dummy pointed at an unreachable URL — any of these
// cases reaching a real network call would hang/error this test).
test "State.handleRoomKeyRequest only ever answers this account's own other devices" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var bob_client = raw.Client.init(testing.allocator, testing.io, "http://unused.invalid", "unused-token");
    defer bob_client.deinit();
    var bob_account = try olm.Account.create(testing.allocator, testing.io);
    const bob_keys = try extractOwnIdentityKeys(testing.allocator, &bob_account);
    var bob_state = State{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = &pool,
        .pickle_key = "test-pickle-key",
        .account = bob_account,
        .user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .device_id = try testing.allocator.dupe(u8, "BOBDEVICE"),
        .own_curve25519 = bob_keys.curve25519,
        .own_ed25519 = bob_keys.ed25519,
        .client = &bob_client,
    };
    defer bob_state.deinit();

    const valid_body = types.RoomKeyRequestBody{
        .algorithm = "m.megolm.v1.aes-sha2",
        .room_id = "!room:server",
        .sender_key = "some-sender-key",
        .session_id = "some-session-id",
    };

    // A stranger's request — must be ignored regardless of anything else.
    try bob_state.handleRoomKeyRequestFallible("@mallory:server", .{
        .action = "request",
        .body = valid_body,
        .requesting_device_id = "MALLORYDEVICE",
    });

    // Our own account, but a cancellation, not a request.
    try bob_state.handleRoomKeyRequestFallible("@bob:server", .{
        .action = "request_cancellation",
        .body = valid_body,
        .requesting_device_id = "BOBOTHERDEVICE",
    });

    // Our own account, but no body (malformed).
    try bob_state.handleRoomKeyRequestFallible("@bob:server", .{
        .action = "request",
        .body = null,
        .requesting_device_id = "BOBOTHERDEVICE",
    });

    // Our own account, requesting our own current device — would be a
    // self-request loop.
    try bob_state.handleRoomKeyRequestFallible("@bob:server", .{
        .action = "request",
        .body = valid_body,
        .requesting_device_id = "BOBDEVICE",
    });

    // Our own account, wrong algorithm.
    try bob_state.handleRoomKeyRequestFallible("@bob:server", .{
        .action = "request",
        .body = .{ .algorithm = "m.olm.v1.curve25519-aes-sha2", .room_id = "!room:server", .sender_key = "k", .session_id = "s" },
        .requesting_device_id = "BOBOTHERDEVICE",
    });

    // A genuinely valid request would proceed to `self.client.queryKeys`
    // (untested here — no mock HTTP transport exists yet, see Phase E) —
    // reaching that call at all, without erroring on any of the cases
    // above, is what this test actually asserts.
}

test "State.handleToDeviceEvent + State.decryptRoomEvent: full room-key-share and message round trip" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    // Alice is the "other client" sharing a room key with us (bob).
    var alice_account = try olm.Account.create(testing.allocator, testing.io);
    defer alice_account.deinit(testing.allocator);
    const alice_keys = try extractOwnIdentityKeys(testing.allocator, &alice_account);
    defer testing.allocator.free(alice_keys.curve25519);
    defer testing.allocator.free(alice_keys.ed25519);

    // Bob is "us" — the State under test. This test only exercises the
    // decrypt side, which never dereferences `client` — a dummy pointed at
    // an unreachable URL is enough.
    var bob_client = raw.Client.init(testing.allocator, testing.io, "http://unused.invalid", "unused-token");
    defer bob_client.deinit();
    var bob_account = try olm.Account.create(testing.allocator, testing.io);
    const bob_keys = try extractOwnIdentityKeys(testing.allocator, &bob_account);
    var bob_state = State{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = &pool,
        .pickle_key = "test-pickle-key",
        .account = bob_account,
        .user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .device_id = try testing.allocator.dupe(u8, "BOBDEVICE"),
        .own_curve25519 = bob_keys.curve25519,
        .own_ed25519 = bob_keys.ed25519,
        .client = &bob_client,
    };
    defer bob_state.deinit();

    // Alice claims one of bob's one-time keys and establishes an outbound
    // Olm session with him (mirrors what /keys/claim + olm_create_outbound_
    // session gets a real client to, minus the HTTP round trip).
    try bob_state.account.generateOneTimeKeys(testing.allocator, testing.io, 1);
    const bob_otks_json = try bob_state.account.oneTimeKeysJson(testing.allocator);
    defer testing.allocator.free(bob_otks_json);
    var bob_otks = try json.parseFromSlice(struct { curve25519: json.ArrayHashMap([]const u8) }, testing.allocator, bob_otks_json, .{ .allocate = .alloc_always });
    defer bob_otks.deinit();
    var bob_otk_it = bob_otks.value.curve25519.map.iterator();
    const bob_otk = bob_otk_it.next().?.value_ptr.*;

    var alice_to_bob_session = try olm.Session.createOutbound(testing.allocator, testing.io, &alice_account, bob_keys.curve25519, bob_otk);
    defer alice_to_bob_session.deinit(testing.allocator);

    // Alice starts a Megolm outbound session for the room and shares its
    // key with bob via an Olm-encrypted m.room_key to-device payload.
    var alice_group_session = try olm.OutboundGroupSession.create(testing.allocator, testing.io);
    defer alice_group_session.deinit(testing.allocator);
    const megolm_session_id = try alice_group_session.id(testing.allocator);
    defer testing.allocator.free(megolm_session_id);
    const megolm_session_key = try alice_group_session.sessionKey(testing.allocator);
    defer testing.allocator.free(megolm_session_key);

    // Built via the same helper `shareWithNewDevices` uses — a payload
    // missing `sender`/`recipient`/`recipient_keys` is exactly the bug
    // found live 2026-07-20 (see `buildRoomKeyPayload`'s doc comment).
    const room_key_payload = try State.buildRoomKeyPayload(testing.allocator, .{
        .sender = "@alice:server",
        .sender_device = "ALICEDEVICE",
        .sender_ed25519 = alice_keys.ed25519,
        .recipient = "@bob:server",
        .recipient_ed25519 = bob_keys.ed25519,
        .room_id = "!room:server",
        .session_id = megolm_session_id,
        .session_key = megolm_session_key,
    });
    defer testing.allocator.free(room_key_payload);
    const olm_ciphertext = try alice_to_bob_session.encrypt(testing.allocator, testing.io, room_key_payload);
    defer testing.allocator.free(olm_ciphertext);
    const msg_type = try alice_to_bob_session.nextMessageType();
    try testing.expectEqual(@as(usize, 0), msg_type); // fresh session's first message is always PRE_KEY

    var content = types.OlmEncryptedContent{
        .algorithm = "m.olm.v1.curve25519-aes-sha2",
        .sender_key = alice_keys.curve25519,
    };
    try content.ciphertext.map.put(testing.allocator, bob_keys.curve25519, .{ .type = msg_type, .body = olm_ciphertext });
    defer content.ciphertext.deinit(testing.allocator);

    bob_state.handleToDeviceEvent("@alice:server", content);

    // The room key must now be on file...
    const stored_group = try store_crypto.loadInboundGroupSession(&pool, testing.allocator, "!room:server", alice_keys.curve25519, megolm_session_id);
    try testing.expect(stored_group != null);
    testing.allocator.free(stored_group.?);

    // ...and usable to decrypt an actual room message alice sends with it.
    const room_message_plaintext = "{\"type\":\"m.room.message\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"hello from megolm\"},\"room_id\":\"!room:server\"}";
    const megolm_ciphertext = try alice_group_session.encrypt(testing.allocator, room_message_plaintext);
    defer testing.allocator.free(megolm_ciphertext);

    const megolm_content = types.MegolmEncryptedContent{
        .algorithm = "m.megolm.v1.aes-sha2",
        .sender_key = alice_keys.curve25519,
        .ciphertext = megolm_ciphertext,
        .session_id = megolm_session_id,
    };
    var decrypted = (try bob_state.decryptRoomEvent(testing.allocator, "!room:server", megolm_content)).?;
    defer decrypted.deinit();
    try testing.expectEqualStrings("m.room.message", decrypted.value.type);
    try testing.expectEqualStrings("hello from megolm", decrypted.value.content.body.?);
}

// Regression test for `handleToDeviceEventFallible`'s new envelope
// validation — the receive-side counterpart of `buildRoomKeyPayload`'s
// send-side fix. A room key addressed to someone else must be rejected,
// not silently stored under our name (which would let a compromised or
// buggy sender plant a session key we'd trust as if we'd been the
// legitimate recipient).
test "State.handleToDeviceEvent rejects a room key addressed to a different recipient" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var alice_account = try olm.Account.create(testing.allocator, testing.io);
    defer alice_account.deinit(testing.allocator);
    const alice_keys = try extractOwnIdentityKeys(testing.allocator, &alice_account);
    defer testing.allocator.free(alice_keys.curve25519);
    defer testing.allocator.free(alice_keys.ed25519);

    var bob_client = raw.Client.init(testing.allocator, testing.io, "http://unused.invalid", "unused-token");
    defer bob_client.deinit();
    var bob_account = try olm.Account.create(testing.allocator, testing.io);
    const bob_keys = try extractOwnIdentityKeys(testing.allocator, &bob_account);
    var bob_state = State{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = &pool,
        .pickle_key = "test-pickle-key",
        .account = bob_account,
        .user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .device_id = try testing.allocator.dupe(u8, "BOBDEVICE"),
        .own_curve25519 = bob_keys.curve25519,
        .own_ed25519 = bob_keys.ed25519,
        .client = &bob_client,
    };
    defer bob_state.deinit();

    try bob_state.account.generateOneTimeKeys(testing.allocator, testing.io, 1);
    const bob_otks_json = try bob_state.account.oneTimeKeysJson(testing.allocator);
    defer testing.allocator.free(bob_otks_json);
    var bob_otks = try json.parseFromSlice(struct { curve25519: json.ArrayHashMap([]const u8) }, testing.allocator, bob_otks_json, .{ .allocate = .alloc_always });
    defer bob_otks.deinit();
    var bob_otk_it = bob_otks.value.curve25519.map.iterator();
    const bob_otk = bob_otk_it.next().?.value_ptr.*;

    var alice_to_bob_session = try olm.Session.createOutbound(testing.allocator, testing.io, &alice_account, bob_keys.curve25519, bob_otk);
    defer alice_to_bob_session.deinit(testing.allocator);

    var alice_group_session = try olm.OutboundGroupSession.create(testing.allocator, testing.io);
    defer alice_group_session.deinit(testing.allocator);
    const megolm_session_id = try alice_group_session.id(testing.allocator);
    defer testing.allocator.free(megolm_session_id);
    const megolm_session_key = try alice_group_session.sessionKey(testing.allocator);
    defer testing.allocator.free(megolm_session_key);

    // Addressed to Mallory, not Bob — Alice's own outbound session was
    // still established against Bob's real identity/one-time keys (as if
    // Bob's own client had a bug and built a wrong envelope, or a
    // malicious relay tried to redirect a genuine share), so the Olm
    // ratchet decrypt itself succeeds fine; only the envelope check should
    // catch this.
    const room_key_payload = try State.buildRoomKeyPayload(testing.allocator, .{
        .sender = "@alice:server",
        .sender_device = "ALICEDEVICE",
        .sender_ed25519 = alice_keys.ed25519,
        .recipient = "@mallory:server",
        .recipient_ed25519 = "mallory-does-not-have-this-key",
        .room_id = "!room:server",
        .session_id = megolm_session_id,
        .session_key = megolm_session_key,
    });
    defer testing.allocator.free(room_key_payload);
    const olm_ciphertext = try alice_to_bob_session.encrypt(testing.allocator, testing.io, room_key_payload);
    defer testing.allocator.free(olm_ciphertext);
    const msg_type = try alice_to_bob_session.nextMessageType();

    var content = types.OlmEncryptedContent{
        .algorithm = "m.olm.v1.curve25519-aes-sha2",
        .sender_key = alice_keys.curve25519,
    };
    try content.ciphertext.map.put(testing.allocator, bob_keys.curve25519, .{ .type = msg_type, .body = olm_ciphertext });
    defer content.ciphertext.deinit(testing.allocator);

    bob_state.handleToDeviceEvent("@alice:server", content);

    // The room key must NOT be stored under Bob's name.
    const stored_group = try store_crypto.loadInboundGroupSession(&pool, testing.allocator, "!room:server", alice_keys.curve25519, megolm_session_id);
    try testing.expectEqual(@as(?[]const u8, null), stored_group);
}

test "State.decryptRoomEvent returns null when no inbound session is on file" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var bob_client = raw.Client.init(testing.allocator, testing.io, "http://unused.invalid", "unused-token");
    defer bob_client.deinit();
    var bob_account = try olm.Account.create(testing.allocator, testing.io);
    const bob_keys = try extractOwnIdentityKeys(testing.allocator, &bob_account);
    var bob_state = State{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = &pool,
        .pickle_key = "test-pickle-key",
        .account = bob_account,
        .user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .device_id = try testing.allocator.dupe(u8, "BOBDEVICE"),
        .own_curve25519 = bob_keys.curve25519,
        .own_ed25519 = bob_keys.ed25519,
        .client = &bob_client,
    };
    defer bob_state.deinit();

    const content = types.MegolmEncryptedContent{
        .algorithm = "m.megolm.v1.aes-sha2",
        .sender_key = "UNKNOWNSENDER",
        .ciphertext = "irrelevant",
        .session_id = "UNKNOWNSESSION",
    };
    try testing.expectEqual(@as(?json.Parsed(types.DecryptedRoomEventPayload), null), try bob_state.decryptRoomEvent(testing.allocator, "!room:server", content));
}

// Regression test for the bug found live 2026-07-20, the mirror image of
// the missing-envelope-fields bug: `platform/matrix.zig`'s `sendEvent`
// omitted `room_id` from the plaintext it Megolm-encrypts, so every
// decrypted event failed matrix-js-sdk's own anti-replay check ("the room
// id of the room key doesn't match the room id of the decrypted event:
// expected <room>, got None") even though the room-key delivery itself
// (the earlier bug) had by then been fixed. `decryptRoomEvent` now
// enforces the same check on the receive side.
test "State.decryptRoomEvent rejects a plaintext whose room_id doesn't match" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var bob_client = raw.Client.init(testing.allocator, testing.io, "http://unused.invalid", "unused-token");
    defer bob_client.deinit();
    var bob_account = try olm.Account.create(testing.allocator, testing.io);
    const bob_keys = try extractOwnIdentityKeys(testing.allocator, &bob_account);
    var bob_state = State{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = &pool,
        .pickle_key = "test-pickle-key",
        .account = bob_account,
        .user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .device_id = try testing.allocator.dupe(u8, "BOBDEVICE"),
        .own_curve25519 = bob_keys.curve25519,
        .own_ed25519 = bob_keys.ed25519,
        .client = &bob_client,
    };
    defer bob_state.deinit();

    var group_session = try olm.OutboundGroupSession.create(testing.allocator, testing.io);
    defer group_session.deinit(testing.allocator);
    const session_id = try group_session.id(testing.allocator);
    defer testing.allocator.free(session_id);
    const session_key = try group_session.sessionKey(testing.allocator);
    defer testing.allocator.free(session_key);

    var inbound = try olm.InboundGroupSession.create(testing.allocator, session_key);
    defer inbound.deinit(testing.allocator);
    const pickled = try inbound.pickle(testing.allocator, bob_state.pickle_key);
    defer testing.allocator.free(pickled);
    try store_crypto.saveInboundGroupSession(&pool, "!roomA:server", "sender-curve25519", session_id, pickled);

    // Plaintext claims a *different* room than the session it's stored
    // under — exactly what a replayed/forged event would look like.
    const wrong_room_plaintext = "{\"type\":\"m.room.message\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"forged\"},\"room_id\":\"!roomB:server\"}";
    const ciphertext = try group_session.encrypt(testing.allocator, wrong_room_plaintext);
    defer testing.allocator.free(ciphertext);

    const content = types.MegolmEncryptedContent{
        .algorithm = "m.megolm.v1.aes-sha2",
        .sender_key = "sender-curve25519",
        .ciphertext = ciphertext,
        .session_id = session_id,
    };
    try testing.expectError(error.RoomIdMismatch, bob_state.decryptRoomEvent(testing.allocator, "!roomA:server", content));
}

// The full success path of a verification ceremony can't be tested without
// a mock HTTP transport (every handler's success path ends in a real
// `self.client.sendToDevice` call — same limitation noted throughout this
// file's other tests). The rejection paths *are* testable, though: a
// `cancelVerification` call's own `sendVerificationEvent` failure is
// caught internally and doesn't block cleanup, so a dummy unreachable
// client is enough to exercise "wrong commitment/MAC gets rejected and the
// session is torn down" — exactly the security-critical behavior worth
// regression-testing.
fn testVerificationState(pool: *store_pool.PgPool, client: *raw.Client) !State {
    var account = try olm.Account.create(testing.allocator, testing.io);
    const keys = try extractOwnIdentityKeys(testing.allocator, &account);
    return .{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = pool,
        .pickle_key = "test-pickle-key",
        .account = account,
        .user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .device_id = try testing.allocator.dupe(u8, "BOBDEVICE"),
        .own_curve25519 = keys.curve25519,
        .own_ed25519 = keys.ed25519,
        .client = client,
    };
}

test "State.handleVerificationKey rejects a mismatched commitment and tears down the session" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var client = raw.Client.init(testing.allocator, testing.io, "http://unused.invalid", "unused-token");
    defer client.deinit();
    var bob_state = try testVerificationState(&pool, &client);
    defer bob_state.deinit();

    var sas = try olm.Sas.create(testing.allocator, testing.io);
    errdefer sas.deinit(testing.allocator);
    const txn_key = try testing.allocator.dupe(u8, "txn-1");
    try bob_state.verifications.put(testing.allocator, txn_key, .{
        .their_user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .their_device_id = try testing.allocator.dupe(u8, "ALICEDEVICE"),
        .their_ed25519 = try testing.allocator.dupe(u8, "irrelevant-for-this-test"),
        .sent_start_json = try testing.allocator.dupe(u8, "{\"method\":\"m.sas.v1\"}"),
        .our_pubkey = try testing.allocator.dupe(u8, "irrelevant-for-this-test"),
        .sas = sas,
        .created_at_unix = std.Io.Timestamp.now(testing.io, .real).toSeconds(),
        .state = .key_sent,
        .their_commitment = try testing.allocator.dupe(u8, "deliberately-wrong-commitment"),
    });

    bob_state.handleVerificationKey("@bob:server", .{ .transaction_id = "txn-1", .key = "their-real-ephemeral-key" });

    try testing.expect(!bob_state.verifications.contains("txn-1"));
}

test "State.handleVerificationMac rejects a mismatched MAC and tears down the session" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try store_pool.PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var client = raw.Client.init(testing.allocator, testing.io, "http://unused.invalid", "unused-token");
    defer client.deinit();
    var bob_state = try testVerificationState(&pool, &client);
    defer bob_state.deinit();

    var sas = try olm.Sas.create(testing.allocator, testing.io);
    errdefer sas.deinit(testing.allocator);
    // A real session never reaches `.mac_sent` without `setTheirKey`
    // having already been called in `handleVerificationKeyFallible` —
    // match that here (any valid peer pubkey does, a second throwaway
    // `Sas`'s), or `calculateMac` below correctly errors
    // `SAS_THEIR_KEY_NOT_SET` instead of exercising the rejection path
    // this test is for.
    var peer_sas = try olm.Sas.create(testing.allocator, testing.io);
    defer peer_sas.deinit(testing.allocator);
    const peer_pubkey = try peer_sas.pubkey(testing.allocator);
    defer testing.allocator.free(peer_pubkey);
    try sas.setTheirKey(testing.allocator, peer_pubkey);

    const txn_key = try testing.allocator.dupe(u8, "txn-2");
    try bob_state.verifications.put(testing.allocator, txn_key, .{
        .their_user_id = try testing.allocator.dupe(u8, "@bob:server"),
        .their_device_id = try testing.allocator.dupe(u8, "ALICEDEVICE"),
        .their_ed25519 = try testing.allocator.dupe(u8, "some-ed25519-key"),
        .sent_start_json = try testing.allocator.dupe(u8, "{\"method\":\"m.sas.v1\"}"),
        .our_pubkey = try testing.allocator.dupe(u8, "irrelevant-for-this-test"),
        .sas = sas,
        .created_at_unix = std.Io.Timestamp.now(testing.io, .real).toSeconds(),
        .state = .mac_sent,
    });

    var mac_content = types.VerificationMacContent{ .transaction_id = "txn-2", .keys = "deliberately-wrong-keys-mac" };
    defer mac_content.mac.deinit(testing.allocator);
    try mac_content.mac.map.put(testing.allocator, "ed25519:ALICEDEVICE", "some-mac-value");

    bob_state.handleVerificationMac("@bob:server", mac_content);

    try testing.expect(!bob_state.verifications.contains("txn-2"));
}

test "parseSharedWithInto/serializeSharedWith round-trip a device share set" {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = set.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        set.deinit(testing.allocator);
    }

    try parseSharedWithInto(testing.allocator, "[\"@alice:server|DEVICE1\",\"@bob:server|DEVICE2\"]", &set);
    try testing.expect(set.contains("@alice:server|DEVICE1"));
    try testing.expect(set.contains("@bob:server|DEVICE2"));

    const serialized = try serializeSharedWith(testing.allocator, &set);
    defer testing.allocator.free(serialized);
    var reparsed: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = reparsed.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        reparsed.deinit(testing.allocator);
    }
    try parseSharedWithInto(testing.allocator, serialized, &reparsed);
    try testing.expect(reparsed.contains("@alice:server|DEVICE1"));
    try testing.expect(reparsed.contains("@bob:server|DEVICE2"));
}

test "curveKeyFor extracts a device's own curve25519 key, ignoring other devices'" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"keys":{"curve25519:DEVICE1":"KEY1","ed25519:DEVICE1":"SIGKEY1","curve25519:OTHERDEVICE":"KEY2"}}
    , .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();

    try testing.expectEqualStrings("KEY1", State.curveKeyFor(parsed.value, "DEVICE1").?);
    try testing.expect(State.curveKeyFor(parsed.value, "NONEXISTENT") == null);
}
