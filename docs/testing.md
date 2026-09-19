# Testing

```
zig fmt --check .        # CI's first step; per-file checks miss violations
zig build                # the real executable
zig build test           # the suite (~45 s with a local Postgres)
zig build test -Dtest-filter="<substring>"
```

Run **both** `zig build` and `zig build test`: the test build can pass
while the executable has a compile error in code no test reaches.

## Test registration

- A new test file must be referenced from the `test { _ = @import(...) }`
  block at the bottom of `src/main.zig`, or its tests never run.
- A new migration must be added to the array in `store/migrate.zig`, or
  it never applies (locally *and* in production).

## The test database

DB-backed tests need `WARDEN_TEST_POSTGRES_DSN` (a database with the
`vector` extension; migrations run automatically). Tests that can't reach
it return `error.SkipZigTest`, so a suite that skips DB tests still looks
green — check the skip count (4 expected: XMPP live tests and similar).

`test_support.openTestDb` truncates every table at the start of **each**
test, so never run two `zig build test` processes against the same
database at once (parallel worktrees need separate databases); the
failures that produces look like real regressions in unrelated modules.

## Conventions

- Store tests use `PgPool.wrapForTest` around one connection.
- Connector/provider behaviour is tested with stub vtables
  (`StubConnector` in `auth.zig`, `FakeProvider`/`ScriptedProvider` in
  `toolcall.zig`, `Recorder` sinks in the adapters) — no network.
- `std.testing` treats an `err`-level log during a test as a failure, so a
  test exercising an error path must avoid triggering `log.err`, or the
  code path must log at `warn`.
- Comptime-known literals in test configs are load-bearing: a
  `Config.owners` slice built from a runtime string dangles once the
  helper returns (see the `testConfig` note in `auth.zig`).

## Live tests

XMPP connector tests run only with `WARDEN_TEST_XMPP_HOST` set. Matrix
E2EE has no automated live test — verify against a real client after any
crypto change. The web API tests spin up a real server on a random port.

## Known local flakes

`store.crypto`'s `loadInboundGroupSession` test can ABRT locally on a
clean tree; it is not a regression from unrelated work.
