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

const RomSize = enum(u8) {
    _32KB = 0x00,
    _64KB = 0x01,
    _128KB = 0x02,
    _256KB = 0x03,
    _512KB = 0x04,
    _1MB = 0x05,
    _2MB = 0x06,
    _4MB = 0x07,
    _1_1MB = 0x52,
    _1_2MB = 0x53,
    _1_5MB = 0x54,
};

const RamSize = enum(u8) {
    _None = 0x00,
    _2KB = 0x01,
    _8KB = 0x02,
    _32KB = 0x03,
};

/// this isnt consistent
// 0x0134 - 0x0143
const Title = extern struct {
    // 0x0134 - 0x013E
    title: [11]u8,
    // 0x013F - 0x0142
    manufacturer_code: [4]u8,
    // 0x0143
    cgb_flag: u8,
};

const GameBoyRomHeader = extern struct {
    // 0x0100 - 0x0103
    entry_point: [4]u8,
    // 0x0104 - 0x0133
    nintendo_logo: [48]u8,
    // 0x0134 - 0x0143
    title: Title,
    // 0x0144 - 0x0145
    new_licensee_code: [2]u8,
    // 0x0146
    sgb_flag: u8,
    // 0x0147
    cartridge_type: u8,
    // 0x0148
    rom_size: RomSize,
    // 0x0149
    ram_size: RamSize,
    // 0x014A
    destination_code: u8,
    // 0x014B
    old_licensee_code: u8,
    // 0x014C
    mask_rom_version: u8,
    // 0x014D
    header_checksum: u8,
    // 0x014E - 0x014F
    global_checksum: [2]u8,
};
pub const MemoryBus = struct {
    memory: [0x10000]u8,

    gpu: GPU,
    joypad: joypad.Joypad,
    timer: timer.Timer,
    mbc: MBC,

    interrupt_enable: IERegister,
    interrupt_flag: IERegister,

    pub fn new(mbc_: MBC, gpu_: GPU, timer_: timer.Timer, joypad_: joypad.Joypad) !MemoryBus {
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
                    //     // std.debug.print("Attempted read from boot rom\n", .{});
                    //     return self.memory[address];
                    // },
                    0x0000...0x7FFF => {
                        return self.mbc.read_rom(rom_addr);
                    },
                    else => {},
                }
            },
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                // std.debug.print("Vram byte read\n", .{});
                return self.gpu.read_vram(address);
            },
            // external ram
            cartridge.RAM_BANK_START...cartridge.RAM_BANK_END => {
                return self.mbc.read_ram(address);
            },
            0xC000...0xFDFF => {
                // wram eram
                // self.memory[address] = byte;
                return self.memory[address];
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                return self.memory[address];
            },
            0xFEA0...0xFEFF => {
                // std.debug.print("Attempted read from unusable memory\n", .{});
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
                // std.debug.print("Attempted write to rom\n", .{});
                self.mbc.handle_register(address, byte);
                return;
            },
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                self.gpu.write_vram(address, byte);
                return;
            },
            0xA000...0xBFFF => {
                // std.debug.print("Attempted write to external ram\n", .{});
                self.memory[address] = byte;
                return;
            },
            0xC000...0xFDFF => {
                // self.memory[address] = byte;
                self.memory[address] = byte;
                return;
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                self.gpu.write_oam(address, byte);
                return;
            },
            0xFEA0...0xFEFF => {
                // std.debug.print("Attempted write to unusable memory\n", .{});
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
                    break :blk self.joypad.joyp.unpressed;
                },
                0xFF01 => break :blk 0x00,
                0xFF02 => break :blk 0x00,
                0xFF04 => break :blk self.timer.div,
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
                // 0xFF01 => break :blk,
                // 0xFF02 => break :blk,
                0xFF01 => std.debug.print("{c}", .{byte}),
                0xFF02 => std.debug.print("{c}", .{byte}),
                0xFF04 => {
                    // theres a bunch of obscure timing accuracy fixes like this that will make things impossible to read
                    const bit_9_low = (self.timer.div & 0b1) == 1;
                    self.timer.div = 0;
                    self.timer.tima = self.timer.tma;
                    if (bit_9_low) {
                        self.timer.tima += 1;
                    }
                },
                0xFF05 => self.timer.tima = byte,
                0xFF06 => self.timer.tma = byte,
                0xFF07 => {
                    const new_tac: timer.Tac = @bitCast(byte);
                    self.timer.tac = new_tac;
                    // std.debug.print("self.timer.tac 0b{b:0>8}\n", .{@as(u8, @bitCast(self.timer.tac))});
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
                    for (0x00..0x100) |i| {
                        self.memory[i] = 0;
                    }
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
