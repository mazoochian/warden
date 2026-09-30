//! Warden's own disk-usage awareness, built after a real outage: the VPS's
//! disk filled to 100% (an unrotated Docker log plus general growth),
//! Postgres PANIC crash-looped, and every DB write silently failed for ~3
//! hours until someone noticed and restarted the container by hand.
const std = @import("std");
const Io = std.Io;

const llm = @import("../llm/provider.zig");
const digest = @import("digest.zig");
const registry = @import("../tools/registry.zig");
const iface = @import("../platform/interface.zig");
const config_mod = @import("../config.zig");
const civil_time = @import("../text/civil_time.zig");
const embeddings = @import("../llm/embeddings.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const messages = @import("../store/messages.zig");
const chats = @import("../store/chats.zig");
const identities = @import("../store/identities.zig");
const facts = @import("../store/facts.zig");
const daily_digests = @import("../store/daily_digests.zig");
const dynamic_config = @import("../store/dynamic_config.zig");

pub const low_watermark_key = "WARDEN_STORAGE_SENSE_LOW_WATERMARK_PCT";
pub const high_watermark_key = "WARDEN_STORAGE_SENSE_HIGH_WATERMARK_PCT";
pub const flood_watermark_key = "WARDEN_STORAGE_SENSE_FLOOD_WATERMARK_PCT";
pub const resume_margin_key = "WARDEN_STORAGE_SENSE_RESUME_MARGIN_PCT";
pub const prune_age_days_key = "WARDEN_STORAGE_SENSE_PRUNE_AGE_DAYS";
pub const resample_batch_size_key = "WARDEN_STORAGE_SENSE_RESAMPLE_BATCH_SIZE";
pub const autopilot_enabled_key = "WARDEN_STORAGE_SENSE_AUTOPILOT_ENABLED";
pub const backlog_multiplier_key = "WARDEN_STORAGE_SENSE_BACKLOG_MULTIPLIER";
pub const backlog_interval_key = "WARDEN_STORAGE_SENSE_BACKLOG_INTERVAL_SECONDS";
pub const facts_tentative_max_age_days_key = "WARDEN_FACTS_TENTATIVE_MAX_AGE_DAYS";

/// Runtime bookkeeping, not an owner tunable -- deliberately left out of
/// `dynamic_config.known_keys` (see that file's own comment on these three).
const last_high_alert_ts_key = "WARDEN_STORAGE_SENSE_LAST_HIGH_ALERT_TS";
const sleep_active_key = "WARDEN_STORAGE_SENSE_SLEEP_ACTIVE";
const sleep_entered_ts_key = "WARDEN_STORAGE_SENSE_SLEEP_ENTERED_TS";
const last_tmp_sweep_ts_key = "WARDEN_STORAGE_SENSE_LAST_TMP_SWEEP_TS";
const last_backlog_compact_ts_key = "WARDEN_STORAGE_SENSE_LAST_BACKLOG_COMPACT_TS";

/// How long between daily high-watermark owner alerts.
const high_alert_interval_seconds: i64 = 24 * 60 * 60;
/// How often the unconditional tmp sweep actually runs -- every tick would
/// be wasted directory-listing work for scratch space that only grows slowly.
const tmp_sweep_interval_seconds: i64 = 6 * 60 * 60;
/// Files under `tmp_dir` older than this are considered abandoned rather than
/// mid-use.
pub const tmp_sweep_max_age_seconds: i64 = 24 * 60 * 60;
/// Below this, `resampleOldMessages` skips a chat rather than spending a real
/// LLM call compacting a handful of leftover rows.
const min_batch_for_resample: usize = 20;

pub const DiskUsage = struct {
    used_pct: f64,
    total_bytes: u64,
    available_bytes: u64,
};

/// Runs `df -kP path` and parses its one data row.
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
/// slack.
const df_timeout_seconds: i64 = 10;

/// Local since only `checkDiskUsage` and this file's own tests need it.
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
/// kept trivially unit-testable on its own.
pub fn classify(used_pct: f64, low_pct: i64, high_pct: i64, flood_pct: i64) Watermark {
    if (used_pct >= @as(f64, @floatFromInt(flood_pct))) return .flood;
    if (used_pct >= @as(f64, @floatFromInt(high_pct))) return .high;
    if (used_pct >= @as(f64, @floatFromInt(low_pct))) return .low;
    return .normal;
}

pub const PruneResult = struct {
    chats_affected: usize = 0,
    rows_deleted: i64 = 0,
    /// Chats whose delete errored (logged); the rest were still pruned.
    chats_failed: usize = 0,
};

/// Deletes messages older than `cutoff_ts` in `chat_id`, or across every
/// known chat when `chat_id` is `null`.
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
            result.chats_failed += 1;
            continue;
        };
        if (deleted > 0) result.chats_affected += 1;
        result.rows_deleted += deleted;
    }
    return result;
}

pub const ResampleResult = struct {
    chats_affected: usize = 0,
    messages_compacted: i64 = 0,
    /// Chats whose batch couldn't be summarized (logged). Callers must
    /// surface this: "0 compacted" alone reads as "nothing to do".
    chats_failed: usize = 0,
    last_error: ?anyerror = null,
};

/// Platform-agnostic identity `resampleOldMessages` attributes every
/// synthetic summary row to.
const system_identity_native_id = "warden_storage_sense";

/// An all-zero placeholder for `daily_digests.upsert`'s `NOT NULL embedding`
/// column when no embeddings client is configured -- keeps the digest
/// visible via `daily_digests.mostRecent`'s recency floor even though it'll
/// never win a similarity-ranked match, the same "ranked recall degrades,
/// recency recall doesn't" tradeoff `context_assembly.zig` already makes.
const zero_embedding: [embeddings.embedding_dimensions]f32 = @splat(0);

/// Best-effort write into the episodic layer `context_assembly.zig` actually
/// reads -- failure here must not undo the already-committed
/// `messages.replaceRangeWithSummary` collapse above it.
fn writeDailyDigest(pool: *PgPool, allocator: std.mem.Allocator, embeddings_client: ?*embeddings.EmbeddingsClient, chat_id: i64, batch: messages.SummaryBatch, summary: []const u8) void {
    const embedding: []const f32 = blk: {
        const client = embeddings_client orelse break :blk &zero_embedding;
        break :blk client.embed(allocator, summary) catch |err| {
            std.log.warn("storage_sense: embed failed for chat {d} digest: {t}", .{ chat_id, err });
            break :blk &zero_embedding;
        };
    };
    const c = civil_time.localFromUnix(batch.newest_ts, 0);
    const weekday = civil_time.weekdayName(civil_time.weekdayFromDays(@divFloor(batch.newest_ts, 86400)));
    _ = daily_digests.upsert(pool, allocator, chat_id, c.year, c.month, c.day, weekday, summary, batch.min_id, batch.max_id, embedding) catch |err| {
        std.log.warn("storage_sense: daily_digests upsert failed for chat {d}: {t}", .{ chat_id, err });
    };
}

/// Compacts the oldest batch of `chat_id`'s non-summary messages into one
/// LLM-written summary via `digest.summarizeHistory`, both collapsing them
/// in place (`messages.replaceRangeWithSummary`) and writing the summary into
/// `daily_digests` for the local day the batch's newest message falls on.
fn resampleOneChat(pool: *PgPool, allocator: std.mem.Allocator, io: Io, llm_provider: llm.Provider, embeddings_client: ?*embeddings.EmbeddingsClient, chat_id: i64, batch_size: i64, system_identity_id: i64) !i64 {
    const batch = try messages.oldestBatchForSummary(pool, allocator, chat_id, batch_size) orelse return 0;
    if (batch.count < min_batch_for_resample) return 0;

    const ctx = registry.ToolContext{ .allocator = allocator, .io = io };
    const summary = digest.summarizeHistory(llm_provider, allocator, ctx, batch.text);
    if (summary.len == 0) return error.SummaryFailed;

    try messages.replaceRangeWithSummary(pool, chat_id, system_identity_id, batch.min_id, batch.max_id, summary, batch.newest_ts);
    writeDailyDigest(pool, allocator, embeddings_client, chat_id, batch, summary);
    return @intCast(batch.count);
}

/// See `resampleOneChat` for the per-chat mechanics; `chat_id = null` runs it
/// across every known chat (the ladder's use).
pub fn resampleOldMessages(pool: *PgPool, allocator: std.mem.Allocator, io: Io, llm_provider: llm.Provider, embeddings_client: ?*embeddings.EmbeddingsClient, chat_id: ?i64, batch_size: i64) !ResampleResult {
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const system_identity_id = try identities.getOrCreateMinimal(pool, .telegram, system_identity_native_id, "Warden", null, true, now);

    if (chat_id) |id| {
        const compacted = try resampleOneChat(pool, allocator, io, llm_provider, embeddings_client, id, batch_size, system_identity_id);
        return .{ .chats_affected = if (compacted > 0) 1 else 0, .messages_compacted = compacted };
    }

    const refs = try chats.listAll(pool, allocator);
    defer {
        for (refs) |r| allocator.free(r.native_chat_id);
        allocator.free(refs);
    }

    var result: ResampleResult = .{};
    for (refs) |ref| {
        const compacted = resampleOneChat(pool, allocator, io, llm_provider, embeddings_client, ref.id, batch_size, system_identity_id) catch |err| {
            std.log.warn("storage_sense: resample failed for chat {d}: {t}", .{ ref.id, err });
            result.chats_failed += 1;
            result.last_error = err;
            continue;
        };
        if (compacted > 0) result.chats_affected += 1;
        result.messages_compacted += compacted;
    }
    return result;
}

pub const BacklogResult = struct { chats_affected: usize = 0, messages_compacted: i64 = 0 };

/// Chat-scoped backlog trigger, independent of disk pressure: compacts a
/// chat once its non-summary message count exceeds
/// `history_window * multiplier`. Complements `tick`'s disk-pressure ladder
/// -- on a host with plenty of headroom that ladder never fires, so without
/// this `daily_digests` stays empty and old raw history just accumulates
/// until the per-turn char budget in `context_assembly.zig` silently drops
/// it from a given answer with nothing to remember it by.
pub fn compactBacklog(
    pool: *PgPool,
    allocator: std.mem.Allocator,
    io: Io,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    history_window: i64,
    multiplier: i64,
    batch_size: i64,
) !BacklogResult {
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const system_identity_id = try identities.getOrCreateMinimal(pool, .telegram, system_identity_native_id, "Warden", null, true, now);
    const threshold = history_window * multiplier;

    const refs = try chats.listAll(pool, allocator);
    defer {
        for (refs) |r| allocator.free(r.native_chat_id);
        allocator.free(refs);
    }

    var result: BacklogResult = .{};
    for (refs) |ref| {
        const count = messages.countNonSummary(pool, ref.id) catch |err| {
            std.log.warn("storage_sense: backlog count failed for chat {d}: {t}", .{ ref.id, err });
            continue;
        };
        if (count <= threshold) continue;
        const compacted = resampleOneChat(pool, allocator, io, llm_provider, embeddings_client, ref.id, batch_size, system_identity_id) catch |err| {
            std.log.warn("storage_sense: backlog compaction failed for chat {d}: {t}", .{ ref.id, err });
            continue;
        };
        if (compacted > 0) result.chats_affected += 1;
        result.messages_compacted += compacted;
    }
    return result;
}

/// Runs `compactBacklog` plus `facts.autoRetireStaleTentative`, gated by its
/// own interval (`backlog_interval_key`) independent of `tick`'s disk
/// watermark -- deliberately not folded into `tick` itself: disk health and
/// context quality are different concerns with different natural cadences,
/// and conflating them would muddy both. Called once per scheduler tick from
/// `main.zig`, right after `tick`.
pub fn tickBacklog(
    gpa: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    pool: *PgPool,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    owner_identity_id: i64,
    now: i64,
) void {
    const interval = dynamic_config.getI64(pool, gpa, backlog_interval_key, config.storage_sense_backlog_interval_seconds);
    const last = dynamic_config.getI64(pool, gpa, last_backlog_compact_ts_key, 0);
    if (now - last < interval) return;
    setInt(pool, last_backlog_compact_ts_key, now, owner_identity_id);

    const multiplier = dynamic_config.getI64(pool, gpa, backlog_multiplier_key, config.storage_sense_backlog_multiplier);
    const history_window = dynamic_config.getI64(pool, gpa, "WARDEN_LLM_HISTORY_MESSAGES", config.llm_history_messages);
    const batch_size = dynamic_config.getI64(pool, gpa, resample_batch_size_key, config.storage_sense_resample_batch_size);
    const result = compactBacklog(pool, gpa, io, llm_provider, embeddings_client, history_window, multiplier, batch_size) catch |err| blk: {
        std.log.warn("storage_sense: tickBacklog compaction failed: {t}", .{err});
        break :blk BacklogResult{};
    };
    if (result.messages_compacted > 0) {
        std.log.info("storage_sense: backlog-compacted {d} messages across {d} chats", .{ result.messages_compacted, result.chats_affected });
    }

    const max_age_days = dynamic_config.getI64(pool, gpa, facts_tentative_max_age_days_key, config.facts_tentative_max_age_days);
    const retired = facts.autoRetireStaleTentative(pool, gpa, now, max_age_days * 86400) catch |err| blk: {
        std.log.warn("storage_sense: tentative-fact auto-retire failed: {t}", .{err});
        break :blk 0;
    };
    if (retired > 0) {
        std.log.info("storage_sense: auto-retired {d} stale tentative fact(s)", .{retired});
    }
}

pub const SweepResult = struct {
    files_deleted: usize = 0,
    bytes_freed: u64 = 0,
    /// Files left alone because they're newer than the age threshold.
    files_kept: usize = 0,
    bytes_kept: u64 = 0,
};

/// Deletes every file directly under `tmp_dir` whose mtime is older than
/// `older_than_seconds`.
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
        if (now - stat.mtime.toSeconds() < older_than_seconds) {
            result.files_kept += 1;
            result.bytes_kept += stat.size;
            continue;
        }
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
/// notice this sleep episode.
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
/// main loop.
pub fn tick(
    gpa: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    pool: *PgPool,
    llm_provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
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
        const resample_result = resampleOldMessages(pool, gpa, io, llm_provider, embeddings_client, null, batch_size) catch |err| blk: {
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

/// `dynamic_config.set` only takes text values.
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
    // 388145164 / 421864448 * 100 -- computed.
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
    // Runs against the shared process-global map.
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

/// Records nothing, just answers with a fixed sentence -- `digest.zig`'s own
/// tests use the same shape.
const FixedAnswerProvider = struct {
    answer: []const u8 = "They discussed something mundane.",

    fn provider(self: *FixedAnswerProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: llm.Provider.VTable = .{ .chat = chat };
    fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        _ = request;
        const self: *FixedAnswerProvider = @ptrCast(@alignCast(ptr));
        const blocks = try allocator.alloc(llm.ContentBlock, 1);
        blocks[0] = .{ .text = self.answer };
        return .{ .content = blocks, .stop_reason = .end_turn };
    }
};

test "resampleOldMessages compacts a chat's oldest batch and also writes a daily_digests row for it" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPoolT.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const chat1 = try chats.upsertChat(&pool, .telegram, "1", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    var i: i64 = 0;
    while (i < 25) : (i += 1) {
        try messages.insert(&pool, chat1, alice, null, "chatting away", 1000 + i);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stub = FixedAnswerProvider{};
    const result = try resampleOldMessages(&pool, a, testing.io, stub.provider(), null, chat1, 25);
    try testing.expectEqual(@as(usize, 1), result.chats_affected);
    try testing.expectEqual(@as(i64, 25), result.messages_compacted);

    try testing.expect(try daily_digests.hasAny(&pool, chat1));
    const recent = try daily_digests.mostRecent(&pool, a, chat1, 5);
    try testing.expectEqual(@as(usize, 1), recent.len);
    try testing.expectEqualStrings(stub.answer, recent[0].summary);
}

test "compactBacklog only compacts chats whose non-summary count exceeds the threshold" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPoolT.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    // Over threshold (history_window=10, multiplier=2 -> compacts past 20).
    const busy = try chats.upsertChat(&pool, .telegram, "1", null, null);
    // Under threshold -- left alone.
    const quiet = try chats.upsertChat(&pool, .telegram, "2", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);

    var i: i64 = 0;
    while (i < 25) : (i += 1) try messages.insert(&pool, busy, alice, null, "busy chat filler", 1000 + i);
    i = 0;
    while (i < 5) : (i += 1) try messages.insert(&pool, quiet, alice, null, "quiet chat filler", 1000 + i);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stub = FixedAnswerProvider{};
    const result = try compactBacklog(&pool, a, testing.io, stub.provider(), null, 10, 2, 25);
    try testing.expectEqual(@as(usize, 1), result.chats_affected);
    try testing.expectEqual(@as(i64, 25), result.messages_compacted);

    try testing.expect(try daily_digests.hasAny(&pool, busy));
    try testing.expect(!try daily_digests.hasAny(&pool, quiet));
    try testing.expectEqual(@as(i64, 5), try messages.countNonSummary(&pool, quiet));
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

    // A sweep with a threshold in the far future treats every file (including one
    // just written) as stale.
    const swept = try sweepTmpDir(io, a, dir_path, -1_000_000);
    try testing.expectEqual(@as(usize, 1), swept.files_deleted);
    try testing.expectEqual(@as(u64, "still in use".len), swept.bytes_freed);

    // A second sweep with an effectively-infinite threshold leaves a
    // freshly-written file alone.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fresh_path, .data = "still in use" });
    const untouched = try sweepTmpDir(io, a, dir_path, 1_000_000);
    try testing.expectEqual(@as(usize, 0), untouched.files_deleted);
    try testing.expectEqual(@as(usize, 1), untouched.files_kept);
    try testing.expectEqual(@as(u64, "still in use".len), untouched.bytes_kept);
}

test "sweepTmpDir on a missing directory is a no-op, not an error" {
    const swept = try sweepTmpDir(testing.io, testing.allocator, "data/tmp/storage_sense_does_not_exist", 0);
    try testing.expectEqual(@as(usize, 0), swept.files_deleted);
}

/// Answers every call with `reply`; `.thinking` models a reasoning model that
/// ran out of tokens before writing anything visible.
const StubProvider = struct {
    reply: enum { text, thinking },

    fn provider(self: *StubProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        _ = request;
        const self: *StubProvider = @ptrCast(@alignCast(ptr));
        return switch (self.reply) {
            .text => .{ .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "a summary" }}), .stop_reason = .end_turn },
            .thinking => .{ .content = try allocator.dupe(llm.ContentBlock, &.{.{ .thinking = .{ .text = "...", .field = .reasoning_content } }}), .stop_reason = .max_tokens },
        };
    }
};

test "resampleOldMessages across every chat counts a failed summary instead of reporting nothing to do" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPoolT.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chat = try chats.upsertChat(&pool, .telegram, "-100", null, null);
    const alice = try identities.getOrCreateMinimal(&pool, .telegram, "1", "alice", null, false, 1000);
    var i: i64 = 0;
    while (i < 30) : (i += 1) try messages.insert(&pool, chat, alice, null, "hello", 1000 + i);

    var failing = StubProvider{ .reply = .thinking };
    const failed = try resampleOldMessages(&pool, a, testing.io, failing.provider(), null, null, 200);
    try testing.expectEqual(@as(i64, 0), failed.messages_compacted);
    try testing.expectEqual(@as(usize, 1), failed.chats_failed);
    try testing.expectEqual(@as(?anyerror, error.SummaryFailed), failed.last_error);

    var working = StubProvider{ .reply = .text };
    const ok = try resampleOldMessages(&pool, a, testing.io, working.provider(), null, null, 200);
    try testing.expectEqual(@as(i64, 30), ok.messages_compacted);
    try testing.expectEqual(@as(usize, 1), ok.chats_affected);
    try testing.expectEqual(@as(usize, 0), ok.chats_failed);
}
