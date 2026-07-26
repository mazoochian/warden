-- Coarse gate on whether the bot responds to a message at all (message
-- recording/stats in main.zig's recordMessage/recordObservedUsers are
-- unaffected). A user needs a row here OR their current chat needs a row
-- in bot_allowed_chats; owners and bot_admins bypass both unconditionally
-- (see main.zig's handleMessage top-of-function gate).
CREATE TABLE bot_allowed_users (
  identity_id BIGINT PRIMARY KEY REFERENCES identities(id) ON DELETE CASCADE,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  added_by BIGINT NOT NULL REFERENCES identities(id)
);

CREATE TABLE bot_allowed_chats (
  chat_id BIGINT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  added_by BIGINT NOT NULL REFERENCES identities(id)
);
