const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const types = @import("types.zig");
const http_util = @import("../../http_util.zig");

/// Thin wrapper around the Matrix Client-Server API, authenticated with a
/// pre-provisioned access token.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    http_client: http.Client,
    homeserver_url: []const u8,
    access_token: []const u8,
    /// Unique per PUT (send/state) call, so retried/duplicate requests are
    /// idempotent from the homeserver's point of view.
    txn_counter: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, io: Io, homeserver_url: []const u8, access_token: []const u8) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
            .homeserver_url = homeserver_url,
            .access_token = access_token,
            .txn_counter = .init(@intCast(Io.Timestamp.now(io, .real).toNanoseconds())),
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    fn authHeader(self: *Client, allocator: std.mem.Allocator) !http.Header {
        return .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.access_token}) };
    }

    fn nextTxnId(self: *Client, allocator: std.mem.Allocator) ![]const u8 {
        const n = self.txn_counter.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(allocator, "warden{d}", .{n});
    }

    /// Percent-encodes a path segment.
    fn encodeSegment(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        return http_util.encodeQueryComponent(allocator, s);
    }

    /// Resolves the bot's own user id — Matrix's equivalent of Telegram's
    /// `getMe`.
    pub fn whoami(self: *Client, allocator: std.mem.Allocator) !json.Parsed(types.WhoamiResponse) {
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/account/whoami", .{self.homeserver_url});
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth});
        defer allocator.free(body);

        return json.parseFromSlice(types.WhoamiResponse, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// Uploads this device's signed identity/one-time keys.
    pub fn uploadKeys(self: *Client, allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/keys/upload", .{self.homeserver_url});
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        return http_util.postJson(&self.http_client, allocator, url, &.{auth}, payload);
    }

    /// Long-polls for new events since `since`.
    pub fn sync(self: *Client, allocator: std.mem.Allocator, since: ?[]const u8) !json.Parsed(types.SyncResponse) {
        const url = if (since) |s|
            try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/sync?timeout=25000&since={s}", .{ self.homeserver_url, try encodeSegment(allocator, s) })
        else
            try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/sync?timeout=25000", .{self.homeserver_url});
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth});
        defer allocator.free(body);

        return json.parseFromSlice(types.SyncResponse, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// Accepts a pending invite — warden auto-joins any room it's invited to (see
    /// `pollFn`).
    pub fn joinRoom(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) !void {
        const encoded = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/join/{s}", .{ self.homeserver_url, encoded });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.postJson(&self.http_client, allocator, url, &.{auth}, "{}");
        defer allocator.free(body);
    }

    pub const MessagePayload = struct {
        msgtype: []const u8 = "m.text",
        body: []const u8,
        @"m.relates_to": ?types.RelatesTo = null,
    };

    pub fn replyRelation(reply_to_event_id: ?[]const u8) ?types.RelatesTo {
        const id = reply_to_event_id orelse return null;
        return .{ .@"m.in_reply_to" = .{ .event_id = id } };
    }

    pub const EditPayload = struct {
        msgtype: []const u8 = "m.text",
        body: []const u8,
        @"m.new_content": types.NewContent,
        @"m.relates_to": types.RelatesTo,
    };

    pub const ReactionPayload = struct {
        @"m.relates_to": types.RelatesTo,
    };

    /// `PUT .../rooms/{roomId}/send/{eventType}/{txn}` with an already-JSON-
    /// stringified `payload`.
    pub fn putRoomEvent(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_type: []const u8, payload: []const u8) ![]const u8 {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const encoded_type = try encodeSegment(allocator, event_type);
        defer allocator.free(encoded_type);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/send/{s}/{s}", .{ self.homeserver_url, encoded_room, encoded_type, txn });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(types.SendEventResponse, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();
        return allocator.dupe(u8, parsed.value.event_id);
    }

    /// Uploads bytes and returns their `mxc://` content URI — the two-step
    /// process every image/document send needs.
    pub fn uploadMedia(self: *Client, allocator: std.mem.Allocator, bytes: []const u8, content_type: []const u8, filename: []const u8) ![]const u8 {
        const encoded_name = try encodeSegment(allocator, filename);
        defer allocator.free(encoded_name);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/media/v3/upload?filename={s}", .{ self.homeserver_url, encoded_name });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.postRaw(&self.http_client, allocator, url, content_type, &.{auth}, bytes);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(types.UploadResponse, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();
        return allocator.dupe(u8, parsed.value.content_uri);
    }

    const MediaMessagePayload = struct {
        msgtype: []const u8,
        body: []const u8,
        url: []const u8,
        filename: ?[]const u8 = null,
    };

    /// Uploads `bytes` then sends an `m.room.message` pointing at it.
    fn sendMedia(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, bytes: []const u8, content_type: []const u8, msgtype: []const u8, filename: []const u8, caption: ?[]const u8) !void {
        const uri = try self.uploadMedia(allocator, bytes, content_type, filename);
        defer allocator.free(uri);

        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/send/m.room.message/{s}", .{ self.homeserver_url, encoded_room, txn });
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(MediaMessagePayload{
            .msgtype = msgtype,
            .body = caption orelse filename,
            .url = uri,
            .filename = filename,
        }, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
    }

    /// Fire-and-forget, like `../telegram/client.zig`'s `sendPhoto`.
    pub fn sendPhoto(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        self.sendMedia(allocator, room_id, image_bytes, "image/png", "m.image", "image.png", caption) catch |err| {
            std.log.err("matrix sendPhoto failed: {t}", .{err});
        };
    }

    /// Fire-and-forget, like `../telegram/client.zig`'s `sendDocument`.
    pub fn sendDocument(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        self.sendMedia(allocator, room_id, file_bytes, "application/octet-stream", "m.file", file_name, caption) catch |err| {
            std.log.err("matrix sendDocument failed: {t}", .{err});
        };
    }

    /// Resolves an inbound attachment's `mxc://server/media_id` URI to bytes.
    pub fn downloadFile(self: *Client, allocator: std.mem.Allocator, mxc_uri: []const u8) ![]u8 {
        const prefix = "mxc://";
        if (!std.mem.startsWith(u8, mxc_uri, prefix)) return error.InvalidMxcUri;
        const rest = mxc_uri[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidMxcUri;
        const server_name = rest[0..slash];
        const media_id = rest[slash + 1 ..];

        const encoded_server = try encodeSegment(allocator, server_name);
        defer allocator.free(encoded_server);
        const encoded_media = try encodeSegment(allocator, media_id);
        defer allocator.free(encoded_media);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v1/media/download/{s}/{s}", .{ self.homeserver_url, encoded_server, encoded_media });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        return http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth});
    }

    /// Fetches a single event by id — Matrix doesn't inline the replied-to
    /// event's sender/body the way Telegram's `reply_to_message` does.
    pub fn getEvent(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_id: []const u8) !json.Parsed(types.RoomEvent) {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const encoded_event = try encodeSegment(allocator, event_id);
        defer allocator.free(encoded_event);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/event/{s}", .{ self.homeserver_url, encoded_room, encoded_event });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth});
        defer allocator.free(body);

        return json.parseFromSlice(types.RoomEvent, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// True if `room_id` has an `m.room.encryption` state event — 404 (no such
    /// state event) means the room is plaintext.
    pub fn isRoomEncrypted(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) !bool {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/state/m.room.encryption", .{ self.homeserver_url, encoded_room });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth}) catch |err| {
            if (err == error.HttpRequestFailed) return false;
            return err;
        };
        allocator.free(body);
        return true;
    }

    /// `m.room.name` for `room_id`, or `null` when the room has none set (a 1:1
    /// DM usually doesn't) or the server refuses the read.
    pub fn roomName(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) !?[]const u8 {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/state/m.room.name", .{ self.homeserver_url, encoded_room });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth}) catch |err| {
            // A room with no name set answers 404, which is a normal
            // outcome here, not a failure worth propagating.
            if (err == error.HttpRequestFailed) return null;
            return err;
        };
        defer allocator.free(body);

        const Body = struct { name: ?[]const u8 = null };
        const parsed = json.parseFromSlice(Body, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const name = parsed.value.name orelse return null;
        if (name.len == 0) return null;
        return try allocator.dupe(u8, name);
    }

    /// Currently-joined member user ids for `room_id`.
    pub fn joinedMembers(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) ![]const []const u8 {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/joined_members", .{ self.homeserver_url, encoded_room });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth});
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(json.Value, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();
        const joined = parsed.value.object.get("joined") orelse return &.{};
        if (joined != .object) return &.{};

        var out: std.ArrayList([]const u8) = .empty;
        var it = joined.object.iterator();
        while (it.next()) |entry| try out.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        return out.toOwnedSlice(allocator);
    }

    /// `POST /keys/query` for every device of each of `user_ids` — returned as a
    /// raw `json.Value`.
    pub fn queryKeys(self: *Client, allocator: std.mem.Allocator, user_ids: []const []const u8) !json.Parsed(json.Value) {
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/keys/query", .{self.homeserver_url});
        defer allocator.free(url);

        var device_keys: json.Value = .{ .object = .empty };
        for (user_ids) |uid| try device_keys.object.put(allocator, uid, .{ .array = .init(allocator) });
        var body_obj: json.Value = .{ .object = .empty };
        try body_obj.object.put(allocator, "device_keys", device_keys);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(body_obj, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.postJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);

        return json.parseFromSlice(json.Value, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// `POST /keys/claim` for one `signed_curve25519` one-time key from
    /// `device_id`, returning the claimed key's base64 value.
    pub fn claimOneTimeKey(self: *Client, allocator: std.mem.Allocator, user_id: []const u8, device_id: []const u8) ![]const u8 {
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/keys/claim", .{self.homeserver_url});
        defer allocator.free(url);

        var device_obj: json.Value = .{ .object = .empty };
        try device_obj.object.put(allocator, device_id, .{ .string = "signed_curve25519" });
        var user_obj: json.Value = .{ .object = .empty };
        try user_obj.object.put(allocator, user_id, device_obj);
        var body_obj: json.Value = .{ .object = .empty };
        try body_obj.object.put(allocator, "one_time_keys", user_obj);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(body_obj, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.postJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(json.Value, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();

        const otks = parsed.value.object.get("one_time_keys") orelse return error.NoOneTimeKeyAvailable;
        if (otks != .object) return error.NoOneTimeKeyAvailable;
        const per_user = otks.object.get(user_id) orelse return error.NoOneTimeKeyAvailable;
        if (per_user != .object) return error.NoOneTimeKeyAvailable;
        const per_device = per_user.object.get(device_id) orelse return error.NoOneTimeKeyAvailable;
        if (per_device != .object or per_device.object.count() == 0) return error.NoOneTimeKeyAvailable;

        // Exactly one `signed_curve25519:<key id>` entry per requested
        // device — take whichever the server handed back.
        var it = per_device.object.iterator();
        const entry = it.next().?;
        if (entry.value_ptr.* != .object) return error.NoOneTimeKeyAvailable;
        const key_val = entry.value_ptr.object.get("key") orelse return error.NoOneTimeKeyAvailable;
        if (key_val != .string) return error.NoOneTimeKeyAvailable;
        return allocator.dupe(u8, key_val.string);
    }

    /// `PUT /sendToDevice/{eventType}/{txn}` addressed to a single `(user_id,
    /// device_id)`.
    pub fn sendToDevice(self: *Client, allocator: std.mem.Allocator, event_type: []const u8, user_id: []const u8, device_id: []const u8, content: json.Value) !void {
        const encoded_type = try encodeSegment(allocator, event_type);
        defer allocator.free(encoded_type);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/sendToDevice/{s}/{s}", .{ self.homeserver_url, encoded_type, txn });
        defer allocator.free(url);

        // Each `.deinit()` only frees this function's own wrapper map storage, not
        // `content` itself.
        var device_obj: json.Value = .{ .object = .empty };
        defer device_obj.object.deinit(allocator);
        try device_obj.object.put(allocator, device_id, content);
        var user_obj: json.Value = .{ .object = .empty };
        defer user_obj.object.deinit(allocator);
        try user_obj.object.put(allocator, user_id, device_obj);
        var body_obj: json.Value = .{ .object = .empty };
        defer body_obj.object.deinit(allocator);
        try body_obj.object.put(allocator, "messages", user_obj);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(body_obj, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
    }

    fn callAction(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, action: []const u8, user_id: []const u8, reason: ?[]const u8) !void {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/{s}", .{ self.homeserver_url, encoded_room, action });
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(.{ .user_id = user_id, .reason = reason }, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.postJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
    }

    pub fn kickUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.callAction(allocator, room_id, "kick", user_id, "Kicked by warden");
    }

    pub fn banUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.callAction(allocator, room_id, "ban", user_id, "Banned by warden");
    }

    pub fn unbanUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.callAction(allocator, room_id, "unban", user_id, null);
    }

    /// Matrix's default moderator threshold.
    const moderator_power_level: i64 = 50;
    /// Below `events_default` (normally 0) so a muted user's own messages are
    /// rejected by the homeserver, mirroring Telegram's `restrictChatMember`.
    const muted_power_level: i64 = -1;
    const ordinary_power_level: i64 = 0;

    fn powerLevelsUrl(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) ![]u8 {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        return std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/state/m.room.power_levels", .{ self.homeserver_url, encoded_room });
    }

    /// Fetches the room's power-levels state event as a raw `json.Value` —
    /// deliberately not a fully-typed struct.
    fn getPowerLevels(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) !json.Parsed(json.Value) {
        const url = try self.powerLevelsUrl(allocator, room_id);
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth});
        defer allocator.free(body);

        return json.parseFromSlice(json.Value, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    fn putPowerLevels(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, content: json.Value) !void {
        const url = try self.powerLevelsUrl(allocator, room_id);
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(content, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
    }

    fn setUserPowerLevel(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8, level: i64) !void {
        var parsed = try self.getPowerLevels(allocator, room_id);
        defer parsed.deinit();

        if (parsed.value != .object) return error.UnexpectedPowerLevelsShape;
        const users_entry = try parsed.value.object.getOrPut(allocator, "users");
        if (!users_entry.found_existing or users_entry.value_ptr.* != .object) {
            users_entry.value_ptr.* = .{ .object = .empty };
        }
        try users_entry.value_ptr.object.put(allocator, user_id, .{ .integer = level });

        try self.putPowerLevels(allocator, room_id, parsed.value);
    }

    pub fn muteUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.setUserPowerLevel(allocator, room_id, user_id, muted_power_level);
    }

    pub fn unmuteUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.setUserPowerLevel(allocator, room_id, user_id, ordinary_power_level);
    }

    /// Matrix's power-level equivalent of Telegram's `promoteChatMember` — bumps
    /// `user_id` to the room's moderator threshold.
    pub fn promoteUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.setUserPowerLevel(allocator, room_id, user_id, moderator_power_level);
    }

    pub fn demoteUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.setUserPowerLevel(allocator, room_id, user_id, ordinary_power_level);
    }

    /// True if `user_id`'s power level in `room_id` meets or exceeds the
    /// moderator threshold.
    pub fn isRoomModerator(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !bool {
        var parsed = try self.getPowerLevels(allocator, room_id);
        defer parsed.deinit();
        if (parsed.value != .object) return false;

        const level = blk: {
            if (parsed.value.object.get("users")) |users| {
                if (users == .object) {
                    if (users.object.get(user_id)) |v| {
                        if (v == .integer) break :blk v.integer;
                    }
                }
            }
            if (parsed.value.object.get("users_default")) |d| {
                if (d == .integer) break :blk d.integer;
            }
            break :blk 0;
        };
        return level >= moderator_power_level;
    }

    const PinnedContent = struct { pinned: []const []const u8 = &.{} };

    fn pinnedEventsUrl(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) ![]u8 {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        return std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/state/m.room.pinned_events", .{ self.homeserver_url, encoded_room });
    }

    fn getPinnedEvents(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) ![][]const u8 {
        const url = try self.pinnedEventsUrl(allocator, room_id);
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = http_util.getWithHeaders(&self.http_client, allocator, url, &.{auth}) catch |err| {
            // No `m.room.pinned_events` state event yet (nothing pinned so
            // far) 404s — that's an empty list, not a real failure.
            if (err == error.HttpRequestFailed) return &.{};
            return err;
        };
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(PinnedContent, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();
        return allocator.dupe([]const u8, parsed.value.pinned);
    }

    fn putPinnedEvents(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, pinned: []const []const u8) !void {
        const url = try self.pinnedEventsUrl(allocator, room_id);
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(PinnedContent{ .pinned = pinned }, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
    }

    /// PUTs a single-field room state event (`m.room.name`/`m.room.topic`/
    /// `m.room.avatar`).
    fn putSingleFieldState(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_type: []const u8, field: []const u8, value: []const u8) !void {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/state/{s}", .{ self.homeserver_url, encoded_room, event_type });
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try payload_writer.writer.print("{{\"{s}\":", .{field});
        try json.Stringify.value(value, .{}, &payload_writer.writer);
        try payload_writer.writer.writeAll("}");
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
    }

    /// `/title` — `m.room.name`.
    pub fn setRoomName(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, name: []const u8) !void {
        return self.putSingleFieldState(allocator, room_id, "m.room.name", "name", name);
    }

    /// `/description` — `m.room.topic`. An empty `topic` clears it (Matrix
    /// has no separate "unset" — an empty string is the convention).
    pub fn setRoomTopic(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, topic: []const u8) !void {
        return self.putSingleFieldState(allocator, room_id, "m.room.topic", "topic", topic);
    }

    /// `/photo` — uploads the image, then points `m.room.avatar` at the resulting
    /// `mxc://` uri.
    pub fn setRoomAvatar(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, image_bytes: []const u8, content_type: []const u8) !void {
        const uri = try self.uploadMedia(allocator, image_bytes, content_type, "avatar");
        defer allocator.free(uri);
        return self.putSingleFieldState(allocator, room_id, "m.room.avatar", "url", uri);
    }

    /// `/photo remove` — clears `m.room.avatar`'s `url` rather than removing the
    /// state event (Matrix has no delete-state-event operation Bot-API-style; an
    /// empty `url` is how clients render "no avatar").
    pub fn removeRoomAvatar(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) !void {
        return self.putSingleFieldState(allocator, room_id, "m.room.avatar", "url", "");
    }

    /// Adds `event_id` to the room's pinned list if it isn't already there.
    pub fn pinMessage(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_id: []const u8) !void {
        const existing = try self.getPinnedEvents(allocator, room_id);
        defer allocator.free(existing);
        for (existing) |id| if (std.mem.eql(u8, id, event_id)) return;

        var next: std.ArrayList([]const u8) = .empty;
        defer next.deinit(allocator);
        try next.appendSlice(allocator, existing);
        try next.append(allocator, event_id);
        try self.putPinnedEvents(allocator, room_id, next.items);
    }

    /// `event_id` null clears every pin (matches Telegram's `unpinMessage`
    /// semantics when no specific message is targeted); otherwise removes just
    /// that one.
    pub fn unpinMessage(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_id: ?[]const u8) !void {
        const id = event_id orelse return self.putPinnedEvents(allocator, room_id, &.{});

        const existing = try self.getPinnedEvents(allocator, room_id);
        defer allocator.free(existing);

        var next: std.ArrayList([]const u8) = .empty;
        defer next.deinit(allocator);
        for (existing) |eid| {
            if (!std.mem.eql(u8, eid, id)) try next.append(allocator, eid);
        }
        try self.putPinnedEvents(allocator, room_id, next.items);
    }

    /// Redacts (Matrix's soft-delete: content is stripped, not the event
    /// itself) — the closest equivalent to Telegram's `deleteMessage`.
    pub fn redactMessage(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_id: []const u8) !void {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const encoded_event = try encodeSegment(allocator, event_id);
        defer allocator.free(encoded_event);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/redact/{s}/{s}", .{ self.homeserver_url, encoded_room, encoded_event, txn });
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, "{}");
        defer allocator.free(body);
    }
};
