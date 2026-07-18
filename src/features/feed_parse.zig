//! A deliberately small, hand-rolled RSS 2.0 / Atom parser — just enough to
//! pull each entry's title and a stable identifier out of a feed, in
//! document order (both formats list newest-first by convention). Not a
//! real XML parser: no namespace handling, no DTD/entity expansion beyond
//! the five standard XML entities, and a malformed or unusual feed shape
//! degrades to "found nothing" rather than an error — good enough for
//! diffing "what's new" against `last_seen_guid`, not a general feed
//! reader.

const std = @import("std");

pub const Item = struct {
    title: []const u8,
    /// RSS: `<guid>`, falling back to `<link>`. Atom: `<id>`. Falling back
    /// to the title itself (in the rare case neither is present) is better
    /// than skipping the item outright, at the cost of re-notifying if the
    /// title ever changes — an acceptable tradeoff for something this
    /// simple.
    guid: []const u8,
};

/// Extracts every `<item>...</item>` (RSS) or `<entry>...</entry>` (Atom)
/// block's title + identifier, in the order they appear in `xml`. Returns
/// an empty slice (not an error) for anything that doesn't look like
/// either shape.
pub fn parseFeedItems(allocator: std.mem.Allocator, xml: []const u8) ![]Item {
    const blocks = try extractBlocks(allocator, xml, "item");
    defer allocator.free(blocks);
    if (blocks.len > 0) return itemsFromBlocks(allocator, blocks, "guid", "link");

    const entries = try extractBlocks(allocator, xml, "entry");
    defer allocator.free(entries);
    return itemsFromBlocks(allocator, entries, "id", "id");
}

fn itemsFromBlocks(allocator: std.mem.Allocator, blocks: []const []const u8, id_tag: []const u8, fallback_tag: []const u8) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (blocks) |block| {
        const title = extractTagText(allocator, block, "title") orelse continue;
        const guid = extractTagText(allocator, block, id_tag) orelse
            extractTagText(allocator, block, fallback_tag) orelse
            try allocator.dupe(u8, title);
        try out.append(allocator, .{ .title = title, .guid = guid });
    }
    return out.toOwnedSlice(allocator);
}

/// Finds every substring between a `<tag` start (allowing attributes before
/// the closing `>`) and its matching `</tag>`, non-overlapping and
/// non-nested (RSS/Atom entries are never nested in valid feeds).
fn extractBlocks(allocator: std.mem.Allocator, xml: []const u8, tag: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const open = try std.fmt.allocPrint(allocator, "<{s}", .{tag});
    defer allocator.free(open);
    const close = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    defer allocator.free(close);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, open)) |start| {
        // Reject a longer tag name that merely starts with `tag` (e.g. an
        // "itemization" element while looking for "item") by requiring the
        // next byte to end the tag name.
        const after = start + open.len;
        if (after < xml.len and (std.ascii.isAlphanumeric(xml[after]) or xml[after] == '-' or xml[after] == '_')) {
            pos = after;
            continue;
        }
        const body_start = std.mem.indexOfScalarPos(u8, xml, after, '>') orelse break;
        const end = std.mem.indexOfPos(u8, xml, body_start, close) orelse break;
        try out.append(allocator, xml[body_start + 1 .. end]);
        pos = end + close.len;
    }
    return out.toOwnedSlice(allocator);
}

/// Finds `<tag>...</tag>` or `<tag ...>...</tag>` inside `block` and returns
/// its text content, CDATA-unwrapped and XML-entity-decoded. Null if the
/// tag isn't present.
fn extractTagText(allocator: std.mem.Allocator, block: []const u8, tag: []const u8) ?[]const u8 {
    const open = std.fmt.allocPrint(allocator, "<{s}", .{tag}) catch return null;
    defer allocator.free(open);
    const close = std.fmt.allocPrint(allocator, "</{s}>", .{tag}) catch return null;
    defer allocator.free(close);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, block, pos, open)) |start| {
        const after = start + open.len;
        if (after < block.len and (std.ascii.isAlphanumeric(block[after]) or block[after] == '-' or block[after] == '_')) {
            pos = after;
            continue;
        }
        const tag_end = std.mem.indexOfScalarPos(u8, block, after, '>') orelse return null;
        // A self-closing tag (e.g. Atom's `<id/>`, unusual but possible)
        // has no text to extract.
        if (block[tag_end - 1] == '/') return null;
        const body_end = std.mem.indexOfPos(u8, block, tag_end, close) orelse return null;
        const raw = std.mem.trim(u8, block[tag_end + 1 .. body_end], " \t\r\n");
        return decode(allocator, raw) catch null;
    }
    return null;
}

/// Strips a `<![CDATA[...]]>` wrapper if present, then unescapes the five
/// standard XML entities. Numeric character references (`&#NN;`) are left
/// as-is — a rare enough case in feed titles not to be worth the extra
/// complexity here.
fn decode(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const cdata_prefix = "<![CDATA[";
    const cdata_suffix = "]]>";
    const inner = if (std.mem.startsWith(u8, raw, cdata_prefix) and std.mem.endsWith(u8, raw, cdata_suffix))
        raw[cdata_prefix.len .. raw.len - cdata_suffix.len]
    else
        raw;

    if (std.mem.indexOfScalar(u8, inner, '&') == null) return allocator.dupe(u8, inner);

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '&') {
            const entities = [_]struct { name: []const u8, value: u8 }{
                .{ .name = "&amp;", .value = '&' },
                .{ .name = "&lt;", .value = '<' },
                .{ .name = "&gt;", .value = '>' },
                .{ .name = "&quot;", .value = '"' },
                .{ .name = "&apos;", .value = '\'' },
            };
            var matched = false;
            for (entities) |e| {
                if (std.mem.startsWith(u8, inner[i..], e.name)) {
                    try out.append(allocator, e.value);
                    i += e.name.len;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                try out.append(allocator, inner[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, inner[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "parseFeedItems reads RSS items newest-first, preferring guid over link" {
    const rss =
        \\<?xml version="1.0"?>
        \\<rss><channel>
        \\<item><title>First &amp; Best</title><link>https://example.com/1</link><guid>guid-1</guid></item>
        \\<item><title><![CDATA[Second <post>]]></title><link>https://example.com/2</link></item>
        \\</channel></rss>
    ;
    const items = try parseFeedItems(testing.allocator, rss);
    defer {
        for (items) |it| {
            testing.allocator.free(it.title);
            testing.allocator.free(it.guid);
        }
        testing.allocator.free(items);
    }
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("First & Best", items[0].title);
    try testing.expectEqualStrings("guid-1", items[0].guid);
    // No <guid>: falls back to <link>.
    try testing.expectEqualStrings("Second <post>", items[1].title);
    try testing.expectEqualStrings("https://example.com/2", items[1].guid);
}

test "parseFeedItems reads Atom entries using id as the identifier" {
    const atom =
        \\<?xml version="1.0"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<entry><title>Atom Entry One</title><id>urn:uuid:1</id></entry>
        \\<entry><title>Atom Entry Two</title><id>urn:uuid:2</id></entry>
        \\</feed>
    ;
    const items = try parseFeedItems(testing.allocator, atom);
    defer {
        for (items) |it| {
            testing.allocator.free(it.title);
            testing.allocator.free(it.guid);
        }
        testing.allocator.free(items);
    }
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("urn:uuid:1", items[0].guid);
    try testing.expectEqualStrings("urn:uuid:2", items[1].guid);
}

test "parseFeedItems returns an empty slice for unrecognized content" {
    const items = try parseFeedItems(testing.allocator, "<html><body>not a feed</body></html>");
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 0), items.len);
}

test "extractBlocks does not mistake a longer tag name for an exact match" {
    const xml = "<itemization>not an item</itemization><item><title>Real</title><guid>g</guid></item>";
    const items = try parseFeedItems(testing.allocator, xml);
    defer {
        for (items) |it| {
            testing.allocator.free(it.title);
            testing.allocator.free(it.guid);
        }
        testing.allocator.free(items);
    }
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("Real", items[0].title);
}
