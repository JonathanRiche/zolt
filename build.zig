const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_enabled = b.option(bool, "vaxis", "Enable experimental libvaxis backend path") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_vaxis_backend", vaxis_enabled);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (vaxis_enabled) {
        const vaxis_dep = b.dependency("vaxis", .{
            .target = target,
            .optimize = optimize,
        });
        root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    }
    root_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "zolt",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (vaxis_enabled) {
        const vaxis_dep = b.dependency("vaxis", .{
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    }
    test_module.addOptions("build_options", build_options);
    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}
