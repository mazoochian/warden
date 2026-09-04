-- Make embeddings optional, so long-term memory works without an
-- embeddings endpoint configured.
--
-- The bug this fixes: remembering anything required WARDEN_EMBEDDINGS_URL
-- to be set, and failed *silently* when it wasn't. main.zig only wired the
-- MemorySink when an embeddings client existed, so with no endpoint
-- configured the `remember_memory` tool was never registered at all -- the
-- model would agree to remember something, call nothing, and the fact was
-- lost. Nothing surfaced the gap: no error in chat, an empty /memory list,
-- and an empty memory page, indistinguishable from "you never asked me to
-- remember anything". Even had the tool been registered, this NOT NULL made
-- the insert impossible.
--
-- Semantic recall genuinely needs a vector, but *storing* a fact does not,
-- and neither does retrieving one by keyword, recency or salience --
-- the hybrid score has three other terms. So an embedding becomes an
-- optional enhancement: present, it contributes its 0.40 similarity term;
-- absent, that term is COALESCEd to 0 and the remaining terms rank on their
-- own (see facts.hybrid_score_expr). Ordering is by score DESC, so the
-- missing weight scales every row equally and doesn't distort the ranking.
--
-- Applied to the digest tables too, not just facts: nothing writes them
-- yet, so they have no rows to migrate, but they carry exactly the same
-- NOT NULL and would hit exactly the same wall the moment digest
-- persistence is wired up.
ALTER TABLE facts          ALTER COLUMN embedding DROP NOT NULL;
ALTER TABLE daily_digests  ALTER COLUMN embedding DROP NOT NULL;
ALTER TABLE period_rollups ALTER COLUMN embedding DROP NOT NULL;
