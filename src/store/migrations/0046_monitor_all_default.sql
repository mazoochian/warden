-- Lets the owner monitor every personal-account chat by default (reading
-- is low-risk -- get_bulletin never sends anything -- unlike replying,
-- which stays opt-in per chat via reply_autonomy). Widens
-- chat_settings.monitor_importance (0045_chat_monitoring.sql) to accept an
-- explicit 'off' value: once a chat's own NULL means "inherit the global
-- default" rather than "not monitored", a chat still needs a way to opt
-- OUT even while the global default is "monitor everything".
ALTER TABLE chat_settings DROP CONSTRAINT chat_settings_monitor_importance_check;
ALTER TABLE chat_settings ADD CONSTRAINT chat_settings_monitor_importance_check
    CHECK (monitor_importance IN ('off', 'low', 'normal', 'high'));

-- The owner's global default, same "NULL falls back to a safe default"
-- shape as reply_autonomy_default (0043_reply_autonomy.sql) -- NULL/'off'
-- both mean "only explicitly opted-in chats are monitored", preserving
-- today's behavior for every existing deployment until the owner
-- explicitly turns this on.
ALTER TABLE user_settings ADD COLUMN monitor_all_default TEXT
    CHECK (monitor_all_default IN ('off', 'low', 'normal', 'high'));
