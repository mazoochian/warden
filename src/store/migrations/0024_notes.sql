-- Phase 11: a personal knowledge base primitive -- one flat, freeform
-- table backs notes, shopping lists, wishlists, packing lists, etc: all of
-- them are just "a chat-scoped list of short text entries someone added",
-- not materially different structures, so this is one generic table
-- rather than several typed ones. See src/store/notes.zig.
CREATE TABLE notes (
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  identity_id BIGINT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_notes_chat_id ON notes(chat_id);
