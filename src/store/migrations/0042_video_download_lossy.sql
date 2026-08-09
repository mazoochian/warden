-- Lossy (compressed, native-video) vs lossless (original quality, capped
-- at 50MB, sent as a file) mode for video auto-download. TRUE (lossy) by
-- default: once a chat has already opted into auto-download at all
-- (video_download_enabled), lossy/native delivery is the better default;
-- lossless is the opt-in, unlike video_download_enabled itself which
-- defaults off.
ALTER TABLE chat_settings ADD COLUMN video_download_lossy BOOLEAN NOT NULL DEFAULT TRUE;
