const std = @import("std");
const cartridge = @import("cartridge.zig");
const cpu = @import("cpu.zig");
const gpu = @import("gpu.zig");
const apu = @import("apu.zig");
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
    apu: *apu.APU,
    memory_bus: *memory_bus.MemoryBus,
    joypad: *joypad.Joypad,
    timer: *timer.Timer,

    alloc: std.mem.Allocator,

    pub fn new(filename: []u8, alloc: std.mem.Allocator) !Gameboy {
        const mbc_ = try alloc.create(cartridge.MBC);
        mbc_.* = try cartridge.MBC.new(filename, alloc);

        const gpu_ = try alloc.create(gpu.GPU);
        gpu_.* = gpu.GPU.new();

        const apu_ = try alloc.create(apu.APU);
        apu_.* = apu.APU.new();

        const joypad_ = try alloc.create(joypad.Joypad);
        joypad_.* = joypad.Joypad.new();

        const timer_ = try alloc.create(timer.Timer);
        timer_.* = timer.Timer.new();
        timer_.*.tac.frequency = timer.Frequency.Hz4096;

        const mb = try alloc.create(memory_bus.MemoryBus);
        mb.* = memory_bus.MemoryBus.new(mbc_, gpu_, apu_, timer_, joypad_);

        const cpu_ = try alloc.create(cpu.CPU);
        cpu_.* = cpu.CPU.new(mb, mbc_);

        return Gameboy{
            .mbc = mbc_,
            .cpu = cpu_,
            .gpu = gpu_,
            .apu = apu_,
            .joypad = joypad_,
            .timer = timer_,
            .memory_bus = mb,

            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Gameboy) void {
        self.mbc.deinit();
        self.alloc.destroy(self.mbc);
        self.alloc.destroy(self.cpu);
        self.alloc.destroy(self.gpu);
        self.alloc.destroy(self.apu);
        self.alloc.destroy(self.joypad);
        self.alloc.destroy(self.timer);
        self.alloc.destroy(self.memory_bus);
    }

    pub fn frame(self: *Gameboy) void {
        const cycles_per_frame = CPU_SPEED_HZ / 60;
        var frame_cycles: u64 = 0;
        // std.debug.print("joyp state: 0b{b:0>8}\n", .{@as(u8, @bitCast(self.bus.joypad.joyp))});

        const prev_ticks = self.apu.sdl_total_ticks;
        while (true) {
            const enable_joypad_interrupt = joypad.Joypad.update_joyp_keys(self);
            const joypad_interrupt_flag = ie_register.IERegister{
                .enable_timer = false,
                .enable_vblank = false,
                .enable_lcd_stat = false,
                .enable_serial = false,
                .enable_joypad = enable_joypad_interrupt,
            };
            self.memory_bus.update_if_flags(joypad_interrupt_flag);
            var cpu_cycles_spent = self.cpu.step();
            frame_cycles += cpu_cycles_spent;

            while (cpu_cycles_spent > 0) : (cpu_cycles_spent -= 4) {
                const enable_timer_flag = self.timer.step();
                _ = self.apu.step(self.cpu.clock);
                const gpu_interrupt_requests = self.gpu.step(4);

                const interrupt_flags = ie_register.IERegister{
                    .enable_timer = enable_timer_flag,
                    .enable_vblank = gpu_interrupt_requests.vblank,
                    .enable_lcd_stat = gpu_interrupt_requests.lcd_stat,
                    // whocares
                    .enable_serial = false,
                    .enable_joypad = false,
                };

                self.memory_bus.update_if_flags(interrupt_flags);
            }

            if (frame_cycles >= cycles_per_frame) {
                log.debug("frame_cycles {}", .{frame_cycles});
                break;
            }
        }
        log.debug("apu sdl ticks {}", .{self.apu.sdl_total_ticks - prev_ticks});
    }
};
