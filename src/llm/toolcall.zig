const std = @import("std");
const Io = std.Io;
const llm = @import("provider.zig");
const registry = @import("../tools/registry.zig");
const attachment_content = @import("attachment_content.zig");

/// Hard cap on model<->tool round trips per question, so a confused model
/// can't loop forever burning tokens. Hitting it doesn't fail the request:
/// the model gets one final wrap-up turn (see end of `run`).
const max_iterations = 6;

/// Lets a caller observe what a `run` call is doing while it's in flight —
/// e.g. main.zig uses this to keep an animated "thinking"/"using X" chat
/// message up to date instead of the user staring at silence until the
/// whole tool-calling loop finishes. `ptr`/`onEvent` null (the default) is
/// a no-op, so existing callers don't need to change.
pub const Progress = struct {
    ptr: *anyopaque = undefined,
    onEvent: ?*const fn (ptr: *anyopaque, event: Event) void = null,
    /// Set by callers that support cooperative cancellation (main.zig's
    /// "🛑 Cancel" button on the thinking placeholder — see
    /// `features/cancel_request.zig`) — `run` below checks this at each
    /// loop-iteration boundary (before a new model call, before each tool
    /// execution) and bails out with `error.Cancelled` as soon as it sees
    /// it set. Deliberately *not* checked mid-flight inside a `chat`/
    /// `chatStream` call already underway: there's nothing here to abort
    /// that with (see `http_util.zig`'s own timeout-not-true-cancellation
    /// tradeoff for why) — a cancel pressed while a request is in flight
    /// takes effect only once that call returns. `null` (the default)
    /// means "not cancellable", same as `onEvent = null` meaning "no
    /// progress reporting".
    cancelled: ?*const std.atomic.Value(bool) = null,

    pub const Event = union(enum) {
        /// About to send a request to the model (first turn or a follow-up
        /// after tool results).
        thinking,
        /// About to execute a tool the model asked for.
        tool_use: []const u8,
        /// Cumulative visible answer text generated so far *this turn* (not
        /// a delta) — reported repeatedly as a streaming provider produces
        /// more of it; the last report for a given turn equals that turn's
        /// full text. Resets to a fresh, independent accumulation on the
        /// next turn (e.g. after a tool call), same as `tool_use` simply
        /// replacing whatever status was shown before it.
        text: []const u8,
    };

    pub fn report(self: Progress, event: Event) void {
        if (self.onEvent) |f| f(self.ptr, event);
    }

    pub fn isCancelled(self: Progress) bool {
        const flag = self.cancelled orelse return false;
        return flag.load(.acquire);
    }
};

/// Drives one provider-agnostic conversation: sends `user_message`, and as
/// long as the model keeps asking for tools, executes them against
/// `tool_defs` and feeds the results back, until it produces a final text
/// answer (or the iteration cap is hit). `stream` selects `chatStream`
/// (progressively reports `.text` events as the model generates, see
/// `ProgressStreamBridge`) vs. one blocking `chat` call per turn.
/// `show_thinking`/`max_tokens` are forwarded straight into every
/// `ChatRequest` — see `provider.zig`'s `ChatRequest.show_thinking` doc
/// comment and `qa.zig`'s `answerMaxTokens` for how callers compute them.
/// `vision_enabled`/`documents_enabled` gate whether `ctx`'s attachment
/// gets attached as real bytes to the first turn below — the former for
/// images, the latter for PDFs (see `llm/attachment_content.zig`). Neither
/// `imageBlockForAttachment` nor `documentBlockForAttachment` knows about
/// this config; callers are expected to check it first, same division of
/// responsibility as everywhere else config-gating happens above this
/// layer rather than inside it. They're separate flags because they're
/// separate capabilities: a model can support vision and still have no way
/// to read a PDF, which is exactly the case for the OpenAI-compatible
/// surface (see `llm/openai_compat.zig`'s `writeMessages`).
pub fn run(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    ctx: registry.ToolContext,
    system: ?[]const u8,
    user_message: []const u8,
    tool_defs: []const registry.ToolDef,
    progress: Progress,
    stream: bool,
    show_thinking: bool,
    vision_enabled: bool,
    documents_enabled: bool,
    max_tokens: u32,
) ![]const u8 {
    const llm_tools = try toLlmTools(allocator, tool_defs);

    var messages: std.ArrayList(llm.ChatMessage) = .empty;
    // At most one attachment block: a given message carries a single
    // attachment, and the two builders are mutually exclusive by
    // construction (an image's media type is never `application/pdf`).
    // Image is tried first only because it's the cheaper check.
    const attachment_block: ?llm.ContentBlock = blk: {
        if (vision_enabled) {
            if (attachment_content.imageBlockForAttachment(ctx)) |img| break :blk img;
        }
        if (documents_enabled) {
            if (attachment_content.documentBlockForAttachment(ctx)) |doc| break :blk doc;
        }
        break :blk null;
    };
    try messages.append(allocator, .{
        .role = .user,
        .content = if (attachment_block) |att|
            try allocator.dupe(llm.ContentBlock, &.{ .{ .text = user_message }, att })
        else
            try allocator.dupe(llm.ContentBlock, &.{.{ .text = user_message }}),
    });

    // Bridges the provider-layer `llm.StreamSink` into this loop's own
    // `Progress` — kept as one instance reused across every turn since it's
    // stateless (just forwards whatever `text_so_far` it's given); each
    // turn's own accumulation lives in the provider's `chatStream` call,
    // not here. Only actually used when `stream` is true.
    var stream_bridge = ProgressStreamBridge{ .progress = progress };

    var i: u32 = 0;
    while (i < max_iterations) : (i += 1) {
        if (progress.isCancelled()) return error.Cancelled;
        progress.report(.thinking);
        const response = if (stream)
            try provider.chatStream(allocator, .{
                .system = system,
                .messages = messages.items,
                .tools = llm_tools,
                .show_thinking = show_thinking,
                .max_tokens = max_tokens,
            }, stream_bridge.sink())
        else
            try provider.chat(allocator, .{
                .system = system,
                .messages = messages.items,
                .tools = llm_tools,
                .show_thinking = show_thinking,
                .max_tokens = max_tokens,
            });

        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        var tool_uses: std.ArrayList(llm.ToolUse) = .empty;
        for (response.content) |block| {
            switch (block) {
                .tool_use => |tu| try tool_uses.append(allocator, tu),
                .text, .image, .document, .tool_result => {},
            }
        }

        if (tool_uses.items.len == 0) {
            return llm.textOf(allocator, response.content);
        }

        var results: std.ArrayList(llm.ContentBlock) = .empty;
        for (tool_uses.items) |tu| {
            if (progress.isCancelled()) return error.Cancelled;
            progress.report(.{ .tool_use = tu.name });
            const result_text = executeTool(ctx, tool_defs, tu) catch |err| blk: {
                std.log.err("tool '{s}' failed: {t}", .{ tu.name, err });
                break :blk try std.fmt.allocPrint(allocator, "tool error: {t}", .{err});
            };
            const safe_text = try sanitizeUtf8(allocator, result_text);
            try results.append(allocator, .{ .tool_result = .{ .tool_use_id = tu.id, .content = safe_text } });
        }
        try messages.append(allocator, .{ .role = .user, .content = try results.toOwnedSlice(allocator) });
    }

    // Cap hit (usually a model flailing at tools that keep erroring). One
    // last call, told to wrap up, salvages whatever it has learned so far —
    // a partial answer beats surfacing an error after all that work. Tools
    // stay in the request (providers reject conversations containing
    // tool_use blocks without them) but any further calls are ignored.
    try messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(llm.ContentBlock, &.{
        .{ .text = "You have reached the tool-call limit. Do not call any more tools — give your final answer now using what you already have, and say plainly what you couldn't complete." },
    }) });
    const response = if (stream)
        try provider.chatStream(allocator, .{
            .system = system,
            .messages = messages.items,
            .tools = llm_tools,
            .show_thinking = show_thinking,
            .max_tokens = max_tokens,
        }, stream_bridge.sink())
    else
        try provider.chat(allocator, .{
            .system = system,
            .messages = messages.items,
            .tools = llm_tools,
            .show_thinking = show_thinking,
            .max_tokens = max_tokens,
        });
    const text = try llm.textOf(allocator, response.content);
    if (text.len > 0) return text;
    return error.ToolCallLoopExceeded;
}

/// Forwards `llm.StreamSink` reports into this loop's own `Progress` as
/// `.text` events — kept separate from `llm.StreamSink` itself since this
/// module (unlike `llm/provider.zig`) is allowed to depend on `Progress`.
const ProgressStreamBridge = struct {
    progress: Progress,

    fn sink(self: *ProgressStreamBridge) llm.StreamSink {
        return .{ .ptr = self, .onText = onText };
    }

    fn onText(ptr: *anyopaque, text_so_far: []const u8) void {
        const self: *ProgressStreamBridge = @ptrCast(@alignCast(ptr));
        self.progress.report(.{ .text = text_so_far });
    }
};

/// Tool results can carry arbitrary bytes from external sources — a
/// scraped page served in an unexpected encoding, a botched HTML-entity
/// decode — that aren't valid UTF-8. Zig's `json.Stringify` only emits a
/// `[]const u8` as a JSON string when it validates as UTF-8 (see
/// `std.json.Stringify.write`); otherwise it silently falls back to a raw
/// array of byte integers, which Anthropic's API then rejects outright
/// ("Input should be an object") — surfacing as a confusing 400 on the
/// *next* turn, far from whichever tool actually produced the bad bytes.
/// Replacing anything that doesn't decode cleanly with U+FFFD guarantees
/// every tool result is valid UTF-8 by the time it reaches the wire.
fn sanitizeUtf8(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;

    const replacement = "\u{FFFD}";
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.appendSlice(allocator, replacement);
            i += 1;
            continue;
        };
        const end = i + seq_len;
        if (end <= text.len and std.unicode.utf8ValidateSlice(text[i..end])) {
            try out.appendSlice(allocator, text[i..end]);
            i = end;
        } else {
            try out.appendSlice(allocator, replacement);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn executeTool(ctx: registry.ToolContext, tool_defs: []const registry.ToolDef, tu: llm.ToolUse) ![]const u8 {
    const def = registry.find(tool_defs, tu.name) orelse return error.UnknownTool;
    const input_json = try std.json.Stringify.valueAlloc(ctx.allocator, tu.input, .{});
    return def.execute(ctx, input_json);
}

fn toLlmTools(allocator: std.mem.Allocator, defs: []const registry.ToolDef) ![]const llm.Tool {
    var list: std.ArrayList(llm.Tool) = .empty;
    for (defs) |d| {
        try list.append(allocator, .{
            .name = d.name,
            .description = d.description,
            .input_schema_json = d.input_schema_json,
        });
    }
    return list.toOwnedSlice(allocator);
}

const testing = std.testing;
const calculator = @import("../tools/calculator.zig");

/// Stands in for a real provider: first turn asks for the calculator tool,
/// second turn checks the tool's result actually made it back into the
/// conversation before returning a final answer. Exercises the loop's
/// dispatch/threading logic with no network involved.
const FakeProvider = struct {
    call_count: u32 = 0,

    fn provider(self: *FakeProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;

        if (self.call_count == 1) {
            const input = try std.json.parseFromSlice(std.json.Value, allocator, "{\"expression\":\"2+2\"}", .{});
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{
                    .{ .tool_use = .{ .id = "call_1", .name = "calculator", .input = input.value } },
                }),
                .stop_reason = .tool_use,
            };
        }

        var saw_result = false;
        for (request.messages) |m| {
            for (m.content) |block| {
                if (block == .tool_result and std.mem.eql(u8, block.tool_result.tool_use_id, "call_1")) {
                    try testing.expectEqualStrings("4", block.tool_result.content);
                    saw_result = true;
                }
            }
        }
        try testing.expect(saw_result);

        return .{
            .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "The answer is 4." }}),
            .stop_reason = .end_turn,
        };
    }
};

test "run executes a tool call and threads its result back to the model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try run(fake.provider(), a, ctx, "system", "what is 2+2?", &.{calculator.tool}, .{}, false, false, false, false, 1024);
    try testing.expectEqualStrings("The answer is 4.", result);
    try testing.expectEqual(@as(u32, 2), fake.call_count);
}

test "run bails out with error.Cancelled instead of calling the model when already cancelled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    var cancelled = std.atomic.Value(bool).init(true);

    const result = run(fake.provider(), a, ctx, "system", "what is 2+2?", &.{calculator.tool}, .{ .cancelled = &cancelled }, false, false, false, false, 1024);
    try testing.expectError(error.Cancelled, result);
    try testing.expectEqual(@as(u32, 0), fake.call_count);
}

/// Implements `chatStream`, not just `chat` — used to confirm `run(...,
/// true)` actually calls the streaming path (and reports `.text` progress
/// events for the visible answer, not the tool-calling turn) rather than
/// silently falling back to `chat`.
const FakeStreamingProvider = struct {
    call_count: u32 = 0,

    fn provider(self: *FakeStreamingProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn, .chatStream = chatStreamFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        _ = ptr;
        _ = allocator;
        _ = request;
        return error.UnexpectedNonStreamingCall;
    }

    fn chatStreamFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest, sink: llm.StreamSink) anyerror!llm.ChatResponse {
        _ = request;
        const self: *FakeStreamingProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        sink.report("Hel");
        sink.report("Hello");
        return .{
            .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "Hello" }}),
            .stop_reason = .end_turn,
        };
    }
};

test "run(..., true) uses chatStream, reporting .text progress events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeStreamingProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    var reports: std.ArrayList([]const u8) = .empty;
    const Recorder = struct {
        fn onEvent(ptr: *anyopaque, event: Progress.Event) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ptr));
            switch (event) {
                .text => |t| list.append(std.testing.allocator, t) catch {},
                else => {},
            }
        }
    };
    defer reports.deinit(testing.allocator);
    const progress = Progress{ .ptr = &reports, .onEvent = Recorder.onEvent };

    const result = try run(fake.provider(), a, ctx, null, "hi", &.{}, progress, true, false, false, false, 1024);
    try testing.expectEqualStrings("Hello", result);
    try testing.expectEqual(@as(u32, 1), fake.call_count);
    try testing.expectEqual(@as(usize, 2), reports.items.len);
    try testing.expectEqualStrings("Hel", reports.items[0]);
    try testing.expectEqualStrings("Hello", reports.items[1]);
}

/// Requests the calculator on every turn until it sees the wrap-up nudge —
/// exercises the tool-call-limit path in `run`.
const InsatiableProvider = struct {
    call_count: u32 = 0,

    fn provider(self: *InsatiableProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *InsatiableProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;

        const last = request.messages[request.messages.len - 1];
        if (last.content.len == 1 and last.content[0] == .text and
            std.mem.indexOf(u8, last.content[0].text, "tool-call limit") != null)
        {
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "best effort answer" }}),
                .stop_reason = .end_turn,
            };
        }

        const input = try std.json.parseFromSlice(std.json.Value, allocator, "{\"expression\":\"1+1\"}", .{});
        const id = try std.fmt.allocPrint(allocator, "call_{d}", .{self.call_count});
        return .{
            .content = try allocator.dupe(llm.ContentBlock, &.{
                .{ .tool_use = .{ .id = id, .name = "calculator", .input = input.value } },
            }),
            .stop_reason = .tool_use,
        };
    }
};

test "run salvages a final answer when the tool-call cap is hit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = InsatiableProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try run(fake.provider(), a, ctx, "system", "loop forever", &.{calculator.tool}, .{}, false, false, false, false, 1024);
    try testing.expectEqualStrings("best effort answer", result);
    // max_iterations tool turns plus the final wrap-up call.
    try testing.expectEqual(@as(u32, 7), fake.call_count);
}

test "run returns the model's answer directly when it never calls a tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NoToolProvider = struct {
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = request;
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "no tools needed" }}),
                .stop_reason = .end_turn,
            };
        }
    };
    var fake = NoToolProvider{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try run(fake.provider(), a, ctx, null, "hi", &.{}, .{}, false, false, false, false, 1024);
    try testing.expectEqualStrings("no tools needed", result);
}

test "run attaches an image block to the first message when vision_enabled and the attachment is an image, but not when vision_enabled is false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    const path = "data/tmp/toolcall_test_photo.bin";
    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    {
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll("fake jpeg bytes");
        try w.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{ .allocator = a, .io = io, .attachment_path = path, .attachment_kind = .photo };

    const BlockCountingProvider = struct {
        seen_block_count: usize = 0,
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.seen_block_count = request.messages[0].content.len;
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "ok" }}),
                .stop_reason = .end_turn,
            };
        }
    };

    var vision_on = BlockCountingProvider{};
    _ = try run(vision_on.provider(), a, ctx, null, "what's this?", &.{}, .{}, false, false, true, false, 1024);
    try testing.expectEqual(@as(usize, 2), vision_on.seen_block_count);

    var vision_off = BlockCountingProvider{};
    _ = try run(vision_off.provider(), a, ctx, null, "what's this?", &.{}, .{}, false, false, false, false, 1024);
    try testing.expectEqual(@as(usize, 1), vision_off.seen_block_count);
}

test "sanitizeUtf8 passes valid UTF-8 through untouched" {
    const a = testing.allocator;
    const out = try sanitizeUtf8(a, "=== \u{0635}\u{0641}\u{062d}\u{0647} ===");
    try testing.expectEqualStrings("=== \u{0635}\u{0641}\u{062d}\u{0647} ===", out);
}

test "sanitizeUtf8 replaces invalid bytes with U+FFFD instead of corrupting the string" {
    const a = testing.allocator;
    const bad = "=== \xd8\x00 broken ===";
    const out = try sanitizeUtf8(a, bad);
    defer a.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.indexOf(u8, out, "\u{FFFD}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "broken") != null);
}

test "run attaches a document block only when documents_enabled -- vision_enabled alone never pulls in a PDF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    const path = "data/tmp/toolcall_test_doc.pdf";
    try Io.Dir.cwd().createDirPath(io, "data/tmp");
    {
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll("%PDF-1.7 fake");
        try w.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const ctx = registry.ToolContext{
        .allocator = a,
        .io = io,
        .attachment_path = path,
        .attachment_kind = .document,
        .attachment_mime = "application/pdf",
    };

    const BlockProbe = struct {
        seen_block_count: usize = 0,
        saw_document: bool = false,
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.seen_block_count = request.messages[0].content.len;
            for (request.messages[0].content) |b| {
                if (b == .document) self.saw_document = true;
            }
            return .{
                .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "ok" }}),
                .stop_reason = .end_turn,
            };
        }
    };

    // documents on -> the PDF rides along as a real document block.
    var docs_on = BlockProbe{};
    _ = try run(docs_on.provider(), a, ctx, null, "summarise", &.{}, .{}, false, false, false, true, 1024);
    try testing.expectEqual(@as(usize, 2), docs_on.seen_block_count);
    try testing.expect(docs_on.saw_document);

    // documents off -> text only.
    var docs_off = BlockProbe{};
    _ = try run(docs_off.provider(), a, ctx, null, "summarise", &.{}, .{}, false, false, false, false, 1024);
    try testing.expectEqual(@as(usize, 1), docs_off.seen_block_count);
    try testing.expect(!docs_off.saw_document);

    // The two flags are genuinely independent: an owner who enabled vision
    // for a model that can't read PDFs must not get one attached anyway.
    var vision_only = BlockProbe{};
    _ = try run(vision_only.provider(), a, ctx, null, "summarise", &.{}, .{}, false, false, true, false, 1024);
    try testing.expectEqual(@as(usize, 1), vision_only.seen_block_count);
    try testing.expect(!vision_only.saw_document);
}
