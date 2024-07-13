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
    _8KB = 0x03,
    _32KB = 0x04,
    _128KB = 0x05,
    _64KB = 0x06,

    pub fn num_bytes(self: RamSize) u32 {
        switch (self) {
            ._None => return 0,
            ._8KB => return 0x2000,
            ._32KB => return 0x8000,
            ._128KB => return 0x20000,
            ._64KB => return 0x10000,
        }
    }

    pub fn num_banks(self: RamSize) u32 {
        switch (self) {
            ._None => return 0,
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

pub const MBC = struct {
    filename: []u8,
    header: GameBoyRomHeader,
    rom: []u8,
    ram: []u8,

    rom_bank: u8,
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
            MBCCartridgeType.MBC1 => {
                switch (address) {
                    MBC1_RAM_ENABLE_START...MBC1_RAM_ENABLE_END => {
                        self.set_ram_enabled(byte);
                    },
                    MBC1_ROM_BANK_NUMBER_START...MBC1_ROM_BANK_NUMBER_END => {
                        self.set_rom_bank_number(byte);
                    },
                    MBC1_RAM_BANK_NUMBER_START...MBC1_RAM_BANK_NUMBER_END => {
                        if (self.banking_mode == 0) {
                            self.set_upper_rom_bank_number(byte);
                        } else {
                            self.set_ram_bank_number(byte);
                        }
                    },
                    MBC1_ROM_RAM_MODE_SELECT_START...MBC1_ROM_RAM_MODE_SELECT_END => {
                        self.set_banking_mode(byte);
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
            MBCCartridgeType.MBC1 => {
                switch (address) {
                    ROM_BANK_X0_START...ROM_BANK_X0_END => {
                        return self.rom[address];
                    },
                    ROM_BANK_N_START...ROM_BANK_N_END => {
                        return self.rom[address + (@as(u16, self.rom_bank) * 0x4000)];
                    },
                    else => {
                        return 0;
                    },
                }
            },
            else => unreachable,
        }
    }

    pub fn read_ram(self: *MBC, address: u16) u8 {
        switch (self.mbc_type) {
            MBCCartridgeType.ROM_ONLY => {
                return self.rom[address];
            },
            MBCCartridgeType.MBC1 => {
                switch (address) {
                    RAM_BANK_START...RAM_BANK_END => {
                        return self.rom[address + (self.ram_bank * 0x2000)];
                    },
                    else => {
                        return 0;
                    },
                }
            },
            else => unreachable,
        }
    }

    pub fn set_ram_enabled(self: *MBC, byte: u8) void {
        self.ram_enabled = if ((byte & 0x0F) == 0x0A) true else false;
    }

    pub fn set_upper_rom_bank_number(self: *MBC, bank: u8) void {
        var masked_bank = bank & 0x03;
        const rom_banks = @intFromEnum(self.rom_size.num_banks());
        masked_bank = masked_bank & (rom_banks - 1);
        const new_banks = self.rom_bank & 0b0001_1111;

        self.rom_bank = new_banks | masked_bank;
    }
    pub fn set_rom_bank_number(self: *MBC, bank: u8) void {
        // mask to 5 bits
        var masked_bank = bank & 0x1F;
        // 0 is set to 1, looking at all 5 bits
        masked_bank = if (masked_bank == 0) 1 else masked_bank;
        // after, we mask to the size of the cart
        const rom_banks = @intFromEnum(self.rom_size.num_banks());
        masked_bank = masked_bank & (rom_banks - 1);
        const new_bank = self.rom_bank & 0b0110_0000;
        self.rom_bank = new_bank | masked_bank;

        // TODO:
        // secondary banks
        // const secondary_bank = 0x12345;
        // masked_bank = (secondary_bank << 5) | masked_bank;

        // note: do not understand the 0x20 0x40 0x60 issues mentioned in docs
    }
    pub fn set_ram_bank_number(self: *MBC, bank: u8) void {
        self.debug.assert(self.ram_size == RamSize._32KB, "only 32KB ram supported");
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
