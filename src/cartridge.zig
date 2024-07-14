const std = @import("std");

//
pub const FULL_ROM_START = 0x0000;
pub const FULL_ROM_END = 0x7FFF;

pub const ROM_BANK_X0_START = 0x0000;
pub const ROM_BANK_X0_END = 0x3FFF;

pub const ROM_BANK_N_START = 0x4000;
pub const ROM_BANK_N_END = 0x7FFF;

pub const RAM_BANK_START = 0xA000;
pub const RAM_BANK_END = 0xBFFF;

// register address spaces for MBCs
// MBC1
const MBC1_RAM_ENABLE_START = 0x0000;
const MBC1_RAM_ENABLE_END = 0x1FFF;

const MBC1_ROM_BANK_NUMBER_START = 0x2000;
const MBC1_ROM_BANK_NUMBER_END = 0x3FFF;

const MBC1_RAM_BANK_NUMBER_START = 0x4000;
const MBC1_RAM_BANK_NUMBER_END = 0x5FFF;

const MBC1_ROM_RAM_MODE_SELECT_START = 0x6000;
const MBC1_ROM_RAM_MODE_SELECT_END = 0x7FFF;

// MBC2
const MBC2_RAM_ENABLE_START = 0x0000;
const MBC2_RAM_ENABLE_END = 0x00FF;

const MBC2_ROM_BANK_NUMBER_START = 0x2100;
const MBC2_ROM_BANK_NUMBER_END = 0x21FF;

// MBC3
const MBC3_RAM_RTC_ENABLE_START = 0x0000;
const MBC3_RAM_RTC_ENABLE_END = 0x1FFF;

const MBC3_ROM_BANK_NUMBER_START = 0x2000;
const MBC3_ROM_BANK_NUMBER_END = 0x3FFF;

const MBC3_RAM_RTC_SELECT_START = 0x4000;
const MBC3_RAM_RTC_SELECT_END = 0x5FFF;

const MBC3_RTC_LATCH_CLOCK_DATA_START = 0x6000;
const MBC3_RTC_LATCH_CLOCK_DATA_END = 0x7FFF;

// MBC5
const MBC5_RAM_ENABLE_START = 0x0000;
const MBC5_RAM_ENABLE_END = 0x1FFF;

const MBC5_ROM_BANK_NUMBER_LOW_START = 0x2000;
const MBC5_ROM_BANK_NUMBER_LOW_END = 0x2FFF;

const MBC5_ROM_BANK_NUMBER_HIGH_START = 0x3000;
const MBC5_ROM_BANK_NUMBER_HIGH_END = 0x3FFF;

const MBC5_RAM_BANK_NUMBER_START = 0x4000;
const MBC5_RAM_BANK_NUMBER_END = 0x5FFF;

/// MBC - Memory Bank Controller
const MBCCartridgeType = enum(u8) {
    ROM_ONLY = 0x00,
    MBC1 = 0x01,
    MBC1_RAM = 0x02,
    MBC1_RAM_BATTERY = 0x03,
    MBC2 = 0x05,
    MBC2_BATTERY = 0x06,
    ROM_RAM = 0x08,
    ROM_RAM_BATTERY = 0x09,
    MMM01 = 0x0B,
    MMM01_RAM = 0x0C,
    MMM01_RAM_BATTERY = 0x0D,
    MBC3_TIMER_BATTERY = 0x0F,
    MBC3_TIMER_RAM_BATTERY = 0x10,
    MBC3 = 0x11,
    MBC3_RAM = 0x12,
    MBC3_RAM_BATTERY = 0x13,
    MBC5 = 0x19,
    MBC5_RAM = 0x1A,
    MBC5_RAM_BATTERY = 0x1B,
    MBC5_RUMBLE = 0x1C,
    MBC5_RUMBLE_RAM = 0x1D,
    MBC5_RUMBLE_RAM_BATTERY = 0x1E,
    MBC6 = 0x20,
    MBC7_SENSOR_RUMBLE_RAM_BATTERY = 0x22,
    POCKET_CAMERA = 0xFC,
    BANDAI_TAMA5 = 0xFD,
    HuC3 = 0xFE,
    HuC1_RAM_BATTERY = 0xFF,
};

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

    pub fn num_banks(self: RomSize) u32 {
        switch (self) {
            ._32KB => return 0x02,
            ._64KB => return 0x04,
            ._128KB => return 0x08,
            ._256KB => return 0x10,
            ._512KB => return 0x20,
            ._1MB => return 0x40,
            ._2MB => return 0x80,
            ._4MB => return 0x100,
            ._1_1MB => return 0x48,
            ._1_2MB => return 0x50,
            ._1_5MB => return 0x60,
        }
    }
    pub fn num_bytes(self: RomSize) u32 {
        switch (self) {
            ._32KB => return 0x8000,
            ._64KB => return 0x10000,
            ._128KB => return 0x20000,
            ._256KB => return 0x40000,
            ._512KB => return 0x80000,
            ._1MB => return 0x100000,
            ._2MB => return 0x200000,
            ._4MB => return 0x400000,
            ._1_1MB => return 0x120000,
            ._1_2MB => return 0x140000,
            ._1_5MB => return 0x180000,
        }
    }
};

const RamSize = enum(u8) {
    _None = 0x00,
    _Unused = 0x01,
    _8KB = 0x02,
    _32KB = 0x03,
    _128KB = 0x04,
    _64KB = 0x05,

    pub fn num_bytes(self: RamSize) u32 {
        switch (self) {
            ._None => return 0,
            ._Unused => return 0,
            ._8KB => return 0x2000,
            ._32KB => return 0x8000,
            ._128KB => return 0x20000,
            ._64KB => return 0x10000,
        }
    }

    pub fn num_banks(self: RamSize) u32 {
        switch (self) {
            ._None => return 0,
            ._Unused => return 0,
            ._8KB => return 0x01,
            ._32KB => return 0x04,
            ._128KB => return 0x16,
            ._64KB => return 0x08,
        }
    }
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
    cartridge_type: MBCCartridgeType,
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

pub const MBC1RamAddressSpace = packed struct {
    base: u13,
    ram_bank: u2,
};

pub const MBC1RomAddress = packed struct {
    base: u14,
    rom_bank: u5,
    ram_bank: u2,
};

pub const MBC5RomAddress = packed struct {
    base: u14,
    rom_bank_low: u8,
    rom_bank_high: u1,
};

pub const MBC5RamAddress = packed struct {
    base: u13,
    ram_bank: u4,
};

pub const MBC3RomAddress = packed struct {
    base: u14,
    rom_bank: u7,
};

pub const MBC3RamAddress = packed struct {
    base: u13,
    ram_bank: u2,
};

pub const MBC3RTCAddress = packed struct {
    base: u13,
    rtc_register: u3,
};

pub const MBC = struct {
    filename: []u8,
    header: GameBoyRomHeader,
    rom: []u8,
    ram: []u8,

    rom_bank: u16,
    ram_bank: u8,
    ram_enabled: bool,
    banking_mode: u8,
    mbc_type: MBCCartridgeType,
    rom_size: RomSize,
    ram_size: RamSize,

    gpa: std.heap.GeneralPurposeAllocator(.{}),
    allocator: std.mem.Allocator,

    pub fn handle_register(self: *MBC, address: u16, byte: u8) void {
        switch (self.mbc_type) {
            MBCCartridgeType.ROM_ONLY => {},

            MBCCartridgeType.MBC1,
            MBCCartridgeType.MBC1_RAM,
            MBCCartridgeType.MBC1_RAM_BATTERY,
            => {
                switch (address) {
                    MBC1_RAM_ENABLE_START...MBC1_RAM_ENABLE_END => {
                        self.ram_enabled = if ((byte & 0x0F) == 0x0A) true else false;
                    },
                    MBC1_ROM_BANK_NUMBER_START...MBC1_ROM_BANK_NUMBER_END => {
                        // mask to 5 bits
                        var masked_bank = byte & 0x1F;
                        // 0 is set to 1, looking at all 5 bits
                        masked_bank = if (masked_bank == 0) 1 else masked_bank;
                        // after, we mask to the size of the cart
                        const rom_banks = @as(u8, @truncate(self.rom_size.num_banks()));
                        masked_bank = masked_bank & (rom_banks - 1);
                        // const new_bank = self.rom_bank & 0b0110_0000;
                        // self.rom_bank = new_bank | masked_bank;
                        self.rom_bank = masked_bank;
                    },
                    MBC1_RAM_BANK_NUMBER_START...MBC1_RAM_BANK_NUMBER_END => {
                        self.ram_bank = byte;
                    },
                    MBC1_ROM_RAM_MODE_SELECT_START...MBC1_ROM_RAM_MODE_SELECT_END => {
                        self.banking_mode = byte & 0x01;
                    },
                    else => {},
                }
            },
            MBCCartridgeType.MBC5,
            MBCCartridgeType.MBC5_RAM,
            MBCCartridgeType.MBC5_RAM_BATTERY,
            MBCCartridgeType.MBC5_RUMBLE,
            MBCCartridgeType.MBC5_RUMBLE_RAM,
            MBCCartridgeType.MBC5_RUMBLE_RAM_BATTERY,
            => {
                switch (address) {
                    MBC5_RAM_ENABLE_START...MBC5_RAM_ENABLE_END => {
                        self.ram_enabled = (byte & 0x0F) == 0x0A;
                    },
                    MBC5_ROM_BANK_NUMBER_LOW_START...MBC5_ROM_BANK_NUMBER_LOW_END => {
                        self.rom_bank = (self.rom_bank & 0x100) | byte;
                    },
                    MBC5_ROM_BANK_NUMBER_HIGH_START...MBC5_ROM_BANK_NUMBER_HIGH_END => {
                        self.rom_bank = (self.rom_bank & 0xFF) | (@as(u16, byte & 0x01) << 8);
                    },
                    MBC5_RAM_BANK_NUMBER_START...MBC5_RAM_BANK_NUMBER_END => {
                        self.ram_bank = byte & 0x0F;
                    },
                    else => {},
                }
            },
            // complete the switch for mbc3
            MBCCartridgeType.MBC3,
            MBCCartridgeType.MBC3_RAM,
            MBCCartridgeType.MBC3_RAM_BATTERY,
            MBCCartridgeType.MBC3_TIMER_BATTERY,
            MBCCartridgeType.MBC3_TIMER_RAM_BATTERY,
            => {
                switch (address) {
                    MBC3_RAM_RTC_ENABLE_START...MBC3_RAM_RTC_ENABLE_END => {
                        self.ram_enabled = (byte & 0x0F) == 0x0A;
                    },
                    MBC3_ROM_BANK_NUMBER_START...MBC3_ROM_BANK_NUMBER_END => {
                        self.rom_bank = if (byte == 0) 1 else byte & 0x7F;
                    },
                    MBC3_RAM_RTC_SELECT_START...MBC3_RAM_RTC_SELECT_END => {
                        self.ram_bank = byte;
                    },
                    MBC3_RTC_LATCH_CLOCK_DATA_START...MBC3_RTC_LATCH_CLOCK_DATA_END => {
                        // Implement RTC latch functionality if needed
                    },
                    else => {},
                }
            },

            else => {},
        }
    }

    pub fn read_rom(self: *const MBC, address: u16) u8 {
        switch (self.mbc_type) {
            MBCCartridgeType.ROM_ONLY => {
                return self.rom[address];
            },

            MBCCartridgeType.MBC1,
            MBCCartridgeType.MBC1_RAM,
            MBCCartridgeType.MBC1_RAM_BATTERY,
            => {
                switch (address) {
                    ROM_BANK_X0_START...ROM_BANK_X0_END => {
                        const mbc1_address = MBC1RomAddress{
                            .base = @truncate(address),
                            .rom_bank = 0,
                            .ram_bank = if (self.banking_mode == 1) @truncate(self.ram_bank) else 0,
                        };

                        return self.rom[@as(u21, @bitCast(mbc1_address))];
                    },
                    ROM_BANK_N_START...ROM_BANK_N_END => {
                        const mbc1_address = MBC1RomAddress{
                            .base = @truncate(address),
                            .rom_bank = @truncate(self.rom_bank),
                            .ram_bank = @truncate(self.ram_bank),
                        };
                        const full_address = @as(u21, @bitCast(mbc1_address));
                        // std.debug.print("ram bank: {} full_addr 0x{x}\n", .{ self.rom_bank, full_address });
                        return self.rom[full_address];
                    },
                    else => {
                        return 0xFF;
                    },
                }
            },
            MBCCartridgeType.MBC5,
            MBCCartridgeType.MBC5_RAM,
            MBCCartridgeType.MBC5_RAM_BATTERY,
            MBCCartridgeType.MBC5_RUMBLE,
            MBCCartridgeType.MBC5_RUMBLE_RAM,
            MBCCartridgeType.MBC5_RUMBLE_RAM_BATTERY,
            => {
                switch (address) {
                    ROM_BANK_X0_START...ROM_BANK_X0_END => {
                        return self.rom[address];
                    },
                    ROM_BANK_N_START...ROM_BANK_N_END => {
                        const mbc5_address = MBC5RomAddress{
                            .base = @truncate(address),
                            .rom_bank_low = @truncate(self.rom_bank),
                            .rom_bank_high = @truncate(self.rom_bank >> 8 & 0x01),
                        };
                        const full_address = @as(u23, @bitCast(mbc5_address));
                        std.debug.print("ram bank: {} full_addr 0x{x}\n", .{ self.rom_bank, full_address });
                        return self.rom[full_address];
                    },
                    else => {
                        return 0xFF;
                    },
                }
            },
            MBCCartridgeType.MBC3,
            MBCCartridgeType.MBC3_RAM,
            MBCCartridgeType.MBC3_RAM_BATTERY,
            MBCCartridgeType.MBC3_TIMER_BATTERY,
            MBCCartridgeType.MBC3_TIMER_RAM_BATTERY,
            => {
                switch (address) {
                    ROM_BANK_X0_START...ROM_BANK_X0_END => {
                        return self.rom[address];
                    },
                    ROM_BANK_N_START...ROM_BANK_N_END => {
                        const mbc3_address = MBC3RomAddress{
                            .base = @truncate(address),
                            .rom_bank = @truncate(self.rom_bank),
                        };
                        const full_address = @as(u21, @bitCast(mbc3_address));
                        return self.rom[full_address];
                    },
                    else => {
                        return 0xFF;
                    },
                }
            },
            else => unreachable,
        }
    }

    pub fn read_ram(self: *const MBC, address: u16) u8 {
        switch (self.mbc_type) {
            MBCCartridgeType.ROM_ONLY => {
                return self.ram[address];
            },
            MBCCartridgeType.MBC1,
            MBCCartridgeType.MBC1_RAM,
            MBCCartridgeType.MBC1_RAM_BATTERY,
            => {
                if (!self.ram_enabled) {
                    return 0xFF;
                }
                switch (address) {
                    RAM_BANK_START...RAM_BANK_END => {
                        const mbc1_address = MBC1RamAddressSpace{
                            .base = @truncate(address),
                            .ram_bank = if (self.banking_mode == 1) @truncate(self.ram_bank) else 0,
                        };
                        return self.ram[@as(u15, @bitCast(mbc1_address))];
                    },
                    else => {
                        return 0xFF;
                    },
                }
            },
            MBCCartridgeType.MBC5,
            MBCCartridgeType.MBC5_RAM,
            MBCCartridgeType.MBC5_RAM_BATTERY,
            MBCCartridgeType.MBC5_RUMBLE,
            MBCCartridgeType.MBC5_RUMBLE_RAM,
            MBCCartridgeType.MBC5_RUMBLE_RAM_BATTERY,
            => {
                if (!self.ram_enabled) {
                    return 0xFF;
                }
                switch (address) {
                    RAM_BANK_START...RAM_BANK_END => {
                        const mbc5_address = MBC5RamAddress{
                            .base = @truncate(address),
                            .ram_bank = @truncate(self.ram_bank),
                        };
                        const full_address = @as(u17, @bitCast(mbc5_address));
                        // std.debug.print("ram bank: {} full_addr 0x{x}\n", .{ self.ram_bank, full_address });
                        return self.ram[full_address];
                    },
                    else => {
                        return 0xFF;
                    },
                }
            },
            MBCCartridgeType.MBC3,
            MBCCartridgeType.MBC3_RAM,
            MBCCartridgeType.MBC3_RAM_BATTERY,
            MBCCartridgeType.MBC3_TIMER_BATTERY,
            MBCCartridgeType.MBC3_TIMER_RAM_BATTERY,
            => {
                if (!self.ram_enabled) {
                    return 0xFF;
                }
                switch (address) {
                    RAM_BANK_START...RAM_BANK_END => {
                        if (self.ram_bank <= 0x03) {
                            const mbc3_address = MBC3RamAddress{
                                .base = @truncate(address),
                                .ram_bank = @truncate(self.ram_bank),
                            };
                            const full_address = @as(u15, @bitCast(mbc3_address));
                            return self.ram[full_address];
                        } else {
                            // RTC register access
                            // Implement RTC register reading if needed
                            return 0xFF;
                        }
                    },
                    else => {
                        return 0xFF;
                    },
                }
            },
            else => unreachable,
        }
    }

    pub fn set_ram_enabled(self: *MBC, byte: u8) void {
        self.ram_enabled = if ((byte & 0x0F) == 0x0A) true else false;
    }

    /// this has dual purpose for MBC1
    /// in mode 0, it selects the upper 2 bits of the ROM bank number
    /// in mode 1, it selects the RAM bank number
    pub fn set_ram_bank(self: *MBC, bank: u8) void {
        self.ram_bank = bank & 0x03;
    }
    pub fn set_rom_bank_number(self: *MBC, bank: u8) void {
        // mask to 5 bits
        var masked_bank = bank & 0x1F;
        // 0 is set to 1, looking at all 5 bits
        masked_bank = if (masked_bank == 0) 1 else masked_bank;
        // after, we mask to the size of the cart
        const rom_banks = @as(u8, @truncate(self.rom_size.num_banks()));
        masked_bank = masked_bank & (rom_banks - 1);
        // const new_bank = self.rom_bank & 0b0110_0000;
        // self.rom_bank = new_bank | masked_bank;
        self.rom_bank = masked_bank;

        // note: do not understand the 0x20 0x40 0x60 issues mentioned in docs
    }
    pub fn set_ram_bank_number(self: *MBC, bank: u8) void {
        self.ram_bank = bank;
    }

    // 0 -> 0x0000-0x3FFF and 0xA000-0xBFFF locked to rom bank 0 / sram
    // 1 -> the above can be bank switched
    pub fn set_banking_mode(self: *MBC, mode: u8) void {
        self.banking_mode = mode & 0x01;
    }

    pub fn new(filename: []u8) !MBC {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const size = try file.getEndPos();

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        const rom = try allocator.alloc(u8, size);
        _ = try file.readAll(rom);
        const header = get_game_rom_metadata(rom);

        const ram = try allocator.alloc(u8, header.ram_size.num_bytes());

        std.debug.print("cartridge type: {}, rom size: {}, ram size: {}\n", .{
            header.cartridge_type,
            header.rom_size,
            header.ram_size,
        });

        return MBC{
            .filename = filename,
            .header = header,
            .rom = rom,
            .ram = ram,
            .rom_bank = 1,
            .ram_bank = 0,
            .ram_enabled = false,
            .banking_mode = 0,
            .mbc_type = header.cartridge_type,
            .rom_size = header.rom_size,
            .ram_size = header.ram_size,

            .gpa = gpa,
            .allocator = allocator,
        };
    }

    // lives for entire program, no need to worry about this
    pub fn deinit(self: *MBC) void {
        self.allocator.free(self.ram);
        self.allocator.free(self.rom);
        self.gpa.deinit();
    }
};
pub fn get_game_rom_metadata(memory: []u8) GameBoyRomHeader {
    const slice = memory[0x100..0x150];
    const header: *GameBoyRomHeader = @ptrCast(slice);
    return header.*;
}
