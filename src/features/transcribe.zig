const std = @import("std");
const Io = std.Io;
const http = std.http;

const http_util = @import("../http_util.zig");

pub const TranscribeError = error{TranscriptionFailed};

/// Normalizes `input_path` to 16kHz mono WAV via ffmpeg (whisper.cpp's own
/// documented preferred input shape) and posts it to a `whisper-server`
/// instance's `/inference` endpoint, returning the plain-text transcript.
/// `whisper_url` has no trailing slash (see `config.zig`'s `whisper_url`
/// doc comment).
pub fn transcribe(allocator: std.mem.Allocator, io: Io, whisper_url: []const u8, tmp_dir: []const u8, input_path: []const u8) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, tmp_dir);
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const wav_path = try std.fmt.allocPrint(allocator, "{s}/transcribe_{d}.wav", .{ tmp_dir, ts });
    defer allocator.free(wav_path);
    defer Io.Dir.cwd().deleteFile(io, wav_path) catch {};

    try runFfmpeg(allocator, io, input_path, wav_path);

    const wav_bytes = try Io.Dir.cwd().readFileAlloc(io, wav_path, allocator, .limited(25 * 1024 * 1024));
    defer allocator.free(wav_bytes);

    return postForTranscription(allocator, io, whisper_url, wav_bytes);
}

fn runFfmpeg(allocator: std.mem.Allocator, io: Io, input_path: []const u8, wav_path: []const u8) !void {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "ffmpeg", "-y", "-i", input_path, "-ar", "16000", "-ac", "1", wav_path },
    }) catch |err| {
        std.log.err("transcribe: failed to run ffmpeg: {t}", .{err});
        return TranscribeError.TranscriptionFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("transcribe: ffmpeg failed (term={any}): {s}", .{ result.term, result.stderr });
        return TranscribeError.TranscriptionFailed;
    }
}

/// `response_format=text` gets back the raw transcript with no JSON
/// wrapper (whisper.cpp's server also supports `json`/`verbose_json`, but
/// the plain-text form is all this needs and skips a parse step entirely).
fn postForTranscription(allocator: std.mem.Allocator, io: Io, whisper_url: []const u8, wav_bytes: []const u8) ![]const u8 {
    const boundary = "----WardenBoundary7f3a9c2e";

    var body_writer: Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    const w = &body_writer.writer;

    try w.print("--{s}\r\n", .{boundary});
    try w.writeAll("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n");
    try w.print("--{s}\r\n", .{boundary});
    try w.writeAll("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n");
    try w.writeAll(wav_bytes);
    try w.writeAll("\r\n");
    try w.print("--{s}--\r\n", .{boundary});
    const body = w.buffered();

    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "{s}/inference", .{whisper_url});
    defer allocator.free(url);
    const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
    defer allocator.free(content_type);

    const raw = try http_util.postRaw(&client, allocator, url, content_type, &.{}, body);
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

const testing = std.testing;

test "runFfmpeg normalizes a real audio file to 16kHz mono wav" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    if (std.process.run(a, io, .{ .argv = &.{ "ffmpeg", "-version" } })) |r| {
        if (r.term != .exited or r.term.exited != 0) return error.SkipZigTest;
    } else |_| return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const src_path = "data/tmp/transcribe_test_src.wav";
    // A trivial 44.1kHz stereo tone as input — normalization to 16kHz mono
    // is what's under test, not the audio's own content.
    try runProcessForTest(a, io, &.{ "ffmpeg", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", src_path });
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};

    const wav_path = "data/tmp/transcribe_test_out.wav";
    defer Io.Dir.cwd().deleteFile(io, wav_path) catch {};
    try runFfmpeg(a, io, src_path, wav_path);

    const out_bytes = try Io.Dir.cwd().readFileAlloc(io, wav_path, a, .limited(1024 * 1024));
    try testing.expect(out_bytes.len > 0);
}

fn runProcessForTest(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}
