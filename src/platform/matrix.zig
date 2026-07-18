const std = @import("std");
const Io = std.Io;

const iface = @import("interface.zig");
const raw = @import("../matrix/client.zig");
const types = @import("../matrix/types.zig");
const Identity = @import("../domain/identity.zig").Identity;

/// Matrix implementation of `platform.Connector`, backed by `/sync`
/// long-polling — same shape as `telegram.zig`'s `TelegramConnector`, just
/// against Matrix's Client-Server API instead of the Bot API.
///
/// Two deliberate simplifications versus Telegram parity, both documented
/// where they bite:
///   - End-to-end encrypted rooms aren't supported at all (see README) —
///     this only sends/receives in plaintext rooms.
///   - Every room is treated as a group for `is_group` purposes (see
///     `pollFn`) since distinguishing a real 1:1 room from a small group
///     needs an extra `m.direct` account-data lookup this doesn't do yet;
///     worst case the owner has to mention the bot in a Matrix DM the same
///     way they would in a group, rather than it engaging on every message
///     the way a Telegram DM does.
pub const MatrixConnector = struct {
    client: raw.Client,
    /// `/sync`'s `next_batch` token — Matrix's equivalent of Telegram's
    /// integer `offset`, just an opaque string instead.
    since: ?[]const u8 = null,
    /// The very first `/sync` (since = null) returns each joined room's
    /// recent history, not just what's new — discarded rather than
    /// processed (see `pollFn`) so a restart doesn't re-answer old
    /// messages. Sync calls after this one only ever contain genuinely new
    /// events.
    initial_sync_done: bool = false,
    self_user_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, homeserver_url: []const u8, access_token: []const u8) MatrixConnector {
        return .{ .client = raw.Client.init(allocator, io, homeserver_url, access_token) };
    }

    pub fn deinit(self: *MatrixConnector) void {
        if (self.since) |s| self.client.allocator.free(s);
        if (self.self_user_id) |s| self.client.allocator.free(s);
        self.client.deinit();
    }

    fn ensureSelfInfo(self: *MatrixConnector, allocator: std.mem.Allocator) void {
        if (self.self_user_id != null) return;
        var who = self.client.whoami(allocator) catch |err| {
            std.log.warn("matrix whoami failed (mention detection degraded until it succeeds): {t}", .{err});
            return;
        };
        defer who.deinit();
        if (who.value.user_id.len == 0) return;
        self.self_user_id = self.client.allocator.dupe(u8, who.value.user_id) catch null;
    }

    /// Content-based mention check, preferred over a plain-text scan: modern
    /// clients (Element and others) set this explicitly per MSC3952 rather
    /// than relying on the message body actually containing the mentioned
    /// user's id.
    fn mentionsViaContent(content: types.MessageContent, self_user_id: []const u8) bool {
        const mentions = content.@"m.mentions" orelse return false;
        for (mentions.user_ids) |id| {
            if (std.mem.eql(u8, id, self_user_id)) return true;
        }
        return false;
    }

    /// Fallback for clients that don't send `m.mentions`: a plain substring
    /// scan for the bot's own full user id ("@bot:server"). Less precise
    /// than Telegram's word-boundary `textMentions` (a false positive would
    /// need one user id to literally contain another's, which Matrix's
    /// `@localpart:server` shape makes very unlikely in practice), but
    /// simple and good enough absent a real client-side pill-rendering
    /// concept to parse.
    fn mentionsViaText(text: []const u8, self_user_id: []const u8) bool {
        if (self_user_id.len == 0) return false;
        return std.mem.indexOf(u8, text, self_user_id) != null;
    }

    /// True when `content` carries an `m.replace` relation — an edit of a
    /// previously-sent event, not a new message. Skipped entirely by
    /// `pollFn` so re-editing (e.g. another bot's live-updating message)
    /// never gets treated as fresh input, matching how `telegram.zig` never
    /// looks at `Update.edited_message` either.
    fn isEdit(content: types.MessageContent) bool {
        const rel = content.@"m.relates_to" orelse return false;
        return rel.rel_type != null and std.mem.eql(u8, rel.rel_type.?, "m.replace");
    }

    fn attachmentFromContent(allocator: std.mem.Allocator, content: types.MessageContent) !?iface.Attachment {
        const msgtype = content.msgtype orelse return null;
        const kind: iface.AttachmentKind = if (std.mem.eql(u8, msgtype, "m.image"))
            .photo
        else if (std.mem.eql(u8, msgtype, "m.file"))
            .document
        else if (std.mem.eql(u8, msgtype, "m.audio"))
            (if (content.@"org.matrix.msc3245.voice" != null) .voice else .audio)
        else if (std.mem.eql(u8, msgtype, "m.video"))
            .video
        else
            return null;

        const url = content.url orelse return null;
        return .{
            .kind = kind,
            .file_id = try allocator.dupe(u8, url),
            .file_name = if (content.filename) |n| try allocator.dupe(u8, n) else null,
            .mime_type = if (content.info) |i| (if (i.mimetype) |m| try allocator.dupe(u8, m) else null) else null,
        };
    }

    /// Best-effort display name absent a room-member/profile lookup: the
    /// localpart of "@localpart:server" ("localpart"), falling back to the
    /// full id if it's not shaped as expected.
    fn displayNameFromUserId(user_id: []const u8) []const u8 {
        const without_sigil = if (std.mem.startsWith(u8, user_id, "@")) user_id[1..] else user_id;
        const colon = std.mem.indexOfScalar(u8, without_sigil, ':') orelse return user_id;
        if (colon == 0) return user_id;
        return without_sigil[0..colon];
    }

    pub fn connector(self: *MatrixConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendPhoto = sendPhotoFn,
        .sendDocument = sendDocumentFn,
        .downloadFile = downloadFileFn,
        .sendMessageReturningId = sendMessageReturningIdFn,
        .editMessage = editMessageFn,
        .sendChoicePrompt = sendChoicePromptFn,
        .muteUser = muteUserFn,
        .unmuteUser = unmuteUserFn,
        .kickUser = kickUserFn,
        .banUser = banUserFn,
        .pinMessage = pinMessageFn,
        .unpinMessage = unpinMessageFn,
        .deleteMessage = deleteMessageFn,
        .isGroupAdmin = isGroupAdminFn,
        .selfId = selfIdFn,
        // `maxMessageLength` deliberately left null: Matrix caps total
        // event size (tens of KB including markup), not a small character
        // count — see `iface.Connector.VTable.maxMessageLength`'s doc
        // comment on why that means Matrix just doesn't contribute a floor
        // to the cross-platform minimum.
        // `selfUsername` left null: Matrix has no separate "username"
        // distinct from the user id the way Telegram does.
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .matrix;
    }

    fn selfIdFn(ptr: *anyopaque) ?[]const u8 {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.self_user_id;
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        self.ensureSelfInfo(allocator);

        var synced = try self.client.sync(allocator, self.since);
        defer synced.deinit();

        const next_batch = try self.client.allocator.dupe(u8, synced.value.next_batch);
        if (self.since) |old| self.client.allocator.free(old);
        self.since = next_batch;

        // Auto-accept invites unconditionally, including on the discarded
        // first sync — a Matrix bot has to explicitly join a room it's
        // invited to (unlike Telegram, where being added to a group needs
        // no bot-side action), and there's no reason to make that wait for
        // a second sync cycle.
        var invite_it = synced.value.rooms.invite.map.iterator();
        while (invite_it.next()) |entry| {
            self.client.joinRoom(allocator, entry.key_ptr.*) catch |err| {
                std.log.warn("matrix: failed to auto-join invited room {s}: {t}", .{ entry.key_ptr.*, err });
            };
        }

        if (!self.initial_sync_done) {
            self.initial_sync_done = true;
            return &.{};
        }

        var out: std.ArrayList(iface.Message) = .empty;
        var room_it = synced.value.rooms.join.map.iterator();
        while (room_it.next()) |room_entry| {
            const room_id = room_entry.key_ptr.*;
            for (room_entry.value_ptr.timeline.events) |event| {
                if (std.mem.eql(u8, event.type, "m.reaction")) {
                    // Don't treat our own seed reactions (see
                    // `sendChoicePromptFn`) as a user's pick.
                    if (self.self_user_id) |me| if (std.mem.eql(u8, event.sender, me)) continue;
                    const rel = event.content.@"m.relates_to" orelse continue;
                    const target_event_id = rel.event_id orelse continue;
                    const key = rel.key orelse continue;

                    const display_name = try allocator.dupe(u8, displayNameFromUserId(event.sender));
                    const identity = Identity{
                        .platform = .matrix,
                        .native_id = try allocator.dupe(u8, event.sender),
                        .display_name = display_name,
                        .is_bot = false,
                        .first_seen = event.origin_server_ts,
                        .last_seen = event.origin_server_ts,
                    };

                    try out.append(allocator, .{
                        .chat_id = try allocator.dupe(u8, room_id),
                        .message_id = try allocator.dupe(u8, target_event_id),
                        .user_id = try allocator.dupe(u8, event.sender),
                        .is_group = true,
                        .chat_type = "room",
                        .identity = identity,
                        .choice_picked = .{
                            .prompt_message_id = try allocator.dupe(u8, target_event_id),
                            .value = try allocator.dupe(u8, key),
                        },
                    });
                    continue;
                }
                if (!std.mem.eql(u8, event.type, "m.room.message")) continue;
                if (self.self_user_id) |me| if (std.mem.eql(u8, event.sender, me)) continue;
                if (isEdit(event.content)) continue;

                const chat_id = try allocator.dupe(u8, room_id);
                const message_id = try allocator.dupe(u8, event.event_id);
                const user_id = try allocator.dupe(u8, event.sender);
                const text = if (event.content.body) |b| try allocator.dupe(u8, b) else null;

                var reply_to_message_id: ?[]const u8 = null;
                var reply_to_user_id: ?[]const u8 = null;
                var reply_to_text: ?[]const u8 = null;
                var reply_to_is_me = false;
                if (event.content.@"m.relates_to") |rel| {
                    if (rel.@"m.in_reply_to") |in_reply_to| {
                        reply_to_message_id = try allocator.dupe(u8, in_reply_to.event_id);
                        if (self.client.getEvent(allocator, room_id, in_reply_to.event_id)) |parsed_reply| {
                            var reply_ev = parsed_reply;
                            defer reply_ev.deinit();
                            reply_to_user_id = try allocator.dupe(u8, reply_ev.value.sender);
                            if (reply_ev.value.content.body) |b| reply_to_text = try allocator.dupe(u8, b);
                            if (self.self_user_id) |me| reply_to_is_me = std.mem.eql(u8, reply_ev.value.sender, me);
                        } else |err| {
                            std.log.warn("matrix: failed to resolve reply target {s}: {t}", .{ in_reply_to.event_id, err });
                        }
                    }
                }

                const mentions_me = if (self.self_user_id) |me|
                    mentionsViaContent(event.content, me) or (if (text) |t| mentionsViaText(t, me) else false)
                else
                    false;

                const attachment = try attachmentFromContent(allocator, event.content);

                const display_name = try allocator.dupe(u8, displayNameFromUserId(event.sender));
                const identity = Identity{
                    .platform = .matrix,
                    .native_id = try allocator.dupe(u8, event.sender),
                    .display_name = display_name,
                    .is_bot = false,
                    .first_seen = event.origin_server_ts,
                    .last_seen = event.origin_server_ts,
                };

                try out.append(allocator, .{
                    .chat_id = chat_id,
                    .message_id = message_id,
                    .user_id = user_id,
                    .text = text,
                    .reply_to_message_id = reply_to_message_id,
                    .reply_to_user_id = reply_to_user_id,
                    .reply_to_text = reply_to_text,
                    // Every Matrix room is treated as a group — see this
                    // struct's doc comment.
                    .is_group = true,
                    .chat_type = "room",
                    .reply_to_is_me = reply_to_is_me,
                    .mentions_me = mentions_me,
                    .identity = identity,
                    .attachment = attachment,
                });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        self.client.sendMessage(allocator, chat_id, text, reply_to_message_id);
    }

    fn sendMessageReturningIdFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.sendMessageReturningId(allocator, chat_id, text, reply_to_message_id);
    }

    fn editMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.editMessage(allocator, chat_id, message_id, text);
    }

    /// Sends the prompt text (choices spelled out as "{emoji} — {label}",
    /// since a Matrix reaction alone carries no label) then self-reacts
    /// once per choice to seed tappable pills — Matrix's nearest equivalent
    /// of Telegram's inline-keyboard buttons. A single failed seed reaction
    /// is logged and skipped rather than aborting the whole prompt.
    fn sendChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const iface.Choice, reply_to_message_id: ?[]const u8) anyerror!?[]const u8 {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));

        var body_writer: Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();
        try body_writer.writer.print("{s}\n", .{text});
        for (choices) |c| try body_writer.writer.print("{s} — {s}\n", .{ c.emoji, c.label });

        const event_id = try self.client.sendMessageReturningId(allocator, chat_id, body_writer.writer.buffered(), reply_to_message_id);

        for (choices) |c| {
            self.client.sendReaction(allocator, chat_id, event_id, c.emoji) catch |err| {
                std.log.warn("matrix: failed to seed reaction {s} on {s}: {t}", .{ c.emoji, event_id, err });
            };
        }
        return event_id;
    }

    fn sendPhotoFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        self.client.sendPhoto(allocator, chat_id, image_bytes, caption);
    }

    fn sendDocumentFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        self.client.sendDocument(allocator, chat_id, file_bytes, file_name, caption);
    }

    fn downloadFileFn(ptr: *anyopaque, allocator: std.mem.Allocator, file_id: []const u8) anyerror![]u8 {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.downloadFile(allocator, file_id);
    }

    fn muteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) anyerror!void {
        _ = until_unix_time; // Matrix power levels have no expiry — matches `unmuteUser` being the only way back.
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.muteUser(allocator, chat_id, user_id);
    }

    fn unmuteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.unmuteUser(allocator, chat_id, user_id);
    }

    fn kickUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.kickUser(allocator, chat_id, user_id);
    }

    fn banUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.banUser(allocator, chat_id, user_id);
    }

    fn pinMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.pinMessage(allocator, chat_id, message_id);
    }

    fn unpinMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: ?[]const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.unpinMessage(allocator, chat_id, message_id);
    }

    fn deleteMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.redactMessage(allocator, chat_id, message_id);
    }

    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.isRoomModerator(allocator, chat_id, user_id);
    }
};

const testing = std.testing;

test "displayNameFromUserId extracts the localpart" {
    try testing.expectEqualStrings("alice", MatrixConnector.displayNameFromUserId("@alice:example.org"));
    // Malformed input (no sigil/colon) falls back to the whole string
    // rather than panicking on an unexpected shape.
    try testing.expectEqualStrings("alice", MatrixConnector.displayNameFromUserId("alice"));
}

test "mentionsViaContent matches only an explicit m.mentions entry" {
    const with_mention = types.MessageContent{ .@"m.mentions" = .{ .user_ids = &.{"@bot:server"} } };
    try testing.expect(MatrixConnector.mentionsViaContent(with_mention, "@bot:server"));
    try testing.expect(!MatrixConnector.mentionsViaContent(with_mention, "@other:server"));
    try testing.expect(!MatrixConnector.mentionsViaContent(.{}, "@bot:server"));
}

test "mentionsViaText finds the bot's full user id as a substring" {
    try testing.expect(MatrixConnector.mentionsViaText("hey @bot:server what's up", "@bot:server"));
    try testing.expect(!MatrixConnector.mentionsViaText("no mention here", "@bot:server"));
    try testing.expect(!MatrixConnector.mentionsViaText("anything", ""));
}

test "isEdit recognizes an m.replace relation and nothing else" {
    const edit = types.MessageContent{ .@"m.relates_to" = .{ .rel_type = "m.replace", .event_id = "$x" } };
    try testing.expect(MatrixConnector.isEdit(edit));

    const reply = types.MessageContent{ .@"m.relates_to" = .{ .@"m.in_reply_to" = .{ .event_id = "$x" } } };
    try testing.expect(!MatrixConnector.isEdit(reply));
    try testing.expect(!MatrixConnector.isEdit(.{}));
}

test "attachmentFromContent maps msgtype to AttachmentKind, distinguishing voice from audio" {
    const image = types.MessageContent{ .msgtype = "m.image", .url = "mxc://server/abc", .info = .{ .mimetype = "image/png" } };
    const att = (try MatrixConnector.attachmentFromContent(testing.allocator, image)).?;
    defer {
        testing.allocator.free(att.file_id);
        testing.allocator.free(att.mime_type.?);
    }
    try testing.expectEqual(iface.AttachmentKind.photo, att.kind);
    try testing.expectEqualStrings("mxc://server/abc", att.file_id);

    const voice = types.MessageContent{ .msgtype = "m.audio", .url = "mxc://server/def", .@"org.matrix.msc3245.voice" = .{ .object = .empty } };
    const voice_att = (try MatrixConnector.attachmentFromContent(testing.allocator, voice)).?;
    defer testing.allocator.free(voice_att.file_id);
    try testing.expectEqual(iface.AttachmentKind.voice, voice_att.kind);

    const audio = types.MessageContent{ .msgtype = "m.audio", .url = "mxc://server/ghi" };
    const audio_att = (try MatrixConnector.attachmentFromContent(testing.allocator, audio)).?;
    defer testing.allocator.free(audio_att.file_id);
    try testing.expectEqual(iface.AttachmentKind.audio, audio_att.kind);

    try testing.expectEqual(@as(?iface.Attachment, null), try MatrixConnector.attachmentFromContent(testing.allocator, .{ .msgtype = "m.text", .body = "hi" }));
}

test "MatrixConnector reports its own platform" {
    var conn = MatrixConnector.init(testing.allocator, testing.io, "https://example.org", "tok");
    defer conn.deinit();
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.matrix, c.platform());
}
