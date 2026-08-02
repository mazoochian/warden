-- Per-chat opt-in for Phase 13's proactive daily briefing -- same
-- enabled/last-sent shape as chat_settings.digest_enabled/last_digest_ts
-- (see that pair's own doc comments in store/chat_settings.zig), kept as
-- its own separate pair rather than reusing the digest ones since a chat
-- can opt into digests, briefings, both, or neither independently.
ALTER TABLE chat_settings ADD COLUMN briefing_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chat_settings ADD COLUMN last_briefing_ts TIMESTAMPTZ;
