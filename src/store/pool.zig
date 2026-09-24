const std = @import("std");
const Io = std.Io;
const Db = @import("db.zig").Db;
const log = @import("../log.zig").scoped("postgres");

/// How often `acquire` re-checks the free list while waiting for a connection
/// — same idiom/value as `http_util.zig`'s `fetchWithTimeout` poll loop.
const poll_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// A fixed-size pool of Postgres connections.
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
            conn.* = Db.open(allocator, io, dsn_z, statement_timeout_seconds) catch |err| {
                log.err("failed to open connection {d}/{d}: {t}", .{ opened + 1, size, err });
                return err;
            };
            opened += 1;
            log.debug("opened connection {d}/{d}", .{ opened, size });
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
        // `runWithDeadline` thread at any point in the future (see `Db.poisoned`).
        for (self.conns) |*conn| {
            if (!conn.poisoned) conn.close();
        }
        self.allocator.free(self.conns);
        self.free_idx.deinit(self.allocator);
        self.allocator.free(self.dsn);
    }

    /// Waits up to `acquire_timeout_ns` for a free connection, polling every
    /// `poll_interval_ns`.
    pub fn acquire(self: *PgPool) !*Db {
        var waited_ns: u64 = 0;
        while (true) {
            if (try self.tryAcquire()) |db| {
                // Only logged once actual waiting happened (not on the common instant-acquire
                // path).
                if (waited_ns > 0) {
                    log.debug("acquired after waiting {d}ms", .{@divTrunc(waited_ns, std.time.ns_per_ms)});
                }
                return db;
            }
            if (waited_ns >= self.acquire_timeout_ns) {
                log.warn("pool exhausted, gave up after {d}ms", .{@divTrunc(waited_ns, std.time.ns_per_ms)});
                return error.PoolExhausted;
            }
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

    /// A query on this slot blew its deadline (see `Db.runWithDeadline`).
    fn reopenPoisoned(self: *PgPool, idx: usize) void {
        log.warn("connection slot {d} poisoned (query blew its deadline), reopening", .{idx});
        const fresh = Db.open(self.allocator, self.io, self.dsn, self.statement_timeout_seconds) catch |err| {
            log.err("failed to reopen poisoned connection (slot {d} stays out of the pool): {t}", .{ idx, err });
            return;
        };
        self.conns[idx] = fresh;
        self.mutex.lockUncancelable(self.io);
        self.free_idx.appendAssumeCapacity(idx);
        self.mutex.unlock(self.io);
        log.notice("connection slot {d} reopened and back in the pool", .{idx});
    }

    /// Test-only: wraps a single already-open connection the caller still owns
    /// (e.g. `test_support.openTestDb`'s handle).
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

    // Deliberately not `PgPool.init` — no real Postgres needed to exercise this.
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
