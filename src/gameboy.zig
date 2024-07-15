const std = @import("std");
const cartridge = @import("cartridge.zig");
const cpu = @import("cpu.zig");
const gpu = @import("gpu.zig");
const memory_bus = @import("memory_bus.zig");
const joypad = @import("joypad.zig");
const timer = @import("timer.zig");
const ie_register = @import("ie_register.zig");

const CPU_SPEED_HZ = 4194304;
pub const Gameboy = struct {
    mbc: cartridge.MBC,
    cpu: cpu.CPU,
    gpu: gpu.GPU,
    memory_bus: memory_bus.MemoryBus,
    joypad: joypad.Joypad,
    timer: timer.Timer,

    pub fn new(filename: []u8) !Gameboy {
        const mbc_ = try cartridge.MBC.new(filename);
        const gpu_ = gpu.GPU.new();
        const joypad_ = joypad.Joypad.new();
        var timer_ = timer.Timer.new();
        timer_.tac.frequency = timer.Frequency.Hz4096;
        const memory_bus_ = try memory_bus.MemoryBus.new(mbc_, gpu_, timer_, joypad_);
        const cpu_ = try cpu.CPU.new(memory_bus_);

        return Gameboy{
            .mbc = mbc_,
            .cpu = cpu_,
            .gpu = gpu_,
            .joypad = joypad_,
            .timer = timer_,
            .memory_bus = memory_bus_,
        };
    }

    pub fn frame(self: *Gameboy) void {
        const cycles_per_frame = CPU_SPEED_HZ / 60;
        // const hz_60_nanos: u64 = std.time.ns_per_s / 60;
        // _ = hz_60_nanos; // autofix
        // var timer = try std.time.Timer.start();
        // _ = timer; // autofix
        var frame_cycles: u64 = 0;
        joypad.Joypad.update_joyp_keys(self);
        // std.debug.print("joyp state: 0b{b:0>8}\n", .{@as(u8, @bitCast(self.bus.joypad.joyp))});

        while (true) {
            var cpu_cycles_spent = self.cpu.step();
            frame_cycles += cpu_cycles_spent;

            while (cpu_cycles_spent > 0) : (cpu_cycles_spent -= 4) {
                const enable_timer_flag = self.timer.step(4, self.cpu.clock.bits.div);
                const gpu_interrupt_requests = self.gpu.step(4);

                const interrupt_flags = ie_register.IERegister{
                    .enable_timer = enable_timer_flag,
                    .enable_vblank = gpu_interrupt_requests.vblank,
                    .enable_lcd_stat = gpu_interrupt_requests.lcd_stat,
                    // who
                    .enable_serial = false,
                    // cares
                    .enable_joypad = false,
                };

                // std.debug.print("gb.timer {} gb.bus.timer {}\n", .{ self.timer.tac, self.memory_bus.timer.tac });
                self.memory_bus.update_if_flags(interrupt_flags);
            }

            // need to track unspent cycles in CPU
            if (frame_cycles >= cycles_per_frame) {
                break;
            }
        }
    }
};
