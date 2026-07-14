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

pub const Message = struct {
    message_id: i64,
    from: ?User = null,
    chat: Chat,
    date: i64 = 0,
    text: ?[]const u8 = null,
    reply_to_message: ?ReplyToMessage = null,
};

pub const Update = struct {
    update_id: i64,
    message: ?Message = null,
    edited_message: ?Message = null,
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
