-- Phase 20 (ROADMAP.md): management-room binding becomes 1:1 -- a control
-- room binds exactly one target, and a target is watched by exactly one
-- room, so a direct command typed in a bound room (no `/as <id>` prefix,
-- landing in Phase 21) has an unambiguous implicit target, and "the" bound
-- room a target's audit log posts into is well-defined. `/as` itself is
-- unaffected -- it always took an explicit target id and keeps doing so.
--
-- Dedupe existing many-to-many rows before the new constraints can be
-- added: keep the earliest row per control room, then (a second pass,
-- since the first alone doesn't guarantee it) the earliest per target.
DELETE FROM management_room_bindings a
USING management_room_bindings b
WHERE a.control_chat_id = b.control_chat_id AND a.id > b.id;

DELETE FROM management_room_bindings a
USING management_room_bindings b
WHERE a.target_chat_id = b.target_chat_id AND a.id > b.id;

ALTER TABLE management_room_bindings ADD CONSTRAINT management_room_bindings_control_chat_id_key UNIQUE (control_chat_id);
ALTER TABLE management_room_bindings ADD CONSTRAINT management_room_bindings_target_chat_id_key UNIQUE (target_chat_id);
