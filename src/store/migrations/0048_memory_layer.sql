-- Rebuilds long-term memory: `memories` (flat, explicit-remember-only, no
-- supersession, no decay) becomes `facts` (bitemporal, subject/predicate/
-- object, auto-extracted + explicit, supersession-aware), and gains a
-- per-chat episodic layer (`daily_digests`, `period_rollups`) that today
-- only exists as an ephemeral, unsaved `/digest` reply (features/digest.zig).
--
-- Scoping decisions (see conversation): facts are per-identity (a fact
-- follows a person across every chat, matching the old `memories` table's
-- convention); digests are per-chat (matching digest.zig/storage_sense's
-- existing chat-scoped summarization). No new `conversations` table --
-- `messages` is already a continuous per-chat stream; a digest's
-- `min_message_id`/`max_message_id` range drills into it directly, the same
-- idiom `messages.oldestBatchForSummary` already uses for its own
-- compaction batches.
--
-- No HNSW/GIN vector indexes, matching 0025_memories.sql's own reasoning:
-- a personal bot's row counts don't need an approximate index yet. A plain
-- tsvector GIN index backs full-text ranking (Postgres has no real BM25;
-- ts_rank_cd is the practical stand-in the design doc's bm25() term maps to).

CREATE TABLE facts (
  id                   BIGSERIAL PRIMARY KEY,
  identity_id          BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,

  -- identity | preference | project | relationship | directive
  scope                TEXT NOT NULL,
  -- normalized, e.g. 'works_at', 'prefers', 'remembers' (explicit /memory
  -- remember calls degenerate to predicate='remembers', object=statement)
  predicate            TEXT NOT NULL,
  object               TEXT NOT NULL,
  statement            TEXT NOT NULL,

  valid_from           TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_to             TIMESTAMPTZ,
  recorded_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  superseded_by        BIGINT REFERENCES facts(id),

  -- tentative | stable | pinned | retired
  status               TEXT NOT NULL DEFAULT 'tentative',
  confirmations        INT NOT NULL DEFAULT 1,
  last_confirmed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  contradiction_count  INT NOT NULL DEFAULT 0,

  source_message_ids   BIGINT[] NOT NULL DEFAULT '{}',
  embedding            vector(1536) NOT NULL
);

-- The constraint that makes silent contradiction impossible: at most one
-- currently-true row per (identity, predicate, object).
CREATE UNIQUE INDEX idx_facts_active_triple ON facts (identity_id, predicate, object) WHERE valid_to IS NULL;
CREATE INDEX idx_facts_identity ON facts (identity_id);
CREATE INDEX idx_facts_status ON facts (status);
CREATE INDEX idx_facts_last_confirmed ON facts (last_confirmed_at);
CREATE INDEX idx_facts_statement_fts ON facts USING GIN (to_tsvector('english', statement));

CREATE TABLE fact_tombstones (
  id           BIGSERIAL PRIMARY KEY,
  identity_id  BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  pattern      TEXT NOT NULL,  -- fact id, predicate, or a topic substring
  reason       TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_fact_tombstones_identity ON fact_tombstones (identity_id);

CREATE TABLE daily_digests (
  id              BIGSERIAL PRIMARY KEY,
  chat_id         BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  local_date      DATE NOT NULL,
  weekday         TEXT NOT NULL,       -- precomputed, e.g. 'Saturday'
  summary         TEXT NOT NULL,
  topics          TEXT[] NOT NULL DEFAULT '{}',
  entities        TEXT[] NOT NULL DEFAULT '{}',
  min_message_id  BIGINT NOT NULL,
  max_message_id  BIGINT NOT NULL,
  embedding       vector(1536) NOT NULL,
  UNIQUE (chat_id, local_date)
);
CREATE INDEX idx_daily_digests_chat_date ON daily_digests (chat_id, local_date);
CREATE INDEX idx_daily_digests_summary_fts ON daily_digests USING GIN (to_tsvector('english', summary));

CREATE TABLE period_rollups (
  id            BIGSERIAL PRIMARY KEY,
  chat_id       BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  grain         TEXT NOT NULL,  -- 'week' | 'month' | 'quarter'
  period_start  DATE NOT NULL,
  period_end    DATE NOT NULL,
  summary       TEXT NOT NULL,
  embedding     vector(1536) NOT NULL,
  UNIQUE (chat_id, grain, period_start)
);

CREATE TABLE retrieval_log (
  id           BIGSERIAL PRIMARY KEY,
  chat_id      BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id  BIGINT REFERENCES identities(id) ON DELETE CASCADE,
  fact_id      BIGINT REFERENCES facts(id) ON DELETE CASCADE,
  digest_id    BIGINT REFERENCES daily_digests(id) ON DELETE CASCADE,
  rank         INT NOT NULL,
  was_useful   BOOLEAN,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_retrieval_log_fact ON retrieval_log (fact_id);
CREATE INDEX idx_retrieval_log_digest ON retrieval_log (digest_id);

-- Backfill: every existing `memories` row becomes a pinned fact (it was an
-- explicit /memory remember, i.e. already user-confirmed, not a tentative
-- LLM extraction) with a degenerate triple, then the old table is dropped.
INSERT INTO facts (identity_id, scope, predicate, object, statement, valid_from, recorded_at, last_confirmed_at, status, embedding)
SELECT identity_id, 'preference', 'remembers', text, text, created_at, created_at, created_at, 'pinned', embedding
FROM memories;

DROP TABLE memories;
