const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One manual expense entry (ROADMAP.md's Phase 17) -- chat-scoped and
/// visible to the whole chat, same "shared, but only the creator or the
/// bot owner may delete" model `notes.zig`/`reminders.zig` already use.
/// `amount_cents` is always a positive integer (enforced by the
/// `0029_expenses.sql` CHECK constraint) -- see that migration's comment
/// for why cents, never a float, back real money here.
pub const Expense = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    amount_cents: i64,
    currency: []const u8,
    category: []const u8,
    description: ?[]const u8,
    created_at: i64,
};

pub fn create(pool: *PgPool, chat_id: i64, identity_id: i64, amount_cents: i64, currency: []const u8, category: []const u8, description: ?[]const u8, created_at: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO expenses (chat_id, identity_id, amount_cents, currency, category, description, created_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, to_timestamp($7))
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindInt64(3, amount_cents);
    stmt.bindText(4, currency);
    stmt.bindText(5, category);
    if (description) |d| stmt.bindText(6, d) else stmt.bindNull(6);
    stmt.bindInt64(7, created_at);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Most recent `limit` expenses in `chat_id`, newest first, optionally
/// narrowed to one `category` and/or a `since_ts` floor -- backs
/// `/expense list`. Same NULL-coalescing optional-filter idiom
/// `notes.listForIdentity` already uses for its own optional `chat_id`.
pub fn listForChat(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, category: ?[]const u8, since_ts: ?i64, limit: i64) ![]Expense {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, identity_id, amount_cents, currency, category, description, EXTRACT(EPOCH FROM created_at)::bigint
        \\FROM expenses
        \\WHERE chat_id = $1
        \\  AND ($2::text IS NULL OR category = $2)
        \\  AND ($3::bigint IS NULL OR created_at >= to_timestamp($3))
        \\ORDER BY created_at DESC LIMIT $4;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (category) |c| stmt.bindText(2, c) else stmt.bindNull(2);
    if (since_ts) |s| stmt.bindInt64(3, s) else stmt.bindNull(3);
    stmt.bindInt64(4, limit);

    var out: std.ArrayList(Expense) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = chat_id,
            .identity_id = stmt.columnInt64(1),
            .amount_cents = stmt.columnInt64(2),
            .currency = try allocator.dupe(u8, stmt.columnText(3)),
            .category = try allocator.dupe(u8, stmt.columnText(4)),
            .description = if (stmt.columnIsNull(5)) null else try allocator.dupe(u8, stmt.columnText(5)),
            .created_at = stmt.columnInt64(6),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` if no such expense exists -- used by `/expense delete` to check
/// chat/creator before deleting, same pattern as `notes.get`.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Expense {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT chat_id, identity_id, amount_cents, currency, category, description, EXTRACT(EPOCH FROM created_at)::bigint FROM expenses WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .chat_id = stmt.columnInt64(0),
        .identity_id = stmt.columnInt64(1),
        .amount_cents = stmt.columnInt64(2),
        .currency = try allocator.dupe(u8, stmt.columnText(3)),
        .category = try allocator.dupe(u8, stmt.columnText(4)),
        .description = if (stmt.columnIsNull(5)) null else try allocator.dupe(u8, stmt.columnText(5)),
        .created_at = stmt.columnInt64(6),
    };
}

pub fn delete(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM expenses WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

pub const CategoryTotal = struct {
    category: []const u8,
    total_cents: i64,
};

/// Per-category totals since `since_ts` (null = all time), highest first
/// -- backs `/expense summary` and `/budget list`'s "spent so far this
/// month" column. Sums naively across whatever currencies happen to be
/// recorded in a category -- see `Expense`'s doc comment on the v1
/// single-effective-currency assumption.
pub fn totalsByCategory(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64, since_ts: ?i64) ![]CategoryTotal {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT category, SUM(amount_cents)
        \\FROM expenses
        \\WHERE chat_id = $1 AND ($2::bigint IS NULL OR created_at >= to_timestamp($2))
        \\GROUP BY category ORDER BY SUM(amount_cents) DESC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (since_ts) |s| stmt.bindInt64(2, s) else stmt.bindNull(2);

    var out: std.ArrayList(CategoryTotal) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .category = try allocator.dupe(u8, stmt.columnText(0)),
            .total_cents = stmt.columnInt64(1),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Grand total since `since_ts` (null = all time) across every category --
/// 0 if there are no matching expenses at all (a bare `SUM()` over zero
/// rows is SQL NULL, not 0, so this coalesces before returning).
pub fn totalForChat(pool: *PgPool, chat_id: i64, since_ts: ?i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT COALESCE(SUM(amount_cents), 0)
        \\FROM expenses
        \\WHERE chat_id = $1 AND ($2::bigint IS NULL OR created_at >= to_timestamp($2));
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    if (since_ts) |s| stmt.bindInt64(2, s) else stmt.bindNull(2);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "create/listForChat/get/delete round trip, scoped per chat" {
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

    const id = try create(&pool, chat1, alice, 1250, "USD", "food", "lunch", 1000);
    _ = try create(&pool, chat2, alice, 500, "USD", "food", null, 1000);

    const listed1 = try listForChat(&pool, a, chat1, null, null, 100);
    try testing.expectEqual(@as(usize, 1), listed1.len);
    try testing.expectEqual(@as(i64, 1250), listed1[0].amount_cents);
    try testing.expectEqualStrings("lunch", listed1[0].description.?);

    const listed2 = try listForChat(&pool, a, chat2, null, null, 100);
    try testing.expectEqual(@as(usize, 1), listed2.len); // scoped per chat

    const fetched = (try get(&pool, a, id)).?;
    try testing.expectEqual(chat1, fetched.chat_id);
    try testing.expectEqualStrings("food", fetched.category);

    try delete(&pool, id);
    try testing.expectEqual(@as(?Expense, null), try get(&pool, a, id));
}

test "listForChat filters by category and since_ts" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try create(&pool, chat1, alice, 1000, "USD", "food", null, 1000);
    _ = try create(&pool, chat1, alice, 2000, "USD", "transport", null, 2000);
    _ = try create(&pool, chat1, alice, 3000, "USD", "food", null, 3000);

    const food_only = try listForChat(&pool, a, chat1, "food", null, 100);
    try testing.expectEqual(@as(usize, 2), food_only.len);

    const since_recent = try listForChat(&pool, a, chat1, null, 2500, 100);
    try testing.expectEqual(@as(usize, 1), since_recent.len);
    try testing.expectEqual(@as(i64, 3000), since_recent[0].amount_cents);
}

test "totalsByCategory and totalForChat sum correctly and totalForChat is 0 with no matching rows" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(i64, 0), try totalForChat(&pool, chat1, null));

    _ = try create(&pool, chat1, alice, 1000, "USD", "food", null, 1000);
    _ = try create(&pool, chat1, alice, 500, "USD", "food", null, 1000);
    _ = try create(&pool, chat1, alice, 2000, "USD", "transport", null, 1000);

    try testing.expectEqual(@as(i64, 3500), try totalForChat(&pool, chat1, null));

    const totals = try totalsByCategory(&pool, a, chat1, null);
    try testing.expectEqual(@as(usize, 2), totals.len);
    // highest total first: transport (2000) > food (1000+500=1500).
    try testing.expectEqualStrings("transport", totals[0].category);
    try testing.expectEqual(@as(i64, 2000), totals[0].total_cents);
    try testing.expectEqualStrings("food", totals[1].category);
    try testing.expectEqual(@as(i64, 1500), totals[1].total_cents);
}
