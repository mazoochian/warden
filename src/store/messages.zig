const std = @import("std");
const Db = @import("db.zig").Db;
const iface = @import("../platform/interface.zig");

/// Logs one message and upserts its sender into `users`. Called for every
/// inbound message regardless of sender — the owner-only gate is about
/// replies/actions, not what gets recorded.
pub fn insert(db: *Db, msg: iface.Message, ts: i64) !void {
    {
        var stmt = try db.prepare("INSERT INTO messages (user_id, username, text, ts) VALUES (?, ?, ?, ?);");
        defer stmt.finalize();
        stmt.bindText(1, msg.user_id);
        if (msg.username) |u| stmt.bindText(2, u) else stmt.bindNull(2);
        if (msg.text) |t| stmt.bindText(3, t) else stmt.bindNull(3);
        stmt.bindInt64(4, ts);
        _ = try stmt.step();
    }
    {
        var stmt = try db.prepare(
            \\INSERT INTO users (user_id, username, last_seen) VALUES (?, ?, ?)
            \\ON CONFLICT(user_id) DO UPDATE SET username=excluded.username, last_seen=excluded.last_seen;
        );
        defer stmt.finalize();
        stmt.bindText(1, msg.user_id);
        if (msg.username) |u| stmt.bindText(2, u) else stmt.bindNull(2);
        stmt.bindInt64(3, ts);
        _ = try stmt.step();
    }
}

/// Deletes everything older than the most recent `keep` messages. Bounds
/// per-chat DB growth so "recently discussed" stays honest instead of
/// accumulating forever. No-ops if fewer than `keep` rows exist.
pub fn pruneKeepLast(db: *Db, keep: i64) !void {
    std.debug.assert(keep > 0);
    var stmt = try db.prepare(
        \\DELETE FROM messages WHERE id < (
        \\  SELECT id FROM messages ORDER BY id DESC LIMIT 1 OFFSET ?
        \\);
    );
    defer stmt.finalize();
    stmt.bindInt64(1, keep - 1);
    _ = try stmt.step();
}

/// Renders the most recent `limit` messages (oldest first) as
/// "username: text" lines, for grounding free-form LLM questions in this
/// chat's actual local history rather than model memory.
pub fn recentFormatted(db: *Db, allocator: std.mem.Allocator, limit: i64) ![]const u8 {
    var stmt = try db.prepare(
        \\SELECT username, text FROM messages
        \\WHERE text IS NOT NULL
        \\ORDER BY id DESC LIMIT ?;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, limit);

    var lines: std.ArrayList([]const u8) = .empty;
    while (try stmt.step()) {
        const username = stmt.columnText(0);
        const who = if (username.len > 0) username else "unknown";
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ who, stmt.columnText(1) }));
    }
    std.mem.reverse([]const u8, lines.items); // rows came back newest-first
    return std.mem.join(allocator, "\n", lines.items);
}
