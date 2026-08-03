const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One custom command shortcut (ROADMAP.md's Phase 19) -- typing `/name`
/// re-dispatches `expansion` (plus any trailing text the user typed after
/// the alias) exactly as if it had been typed directly, see `main.zig`'s
/// alias-expansion step right after `/sudo` unwrapping. Chat-scoped and
/// shared, same "creator or the bot owner may remove" model
/// `notes.zig`/`expenses.zig` already use. `name` is always stored
/// lowercase, without its leading slash (see `main.zig`'s
/// `handleAliasCommand`, which also rejects any name colliding with a
/// real built-in command before this is ever called).
pub const CommandAlias = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    name: []const u8,
    expansion: []const u8,
    created_at: i64,
};

/// Upserts `(chat_id, name)` -- saving over an existing alias name
/// replaces its expansion (and reassigns "who added it" to whoever just
/// saved it, a deliberate simplification: the alternative, rejecting a
/// re-save from someone other than the original creator, adds real
/// friction to a shared-chat power tool for little benefit).
pub fn set(pool: *PgPool, chat_id: i64, identity_id: i64, name: []const u8, expansion: []const u8, created_at: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO command_aliases (chat_id, identity_id, name, expansion, created_at) VALUES ($1, $2, $3, $4, to_timestamp($5))
        \\ON CONFLICT (chat_id, name) DO UPDATE SET
        \\  identity_id = excluded.identity_id, expansion = excluded.expansion
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, name);
    stmt.bindText(4, expansion);
    stmt.bindInt64(5, created_at);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// `null` if `name` isn't a known alias in this chat -- the lookup
/// `main.zig`'s alias-expansion step runs on every slash command.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, name: []const u8) !?CommandAlias {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, identity_id, expansion, EXTRACT(EPOCH FROM created_at)::bigint FROM command_aliases WHERE chat_id = $1 AND name = $2;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, name);
    if (!try stmt.step()) return null;
    return .{
        .id = stmt.columnInt64(0),
        .chat_id = chat_id,
        .identity_id = stmt.columnInt64(1),
        .name = try allocator.dupe(u8, name),
        .expansion = try allocator.dupe(u8, stmt.columnText(2)),
        .created_at = stmt.columnInt64(3),
    };
}

/// Every alias in one chat, alphabetical by name -- backs `/alias list`.
pub fn listForChat(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]CommandAlias {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, identity_id, name, expansion, EXTRACT(EPOCH FROM created_at)::bigint FROM command_aliases WHERE chat_id = $1 ORDER BY name ASC;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(CommandAlias) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = chat_id,
            .identity_id = stmt.columnInt64(1),
            .name = try allocator.dupe(u8, stmt.columnText(2)),
            .expansion = try allocator.dupe(u8, stmt.columnText(3)),
            .created_at = stmt.columnInt64(4),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn remove(pool: *PgPool, chat_id: i64, name: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM command_aliases WHERE chat_id = $1 AND name = $2;");
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
    const bob = try identities.getOrCreateMinimal(&pool, .telegram, "2", "bob", null, false, 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try set(&pool, chat1, alice, "gm", "/weather Tehran", 1000);
    _ = try set(&pool, chat2, alice, "gm", "/weather Berlin", 1000); // scoped per chat

    const fetched = (try get(&pool, a, chat1, "gm")).?;
    try testing.expectEqualStrings("/weather Tehran", fetched.expansion);
    try testing.expectEqual(alice, fetched.identity_id);

    try testing.expectEqual(@as(?CommandAlias, null), try get(&pool, a, chat1, "nonexistent"));

    // Upsert by a different identity reassigns ownership and replaces the
    // expansion, doesn't add a second row.
    _ = try set(&pool, chat1, bob, "gm", "/weather Oslo", 2000);
    const listed = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("/weather Oslo", listed[0].expansion);
    try testing.expectEqual(bob, listed[0].identity_id);

    try remove(&pool, chat1, "gm");
    try testing.expectEqual(@as(?CommandAlias, null), try get(&pool, a, chat1, "gm"));
}
