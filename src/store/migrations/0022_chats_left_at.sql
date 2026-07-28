-- Housekeeping: tracks when the bot's own membership in a chat ended
-- (kicked, left, or the chat itself deleted) -- NULL means still an active
-- member. See src/store/chats.zig's markLeft/renameNativeChatId/
-- deleteLeftBefore for how this gets set, cleared, and swept.
ALTER TABLE chats ADD COLUMN left_at TIMESTAMPTZ;
