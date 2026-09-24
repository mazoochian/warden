//! Rate-limit / ban-avoidance pacing for the Instagram connector's poll loop
//! -- jittered intervals and a hard pause-and-alert on anything shaped like a
//! checkpoint/feedback-block response, per the connector plan's "Rate-limit /
//! ban-avoidance policy" section.
const std = @import("std");
const Io = std.Io;

/// Jittered delay before the next poll cycle -- `base_ms` plus up to 50%
/// extra.
pub fn nextPollDelayMs(io: Io, base_ms: u32) u32 {
    var buf: [4]u8 = undefined;
    io.random(&buf);
    const r = std.mem.readInt(u32, &buf, .little);
    const jitter_range = base_ms / 2;
    if (jitter_range == 0) return base_ms;
    const jitter = r % jitter_range;
    return base_ms + jitter;
}

/// Whether an HTTP status/body combination looks like Instagram's
/// checkpoint/feedback-block family of responses.
pub fn looksLikeChallengeOrBlock(status_class_is_error: bool, body: []const u8) bool {
    if (!status_class_is_error) return false;
    const markers = [_][]const u8{
        "checkpoint_required",
        "challenge_required",
        "feedback_required",
        "login_required",
        "user_has_logged_out",
    };
    for (markers) |m| {
        if (std.mem.indexOf(u8, body, m) != null) return true;
    }
    return false;
}

/// Tracks whether polling is currently paused after a challenge/block was
/// detected.
pub const Breaker = struct {
    paused: std.atomic.Value(bool) = .init(false),
    /// Set once, the first time `trip()` fires -- surfaced by `/iglogin
    /// status` so the owner sees *why* it paused, not just that it did.
    reason: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Breaker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Breaker) void {
        if (self.reason) |r| self.allocator.free(r);
    }

    pub fn isPaused(self: *const Breaker) bool {
        return self.paused.load(.acquire);
    }

    /// Idempotent -- a second trip while already paused just leaves the original
    /// reason in place.
    pub fn trip(self: *Breaker, reason: []const u8) void {
        if (self.paused.swap(true, .acq_rel)) return;
        self.reason = self.allocator.dupe(u8, reason) catch null;
    }

    pub fn resume_(self: *Breaker) void {
        self.paused.store(false, .release);
        if (self.reason) |r| {
            self.allocator.free(r);
            self.reason = null;
        }
    }
};

const testing = std.testing;

test "nextPollDelayMs stays within [base, base*1.5]" {
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        const d = nextPollDelayMs(testing.io, 1000);
        try testing.expect(d >= 1000);
        try testing.expect(d < 1500);
    }
}

test "nextPollDelayMs handles a zero base without dividing by zero" {
    try testing.expectEqual(@as(u32, 0), nextPollDelayMs(testing.io, 0));
}

test "looksLikeChallengeOrBlock only fires on an error status with a known marker" {
    try testing.expect(looksLikeChallengeOrBlock(true, "{\"message\": \"challenge_required\"}"));
    try testing.expect(looksLikeChallengeOrBlock(true, "{\"error_type\": \"checkpoint_required\"}"));
    try testing.expect(!looksLikeChallengeOrBlock(true, "{\"message\": \"some other error\"}"));
    try testing.expect(!looksLikeChallengeOrBlock(false, "{\"message\": \"challenge_required\"}"));
}

test "Breaker starts unpaused, trips once, stays paused across repeated trips, and resumes cleanly" {
    var breaker = Breaker.init(testing.allocator);
    defer breaker.deinit();

    try testing.expect(!breaker.isPaused());

    breaker.trip("checkpoint_required");
    try testing.expect(breaker.isPaused());
    try testing.expectEqualStrings("checkpoint_required", breaker.reason.?);

    // A second trip with a different reason doesn't overwrite the first.
    breaker.trip("something else");
    try testing.expectEqualStrings("checkpoint_required", breaker.reason.?);

    breaker.resume_();
    try testing.expect(!breaker.isPaused());
    try testing.expectEqual(@as(?[]const u8, null), breaker.reason);
}
