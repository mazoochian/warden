# Access control

Warden is owner-centric: one person (per platform, via `Config.owners`)
owns the bot; everything else is a delegation from them.

## Tiers

| Tier | Who | How it is determined |
|---|---|---|
| Owner | The configured account on each platform | `auth.isOwner`: platform + native user id match. The owner is implicitly a bot admin everywhere a bot admin is checked. |
| Bot admin | Accounts the owner (or another bot admin) granted with `/addadmin` | `bot_admins` table. Bot-wide, not chat-scoped. |
| Platform admin | A live administrator of the current chat | `Connector.isGroupAdmin` (a real API call per check; fails closed on error) |
| Everyone else | — | — |

`/sudo <command>` lets a bot admin run a moderation command in a chat they
are not a platform admin of. The bot announces the elevation in the chat
("X has been granted superuser permissions for action: kick"), so it is
never silent. `sudo_active` is only ever true after that prefix has been
verified for a bot admin.

## Who may do what

- **Talk to the bot at all** (`routeIncoming` in `main.zig`): everyone,
  unless the sender or the whole chat is on the blocklist. The owner and
  bot admins can never be blocked. The gate is silent — a blocked sender
  gets nothing, not an error. Messages are still *recorded* (history,
  stats, keyword alerts) regardless; the gate only controls whether the bot
  acts.
- **Free-form LLM Q&A** (mention, reply to the bot, magic word, private
  chat): owner and bot admins, unless `WARDEN_LLM_OWNER_ONLY=false`, in
  which case anyone not blocked. This is the gate that protects the model
  bill. Silent when denied. Trivial greetings get a canned reply before
  this gate (no model call, so no cost).
- **Moderation commands** (`/mute /unmute /kick /ban /pin /unpin /delete
  /redact /slowmode /permission /tag /confirm /cancel /chatinfo`):
  `auth.checkGroupAdminAccess` — owner, then `/sudo`, then a live platform
  admin; otherwise denied silently. `/redact regex` and `/promote`/
  `/demote` are stricter (owner or `/sudo`, and owner only respectively).
- **Chat configuration** (`/persona /welcome /location /magicword /budget
  /thinking ...`): viewing is open to anyone in the chat; changing is
  owner-only (or admin-tier where noted in commands.md).
- **Bot-wide management** (`/addadmin /removeadmin /blockuser /unblockuser
  /blockchat /unblockchat /scraper`): owner or bot admin
  (`auth.isOwnerOrBotAdmin`); no platform-admin fallback.
- **Owner only, never delegated**: `/storage`, `/tdlogin`, `/iglogin`,
  `/sendas`, `/autonomy`, `/feed`, the personal-account LLM tools, and
  anything that acts through the owner's own accounts.
- **Per-record features** (notes, expenses, subscriptions, aliases,
  templates, keyword alerts): anyone in the chat may add; only the creator
  or the owner may delete (`isRecordOwnerOrCreator`).

The `/menu` button system enforces the same tiers per node (`MinRole`);
its `chat_admin` tier is owner-or-live-platform-admin only, with no `/sudo`
equivalent for a button press.

## The blocklist

`bot_blocked_users` / `bot_blocked_chats` (`src/store/bot_blocklist.zig`).
`/blockuser` accepts a reply, `@username`, or a raw native id; for a
`@username` the bot has never seen, the block is queued in
`bot_pending_grants` and applied the moment that username first appears
(same mechanism `/addadmin @name` uses). Blocking the owner or a bot admin
is refused. The blocklist check fails *open* on a database error — it is a
moderation convenience, not the security boundary; the owner-only LLM gate
and the admin ladder are enforced separately.

History: until 2026-09-19 this was an allowlist plus a per-identity LLM
credit balance and per-chat moderation tokens. All three were removed;
see decisions.md.

## Management rooms and `/as`

A **management room** is a chat bound 1:1 to a target chat (`/manage bind
<chat id>`), for targets with no back-and-forth of their own (channels).
A relayable command typed in the room runs against the target as if typed
there, with replies redirected back to the room (`reply_redirect.zig`).
`/as <chat id> <command>` does the same for one command without a binding.
Only commands in `as_relayable_commands` may be relayed — moderation,
per-chat settings, blocks, announcements and read-only reports; stateful
flows (`/menu`, `/convert`, `/confirm`), `/sudo`, and LLM-backed commands
are excluded. Authorisation is against the *target* chat's admins
(`auth.isOwnerOrLiveAdminOfChat`).

## Audit log and undo

Every admin action (chat commands and web API alike) writes an
`audit_log` row. When the target chat has a bound management room, a
structured entry is also posted there with an **Undo** button for actions
with a clean inverse: mute (→ unmute), promote (→ demote if they weren't
admin before), demote (→ promote if they were). Kick/ban/unmute and the
title/description/photo changes are logged but not undoable. Undo state
lives in memory for 24 h, keyed by (room, prompt message).

`-s` on a moderation/settings command (or `/silent on` for the chat) skips
the in-chat confirmation message; the audit entry is written regardless.

## Web sessions

The web API resolves an account's roles from its linked identities:
owner if any linked identity is a configured owner, bot admin if any is in
`bot_admins`. See web-api.md.
