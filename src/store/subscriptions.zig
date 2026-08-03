const std = @import("std");
const PgPool = @import("pool.zig").PgPool;

/// One recurring cost (ROADMAP.md's Phase 17) -- a read-only ledger of
/// "what am I paying for and how much per month total," not a second
/// reminder-firing scheduler; see the `0031_subscriptions.sql` migration
/// comment for why "remind me when it's due" is deliberately left to the
/// existing `/remind every <interval> <message>` instead of duplicated
/// here. Chat-scoped and shared, same "creator or the bot owner may
/// remove" model `notes.zig`/`expenses.zig` already use.
pub const Subscription = struct {
    id: i64,
    chat_id: i64,
    identity_id: i64,
    name: []const u8,
    amount_cents: i64,
    currency: []const u8,
    interval_days: i64,
    created_at: i64,
};

pub fn create(pool: *PgPool, chat_id: i64, identity_id: i64, name: []const u8, amount_cents: i64, currency: []const u8, interval_days: i64, created_at: i64) !i64 {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\INSERT INTO subscriptions (chat_id, identity_id, name, amount_cents, currency, interval_days, created_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, to_timestamp($7))
        \\RETURNING id;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);
    stmt.bindInt64(2, identity_id);
    stmt.bindText(3, name);
    stmt.bindInt64(4, amount_cents);
    stmt.bindText(5, currency);
    stmt.bindInt64(6, interval_days);
    stmt.bindInt64(7, created_at);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Every subscription in one chat, oldest first -- backs `/subscription
/// list`.
pub fn listForChat(pool: *PgPool, allocator: std.mem.Allocator, chat_id: i64) ![]Subscription {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT id, identity_id, name, amount_cents, currency, interval_days, EXTRACT(EPOCH FROM created_at)::bigint
        \\FROM subscriptions WHERE chat_id = $1
        \\ORDER BY created_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, chat_id);

    var out: std.ArrayList(Subscription) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = chat_id,
            .identity_id = stmt.columnInt64(1),
            .name = try allocator.dupe(u8, stmt.columnText(2)),
            .amount_cents = stmt.columnInt64(3),
            .currency = try allocator.dupe(u8, stmt.columnText(4)),
            .interval_days = stmt.columnInt64(5),
            .created_at = stmt.columnInt64(6),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// One row for the web API's `GET /api/v1/subscriptions` -- identity-
/// scoped (not chat-scoped like `Subscription`/`listForChat` above, which
/// back the bot's own in-chat `/subscription list`), so each row carries
/// its own chat context for a "everything I'm paying for, across every
/// chat" view, same shape as `expenses.ExpenseForIdentity`/
/// `notes.NoteForIdentity`.
pub const SubscriptionForIdentity = struct {
    id: i64,
    chat_id: i64,
    chat_title: ?[]const u8,
    name: []const u8,
    amount_cents: i64,
    currency: []const u8,
    interval_days: i64,
    created_at: i64,
};

/// Subscriptions added by one identity, optionally narrowed to one chat
/// -- see `SubscriptionForIdentity`'s doc comment for why this is a
/// separate query from `listForChat`. Oldest first, same ordering
/// `listForChat` already uses.
pub fn listForIdentity(pool: *PgPool, allocator: std.mem.Allocator, identity_id: i64, chat_id: ?i64) ![]SubscriptionForIdentity {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare(
        \\SELECT s.id, s.chat_id, c.title, s.name, s.amount_cents, s.currency, s.interval_days,
        \\       EXTRACT(EPOCH FROM s.created_at)::bigint
        \\FROM subscriptions s JOIN chats c ON c.id = s.chat_id
        \\WHERE s.identity_id = $1 AND ($2::bigint IS NULL OR s.chat_id = $2)
        \\ORDER BY s.created_at ASC;
    );
    defer stmt.finalize();
    stmt.bindInt64(1, identity_id);
    if (chat_id) |c| stmt.bindInt64(2, c) else stmt.bindNull(2);

    var out: std.ArrayList(SubscriptionForIdentity) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, .{
            .id = stmt.columnInt64(0),
            .chat_id = stmt.columnInt64(1),
            .chat_title = if (stmt.columnIsNull(2)) null else try allocator.dupe(u8, stmt.columnText(2)),
            .name = try allocator.dupe(u8, stmt.columnText(3)),
            .amount_cents = stmt.columnInt64(4),
            .currency = try allocator.dupe(u8, stmt.columnText(5)),
            .interval_days = stmt.columnInt64(6),
            .created_at = stmt.columnInt64(7),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `null` if no such subscription exists -- used by `/subscription
/// remove` to check chat/creator before deleting, same pattern as
/// `notes.get`.
pub fn get(pool: *PgPool, allocator: std.mem.Allocator, id: i64) !?Subscription {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("SELECT chat_id, identity_id, name, amount_cents, currency, interval_days, EXTRACT(EPOCH FROM created_at)::bigint FROM subscriptions WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return .{
        .id = id,
        .chat_id = stmt.columnInt64(0),
        .identity_id = stmt.columnInt64(1),
        .name = try allocator.dupe(u8, stmt.columnText(2)),
        .amount_cents = stmt.columnInt64(3),
        .currency = try allocator.dupe(u8, stmt.columnText(4)),
        .interval_days = stmt.columnInt64(5),
        .created_at = stmt.columnInt64(6),
    };
}

pub fn remove(pool: *PgPool, id: i64) !void {
    const db = try pool.acquire();
    defer pool.release(db);

    var stmt = try db.prepare("DELETE FROM subscriptions WHERE id = $1;");
    defer stmt.finalize();
    stmt.bindInt64(1, id);
    _ = try stmt.step();
}

/// `amount_cents` expressed as a 30-day-month equivalent -- e.g. a $84/yr
/// subscription is ~$7/mo. Approximate by construction (see this file's
/// own doc comment on `interval_days` not being calendar-aware) but good
/// enough to answer "what's my total monthly recurring spend," the
/// actual point of tracking these at all.
pub fn monthlyEquivalentCents(amount_cents: i64, interval_days: i64) i64 {
    return @divTrunc(amount_cents * 30, interval_days);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const chats = @import("chats.zig");
const identities = @import("identities.zig");

test "create/listForChat/get/remove round trip, scoped per chat" {
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

    const id = try create(&pool, chat1, alice, "Netflix", 1599, "USD", 30, 1000);
    _ = try create(&pool, chat2, alice, "Spotify", 999, "USD", 30, 1000);

    const listed1 = try listForChat(&pool, a, chat1);
    try testing.expectEqual(@as(usize, 1), listed1.len);
    try testing.expectEqualStrings("Netflix", listed1[0].name);

    const listed2 = try listForChat(&pool, a, chat2);
    try testing.expectEqual(@as(usize, 1), listed2.len); // scoped per chat

    const fetched = (try get(&pool, a, id)).?;
    try testing.expectEqual(chat1, fetched.chat_id);
    try testing.expectEqualStrings("Netflix", fetched.name);

    try remove(&pool, id);
    try testing.expectEqual(@as(?Subscription, null), try get(&pool, a, id));
}

test "monthlyEquivalentCents normalizes weekly/monthly/yearly intervals to a 30-day month" {
    try testing.expectEqual(@as(i64, 1599), monthlyEquivalentCents(1599, 30)); // already monthly
    try testing.expectEqual(@as(i64, 690), monthlyEquivalentCents(8400, 365)); // ~$84/yr -> ~$6.90/mo
    try testing.expectEqual(@as(i64, 3000), monthlyEquivalentCents(700, 7)); // $7/wk -> $30/mo
}

test "listForIdentity scopes by identity across chats, optionally narrowed to one" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, "Chat One");
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    const bob = try identities.getOrCreateMinimal(&pool, .telegram, "2", "bob", null, false, 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try create(&pool, chat1, alice, "Netflix", 1599, "USD", 30, 1000);
    _ = try create(&pool, chat2, alice, "Spotify", 999, "USD", 30, 2000);
    _ = try create(&pool, chat1, bob, "Hulu", 799, "USD", 30, 3000);

    const alice_all = try listForIdentity(&pool, a, alice, null);
    try testing.expectEqual(@as(usize, 2), alice_all.len);
    try testing.expectEqualStrings("Netflix", alice_all[0].name); // oldest first
    try testing.expectEqualStrings("Chat One", alice_all[0].chat_title.?);
    try testing.expectEqual(@as(?[]const u8, null), alice_all[1].chat_title); // chat2 has no title

    const alice_chat2 = try listForIdentity(&pool, a, alice, chat2);
    try testing.expectEqual(@as(usize, 1), alice_chat2.len);
    try testing.expectEqualStrings("Spotify", alice_chat2[0].name);

    const bob_all = try listForIdentity(&pool, a, bob, null);
    try testing.expectEqual(@as(usize, 1), bob_all.len); // never sees alice's
}
