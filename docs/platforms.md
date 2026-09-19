# Platforms

Every platform is a `Connector` (`src/platform/interface.zig`). The
`Platform` enum also lists `discord` and `whatsapp`, which have no
connector — they exist so ids and stored rows are future-proof.

Capability matrix (✓ implemented, ~ partial, — not available):

| Capability | Telegram bot | Matrix | XMPP | Telegram user | Instagram |
|---|---|---|---|---|---|
| Receive/send text | ✓ | ✓ (plaintext + E2EE) | ✓ (1:1 + MUC) | ✓ | ✓ (DMs) |
| Edit / delete messages | ✓ | ✓ | — | — | — |
| Photos / documents | ✓ | ✓ (unencrypted media only) | — | — | ~ |
| Buttons / choice prompts | ✓ inline keyboards | ~ reactions | — | — | — |
| Moderation (mute/kick/ban/promote/pin) | ✓ | ✓ | ✓ (MUC roles/affiliations) | — | — |
| `/permission` bitmask | ✓ | ~ (write only) | — | — | — |
| Is-admin check | ✓ | ✓ | ✓ | — | — |
| Slow mode enforcement | ✓ | ✓ | — | — | — |
| Commands menu (`setCommands`) | ✓ | — | — | — | — |
| Voice/attachment download | ✓ | ✓ | — | — | — |

## Telegram Bot API (`platform/telegram/`)

The primary platform; everything is built here first. `client.zig` wraps
the HTTP API; `connector.zig` maps updates to `Message`s.

- Long-polls `getUpdates`; a poll that fails returns immediately, and the
  poll loop sleeps 5 s before retrying so an outage doesn't spin.
- `my_chat_member` updates are turned into synthetic "chat ingest only"
  messages — the only reliable way a *channel* (which never emits ordinary
  message updates) becomes a `chats` row.
- Every message's `from` is folded into a full `Identity`; replied-to and
  mentioned users are reported as `observed_users` so `find_chat_member`
  can resolve people who never spoke.
- Replies are sent as HTML (`markdown_html.zig`) with a plain-text
  fallback. JSON payloads must omit null optional fields
  (`emit_null_optional_fields = false`) — an explicit `"reply_parameters":
  null` is rejected by the API and once broke every unprompted send.
- `/tag` uses `setChatAdministratorCustomTitle`, which only works on chat
  administrators.
- Message size cap 4096 bytes; the tightest of any platform, so it is the
  effective cap when several connectors run.

## Matrix (`platform/matrix/`)

`/sync` long-polling against the Client-Server API. Every room is treated
as a group (no `m.direct` lookup yet), so the bot must be mentioned even in
a DM. The bot auto-joins on invite. Departures are recorded from `leave`
events even on the discarded first sync.

**E2EE** (`crypto.zig` over `olm.zig`, a libolm FFI binding; enabled by
`WARDEN_MATRIX_PICKLE_KEY`):

- Device keys and one-time keys are created on first run, persisted
  pickled in Postgres (`store/crypto.zig`), and uploaded. The one-time-key
  pool is topped up whenever `/sync` reports it below half of libolm's
  maximum — it used to be generated once and never replenished.
- Startup fails loudly if the persisted account's device id doesn't match
  the access token's device (reusing a device already initialised by
  another client produces keys nobody validates).
- Outbound: Megolm session per room, shared to every device in the room
  via Olm to-device events. Whether a room is encrypted is cached
  positively and never evicted, so a transient failure to re-check can
  never downgrade a message to plaintext.
- Only text is encrypted; `sendPhoto`/`sendDocument` send unencrypted
  media. Choice-prompt reactions are sent encrypted but picks can't be read
  back in an encrypted room yet.
- `m.relates_to` is kept outside the encrypted payload (clients need it in
  the clear for edits/replies/reactions).
- Interactive SAS/emoji verification (`verification.zig`) is *responded
  to* only — the bot never initiates and never verifies another user's
  device. Modern methods only (`curve25519-hkdf-sha256`,
  `hkdf-hmac-sha256.v2`, sha256 commitment).
- The pickle key must be stable across restarts.

Six real send-side bugs were found during live verification (envelope
fields, room_id placement, `relates_to`, canonical JSON key order, the
KEY_IDS MAC, a `sendToDevice` leak) — the encrypt path can *look* right
while producing events no client decrypts. Always verify E2EE changes
against a real client.

## XMPP (`platform/xmpp/`)

Persistent socket rather than HTTP: `ensureConnected` drives
connect → STARTTLS → SASL (SCRAM-SHA-256 / SHA-1 / PLAIN) → bind → MUC
join lazily on first poll and after any loss. `xml.zig` is a small
streaming parser (CDATA, both quote styles, the five standard entities).

- One background read outlives poll timeouts: an idle poll must not tear
  the connection down (an earlier version reconnected every ~8 s on quiet
  servers and leaked a thread + socket each time).
- Every server-initiated `<iq type='get'/'set'>` gets a reply: XEP-0199
  ping → result, anything else → `feature-not-implemented` (spec-compliant
  and enough to prove liveness).
- Moderation maps to MUC roles/affiliations (XEP-0045 §9). No OMEMO, no
  file transfer, no `/permission` bitmask, no `/tag`, no message deletion.
- `WARDEN_XMPP_TLS_MODE` controls certificate verification for
  self-hosted servers.

## Personal Telegram account (`platform/telegram/user_connector.zig`)

TDLib (`tdjson`) driving the *owner's own* account — a separate
`Platform.telegram_user` connector, never the same object as the bot.

- Login is interactive: phone → code → optional 2FA password, driven by
  `/tdlogin` from whichever connector the owner is talking to the bot on.
  Once `authorizationStateReady`, TDLib persists the session in
  `WARDEN_TELEGRAM_USER_SESSION_DIR`; restarts need no re-login.
- Only `updateNewMessage` is converted; the account's own outgoing
  messages are dropped, so every delivered message is from someone else.
  Consequently this connector never dispatches commands and never applies
  the blocklist — its messages go straight to reply autonomy
  (features.md). Messages must never be marked read automatically; only
  `/tdsummary` and `summarize_unread_chat` do so deliberately.
- Requests that need a response (`getChat`, `getChatHistory`,
  `viewMessages`, `searchPublicChat`) are correlated via TDLib's `@extra`
  field; the caller blocks on a bounded poll while the poll-loop thread
  fills the response map.
- A chat-id → title map is built from `updateNewChat` bursts for
  `/tdchats` / `/tdsearch`.
- The bot's own DM with the owner is identified by chat id
  (`isOwnBotDm`, derived from the bot token's `<id>:` prefix) and never
  drafted for — drafting replied to its own notifications in a loop once.

## Instagram (`platform/instagram/`)

Private-API DM connector for the owner's account, best effort and
documented as such: `auth.zig` (login, challenge/2FA flow, password
encryption needing a current public key from `WARDEN_INSTAGRAM_PASSWORD_*`),
`transport.zig` (signed requests over `http_util`), `direct.zig` (inbox
polling), `policy.zig` (pause/resume backoff on rate limits or
checkpoints), `session.zig` (persisted device profile + cookies in
Postgres). `/iglogin` drives it. There is no reply-autonomy path for
Instagram, so its DMs are not answered automatically.

## Adding a platform

Implement the `VTable` core (`platform`, `poll`, `sendMessage`), declare
`maxMessageLength`, add the connector in `main` behind a config check, add
an owner entry in `Config.owners`, and give the new `Platform` value a
branch wherever `switch (platform)` is exhaustive. Optional slots can be
added incrementally; every caller already tolerates `error.Unsupported`.
