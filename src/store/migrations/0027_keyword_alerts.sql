-- Phase 16 slice 2: keyword alerts -- a per-chat list of tracked words;
-- whenever any chat member's message contains one (whole-word, case-
-- insensitive, same matching as the existing magic-word check), the bot
-- flags it right in the chat. See src/store/keyword_alerts.zig.
CREATE TABLE keyword_alerts (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  keyword TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (chat_id, keyword)
);
CREATE INDEX idx_keyword_alerts_chat_id ON keyword_alerts(chat_id);
