-- Phase 17: expense tracker. Amounts are stored as integer cents
-- (amount_cents), never floating point -- this is real money, and float
-- rounding error is exactly the kind of "close enough" tradeoff
-- ROADMAP.md's Phase 17 intro explicitly calls out as the wrong one for
-- anything real-money-adjacent, even a manual-entry personal ledger.
-- currency is a plain ISO 4217 label (default USD), no conversion --
-- sums within one chat are added naively regardless of currency, a
-- documented v1 limitation (see src/store/expenses.zig).
CREATE TABLE expenses (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  amount_cents BIGINT NOT NULL CHECK (amount_cents > 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  category TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_expenses_chat_id ON expenses(chat_id);
CREATE INDEX idx_expenses_chat_category ON expenses(chat_id, category);
