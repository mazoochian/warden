-- storage_sense.zig's `tickBacklog` (routine, disk-pressure-independent
-- history compaction) checks every known chat's non-summary message count
-- against a threshold on its own interval -- index the predicate it filters
-- on so that check stays cheap as `messages` grows.
CREATE INDEX idx_messages_chat_non_summary ON messages (chat_id) WHERE is_summary = false;
