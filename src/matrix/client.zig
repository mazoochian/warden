const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const types = @import("types.zig");
const http_util = @import("../http_util.zig");

/// Thin wrapper around the Matrix Client-Server API, authenticated with a
/// pre-provisioned access token (see `config.MatrixConfig`'s doc comment).
/// Uses `/sync` long-polling rather than push/webhooks, same reasoning as
/// `telegram/client.zig`'s choice of long polling over webhooks.
///
/// Deliberately out of scope: end-to-end encryption (Olm/Megolm) — this
/// client only sends/receives in plaintext rooms. See README for details.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    http_client: http.Client,
    homeserver_url: []const u8,
    access_token: []const u8,
    /// Unique per PUT (send/state) call, so retried/duplicate requests are
    /// idempotent from the homeserver's point of view — incremented
    /// atomically since moderation/reply calls can run concurrently across
    /// per-message tasks (see `PgPool`'s doc comment for why that's normal
    /// in this codebase).
    ///
    /// Seeded from wall-clock time in `init`, not left at 0: Synapse
    /// remembers recently-used txn ids per access token across different
    /// endpoints (e.g. `sendToDevice` vs `send/m.room.encrypted`) and
    /// rejects a reused id with `M_INVALID_PARAM` even across process
    /// restarts. A dev container that restarts often would otherwise
    /// reissue low ids like `warden3` that collide with the same id from
    /// a previous run — confirmed live 2026-07-20.
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

    /// Percent-encodes a path segment (room id, event id, user id — all of
    /// which contain characters like `!`, `$`, `@`, `:` that must not be
    /// interpreted as URL structure).
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

    /// Uploads this device's signed identity/one-time keys (see
    /// `matrix/crypto.zig`'s `deviceKeysJson`/`signedOneTimeKeysJson`/
    /// `uploadKeysPayload` for how `payload` is built) — returns the raw
    /// response body (just `{"one_time_key_counts": {...}}`) rather than a
    /// typed struct, since nothing needs to act on it yet beyond logging.
    pub fn uploadKeys(self: *Client, allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/keys/upload", .{self.homeserver_url});
        defer allocator.free(url);

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        return http_util.postJson(&self.http_client, allocator, url, &.{auth}, payload);
    }

    /// Long-polls for new events since `since` (null on the very first call
    /// — see `MatrixConnector.pollFn`'s doc comment on why that first
    /// response's events are discarded rather than processed). 25s not 30s,
    /// same middlebox-idle-reap reasoning as `telegram.zig`'s `pollFn`.
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

    /// Accepts a pending invite — warden auto-joins any room it's invited
    /// to (see `pollFn`), matching how a Telegram bot is simply added to a
    /// group with no separate accept step.
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

    /// `PUT .../rooms/{roomId}/send/{eventType}/{txn}` with an
    /// already-JSON-stringified `payload` — the one generic primitive every
    /// room-timeline send goes through, whether that's a plaintext
    /// `m.room.message`/`m.reaction` or (see `platform/matrix.zig`'s
    /// `MatrixConnector.sendEvent`) an `m.room.encrypted` event wrapping one
    /// of those. Kept generic rather than one method per event type so the
    /// encryption decision has a single place to plug into, instead of
    /// needing its own copy inside every `sendX` method.
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
    /// process every image/document send needs: upload first, then send an
    /// `m.room.message` event pointing at the resulting URI.
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

    /// Uploads `bytes` then sends an `m.room.message` pointing at it —
    /// shared by `sendPhoto`/`sendDocument` (only `msgtype` and whether
    /// `filename` is sent differ between an image and an arbitrary file).
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

    /// Fire-and-forget, like `telegram/client.zig`'s `sendPhoto`.
    pub fn sendPhoto(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        self.sendMedia(allocator, room_id, image_bytes, "image/png", "m.image", "image.png", caption) catch |err| {
            std.log.err("matrix sendPhoto failed: {t}", .{err});
        };
    }

    /// Fire-and-forget, like `telegram/client.zig`'s `sendDocument`.
    pub fn sendDocument(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        self.sendMedia(allocator, room_id, file_bytes, "application/octet-stream", "m.file", file_name, caption) catch |err| {
            std.log.err("matrix sendDocument failed: {t}", .{err});
        };
    }

    /// Resolves an inbound attachment's `mxc://server/media_id` URI to
    /// bytes — Matrix's equivalent of Telegram's two-step `getFile` +
    /// download, but a single request since the media id is already fully
    /// resolved (no separate lookup step).
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
    /// event's sender/body the way Telegram's `reply_to_message` does, so
    /// resolving a reply's target (for `reply_to_is_me`/`reply_to_text`)
    /// needs this extra round trip. Only called when an inbound message
    /// actually carries an `m.in_reply_to` relation (see
    /// `MatrixConnector.pollFn`), not on every message.
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

    /// True if `room_id` has an `m.room.encryption` state event — 404 (no
    /// such state event) means the room is plaintext, matching how
    /// `getPinnedEvents` treats a 404 as "nothing there" rather than an
    /// error. Checked once per send by `platform/matrix.zig`'s
    /// `MatrixConnector.sendEvent` to decide whether to Megolm-wrap the
    /// outgoing content.
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

    /// Currently-joined member user ids for `room_id` — needed to know
    /// whose devices a freshly-created (or expanding) outbound Megolm
    /// session's key must be shared with. A dedicated GET rather than
    /// reading `m.room.member` state off `/sync`: warden doesn't track full
    /// room membership locally, and this is only called on a send into an
    /// encrypted room, not on every poll cycle.
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

    /// `POST /keys/query` for every device of each of `user_ids` — returned
    /// as a raw `json.Value` (shape:
    /// `{"device_keys":{"@user:server":{"DEVICEID":{"keys":{"curve25519:DEVICEID":"..."},...}}}}`)
    /// rather than a typed struct: `matrix/crypto.zig`'s
    /// `State.shareWithNewDevices` is the only caller, and it only ever
    /// walks this one shape once per send — not worth a dedicated type for
    /// a single call site, same reasoning as `getPowerLevels`.
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
    /// `device_id`, returning the claimed key's base64 value — needed to
    /// `olm.Session.createOutbound` a fresh per-device Olm session before a
    /// room key can be shared with a device warden has never talked to
    /// before. The claimed key's own signature isn't verified here (no
    /// device-verification UI exists at all yet — trust-on-first-use,
    /// same simplification scope already accepted for the rest of tonight's
    /// E2EE work).
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

    /// `PUT /sendToDevice/{eventType}/{txn}` addressed to a single
    /// `(user_id, device_id)` — used to Olm-encrypt and deliver an
    /// `m.room_key` to exactly the device that needs it. Matrix's
    /// `/sendToDevice` supports batching many recipients into one call, but
    /// warden's key-sharing loop (`matrix/crypto.zig`'s
    /// `State.shareWithNewDevices`) already needs a separate Olm-encrypt
    /// step per device anyway, so there's no batching win being left behind
    /// by sending one at a time here.
    pub fn sendToDevice(self: *Client, allocator: std.mem.Allocator, event_type: []const u8, user_id: []const u8, device_id: []const u8, content: json.Value) !void {
        const encoded_type = try encodeSegment(allocator, event_type);
        defer allocator.free(encoded_type);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/sendToDevice/{s}/{s}", .{ self.homeserver_url, encoded_type, txn });
        defer allocator.free(url);

        // Each `.deinit()` only frees this function's own wrapper map
        // storage, not `content` itself — that's the caller's, freed
        // separately (e.g. `crypto.zig`'s `sendVerificationEvent` owns
        // `content` via its own `parsed.deinit()`). Found live via a test
        // that — for the first time — actually exercised a real (if
        // failing) call through this function: previously nothing ever
        // freed these on *any* path, success included.
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

    /// Matrix's default moderator threshold — `m.room.power_levels`'
    /// `state_default` defaults to 50 when the room doesn't override it (a
    /// plain member defaults to `users_default`, normally 0).
    const moderator_power_level: i64 = 50;
    /// Below `events_default` (normally 0) so a muted user's own messages
    /// are rejected by the homeserver, mirroring Telegram's
    /// `restrictChatMember`.
    const muted_power_level: i64 = -1;
    const ordinary_power_level: i64 = 0;

    fn powerLevelsUrl(self: *Client, allocator: std.mem.Allocator, room_id: []const u8) ![]u8 {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        return std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/state/m.room.power_levels", .{ self.homeserver_url, encoded_room });
    }

    /// Fetches the room's power-levels state event as a raw `json.Value` —
    /// deliberately not a fully-typed struct: `events`/`notifications` and
    /// similar sub-objects have their own dynamic keys warden never reads,
    /// and a PUT of this state event must resend the *entire* content
    /// (Matrix state events are replace-whole-content, not a patch), so
    /// round-tripping through `json.Value` preserves whatever the room
    /// already had configured instead of silently dropping it.
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

    /// Matrix's power-level equivalent of Telegram's `promoteChatMember` —
    /// bumps `user_id` to the room's moderator threshold. Unlike
    /// Telegram's granular permission bits, Matrix power levels are a
    /// single scalar gating every privileged action at or below it, so
    /// there's no equivalent of withholding "can_promote_members"
    /// specifically — a promoted moderator here *can* set other users'
    /// power levels up to their own. `/promote` staying owner-gated (see
    /// `group_admin.zig`) is what actually prevents runaway
    /// self-promotion chains, not anything at this layer.
    pub fn promoteUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.setUserPowerLevel(allocator, room_id, user_id, moderator_power_level);
    }

    pub fn demoteUser(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, user_id: []const u8) !void {
        return self.setUserPowerLevel(allocator, room_id, user_id, ordinary_power_level);
    }

    /// True if `user_id`'s power level in `room_id` meets or exceeds the
    /// moderator threshold — the live source of truth `group_admin.zig`
    /// gates moderation commands on, same role as `telegram/client.zig`'s
    /// `isChatAdmin`.
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

    /// Adds `event_id` to the room's pinned list if it isn't already there
    /// — Matrix supports pinning several messages at once, unlike
    /// Telegram's single pinned message, but appending (not replacing) is
    /// the closer match to Telegram's `pinChatMessage` behavior from a
    /// command's point of view ("pin this one too").
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
    /// semantics when no specific message is targeted); otherwise removes
    /// just that one.
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
