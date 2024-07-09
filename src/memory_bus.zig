const std = @import("std");

const joypad = @import("joypad.zig");
const timer = @import("timer.zig");
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
    boot_rom: [0x100]u8,
    memory: [0x10000]u8,
    joypad: joypad.Joypad,
    timer: timer.Timer,
    interrupt_enable: IERegister,
    interrupt_flag: IERegister,

    gpu: GPU,
    pub fn new(boot_rom_buffer: []u8, game_rom: []u8) MemoryBus {
        var memory = [_]u8{0} ** 0x10000;
        var boot_rom = [_]u8{0} ** 0x100;
        for (0x0000..0x0100) |i| {
            // temp separate memory for boot rom, idk what to do with it yet
            // std.debug.print("byte 0x{x}\n", .{boot_rom_buffer[i]});
            boot_rom[i] = boot_rom_buffer[i];
            memory[i] = boot_rom_buffer[i];
        }

        for (0x0000..0x8000) |i| {
            memory[i] = game_rom[i];
        }
        memory[0x07] = 0x00;
        memory[0x10] = 0x80;
        memory[0x11] = 0xBF;
        memory[0x12] = 0xF3;
        memory[0x14] = 0xBF;
        memory[0x16] = 0x3F;
        memory[0x17] = 0x00;
        memory[0x19] = 0xBF;
        memory[0x1A] = 0x7F;
        memory[0x1B] = 0xFF;
        memory[0x1C] = 0x9F;
        memory[0x1E] = 0xBF;
        memory[0x20] = 0xFF;
        memory[0x21] = 0x00;
        memory[0x22] = 0x00;
        memory[0x23] = 0xBF;
        memory[0x24] = 0x77;
        memory[0x25] = 0xF3;
        memory[0x26] = 0xF1;
        memory[0x40] = 0x91;
        memory[0x42] = 0x00;
        memory[0x43] = 0x00;
        memory[0x45] = 0x00;
        memory[0x47] = 0xFC;
        memory[0x48] = 0xFF;
        memory[0x49] = 0xFF;
        memory[0x4A] = 0x00;
        memory[0x4B] = 0x00;
        memory[0xFF] = 0x00;

        // pandocs
        // memory[0xFF00] = 0xCF;
        // memory[0xFF01] = 0x00;
        // memory[0xFF02] = 0x7E;
        // memory[0xFF04] = 0xAB;
        // memory[0xFF05] = 0x00;
        // memory[0xFF06] = 0x00;
        // memory[0xFF07] = 0xF8;
        // memory[0xFF0F] = 0xE1;
        // memory[0xFF10] = 0x80;
        // memory[0xFF11] = 0xBF;
        // memory[0xFF12] = 0xF3;
        // memory[0xFF13] = 0xFF;
        // memory[0xFF14] = 0xBF;
        // memory[0xFF16] = 0x3F;
        // memory[0xFF17] = 0x00;
        // memory[0xFF18] = 0xFF;
        // memory[0xFF19] = 0xBF;
        // memory[0xFF1A] = 0x7F;
        // memory[0xFF1B] = 0xFF;
        // memory[0xFF1C] = 0x9F;
        // memory[0xFF1D] = 0xFF;
        // memory[0xFF1E] = 0xBF;
        // memory[0xFF20] = 0xFF;
        // memory[0xFF21] = 0x00;
        // memory[0xFF22] = 0x00;
        // memory[0xFF23] = 0xBF;
        // memory[0xFF24] = 0x77;
        // memory[0xFF25] = 0xF3;
        // memory[0xFF26] = 0xF1;
        // memory[0xFF40] = 0x91;
        // memory[0xFF41] = 0x85;
        // memory[0xFF42] = 0x00;
        // memory[0xFF43] = 0x00;
        // memory[0xFF44] = 0x00;
        // memory[0xFF45] = 0x00;
        // memory[0xFF46] = 0xFF;
        // memory[0xFF47] = 0xFC;
        // // memory[0xFF48] = 0x?7 ;
        // // memory[0xFF49] = 0x?7 ;
        // memory[0xFF4A] = 0x00;
        // memory[0xFF4B] = 0x00;
        // // memory[0xFF4D] = --   ;
        // // memory[0xFF4F] = --   ;
        // // memory[0xFF51] = --   ;
        // // memory[0xFF52] = --   ;
        // // memory[0xFF53] = --   ;
        // // memory[0xFF54] = --   ;
        // // memory[0xFF55] = --   ;
        // // memory[0xFF56] = --   ;
        // // memory[0xFF68] = --   ;
        // // memory[0xFF69] = --   ;
        // // memory[0xFF6A] = --   ;
        // // memory[0xFF6B] = --   ;
        // // memory[0xFF70] = --   ;
        // memory[0xFFFF] = 0x00;

        var timer_ = timer.Timer.new();
        timer_.tac.frequency = @intFromEnum(timer.Frequency.Hz4096);

        return MemoryBus{
            .boot_rom = boot_rom,
            .memory = memory,
            .gpu = GPU.new(),
            .joypad = joypad.Joypad.new(),
            .timer = timer_,
            .interrupt_enable = @bitCast(@as(u8, 0)),
            .interrupt_flag = @bitCast(@as(u8, 0)),
        };
    }

    pub fn step(self: *MemoryBus, cycles: u64, div: u8) void {
        if (self.timer.step(cycles, div)) {
            // std.debug.print("timer interrupt flag turned on\n", .{});
            self.interrupt_flag.enable_timer = true;
        }

        // TODO: should gpu control memory bus? gpu having direct oam write access?
        // seems like delegating memory control to bus makes more sense
        // would need to hand off the enabled interrupts to the bus from cpu
        const res = self.gpu.step(cycles);

        self.interrupt_flag.enable_lcd_stat = res.enable_lcd_stat;
        self.interrupt_flag.enable_vblank = res.enable_vblank;
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
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                // std.debug.print("Vram byte read\n", .{});
                return self.gpu.read_vram(address);
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                return self.memory[address];
            },
            0xFF00...0xFF7F => {
                return self.read_io(address);
            },
            0xFFFF => {
                return @bitCast(self.interrupt_enable);
            },
            else => {
                // std.debug.print("Non Vram byte read\n", .{});
            },
        }
        return self.memory[address];
    }
    pub fn write_byte(self: *MemoryBus, address: u16, byte: u8) void {
        switch (address) {
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                self.gpu.write_vram(address, byte);
                return;
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                self.gpu.write_oam(address, byte);
                return;
            },
            0xFF00...0xFF7F => {
                self.write_io(address, byte);
                return;
            },
            0xFFFF => {
                self.interrupt_enable = @bitCast(byte);
                return;
            },
            else => {
                // std.debug.print("Implement other writes\n", .{});
            },
        }
        self.memory[address] = byte;
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
                0xFF00 => break :blk self.joypad.joyp.unpressed | 0xF,
                0xFF01 => break :blk 0x00,
                0xFF02 => break :blk 0x00,
                0xFF04 => break :blk self.timer.div,
                0xFF05 => break :blk self.timer.tima,
                0xFF06 => break :blk self.timer.tma,
                0xFF07 => break :blk @bitCast(self.timer.tac),
                0xFF0F => break :blk @bitCast(self.interrupt_flag),
                0xFF40 => break :blk @bitCast(self.gpu.lcdc),
                0xFF41 => break :blk @bitCast(self.gpu.stat),
                0xFF42 => break :blk self.gpu.background_viewport.scy,
                // debug
                0xFF44 => break :blk 0x90,
                // 0xFF44 => break :blk self.gpu.ly,
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
                    self.joypad.joyp = @bitCast(byte);
                },
                // 0xFF01 => break :blk,
                // 0xFF02 => break :blk,
                0xFF01 => std.debug.print("{c}", .{byte}),
                0xFF02 => std.debug.print("{c}", .{byte}),
                0xFF04 => {
                    self.timer.div = 0;
                },
                0xFF05 => self.timer.tima = byte,
                0xFF06 => self.timer.tma = byte,
                0xFF07 => self.timer.tac = @bitCast(byte),
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
                        const value = self.read_byte(dma_high +% dma_low_u16);
                        self.write_byte(0xFE +% dma_low_u16, value);
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
    pub fn get_game_rom_metadata(memory: []u8) GameBoyRomHeader {
        const slice = memory[0x100..0x150];
        const header: *GameBoyRomHeader = @ptrCast(slice);
        return header.*;
    }
};
