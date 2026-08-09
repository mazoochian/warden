-- Phase 23 (ROADMAP.md): a chat admin can flip this so future managerial
-- commands (redact/kick/ban/promote/demote/mute/unmute, and the Phase 22
-- photo/title/description setters) default to "-s" (silent -- suppress
-- the in-group confirmation message; the bound management room's audit
-- entry is unaffected either way) without needing the flag typed every
-- time. Off by default, same "off until asked" convention every other
-- chat_settings boolean here already uses.
ALTER TABLE chat_settings ADD COLUMN silent_by_default BOOLEAN NOT NULL DEFAULT false;
