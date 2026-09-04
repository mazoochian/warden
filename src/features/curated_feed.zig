const std = @import("std");
const Io = std.Io;

const llm = @import("../llm/provider.zig");
const toolcall = @import("../llm/toolcall.zig");
const registry = @import("../tools/registry.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const feed = @import("../store/feed.zig");
const telegram_user_platform = @import("../platform/telegram_user.zig");
const log = @import("../log.zig").scoped("curated_feed");

/// How many recent posts are pulled per source per pass. TDLib's
/// `getChatHistory` has no "since id" form, so this is the ceiling on how
/// far behind a source can fall and still be caught up in one pass: a
/// channel posting more than this between two passes loses the overflow.
/// 50 an hour is a very busy channel; the alternative (paging backwards
/// until the watermark) would let one runaway source stall an entire pass.
const posts_per_source = 50;

/// Cap on how many posts one pass will *summarise*, across all sources.
/// The relevance filter is cheap; summarisation is not, and without a
/// ceiling a single burst of on-topic posts could turn one tick into
/// dozens of model calls. Overflow is left behind the watermark and picked
/// up next pass rather than dropped.
const max_summaries_per_pass = 12;

/// Characters of a post handed to the model. Long enough for a news post,
/// short enough that a pathological wall of text can't dominate a batch.
const max_post_chars = 2000;

const relevance_system_prompt =
    \\You decide whether one message belongs in a curated feed.
    \\You will be given the reader's policy and one message.
    \\Answer with exactly one word: YES if the message matches the policy,
    \\NO if it does not. No punctuation, no explanation. When genuinely
    \\unsure, answer NO -- a feed that admits everything is worthless.
;

const summary_system_prompt =
    \\You write one entry for a curated feed digest.
    \\Given a message, write a single plain-text sentence (at most 200
    \\characters) capturing what actually happened or was announced. No
    \\preamble, no "this post says", no markdown, no emoji, no quotes.
    \\Write it as a headline a reader could skim.
;

/// One post that passed the policy and has been summarised.
pub const Item = struct {
    source_title: []const u8,
    summary: []const u8,
};

/// Runs one pass: for each enabled source, pull what's new, keep what
/// matches the policy, summarise it, and post one digest to the target
/// channel.
///
/// Two-stage on purpose. The relevance check is a handful of tokens per
/// post and discards most of them; only survivors pay for a summarisation
/// call. Doing both in one call would mean paying full summary cost for
/// every post in every subscribed channel, which is what makes "read
/// everything and filter" affordable at all.
///
/// A source with no watermark yet (just added) is caught up silently: its
/// watermark jumps to the newest post without emitting anything, so adding
/// a channel never dumps its backlog into the feed.
///
/// Returns how many items were posted, for logging and `/feed run`.
pub fn runOnce(
    pool: *PgPool,
    allocator: std.mem.Allocator,
    io: Io,
    provider: llm.Provider,
    telegram_user: ?*telegram_user_platform.TelegramUserConnector,
    max_retries: u32,
    now: i64,
) !usize {
    const settings = try feed.getSettings(pool, allocator);
    if (!settings.isRunnable()) return 0;
    const target = settings.target_native_chat_id.?;
    const policy = settings.policy.?;

    const conn = telegram_user orelse {
        log.warn("the personal-account connector isn't configured; the feed can't read channels", .{});
        return 0;
    };

    const sources = try feed.listSources(pool, allocator, true);
    if (sources.len == 0) return 0;

    var items: std.ArrayList(Item) = .empty;
    var summarised: usize = 0;

    for (sources) |source| {
        const chat_id = std.fmt.parseInt(i64, source.native_chat_id, 10) catch {
            log.warn("source {s} isn't a TDLib chat id, skipping", .{source.native_chat_id});
            continue;
        };

        const posts = conn.fetchRecentPosts(allocator, io, chat_id, posts_per_source) catch |err| {
            log.warn("couldn't read {s}: {t}", .{ source.title, err });
            continue;
        };
        if (posts.len == 0) continue;

        var highest = source.last_seen_message_id;
        for (posts) |p| highest = @max(highest, p.id);

        // First sight of a source: adopt its position without emitting
        // anything, so adding a channel doesn't replay its history.
        if (source.last_seen_message_id == 0) {
            feed.setWatermark(pool, source.id, highest) catch |err| {
                log.err("couldn't set the initial watermark for {s}: {t}", .{ source.title, err });
            };
            log.info("caught up to {s} without posting (newly added source)", .{source.title});
            continue;
        }

        // Oldest first, so a digest reads in the order things happened and
        // the per-pass ceiling truncates the *newest* rather than leaving a
        // gap in the middle.
        var fresh: std.ArrayList(telegram_user_platform.TelegramUserConnector.Post) = .empty;
        for (posts) |p| {
            if (p.id > source.last_seen_message_id) try fresh.append(allocator, p);
        }
        std.mem.sort(telegram_user_platform.TelegramUserConnector.Post, fresh.items, {}, struct {
            fn lessThan(_: void, a: telegram_user_platform.TelegramUserConnector.Post, b: telegram_user_platform.TelegramUserConnector.Post) bool {
                return a.id < b.id;
            }
        }.lessThan);

        var source_high_water = source.last_seen_message_id;
        for (fresh.items) |post| {
            if (summarised >= max_summaries_per_pass) break;

            const body = truncate(post.text, max_post_chars);
            const relevant = isRelevant(provider, allocator, io, policy, body, max_retries) catch |err| {
                // Treat an unreachable model as "don't know", and leave the
                // watermark behind this post so it's reconsidered next pass
                // rather than silently skipped.
                log.warn("relevance check failed for a post in {s}: {t}", .{ source.title, err });
                break;
            };
            source_high_water = post.id;
            if (!relevant) continue;

            const summary = summarise(provider, allocator, io, body, max_retries) catch |err| {
                log.warn("summarising a post in {s} failed: {t}", .{ source.title, err });
                continue;
            };
            if (summary.len == 0) continue;

            try items.append(allocator, .{ .source_title = source.title, .summary = summary });
            summarised += 1;
        }

        feed.setWatermark(pool, source.id, source_high_water) catch |err| {
            log.err("couldn't advance the watermark for {s}: {t}", .{ source.title, err });
        };
    }

    feed.markRun(pool, now) catch |err| {
        log.err("couldn't stamp the feed run: {t}", .{err});
    };

    if (items.items.len == 0) return 0;

    const digest = try renderDigest(allocator, items.items);
    conn.connector().sendMessage(allocator, target, digest, null);
    log.info("posted a feed digest with {d} item(s)", .{items.items.len});
    return items.items.len;
}

/// Stage one: does this post match the policy at all? Deliberately a tiny
/// prompt with a one-word answer — this runs on every new post in every
/// source, so its cost is what decides whether the whole feature is
/// affordable.
fn isRelevant(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    io: Io,
    policy: []const u8,
    post: []const u8,
    max_retries: u32,
) !bool {
    const prompt = try std.fmt.allocPrint(allocator, "Policy: {s}\n\nMessage:\n{s}", .{ policy, post });
    const ctx = registry.ToolContext{ .allocator = allocator, .io = io };
    const answer = try toolcall.run(provider, allocator, ctx, relevance_system_prompt, prompt, &.{}, .{}, false, false, false, false, 8, max_retries);
    // Anything that isn't a clear yes is a no: an unparseable answer must
    // not smuggle an off-policy post into the feed.
    const trimmed = std.mem.trim(u8, answer, " \t\r\n.");
    return std.ascii.eqlIgnoreCase(trimmed, "yes");
}

/// Stage two: one headline-shaped line for a post that already passed.
fn summarise(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    io: Io,
    post: []const u8,
    max_retries: u32,
) ![]const u8 {
    const ctx = registry.ToolContext{ .allocator = allocator, .io = io };
    const answer = try toolcall.run(provider, allocator, ctx, summary_system_prompt, post, &.{}, .{}, false, false, false, false, 256, max_retries);
    return std.mem.trim(u8, answer, " \t\r\n");
}

/// Groups items under their source, so a digest reads as a short briefing
/// rather than a flat list where every line has to repeat where it came
/// from. Items arrive already grouped by source (the caller walks sources
/// in order), so this only needs to notice when the source changes.
pub fn renderDigest(allocator: std.mem.Allocator, items: []const Item) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("\u{1F4F0} Feed digest\n");
    var current: ?[]const u8 = null;
    for (items) |item| {
        if (current == null or !std.mem.eql(u8, current.?, item.source_title)) {
            try w.print("\n{s}\n", .{item.source_title});
            current = item.source_title;
        }
        try w.print("  • {s}\n", .{item.summary});
    }
    return out.written();
}

/// UTF-8-boundary-safe truncation, so a post cut at `max` never ends
/// mid-codepoint and produces invalid text in a prompt.
fn truncate(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

test "renderDigest groups items under their source" {
    const a = testing.allocator;
    const items = [_]Item{
        .{ .source_title = "World News", .summary = "Ceasefire agreed in the north" },
        .{ .source_title = "World News", .summary = "Election results delayed" },
        .{ .source_title = "Science Daily", .summary = "New telescope image released" },
    };
    const out = try renderDigest(a, &items);
    defer a.free(out);
    try testing.expectEqualStrings(
        "\u{1F4F0} Feed digest\n\nWorld News\n  \u{2022} Ceasefire agreed in the north\n  \u{2022} Election results delayed\n\nScience Daily\n  \u{2022} New telescope image released\n",
        out,
    );
}

test "truncate never splits a multi-byte codepoint" {
    // "é" is two bytes; cutting at 3 must back off to 2 rather than leave
    // half a codepoint in the prompt.
    const text = "ab\u{00e9}cd";
    const cut = truncate(text, 3);
    try testing.expectEqualStrings("ab", cut);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "truncate leaves short text alone" {
    try testing.expectEqualStrings("short", truncate("short", 100));
}
