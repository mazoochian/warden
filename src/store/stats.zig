const std = @import("std");
const Db = @import("db.zig").Db;

pub const TopUser = struct {
    user_id: []const u8,
    /// Empty if the user has no username set.
    username: []const u8,
    message_count: i64,
};

pub const Stats = struct {
    total_messages: i64,
    distinct_users: i64,
    top_users: []TopUser,
};

/// Pure SQLite aggregate queries — no LLM involved, so this can't hallucinate
/// counts and costs nothing to call.
pub fn compute(db: *Db, allocator: std.mem.Allocator, top_n: usize) !Stats {
    const total = try scalarInt(db, "SELECT COUNT(*) FROM messages;");
    const distinct = try scalarInt(db, "SELECT COUNT(DISTINCT user_id) FROM messages;");

    var stmt = try db.prepare(
        \\SELECT user_id, username, COUNT(*) as message_count FROM messages
        \\GROUP BY user_id ORDER BY message_count DESC LIMIT ?;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, @intCast(top_n));

    var top_users: std.ArrayList(TopUser) = .empty;
    while (try stmt.step()) {
        try top_users.append(allocator, .{
            .user_id = try allocator.dupe(u8, stmt.columnText(0)),
            .username = try allocator.dupe(u8, stmt.columnText(1)),
            .message_count = stmt.columnInt64(2),
        });
    }

    return .{
        .total_messages = total,
        .distinct_users = distinct,
        .top_users = try top_users.toOwnedSlice(allocator),
    };
}

fn scalarInt(db: *Db, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt64(0);
}
