-- Curated feed: read a set of Telegram channels through the owner's
-- personal account, keep only what matches a natural-language policy, and
-- post periodic digests into a feed channel.
--
-- Sources are opt-in rather than "every channel the account is subscribed
-- to". The account may well be in dozens; reading all of them would make
-- the LLM bill a function of how many channels the owner happens to follow,
-- and a noisy one they had forgotten about would quietly dominate it.
-- Naming sources explicitly keeps the cost predictable and the feed
-- intentional.
CREATE TABLE feed_sources (
  id                   BIGSERIAL PRIMARY KEY,
  -- TDLib's own chat id, the same id space /tdchats and /sendas use.
  native_chat_id       TEXT NOT NULL UNIQUE,
  title                TEXT NOT NULL,
  -- Highest message id already considered. Posts are pulled newest-first
  -- (TDLib's getChatHistory has no "since id" form), so this is what turns
  -- "the most recent N posts" into "what is new since the last pass".
  -- 0 means "nothing seen yet"; the first pass sets it without emitting a
  -- digest, so adding a source never dumps its backlog into the feed.
  last_seen_message_id BIGINT NOT NULL DEFAULT 0,
  enabled              BOOLEAN NOT NULL DEFAULT TRUE,
  added_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Single row, like the personal-account settings it sits alongside: the
-- personal account belongs to exactly one owner, so there is no second
-- configuration to key by. The CHECK makes that structural rather than a
-- convention a later INSERT could break.
CREATE TABLE feed_settings (
  id                    INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  -- Where digests are posted. NULL until set; the feed stays inert without
  -- it rather than guessing a destination.
  target_native_chat_id TEXT,
  -- The natural-language filter, e.g. "I want international news, not
  -- crypto price talk". NULL means no policy set, which (like a missing
  -- target) keeps the feed inert -- never "post everything".
  policy                TEXT,
  interval_seconds      BIGINT NOT NULL DEFAULT 3600,
  enabled               BOOLEAN NOT NULL DEFAULT FALSE,
  last_run_at           TIMESTAMPTZ
);

INSERT INTO feed_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
