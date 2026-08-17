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
    // libolm (Matrix E2E encryption, see src/matrix/olm.zig) — same
    // reasoning/shape as the pq linkage above.
    exe_mod.linkSystemLibrary("olm", .{});
    // TDLib's JSON client (src/platform/telegram_user.zig) — same
    // reasoning/shape as the pq linkage above. Header lives under
    // /usr/include/td/telegram/td_json_client.h (the `tdlib-devel`/
    // `telegram-tdlib-dev` package, depending on distro).
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

    // One-time SQLite -> Postgres data migration tool (see
    // src/migrate_tool.zig). Not part of the `warden` binary or its Docker
    // image — the only place SQLite-reading code survives post-cutover, so
    // it's the only target that still vendors the SQLite amalgamation.
    const migrate_mod = b.createModule(.{
        .root_source_file = b.path("src/migrate_tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    migrate_mod.link_libc = true;
    migrate_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    migrate_mod.linkSystemLibrary("pq", .{});
    migrate_mod.addIncludePath(b.path("third_party/sqlite"));
    migrate_mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
        },
    });

    const migrate_exe = b.addExecutable(.{
        .name = "warden-migrate",
        .root_module = migrate_mod,
    });

    const migrate_step = b.step("migrate-data", "One-time migration of data/chats/*.db into Postgres");
    const run_migrate_cmd = b.addRunArtifact(migrate_exe);
    migrate_step.dependOn(&run_migrate_cmd.step);
    if (b.args) |args| run_migrate_cmd.addArgs(args);

    // Retroactive chat-departure reconciliation tool (see
    // src/cleanup_left_chats.zig) -- installed (unlike migrate_exe) so the
    // Docker image can also copy it in and run it against production, not
    // just locally via `zig build cleanup-left-chats`.
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
