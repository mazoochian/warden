-- Admin-configured generic-OIDC login providers -- Google gets its own
-- well-known endpoint/config (env-based, like every other external
-- integration warden already has), but "any OIDC IdP" needs somewhere to
-- store an issuer URL + client id/secret per provider, since there's no
-- single fixed endpoint. `client_secret` is server-side only -- the API
-- layer must never serialize this column back to a client.
CREATE TABLE oauth_providers (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  issuer_url TEXT NOT NULL,
  client_id TEXT NOT NULL,
  client_secret TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
