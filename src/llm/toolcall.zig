const std = @import("std");
const Io = std.Io;
const llm = @import("provider.zig");
const registry = @import("../tools/registry.zig");
const attachment_content = @import("attachment_content.zig");

/// Hard cap on model<->tool round trips per question, so a confused model
/// can't loop forever burning tokens.
const max_iterations = 6;

/// Headroom on top of a request's visible-answer budget for a reasoning
/// model's chain of thought. Without it, a small `max_tokens` is spent
/// entirely on thinking and the reply comes back empty.
pub const thinking_token_reserve: u32 = 4000;

/// Lets a caller observe what a `run` call is doing while it's in flight.
pub const Progress = struct {
    ptr: *anyopaque = undefined,
    onEvent: ?*const fn (ptr: *anyopaque, event: Event) void = null,
    /// Set by callers that support cooperative cancellation.
    cancelled: ?*const std.atomic.Value(bool) = null,

    pub const Event = union(enum) {
        /// About to send a request to the model (first turn or a follow-up
        /// after tool results).
        thinking,
        /// About to execute a tool the model asked for.
        tool_use: struct { name: []const u8, input_digest: u64 },
        /// Cumulative visible answer text generated so far *this turn* (not a delta).
        text: []const u8,
        /// A model call failed with something worth retrying and another attempt is
        /// about to be made after a backoff.
        retry: struct { attempt: u32, max: u32, err: anyerror },
    };

    pub fn report(self: Progress, event: Event) void {
        if (self.onEvent) |f| f(self.ptr, event);
    }

    pub fn isCancelled(self: Progress) bool {
        const flag = self.cancelled orelse return false;
        return flag.load(.acquire);
    }
};

/// Order-stable fingerprint of a tool call's arguments, for telling "the
/// model called web_search again.
fn hashToolInput(allocator: std.mem.Allocator, input: std.json.Value) u64 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    std.json.Stringify.value(input, .{}, &out.writer) catch return std.math.maxInt(u64);
    return std.hash.Wyhash.hash(0, out.writer.buffered());
}

/// Base backoff before the first retry; doubles each further attempt (1s, 2s,
/// 4s with the default of 3).
const retry_backoff_base_ms: u64 = 1000;

/// Whether a failed model call is worth trying again.
fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.HttpRequestFailed,
        error.RequestTimedOut,
        error.AnthropicApiError,
        error.OpenAiCompatApiError,
        error.OpenAiCompatEmptyResponse,
        => true,
        else => false,
    };
}

/// One model call, retried up to `max_retries` times on a transient failure
/// with exponential backoff.
fn callProviderWithRetry(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    io: Io,
    request: llm.ChatRequest,
    stream: bool,
    sink: llm.StreamSink,
    progress: Progress,
    max_retries: u32,
) !llm.ChatResponse {
    var attempt: u32 = 0;
    while (true) {
        if (progress.isCancelled()) return error.Cancelled;
        const attempted = if (stream)
            provider.chatStream(allocator, request, sink)
        else
            provider.chat(allocator, request);
        return attempted catch |err| {
            if (attempt >= max_retries or !isRetryable(err)) return err;
            attempt += 1;
            std.log.warn("model call failed ({t}), retrying {d}/{d}", .{ err, attempt, max_retries });
            progress.report(.{ .retry = .{ .attempt = attempt, .max = max_retries, .err = err } });
            const delay_ms: i64 = @intCast(retry_backoff_base_ms * (@as(u64, 1) << @intCast(attempt - 1)));
            // A failed sleep means the task is going away; surface the
            // original model error rather than the sleep's.
            Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch return err;
            continue;
        };
    }
}

/// One executed tool call, as `RunResult.tool_calls` reports it.
pub const ToolCallRecord = struct {
    name: []const u8,
    /// The arguments, JSON-serialised.
    input_json: []const u8,
    /// What the tool returned (or the `tool error: ...` text fed back to
    /// the model when it failed).
    result: []const u8,
    is_error: bool,
};

pub const RunResult = struct {
    /// The visible answer (thinking rendered in when `show_thinking`).
    text: []const u8,
    /// Every tool executed this run, in order.
    tool_calls: []const ToolCallRecord,
    /// The final model turn's stop reason.
    stop_reason: llm.StopReason,
};

/// How many times an empty final turn is answered with a nudge before the run
/// gives up and returns the empty text for the caller to handle.
const max_empty_nudges = 1;

/// Sent as a user turn when the model's final turn carried no visible text.
const empty_turn_nudge = "Your last turn had no visible reply text -- the user saw nothing. Reply now, in plain text, with your answer (or a one-line summary of what you just did with tools). Do not call any more tools.";
const empty_truncated_nudge = "Your last turn was cut off by the length limit before any visible reply text -- the user saw nothing. Reply now with a short, direct answer; keep any reasoning brief. Do not call any more tools.";

/// `run` for callers that only want the text -- see `runDetailed`.
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
    max_retries: u32,
) ![]const u8 {
    const result = try runDetailed(provider, allocator, ctx, system, user_message, tool_defs, progress, stream, show_thinking, vision_enabled, documents_enabled, max_tokens, max_retries);
    return result.text;
}

/// Drives one provider-agnostic conversation.
pub fn runDetailed(
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
    /// How many times a *transient* model-call failure is retried before the
    /// request gives up (see `callProviderWithRetry`).
    max_retries: u32,
) !RunResult {
    const llm_tools = try toLlmTools(allocator, tool_defs);
    var trace: std.ArrayList(ToolCallRecord) = .empty;
    var empty_nudges: u32 = 0;

    var messages: std.ArrayList(llm.ChatMessage) = .empty;
    // At most one attachment block.
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
    // `Progress`.
    var stream_bridge = ProgressStreamBridge{ .progress = progress };

    var i: u32 = 0;
    while (i < max_iterations) : (i += 1) {
        if (progress.isCancelled()) return error.Cancelled;
        progress.report(.thinking);
        const response = try callProviderWithRetry(provider, allocator, ctx.io, .{
            .system = system,
            .messages = messages.items,
            .tools = llm_tools,
            .show_thinking = show_thinking,
            .max_tokens = max_tokens,
        }, stream, stream_bridge.sink(), progress, max_retries);

        var tool_uses: std.ArrayList(llm.ToolUse) = .empty;
        for (response.content) |block| {
            switch (block) {
                .tool_use => |tu| try tool_uses.append(allocator, tu),
                .text, .thinking, .image, .document, .tool_result => {},
            }
        }

        if (tool_uses.items.len == 0) {
            const text = try renderText(allocator, response.content, show_thinking);
            if (std.mem.trim(u8, text, " \t\r\n").len > 0 or empty_nudges >= max_empty_nudges) {
                return .{ .text = text, .tool_calls = try trace.toOwnedSlice(allocator), .stop_reason = response.stop_reason };
            }
            // Nothing visible came back.
            empty_nudges += 1;
            std.log.warn("model turn had no visible text (stop={t}, thinking={d} bytes, tools so far={d}); nudging once", .{
                response.stop_reason, llm.thinkingLenOf(response.content), trace.items.len,
            });
            const nudge = if (response.stop_reason == .max_tokens) empty_truncated_nudge else empty_turn_nudge;
            try messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = nudge }}) });
            continue;
        }

        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        var results: std.ArrayList(llm.ContentBlock) = .empty;
        for (tool_uses.items) |tu| {
            if (progress.isCancelled()) return error.Cancelled;
            progress.report(.{ .tool_use = .{ .name = tu.name, .input_digest = hashToolInput(allocator, tu.input) } });
            var is_error = false;
            const result_text = executeTool(ctx, tool_defs, tu) catch |err| blk: {
                std.log.err("tool '{s}' failed: {t}", .{ tu.name, err });
                is_error = true;
                break :blk try std.fmt.allocPrint(allocator, "tool error: {t}", .{err});
            };
            const safe_text = try sanitizeUtf8(allocator, result_text);
            try results.append(allocator, .{ .tool_result = .{ .tool_use_id = tu.id, .content = safe_text } });
            try trace.append(allocator, .{
                .name = tu.name,
                .input_json = std.json.Stringify.valueAlloc(allocator, tu.input, .{}) catch "{}",
                .result = safe_text,
                .is_error = is_error,
            });
        }
        try messages.append(allocator, .{ .role = .user, .content = try results.toOwnedSlice(allocator) });
    }

    // Cap hit (usually a model flailing at tools that keep erroring).
    try messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(llm.ContentBlock, &.{
        .{ .text = "You have reached the tool-call limit. Do not call any more tools — give your final answer now using what you already have, and say plainly what you couldn't complete." },
    }) });
    const response = try callProviderWithRetry(provider, allocator, ctx.io, .{
        .system = system,
        .messages = messages.items,
        .tools = llm_tools,
        .show_thinking = show_thinking,
        .max_tokens = max_tokens,
    }, stream, stream_bridge.sink(), progress, max_retries);
    const text = try renderText(allocator, response.content, show_thinking);
    if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
        return .{ .text = text, .tool_calls = try trace.toOwnedSlice(allocator), .stop_reason = response.stop_reason };
    }
    return error.ToolCallLoopExceeded;
}

/// Per-call caps for `formatTrace` -- the trace is grounding for the model's
/// next turn, not a transcript.
const trace_args_max = 80;
const trace_result_max = 160;
const trace_total_max = 700;

/// Renders a run's tool calls as one compact line -- `name(args) -> result`
/// per call, `; `-separated, newlines flattened, each part capped.
pub fn formatTrace(allocator: std.mem.Allocator, tool_calls: []const ToolCallRecord) !?[]const u8 {
    if (tool_calls.len == 0) return null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (tool_calls, 0..) |tc, idx| {
        if (idx != 0) try buf.appendSlice(allocator, "; ");
        if (buf.items.len >= trace_total_max) {
            try buf.print(allocator, "+{d} more", .{tool_calls.len - idx});
            break;
        }
        try buf.appendSlice(allocator, tc.name);
        try buf.append(allocator, '(');
        try appendFlattened(&buf, allocator, tc.input_json, trace_args_max);
        try buf.appendSlice(allocator, if (tc.is_error) ") -> ERROR " else ") -> ");
        try appendFlattened(&buf, allocator, tc.result, trace_result_max);
    }
    return try buf.toOwnedSlice(allocator);
}

/// Appends `text` with runs of whitespace collapsed to one space, cut to
/// `max` bytes on a UTF-8 boundary with a trailing ellipsis when cut.
fn appendFlattened(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max: usize) !void {
    const start = buf.items.len;
    var last_space = false;
    for (text) |c| {
        const is_space = std.ascii.isWhitespace(c);
        if (is_space and last_space) continue;
        last_space = is_space;
        try buf.append(allocator, if (is_space) ' ' else c);
        if (buf.items.len - start > max) break;
    }
    if (buf.items.len - start > max) {
        var end = start + max;
        while (end > start and (buf.items[end] & 0xC0) == 0x80) end -= 1;
        buf.shrinkRetainingCapacity(end);
        try buf.appendSlice(allocator, "\u{2026}");
    }
}

/// The answer as the caller should see it.
fn renderText(allocator: std.mem.Allocator, content: []const llm.ContentBlock, show_thinking: bool) ![]const u8 {
    return if (show_thinking) llm.textWithThinkingOf(allocator, content) else llm.textOf(allocator, content);
}

/// Forwards `llm.StreamSink` reports into this loop's own `Progress` as
/// `.text` events.
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

/// Tool results can carry arbitrary bytes from external sources.
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

/// Stands in for a real provider.
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

    const result = try run(fake.provider(), a, ctx, "system", "what is 2+2?", &.{calculator.tool}, .{}, false, false, false, false, 1024, 0);
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

    const result = run(fake.provider(), a, ctx, "system", "what is 2+2?", &.{calculator.tool}, .{ .cancelled = &cancelled }, false, false, false, false, 1024, 0);
    try testing.expectError(error.Cancelled, result);
    try testing.expectEqual(@as(u32, 0), fake.call_count);
}

/// Implements `chatStream`, not just `chat`.
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

    const result = try run(fake.provider(), a, ctx, null, "hi", &.{}, progress, true, false, false, false, 1024, 0);
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

    const result = try run(fake.provider(), a, ctx, "system", "loop forever", &.{calculator.tool}, .{}, false, false, false, false, 1024, 0);
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

    const result = try run(fake.provider(), a, ctx, null, "hi", &.{}, .{}, false, false, false, false, 1024, 0);
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
    _ = try run(vision_on.provider(), a, ctx, null, "what's this?", &.{}, .{}, false, false, true, false, 1024, 0);
    try testing.expectEqual(@as(usize, 2), vision_on.seen_block_count);

    var vision_off = BlockCountingProvider{};
    _ = try run(vision_off.provider(), a, ctx, null, "what's this?", &.{}, .{}, false, false, false, false, 1024, 0);
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
    _ = try run(docs_on.provider(), a, ctx, null, "summarise", &.{}, .{}, false, false, false, true, 1024, 0);
    try testing.expectEqual(@as(usize, 2), docs_on.seen_block_count);
    try testing.expect(docs_on.saw_document);

    // documents off -> text only.
    var docs_off = BlockProbe{};
    _ = try run(docs_off.provider(), a, ctx, null, "summarise", &.{}, .{}, false, false, false, false, 1024, 0);
    try testing.expectEqual(@as(usize, 1), docs_off.seen_block_count);
    try testing.expect(!docs_off.saw_document);

    // The two flags are genuinely independent: an owner who enabled vision
    // for a model that can't read PDFs must not get one attached anyway.
    var vision_only = BlockProbe{};
    _ = try run(vision_only.provider(), a, ctx, null, "summarise", &.{}, .{}, false, false, true, false, 1024, 0);
    try testing.expectEqual(@as(usize, 1), vision_only.seen_block_count);
    try testing.expect(!vision_only.saw_document);
}

/// Fails its first `fail_times` calls with `err`, then succeeds — for
/// exercising `callProviderWithRetry` without a real endpoint.
const FlakyProvider = struct {
    call_count: u32 = 0,
    fail_times: u32,
    err: anyerror,

    fn provider(self: *FlakyProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        _ = request;
        const self: *FlakyProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        if (self.call_count <= self.fail_times) return self.err;
        return .{
            .content = try allocator.dupe(llm.ContentBlock, &.{.{ .text = "recovered" }}),
            .stop_reason = .end_turn,
        };
    }
};

/// Records every progress event, so a test can assert on what the user
/// would have been shown.
const RetryRecorder = struct {
    retries: std.ArrayList(struct { attempt: u32, max: u32 }) = .empty,
    allocator: std.mem.Allocator,

    fn progress(self: *RetryRecorder) Progress {
        return .{ .ptr = self, .onEvent = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: Progress.Event) void {
        const self: *RetryRecorder = @ptrCast(@alignCast(ptr));
        switch (event) {
            .retry => |r| self.retries.append(self.allocator, .{ .attempt = r.attempt, .max = r.max }) catch {},
            else => {},
        }
    }
};

test "run: a transient model failure is retried and reported, not surfaced as an error" {
    // The reported bug: one failed call ended the whole request with "Sorry, I
    // couldn't reach the model just now".
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var flaky = FlakyProvider{ .fail_times = 2, .err = error.RequestTimedOut };
    var recorder = RetryRecorder{ .allocator = a };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try run(flaky.provider(), a, ctx, null, "hi", &.{}, recorder.progress(), false, false, false, false, 1024, 3);
    try testing.expectEqualStrings("recovered", result);
    try testing.expectEqual(@as(u32, 3), flaky.call_count); // two failures, then success

    // ...and the user was told, rather than just watching a long pause.
    try testing.expectEqual(@as(usize, 2), recorder.retries.items.len);
    try testing.expectEqual(@as(u32, 1), recorder.retries.items[0].attempt);
    try testing.expectEqual(@as(u32, 3), recorder.retries.items[0].max);
    try testing.expectEqual(@as(u32, 2), recorder.retries.items[1].attempt);
}

test "run: retries are exhausted rather than infinite, and give up with the real error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var flaky = FlakyProvider{ .fail_times = 99, .err = error.RequestTimedOut };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    try testing.expectError(error.RequestTimedOut, run(flaky.provider(), a, ctx, null, "hi", &.{}, .{}, false, false, false, false, 1024, 2));
    // The initial attempt plus exactly two retries.
    try testing.expectEqual(@as(u32, 3), flaky.call_count);
}

test "run: a non-transient failure is not retried at all" {
    // Retrying a malformed request or a bad key just burns the same
    // failure again -- only transport/congestion failures are retryable.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var flaky = FlakyProvider{ .fail_times = 99, .err = error.SomethingUnretryable };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    try testing.expectError(error.SomethingUnretryable, run(flaky.provider(), a, ctx, null, "hi", &.{}, .{}, false, false, false, false, 1024, 3));
    try testing.expectEqual(@as(u32, 1), flaky.call_count);
}

/// Scripts a sequence of canned responses, one per model call, and records
/// every request it was given -- for the empty-turn recovery tests below.
const ScriptedProvider = struct {
    script: []const llm.ChatResponse,
    call_count: usize = 0,
    requests: std.ArrayList([]const llm.ChatMessage) = .empty,

    fn provider(self: *ScriptedProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn };

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        try self.requests.append(allocator, try allocator.dupe(llm.ChatMessage, request.messages));
        defer self.call_count += 1;
        return self.script[self.call_count];
    }
};

test "runDetailed: an empty final turn after a tool call is nudged once, and the nudge is what recovers the answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = try std.json.parseFromSlice(std.json.Value, a, "{\"expression\":\"2+2\"}", .{});
    var scripted = ScriptedProvider{
        .script = &.{
            .{ .content = &.{.{ .tool_use = .{ .id = "call_1", .name = "calculator", .input = input.value } }}, .stop_reason = .tool_use },
            // The MiniMax shape: thought about it, said nothing.
            .{ .content = &.{.{ .thinking = .{ .text = "the tool said 4", .field = .reasoning_content } }}, .stop_reason = .end_turn },
            .{ .content = &.{.{ .text = "It's 4." }}, .stop_reason = .end_turn },
        },
    };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try runDetailed(scripted.provider(), a, ctx, "system", "what is 2+2?", &.{calculator.tool}, .{}, false, false, false, false, 1024, 0);
    try testing.expectEqualStrings("It's 4.", result.text);
    try testing.expectEqual(@as(usize, 3), scripted.call_count);
    try testing.expectEqual(llm.StopReason.end_turn, result.stop_reason);

    // The trace reports the one tool that ran, with its arguments and result.
    try testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try testing.expectEqualStrings("calculator", result.tool_calls[0].name);
    try testing.expectEqualStrings("{\"expression\":\"2+2\"}", result.tool_calls[0].input_json);
    try testing.expectEqualStrings("4", result.tool_calls[0].result);
    try testing.expect(!result.tool_calls[0].is_error);

    // The third request ends with the nudge as a user turn, and the empty
    // assistant turn itself was not kept.
    const third = scripted.requests.items[2];
    const last = third[third.len - 1];
    try testing.expectEqual(llm.Role.user, last.role);
    try testing.expectEqualStrings(empty_turn_nudge, last.content[0].text);
    for (third) |m| {
        if (m.role == .assistant) try testing.expect(m.content[0] != .thinking);
    }
}

test "runDetailed: a turn cut off by max_tokens with no text gets the truncation nudge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scripted = ScriptedProvider{ .script = &.{
        .{ .content = &.{}, .stop_reason = .max_tokens },
        .{ .content = &.{.{ .text = "short answer" }}, .stop_reason = .end_turn },
    } };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try runDetailed(scripted.provider(), a, ctx, null, "q", &.{}, .{}, false, false, false, false, 64, 0);
    try testing.expectEqualStrings("short answer", result.text);
    const second = scripted.requests.items[1];
    try testing.expectEqualStrings(empty_truncated_nudge, second[second.len - 1].content[0].text);
}

test "runDetailed: a second empty turn is returned as empty text, not nudged forever" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scripted = ScriptedProvider{
        .script = &.{
            .{ .content = &.{.{ .text = "   \n" }}, .stop_reason = .end_turn },
            .{ .content = &.{}, .stop_reason = .end_turn },
            // Never reached.
            .{ .content = &.{.{ .text = "unexpected" }}, .stop_reason = .end_turn },
        },
    };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    const result = try runDetailed(scripted.provider(), a, ctx, null, "q", &.{}, .{}, false, false, false, false, 64, 0);
    try testing.expectEqual(@as(usize, 0), std.mem.trim(u8, result.text, " \t\r\n").len);
    try testing.expectEqual(@as(usize, 2), scripted.call_count);
    try testing.expectEqual(@as(usize, 0), result.tool_calls.len);
}

test "runDetailed renders thinking into the text only when show_thinking is on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const script = [_]llm.ChatResponse{
        .{ .content = &.{ .{ .thinking = .{ .text = "hmm", .field = .reasoning } }, .{ .text = "four" } }, .stop_reason = .end_turn },
    };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };

    var hidden = ScriptedProvider{ .script = &script };
    try testing.expectEqualStrings("four", (try runDetailed(hidden.provider(), a, ctx, null, "q", &.{}, .{}, false, false, false, false, 64, 0)).text);

    var shown = ScriptedProvider{ .script = &script };
    try testing.expectEqualStrings(llm.thinking_start ++ "hmm" ++ llm.thinking_end ++ "\n\nfour", (try runDetailed(shown.provider(), a, ctx, null, "q", &.{}, .{}, false, true, false, false, 64, 0)).text);
}

test "formatTrace renders one compact entry per call, flattens whitespace, caps long parts, and is null with no calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try formatTrace(a, &.{})) == null);

    const long_result = "x" ** 300;
    const trace = (try formatTrace(a, &.{
        .{ .name = "weather", .input_json = "{\"location\":\"Berlin\"}", .result = "Berlin:\n  12°C,\twind 3 m/s", .is_error = false },
        .{ .name = "fetch_url", .input_json = "{}", .result = long_result, .is_error = true },
    })).?;
    try testing.expect(std.mem.startsWith(u8, trace, "weather({\"location\":\"Berlin\"}) -> Berlin: 12°C, wind 3 m/s; fetch_url({}) -> ERROR xxx"));
    try testing.expect(std.mem.endsWith(u8, trace, "\u{2026}"));
    try testing.expect(trace.len < 300);
    try testing.expect(std.unicode.utf8ValidateSlice(trace));
}
