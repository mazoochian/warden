-- Pending "reply on my behalf" drafts for the personal-account connector
-- (see platform/telegram_user.zig and features/reply_drafts.zig).
--
-- These used to live only in an in-memory std.StringHashMap, which meant
-- every restart or deploy silently dropped every pending draft: the owner
-- would be notified a draft was ready, then find nothing left to approve
-- (and an empty list on the web UI's drafts page, which reads the same
-- state). Since the entire point of 'draft' mode is "reply to this hours
-- later, when I actually get to it" -- the reason PendingDrafts' timeout is
-- deliberately generous rather than the few seconds a moderation
-- confirmation gets -- losing them across a restart defeated the feature.
--
-- Keyed by TDLib's own native chat id alone rather than (platform, chat
-- id): reply_autonomy is only ever consulted for the Telegram personal
-- account (main.zig's `.telegram_user` branch is its single call site), so
-- there is exactly one id space in play here. Add a platform column if that
-- ever stops being true.
--
-- At most one pending draft per chat: a second draft for the same chat
-- replaces the first rather than queuing behind it, preserving exactly the
-- semantics the in-memory map had (see PendingDrafts.set).
CREATE TABLE reply_drafts (
    native_chat_id TEXT PRIMARY KEY,
    chat_title     TEXT NOT NULL,
    incoming_text  TEXT NOT NULL,
    draft_text     TEXT NOT NULL,
    -- The incoming message's id, so an approved send threads as a reply in
    -- the real chat instead of arriving as a bare new message. NULL when
    -- TDLib didn't report one.
    reply_to       TEXT,
    -- Whatever the owner had already typed into this chat's Telegram
    -- composer before this draft overwrote it, so the notification can hand
    -- it back and it is never silently destroyed (see
    -- telegram_user.setChatDraft). NULL when the composer was empty, which
    -- is the overwhelmingly common case.
    replaced_draft TEXT,
    created_at     TIMESTAMPTZ NOT NULL,
    expires_at     TIMESTAMPTZ NOT NULL
);

-- `list` and the expiry sweep both filter on expires_at.
CREATE INDEX reply_drafts_expires_at_idx ON reply_drafts (expires_at);

-- reply_autonomy's own per-chat system-prompt override, separate from
-- chat_settings.system_prompt (`/persona`).
--
-- The autonomy path used to read `/persona`'s override, which reads
-- reasonable and is actively wrong: `/persona` styles *Warden answering as
-- itself* in a chat ("a sarcastic assistant"), while reply_autonomy is
-- ghostwriting as the owner, in the owner's voice, where sounding like a
-- configured bot persona is precisely the failure
-- main.zig's default_reply_as_owner_prompt exists to prevent. Setting a
-- persona on a chat therefore silently made its ghostwritten replies out
-- themselves as an AI. NULL = use that built-in ghostwriter prompt.
ALTER TABLE chat_settings ADD COLUMN reply_autonomy_prompt TEXT;
