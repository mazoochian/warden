-- Lets /adduser and /addadmin grant access to a @username the bot has
-- never seen a message from yet (so no identities row -- and therefore no
-- identity_id -- exists for them at all). Rather than failing outright,
-- the grant is queued here and completed automatically the moment that
-- username is next seen (see main.zig's resolveSenderIdentity, which
-- checks this table right after resolving/creating the sender's identity
-- row, before handleMessage's allowlist gate ever runs -- so their very
-- first message already has the grant applied).
CREATE TABLE bot_pending_grants (
  platform TEXT NOT NULL,
  username_lower TEXT NOT NULL,
  kind TEXT NOT NULL, -- 'allowed_user' | 'bot_admin'
  added_by BIGINT NOT NULL REFERENCES identities(id),
  added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (platform, username_lower, kind)
);
