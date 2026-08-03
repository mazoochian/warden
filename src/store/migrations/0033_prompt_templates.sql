-- Phase 19: saved prompt templates -- "/template use <name>" resends the
-- saved text as a question through the normal Q&A pipeline (same
-- handleModeCommand path /eli5, /brainstorm etc. already use). One
-- template per (chat_id, name); saving over an existing name replaces it
-- (see src/store/prompt_templates.zig for the same "last writer" upsert
-- tradeoff src/store/command_aliases.zig documents).
CREATE TABLE prompt_templates (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (chat_id, name)
);
