-- Price/metric alerts: "let me know when bitcoin crosses 70k" style
-- standing watches, checked periodically by the poll loop rather than a
-- separate scheduler (see checkAndDeliverAlerts in main.zig) — same
-- interval-based philosophy as reminders/digests.
--
-- check_interval_seconds gates how often the external API actually gets
-- hit (independent of cooldown_seconds, which gates re-notifying once a
-- condition is already true) — without it, an active alert would get
-- re-fetched every ~25-30s poll cycle, which is both wasteful and a good
-- way to get rate-limited by a free-tier API like CoinGecko's.
CREATE TABLE alerts (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,              -- 'crypto' | 'weather' | 'aqi'
  subject TEXT NOT NULL,           -- CoinGecko id or city name
  currency TEXT,                   -- crypto only; null for weather/aqi
  condition TEXT NOT NULL,         -- 'above' | 'below'
  threshold DOUBLE PRECISION NOT NULL,
  check_interval_seconds BIGINT NOT NULL DEFAULT 300,
  cooldown_seconds BIGINT NOT NULL DEFAULT 3600,
  last_checked_at TIMESTAMPTZ,
  last_triggered_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_alerts_chat ON alerts(chat_id);
