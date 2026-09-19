# Web API

The HTTP + WebSocket server behind **warden-ui** (a separate repository).
The endpoint contract — paths, bodies, status codes — is documented in
warden-ui's `API.md`; this page covers the server side.

Off unless `WARDEN_API_PORT` is set. `api_server.run` accepts on a
dedicated thread with `WARDEN_API_WORKERS` connection workers; a startup
failure is logged, never fatal to the bot.

## Modules

| File | Role |
|---|---|
| `api/server.zig` | Accept loop, connection workers, WebSocket upgrade, `ServerContext` |
| `api/router.zig` | Method+path dispatch, every handler, JSON helpers, session resolution |
| `api/auth.zig` | Session cookie: `<session_id>.<base64url(HMAC-SHA256)>`, timing-safe verify; session state itself is in `web_sessions` |
| `api/oidc.zig` | Authorization Code + PKCE login against configured providers (`oauth_providers`) |
| `api/rate_limit.zig` | Fixed-window limits: 20 auth attempts/min, 10 Bot View sends/min per account |
| `api/multipart.zig` | Minimal `multipart/form-data` parser for the convert endpoint |
| `api/bot_view.zig` | In-memory pub/sub of incoming messages to WebSocket subscribers |
| `store/admin_directory.zig` | Read-only stats and directories for the admin pages |

## Accounts, identities, roles

Login (OIDC; `WARDEN_API_DEV_LOGIN` enables a dev-only `POST
/auth/dev-login` by identity id) resolves or creates an `accounts` row
linked to the `identities` row the provider vouched for — today that is
the Telegram identity. Roles are computed per request from every linked
identity: **owner** if any is a configured owner, **bot_admin** if any is
in `bot_admins`.

"My …" list endpoints (notes, reminders, alerts, watches, memory,
expenses, subscriptions) scope by `callersIdentityIds`: the account's
linked identities plus, for the owner, every configured owner identity
across platforms. Creating on behalf of a chat picks whichever of those
identities is a member of that chat. An explicit `?identity_id=` /
`identity_id` in the body is owner/bot-admin only. Display preferences
(timezone, date format) come from the primary (first linked) identity.

## Authorisation

- `requireLoggedIn` → any account; `requireAdmin` → owner or bot admin;
  `requireOwner` → owner only (Storage Sense, drafts, personal-account
  pages, Bot View WebSocket and send-as-bot).
- Chat-scoped actions (`/api/v1/chats/:id/actions/*`) reuse
  `auth.checkGroupAdminAccess` with a synthetic `Message` standing in for
  "the caller, in that chat"; a logged-in bot admin counts as `sudo_active`
  (there is no prefix to type in a form), and the elevation message is
  still sent into the real chat. Every mutating call writes `audit_log`.
- Feature-flag checks mirror the bot's own (`POST /notes` is refused when
  the notes module is off).

## Bot View

`GET /api/v1/bot-view/ws?chat_id=` upgrades to a WebSocket and streams
messages as they are recorded (`bot_view.Broadcaster.publish` is called
right after `recordMessage`). Each connection owns a `Subscriber` with its
own queue; publishing appends and signals, never touches the wire, so a
slow client can't block message processing. `respondWebSocket` never
auto-flushes. `POST /bot-view/send` sends through the chat's connector as
the bot.

## Admin config

`GET/PATCH /admin/config` exposes the dynamic-config keys
(configuration.md); secrets are reported as set/unset only.
`WARDEN_LLM_PROVIDER` can only be switched to a provider that has
credentials. `/admin/modules` lists every known feature flag with its
current state.

## Request handling notes

- Bodies are read with `readJsonBody` before any response is written;
  handlers that need the `user-agent` capture it first.
- Responses are JSON with `{error, message}` on failure; `404` (not `403`)
  is used where confirming existence to a non-owner would leak.
- A malformed request head is answered and the connection closed rather
  than aborting the process.
