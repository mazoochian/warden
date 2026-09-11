# Open notes

Two things found on 2026-09-09 while checking over the working tree. Neither
is fixed here — both need a decision that isn't mine to make.

## 1. Every database query pays a hard 100 ms floor

`src/store/db.zig:18` sets `poll_interval_ns = 100 * ns_per_ms`.
`runWithDeadline` (`db.zig:191`) spawns an OS thread per query and then waits
for it like this:

```zig
while (!outcome.done.load(.acquire) and waited_ns < db.query_timeout_ns) {
    const step = @min(poll_interval_ns, db.query_timeout_ns - waited_ns);
    Io.sleep(db.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
    waited_ns += step;
}
```

There is no fast path. The flag is checked, then the caller sleeps a full
100 ms before checking again, so a query that finished in 200 µs still costs
100 ms of wall clock. Both query entry points go through it — `Db.exec`
(`db.zig:147`) and `Stmt.ensureExecuted` (`db.zig:299`) — so this is every
query in the process, production included, not just tests.

What it costs the test suite: `openTestDb` (`store/test_support.zig:11`) is
~55 queries before a test body runs at all — one `SET statement_timeout`, one
`CREATE TABLE IF NOT EXISTS schema_migrations`, 51 `isApplied` checks (one per
migration in `store/migrate.zig`), then `TRUNCATE` + the `feed_settings`
reseed. At 100 ms each that is ~5.5 s of pure sleeping per DB-backed test,
before the test does anything. There are 223 `openTestDb` call sites across 55
files.

Measured, same machine, same build:

| run | tests | reported step time |
|---|---|---|
| `-Dtest-filter="parsePollCommand"` | 3, no DB | **9 ms** |
| `-Dtest-filter="convert endpoint"` | 2, one DB | **11 s** |
| full suite, prebuilt binary run directly | 790 | **22 min 41 s** |

The full-suite time is essentially all of it: that run used an already-built
binary, so no compilation was involved. Postgres is not the bottleneck — a
`truncateAll` measured ~50 ms of real work, and the whole 51-row migration
check is a few ms of actual query time.

Worth deciding: the poll loop exists to enforce a client-side deadline around
a blocking libpq call (see `runWithDeadline`'s doc comment and `Db.poisoned`
for why the thread is abandoned rather than joined on timeout). Keeping that
property while losing the floor means signalling completion instead of
polling for it — a `std.Thread.ResetEvent`/condvar the runner sets and the
caller waits on with a timeout. Dropping `poll_interval_ns` to ~1 ms would
also get most of it back for far less risk, at the cost of more wakeups.

Not touched here because it is core DB code on every request path.

## 2. The API tests leave a `serve` thread running after they finish

`src/api/server.zig:759` and `:829` both do:

```zig
const thread = try std.Thread.spawn(.{}, serve, .{ ctx, listener, @as(usize, 2) });
thread.detach();
```

`ctx`, `pool`, `config` and `listener` are deliberately leaked onto
`page_allocator` so the thread's pointers stay valid — that part is fine and
intentional. What is not handled is that nothing ever stops the thread: the
accept loop and its two pool workers are still live when the test returns,
and stay live for the rest of the process.

Visible symptom: the test binary exits abnormally during teardown, so
`zig build test` prints

```
failed command: ./.zig-cache/o/<hash>/test --cache-dir=./.zig-cache --seed=0x... --listen=-
```

even on a fully green run. This is cosmetic today — the build runner has
already collected the results by then, so both the summary and the exit code
are correct. Verified:

- `zig build test --summary all -Dtest-filter="convert endpoint"` →
  `failed command:` **and** `Build Summary: 3/3 steps succeeded; 2/2 tests passed`,
  exit 0.
- The same binary run directly, outside the build runner, exits 0 cleanly with
  `All 2 tests passed.` on three consecutive runs.
- Full suite run directly: `786 passed; 4 skipped; 0 failed`.

It reproduces with the pre-existing `convert endpoint` test
(`server.zig:735`) on its own, so it is not new to the malformed-request-head
test added alongside it.

Why it is still worth fixing: this is the same shape as the bug the
`.github/workflows/ci.yml` comment warns about at length — a detached thread
outliving the stack frame it borrowed from, faulting later, and getting blamed
on whatever unrelated test held the main thread at that moment. Here the
borrowed state is leaked on purpose so it does not fault, but the pattern is
one edit away from doing so, and it already costs a confusing line in every
CI log. A shutdown signal on `serve` (or a test-only variant that accepts a
bounded number of connections and returns) would close it.
