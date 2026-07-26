-- warden-ui foundations (see /home/armin/claude/warden-ui/ARCHITECTURE.md
-- §4 for the full reasoning). An `accounts` row is "one browser-facing
-- person" -- distinct from `identities`, which is "one real person per
-- platform" and stays exactly as the bot's own command handling already
-- uses it. `account_identities` links the two: logging in via the
-- Telegram Login Widget resolves directly to an existing `identities` row
-- (no linking step needed, the common case); logging in via Google/OIDC
-- for the first time creates a fresh `identities` row (platform='google'
-- or 'oidc:<issuer-host>') plus a fresh `accounts` row, which a
-- logged-in user can later link additional identities onto.
CREATE TABLE accounts (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  display_name TEXT NOT NULL DEFAULT '',
  avatar_url TEXT
);

-- One identity belongs to at most one account (UNIQUE on identity_id
-- alone, not just the pair) -- an identity already linked elsewhere can't
-- be silently re-linked to a second account.
CREATE TABLE account_identities (
  account_id BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL UNIQUE REFERENCES identities(id) ON DELETE CASCADE,
  linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, identity_id)
);
