const std = @import("std");
const Io = std.Io;
const Db = @import("../store/db.zig").Db;

pub const WordCount = struct { word: []const u8, count: u32 };

/// How many of the chat's most recent logged messages to tokenize. Bounded
/// so a very active chat doesn't make this scan unboundedly large — matches
/// the "recently discussed" framing used elsewhere (qa.zig's history
/// window, retention pruning).
const message_window = 5000;
const min_word_len = 3;
const max_word_len = 30;

/// Common English function words filtered out before counting — without
/// this the cloud is just "the/and/that" in giant letters.
const stopwords = [_][]const u8{
    "the",  "and",  "for",  "are",  "but",  "not",  "you",  "your",
    "with", "this", "that", "have", "has",  "had",  "was",  "were",
    "will", "would", "can", "could", "should", "just", "like", "get",
    "got",  "its",  "it's", "about", "what", "when", "where", "who",
    "why",  "how",  "all",  "any",   "some", "such", "than",  "then",
    "them", "they", "their", "there", "here", "from", "into", "out",
    "over", "under", "again", "also", "very", "one",  "two",  "now",
    "yeah", "yes",  "no",   "ok",    "okay", "lol",  "haha",  "did",
    "does", "doing", "done", "being", "been", "our",  "his",  "her",
    "she",  "him",   "these", "those", "because", "still", "want",
    "think", "know", "really", "much", "more", "well", "make", "made",
};

fn isStopword(word: []const u8) bool {
    for (stopwords) |s| {
        if (std.mem.eql(u8, s, word)) return true;
    }
    return false;
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Tokenizes recent message text into lowercased word counts, filtered of
/// stopwords/digits/very short or long tokens. Not `.deinit()`'d
/// internally — callers are expected to run this against an arena (same
/// pattern as `chat_store`/`toolcall`), so the hash map's storage rides
/// along and gets reclaimed for free.
pub fn topWords(allocator: std.mem.Allocator, db: *Db, top_n: usize) ![]WordCount {
    var stmt = try db.prepare("SELECT text FROM messages WHERE text IS NOT NULL ORDER BY id DESC LIMIT ?;");
    defer stmt.finalize();
    stmt.bindInt64(1, message_window);

    var counts = std.StringHashMap(u32).init(allocator);
    while (try stmt.step()) {
        const text = stmt.columnText(0);
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,!?;:\"'()[]{}<>/\\|`~@#$%^&*_+=-");
        while (it.next()) |raw| {
            if (raw.len < min_word_len or raw.len > max_word_len) continue;
            const lower = try std.ascii.allocLowerString(allocator, raw);
            if (isStopword(lower) or isAllDigits(lower)) continue;

            const gop = try counts.getOrPut(lower);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }
    }

    var list: std.ArrayList(WordCount) = .empty;
    var it = counts.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, .{ .word = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    const items = try list.toOwnedSlice(allocator);
    std.mem.sort(WordCount, items, {}, moreFrequentFirst);
    return if (items.len > top_n) items[0..top_n] else items;
}

fn moreFrequentFirst(_: void, a: WordCount, b: WordCount) bool {
    return a.count > b.count;
}

/// Shells out to the bundled Node renderer (`tools/wordcloud/render.mjs`)
/// and returns the resulting PNG bytes. Requires `node` on PATH.
pub fn render(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, words: []const WordCount) ![]const u8 {
    if (words.len == 0) return error.NoWords;

    try Io.Dir.cwd().createDirPath(io, tmp_dir);

    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const input_path = try std.fmt.allocPrint(allocator, "{s}/wordcloud_{d}.json", .{ tmp_dir, ts });
    defer allocator.free(input_path);
    defer Io.Dir.cwd().deleteFile(io, input_path) catch {};

    {
        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try std.json.Stringify.value(words, .{}, &payload_writer.writer);

        var file = try Io.Dir.cwd().createFile(io, input_path, .{});
        defer file.close(io);
        var file_writer = file.writer(io, &.{});
        try file_writer.interface.writeAll(payload_writer.writer.buffered());
        try file_writer.interface.flush();
    }

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "node", "tools/wordcloud/render.mjs", input_path },
    });
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("wordcloud render failed (term={any}): {s}", .{ result.term, result.stderr });
        allocator.free(result.stdout);
        return error.RenderFailed;
    }

    // std.debug.print("{s}\n", .{result.stderr});
    return result.stdout;
}

const testing = std.testing;

test "topWords ranks by frequency and filters stopwords/short tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_path = "zig-cache-test-wordcloud/topwords.db";
    defer Io.Dir.cwd().deleteTree(testing.io, "zig-cache-test-wordcloud") catch {};
    try Io.Dir.cwd().createDirPath(testing.io, "zig-cache-test-wordcloud");

    var db = try Db.open(tmp_path);
    defer db.close();
    try @import("../store/schema.zig").migrate(&db);

    const texts = [_][]const u8{
        "zig is great and zig is fast",
        "the zig compiler is neat",
        "I love zig so much",
        "a", // too short, filtered
        "the and but", // all stopwords
    };
    for (texts) |t| {
        var stmt = try db.prepare("INSERT INTO messages (user_id, text, ts) VALUES ('1', ?, 0);");
        defer stmt.finalize();
        stmt.bindText(1, t);
        _ = try stmt.step();
    }

    const words = try topWords(a, &db, 10);
    try testing.expect(words.len > 0);
    try testing.expectEqualStrings("zig", words[0].word);
    try testing.expectEqual(@as(u32, 4), words[0].count);

    for (words) |w| {
        try testing.expect(!isStopword(w.word));
        try testing.expect(w.word.len >= min_word_len);
    }
}
