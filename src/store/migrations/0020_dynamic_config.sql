-- The DB-backed subset of today's env-only Config fields that are safe to
-- expose as live-editable from warden-ui (see ARCHITECTURE.md §6's table
-- for exactly which keys and why -- secrets/DSNs/tokens are deliberately
-- never stored here, only in .env, by design not omission). A missing row
-- for a given key means "use the env-sourced Config default" -- nothing
-- regresses on upgrade until someone actually changes something from the
-- panel. `value` is always TEXT and parsed per-key the same way env vars
-- already are (see store/dynamic_config.zig).
CREATE TABLE dynamic_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by BIGINT REFERENCES identities(id)
);
