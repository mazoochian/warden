-- Every mutating warden-ui API call writes one row here (see
-- src/api/audit.zig) -- built in from warden-ui's very first mutating
-- endpoint rather than retrofitted later, since audit logging added after
-- the fact tends to miss whatever shipped before it existed.
CREATE TABLE audit_log (
  id BIGSERIAL PRIMARY KEY,
  account_id BIGINT REFERENCES accounts(id),
  action TEXT NOT NULL,
  target TEXT,
  detail JSONB,
  at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_log_at ON audit_log(at);
CREATE INDEX idx_audit_log_account_id ON audit_log(account_id);
