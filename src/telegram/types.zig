//! Minimal subset of the Telegram Bot API's JSON shapes, decoded with
//! std.json. Only fields Warden actually uses are modeled; parsing is done
//! with `ignore_unknown_fields = true` so Telegram can add fields freely.

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
    title: ?[]const u8 = null,
    /// Private chats/channels have a username; groups/supergroups usually
    /// don't unless they have a public invite link.
    username: ?[]const u8 = null,
};

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

pub const Update = struct {
    update_id: i64,
    message: ?Message = null,
    edited_message: ?Message = null,
    callback_query: ?CallbackQuery = null,
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
