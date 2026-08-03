-- Phase 16 slice 3: welcome messages. NULL means "no welcome configured"
-- (the default -- a chat opts in explicitly), same null-means-unset
-- convention as chat_settings.system_prompt/magic_word. `{name}` in the
-- text is substituted per new member by main.zig, not templated in SQL.
ALTER TABLE chat_settings ADD COLUMN welcome_message TEXT;
