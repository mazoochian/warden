-- Phase 25: video auto-download. FALSE (off) by default -- unlike
-- keyword_alerts (a word a user explicitly opts a chat into tracking),
-- this changes what the bot does with *any* video link *any* member
-- posts, so it needs an explicit admin opt-in per chat rather than being
-- on by default, same "off until asked" convention as
-- autopin_announcements/welcome_message.
ALTER TABLE chat_settings ADD COLUMN video_download_enabled BOOLEAN NOT NULL DEFAULT FALSE;
