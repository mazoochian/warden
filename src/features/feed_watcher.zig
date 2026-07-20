const std = @import("std");
const Io = std.Io;
const http = std.http;

const iface = @import("../platform/interface.zig");
const store_pool = @import("../store/pool.zig");
const feed_watches = @import("../store/feed_watches.zig");
const feed_parse = @import("feed_parse.zig");
const http_util = @import("../http_util.zig");
const llm = @import("../llm/provider.zig");
const toolcall = @import("../llm/toolcall.zig");
const registry = @import("../tools/registry.zig");

const system_prompt =
    \\You write a short update for a group chat about new items that just
    \\appeared in an RSS/Atom feed they're watching. Given a list of new
    \\item titles, write 1-2 sentences summarizing what's new, in a casual
    \\tone. Do not invent details beyond the titles given to you.
;

/// Upper bound on how many item guids get persisted as the "seen" set per
/// watch — bounds the `seen_guids_json` column's size regardless of how
/// large a feed's own item window is (one real feed encountered live had
/// 777 `<item>`s). Which specific items get kept doesn't affect *this*
/// check's correctness (dedup is a pure set-membership test now, not
/// order-dependent) — it only bounds how much inter-check publishing
/// volume the *next* check can still recognize as "already seen".
const max_tracked_guids: usize = 150;

/// Finds the connector whose platform matches `platform` — duplicated from
/// `main.zig`'s `findConnector`, same reasoning as `features/alerts.zig`'s
/// own copy (keeps this file's only dependency on `main.zig` at zero).
fn findConnector(connectors: []const iface.Connector, platform: iface.Platform) ?iface.Connector {
    for (connectors) |c| {
        if (c.platform() == platform) return c;
    }
    return null;
}

fn fetchFeed(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    return http_util.get(&client, allocator, url);
}

/// What happened when checking one watch — returned so both the scheduled
/// batch loop and the manual `/watchcheck` command can react appropriately
/// (the batch loop mostly just logs; the manual command reports this
/// directly to the chat, which is the whole point of that command existing
/// — answering "is my feed actually broken" without needing log access).
pub const CheckOutcome = union(enum) {
    /// First-ever check: baseline recorded, nothing announced (see
    /// `checkOne`'s doc comment for why).
    baseline_recorded: usize,
    /// Fetched and parsed fine, nothing new since last time.
    no_new_items,
    /// Notified the chat with this many new items.
    notified: usize,
    /// Fetched fine, but not recognizable as RSS/Atom (0 `<item>`/`<entry>`
    /// blocks found) — `feed_parse.parseFeedItems` treats this as "empty",
    /// not an error, so this is the closest signal available that
    /// something about the feed's shape might be wrong.
    unrecognized_feed_shape,
    fetch_failed: anyerror,
    parse_failed: anyerror,
    no_connector_for_platform: iface.Platform,
};

/// Checks every feed watch whose interval has elapsed, and for any with
/// genuinely new items (not the first check ever — see below), posts an
/// LLM-written one-or-two-sentence blurb rather than a raw item dump.
///
/// The very first check of a newly-added feed only records a baseline
/// (the current items' guids) without announcing anything — same
/// "don't replay history" reasoning as `MatrixConnector.pollFn`'s discarded
/// first `/sync`, since a feed can easily have dozens of old items and
/// nobody wants those all replayed into the chat the moment they add a
/// watch.
pub fn checkAndNotifyFeeds(connectors: []const iface.Connector, gpa: std.mem.Allocator, io: Io, pool: *store_pool.PgPool, llm_provider: llm.Provider, now: i64) void {
    const due = feed_watches.dueForCheck(pool, gpa, now) catch |err| {
        std.log.err("feed_watcher: failed to query due feed watches: {t}", .{err});
        return;
    };
    defer {
        for (due) |fw| {
            gpa.free(fw.native_chat_id);
            gpa.free(fw.feed_url);
            if (fw.seen_guids) |guids| {
                for (guids) |g| gpa.free(g);
                gpa.free(guids);
            }
        }
        gpa.free(due);
    }

    for (due) |fw| {
        const outcome = checkOne(connectors, gpa, io, pool, llm_provider, fw, now);
        switch (outcome) {
            .fetch_failed => |err| std.log.warn("feed_watcher: failed to fetch {s}: {t}", .{ fw.feed_url, err }),
            .parse_failed => |err| std.log.warn("feed_watcher: failed to parse {s}: {t}", .{ fw.feed_url, err }),
            .no_connector_for_platform => |p| std.log.warn("feed_watcher: no active connector for platform {s}, leaving watch {d} unchecked", .{ @tagName(p), fw.id }),
            .baseline_recorded, .no_new_items, .notified, .unrecognized_feed_shape => {},
        }
    }
}

/// Forces an immediate check of one specific watch, regardless of whether
/// its interval has elapsed — the `/watchcheck <url>` command's entry
/// point. `null` means this chat isn't watching that URL at all.
pub fn checkNow(connectors: []const iface.Connector, gpa: std.mem.Allocator, io: Io, pool: *store_pool.PgPool, llm_provider: llm.Provider, chat_id: i64, feed_url: []const u8, now: i64) !?CheckOutcome {
    const fw = try feed_watches.getOne(pool, gpa, chat_id, feed_url) orelse return null;
    defer {
        gpa.free(fw.native_chat_id);
        gpa.free(fw.feed_url);
        if (fw.seen_guids) |guids| {
            for (guids) |g| gpa.free(g);
            gpa.free(guids);
        }
    }
    return checkOne(connectors, gpa, io, pool, llm_provider, fw, now);
}

/// The actual fetch → parse → dedupe → notify → mark-checked pipeline for
/// one watch, shared by the scheduled batch loop and the manual
/// `/watchcheck` command so they can never drift apart.
///
/// Dedup is a set-membership test against `fw.seen_guids` (the snapshot of
/// item guids from the *previous* check), not a positional scan — found
/// live 2026-07-20: a real feed (iranwire.com's) keeps a featured/pinned
/// story at `<item>` position 0 regardless of publish date, so the old
/// "scan from the top, stop at the first guid matching the watermark"
/// approach got permanently stuck the moment that pinned story became the
/// watermark, silently reporting "0 new items" forever while hundreds of
/// genuinely new items accumulated underneath it. Set membership doesn't
/// care what order items come in.
fn checkOne(connectors: []const iface.Connector, gpa: std.mem.Allocator, io: Io, pool: *store_pool.PgPool, llm_provider: llm.Provider, fw: feed_watches.DueFeedWatch, now: i64) CheckOutcome {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const body = fetchFeed(a, io, fw.feed_url) catch |err| return .{ .fetch_failed = err };
    const items = feed_parse.parseFeedItems(a, body) catch |err| return .{ .parse_failed = err };
    if (items.len == 0) {
        // Not necessarily an error (a feed can genuinely be empty, or this
        // fetch just didn't look like RSS/Atom at all — parseFeedItems
        // doesn't distinguish the two) — still bump last_checked_at so
        // this doesn't get re-fetched every poll cycle.
        feed_watches.markChecked(pool, gpa, fw.id, now, &.{}) catch |err| {
            std.log.err("feed_watcher: failed to mark {d} checked: {t}", .{ fw.id, err });
        };
        return .unrecognized_feed_shape;
    }

    const current_guids = collectGuids(a, items);

    if (fw.seen_guids == null) {
        feed_watches.markChecked(pool, gpa, fw.id, now, current_guids) catch |err| {
            std.log.err("feed_watcher: failed to record baseline for {d}: {t}", .{ fw.id, err });
        };
        return .{ .baseline_recorded = items.len };
    }

    const new_items = newItemsSince(a, items, fw.seen_guids.?);

    if (new_items.items.len == 0) {
        feed_watches.markChecked(pool, gpa, fw.id, now, current_guids) catch |err| {
            std.log.err("feed_watcher: failed to mark {d} checked: {t}", .{ fw.id, err });
        };
        return .no_new_items;
    }

    const connector = findConnector(connectors, fw.platform) orelse return .{ .no_connector_for_platform = fw.platform };

    var titles_buf: std.Io.Writer.Allocating = .init(a);
    for (new_items.items) |it| titles_buf.writer.print("- {s}\n", .{it.title}) catch {};
    const prompt = std.fmt.allocPrint(a, "New items from {s}:\n{s}\nWrite the update now.", .{ fw.feed_url, titles_buf.writer.buffered() }) catch return .no_new_items;

    const tool_ctx = registry.ToolContext{ .allocator = a, .io = io };
    // Background job, no live chat message being edited — streaming
    // would have zero visible effect (same reasoning as digest.zig).
    // show_thinking=false and max_tokens=1024 for the same reasons
    // documented in digest.zig's own toolcall.run call.
    const blurb = toolcall.run(llm_provider, a, tool_ctx, system_prompt, prompt, &.{}, .{}, false, false, 1024) catch |err| blk: {
        std.log.err("feed_watcher: llm summary failed for {s}: {t}", .{ fw.feed_url, err });
        break :blk "";
    };

    const text = if (blurb.len > 0)
        std.fmt.allocPrint(a, "📰 {s}: {s}", .{ fw.feed_url, blurb }) catch return .{ .notified = new_items.items.len }
    else
        std.fmt.allocPrint(a, "📰 {s} has {d} new item(s): {s}", .{ fw.feed_url, new_items.items.len, new_items.items[0].title }) catch return .{ .notified = new_items.items.len };
    connector.sendMessage(a, fw.native_chat_id, text, null);

    feed_watches.markChecked(pool, gpa, fw.id, now, current_guids) catch |err| {
        std.log.err("feed_watcher: failed to mark {d} checked after notifying: {t}", .{ fw.id, err });
    };
    return .{ .notified = new_items.items.len };
}

fn collectGuids(allocator: std.mem.Allocator, items: []const feed_parse.Item) []const []const u8 {
    const capped = @min(items.len, max_tracked_guids);
    const out = allocator.alloc([]const u8, capped) catch return &.{};
    for (0..capped) |i| out[i] = items[i].guid;
    return out;
}

/// Every item in `items` whose guid isn't in `seen_guids` — a pure
/// set-membership test, deliberately independent of item order. This is
/// the fix for the bug found live 2026-07-20: the old logic scanned
/// `items` from the top and stopped at the first one matching a single
/// watermark guid, which broke permanently the moment a feed put a
/// pinned/featured item (older than genuinely new ones) at position 0 —
/// see this file's module-level and `checkOne`'s doc comments.
fn newItemsSince(allocator: std.mem.Allocator, items: []const feed_parse.Item, seen_guids: []const []const u8) std.ArrayList(feed_parse.Item) {
    var seen_set: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_set.deinit(allocator);
    for (seen_guids) |g| seen_set.put(allocator, g, {}) catch {};

    var new_items: std.ArrayList(feed_parse.Item) = .empty;
    for (items) |it| {
        if (!seen_set.contains(it.guid)) new_items.append(allocator, it) catch break;
    }
    return new_items;
}

const testing = std.testing;

test "newItemsSince finds new items regardless of a stale item's position" {
    // Reproduces the real bug: a "pinned" item stays at position 0 even
    // though items published later sit underneath it in the feed.
    const items = [_]feed_parse.Item{
        .{ .title = "Pinned old story", .guid = "guid-old-pinned" },
        .{ .title = "Genuinely new story A", .guid = "guid-new-a" },
        .{ .title = "Genuinely new story B", .guid = "guid-new-b" },
    };
    const seen_guids = [_][]const u8{"guid-old-pinned"};

    var new_items = newItemsSince(testing.allocator, &items, &seen_guids);
    defer new_items.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), new_items.items.len);
    try testing.expectEqualStrings("guid-new-a", new_items.items[0].guid);
    try testing.expectEqualStrings("guid-new-b", new_items.items[1].guid);
}

test "newItemsSince returns nothing when every guid was already seen" {
    const items = [_]feed_parse.Item{
        .{ .title = "A", .guid = "guid-a" },
        .{ .title = "B", .guid = "guid-b" },
    };
    const seen_guids = [_][]const u8{ "guid-a", "guid-b" };

    var new_items = newItemsSince(testing.allocator, &items, &seen_guids);
    defer new_items.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), new_items.items.len);
}

test "newItemsSince treats every item as new when seen_guids is empty" {
    const items = [_]feed_parse.Item{
        .{ .title = "A", .guid = "guid-a" },
        .{ .title = "B", .guid = "guid-b" },
    };

    var new_items = newItemsSince(testing.allocator, &items, &.{});
    defer new_items.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), new_items.items.len);
}
