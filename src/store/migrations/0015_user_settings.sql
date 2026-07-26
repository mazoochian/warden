-- Per-identity personal settings (not per-chat, unlike chat_settings) --
-- backs the /menu Settings -> Personal section. All three columns default
-- to NULL ("not set"): a NULL utc_offset_minutes falls back to a
-- language_code-derived guess (see store/user_settings.zig's
-- getEffectiveOffsetMinutes), then UTC; NULL date_format/time_format fall
-- back to 'mdy'/'24h'. See store/user_settings.zig for the full API.
CREATE TABLE user_settings (
    identity_id BIGINT PRIMARY KEY REFERENCES identities(id),
    utc_offset_minutes INT,
    date_format TEXT,
    time_format TEXT
);
