const std = @import("std");
const iface = @import("interface.zig");

/// Stub XMPP connector — same shape and purpose as `matrix.zig`'s stub (see
/// its doc comment). Not currently advertised anywhere (unlike Matrix, XMPP
/// isn't mentioned in the README yet), but the `Platform.xmpp` enum variant
/// and `XmppProfile` domain type need a real (if inert) consumer.
pub const XmppConnector = struct {
    pub fn init() XmppConnector {
        return .{};
    }

    pub fn connector(self: *XmppConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .xmpp;
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
        std.log.warn("xmpp connector is a stub — dropped message to {s}: {s}", .{ chat_id, text });
    }
};

const testing = std.testing;

test "XmppConnector reports its platform and an always-empty poll" {
    var conn = XmppConnector.init();
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.xmpp, c.platform());
    const msgs = try c.poll(testing.allocator);
    try testing.expectEqual(@as(usize, 0), msgs.len);
}

test "XmppConnector reports Unsupported for every moderation action (no vtable entries set)" {
    var conn = XmppConnector.init();
    const c = conn.connector();
    try testing.expectError(error.Unsupported, c.isGroupAdmin(testing.allocator, "1", "2"));
    try testing.expectError(error.Unsupported, c.kickUser(testing.allocator, "1", "2"));
}
