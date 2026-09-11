const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    // Explicit -Dtarget builds (e.g. the Docker cross-build) skip the
    // default system library search paths even when the target matches
    // the host, so libpq isn't found without these even though it's
    // right there in /usr/lib.
    exe_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    exe_mod.linkSystemLibrary("pq", .{});
    // libolm (Matrix E2E encryption, see src/platform/matrix/olm.zig) — same
    // reasoning/shape as the pq linkage above.
    exe_mod.linkSystemLibrary("olm", .{});
    // TDLib's JSON client (src/platform/telegram/user_connector.zig) — same
    // library-path reasoning as pq above, plus an explicit *include* path
    // this one actually needs and pq/olm don't: those two have no
    // `@cImport` anywhere in this codebase (hand-written `extern fn`
    // bindings instead), so they never depended on the C compiler finding
    // a header at all. `user_connector.zig` is the first file to
    // `@cInclude` a system header, and the same "-Dtarget skips default
    // search paths" gap documented above for libraries turned out to
    // apply to header search paths too — confirmed live: this compiled
    // fine natively (no -Dtarget) but failed
    // `error: 'td/telegram/td_json_client.h' not found` under the Docker
    // cross-build's `-Dtarget=x86_64-linux-musl` until this was added.
    exe_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe_mod.linkSystemLibrary("tdjson", .{});

    const exe = b.addExecutable(.{
        .name = "warden",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the bot");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // `zig build test -Dtest-filter="some test name"` runs just the matching
    // tests. Worth having because the test runner takes filters only at
    // COMPILE time -- passing `--test-filter` to the built test binary is a
    // hard error -- so without this option there is no way at all to run one
    // test in isolation, and the whole DB-backed suite is a multi-minute
    // round trip. That cost real time on 2026-08-04 while isolating a crash
    // that turned out to be misattributed to an innocent test.
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains one of these filters") orelse &[_][]const u8{};
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Retroactive chat-departure reconciliation tool (see
    // src/cleanup_left_chats.zig) -- installed, not just wired to its own
    // step, so the Docker image can copy it in and run it against
    // production rather than only locally via `zig build
    // cleanup-left-chats`.
    const cleanup_mod = b.createModule(.{
        .root_source_file = b.path("src/cleanup_left_chats.zig"),
        .target = target,
        .optimize = optimize,
    });
    cleanup_mod.link_libc = true;
    cleanup_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    cleanup_mod.linkSystemLibrary("pq", .{});

    const cleanup_exe = b.addExecutable(.{
        .name = "cleanup-left-chats",
        .root_module = cleanup_mod,
    });
    b.installArtifact(cleanup_exe);

    const cleanup_step = b.step("cleanup-left-chats", "Retroactively deletes chats the bot is no longer a member of (dry run by default, pass -- --apply to delete)");
    const run_cleanup_cmd = b.addRunArtifact(cleanup_exe);
    cleanup_step.dependOn(&run_cleanup_cmd.step);
    if (b.args) |args| run_cleanup_cmd.addArgs(args);
}
