CREATE TABLE identities (
  id BIGSERIAL PRIMARY KEY,
  platform TEXT NOT NULL,
  native_id TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  username TEXT,
  is_bot BOOLEAN NOT NULL DEFAULT FALSE,
  first_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen TIMESTAMPTZ,
  UNIQUE (platform, native_id)
);

CREATE TABLE telegram_profiles (
  identity_id BIGINT PRIMARY KEY REFERENCES identities(id) ON DELETE CASCADE,
  first_name TEXT NOT NULL DEFAULT '',
  last_name TEXT,
  language_code TEXT,
  is_premium BOOLEAN NOT NULL DEFAULT FALSE,
  added_to_attachment_menu BOOLEAN NOT NULL DEFAULT FALSE,
  can_join_groups BOOLEAN,
  can_read_all_group_messages BOOLEAN,
  supports_inline_queries BOOLEAN
);

-- Stubs: no connector populates these yet, but the shape exists so the
-- Matrix/XMPP connectors have somewhere to write when implemented.
CREATE TABLE matrix_profiles (
  identity_id BIGINT PRIMARY KEY REFERENCES identities(id) ON DELETE CASCADE,
  homeserver TEXT NOT NULL DEFAULT '',
  avatar_url TEXT
);

CREATE TABLE xmpp_profiles (
  identity_id BIGINT PRIMARY KEY REFERENCES identities(id) ON DELETE CASCADE,
  jid_resource TEXT
);

CREATE TABLE chats (
  id BIGSERIAL PRIMARY KEY,
  platform TEXT NOT NULL,
  native_chat_id TEXT NOT NULL,
  chat_type TEXT,
  title TEXT,
  UNIQUE (platform, native_chat_id)
);

-- One row per (chat, real person) — replaces the old per-chat-file `users`
-- table. The same identity can now be correlated across chats via
-- identity_id, instead of getting a disconnected row (and token balance)
-- per chat.
CREATE TABLE chat_members (
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  tokens BIGINT NOT NULL DEFAULT 0,
  last_seen TIMESTAMPTZ,
  PRIMARY KEY (chat_id, identity_id)
);

CREATE TABLE messages (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id),
  native_message_id TEXT,
  text TEXT,
  ts TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_messages_chat_id_id ON messages(chat_id, id);
CREATE INDEX idx_messages_identity_id ON messages(identity_id);
CREATE INDEX idx_messages_ts ON messages(ts);

-- Typed replacement for the old stringly-typed chat_settings KV table.
CREATE TABLE chat_settings (
  chat_id BIGINT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
  digest_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  last_digest_ts TIMESTAMPTZ,
  magic_word TEXT
);

-- Replaces the "_global.db" fake-chat-id hack (scraper_mode/remote_url/api_key).
CREATE TABLE bot_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
