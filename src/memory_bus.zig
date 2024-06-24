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
    divider: timer.Timer,
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

        var divider = timer.Timer.new();
        divider.tac.enabled = true;
        divider.tac.frequency = @intFromEnum(timer.Frequency.Hz16384);

        var timer_ = timer.Timer.new();
        timer_.tac.frequency = @intFromEnum(timer.Frequency.Hz4096);

        return MemoryBus{
            .boot_rom = boot_rom,
            .memory = memory,
            .gpu = GPU.new(),
            .joypad = joypad.Joypad.new(),
            .divider = divider,
            .timer = timer_,
            .interrupt_enable = @bitCast(@as(u8, 0)),
            .interrupt_flag = @bitCast(@as(u8, 0)),
        };
    }

    pub fn step(self: *MemoryBus, cycles: u8) void {
        if (self.timer.step(cycles)) {
            self.interrupt_flag.enable_timer = true;
        }
        self.divider.step(cycles);

        const res = self.gpu.step(cycles);
        self.interrupt_flag.enable_lcd_stat |= res.enable_lcd_stat;
        self.interrupt_flag.enable_vblank |= res.enable_vblank;
    }

    pub fn has_interrupt(self: *MemoryBus) bool {
        return self.interrupt_flag.enable_vblank and self.interrupt_enable.enable_vblank or
            self.interrupt_flag.enable_timer and self.interrupt_enable.enable_timer or
            self.interrupt_flag.enable_lcd_stat and self.interrupt_enable.enable_lcd_stat or
            self.interrupt_flag.enable_serial and self.interrupt_enable.enable_serial or
            self.interrupt_flag.enable_joypad and self.interrupt_enable.enable_joypad;
    }

    pub fn read_byte(self: *const MemoryBus, address: u16) u8 {
        const addr = @as(usize, address);
        switch (addr) {
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                // std.debug.print("Vram byte read\n", .{});
                return self.gpu.read_vram(addr);
            },
            else => {
                // std.debug.print("Non Vram byte read\n", .{});
            },
        }
        return self.memory[address];
    }
    pub fn write_byte(self: *MemoryBus, address: u16, byte: u8) void {
        const addr = @as(usize, address);
        switch (addr) {
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                self.gpu.write_vram(addr, byte);
                return;
            },
            else => {
                // std.debug.print("Implement other writes\n", .{});
            },
        }
        self.memory[addr] = byte;
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

    pub fn read_io(self: *MemoryBus, io_addr: u16) u8 {
        return blk: {
            switch (io_addr) {
                0xFF00 => break :blk self.joypad.to_bytes(),
                0xFF01 => break :blk 0x00,
                0xFF02 => break :blk 0x00,
                0xFF04 => break :blk self.divider.tima,
                0xFF0F => break :blk @bitCast(self.interrupt_flag),
                0xFF40 => break :blk @bitCast(self.gpu.lcdc),
                0xFF41 => break :blk @bitCast(self.gpu.stat),
                0xFF42 => break :blk self.gpu.background_viewport.scy,
                // 0xFF44 => break :blk self.gpu.ly,
                // debug
                0xFF44 => break :blk 0x90,
                // 0xFF45 => break :blk self.gpu.lyc,
                else => break :blk 0x00,
            }
        };
    }

    pub fn write_io(self: *MemoryBus, io_addr: u16, byte: u8) void {
        const res = blk: {
            switch (io_addr) {
                0xFF00 => {
                    if (self.joypad.is_action_row) {
                        self.joypad.action = @bitCast(byte);
                    } else {
                        self.joypad.direction = @bitCast(byte);
                    }
                },
                0xFF01 => break :blk,
                0xFF02 => break :blk,
                0xFF04 => {
                    self.divider.tima = 0;
                },
                0xFF05 => self.timer.tima = byte,
                0xFF06 => self.timer.tma = byte,
                0xFF07 => self.timer.tma = @bitCast(byte),
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
                //
                0xFF40 => {
                    self.gpu.lcdc = @bitCast(byte);
                },
                0xFF41 => {
                    self.gpu.stat = @bitCast(byte);
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
                    const dma_high = @as(u16, byte) << 8;
                    for (0x00..0x9F) |dma_low| {
                        const value = self.read_byte(dma_high +% dma_low);
                        self.write_byte(0xFE +% dma_low, value);
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
