//! Short-circuits the (paid) LLM call for messages that are addressed to the
//! bot but are essentially just a greeting, acknowledgement, or sign-off —
//! "hi", "thanks", "lol", "good morning", and so on — where a real model call
//! adds cost and latency for zero actual value over a canned reply. Gated by
//! `config.zig`'s `skip_trivial_messages`
const std = @import("std");
const safe_regex = @import("../text/safe_regex.zig");

/// Whole-message (`^...$`), not substring.
const pattern =
    "^(hi|hello|hey|hiya|yo|sup|howdy|thanks|thank you|thx|ty|ok|okay|k|" ++
    "lol|haha|hahaha|lmao|good morning|good night|gm|gn|bye|goodbye|" ++
    "see ya|cool|nice|great|nvm|never mind)[!.?]*$";

/// Sent back verbatim (no LLM involvement) when `isTrivialMessage` matches.
pub const responses = [_][]const u8{
    "Hey!",
    "Hi there!",
    "Hello!",
    "👋",
    "Hey, what can I do for you?",
};

/// `false` on a compile error.
pub fn isTrivialMessage(allocator: std.mem.Allocator, text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;

    const lower = std.ascii.allocLowerString(allocator, trimmed) catch return false;
    defer allocator.free(lower);

    var regex = safe_regex.compile(allocator, pattern) catch return false;
    defer regex.deinit();
    return regex.isMatch(lower);
}

/// `seed` should be something that varies call to call (e.g. the current unix
/// timestamp).
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
