const std = @import("std");
const builtin = @import("builtin");
const Gameboy = @import("gameboy.zig").Gameboy;
const cartridge_mod = @import("cartridge.zig");
const gpu = @import("gpu.zig");
const consts = @import("constants.zig");

// Host-provided high resolution time in microseconds. JS will supply via performance.now()*1000 rounded.
extern fn host_now_us() u64;

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
// Use an ArenaAllocator for WebAssembly: allocations mostly happen during init; arena frees all at once.
var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var gb_opt: ?Gameboy = null;

// Cycle-based pacing: accumulate target cycles from wall time, advance frames in fixed blocks of consts.FRAME_CYCLES
const CPU_HZ: f64 = @as(f64, consts.CPU_HZ);
const FRAME_CYCLES: u64 = consts.FRAME_CYCLES;
var last_time_us: u64 = 0;
var target_cycles: f64 = 0.0; // desired total cycles since pacing start
var base_cpu_cycles: u64 = 0; // CPU cycles at pacing baseline
const max_catchup_frames: u64 = 5; // cap burst
var pacing_enabled: bool = true; // can be toggled off for diagnostics
var frame_counter: u64 = 0; // counts frames actually executed

fn allocator() std.mem.Allocator { return arena_state.allocator(); }

// Utility: convert a raw pointer + length from JS memory into a slice.
fn sliceFrom(ptr: [*]u8, len: usize) []u8 { return ptr[0..len]; }

export fn gb_init(rom_ptr: [*]u8, rom_len: usize) i32 {
    if (gb_opt) |_| {
        // Already initialized; destroy previous instance & arena contents
        var gb_ref = gb_opt.?;
        gb_ref.deinit();
        gb_opt = null;
        arena_state.deinit();
        arena_state = .init(std.heap.page_allocator);
    }

    const alloc = allocator();
    gb_opt = Gameboy.newFromRomBytes(sliceFrom(rom_ptr, rom_len), alloc) catch return -1;
    // Reset pacing baselines
    last_time_us = 0;
    target_cycles = 0;
    base_cpu_cycles = 0;
    return 0;
}

// Called each animation frame from JS. Returns pointer to RGB framebuffer (RGB24) of size DRAW_WIDTH*DRAW_HEIGHT*3
export fn gb_frame() ?[*]const u8 {
    if (gb_opt) |*gb| {
        const now_us = host_now_us();
        if (last_time_us == 0) {
            last_time_us = now_us;
            // Initialize base CPU cycle reference
            base_cpu_cycles = gb.cpu.clock.t_cycles;
            return null; // need a delta first
        }
        var delta_us = now_us - last_time_us;
        if (delta_us > 500_000) delta_us = 500_000; // clamp long pauses (0.5s)
        last_time_us = now_us;
        // Increase target cycles based on elapsed microseconds.
        if (pacing_enabled) {
            target_cycles += (CPU_HZ * @as(f64, @floatFromInt(delta_us))) / 1_000_000.0;
        } else {
            // If pacing disabled, just schedule one frame worth each call so loop runs.
            target_cycles = @as(f64, @floatFromInt((gb.cpu.clock.t_cycles - base_cpu_cycles))) + @as(f64, @floatFromInt(FRAME_CYCLES));
        }
    // Calculate executed cycles relative to pacing baseline using actual CPU cycles
    const executed_cycles = gb.cpu.clock.t_cycles - base_cpu_cycles;
        if (target_cycles < @as(f64, @floatFromInt(executed_cycles + FRAME_CYCLES))) return null;
        var frames_to_run: u64 = @intFromFloat(@floor((target_cycles - @as(f64, @floatFromInt(executed_cycles))) / @as(f64, @floatFromInt(FRAME_CYCLES))));
    if (frames_to_run == 0) return null;
        if (frames_to_run > max_catchup_frames) frames_to_run = max_catchup_frames;
        while (frames_to_run > 0) : (frames_to_run -= 1) {
            gb.frame();
            frame_counter += 1;
        }
        return &gb.gpu.canvas;
    }
    return null;
}

// Keyboard input mapping from JS: pass bitfield or individual button changes.
// action: 1=press, 0=release. button codes we define: 0=A,1=B,2=SELECT,3=START,4=RIGHT,5=LEFT,6=UP,7=DOWN
export fn gb_input(button: u32, action: u32) void {
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
export fn gb_width() u32 { return gpu.DRAW_WIDTH; }
export fn gb_height() u32 { return gpu.DRAW_HEIGHT; }

// Minimal stub for audio: expose a ring buffer of interleaved f32 L,R samples that JS can pull.
// We reuse the existing APU buffer (SDL dependent) later; for now we expose silence until APU is abstracted.
// Audio pull model: JS calls gb_audio_available(); if >0 then gb_audio_read to obtain pointer + frame count.
export fn gb_audio_available() usize {
    if (gb_opt) |*gb| return gb.apu.audio_buffer_count / 2; // stereo frames
    return 0;
}
export fn gb_audio_read(buffer_ptr_out: *[*]const f32, frames_out: *usize) void {
    if (gb_opt) |*gb| {
        buffer_ptr_out.* = &gb.apu.audio_buffer;
        frames_out.* = gb.apu.audio_buffer_count / 2;
        gb.apu.audio_buffer_count = 0; // reset after consumption
    } else {
        frames_out.* = 0;
    }
}

// Optional: expose a very lightweight performance counter for JS profiling.
// JS can call before/after gb_frame to accumulate CPU time if desired.
// Backward compat helper (deprecated): returns CPU t-cycles.
export fn gb_cycle_hint() u64 { return gb_cycles(); }

// Preferred explicit export.
export fn gb_cycles() u64 {
    if (gb_opt) |*gb| return gb.cpu.clock.t_cycles;
    return 0;
}

// Reset cycle counter (useful to measure per-frame cycles from JS without extra state).
export fn gb_reset_cycles() void {
    if (gb_opt) |*gb| gb.cpu.clock.t_cycles = 0;
}
// Toggle pacing (1 = enabled, 0 = disabled)
export fn gb_set_pacing(on: u32) void { pacing_enabled = (on != 0); }
// Force run exactly one frame ignoring pacing accumulation.
export fn gb_force_frame() void {
    if (gb_opt) |*gb| {
        gb.frame();
        frame_counter += 1;
    }
}
export fn gb_frame_count() u64 { return frame_counter; }

// Error reporting: return last cartridge error code (0 = OK). Future: map codes to strings in JS.
export fn gb_last_error_code() u32 {
    return cartridge_mod.last_error_code;
}

// Diagnostic helpers
export fn gb_cart_type() u32 { if (gb_opt) |*gb| return @intFromEnum(gb.mbc.header.cartridge_type); return 0xFFFFFFFF; }
export fn gb_cart_rom_size_bytes() u32 { if (gb_opt) |*gb| return @intCast(gb.mbc.rom.len); return 0; }
export fn gb_cart_ram_size_bytes() u32 { if (gb_opt) |*gb| return @intCast(gb.mbc.ram.len); return 0; }
export fn gb_cpu_pc() u16 { if (gb_opt) |*gb| return gb.cpu.pc; return 0; }

// Debug: read a single memory byte (returns 0xFF if no gb)
export fn gb_read_mem(addr: u16) u8 { if (gb_opt) |*gb| return gb.memory_bus.read_byte(addr); return 0xFF; }
// Debug: expose IF and IE registers raw
export fn gb_if() u8 { if (gb_opt) |*gb| return @bitCast(gb.memory_bus.interrupt_flag); return 0; }
export fn gb_ie() u8 { if (gb_opt) |*gb| return @bitCast(gb.memory_bus.interrupt_enable); return 0; }
// Debug: current last fetched opcode
export fn gb_current_opcode() u8 { if (gb_opt) |*gb| return gb.cpu.debug_current_opcode(); return 0; }
// Fetch log exports
export fn gb_fetch_log_index() u16 { if (gb_opt) |*gb| return gb.cpu.debug_fetch_log_index(); return 0; }
export fn gb_fetch_log_capacity() u16 { return 256; }
export fn gb_fetch_log_pc_ptr() [*]const u16 { if (gb_opt) |*gb| return gb.cpu.debug_fetch_log_pcs_ptr(); return undefined; }
export fn gb_fetch_log_opcode_ptr() [*]const u8 { if (gb_opt) |*gb| return gb.cpu.debug_fetch_log_opcodes_ptr(); return undefined; }

// Debug: dump a range of memory into a caller-provided buffer (returns number of bytes written)
export fn gb_dump_mem(start: u16, out_ptr: [*]u8, len: u32) u32 {
    if (gb_opt) |*gb| {
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const addr: u16 = start +% @as(u16, @intCast(i));
            out_ptr[i] = gb.memory_bus.read_byte(addr);
        }
        return len;
    }
    return 0;
}
