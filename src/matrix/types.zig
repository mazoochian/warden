//! Minimal subset of the Matrix Client-Server API's JSON shapes, decoded
//! with std.json — same spirit as `telegram/types.zig`: only fields Warden
//! actually uses are modeled, with `ignore_unknown_fields = true` at every
//! call site so the homeserver can send more than this without breaking
//! parsing. Field names that contain a literal dot (Matrix convention, e.g.
//! "m.relates_to") use Zig's `@"..."` quoted-identifier syntax rather than a
//! renamed field, since std.json matches JSON keys against the struct field
//! name exactly.

const std = @import("std");
const json = std.json;

/// `GET /_matrix/client/v3/account/whoami` — Matrix's equivalent of
/// Telegram's `getMe`, used to learn the bot's own user id at startup
/// (needed for mention detection and to avoid processing its own messages).
pub const WhoamiResponse = struct {
    user_id: []const u8 = "",
    device_id: ?[]const u8 = null,
};

pub const RelatesTo = struct {
    rel_type: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
    @"m.in_reply_to": ?InReplyTo = null,
    /// The reaction emoji, present when `rel_type` is "m.annotation" (an
    /// `m.reaction` event) — see `MatrixConnector.pollFn`'s handling of it.
    key: ?[]const u8 = null,
};

pub const InReplyTo = struct {
    event_id: []const u8,
};

pub const NewContent = struct {
    msgtype: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub const MediaInfo = struct {
    mimetype: ?[]const u8 = null,
    size: ?i64 = null,
};

/// `m.room.message` content, flattened across every msgtype Warden cares
/// about (text, image, file, audio, video) rather than a JSON-tagged union
/// — same style as `telegram/types.zig`'s `ChatMember`.
pub const MessageContent = struct {
    msgtype: ?[]const u8 = null,
    body: ?[]const u8 = null,
    /// `mxc://` URI, present on image/file/audio/video msgtypes (unencrypted
    /// media only — see README's note on encryption being out of scope).
    url: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    info: ?MediaInfo = null,
    @"m.relates_to": ?RelatesTo = null,
    @"m.new_content": ?NewContent = null,
    /// Presence of this key (any value, even `{}`) marks an `m.audio`
    /// message as a voice message per MSC3245.
    @"org.matrix.msc3245.voice": ?json.Value = null,
    /// Modern (MSC3952) explicit-mentions block; `user_ids` containing the
    /// bot's own id is the primary mention signal — see
    /// `MatrixConnector.mentionsMe`.
    @"m.mentions": ?Mentions = null,
};

pub const Mentions = struct {
    user_ids: []const []const u8 = &.{},
};

pub const RoomEvent = struct {
    type: []const u8 = "",
    sender: []const u8 = "",
    event_id: []const u8 = "",
    origin_server_ts: i64 = 0,
    /// Left as a raw `json.Value` rather than a fixed `MessageContent`:
    /// this event's `type` determines the actual content shape — plain
    /// `m.room.message` parses as `MessageContent`, but `m.room.encrypted`
    /// is a completely different shape (`MegolmEncryptedContent`), decided
    /// by whichever code reads this field, same pattern `ToDeviceEvent.
    /// content` below uses.
    content: json.Value = .null,
    /// Only meaningful for `m.room.member` events (join/leave/ban), unused
    /// for messages.
    state_key: ?[]const u8 = null,
};

pub const Timeline = struct {
    events: []RoomEvent = &.{},
};

pub const JoinedRoom = struct {
    timeline: Timeline = .{},
};

/// `rooms.invite`'s per-room value carries `invite_state`, but auto-join
/// only needs the room id itself (the map key) — the value is parsed just
/// enough to satisfy the schema, not actually read.
pub const InvitedRoom = struct {
    invite_state: ?json.Value = null,
};

pub const Rooms = struct {
    join: json.ArrayHashMap(JoinedRoom) = .{},
    invite: json.ArrayHashMap(InvitedRoom) = .{},
};

/// One entry of an Olm-encrypted to-device event's `ciphertext` map — keyed
/// by the *recipient's* curve25519 identity key (there's normally exactly
/// one entry, addressed to us, since to-device delivery is per-recipient).
pub const OlmCiphertextEntry = struct {
    type: usize = 0,
    body: []const u8 = "",
};

/// `m.room.encrypted` content for a **to-device** event (Olm,
/// `m.olm.v1.curve25519-aes-sha2`) — see `matrix/crypto.zig`'s
/// `State.handleToDeviceEvent`. Distinct shape from `MegolmEncryptedContent`
/// below: Olm's `ciphertext` is an object keyed by recipient identity key,
/// Megolm's is a plain base64 string.
pub const OlmEncryptedContent = struct {
    algorithm: []const u8 = "",
    sender_key: []const u8 = "",
    ciphertext: json.ArrayHashMap(OlmCiphertextEntry) = .{},
};

/// `m.room.encrypted` content for a **room-timeline** event (Megolm,
/// `m.megolm.v1.aes-sha2`) — see `matrix/crypto.zig`'s
/// `State.decryptRoomEvent`.
pub const MegolmEncryptedContent = struct {
    algorithm: []const u8 = "",
    sender_key: []const u8 = "",
    ciphertext: []const u8 = "",
    session_id: []const u8 = "",
    device_id: ?[]const u8 = null,
};

pub const ToDeviceEvent = struct {
    type: []const u8 = "",
    sender: []const u8 = "",
    /// Parsed later, once `type` is known — either `"m.room.encrypted"` or
    /// `"m.room_key_request"`, the two to-device event types this bot
    /// understands.
    content: json.Value = .null,
};

/// `m.room_key_request`'s `body` field — identifies which Megolm session
/// is being asked for. Only present when `action == "request"` (a
/// `"request_cancellation"` has no `body`).
pub const RoomKeyRequestBody = struct {
    algorithm: []const u8 = "",
    room_id: []const u8 = "",
    sender_key: []const u8 = "",
    session_id: []const u8 = "",
};

/// A to-device `m.room_key_request` — the reactive counterpart to
/// `m.room_key`'s proactive share, sent when a client (e.g. one of the
/// bot's own other devices, or a client that ran `/discardsession`)
/// couldn't decrypt a message and wants the session forwarded. See
/// `matrix/crypto.zig`'s `State.handleRoomKeyRequest`.
pub const RoomKeyRequestContent = struct {
    action: []const u8 = "",
    body: ?RoomKeyRequestBody = null,
    requesting_device_id: []const u8 = "",
    request_id: []const u8 = "",
};

pub const ToDevice = struct {
    events: []ToDeviceEvent = &.{},
};

/// Interactive (SAS/emoji) device verification, `m.key.verification.*` —
/// see `matrix/verification.zig` for the protocol logic and
/// `matrix/crypto.zig`'s `State.handleVerificationRequest` and friends for
/// the handlers. No `.ready`/`.start` receive-side structs: this bot only
/// ever *responds* to an incoming `.request` (never initiates one), and
/// per the spec's tie-break rule (whoever sends `.ready` auto-selects the
/// method and sends `.start` next), that means the bot always sends both
/// of those itself and never needs to parse a received one.
pub const VerificationRequestContent = struct {
    from_device: []const u8 = "",
    methods: []const []const u8 = &.{},
    transaction_id: []const u8 = "",
    /// POSIX milliseconds — ignore requests too far outside a sane skew
    /// window (spec: >5 min future or >10 min past).
    timestamp: i64 = 0,
};

pub const VerificationAcceptContent = struct {
    transaction_id: []const u8 = "",
    key_agreement_protocol: []const u8 = "",
    hash: []const u8 = "",
    message_authentication_code: []const u8 = "",
    short_authentication_string: []const []const u8 = &.{},
    /// base64(SHA256(their ephemeral pubkey || canonical JSON of the
    /// `start` content)) — see `verification.commitment`.
    commitment: []const u8 = "",
};

pub const VerificationKeyContent = struct {
    transaction_id: []const u8 = "",
    /// The sender's ephemeral Curve25519 public key, unpadded base64.
    key: []const u8 = "",
};

pub const VerificationMacContent = struct {
    transaction_id: []const u8 = "",
    /// MAC over the sorted, comma-joined `"{algorithm}:{keyId}"` list of
    /// every key present in `mac` below.
    keys: []const u8 = "",
    /// `"{algorithm}:{keyId}"` (e.g. `"ed25519:DEVICEID"`) -> base64 MAC.
    mac: json.ArrayHashMap([]const u8) = .{},
};

pub const VerificationDoneContent = struct {
    transaction_id: []const u8 = "",
};

pub const VerificationCancelContent = struct {
    transaction_id: []const u8 = "",
    code: []const u8 = "",
    reason: []const u8 = "",
};

/// The plaintext an Olm-decrypted to-device `m.room.encrypted` event
/// unwraps to — itself a full event shape (`type`+`content`), per the
/// Matrix spec's to-device encryption design. Only `m.room_key` is
/// understood; anything else is logged and ignored.
///
/// `sender`/`recipient`/`recipient_keys` are the same envelope fields
/// `matrix/crypto.zig`'s `State.buildRoomKeyPayload` writes on the send
/// side (see its doc comment for why they're required) — `State.
/// handleToDeviceEventFallible` validates them here on receive too,
/// mirroring matrix-js-sdk's own `OlmDecryption.decryptEvent` checks:
/// defense against a forged/misdirected Olm message, and symmetry with
/// what we now require of ourselves when sending.
pub const RoomKeyPayload = struct {
    type: []const u8 = "",
    content: RoomKeyContent = .{},
    sender: []const u8 = "",
    recipient: []const u8 = "",
    recipient_keys: RecipientKeys = .{},
};

pub const RecipientKeys = struct {
    ed25519: []const u8 = "",
};

pub const RoomKeyContent = struct {
    algorithm: []const u8 = "",
    room_id: []const u8 = "",
    session_id: []const u8 = "",
    session_key: []const u8 = "",
};

/// The plaintext a Megolm-decrypted room-timeline `m.room.encrypted` event
/// unwraps to — `content` reuses `MessageContent` directly since it's the
/// exact same shape an unencrypted `m.room.message` event's content is.
pub const DecryptedRoomEventPayload = struct {
    type: []const u8 = "",
    content: MessageContent = .{},
    room_id: []const u8 = "",
};

pub const SyncResponse = struct {
    next_batch: []const u8 = "",
    rooms: Rooms = .{},
    to_device: ToDevice = .{},
    /// `{algorithm: count}`, e.g. `{"signed_curve25519": 12}` — this
    /// device's remaining one-time keys still on the server, per the spec.
    /// Previously discarded (never parsed at all): the account's initial
    /// batch of 20 one-time keys, generated once at first startup, was
    /// never topped up as they got claimed — see `crypto.zig`'s
    /// `State.topUpOneTimeKeysIfNeeded`, driven by this field.
    device_one_time_keys_count: json.ArrayHashMap(i64) = .{},
};

pub const SendEventResponse = struct {
    event_id: []const u8 = "",
};

pub const UploadResponse = struct {
    content_uri: []const u8 = "",
};

/// Matrix errors are `{errcode, error}` on a non-2xx status — `http_util`'s
/// non-2xx handling discards the body (see its doc comment), so this is
/// only decoded where a client method needs the specific `errcode` (none
/// currently do; kept for parity with `telegram/types.zig`'s equivalent
/// error shapes and as a landing spot if that changes).
pub const ErrorResponse = struct {
    errcode: []const u8 = "",
    @"error": []const u8 = "",
};

const testing = std.testing;

test "MessageContent parses a plain text message" {
    const raw =
        \\{"msgtype":"m.text","body":"hello world"}
    ;
    var parsed = try json.parseFromSlice(MessageContent, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("m.text", parsed.value.msgtype.?);
    try testing.expectEqualStrings("hello world", parsed.value.body.?);
}

test "MessageContent parses m.relates_to for a reply and an edit" {
    const reply_raw =
        \\{"msgtype":"m.text","body":"re","m.relates_to":{"m.in_reply_to":{"event_id":"$abc"}}}
    ;
    var reply_parsed = try json.parseFromSlice(MessageContent, testing.allocator, reply_raw, .{ .ignore_unknown_fields = true });
    defer reply_parsed.deinit();
    try testing.expectEqualStrings("$abc", reply_parsed.value.@"m.relates_to".?.@"m.in_reply_to".?.event_id);

    const edit_raw =
        \\{"msgtype":"m.text","body":"* new","m.new_content":{"msgtype":"m.text","body":"new"},"m.relates_to":{"rel_type":"m.replace","event_id":"$xyz"}}
    ;
    var edit_parsed = try json.parseFromSlice(MessageContent, testing.allocator, edit_raw, .{ .ignore_unknown_fields = true });
    defer edit_parsed.deinit();
    try testing.expectEqualStrings("m.replace", edit_parsed.value.@"m.relates_to".?.rel_type.?);
    try testing.expectEqualStrings("new", edit_parsed.value.@"m.new_content".?.body.?);
}

test "RoomEvent parses an m.reaction event's rel_type/event_id/key" {
    const raw =
        \\{"type":"m.reaction","sender":"@alice:server","event_id":"$r1","origin_server_ts":1000,
        \\"content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$target","key":"📄"}}}
    ;
    var parsed = try json.parseFromSlice(RoomEvent, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var content = try json.parseFromValue(MessageContent, testing.allocator, parsed.value.content, .{ .ignore_unknown_fields = true });
    defer content.deinit();
    const rel = content.value.@"m.relates_to".?;
    try testing.expectEqualStrings("m.annotation", rel.rel_type.?);
    try testing.expectEqualStrings("$target", rel.event_id.?);
    try testing.expectEqualStrings("📄", rel.key.?);
}

test "SyncResponse parses a joined room's timeline via ArrayHashMap" {
    const raw =
        \\{"next_batch":"s1","rooms":{"join":{"!room:server":{"timeline":{"events":[
        \\  {"type":"m.room.message","sender":"@alice:server","event_id":"$1","origin_server_ts":1000,"content":{"msgtype":"m.text","body":"hi"}}
        \\]}}}}}
    ;
    var parsed = try json.parseFromSlice(SyncResponse, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("s1", parsed.value.next_batch);
    const room = parsed.value.rooms.join.map.get("!room:server").?;
    try testing.expectEqual(@as(usize, 1), room.timeline.events.len);
    var content = try json.parseFromValue(MessageContent, testing.allocator, room.timeline.events[0].content, .{ .ignore_unknown_fields = true });
    defer content.deinit();
    try testing.expectEqualStrings("hi", content.value.body.?);
}

test "Mentions parses explicit m.mentions user_ids" {
    const raw =
        \\{"msgtype":"m.text","body":"@bot hi","m.mentions":{"user_ids":["@bot:server"]}}
    ;
    var parsed = try json.parseFromSlice(MessageContent, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.@"m.mentions".?.user_ids.len);
    try testing.expectEqualStrings("@bot:server", parsed.value.@"m.mentions".?.user_ids[0]);
}

test "SyncResponse parses to_device Olm-encrypted events" {
    const raw =
        \\{"next_batch":"s1","to_device":{"events":[
        \\  {"type":"m.room.encrypted","sender":"@alice:server","content":{
        \\    "algorithm":"m.olm.v1.curve25519-aes-sha2","sender_key":"SENDERKEY",
        \\    "ciphertext":{"OURKEY":{"type":0,"body":"BASE64BODY"}}
        \\  }}
        \\]}}
    ;
    var parsed = try json.parseFromSlice(SyncResponse, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.to_device.events.len);
    const ev = parsed.value.to_device.events[0];
    try testing.expectEqualStrings("m.room.encrypted", ev.type);
    try testing.expectEqualStrings("@alice:server", ev.sender);

    var content = try json.parseFromValue(OlmEncryptedContent, testing.allocator, ev.content, .{ .ignore_unknown_fields = true });
    defer content.deinit();
    try testing.expectEqualStrings("SENDERKEY", content.value.sender_key);
    const entry = content.value.ciphertext.map.get("OURKEY").?;
    try testing.expectEqual(@as(usize, 0), entry.type);
    try testing.expectEqualStrings("BASE64BODY", entry.body);
}

test "MegolmEncryptedContent parses a room-timeline encrypted event's content" {
    const raw =
        \\{"algorithm":"m.megolm.v1.aes-sha2","sender_key":"SENDERKEY","ciphertext":"BASE64CIPHERTEXT","session_id":"SESSIONID","device_id":"DEVICEID"}
    ;
    var parsed = try json.parseFromSlice(MegolmEncryptedContent, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("BASE64CIPHERTEXT", parsed.value.ciphertext);
    try testing.expectEqualStrings("SESSIONID", parsed.value.session_id);
}

test "RoomKeyPayload parses a decrypted to-device m.room_key payload" {
    const raw =
        \\{"type":"m.room_key","content":{"algorithm":"m.megolm.v1.aes-sha2","room_id":"!room:server","session_id":"SESSIONID","session_key":"SESSIONKEY"}}
    ;
    var parsed = try json.parseFromSlice(RoomKeyPayload, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("m.room_key", parsed.value.type);
    try testing.expectEqualStrings("!room:server", parsed.value.content.room_id);
    try testing.expectEqualStrings("SESSIONKEY", parsed.value.content.session_key);
}

test "DecryptedRoomEventPayload parses a decrypted megolm room message" {
    const raw =
        \\{"type":"m.room.message","content":{"msgtype":"m.text","body":"hi from megolm"},"room_id":"!room:server"}
    ;
    var parsed = try json.parseFromSlice(DecryptedRoomEventPayload, testing.allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("m.room.message", parsed.value.type);
    try testing.expectEqualStrings("hi from megolm", parsed.value.content.body.?);
}
