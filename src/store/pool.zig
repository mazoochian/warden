const std = @import("std");
const Io = std.Io;
const Db = @import("db.zig").Db;

/// How often `acquire` re-checks the free list while waiting for a
/// connection — same idiom/value as `http_util.zig`'s `fetchWithTimeout`
/// poll loop.
const poll_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// A fixed-size pool of Postgres connections. Replaces `ChatStore`'s
/// `std.StringHashMap(*Db)` (one SQLite connection per chat, free isolation
/// via separate files) — a single shared Postgres database has no such free
/// isolation, so every concurrently-running per-message task now borrows a
/// connection from here for the duration of its queries instead of owning
/// one outright.
///
/// `acquire` used to block forever on an `Io.Semaphore` when the pool was
/// exhausted — no timeout, no way out. Confirmed live (2026-07-22) as the
/// likely cause of a production hang: with per-message concurrency degraded
/// to fully serial-per-platform on a low-core host (see `main.zig`'s
/// `WorkerPool`), a single connection wedged for any reason (network blip to
/// Postgres, a slow query) would silently shrink the pool's usable capacity
/// by one forever, eventually starving every future acquire with nothing to
/// show for it in the logs — the exact same "looks alive, answers nothing"
/// failure mode `8dcbcd8` fixed for HTTP. `acquire` now polls the free list
/// with a bounded wait instead of blocking on a semaphore, returning
/// `error.PoolExhausted` after `acquire_timeout_ns` so a starved pool is a
/// normal, loggable error instead of a silent forever-hang.
pub const PgPool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    conns: []Db,
    free_idx: std.ArrayList(usize),
    mutex: Io.Mutex = .init,
    acquire_timeout_ns: u64,
    /// Kept for the pool's lifetime (not just during `init`) so a poisoned
    /// slot can be reopened later — see `reopenPoisoned`.
    dsn: [:0]const u8,
    statement_timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, dsn: []const u8, size: usize, acquire_timeout_ns: u64, statement_timeout_seconds: i64) !PgPool {
        std.debug.assert(size > 0);
        const dsn_z = try allocator.dupeZ(u8, dsn);
        errdefer allocator.free(dsn_z);

        const conns = try allocator.alloc(Db, size);
        errdefer allocator.free(conns);

        var opened: usize = 0;
        errdefer for (conns[0..opened]) |*conn| conn.close();
        for (conns) |*conn| {
            conn.* = try Db.open(allocator, io, dsn_z, statement_timeout_seconds);
            opened += 1;
        }

        var free_idx: std.ArrayList(usize) = .empty;
        errdefer free_idx.deinit(allocator);
        try free_idx.ensureTotalCapacity(allocator, size);
        for (0..size) |i| free_idx.appendAssumeCapacity(i);

        return .{
            .allocator = allocator,
            .io = io,
            .conns = conns,
            .free_idx = free_idx,
            .acquire_timeout_ns = acquire_timeout_ns,
            .dsn = dsn_z,
            .statement_timeout_seconds = statement_timeout_seconds,
        };
    }

    pub fn deinit(self: *PgPool) void {
        // A poisoned slot's `conn` may still be touched by an abandoned
        // `runWithDeadline` thread at any point in the future (see
        // `Db.poisoned`) — closing it here would race that thread, so it's
        // left leaked, same trade-off `http_util.zig` accepts for a
        // detached-on-timeout HTTP request.
        for (self.conns) |*conn| {
            if (!conn.poisoned) conn.close();
        }
        self.allocator.free(self.conns);
        self.free_idx.deinit(self.allocator);
        self.allocator.free(self.dsn);
    }

    /// Waits up to `acquire_timeout_ns` for a free connection, polling every
    /// `poll_interval_ns` — see this struct's doc comment for why this isn't
    /// an unbounded wait anymore. Returns `error.PoolExhausted` on timeout.
    pub fn acquire(self: *PgPool) !*Db {
        var waited_ns: u64 = 0;
        while (true) {
            if (try self.tryAcquire()) |db| return db;
            if (waited_ns >= self.acquire_timeout_ns) return error.PoolExhausted;
            const step = @min(poll_interval_ns, self.acquire_timeout_ns - waited_ns);
            Io.sleep(self.io, .fromNanoseconds(@intCast(step)), .awake) catch return error.PoolExhausted;
            waited_ns += step;
        }
    }

    fn tryAcquire(self: *PgPool) !?*Db {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const idx = self.free_idx.pop() orelse return null;
        return &self.conns[idx];
    }

    pub fn release(self: *PgPool, db: *Db) void {
        const idx = (@intFromPtr(db) - @intFromPtr(self.conns.ptr)) / @sizeOf(Db);
        if (db.poisoned) {
            self.reopenPoisoned(idx);
            return;
        }
        self.mutex.lockUncancelable(self.io);
        self.free_idx.appendAssumeCapacity(idx);
        self.mutex.unlock(self.io);
    }

    /// A query on this slot blew its deadline (see `Db.runWithDeadline`) —
    /// the old connection is left exactly as-is (leaked; an abandoned
    /// thread may still be touching it) and a fresh one takes its place so
    /// the pool's usable capacity doesn't shrink permanently every time a
    /// connection dies. If the reopen itself fails (Postgres genuinely
    /// unreachable right now), the slot is simply not returned to the free
    /// list — capacity degrades by one instead of looping or panicking; a
    /// pool that runs out entirely surfaces as an ordinary, loggable
    /// `error.PoolExhausted` from `acquire` rather than another silent hang.
    fn reopenPoisoned(self: *PgPool, idx: usize) void {
        const fresh = Db.open(self.allocator, self.io, self.dsn, self.statement_timeout_seconds) catch |err| {
            std.log.err("pg: failed to reopen poisoned connection: {t}", .{err});
            return;
        };
        self.conns[idx] = fresh;
        self.mutex.lockUncancelable(self.io);
        self.free_idx.appendAssumeCapacity(idx);
        self.mutex.unlock(self.io);
    }

    /// Test-only: wraps a single already-open connection the caller still
    /// owns (e.g. `test_support.openTestDb`'s handle), so store-module tests
    /// can exercise pool-based APIs without opening a second real
    /// connection. Must be torn down with `deinitTestWrap`, not `deinit` —
    /// this pool doesn't own `db` or the one-element `conns` slice, so
    /// `deinit`'s `close()`/`free()` would misbehave.
    pub fn wrapForTest(allocator: std.mem.Allocator, io: Io, db: *Db) !PgPool {
        var free_idx: std.ArrayList(usize) = .empty;
        try free_idx.append(allocator, 0);
        return .{
            .allocator = allocator,
            .io = io,
            .conns = @as([*]Db, @ptrCast(db))[0..1],
            .free_idx = free_idx,
            .acquire_timeout_ns = 30 * std.time.ns_per_s,
            .dsn = "",
            .statement_timeout_seconds = 30,
        };
    }

    pub fn deinitTestWrap(self: *PgPool) void {
        self.free_idx.deinit(self.allocator);
    }
};

const testing = std.testing;

test "acquire/release round-trips a connection through the pool" {
    const dsn_z = std.c.getenv("WARDEN_TEST_POSTGRES_DSN") orelse return error.SkipZigTest;
    var pool = try PgPool.init(testing.allocator, testing.io, std.mem.span(dsn_z), 2, 30 * std.time.ns_per_s, 30);
    defer pool.deinit();

    const a = try pool.acquire();
    const b = try pool.acquire();
    try testing.expect(a != b);

    pool.release(a);
    const c = try pool.acquire();
    try testing.expect(c == a);
    pool.release(b);
    pool.release(c);
}

test "acquire returns error.PoolExhausted instead of hanging forever when nothing is free" {
    const io = testing.io;

    // Deliberately not `PgPool.init` — no real Postgres needed to exercise
    // this: `acquire`/`tryAcquire` never dereference `conns[idx]` itself,
    // only `free_idx`, so a single placeholder `Db` (never touched) is
    // enough to test the timeout path in isolation. Regression for the
    // production hang this replaces: `acquire` used to block on an
    // `Io.Semaphore` with no way out at all when every connection was
    // checked out and never returned.
    var conns = [_]Db{.{ .conn = undefined, .allocator = testing.allocator, .io = io, .query_timeout_ns = 30 * std.time.ns_per_s }};
    var pool: PgPool = .{
        .allocator = testing.allocator,
        .io = io,
        .conns = &conns,
        .free_idx = .empty, // nothing available to acquire
        .acquire_timeout_ns = 200 * std.time.ns_per_ms,
        .dsn = "",
        .statement_timeout_seconds = 30,
    };

    const started = Io.Timestamp.now(io, .real);
    const result = pool.acquire();
    const elapsed_ns = Io.Timestamp.now(io, .real).toNanoseconds() - started.toNanoseconds();

    try testing.expectError(error.PoolExhausted, result);
    // Generous upper bound — asserts "didn't hang indefinitely," not exact
    // timing, same shape as `http_util.zig`'s analogous regression test.
    try testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}
