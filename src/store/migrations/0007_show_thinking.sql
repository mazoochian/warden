-- Per-chat override for whether a reasoning model's chain-of-thought is
-- shown — lets one chat see it while another doesn't, without redeploying.
-- NULL means "use the global default" (WARDEN_LLM_SHOW_THINKING), same
-- null-means-unset convention as chat_settings.magic_word/system_prompt.
ALTER TABLE chat_settings ADD COLUMN show_thinking BOOLEAN;
