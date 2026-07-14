const std = @import("std");
const Io = std.Io;
const Db = @import("db.zig").Db;

/// A fixed-size pool of Postgres connections. Replaces `ChatStore`'s
/// `std.StringHashMap(*Db)` (one SQLite connection per chat, free isolation
/// via separate files) — a single shared Postgres database has no such free
/// isolation, so every concurrently-running per-message task now borrows a
/// connection from here for the duration of its queries instead of owning
/// one outright.
///
/// `acquire`/`release` are guarded by `Io.Semaphore` (blocks the caller
/// until a connection frees up rather than erroring) plus an `Io.Mutex`
/// around the free-list itself.
pub const PgPool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    conns: []Db,
    free_idx: std.ArrayList(usize),
    mutex: Io.Mutex = .init,
    sem: Io.Semaphore,

    pub fn init(allocator: std.mem.Allocator, io: Io, dsn: []const u8, size: usize) !PgPool {
        std.debug.assert(size > 0);
        const dsn_z = try allocator.dupeZ(u8, dsn);
        defer allocator.free(dsn_z);

        const conns = try allocator.alloc(Db, size);
        errdefer allocator.free(conns);

        var opened: usize = 0;
        errdefer for (conns[0..opened]) |*conn| conn.close();
        for (conns) |*conn| {
            conn.* = try Db.open(allocator, dsn_z);
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
            .sem = .{ .permits = size },
        };
    }

    pub fn deinit(self: *PgPool) void {
        for (self.conns) |*conn| conn.close();
        self.allocator.free(self.conns);
        self.free_idx.deinit(self.allocator);
    }

    /// Blocks until a connection is free.
    pub fn acquire(self: *PgPool) !*Db {
        try self.sem.wait(self.io);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        // A permit was obtained above, so the free list is guaranteed
        // non-empty here.
        const idx = self.free_idx.pop().?;
        return &self.conns[idx];
    }

    pub fn release(self: *PgPool, db: *Db) void {
        const idx = (@intFromPtr(db) - @intFromPtr(self.conns.ptr)) / @sizeOf(Db);
        self.mutex.lockUncancelable(self.io);
        self.free_idx.appendAssumeCapacity(idx);
        self.mutex.unlock(self.io);
        self.sem.post(self.io);
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
            .sem = .{ .permits = 1 },
        };
    }

    pub fn deinitTestWrap(self: *PgPool) void {
        self.free_idx.deinit(self.allocator);
    }
};

const testing = std.testing;

test "acquire/release round-trips a connection through the pool" {
    const dsn_z = std.c.getenv("WARDEN_TEST_POSTGRES_DSN") orelse return error.SkipZigTest;
    var pool = try PgPool.init(testing.allocator, testing.io, std.mem.span(dsn_z), 2);
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
