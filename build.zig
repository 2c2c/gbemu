const std = @import("std");
const sdl = @import("sdl");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = sdl.init(b, .{});

    // link build main exe
    const exe = b.addExecutable(.{
        .name = "GBEMU",
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // sdl2
    sdk.link(exe, .dynamic, .SDL2);
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

    // // partial buildfor zls
    const exe_check = b.addExecutable(.{
        .name = "GBEMU",
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    sdk.link(exe_check, .dynamic, .SDL2);
    exe_check.root_module.addImport("sdl2", sdk.getNativeModule());
    const check = b.step("check", "Check the app");
    check.dependOn(&exe_check.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.root_module.addImport("sdl2", sdk.getNativeModule());
    sdk.link(exe_unit_tests, .dynamic, .SDL2);
    b.installArtifact(exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // WebAssembly (wasm32) build (headless core + JS glue)
    // We intentionally do NOT link SDL for the wasm target. The wasm entrypoint lives in src/web.zig
    // and exposes a small C ABI / export surface that the JS loader (web/emu.js) will use.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "gbemu_wasm",
        .root_source_file = .{ .cwd_relative = "src/web.zig" },
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm.rdynamic = true;
    // No _start symbol required; exports are called from JS.
    wasm.entry = .disabled;
    // Provide a define so code can detect Web build without relying solely on arch.
    wasm.root_module.addCMacro("GBEMU_WASM", "1");
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build & install WebAssembly module (gbemu_wasm.wasm)");
    wasm_step.dependOn(&install_wasm.step);
}
