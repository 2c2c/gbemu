const std = @import("std");
const sdl = @import("SDL.zig/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = sdl.init(b, null);

    // link build main exe
    const exe = b.addExecutable(.{
        .name = "GBEMU",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // sdl2
    sdk.link(exe, .dynamic);
    // exe.root_module.addImport("sdl2", sdk.getWrapperModule());
    exe.root_module.addImport("sdl2", sdk.getNativeModule());

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // partial buildfor zls
    const exe_check = b.addExecutable(.{
        .name = "GBEMU",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdk.link(exe_check, .dynamic);
    exe_check.root_module.addImport("sdl2", sdk.getNativeModule());
    const check = b.step("check", "Check the app");
    check.dependOn(&exe_check.step);

    // unit tests
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.root_module.addImport("sdl2", sdk.getNativeModule());
    sdk.link(exe_unit_tests, .dynamic);
    b.installArtifact(exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
