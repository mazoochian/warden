const std = @import("std");
const Identity = @import("../domain/identity.zig").Identity;
const TelegramProfile = @import("../domain/telegram_profile.zig").TelegramProfile;
const MatrixProfile = @import("../domain/matrix_profile.zig").MatrixProfile;
const XmppProfile = @import("../domain/xmpp_profile.zig").XmppProfile;
const InstagramProfile = @import("../domain/instagram_profile.zig").InstagramProfile;

/// Chat platforms Warden can be wired up to. `.telegram`/`.matrix`/`.xmpp`
/// have implementations; `.discord`/`.whatsapp` exist so config/auth code
/// can already be written against a stable enum instead of raw strings.
///
/// `.telegram_user` is deliberately distinct from `.telegram`, not a mode
/// flag on it: they're different protocols entirely (MTProto via TDLib vs.
/// the HTTPS Bot API), with their own connector, own credentials (TDLib
/// api_id/api_hash vs. a bot token), and their own session lifecycle
/// (interactive phone/code/2FA login vs. a static token). The two can be
/// connected at once — the bot account and the owner's personal account
/// are different Telegram users occupying the same `Platform` *family* but
/// not the same identity. This is exactly why `chats`/`identities` are
/// keyed by `(platform, native_id)`, not bare native id (see
/// `store/chats.zig`'s `upsertChat`) — a `.telegram_user` chat/identity
/// with the same native numeric id as a `.telegram` one is a distinct row,
/// never collides.
///
/// `.instagram` is the same "personal-account connector" shape as
/// `.telegram_user`: it logs into the owner's own Instagram account
/// (private mobile-app API, interactive login) rather than holding a
/// platform-issued bot credential. Unlike `.telegram_user`, Instagram has
/// no separate bot-account concept at all — the connector's identity IS
/// the owner's account — so `instagram/auth.zig`'s login flow is the only
/// way this platform ever gets configured, there's no static-token path.
pub const Platform = enum {
    telegram,
    telegram_user,
    matrix,
    xmpp,
    discord,
    whatsapp,
    instagram,
};

pub const AttachmentKind = enum { photo, document, voice, audio, video };

/// Bit flags for the granular per-member permission model (`/permission`,
/// ROADMAP.md's Phase 24) — one bit per grammar letter
/// (`+rwpvfmodslaeti`/`-<letters>`). Lives here rather than in
/// `store/member_permissions.zig` so both the store layer (bitmask
/// persistence) and each platform's own enforcement code can share one
/// definition without the platform layer depending on the store layer for
/// a value type — same reasoning as `Platform` itself living here and
/// already being imported by store files (see `store/chat_members.zig`).
pub const MemberPermission = struct {
    pub const read: u32 = 1 << 0;
    pub const write: u32 = 1 << 1;
    pub const photos: u32 = 1 << 2;
    pub const videos: u32 = 1 << 3;
    pub const file: u32 = 1 << 4;
    pub const music: u32 = 1 << 5;
    pub const voice: u32 = 1 << 6;
    pub const video_messages: u32 = 1 << 7;
    pub const stickers: u32 = 1 << 8;
    pub const polls: u32 = 1 << 9;
    pub const embed_links: u32 = 1 << 10;
    pub const reactions: u32 = 1 << 11;
    pub const edit_tags: u32 = 1 << 12;
    pub const change_info: u32 = 1 << 13;

    /// Every bit set — the implicit bitmask a member has until `/permission`
    /// ever restricts them, and what a timed grant/revoke reverts to once
    /// it expires (see `store/member_permissions.zig`'s `getBits`/`revert`).
    pub const all: u32 = read | write | photos | videos | file | music | voice |
        video_messages | stickers | polls | embed_links | reactions | edit_tags | change_info;

    /// Bits that have a real, enforceable Telegram Bot API equivalent via
    /// `restrictChatMember`'s `ChatPermissions` object — the complement
    /// (`read`/`reactions`/`edit_tags`) is stored for cross-platform intent
    /// but never actually restricts anything on Telegram (no Bot API field
    /// exists for "can't read"/"can't react"/"can't edit own tag"). See
    /// `platform/telegram.zig`'s `restrictChatMemberPermissionsFn`.
    pub const telegram_enforceable: u32 = write | photos | videos | file | music | voice |
        video_messages | stickers | polls | embed_links | change_info;

    /// Maps a single grammar letter to its bit, or `null` for an
    /// unrecognized one — the source of truth `member_permissions.
    /// parseChange` (parsing `+`/`-<letters>`) keys off of.
    pub fn bitForLetter(c: u8) ?u32 {
        return switch (c) {
            'r' => read,
            'w' => write,
            'p' => photos,
            'v' => videos,
            'f' => file,
            'm' => music,
            'o' => voice,
            'd' => video_messages,
            's' => stickers,
            'l' => polls,
            'e' => embed_links,
            'a' => reactions,
            't' => edit_tags,
            'i' => change_info,
            else => null,
        };
    }
};

/// One entry in the bot's advertised command menu (Telegram's `/`
/// autocomplete) — see `Connector.VTable.setCommands`.
pub const CommandSpec = struct {
    /// Bare command name, no leading slash (e.g. "ping", not "/ping").
    name: []const u8,
    description: []const u8,
};

/// Metadata for an inbound file/media attachment — deliberately just enough
/// to *locate* the bytes (via `Connector.downloadFile`), not the bytes
/// themselves: not every message with an attachment needs it downloaded
/// (e.g. one the user never asks the bot to act on), so downloading is done
/// lazily by `main.zig` only when a message is actually addressed to the
/// bot.
pub const Attachment = struct {
    kind: AttachmentKind,
    /// Platform-native id `Connector.downloadFile` resolves to bytes.
    file_id: []const u8,
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,

    pub fn dupe(self: Attachment, allocator: std.mem.Allocator) !Attachment {
        return .{
            .kind = self.kind,
            .file_id = try allocator.dupe(u8, self.file_id),
            .file_name = if (self.file_name) |s| try allocator.dupe(u8, s) else null,
            .mime_type = if (self.mime_type) |s| try allocator.dupe(u8, s) else null,
        };
    }
};

/// One offered option in an interactive choice prompt — Telegram inline
/// button / Matrix seeded reaction (see `Connector.VTable.sendChoicePrompt`).
/// `emoji` doubles as the Matrix reaction key, so it must be an actual
/// emoji, not arbitrary text. `label` is Telegram's button text
/// (`"{emoji} {label}"`) and, since a Matrix reaction alone carries no
/// label, is also spelled out in the prompt's body text there. `value` is
/// the opaque result the application gets back via `ChoicePicked` — see
/// that type's doc comment for why its meaning differs by platform.
pub const Choice = struct {
    emoji: []const u8,
    label: []const u8,
    value: []const u8,
};

/// A user picking one of a previous `sendChoicePrompt`'s options — carried
/// on `Message.choice_picked` so a button press/reaction flows through the
/// existing poll -> per-task-spawn -> handleMessage pipeline like any other
/// message, rather than a parallel notification path.
///
/// `value`'s meaning is platform-dependent and deliberately left
/// unresolved by the connector: Telegram's `callback_data` is a real
/// opaque channel, so `value` there already IS the application's chosen
/// `Choice.value`. Matrix reactions have no such channel — `value` there
/// is the raw emoji `key` the user reacted with, and the application (not
/// the connector, which has no visibility into app-level pending state)
/// must map it back to a `Choice.value` using the same choice list it
/// built when it sent that prompt (see `features/convert_flow.zig`'s
/// `resolveTargetFormat`).
pub const ChoicePicked = struct {
    /// Native id of the message the choices were originally posted on —
    /// scopes the picked value to one specific pending interaction, since
    /// more than one prompt could be in flight in the same chat.
    prompt_message_id: []const u8,
    value: []const u8,
};

/// A platform-agnostic inbound message. Adapters translate their native
/// wire format into this shape. IDs are kept as strings since native ID
/// types vary wildly (Telegram: i64, Matrix: "!room:server"/"@user:server",
/// Discord: u64 snowflake, WhatsApp: phone number) — adapters own the
/// parsing/formatting round trip to their own native type.
pub const Message = struct {
    chat_id: []const u8,
    /// This message's own id — pass back to `sendMessage`'s
    /// `reply_to_message_id` so the bot's answer shows up threaded under
    /// the message that prompted it, rather than as a bare new message.
    message_id: ?[]const u8 = null,
    user_id: []const u8,
    username: ?[]const u8 = null,
    text: ?[]const u8 = null,
    /// Populated when this message is a direct reply to another one — the
    /// primary way group-admin commands target a user/message (e.g. reply
    /// to someone's message with "/ban" rather than needing to resolve a
    /// username or user id by hand).
    reply_to_message_id: ?[]const u8 = null,
    reply_to_user_id: ?[]const u8 = null,
    reply_to_username: ?[]const u8 = null,
    /// Text of the message being replied to, when the platform provides it.
    /// Lets a reply to one of the bot's own answers carry the context of
    /// what it's following up on.
    reply_to_text: ?[]const u8 = null,
    /// True in a multi-user chat, false in a 1:1 conversation with the bot.
    /// Drives the "don't answer everything in a group" gating: DMs always
    /// get a response.
    is_group: bool = false,
    /// Platform-native chat type string (Telegram: "private"/"group"/
    /// "supergroup"/"channel") and display title, when known — persisted
    /// into the `chats` table. Both null when the platform doesn't surface
    /// this (or hasn't changed since last seen; `chats.upsertChat` preserves
    /// the existing stored value in that case rather than clobbering it).
    chat_type: ?[]const u8 = null,
    chat_title: ?[]const u8 = null,
    /// True when this message is a direct reply to something the bot sent.
    /// Set by the adapter, which knows its own platform identity.
    reply_to_is_me: bool = false,
    /// True when the message addresses the bot by name in the platform's
    /// native way (e.g. "@botusername" on Telegram). Set by the adapter.
    mentions_me: bool = false,
    /// Ancestor identity for this message's sender — platform-neutral
    /// (platform/native_id/display_name/username/is_bot/last_seen).
    /// Populated by every connector (Telegram now; Matrix/XMPP once their
    /// connectors are real). Kept alongside `user_id`/`username` above
    /// rather than replacing them, to avoid a wholesale call-site rewrite.
    identity: ?Identity = null,
    /// Telegram-specific extension of `identity` (is_premium, language_code,
    /// last_name, ...) — populated only by the Telegram connector, null for
    /// every other platform. `identity` above stays the source of truth for
    /// the shared fields; this just carries what Telegram's `User` object
    /// has beyond them, for persisting into `telegram_profiles`.
    telegram_profile: ?TelegramProfile = null,
    /// Matrix-specific extension of `identity` (homeserver, avatar_url) —
    /// populated only by the Matrix connector, null for every other
    /// platform. Same reasoning as `telegram_profile` above.
    matrix_profile: ?MatrixProfile = null,
    /// XMPP-specific extension of `identity` (jid_resource) — populated
    /// only by the XMPP connector, null for every other platform. Same
    /// reasoning as `telegram_profile`/`matrix_profile` above.
    xmpp_profile: ?XmppProfile = null,
    /// Instagram-specific extension of `identity` (full_name, is_private)
    /// — populated only by the Instagram connector, null for every other
    /// platform. Same reasoning as `telegram_profile`/`matrix_profile`/
    /// `xmpp_profile` above.
    instagram_profile: ?InstagramProfile = null,
    /// Set when this message carries a photo/document/voice/audio/video —
    /// see `Attachment`'s doc comment on why only metadata lives here.
    attachment: ?Attachment = null,
    /// Set when this "message" is actually a button press / reaction pick
    /// on a previous `sendChoicePrompt` — see `ChoicePicked`'s doc comment.
    /// A message with this set typically has no `text`/`attachment` of its
    /// own, so callers that check this must do so before any "text or
    /// attachment required" bail-out.
    choice_picked: ?ChoicePicked = null,
    /// Other identities this one message happened to reveal, beyond its own
    /// sender — e.g. a reply target, a name-mention with no `@username`
    /// (Telegram's `text_mention` entity), or a join/leave service message's
    /// subject. `main.zig` upserts each into `chat_members` alongside the
    /// sender, so the chat's known-participant roster (see the
    /// `find_chat_member` tool) grows from more than just who's actually
    /// spoken. Empty for platforms/messages that reveal nothing extra.
    observed_users: []const Identity = &.{},
    /// Subset of a join service message's subjects that should trigger a
    /// welcome message (ROADMAP.md's Phase 16) — distinct from
    /// `observed_users` above, which already includes the same identities
    /// for roster-registration purposes but conflates joins with replies/
    /// mentions/leaves, giving `main.zig` no reliable way to tell "someone
    /// just joined" apart from those. Excludes the bot's own account
    /// joining/being added (not a "welcome a new member" event). Empty for
    /// platforms/messages that aren't a join.
    joined_users: []const Identity = &.{},
    /// Synthetic signal (not a real chat message) meaning the bot's own
    /// membership in `chat_id` just ended — left, kicked/banned, or the
    /// chat itself was deleted; every case is handled identically since
    /// they're indistinguishable in effect (see each connector's own
    /// doc comment for how it detects this). `main.zig`'s
    /// `processMessageTask` checks this before anything else and calls
    /// `store/chats.zig`'s `markLeft` instead of normal message handling.
    chat_left: bool = false,
    /// Synthetic signal for Telegram's basic-group -> supergroup upgrade
    /// (Telegram mints a brand-new chat id for the same real-world group
    /// and sends this on a service message) — `chat_id` is the OLD native
    /// id, this field is the NEW one. `main.zig` renames the existing
    /// `chats` row in place (`store/chats.zig`'s `renameNativeChatId`)
    /// instead of letting a second row get created under the new id, which
    /// was the actual cause of "duplicate" chats. Null on every other
    /// platform/message.
    migrated_to_native_chat_id: ?[]const u8 = null,
    /// Synthetic signal meaning "upsert the chat row (`chat_id`/`chat_type`/
    /// `chat_title` above) and stop — this isn't real conversational
    /// content." Set for a Telegram channel post (channels have no `from`
    /// user and never produce ordinary `message` updates, only these) and
    /// for the bot being newly added to/promoted in a chat via
    /// `my_chat_member` (see `platform/telegram.zig`'s
    /// `chatJoinedMessageFromUpdate`) — the latter matters most for
    /// channels, which otherwise wouldn't become a `chats` row until their
    /// first post, which may never come if the channel is post-only for
    /// other admins. `main.zig`'s `processMessageTask` checks this right
    /// after its unconditional `upsertChat` call and returns early, same
    /// shape as `chat_left`/`migrated_to_native_chat_id` above.
    chat_ingest_only: bool = false,

    /// Deep-copies every string field into `allocator`. The poll loop
    /// spawns one concurrent task per message, each owning its own arena;
    /// this detaches a message from the short-lived arena `poll()` used to
    /// build the batch, which gets freed as soon as every message in it
    /// has been handed off to its own task.
    pub fn dupe(self: Message, allocator: std.mem.Allocator) !Message {
        return .{
            .chat_id = try allocator.dupe(u8, self.chat_id),
            .message_id = if (self.message_id) |s| try allocator.dupe(u8, s) else null,
            .user_id = try allocator.dupe(u8, self.user_id),
            .username = if (self.username) |s| try allocator.dupe(u8, s) else null,
            .text = if (self.text) |s| try allocator.dupe(u8, s) else null,
            .reply_to_message_id = if (self.reply_to_message_id) |s| try allocator.dupe(u8, s) else null,
            .reply_to_user_id = if (self.reply_to_user_id) |s| try allocator.dupe(u8, s) else null,
            .reply_to_username = if (self.reply_to_username) |s| try allocator.dupe(u8, s) else null,
            .reply_to_text = if (self.reply_to_text) |s| try allocator.dupe(u8, s) else null,
            .is_group = self.is_group,
            .chat_type = if (self.chat_type) |s| try allocator.dupe(u8, s) else null,
            .chat_title = if (self.chat_title) |s| try allocator.dupe(u8, s) else null,
            .reply_to_is_me = self.reply_to_is_me,
            .mentions_me = self.mentions_me,
            .identity = if (self.identity) |id| try id.dupe(allocator) else null,
            .telegram_profile = if (self.telegram_profile) |p| try p.dupe(allocator) else null,
            .matrix_profile = if (self.matrix_profile) |p| try p.dupe(allocator) else null,
            .xmpp_profile = if (self.xmpp_profile) |p| try p.dupe(allocator) else null,
            .instagram_profile = if (self.instagram_profile) |p| try p.dupe(allocator) else null,
            .attachment = if (self.attachment) |att| try att.dupe(allocator) else null,
            .choice_picked = if (self.choice_picked) |cp| .{
                .prompt_message_id = try allocator.dupe(u8, cp.prompt_message_id),
                .value = try allocator.dupe(u8, cp.value),
            } else null,
            .observed_users = blk: {
                if (self.observed_users.len == 0) break :blk &.{};
                const out = try allocator.alloc(Identity, self.observed_users.len);
                for (self.observed_users, 0..) |id, i| out[i] = try id.dupe(allocator);
                break :blk out;
            },
            .joined_users = blk: {
                if (self.joined_users.len == 0) break :blk &.{};
                const out = try allocator.alloc(Identity, self.joined_users.len);
                for (self.joined_users, 0..) |id, i| out[i] = try id.dupe(allocator);
                break :blk out;
            },
            .chat_left = self.chat_left,
            .migrated_to_native_chat_id = if (self.migrated_to_native_chat_id) |s| try allocator.dupe(u8, s) else null,
            .chat_ingest_only = self.chat_ingest_only,
        };
    }
};

/// Vtable-based connector interface, one implementation per platform.
/// Modeled after `std.mem.Allocator`/`std.Io`'s ptr+vtable pattern.
///
/// Admin actions are optional (default to `null`): a platform that can't or
/// doesn't yet implement one (e.g. a future Matrix connector without
/// moderation power levels wired up) simply reports `error.Unsupported`
/// rather than every connector needing a stub implementation.
pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        platform: *const fn (ptr: *anyopaque) Platform,
        /// Blocks until at least one message arrives or a poll cycle times
        /// out (returning an empty slice is fine). Allocates out of
        /// `allocator`, which callers are expected to reset per cycle
        /// (e.g. an arena).
        poll: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Message,
        /// Best-effort send: adapters log failures themselves rather than
        /// propagating them, since a failed reply shouldn't crash the poll
        /// loop. `reply_to_message_id`, when set, threads the message as a
        /// platform-native reply to that message id instead of a bare new
        /// message; adapters that don't support it may ignore it.
        sendMessage: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void,
        /// Sends an image (e.g. a rendered word cloud/diagram). Optional
        /// since not every platform this bot might target necessarily
        /// supports rich media the same way.
        sendPhoto: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void = null,
        /// Sends an arbitrary file as a document attachment — the fallback
        /// for text too long for this platform's `maxMessageLength`, and
        /// how `convert_file` delivers a converted file. Optional like
        /// `sendPhoto`, with the same "unsupported platform" fallback.
        sendDocument: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void = null,
        /// Sends a native, inline-playable video message (as opposed to
        /// `sendDocument`'s generic file attachment) — `video_download.zig`'s
        /// lossy delivery path (ROADMAP.md's Phase 25 follow-up). Optional
        /// like `sendPhoto`/`sendDocument`, same "unsupported platform"
        /// fallback; the only current producer always emits `.mp4` bytes, so
        /// there's no mime-type parameter here (add one if a second producer
        /// ever needs it).
        sendVideo: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, video_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void = null,
        /// Sends a native poll (ROADMAP.md's Phase 16), if this platform has
        /// the concept. Fire-and-forget like `sendPhoto`/`sendDocument` --
        /// the wrapper method below falls back to a plain text listing of
        /// the question/options when unsupported.
        sendPoll: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, question: []const u8, options: []const []const u8, reply_to_message_id: ?[]const u8) void = null,
        /// This platform's hard limit on a single text message's length, in
        /// bytes, if it enforces one. Optional/null when a platform has no
        /// small fixed limit (e.g. Matrix/XMPP cap on total event/stanza
        /// *size*, tens of KB including markup, not a small character
        /// count) — `effectiveMaxMessageLength` in main.zig takes the
        /// minimum across every connector that does declare one.
        maxMessageLength: ?*const fn (ptr: *anyopaque) usize = null,
        /// Downloads a previously-seen attachment's bytes by its
        /// platform-native file id (see `Message.Attachment`). Optional:
        /// a platform without inbound-file support just doesn't get one.
        downloadFile: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, file_id: []const u8) anyerror![]u8 = null,
        /// Like `sendMessage`, but returns the id of the sent message so it
        /// can later be `editMessage`d — the "thinking" placeholder /
        /// progressive-answer flow. Optional: a platform without a message-
        /// editing concept just doesn't get animated replies (`editMessage`
        /// null too), falling back to the plain send-when-done behavior.
        sendMessageReturningId: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 = null,
        /// Replaces the text of a previously-sent message.
        editMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void = null,

        /// Sends an interactive choice prompt — Telegram inline-keyboard
        /// buttons, Matrix self-seeded reactions (see the two connectors'
        /// implementations). Returns the prompt message's native id (to
        /// later match against `ChoicePicked.prompt_message_id`), or null
        /// if the platform doesn't support the concept — see the wrapper
        /// method's plain-text fallback for that case.
        sendChoicePrompt: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const Choice, reply_to_message_id: ?[]const u8) anyerror!?[]const u8 = null,

        /// Replaces a previously-sent `sendChoicePrompt` message's text AND
        /// buttons together, in place — the mechanism `features/menu.zig`
        /// uses to navigate a multi-level menu by editing one living
        /// message instead of sending a new one per level. Optional: a
        /// connector without it (or without any keyboard-edit primitive on
        /// its platform) reports `error.Unsupported`, and the caller falls
        /// back to sending a fresh `sendChoicePrompt` instead.
        editChoicePrompt: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8, choices: []const Choice) anyerror!void = null,

        /// Restricts a user from sending messages until `until_unix_time`
        /// (0 = forever, until explicitly unmuted).
        muteUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) anyerror!void = null,
        unmuteUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        /// Removes a user but allows them back in (ban immediately followed
        /// by unban, Telegram's standard "kick" idiom).
        kickUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        /// Permanent removal — stays banned until explicitly unbanned.
        banUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        /// Grants `user_id` real, platform-level admin/moderator standing
        /// in `chat_id` — not a warden-internal flag. Telegram:
        /// `promoteChatMember` with a moderate permission set (no
        /// `can_promote_members`, so a promoted admin can't themselves
        /// mint further admins through the bot). Matrix: room power level
        /// bumped to moderator. Optional: a platform without a granular
        /// admin concept (e.g. XMPP MUC, per this project's current
        /// scope) reports `error.Unsupported`.
        promoteUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        /// Reverses `promoteUser` — back to an ordinary member.
        demoteUser: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void = null,
        /// Applies the granular `/permission` bitmask (`MemberPermission`)
        /// to `user_id`, best-effort per platform — see
        /// `MemberPermission.telegram_enforceable`'s doc comment for exactly
        /// which bits a given platform can actually restrict.
        /// `until_unix_time` mirrors `muteUser` (0 = no expiry at the
        /// platform level; warden's own scheduler is what re-applies the
        /// default bitmask once `store/member_permissions.zig`'s
        /// `expires_at` lapses, same "no native expiry" situation `muteUser`
        /// documents for Matrix). Optional: a platform with no granular
        /// permission concept at all (XMPP) reports `error.Unsupported` —
        /// the bitmask is still stored, just never enforced there.
        restrictChatMemberPermissions: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, permission_bits: u32, until_unix_time: i64) anyerror!void = null,
        /// Sets `user_id`'s custom admin title (`/tag`) — Telegram's
        /// `setChatAdministratorCustomTitle`, which only works on chat
        /// *administrators* (a Telegram Bot API limitation, not a bug —
        /// callers should surface that distinctly from a generic failure).
        /// An empty `title` clears it. Optional: no equivalent primitive on
        /// Matrix/XMPP, reports `error.Unsupported`.
        setChatAdminTitle: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, title: []const u8) anyerror!void = null,
        /// `/title` (ROADMAP.md's Phase 22). Optional: no equivalent on
        /// XMPP.
        setChatTitle: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, title: []const u8) anyerror!void = null,
        /// `/description`. Optional: no equivalent on XMPP. An empty
        /// `description` clears it.
        setChatDescription: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, description: []const u8) anyerror!void = null,
        /// `/photo` (reply to or send with an image). Optional: no
        /// equivalent on XMPP.
        setChatPhoto: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, photo_bytes: []const u8) anyerror!void = null,
        /// `/photo remove`. Optional: no equivalent on XMPP.
        deleteChatPhoto: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8) anyerror!void = null,
        pinMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void = null,
        /// `message_id` null unpins whatever's currently pinned.
        unpinMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: ?[]const u8) anyerror!void = null,
        deleteMessage: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void = null,
        /// True if `user_id` currently has admin/owner standing in
        /// `chat_id` on this platform — the source of truth `group_admin.zig`
        /// gates moderation commands on. Optional: a platform without a
        /// group-admin concept (e.g. a 1:1-only platform) just has every
        /// group-management command report `error.Unsupported`.
        isGroupAdmin: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool = null,
        /// The bot's own username on this platform, if known (adapters may
        /// only learn it after their first API round trip). The returned
        /// slice must stay valid for the connector's lifetime — used e.g.
        /// to attribute the bot's own answers in the chat log.
        selfUsername: ?*const fn (ptr: *anyopaque) ?[]const u8 = null,
        /// The bot's own native platform id, as a string, if known — same
        /// lazy-population/lifetime rules as `selfUsername`. Used to resolve
        /// the bot's own `Identity` row so its own messages aren't logged
        /// under a hardcoded placeholder id.
        selfId: ?*const fn (ptr: *anyopaque) ?[]const u8 = null,
        /// Every owner/administrator of `chat_id`, if this platform exposes
        /// such a call — the closest thing to a bulk member listing bots
        /// get (see `telegram/client.zig`'s `getChatAdministrators` doc
        /// comment: there is no bulk call for regular members). Used to
        /// seed the local roster (`chat_members`) with admins who may never
        /// have sent a message themselves. Optional: a platform without the
        /// concept just reports `error.Unsupported`.
        listChatAdmins: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8) anyerror![]Identity = null,
        /// Publishes the bot's command menu (see `CommandSpec`'s doc
        /// comment) so it shows up in the platform's own UI (Telegram's "/"
        /// autocomplete) instead of only working for people who already
        /// know the exact command text. Optional/best-effort: a platform
        /// without the concept just reports `error.Unsupported`, and
        /// `main.zig` logs rather than fails startup on any error here.
        setCommands: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, commands: []const CommandSpec) anyerror!void = null,
    };

    pub fn platform(self: Connector) Platform {
        return self.vtable.platform(self.ptr);
    }

    pub fn poll(self: Connector, allocator: std.mem.Allocator) ![]Message {
        return self.vtable.poll(self.ptr, allocator);
    }

    pub fn sendMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        self.vtable.sendMessage(self.ptr, allocator, chat_id, text, reply_to_message_id);
    }

    pub fn sendPhoto(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        const f = self.vtable.sendPhoto orelse {
            self.sendMessage(allocator, chat_id, "This platform doesn't support sending images.", null);
            return;
        };
        f(self.ptr, allocator, chat_id, image_bytes, caption);
    }

    pub fn sendDocument(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        const f = self.vtable.sendDocument orelse {
            self.sendMessage(allocator, chat_id, "This platform doesn't support sending files.", null);
            return;
        };
        f(self.ptr, allocator, chat_id, file_bytes, file_name, caption);
    }

    pub fn sendVideo(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, video_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        const f = self.vtable.sendVideo orelse {
            self.sendMessage(allocator, chat_id, "This platform doesn't support sending videos.", null);
            return;
        };
        f(self.ptr, allocator, chat_id, video_bytes, file_name, caption);
    }

    /// Renders `question`/`options` as plain numbered text when this
    /// platform has no native poll concept -- same "degrade to text rather
    /// than silently drop it" convention `sendPhoto`/`sendDocument` already
    /// use for their own unsupported case.
    pub fn sendPoll(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, question: []const u8, options: []const []const u8, reply_to_message_id: ?[]const u8) void {
        const f = self.vtable.sendPoll orelse {
            var buf: std.Io.Writer.Allocating = .init(allocator);
            buf.writer.print("{s}\n", .{question}) catch return;
            for (options, 0..) |opt, i| buf.writer.print("{d}. {s}\n", .{ i + 1, opt }) catch return;
            self.sendMessage(allocator, chat_id, buf.writer.buffered(), reply_to_message_id);
            return;
        };
        f(self.ptr, allocator, chat_id, question, options, reply_to_message_id);
    }

    /// `null` when this connector doesn't declare a limit — see
    /// `VTable.maxMessageLength`'s doc comment.
    pub fn maxMessageLength(self: Connector) ?usize {
        const f = self.vtable.maxMessageLength orelse return null;
        return f(self.ptr);
    }

    pub fn downloadFile(self: Connector, allocator: std.mem.Allocator, file_id: []const u8) ![]u8 {
        const f = self.vtable.downloadFile orelse return error.Unsupported;
        return f(self.ptr, allocator, file_id);
    }

    /// Returns `null` when the platform doesn't support it (caller should
    /// fall back to a plain `sendMessage`), or propagates a real send error.
    pub fn sendMessageReturningId(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) !?[]const u8 {
        const f = self.vtable.sendMessageReturningId orelse return null;
        return try f(self.ptr, allocator, chat_id, text, reply_to_message_id);
    }

    pub fn editMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) !void {
        const f = self.vtable.editMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id, text);
    }

    /// Falls back to a plain numbered-list `sendMessage` when the platform
    /// doesn't implement choice prompts — returns `null` in that case (no
    /// prompt id exists to match a later pick against), matching
    /// `sendPhoto`/`sendDocument`'s "unsupported platform" convention.
    pub fn sendChoicePrompt(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const Choice, reply_to_message_id: ?[]const u8) !?[]const u8 {
        const f = self.vtable.sendChoicePrompt orelse {
            var buf: std.Io.Writer.Allocating = .init(allocator);
            defer buf.deinit();
            buf.writer.print("{s}\n", .{text}) catch {};
            for (choices) |c| buf.writer.print("  {s} {s}\n", .{ c.emoji, c.label }) catch {};
            self.sendMessage(allocator, chat_id, buf.writer.buffered(), reply_to_message_id);
            return null;
        };
        return try f(self.ptr, allocator, chat_id, text, choices, reply_to_message_id);
    }

    pub fn editChoicePrompt(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8, choices: []const Choice) !void {
        const f = self.vtable.editChoicePrompt orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id, text, choices);
    }

    pub fn muteUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) !void {
        const f = self.vtable.muteUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id, until_unix_time);
    }

    pub fn unmuteUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.unmuteUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn kickUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.kickUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn banUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.banUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn promoteUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.promoteUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn demoteUser(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !void {
        const f = self.vtable.demoteUser orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn restrictChatMemberPermissions(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, permission_bits: u32, until_unix_time: i64) !void {
        const f = self.vtable.restrictChatMemberPermissions orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id, permission_bits, until_unix_time);
    }

    pub fn setChatAdminTitle(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, title: []const u8) !void {
        const f = self.vtable.setChatAdminTitle orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id, title);
    }

    pub fn setChatTitle(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, title: []const u8) !void {
        const f = self.vtable.setChatTitle orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, title);
    }

    pub fn setChatDescription(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, description: []const u8) !void {
        const f = self.vtable.setChatDescription orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, description);
    }

    pub fn setChatPhoto(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, photo_bytes: []const u8) !void {
        const f = self.vtable.setChatPhoto orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, photo_bytes);
    }

    pub fn deleteChatPhoto(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8) !void {
        const f = self.vtable.deleteChatPhoto orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id);
    }

    pub fn pinMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) !void {
        const f = self.vtable.pinMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id);
    }

    pub fn unpinMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: ?[]const u8) !void {
        const f = self.vtable.unpinMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id);
    }

    pub fn deleteMessage(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) !void {
        const f = self.vtable.deleteMessage orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, message_id);
    }

    pub fn isGroupAdmin(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) !bool {
        const f = self.vtable.isGroupAdmin orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id, user_id);
    }

    pub fn selfUsername(self: Connector) ?[]const u8 {
        const f = self.vtable.selfUsername orelse return null;
        return f(self.ptr);
    }

    pub fn selfId(self: Connector) ?[]const u8 {
        const f = self.vtable.selfId orelse return null;
        return f(self.ptr);
    }

    pub fn listChatAdmins(self: Connector, allocator: std.mem.Allocator, chat_id: []const u8) ![]Identity {
        const f = self.vtable.listChatAdmins orelse return error.Unsupported;
        return f(self.ptr, allocator, chat_id);
    }

    pub fn setCommands(self: Connector, allocator: std.mem.Allocator, commands: []const CommandSpec) !void {
        const f = self.vtable.setCommands orelse return error.Unsupported;
        return f(self.ptr, allocator, commands);
    }
};

const testing = std.testing;

test "Message.dupe deep-copies every string field into the new allocator" {
    // Not deferred: deinited explicitly mid-test (see below) to prove
    // `dst` doesn't alias it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    // Built with allocations from an arena the caller will free right
    // after `dupe` returns, to prove the result doesn't alias `src`.
    const src = Message{
        .chat_id = try src_a.dupe(u8, "123"),
        .message_id = try src_a.dupe(u8, "555"),
        .user_id = try src_a.dupe(u8, "42"),
        .username = try src_a.dupe(u8, "alice"),
        .text = try src_a.dupe(u8, "hello"),
        .reply_to_message_id = try src_a.dupe(u8, "554"),
        .reply_to_user_id = try src_a.dupe(u8, "43"),
        .reply_to_username = try src_a.dupe(u8, "bob"),
        .reply_to_text = try src_a.dupe(u8, "earlier text"),
        .is_group = true,
        .reply_to_is_me = true,
        .mentions_me = true,
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.message_id.?);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.username.?);
        testing.allocator.free(dst.text.?);
        testing.allocator.free(dst.reply_to_message_id.?);
        testing.allocator.free(dst.reply_to_user_id.?);
        testing.allocator.free(dst.reply_to_username.?);
        testing.allocator.free(dst.reply_to_text.?);
    }

    // Freeing the source arena now (before any assertions) proves `dst`
    // doesn't merely borrow `src`'s pointers — a UAF would corrupt these
    // reads on most allocators.
    arena.deinit();

    try testing.expectEqualStrings("123", dst.chat_id);
    try testing.expectEqualStrings("555", dst.message_id.?);
    try testing.expectEqualStrings("42", dst.user_id);
    try testing.expectEqualStrings("alice", dst.username.?);
    try testing.expectEqualStrings("hello", dst.text.?);
    try testing.expectEqualStrings("554", dst.reply_to_message_id.?);
    try testing.expectEqualStrings("43", dst.reply_to_user_id.?);
    try testing.expectEqualStrings("bob", dst.reply_to_username.?);
    try testing.expectEqualStrings("earlier text", dst.reply_to_text.?);
    try testing.expect(dst.is_group);
    try testing.expect(dst.reply_to_is_me);
    try testing.expect(dst.mentions_me);
}

test "Message.dupe passes through null optional fields as null" {
    const src = Message{ .chat_id = "1", .user_id = "2" };
    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
    }
    try testing.expectEqual(@as(?[]const u8, null), dst.message_id);
    try testing.expectEqual(@as(?[]const u8, null), dst.username);
    try testing.expectEqual(@as(?[]const u8, null), dst.text);
    try testing.expectEqual(@as(?Identity, null), dst.identity);
    try testing.expectEqual(@as(?TelegramProfile, null), dst.telegram_profile);
    try testing.expectEqual(@as(?InstagramProfile, null), dst.instagram_profile);
    try testing.expectEqual(@as(?ChoicePicked, null), dst.choice_picked);
}

test "Message.dupe deep-copies choice_picked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = Message{
        .chat_id = try src_a.dupe(u8, "1"),
        .user_id = try src_a.dupe(u8, "2"),
        .choice_picked = .{
            .prompt_message_id = try src_a.dupe(u8, "555"),
            .value = try src_a.dupe(u8, "png"),
        },
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.choice_picked.?.prompt_message_id);
        testing.allocator.free(dst.choice_picked.?.value);
    }

    arena.deinit();

    try testing.expectEqualStrings("555", dst.choice_picked.?.prompt_message_id);
    try testing.expectEqualStrings("png", dst.choice_picked.?.value);
}

test "Message.dupe deep-copies identity and telegram_profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = Message{
        .chat_id = try src_a.dupe(u8, "1"),
        .user_id = try src_a.dupe(u8, "42"),
        .identity = .{
            .platform = .telegram,
            .native_id = try src_a.dupe(u8, "42"),
            .display_name = try src_a.dupe(u8, "Alice"),
            .username = try src_a.dupe(u8, "alice"),
            .is_bot = false,
            .first_seen = 1000,
            .last_seen = 1000,
        },
        .telegram_profile = .{
            .identity = .{
                .platform = .telegram,
                .native_id = try src_a.dupe(u8, "42"),
                .display_name = try src_a.dupe(u8, "Alice"),
                .username = try src_a.dupe(u8, "alice"),
                .first_seen = 1000,
                .last_seen = 1000,
            },
            .language_code = try src_a.dupe(u8, "en"),
        },
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.identity.?.native_id);
        testing.allocator.free(dst.identity.?.display_name);
        testing.allocator.free(dst.identity.?.username.?);
        testing.allocator.free(dst.telegram_profile.?.identity.native_id);
        testing.allocator.free(dst.telegram_profile.?.identity.display_name);
        testing.allocator.free(dst.telegram_profile.?.identity.username.?);
        testing.allocator.free(dst.telegram_profile.?.language_code.?);
    }

    arena.deinit();

    try testing.expectEqualStrings("42", dst.identity.?.native_id);
    try testing.expectEqualStrings("Alice", dst.identity.?.display_name);
    try testing.expectEqualStrings("alice", dst.identity.?.username.?);
    try testing.expectEqualStrings("en", dst.telegram_profile.?.language_code.?);
}

test "Message.dupe deep-copies instagram_profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = Message{
        .chat_id = try src_a.dupe(u8, "1"),
        .user_id = try src_a.dupe(u8, "42"),
        .instagram_profile = .{
            .identity = .{
                .platform = .instagram,
                .native_id = try src_a.dupe(u8, "42"),
                .display_name = try src_a.dupe(u8, "alice"),
                .first_seen = 1000,
                .last_seen = 1000,
            },
            .full_name = try src_a.dupe(u8, "Alice Example"),
            .is_private = true,
        },
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.instagram_profile.?.identity.native_id);
        testing.allocator.free(dst.instagram_profile.?.identity.display_name);
        testing.allocator.free(dst.instagram_profile.?.full_name.?);
    }

    arena.deinit();

    try testing.expectEqualStrings("Alice Example", dst.instagram_profile.?.full_name.?);
    try testing.expect(dst.instagram_profile.?.is_private);
}

test "Message.dupe deep-copies observed_users and detaches them from the source arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = Message{
        .chat_id = try src_a.dupe(u8, "1"),
        .user_id = try src_a.dupe(u8, "2"),
        .observed_users = &.{
            .{
                .platform = .telegram,
                .native_id = try src_a.dupe(u8, "99"),
                .display_name = try src_a.dupe(u8, "Bob"),
                .first_seen = 1000,
                .last_seen = 1000,
            },
        },
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.observed_users[0].native_id);
        testing.allocator.free(dst.observed_users[0].display_name);
        testing.allocator.free(dst.observed_users);
    }

    arena.deinit();

    try testing.expectEqual(@as(usize, 1), dst.observed_users.len);
    try testing.expectEqualStrings("99", dst.observed_users[0].native_id);
    try testing.expectEqualStrings("Bob", dst.observed_users[0].display_name);
}

test "Message.dupe passes through an empty observed_users without allocating" {
    const src = Message{ .chat_id = "1", .user_id = "2" };
    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
    }
    try testing.expectEqual(@as(usize, 0), dst.observed_users.len);
    try testing.expectEqual(@as(usize, 0), dst.joined_users.len);
}

test "Message.dupe deep-copies joined_users independently of observed_users" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = Message{
        .chat_id = try src_a.dupe(u8, "1"),
        .user_id = try src_a.dupe(u8, "2"),
        .joined_users = &.{
            .{
                .platform = .telegram,
                .native_id = try src_a.dupe(u8, "99"),
                .display_name = try src_a.dupe(u8, "Bob"),
                .first_seen = 1000,
                .last_seen = 1000,
            },
        },
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.joined_users[0].native_id);
        testing.allocator.free(dst.joined_users[0].display_name);
        testing.allocator.free(dst.joined_users);
    }

    arena.deinit();

    try testing.expectEqual(@as(usize, 0), dst.observed_users.len);
    try testing.expectEqual(@as(usize, 1), dst.joined_users.len);
    try testing.expectEqualStrings("Bob", dst.joined_users[0].display_name);
}

test "Message.dupe carries chat_left and deep-copies migrated_to_native_chat_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const src_a = arena.allocator();

    const src = Message{
        .chat_id = try src_a.dupe(u8, "1"),
        .user_id = try src_a.dupe(u8, "2"),
        .chat_left = true,
        .migrated_to_native_chat_id = try src_a.dupe(u8, "-100999"),
    };

    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
        testing.allocator.free(dst.migrated_to_native_chat_id.?);
    }

    arena.deinit();

    try testing.expect(dst.chat_left);
    try testing.expectEqualStrings("-100999", dst.migrated_to_native_chat_id.?);
}

test "Message.dupe passes through null migrated_to_native_chat_id and false chat_left" {
    const src = Message{ .chat_id = "1", .user_id = "2" };
    const dst = try src.dupe(testing.allocator);
    defer {
        testing.allocator.free(dst.chat_id);
        testing.allocator.free(dst.user_id);
    }
    try testing.expect(!dst.chat_left);
    try testing.expectEqual(@as(?[]const u8, null), dst.migrated_to_native_chat_id);
}
