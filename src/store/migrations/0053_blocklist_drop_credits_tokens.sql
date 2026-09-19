-- Access control flips from allowlist to blocklist: the bot now answers
-- everyone by default (the owner-only LLM gate, WARDEN_LLM_OWNER_ONLY, and
-- the bot-admin role are unchanged), and the owner or a bot admin blocks a
-- specific user or chat instead of allowing one. See store/bot_blocklist.zig
-- and main.zig's handleMessage top-of-function gate. Existing allow rows are
-- dropped, not inverted -- "allowed" carries no information under the new
-- default.
DROP TABLE bot_allowed_users;
DROP TABLE bot_allowed_chats;

CREATE TABLE bot_blocked_users (
  identity_id BIGINT PRIMARY KEY REFERENCES identities(id) ON DELETE CASCADE,
  blocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  blocked_by BIGINT NOT NULL REFERENCES identities(id)
);

CREATE TABLE bot_blocked_chats (
  chat_id BIGINT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
  blocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  blocked_by BIGINT NOT NULL REFERENCES identities(id)
);

-- A queued /adduser for a never-seen @username has nothing left to grant;
-- the kind itself is retired (/blockuser @username queues 'blocked_user'
-- in its place; 'bot_admin' stays).
DELETE FROM bot_pending_grants WHERE kind = 'allowed_user';

-- The per-identity LLM credit balance (0012) and the per-chat moderation
-- tokens (0001's chat_members.tokens) are gone: RBAC -- owner, bot admins,
-- a chat's own live platform admins -- is the whole permission model now.
-- Their audit-log rows ('chat.action.credit' / 'chat.action.token') stay
-- as history.
ALTER TABLE identities DROP COLUMN credits;
ALTER TABLE chat_members DROP COLUMN tokens;
