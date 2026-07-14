const std = @import("std");
const iface = @import("interface.zig");

/// Stub Matrix connector — scaffolding for a future real implementation
/// (the README lists Matrix as "coming soon"). `poll` always returns empty
/// and `sendMessage` just logs, so wiring this in wouldn't do anything yet;
/// every optional moderation/admin vtable field is left `null`, so
/// `Connector`'s wrapper methods naturally report `error.Unsupported` for
/// them (see `Connector`'s doc comment on why that's the intended shape for
/// a not-yet-capable platform rather than every connector needing stubs).
pub const MatrixConnector = struct {
    pub fn init() MatrixConnector {
        return .{};
    }

    pub fn connector(self: *MatrixConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .matrix;
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = ptr;
        _ = allocator;
        _ = reply_to_message_id;
        std.log.warn("matrix connector is a stub — dropped message to {s}: {s}", .{ chat_id, text });
    }
};

const testing = std.testing;

test "MatrixConnector reports its platform and an always-empty poll" {
    var conn = MatrixConnector.init();
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.matrix, c.platform());
    const msgs = try c.poll(testing.allocator);
    try testing.expectEqual(@as(usize, 0), msgs.len);
}

test "MatrixConnector reports Unsupported for every moderation action (no vtable entries set)" {
    var conn = MatrixConnector.init();
    const c = conn.connector();
    try testing.expectError(error.Unsupported, c.isGroupAdmin(testing.allocator, "1", "2"));
    try testing.expectError(error.Unsupported, c.banUser(testing.allocator, "1", "2"));
    try testing.expectError(error.Unsupported, c.muteUser(testing.allocator, "1", "2", 0));
}
