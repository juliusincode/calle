const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The actual calle module: transport/protocol/session/commands.
    const calle_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI executable, imports the calle module under the name "calle".
    const exe = b.addExecutable(.{
        .name = "calle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "calle", .module = calle_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "run calle (args: [host] [port])");
    run_step.dependOn(&run_cmd.step);

    // Tests run directly against the calle module, so ALL test blocks
    // from transport/, protocol/, session/ and commands/ get picked up.
    const lib_tests = b.addTest(.{
        .root_module = calle_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
