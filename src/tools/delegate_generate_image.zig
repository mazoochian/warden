const std = @import("std");
const http = std.http;
const json = std.json;

const registry = @import("registry.zig");
const delegates_mod = @import("../llm/delegates.zig");
const http_util = @import("../http_util.zig");

const Args = struct {
    delegate: []const u8,
    prompt: []const u8,
    /// e.g. "1024x1024" — left to the delegate's own default when unset.
    size: ?[]const u8 = null,
};

const ImageDatum = struct {
    /// Set by backends that default to inline image bytes (e.g. OpenAI's
    /// gpt-image-1).
    b64_json: ?[]const u8 = null,
    /// Set by backends that default to a fetch-it-yourself URL instead
    /// (e.g. OpenAI's dall-e-2/dall-e-3) — fetched with a plain GET, no
    /// auth header, matching how these URLs are meant to be used (they're
    /// short-lived, pre-signed, and not the API host itself).
    url: ?[]const u8 = null,
};

const ImagesApiError = struct {
    message: []const u8 = "",
};

const ImagesResponse = struct {
    data: []ImageDatum = &.{},
    @"error": ?ImagesApiError = null,
};

pub const tool: registry.ToolDef = .{
    .name = "delegate_generate_image",
    .description = "Generates an image via a configured delegate model that supports image generation (e.g. ChatGPT/DALL-E) and sends it directly to this chat as a photo. Use this whenever an image needs to be generated — Warden has no image-generation model of its own. Write a detailed, specific prompt (you may expand on the user's request) for the best result.",
    .input_schema_json =
    \\{"type":"object","properties":{"delegate":{"type":"string","description":"Name of a configured delegate that supports image generation."},"prompt":{"type":"string","description":"Detailed image description. Expand on the user's request as needed for a good result."},"size":{"type":"string","description":"Optional image size/aspect, e.g. '1024x1024'. Defaults to the delegate's own default."}},"required":["delegate","prompt"]}
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
    const args = parsed.value;

    const delegate = delegates_mod.find(ctx.delegates, args.delegate) orelse {
        const available = try delegates_mod.describeImageCapable(ctx.allocator, ctx.delegates);
        return std.fmt.allocPrint(
            ctx.allocator,
            "No delegate named '{s}' is configured. Delegates that support image generation: {s}.",
            .{ args.delegate, available },
        );
    };
    const image = delegate.image orelse {
        const available = try delegates_mod.describeImageCapable(ctx.allocator, ctx.delegates);
        return std.fmt.allocPrint(
            ctx.allocator,
            "'{s}' doesn't support image generation. Delegates that do: {s}.",
            .{ delegate.name, available },
        );
    };

    if (args.prompt.len == 0) return "The image prompt can't be empty.";

    var payload_writer: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer payload_writer.deinit();
    {
        const w = &payload_writer.writer;
        try w.writeAll("{\"model\":");
        try json.Stringify.value(image.model, .{}, w);
        try w.writeAll(",\"prompt\":");
        try json.Stringify.value(args.prompt, .{}, w);
        if (args.size) |size| {
            try w.writeAll(",\"size\":");
            try json.Stringify.value(size, .{}, w);
        }
        try w.writeByte('}');
    }
    const payload = payload_writer.writer.buffered();

    const url = try std.fmt.allocPrint(ctx.allocator, "{s}/images/generations", .{image.base_url});
    defer ctx.allocator.free(url);

    var auth_header_buf: [8 + 255]u8 = undefined;
    var headers_buf: [1]http.Header = undefined;
    const headers: []const http.Header = if (image.api_key.len == 0) &.{} else blk: {
        const value = try std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{image.api_key});
        headers_buf[0] = .{ .name = "Authorization", .value = value };
        break :blk headers_buf[0..1];
    };

    var client: http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const body = try http_util.postJsonWithTimeout(&client, ctx.allocator, url, headers, payload, http_util.llm_timeout_ns);
    defer ctx.allocator.free(body);

    var response = json.parseFromSlice(
        ImagesResponse,
        ctx.allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.DelegateImageBadResponse;
    defer response.deinit();

    if (response.value.@"error") |api_err| {
        return std.fmt.allocPrint(ctx.allocator, "'{s}' failed to generate the image: {s}", .{ delegate.name, api_err.message });
    }
    if (response.value.data.len == 0) {
        return std.fmt.allocPrint(ctx.allocator, "'{s}' returned no image.", .{delegate.name});
    }
    const datum = response.value.data[0];

    const image_bytes: []const u8 = if (datum.b64_json) |b64| decode: {
        const len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.DelegateImageBadResponse;
        const decoded = try ctx.allocator.alloc(u8, len);
        std.base64.standard.Decoder.decode(decoded, b64) catch return error.DelegateImageBadResponse;
        break :decode decoded;
    } else if (datum.url) |image_url| fetch: {
        break :fetch try http_util.get(&client, ctx.allocator, image_url);
    } else {
        return std.fmt.allocPrint(ctx.allocator, "'{s}' returned no usable image data.", .{delegate.name});
    };
    defer ctx.allocator.free(image_bytes);

    connector.sendPhoto(ctx.allocator, chat_id, image_bytes, null);
    return std.fmt.allocPrint(ctx.allocator, "Image generated by '{s}' sent to the chat.", .{delegate.name});
}

const testing = std.testing;

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "execute without a connector/chat_id fails loudly rather than silently no-opping" {
    const ctx = registry.ToolContext{ .allocator = testing.allocator, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{\"delegate\":\"chatgpt\",\"prompt\":\"a cat\"}"));
}
