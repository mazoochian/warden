# Open notes

One thing found on 2026-09-09 while checking over the working tree, still
unfixed — it needs a decision that isn't mine to make.

The other note here, "every database query pays a hard 100 ms floor", was
fixed on 2026-09-13: `runWithDeadline`'s poll interval now backs off from
50 us instead of sitting flat at 100 ms, and `migrate()` reads
`schema_migrations` in one query instead of one probe per migration. Full
suite went 23m24s -> 46s, 821 pass / 4 skip. The reasoning lives in the doc
comments on `db.zig`'s poll-interval constants and above the loop in
`migrate.zig`.

## The API tests leave a `serve` thread running after they finish

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
