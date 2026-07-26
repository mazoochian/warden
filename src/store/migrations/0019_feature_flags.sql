-- Bot-wide module enable/disable (not per-chat -- see ARCHITECTURE.md §5
-- in warden-ui for why bot-wide was chosen, and for the split between
-- "standalone command features" that check this directly in main.zig's
-- dispatch and "LLM-tool-shaped features" that are filtered out of
-- tools/registry.zig's list instead). Deliberately no seed rows: a
-- missing row for a module means "enabled" (see
-- store/feature_flags.zig's isEnabled) -- same missing-row-means-default
-- fallback convention as dynamic_config, and avoids a one-time migration
-- INSERT that a test's TRUNCATE ... CASCADE (via updated_by's FK to
-- identities) would silently and permanently wipe, since an
-- already-applied migration never re-runs its INSERT. A module only ever
-- gets a row here the first time someone actually disables it.
CREATE TABLE feature_flags (
  module TEXT PRIMARY KEY,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by BIGINT REFERENCES identities(id)
);
