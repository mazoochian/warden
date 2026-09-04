const std = @import("std");
const Io = std.Io;
const PgPool = @import("../store/pool.zig").PgPool;
const log = @import("../log.zig").scoped("reply_drafts");

/// One reply drafted on the owner's behalf, waiting for `/approve` or
/// `/discard` — the `reply_autonomy = .draft` counterpart to
/// `group_admin.PendingConfirmations`'s ban/kick confirmation, but backed by
/// Postgres rather than an in-memory map (see below). Everything needed to
/// both show the owner what's pending and actually send it once approved,
/// so `/approve` never has to re-derive anything from the original message.
pub const Draft = struct {
    chat_title: []const u8,
    incoming_text: []const u8,
    draft_text: []const u8,
    /// The incoming message's id, so an approved send threads as a reply
    /// in the real chat instead of arriving as a bare new message.
    reply_to: ?[]const u8,
    /// Whatever the owner had already typed into this chat's Telegram
    /// composer before this draft overwrote it — see
    /// `telegram_user.setChatDraft`. `null` when the composer was empty.
    replaced_draft: ?[]const u8,
};

/// One pending "reply on my behalf" draft per personal-account chat,
/// awaiting the owner's `/approve`/`/discard` (or the equivalent button /
/// web-UI action).
///
/// **Backed by the `reply_drafts` table, not memory.** This was originally
/// a mutex-guarded `std.StringHashMap` living for the lifetime of the
/// process, which meant every restart or deploy silently dropped every
/// pending draft — the owner would get a "draft ready" notification, then
/// find nothing to approve and an empty drafts page. That's the wrong
/// trade-off for this feature specifically: unlike a ban/kick confirmation
/// (answered within seconds by someone at the keyboard, hence
/// `PendingConfirmations`' deliberately short timeout), "reply to this a
/// few hours later when I actually see it" is completely normal for a
/// personal account, so the timeout here is generous — and a draft that
/// doesn't survive a deploy inside that window is a draft the owner was
/// promised and never got. See `0049_reply_drafts.sql`.
///
/// Being DB-backed also means no mutex: Postgres serializes the concurrent
/// access this type gets (the connector that receives the incoming message,
/// the connector the owner taps Approve on, and the web API's request
/// thread are all different threads), where the in-memory version needed
/// its own `Io.Mutex` to be safe.
pub const PendingDrafts = struct {
    pool: *PgPool,
    timeout_seconds: i64,

    pub fn init(pool: *PgPool, timeout_seconds: i64) PendingDrafts {
        return .{ .pool = pool, .timeout_seconds = timeout_seconds };
    }

    /// Replaces any existing pending draft for `native_chat_id` (one draft
    /// per chat — a second one supersedes the first rather than queuing
    /// behind it, exactly as the in-memory map did).
    ///
    /// Also sweeps already-expired rows while it holds a connection: expiry
    /// is lazy (`take`/`list` both filter on `expires_at` rather than
    /// relying on a sweeper having run), so this is purely about not letting
    /// dead rows accumulate forever in a table nothing else ever prunes.
    pub fn set(
        self: *PendingDrafts,
        now: i64,
        native_chat_id: []const u8,
        chat_title: []const u8,
        incoming_text: []const u8,
        draft_text: []const u8,
        reply_to: ?[]const u8,
        replaced_draft: ?[]const u8,
    ) !void {
        const db = try self.pool.acquire();
        defer self.pool.release(db);

        {
            var sweep = try db.prepare("DELETE FROM reply_drafts WHERE expires_at < to_timestamp($1);");
            defer sweep.finalize();
            sweep.bindInt64(1, now);
            _ = try sweep.step();
        }

        var stmt = try db.prepare(
            \\INSERT INTO reply_drafts
            \\  (native_chat_id, chat_title, incoming_text, draft_text, reply_to,
            \\   replaced_draft, created_at, expires_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, to_timestamp($7), to_timestamp($8))
            \\ON CONFLICT (native_chat_id) DO UPDATE SET
            \\  chat_title     = excluded.chat_title,
            \\  incoming_text  = excluded.incoming_text,
            \\  draft_text     = excluded.draft_text,
            \\  reply_to       = excluded.reply_to,
            \\  replaced_draft = excluded.replaced_draft,
            \\  created_at     = excluded.created_at,
            \\  expires_at     = excluded.expires_at;
        );
        defer stmt.finalize();
        stmt.bindText(1, native_chat_id);
        stmt.bindText(2, chat_title);
        stmt.bindText(3, incoming_text);
        stmt.bindText(4, draft_text);
        if (reply_to) |r| stmt.bindText(5, r) else stmt.bindNull(5);
        if (replaced_draft) |r| stmt.bindText(6, r) else stmt.bindNull(6);
        stmt.bindInt64(7, now);
        stmt.bindInt64(8, now + self.timeout_seconds);
        _ = try stmt.step();
    }

    /// Removes and returns the pending draft for `native_chat_id` if one
    /// exists and hasn't expired — the caller owns the returned strings and
    /// must free them. An expired row is deleted and reported as absent,
    /// same as the in-memory version. Returns `null` (never an error) on a
    /// DB failure too: a draft that can't be read back is indistinguishable
    /// from one that isn't there as far as every call site is concerned, and
    /// failing closed here means a transient DB blip can never cause a
    /// half-formed message to go out under the owner's name.
    pub fn take(self: *PendingDrafts, allocator: std.mem.Allocator, now: i64, native_chat_id: []const u8) ?Draft {
        const db = self.pool.acquire() catch return null;
        defer self.pool.release(db);

        var stmt = db.prepare(
            \\DELETE FROM reply_drafts WHERE native_chat_id = $1
            \\RETURNING chat_title, incoming_text, draft_text, reply_to, replaced_draft,
            \\          EXTRACT(EPOCH FROM expires_at)::bigint;
        ) catch |err| {
            log.err("take: prepare failed for chat {s}: {t}", .{ native_chat_id, err });
            return null;
        };
        defer stmt.finalize();
        stmt.bindText(1, native_chat_id);

        const has_row = stmt.step() catch |err| {
            log.err("take: query failed for chat {s}: {t}", .{ native_chat_id, err });
            return null;
        };
        if (!has_row) return null;
        if (now > stmt.columnInt64(5)) return null;

        return .{
            .chat_title = allocator.dupe(u8, stmt.columnText(0)) catch return null,
            .incoming_text = allocator.dupe(u8, stmt.columnText(1)) catch return null,
            .draft_text = allocator.dupe(u8, stmt.columnText(2)) catch return null,
            .reply_to = if (stmt.columnIsNull(3)) null else (allocator.dupe(u8, stmt.columnText(3)) catch return null),
            .replaced_draft = if (stmt.columnIsNull(4)) null else (allocator.dupe(u8, stmt.columnText(4)) catch return null),
        };
    }

    /// Drops the pending draft for `native_chat_id`, reporting whether one
    /// was actually there. An already-expired row still counts as "there"
    /// for this purpose — the owner discarding something they were told
    /// about shouldn't be told it was "already gone" just because the
    /// timeout lapsed a moment earlier.
    pub fn discard(self: *PendingDrafts, native_chat_id: []const u8) bool {
        const db = self.pool.acquire() catch return false;
        defer self.pool.release(db);

        var stmt = db.prepare("DELETE FROM reply_drafts WHERE native_chat_id = $1 RETURNING 1;") catch |err| {
            log.err("discard: prepare failed for chat {s}: {t}", .{ native_chat_id, err });
            return false;
        };
        defer stmt.finalize();
        stmt.bindText(1, native_chat_id);
        return stmt.step() catch false;
    }

    /// The pending draft for `native_chat_id` without consuming it, for the
    /// composer-prefill bookkeeping that needs to know what a chat's current
    /// draft text is (see `main.zig`'s `clearComposerDraftFor`) — `take`
    /// would delete the row it's about to need.
    pub fn peek(self: *PendingDrafts, allocator: std.mem.Allocator, now: i64, native_chat_id: []const u8) ?Draft {
        const db = self.pool.acquire() catch return null;
        defer self.pool.release(db);

        var stmt = db.prepare(
            \\SELECT chat_title, incoming_text, draft_text, reply_to, replaced_draft
            \\FROM reply_drafts
            \\WHERE native_chat_id = $1 AND expires_at >= to_timestamp($2);
        ) catch return null;
        defer stmt.finalize();
        stmt.bindText(1, native_chat_id);
        stmt.bindInt64(2, now);

        const has_row = stmt.step() catch return null;
        if (!has_row) return null;
        return .{
            .chat_title = allocator.dupe(u8, stmt.columnText(0)) catch return null,
            .incoming_text = allocator.dupe(u8, stmt.columnText(1)) catch return null,
            .draft_text = allocator.dupe(u8, stmt.columnText(2)) catch return null,
            .reply_to = if (stmt.columnIsNull(3)) null else (allocator.dupe(u8, stmt.columnText(3)) catch return null),
            .replaced_draft = if (stmt.columnIsNull(4)) null else (allocator.dupe(u8, stmt.columnText(4)) catch return null),
        };
    }

    /// One row of `/drafts` and of `GET /api/v1/telegram-user/drafts` —
    /// serialized to JSON field-for-field, so these names are the web API's
    /// response keys.
    pub const Listed = struct {
        native_chat_id: []const u8,
        chat_title: []const u8,
        incoming_text: []const u8,
        draft_text: []const u8,
        /// Non-null when writing this draft into the Telegram composer
        /// overwrote something the owner had already typed there, so the
        /// drafts page can show it back rather than letting it vanish.
        replaced_draft: ?[]const u8,
    };

    /// Every non-expired pending draft, newest first.
    pub fn list(self: *PendingDrafts, allocator: std.mem.Allocator, now: i64) ![]Listed {
        const db = try self.pool.acquire();
        defer self.pool.release(db);

        var stmt = try db.prepare(
            \\SELECT native_chat_id, chat_title, incoming_text, draft_text, replaced_draft
            \\FROM reply_drafts
            \\WHERE expires_at >= to_timestamp($1)
            \\ORDER BY created_at DESC;
        );
        defer stmt.finalize();
        stmt.bindInt64(1, now);

        var out: std.ArrayList(Listed) = .empty;
        while (try stmt.step()) {
            try out.append(allocator, .{
                .native_chat_id = try allocator.dupe(u8, stmt.columnText(0)),
                .chat_title = try allocator.dupe(u8, stmt.columnText(1)),
                .incoming_text = try allocator.dupe(u8, stmt.columnText(2)),
                .draft_text = try allocator.dupe(u8, stmt.columnText(3)),
                .replaced_draft = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

const testing = std.testing;
const test_support = @import("../store/test_support.zig");

fn freeDraft(d: Draft) void {
    testing.allocator.free(d.chat_title);
    testing.allocator.free(d.incoming_text);
    testing.allocator.free(d.draft_text);
    if (d.reply_to) |r| testing.allocator.free(r);
    if (d.replaced_draft) |r| testing.allocator.free(r);
}

fn freeListed(items: []PendingDrafts.Listed) void {
    for (items) |it| {
        testing.allocator.free(it.native_chat_id);
        testing.allocator.free(it.chat_title);
        testing.allocator.free(it.incoming_text);
        testing.allocator.free(it.draft_text);
        if (it.replaced_draft) |r| testing.allocator.free(r);
    }
    testing.allocator.free(items);
}

test "PendingDrafts: set then take round-trips, a second take sees nothing" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 3600);

    try pending.set(1000, "chat-1", "Alice", "hey are you free tonight?", "Yeah, free after 7", "msg-42", null);
    const got = pending.take(testing.allocator, 1001, "chat-1").?;
    defer freeDraft(got);
    try testing.expectEqualStrings("Alice", got.chat_title);
    try testing.expectEqualStrings("Yeah, free after 7", got.draft_text);
    try testing.expectEqualStrings("msg-42", got.reply_to.?);
    try testing.expectEqual(@as(?[]const u8, null), got.replaced_draft);

    try testing.expect(pending.take(testing.allocator, 1002, "chat-1") == null);
}

test "PendingDrafts: a second set for the same chat replaces the first, not queues" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 3600);

    try pending.set(1000, "chat-1", "Alice", "first message", "first draft", null, null);
    try pending.set(1000, "chat-1", "Alice", "second message", "second draft", null, null);

    const got = pending.take(testing.allocator, 1000, "chat-1").?;
    defer freeDraft(got);
    try testing.expectEqualStrings("second draft", got.draft_text);

    // Replacement, not a second row.
    try testing.expect(pending.take(testing.allocator, 1000, "chat-1") == null);
}

test "PendingDrafts: take past the timeout returns null" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 60);

    try pending.set(1000, "chat-1", "Alice", "hey", "hi!", null, null);
    try testing.expect(pending.take(testing.allocator, 1061, "chat-1") == null);
}

test "PendingDrafts: discard removes a pending draft, reporting whether one existed" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 3600);

    try testing.expect(!pending.discard("chat-1"));
    try pending.set(1000, "chat-1", "Alice", "hey", "hi!", null, null);
    try testing.expect(pending.discard("chat-1"));
    try testing.expect(!pending.discard("chat-1"));
}

test "PendingDrafts: list returns every non-expired draft" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 60);

    try pending.set(1000, "chat-1", "Alice", "hey", "hi Alice!", null, null);
    try pending.set(1000, "chat-2", "Bob", "yo", "hey Bob!", null, null);

    const listed = try pending.list(testing.allocator, 1000);
    defer freeListed(listed);
    try testing.expectEqual(@as(usize, 2), listed.len);

    // ...and hides the expired ones without needing a sweep to have run.
    const later = try pending.list(testing.allocator, 1061);
    defer freeListed(later);
    try testing.expectEqual(@as(usize, 0), later.len);
}

test "PendingDrafts: a draft survives being reconstructed from the same pool" {
    // The whole point of moving this off an in-memory map: a fresh
    // PendingDrafts (as a restarted process would build) still sees drafts
    // written by the previous one.
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    var first = PendingDrafts.init(&pool, 3600);
    try first.set(1000, "chat-1", "Alice", "hey", "hi Alice!", "msg-1", null);

    var restarted = PendingDrafts.init(&pool, 3600);
    const got = restarted.take(testing.allocator, 1001, "chat-1").?;
    defer freeDraft(got);
    try testing.expectEqualStrings("hi Alice!", got.draft_text);
}

test "PendingDrafts: an overwritten composer draft round-trips through set/take and list" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 3600);

    try pending.set(1000, "chat-1", "Alice", "you around?", "yep, what's up", null, "half-typed thing");

    const listed = try pending.list(testing.allocator, 1000);
    defer freeListed(listed);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("half-typed thing", listed[0].replaced_draft.?);
    try testing.expectEqualStrings("you around?", listed[0].incoming_text);

    const got = pending.take(testing.allocator, 1000, "chat-1").?;
    defer freeDraft(got);
    try testing.expectEqualStrings("half-typed thing", got.replaced_draft.?);
}

test "PendingDrafts: peek returns the draft without consuming it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 3600);

    try pending.set(1000, "chat-1", "Alice", "hey", "hi Alice!", null, null);

    const peeked = pending.peek(testing.allocator, 1000, "chat-1").?;
    defer freeDraft(peeked);
    try testing.expectEqualStrings("hi Alice!", peeked.draft_text);

    // Still there afterwards, unlike take.
    const got = pending.take(testing.allocator, 1000, "chat-1").?;
    defer freeDraft(got);
    try testing.expectEqualStrings("hi Alice!", got.draft_text);
}

test "PendingDrafts: set sweeps rows that expired before it ran" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var pending = PendingDrafts.init(&pool, 60);

    try pending.set(1000, "stale-chat", "Alice", "hey", "hi!", null, null);
    // Well past stale-chat's expiry, so this set() should have swept it.
    try pending.set(5000, "fresh-chat", "Bob", "yo", "hey!", null, null);

    var stmt = try db.prepare("SELECT count(*) FROM reply_drafts;");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
}
