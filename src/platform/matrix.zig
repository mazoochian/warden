const std = @import("std");
const Io = std.Io;
const json = std.json;

const iface = @import("interface.zig");
const raw = @import("../matrix/client.zig");
const types = @import("../matrix/types.zig");
const matrix_crypto = @import("../matrix/crypto.zig");
const store_pool = @import("../store/pool.zig");
const Identity = @import("../domain/identity.zig").Identity;
const MatrixProfile = @import("../domain/matrix_profile.zig").MatrixProfile;

/// Matrix implementation of `platform.Connector`, backed by `/sync`
/// long-polling — same shape as `telegram.zig`'s `TelegramConnector`, just
/// against Matrix's Client-Server API instead of the Bot API.
///
/// Two deliberate simplifications versus Telegram parity, both documented
/// where they bite:
///   - E2E-encrypted rooms are supported for text messages (see
///     `sendEvent`/`matrix/crypto.zig`) but not media — `sendPhotoFn`/
///     `sendDocumentFn` always send unencrypted `m.image`/`m.file`
///     (encrypted media needs its own AES-CTR-over-the-file-bytes scheme
///     per the Matrix spec, separate from Olm/Megolm; not built yet).
///     Choice-prompt reactions are sent encrypted but can't be *received*
///     back as picks in an encrypted room yet (see `sendChoicePromptFn`'s
///     doc comment).
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
    /// Null when `WARDEN_MATRIX_PICKLE_KEY` isn't set — encryption stays
    /// inert (an `m.room.encrypted` event just can't be read, same as
    /// before this field existed). Set via `enableCrypto` once the DB pool
    /// is available (later than `init`, see `main.zig`'s startup sequence).
    crypto: ?matrix_crypto.State = null,
    /// Rooms confirmed E2E-encrypted, cached once and never evicted — a
    /// room can only ever turn encryption *on*, never back off, so a
    /// positive result never goes stale. Found live: without this,
    /// `sendEvent` called `client.isRoomEncrypted` fresh on every single
    /// send, and on this desktop's occasionally-flaky networking, that
    /// GET sometimes timed out — and the fallback for "couldn't check"
    /// was to send plaintext, silently downgrading a message into an
    /// *already-confirmed-encrypted* room the moment one HTTP call was
    /// slow. Caching a positive result means a transient blip after the
    /// first successful check can never cause that again for the same
    /// room. Guarded by `encrypted_rooms_mutex` since sends run
    /// concurrently across per-message tasks.
    encrypted_rooms: std.StringHashMapUnmanaged(void) = .empty,
    encrypted_rooms_mutex: Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: Io, homeserver_url: []const u8, access_token: []const u8) MatrixConnector {
        return .{ .client = raw.Client.init(allocator, io, homeserver_url, access_token) };
    }

    /// Loads (or creates+uploads) this device's Olm account and turns on
    /// decrypt/encrypt for `m.room.encrypted` events from here on. Called
    /// once at startup, after the DB pool exists — see `main.zig`.
    pub fn enableCrypto(self: *MatrixConnector, allocator: std.mem.Allocator, io: Io, pool: *store_pool.PgPool, pickle_key: []const u8) !void {
        self.crypto = try matrix_crypto.State.load(allocator, io, pool, pickle_key, &self.client);
    }

    pub fn deinit(self: *MatrixConnector) void {
        if (self.since) |s| self.client.allocator.free(s);
        if (self.self_user_id) |s| self.client.allocator.free(s);
        if (self.crypto) |*c| c.deinit();
        var room_it = self.encrypted_rooms.keyIterator();
        while (room_it.next()) |k| self.client.allocator.free(k.*);
        self.encrypted_rooms.deinit(self.client.allocator);
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
        .promoteUser = promoteUserFn,
        .demoteUser = demoteUserFn,
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

        // To-device events (room-key shares, etc.) are consumed by the
        // server the moment `/sync` returns them — unlike room timeline
        // history, there's no backlog to discard, so these are processed
        // every cycle, including the one whose *room* events get thrown
        // away below.
        if (self.crypto) |*crypto| {
            for (synced.value.to_device.events) |ev| {
                if (std.mem.eql(u8, ev.type, "m.room.encrypted")) {
                    var parsed = json.parseFromValue(types.OlmEncryptedContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse to-device m.room.encrypted content from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleToDeviceEvent(ev.sender, parsed.value);
                } else if (std.mem.eql(u8, ev.type, "m.room_key_request")) {
                    var parsed = json.parseFromValue(types.RoomKeyRequestContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.room_key_request from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleRoomKeyRequest(ev.sender, parsed.value);
                } else if (std.mem.eql(u8, ev.type, "m.key.verification.request")) {
                    var parsed = json.parseFromValue(types.VerificationRequestContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.key.verification.request from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleVerificationRequest(ev.sender, parsed.value);
                } else if (std.mem.eql(u8, ev.type, "m.key.verification.accept")) {
                    var parsed = json.parseFromValue(types.VerificationAcceptContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.key.verification.accept from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleVerificationAccept(ev.sender, parsed.value);
                } else if (std.mem.eql(u8, ev.type, "m.key.verification.key")) {
                    var parsed = json.parseFromValue(types.VerificationKeyContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.key.verification.key from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleVerificationKey(ev.sender, parsed.value);
                } else if (std.mem.eql(u8, ev.type, "m.key.verification.mac")) {
                    var parsed = json.parseFromValue(types.VerificationMacContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.key.verification.mac from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleVerificationMac(ev.sender, parsed.value);
                } else if (std.mem.eql(u8, ev.type, "m.key.verification.done")) {
                    var parsed = json.parseFromValue(types.VerificationDoneContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.key.verification.done from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleVerificationDone(ev.sender, parsed.value);
                } else if (std.mem.eql(u8, ev.type, "m.key.verification.cancel")) {
                    var parsed = json.parseFromValue(types.VerificationCancelContent, allocator, ev.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.key.verification.cancel from {s}: {t}", .{ ev.sender, err });
                        continue;
                    };
                    defer parsed.deinit();
                    crypto.handleVerificationCancel(ev.sender, parsed.value);
                }
            }

            if (synced.value.device_one_time_keys_count.map.get("signed_curve25519")) |count| {
                crypto.topUpOneTimeKeysIfNeeded(allocator, count) catch |err| {
                    std.log.warn("matrix e2ee: failed to top up one-time keys: {t}", .{err});
                };
            }
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
                    var parsed = json.parseFromValue(types.MessageContent, allocator, event.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
                    defer parsed.deinit();
                    const rel = parsed.value.@"m.relates_to" orelse continue;
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

                if (std.mem.eql(u8, event.type, "m.room.message")) {
                    if (self.self_user_id) |me| if (std.mem.eql(u8, event.sender, me)) continue;
                    var parsed = json.parseFromValue(types.MessageContent, allocator, event.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.room.message content for {s}: {t}", .{ event.event_id, err });
                        continue;
                    };
                    defer parsed.deinit();
                    if (isEdit(parsed.value)) continue;
                    try self.appendMessageEvent(allocator, &out, room_id, event, parsed.value);
                    continue;
                }

                if (std.mem.eql(u8, event.type, "m.room.encrypted")) {
                    if (self.self_user_id) |me| if (std.mem.eql(u8, event.sender, me)) continue;
                    const crypto = if (self.crypto) |*c| c else continue; // no pickle key configured — can't read this
                    var enc_parsed = json.parseFromValue(types.MegolmEncryptedContent, allocator, event.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                        std.log.warn("matrix: failed to parse m.room.encrypted content for {s}: {t}", .{ event.event_id, err });
                        continue;
                    };
                    defer enc_parsed.deinit();
                    var decrypted = (crypto.decryptRoomEvent(allocator, room_id, enc_parsed.value) catch |err| {
                        std.log.warn("matrix: failed to decrypt event {s} in {s}: {t}", .{ event.event_id, room_id, err });
                        continue;
                    }) orelse continue; // no room key on file yet — can't read this one
                    defer decrypted.deinit();
                    if (!std.mem.eql(u8, decrypted.value.type, "m.room.message")) continue;
                    if (isEdit(decrypted.value.content)) continue;
                    try self.appendMessageEvent(allocator, &out, room_id, event, decrypted.value.content);
                    continue;
                }
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Builds and appends the `iface.Message` for one `m.room.message`-
    /// shaped event — shared by the plaintext `m.room.message` and
    /// decrypted `m.room.encrypted` (Megolm) branches in `pollFn`, which
    /// differ only in *how* they arrived at `content`.
    fn appendMessageEvent(self: *MatrixConnector, allocator: std.mem.Allocator, out: *std.ArrayList(iface.Message), room_id: []const u8, event: types.RoomEvent, content: types.MessageContent) !void {
        const chat_id = try allocator.dupe(u8, room_id);
        const message_id = try allocator.dupe(u8, event.event_id);
        const user_id = try allocator.dupe(u8, event.sender);
        const text = if (content.body) |b| try allocator.dupe(u8, b) else null;

        var reply_to_message_id: ?[]const u8 = null;
        var reply_to_user_id: ?[]const u8 = null;
        var reply_to_text: ?[]const u8 = null;
        var reply_to_is_me = false;
        if (content.@"m.relates_to") |rel| {
            if (rel.@"m.in_reply_to") |in_reply_to| {
                reply_to_message_id = try allocator.dupe(u8, in_reply_to.event_id);
                if (self.client.getEvent(allocator, room_id, in_reply_to.event_id)) |parsed_reply| {
                    var reply_ev = parsed_reply;
                    defer reply_ev.deinit();
                    reply_to_user_id = try allocator.dupe(u8, reply_ev.value.sender);
                    // The reply target could itself be `m.room.encrypted`
                    // (an encrypted room's own replies point at other
                    // encrypted events) — decrypting a *reply target* for
                    // quoted-context purposes isn't built tonight, so this
                    // just degrades to no quoted text rather than erroring,
                    // same as any other content-shape mismatch here.
                    if (json.parseFromValue(types.MessageContent, allocator, reply_ev.value.content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |parsed_content| {
                        var pc = parsed_content;
                        defer pc.deinit();
                        if (pc.value.body) |b| reply_to_text = try allocator.dupe(u8, b);
                    } else |_| {}
                    if (self.self_user_id) |me| reply_to_is_me = std.mem.eql(u8, reply_ev.value.sender, me);
                } else |err| {
                    std.log.warn("matrix: failed to resolve reply target {s}: {t}", .{ in_reply_to.event_id, err });
                }
            }
        }

        const mentions_me = if (self.self_user_id) |me|
            mentionsViaContent(content, me) or (if (text) |t| mentionsViaText(t, me) else false)
        else
            false;

        const attachment = try attachmentFromContent(allocator, content);

        const display_name = try allocator.dupe(u8, displayNameFromUserId(event.sender));
        const identity = Identity{
            .platform = .matrix,
            .native_id = try allocator.dupe(u8, event.sender),
            .display_name = display_name,
            .is_bot = false,
            .first_seen = event.origin_server_ts,
            .last_seen = event.origin_server_ts,
        };
        // `avatar_url` stays null — see `MatrixProfile`'s doc comment on
        // why (no profile lookup implemented yet).
        const matrix_profile = MatrixProfile{
            .identity = identity,
            .homeserver = try allocator.dupe(u8, self.client.homeserver_url),
        };

        try out.append(allocator, .{
            .chat_id = chat_id,
            .message_id = message_id,
            .user_id = user_id,
            .text = text,
            .reply_to_message_id = reply_to_message_id,
            .reply_to_user_id = reply_to_user_id,
            .reply_to_text = reply_to_text,
            // Every Matrix room is treated as a group — see this struct's
            // doc comment.
            .is_group = true,
            .chat_type = "room",
            .reply_to_is_me = reply_to_is_me,
            .mentions_me = mentions_me,
            .identity = identity,
            .matrix_profile = matrix_profile,
            .attachment = attachment,
        });
    }

    /// Serializes `value` via `std.json.Stringify` into a freshly-allocated
    /// buffer — the safe way to build event content JSON (handles string
    /// escaping for user text), as opposed to hand-formatting with
    /// `std.fmt.allocPrint` the way `matrix/crypto.zig` does for its own
    /// library/server-generated (never user-controlled) tokens.
    fn buildJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
        var w: Io.Writer.Allocating = .init(allocator);
        defer w.deinit();
        try json.Stringify.value(value, .{}, &w.writer);
        return w.toOwnedSlice();
    }

    const EncryptedEventContent = struct {
        algorithm: []const u8 = "m.megolm.v1.aes-sha2",
        sender_key: []const u8,
        ciphertext: []const u8,
        session_id: []const u8,
        device_id: []const u8,
        /// Duplicated from the encrypted content when present, not just
        /// left inside it — found live 2026-07-20 (why the bot's edits
        /// were rendering as brand-new messages instead of replacing the
        /// placeholder): matrix-js-sdk's `MatrixEvent.isRelation`/
        /// `getRelation` read `m.relates_to` from `getWireContent()` —
        /// the event's *clear*, unencrypted top level — never from the
        /// decrypted payload, so a client can recognize an edit/reply/
        /// reaction without decrypting first (also what lets the server
        /// compute bundled aggregations for encrypted rooms at all).
        /// Their own comment: "Relation info is lifted out of the
        /// encrypted content when sent to encrypted rooms." Still present
        /// inside the encrypted content too, unchanged — this is a
        /// duplicate, not a replacement.
        @"m.relates_to": ?json.Value = null,
    };

    /// Checks (and caches, on a positive result) whether `room_id` is
    /// E2E-encrypted. A network failure while checking is treated as "not
    /// encrypted" **only for this one call** — it's deliberately never
    /// cached as a negative, so the very next send retries the real check
    /// instead of a single blip permanently disabling encryption for the
    /// room (see `encrypted_rooms`'s doc comment for the bug this fixes).
    fn isRoomEncryptedCached(self: *MatrixConnector, allocator: std.mem.Allocator, room_id: []const u8) bool {
        self.encrypted_rooms_mutex.lockUncancelable(self.client.io);
        const cached = self.encrypted_rooms.contains(room_id);
        self.encrypted_rooms_mutex.unlock(self.client.io);
        if (cached) return true;

        const encrypted = self.client.isRoomEncrypted(allocator, room_id) catch |err| {
            std.log.warn("matrix: failed to check encryption state of {s}, sending this one plaintext (will re-check next send): {t}", .{ room_id, err });
            return false;
        };
        if (encrypted) {
            self.encrypted_rooms_mutex.lockUncancelable(self.client.io);
            defer self.encrypted_rooms_mutex.unlock(self.client.io);
            if (self.client.allocator.dupe(u8, room_id)) |owned| {
                self.encrypted_rooms.put(self.client.allocator, owned, {}) catch self.client.allocator.free(owned);
            } else |_| {}
        }
        return encrypted;
    }

    /// Sends `content_json` (an already-serialized `m.room.message`/
    /// `m.reaction` content object) to `room_id`, transparently
    /// Megolm-encrypting it first when the room is E2E-encrypted and crypto
    /// is enabled. This is what fixes the "reply sent but not visible" bug:
    /// previously every send went out as a plaintext `m.room.message`
    /// regardless of the room's own encryption state, which the server
    /// accepted but compliant clients (Element included) won't render.
    /// Falls back to plaintext (logged) if the encryption state check or
    /// the encrypt itself fails — better a visible-but-unencrypted message
    /// than a silently dropped one, matching the room's plaintext behavior
    /// from before this existed.
    fn sendEvent(self: *MatrixConnector, allocator: std.mem.Allocator, room_id: []const u8, event_type: []const u8, content_json: []const u8) ![]const u8 {
        const crypto = if (self.crypto) |*c| c else return self.client.putRoomEvent(allocator, room_id, event_type, content_json);

        if (!self.isRoomEncryptedCached(allocator, room_id)) return self.client.putRoomEvent(allocator, room_id, event_type, content_json);

        // `room_id` is required in a Megolm-encrypted event's *plaintext*,
        // not just its outer envelope — an anti-replay check (found live
        // 2026-07-20): without it, matrix-js-sdk's decrypt rejects with
        // "the room id of the room key doesn't match the room id of the
        // decrypted event: expected <room>, got None", since a session key
        // could otherwise be replayed to forge a message into a different
        // room. `types.DecryptedRoomEventPayload` already parses this
        // field on the receive side; this was the one place that never
        // wrote it.
        const inner_event = try std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"content\":{s},\"room_id\":\"{s}\"}}", .{ event_type, content_json, room_id });
        defer allocator.free(inner_event);

        const enc = crypto.encryptForRoom(allocator, room_id, inner_event) catch |err| {
            std.log.err("matrix e2ee: failed to encrypt outgoing {s} for {s}, sending plaintext (recipients likely won't see it): {t}", .{ event_type, room_id, err });
            return self.client.putRoomEvent(allocator, room_id, event_type, content_json);
        };
        defer allocator.free(enc.ciphertext);
        defer allocator.free(enc.session_id);

        // See `EncryptedEventContent.m.relates_to`'s doc comment — clients
        // need this outside the encrypted blob to recognize edits/replies/
        // reactions at all.
        var parsed_content = try json.parseFromSlice(json.Value, allocator, content_json, .{});
        defer parsed_content.deinit();
        const relates_to: ?json.Value = if (parsed_content.value == .object) parsed_content.value.object.get("m.relates_to") else null;

        const encrypted_content = try buildJson(allocator, EncryptedEventContent{
            .sender_key = crypto.own_curve25519,
            .ciphertext = enc.ciphertext,
            .session_id = enc.session_id,
            .device_id = crypto.device_id,
            .@"m.relates_to" = relates_to,
        });
        defer allocator.free(encrypted_content);

        return self.client.putRoomEvent(allocator, room_id, "m.room.encrypted", encrypted_content);
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        const id = sendMessageReturningIdFn(ptr, allocator, chat_id, text, reply_to_message_id) catch |err| {
            std.log.err("matrix sendMessage failed: {t}", .{err});
            return;
        };
        allocator.free(id);
    }

    fn sendMessageReturningIdFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        const payload = try buildJson(allocator, raw.Client.MessagePayload{ .body = text, .@"m.relates_to" = raw.Client.replyRelation(reply_to_message_id) });
        defer allocator.free(payload);
        return self.sendEvent(allocator, chat_id, "m.room.message", payload);
    }

    fn editMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));

        // `body` is a plain-text fallback for clients that don't understand
        // `m.replace` — conventionally prefixed with "* " per MSC2676.
        const fallback_body = try std.fmt.allocPrint(allocator, "* {s}", .{text});
        defer allocator.free(fallback_body);

        const payload = try buildJson(allocator, raw.Client.EditPayload{
            .body = fallback_body,
            .@"m.new_content" = .{ .msgtype = "m.text", .body = text },
            .@"m.relates_to" = .{ .rel_type = "m.replace", .event_id = message_id },
        });
        defer allocator.free(payload);

        const id = try self.sendEvent(allocator, chat_id, "m.room.message", payload);
        allocator.free(id);
    }

    /// Sends the prompt text (choices spelled out as "{emoji} — {label}",
    /// since a Matrix reaction alone carries no label) then self-reacts
    /// once per choice to seed tappable pills — Matrix's nearest equivalent
    /// of Telegram's inline-keyboard buttons. A single failed seed reaction
    /// is logged and skipped rather than aborting the whole prompt.
    ///
    /// Both the prompt and the seed reactions go through `sendEvent`, so
    /// they're visible in encrypted rooms like any other outgoing message —
    /// but a user's own tap-to-pick reaction arriving back as an encrypted
    /// `m.reaction` isn't decrypted by `pollFn` yet (its `m.room.encrypted`
    /// branch only unwraps to `m.room.message`), so choice prompts aren't
    /// pickable in encrypted rooms yet. Known gap, not fixed tonight.
    fn sendChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const iface.Choice, reply_to_message_id: ?[]const u8) anyerror!?[]const u8 {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));

        var body_writer: Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();
        try body_writer.writer.print("{s}\n", .{text});
        for (choices) |c| try body_writer.writer.print("{s} — {s}\n", .{ c.emoji, c.label });

        const event_id = try sendMessageReturningIdFn(ptr, allocator, chat_id, body_writer.writer.buffered(), reply_to_message_id);

        for (choices) |c| {
            const reaction_payload = buildJson(allocator, raw.Client.ReactionPayload{
                .@"m.relates_to" = .{ .rel_type = "m.annotation", .event_id = event_id, .key = c.emoji },
            }) catch |err| {
                std.log.warn("matrix: failed to build reaction payload for {s} on {s}: {t}", .{ c.emoji, event_id, err });
                continue;
            };
            defer allocator.free(reaction_payload);
            const reaction_id = self.sendEvent(allocator, chat_id, "m.reaction", reaction_payload) catch |err| {
                std.log.warn("matrix: failed to seed reaction {s} on {s}: {t}", .{ c.emoji, event_id, err });
                continue;
            };
            allocator.free(reaction_id);
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

    fn promoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.promoteUser(allocator, chat_id, user_id);
    }

    fn demoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *MatrixConnector = @ptrCast(@alignCast(ptr));
        return self.client.demoteUser(allocator, chat_id, user_id);
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
