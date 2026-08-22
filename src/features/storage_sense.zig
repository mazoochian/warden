//! Warden's own disk-usage awareness, built after a real outage: the VPS's
//! disk filled to 100% (an unrotated Docker log plus general growth),
//! Postgres PANIC crash-looped, and every DB write silently failed for
//! ~3 hours until someone noticed and restarted the container by hand. This
//! module gives the bot an Elasticsearch-watermark-style ladder over its own
//! disk: monitor -> alert -> prune/resample -> sleep, plus the reusable
//! cleanup actions each ladder rung (and the manual `/storage cleanup`
//! command in `main.zig`) calls into.
//!
//! Deliberately free of any `main.zig`/Telegram-specific dependency (same
//! "pure function over pool/io/config" shape `video_download.zig` uses) --
//! `tick`'s caller passes the owner's already-resolved native id and a
//! connector to notify through, rather than this module reaching for
//! `main.zig`'s `ownerTelegramNativeId` itself.
//!
//! Two independent gates control how much of this actually runs:
//!   - `feature_flags.isEnabled(pool, "storage_sense_monitor")` (fails open,
//!     like every other module) -- gates only `tick`'s periodic disk check
//!     and alerting. The manual `/storage` command surface always works
//!     regardless, so the owner can debug even with monitoring off.
//!   - `WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED`, a `dynamic_config` bool
//!     (fails *closed* to its default, unlike a feature flag) -- gates the
//!     ladder's destructive actions (prune, resample) and sleep mode. This
//!     has to be `dynamic_config`, not another `feature_flags` entry:
//!     `feature_flags.isEnabled`'s whole point is "no row means enabled" (see
//!     `0019_feature_flags.sql`'s own comment on why -- a test's
//!     `TRUNCATE ... CASCADE` would otherwise silently and permanently erase
//!     a seeded "off" row), which is exactly backwards for a switch that
//!     must default off until the owner has watched `/storage status` for a
//!     while and turns it on deliberately.
const std = @import("std");
const Io = std.Io;

const llm = @import("../llm/provider.zig");
const digest = @import("digest.zig");
const registry = @import("../tools/registry.zig");
const iface = @import("../platform/interface.zig");
const config_mod = @import("../config.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const messages = @import("../store/messages.zig");
const chats = @import("../store/chats.zig");
const identities = @import("../store/identities.zig");
const dynamic_config = @import("../store/dynamic_config.zig");

pub const low_watermark_key = "WARDEN_STORAGE_SENSE_LOW_WATERMARK_PCT";
pub const high_watermark_key = "WARDEN_STORAGE_SENSE_HIGH_WATERMARK_PCT";
pub const flood_watermark_key = "WARDEN_STORAGE_SENSE_FLOOD_WATERMARK_PCT";
pub const resume_margin_key = "WARDEN_STORAGE_SENSE_RESUME_MARGIN_PCT";
pub const prune_age_days_key = "WARDEN_STORAGE_SENSE_PRUNE_AGE_DAYS";
pub const resample_batch_size_key = "WARDEN_STORAGE_SENSE_RESAMPLE_BATCH_SIZE";
pub const autopilot_enabled_key = "WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED";

/// Runtime bookkeeping, not an owner tunable -- deliberately left out of
/// `dynamic_config.known_keys` (see that file's own comment on these three).
const last_high_alert_ts_key = "WARDEN_STORAGE_SENSE_LAST_HIGH_ALERT_TS";
const sleep_active_key = "WARDEN_STORAGE_SENSE_SLEEP_ACTIVE";
const sleep_entered_ts_key = "WARDEN_STORAGE_SENSE_SLEEP_ENTERED_TS";
const last_tmp_sweep_ts_key = "WARDEN_STORAGE_SENSE_LAST_TMP_SWEEP_TS";

/// How long between daily high-watermark owner alerts.
const high_alert_interval_seconds: i64 = 24 * 60 * 60;
/// How often the unconditional tmp sweep actually runs -- every tick would
/// be wasted directory-listing work for scratch space that only grows slowly.
const tmp_sweep_interval_seconds: i64 = 6 * 60 * 60;
/// Files under `tmp_dir` older than this are considered abandoned rather
/// than mid-use -- generous headroom over the longest legitimate operation
/// this codebase runs against it (video_download.zig's 600s download / 300s
/// compress timeouts), so a sweep can never delete a file a concurrent
/// convert/download is still writing. `pub` since `main.zig`'s
/// `/storage cleanup tmp` reuses the same threshold for its on-demand sweep
/// rather than deleting everything unconditionally.
pub const tmp_sweep_max_age_seconds: i64 = 24 * 60 * 60;
/// Below this, `resampleOldMessages` skips a chat rather than spending a
/// real LLM call compacting a handful of leftover rows -- not worth the
/// cost for negligible disk savings. A manual `/storage cleanup resample`
/// on a chat with fewer old messages than this is genuinely a no-op; prune
/// is the right tool for a chat that small.
const min_batch_for_resample: usize = 20;

pub const DiskUsage = struct {
    used_pct: f64,
    total_bytes: u64,
    available_bytes: u64,
};

/// Runs `df -kP path` and parses its one data row. `-P` (POSIX output
/// format) is what makes this portable: confirmed live against both GNU
/// coreutils (the dev box) and busybox (the production Alpine container,
/// `alpine:3.22`) -- both print the identical
/// "Filesystem 1024-blocks Used Available Capacity Mounted on" header and a
/// single-line data row, unlike GNU's default (non-`-P`) format, which wraps
/// onto a second line for a long filesystem name. Zig 0.16's std has no
/// `statvfs`/`statfs` wrapper, and hand-rolling the raw syscall struct risks
/// a musl-vs-glibc ABI mismatch -- shelling out is the same tradeoff
/// `video_download.zig` already makes for `yt-dlp`/`ffmpeg`.
pub fn checkDiskUsage(allocator: std.mem.Allocator, io: Io, path: []const u8) !DiskUsage {
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(df_timeout_seconds), .clock = .awake });
    const result = std.process.run(allocator, io, .{ .argv = &.{ "df", "-kP", path }, .timeout = .{ .deadline = deadline } }) catch |err| {
        std.log.warn("storage_sense: df failed to run for {s}: {t}", .{ path, err });
        return error.DfFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.warn("storage_sense: df exited nonzero for {s}: {s}", .{ path, result.stderr });
        return error.DfFailed;
    }
    return parseDfOutput(result.stdout);
}

/// `df` is local and CPU-only -- should return almost instantly; generous
/// slack, not a real expected duration (same reasoning `video_download.zig`
/// gives `ffprobe_timeout_seconds`).
const df_timeout_seconds: i64 = 10;

/// Local since only `checkDiskUsage` and this file's own tests need it.
/// Skips the header line, then reads the first (and only, under `-P`) data
/// line: filesystem, 1024-blocks (total), used, available, capacity%,
/// mounted-on -- tokenized by whitespace rather than assuming fixed column
/// widths, since the filesystem name's length varies ("overlay" vs.
/// "/dev/nvme0n1p7").
fn parseDfOutput(output: []const u8) !DiskUsage {
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next() orelse return error.DfParseFailed; // header
    const data_line = lines.next() orelse return error.DfParseFailed;

    var fields = std.mem.tokenizeAny(u8, data_line, " \t");
    _ = fields.next() orelse return error.DfParseFailed; // filesystem
    const total_kb = std.fmt.parseInt(u64, fields.next() orelse return error.DfParseFailed, 10) catch return error.DfParseFailed;
    const used_kb = std.fmt.parseInt(u64, fields.next() orelse return error.DfParseFailed, 10) catch return error.DfParseFailed;
    const available_kb = std.fmt.parseInt(u64, fields.next() orelse return error.DfParseFailed, 10) catch return error.DfParseFailed;
    if (total_kb == 0) return error.DfParseFailed;

    return .{
        .used_pct = @as(f64, @floatFromInt(used_kb)) * 100.0 / @as(f64, @floatFromInt(total_kb)),
        .total_bytes = total_kb * 1024,
        .available_bytes = available_kb * 1024,
    };
}

pub const Watermark = enum { normal, low, high, flood };

/// Pure classification, no IO -- the most bug-prone part of the ladder, so
/// kept trivially unit-testable on its own. `>=` at every boundary: hitting
/// a watermark exactly counts as having reached it, not "still normal".
pub fn classify(used_pct: f64, low_pct: i64, high_pct: i64, flood_pct: i64) Watermark {
    if (used_pct >= @as(f64, @floatFromInt(flood_pct))) return .flood;
    if (used_pct >= @as(f64, @floatFromInt(high_pct))) return .high;
    if (used_pct >= @as(f64, @floatFromInt(low_pct))) return .low;
    return .normal;
}

pub const PruneResult = struct { chats_affected: usize = 0, rows_deleted: i64 = 0 };

/// Deletes messages older than `cutoff_ts` in `chat_id`, or across every
/// known chat when `chat_id` is `null` (the ladder's own "across chats,
/// bounded per tick" use, as opposed to `/storage cleanup messages
/// [chat_id]`'s single-chat default). Errors from one chat are logged and
/// skipped rather than aborting the whole sweep -- same "don't let one bad
/// chat starve every other one" reasoning `feed_watcher.zig`'s per-feed loop
/// already follows.
pub fn pruneOldMessages(pool: *PgPool, allocator: std.mem.Allocator, chat_id: ?i64, cutoff_ts: i64) !PruneResult {
    if (chat_id) |id| {
        const deleted = try messages.deleteOlderThan(pool, id, cutoff_ts);
        return .{ .chats_affected = if (deleted > 0) 1 else 0, .rows_deleted = deleted };
    }

    const refs = try chats.listAll(pool, allocator);
    defer {
        for (refs) |r| allocator.free(r.native_chat_id);
        allocator.free(refs);
    }

    var result: PruneResult = .{};
    for (refs) |ref| {
        const deleted = messages.deleteOlderThan(pool, ref.id, cutoff_ts) catch |err| {
            std.log.warn("storage_sense: prune failed for chat {d}: {t}", .{ ref.id, err });
            continue;
        };
        if (deleted > 0) result.chats_affected += 1;
        result.rows_deleted += deleted;
    }
    return result;
}

pub const ResampleResult = struct { chats_affected: usize = 0, messages_compacted: i64 = 0 };

/// Platform-agnostic identity `resampleOldMessages` attributes every
/// synthetic summary row to -- deliberately not the real owner's identity
/// (which would misattribute LLM-written prose as something the owner
/// actually said in the chat) and not `null` (every message row needs a
/// valid `identity_id` FK). The native id can never collide with a real
/// platform user id (Telegram/Matrix/XMPP ids are all numeric or
/// `@user:server`-shaped).
const system_identity_native_id = "warden_storage_sense";

/// Compacts the oldest batch of `chat_id`'s non-summary messages into one
/// LLM-written summary via `digest.summarizeHistory` (reused as-is, no new
/// LLM-calling code), deleting the batch and inserting the summary in one
/// transaction (`messages.replaceRangeWithSummary`) so a message arriving
/// mid-call is never lost. Returns `0` (not an error) for a chat with
/// nothing left to compact, or fewer than `min_batch_for_resample` messages.
fn resampleOneChat(pool: *PgPool, allocator: std.mem.Allocator, io: Io, llm_provider: llm.Provider, chat_id: i64, batch_size: i64, system_identity_id: i64) !i64 {
    const batch = try messages.oldestBatchForSummary(pool, allocator, chat_id, batch_size) orelse return 0;
    if (batch.count < min_batch_for_resample) return 0;

    const ctx = registry.ToolContext{ .allocator = allocator, .io = io };
    const summary = digest.summarizeHistory(llm_provider, allocator, ctx, batch.text);
    if (summary.len == 0) return error.SummaryFailed;

    try messages.replaceRangeWithSummary(pool, chat_id, system_identity_id, batch.min_id, batch.max_id, summary, batch.newest_ts);
    return @intCast(batch.count);
}

/// See `resampleOneChat` for the per-chat mechanics; `chat_id = null` runs
/// it across every known chat (the ladder's use), same null-means-every-chat
/// convention `pruneOldMessages` uses.
pub fn resampleOldMessages(pool: *PgPool, allocator: std.mem.Allocator, io: Io, llm_provider: llm.Provider, chat_id: ?i64, batch_size: i64) !ResampleResult {
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const system_identity_id = try identities.getOrCreateMinimal(pool, .telegram, system_identity_native_id, "Warden", null, true, now);

    if (chat_id) |id| {
        const compacted = try resampleOneChat(pool, allocator, io, llm_provider, id, batch_size, system_identity_id);
        return .{ .chats_affected = if (compacted > 0) 1 else 0, .messages_compacted = compacted };
    }

    const refs = try chats.listAll(pool, allocator);
    defer {
        for (refs) |r| allocator.free(r.native_chat_id);
        allocator.free(refs);
    }

    var result: ResampleResult = .{};
    for (refs) |ref| {
        const compacted = resampleOneChat(pool, allocator, io, llm_provider, ref.id, batch_size, system_identity_id) catch |err| {
            std.log.warn("storage_sense: resample failed for chat {d}: {t}", .{ ref.id, err });
            continue;
        };
        if (compacted > 0) result.chats_affected += 1;
        result.messages_compacted += compacted;
    }
    return result;
}

pub const SweepResult = struct { files_deleted: usize = 0, bytes_freed: u64 = 0 };

/// Deletes every file directly under `tmp_dir` whose mtime is older than
/// `older_than_seconds` -- addresses the leftover scratch files real
/// deployments accumulate from `/convert`/video downloads that didn't clean
/// up after themselves. Runs unconditionally (independent of autopilot,
/// watermark, or anything else): this is disposable scratch space, not real
/// data, so there's no destructive-action gate to respect. A missing
/// `tmp_dir` is a normal "nothing to sweep yet" case, not an error.
pub fn sweepTmpDir(io: Io, allocator: std.mem.Allocator, tmp_dir: []const u8, older_than_seconds: i64) !SweepResult {
    var dir = Io.Dir.cwd().openDir(io, tmp_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer dir.close(io);

    const now = Io.Timestamp.now(io, .real).toSeconds();
    var result: SweepResult = .{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (now - stat.mtime.toSeconds() < older_than_seconds) continue;
        dir.deleteFile(io, entry.name) catch |err| {
            std.log.warn("storage_sense: couldn't delete stale tmp file '{s}': {t}", .{ entry.name, err });
            continue;
        };
        result.files_deleted += 1;
        result.bytes_freed += stat.size;
    }
    _ = allocator;
    return result;
}

pub fn isSleepModeActive(pool: *PgPool, allocator: std.mem.Allocator) bool {
    return dynamic_config.getBool(pool, allocator, sleep_active_key, false);
}

/// Which chats have already gotten the "paused for storage maintenance"
/// notice this sleep episode, so `main.zig`'s sleep-mode gate sends it once
/// per chat rather than on every incoming message while asleep. Process-
/// global, `page_allocator`-backed -- same idiom `video_download.zig`'s
/// `compression_mutex` uses for its own cross-thread state, and there's
/// only ever one of these (unlike per-request data) so a plain global is the
/// natural shape. `Io.Mutex`, not `std.Thread.Mutex` -- this Zig version has
/// no such type; synchronization moved into `Io` itself (see
/// `video_download.zig`'s `compression_mutex` doc comment for the same note).
var sleep_notified_chats: std.StringHashMapUnmanaged(void) = .empty;
var sleep_notified_mutex: Io.Mutex = .init;

/// `true` the first time this is called for `native_chat_id` since the last
/// `resetSleepNotifications` (sleep entered or exited); `false` on every
/// later call for the same chat until then.
pub fn shouldNotifySleepOnce(io: Io, native_chat_id: []const u8) bool {
    sleep_notified_mutex.lockUncancelable(io);
    defer sleep_notified_mutex.unlock(io);
    if (sleep_notified_chats.contains(native_chat_id)) return false;
    const owned = std.heap.page_allocator.dupe(u8, native_chat_id) catch return true;
    sleep_notified_chats.put(std.heap.page_allocator, owned, {}) catch {
        std.heap.page_allocator.free(owned);
        return true;
    };
    return true;
}

fn resetSleepNotifications(io: Io) void {
    sleep_notified_mutex.lockUncancelable(io);
    defer sleep_notified_mutex.unlock(io);
    var it = sleep_notified_chats.keyIterator();
    while (it.next()) |k| std.heap.page_allocator.free(k.*);
    sleep_notified_chats.clearAndFree(std.heap.page_allocator);
}

/// The full ladder, called once per ~30s scheduler tick from `main.zig`'s
/// main loop -- gated overall by
/// `feature_flags.isEnabled(pool, "storage_sense_monitor")` (checked by the
/// caller, not here, same "caller owns the feature-flag check" convention
/// every other `checkAndSendDueX` function in `main.zig` already follows).
///
/// `owner_identity_id` is whoever `dynamic_config.set`'s automated writes
/// below (sleep flag, last-alert timestamp, tmp-sweep cursor) get attributed
/// to -- resolved by the caller via the same `resolveOwnerIdentityId`
/// `main.zig` already uses for other owner-attributed writes (e.g.
/// `/autonomy`), not re-derived here.
pub fn tick(
    gpa: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    pool: *PgPool,
    llm_provider: llm.Provider,
    owner_notify: iface.Connector,
    owner_native_id: []const u8,
    owner_identity_id: i64,
    now: i64,
) void {
    const usage = checkDiskUsage(gpa, io, config.tmp_dir) catch |err| {
        std.log.warn("storage_sense: couldn't read disk usage for {s}: {t}", .{ config.tmp_dir, err });
        return;
    };

    const low = dynamic_config.getI64(pool, gpa, low_watermark_key, config.storage_sense_low_watermark_pct);
    const high = dynamic_config.getI64(pool, gpa, high_watermark_key, config.storage_sense_high_watermark_pct);
    const flood = dynamic_config.getI64(pool, gpa, flood_watermark_key, config.storage_sense_flood_watermark_pct);
    const resume_margin = dynamic_config.getI64(pool, gpa, resume_margin_key, config.storage_sense_resume_margin_pct);
    const watermark = classify(usage.used_pct, low, high, flood);

    // Unconditional tmp sweep, on its own longer cadence -- independent of
    // watermark/autopilot, since this is disposable scratch space.
    const last_sweep = dynamic_config.getI64(pool, gpa, last_tmp_sweep_ts_key, 0);
    if (now - last_sweep >= tmp_sweep_interval_seconds) {
        const swept = sweepTmpDir(io, gpa, config.tmp_dir, tmp_sweep_max_age_seconds) catch |err| blk: {
            std.log.warn("storage_sense: tmp sweep failed: {t}", .{err});
            break :blk SweepResult{};
        };
        if (swept.files_deleted > 0) {
            std.log.info("storage_sense: swept {d} stale tmp files ({d} bytes)", .{ swept.files_deleted, swept.bytes_freed });
        }
        setInt(pool, last_tmp_sweep_ts_key, now, owner_identity_id);
    }

    // Sleep-mode recovery -- always checked, never gated by autopilot.
    // Recovery must not depend on autopilot still being on, or turning
    // autopilot off mid-sleep would strand the bot asleep with no way out
    // but SSH.
    const sleeping = dynamic_config.getBool(pool, gpa, sleep_active_key, false);
    if (sleeping and usage.used_pct < @as(f64, @floatFromInt(flood - resume_margin))) {
        dynamic_config.set(pool, sleep_active_key, "false", owner_identity_id) catch |err| {
            std.log.err("storage_sense: failed to clear sleep_active: {t}", .{err});
        };
        resetSleepNotifications(io);
        owner_notify.sendMessage(gpa, owner_native_id, "Storage has recovered — Warden is back to normal operation.", null);
    }

    // Daily high-watermark alert -- also always checked, monitoring rather
    // than a destructive action.
    if ((watermark == .high or watermark == .flood) and now - dynamic_config.getI64(pool, gpa, last_high_alert_ts_key, 0) >= high_alert_interval_seconds) {
        const text = std.fmt.allocPrint(gpa, "Disk usage is at {d:.1}% ({t} watermark). Run /storage status for details.", .{ usage.used_pct, watermark }) catch null;
        if (text) |t| {
            owner_notify.sendMessage(gpa, owner_native_id, t, null);
            gpa.free(t);
        }
        setInt(pool, last_high_alert_ts_key, now, owner_identity_id);
    }

    if (!dynamic_config.getBool(pool, gpa, autopilot_enabled_key, config.storage_sense_autopilot_enabled)) return;

    if (watermark == .low or watermark == .high or watermark == .flood) {
        const prune_age_days = dynamic_config.getI64(pool, gpa, prune_age_days_key, config.storage_sense_prune_age_days);
        const prune_result = pruneOldMessages(pool, gpa, null, now - prune_age_days * 86400) catch |err| blk: {
            std.log.warn("storage_sense: ladder prune failed: {t}", .{err});
            break :blk PruneResult{};
        };
        if (prune_result.rows_deleted > 0) {
            std.log.info("storage_sense: ladder pruned {d} messages across {d} chats", .{ prune_result.rows_deleted, prune_result.chats_affected });
        }

        const batch_size = dynamic_config.getI64(pool, gpa, resample_batch_size_key, config.storage_sense_resample_batch_size);
        const resample_result = resampleOldMessages(pool, gpa, io, llm_provider, null, batch_size) catch |err| blk: {
            std.log.warn("storage_sense: ladder resample failed: {t}", .{err});
            break :blk ResampleResult{};
        };
        if (resample_result.messages_compacted > 0) {
            std.log.info("storage_sense: ladder resampled {d} messages across {d} chats", .{ resample_result.messages_compacted, resample_result.chats_affected });
        }
    }

    if (watermark == .flood and !sleeping) {
        dynamic_config.set(pool, sleep_active_key, "true", owner_identity_id) catch |err| {
            std.log.err("storage_sense: failed to set sleep_active: {t}", .{err});
        };
        setInt(pool, sleep_entered_ts_key, now, owner_identity_id);
        resetSleepNotifications(io);
        owner_notify.sendMessage(gpa, owner_native_id, "Disk usage has hit the flood watermark — Warden is entering sleep mode until storage recovers. /storage status or /storage autopilot off still work.", null);
    }
}

/// `dynamic_config.set` only takes text values -- this is the small
/// int-to-string dance every integer write in `tick` needs, factored out
/// once rather than repeated at each call site.
fn setInt(pool: *PgPool, key: []const u8, value: i64, updated_by: i64) void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    dynamic_config.set(pool, key, text, updated_by) catch |err| {
        std.log.err("storage_sense: failed to write {s}: {t}", .{ key, err });
    };
}

/// `/storage status`'s reply body — disk %, watermark tier, autopilot
/// on/off, sleep state, time since the last high-watermark alert.
pub fn buildStatusReport(allocator: std.mem.Allocator, io: Io, config: *const config_mod.Config, pool: *PgPool) ![]const u8 {
    const usage = checkDiskUsage(allocator, io, config.tmp_dir) catch |err| {
        return std.fmt.allocPrint(allocator, "Couldn't read disk usage for {s}: {t}", .{ config.tmp_dir, err });
    };
    const low = dynamic_config.getI64(pool, allocator, low_watermark_key, config.storage_sense_low_watermark_pct);
    const high = dynamic_config.getI64(pool, allocator, high_watermark_key, config.storage_sense_high_watermark_pct);
    const flood = dynamic_config.getI64(pool, allocator, flood_watermark_key, config.storage_sense_flood_watermark_pct);
    const watermark = classify(usage.used_pct, low, high, flood);
    const autopilot = dynamic_config.getBool(pool, allocator, autopilot_enabled_key, config.storage_sense_autopilot_enabled);
    const sleeping = isSleepModeActive(pool, allocator);

    const now = Io.Timestamp.now(io, .real).toSeconds();
    const last_alert = dynamic_config.getI64(pool, allocator, last_high_alert_ts_key, 0);
    const last_alert_desc = if (last_alert == 0)
        try allocator.dupe(u8, "never")
    else
        try std.fmt.allocPrint(allocator, "{d}h ago", .{@divTrunc(now - last_alert, 3600)});

    return std.fmt.allocPrint(
        allocator,
        "Disk: {d:.1}% used ({t} watermark, thresholds {d}/{d}/{d})\n" ++
            "Available: {d:.1} GB / {d:.1} GB total\n" ++
            "Autopilot: {s}\n" ++
            "Sleep mode: {s}\n" ++
            "Last high-watermark alert: {s}",
        .{
            usage.used_pct,
            watermark,
            low,
            high,
            flood,
            @as(f64, @floatFromInt(usage.available_bytes)) / (1024.0 * 1024.0 * 1024.0),
            @as(f64, @floatFromInt(usage.total_bytes)) / (1024.0 * 1024.0 * 1024.0),
            if (autopilot) "on" else "off",
            if (sleeping) "active" else "inactive",
            last_alert_desc,
        },
    );
}

const testing = std.testing;

test "parseDfOutput reads GNU coreutils -P output" {
    const output =
        \\Filesystem     1024-blocks      Used Available Capacity Mounted on
        \\/dev/nvme0n1p7   421864448 388145164  25418388      94% /home
        \\
    ;
    const usage = try parseDfOutput(output);
    try testing.expectEqual(@as(u64, 421864448 * 1024), usage.total_bytes);
    try testing.expectEqual(@as(u64, 25418388 * 1024), usage.available_bytes);
    // 388145164 / 421864448 * 100 -- computed, not `df`'s own rounded "94%"
    // column (which this parser deliberately ignores in favor of computing
    // its own float from the raw block counts).
    try testing.expect(usage.used_pct > 92.0 and usage.used_pct < 92.1);
}

test "parseDfOutput reads busybox -P output (production container shape)" {
    const output =
        \\Filesystem           1024-blocks    Used Available Capacity Mounted on
        \\overlay              421864448 388165188  25399356  94% /
        \\
    ;
    const usage = try parseDfOutput(output);
    try testing.expectEqual(@as(u64, 421864448 * 1024), usage.total_bytes);
    try testing.expectEqual(@as(u64, 25399356 * 1024), usage.available_bytes);
    // 388165188 / 421864448 * 100 -- same reasoning as the GNU test above.
    try testing.expect(usage.used_pct > 92.0 and usage.used_pct < 92.1);
}

test "parseDfOutput fails closed on garbage input" {
    try testing.expectError(error.DfParseFailed, parseDfOutput(""));
    try testing.expectError(error.DfParseFailed, parseDfOutput("Filesystem 1024-blocks Used Available Capacity Mounted on\n"));
    try testing.expectError(error.DfParseFailed, parseDfOutput("Filesystem 1024-blocks Used Available Capacity Mounted on\nnot enough fields\n"));
}

test "classify picks the right tier at and around each boundary" {
    try testing.expectEqual(Watermark.normal, classify(79.9, 80, 90, 95));
    try testing.expectEqual(Watermark.low, classify(80.0, 80, 90, 95));
    try testing.expectEqual(Watermark.low, classify(89.9, 80, 90, 95));
    try testing.expectEqual(Watermark.high, classify(90.0, 80, 90, 95));
    try testing.expectEqual(Watermark.high, classify(94.9, 80, 90, 95));
    try testing.expectEqual(Watermark.flood, classify(95.0, 80, 90, 95));
    try testing.expectEqual(Watermark.flood, classify(100.0, 80, 90, 95));
}

test "classify with custom thresholds" {
    try testing.expectEqual(Watermark.normal, classify(50.0, 60, 75, 85));
    try testing.expectEqual(Watermark.flood, classify(85.0, 60, 75, 85));
}

test "shouldNotifySleepOnce fires once per chat until reset" {
    // Runs against the shared process-global map -- pick chat ids unlikely
    // to collide with any other test in this file (there are none today,
    // but future-proofing this the same way `video_download.zig`'s tests
    // namespace their tmp filenames with a nanosecond timestamp).
    const chat_a = "storage_sense_test_chat_a";
    const chat_b = "storage_sense_test_chat_b";
    const io = testing.io;
    defer resetSleepNotifications(io);

    try testing.expect(shouldNotifySleepOnce(io, chat_a));
    try testing.expect(!shouldNotifySleepOnce(io, chat_a));
    try testing.expect(shouldNotifySleepOnce(io, chat_b));
    try testing.expect(!shouldNotifySleepOnce(io, chat_b));

    resetSleepNotifications(io);
    try testing.expect(shouldNotifySleepOnce(io, chat_a));
}

const test_support = @import("../store/test_support.zig");
const PgPoolT = @import("../store/pool.zig").PgPool;

test "pruneOldMessages across every chat, and scoped to one chat" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPoolT.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const chat2 = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    try messages.insert(&pool, chat1, alice, "1", "old", 1000);
    try messages.insert(&pool, chat1, alice, "2", "recent", 5000);
    try messages.insert(&pool, chat2, alice, "3", "also old", 1000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const scoped = try pruneOldMessages(&pool, a, chat1, 2000);
    try testing.expectEqual(@as(i64, 1), scoped.rows_deleted);
    try testing.expectEqual(@as(usize, 1), scoped.chats_affected);

    const across_all = try pruneOldMessages(&pool, a, null, 2000);
    try testing.expectEqual(@as(i64, 1), across_all.rows_deleted); // only chat2's row was left to prune
    try testing.expectEqual(@as(usize, 1), across_all.chats_affected);
}

test "sweepTmpDir deletes only files older than the threshold" {
    const io = testing.io;
    const a = testing.allocator;
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const dir_path = try std.fmt.allocPrint(a, "data/tmp/storage_sense_test_{d}", .{ts});
    defer a.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    defer Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    const fresh_path = try std.fmt.allocPrint(a, "{s}/fresh.txt", .{dir_path});
    defer a.free(fresh_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fresh_path, .data = "still in use" });

    // A sweep with a threshold in the far future treats every file
    // (including one just written) as stale -- this proves the age check
    // itself works without needing to fabricate an old mtime.
    const swept = try sweepTmpDir(io, a, dir_path, -1_000_000);
    try testing.expectEqual(@as(usize, 1), swept.files_deleted);
    try testing.expectEqual(@as(u64, "still in use".len), swept.bytes_freed);

    // A second sweep with an effectively-infinite threshold leaves a
    // freshly-written file alone.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fresh_path, .data = "still in use" });
    const untouched = try sweepTmpDir(io, a, dir_path, 1_000_000);
    try testing.expectEqual(@as(usize, 0), untouched.files_deleted);
}

test "sweepTmpDir on a missing directory is a no-op, not an error" {
    const swept = try sweepTmpDir(testing.io, testing.allocator, "data/tmp/storage_sense_does_not_exist", 0);
    try testing.expectEqual(@as(usize, 0), swept.files_deleted);
}
