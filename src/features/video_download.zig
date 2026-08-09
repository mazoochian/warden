//! ROADMAP.md's Phase 25: passive auto-download of YouTube/Instagram/X
//! video links posted in a chat, delivered either as a native inline-
//! playable video (lossy mode, the default -- compressed to fit Telegram's
//! upload ceiling) or as a plain file (lossless mode, an opt-in -- original
//! quality, capped at 50MB, unchanged from this feature's original shape).
//! Three independent pieces live here, all deliberately free of any
//! `Connector`/store dependency (same "pure function over bytes/paths"
//! shape as `convert.zig`/`transcribe.zig` -- `main.zig`'s
//! `checkVideoDownload`/`videoDownloadWorker` own the gating, threading,
//! progress-ticker and connector calls):
//!
//!   - `findLink`: a plain substring scan over a message's text, no LLM
//!     call, same "passive content observation" tier as
//!     `main.zig`'s `checkKeywordAlerts`.
//!   - `download`: shells out to `yt-dlp` (and, in lossy mode when the
//!     source doesn't already fit, `ffmpeg`/`ffprobe` to compress it),
//!     same argv/tmpdir/`defer deleteFile`/`readFileAlloc(.limited(...))`
//!     idiom `convert.zig`/`transcribe.zig` already use for their own
//!     external tools, plus a hard wall-clock timeout on every subprocess
//!     call -- see `runWithTimeout`'s doc comment for why `yt-dlp`
//!     specifically needs one and how it's enforced.
//!   - `estimateSize`/`pollCurrentBytes`/`formatProgressText`: best-effort
//!     progress reporting for `main.zig`'s progress ticker. Deliberately
//!     filesystem-polling rather than streaming `yt-dlp`'s own stdout --
//!     this codebase has no precedent anywhere for incrementally reading a
//!     subprocess's output (every other shell-out blocks to completion),
//!     and polling a growing file's size on disk gets a good-enough
//!     percentage without introducing that new, riskier pattern.
//!
//! **Failure handling is fail-closed by design**: age-restricted, private,
//! geo-blocked, DRM'd, oversized (even after compression), or otherwise
//! undownloadable links are never surfaced as an in-chat error -- `download`
//! just returns an error, `main.zig`'s caller logs it and does nothing
//! visible, exactly the "never block the reply on failure" philosophy
//! `transcribe.zig`'s own caller (`resolveQuestion`) already follows for a
//! failed transcription. A chat with this feature on posts a lot of
//! ordinary links that are not videos at all (a news article, a github
//! repo) -- erroring loudly on every one of those would be far worse than
//! silently doing nothing.
const std = @import("std");
const Io = std.Io;

const convert = @import("convert.zig");

/// Telegram's cloud Bot API's real upload ceiling — this codebase talks
/// directly to `api.telegram.org` with no local Bot API server (which would
/// raise the limit to 2GB but needs its own separate service this project
/// doesn't run — see ROADMAP.md's Phase 25 entry for why that's flagged as
/// a possible future backlog item, not solved here). This is the hard
/// budget both quality modes ultimately respect: lossless mode asks
/// `yt-dlp` to never fetch more than this in the first place; lossy mode
/// compresses down to fit it when the source doesn't already.
const max_bytes: usize = 50 * 1024 * 1024;

/// Which delivery mode `download` should use — see this file's module doc
/// comment. Chosen per-chat via `chat_settings.getVideoDownloadLossy`
/// (`main.zig`), lossy being the default.
pub const Quality = enum { lossy, lossless };

/// How long lossless `yt-dlp` gets before `download` gives up and kills it
/// -- see `runWithTimeout`'s doc comment. `yt-dlp` is network-bound against
/// an arbitrary remote server (unlike the local `ffmpeg`/`pandoc`/`convert`
/// binaries `convert.zig` shells out to), so it can hang far longer than
/// any of those ever would; 2 minutes comfortably covers a real short-clip
/// download while still failing closed well within a human's patience for
/// "did my link do anything." Lossy mode gets its own, longer budgets
/// below -- it's doing more work (a same-or-larger fetch, potentially a
/// compression pass too).
const lossless_timeout_seconds: i64 = 120;

/// `yt-dlp` format selector both `downloadLossy` and `estimateSize` use --
/// shared so the preflight size estimate actually corresponds to what gets
/// fetched. Bounded to ~720p: a reasonable "shareable clip" resolution that
/// keeps most short social clips at or near `max_bytes` already, so the
/// `compressToFit` fallback below is the exception, not the common case.
const lossy_format_selector = "bv*[height<=720]+ba/b[height<=720]";

/// Safety-valve ceiling on `yt-dlp`'s own `--max-filesize` in lossy mode --
/// NOT the delivered-size budget (that's still `max_bytes`, enforced by
/// compression below). Purpose is only to stop a pathological multi-GB
/// source (a long stream someone links) from being fetched at all; a
/// generously large but bounded ceiling, since the point of lossy mode is
/// "compress whatever a reasonable clip actually is," not "cap the source."
const lossy_source_max_filesize_arg = "500M";

/// Longer than `lossless_timeout_seconds`: even bounded to ~720p, a lossy
/// fetch can be pulling a larger/longer source than the lossless path ever
/// would (which fails closed immediately if no under-50MB format exists).
const lossy_download_timeout_seconds: i64 = 180;

/// Bounds the best-effort `estimateSize` preflight call -- must stay short
/// since it runs before the placeholder message and progress ticker even
/// start; a slow preflight would itself look like "nothing is happening."
const preflight_timeout_seconds: i64 = 15;

/// `ffprobe` is local and CPU-only (no network) -- should return almost
/// instantly; generous slack, not a real expected duration.
const ffprobe_timeout_seconds: i64 = 15;

/// Bounds the `ffmpeg` compression pass.
const compress_timeout_seconds: i64 = 120;

/// Audio bitrate `compressToFit` reserves out of the size budget before
/// computing a video bitrate for the rest.
const target_audio_bitrate_kbps: u32 = 128;

/// Floor below which a computed video bitrate would produce an unwatchably
/// bad encode -- `computeVideoBitrateKbps` returns `null` rather than that,
/// which `compressToFit`/`downloadLossy` treat as "this clip is too long to
/// fit lossy mode's budget at all," failing closed the same as an
/// oversized lossless link does today.
const min_video_bitrate_kbps: u32 = 150;

/// `compressToFit` targets this fraction of `max_bytes`, not all of it --
/// headroom for container overhead and single-pass `libx264` rate control
/// occasionally overshooting its target under high-motion content. A first
/// guess, not a derived constant; worth revisiting once real videos have
/// run through it.
const size_safety_margin: f64 = 0.92;

/// Serializes every `ffmpeg` compression call in the process (see
/// `compressToFit`) -- deliberately NOT serializing `yt-dlp` fetches, which
/// are I/O-bound and fine running concurrently. `Io.Mutex`, not
/// `std.Thread.Mutex` -- same primitive `main.zig`'s `TickerState` already
/// uses for its own cross-thread state, locked/unlocked through the `Io`
/// each caller already has on hand.
var compression_mutex: Io.Mutex = .init;

/// Substrings identifying a link this module will attempt to download —
/// deliberately conservative and literal (no real regex engine in `std`),
/// equivalent to the plan's own
/// `(youtube\.com/watch|youtube\.com/shorts/|youtu\.be/|instagram\.com/(reel|p)/|x\.com/|twitter\.com/)`.
/// Case-sensitive on purpose: real URLs use lowercase domains, and a
/// hand-rolled case-insensitive substring search isn't worth the extra
/// code for a fail-closed feature where a missed match just means no
/// download, not a functional gap.
const trigger_patterns = [_][]const u8{
    "youtube.com/watch",
    "youtube.com/shorts/",
    "youtu.be/",
    "instagram.com/reel/",
    "instagram.com/p/",
    "x.com/",
    "twitter.com/",
};

/// Scans `text` token by token (splitting on ASCII whitespace) for the
/// first token containing one of `trigger_patterns`, returning that token
/// trimmed of common trailing punctuation a sentence might wrap it in
/// (`"check this out: https://youtu.be/abc123."` yields
/// `"https://youtu.be/abc123"`, not `"https://youtu.be/abc123."`). Doesn't
/// otherwise validate the token is a well-formed URL — `yt-dlp` itself is
/// the source of truth for "is this actually downloadable" (see this
/// module's own doc comment on fail-closed handling), so a token that
/// merely *contains* a trigger substring but isn't really a link just
/// fails the download attempt harmlessly.
pub fn findLink(text: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |token| {
        for (trigger_patterns) |pattern| {
            if (std.mem.indexOf(u8, token, pattern) != null) {
                return std.mem.trimEnd(u8, token, ").,!?\"'");
            }
        }
    }
    return null;
}

pub const DownloadResult = struct {
    bytes: []const u8,
    file_name: []const u8,
};

/// Named for callers that want to log/branch on which failure mode this
/// was — `download` itself returns a plain inferred error set (same shape
/// as `convert.zig`'s `convert()`), so these names are documentation more
/// than a binding contract.
pub const DownloadError = error{ DownloadFailed, DownloadTimedOut, CompressionFailed, DownloadTooLarge };

/// Downloads `url` at `quality`, returning file bytes (capped at
/// `max_bytes`) plus a suggested filename. `ts` is the nanosecond
/// uniqueness key for this attempt's tmp files -- generated by the caller
/// (`main.zig`'s `checkVideoDownload`), not here, so a concurrent progress
/// ticker (`pollCurrentBytes`) can watch the same `tmp_dir/video_download_
/// {ts}*` prefix while this runs on the worker thread.
pub fn download(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, url: []const u8, quality: Quality, ts: i96) !DownloadResult {
    try Io.Dir.cwd().createDirPath(io, tmp_dir);
    return switch (quality) {
        .lossless => downloadLossless(allocator, io, tmp_dir, url, ts),
        .lossy => downloadLossy(allocator, io, tmp_dir, url, ts),
    };
}

/// Original, unchanged-since-launch behavior: `yt-dlp --max-filesize 50M`,
/// fail closed if no under-`max_bytes` format exists. Delivered as a file
/// (`sendDocument`), original quality -- see this file's module doc
/// comment for the lossy/lossless split.
///
/// `--no-playlist` is the one argv addition beyond the plan's literal
/// `yt-dlp -o ... --max-filesize 50M <url>`: without it, a
/// `youtube.com/watch?v=...&list=...` link (a video that's also part of a
/// playlist — common in practice) would have `yt-dlp` fetch the *entire*
/// playlist into `tmp_dir`, breaking `findDownloadedFile`'s single-file
/// assumption below and turning one chat link into an unbounded, far-past-
/// timeout download. Restricting to the one linked video is what "someone
/// posted a video link" means here, not "someone posted a playlist link."
fn downloadLossless(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, url: []const u8, ts: i96) !DownloadResult {
    const output_template = try std.fmt.allocPrint(allocator, "{s}/video_download_{d}.%(ext)s", .{ tmp_dir, ts });
    defer allocator.free(output_template);

    const result = runWithTimeout(allocator, io, &.{
        "yt-dlp",
        "-o",
        output_template,
        "--max-filesize",
        "50M",
        "--no-playlist",
        url,
    }, lossless_timeout_seconds) catch |err| {
        std.log.warn("video_download: yt-dlp failed to run for {s}: {t}", .{ url, err });
        return if (err == error.Timeout) error.DownloadTimedOut else error.DownloadFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.warn("video_download: yt-dlp exited nonzero for {s} (term={any}): {s}", .{ url, result.term, result.stderr });
        return error.DownloadFailed;
    }

    const output_path = findDownloadedFile(allocator, io, tmp_dir, ts) catch |err| {
        std.log.warn("video_download: yt-dlp exited 0 for {s} but no output file was found: {t}", .{ url, err });
        return error.DownloadFailed;
    };
    defer allocator.free(output_path);
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    const bytes = try Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(max_bytes));
    const ext = convert.extensionOf(output_path);
    const file_name = try std.fmt.allocPrint(allocator, "video{s}", .{ext});
    return .{ .bytes = bytes, .file_name = file_name };
}

/// Fetches a bounded/reasonable-resolution source (~720p, well under
/// `lossy_source_max_filesize_arg`), then delivers it as-is if it already
/// fits `max_bytes` (the common case for short clips), or compresses it
/// down to fit via `compressToFit` otherwise. Delivered as a native video
/// (`sendVideo`) -- see this file's module doc comment.
fn downloadLossy(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, url: []const u8, ts: i96) !DownloadResult {
    const output_template = try std.fmt.allocPrint(allocator, "{s}/video_download_{d}.%(ext)s", .{ tmp_dir, ts });
    defer allocator.free(output_template);

    const result = runWithTimeout(allocator, io, &.{
        "yt-dlp",
        "-o",
        output_template,
        "-f",
        lossy_format_selector,
        "--merge-output-format",
        "mp4",
        "--max-filesize",
        lossy_source_max_filesize_arg,
        "--no-playlist",
        url,
    }, lossy_download_timeout_seconds) catch |err| {
        std.log.warn("video_download: yt-dlp (lossy) failed to run for {s}: {t}", .{ url, err });
        return if (err == error.Timeout) error.DownloadTimedOut else error.DownloadFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.warn("video_download: yt-dlp (lossy) exited nonzero for {s} (term={any}): {s}", .{ url, result.term, result.stderr });
        return error.DownloadFailed;
    }

    const source_path = findDownloadedFile(allocator, io, tmp_dir, ts) catch |err| {
        std.log.warn("video_download: yt-dlp (lossy) exited 0 for {s} but no output file was found: {t}", .{ url, err });
        return error.DownloadFailed;
    };
    defer allocator.free(source_path);
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};

    const source_stat = try Io.Dir.cwd().statFile(io, source_path, .{});
    if (source_stat.size <= max_bytes) {
        // Already fits -- skip compression entirely, the common case for a
        // short clip at this format selector.
        const bytes = try Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(max_bytes));
        return .{ .bytes = bytes, .file_name = try allocator.dupe(u8, "video.mp4") };
    }

    const compressed_path = try std.fmt.allocPrint(allocator, "{s}/video_download_{d}_compressed.mp4", .{ tmp_dir, ts });
    defer allocator.free(compressed_path);
    defer Io.Dir.cwd().deleteFile(io, compressed_path) catch {};

    const budget_bytes: u64 = @intFromFloat(size_safety_margin * @as(f64, @floatFromInt(max_bytes)));
    compressToFit(allocator, io, source_path, compressed_path, budget_bytes) catch |err| {
        std.log.warn("video_download: compression failed for {s}: {t}", .{ url, err });
        return error.CompressionFailed;
    };

    const compressed_stat = try Io.Dir.cwd().statFile(io, compressed_path, .{});
    if (compressed_stat.size > max_bytes) {
        std.log.warn("video_download: compressed output for {s} is still {d} bytes, over the {d} budget -- giving up", .{ url, compressed_stat.size, max_bytes });
        return error.DownloadTooLarge;
    }

    const bytes = try Io.Dir.cwd().readFileAlloc(io, compressed_path, allocator, .limited(max_bytes));
    return .{ .bytes = bytes, .file_name = try allocator.dupe(u8, "video.mp4") };
}

/// Pure sizing math, no IO -- given a clip's `duration_seconds` and a
/// total `budget_bytes`, reserves `audio_kbps` worth of audio out of the
/// budget and returns the video bitrate (in kbps) that spends the rest
/// over the clip's full length. Returns `null` if that would fall below
/// `min_video_bitrate_kbps` -- the clip is too long to fit this budget at
/// any watchable quality, which `compressToFit`/`downloadLossy` treat as a
/// fail-closed signal, same class as an oversized lossless link today.
pub fn computeVideoBitrateKbps(duration_seconds: f64, budget_bytes: u64, audio_kbps: u32) ?u32 {
    if (duration_seconds <= 0) return null;
    const budget_kbits = @as(f64, @floatFromInt(budget_bytes)) * 8.0 / 1000.0;
    const audio_kbits = @as(f64, @floatFromInt(audio_kbps)) * duration_seconds;
    const video_kbps = (budget_kbits - audio_kbits) / duration_seconds;
    if (video_kbps < @as(f64, @floatFromInt(min_video_bitrate_kbps))) return null;
    return @intFromFloat(video_kbps);
}

/// `ffprobe -show_entries format=duration`, parsed as a plain float
/// (seconds, may have a fractional part) -- fails closed (`error.
/// CompressionFailed`) on a nonzero exit or unparseable output rather than
/// letting a bogus duration feed bogus bitrate math.
fn probeDurationSeconds(allocator: std.mem.Allocator, io: Io, path: []const u8) !f64 {
    const result = runWithTimeout(allocator, io, &.{
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "csv=p=0",
        path,
    }, ffprobe_timeout_seconds) catch |err| {
        std.log.warn("video_download: ffprobe failed to run for {s}: {t}", .{ path, err });
        return error.CompressionFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.warn("video_download: ffprobe exited nonzero for {s} (term={any}): {s}", .{ path, result.term, result.stderr });
        return error.CompressionFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.fmt.parseFloat(f64, trimmed) catch {
        std.log.warn("video_download: ffprobe produced unparseable duration '{s}' for {s}", .{ trimmed, path });
        return error.CompressionFailed;
    };
}

/// Probes `input_path`'s duration, sizes a bitrate that fits `budget_bytes`
/// via `computeVideoBitrateKbps`, then re-encodes with `ffmpeg` into
/// `output_path`. Single-pass CBR-ish encoding (`-b:v`/`-maxrate`/
/// `-bufsize`), not 2-pass -- 2-pass roughly doubles encode time for no
/// benefit here, since the goal is "fits under budget," not "best quality
/// at a fixed size." No retry on overshoot -- `downloadLossy` fails closed
/// instead, keeping worst-case time bounded and predictable.
///
/// Only the `ffmpeg` call itself is held under `compression_mutex` (see its
/// own doc comment) -- `probeDurationSeconds` above it is cheap and doesn't
/// need to serialize.
fn compressToFit(allocator: std.mem.Allocator, io: Io, input_path: []const u8, output_path: []const u8, budget_bytes: u64) !void {
    const duration = try probeDurationSeconds(allocator, io, input_path);
    const video_kbps = computeVideoBitrateKbps(duration, budget_bytes, target_audio_bitrate_kbps) orelse {
        std.log.info("video_download: {s} is too long ({d:.0}s) to fit the lossy budget at a watchable bitrate", .{ input_path, duration });
        return error.CompressionFailed;
    };

    var video_bitrate_buf: [32]u8 = undefined;
    const video_bitrate_arg = try std.fmt.bufPrint(&video_bitrate_buf, "{d}k", .{video_kbps});
    var maxrate_buf: [32]u8 = undefined;
    const maxrate_arg = try std.fmt.bufPrint(&maxrate_buf, "{d}k", .{video_kbps * 12 / 10});
    var bufsize_buf: [32]u8 = undefined;
    const bufsize_arg = try std.fmt.bufPrint(&bufsize_buf, "{d}k", .{video_kbps * 2});
    var audio_bitrate_buf: [16]u8 = undefined;
    const audio_bitrate_arg = try std.fmt.bufPrint(&audio_bitrate_buf, "{d}k", .{target_audio_bitrate_kbps});

    compression_mutex.lockUncancelable(io);
    defer compression_mutex.unlock(io);

    const result = runWithTimeout(allocator, io, &.{
        "ffmpeg",
        "-y",
        "-i",
        input_path,
        "-c:v",
        "libx264",
        "-b:v",
        video_bitrate_arg,
        "-maxrate",
        maxrate_arg,
        "-bufsize",
        bufsize_arg,
        "-c:a",
        "aac",
        "-b:a",
        audio_bitrate_arg,
        "-movflags",
        "+faststart",
        output_path,
    }, compress_timeout_seconds) catch |err| {
        std.log.warn("video_download: ffmpeg failed to run for {s}: {t}", .{ input_path, err });
        return error.CompressionFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.warn("video_download: ffmpeg exited nonzero for {s} (term={any}): {s}", .{ input_path, result.term, result.stderr });
        return error.CompressionFailed;
    }
    _ = Io.Dir.cwd().statFile(io, output_path, .{}) catch {
        std.log.warn("video_download: ffmpeg exited 0 for {s} but no output file was found", .{input_path});
        return error.CompressionFailed;
    };
}

/// Best-effort preflight size estimate, using the same format selector
/// `downloadLossy` fetches with so the estimate actually corresponds to
/// what will be downloaded. Many extractors (most YouTube videos; commonly
/// NOT Instagram/X) report an approximate filesize without downloading
/// anything. Swallows every failure mode (nonzero exit, timeout,
/// unparseable/`NA` output) and returns `null` rather than propagating --
/// this only ever feeds a progress percentage; when it's unavailable,
/// `main.zig`'s ticker falls back to an elapsed-time display instead.
pub fn estimateSize(allocator: std.mem.Allocator, io: Io, url: []const u8) ?u64 {
    const result = runWithTimeout(allocator, io, &.{
        "yt-dlp",
        "--no-download",
        "--print",
        "filesize_approx",
        "--no-playlist",
        "-f",
        lossy_format_selector,
        url,
    }, preflight_timeout_seconds) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) return null;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

/// Best-effort progress-ticker helper (`main.zig`'s
/// `videoProgressTickerLoop`): scans `tmp_dir` for every entry whose name
/// starts with `video_download_{ts}` and returns the largest size found --
/// covers `yt-dlp`'s in-progress `.part`/`.ytdl` temp files, the merged
/// source file, and (in lossy mode, once compression starts) the
/// compressed output, across both phases, without needing to know which
/// phase is currently active. Returns `null` if nothing matches yet or on
/// any stat error -- this only ever feeds a progress display, never
/// propagates.
pub fn pollCurrentBytes(io: Io, tmp_dir: []const u8, ts: i96) ?u64 {
    var buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "video_download_{d}", .{ts}) catch return null;

    var dir = Io.Dir.cwd().openDir(io, tmp_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var largest: ?u64 = null;
    var it = dir.iterate();
    while (it.next(io) catch return largest) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (largest == null or stat.size > largest.?) largest = stat.size;
    }
    return largest;
}

/// Pure formatting for `main.zig`'s progress ticker -- a percent-based bar
/// when both a current size and a preflight estimate are known (clamped to
/// 99% so it never visually claims completion before the real "done"
/// message replaces it), otherwise a plain elapsed-time line (the common
/// case for Instagram/X, where `estimateSize` usually can't report a
/// total, and for lossless mode, which doesn't call `estimateSize` at all).
pub fn formatProgressText(allocator: std.mem.Allocator, elapsed_seconds: i64, current_bytes: ?u64, estimated_total_bytes: ?u64) ![]const u8 {
    if (current_bytes) |current| {
        if (estimated_total_bytes) |total| {
            if (total > 0) {
                const percent = @min(@as(u64, 99), current * 100 / total);
                return std.fmt.allocPrint(allocator, "⬇️ Downloading… {d}%", .{percent});
            }
        }
    }
    return std.fmt.allocPrint(allocator, "⬇️ Downloading… ({d}s)", .{elapsed_seconds});
}

/// `yt-dlp` resolves `%(ext)s` itself (mp4/webm/mkv/... depending on what
/// it actually fetched), so the real output filename isn't knowable ahead
/// of time the way `convert.zig`'s fixed-extension output path is — this
/// scans `tmp_dir` for whichever file starts with this run's unique
/// `video_download_{ts}.` prefix (the same nanosecond-timestamp-as-
/// uniqueness-key idiom `convert.zig`/`transcribe.zig` use for their own
/// tmp paths) instead. Exactly one match is expected on a clean success —
/// `--no-playlist` above is what keeps that true. The trailing `.` in the
/// prefix keeps this from ever matching a `compressToFit` output
/// (`video_download_{ts}_compressed.mp4`, no `.` right after the number).
fn findDownloadedFile(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, ts: i96) ![]const u8 {
    const prefix = try std.fmt.allocPrint(allocator, "video_download_{d}.", .{ts});
    defer allocator.free(prefix);

    var dir = try Io.Dir.cwd().openDir(io, tmp_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, entry.name });
        }
    }
    return error.FileNotFound;
}

/// Runs `argv` with a hard wall-clock deadline `timeout_seconds_arg` from
/// now — the "new infrastructure" ROADMAP.md's Phase 25 entry calls out:
/// neither `convert.zig` nor `transcribe.zig` bounds its `std.process.run`
/// call at all, safe for them only because both shell out to a local
/// binary operating on a local file, never a caller-supplied remote URL.
///
/// This uses `std.process.run`'s own `timeout: Io.Timeout` option — a real
/// option this Zig version already exposes, not new plumbing built from
/// scratch. `run()`'s implementation (`lib/std/process.zig`) always
/// `defer child.kill(io)`s before returning, on every path including a
/// timeout error, so a fired timeout doesn't just abandon the subprocess:
/// it synchronously sends it `SIGTERM` and waits for it to be reaped
/// before this function returns, so no zombie is left behind.
///
/// **Must be a `.deadline`, not a `.duration`.** `run()` internally polls
/// the child's stdout/stderr in a loop and passes the same `Io.Timeout`
/// value to every poll; `yt-dlp` writes progress output steadily while a
/// download is in flight. A `.duration` timeout is recomputed as "now + N"
/// on every single poll (see `Io.Timeout.toTimestamp`), so as long as
/// *some* output keeps arriving it would never actually elapse — an idle
/// timeout in practice, not the firm execution cap this needs. Computing
/// one fixed `.deadline` up front, before the first poll, makes it a true
/// total-runtime cap regardless of how much output `yt-dlp` produces.
///
/// **Known limitation, not solved here**: `Child.kill` on this Zig version
/// only signals the direct child pid (`SIGTERM`, POSIX), not its process
/// group — there is no process-group-kill primitive exposed by `std.Io`/
/// `std.process` to reach for instead. If `yt-dlp` has already forked a
/// helper (commonly `ffmpeg`, to merge separately-fetched audio/video
/// streams) at the exact moment the deadline fires, that grandchild isn't
/// guaranteed to die with its parent and can briefly survive as an orphan
/// reparented to PID 1. Accepted as a real but minor gap: it only matters
/// during the narrow mid-merge window, the orphan is single-purpose and
/// self-terminating (ffmpeg exits on its own once done or once its input
/// pipe closes), and it is strictly better than the alternative this
/// function actually prevents — the `yt-dlp` process itself hanging
/// forever, unkilled, unreaped.
fn runWithTimeout(allocator: std.mem.Allocator, io: Io, argv: []const []const u8, timeout_seconds_arg: i64) std.process.RunError!std.process.RunResult {
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(timeout_seconds_arg), .clock = .awake });
    return std.process.run(allocator, io, .{ .argv = argv, .timeout = .{ .deadline = deadline } });
}

/// `pub` for the same reason `convert.zig`'s own `binaryAvailable` is —
/// callers outside this file (tests, and eventually `main.zig` if it ever
/// wants to warn rather than silently fail-closed on a missing binary) can
/// skip on the same terms rather than hard-failing wherever `yt-dlp` isn't
/// installed. Deliberately just re-exports `convert.binaryAvailable`
/// rather than duplicating its body — the check itself ("does running this
/// argv produce a normal exit") has nothing video-specific about it.
pub const binaryAvailable = convert.binaryAvailable;

const testing = std.testing;

test "findLink matches every trigger pattern and extracts the exact url" {
    try testing.expectEqualStrings(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        findLink("check this out https://www.youtube.com/watch?v=dQw4w9WgXcQ nice").?,
    );
    try testing.expectEqualStrings(
        "https://youtu.be/dQw4w9WgXcQ",
        findLink("https://youtu.be/dQw4w9WgXcQ").?,
    );
    try testing.expectEqualStrings(
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        findLink("https://www.youtube.com/shorts/dQw4w9WgXcQ").?,
    );
    try testing.expectEqualStrings(
        "https://www.instagram.com/reel/abc123/",
        findLink("look at this https://www.instagram.com/reel/abc123/").?,
    );
    try testing.expectEqualStrings(
        "https://www.instagram.com/p/abc123/",
        findLink("https://www.instagram.com/p/abc123/").?,
    );
    try testing.expectEqualStrings(
        "https://x.com/someuser/status/123456",
        findLink("https://x.com/someuser/status/123456").?,
    );
    try testing.expectEqualStrings(
        "https://twitter.com/someuser/status/123456",
        findLink("https://twitter.com/someuser/status/123456").?,
    );
}

test "findLink strips trailing sentence punctuation but not the url itself" {
    const found = findLink("check this out: https://youtu.be/abc123.") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("https://youtu.be/abc123", found);

    const parenthesized = findLink("(see https://youtu.be/abc123)") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("https://youtu.be/abc123", parenthesized);
}

test "findLink returns null for ordinary text and non-video links" {
    try testing.expectEqual(@as(?[]const u8, null), findLink("just chatting, nothing to see here"));
    try testing.expectEqual(@as(?[]const u8, null), findLink("check out https://example.com/article"));
    try testing.expectEqual(@as(?[]const u8, null), findLink("https://github.com/ziglang/zig"));
    try testing.expectEqual(@as(?[]const u8, null), findLink(""));
}

test "findLink picks the first matching token when a message has several links" {
    const found = findLink("first https://example.com/article then https://youtu.be/abc123 too") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("https://youtu.be/abc123", found);
}

test "runWithTimeout kills a subprocess that outlives its deadline, rather than waiting for it" {
    const a = testing.allocator;
    const io = testing.io;

    // Guard, same shape as convert.zig's own binary-presence checks: skip
    // rather than hard-fail if this environment somehow lacks `sleep`
    // (present via busybox/coreutils on essentially every POSIX box this
    // project runs or tests on).
    if (std.process.run(a, io, .{ .argv = &.{ "sleep", "0" } })) |r| {
        a.free(r.stdout);
        a.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) return error.SkipZigTest;
    } else |_| return error.SkipZigTest;

    const started = Io.Timestamp.now(io, .real);
    const result = runWithTimeout(a, io, &.{ "sleep", "5" }, 1);
    const elapsed_ms = @divTrunc(Io.Timestamp.now(io, .real).toNanoseconds() - started.toNanoseconds(), std.time.ns_per_ms);

    // The bound here (well under the 5s `sleep` would take if the timeout
    // didn't fire) is what actually proves the kill happened rather than
    // this test just passing by coincidentally waiting out the sleep.
    try testing.expect(elapsed_ms < 4000);
    if (result) |r| {
        a.free(r.stdout);
        a.free(r.stderr);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.Timeout, err);
    }
}

test "binaryAvailable reports false for a command that doesn't exist" {
    try testing.expect(!binaryAvailable(testing.allocator, testing.io, &.{"this-binary-does-not-exist-warden-test"}));
}

test "download fails closed rather than crashing when yt-dlp itself is unavailable or the link is bogus" {
    const a = testing.allocator;
    const io = testing.io;
    if (!binaryAvailable(a, io, &.{ "yt-dlp", "--version" })) return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    // Not a real video -- exercises the "yt-dlp ran, exited nonzero"
    // failure path without depending on any specific network condition
    // succeeding, only on it not silently fabricating a video from thin
    // air. Covers both quality modes through the same bogus URL.
    inline for (.{ Quality.lossless, Quality.lossy }) |quality| {
        const ts = Io.Timestamp.now(io, .real).toNanoseconds();
        const result = download(a, io, "data/tmp", "https://x.com/this_is_not_a_real_status_url_warden_test/status/1", quality, ts);
        if (result) |r| {
            a.free(r.bytes);
            a.free(r.file_name);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expect(err == error.DownloadFailed or err == error.DownloadTimedOut);
        }
    }
}

test "computeVideoBitrateKbps sizes a normal clip and fails closed on one too long for the budget" {
    // 10s clip, 5MB budget, 128kbps audio -- comfortably fits a real video
    // bitrate above the floor.
    const normal = computeVideoBitrateKbps(10.0, 5 * 1024 * 1024, 128) orelse return error.TestExpectedValue;
    try testing.expect(normal >= min_video_bitrate_kbps);

    // A 2-hour clip squeezed into the same 5MB budget can't fit a
    // watchable bitrate -- this is the "too long for lossy mode" signal
    // `compressToFit`/`downloadLossy` fail closed on.
    try testing.expectEqual(@as(?u32, null), computeVideoBitrateKbps(7200.0, 5 * 1024 * 1024, 128));
}

test "formatProgressText prefers a percent bar when both sizes are known, else elapsed time" {
    const a = testing.allocator;

    const percent_text = try formatProgressText(a, 42, 25, 100);
    defer a.free(percent_text);
    try testing.expectEqualStrings("⬇️ Downloading… 25%", percent_text);

    // Clamped at 99% so it never visually claims completion before the
    // real "done" message replaces it.
    const clamped_text = try formatProgressText(a, 42, 120, 100);
    defer a.free(clamped_text);
    try testing.expectEqualStrings("⬇️ Downloading… 99%", clamped_text);

    const elapsed_text = try formatProgressText(a, 17, null, null);
    defer a.free(elapsed_text);
    try testing.expectEqualStrings("⬇️ Downloading… (17s)", elapsed_text);

    // A current size with no estimate (the common Instagram/X case) also
    // falls back to elapsed time.
    const no_estimate_text = try formatProgressText(a, 5, 1000, null);
    defer a.free(no_estimate_text);
    try testing.expectEqualStrings("⬇️ Downloading… (5s)", no_estimate_text);
}

test "pollCurrentBytes finds the largest file matching this attempt's prefix and ignores others" {
    const io = testing.io;
    const a = testing.allocator;
    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();

    const small_path = try std.fmt.allocPrint(a, "data/tmp/video_download_{d}.part", .{ts});
    defer a.free(small_path);
    const large_path = try std.fmt.allocPrint(a, "data/tmp/video_download_{d}_compressed.mp4", .{ts});
    defer a.free(large_path);
    const unrelated_path = try std.fmt.allocPrint(a, "data/tmp/video_download_{d}.part", .{ts + 1});
    defer a.free(unrelated_path);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = small_path, .data = "ab" });
    defer Io.Dir.cwd().deleteFile(io, small_path) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = large_path, .data = "abcdefghij" });
    defer Io.Dir.cwd().deleteFile(io, large_path) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = unrelated_path, .data = "this file belongs to a different attempt and must be ignored" });
    defer Io.Dir.cwd().deleteFile(io, unrelated_path) catch {};

    try testing.expectEqual(@as(?u64, 10), pollCurrentBytes(io, "data/tmp", ts));
    try testing.expectEqual(@as(?u64, null), pollCurrentBytes(io, "data/tmp", ts + 999));
}

test "compressToFit shrinks a synthesized clip to fit a small budget" {
    const a = testing.allocator;
    const io = testing.io;
    if (!binaryAvailable(a, io, &.{ "ffmpeg", "-version" })) return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const input_path = try std.fmt.allocPrint(a, "data/tmp/video_download_test_input_{d}.mp4", .{ts});
    defer a.free(input_path);
    const output_path = try std.fmt.allocPrint(a, "data/tmp/video_download_test_output_{d}.mp4", .{ts});
    defer a.free(output_path);
    defer Io.Dir.cwd().deleteFile(io, input_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    // A real, tiny, deterministic local video -- no download required.
    const fixture = std.process.run(a, io, .{ .argv = &.{
        "ffmpeg", "-y", "-f",       "lavfi", "-i", "testsrc2=size=320x240:rate=15", "-f", "lavfi", "-i", "sine=frequency=440",
        "-t",     "2",  input_path,
    } }) catch return error.SkipZigTest;
    a.free(fixture.stdout);
    a.free(fixture.stderr);
    if (fixture.term != .exited or fixture.term.exited != 0) return error.SkipZigTest;

    const budget_bytes: u64 = 200 * 1024; // artificially small, forces real compression
    try compressToFit(a, io, input_path, output_path, budget_bytes);

    const stat = try Io.Dir.cwd().statFile(io, output_path, .{});
    try testing.expect(stat.size > 0);
    try testing.expect(stat.size <= budget_bytes * 3 / 2); // rate control isn't exact; generous slack
}
