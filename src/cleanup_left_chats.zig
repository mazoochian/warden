//! Retroactive reconciliation tool: scans every currently-active Telegram
//! chat in the database and asks Telegram directly whether the bot is
//! still a member. Unlike the ongoing automatic housekeeping in
//! `main.zig`/`store/chats.zig` (which only catches a chat departure from
//! the moment `chat_left` support shipped onward, via each connector's own
//! live event stream), this is a one-off pass for chats that already went
//! stale *before* that tracking existed — see `store/migrations/
//! 0022_chats_left_at.sql`.
//!
//! Only checks Telegram chats: the only connector actually live in
//! production today. A Matrix/XMPP chat (if any exist) is left untouched,
//! since there's no equivalent live "am I still in this room" check wired
//! up for those yet.
//!
//! Defaults to a dry run (lists what it WOULD delete, deletes nothing) —
//! pass `--apply` to actually delete. Deletion is immediate (bypasses the
//! usual `markLeft` + 30-day grace period): these chats are already
//! confirmed gone by a live API check, not freshly-departed, so there's no
//! reason to wait.
//!
//! Run:
//!   zig build cleanup-left-chats                -- dry run
//!   zig build cleanup-left-chats -- --apply      -- actually deletes
//!
//! Needs WARDEN_POSTGRES_DSN and WARDEN_TELEGRAM_BOT_TOKEN in the
//! environment, same as the main bot.

const std = @import("std");
const Io = std.Io;

const store_pool = @import("store/pool.zig");
const chats = @import("store/chats.zig");
const raw = @import("telegram/client.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const postgres_dsn = env.get("WARDEN_POSTGRES_DSN") orelse {
        std.log.err("WARDEN_POSTGRES_DSN must be set", .{});
        return error.MissingPostgresDsn;
    };
    const bot_token = env.get("WARDEN_TELEGRAM_BOT_TOKEN") orelse {
        std.log.err("WARDEN_TELEGRAM_BOT_TOKEN must be set", .{});
        return error.MissingBotToken;
    };

    var apply = false;
    {
        var it = init.minimal.args.iterate();
        _ = it.next(); // argv[0]
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--apply")) apply = true;
        }
    }
    std.log.info("mode: {s}", .{if (apply) "APPLY (will delete)" else "dry run (nothing will be deleted, pass --apply to actually delete)"});

    var pool = try store_pool.PgPool.init(gpa, io, postgres_dsn, 4, 30 * std.time.ns_per_s, 30);
    defer pool.deinit();

    var client = raw.Client.init(gpa, io, bot_token);
    defer client.deinit();

    var me = try client.getMe(gpa);
    defer me.deinit();
    const self_id = (me.value.result orelse return error.CouldNotResolveSelf).id;
    std.log.info("checking chats as bot id {d}", .{self_id});

    const refs = try chats.listAll(&pool, gpa);
    defer {
        for (refs) |r| gpa.free(r.native_chat_id);
        gpa.free(refs);
    }

    var checked: usize = 0;
    var gone: usize = 0;
    var deleted: usize = 0;
    var unknown: usize = 0;
    var skipped_non_telegram: usize = 0;

    for (refs) |r| {
        if (r.platform != .telegram) {
            skipped_non_telegram += 1;
            continue;
        }
        const native_id = std.fmt.parseInt(i64, r.native_chat_id, 10) catch {
            std.log.warn("chat {d}: native id '{s}' isn't a valid Telegram chat id, skipping", .{ r.id, r.native_chat_id });
            continue;
        };
        checked += 1;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const membership = client.checkMembership(arena.allocator(), native_id, self_id) catch |err| {
            std.log.warn("chat {d} ({s}): membership check errored, leaving alone: {t}", .{ r.id, r.native_chat_id, err });
            unknown += 1;
            continue;
        };

        switch (membership) {
            .member => {},
            .unknown => unknown += 1,
            .gone => {
                gone += 1;
                if (apply) {
                    chats.deleteById(&pool, r.id) catch |err| {
                        std.log.err("chat {d} ({s}): failed to delete: {t}", .{ r.id, r.native_chat_id, err });
                        continue;
                    };
                    deleted += 1;
                    std.log.info("chat {d} ({s}): bot no longer a member -- deleted", .{ r.id, r.native_chat_id });
                } else {
                    std.log.info("chat {d} ({s}): bot no longer a member -- would delete (dry run)", .{ r.id, r.native_chat_id });
                }
            },
        }

        // Telegram's per-bot rate limit is generous but not infinite -- a
        // small delay keeps a large chat list from tripping it.
        Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }

    std.log.info(
        "done: {d} telegram chat(s) checked -- {d} still active, {d} gone ({d} deleted), {d} unknown/errored (left alone), {d} non-telegram chat(s) skipped",
        .{ checked, checked - gone - unknown, gone, deleted, unknown, skipped_non_telegram },
    );
    if (!apply and gone > 0) {
        std.log.info("re-run with --apply to actually delete the {d} chat(s) listed above", .{gone});
    }
}
