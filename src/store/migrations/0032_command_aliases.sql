-- Phase 19: custom command aliases -- "/gm" expanding to a saved command/
-- phrase (e.g. "/weather Tehran"), re-entering the normal dispatch
-- pipeline exactly as if the user had typed the expansion themselves.
-- `name` is stored without its leading slash, lowercase, unique per chat
-- (`main.zig`'s alias creation also rejects any name that collides with a
-- real built-in command, checked in code since the fixed command list
-- lives there, not in SQL). See src/store/command_aliases.zig.
CREATE TABLE command_aliases (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  expansion TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (chat_id, name)
);
