-- Owner-declared, per-chat opt-in for the "monitor for bulletins" feature
-- (see get_bulletin/set_chat_monitoring tools). NULL = not monitored
-- (default) -- same "NULL means off" convention as reply_autonomy
-- (0043_reply_autonomy.sql). Deliberately NOT a classifier: this is set
-- once by the owner (or the LLM, only on explicit request), never inferred
-- by reading message content automatically -- see ROADMAP.md's prior
-- rejection of a per-message importance scorer.
ALTER TABLE chat_settings ADD COLUMN monitor_importance TEXT
    CHECK (monitor_importance IN ('low', 'normal', 'high'));

-- Per-owner cursor for get_bulletin's default "since" window -- one
-- bulletin covers every monitored chat at once, so this is identity-scoped
-- (like reply_autonomy_default), not chat-scoped.
ALTER TABLE user_settings ADD COLUMN last_bulletin_ts TIMESTAMPTZ;
