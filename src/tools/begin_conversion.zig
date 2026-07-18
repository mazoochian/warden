const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

pub const tool: registry.ToolDef = .{
    .name = "begin_file_conversion",
    .description = "Starts the interactive file-conversion flow when the user says they want to convert a file but haven't attached one to this message yet (e.g. \"I want to convert a video\", \"can you convert a document for me?\"). Do NOT use this if a file is already attached to the current message — use convert_file directly for that instead. Takes no arguments. After calling this, tell the user to go ahead and send the file they want to convert.",
    .input_schema_json =
    \\{"type":"object","properties":{}}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    _ = input_json;
    const sink = ctx.convert_flow orelse return error.MissingToolContext;
    try sink.beginAwaitingFile();
    return "Started the conversion flow — ask the user to upload the file they want to convert now; once it arrives they'll be asked (via buttons or reactions) what format to convert it to.";
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const testing = std.testing;

const FakeSink = struct {
    called: bool = false,

    fn sink(self: *FakeSink) registry.ConvertFlowSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.ConvertFlowSink.VTable = .{ .beginAwaitingFile = beginAwaitingFileFn };

    fn beginAwaitingFileFn(ptr: *anyopaque) anyerror!void {
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.called = true;
    }
};

test "execute calls the sink and returns a status string for the model to relay" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .convert_flow = fake.sink() };

    const out = try execute(ctx, "{}");
    try testing.expect(fake.called);
    try testing.expect(std.mem.indexOf(u8, out, "conversion flow") != null);
}

test "execute without a convert_flow sink returns an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io };
    try testing.expectError(error.MissingToolContext, execute(ctx, "{}"));
}
