-- RSS/Atom feed watches: "watch this URL, tell me when something new shows
-- up" — same interval-checked-in-the-background shape as alerts, but keyed
-- by (chat_id, feed_url) instead of an id, since /unwatch <url> is a more
-- natural command than needing to look up an id first (a chat can watch
-- several feeds at once, so a single per-chat toggle like /digest wouldn't
-- fit, but the feed URL itself is a fine natural key).
CREATE TABLE feed_watches (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  feed_url TEXT NOT NULL,
  last_seen_guid TEXT,
  last_checked_at TIMESTAMPTZ,
  check_interval_seconds BIGINT NOT NULL DEFAULT 900,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (chat_id, feed_url)
);
CREATE INDEX idx_feed_watches_chat ON feed_watches(chat_id);
