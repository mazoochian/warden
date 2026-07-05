const std = @import("std");
const Io = std.Io;

const Db = @import("db.zig").Db;
const schema = @import("schema.zig");
const messages = @import("messages.zig");

/// Owns one SQLite file per chat (`<data_dir>/<chat_id>.db`), opened lazily
/// and kept for the process lifetime. This is the literal "local to each
/// group/chat" isolation the bot was asked for, rather than one shared DB
/// scoped by a chat_id column.
pub const ChatStore = struct {
    allocator: std.mem.Allocator,
    io: Io,
    data_dir: []const u8,
    dbs: std.StringHashMap(*Db),
    /// Prune to this many most-recent messages per chat after each insert.
    retention_messages: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, data_dir: []const u8, retention_messages: i64) ChatStore {
        return .{
            .allocator = allocator,
            .io = io,
            .data_dir = data_dir,
            .dbs = std.StringHashMap(*Db).init(allocator),
            .retention_messages = retention_messages,
        };
    }

    pub fn deinit(self: *ChatStore) void {
        var it = self.dbs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.close();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.dbs.deinit();
    }

    /// Logs `msg` into `chat_id`'s db (creating it on first use) and prunes
    /// to the retention window. Errors are logged, not propagated — a
    /// storage hiccup shouldn't take down the poll loop.
    pub fn record(self: *ChatStore, chat_id: []const u8, msg: anytype, ts: i64) void {
        const db = self.get(chat_id) catch |err| {
            std.log.err("chat_store: failed to open db for chat {s}: {t}", .{ chat_id, err });
            return;
        };
        messages.insert(db, msg, ts) catch |err| {
            std.log.err("chat_store: failed to insert message for chat {s}: {t}", .{ chat_id, err });
            return;
        };
        messages.pruneKeepLast(db, self.retention_messages) catch |err| {
            std.log.err("chat_store: prune failed for chat {s}: {t}", .{ chat_id, err });
        };
    }

    pub fn get(self: *ChatStore, chat_id: []const u8) !*Db {
        if (self.dbs.get(chat_id)) |db| return db;

        try Io.Dir.cwd().createDirPath(self.io, self.data_dir);

        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}.db", .{ self.data_dir, chat_id }, 0);
        defer self.allocator.free(path);

        const db = try self.allocator.create(Db);
        errdefer self.allocator.destroy(db);
        db.* = try Db.open(path);
        errdefer db.close();
        try schema.migrate(db);

        const key = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(key);
        try self.dbs.put(key, db);
        return db;
    }

    /// Lists chat ids that already have a `.db` file on disk — used at
    /// startup to rediscover which chats had digests enabled before a
    /// restart, without needing a separate index file.
    pub fn listExistingChatIds(self: *ChatStore, allocator: std.mem.Allocator) ![][]const u8 {
        var dir = Io.Dir.cwd().openDir(self.io, self.data_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close(self.io);

        var ids: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".db")) continue;
            const chat_id = entry.name[0 .. entry.name.len - 3];
            try ids.append(allocator, try allocator.dupe(u8, chat_id));
        }
        return ids.toOwnedSlice(allocator);
    }
};

const testing = std.testing;
const stats = @import("stats.zig");
const iface = @import("../platform/interface.zig");

test "record logs messages and stats reflects them" {
    const allocator = testing.allocator;
    const io = testing.io;
    const dir = "zig-cache-test-chat-store";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = ChatStore.init(allocator, io, dir, 20_000);
    defer store.deinit();

    store.record("chat1", iface.Message{ .chat_id = "chat1", .user_id = "1", .username = "alice", .text = "hi" }, 1000);
    store.record("chat1", iface.Message{ .chat_id = "chat1", .user_id = "1", .username = "alice", .text = "again" }, 1001);
    store.record("chat1", iface.Message{ .chat_id = "chat1", .user_id = "2", .username = "bob", .text = "hello" }, 1002);
    // A separate chat must not see chat1's messages (per-chat isolation).
    store.record("chat2", iface.Message{ .chat_id = "chat2", .user_id = "3", .username = "carol", .text = "unrelated" }, 1003);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db1 = try store.get("chat1");
    const s1 = try stats.compute(db1, arena.allocator(), 5);
    try testing.expectEqual(@as(i64, 3), s1.total_messages);
    try testing.expectEqual(@as(i64, 2), s1.distinct_users);
    try testing.expectEqual(@as(i64, 2), s1.top_users[0].message_count);
    try testing.expectEqualStrings("alice", s1.top_users[0].username);

    const db2 = try store.get("chat2");
    const s2 = try stats.compute(db2, arena.allocator(), 5);
    try testing.expectEqual(@as(i64, 1), s2.total_messages);
}

test "pruneKeepLast bounds per-chat history" {
    const allocator = testing.allocator;
    const io = testing.io;
    const dir = "zig-cache-test-chat-store-prune";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = ChatStore.init(allocator, io, dir, 2);
    defer store.deinit();

    store.record("chat1", iface.Message{ .chat_id = "chat1", .user_id = "1", .text = "one" }, 1);
    store.record("chat1", iface.Message{ .chat_id = "chat1", .user_id = "1", .text = "two" }, 2);
    store.record("chat1", iface.Message{ .chat_id = "chat1", .user_id = "1", .text = "three" }, 3);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const db = try store.get("chat1");
    const s = try stats.compute(db, arena.allocator(), 5);
    try testing.expectEqual(@as(i64, 2), s.total_messages);
}

test "listExistingChatIds finds chats that already have a db file" {
    const allocator = testing.allocator;
    const io = testing.io;
    const dir = "zig-cache-test-chat-store-list";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = ChatStore.init(allocator, io, dir, 20_000);
    defer store.deinit();

    _ = try store.get("chat1");
    _ = try store.get("chat2");

    const ids = try store.listExistingChatIds(allocator);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }

    try testing.expectEqual(@as(usize, 2), ids.len);
    var saw_chat1 = false;
    var saw_chat2 = false;
    for (ids) |id| {
        if (std.mem.eql(u8, id, "chat1")) saw_chat1 = true;
        if (std.mem.eql(u8, id, "chat2")) saw_chat2 = true;
    }
    try testing.expect(saw_chat1 and saw_chat2);
}

test "listExistingChatIds returns empty when the data dir doesn't exist yet" {
    const allocator = testing.allocator;
    const io = testing.io;
    const dir = "zig-cache-test-chat-store-list-missing";
    // Deliberately not created.
    var store = ChatStore.init(allocator, io, dir, 20_000);
    defer store.deinit();

    const ids = try store.listExistingChatIds(allocator);
    try testing.expectEqual(@as(usize, 0), ids.len);
}
