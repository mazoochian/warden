-- Instagram personal-account connector: persists the device identity and
-- session cookies the private mobile-app API needs so a process restart
-- resumes without re-login (re-logging in from scratch is a real
-- checkpoint/ban risk factor -- see the connector's design notes). Single
-- row per process (this is a personal-account connector, not multi-tenant),
-- enforced with a fixed id rather than a unique-constraint-on-nothing.
CREATE TABLE instagram_sessions (
    id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    ig_username TEXT NOT NULL,
    ig_user_id TEXT NOT NULL,
    android_device_id TEXT NOT NULL,
    phone_id TEXT NOT NULL,
    device_uuid TEXT NOT NULL,
    advertising_id TEXT NOT NULL,
    session_id_cookie TEXT NOT NULL,
    csrf_token TEXT NOT NULL,
    mid_cookie TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Per-thread last-seen-item watermark, so a poll cycle only yields messages
-- newer than the last one already delivered -- same dedup shape as every
-- other "don't re-process what we've already seen" cursor in this codebase.
CREATE TABLE instagram_thread_watermarks (
    thread_id TEXT PRIMARY KEY,
    last_item_ts BIGINT NOT NULL DEFAULT 0
);
