//! One-time tool that migrates every pre-Postgres per-chat SQLite file
//! (`data/chats/<chat_id>.db`, plus the bot-wide `_global.db`) into the new
//! shared Postgres database. Run once, manually, during cutover:
//!
//!   zig build migrate-data
//!
//! Not part of the `warden` binary or its Docker image — this is the only
//! place SQLite-reading code survives post-cutover (see
//! `sqlite_reader.zig`'s doc comment).

const std = @import("std");
const Io = std.Io;

const sqlite = @import("migrate/sqlite_reader.zig");
const store_pool = @import("store/pool.zig");
const migrate_schema = @import("store/migrate.zig");
const chats = @import("store/chats.zig");
const identities = @import("store/identities.zig");
const chat_members = @import("store/chat_members.zig");
const chat_settings = @import("store/chat_settings.zig");
const bot_config = @import("store/bot_config.zig");
const messages = @import("store/messages.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const postgres_dsn = env.get("WARDEN_POSTGRES_DSN") orelse {
        std.log.err("WARDEN_POSTGRES_DSN must be set", .{});
        return error.MissingPostgresDsn;
    };
    const data_dir = env.get("WARDEN_DATA_DIR") orelse "data/chats";

    var pool = try store_pool.PgPool.init(gpa, io, postgres_dsn, 4, 30 * std.time.ns_per_s, 30);
    defer pool.deinit();
    {
        const db = try pool.acquire();
        defer pool.release(db);
        try migrate_schema.migrate(db, gpa);
    }

    var dir = Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch |err| {
        std.log.err("could not open data dir '{s}': {t}", .{ data_dir, err });
        return err;
    };
    defer dir.close(io);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".db")) continue;
        const stem = entry.name[0 .. entry.name.len - 3];

        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ data_dir, entry.name }, 0);

        if (std.mem.eql(u8, stem, "_global")) {
            migrateGlobal(a, &pool, path) catch |err| {
                std.log.err("failed to migrate {s}: {t}", .{ path, err });
            };
        } else {
            migrateChat(a, &pool, stem, path) catch |err| {
                std.log.err("failed to migrate {s}: {t}", .{ path, err });
            };
        }
    }

    std.log.info("migration complete", .{});
}

/// `_global.db`'s `chat_settings` KV rows (scraper_mode/remote_url/api_key)
/// map directly onto `bot_config` — same key names, just a real table
/// instead of a reserved fake-chat-id workaround.
fn migrateGlobal(a: std.mem.Allocator, pool: *store_pool.PgPool, path: [:0]const u8) !void {
    var db = try sqlite.Db.open(path);
    defer db.close();

    var stmt = try db.prepare("SELECT key, value FROM chat_settings;");
    defer stmt.finalize();

    var migrated: usize = 0;
    while (try stmt.step()) {
        const key = try a.dupe(u8, stmt.columnText(0));
        const value = stmt.columnText(1);
        // Empty string was the old "unset" convention; a real bot_config
        // row simply shouldn't exist for that key.
        if (value.len == 0) continue;
        try bot_config.setText(pool, key, value);
        migrated += 1;
    }
    std.log.info("migrated {d} bot_config row(s) from {s}", .{ migrated, path });
}

fn migrateChat(a: std.mem.Allocator, pool: *store_pool.PgPool, native_chat_id: []const u8, path: [:0]const u8) !void {
    var db = try sqlite.Db.open(path);
    defer db.close();

    // Old schema had no chat_type/title — those backfill naturally the
    // next time this chat gets a live message post-cutover.
    const chat_id = try chats.upsertChat(pool, .telegram, native_chat_id, null, null);

    var identity_by_user_id = std.StringHashMap(i64).init(a);

    // `users`: one row per person ever seen in this chat (per-chat scoped in
    // the old schema) — becomes an `identities` row (global) plus a
    // `chat_members` row (this chat's tokens/last_seen).
    {
        var stmt = try db.prepare("SELECT user_id, username, last_seen, tokens FROM users;");
        defer stmt.finalize();

        var count: usize = 0;
        while (try stmt.step()) {
            const user_id = try a.dupe(u8, stmt.columnText(0));
            const username = stmt.columnText(1);
            const last_seen = stmt.columnInt64(2);

            const identity_id = try identities.upsertIdentity(pool, .{
                .platform = .telegram,
                .native_id = user_id,
                // Old schema only ever stored a username, never a separate
                // display name — fall back to the id itself when even that
                // is missing, same convention `messages.recentFormatted`
                // already uses for "who said this."
                .display_name = if (username.len > 0) username else user_id,
                .username = if (username.len > 0) username else null,
                .is_bot = std.mem.eql(u8, user_id, "warden"),
                .first_seen = last_seen,
                .last_seen = last_seen,
            });
            try identity_by_user_id.put(user_id, identity_id);

            try chat_members.touch(pool, chat_id, identity_id, last_seen);
            if (!stmt.columnIsNull(3)) {
                try chat_members.setTokens(pool, chat_id, identity_id, stmt.columnInt64(3));
            }
            count += 1;
        }
        std.log.info("chat {s}: migrated {d} user(s)", .{ native_chat_id, count });
    }

    // `messages`: resolve each row's sender through the map built above,
    // falling back to an on-the-fly minimal identity for the rare case of a
    // message whose sender never got a `users` row (shouldn't happen given
    // the old insert path always upserted both together, but cheap to
    // handle defensively rather than dropping the message).
    {
        var stmt = try db.prepare("SELECT user_id, username, text, ts FROM messages ORDER BY id ASC;");
        defer stmt.finalize();

        var count: usize = 0;
        while (try stmt.step()) {
            const user_id = stmt.columnText(0);
            const username = stmt.columnText(1);
            const text: ?[]const u8 = if (stmt.columnIsNull(2)) null else stmt.columnText(2);
            const ts = stmt.columnInt64(3);

            const identity_id = identity_by_user_id.get(user_id) orelse blk: {
                const id = try identities.getOrCreateMinimal(pool, .telegram, user_id, if (username.len > 0) username else user_id, std.mem.eql(u8, user_id, "warden"), ts);
                try identity_by_user_id.put(try a.dupe(u8, user_id), id);
                break :blk id;
            };

            try messages.insert(pool, chat_id, identity_id, null, text, ts);
            count += 1;
        }
        std.log.info("chat {s}: migrated {d} message(s)", .{ native_chat_id, count });
    }

    // `chat_settings`: typed columns now instead of a KV table.
    {
        var stmt = try db.prepare("SELECT key, value FROM chat_settings;");
        defer stmt.finalize();

        while (try stmt.step()) {
            const key = stmt.columnText(0);
            const value = stmt.columnText(1);
            if (std.mem.eql(u8, key, "digest_enabled")) {
                try chat_settings.setDigestEnabled(pool, chat_id, std.mem.eql(u8, value, "1"));
            } else if (std.mem.eql(u8, key, "last_digest_ts")) {
                const ts = std.fmt.parseInt(i64, value, 10) catch continue;
                try chat_settings.setLastDigestTs(pool, chat_id, ts);
            } else if (std.mem.eql(u8, key, "magic_word")) {
                if (value.len > 0) try chat_settings.setMagicWord(pool, chat_id, value);
            }
        }
    }
}
