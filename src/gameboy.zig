const std = @import("std");
const cartridge = @import("cartridge.zig");
const cpu = @import("cpu.zig");
const gpu = @import("gpu.zig");
const memory_bus = @import("memory_bus.zig");
const joypad = @import("joypad.zig");
const timer = @import("timer.zig");
const ie_register = @import("ie_register.zig");

const log = std.log.scoped(.gameboy);

const CPU_SPEED_HZ = 4194304;
pub const Gameboy = struct {
    mbc: *cartridge.MBC,
    cpu: *cpu.CPU,
    gpu: *gpu.GPU,
    memory_bus: *memory_bus.MemoryBus,
    joypad: *joypad.Joypad,
    timer: *timer.Timer,

    alloc: std.mem.Allocator,

    pub fn new(filename: []u8, alloc: std.mem.Allocator) !Gameboy {
        const mbc__ = try alloc.create(cartridge.MBC);
        const mbc_ = try cartridge.MBC.new(filename, alloc);
        mbc__.* = mbc_;

        const gpu__ = try alloc.create(gpu.GPU);
        const gpu_ = gpu.GPU.new();
        gpu__.* = gpu_;

        const joypad__ = try alloc.create(joypad.Joypad);
        const joypad_ = joypad.Joypad.new();
        joypad__.* = joypad_;

        const timer__ = try alloc.create(timer.Timer);
        var timer_ = timer.Timer.new();
        timer_.tac.frequency = timer.Frequency.Hz4096;

        timer__.* = timer_;

        const mb = try alloc.create(memory_bus.MemoryBus);
        const memory_bus_ = memory_bus.MemoryBus.new(mbc__, gpu__, timer__, joypad__);
        mb.* = memory_bus_;

        const cpu__ = try alloc.create(cpu.CPU);
        const cpu_ = cpu.CPU.new(mb);
        cpu__.* = cpu_;

        return Gameboy{
            .mbc = mbc__,
            .cpu = cpu__,
            .gpu = gpu__,
            .joypad = joypad__,
            .timer = timer__,
            .memory_bus = mb,

            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Gameboy) void {
        self.mbc.deinit();
        self.alloc.destroy(self.mbc);
        self.alloc.destroy(self.cpu);
        self.alloc.destroy(self.gpu);
        self.alloc.destroy(self.joypad);
        self.alloc.destroy(self.timer);
        self.alloc.destroy(self.memory_bus);
    }

    pub fn frame(self: *Gameboy) void {
        const cycles_per_frame = CPU_SPEED_HZ / 60;
        var frame_cycles: u64 = 0;
        // std.debug.print("joyp state: 0b{b:0>8}\n", .{@as(u8, @bitCast(self.bus.joypad.joyp))});

        while (true) {
            joypad.Joypad.update_joyp_keys(self);
            var cpu_cycles_spent = self.cpu.step();
            frame_cycles += cpu_cycles_spent;

            while (cpu_cycles_spent > 0) : (cpu_cycles_spent -= 4) {
                const enable_timer_flag = self.timer.step();
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
                std.time.sleep(500);
            }

            // need to track unspent cycles in CPU
            if (frame_cycles >= cycles_per_frame) {
                break;
            }
        }
    }
};
