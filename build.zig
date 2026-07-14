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
    exe_mod.linkSystemLibrary("pq", .{});

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

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
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
}
