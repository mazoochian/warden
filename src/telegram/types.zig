//! Minimal subset of the Telegram Bot API's JSON shapes, decoded with
//! std.json. Only fields Warden actually uses are modeled; parsing is done
//! with `ignore_unknown_fields = true` so Telegram can add fields freely.

pub const User = struct {
    id: i64,
    is_bot: bool = false,
    first_name: []const u8 = "",
    username: ?[]const u8 = null,
};

pub const Chat = struct {
    id: i64,
    type: []const u8 = "",
    title: ?[]const u8 = null,
};

/// Deliberately flat (no nested `reply_to_message` of its own) rather than
/// a recursive `Message` — Telegram does allow reply chains, but Warden
/// only ever needs to know who/what a direct reply targets.
pub const ReplyToMessage = struct {
    message_id: i64,
    from: ?User = null,
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
