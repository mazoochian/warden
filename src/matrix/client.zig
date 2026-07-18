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
    txn_counter: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, io: Io, homeserver_url: []const u8, access_token: []const u8) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
            .homeserver_url = homeserver_url,
            .access_token = access_token,
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

    const MessagePayload = struct {
        msgtype: []const u8 = "m.text",
        body: []const u8,
        @"m.relates_to": ?types.RelatesTo = null,
    };

    fn replyRelation(reply_to_event_id: ?[]const u8) ?types.RelatesTo {
        const id = reply_to_event_id orelse return null;
        return .{ .@"m.in_reply_to" = .{ .event_id = id } };
    }

    /// Fire-and-forget send, matching `telegram/client.zig`'s `sendMessage`
    /// — logs failures rather than propagating, since a failed reply
    /// shouldn't crash the poll loop.
    pub fn sendMessage(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, text: []const u8, reply_to_event_id: ?[]const u8) void {
        _ = self.sendMessageReturningId(allocator, room_id, text, reply_to_event_id) catch |err| {
            std.log.err("matrix sendMessage failed: {t}", .{err});
        };
    }

    /// Like `sendMessage`, but returns the sent event id (needed to later
    /// `editMessage` it — the "thinking" placeholder / progressive-answer
    /// flow, same as Telegram's).
    pub fn sendMessageReturningId(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, text: []const u8, reply_to_event_id: ?[]const u8) ![]const u8 {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/send/m.room.message/{s}", .{ self.homeserver_url, encoded_room, txn });
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(MessagePayload{ .body = text, .@"m.relates_to" = replyRelation(reply_to_event_id) }, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);

        var parsed = try json.parseFromSlice(types.SendEventResponse, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();
        return allocator.dupe(u8, parsed.value.event_id);
    }

    const EditPayload = struct {
        msgtype: []const u8 = "m.text",
        body: []const u8,
        @"m.new_content": types.NewContent,
        @"m.relates_to": types.RelatesTo,
    };

    /// Replaces a previously-sent message's displayed text via `m.replace`
    /// (MSC2676) — same "thinking" placeholder / progressive-answer role as
    /// `telegram/client.zig`'s `editMessage`. Unlike Telegram, Matrix has no
    /// "not modified" rejection for an edit identical to the current
    /// content, so callers don't need Telegram's dedupe workaround here.
    pub fn editMessage(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_id: []const u8, text: []const u8) !void {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/send/m.room.message/{s}", .{ self.homeserver_url, encoded_room, txn });
        defer allocator.free(url);

        // `body` is a plain-text fallback for clients that don't understand
        // `m.replace` — conventionally prefixed with "* " per MSC2676.
        const fallback_body = try std.fmt.allocPrint(allocator, "* {s}", .{text});
        defer allocator.free(fallback_body);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(EditPayload{
            .body = fallback_body,
            .@"m.new_content" = .{ .msgtype = "m.text", .body = text },
            .@"m.relates_to" = .{ .rel_type = "m.replace", .event_id = event_id },
        }, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
    }

    const ReactionPayload = struct {
        @"m.relates_to": types.RelatesTo,
    };

    /// Reacts to `event_id` with `key` (an emoji) — used to self-seed
    /// tappable "pills" on the bot's own choice-prompt message (see
    /// `MatrixConnector.sendChoicePromptFn`), and by users tapping one to
    /// pick a choice (read back via `pollFn`'s `m.reaction` handling).
    /// Fire-and-forget like `sendMessage`.
    pub fn sendReaction(self: *Client, allocator: std.mem.Allocator, room_id: []const u8, event_id: []const u8, key: []const u8) !void {
        const encoded_room = try encodeSegment(allocator, room_id);
        defer allocator.free(encoded_room);
        const txn = try self.nextTxnId(allocator);
        defer allocator.free(txn);
        const url = try std.fmt.allocPrint(allocator, "{s}/_matrix/client/v3/rooms/{s}/send/m.reaction/{s}", .{ self.homeserver_url, encoded_room, txn });
        defer allocator.free(url);

        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try json.Stringify.value(ReactionPayload{
            .@"m.relates_to" = .{ .rel_type = "m.annotation", .event_id = event_id, .key = key },
        }, .{}, &payload_writer.writer);
        const payload = payload_writer.writer.buffered();

        const auth = try self.authHeader(allocator);
        defer allocator.free(auth.value);
        const body = try http_util.putJson(&self.http_client, allocator, url, &.{auth}, payload);
        defer allocator.free(body);
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
