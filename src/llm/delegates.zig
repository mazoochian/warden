const std = @import("std");
const llm = @import("provider.zig");

/// One configured "ask another model" target, built once at startup (see
/// `main.zig`'s delegate construction) from a `config.DelegateConfig` — kept
/// as its own type here rather than reusing `config.DelegateConfig` directly
/// since this one carries a real, callable `llm.Provider`, not just the raw
/// credentials that produced it. Plain data, not another ptr+vtable `Sink`
/// like `tools/registry.zig`'s `ReminderSink`/etc: the only "backend" a
/// delegate needs is already the vtable-based `llm.Provider` from this same
/// package, so there's no store-layer dependency to hide behind an extra
/// indirection.
pub const Delegate = struct {
    /// Matched case-insensitively against the `delegate` tool argument —
    /// see `find` below.
    name: []const u8,
    /// Shown to the delegating model alongside `name` so it can pick the
    /// right target for a given task, e.g. "OpenAI's GPT-4o — strong at
    /// code and general reasoning." May be empty.
    description: []const u8,
    provider: llm.Provider,
    /// Non-null only when this delegate should also be offered for
    /// `tools/delegate_generate_image.zig` — see `ImageConfig`'s own doc
    /// comment.
    image: ?ImageConfig = null,

    /// What `delegate_generate_image` needs to call an OpenAI-compatible
    /// `/images/generations` endpoint directly — separate from `provider`
    /// since that's a `chat/completions` client and image generation is a
    /// different endpoint entirely, not something `llm.Provider`'s
    /// chat-shaped interface can express.
    pub const ImageConfig = struct {
        /// No trailing slash — `{base_url}/images/generations` is appended
        /// directly.
        base_url: []const u8,
        api_key: []const u8,
        model: []const u8,
    };
};

/// Case-insensitive lookup by `Delegate.name` — the delegating model may
/// send the name in any casing.
pub fn find(delegates: []const Delegate, name: []const u8) ?Delegate {
    for (delegates) |d| {
        if (std.ascii.eqlIgnoreCase(d.name, name)) return d;
    }
    return null;
}

/// Renders every configured delegate as a "name (description), ..." list —
/// used by `ask_delegate`'s "no such delegate" tool result so the calling
/// model can see what's actually available and retry with a valid name,
/// instead of just failing.
pub fn describeAll(allocator: std.mem.Allocator, delegates: []const Delegate) ![]const u8 {
    if (delegates.len == 0) return allocator.dupe(u8, "none configured");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    for (delegates, 0..) |d, i| {
        if (i > 0) try w.writeAll(", ");
        if (d.description.len > 0) {
            try w.print("{s} ({s})", .{ d.name, d.description });
        } else {
            try w.writeAll(d.name);
        }
    }
    return allocator.dupe(u8, buf.writer.buffered());
}

/// Same shape as `describeAll`, but only the delegates with `image` set —
/// used by `delegate_generate_image`'s "no such image-capable delegate"
/// tool result.
pub fn describeImageCapable(allocator: std.mem.Allocator, delegates: []const Delegate) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    var n: usize = 0;
    for (delegates) |d| {
        if (d.image == null) continue;
        if (n > 0) try w.writeAll(", ");
        if (d.description.len > 0) {
            try w.print("{s} ({s})", .{ d.name, d.description });
        } else {
            try w.writeAll(d.name);
        }
        n += 1;
    }
    if (n == 0) return allocator.dupe(u8, "none configured");
    return allocator.dupe(u8, buf.writer.buffered());
}

const testing = std.testing;

fn testProvider() llm.Provider {
    const S = struct {
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = allocator;
            _ = request;
            return .{ .content = &.{}, .stop_reason = .end_turn };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
    };
    return .{ .ptr = undefined, .vtable = &S.vt };
}

test "find matches case-insensitively and reports a miss as null" {
    const delegates = [_]Delegate{
        .{ .name = "ChatGPT", .description = "", .provider = testProvider() },
    };
    try testing.expect(find(&delegates, "chatgpt") != null);
    try testing.expect(find(&delegates, "CHATGPT") != null);
    try testing.expect(find(&delegates, "claude") == null);
}

test "describeAll lists every delegate with its description, and reports none configured" {
    const a = testing.allocator;

    const empty_text = try describeAll(a, &.{});
    defer a.free(empty_text);
    try testing.expectEqualStrings("none configured", empty_text);

    const delegates = [_]Delegate{
        .{ .name = "chatgpt", .description = "strong at code", .provider = testProvider() },
        .{ .name = "local", .description = "", .provider = testProvider() },
    };
    const text = try describeAll(a, &delegates);
    defer a.free(text);
    try testing.expectEqualStrings("chatgpt (strong at code), local", text);
}

test "describeImageCapable only lists delegates with an image config" {
    const a = testing.allocator;

    const delegates = [_]Delegate{
        .{ .name = "chatgpt", .description = "", .provider = testProvider(), .image = .{ .base_url = "https://api.openai.com/v1", .api_key = "", .model = "gpt-image-1" } },
        .{ .name = "claude", .description = "", .provider = testProvider() },
    };
    const text = try describeImageCapable(a, &delegates);
    defer a.free(text);
    try testing.expectEqualStrings("chatgpt", text);

    const none_text = try describeImageCapable(a, delegates[1..]);
    defer a.free(none_text);
    try testing.expectEqualStrings("none configured", none_text);
}
