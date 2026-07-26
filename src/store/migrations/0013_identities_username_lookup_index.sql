-- Supports the exact-match username->identity lookup (store/identities.zig's
-- findByUsername), backing /token, /credit, /adduser, /removeuser,
-- /addadmin, /removeadmin's @username targeting. Functional + case-
-- insensitive to match how usernames are actually compared.
CREATE INDEX idx_identities_platform_username_lower
  ON identities (platform, lower(username));
