const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One per-category monthly budget (ROADMAP.md's Phase 17) -- see the
/// `0030_budgets.sql` migration comment for why "monthly" is fixed rather
/// than a selectable period. Chat-wide, not per-identity: a shared budget
/// a whole chat sees, same "policy" tier `chat_settings.system_prompt`
/// already treats as owner-only to change (see `main.zig`'s
/// `handleBudgetCommand`).
pub const Budget = struct {
    id: i64,
    chat_id: i64,
    category: []const u8,
    amount_cents: i64,
    currency: []const u8,
};

/// Upserts the budget for `(chat_id, category)` -- `/budget set` always
/// replaces whatever was there before, same "one call does create-or-
/// update" shape `chat_settings.setSystemPromptOverride` already uses.
pub fn set(pool: *PgPool, chat_id: i64, category: []const u8, amount_cents: i64, currency: []const u8) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO budgets (chat_id, category, amount_cents, currency) VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (chat_id, category) DO UPDATE SET
        \\  amount_cents = excluded.amount_cents, currency = excluded.currency
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, category);
    stmt.bindInt64(3, amount_cents);
    stmt.bindText(4, currency);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Every budget in one chat, alphabetical by category -- backs `/budget
/// list`.
pub fn listForChat(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]Budget {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT id, category, amount_cents, currency FROM budgets WHERE chat_id = $1 ORDER BY category ASC;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(Budget) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = chat_id,
            .category = try allocator.dupe(u8, stmt.columnText(1)),
            .amount_cents = stmt.columnInt64(2),
            .currency = try allocator.dupe(u8, stmt.columnText(3)),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn remove(pool: *PgPool, chat_id: i64, category: []const u8) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM budgets WHERE chat_id = $1 AND category = $2;");
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindText(2, category);
    _ = try stmt.step();
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");

test "set is an upsert keyed by (chat_id, category), listForChat is alphabetical, remove deletes" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try set(&pool, chat1, "transport", 10000, "USD");
    _ = try set(&pool, chat1, "food", 30000, "USD");
    _ = try set(&pool, chat2, "food", 99900, "USD"); // scoped per chat

    const listed = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("food", listed[0].category); // alphabetical
    try testing.expectEqual(@as(i64, 30000), listed[0].amount_cents);
    try testing.expectEqualStrings("transport", listed[1].category);

    // Upsert: setting "food" again replaces the amount, doesn't add a row.
    _ = try set(&pool, chat1, "food", 35000, "USD");
    const listed2 = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 2), listed2.len);
    try testing.expectEqual(@as(i64, 35000), listed2[0].amount_cents);

    try remove(&pool, chat1, "food");
    const listed3 = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 1), listed3.len);
    try testing.expectEqualStrings("transport", listed3[0].category);
}
