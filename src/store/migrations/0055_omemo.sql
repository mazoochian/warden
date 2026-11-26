-- XMPP OMEMO (legacy 0.3, eu.siacs.conversations.axolotl) state, scoped by
-- the bot's own bare JID (`account`) so a changed WARDEN_XMPP_JID gets a
-- fresh device. Every key/session column holds base64 of an
-- AES-256-GCM-sealed blob under WARDEN_XMPP_OMEMO_KEY, which is kept out of
-- the database for the same reason as WARDEN_MATRIX_PICKLE_KEY.

CREATE TABLE omemo_device (
  account TEXT PRIMARY KEY,
  device_id BIGINT NOT NULL,
  registration_id BIGINT NOT NULL,
  identity_public TEXT NOT NULL,
  identity_private TEXT NOT NULL,
  next_prekey_id BIGINT NOT NULL,
  current_signed_prekey_id BIGINT NOT NULL
);

CREATE TABLE omemo_prekeys (
  account TEXT NOT NULL,
  id BIGINT NOT NULL,
  record TEXT NOT NULL,
  PRIMARY KEY (account, id)
);

CREATE TABLE omemo_signed_prekeys (
  account TEXT NOT NULL,
  id BIGINT NOT NULL,
  record TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account, id)
);

CREATE TABLE omemo_sessions (
  account TEXT NOT NULL,
  jid TEXT NOT NULL,
  device_id BIGINT NOT NULL,
  record TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account, jid, device_id)
);

-- Peer identity keys, trusted on first use; a changed key for a known
-- device is refused until the owner resets it.
CREATE TABLE omemo_identities (
  account TEXT NOT NULL,
  jid TEXT NOT NULL,
  device_id BIGINT NOT NULL,
  identity_key TEXT NOT NULL,
  first_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account, jid, device_id)
);

-- 1:1 chats whose last message from the peer was OMEMO-encrypted, so
-- replies (and unprompted messages) go out encrypted too.
CREATE TABLE omemo_chats (
  account TEXT NOT NULL,
  jid TEXT NOT NULL,
  encrypted BOOLEAN NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account, jid)
);
