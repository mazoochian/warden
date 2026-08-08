//! ROADMAP.md's Phase 25: passive auto-download of YouTube/Instagram/X
//! video links posted in a chat, reposted as a document via the connector's
//! `sendDocument` vtable slot. Two independent pieces live here, both
//! deliberately free of any `Connector`/store dependency (same "pure
//! function over bytes/paths" shape as `convert.zig`/`transcribe.zig` —
//! `main.zig`'s `checkVideoDownload`/`videoDownloadWorker` own the gating,
//! threading and connector calls):
//!
//!   - `findLink`: a plain substring scan over a message's text, no LLM
//!     call, same "passive content observation" tier as
//!     `main.zig`'s `checkKeywordAlerts`.
//!   - `download`: shells out to `yt-dlp`, same argv/tmpdir/`defer
//!     deleteFile`/`readFileAlloc(.limited(...))` idiom
//!     `convert.zig`/`transcribe.zig` already use for their own external
//!     tools, plus one thing neither of those has: a hard wall-clock
//!     timeout (`timeout_seconds` below) — see `runWithTimeout`'s doc
//!     comment for why `yt-dlp` specifically needs one and how it's
//!     enforced.
//!
//! **Failure handling is fail-closed by design**: age-restricted, private,
//! geo-blocked, DRM'd, oversized, or otherwise undownloadable links are
//! never surfaced as an in-chat error — `download` just returns an error,
//! `main.zig`'s caller logs it and does nothing visible, exactly the
//! "never block the reply on failure" philosophy `transcribe.zig`'s own
//! caller (`resolveQuestion`) already follows for a failed transcription.
//! A chat with this feature on posts a lot of ordinary links that are not
//! videos at all (a news article, a github repo) — erroring loudly on
//! every one of those would be far worse than silently doing nothing.
const std = @import("std");
const Io = std.Io;

const convert = @import("convert.zig");

/// Telegram's cloud Bot API's real upload ceiling — this codebase talks
/// directly to `api.telegram.org` with no local Bot API server (which would
/// raise the limit to 2GB but needs its own separate service this project
/// doesn't run — see ROADMAP.md's Phase 25 entry for why that's flagged as
/// a possible future backlog item, not solved here). Passed straight to
/// `yt-dlp --max-filesize` so an oversized video is never downloaded in the
/// first place, not downloaded-then-rejected.
const max_bytes: usize = 50 * 1024 * 1024;

/// How long `yt-dlp` gets before `download` gives up and kills it — see
/// `runWithTimeout`'s doc comment. `yt-dlp` is network-bound against an
/// arbitrary remote server (unlike the local `ffmpeg`/`pandoc`/`convert`
/// binaries `convert.zig` shells out to), so it can hang far longer than
/// any of those ever would; 2 minutes comfortably covers a real short-clip
/// download while still failing closed well within a human's patience for
/// "did my link do anything."
const timeout_seconds: i64 = 120;

/// Substrings identifying a link this module will attempt to download —
/// deliberately conservative and literal (no real regex engine in `std`),
/// equivalent to the plan's own
/// `(youtube\.com/watch|youtu\.be/|instagram\.com/(reel|p)/|x\.com/|twitter\.com/)`.
/// Case-sensitive on purpose: real URLs use lowercase domains, and a
/// hand-rolled case-insensitive substring search isn't worth the extra
/// code for a fail-closed feature where a missed match just means no
/// download, not a functional gap.
const trigger_patterns = [_][]const u8{
    "youtube.com/watch",
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
pub const DownloadError = error{ DownloadFailed, DownloadTimedOut };

/// Downloads the video at `url` via `yt-dlp` into `tmp_dir`, returning its
/// bytes (capped at `max_bytes`, same `readFileAlloc(.limited(...))` idiom
/// `convert.zig` uses) plus a suggested filename. Fails closed on anything
/// that isn't a clean success — nonzero exit, a timeout, or the output file
/// simply not existing afterward — never partial/garbage bytes.
///
/// `--no-playlist` is the one argv addition beyond the plan's literal
/// `yt-dlp -o ... --max-filesize 50M <url>`: without it, a
/// `youtube.com/watch?v=...&list=...` link (a video that's also part of a
/// playlist — common in practice) would have `yt-dlp` fetch the *entire*
/// playlist into `tmp_dir`, breaking `findDownloadedFile`'s single-file
/// assumption below and turning one chat link into an unbounded, far-past-
/// `timeout_seconds` download. Restricting to the one linked video is what
/// "someone posted a video link" means here, not "someone posted a
/// playlist link."
pub fn download(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, url: []const u8) !DownloadResult {
    try Io.Dir.cwd().createDirPath(io, tmp_dir);
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
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
    }, timeout_seconds) catch |err| {
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

/// `yt-dlp` resolves `%(ext)s` itself (mp4/webm/mkv/... depending on what
/// it actually fetched), so the real output filename isn't knowable ahead
/// of time the way `convert.zig`'s fixed-extension output path is — this
/// scans `tmp_dir` for whichever file starts with this run's unique
/// `video_download_{ts}.` prefix (the same nanosecond-timestamp-as-
/// uniqueness-key idiom `convert.zig`/`transcribe.zig` use for their own
/// tmp paths) instead. Exactly one match is expected on a clean success —
/// `--no-playlist` above is what keeps that true.
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
    // air.
    const result = download(a, io, "data/tmp", "https://x.com/this_is_not_a_real_status_url_warden_test/status/1");
    if (result) |r| {
        a.free(r.bytes);
        a.free(r.file_name);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.DownloadFailed or err == error.DownloadTimedOut);
    }
}
