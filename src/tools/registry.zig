const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");

/// Most tools are pure request/response (fetch some data, return text to
/// feed back to the model). A few — like rendering and sending a diagram —
/// have a side effect (sending a photo to the chat), so the
/// connector/chat_id/scratch dir are available too. Optional (rather than
/// required) so simple tools and their tests can keep constructing a
/// `ToolContext` with just `allocator`/`io`.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    connector: ?iface.Connector = null,
    chat_id: ?[]const u8 = null,
    /// Scratch directory for tools that shell out to an external renderer.
    tmp_dir: ?[]const u8 = null,
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON Schema object text describing the tool's input.
    input_schema_json: []const u8,
    execute: *const fn (ctx: ToolContext, input_json: []const u8) anyerror![]const u8,
};

pub fn find(defs: []const ToolDef, name: []const u8) ?ToolDef {
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}
