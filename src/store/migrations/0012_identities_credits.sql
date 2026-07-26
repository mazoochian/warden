-- Global (not per-chat, unlike chat_members.tokens) per-identity LLM credit
-- balance. Spent 1-per-turn at the free-form LLM Q&A choke point (main.zig,
-- next to the llm_owner_only check); owner and bot admins are exempt. See
-- store/identities.zig's getCredits/setCredits/spendCredit.
ALTER TABLE identities ADD COLUMN credits BIGINT NOT NULL DEFAULT 0;
