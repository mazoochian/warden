# Storage

One Postgres database (pgvector required). Every store module in
`src/store/` owns one table group and exposes plain functions taking a
`*PgPool`; SQL lives in the functions, never in the callers.

## Connections (`store/db.zig`, `store/pool.zig`)

- `PgPool` is a fixed-size pool (`WARDEN_POSTGRES_POOL_SIZE`). `acquire`
  waits at most `WARDEN_POSTGRES_ACQUIRE_TIMEOUT_SECONDS` and then returns
  `error.PoolExhausted` — never blocks forever. Per-message tasks borrow a
  connection for each query and release it immediately.
- Every connection is opened with `connect_timeout=10` and TCP keepalives
  (`keepalives_idle=20 interval=10 count=3`) appended to the DSN, and sets a
  session `statement_timeout` (`WARDEN_POSTGRES_STATEMENT_TIMEOUT_SECONDS`).
  Both the Docker bridge and the VPS's NAT drop idle connections silently;
  without keepalives a dead connection blocked a libpq call for hours.
- Every query additionally runs under a client-side wall-clock deadline
  (`Db.runWithDeadline`, statement timeout plus slack) on a helper thread.
  On timeout the thread is detached, the connection is marked `poisoned`,
  and `release` replaces it with a fresh one instead of returning it to the
  pool. The done-flag poll backs off from a sub-millisecond start (a flat
  100 ms interval once put a 100 ms floor under every query — 23 min of
  pure sleep in a test run).
- Parameters are bound as text (`bindInt64`, `bindText`, `bindBool`,
  `bindFloat64`, `bindNull`, `bindInt64Array` → `{1,2,3}` for
  `= ANY($n::bigint[])`).

## Migrations (`store/migrate.zig`, `store/migrations/NNNN_name.sql`)

Applied at startup, in order, each inside a transaction with its
`schema_migrations` row; already-applied versions are skipped. **A new
`.sql` file must also be added to the array in `migrate.zig`** or it
silently never runs. Migrations are logged (`applying migration 52 ...`).
Never edit an applied migration; add a new one.

## Tables by area

| Area | Tables |
|---|---|
| Identity & chats | `identities`, `telegram_profiles`, `matrix_profiles`, `xmpp_profiles`, `instagram_*`, `chats`, `chat_members`, `chat_settings`, `user_settings` |
| History | `messages` (`text`, `native_message_id`, `is_summary`, `tool_trace`), `daily_digests` |
| Access | `bot_admins`, `bot_blocked_users`, `bot_blocked_chats`, `bot_pending_grants`, `management_rooms`, `member_permissions`, `rate_limits`, `member_message_cooldowns` |
| Features | `reminders`, `alerts`, `feed_watches`, `notes`, `facts`, `keyword_alerts`, `expenses`, `budgets`, `subscriptions`, `command_aliases`, `prompt_templates`, `announcements`, `reply_drafts`, `feed_*` (curated feed) |
| Config | `feature_flags`, `dynamic_config`, `bot_config` |
| Web | `accounts`, `account_identities`, `web_sessions`, `oauth_providers`, `audit_log` |
| Matrix E2EE | `crypto_account`, `crypto_sessions`, `crypto_megolm_outbound`, `crypto_megolm_inbound` |

Two id spaces: platform-native ids are strings on `Message`; internal ids
are `BIGINT` row ids. `chats.id` ≠ the native chat id, `identities.id` ≠
the native user id. Functions that take one are named or documented
accordingly; mixing them has silently broken guards before.

## Identities

One `identities` row per (platform, native id). The owner therefore has
several identity rows — one per platform — which is why "my X" views must
resolve the whole set (web-api.md). `getOrCreateMinimal` creates
placeholder rows for users first seen as a reply target; usernames are
backfilled when later seen so `@username` targeting works.

## Retention and history

`messages` is pruned per chat to the last `WARDEN_RETENTION_MESSAGES` rows
on every insert. Storage Sense (features.md) can additionally prune by age
and replace old spans with `is_summary` rows. Inbound messages are recorded
for every sender before any access check; a button press or reaction is
not recorded.

## Chats the bot has left

`chats.left_at` marks chats the bot is no longer in (from a connector's
lifecycle signal). `src/cleanup_left_chats.zig` is a one-off tool that
removes their rows; everything referencing a chat is `ON DELETE CASCADE`.
