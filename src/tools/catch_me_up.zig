const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const default_hours: i64 = 24;
// 2 weeks -- a hard ceiling so a careless "catch me up on everything" doesn't
// pull an unbounded amount of history into the model's context.
const max_hours: i64 = 24 * 14;

const Args = struct {
    hours: ?i64 = null,
};

/// ROADMAP.md's Phase 14 ("messaging assistance modes") -- lets the user
/// ask "catch me up" / "what did I miss" and get an answer grounded in this
/// chat's own logged history, without waiting for a scheduled `/digest`.
/// Deliberately returns raw "who: text" lines for the model to summarize
/// itself, the same "we just fetch, the model summarizes" shape
/// `fetch_url`'s own doc comment already established -- there's no nested
/// LLM call here (unlike `features/digest.zig`'s `generate`, which does its
/// own summarization internally), so this is one plain request/response
/// tool call, not a second model round trip hidden inside a tool.
pub const tool: registry.ToolDef = .{
    .name = "catch_me_up",
    .description = "Fetches this chat's raw message history from the last N hours (default 24, max 336) so you can summarize it yourself when the user asks to catch up, asks what they missed, or wants a recap of recent discussion. Returns raw \"who: text\" lines, not a summary -- write the summary yourself in your reply. Different from a scheduled /digest: this is an on-demand, user-controlled time window.",
    .input_schema_json =
    \\{"type":"object","properties":{"hours":{"type":"integer","description":"How many hours back to look. Defaults to 24, capped at 336 (2 weeks)."}},"required":[]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.chat_history orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const requested = parsed.value.hours orelse default_hours;
    const hours = std.math.clamp(requested, 1, max_hours);

    const history = try sink.recentSince(ctx.allocator, hours);
    if (history.len == 0) {
        return std.fmt.allocPrint(ctx.allocator, "No messages in the last {d}h.", .{hours});
    }
    return std.fmt.allocPrint(ctx.allocator, "Chat history from the last {d}h:\n{s}", .{ hours, history });
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    requested_hours: ?i64 = null,
    result_text: []const u8 = "alice: hi\nbob: hey",

    fn sink(self: *FakeSink) registry.ChatHistorySink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.ChatHistorySink.VTable = .{ .recentSince = recentSinceFn };

    fn recentSinceFn(ptr: *anyopaque, allocator: std.mem.Allocator, hours_ago: i64) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.requested_hours = hours_ago;
        return self.result_text;
    }
};

test "execute defaults to 24 hours when no argument is given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .chat_history = fake.sink() };

    const out = try execute(ctx, "{}");
    try testing.expectEqual(@as(?i64, 24), fake.requested_hours);
    try testing.expect(std.mem.indexOf(u8, out, "alice: hi") != null);
}

test "execute clamps an out-of-range hours value into [1, 336]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .chat_history = fake.sink() };

    _ = try execute(ctx, "{\"hours\":99999}");
    try testing.expectEqual(@as(?i64, 336), fake.requested_hours);

    _ = try execute(ctx, "{\"hours\":-5}");
    try testing.expectEqual(@as(?i64, 1), fake.requested_hours);
}

test "execute reports an empty window distinctly from a populated one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{ .result_text = "" };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .chat_history = fake.sink() };

    const out = try execute(ctx, "{}");
    try testing.expect(std.mem.indexOf(u8, out, "No messages") != null);
}
