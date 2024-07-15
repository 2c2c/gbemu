const std = @import("std");
const cartridge = @import("cartridge.zig");
const cpu = @import("cpu.zig");
const gpu = @import("gpu.zig");
const memory_bus = @import("memory_bus.zig");
const joypad = @import("joypad.zig");
const timer = @import("timer.zig");

pub const Gameboy = struct {
    mbc: cartridge.MBC,
    cpu: cpu.CPU,
    gpu: gpu.GPU,
    memory_bus: memory_bus.MemoryBus,
    joypad: joypad.Joypad,
    timer: timer.Timer,

    pub fn new(filename: []u8) !Gameboy {
        return Gameboy{
            .mbc = try cartridge.MBC.new(filename),
            .cpu = try cpu.CPU.new(),
            .gpu = gpu.GPU.new(),
            .memory_bus = try memory_bus.MemoryBus.new(),
            .joypad = joypad.Joypad.new(),
            .timer = timer.Timer.new(),
        };
    }
};
