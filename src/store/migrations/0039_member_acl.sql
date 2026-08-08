-- Phase 24: per-member rate limiting ("slow mode") and the granular
-- permission model (`/permission`). Three new tables, kept separate from
-- chat_settings/chat_members (both already large, frequently-edited files)
-- rather than additive columns on either -- see store/rate_limits.zig's and
-- store/member_permissions.zig's doc comments for the full reasoning.

-- Warden's own slow-mode setting per chat (Telegram's Bot API has no
-- native slow-mode setter for bots -- see rate_limits.zig). 0 or no row
-- means no limit.
CREATE TABLE rate_limits (
  chat_id BIGINT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
  min_seconds_between_messages INT NOT NULL DEFAULT 0
);

-- The last *accepted* (not rate-limited) message timestamp per
-- (chat, member) the slow-mode cooldown check is measured against --
-- deliberately not chat_members.last_seen, which is bumped for every
-- inbound message including the one currently being checked (see
-- rate_limits.zig's getLastMessageAt doc comment).
CREATE TABLE member_message_cooldowns (
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  last_message_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (chat_id, identity_id)
);

-- The granular per-member permission model (`/permission +rwpvfmodslaeti`/
-- `-<letters>`). A member with no row here has the implicit default
-- bitmask (every bit set) -- see member_permissions.zig's getBits.
-- expires_at is set only for a timed grant/revoke; NULL means permanent
-- until the next explicit /permission change.
CREATE TABLE member_permissions (
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  permission_bits INT NOT NULL,
  expires_at TIMESTAMPTZ,
  PRIMARY KEY (chat_id, identity_id)
);
CREATE INDEX idx_member_permissions_expires_at ON member_permissions(expires_at) WHERE expires_at IS NOT NULL;
