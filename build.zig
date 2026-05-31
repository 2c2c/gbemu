const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Allow the native GUI build to fall back to the no-op SDL stub (e.g. when
    // cross-compiling or building where SDL2 isn't installed).
    const stub_sdl = b.option(
        bool,
        "stub-sdl",
        "Build the GUI exe against the no-op SDL stub instead of linking real SDL2",
    ) orelse false;

    // No-op SDL module (used by the stub GUI build and the unit tests, which must
    // not open real audio hardware). SDL never affects emulation state.
    const sdl_stub = b.createModule(.{ .root_source_file = b.path("src/sdl_stub.zig") });
    const stub_import: std.Build.Module.Import = .{ .name = "sdl2", .module = sdl_stub };

    // Real SDL2 bindings via the compiler's own translate-c over the system SDL2
    // headers (replaces the unmaintained third-party SDL.zig binding). Lazy: only
    // runs if something imports it. pkg-config supplies -I/-L/-l.
    const sdl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_translate.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/sdl2/include" });
    const sdl_real = sdl_translate.createModule();
    sdl_real.linkSystemLibrary("SDL2", .{});
    const real_import: std.Build.Module.Import = .{ .name = "sdl2", .module = sdl_real };

    const gui_import = if (stub_sdl) stub_import else real_import;

    // ---- native GUI executable (real SDL2 by default) ----
    const exe = b.addExecutable(.{
        .name = "GBEMU",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{gui_import},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Pass a ROM by running the installed binary directly: `./zig-out/bin/GBEMU <rom>`.
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ---- zls / partial check build ----
    const exe_check = b.addExecutable(.{
        .name = "GBEMU",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{gui_import},
        }),
    });
    const check = b.step("check", "Check the app");
    check.dependOn(&exe_check.step);

    // ---- unit tests (stub: must not open real audio hardware) ----
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{stub_import},
        }),
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // ---- native headless accuracy-test runner (stub SDL; ReleaseFast for speed) ----
    const testrunner = b.addExecutable(.{
        .name = "testrunner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testrunner.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{stub_import},
        }),
    });
    const install_testrunner = b.addInstallArtifact(testrunner, .{});
    const testrunner_step = b.step("testrunner", "Build the accuracy-test runner");
    testrunner_step.dependOn(&install_testrunner.step);

    // ---- WebAssembly (wasm32) build: headless core + JS glue, no SDL ----
    // The wasm entrypoint (src/web.zig) loads ROMs from a byte buffer (no fs) and
    // exposes a C-ABI surface the JS loader (web/emu.js) and the Node golden
    // harness (tools/wasm_golden.mjs) call. This is the SDL-free verification path.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const wasm = b.addExecutable(.{
        .name = "gbemu_wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        }),
    });
    wasm.rdynamic = true;
    wasm.entry = .disabled; // no _start; exports are called from JS
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build & install WebAssembly module (gbemu_wasm.wasm)");
    wasm_step.dependOn(&install_wasm.step);
}
