-- Per-chat system-prompt override for the LLM Q&A path — lets different
-- chats have a genuinely different bot personality without redeploying.
-- NULL means "use the global default" (WARDEN_SYSTEM_PROMPT[_FILE], or the
-- built-in persona if neither is set) — same null-means-unset convention
-- as chat_settings.magic_word.
ALTER TABLE chat_settings ADD COLUMN system_prompt TEXT;
