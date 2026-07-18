-- Recurring reminders ("every 1d", "every 2h") — interval-based, not
-- cron/day-of-week scheduling, same interval-not-wall-clock philosophy as
-- `DigestScheduler`. NULL means the existing one-off behavior: delivered
-- once, then `delivered_at` is set. Non-null means the poll loop advances
-- `due_at` by this many seconds and leaves `delivered_at` NULL instead,
-- so the reminder keeps showing up in `/reminders` and keeps firing.
ALTER TABLE reminders ADD COLUMN recur_interval_seconds BIGINT;
