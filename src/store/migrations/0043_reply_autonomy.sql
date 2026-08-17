-- "Reply on my behalf" (personal-account connector, see platform/
-- telegram_user.zig): how much autonomy a drafted reply gets, either as
-- the owner's global default (user_settings.reply_autonomy_default, NULL
-- = 'off', same "explicit override else a sensible default" convention as
-- utc_offset_minutes/date_format/time_format below it) or overridden per
-- chat (chat_settings.reply_autonomy, NULL = inherit the global default).
--
-- Three levels, safest first:
--   'off'   — no drafts at all in this chat.
--   'draft' — Warden drafts a reply and posts it to the bound management
--             room as an approve/edit/discard prompt; nothing is sent
--             under the owner's identity without an explicit tap.
--   'auto'  — approved drafts send themselves; only meant to be reached
--             after 'draft' has been used and trusted in a given chat.
ALTER TABLE user_settings ADD COLUMN reply_autonomy_default TEXT
    CHECK (reply_autonomy_default IN ('off', 'draft', 'auto'));

ALTER TABLE chat_settings ADD COLUMN reply_autonomy TEXT
    CHECK (reply_autonomy IN ('off', 'draft', 'auto'));
