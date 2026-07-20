-- Matrix E2E encryption state (Olm/Megolm via libolm, see
-- src/matrix/olm.zig and ROADMAP.md's Phase 2b). Losing any of this loses
-- the ability to decrypt already-shared room keys or continue an
-- established per-device session, so — unlike most of warden's other
-- state — this isn't optional to persist.
--
-- The pickle key each pickled_* column is encrypted under is deliberately
-- NOT stored here (sourced from config instead, see WARDEN_MATRIX_PICKLE_KEY)
-- — keeping it out of the database means a DB-only compromise doesn't also
-- hand over the key material needed to decrypt these blobs.

-- One process-wide Olm account (one device identity for the whole bot, not
-- per-room) — always exactly one row, upserted against the fixed id
-- 'self', same singleton-via-fixed-key idiom `bot_config` already uses for
-- individual scalar settings.
CREATE TABLE crypto_account (
  id TEXT PRIMARY KEY DEFAULT 'self',
  device_id TEXT NOT NULL,
  pickled_account TEXT NOT NULL
);

-- Per-device Olm (Double Ratchet) sessions — used for the to-device
-- `m.room.encrypted` (m.olm.v1.curve25519-aes-sha2) messages room keys are
-- shared through, not room messages themselves.
CREATE TABLE crypto_sessions (
  id BIGSERIAL PRIMARY KEY,
  their_identity_key TEXT NOT NULL,
  session_id TEXT NOT NULL,
  pickled_session TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (their_identity_key, session_id)
);

-- This device's outbound Megolm session per room — encrypts every
-- `m.room.message` sent there once the session's key has been shared with
-- every other device in the room.
CREATE TABLE crypto_megolm_outbound (
  room_id TEXT PRIMARY KEY,
  pickled_session TEXT NOT NULL,
  -- JSON array of device identity keys already sent this session's key —
  -- a later message in the same room doesn't need to re-share with them.
  -- Cleared (forcing a re-share to everyone) whenever the session itself
  -- rotates.
  shared_with_json TEXT NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Received Megolm sessions — one per (room, sending device, session id), so
-- a room with N actively-posting devices needs N rows to read everyone's
-- messages.
CREATE TABLE crypto_megolm_inbound (
  room_id TEXT NOT NULL,
  sender_key TEXT NOT NULL,
  session_id TEXT NOT NULL,
  pickled_session TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, sender_key, session_id)
);
