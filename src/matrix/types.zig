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
    content: MessageContent = .{},
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

pub const SyncResponse = struct {
    next_batch: []const u8 = "",
    rooms: Rooms = .{},
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
    try testing.expectEqualStrings("hi", room.timeline.events[0].content.body.?);
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
