const std = @import("std");
const Io = std.Io;
const llm = @import("provider.zig");
const registry = @import("../tools/registry.zig");
const iface = @import("../platform/interface.zig");

/// Anthropic's real per-image cap; OpenAI's vision limit is comparable.
/// Oversized attachments fall back to text-only rather than failing the
/// whole Q&A call — see `imageBlockForAttachment`'s doc comment.
const max_image_bytes = 5 * 1024 * 1024;

/// Deliberately *not* Anthropic's own 32MB number: that limit is on the
/// whole request, while this caps one attachment's raw bytes before base64
/// expands them by 4/3 (a 24MB PDF is already ~32MB encoded, before the
/// system prompt, tool schemas, and conversation history that share the
/// same request). 16MB raw is ~21.3MB encoded, leaving real headroom for
/// the rest of the request. It also sits comfortably above Telegram's own
/// Bot-API download ceiling (20MB via `getFile`), so in practice this cap
/// rejects almost nothing that could actually have been fetched.
const max_document_bytes = 16 * 1024 * 1024;

const image_extensions = [_]struct { ext: []const u8, media_type: []const u8 }{
    .{ .ext = ".jpg", .media_type = "image/jpeg" },
    .{ .ext = ".jpeg", .media_type = "image/jpeg" },
    .{ .ext = ".png", .media_type = "image/png" },
    .{ .ext = ".gif", .media_type = "image/gif" },
    .{ .ext = ".webp", .media_type = "image/webp" },
};

/// `.document`-kind attachments (a file, not a Telegram "photo") need their
/// own image/not-image call: a real `image/*` mime type is authoritative
/// (returned as-is, so a provider gets the exact reported type rather than
/// a guess); with no mime at all, falls back to sniffing the filename's own
/// extension, same shape `main.zig`'s `extensionFor` already uses for
/// picking a download extension. A non-image mime (e.g. `application/pdf`)
/// is authoritative too — never overridden by a filename guess.
fn imageMediaTypeForDocument(ctx: registry.ToolContext) ?[]const u8 {
    if (ctx.attachment_mime) |mime| {
        return if (std.mem.startsWith(u8, mime, "image/")) mime else null;
    }
    const name = ctx.attachment_file_name orelse return null;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const ext = name[dot..];
    for (image_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(e.ext, ext)) return e.media_type;
    }
    return null;
}

/// Builds a base64 `llm.ContentBlock.image` for this message's attachment,
/// if it has one and it's an image — see `ROADMAP.md`'s Phase 10 for why
/// this exists (making the model actually see a photo instead of only ever
/// mechanically converting/transcribing it) and its "scope decision" note
/// on why PDFs/other documents aren't handled here.
///
/// Every failure path returns `null` rather than an error — a missing
/// attachment, an unreadable file, or one over `max_image_bytes` should
/// silently fall back to text-only, never fail the whole Q&A call over a
/// picture the model just won't get to see this time. Callers are expected
/// to gate this behind their own `vision_enabled` check (see
/// `llm/toolcall.zig`'s `run`) rather than this function knowing about that
/// config itself.
pub fn imageBlockForAttachment(ctx: registry.ToolContext) ?llm.ContentBlock {
    const path = ctx.attachment_path orelse return null;
    const kind = ctx.attachment_kind orelse return null;

    // Telegram never reports a `mime_type` for a `.photo` at all (see
    // `platform/telegram.zig`'s `attachmentFromMessage`) -- always JPEG for
    // the size warden picks, so this is a safe hardcode, not a guess.
    const media_type = switch (kind) {
        .photo => "image/jpeg",
        .document => imageMediaTypeForDocument(ctx) orelse return null,
        .voice, .audio, .video => return null,
    };

    const b64 = readBase64(ctx, path, max_image_bytes, "vision") orelse return null;
    return .{ .image = .{ .media_type = media_type, .base64_data = b64 } };
}

/// Reads `path` (capped at `max_bytes`) and base64-encodes it, or returns
/// `null` on any failure — shared by `imageBlockForAttachment` and
/// `documentBlockForAttachment`, which differ only in their cap and the
/// block they wrap the result in. `what` only labels the warning log.
///
/// Returning `null` rather than an error is the whole point: see
/// `imageBlockForAttachment`'s doc comment on why an unreadable or
/// oversized attachment must degrade to text-only instead of failing the
/// Q&A call around it.
fn readBase64(ctx: registry.ToolContext, path: []const u8, max_bytes: usize, what: []const u8) ?[]const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(max_bytes)) catch |err| {
        std.log.warn("attachment_content: couldn't read {s} for {s}: {t}", .{ path, what, err });
        return null;
    };
    defer ctx.allocator.free(bytes);

    const b64_buf = ctx.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len)) catch |err| {
        std.log.warn("attachment_content: couldn't allocate base64 buffer for {s}: {t}", .{ path, err });
        return null;
    };
    return std.base64.standard.Encoder.encode(b64_buf, bytes);
}

/// PDF is the only document type here, for the same reason ROADMAP.md's
/// Phase 10 deferred this in the first place: a native `document` block is
/// an Anthropic-specific wire shape, and PDF is the only media type it
/// accepts. Anything else a user sends as a `.document` (a .docx, a .zip)
/// stays on the existing `/convert`-and-transcribe path rather than being
/// handed to the model as opaque bytes it can't decode.
///
/// Mime-type-first, filename-fallback — deliberately the same precedence
/// `imageMediaTypeForDocument` above uses, since the inputs have the same
/// reliability: a real `application/pdf` is authoritative, and a missing
/// mime (which Telegram does sometimes send) falls back to the extension.
fn documentMediaTypeFor(ctx: registry.ToolContext) ?[]const u8 {
    if (ctx.attachment_mime) |mime| {
        return if (std.mem.eql(u8, mime, "application/pdf")) "application/pdf" else null;
    }
    const name = ctx.attachment_file_name orelse return null;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    return if (std.ascii.eqlIgnoreCase(".pdf", name[dot..])) "application/pdf" else null;
}

/// Builds a base64 `llm.ContentBlock.document` for this message's
/// attachment, if it has one and it's a PDF — the Phase 10 slice 2
/// counterpart to `imageBlockForAttachment`, letting the model read a PDF
/// natively (real layout/page understanding) instead of only ever
/// mechanically converting it.
///
/// Only `.document`-kind attachments qualify: a Telegram `.photo` is never
/// a PDF, and voice/audio/video have their own transcription path. Every
/// failure returns `null` for exactly the same reason the image path does
/// — a PDF the model won't see this turn must not fail the whole call.
///
/// Callers gate this on config themselves (see `llm/toolcall.zig`'s `run`),
/// same division of responsibility as `imageBlockForAttachment`.
pub fn documentBlockForAttachment(ctx: registry.ToolContext) ?llm.ContentBlock {
    const path = ctx.attachment_path orelse return null;
    const kind = ctx.attachment_kind orelse return null;
    if (kind != .document) return null;

    const media_type = documentMediaTypeFor(ctx) orelse return null;
    const b64 = readBase64(ctx, path, max_document_bytes, "documents") orelse return null;
    return .{ .document = .{ .media_type = media_type, .base64_data = b64 } };
}

const testing = std.testing;

fn writeTestFile(io: Io, path: []const u8, content: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer = file.writer(io, &.{});
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

test "imageBlockForAttachment: a photo is always an image, regardless of mime/filename" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_photo.bin";
    try writeTestFile(io, path, "fake jpeg bytes");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .photo,
    };
    const block = imageBlockForAttachment(ctx) orelse return error.TestExpectedValue;
    defer testing.allocator.free(block.image.base64_data);
    try testing.expectEqualStrings("image/jpeg", block.image.media_type);
}

test "imageBlockForAttachment: a document with an image mime type is an image" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_screenshot.bin";
    try writeTestFile(io, path, "fake png bytes");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_mime = "image/png",
    };
    const block = imageBlockForAttachment(ctx) orelse return error.TestExpectedValue;
    defer testing.allocator.free(block.image.base64_data);
    try testing.expectEqualStrings("image/png", block.image.media_type);
}

test "imageBlockForAttachment: a document with a non-image mime type (e.g. a PDF) is null" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_report.bin";
    try writeTestFile(io, path, "fake pdf bytes");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_mime = "application/pdf",
    };
    try testing.expectEqual(@as(?llm.ContentBlock, null), imageBlockForAttachment(ctx));
}

test "imageBlockForAttachment: a document with no mime falls back to sniffing the filename extension" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_picture.bin";
    try writeTestFile(io, path, "fake jpg bytes");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_file_name = "vacation.JPG",
    };
    const block = imageBlockForAttachment(ctx) orelse return error.TestExpectedValue;
    defer testing.allocator.free(block.image.base64_data);
    try testing.expectEqualStrings("image/jpeg", block.image.media_type);
}

test "imageBlockForAttachment: null for voice/audio/video, no attachment, or no attachment_kind" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_clip.bin";
    try writeTestFile(io, path, "fake bytes");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const base = registry.ToolContext{ .allocator = testing.allocator, .io = io, .attachment_path = path };
    try testing.expectEqual(@as(?llm.ContentBlock, null), imageBlockForAttachment(base));

    var voice_ctx = base;
    voice_ctx.attachment_kind = .voice;
    try testing.expectEqual(@as(?llm.ContentBlock, null), imageBlockForAttachment(voice_ctx));

    const no_path_ctx = registry.ToolContext{ .allocator = testing.allocator, .io = io, .attachment_kind = .photo };
    try testing.expectEqual(@as(?llm.ContentBlock, null), imageBlockForAttachment(no_path_ctx));
}

test "imageBlockForAttachment: an oversized file falls back to null instead of erroring" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_huge.bin";
    const oversized = try testing.allocator.alloc(u8, max_image_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try writeTestFile(io, path, oversized);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .photo,
    };
    try testing.expectEqual(@as(?llm.ContentBlock, null), imageBlockForAttachment(ctx));
}

test "documentBlockForAttachment: a document with application/pdf is a document block" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_report.pdf";
    try writeTestFile(io, path, "%PDF-1.7 fake");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_mime = "application/pdf",
    };
    const block = documentBlockForAttachment(ctx) orelse return error.TestExpectedValue;
    defer testing.allocator.free(block.document.base64_data);
    try testing.expectEqualStrings("application/pdf", block.document.media_type);
}

test "documentBlockForAttachment: no mime falls back to the .pdf extension, case-insensitively" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_nomime.pdf";
    try writeTestFile(io, path, "%PDF-1.7 fake");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_file_name = "Quarterly.PDF",
    };
    const block = documentBlockForAttachment(ctx) orelse return error.TestExpectedValue;
    defer testing.allocator.free(block.document.base64_data);
    try testing.expectEqualStrings("application/pdf", block.document.media_type);
}

test "documentBlockForAttachment: a real mime type wins over the filename, so a .pdf-named non-PDF is null" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_mismatch.bin";
    try writeTestFile(io, path, "PK fake zip");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_mime = "application/zip",
        .attachment_file_name = "definitely.pdf",
    };
    try testing.expectEqual(@as(?llm.ContentBlock, null), documentBlockForAttachment(ctx));
}

test "documentBlockForAttachment: non-PDF documents, photos, and voice are all null" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_notpdf.bin";
    try writeTestFile(io, path, "fake bytes");
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const base = registry.ToolContext{ .allocator = testing.allocator, .io = io, .attachment_path = path };

    // A .docx is a document, but not one the model can decode natively.
    var docx_ctx = base;
    docx_ctx.attachment_kind = .document;
    docx_ctx.attachment_mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    try testing.expectEqual(@as(?llm.ContentBlock, null), documentBlockForAttachment(docx_ctx));

    // A Telegram photo is never a PDF -- it must not take the document path
    // even though it has a readable file behind it.
    var photo_ctx = base;
    photo_ctx.attachment_kind = .photo;
    try testing.expectEqual(@as(?llm.ContentBlock, null), documentBlockForAttachment(photo_ctx));

    var voice_ctx = base;
    voice_ctx.attachment_kind = .voice;
    voice_ctx.attachment_mime = "application/pdf";
    try testing.expectEqual(@as(?llm.ContentBlock, null), documentBlockForAttachment(voice_ctx));
}

test "documentBlockForAttachment: an oversized PDF falls back to null instead of erroring" {
    const io = testing.io;
    const path = "data/tmp/attachment_content_test_huge.pdf";
    const oversized = try testing.allocator.alloc(u8, max_document_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try writeTestFile(io, path, oversized);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = testing.allocator,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_mime = "application/pdf",
    };
    try testing.expectEqual(@as(?llm.ContentBlock, null), documentBlockForAttachment(ctx));
}
