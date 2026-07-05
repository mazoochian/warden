const std = @import("std");
const Io = std.Io;

/// Shells out to the bundled Mermaid CLI (`tools/diagram/node_modules/.bin/mmdc`)
/// to render `mermaid_source` and returns the resulting PNG bytes. Requires
/// `node` on PATH and the mermaid-cli install in `tools/diagram/` (it
/// bundles its own headless Chromium via Puppeteer — a much heavier
/// dependency than the word cloud's pure-canvas renderer).
pub fn render(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8, mermaid_source: []const u8) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, tmp_dir);

    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const input_path = try std.fmt.allocPrint(allocator, "{s}/diagram_{d}.mmd", .{ tmp_dir, ts });
    defer allocator.free(input_path);
    defer Io.Dir.cwd().deleteFile(io, input_path) catch {};

    const output_path = try std.fmt.allocPrint(allocator, "{s}/diagram_{d}.png", .{ tmp_dir, ts });
    defer allocator.free(output_path);
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    {
        var file = try Io.Dir.cwd().createFile(io, input_path, .{});
        defer file.close(io);
        var file_writer = file.writer(io, &.{});
        try file_writer.interface.writeAll(mermaid_source);
        try file_writer.interface.flush();
    }

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            "tools/diagram/node_modules/.bin/mmdc",
            "-i",
            input_path,
            "-o",
            output_path,
            "-b",
            "transparent",
            "--puppeteerConfigFile",
            "tools/diagram/puppeteer-config.json",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("mermaid render failed (term={any}): {s}", .{ result.term, result.stderr });
        return error.RenderFailed;
    }

    return Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(20 * 1024 * 1024));
}
