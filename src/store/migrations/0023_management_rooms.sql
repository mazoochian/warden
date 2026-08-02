-- Phase 9: a "management room" is a chat that's been designated as the
-- control room for one or more other chats (typically a channel, which has
-- no back-and-forth a member could type commands into) -- see
-- src/store/management_rooms.zig and ROADMAP.md's Phase 9 for the full
-- shape. A control room isn't exclusive to one target; a target isn't
-- exclusive to one control room either.
CREATE TABLE management_room_bindings (
  id BIGSERIAL PRIMARY KEY,
  control_chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  target_chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  bound_by_identity_id BIGINT NOT NULL REFERENCES identities(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (control_chat_id, target_chat_id)
);
CREATE INDEX idx_management_room_bindings_control_chat_id ON management_room_bindings(control_chat_id);
