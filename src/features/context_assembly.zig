//! `assembleContext`, per the memory-layer design brief: renders pinned +
//! ranked facts, ranked/recent daily digests, and recent chat history into
//! one context block under a hard, code-enforced character budget, so
//! prompt quality doesn't degrade as history grows (failure mode 1 --
//! "context rot"). Every date is precomputed here, never left for the model
//! to infer (failure mode 2), tentative facts are suppressed to a small
//! top-ranked set under their own "may be stale" heading (failure mode 3),
//! and a fact's own bitemporal `valid_to`/`superseded_by` (`store/facts.zig`)
//! keeps a contradicted fact from ever being retrieved at all (failure mode
//! 4) -- this module only renders what the store layer already resolved.
const std = @import("std");
const civil_time = @import("../text/civil_time.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const facts = @import("../store/facts.zig");
const daily_digests = @import("../store/daily_digests.zig");
const messages = @import("../store/messages.zig");
const embeddings = @import("../llm/embeddings.zig");

/// Character budgets per section -- `chars ~= tokens * 3`, the same
/// conservative estimate `qa.zig`'s `min_chars_per_token` already uses
/// elsewhere in this codebase, so the two stay consistent rather than
/// picking a second, different heuristic here. Matches the design brief's
/// token table (header ~60, pinned ~250, facts ~500, episodes ~500,
/// session ~2000).
pub const Budget = struct {
    header_chars: usize = 60 * 3,
    stable_facts_chars: usize = 750 * 3, // pinned (~250) + retrieved (~500) share one rendered section
    tentative_facts_chars: usize = 250 * 3,
    episodes_chars: usize = 500 * 3,
    session_chars: usize = 2000 * 3,
};
pub const default_budget: Budget = .{};

const ranked_stable_limit: u32 = 8;
const ranked_tentative_limit: u32 = 3;
const digests_recency_floor: u32 = 3;
const digests_ranked_limit: u32 = 3;

/// Builds the full memory+history block `qa.zig` injects ahead of the
/// asker line and question -- everything from "Today is..." through
/// "## Recent chat history", budget-capped section by section. Never
/// fails the caller: any retrieval error (embeddings down, a query error)
/// just drops that section, same "soft failure" convention the old
/// `qa.zig` memories block used -- a missing memory section is better than
/// no answer at all.
pub fn assemble(
    pool: *PgPool,
    allocator: std.mem.Allocator,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    chat_id: i64,
    identity_id: i64,
    display_name: []const u8,
    question: []const u8,
    now: i64,
    history_window: i64,
    budget: Budget,
) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;

    const now_local = civil_time.localFromUnix(now, 0);
    const header = try std.fmt.allocPrint(allocator, "Today is {s}, {s} {s} UTC.\n", .{
        civil_time.weekdayName(civil_time.weekdayFromDays(@divFloor(now, 86400))),
        civil_time.formatDate(allocator, now_local, .ymd),
        civil_time.formatTime(allocator, now_local, .h24),
    });
    try w.writeAll(truncateHead(header, budget.header_chars));

    // Only pay for an embedding (and the ranked queries that need it) if
    // there's actually something to rank -- matches the old memories
    // block's `hasAny` short circuit, extended to also cover this chat's
    // digests.
    const has_facts = facts.hasAny(pool, identity_id) catch false;
    const has_digests = daily_digests.hasAny(pool, chat_id) catch false;
    const query_vector: ?[]f32 = if (has_facts or has_digests) blk: {
        const client = embeddings_client orelse break :blk null;
        break :blk client.embed(allocator, question) catch |err| {
            std.log.warn("context_assembly: embed failed for identity {d}: {t}", .{ identity_id, err });
            break :blk null;
        };
    } else null;

    try appendStableFactsSection(w, allocator, pool, identity_id, display_name, query_vector, question, now, budget.stable_facts_chars);
    try appendTentativeFactsSection(w, allocator, pool, identity_id, query_vector, question, now, budget.tentative_facts_chars);
    try appendDigestsSection(w, allocator, pool, chat_id, query_vector, question, now, budget.episodes_chars);

    const history = messages.recentFormatted(pool, allocator, chat_id, history_window) catch "";
    if (history.len > 0) {
        try w.print("## Recent chat history\n{s}\n", .{truncateTail(history, budget.session_chars)});
    }

    return buf.writer.buffered();
}

fn appendStableFactsSection(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pool: *PgPool,
    identity_id: i64,
    display_name: []const u8,
    query_vector: ?[]const f32,
    question: []const u8,
    now: i64,
    max_chars: usize,
) !void {
    const pinned = facts.pinnedForIdentity(pool, allocator, identity_id) catch &.{};
    // Ranked even with no query vector: the hybrid score's other three
    // terms (keyword, recency, salience) still discriminate, and skipping
    // the query entirely -- as this used to -- meant a deployment without an
    // embeddings endpoint got *no* stable facts in its context at all, only
    // pinned ones. See `facts.hybrid_score_expr` on why a null vector is
    // safe to pass straight through.
    const stable = facts.rankedStable(pool, allocator, identity_id, query_vector, question, ranked_stable_limit, now) catch &.{};

    var lines: std.ArrayList([]const u8) = .empty;
    for (pinned) |f| try lines.append(allocator, try renderFactLine(allocator, f));
    for (stable) |f| try lines.append(allocator, try renderFactLine(allocator, f));
    if (lines.items.len == 0) return;

    try w.print("\n## About {s} (stable)\n", .{display_name});
    try writeBudgetedLines(w, lines.items, max_chars);
}

fn appendTentativeFactsSection(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pool: *PgPool,
    identity_id: i64,
    query_vector: ?[]const f32,
    question: []const u8,
    now: i64,
    max_chars: usize,
) !void {
    // Same reasoning as the stable section: no query vector is not a reason
    // to skip tentative facts entirely, only to rank them without the
    // similarity term.
    const tentative = facts.rankedTentative(pool, allocator, identity_id, query_vector, question, ranked_tentative_limit, now) catch &.{};
    if (tentative.len == 0) return;

    var lines: std.ArrayList([]const u8) = .empty;
    for (tentative) |f| {
        const marker = if (f.confirmations <= 1) "mentioned once" else "tentative";
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "- {s}. [{s}, {s} -- may be stale]\n", .{
            f.statement, marker, civil_time.formatDate(allocator, civil_time.localFromUnix(f.valid_from, 0), .ymd),
        }));
    }

    try w.writeAll("\n## Possibly relevant, mentioned once\n");
    try writeBudgetedLines(w, lines.items, max_chars);
}

fn appendDigestsSection(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pool: *PgPool,
    chat_id: i64,
    query_vector: ?[]const f32,
    question: []const u8,
    now: i64,
    max_chars: usize,
) !void {
    const recent = daily_digests.mostRecent(pool, allocator, chat_id, digests_recency_floor) catch &.{};
    const scored = if (query_vector) |qv|
        daily_digests.ranked(pool, allocator, chat_id, qv, question, digests_ranked_limit, now) catch &.{}
    else
        &.{};

    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen.deinit(allocator);
    var picked: std.ArrayList(daily_digests.Digest) = .empty;
    for (recent) |d| {
        if (seen.contains(d.id)) continue;
        try seen.put(allocator, d.id, {});
        try picked.append(allocator, d);
    }
    for (scored) |d| {
        if (seen.contains(d.id)) continue;
        try seen.put(allocator, d.id, {});
        try picked.append(allocator, d);
    }
    if (picked.items.len == 0) return;

    // Oldest first, matching the design brief's rendered example (two
    // consecutive days read top-to-bottom as they happened).
    std.mem.sort(daily_digests.Digest, picked.items, {}, struct {
        fn lessThan(_: void, a: daily_digests.Digest, b: daily_digests.Digest) bool {
            return a.local_date_unix < b.local_date_unix;
        }
    }.lessThan);

    var lines: std.ArrayList([]const u8) = .empty;
    for (picked.items) |d| {
        const c = civil_time.localFromUnix(d.local_date_unix, 0);
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "- {s}, {s} ({s}): {s}\n", .{
            d.weekday, civil_time.formatDate(allocator, c, .ymd), relativeAge(allocator, now, d.local_date_unix), d.summary,
        }));
    }

    try w.writeAll("\n## Relevant history in this chat\n");
    try writeBudgetedLines(w, lines.items, max_chars);
}

fn renderFactLine(allocator: std.mem.Allocator, f: facts.RankedFact) ![]const u8 {
    const since = civil_time.formatDate(allocator, civil_time.localFromUnix(f.valid_from, 0), .ymd);
    return std.fmt.allocPrint(allocator, "- {s}. [since {s}, confirmed {d}x]\n", .{ f.statement, since, f.confirmations });
}

/// "4 months ago" / "2 days ago" -- coarse on purpose (the design brief
/// only requires a precomputed relative age be present, not calendar-exact
/// month arithmetic).
fn relativeAge(allocator: std.mem.Allocator, now: i64, then: i64) []const u8 {
    const days = @divFloor(now - then, 86400);
    if (days <= 0) return "today";
    if (days == 1) return "1 day ago";
    if (days < 30) return std.fmt.allocPrint(allocator, "{d} days ago", .{days}) catch "recently";
    if (days < 365) return std.fmt.allocPrint(allocator, "{d} months ago", .{@divFloor(days, 30)}) catch "months ago";
    return std.fmt.allocPrint(allocator, "{d} years ago", .{@divFloor(days, 365)}) catch "years ago";
}

/// Greedily includes lines (already best-first) until the next one would
/// blow `max_chars` -- the hard, code-enforced budget the design brief
/// requires instead of asking the model to self-limit.
fn writeBudgetedLines(w: *std.Io.Writer, lines: []const []const u8, max_chars: usize) !void {
    var used: usize = 0;
    for (lines) |line| {
        if (used + line.len > max_chars) break;
        try w.writeAll(line);
        used += line.len;
    }
}

fn truncateHead(text: []const u8, max_chars: usize) []const u8 {
    return if (text.len <= max_chars) text else text[0..max_chars];
}

/// Drops whole lines from the front of `text` until what's left fits in
/// `max_chars` -- keeps the *most recent* turns verbatim and lets older
/// ones fall out of the prompt first, per the design brief's session
/// handling (nothing is deleted from storage, just not injected).
fn truncateTail(text: []const u8, max_chars: usize) []const u8 {
    if (text.len <= max_chars) return text;
    var rest = text;
    while (rest.len > max_chars) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            rest = rest[rest.len..];
            break;
        };
        rest = rest[nl + 1 ..];
    }
    return rest;
}

const testing = std.testing;
const test_support = @import("../store/test_support.zig");
const chats = @import("../store/chats.zig");
const identities = @import("../store/identities.zig");
const messages_store = @import("../store/messages.zig");
const embedding_dimensions = @import("../llm/embeddings.zig").embedding_dimensions;

fn testVector(hot_index: usize) [embedding_dimensions]f32 {
    var v: [embedding_dimensions]f32 = @splat(0);
    v[hot_index] = 1.0;
    return v;
}

test "truncateTail drops leading lines until the text fits, never cutting mid-line" {
    const text = "line one\nline two\nline three\n";
    const out = truncateTail(text, 11);
    try testing.expectEqualStrings("line three\n", out);
    try testing.expect(out.len <= 11);
}

test "assemble renders pinned facts, chat history, and a header with no embeddings client configured" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.upsertIdentity(&pool, .{ .platform = .telegram, .native_id = "1", .display_name = "Alice", .first_seen = 1000, .last_seen = 1000 });
    _ = try facts.remember(&pool, a, alice, "prefers concise answers", &testVector(0), 1000);
    try messages_store.insert(&pool, chat1, alice, "1", "hello there", 1000);

    const out = try assemble(&pool, a, null, chat1, alice, "Alice", "what's up", 100_000, 50, default_budget);
    try testing.expect(std.mem.indexOf(u8, out, "Today is") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## About Alice (stable)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "prefers concise answers") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Recent chat history") != null);
    try testing.expect(std.mem.indexOf(u8, out, "hello there") != null);
    // No embeddings client -> no ranked/tentative/digest sections, even
    // though there's a fact -- must not crash or fabricate a query vector.
    try testing.expect(std.mem.indexOf(u8, out, "Possibly relevant") == null);
}

test "assemble omits every memory section for an identity/chat with nothing recorded" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.upsertIdentity(&pool, .{ .platform = .telegram, .native_id = "1", .display_name = "Alice", .first_seen = 1000, .last_seen = 1000 });

    const out = try assemble(&pool, a, null, chat1, alice, "Alice", "hi", 100_000, 50, default_budget);
    try testing.expect(std.mem.indexOf(u8, out, "About Alice") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Relevant history") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Recent chat history") == null);
}

test "assemble caps the recent-chat-history section at its budget, keeping the newest lines" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.upsertIdentity(&pool, .{ .platform = .telegram, .native_id = "1", .display_name = "Alice", .first_seen = 1000, .last_seen = 1000 });
    var i: i64 = 0;
    while (i < 50) : (i += 1) {
        try messages_store.insert(&pool, chat1, alice, null, "a moderately long chat message to fill up the budget quickly", 1000 + i);
    }

    var tiny_budget = default_budget;
    tiny_budget.session_chars = 200;
    const out = try assemble(&pool, a, null, chat1, alice, "Alice", "hi", 100_000, 50, tiny_budget);
    const history_start = std.mem.indexOf(u8, out, "## Recent chat history\n").? + "## Recent chat history\n".len;
    try testing.expect(out.len - history_start <= tiny_budget.session_chars + 1);
}
