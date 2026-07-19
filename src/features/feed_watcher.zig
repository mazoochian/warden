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

/// Checks every feed watch whose interval has elapsed, and for any with
/// genuinely new items (not the first check ever — see below), posts an
/// LLM-written one-or-two-sentence blurb rather than a raw item dump.
///
/// The very first check of a newly-added feed only records a baseline
/// (the current newest item's guid) without announcing anything — same
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
            if (fw.last_seen_guid) |g| gpa.free(g);
        }
        gpa.free(due);
    }

    for (due) |fw| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const body = fetchFeed(a, io, fw.feed_url) catch |err| {
            std.log.warn("feed_watcher: failed to fetch {s}: {t}", .{ fw.feed_url, err });
            continue;
        };
        const items = feed_parse.parseFeedItems(a, body) catch |err| {
            std.log.warn("feed_watcher: failed to parse {s}: {t}", .{ fw.feed_url, err });
            continue;
        };
        if (items.len == 0) {
            // Not necessarily an error (a feed can genuinely be empty) —
            // still bump last_checked_at so this doesn't get re-fetched
            // every poll cycle, leaving last_seen_guid untouched.
            feed_watches.markChecked(pool, fw.id, now, fw.last_seen_guid) catch |err| {
                std.log.err("feed_watcher: failed to mark {d} checked: {t}", .{ fw.id, err });
            };
            continue;
        }

        const newest_guid = items[0].guid;

        if (fw.last_seen_guid == null) {
            feed_watches.markChecked(pool, fw.id, now, newest_guid) catch |err| {
                std.log.err("feed_watcher: failed to record baseline for {d}: {t}", .{ fw.id, err });
            };
            continue;
        }
        const seen = fw.last_seen_guid.?;

        var new_items: std.ArrayList(feed_parse.Item) = .empty;
        for (items) |it| {
            if (std.mem.eql(u8, it.guid, seen)) break;
            new_items.append(a, it) catch break;
        }

        if (new_items.items.len == 0) {
            feed_watches.markChecked(pool, fw.id, now, newest_guid) catch |err| {
                std.log.err("feed_watcher: failed to mark {d} checked: {t}", .{ fw.id, err });
            };
            continue;
        }

        const connector = findConnector(connectors, fw.platform) orelse {
            std.log.warn("feed_watcher: no active connector for platform {s}, leaving watch {d} unchecked", .{ @tagName(fw.platform), fw.id });
            continue;
        };

        var titles_buf: std.Io.Writer.Allocating = .init(a);
        for (new_items.items) |it| titles_buf.writer.print("- {s}\n", .{it.title}) catch {};
        const prompt = std.fmt.allocPrint(a, "New items from {s}:\n{s}\nWrite the update now.", .{ fw.feed_url, titles_buf.writer.buffered() }) catch continue;

        const tool_ctx = registry.ToolContext{ .allocator = a, .io = io };
        // Background job, no live chat message being edited — streaming
        // would have zero visible effect (same reasoning as digest.zig).
        const blurb = toolcall.run(llm_provider, a, tool_ctx, system_prompt, prompt, &.{}, .{}, false) catch |err| blk: {
            std.log.err("feed_watcher: llm summary failed for {s}: {t}", .{ fw.feed_url, err });
            break :blk "";
        };

        const text = if (blurb.len > 0)
            std.fmt.allocPrint(a, "📰 {s}: {s}", .{ fw.feed_url, blurb }) catch continue
        else
            std.fmt.allocPrint(a, "📰 {s} has {d} new item(s): {s}", .{ fw.feed_url, new_items.items.len, new_items.items[0].title }) catch continue;
        connector.sendMessage(a, fw.native_chat_id, text, null);

        feed_watches.markChecked(pool, fw.id, now, newest_guid) catch |err| {
            std.log.err("feed_watcher: failed to mark {d} checked after notifying: {t}", .{ fw.id, err });
        };
    }
}
