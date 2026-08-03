const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One saved prompt (ROADMAP.md's Phase 19) -- `/template use <name>`
/// resends `text` (plus any extra text the user typed) as a question
/// through the normal Q&A pipeline, same `handleModeCommand` path
/// `/eli5`/`/brainstorm` already use. Chat-scoped and shared, same
/// "creator or the bot owner may remove" model `notes.zig`/
/// `command_aliases.zig` already use -- see the latter's doc comment for
/// the same "saving over an existing name reassigns ownership" tradeoff
/// this makes too.
pub const PromptTemplate = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    name: []const u8,
    text: []const u8,
    created_at: i64,
};

pub fn set(pool: *PgPool, chat_id: i64, identity_id: i64, name: []const u8, text: []const u8, created_at: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO prompt_templates (chat_id, identity_id, name, text, created_at) VALUES ($1, $2, $3, $4, to_timestamp($5))
        \\ON CONFLICT (chat_id, name) DO UPDATE SET
        \\  identity_id = excluded.identity_id, text = excluded.text
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, name);
    stmt.bindText(4, text);
    stmt.bindInt64(5, created_at);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

pub fn get(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, name: []const u8) !?PromptTemplate {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, identity_id, text, EXTRACT(EPOCH FROM created_at)::bigint FROM prompt_templates WHERE chat_id = $1 AND name = $2;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, name);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .chat_id = chat_id,
        .identity_id = stmt.columnInt64(1),
        .name = try allocator.dupe(u8, name),
        .text = try allocator.dupe(u8, stmt.columnText(2)),
        .created_at = stmt.columnInt64(3),
    };
}

/// Every template in one chat, alphabetical by name -- backs `/template
/// list`.
pub fn listForChat(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]PromptTemplate {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, identity_id, name, text, EXTRACT(EPOCH FROM created_at)::bigint FROM prompt_templates WHERE chat_id = $1 ORDER BY name ASC;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(PromptTemplate) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = chat_id,
            .identity_id = stmt.columnInt64(1),
            .name = try allocator.dupe(u8, stmt.columnText(2)),
            .text = try allocator.dupe(u8, stmt.columnText(3)),
            .created_at = stmt.columnInt64(4),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn remove(pool: *PgPool, chat_id: i64, name: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM prompt_templates WHERE chat_id = $1 AND name = $2;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, name);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "set is an upsert keyed by (chat_id, name), get/listForChat/remove round trip, scoped per chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try set(&pool, chat1, alice, "standup", "Summarize what's outstanding for our team standup", 1000);
    _ = try set(&pool, chat2, alice, "standup", "Something else entirely", 1000); // scoped per chat

    const fetched = (try get(&pool, a, chat1, "standup")).?;
    try testing.expectEqualStrings("Summarize what's outstanding for our team standup", fetched.text);

    try testing.expectEqual(@as(?PromptTemplate, null), try get(&pool, a, chat1, "nonexistent"));

    _ = try set(&pool, chat1, alice, "standup", "Updated text", 2000);
    const listed = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("Updated text", listed[0].text);

    try remove(&pool, chat1, "standup");
    try testing.expectEqual(@as(?PromptTemplate, null), try get(&pool, a, chat1, "standup"));
}
