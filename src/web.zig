const std = @import("std");
const builtin = @import("builtin");
const Gameboy = @import("gameboy.zig").Gameboy;
const gpu = @import("gpu.zig");

// Options: silence logging in wasm to avoid touching stderr.
pub const std_options: std.Options = .{ .logFn = noopLog };
fn noopLog(comptime l: std.log.Level, comptime scope: anytype, comptime f: []const u8, args: anytype) void {
    _ = l; _ = scope; _ = f; _ = args;
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret: ?usize) noreturn {
    _ = msg; _ = trace; _ = ret; @trap();
}

// We avoid SDL in this translation unit. build.zig sets a wasm32 freestanding target.
// Simple global emulator instance. For a more advanced setup we could support multiple instances.
var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
var gb_opt: ?Gameboy = null;

// Export a version constant so we can quickly verify export visibility from JS / tooling.
pub export const gb_version: u32 = 1;

// Stronger retention strategy: create a table of function pointers that is itself exported.
// This prevents the optimizer from discarding the functions even if it (incorrectly) thinks
// the root-level export declarations are unused.
pub const ExportTable = extern struct {
    init: *const anyopaque,
    frame: *const anyopaque,
    input: *const anyopaque,
    width: *const anyopaque,
    height: *const anyopaque,
    audio_available: *const anyopaque,
    audio_read: *const anyopaque,
};

// Export the table; JS can optionally use this as a fallback to locate function addresses.
pub export var gb_exports: ExportTable = .{
    .init = @ptrCast(&gb_init),
    .frame = @ptrCast(&gb_frame),
    .input = @ptrCast(&gb_input),
    .width = @ptrCast(&gb_width),
    .height = @ptrCast(&gb_height),
    .audio_available = @ptrCast(&gb_audio_available),
    .audio_read = @ptrCast(&gb_audio_read),
};

// Some versions of the toolchain may elide exports aggressively when there is no entry point.
// Provide a minimal _start that does nothing so the module is treated as having a start symbol.
pub export fn _start() void {}

fn allocator() std.mem.Allocator { return gpa_state.allocator(); }

// Utility: convert a raw pointer + length from JS memory into a slice.
fn sliceFrom(ptr: [*]u8, len: usize) []u8 { return ptr[0..len]; }

// Explicit C calling convention to stabilize symbol names across optimization levels.
pub fn gb_init(rom_ptr: [*]u8, rom_len: usize) callconv(.C) i32 {
    if (gb_opt) |_| {
        // Already initialized; destroy previous
        var gb_ref = gb_opt.?;
        gb_ref.deinit();
        gb_opt = null;
        _ = gpa_state.deinit();
        gpa_state = .{}; // reset
    }

    gpa_state = .{};
    const alloc = allocator();
    gb_opt = Gameboy.newFromRomBytes(sliceFrom(rom_ptr, rom_len), alloc) catch return -1;
    return 0;
}

// Called each animation frame from JS. Returns pointer to RGB framebuffer (RGB24) of size DRAW_WIDTH*DRAW_HEIGHT*3
pub fn gb_frame() callconv(.C) ?[*]const u8 {
    if (gb_opt) |*gb| {
        gb.frame();
        return &gb.gpu.canvas;
    }
    return null;
}

// Keyboard input mapping from JS: pass bitfield or individual button changes.
// action: 1=press, 0=release. button codes we define: 0=A,1=B,2=SELECT,3=START,4=RIGHT,5=LEFT,6=UP,7=DOWN
pub fn gb_input(button: u32, action: u32) callconv(.C) void {
    if (gb_opt) |*gb| {
        const pressed = action == 1;
        switch (button) {
            0 => gb.joypad.button.pressed.A = pressed,
            1 => gb.joypad.button.pressed.B = pressed,
            2 => gb.joypad.button.pressed.SELECT = pressed,
            3 => gb.joypad.button.pressed.START = pressed,
            4 => gb.joypad.dpad.pressed.RIGHT = pressed,
            5 => gb.joypad.dpad.pressed.LEFT = pressed,
            6 => gb.joypad.dpad.pressed.UP = pressed,
            7 => gb.joypad.dpad.pressed.DOWN = pressed,
            else => {},
        }
    }
}

// Provide canvas dimensions to JS
pub fn gb_width() callconv(.C) u32 { return gpu.DRAW_WIDTH; }
pub fn gb_height() callconv(.C) u32 { return gpu.DRAW_HEIGHT; }

// Minimal stub for audio: expose a ring buffer of interleaved f32 L,R samples that JS can pull.
// We reuse the existing APU buffer (SDL dependent) later; for now we expose silence until APU is abstracted.
// Audio pull model: JS calls gb_audio_available(); if >0 then gb_audio_read to obtain pointer + frame count.
pub fn gb_audio_available() callconv(.C) usize {
    if (gb_opt) |*gb| return gb.apu.audio_buffer_count / 2; // stereo frames
    return 0;
}
pub fn gb_audio_read(buffer_ptr_out: *[*]const f32, frames_out: *usize) callconv(.C) void {
    if (gb_opt) |*gb| {
        buffer_ptr_out.* = &gb.apu.audio_buffer;
        frames_out.* = gb.apu.audio_buffer_count / 2;
        gb.apu.audio_buffer_count = 0; // reset after consumption
    } else {
        frames_out.* = 0;
    }
}

// Explicitly export all wasm-visible symbols (belt-and-braces approach for toolchain quirks).
comptime {
    @export(&gb_init, .{ .name = "gb_init" });
    @export(&gb_frame, .{ .name = "gb_frame" });
    @export(&gb_input, .{ .name = "gb_input" });
    @export(&gb_width, .{ .name = "gb_width" });
    @export(&gb_height, .{ .name = "gb_height" });
    @export(&gb_audio_available, .{ .name = "gb_audio_available" });
    @export(&gb_audio_read, .{ .name = "gb_audio_read" });
}
