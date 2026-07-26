//! Short-circuits the (paid) LLM call for messages that are addressed to
//! the bot but are essentially just a greeting, acknowledgement, or
//! sign-off — "hi", "thanks", "lol", "good morning", and so on — where a
//! real model call adds cost and latency for zero actual value over a
//! canned reply. Gated by `config.zig`'s `skip_trivial_messages`
//! (`WARDEN_LLM_SKIP_TRIVIAL_MESSAGES`).
//!
//! Deliberately a fixed pattern list, not a classifier — see `ROADMAP.md`'s
//! backlog entry for the real embedding/ML-based upgrade path once this
//! simple version's false-negative rate in practice is known. Reuses
//! `text/safe_regex.zig` (the same ReDoS-immune engine `/redact regex`
//! uses) rather than a one-off matcher, both for the reuse itself and
//! because a whole-message anchored alternation is exactly what that
//! engine is built for.
const std = @import("std");
const safe_regex = @import("../text/safe_regex.zig");

/// Whole-message (`^...$`), not substring — "hi there, what's the weather
/// in Tehran" must NOT match this, only a message that IS essentially just
/// one of these phrases (with optional trailing punctuation). Matched
/// case-insensitively: `isTrivialMessage` lowercases the candidate text
/// first, since `safe_regex` itself is byte-wise/case-sensitive by design
/// (see its own module doc) — this pattern is written all-lowercase to
/// match that.
const pattern =
    "^(hi|hello|hey|hiya|yo|sup|howdy|thanks|thank you|thx|ty|ok|okay|k|" ++
    "lol|haha|hahaha|lmao|good morning|good night|gm|gn|bye|goodbye|" ++
    "see ya|cool|nice|great|nvm|never mind)[!.?]*$";

/// Sent back verbatim (no LLM involvement) when `isTrivialMessage` matches.
/// One is picked at random (see `pickResponse`) so replies don't look
/// robotically identical every time.
pub const responses = [_][]const u8{
    "Hey!",
    "Hi there!",
    "Hello!",
    "👋",
    "Hey, what can I do for you?",
};

/// `false` on a compile error (shouldn't happen — `pattern` is a fixed,
/// well-formed string) or allocation failure; callers should treat that as
/// "not trivial" and fall through to a real LLM call rather than erroring
/// the whole message out.
pub fn isTrivialMessage(allocator: std.mem.Allocator, text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;

    const lower = std.ascii.allocLowerString(allocator, trimmed) catch return false;
    defer allocator.free(lower);

    var regex = safe_regex.compile(allocator, pattern) catch return false;
    defer regex.deinit();
    return regex.isMatch(lower);
}

/// `seed` should be something that varies call to call (e.g. the current
/// unix timestamp) — this isn't cryptographic, just enough to avoid always
/// picking `responses[0]`.
pub fn pickResponse(seed: u64) []const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const idx = prng.random().intRangeLessThan(usize, 0, responses.len);
    return responses[idx];
}

const testing = std.testing;

test "isTrivialMessage matches common greetings/acks/sign-offs, case-insensitively and with trailing punctuation" {
    const a = testing.allocator;
    try testing.expect(isTrivialMessage(a, "hi"));
    try testing.expect(isTrivialMessage(a, "Hi!"));
    try testing.expect(isTrivialMessage(a, "HELLO"));
    try testing.expect(isTrivialMessage(a, "thanks"));
    try testing.expect(isTrivialMessage(a, "thank you!"));
    try testing.expect(isTrivialMessage(a, "  ok  "));
    try testing.expect(isTrivialMessage(a, "good morning"));
    try testing.expect(isTrivialMessage(a, "lol"));
    try testing.expect(isTrivialMessage(a, "bye."));
}

test "isTrivialMessage does not match a real question that merely contains a greeting word" {
    const a = testing.allocator;
    try testing.expect(!isTrivialMessage(a, "hi there, what's the weather in Tehran"));
    try testing.expect(!isTrivialMessage(a, "thanks, but can you also check bitcoin's price"));
    try testing.expect(!isTrivialMessage(a, "hello world program in zig"));
}

test "isTrivialMessage rejects empty/whitespace-only text" {
    const a = testing.allocator;
    try testing.expect(!isTrivialMessage(a, ""));
    try testing.expect(!isTrivialMessage(a, "   "));
}

test "pickResponse always returns one of the documented responses" {
    const picked = pickResponse(12345);
    var found = false;
    for (responses) |r| {
        if (std.mem.eql(u8, r, picked)) found = true;
    }
    try testing.expect(found);
}
