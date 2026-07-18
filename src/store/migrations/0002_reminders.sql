-- One-off (non-recurring) reminders, delivered by a due_at <= now() poll
-- rather than a wall-clock/timezone-aware scheduler (see scheduler.zig's
-- doc comment on why warden doesn't have one yet) — due_at is an absolute
-- UTC timestamp computed from a relative duration at creation time, which
-- sidesteps the tz-database gap entirely for "remind me in 2 hours" style
-- use.
CREATE TABLE reminders (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  message TEXT NOT NULL,
  due_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  delivered_at TIMESTAMPTZ
);
CREATE INDEX idx_reminders_due ON reminders(due_at) WHERE delivered_at IS NULL;
