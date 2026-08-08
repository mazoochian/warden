-- Phase 20 (ROADMAP.md): chat-command admin actions (mute/kick/promote/...)
-- are audited into the same `audit_log` table warden-ui's mutating API
-- calls already use, but their actor is a chat `identities` row, not a web
-- `accounts` row -- most identities never sign into the web panel, so
-- forcing them through `account_id` would leave "who did this" null for
-- nearly every chat-originated entry. `identity_id` is a second, independent
-- nullable actor column rather than a replacement for `account_id`: a given
-- row populates whichever actor namespace it came from, never both.
ALTER TABLE audit_log ADD COLUMN identity_id BIGINT REFERENCES identities(id);
CREATE INDEX idx_audit_log_identity_id ON audit_log(identity_id);
