const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const max_matches = 5;

const Args = struct {
    query: []const u8,
};

pub const tool: registry.ToolDef = .{
    .name = "find_chat_member",
    .description = "Looks up a participant of this chat by name, partial name, or @username fragment — use this whenever the user refers to someone else by name (\"tell Courtney I said hi\", \"what's Alex's handle\", \"mention Sam in your reply\") instead of guessing their username or id. Searches everyone Warden has seen in this chat — not just people who've recently messaged, but also anyone replied to, @-mentioned, or who joined/left, plus the chat's admins. If it returns more than one plausible match, ask the user which one they meant rather than picking arbitrarily; if it returns none, say so rather than inventing a handle.",
    .input_schema_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Name, partial name, or @username fragment to search for, e.g. \"Courtney\" or \"court\""}},"required":["query"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.member_directory orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const query = std.mem.trim(u8, parsed.value.query, " ");
    if (query.len == 0) return "Missing query — give a name or @username fragment to search for.";

    const matches = try sink.find(ctx.allocator, query);
    if (matches.len == 0) {
        return "No one in this chat matches that name — they may not have been active, mentioned, or replied to here yet.";
    }

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    buf.writer.print("Matches in this chat:\n", .{}) catch return error.OutOfMemory;
    for (matches) |m| {
        if (m.username) |u| {
            buf.writer.print("- {s} (@{s}, id {s})\n", .{ m.display_name, u, m.native_id }) catch return error.OutOfMemory;
        } else {
            buf.writer.print("- {s} (no username, id {s})\n", .{ m.display_name, m.native_id }) catch return error.OutOfMemory;
        }
    }
    return ctx.allocator.dupe(u8, buf.writer.buffered());
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    matches: []const registry.MemberMatch = &.{},
    last_query: ?[]const u8 = null,

    fn sink(self: *FakeSink) registry.MemberDirectorySink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.MemberDirectorySink.VTable = .{ .find = findFn };

    fn findFn(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8) anyerror![]registry.MemberMatch {
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.last_query = try allocator.dupe(u8, query);
        return @constCast(self.matches);
    }
};

test "execute formats each match with its handle when present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{ .matches = &.{
        .{ .display_name = "Courtney Hale", .username = "courtney_h", .native_id = "123" },
        .{ .display_name = "Court Bot", .native_id = "456" },
    } };
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .member_directory = fake.sink() };

    const out = try execute(ctx, "{\"query\":\"court\"}");
    try testing.expect(std.mem.indexOf(u8, out, "Courtney Hale (@courtney_h, id 123)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Court Bot (no username, id 456)") != null);
    try testing.expectEqualStrings("court", fake.last_query.?);
}

test "execute reports no matches distinctly from an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .member_directory = fake.sink() };

    const out = try execute(ctx, "{\"query\":\"nobody\"}");
    try testing.expect(std.mem.indexOf(u8, out, "No one in this chat matches") != null);
}

test "execute rejects an empty query without calling the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .member_directory = fake.sink() };

    const out = try execute(ctx, "{\"query\":\"   \"}");
    try testing.expect(std.mem.indexOf(u8, out, "Missing query") != null);
    try testing.expectEqual(@as(?[]const u8, null), fake.last_query);
}
