const std = @import("std");

const joypad = @import("joypad.zig");
const timer = @import("timer.zig");
const cartridge = @import("cartridge.zig");
const MBC = cartridge.MBC;
const IERegister = @import("ie_register.zig").IERegister;
const gpu = @import("gpu.zig");
const GPU = gpu.GPU;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = std.log.scoped(.bus);

const WRAM_BEGIN: u16 = 0xC000;
const WRAM_END: u16 = 0xDFFF;
const ECHO_RAM_BEGIN: u16 = 0xE000;
const ECHO_RAM_END: u16 = 0xFDFF;

pub const MemoryBus = struct {
    memory: [0x10000]u8,

    gpu: *GPU,
    joypad: *joypad.Joypad,
    timer: *timer.Timer,
    mbc: *MBC,

    interrupt_enable: IERegister,
    interrupt_flag: IERegister,

    pub fn new(mbc_: *MBC, gpu_: *GPU, timer_: *timer.Timer, joypad_: *joypad.Joypad) MemoryBus {
        var memory = [_]u8{0} ** 0x10000;
        std.mem.copyForwards(u8, memory[0..0x7FFF], mbc_.rom[cartridge.FULL_ROM_START..cartridge.FULL_ROM_END]);

        return MemoryBus{
            .memory = memory,

            .gpu = gpu_,
            .joypad = joypad_,
            .timer = timer_,
            .mbc = mbc_,

            .interrupt_enable = @bitCast(@as(u8, 0)),
            .interrupt_flag = @bitCast(@as(u8, 0)),
        };
    }

    pub fn update_if_flags(self: *MemoryBus, new_enabled_if_flags: IERegister) void {
        self.interrupt_flag.enable_vblank = if (new_enabled_if_flags.enable_vblank) true else self.interrupt_flag.enable_vblank;
        self.interrupt_flag.enable_lcd_stat = if (new_enabled_if_flags.enable_lcd_stat) true else self.interrupt_flag.enable_lcd_stat;
        self.interrupt_flag.enable_timer = if (new_enabled_if_flags.enable_timer) true else self.interrupt_flag.enable_timer;
        self.interrupt_flag.enable_joypad = if (new_enabled_if_flags.enable_joypad) true else self.interrupt_flag.enable_joypad;
        self.interrupt_flag.enable_serial = if (new_enabled_if_flags.enable_serial) true else self.interrupt_flag.enable_serial;
    }

    pub fn has_interrupt(self: *MemoryBus) bool {
        return self.interrupt_flag.enable_vblank and self.interrupt_enable.enable_vblank or
            self.interrupt_flag.enable_timer and self.interrupt_enable.enable_timer or
            self.interrupt_flag.enable_lcd_stat and self.interrupt_enable.enable_lcd_stat or
            self.interrupt_flag.enable_serial and self.interrupt_enable.enable_serial or
            self.interrupt_flag.enable_joypad and self.interrupt_enable.enable_joypad;
    }

    pub fn read_byte(self: *const MemoryBus, address: u16) u8 {
        switch (address) {
            cartridge.FULL_ROM_START...cartridge.FULL_ROM_END => |rom_addr| {
                switch (rom_addr) {
                    // 0x0000...0x00FF => {
                    //     // log.debug("Attempted read from boot rom\n", .{});
                    //     return self.memory[address];
                    // },
                    0x0000...0x7FFF => {
                        return self.mbc.read_rom(rom_addr);
                    },
                    else => {},
                }
            },
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                // log.debug("Vram byte read\n", .{});
                return self.gpu.read_vram(address);
            },
            // external ram
            cartridge.RAM_BANK_START...cartridge.RAM_BANK_END => {
                return self.mbc.read_ram(address);
            },
            WRAM_BEGIN...WRAM_END => {
                return self.memory[address];
            },
            ECHO_RAM_BEGIN...ECHO_RAM_END => {
                return self.memory[address - 0x2000];
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                return self.memory[address];
            },
            0xFEA0...0xFEFF => {
                // log.debug("Attempted read from unusable memory\n", .{});
            },
            0xFF00...0xFF7F => {
                return self.read_io(address);
            },
            0xFF80...0xFFFE => {
                return self.memory[address];
            },
            0xFFFF => {
                return @bitCast(self.interrupt_enable);
            },
        }
        return 0xFF;
    }
    pub fn write_byte(self: *MemoryBus, address: u16, byte: u8) void {
        switch (address) {
            0x0000...0x7FFF => {
                // log.debug("Attempted write to rom\n", .{});
                self.mbc.handle_register(address, byte);
                return;
            },
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                self.gpu.write_vram(address, byte);
                return;
            },
            cartridge.RAM_BANK_START...cartridge.RAM_BANK_END => {
                // log.debug("Attempted write to external ram\n", .{});
                self.mbc.write_ram(address, byte);
                return;
            },
            WRAM_BEGIN...WRAM_END => {
                self.memory[address] = byte;
                return;
            },
            ECHO_RAM_BEGIN...ECHO_RAM_END => {
                self.memory[address - 0x2000] = byte;
                return;
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                self.gpu.write_oam(address, byte);
                return;
            },
            0xFEA0...0xFEFF => {
                // log.debug("Attempted write to unusable memory\n", .{});
                // self.memory[address] = byte;
                return;
            },
            0xFF00...0xFF7F => {
                self.write_io(address, byte);
                return;
            },
            0xFF80...0xFFFE => {
                self.memory[address] = byte;
                return;
            },
            0xFFFF => {
                self.interrupt_enable = @bitCast(byte);
                return;
            },
        }
    }

    pub fn read_word(self: *MemoryBus, address: u16) u16 {
        const low = self.read_byte(address);
        const high = self.read_byte(address +% 1);
        return @as(u16, high) << 8 | @as(u16, low);
    }

    pub fn write_word(self: *MemoryBus, address: u16, word: u16) void {
        const low: u8 = @truncate(word);
        const high: u8 = @truncate(word >> 8);
        self.write_byte(address, low);
        self.write_byte(address +% 1, high);
    }

    pub fn read_io(self: *const MemoryBus, io_addr: u16) u8 {
        return blk: {
            switch (io_addr) {
                0xFF00 => {
                    // break :blk self.joypad.joyp.unpressed;
                    // masking the front bits to 11 fixes a load screen issue in the game Donkey Kong
                    // need to validate this lines up with explainer here
                    // https://www.reddit.com/r/EmuDev/comments/5bgcw1/gb_lcd_disableenable_behavior/
                    break :blk 0b1100_0000 | @as(u8, (@bitCast(self.joypad.joyp)));
                },
                0xFF01 => break :blk 0x00,
                0xFF02 => break :blk 0x00,
                0xFF04 => break :blk self.timer.internal_clock.bits.div,
                0xFF05 => break :blk self.timer.tima,
                0xFF06 => break :blk self.timer.tma,
                0xFF07 => break :blk @bitCast(self.timer.tac),
                0xFF0F => break :blk @bitCast(self.interrupt_flag),
                0xFF40 => break :blk @bitCast(self.gpu.lcdc),
                0xFF41 => break :blk @bitCast(self.gpu.stat),
                // 0xFF41 => break :blk @as(u8, @bitCast(self.gpu.stat)) | 0b1100_0000,
                0xFF42 => break :blk self.gpu.background_viewport.scy,
                // debug
                // 0xFF44 => break :blk 0x90,
                0xFF43 => break :blk self.gpu.background_viewport.scx,
                0xFF44 => break :blk self.gpu.ly,
                0xFF45 => break :blk self.gpu.lyc,
                0xFF47 => break :blk @bitCast(self.gpu.bgp),
                0xFF48 => break :blk @bitCast(self.gpu.obp[0]),
                0xFF49 => break :blk @bitCast(self.gpu.obp[1]),
                0xFF4A => break :blk self.gpu.window_position.wy,
                0xFF4B => break :blk self.gpu.window_position.wx,
                0xFFFF => break :blk @bitCast(self.interrupt_enable),
                else => break :blk 0xFF,
            }
        };
    }

    pub fn write_io(self: *MemoryBus, io_addr: u16, byte: u8) void {
        const res = blk: {
            switch (io_addr) {
                0xFF00 => {
                    // possibly need to not overwrite the lower 4 bits
                    self.joypad.joyp.select = @enumFromInt((byte >> 4) & 0b11);
                },
                0xFF01 => break :blk,
                0xFF02 => break :blk,
                // 0xFF01 => log.debug("{c}", .{byte}),
                // 0xFF02 => log.debug("{c}", .{byte}),
                0xFF04 => {
                    self.timer.clock_update(@bitCast(@as(u64, 0)));
                    log.debug("div reset 0b{b}\n", .{@as(u64, @bitCast(self.timer.internal_clock))});
                },
                0xFF05 => {
                    if (!self.timer.tima_reload_cycle) {
                        self.timer.tima = byte;
                    }
                    if (self.timer.tima_cycles_till_interrupt > 0) {
                        self.timer.tima_cycles_till_interrupt = 0;
                    }
                    log.debug("tima {}\n", .{self.timer.tima});
                },
                0xFF06 => {
                    if (self.timer.tima_reload_cycle) {
                        self.timer.tima = byte;
                    }
                    self.timer.tma = byte;
                    log.debug("tma {}\n", .{self.timer.tima});
                },
                0xFF07 => {
                    const new_tac: timer.Tac = @bitCast(byte);
                    const new_enabled_bit = @intFromBool(new_tac.enabled);
                    self.timer.check_falling_edge(self.timer.prev_bit, new_enabled_bit);

                    self.timer.tac = new_tac;
                    log.debug("tac {}\n", .{self.timer.tima});

                    self.timer.prev_bit = new_enabled_bit;
                    // log.debug("self.timer.tac 0b{b:0>8}\n", .{@as(u8, @bitCast(self.timer.tac))});
                },
                0xFF0F => {
                    self.interrupt_flag = @bitCast(byte);
                },
                // sound
                0xFF10 => {},
                0xFF11 => {},
                0xFF12 => {},
                0xFF13 => {},
                0xFF14 => {},
                0xFF16 => {},
                0xFF17 => {},
                0xFF18 => {},
                0xFF19 => {},
                0xFF1A => {},
                0xFF1B => {},
                0xFF1C => {},
                0xFF1D => {},
                0xFF1E => {},
                0xFF20 => {},
                0xFF21 => {},
                0xFF22 => {},
                0xFF23 => {},
                0xFF24 => {},
                0xFF25 => {},
                0xFF26 => {},
                0xFF30...0xFF3F => {},
                0xFF40 => {
                    self.gpu.lcdc = @bitCast(byte);
                    if (!self.gpu.lcdc.lcd_enable) {
                        self.gpu.ly = 0;
                        self.gpu.internal_window_counter = 0;
                        self.gpu.stat.ppu_mode = 0;
                        self.gpu.stat.lyc_ly_compare = false;
                        // self.gpu.stat.mode_0_interrupt_enabled = false;
                        // self.gpu.stat.mode_1_interrupt_enabled = false;
                        // self.gpu.stat.mode_2_interrupt_enabled = false;
                        // self.gpu.stat.lyc_int_interrupt_enabled = false;
                    }
                },
                0xFF41 => {
                    var stat: gpu.Stat = @bitCast(byte);
                    stat.ppu_mode = self.gpu.stat.ppu_mode;
                    stat.lyc_ly_compare = self.gpu.stat.lyc_ly_compare;

                    self.gpu.stat = stat;
                },
                0xFF42 => {
                    self.gpu.background_viewport.scy = byte;
                },
                0xFF43 => {
                    self.gpu.background_viewport.scx = byte;
                },
                0xFF45 => {
                    self.gpu.lyc = byte;
                },
                0xFF46 => {
                    std.debug.assert(byte >= 0x00 and byte <= 0xDF);
                    const dma_high: u16 = @as(u16, byte) << 8;
                    for (0x00..0x9F) |dma_low| {
                        const dma_low_u16 = @as(u16, @intCast(dma_low));
                        const value = self.read_byte(dma_high | dma_low_u16);
                        self.write_byte(0xFE00 +% dma_low_u16, value);
                    }
                },
                0xFF47 => {
                    self.gpu.bgp = @bitCast(byte);
                },
                0xFF48 => {
                    self.gpu.obp[0] = @bitCast(byte);
                },
                0xFF49 => {
                    self.gpu.obp[1] = @bitCast(byte);
                },
                0xFF4A => {
                    self.gpu.window_position.wy = byte;
                },
                0xFF4B => {
                    self.gpu.window_position.wx = byte;
                },
                0xFF50 => {
                    // disable boot rom
                    // for (0x00..0x100) |i| {
                    //     self.memory[i] = 0;
                    // }
                },
                0xFFFF => {
                    self.interrupt_enable = @bitCast(byte);
                },

                else => break :blk,
            }
        };
        _ = res; // autofix
    }
};
