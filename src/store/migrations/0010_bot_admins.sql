-- Bot-admin role: a DB-backed permission tier distinct from any platform's
-- own group-admin flag (see auth.zig's checkGroupAdminAccess). Granted by
-- the owner or another bot admin via /addadmin. Not chat-scoped -- a bot
-- admin can act via /sudo in any chat the bot is in.
CREATE TABLE bot_admins (
  identity_id BIGINT PRIMARY KEY REFERENCES identities(id) ON DELETE CASCADE,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by BIGINT NOT NULL REFERENCES identities(id)
);
