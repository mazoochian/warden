//! Minimal subset of the Telegram Bot API's JSON shapes, decoded with
//! std.json. Only fields Warden actually uses are modeled; parsing is done
//! with `ignore_unknown_fields = true` so Telegram can add fields freely.

const std = @import("std");

/// Full Telegram Bot API `User` object (fields Warden can plausibly use for
/// identity — deprecated/inline-menu-only fields are omitted since
/// `ignore_unknown_fields = true` means nothing breaks if Telegram sends
/// them anyway).
pub const User = struct {
    id: i64,
    is_bot: bool = false,
    first_name: []const u8 = "",
    last_name: ?[]const u8 = null,
    username: ?[]const u8 = null,
    language_code: ?[]const u8 = null,
    is_premium: bool = false,
    added_to_attachment_menu: bool = false,
    /// Bot-only fields (present only when `is_bot` and this is the bot's
    /// own `getMe` result, or another bot is mentioned/replied to).
    can_join_groups: ?bool = null,
    can_read_all_group_messages: ?bool = null,
    supports_inline_queries: ?bool = null,
};

pub const Chat = struct {
    id: i64,
    type: []const u8 = "",
    /// Groups, supergroups and channels only. A *private* chat never has
    /// one — Telegram identifies the other party by name instead, via the
    /// two fields below. Reading this alone (as everything used to) meant
    /// every 1:1 chat ended up with no title at all and got displayed by
    /// raw numeric id. See `displayTitle`.
    title: ?[]const u8 = null,
    /// Private chats only: the other party's name.
    first_name: ?[]const u8 = null,
    last_name: ?[]const u8 = null,
    /// Private chats/channels have a username; groups/supergroups usually
    /// don't unless they have a public invite link.
    username: ?[]const u8 = null,

    /// The best human-readable name for this chat, whatever its type:
    /// `title` for groups/supergroups/channels, the other party's name for
    /// a private chat, falling back to `@username` when a private chat has
    /// no name at all. `null` only when Telegram gave us nothing to go on,
    /// which is the one case a caller should fall back to the raw id.
    ///
    /// Allocates only when it has to join a first and last name; every
    /// other case borrows from `self`.
    pub fn displayTitle(self: Chat, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.title) |t| if (t.len > 0) return t;
        if (self.first_name) |first| if (first.len > 0) {
            if (self.last_name) |last| if (last.len > 0) {
                return try std.fmt.allocPrint(allocator, "{s} {s}", .{ first, last });
            };
            return first;
        };
        if (self.username) |u| if (u.len > 0) return try std.fmt.allocPrint(allocator, "@{s}", .{u});
        return null;
    }
};

test "Chat.displayTitle prefers a group title" {
    const a = std.testing.allocator;
    const chat = Chat{ .id = 1, .type = "supergroup", .title = "Alpacas" };
    try std.testing.expectEqualStrings("Alpacas", (try chat.displayTitle(a)).?);
}

test "Chat.displayTitle names a private chat by its person, not its id" {
    // The bug: private chats carry no `title`, so reading only that left
    // every 1:1 conversation displayed as a raw numeric chat id.
    const a = std.testing.allocator;

    const both = Chat{ .id = 2, .type = "private", .first_name = "Ada", .last_name = "Lovelace" };
    const joined = (try both.displayTitle(a)).?;
    defer a.free(joined);
    try std.testing.expectEqualStrings("Ada Lovelace", joined);

    const first_only = Chat{ .id = 3, .type = "private", .first_name = "Ada" };
    try std.testing.expectEqualStrings("Ada", (try first_only.displayTitle(a)).?);
}

test "Chat.displayTitle falls back to @username, then to nothing" {
    const a = std.testing.allocator;

    const uname = Chat{ .id = 4, .type = "private", .username = "ada" };
    const at = (try uname.displayTitle(a)).?;
    defer a.free(at);
    try std.testing.expectEqualStrings("@ada", at);

    // Nothing to go on at all -- only here should a caller show the raw id.
    const bare = Chat{ .id = 5, .type = "private" };
    try std.testing.expectEqual(@as(?[]const u8, null), try bare.displayTitle(a));
}

/// Deliberately flat (no nested `reply_to_message` of its own) rather than
/// a recursive `Message` — Telegram does allow reply chains, but Warden
/// only ever needs to know who/what a direct reply targets.
pub const ReplyToMessage = struct {
    message_id: i64,
    from: ?User = null,
    text: ?[]const u8 = null,
};

/// One size variant of an inbound photo — Telegram sends several
/// resolutions per photo; the largest (by pixel area) is what Warden
/// downloads.
pub const PhotoSize = struct {
    file_id: []const u8,
    width: i64 = 0,
    height: i64 = 0,
};

pub const Document = struct {
    file_id: []const u8,
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

pub const Voice = struct {
    file_id: []const u8,
    mime_type: ?[]const u8 = null,
};

pub const Audio = struct {
    file_id: []const u8,
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

pub const Video = struct {
    file_id: []const u8,
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

/// One parsed span of `Message.text` — Warden only cares about
/// `text_mention`, the one entity kind that carries a full `User` object
/// (used when a client mentions someone by name without an `@username`,
/// e.g. tapping a name out of the member list on a person with no handle).
/// Plain `"mention"` entities (`@username`) carry no `user` and need no
/// special parsing — the raw `@handle` is already in `text`.
pub const MessageEntity = struct {
    type: []const u8 = "",
    offset: i64 = 0,
    length: i64 = 0,
    /// Set only when `type == "text_mention"`.
    user: ?User = null,
};

pub const Message = struct {
    message_id: i64,
    from: ?User = null,
    chat: Chat,
    date: i64 = 0,
    text: ?[]const u8 = null,
    /// Telegram never sends `text` on a photo/document/voice/audio/video
    /// message — any caption the user typed alongside the attachment
    /// arrives here instead. `attachmentFromMessage`'s caller folds this
    /// into `iface.Message.text` so callers don't need to know which field
    /// a given message actually populated.
    caption: ?[]const u8 = null,
    /// Parsed spans of `text` (mentions, links, bold, ...) — Warden only
    /// reads `text_mention` entries out of this (see `MessageEntity`'s doc
    /// comment) to learn about a chat member who has no `@username`.
    entities: ?[]MessageEntity = null,
    reply_to_message: ?ReplyToMessage = null,
    /// Multiple resolutions when present; adapters pick the largest.
    photo: ?[]PhotoSize = null,
    document: ?Document = null,
    voice: ?Voice = null,
    audio: ?Audio = null,
    video: ?Video = null,
    /// Present on the service message Telegram sends when one or more users
    /// join a group (including the bot itself, which callers should skip).
    new_chat_members: ?[]User = null,
    /// Present on the service message Telegram sends when a single user
    /// leaves/is removed from a group.
    left_chat_member: ?User = null,
    /// Present on the service message Telegram sends to the OLD chat id
    /// when a basic group is upgraded to a supergroup — Telegram mints a
    /// brand-new chat id for the same real-world group. See
    /// `platform/telegram.zig`'s `pollFn` for how this becomes a
    /// `migrated_to_native_chat_id` signal instead of a normal message.
    migrate_to_chat_id: ?i64 = null,
};

/// Response shape of `getFile` — resolves a `file_id` to a downloadable path.
pub const FileResponse = struct {
    ok: bool,
    result: ?struct { file_path: ?[]const u8 = null } = null,
    description: ?[]const u8 = null,
};

/// A button press on a message's inline keyboard (see
/// `client.zig`'s `sendChoicePrompt`). Telegram never sets `message`
/// alongside `update.message` — a callback query is its own update kind.
pub const CallbackQuery = struct {
    id: []const u8,
    from: ?User = null,
    /// The message the pressed button was attached to.
    message: ?Message = null,
    /// The pressed button's `callback_data`.
    data: ?[]const u8 = null,
};

/// Sent whenever the bot's OWN membership status in a chat changes
/// (added, promoted/demoted, left, kicked/banned) — Telegram's `my_chat_
/// member` update, distinct from `chat_member` (other members' status
/// changes, not requested/parsed here) and from `left_chat_member`
/// (a *service message* visible in the chat's own timeline, which isn't
/// reliably delivered depending on the chat's visibility settings and
/// says nothing about the bot itself unless the bot happens to be who
/// left). `new_chat_member.status` of `"left"`/`"kicked"` is the
/// authoritative "the bot's no longer in this chat" signal — see
/// `platform/telegram.zig`'s `pollFn`.
pub const ChatMemberUpdated = struct {
    chat: Chat,
    new_chat_member: ChatMember,
};

pub const Update = struct {
    update_id: i64,
    message: ?Message = null,
    edited_message: ?Message = null,
    callback_query: ?CallbackQuery = null,
    my_chat_member: ?ChatMemberUpdated = null,
    /// A post in a channel the bot is in — channels have no `from` user
    /// (posts are anonymous-by-channel, not by a member) and never produce
    /// ordinary `message` updates, only these. See `platform/telegram.zig`'s
    /// `pollFn` for how this becomes a chat-ingest-only `iface.Message`.
    channel_post: ?Message = null,
    edited_channel_post: ?Message = null,
};

pub fn GetUpdatesResponse(comptime T: type) type {
    return struct {
        ok: bool,
        result: []T = &.{},
        description: ?[]const u8 = null,
    };
}

pub const UpdatesResponse = GetUpdatesResponse(Update);

/// Response shape of `getMe` — the bot's own identity.
pub const MeResponse = struct {
    ok: bool,
    result: ?User = null,
    description: ?[]const u8 = null,
};

/// Telegram's ChatMember object. The real Bot API models this as a union
/// discriminated by `status` (ChatMemberOwner/Administrator/Member/
/// Restricted/Left/Banned each with their own field set) — flattened here
/// into one struct with every variant's fields optional, matching this
/// file's existing style (see `Message`'s doc comment) rather than
/// introducing a JSON-tagged-union decode. `status` is one of "creator",
/// "administrator", "member", "restricted", "left", "kicked".
pub const ChatMember = struct {
    status: []const u8 = "",
    user: ?User = null,
    /// Owner/administrator only: true if the chat's admin list hides this
    /// member's identity from other members.
    is_anonymous: bool = false,
    /// Owner/administrator only.
    custom_title: ?[]const u8 = null,
    /// Restricted/kicked only: Unix timestamp the restriction/ban lifts (0 =
    /// forever).
    until_date: ?i64 = null,
    /// Administrator-only permission flags.
    can_be_edited: ?bool = null,
    can_manage_chat: ?bool = null,
    can_delete_messages: ?bool = null,
    can_manage_video_chats: ?bool = null,
    can_restrict_members: ?bool = null,
    can_promote_members: ?bool = null,
    can_change_info: ?bool = null,
    can_invite_users: ?bool = null,
    can_post_messages: ?bool = null,
    can_edit_messages: ?bool = null,
    can_pin_messages: ?bool = null,
    can_manage_topics: ?bool = null,
};

pub const ChatMemberResponse = struct {
    ok: bool,
    result: ?ChatMember = null,
    description: ?[]const u8 = null,
};

/// Response shape of `getChatAdministrators` — every owner/administrator of
/// a chat, the one Telegram Bot API call that surfaces more than a single
/// member at a time (see `Client.getChatAdministrators`'s doc comment for
/// why this is the closest thing to a member "roster" bots get).
pub const ChatAdministratorsResponse = struct {
    ok: bool,
    result: []ChatMember = &.{},
    description: ?[]const u8 = null,
};
