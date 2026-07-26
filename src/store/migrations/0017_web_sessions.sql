-- A web login session -- DB-backed (not a stateless JWT) specifically so
-- a session can be revoked server-side ("log out everywhere," force-expire
-- on a permission downgrade). The browser cookie carries only this row's
-- id plus an HMAC-SHA256 tag (see src/api/auth.zig); the actual
-- account/expiry/revocation state lives here, checked on every request.
CREATE TABLE web_sessions (
  id BIGSERIAL PRIMARY KEY,
  account_id BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  user_agent TEXT,
  ip TEXT
);
CREATE INDEX idx_web_sessions_account_id ON web_sessions(account_id);
