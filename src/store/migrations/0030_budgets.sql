-- Phase 17: per-category monthly budgets, checked against expenses'
-- category totals. One budget per (chat_id, category); "monthly" is
-- hardcoded (calendar month, not a rolling 30 days) rather than a
-- selectable period -- the overwhelmingly common personal-budgeting
-- cadence, and consistent with this codebase's established "good enough
-- for a personal bot" tradeoffs elsewhere (e.g. reminder_format.zig's
-- naive timezone). See src/store/budgets.zig.
CREATE TABLE budgets (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  category TEXT NOT NULL,
  amount_cents BIGINT NOT NULL CHECK (amount_cents > 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  UNIQUE (chat_id, category)
);
