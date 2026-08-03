-- Phase 17: subscription tracker -- a read-only ledger of recurring
-- costs (what am I paying for, how much per month total), not a second
-- reminder-firing scheduler: "remind me when it's due" is already well
-- served by the existing /remind every <interval> <message> (Phase 3),
-- so this deliberately doesn't duplicate that. interval_days is a plain
-- day count (week=7, month=30, year=365 -- approximate, not calendar-
-- aware), same interval-not-wall-clock tradeoff scheduler.zig's
-- DigestScheduler doc comment already makes for a different feature.
-- See src/store/subscriptions.zig.
CREATE TABLE subscriptions (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  amount_cents BIGINT NOT NULL CHECK (amount_cents > 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  interval_days BIGINT NOT NULL CHECK (interval_days > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_subscriptions_chat_id ON subscriptions(chat_id);
