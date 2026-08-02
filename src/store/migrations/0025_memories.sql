-- Phase 12: long-term/semantic memory. Explicit remember/forget facts
-- (ChatGPT-Memory-style, not a RAG index over notes/messages) --
-- per-identity, not per-chat, so a memory follows a person across every
-- chat they talk to the bot in. See src/store/memories.zig and
-- src/llm/embeddings.zig.
--
-- Requires the pgvector extension on whatever Postgres instance warden
-- connects to -- confirmed available/enabled by the operator before this
-- migration runs; there's no feature-detection/graceful-degrade here, same
-- "required dependency, fail loud if missing" convention this project
-- already uses elsewhere.
CREATE EXTENSION IF NOT EXISTS vector;

-- 1536 dimensions matches OpenAI's text-embedding-3-small/ada-002 (and
-- what most self-hosted "OpenAI-compatible" embedding servers mirror for
-- drop-in compatibility). Fixed at migration time -- pgvector's vector(N)
-- column width can't be templated from runtime config in this codebase's
-- static-SQL migration system. A WARDEN_EMBEDDINGS_MODEL with a different
-- output dimension fails loudly (a Postgres dimension-mismatch error) on
-- the first `remember` call, not silently -- switching models later needs
-- a manual column-type migration plus re-embedding every existing row.
CREATE TABLE memories (
  id BIGSERIAL PRIMARY KEY,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  embedding vector(1536) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_memories_identity_id ON memories(identity_id);
