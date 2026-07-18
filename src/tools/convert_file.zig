const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");
const convert = @import("../features/convert.zig");

const Args = struct { target_format: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "convert_file",
    .description = "Converts the file the user most recently sent (photo, document, voice note, audio, or video) to a different format and sends the result back to this chat. target_format is a bare extension like \"pdf\", \"png\", \"mp3\", \"txt\" — infer it from what the user asked for. Conversions stay within a family: image-to-image (jpg/png/webp/gif/bmp/tiff), audio/video-to-audio/video (mp3/wav/ogg/mp4/webm/...), and document-to-document (txt/md/html/docx/odt/rtf/pdf) — a pdf source can only become txt (extracted text), not another document format.",
    .input_schema_json =
    \\{"type":"object","properties":{"target_format":{"type":"string","description":"Bare extension to convert to, e.g. \"pdf\", \"png\", \"mp3\", \"txt\" (no leading dot needed)"}},"required":["target_format"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const connector = ctx.connector orelse return error.MissingToolContext;
    const chat_id = ctx.chat_id orelse return error.MissingToolContext;
    const tmp_dir = ctx.tmp_dir orelse return error.MissingToolContext;
    const attachment_path = ctx.attachment_path orelse
        return "No file attached to convert — send a photo, document, voice note, audio, or video first.";

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = convert.convert(ctx.allocator, ctx.io, tmp_dir, attachment_path, parsed.value.target_format) catch |err| {
        return switch (err) {
            error.UnsupportedTargetFormat => try std.fmt.allocPrint(ctx.allocator, "\"{s}\" isn't a format I can produce.", .{parsed.value.target_format}),
            error.UnsupportedConversion => "Can't convert between those two formats — crossing between image/document/audio-video families isn't supported, and a pdf source can only become txt.",
            error.ConversionFailed => "The conversion failed — the file may be corrupt, unsupported, or in an unexpected format.",
            else => return err,
        };
    };

    connector.sendDocument(ctx.allocator, chat_id, result.bytes, result.file_name, null);
    return std.fmt.allocPrint(ctx.allocator, "Converted to {s} and sent to the chat.", .{result.file_name});
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;
const Io = std.Io;
const iface = @import("../platform/interface.zig");

test "execute reports a clear message when there is no attachment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{
        .allocator = a,
        .io = testing.io,
        .connector = dummyConnector(),
        .chat_id = "1",
        .tmp_dir = "data/tmp",
    };
    const out = try execute(ctx, "{\"target_format\":\"png\"}");
    try testing.expect(std.mem.indexOf(u8, out, "No file attached") != null);
}

const FakeConnector = struct {
    sent_bytes: ?[]const u8 = null,
    sent_file_name: ?[]const u8 = null,

    fn connector(self: *FakeConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendDocument = sendDocumentFn,
    };
    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram;
    }
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }
    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to: ?[]const u8) void {
        _ = ptr;
        _ = allocator;
        _ = chat_id;
        _ = text;
        _ = reply_to;
    }
    fn sendDocumentFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        _ = allocator;
        _ = chat_id;
        _ = caption;
        const self: *FakeConnector = @ptrCast(@alignCast(ptr));
        self.sent_bytes = file_bytes;
        self.sent_file_name = file_name;
    }
};

fn dummyConnector() iface.Connector {
    const S = struct {
        var instance: FakeConnector = .{};
    };
    return S.instance.connector();
}

test "execute converts an available image and sends the result via sendDocument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    if (std.process.run(a, io, .{ .argv = &.{ "convert", "--version" } })) |r| {
        if (r.term != .exited or r.term.exited != 0) return error.SkipZigTest;
    } else |_| return error.SkipZigTest;

    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    const src_path = "data/tmp/convert_file_test_src.png";
    const gen = try std.process.run(a, io, .{ .argv = &.{ "convert", "-size", "4x4", "xc:blue", src_path } });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, gen.term);
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};

    var fake = FakeConnector{};
    const ctx = registry.ToolContext{
        .allocator = a,
        .io = io,
        .connector = fake.connector(),
        .chat_id = "1",
        .tmp_dir = "data/tmp",
        .attachment_path = src_path,
    };

    const out = try execute(ctx, "{\"target_format\":\"bmp\"}");
    try testing.expectEqualStrings("Converted to converted.bmp and sent to the chat.", out);
    try testing.expect(fake.sent_bytes.?.len > 0);
    try testing.expectEqualStrings("converted.bmp", fake.sent_file_name.?);
}
