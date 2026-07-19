//! Converts model-generated, Markdown-ish text into Telegram-safe HTML
//! (`parse_mode=HTML`) — models overwhelmingly write standard Markdown
//! (`**bold**`, `` `code` ``, fenced code blocks, `[text](url)` links) when
//! asked for anything richer than plain prose, but Telegram doesn't
//! interpret that syntax at all without `parse_mode` set, so replies were
//! showing up with literal asterisks/backticks.
//!
//! Deliberately narrow: only the handful of constructs above are
//! recognized; everything else — including single-`*`/`_` italics, which
//! are genuinely ambiguous against normal prose ("5 * 3", "file_name.txt")
//! — passes through as literal (HTML-escaped) text rather than risk
//! misinterpreting it. An unclosed marker (a stray "`" with no matching
//! close, "**bold" with no closing "**" — the latter routine mid-stream,
//! before the closing marker has arrived yet) is likewise left as literal
//! text instead of swallowing the rest of the message, so a live streaming
//! preview degrades gracefully rather than ever showing wrong formatting.
//!
//! `main.zig`/`telegram/client.zig` are expected to send every message
//! through `toHtml` with `parse_mode=HTML`, and to retry once as plain
//! text (no `parse_mode`) if Telegram rejects the send — a defense-in-depth
//! safety net for whatever this converter's necessarily-incomplete grammar
//! still gets wrong, since Telegram rejecting one bad entity would
//! otherwise silently drop the whole message.

const std = @import("std");
const llm = @import("../llm/provider.zig");

/// Converts `text` (plain prose, optionally containing the Markdown-ish
/// constructs described above and/or one `llm.thinking_start`/`thinking_end`
/// wrapped span) into Telegram-safe HTML.
pub fn toHtml(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try convertInto(allocator, &out, text);
    return out.toOwnedSlice(allocator);
}

fn convertInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (matchesAt(text, i, llm.thinking_start)) {
            if (std.mem.indexOfPos(u8, text, i + llm.thinking_start.len, llm.thinking_end)) |end_idx| {
                const inner = text[i + llm.thinking_start.len .. end_idx];
                try out.appendSlice(allocator, "<blockquote expandable>\u{1F4AD} ");
                try convertInto(allocator, out, inner);
                try out.appendSlice(allocator, "</blockquote>");
                i = end_idx + llm.thinking_end.len;
                continue;
            }
        }

        if (matchesAt(text, i, "```")) {
            if (std.mem.indexOfPos(u8, text, i + 3, "```")) |close_idx| {
                var body = text[i + 3 .. close_idx];
                // Drop a leading language-tag line ("```zig\n...") — Telegram
                // has no use for it and it reads oddly left in as text.
                if (std.mem.indexOfScalar(u8, body, '\n')) |nl| {
                    const first_line = body[0..nl];
                    if (first_line.len > 0 and first_line.len < 20 and isLikelyLangTag(first_line)) {
                        body = body[nl + 1 ..];
                    }
                }
                try out.appendSlice(allocator, "<pre><code>");
                try escapeInto(allocator, out, body);
                try out.appendSlice(allocator, "</code></pre>");
                i = close_idx + 3;
                continue;
            }
        }

        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close_idx| {
                try out.appendSlice(allocator, "<code>");
                try escapeInto(allocator, out, text[i + 1 .. close_idx]);
                try out.appendSlice(allocator, "</code>");
                i = close_idx + 1;
                continue;
            }
        }

        if (matchesAt(text, i, "**")) {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |close_idx| {
                if (close_idx > i + 2) {
                    try out.appendSlice(allocator, "<b>");
                    try convertInto(allocator, out, text[i + 2 .. close_idx]);
                    try out.appendSlice(allocator, "</b>");
                    i = close_idx + 2;
                    continue;
                }
            }
        }

        if (text[i] == '[') {
            if (parseLink(text, i)) |link| {
                try out.appendSlice(allocator, "<a href=\"");
                try escapeAttrInto(allocator, out, link.url);
                try out.appendSlice(allocator, "\">");
                try convertInto(allocator, out, link.label);
                try out.appendSlice(allocator, "</a>");
                i = link.end;
                continue;
            }
        }

        try escapeChar(allocator, out, text[i]);
        i += 1;
    }
}

fn matchesAt(text: []const u8, i: usize, needle: []const u8) bool {
    return i + needle.len <= text.len and std.mem.eql(u8, text[i .. i + needle.len], needle);
}

fn isLikelyLangTag(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '#' or c == '-')) return false;
    }
    return true;
}

const Link = struct { label: []const u8, url: []const u8, end: usize };

/// Parses a `[label](url)` starting at `text[i] == '['`. Doesn't handle
/// nested brackets/parens in `label`/`url` — an acceptable gap for the
/// simple links LLM output typically contains, and a malformed/unclosed
/// attempt just falls through to being escaped as literal text (see
/// `convertInto`'s caller), same graceful-degradation story as every other
/// construct here.
fn parseLink(text: []const u8, i: usize) ?Link {
    const close_bracket = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse return null;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;
    const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse return null;
    const url = text[close_bracket + 2 .. close_paren];
    if (url.len == 0) return null;
    return .{ .label = text[i + 1 .. close_bracket], .url = url, .end = close_paren + 1 };
}

fn escapeInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| try escapeChar(allocator, out, c);
}

fn escapeAttrInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        if (c == '"') {
            try out.appendSlice(allocator, "&quot;");
            continue;
        }
        try escapeChar(allocator, out, c);
    }
}

fn escapeChar(allocator: std.mem.Allocator, out: *std.ArrayList(u8), c: u8) !void {
    switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        // Control bytes (our own sentinel bytes included, if one somehow
        // reaches here unpaired — e.g. a truncated stream) are dropped:
        // Telegram's HTML parser has no use for raw control bytes either.
        // \t/\n/\r are kept since they're meaningful whitespace.
        0...8, 11, 12, 14...31 => {},
        else => try out.append(allocator, c),
    }
}

const testing = std.testing;

test "toHtml escapes plain text with nothing to convert, byte-for-byte identical otherwise" {
    const a = testing.allocator;
    const out = try toHtml(a, "just plain text, nothing special");
    defer a.free(out);
    try testing.expectEqualStrings("just plain text, nothing special", out);
}

test "toHtml escapes literal & < > without touching anything else" {
    const a = testing.allocator;
    const out = try toHtml(a, "3 < 5 && 5 > 3, Q&A");
    defer a.free(out);
    try testing.expectEqualStrings("3 &lt; 5 &amp;&amp; 5 &gt; 3, Q&amp;A", out);
}

test "toHtml converts bold" {
    const a = testing.allocator;
    const out = try toHtml(a, "this is **important** stuff");
    defer a.free(out);
    try testing.expectEqualStrings("this is <b>important</b> stuff", out);
}

test "toHtml converts inline code without interpreting markdown inside it" {
    const a = testing.allocator;
    const out = try toHtml(a, "run `echo **not bold** <ok>` now");
    defer a.free(out);
    try testing.expectEqualStrings("run <code>echo **not bold** &lt;ok&gt;</code> now", out);
}

test "toHtml converts a fenced code block and drops a leading language tag" {
    const a = testing.allocator;
    const out = try toHtml(a, "```zig\nconst x = 1 < 2;\n```");
    defer a.free(out);
    try testing.expectEqualStrings("<pre><code>const x = 1 &lt; 2;\n</code></pre>", out);
}

test "toHtml converts a fenced code block with no language tag, keeping the fence's own leading newline" {
    const a = testing.allocator;
    const out = try toHtml(a, "```\nplain block\n```");
    defer a.free(out);
    // No language tag to strip (the first line right after the opening
    // fence is empty, not a tag), so the newline that always immediately
    // follows an opening ``` fence is part of the content as-is.
    try testing.expectEqualStrings("<pre><code>\nplain block\n</code></pre>", out);
}

test "toHtml converts a markdown link, escaping quotes in the url" {
    const a = testing.allocator;
    const out = try toHtml(a, "see [the docs](https://example.com/a\"b)");
    defer a.free(out);
    try testing.expectEqualStrings("see <a href=\"https://example.com/a&quot;b\">the docs</a>", out);
}

test "toHtml leaves an unclosed bold marker as literal text instead of eating the rest of the message" {
    const a = testing.allocator;
    const out = try toHtml(a, "starting to say **something bold with no close");
    defer a.free(out);
    try testing.expectEqualStrings("starting to say **something bold with no close", out);
}

test "toHtml leaves an unclosed inline code backtick as literal text" {
    const a = testing.allocator;
    const out = try toHtml(a, "a stray ` backtick");
    defer a.free(out);
    try testing.expectEqualStrings("a stray ` backtick", out);
}

test "toHtml leaves an unclosed link bracket as literal text" {
    const a = testing.allocator;
    const out = try toHtml(a, "a [bracket with no close");
    defer a.free(out);
    try testing.expectEqualStrings("a [bracket with no close", out);
}

test "toHtml renders a thinking-wrapped span as an expandable blockquote, converting markdown inside it too" {
    const a = testing.allocator;
    const text = try std.fmt.allocPrint(a, "{s}pondering **hard**{s}\n\nthe answer is 4", .{ llm.thinking_start, llm.thinking_end });
    defer a.free(text);

    const out = try toHtml(a, text);
    defer a.free(out);
    try testing.expectEqualStrings(
        "<blockquote expandable>\u{1F4AD} pondering <b>hard</b></blockquote>\n\nthe answer is 4",
        out,
    );
}

test "toHtml keeps whitespace control characters but drops other control bytes" {
    const a = testing.allocator;
    const out = try toHtml(a, "line one\nline\ttwo\x07bell");
    defer a.free(out);
    try testing.expectEqualStrings("line one\nline\ttwobell", out);
}
