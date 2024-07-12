const std = @import("std");

const ROM_BANK_X0_START = 0x0000;
const ROM_BANK_X0_END = 0x3FFF;

const ROM_BANK_N_START = 0x4000;
const ROM_BANK_N_END = 0x7FFF;

const RAM_BANK_START = 0xA000;
const RAM_BANK_END = 0xBFFF;

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

const MBC = struct {
    rom: [0x8000]u8,
    ram: [0x2000]u8,
    rom_bank: u8,
    ram_bank: u8,
    ram_enabled: bool,
    mbc_type: MBCCartridgeType,
    rom_size: RomSize,
    ram_size: RamSize,

    pub fn ram_enabled(self: *MBC) void {
        self.ram_enabled = true;
        // probably in mmio react to setting this within range
        // 0x0000...0x1FFF
        self.rom[0x0000] = 0xA;
    }
    pub fn set_rom_bank_number(self: *MBC, bank: u8) void {
        // mask to 5 bits
        var masked_bank = bank & 0x1F;
        // 0 is set to 1, looking at all 5 bits
        masked_bank = if (masked_bank == 0) 1 else masked_bank;
        self.rom_bank = masked_bank;
        // after, we mask to the size of the cart
        const rom_banks = @intFromEnum(self.rom_size.num_banks());
        masked_bank = masked_bank & (rom_banks - 1);

        // TODO:
        // secondary banks
        // const secondary_bank = 0x12345;
        // masked_bank = (secondary_bank << 5) | masked_bank;

        // 0x2000...0x3FFF
        self.rom[0x2000] = masked_bank;

        // note: do not understand the 0x20 0x40 0x60 issues mentioned in docs
    }
    pub fn set_ram_bank_number(self: *MBC, bank: u8) void {
        self.debug.assert(self.ram_size == RamSize._32KB, "only 32KB ram supported");
        self.ram_bank = bank;
    }

    // 0 -> 0x0000-0x3FFF and 0xA000-0xBFFF locked to rom bank 0 / sram
    // 1 -> the above can be bank switched
    pub fn set_banking_mode(self: *MBC, mode: u8) void {
        // 0x0000...0x1FFF
        self.rom[0x6000] = mode;
    }

    pub fn new(header: GameBoyRomHeader) MBC {
        return MBC{
            .rom_bank = 1,
            .ram_bank = 0,
            .ram_enabled = false,
            .mbc_type = header.cartridge_type,
            .rom_size = header.rom_size,
            .ram_size = header.ram_size,
            .rom = undefined,
            .ram = undefined,
        };
    }
};
