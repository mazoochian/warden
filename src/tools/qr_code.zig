const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const http_util = @import("../http_util.zig");

const Args = struct { data: []const u8 };

/// qrserver.com rejects overly long payloads; QR codes past this density
/// are unscannable from a phone screen anyway.
const max_data_len = 900;

pub const tool: registry.ToolDef = .{
    .name = "qr_code",
    .description = "Generates a QR code image for any text — a URL, WiFi credentials, contact info, plain text — and sends it directly to this chat as a photo. Use when someone asks for a QR code or wants to share something scannable.",
    .input_schema_json =
        \\{"type":"object","properties":{"data":{"type":"string","description":"The text or URL to encode in the QR code"}},"required":["data"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const connector = ctx.connector orelse return error.MissingToolContext;
    const chat_id = ctx.chat_id orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    if (parsed.value.data.len == 0) return error.EmptyQrData;
    if (parsed.value.data.len > max_data_len) {
        return std.fmt.allocPrint(
            ctx.allocator,
            "That's too much data for a scannable QR code ({d} bytes, max {d}).",
            .{ parsed.value.data.len, max_data_len },
        );
    }

    const encoded = try http_util.encodeQueryComponent(ctx.allocator, parsed.value.data);
    defer ctx.allocator.free(encoded);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://api.qrserver.com/v1/create-qr-code/?size=400x400&format=png&data={s}",
        .{encoded},
    );
    defer ctx.allocator.free(url);

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const png = try http_util.get(&client, ctx.allocator, url);
    defer ctx.allocator.free(png);

    connector.sendPhoto(ctx.allocator, chat_id, png, null);
    return "QR code sent to the chat.";
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
