const std = @import("std");
const Io = std.Io;
const stats = @import("../store/stats.zig");

pub const Slice = struct { label: []const u8, count: i64 };

/// Builds the renderer's input straight from `stats.compute`'s existing
/// ranked top-users query — no new DB query needed for the "top
/// participants" pie chart. Falls back to the raw platform id as the label
/// when a participant has no username set, same fallback `stats.zig`'s own
/// text formatting already uses.
pub fn slicesFromTopUsers(allocator: std.mem.Allocator, top_users: []const stats.TopUser) ![]Slice {
    const out = try allocator.alloc(Slice, top_users.len);
    for (top_users, 0..) |u, i| {
        out[i] = .{ .label = if (u.username.len > 0) u.username else u.user_id, .count = u.message_count };
    }
    return out;
}

/// Shells out to the bundled Node renderer (`tools/piechart/render.mjs`)
/// and returns the resulting PNG bytes. Requires `node` on PATH — mirrors
/// `wordcloud.zig`'s `render` pipeline exactly (JSON temp file -> node
/// script using `@napi-rs/canvas` -> PNG bytes), just with a different
/// script and payload shape.
pub fn render(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, slices: []const Slice) ![]const u8 {
    if (slices.len == 0) return error.NoSlices;

    try Io.Dir.cwd().createDirPath(io, tmp_dir);

    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const input_path = try std.fmt.allocPrint(allocator, "{s}/piechart_{d}.json", .{ tmp_dir, ts });
    defer allocator.free(input_path);
    defer Io.Dir.cwd().deleteFile(io, input_path) catch {};

    {
        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        try std.json.Stringify.value(slices, .{}, &payload_writer.writer);

        var file = try Io.Dir.cwd().createFile(io, input_path, .{});
        defer file.close(io);
        var file_writer = file.writer(io, &.{});
        try file_writer.interface.writeAll(payload_writer.writer.buffered());
        try file_writer.interface.flush();
    }

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "node", "tools/piechart/render.mjs", input_path },
    });
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("piechart render failed (term={any}): {s}", .{ result.term, result.stderr });
        allocator.free(result.stdout);
        return error.RenderFailed;
    }

    return result.stdout;
}

const testing = std.testing;

test "slicesFromTopUsers prefers the username, falling back to the raw user id" {
    const top_users = [_]stats.TopUser{
        .{ .user_id = "1", .username = "alice", .message_count = 5 },
        .{ .user_id = "2", .username = "", .message_count = 2 },
    };
    const slices = try slicesFromTopUsers(testing.allocator, &top_users);
    defer testing.allocator.free(slices);

    try testing.expectEqualStrings("alice", slices[0].label);
    try testing.expectEqual(@as(i64, 5), slices[0].count);
    try testing.expectEqualStrings("2", slices[1].label);
    try testing.expectEqual(@as(i64, 2), slices[1].count);
}

test "render errors on an empty slice list without shelling out" {
    try testing.expectError(error.NoSlices, render(testing.allocator, testing.io, "data/tmp", &.{}));
}
