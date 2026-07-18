const std = @import("std");
const Io = std.Io;

/// Broad category a file extension falls into — determines which external
/// tool `convert` shells out to. `.document` also covers pdf, even though
/// pandoc itself can only ever *write* pdf (via an html+chromium detour,
/// see `convertDocument`) and can't read it at all (pdftotext is the only
/// supported pdf-as-source path).
pub const Family = enum { document, image, audio_video, unknown };

const document_exts = [_][]const u8{ ".txt", ".md", ".html", ".htm", ".docx", ".odt", ".rtf", ".pdf" };
const image_exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tiff" };
const av_exts = [_][]const u8{ ".mp3", ".wav", ".ogg", ".opus", ".flac", ".aac", ".m4a", ".mp4", ".webm", ".mov", ".mkv", ".avi" };

pub fn familyOfExt(ext: []const u8) Family {
    for (document_exts) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return .document;
    for (image_exts) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return .image;
    for (av_exts) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return .audio_video;
    return .unknown;
}

/// Extension including the leading dot, or "" if `path` has none. Doesn't
/// use `std.fs.path` to stay consistent with `main.zig`'s own hand-rolled
/// extension lookup for downloaded attachments (`extensionFor`).
pub fn extensionOf(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    if (dot == 0 or path[dot - 1] == '/') return "";
    return path[dot..];
}

pub const ConvertResult = struct {
    bytes: []const u8,
    file_name: []const u8,
};

pub const ConvertError = error{
    UnsupportedTargetFormat,
    UnsupportedConversion,
    ConversionFailed,
};

/// Converts the file at `input_path` to `target_format_raw` (a bare
/// extension like "pdf" or "png", leading dot optional), dispatching by
/// format family:
///   - image  -> image:        ImageMagick `convert`
///   - audio/video -> audio/video: `ffmpeg`
///   - document -> document:   `pandoc` (txt/md/html/docx/odt/rtf), with
///     pdf handled specially — pdf *output* goes through an html
///     intermediate + headless Chromium print-to-pdf (pandoc alone can't
///     produce pdf without pulling in a LaTeX engine); pdf *input* only
///     supports a txt target, via `pdftotext` (pandoc can't read pdf at
///     all).
/// Returns the converted file's bytes plus a suggested filename. All three
/// backends are external processes — `error.ConversionFailed` on a nonzero
/// exit, `error.UnsupportedConversion`/`UnsupportedTargetFormat` for
/// combinations this function doesn't attempt at all.
pub fn convert(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_dir: []const u8,
    input_path: []const u8,
    target_format_raw: []const u8,
) !ConvertResult {
    const target_format = try normalizeFormat(allocator, target_format_raw);
    defer allocator.free(target_format);
    const target_ext = try std.fmt.allocPrint(allocator, ".{s}", .{target_format});
    defer allocator.free(target_ext);

    const source_ext = extensionOf(input_path);
    const source_family = familyOfExt(source_ext);
    const target_family = familyOfExt(target_ext);

    try Io.Dir.cwd().createDirPath(io, tmp_dir);
    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const output_path = try std.fmt.allocPrint(allocator, "{s}/convert_{d}{s}", .{ tmp_dir, ts, target_ext });
    defer allocator.free(output_path);
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    switch (target_family) {
        .image => {
            if (source_family != .image) return error.UnsupportedConversion;
            try runProcess(allocator, io, &.{ "convert", input_path, output_path });
        },
        .audio_video => {
            if (source_family != .audio_video) return error.UnsupportedConversion;
            try runProcess(allocator, io, &.{ "ffmpeg", "-y", "-i", input_path, output_path });
        },
        .document => try convertDocument(allocator, io, tmp_dir, input_path, source_ext, source_family, target_format, output_path),
        .unknown => return error.UnsupportedTargetFormat,
    }

    const bytes = try Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(50 * 1024 * 1024));
    const file_name = try std.fmt.allocPrint(allocator, "converted{s}", .{target_ext});
    return .{ .bytes = bytes, .file_name = file_name };
}

fn convertDocument(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_dir: []const u8,
    input_path: []const u8,
    source_ext: []const u8,
    source_family: Family,
    target_format: []const u8,
    output_path: []const u8,
) !void {
    const source_is_pdf = std.ascii.eqlIgnoreCase(source_ext, ".pdf");

    if (std.mem.eql(u8, target_format, "pdf")) {
        if (source_is_pdf or source_family != .document) return error.UnsupportedConversion;

        const is_html = std.ascii.eqlIgnoreCase(source_ext, ".html") or std.ascii.eqlIgnoreCase(source_ext, ".htm");
        var generated_html: ?[]const u8 = null;
        defer if (generated_html) |p| {
            allocator.free(p);
            Io.Dir.cwd().deleteFile(io, p) catch {};
        };

        const html_path = if (is_html) input_path else blk: {
            const ts = Io.Timestamp.now(io, .real).toNanoseconds();
            const p = try std.fmt.allocPrint(allocator, "{s}/convert_{d}.html", .{ tmp_dir, ts });
            generated_html = p;
            try runProcess(allocator, io, &.{ "pandoc", input_path, "-o", p });
            break :blk p;
        };

        const print_flag = try std.fmt.allocPrint(allocator, "--print-to-pdf={s}", .{output_path});
        defer allocator.free(print_flag);
        try runProcess(allocator, io, &.{ "chromium-browser", "--headless", "--disable-gpu", "--no-sandbox", print_flag, html_path });
        return;
    }

    if (source_is_pdf) {
        // pandoc can't read pdf at all; pdftotext is the only supported
        // pdf-as-source path, and it only ever produces plain text.
        if (!std.mem.eql(u8, target_format, "txt")) return error.UnsupportedConversion;
        try runProcess(allocator, io, &.{ "pdftotext", input_path, output_path });
        return;
    }

    try runProcess(allocator, io, &.{ "pandoc", input_path, "-o", output_path });
}

fn normalizeFormat(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const without_dot = if (trimmed.len > 0 and trimmed[0] == '.') trimmed[1..] else trimmed;
    return std.ascii.allocLowerString(allocator, without_dot);
}

fn runProcess(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| {
        std.log.err("convert: failed to run '{s}': {t}", .{ argv[0], err });
        return error.ConversionFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("convert: '{s}' failed (term={any}): {s}", .{ argv[0], result.term, result.stderr });
        return error.ConversionFailed;
    }
}

const testing = std.testing;

test "familyOfExt classifies known extensions and defaults to unknown" {
    try testing.expectEqual(Family.document, familyOfExt(".txt"));
    try testing.expectEqual(Family.document, familyOfExt(".PDF"));
    try testing.expectEqual(Family.image, familyOfExt(".png"));
    try testing.expectEqual(Family.audio_video, familyOfExt(".mp3"));
    try testing.expectEqual(Family.unknown, familyOfExt(".exe"));
    try testing.expectEqual(Family.unknown, familyOfExt(""));
}

test "extensionOf finds the last dot, ignoring directory dots" {
    try testing.expectEqualStrings(".txt", extensionOf("/tmp/warden/attach_123.txt"));
    try testing.expectEqualStrings("", extensionOf("/tmp/.hidden/no_ext"));
    try testing.expectEqualStrings("", extensionOf("noext"));
}

test "normalizeFormat strips a leading dot and lowercases" {
    const a = testing.allocator;
    const r1 = try normalizeFormat(a, "PDF");
    defer a.free(r1);
    try testing.expectEqualStrings("pdf", r1);

    const r2 = try normalizeFormat(a, ".PNG");
    defer a.free(r2);
    try testing.expectEqualStrings("png", r2);
}

test "convert rejects a target format in an unrecognized family" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = convert(a, testing.io, "data/tmp", "/tmp/whatever.txt", "exe");
    try testing.expectError(error.UnsupportedTargetFormat, result);
}

test "convert rejects cross-family conversions (image source, audio target)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = convert(a, testing.io, "data/tmp", "/tmp/whatever.png", "mp3");
    try testing.expectError(error.UnsupportedConversion, result);
}

test "convert converts an image with ImageMagick" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    if (std.process.run(a, io, .{ .argv = &.{ "convert", "--version" } })) |r| {
        if (r.term != .exited or r.term.exited != 0) return error.SkipZigTest;
    } else |_| return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const src_path = "data/tmp/convert_test_src.png";
    try runProcess(a, io, &.{ "convert", "-size", "4x4", "xc:red", src_path });
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};

    const result = try convert(a, io, "data/tmp", src_path, "bmp");
    try testing.expect(result.bytes.len > 0);
    try testing.expectEqualStrings("converted.bmp", result.file_name);
}

test "convert rejects a pdf source targeting anything but txt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    if (std.process.run(a, io, .{ .argv = &.{ "pdftotext", "-v" } })) |r| {
        _ = r;
    } else |_| return error.SkipZigTest;

    const result = convert(a, io, "data/tmp", "/tmp/nonexistent_warden_test.pdf", "docx");
    try testing.expectError(error.UnsupportedConversion, result);
}

fn binaryAvailable(a: std.mem.Allocator, io: Io, argv: []const []const u8) bool {
    if (std.process.run(a, io, .{ .argv = argv })) |r| {
        return r.term == .exited;
    } else |_| return false;
}

test "convert converts markdown to html with pandoc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    if (!binaryAvailable(a, io, &.{ "pandoc", "--version" })) return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const src_path = "data/tmp/convert_test_doc.md";
    {
        var file = try Io.Dir.cwd().createFile(io, src_path, .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll("# Heading\n\nSome **bold** text.\n");
        try w.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};

    const result = try convert(a, io, "data/tmp", src_path, "html");
    try testing.expect(std.mem.indexOf(u8, result.bytes, "<h1") != null);
    try testing.expect(std.mem.indexOf(u8, result.bytes, "<strong>bold</strong>") != null);
    try testing.expectEqualStrings("converted.html", result.file_name);
}

test "convert renders markdown to pdf via pandoc + headless chromium" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    if (!binaryAvailable(a, io, &.{ "pandoc", "--version" })) return error.SkipZigTest;
    if (!binaryAvailable(a, io, &.{ "chromium-browser", "--version" })) return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const src_path = "data/tmp/convert_test_doc2.md";
    {
        var file = try Io.Dir.cwd().createFile(io, src_path, .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll("# Warden test\n\nHello from a converted document.\n");
        try w.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};

    const result = try convert(a, io, "data/tmp", src_path, "pdf");
    // "%PDF-" is the standard magic header every valid PDF starts with.
    try testing.expect(result.bytes.len > 4 and std.mem.eql(u8, result.bytes[0..5], "%PDF-"));
    try testing.expectEqualStrings("converted.pdf", result.file_name);
}

test "convert extracts real pdf text with pdftotext" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    if (!binaryAvailable(a, io, &.{ "pandoc", "--version" })) return error.SkipZigTest;
    if (!binaryAvailable(a, io, &.{ "chromium-browser", "--version" })) return error.SkipZigTest;
    if (!binaryAvailable(a, io, &.{ "pdftotext", "-v" })) return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const md_path = "data/tmp/convert_test_doc3.md";
    {
        var file = try Io.Dir.cwd().createFile(io, md_path, .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll("# Roundtrip\n\nUniqueMarkerXYZ123 should survive pdf extraction.\n");
        try w.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, md_path) catch {};

    const pdf_result = try convert(a, io, "data/tmp", md_path, "pdf");
    const pdf_path = "data/tmp/convert_test_doc3.pdf";
    {
        var file = try Io.Dir.cwd().createFile(io, pdf_path, .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll(pdf_result.bytes);
        try w.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, pdf_path) catch {};

    const txt_result = try convert(a, io, "data/tmp", pdf_path, "txt");
    try testing.expect(std.mem.indexOf(u8, txt_result.bytes, "UniqueMarkerXYZ123") != null);
    try testing.expectEqualStrings("converted.txt", txt_result.file_name);
}
