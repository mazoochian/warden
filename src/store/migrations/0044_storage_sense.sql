-- Marks a message row as a synthetic LLM-written compaction of older raw
-- rows, produced by storage_sense.zig's resample action, rather than a real
-- logged message from a chat participant -- an explicit typed column
-- (matching chat_settings.zig's own preference for real columns over an
-- implicit marker like a synthetic identity), not a magic sender.
ALTER TABLE messages ADD COLUMN is_summary BOOLEAN NOT NULL DEFAULT false;
