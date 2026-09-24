//! Fixed-window rate limiting for the web API's auth endpoints and Bot
//! View's send endpoint.
const std = @import("std");
const Io = std.Io;

const Bucket = struct {
    window_start: i64,
    count: u32,
};

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    buckets: std.StringHashMapUnmanaged(Bucket) = .empty,
    max_per_window: u32,
    window_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, max_per_window: u32, window_seconds: i64) Limiter {
        return .{ .allocator = allocator, .io = io, .max_per_window = max_per_window, .window_seconds = window_seconds };
    }

    pub fn deinit(self: *Limiter) void {
        var it = self.buckets.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.buckets.deinit(self.allocator);
    }

    /// `true` if `key` is still under its limit for the window containing `now`
    /// (and counts this call toward it); `false` if the window's budget is
    /// already spent.
    pub fn allow(self: *Limiter, key: []const u8, now: i64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.buckets.getPtr(key)) |bucket| {
            if (now - bucket.window_start >= self.window_seconds) {
                bucket.window_start = now;
                bucket.count = 1;
                return true;
            }
            if (bucket.count >= self.max_per_window) return false;
            bucket.count += 1;
            return true;
        }

        const owned_key = self.allocator.dupe(u8, key) catch return true; // fail open on OOM
        self.buckets.put(self.allocator, owned_key, .{ .window_start = now, .count = 1 }) catch {
            self.allocator.free(owned_key);
            return true;
        };
        return true;
    }
};

const testing = std.testing;

test "allow permits up to max_per_window, then denies within the same window" {
    var limiter = Limiter.init(testing.allocator, testing.io, 3, 60);
    defer limiter.deinit();

    try testing.expect(limiter.allow("a", 1000));
    try testing.expect(limiter.allow("a", 1000));
    try testing.expect(limiter.allow("a", 1000));
    try testing.expect(!limiter.allow("a", 1000));
    try testing.expect(!limiter.allow("a", 1030));
}

test "allow resets once the window elapses" {
    var limiter = Limiter.init(testing.allocator, testing.io, 2, 60);
    defer limiter.deinit();

    try testing.expect(limiter.allow("a", 1000));
    try testing.expect(limiter.allow("a", 1000));
    try testing.expect(!limiter.allow("a", 1000));

    try testing.expect(limiter.allow("a", 1061));
    try testing.expect(limiter.allow("a", 1061));
    try testing.expect(!limiter.allow("a", 1061));
}

test "allow tracks distinct keys independently" {
    var limiter = Limiter.init(testing.allocator, testing.io, 1, 60);
    defer limiter.deinit();

    try testing.expect(limiter.allow("a", 1000));
    try testing.expect(!limiter.allow("a", 1000));
    try testing.expect(limiter.allow("b", 1000));
}
