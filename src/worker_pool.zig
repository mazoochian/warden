//! A fixed-size pool of real OS threads that pull work off one shared FIFO-
//! ish queue, one item at a time each.
const std = @import("std");
const Io = std.Io;

/// `Item` should be a small, plain-data value (typically a pointer/handle
/// plus whatever context a task needs).
pub fn WorkerPool(comptime Item: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: Io,
        threads: []std.Thread,
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        queue: std.ArrayList(Item) = .empty,
        run_fn: *const fn (Item) void,
        /// Set by `deinit` to tell idle workers to return instead of going back to
        /// sleep on `cond`.
        stopping: std.atomic.Value(bool) = .init(false),

        /// Spawns `worker_count` real OS threads immediately (each blocks on the
        /// initially-empty queue until `push` wakes one).
        pub fn init(allocator: std.mem.Allocator, io: Io, worker_count: usize, run_fn: *const fn (Item) void) !*Self {
            std.debug.assert(worker_count > 0);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .io = io,
                .threads = try allocator.alloc(std.Thread, worker_count),
                .run_fn = run_fn,
            };

            var spawned: usize = 0;
            errdefer {
                // Only reachable if a later spawn fails after some earlier ones already
                // succeeded.
                for (self.threads[0..spawned]) |t| t.detach();
                allocator.free(self.threads);
            }
            for (self.threads) |*t| {
                t.* = try std.Thread.spawn(.{}, workerLoop, .{self});
                spawned += 1;
            }
            return self;
        }

        /// Enqueues `item` for some worker to pick up and returns immediately.
        pub fn push(self: *Self, item: Item) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.queue.append(self.allocator, item);
            self.cond.signal(self.io);
        }

        /// Stops every worker and frees the pool.
        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopping.store(true, .release);
            self.cond.broadcast(self.io);
            self.mutex.unlock(self.io);

            for (self.threads) |t| t.join();

            self.queue.deinit(self.allocator);
            self.allocator.free(self.threads);
            self.allocator.destroy(self);
        }

        /// No ordering guarantee across items (LIFO in practice, via `pop()` rather
        /// than a true FIFO shift) — matches the `Io.Group` this replaces.
        fn workerLoop(self: *Self) void {
            while (true) {
                self.mutex.lockUncancelable(self.io);
                while (self.queue.items.len == 0) {
                    if (self.stopping.load(.acquire)) {
                        self.mutex.unlock(self.io);
                        return;
                    }
                    self.cond.waitUncancelable(self.io, &self.mutex);
                }
                const item = self.queue.pop().?;
                self.mutex.unlock(self.io);
                self.run_fn(item);
            }
        }
    };
}

const testing = std.testing;

const CounterTask = struct {
    counter: *std.atomic.Value(usize),

    fn run(self: CounterTask) void {
        _ = self.counter.fetchAdd(1, .monotonic);
    }
};

test "WorkerPool drains every pushed item exactly once, even with a single worker" {
    const io = testing.io;
    const Pool = WorkerPool(CounterTask);

    var counter: std.atomic.Value(usize) = .init(0);
    // Deliberately not `testing.allocator`.
    const pool = try Pool.init(std.heap.page_allocator, io, 1, CounterTask.run);

    const n = 50;
    for (0..n) |_| try pool.push(.{ .counter = &counter });

    var waited_ms: usize = 0;
    while (counter.load(.monotonic) < n and waited_ms < 5000) {
        Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
        waited_ms += 10;
    }
    try testing.expectEqual(@as(usize, n), counter.load(.monotonic));
}

const SlowThenFastTask = struct {
    const Kind = enum { slow, fast };

    io: Io,
    kind: Kind,
    slow_done: *std.atomic.Value(bool),
    fast_done: *std.atomic.Value(bool),

    fn run(self: SlowThenFastTask) void {
        switch (self.kind) {
            .slow => {
                // Simulates a stuck/slow task (e.g. the unbounded Postgres or LLM calls this
                // pool was built to stop wedging the whole connector).
                Io.sleep(self.io, .fromSeconds(5), .awake) catch {};
                self.slow_done.store(true, .release);
            },
            .fast => self.fast_done.store(true, .release),
        }
    }
};

test "a slow task never blocks a concurrently-queued fast task from completing" {
    const io = testing.io;
    const Pool = WorkerPool(SlowThenFastTask);

    // Heap-allocated (leaked deliberately, `page_allocator`, never freed) — NOT
    // stack-local.
    const slow_done = try std.heap.page_allocator.create(std.atomic.Value(bool));
    slow_done.* = .init(false);
    const fast_done = try std.heap.page_allocator.create(std.atomic.Value(bool));
    fast_done.* = .init(false);
    // 2 workers: one gets stuck on the slow task, the other must still pick up
    // and finish the fast one — this is the whole point of the pool.
    const pool = try Pool.init(std.heap.page_allocator, io, 2, SlowThenFastTask.run);

    try pool.push(.{ .io = io, .kind = .slow, .slow_done = slow_done, .fast_done = fast_done });
    try pool.push(.{ .io = io, .kind = .fast, .slow_done = slow_done, .fast_done = fast_done });

    var waited_ms: usize = 0;
    while (!fast_done.load(.acquire) and waited_ms < 2000) {
        Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
        waited_ms += 10;
    }
    try testing.expect(fast_done.load(.acquire));
    // The slow task must still be running at this point (its 5s sleep hasn't
    // elapsed yet).
    try testing.expect(!slow_done.load(.acquire));
}
