//! A fixed-size pool of real OS threads that pull work off one shared FIFO-
//! ish queue, one item at a time each. Built to replace `main.zig`'s old
//! reliance on Zig 0.16's implicit, process-wide `Io.Threaded` instance
//! (constructed by the runtime itself in `std/start.zig`, before `root.main`
//! ever runs, with no way for warden to configure it) for per-message
//! concurrency.
//!
//! That implicit pool bounds `Io.Group.async`/`Io.concurrent` to
//! `cpu_count - 1` concurrently-running slots (`Io/Threaded.zig`'s
//! `async_limit`) — confirmed live on the production VPS to be **0** on its
//! single vCPU. Once that bound is hit, a further `.async()` call doesn't
//! queue: it runs the task *synchronously inline on the calling thread*
//! instead. Since every connector's poll loop is the thread that calls
//! `.async()` for its own incoming messages, this meant per-message
//! concurrency was already completely defeated on that host — every message
//! ran serially, inline, on the poll loop's own thread — so a single stuck
//! message (an unbounded blocking call somewhere inside it) froze that
//! connector's poll loop, and therefore that whole platform, permanently.
//!
//! `WorkerPool` sidesteps this by owning its threads outright instead of
//! sharing Zig's implicit pool, sized off detected CPU count with a floor of
//! 2 (see `config.zig`'s `defaultWorkersPerPlatform`) rather than a hidden,
//! unconfigurable, and — on small hosts — degenerate value. A stuck item now
//! occupies exactly one of N worker threads; the other N-1 keep draining the
//! queue, and `push` itself never blocks on processing at all, so the
//! connector's poll loop is never at risk of being blocked by backlog either
//! way.
const std = @import("std");
const Io = std.Io;

/// `Item` should be a small, plain-data value (typically a pointer/handle
/// plus whatever context a task needs) — it's copied into the queue and
/// handed to `run_fn` by value, same shape as the `ptr`+`fn` pattern used
/// elsewhere in this codebase (e.g. `platform.Connector`, `SseLineSink`).
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
        /// Set by `deinit` to tell idle workers to return instead of going
        /// back to sleep on `cond`. Guarded by `mutex` like the queue it's
        /// checked alongside; atomic only so the check itself is race-free.
        stopping: std.atomic.Value(bool) = .init(false),

        /// Spawns `worker_count` real OS threads immediately (each blocks on
        /// the initially-empty queue until `push` wakes one). In production
        /// these are never joined or stopped — same "long-lived, runs for
        /// the whole process, never explicitly awaited" shape as
        /// `main.zig`'s per-connector poll-loop threads and the `Io.Group`
        /// this replaces — so nothing on that path calls `deinit`. It exists
        /// for tests, which would otherwise strand a pool's worth of threads
        /// per test for the rest of the run; see `deinit`.
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
                // Only reachable if a later spawn fails after some earlier
                // ones already succeeded — detach whatever did start rather
                // than leaving them unmanaged, then unwind normally.
                for (self.threads[0..spawned]) |t| t.detach();
                allocator.free(self.threads);
            }
            for (self.threads) |*t| {
                t.* = try std.Thread.spawn(.{}, workerLoop, .{self});
                spawned += 1;
            }
            return self;
        }

        /// Enqueues `item` for some worker to pick up and returns
        /// immediately — just a mutex-guarded append plus a wake-up signal,
        /// never a wait on processing itself. This is what lets a
        /// connector's poll loop keep polling no matter how backed up the
        /// queue gets. Deliberately unbounded: a bounded queue would just
        /// trade "the poll loop never blocks" for a new failure mode (either
        /// dropped messages or the poll loop blocking anyway once the bound
        /// is hit) — a real deployment's message rate is nowhere near what
        /// would make unbounded growth a practical memory concern.
        pub fn push(self: *Self, item: Item) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.queue.append(self.allocator, item);
            self.cond.signal(self.io);
        }

        /// Stops every worker and frees the pool. Only workers that are
        /// *idle* return: an item already being handled runs to completion
        /// first, and anything still queued is dropped rather than drained,
        /// which is what a caller shutting the pool down wants either way.
        ///
        /// Deliberately not called in production (see `init`) — a
        /// long-running warden process has nothing to shut a pool down
        /// *for*, and doing it at exit would only add a way to hang on a
        /// wedged item. Tests are the caller that needs it, so that a test
        /// spawning a server doesn't leave its workers running for the
        /// remainder of the test binary.
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

        /// No ordering guarantee across items (LIFO in practice, via
        /// `pop()` rather than a true FIFO shift) — matches the `Io.Group`
        /// this replaces, which never guaranteed message-processing order
        /// across concurrently-running tasks either. Each message is
        /// handled independently (replies thread through `reply_to`, not
        /// arrival order), so this isn't a behavior change.
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
    // Deliberately not `testing.allocator`: this test exercises the
    // production shape, where the pool is never shut down (its worker
    // threads are meant to run for the whole process, same as `main.zig`'s
    // connector poll threads — see `init`'s doc comment), so it doesn't call
    // the `deinit` that exists for tests that do want to wind one down. A
    // leak-checking allocator would always flag that as a leak even though
    // it's the intended, permanent shape in production. Same
    // reasoning/pattern as `http_util.zig`'s deliberate-leak test.
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
                // Simulates a stuck/slow task (e.g. the unbounded Postgres
                // or LLM calls this pool was built to stop wedging the
                // whole connector) — long enough that if the fast task were
                // blocked behind it, the test's own timeout below would
                // catch it.
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

    // Heap-allocated (leaked deliberately, `page_allocator`, never freed) —
    // NOT stack-local: the slow task's worker thread outlives this test
    // function by design (it's still asleep, 5 seconds, when the test
    // returns after the fast task completes in milliseconds), so a
    // stack-local `var` here would be a real use-after-free once that
    // thread wakes up and writes through a dangling pointer into whatever
    // now occupies this stack frame — confirmed live: this crashed the
    // whole test binary (silently, well after this test itself "passed")
    // before switching to heap allocation.
    const slow_done = try std.heap.page_allocator.create(std.atomic.Value(bool));
    slow_done.* = .init(false);
    const fast_done = try std.heap.page_allocator.create(std.atomic.Value(bool));
    fast_done.* = .init(false);
    // 2 workers: one gets stuck on the slow task, the other must still pick
    // up and finish the fast one — this is the whole point of the pool.
    // Deliberately not `testing.allocator` — see the previous test's doc
    // comment for why a pool with no `deinit` needs a non-leak-checking
    // allocator here.
    const pool = try Pool.init(std.heap.page_allocator, io, 2, SlowThenFastTask.run);

    try pool.push(.{ .io = io, .kind = .slow, .slow_done = slow_done, .fast_done = fast_done });
    try pool.push(.{ .io = io, .kind = .fast, .slow_done = slow_done, .fast_done = fast_done });

    var waited_ms: usize = 0;
    while (!fast_done.load(.acquire) and waited_ms < 2000) {
        Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
        waited_ms += 10;
    }
    try testing.expect(fast_done.load(.acquire));
    // The slow task must still be running at this point (its 5s sleep
    // hasn't elapsed yet) — proving the fast task didn't just happen to run
    // first by coincidence of queue order.
    try testing.expect(!slow_done.load(.acquire));
}
