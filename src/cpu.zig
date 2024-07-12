const std = @import("std");
const MemoryBus = @import("memory_bus.zig").MemoryBus;

const Joypad = @import("joypad.zig").Joypad;
const timer = @import("timer.zig");
const IERegister = @import("ie_register.zig").IERegister;
const gpu = @import("gpu.zig");
const GPU = gpu.GPU;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

const out = std.io.getStdOut();
pub var buf = std.io.bufferedWriter(out.writer());
pub const log = buf.writer();

const HaltState = enum {
    SwitchedOn,
    Enabled,
    Bugged,
    Disabled,
};

const IME = enum {
    Disabled,
    /// EI register "turns on" IME, but it takes an extra instruction for it to actually be enabled
    /// this isn't the case for RETI
    EILagCycle,
    Enabled,
};

const ISR = enum(u16) {
    VBlank = 0x0040,
    LCDStat = 0x0048,
    Timer = 0x0050,
    Serial = 0x0058,
    Joypad = 0x0060,
};

const Registers = struct {
    A: u8,
    B: u8,
    C: u8,
    D: u8,
    E: u8,
    F: FlagRegister,
    H: u8,
    L: u8,

    fn get_AF(self: *Registers) u16 {
        const fu8: u8 = @bitCast(self.F);
        return @as(u16, self.A) << 8 | @as(u16, fu8);
    }

    fn set_AF(self: *Registers, value: u16) void {
        self.A = @truncate((value & 0xFF00) >> 8);
        const trunc: u8 = @truncate(value & 0xF0);
        self.F = @bitCast(trunc);
    }

    fn get_BC(self: *Registers) u16 {
        return @as(u16, self.B) << 8 | @as(u16, self.C);
    }

    fn set_BC(self: *Registers, value: u16) void {
        self.B = @truncate((value & 0xFF00) >> 8);
        self.C = @truncate(value & 0xFF);
    }

    fn get_DE(self: *Registers) u16 {
        return @as(u16, self.D) << 8 | @as(u16, self.E);
    }

    fn set_DE(self: *Registers, value: u16) void {
        self.D = @truncate((value & 0xFF00) >> 8);
        self.E = @truncate(value & 0xFF);
    }

    fn get_HL(self: *Registers) u16 {
        return @as(u16, self.H) << 8 | @as(u16, self.L);
    }

    fn set_HL(self: *Registers, value: u16) void {
        self.H = @truncate((value & 0xFF00) >> 8);
        self.L = @truncate(value & 0xFF);
    }
};

// Least to most significant bit for packed struct
// F register is 4 most significant bits as flags
// zshcxxxx
const FlagRegister = packed struct {
    _padding: u4 = 0,
    carry: bool,
    half_carry: bool,
    subtract: bool,
    zero: bool,
};

const PrefixExtendedArgs = struct {
    bit: ?u3 = null,
    r8_cycles: u8,
    hl_cycles: u8,
};

const ArithmeticTarget = enum {
    A,
    B,
    C,
    D,
    E,
    H,
    L,
    HL,
    D8,
};

const WideArithmeticTarget = enum {
    BC,
    DE,
    HL,
    SP,
};

const JumpTest = enum {
    NotZero,
    Zero,
    NotCarry,
    Carry,
    Always,
};

const RstLocation = enum(u8) {
    Rst00 = 0x00,
    Rst08 = 0x08,
    Rst10 = 0x10,
    Rst18 = 0x18,
    Rst20 = 0x20,
    Rst28 = 0x28,
    Rst30 = 0x30,
    Rst38 = 0x38,
};

const LoadByteTarget = enum { A, B, C, D, E, H, L, HLI };

const LoadByteSource = enum { A, B, C, D, E, H, L, D8, HLI };

const LoadWordTarget = enum { BC, DE, HL, SP };

const Indirect = enum {
    BCIndirect,
    DEIndirect,
    HLIndirectPlus,
    HLIndirectMinus,
    WordIndirect,
    LastByteIndirect,
};

const LoadType = union(enum) {
    Byte: struct { target: LoadByteTarget, source: LoadByteSource },
    Word: LoadWordTarget,
    AFromIndirect: Indirect,
    IndirectFromA: Indirect,
    AFromByteAddress,
    ByteAddressFromA,
    SPFromHL,
    HLFromSPN,
    IndirectFromSP,
};

const StackTarget = enum { BC, DE, HL, AF };

const PrefixTarget = enum { B, C, D, E, H, L, HLI, A };

const Instruction = union(enum) {
    ADD: ArithmeticTarget,
    WADD: WideArithmeticTarget,
    SPADD: void,
    ADC: ArithmeticTarget,
    SUB: ArithmeticTarget,
    SBC: ArithmeticTarget,
    AND: ArithmeticTarget,
    XOR: ArithmeticTarget,
    OR: ArithmeticTarget,
    CP: ArithmeticTarget,
    INC: ArithmeticTarget,
    WINC: WideArithmeticTarget,
    DEC: ArithmeticTarget,
    WDEC: WideArithmeticTarget,
    DAA: void,
    CPL: void,
    CCF: void,
    SCF: void,
    RLCA: void,
    RLA: void,
    RRCA: void,
    RRA: void,
    JP: JumpTest,
    JPI: void,
    JR: JumpTest,
    LD: LoadType,
    PUSH: StackTarget,
    POP: StackTarget,
    CALL: JumpTest,
    RET: JumpTest,
    RST: RstLocation,
    NOP: void,
    STOP: void,
    HALT: void,
    // prefixed
    RLC: PrefixTarget,
    RRC: PrefixTarget,
    RL: PrefixTarget,
    RR: PrefixTarget,
    SLA: PrefixTarget,
    SRA: PrefixTarget,
    SWAP: PrefixTarget,
    SRL: PrefixTarget,
    BIT: struct { target: PrefixTarget, bit: u3 },
    SET: struct { target: PrefixTarget, bit: u3 },
    RES: struct { target: PrefixTarget, bit: u3 },
    EI: void,
    DI: void,
    RETI: void,

    fn from_byte(byte: u8, prefixed: bool) ?Instruction {
        if (prefixed) {
            return Instruction.from_byte_prefixed(byte);
        } else {
            return Instruction.from_byte_not_prefixed(byte);
        }
    }

    fn from_byte_not_prefixed(byte: u8) ?Instruction {
        const inst = switch (byte) {
            0x00 => return Instruction.NOP,
            0x01 => return Instruction{ .LD = .{ .Word = LoadWordTarget.BC } },
            0x02 => return Instruction{ .LD = .{ .IndirectFromA = Indirect.BCIndirect } },
            0x03 => return Instruction{ .WINC = WideArithmeticTarget.BC },
            0x04 => return Instruction{ .INC = ArithmeticTarget.B },
            0x05 => return Instruction{ .DEC = ArithmeticTarget.B },
            0x06 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.D8 } } },
            0x07 => return Instruction.RLCA,
            0x08 => return Instruction{ .LD = .IndirectFromSP },
            0x09 => return Instruction{ .WADD = WideArithmeticTarget.BC },
            0x0A => return Instruction{ .LD = .{ .AFromIndirect = Indirect.BCIndirect } },
            0x0B => return Instruction{ .WDEC = WideArithmeticTarget.BC },
            0x0C => return Instruction{ .INC = ArithmeticTarget.C },
            0x0D => return Instruction{ .DEC = ArithmeticTarget.C },
            0x0E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.D8 } } },
            0x0F => return Instruction.RRCA,
            0x10 => return Instruction.STOP,
            0x11 => return Instruction{ .LD = .{ .Word = LoadWordTarget.DE } },
            0x12 => return Instruction{ .LD = .{ .IndirectFromA = Indirect.DEIndirect } },
            0x13 => return Instruction{ .WINC = WideArithmeticTarget.DE },
            0x14 => return Instruction{ .INC = ArithmeticTarget.D },
            0x15 => return Instruction{ .DEC = ArithmeticTarget.D },
            0x16 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.D8 } } },
            0x17 => return Instruction.RLA,
            0x18 => return Instruction{ .JR = JumpTest.Always },
            0x19 => return Instruction{ .WADD = WideArithmeticTarget.DE },
            0x1A => return Instruction{ .LD = .{ .AFromIndirect = Indirect.DEIndirect } },
            0x1B => return Instruction{ .WDEC = WideArithmeticTarget.DE },
            0x1C => return Instruction{ .INC = ArithmeticTarget.E },
            0x1D => return Instruction{ .DEC = ArithmeticTarget.E },
            0x1E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.D8 } } },
            0x1F => return Instruction.RRA,
            0x20 => return Instruction{ .JR = JumpTest.NotZero },
            0x21 => return Instruction{ .LD = .{ .Word = LoadWordTarget.HL } },
            0x22 => return Instruction{ .LD = .{ .IndirectFromA = Indirect.HLIndirectPlus } },
            0x23 => return Instruction{ .WINC = WideArithmeticTarget.HL },
            0x24 => return Instruction{ .INC = ArithmeticTarget.H },
            0x25 => return Instruction{ .DEC = ArithmeticTarget.H },
            0x26 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.D8 } } },
            0x27 => return Instruction.DAA,
            0x28 => return Instruction{ .JR = JumpTest.Zero },
            0x29 => return Instruction{ .WADD = WideArithmeticTarget.HL },
            0x2A => return Instruction{ .LD = .{ .AFromIndirect = Indirect.HLIndirectPlus } },
            0x2B => return Instruction{ .WDEC = WideArithmeticTarget.HL },
            0x2C => return Instruction{ .INC = ArithmeticTarget.L },
            0x2D => return Instruction{ .DEC = ArithmeticTarget.L },
            0x2E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.D8 } } },
            0x2F => return Instruction.CPL,
            0x30 => return Instruction{ .JR = JumpTest.NotCarry },
            0x31 => return Instruction{ .LD = .{ .Word = LoadWordTarget.SP } },
            0x32 => return Instruction{ .LD = .{ .IndirectFromA = Indirect.HLIndirectMinus } },
            0x33 => return Instruction{ .WINC = WideArithmeticTarget.SP },
            0x34 => return Instruction{ .INC = ArithmeticTarget.HL },
            0x35 => return Instruction{ .DEC = ArithmeticTarget.HL },
            0x36 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.D8 } } },
            0x37 => return Instruction.SCF,
            0x38 => return Instruction{ .JR = JumpTest.Carry },
            0x39 => return Instruction{ .WADD = WideArithmeticTarget.SP },
            0x3A => return Instruction{ .LD = .{ .AFromIndirect = Indirect.HLIndirectMinus } },
            0x3B => return Instruction{ .WDEC = WideArithmeticTarget.SP },
            0x3C => return Instruction{ .INC = ArithmeticTarget.A },
            0x3D => return Instruction{ .DEC = ArithmeticTarget.A },
            0x3E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.D8 } } },
            0x3F => return Instruction.CCF,
            0x40 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.B } } },
            0x41 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.C } } },
            0x42 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.D } } },
            0x43 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.E } } },
            0x44 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.H } } },
            0x45 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.L } } },
            0x46 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.HLI } } },
            0x47 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.B, .source = LoadByteSource.A } } },
            0x48 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.B } } },
            0x49 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.C } } },
            0x4A => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.D } } },
            0x4B => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.E } } },
            0x4C => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.H } } },
            0x4D => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.L } } },
            0x4E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.HLI } } },
            0x4F => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.C, .source = LoadByteSource.A } } },
            0x50 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.B } } },
            0x51 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.C } } },
            0x52 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.D } } },
            0x53 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.E } } },
            0x54 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.H } } },
            0x55 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.L } } },
            0x56 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.HLI } } },
            0x57 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.D, .source = LoadByteSource.A } } },
            0x58 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.B } } },
            0x59 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.C } } },
            0x5A => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.D } } },
            0x5B => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.E } } },
            0x5C => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.H } } },
            0x5D => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.L } } },
            0x5E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.HLI } } },
            0x5F => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.E, .source = LoadByteSource.A } } },
            0x60 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.B } } },
            0x61 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.C } } },
            0x62 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.D } } },
            0x63 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.E } } },
            0x64 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.H } } },
            0x65 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.L } } },
            0x66 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.HLI } } },
            0x67 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.H, .source = LoadByteSource.A } } },
            0x68 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.B } } },
            0x69 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.C } } },
            0x6A => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.D } } },
            0x6B => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.E } } },
            0x6C => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.H } } },
            0x6D => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.L } } },
            0x6E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.HLI } } },
            0x6F => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.L, .source = LoadByteSource.A } } },
            0x70 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.B } } },
            0x71 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.C } } },
            0x72 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.D } } },
            0x73 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.E } } },
            0x74 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.H } } },
            0x75 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.L } } },
            0x76 => return Instruction.HALT,
            0x77 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.HLI, .source = LoadByteSource.A } } },
            0x78 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.B } } },
            0x79 => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.C } } },
            0x7A => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.D } } },
            0x7B => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.E } } },
            0x7C => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.H } } },
            0x7D => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.L } } },
            0x7E => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.HLI } } },
            0x7F => return Instruction{ .LD = LoadType{ .Byte = .{ .target = LoadByteTarget.A, .source = LoadByteSource.A } } },
            0x80 => return Instruction{ .ADD = ArithmeticTarget.B },
            0x81 => return Instruction{ .ADD = ArithmeticTarget.C },
            0x82 => return Instruction{ .ADD = ArithmeticTarget.D },
            0x83 => return Instruction{ .ADD = ArithmeticTarget.E },
            0x84 => return Instruction{ .ADD = ArithmeticTarget.H },
            0x85 => return Instruction{ .ADD = ArithmeticTarget.L },
            0x86 => return Instruction{ .ADD = ArithmeticTarget.HL },
            0x87 => return Instruction{ .ADD = ArithmeticTarget.A },
            0x88 => return Instruction{ .ADC = ArithmeticTarget.B },
            0x89 => return Instruction{ .ADC = ArithmeticTarget.C },
            0x8A => return Instruction{ .ADC = ArithmeticTarget.D },
            0x8B => return Instruction{ .ADC = ArithmeticTarget.E },
            0x8C => return Instruction{ .ADC = ArithmeticTarget.H },
            0x8D => return Instruction{ .ADC = ArithmeticTarget.L },
            0x8E => return Instruction{ .ADC = ArithmeticTarget.HL },
            0x8F => return Instruction{ .ADC = ArithmeticTarget.A },
            0x90 => return Instruction{ .SUB = ArithmeticTarget.B },
            0x91 => return Instruction{ .SUB = ArithmeticTarget.C },
            0x92 => return Instruction{ .SUB = ArithmeticTarget.D },
            0x93 => return Instruction{ .SUB = ArithmeticTarget.E },
            0x94 => return Instruction{ .SUB = ArithmeticTarget.H },
            0x95 => return Instruction{ .SUB = ArithmeticTarget.L },
            0x96 => return Instruction{ .SUB = ArithmeticTarget.HL },
            0x97 => return Instruction{ .SUB = ArithmeticTarget.A },
            0x98 => return Instruction{ .SBC = ArithmeticTarget.B },
            0x99 => return Instruction{ .SBC = ArithmeticTarget.C },
            0x9A => return Instruction{ .SBC = ArithmeticTarget.D },
            0x9B => return Instruction{ .SBC = ArithmeticTarget.E },
            0x9C => return Instruction{ .SBC = ArithmeticTarget.H },
            0x9D => return Instruction{ .SBC = ArithmeticTarget.L },
            0x9E => return Instruction{ .SBC = ArithmeticTarget.HL },
            0x9F => return Instruction{ .SBC = ArithmeticTarget.A },
            0xA0 => return Instruction{ .AND = ArithmeticTarget.B },
            0xA1 => return Instruction{ .AND = ArithmeticTarget.C },
            0xA2 => return Instruction{ .AND = ArithmeticTarget.D },
            0xA3 => return Instruction{ .AND = ArithmeticTarget.E },
            0xA4 => return Instruction{ .AND = ArithmeticTarget.H },
            0xA5 => return Instruction{ .AND = ArithmeticTarget.L },
            0xA6 => return Instruction{ .AND = ArithmeticTarget.HL },
            0xA7 => return Instruction{ .AND = ArithmeticTarget.A },
            0xA8 => return Instruction{ .XOR = ArithmeticTarget.B },
            0xA9 => return Instruction{ .XOR = ArithmeticTarget.C },
            0xAA => return Instruction{ .XOR = ArithmeticTarget.D },
            0xAB => return Instruction{ .XOR = ArithmeticTarget.E },
            0xAC => return Instruction{ .XOR = ArithmeticTarget.H },
            0xAD => return Instruction{ .XOR = ArithmeticTarget.L },
            0xAE => return Instruction{ .XOR = ArithmeticTarget.HL },
            0xAF => return Instruction{ .XOR = ArithmeticTarget.A },
            0xB0 => return Instruction{ .OR = ArithmeticTarget.B },
            0xB1 => return Instruction{ .OR = ArithmeticTarget.C },
            0xB2 => return Instruction{ .OR = ArithmeticTarget.D },
            0xB3 => return Instruction{ .OR = ArithmeticTarget.E },
            0xB4 => return Instruction{ .OR = ArithmeticTarget.H },
            0xB5 => return Instruction{ .OR = ArithmeticTarget.L },
            0xB6 => return Instruction{ .OR = ArithmeticTarget.HL },
            0xB7 => return Instruction{ .OR = ArithmeticTarget.A },
            0xB8 => return Instruction{ .CP = ArithmeticTarget.B },
            0xB9 => return Instruction{ .CP = ArithmeticTarget.C },
            0xBA => return Instruction{ .CP = ArithmeticTarget.D },
            0xBB => return Instruction{ .CP = ArithmeticTarget.E },
            0xBC => return Instruction{ .CP = ArithmeticTarget.H },
            0xBD => return Instruction{ .CP = ArithmeticTarget.L },
            0xBE => return Instruction{ .CP = ArithmeticTarget.HL },
            0xBF => return Instruction{ .CP = ArithmeticTarget.A },
            0xC0 => return Instruction{ .RET = JumpTest.NotZero },
            0xC1 => return Instruction{ .POP = StackTarget.BC },
            0xC2 => return Instruction{ .JP = JumpTest.NotZero },
            0xC3 => return Instruction{ .JP = JumpTest.Always },
            0xC4 => return Instruction{ .CALL = JumpTest.NotZero },
            0xC5 => return Instruction{ .PUSH = StackTarget.BC },
            0xC6 => return Instruction{ .ADD = ArithmeticTarget.D8 },
            0xC7 => return Instruction{ .RST = RstLocation.Rst00 },
            0xC8 => return Instruction{ .RET = JumpTest.Zero },
            0xC9 => return Instruction{ .RET = JumpTest.Always },
            0xCA => return Instruction{ .JP = JumpTest.Zero },
            0xCB => std.debug.panic("0xCB CB prefix instruction should not reach this switch", .{}),
            0xCC => return Instruction{ .CALL = JumpTest.Zero },
            0xCD => return Instruction{ .CALL = JumpTest.Always },
            0xCE => return Instruction{ .ADC = ArithmeticTarget.D8 },
            0xCF => return Instruction{ .RST = RstLocation.Rst08 },
            0xD0 => return Instruction{ .RET = JumpTest.NotCarry },
            0xD1 => return Instruction{ .POP = StackTarget.DE },
            0xD2 => return Instruction{ .JP = JumpTest.NotCarry },
            0xD4 => return Instruction{ .CALL = JumpTest.NotCarry },
            0xD5 => return Instruction{ .PUSH = StackTarget.DE },
            0xD6 => return Instruction{ .SUB = ArithmeticTarget.D8 },
            0xD7 => return Instruction{ .RST = RstLocation.Rst10 },
            0xD8 => return Instruction{ .RET = JumpTest.Carry },
            0xD9 => return Instruction.RETI, // Return from interrupt
            0xDA => return Instruction{ .JP = JumpTest.Carry },
            0xDC => return Instruction{ .CALL = JumpTest.Carry },
            0xDE => return Instruction{ .SBC = ArithmeticTarget.D8 },
            0xDF => return Instruction{ .RST = RstLocation.Rst18 },
            0xE0 => return Instruction{ .LD = .ByteAddressFromA },
            0xE1 => return Instruction{ .POP = StackTarget.HL },
            0xE2 => return Instruction{ .LD = .{ .IndirectFromA = Indirect.LastByteIndirect } },
            0xE5 => return Instruction{ .PUSH = StackTarget.HL },
            0xE6 => return Instruction{ .AND = ArithmeticTarget.D8 },
            0xE7 => return Instruction{ .RST = RstLocation.Rst20 },
            0xE8 => return Instruction.SPADD,
            0xE9 => return Instruction.JPI,
            0xEA => return Instruction{ .LD = .{ .IndirectFromA = Indirect.WordIndirect } },
            0xEE => return Instruction{ .XOR = ArithmeticTarget.D8 },
            0xEF => return Instruction{ .RST = RstLocation.Rst28 },
            0xF0 => return Instruction{ .LD = .AFromByteAddress },
            0xF1 => return Instruction{ .POP = StackTarget.AF },
            0xF2 => return Instruction{ .LD = .{ .AFromIndirect = Indirect.LastByteIndirect } },
            0xF3 => return Instruction.DI, // Disable interrupts
            0xF5 => return Instruction{ .PUSH = StackTarget.AF },
            0xF6 => return Instruction{ .OR = ArithmeticTarget.D8 },
            0xF7 => return Instruction{ .RST = RstLocation.Rst30 },
            0xF8 => return Instruction{ .LD = .HLFromSPN },
            0xF9 => return Instruction{ .LD = .SPFromHL },
            0xFA => return Instruction{ .LD = .{ .AFromIndirect = Indirect.WordIndirect } },
            0xFB => return Instruction.EI, // Enable interrupts
            0xFE => return Instruction{ .CP = ArithmeticTarget.D8 },
            0xFF => return Instruction{ .RST = RstLocation.Rst38 },
            // 1. 0xD3: This is an invalid/unused opcode on the Game Boy.
            // 2. 0xDB: This is an invalid/unused opcode on the Game Boy.
            // 3. 0xDD: This is an invalid/unused opcode on the Game Boy.
            // 4. 0xE3: This is an invalid/unused opcode on the Game Boy.
            // 5. 0xE4: This is an invalid/unused opcode on the Game Boy.
            // 6. 0xEB: This is an invalid/unused opcode on the Game Boy.
            // 7. 0xEC: This is an invalid/unused opcode on the Game Boy.
            // 8. 0xED: This is an invalid/unused opcode on the Game Boy.
            // 9. 0xF4: This is an invalid/unused opcode on the Game Boy.
            // 10. 0xFC: This is an invalid/unused opcode on the Game Boy.
            // 11. 0xFD: This is an invalid/unused opcode on the Game Boy.
            else => {
                // std.debug.print("Invalid instruction byte: 0x{x}", .{byte});
                return Instruction.NOP;
            },
        };
        return inst;
    }

    fn from_byte_prefixed(byte: u8) ?Instruction {
        const inst = switch (byte) {
            0x00 => return Instruction{ .RLC = PrefixTarget.B },
            0x01 => return Instruction{ .RLC = PrefixTarget.C },
            0x02 => return Instruction{ .RLC = PrefixTarget.D },
            0x03 => return Instruction{ .RLC = PrefixTarget.E },
            0x04 => return Instruction{ .RLC = PrefixTarget.H },
            0x05 => return Instruction{ .RLC = PrefixTarget.L },
            0x06 => return Instruction{ .RLC = PrefixTarget.HLI },
            0x07 => return Instruction{ .RLC = PrefixTarget.A },
            0x08 => return Instruction{ .RRC = PrefixTarget.B },
            0x09 => return Instruction{ .RRC = PrefixTarget.C },
            0x0A => return Instruction{ .RRC = PrefixTarget.D },
            0x0B => return Instruction{ .RRC = PrefixTarget.E },
            0x0C => return Instruction{ .RRC = PrefixTarget.H },
            0x0D => return Instruction{ .RRC = PrefixTarget.L },
            0x0E => return Instruction{ .RRC = PrefixTarget.HLI },
            0x0F => return Instruction{ .RRC = PrefixTarget.A },
            0x10 => return Instruction{ .RL = PrefixTarget.B },
            0x11 => return Instruction{ .RL = PrefixTarget.C },
            0x12 => return Instruction{ .RL = PrefixTarget.D },
            0x13 => return Instruction{ .RL = PrefixTarget.E },
            0x14 => return Instruction{ .RL = PrefixTarget.H },
            0x15 => return Instruction{ .RL = PrefixTarget.L },
            0x16 => return Instruction{ .RL = PrefixTarget.HLI },
            0x17 => return Instruction{ .RL = PrefixTarget.A },
            0x18 => return Instruction{ .RR = PrefixTarget.B },
            0x19 => return Instruction{ .RR = PrefixTarget.C },
            0x1A => return Instruction{ .RR = PrefixTarget.D },
            0x1B => return Instruction{ .RR = PrefixTarget.E },
            0x1C => return Instruction{ .RR = PrefixTarget.H },
            0x1D => return Instruction{ .RR = PrefixTarget.L },
            0x1E => return Instruction{ .RR = PrefixTarget.HLI },
            0x1F => return Instruction{ .RR = PrefixTarget.A },
            0x20 => return Instruction{ .SLA = PrefixTarget.B },
            0x21 => return Instruction{ .SLA = PrefixTarget.C },
            0x22 => return Instruction{ .SLA = PrefixTarget.D },
            0x23 => return Instruction{ .SLA = PrefixTarget.E },
            0x24 => return Instruction{ .SLA = PrefixTarget.H },
            0x25 => return Instruction{ .SLA = PrefixTarget.L },
            0x26 => return Instruction{ .SLA = PrefixTarget.HLI },
            0x27 => return Instruction{ .SLA = PrefixTarget.A },
            0x28 => return Instruction{ .SRA = PrefixTarget.B },
            0x29 => return Instruction{ .SRA = PrefixTarget.C },
            0x2A => return Instruction{ .SRA = PrefixTarget.D },
            0x2B => return Instruction{ .SRA = PrefixTarget.E },
            0x2C => return Instruction{ .SRA = PrefixTarget.H },
            0x2D => return Instruction{ .SRA = PrefixTarget.L },
            0x2E => return Instruction{ .SRA = PrefixTarget.HLI },
            0x2F => return Instruction{ .SRA = PrefixTarget.A },
            0x30 => return Instruction{ .SWAP = PrefixTarget.B },
            0x31 => return Instruction{ .SWAP = PrefixTarget.C },
            0x32 => return Instruction{ .SWAP = PrefixTarget.D },
            0x33 => return Instruction{ .SWAP = PrefixTarget.E },
            0x34 => return Instruction{ .SWAP = PrefixTarget.H },
            0x35 => return Instruction{ .SWAP = PrefixTarget.L },
            0x36 => return Instruction{ .SWAP = PrefixTarget.HLI },
            0x37 => return Instruction{ .SWAP = PrefixTarget.A },
            0x38 => return Instruction{ .SRL = PrefixTarget.B },
            0x39 => return Instruction{ .SRL = PrefixTarget.C },
            0x3A => return Instruction{ .SRL = PrefixTarget.D },
            0x3B => return Instruction{ .SRL = PrefixTarget.E },
            0x3C => return Instruction{ .SRL = PrefixTarget.H },
            0x3D => return Instruction{ .SRL = PrefixTarget.L },
            0x3E => return Instruction{ .SRL = PrefixTarget.HLI },
            0x3F => return Instruction{ .SRL = PrefixTarget.A },
            0x40...0x7F => {
                const bit: u3 = @intCast((byte & 0x38) >> 3);
                const target: PrefixTarget = @enumFromInt(byte & 0x07);
                return Instruction{ .BIT = .{ .target = target, .bit = bit } };
            },
            0x80...0xBF => {
                const bit: u3 = @intCast((byte & 0x38) >> 3);
                const target: PrefixTarget = @enumFromInt(byte & 0x07);
                return Instruction{ .RES = .{ .target = target, .bit = bit } };
            },
            0xC0...0xFF => {
                const bit: u3 = @intCast((byte & 0x38) >> 3);
                const target: PrefixTarget = @enumFromInt(byte & 0x07);
                return Instruction{ .SET = .{ .target = target, .bit = bit } };
            },
        };
        return inst;
    }
};

pub const CPU = struct {
    registers: Registers,
    pc: u16,
    sp: u16,
    bus: MemoryBus,
    halt_state: HaltState,
    is_stopped: bool,
    ime: IME,
    pending_t_cycles: u64,
    clock: packed union {
        t_cycles: u64,
        bits: packed struct {
            _padding: u8,
            div: u8,
            _padding2: u48,
        },
    },
    fn execute(self: *CPU, mutable_instruction: Instruction) void {
        // log.print("Instruction {}\n", .{instruction}) catch unreachable;
        // halt bug isnt needed to pass blargg fully i think
        //
        // if (self.halt_state == HaltState.Bugged) {
        //     self.halt_state = HaltState.Disabled;
        //     self.pc +%= 1;
        // }
        // IE IF checks run before cpu's IME is even checked. halts are ended regardless of if any interrupts
        // actually run

        switch (mutable_instruction) {
            Instruction.NOP => {
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.STOP => {
                self.is_stopped = true;
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.HALT => {
                if (self.ime == IME.Disabled and self.bus.has_interrupt()) {
                    // fix halt bug sometime
                    // self.halt_state = HaltState.Bugged;
                    // break :blk self.pc + 1;
                    // FIXME:
                    self.pc = self.pc +% 1;
                    self.clock.t_cycles += 4;
                    self.halt_state = HaltState.Enabled;
                    if (self.halt_state == HaltState.Enabled) {
                        self.halt_state = HaltState.Enabled;
                    }
                } else {
                    self.pc = self.pc +% 1;
                    self.clock.t_cycles += 4;
                    self.halt_state = HaltState.Enabled;
                    if (self.halt_state == HaltState.Enabled) {
                        self.halt_state = HaltState.Enabled;
                    }
                }
            },
            Instruction.CALL => |jt| {
                const jump_condition = jmpBlk: {
                    switch (jt) {
                        JumpTest.NotZero => {
                            // std.debug.print("CALL NZ\n", .{});
                            break :jmpBlk !self.registers.F.zero;
                        },
                        JumpTest.NotCarry => {
                            // std.debug.print("CALL NC\n", .{});
                            break :jmpBlk !self.registers.F.carry;
                        },
                        JumpTest.Zero => {
                            // std.debug.print("CALL Z\n", .{});
                            break :jmpBlk self.registers.F.zero;
                        },
                        JumpTest.Carry => {
                            // std.debug.print("CALL C\n", .{});
                            break :jmpBlk self.registers.F.carry;
                        },
                        JumpTest.Always => {
                            // std.debug.print("CALL\n", .{});
                            break :jmpBlk true;
                        },
                    }
                };
                const next_pc = self.pc +% 3;
                self.pc = self.call(next_pc, jump_condition);
                self.clock.t_cycles = if (jump_condition) self.clock.t_cycles + 24 else self.clock.t_cycles + 12;
            },
            Instruction.RET => |jt| {
                const jump_condition = jmpBlk: {
                    switch (jt) {
                        JumpTest.NotZero => {
                            // std.debug.print("RET NZ\n", .{});
                            const jump_condition = !self.registers.F.zero;
                            self.clock.t_cycles = if (jump_condition) self.clock.t_cycles + 20 else self.clock.t_cycles + 8;
                            break :jmpBlk jump_condition;
                        },
                        JumpTest.NotCarry => {
                            // std.debug.print("RET NC\n", .{});
                            const jump_condition = !self.registers.F.carry;
                            self.clock.t_cycles = if (jump_condition) self.clock.t_cycles + 20 else self.clock.t_cycles + 8;
                            break :jmpBlk jump_condition;
                        },
                        JumpTest.Zero => {
                            // std.debug.print("RET Z\n", .{});
                            const jump_condition = self.registers.F.zero;
                            self.clock.t_cycles = if (jump_condition) self.clock.t_cycles + 20 else self.clock.t_cycles + 8;
                            break :jmpBlk jump_condition;
                        },
                        JumpTest.Carry => {
                            // std.debug.print("RET C\n", .{});
                            const jump_condition = self.registers.F.carry;
                            self.clock.t_cycles = if (jump_condition) self.clock.t_cycles + 20 else self.clock.t_cycles + 8;
                            break :jmpBlk jump_condition;
                        },
                        JumpTest.Always => {
                            // std.debug.print("RET\n", .{});
                            self.clock.t_cycles += 16;
                            break :jmpBlk true;
                        },
                    }
                };
                self.pc = self.ret(jump_condition);
            },
            Instruction.RETI => {
                // std.debug.print("RETI\n", .{});
                self.pc = self.reti();
                self.clock.t_cycles += 16;
            },
            Instruction.DI => {
                // std.debug.print("DI\n", .{});
                self.pc = self.di();
                self.clock.t_cycles += 4;
            },
            Instruction.EI => {
                // std.debug.print("EI\n", .{});
                self.pc = self.ei();
                self.clock.t_cycles += 4;
            },
            Instruction.RST => |location| {
                // std.debug.print("RST 0x{x}\n", .{@intFromEnum(location)});
                self.pc = self.rst(location);
                self.clock.t_cycles += 16;
            },
            Instruction.POP => |target| {
                const result = self.pop();
                switch (target) {
                    StackTarget.BC => {
                        // std.debug.print("POP BC\n", .{});
                        self.registers.set_BC(result);
                    },
                    StackTarget.DE => {
                        // std.debug.print("POP DE\n", .{});
                        self.registers.set_DE(result);
                    },
                    StackTarget.HL => {
                        // std.debug.print("POP HL\n", .{});
                        self.registers.set_HL(result);
                    },
                    StackTarget.AF => {
                        // std.debug.print("POP AF\n", .{});
                        self.registers.set_AF(result);
                    },
                }
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 12;
            },
            Instruction.PUSH => |target| {
                const value = pushBlk: {
                    switch (target) {
                        StackTarget.BC => {
                            // std.debug.print("PUSH BC\n", .{});
                            break :pushBlk self.registers.get_BC();
                        },
                        StackTarget.DE => {
                            // std.debug.print("PUSH DE\n", .{});
                            break :pushBlk self.registers.get_DE();
                        },
                        StackTarget.HL => {
                            // std.debug.print("PUSH HL\n", .{});
                            break :pushBlk self.registers.get_HL();
                        },
                        StackTarget.AF => {
                            // std.debug.print("PUSH.AF\n", .{});
                            break :pushBlk self.registers.get_AF();
                        },
                    }
                };
                self.push(value);
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 16;
            },
            Instruction.LD => |load| {
                switch (load) {
                    LoadType.Byte => |byte| {
                        // std.debug.print("LD target {} source {}\n", .{ byte.target, byte.source });
                        const source_value = sourceBlk: {
                            switch (byte.source) {
                                LoadByteSource.A => {
                                    // std.debug.print("LD A\n", .{});
                                    break :sourceBlk self.registers.A;
                                },
                                LoadByteSource.B => {
                                    // std.debug.print("LD B\n", .{});
                                    break :sourceBlk self.registers.B;
                                },
                                LoadByteSource.C => {
                                    // std.debug.print("LD C\n", .{});
                                    break :sourceBlk self.registers.C;
                                },
                                LoadByteSource.D => {
                                    // std.debug.print("LD D\n", .{});
                                    break :sourceBlk self.registers.D;
                                },
                                LoadByteSource.E => {
                                    // std.debug.print("LD E\n", .{});
                                    break :sourceBlk self.registers.E;
                                },
                                LoadByteSource.H => {
                                    // std.debug.print("LD H\n", .{});
                                    break :sourceBlk self.registers.H;
                                },
                                LoadByteSource.L => {
                                    // std.debug.print("LD L\n", .{});
                                    break :sourceBlk self.registers.L;
                                },
                                LoadByteSource.D8 => {
                                    // std.debug.print("LD D8\n", .{});
                                    const next_byte = self.read_next_byte();
                                    break :sourceBlk next_byte;
                                },
                                LoadByteSource.HLI => {
                                    // std.debug.print("LD HLI\n", .{});
                                    const hl_byte = self.bus.read_byte(self.registers.get_HL());
                                    break :sourceBlk hl_byte;
                                },
                            }
                        };
                        switch (byte.target) {
                            LoadByteTarget.A => {
                                // std.debug.print("LD A\n", .{});
                                self.registers.A = source_value;
                            },
                            LoadByteTarget.B => {
                                // std.debug.print("LD B\n", .{});
                                self.registers.B = source_value;
                            },
                            LoadByteTarget.C => {
                                // std.debug.print("LD C\n", .{});
                                self.registers.C = source_value;
                            },
                            LoadByteTarget.D => {
                                // std.debug.print("LD D\n", .{});
                                self.registers.D = source_value;
                            },
                            LoadByteTarget.E => {
                                // std.debug.print("LD E\n", .{});
                                self.registers.E = source_value;
                            },
                            LoadByteTarget.H => {
                                // std.debug.print("LD H\n", .{});
                                self.registers.H = source_value;
                            },
                            LoadByteTarget.L => {
                                // std.debug.print("LD L\n", .{});
                                self.registers.L = source_value;
                            },
                            LoadByteTarget.HLI => {
                                // std.debug.print("LD HLI\n", .{});
                                self.bus.write_byte(self.registers.get_HL(), source_value);
                            },
                        }

                        // this is cringe but i designed things bad before implementing cycles and cba to refactor
                        var hl_op = false;
                        var d8_op = false;
                        switch (byte.source) {
                            LoadByteSource.HLI => {
                                hl_op = true;
                            },
                            LoadByteSource.D8 => {
                                d8_op = true;
                            },
                            else => {},
                        }
                        switch (byte.target) {
                            LoadByteTarget.HLI => {
                                hl_op = true;
                            },
                            else => {},
                        }
                        if (hl_op and d8_op) {
                            self.pc = self.pc +% 2;
                            self.clock.t_cycles += 12;
                        } else if (d8_op) {
                            self.pc = self.pc +% 2;
                            self.clock.t_cycles += 8;
                        } else if (hl_op) {
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 8;
                        } else {
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 4;
                        }
                    },
                    LoadType.Word => |word| {
                        // std.debug.print("LD Word {} source \n", .{word});
                        const source_value = self.read_next_word();
                        switch (word) {
                            LoadWordTarget.BC => {
                                // std.debug.print("LD BC\n", .{});
                                self.registers.set_BC(source_value);
                            },
                            LoadWordTarget.DE => {
                                // std.debug.print("LD DE\n", .{});
                                self.registers.set_DE(source_value);
                            },
                            LoadWordTarget.HL => {
                                // std.debug.print("LD HL\n", .{});
                                self.registers.set_HL(source_value);
                            },
                            LoadWordTarget.SP => {
                                // std.debug.print("LD SP\n", .{});
                                self.sp = source_value;
                            },
                        }
                        self.pc = self.pc +% 3;
                        self.clock.t_cycles += 12;
                    },
                    LoadType.AFromIndirect => |indirect| {
                        const value = sourceBlk: {
                            switch (indirect) {
                                Indirect.BCIndirect => {
                                    // std.debug.print("LD A (BC)\n", .{});
                                    break :sourceBlk self.bus.read_byte(self.registers.get_BC());
                                },
                                Indirect.DEIndirect => {
                                    // std.debug.print("LD A (DE)\n", .{});
                                    break :sourceBlk self.bus.read_byte(self.registers.get_DE());
                                },
                                Indirect.HLIndirectPlus => {
                                    // std.debug.print("LD A (HL+)\n", .{});
                                    const hl = self.registers.get_HL();
                                    const value = self.bus.read_byte(hl);
                                    self.registers.set_HL(hl +% 1);
                                    break :sourceBlk value;
                                },
                                Indirect.HLIndirectMinus => {
                                    // std.debug.print("LD A (HL-)\n", .{});
                                    const hl = self.registers.get_HL();
                                    const value = self.bus.read_byte(hl);
                                    self.registers.set_HL(hl -% 1);
                                    break :sourceBlk value;
                                },
                                Indirect.WordIndirect => {
                                    // std.debug.print("LD A (nn)\n", .{});
                                    const address = self.read_next_word();
                                    break :sourceBlk self.bus.read_byte(address);
                                },
                                Indirect.LastByteIndirect => {
                                    // std.debug.print("LD A (FF00 + C)\n", .{});
                                    const address = 0xFF00 +% @as(u16, self.registers.C);
                                    break :sourceBlk self.bus.read_byte(address);
                                },
                            }
                        };
                        self.registers.A = value;
                        switch (indirect) {
                            Indirect.WordIndirect => {
                                self.pc = self.pc +% 3;
                                self.clock.t_cycles += 16;
                            },
                            else => {
                                self.pc = self.pc +% 1;
                                self.clock.t_cycles += 8;
                            },
                        }
                    },
                    LoadType.IndirectFromA => |indirect| {
                        const value = self.registers.A;
                        switch (indirect) {
                            Indirect.BCIndirect => {
                                // std.debug.print("LD (BC) A\n", .{});
                                self.bus.write_byte(self.registers.get_BC(), value);
                            },
                            Indirect.DEIndirect => {
                                // std.debug.print("LD (DE) A\n", .{});
                                self.bus.write_byte(self.registers.get_DE(), value);
                            },
                            Indirect.HLIndirectPlus => {
                                // std.debug.print("LD (HL+) A\n", .{});
                                const hl = self.registers.get_HL();
                                self.bus.write_byte(hl, value);
                                self.registers.set_HL(hl +% 1);
                            },
                            Indirect.HLIndirectMinus => {
                                // std.debug.print("LD (HL-) A\n", .{});
                                const hl = self.registers.get_HL();
                                self.bus.write_byte(hl, value);
                                self.registers.set_HL(hl -% 1);
                            },
                            Indirect.WordIndirect => {
                                // std.debug.print("LD (nn) A\n", .{});
                                const address = self.read_next_word();
                                self.bus.write_byte(address, value);
                            },
                            Indirect.LastByteIndirect => {
                                // std.debug.print("LD (FF00 + C) A\n", .{});
                                const address = 0xFF00 +% @as(u16, self.registers.C);
                                self.bus.write_byte(address, value);
                            },
                        }
                        switch (indirect) {
                            Indirect.WordIndirect => {
                                self.pc = self.pc +% 3;
                                self.clock.t_cycles += 16;
                            },
                            else => {
                                self.pc = self.pc +% 1;
                                self.clock.t_cycles += 8;
                            },
                        }
                    },
                    LoadType.AFromByteAddress => {
                        const offset = @as(u16, self.read_next_byte());
                        self.registers.A = self.bus.read_byte(0xFF00 +% offset);
                        // at this point A is 0x04, which is correct. why is it going to 0x00?
                        self.pc = self.pc +% 2;
                        self.clock.t_cycles += 12;
                    },
                    LoadType.ByteAddressFromA => {
                        const offset = @as(u16, self.read_next_byte());
                        self.bus.write_byte(0xFF00 + offset, self.registers.A);
                        self.pc = self.pc +% 2;
                        self.clock.t_cycles += 12;
                    },
                    LoadType.SPFromHL => {
                        self.sp = self.registers.get_HL();
                        self.pc = self.pc +% 1;
                        self.clock.t_cycles += 8;
                    },
                    LoadType.HLFromSPN => {
                        const n = self.read_next_byte();
                        const signed: i8 = @bitCast(n);
                        if (signed >= 0) {
                            self.registers.set_HL(self.sp +% @abs(signed));
                        } else {
                            self.registers.set_HL(self.sp -% @abs(signed));
                        }
                        self.registers.F.zero = false;
                        self.registers.F.subtract = false;
                        // i passed instr3 rom, but should still review these flags
                        self.registers.F.half_carry = (self.sp & 0xF) + (n & 0xF) > 0xF;
                        self.registers.F.carry = (self.sp & 0xFF) + n > 0xFF;
                        self.pc = self.pc +% 2;
                        self.clock.t_cycles += 12;
                    },
                    LoadType.IndirectFromSP => {
                        const address = self.read_next_word();
                        self.bus.write_word(address, self.sp);
                        self.pc = self.pc +% 3;
                        self.clock.t_cycles += 20;
                    },
                }
            },
            Instruction.JP => |jt| {
                const jump_condition = jpblk: {
                    switch (jt) {
                        JumpTest.NotZero => {
                            // std.debug.print("JP NZ\n", .{});
                            break :jpblk !self.registers.F.zero;
                        },
                        JumpTest.NotCarry => {
                            // std.debug.print("JP NC\n", .{});
                            break :jpblk !self.registers.F.carry;
                        },
                        JumpTest.Zero => {
                            // std.debug.print("JP Z\n", .{});
                            break :jpblk self.registers.F.zero;
                        },
                        JumpTest.Carry => {
                            // std.debug.print("JP C\n", .{});
                            break :jpblk self.registers.F.carry;
                        },
                        JumpTest.Always => {
                            // std.debug.print("JP\n", .{});
                            break :jpblk true;
                        },
                    }
                };
                self.pc = self.jump(jump_condition);
                self.clock.t_cycles = if (jump_condition) self.clock.t_cycles + 16 else self.clock.t_cycles + 12;
            },
            Instruction.JPI => {
                // std.debug.print("JP HL\n", .{});
                self.pc = self.registers.get_HL();
                self.clock.t_cycles += 4;
            },
            Instruction.JR => |jt| {
                const jump_condition = jpblk: {
                    switch (jt) {
                        JumpTest.NotZero => {
                            // std.debug.print("JP NZ\n", .{});
                            break :jpblk !self.registers.F.zero;
                        },
                        JumpTest.NotCarry => {
                            // std.debug.print("JP NC\n", .{});
                            break :jpblk !self.registers.F.carry;
                        },
                        JumpTest.Zero => {
                            // std.debug.print("JP Z\n", .{});
                            break :jpblk self.registers.F.zero;
                        },
                        JumpTest.Carry => {
                            // std.debug.print("JP C\n", .{});
                            break :jpblk self.registers.F.carry;
                        },
                        JumpTest.Always => {
                            // std.debug.print("JP\n", .{});
                            break :jpblk true;
                        },
                    }
                };
                self.pc = self.jump_relative(jump_condition);
                self.clock.t_cycles = if (jump_condition) self.clock.t_cycles + 12 else self.clock.t_cycles + 8;
            },
            Instruction.ADD => |target| {
                const value = addBlk: {
                    switch (target) {
                        ArithmeticTarget.A => {
                            // std.debug.print("ADD A\n", .{});
                            const value = self.registers.A;
                            const new_value = self.add(value);
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.B => {
                            // std.debug.print("ADD B\n", .{});
                            const value = self.registers.B;
                            const new_value = self.add(value);
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.C => {
                            // std.debug.print("ADD C\n", .{});
                            const value = self.registers.C;
                            const new_value = self.add(value);
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.D => {
                            // std.debug.print("ADD D\n", .{});
                            const value = self.registers.D;
                            const new_value = self.add(value);
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.E => {
                            // std.debug.print("ADD E\n", .{});
                            const value = self.registers.E;
                            const new_value = self.add(value);
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.H => {
                            // std.debug.print("ADD H\n", .{});
                            const value = self.registers.H;
                            const new_value = self.add(value);
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.L => {
                            // std.debug.print("ADD L\n", .{});
                            const value = self.registers.L;
                            const new_value = self.add(value);
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.HL => {
                            // std.debug.print("ADD HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            const new_value = self.add(value);
                            self.clock.t_cycles += 4;
                            break :addBlk new_value;
                        },
                        ArithmeticTarget.D8 => {
                            // std.debug.print("ADD D8\n", .{});
                            const value = self.read_next_byte();
                            const new_value = self.add(value);
                            self.pc +%= 1;
                            self.clock.t_cycles += 4;
                            break :addBlk new_value;
                        },
                    }
                };
                self.registers.A = value;
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.ADC => |target| {
                const value = adcBlk: {
                    switch (target) {
                        ArithmeticTarget.A => {
                            // std.debug.print("adc A\n", .{});
                            const value = self.registers.A;
                            const new_value = self.adc(value);
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.B => {
                            // std.debug.print("adc B\n", .{});
                            const value = self.registers.B;
                            const new_value = self.adc(value);
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.C => {
                            // std.debug.print("adc C\n", .{});
                            const value = self.registers.C;
                            const new_value = self.adc(value);
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.D => {
                            // std.debug.print("adc D\n", .{});
                            const value = self.registers.D;
                            const new_value = self.adc(value);
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.E => {
                            // std.debug.print("adc E\n", .{});
                            const value = self.registers.E;
                            const new_value = self.adc(value);
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.H => {
                            // std.debug.print("adc H\n", .{});
                            const value = self.registers.H;
                            const new_value = self.adc(value);
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.L => {
                            // std.debug.print("adc L\n", .{});
                            const value = self.registers.L;
                            const new_value = self.adc(value);
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.HL => {
                            // std.debug.print("ADC HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            const new_value = self.adc(value);
                            self.clock.t_cycles += 4;
                            break :adcBlk new_value;
                        },
                        ArithmeticTarget.D8 => {
                            // std.debug.print("ADC D8\n", .{});
                            const value = self.read_next_byte();
                            const new_value = self.adc(value);
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 4;
                            break :adcBlk new_value;
                        },
                    }
                };
                self.registers.A = value;
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.SUB => |target| {
                const value = subBlk: {
                    switch (target) {
                        ArithmeticTarget.A => {
                            // std.debug.print("sub A\n", .{});
                            const value = self.registers.A;
                            const new_value = self.sub(value);
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.B => {
                            // std.debug.print("sub B\n", .{});
                            const value = self.registers.B;
                            const new_value = self.sub(value);
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.C => {
                            // std.debug.print("sub C\n", .{});
                            const value = self.registers.C;
                            const new_value = self.sub(value);
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.D => {
                            // std.debug.print("sub D\n", .{});
                            const value = self.registers.D;
                            const new_value = self.sub(value);
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.E => {
                            // std.debug.print("sub E\n", .{});
                            const value = self.registers.E;
                            const new_value = self.sub(value);
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.H => {
                            // std.debug.print("sub H\n", .{});
                            const value = self.registers.H;
                            const new_value = self.sub(value);
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.L => {
                            // std.debug.print("sub L\n", .{});
                            const value = self.registers.L;
                            const new_value = self.sub(value);
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.HL => {
                            // std.debug.print("SUB HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            const new_value = self.sub(value);
                            self.clock.t_cycles += 4;
                            break :subBlk new_value;
                        },
                        ArithmeticTarget.D8 => {
                            // std.debug.print("SUB D8\n", .{});
                            const value = self.read_next_byte();
                            const new_value = self.sub(value);
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 4;
                            break :subBlk new_value;
                        },
                    }
                };
                self.registers.A = value;
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.SBC => |target| {
                const value = sbcBlk: {
                    switch (target) {
                        ArithmeticTarget.A => {
                            // std.debug.print("sbc A\n", .{});
                            const value = self.registers.A;
                            const new_value = self.sbc(value);
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.B => {
                            // std.debug.print("sbc B\n", .{});
                            const value = self.registers.B;
                            const new_value = self.sbc(value);
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.C => {
                            // std.debug.print("sbc C\n", .{});
                            const value = self.registers.C;
                            const new_value = self.sbc(value);
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.D => {
                            // std.debug.print("sbc D\n", .{});
                            const value = self.registers.D;
                            const new_value = self.sbc(value);
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.E => {
                            // std.debug.print("sbc E\n", .{});
                            const value = self.registers.E;
                            const new_value = self.sbc(value);
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.H => {
                            // std.debug.print("sbc H\n", .{});
                            const value = self.registers.H;
                            const new_value = self.sbc(value);
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.L => {
                            // std.debug.print("sbc L\n", .{});
                            const value = self.registers.L;
                            const new_value = self.sbc(value);
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.HL => {
                            // std.debug.print("sbc HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            const new_value = self.sbc(value);
                            self.clock.t_cycles += 4;
                            break :sbcBlk new_value;
                        },
                        ArithmeticTarget.D8 => {
                            // std.debug.print("sbc D8\n", .{});
                            const value = self.read_next_byte();
                            const new_value = self.sbc(value);
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 4;
                            break :sbcBlk new_value;
                        },
                    }
                };
                self.registers.A = value;
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.AND => |target| {
                const value = andBlk: {
                    switch (target) {
                        ArithmeticTarget.A => {
                            // std.debug.print("and A\n", .{});
                            const value = self.registers.A;
                            const new_value = self.and_(value);
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.B => {
                            // std.debug.print("and B\n", .{});
                            const value = self.registers.B;
                            const new_value = self.and_(value);
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.C => {
                            // std.debug.print("and C\n", .{});
                            const value = self.registers.C;
                            const new_value = self.and_(value);
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.D => {
                            // std.debug.print("and D\n", .{});
                            const value = self.registers.D;
                            const new_value = self.and_(value);
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.E => {
                            // std.debug.print("and E\n", .{});
                            const value = self.registers.E;
                            const new_value = self.and_(value);
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.H => {
                            // std.debug.print("and H\n", .{});
                            const value = self.registers.H;
                            const new_value = self.and_(value);
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.L => {
                            // std.debug.print("and L\n", .{});
                            const value = self.registers.L;
                            const new_value = self.and_(value);
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.HL => {
                            // std.debug.print("and HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            const new_value = self.and_(value);
                            self.clock.t_cycles += 4;
                            break :andBlk new_value;
                        },
                        ArithmeticTarget.D8 => {
                            // std.debug.print("and D8\n", .{});
                            const value = self.read_next_byte();
                            const new_value = self.and_(value);
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 4;
                            break :andBlk new_value;
                        },
                    }
                };
                self.registers.A = value;
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.XOR => |target| {
                const value = xorBlk: {
                    switch (target) {
                        ArithmeticTarget.A => {
                            // std.debug.print("xor A\n", .{});
                            const value = self.registers.A;
                            const new_value = self.xor(value);
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.B => {
                            // std.debug.print("xor B\n", .{});
                            const value = self.registers.B;
                            const new_value = self.xor(value);
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.C => {
                            // std.debug.print("xor C\n", .{});
                            const value = self.registers.C;
                            const new_value = self.xor(value);
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.D => {
                            // std.debug.print("xor D\n", .{});
                            const value = self.registers.D;
                            const new_value = self.xor(value);
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.E => {
                            // std.debug.print("xor E\n", .{});
                            const value = self.registers.E;
                            const new_value = self.xor(value);
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.H => {
                            // std.debug.print("xor H\n", .{});
                            const value = self.registers.H;
                            const new_value = self.xor(value);
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.L => {
                            // std.debug.print("xor L\n", .{});
                            const value = self.registers.L;
                            const new_value = self.xor(value);
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.HL => {
                            // std.debug.print("xor HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            const new_value = self.xor(value);
                            self.clock.t_cycles += 4;
                            break :xorBlk new_value;
                        },
                        ArithmeticTarget.D8 => {
                            // std.debug.print("xor D8\n", .{});
                            const value = self.read_next_byte();
                            const new_value = self.xor(value);
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 4;
                            break :xorBlk new_value;
                        },
                    }
                };
                self.registers.A = value;
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.OR => |target| {
                const value = orBlk: {
                    switch (target) {
                        ArithmeticTarget.A => {
                            // std.debug.print("or A\n", .{});
                            const value = self.registers.A;
                            const new_value = self.or_(value);
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.B => {
                            // std.debug.print("or B\n", .{});
                            const value = self.registers.B;
                            const new_value = self.or_(value);
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.C => {
                            // std.debug.print("or C\n", .{});
                            const value = self.registers.C;
                            const new_value = self.or_(value);
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.D => {
                            // std.debug.print("or D\n", .{});
                            const value = self.registers.D;
                            const new_value = self.or_(value);
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.E => {
                            // std.debug.print("or E\n", .{});
                            const value = self.registers.E;
                            const new_value = self.or_(value);
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.H => {
                            // std.debug.print("or H\n", .{});
                            const value = self.registers.H;
                            const new_value = self.or_(value);
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.L => {
                            // std.debug.print("or L\n", .{});
                            const value = self.registers.L;
                            const new_value = self.or_(value);
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.HL => {
                            // std.debug.print("or HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            const new_value = self.or_(value);
                            self.clock.t_cycles += 4;
                            break :orBlk new_value;
                        },
                        ArithmeticTarget.D8 => {
                            // std.debug.print("or D8\n", .{});
                            const value = self.read_next_byte();
                            const new_value = self.or_(value);
                            self.pc = self.pc +% 1;
                            self.clock.t_cycles += 4;
                            break :orBlk new_value;
                        },
                    }
                };
                self.registers.A = value;
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.CP => |target| {
                switch (target) {
                    ArithmeticTarget.A => {
                        // std.debug.print("cp A\n", .{});
                        const value = self.registers.A;
                        self.cp(value);
                    },
                    ArithmeticTarget.B => {
                        // std.debug.print("cp B\n", .{});
                        const value = self.registers.B;
                        self.cp(value);
                    },
                    ArithmeticTarget.C => {
                        // std.debug.print("cp C\n", .{});
                        const value = self.registers.C;
                        self.cp(value);
                    },
                    ArithmeticTarget.D => {
                        // std.debug.print("cp D\n", .{});
                        const value = self.registers.D;
                        self.cp(value);
                    },
                    ArithmeticTarget.E => {
                        // std.debug.print("cp E\n", .{});
                        const value = self.registers.E;
                        self.cp(value);
                    },
                    ArithmeticTarget.H => {
                        // std.debug.print("cp H\n", .{});
                        const value = self.registers.H;
                        self.cp(value);
                    },
                    ArithmeticTarget.L => {
                        // std.debug.print("cp L\n", .{});
                        const value = self.registers.L;
                        self.cp(value);
                    },
                    ArithmeticTarget.HL => {
                        // std.debug.print("cp HL\n", .{});
                        const value = self.bus.read_byte(self.registers.get_HL());
                        self.clock.t_cycles += 4;
                        self.cp(value);
                    },
                    ArithmeticTarget.D8 => {
                        // std.debug.print("cp D8\n", .{});
                        const value = self.read_next_byte();
                        self.pc = self.pc +% 1;
                        self.clock.t_cycles += 4;
                        self.cp(value);
                    },
                }
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.INC => |target| {
                switch (target) {
                    ArithmeticTarget.A => {
                        // std.debug.print("inc A\n", .{});
                        const value = self.registers.A;
                        const res = self.inc(value);
                        self.registers.A = res;
                    },
                    ArithmeticTarget.B => {
                        // std.debug.print("inc B\n", .{});
                        const value = self.registers.B;
                        const res = self.inc(value);
                        self.registers.B = res;
                    },
                    ArithmeticTarget.C => {
                        // std.debug.print("inc C\n", .{});
                        const value = self.registers.C;
                        const res = self.inc(value);
                        self.registers.C = res;
                    },
                    ArithmeticTarget.D => {
                        // std.debug.print("inc D\n", .{});
                        const value = self.registers.D;
                        const res = self.inc(value);
                        self.registers.D = res;
                    },
                    ArithmeticTarget.E => {
                        // std.debug.print("inc E\n", .{});
                        const value = self.registers.E;
                        const res = self.inc(value);
                        self.registers.E = res;
                    },
                    ArithmeticTarget.H => {
                        // std.debug.print("inc H\n", .{});
                        const value = self.registers.H;
                        const res = self.inc(value);
                        self.registers.H = res;
                    },
                    ArithmeticTarget.L => {
                        // std.debug.print("inc L\n", .{});
                        const value = self.registers.L;
                        const res = self.inc(value);
                        self.registers.L = res;
                    },
                    ArithmeticTarget.HL => {
                        // std.debug.print("inc HL\n", .{});
                        const HL = self.registers.get_HL();
                        const value = self.bus.read_byte(HL);
                        const res = self.inc(value);
                        self.clock.t_cycles += 8;
                        self.bus.write_byte(HL, res);
                    },
                    else => {
                        // std.debug.print("Unknown INC target\n", .{});
                    },
                }
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.DEC => |target| {
                switch (target) {
                    ArithmeticTarget.A => {
                        // std.debug.print("dec A\n", .{});
                        const value = self.registers.A;
                        const res = self.dec(value);
                        self.registers.A = res;
                    },
                    ArithmeticTarget.B => {
                        // std.debug.print("dec B\n", .{});
                        const value = self.registers.B;
                        const res = self.dec(value);
                        self.registers.B = res;
                    },
                    ArithmeticTarget.C => {
                        // std.debug.print("dec C\n", .{});
                        const value = self.registers.C;
                        const res = self.dec(value);
                        self.registers.C = res;
                    },
                    ArithmeticTarget.D => {
                        // std.debug.print("dec D\n", .{});
                        const value = self.registers.D;
                        const res = self.dec(value);
                        self.registers.D = res;
                    },
                    ArithmeticTarget.E => {
                        // std.debug.print("dec E\n", .{});
                        const value = self.registers.E;
                        const res = self.dec(value);
                        self.registers.E = res;
                    },
                    ArithmeticTarget.H => {
                        // std.debug.print("dec H\n", .{});
                        const value = self.registers.H;
                        const res = self.dec(value);
                        self.registers.H = res;
                    },
                    ArithmeticTarget.L => {
                        // std.debug.print("dec L\n", .{});
                        const value = self.registers.L;
                        const res = self.dec(value);
                        self.registers.L = res;
                    },
                    ArithmeticTarget.HL => {
                        // std.debug.print("dec HL\n", .{});
                        const HL = self.registers.get_HL();
                        const value = self.bus.read_byte(HL);
                        const res = self.dec(value);
                        self.clock.t_cycles += 8;
                        self.bus.write_byte(HL, res);
                    },
                    else => {
                        // std.debug.print("Unknown DEC target\n", .{});
                    },
                }
                self.pc +%= 1;
                self.clock.t_cycles += 4;
            },
            Instruction.WADD => |target| {
                const value = waddBlk: {
                    switch (target) {
                        WideArithmeticTarget.HL => {
                            // std.debug.print("wadd HL\n", .{});
                            const value = self.registers.get_HL();
                            const new_value = self.wadd(value);
                            break :waddBlk new_value;
                        },
                        WideArithmeticTarget.BC => {
                            // std.debug.print("wadd BC\n", .{});
                            const value = self.registers.get_BC();
                            const new_value = self.wadd(value);
                            break :waddBlk new_value;
                        },
                        WideArithmeticTarget.DE => {
                            // std.debug.print("wadd DE\n", .{});
                            const value = self.registers.get_DE();
                            const new_value = self.wadd(value);
                            break :waddBlk new_value;
                        },
                        WideArithmeticTarget.SP => {
                            // std.debug.print("wadd SP\n", .{});
                            const value = self.sp;
                            const new_value = self.wadd(value);
                            break :waddBlk new_value;
                        },
                    }
                };
                self.registers.set_HL(value);
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 8;
            },
            Instruction.WINC => |target| {
                switch (target) {
                    WideArithmeticTarget.HL => {
                        // std.debug.print("winc HL\n", .{});
                        const value = self.registers.get_HL();
                        const new_value = self.winc(value);
                        self.registers.set_HL(new_value);
                    },
                    WideArithmeticTarget.BC => {
                        // std.debug.print("winc BC\n", .{});
                        const value = self.registers.get_BC();
                        const new_value = self.winc(value);
                        self.registers.set_BC(new_value);
                    },
                    WideArithmeticTarget.DE => {
                        // std.debug.print("winc DE\n", .{});
                        const value = self.registers.get_DE();
                        const new_value = self.winc(value);
                        self.registers.set_DE(new_value);
                    },
                    WideArithmeticTarget.SP => {
                        // std.debug.print("winc SP\n", .{});
                        const value = self.sp;
                        const new_value = self.winc(value);
                        self.sp = new_value;
                    },
                }
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 8;
            },
            Instruction.WDEC => |target| {
                switch (target) {
                    WideArithmeticTarget.HL => {
                        // std.debug.print("wdec HL\n", .{});
                        const value = self.registers.get_HL();
                        const new_value = self.wdec(value);
                        self.registers.set_HL(new_value);
                    },
                    WideArithmeticTarget.BC => {
                        // std.debug.print("wdec BC\n", .{});
                        const value = self.registers.get_BC();
                        const new_value = self.wdec(value);
                        self.registers.set_BC(new_value);
                    },
                    WideArithmeticTarget.DE => {
                        // std.debug.print("wdec DE\n", .{});
                        const value = self.registers.get_DE();
                        const new_value = self.wdec(value);
                        self.registers.set_DE(new_value);
                    },
                    WideArithmeticTarget.SP => {
                        // std.debug.print("wdec SP\n", .{});
                        const value = self.sp;
                        const new_value = self.wdec(value);
                        self.sp = new_value;
                    },
                }
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 8;
            },
            Instruction.SPADD => |_| {
                const value = self.read_next_byte();
                const new_value = self.spadd(value);
                self.sp = new_value;
                self.pc = self.pc +% 2;
                self.clock.t_cycles += 16;
            },
            Instruction.DAA => |_| {
                // std.debug.print("DAA\n", .{});
                const new_value = self.daa(self.registers.A);
                self.registers.A = new_value;
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.CPL => |_| {
                // std.debug.print("CPL\n", .{});
                _ = self.cpl();
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.CCF => |_| {
                // std.debug.print("CCF\n", .{});
                _ = self.ccf();
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.SCF => |_| {
                // std.debug.print("SCF\n", .{});
                _ = self.scf();
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.RLA => |_| {
                // std.debug.print("RLA\n", .{});
                const new_value = self.rla(self.registers.A);
                self.registers.A = new_value;
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.RLCA => |_| {
                // std.debug.print("RLCA\n", .{});
                const new_value = self.rlca(self.registers.A);
                self.registers.A = new_value;
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.RRA => |_| {
                // std.debug.print("RRA\n", .{});
                const new_value = self.rra(self.registers.A);
                self.registers.A = new_value;
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.RRCA => |_| {
                // std.debug.print("RRCA\n", .{});
                const new_value = self.rrca(self.registers.A);
                self.registers.A = new_value;
                self.pc = self.pc +% 1;
                self.clock.t_cycles += 4;
            },
            Instruction.RLC => |target| {
                // std.debug.print("RLC {}\n", .{target});
                handle_prefix_instruction(self, target, rlc, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
                self.clock.t_cycles += 8;
            },
            Instruction.RRC => |target| {
                // std.debug.print("RRC {}\n", .{target});
                handle_prefix_instruction(self, target, rrc, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
                self.clock.t_cycles += 8;
            },
            Instruction.RL => |target| {
                // std.debug.print("RL {}\n", .{target});
                handle_prefix_instruction(self, target, rl, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
            Instruction.RR => |target| {
                // std.debug.print("RR {}\n", .{target});
                handle_prefix_instruction(self, target, rr, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
            Instruction.SLA => |target| {
                // std.debug.print("LRA {}\n", .{target});
                handle_prefix_instruction(self, target, shift_left_arithmetic, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
            Instruction.SRA => |target| {
                // std.debug.print("SRA {}\n", .{target});
                handle_prefix_instruction(self, target, shift_right_arithmetic, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
            Instruction.SRL => |target| {
                // std.debug.print("SRL {}\n", .{target});
                handle_prefix_instruction(self, target, shift_right_logical, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
            Instruction.SWAP => |target| {
                // std.debug.print("SWAP {}\n", .{target});
                handle_prefix_instruction(self, target, swap, .{ .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
            Instruction.BIT => |target| {
                // std.debug.print("BIT {}\n", .{target.target});
                handle_prefix_instruction(self, target.target, bit, .{ .bit = target.bit, .r8_cycles = 8, .hl_cycles = 12 });
                self.pc = self.pc +% 2;
            },
            Instruction.SET => |target| {
                // std.debug.print("SET {}\n", .{target});
                handle_prefix_instruction(self, target.target, set, .{ .bit = target.bit, .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
            Instruction.RES => |target| {
                // std.debug.print("RES {}\n", .{target});
                handle_prefix_instruction(self, target.target, reset, .{ .bit = target.bit, .r8_cycles = 8, .hl_cycles = 16 });
                self.pc = self.pc +% 2;
            },
        }
    }
    pub fn frame_walk(self: *CPU) void {
        self.pending_t_cycles = 0;
        var current_cycles = self.clock.t_cycles;

        Joypad.update_joyp_keys(self);
        // std.debug.print("joyp state: 0b{b:0>8}\n", .{@as(u8, @bitCast(self.bus.joypad.joyp))});

        if (self.bus.has_interrupt()) {
            // std.debug.print("HAS AN INTERRUPT PC=0x{x}\n", .{self.pc});

            if (self.halt_state == HaltState.Enabled or self.halt_state == HaltState.SwitchedOn) {
                // std.debug.print("IE/IF set while in halt, setting HaltState.Disabled\n", .{});
                self.halt_state = HaltState.Disabled;
                self.pc +%= 1;
            }

            if (self.ime == IME.Enabled) {
                // std.debug.print("IME.Enabled PC=0x{x}\n", .{self.pc});
                // std.debug.print("HANDLING AN INTERRUPT PC=0x{x}\n", .{self.pc});
                // std.debug.print("IF=0b{b:0>8}\n", .{@as(u8, @bitCast(self.bus.interrupt_flag))});
                // std.debug.print("IE=0b{b:0>8}\n", .{@as(u8, @bitCast(self.bus.interrupt_enable))});
                self.ime = IME.Disabled;
                self.push(self.pc);
                self.halt_state = HaltState.Disabled;

                // when handling an interrupt,
                // 1 cycle for interrupt check
                // 1 cycle for ack
                // 8 cycles for push
                // 4 cycles for jump
                // not sure if some of these cycles are spent if IME is on, but ie/if are off for all interrupts
                if (self.bus.interrupt_enable.enable_vblank and self.bus.interrupt_flag.enable_vblank) {
                    // std.debug.print("HANDLING VBLANK\n", .{});
                    self.bus.interrupt_flag.enable_vblank = false;
                    self.pc = @intFromEnum(ISR.VBlank);
                    self.clock.t_cycles += 20;
                } else if (self.bus.interrupt_enable.enable_lcd_stat and self.bus.interrupt_flag.enable_lcd_stat) {
                    // std.debug.print("HANDLING LCDSTAT\n", .{});
                    self.bus.interrupt_flag.enable_lcd_stat = false;
                    self.pc = @intFromEnum(ISR.LCDStat);
                    self.clock.t_cycles += 20;
                } else if (self.bus.interrupt_enable.enable_timer and self.bus.interrupt_flag.enable_timer) {
                    // std.debug.print("HANDLING TIMER\n", .{});
                    self.bus.interrupt_flag.enable_timer = false;
                    self.pc = @intFromEnum(ISR.Timer);
                    self.clock.t_cycles += 20;
                } else if (self.bus.interrupt_enable.enable_serial and self.bus.interrupt_flag.enable_serial) {
                    // std.debug.print("HANDLING SERIAL\n", .{});
                    self.bus.interrupt_flag.enable_serial = false;
                    self.pc = @intFromEnum(ISR.Serial);
                    self.clock.t_cycles += 20;
                } else if (self.bus.interrupt_enable.enable_joypad and self.bus.interrupt_flag.enable_joypad) {
                    // std.debug.print("HANDLING JOYPAD\n", .{});
                    self.bus.interrupt_flag.enable_joypad = false;
                    self.pc = @intFromEnum(ISR.Joypad);
                    self.clock.t_cycles += 20;
                }
                // std.debug.print("INTERRUPT TO PC=0x{x}\n", .{self.pc});
            }
        }
        if (self.ime == IME.EILagCycle) {
            // std.debug.print("IME.EILagCycle -> IME.Enabled at PC=0x{x}\n", .{self.pc});
            self.ime = IME.Enabled;
        }
        // can doing this regardless of interrupt or halt occuring break things? should always be 0 cycles?
        self.pending_t_cycles = self.clock.t_cycles - current_cycles;
        self.bus.step(self.pending_t_cycles, self.clock.bits.div);

        self.pending_t_cycles = 0;
        current_cycles = self.clock.t_cycles;

        // gameboy_doctor_print(self);
        // beeg_print(self);
        if (self.halt_state == HaltState.SwitchedOn or self.halt_state == HaltState.Enabled) {
            self.halt_state = HaltState.Enabled;
            // self.pc -%= 1;
            self.clock.t_cycles += 4;
        } else {
            self.step();
        }
        self.pending_t_cycles = self.clock.t_cycles - current_cycles;
        self.bus.step(self.pending_t_cycles, self.clock.bits.div);
    }

    pub fn step(self: *CPU) void {
        // std.debug.print("CPU STEP PC: 0x{x}\n", .{self.pc});
        var instruction_byte = self.bus.read_byte(self.pc);
        const prefixed = instruction_byte == 0xCB;
        if (prefixed) {
            instruction_byte = self.bus.read_byte(self.pc +% 1);
        }
        if (Instruction.from_byte(instruction_byte, prefixed)) |instruction| blk: {
            break :blk self.execute(instruction);
        } else {
            std.debug.panic("Unknown instruction for 0x{s}{x}\n", .{ if (prefixed) "cb" else "", instruction_byte });
        }
    }
    fn jump(self: *CPU, should_jump: bool) u16 {
        if (should_jump) {
            const low = self.bus.read_byte(self.pc +% 1);
            const high = self.bus.read_byte(self.pc +% 2);
            const address = @as(u16, high) << 8 | @as(u16, low);
            return address;
        } else {
            return self.pc +% 3;
        }
    }
    fn jump_relative(self: *CPU, should_jump: bool) u16 {
        var new_pc = self.pc +% 2;
        if (should_jump) {
            const offset = self.read_next_byte();
            const signed: i8 = @bitCast(offset);
            if (signed < 0) {
                new_pc = new_pc -% @abs(signed);
            } else {
                new_pc = new_pc +% @abs(signed);
            }
            return new_pc;
        } else {
            return self.pc +% 2;
        }

        return new_pc;
    }
    fn add(self: *CPU, value: u8) u8 {
        const result = @addWithOverflow(self.registers.A, value);
        const sum = result[0];
        const carry = result[1];

        self.registers.F = .{
            .zero = sum == 0,
            .subtract = false,
            .carry = carry == 1,
            .half_carry = (((self.registers.A & 0xF) + (value & 0xF)) > 0xF),
        };
        return sum;
    }

    fn wadd(self: *CPU, value: u16) u16 {
        const result = @addWithOverflow(self.registers.get_HL(), value);
        const sum = result[0];
        const carry = result[1];

        self.registers.F.subtract = false;
        self.registers.F.half_carry = (((self.registers.get_HL() & 0xFFF) + (value & 0xFFF)) > 0xFFF);
        self.registers.F.carry = carry == 1;

        return sum;
    }

    fn spadd(self: *CPU, value: u8) u16 {
        const signed: i8 = @bitCast(value);
        // const extended: u16 = @intCast(signed);
        const extended = @as(i16, signed);
        // const unsigned: u16 = @intCast(@abs(extended));
        const unsigned: u16 = @bitCast(extended);
        // std.debug.print("SPADD: {} + {}\n", .{ self.sp, unsigned });
        const sum = self.sp +% unsigned;
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .carry = (((self.sp & 0xFF) + (unsigned & 0xFF)) > 0xFF),
            .half_carry = (((self.sp & 0xF) + (value & 0xF)) > 0xF),
        };
        return sum;
    }

    fn adc(self: *CPU, value: u8) u8 {
        const carry: u8 = @intFromBool(self.registers.F.carry);
        const result = @addWithOverflow(self.registers.A, value);
        const result2 = @addWithOverflow(result[0], carry);
        const sum = result2[0];
        const overflow = result2[1] | result[1];

        self.registers.F = FlagRegister{
            .zero = sum == 0,
            .subtract = false,
            .carry = overflow == 1,
            .half_carry = (((self.registers.A & 0xF) + (value & 0xF) + carry) > 0xF),
        };

        return sum;
    }

    fn sub(self: *CPU, value: u8) u8 {
        const result = @subWithOverflow(self.registers.A, value);
        const sum = result[0];
        const carry = result[1];

        self.registers.F = .{
            .zero = sum == 0,
            .subtract = true,
            .carry = carry == 1,
            .half_carry = (((@as(i16, self.registers.A) & 0xF) - (@as(i16, value) & 0xF)) < 0),
        };

        return sum;
    }

    fn sbc(self: *CPU, value: u8) u8 {
        const carry = @intFromBool(self.registers.F.carry);
        const result = @subWithOverflow(self.registers.A, value);
        const result2 = @subWithOverflow(result[0], carry);
        const sum = result2[0];
        const overflow = result2[1] | result[1];

        self.registers.F = .{
            .zero = sum == 0,
            .subtract = true,
            .carry = overflow == 1,
            // .half_carry = (((@as(i16, self.registers.A) & 0xF) - (@as(i16, value) & 0xF) - carry) < 0),
            .half_carry = (self.registers.A & 0xF) < (value & 0xF) + carry,
        };

        return sum;
    }

    fn and_(self: *CPU, value: u8) u8 {
        const result = self.registers.A & value;

        self.registers.F = FlagRegister{
            .zero = result == 0,
            .subtract = false,
            .half_carry = true,
            .carry = false,
        };

        return result;
    }

    fn xor(self: *CPU, value: u8) u8 {
        const result = self.registers.A ^ value;

        self.registers.F = FlagRegister{
            .zero = result == 0,
            .subtract = false,
            .half_carry = false,
            .carry = false,
        };

        return result;
    }

    fn or_(self: *CPU, value: u8) u8 {
        const result = self.registers.A | value;

        self.registers.F = FlagRegister{
            .zero = result == 0,
            .subtract = false,
            .half_carry = false,
            .carry = false,
        };

        return result;
    }
    fn cp(self: *CPU, value: u8) void {
        const result = @subWithOverflow(self.registers.A, value);
        const sum = result[0];
        const carry = result[1];

        self.registers.F = .{
            .zero = sum == 0,
            .subtract = true,
            .carry = carry == 1,
            .half_carry = (((@as(i16, self.registers.A) & 0xF) - (@as(i16, value) & 0xF)) < 0),
        };

        return;
    }

    fn inc(self: *CPU, value: u8) u8 {
        const result = value +% 1;
        self.registers.F.zero = result == 0;
        self.registers.F.subtract = false;
        self.registers.F.half_carry = (value & 0xF) == 0xF;
        return result;
    }

    fn winc(_: *CPU, value: u16) u16 {
        const result = value +% 1;
        return result;
    }

    fn dec(self: *CPU, value: u8) u8 {
        const result = value -% 1;
        self.registers.F.zero = result == 0;
        self.registers.F.subtract = true;
        self.registers.F.half_carry = (value & 0xF) == 0x0;
        return result;
    }

    fn wdec(_: *CPU, value: u16) u16 {
        const result = value -% 1;
        return result;
    }

    // there are a million implementations that are blargg inaccurate
    // an emu accuracy tester posted these simple set of rules that seem to nail the quirks:
    //
    // If N == 0 and A >= $9A, set C
    // If N == 0 and (A & $0F) >= $0A, set H
    // adjustment is ($06 if H else $00) | ($60 if C else $00)
    // Add adjustment if N is 0 or subtract adjustment if N is 1
    // Z = A == 0, N unchanged, clear H to 0
    fn daa(self: *CPU, value: u8) u8 {
        if (!self.registers.F.subtract and (value >= 0x9A)) {
            self.registers.F.carry = true;
        }
        if (!self.registers.F.subtract and ((value & 0xF) >= 0xA)) {
            self.registers.F.half_carry = true;
        }
        var adjustment: u8 = 0;
        if (self.registers.F.half_carry) {
            adjustment = 0x06;
        }
        if (self.registers.F.carry) {
            adjustment = adjustment | 0x60;
        }
        var new_value = value;
        if (self.registers.F.subtract) {
            new_value = value -% adjustment;
        } else {
            new_value = value +% adjustment;
        }
        self.registers.F.zero = new_value == 0;
        self.registers.F.half_carry = false;

        return new_value;
    }

    fn cpl(self: *CPU) void {
        self.registers.A = self.registers.A ^ 0xFF;
        self.registers.F.subtract = true;
        self.registers.F.half_carry = true;
    }

    fn ccf(self: *CPU) void {
        self.registers.F = .{
            .zero = self.registers.F.zero,
            .subtract = false,
            .half_carry = false,
            .carry = !self.registers.F.carry,
        };
    }

    fn scf(self: *CPU) void {
        self.registers.F = .{
            .zero = self.registers.F.zero,
            .subtract = false,
            .half_carry = false,
            .carry = true,
        };
    }

    // would rather have clear rotate instructions than generalize these ugly things
    fn rl(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        const new_value = (value << 1) | @intFromBool(self.registers.F.carry);
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = (value & 0x80) > 0,
        };

        return new_value;
    }

    fn rla(self: *CPU, value: u8) u8 {
        const new_value = (value << 1) | @intFromBool(self.registers.F.carry);
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = (value & 0x80) > 0,
        };

        return new_value;
    }

    fn rlc(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        const shift_carry = value >> 7;
        const new_value = (value << 1) | shift_carry;
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = shift_carry == 1,
        };
        return new_value;
    }

    fn rlca(self: *CPU, value: u8) u8 {
        const shift_carry = value >> 7;
        const new_value = (value << 1) | shift_carry;
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = shift_carry == 1,
        };
        return new_value;
    }

    fn rr(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        // const carry = value & 1;
        // const new_value = (value >> 1) | (carry << 7);
        const carry: u1 = @intFromBool(self.registers.F.carry);
        const new_value = (value >> 1) | @as(u8, (carry)) << @intCast(7);
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = value & 1 == 1,
        };
        return new_value;
    }

    fn rra(self: *CPU, value: u8) u8 {
        const carry: u1 = @intFromBool(self.registers.F.carry);
        const new_value = (value >> 1) | @as(u8, carry) << @intCast(7);
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = value & 1 == 1,
        };
        return new_value;
    }

    fn rrc(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        const shift_carry = value & 1;
        const new_value = (value >> 1) | @as(u8, shift_carry) << @intCast(7);
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = shift_carry == 1,
        };
        return new_value;
    }

    fn rrca(self: *CPU, value: u8) u8 {
        const shift_carry = value & 1;
        const new_value = (value >> 1) | @as(u8, shift_carry) << @intCast(7);
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = shift_carry == 1,
        };
        return new_value;
    }

    fn shift_left_arithmetic(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        const carry = value >> 7;
        const new_value = value << 1;
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = carry == 1,
        };
        return new_value;
    }

    fn shift_right_arithmetic(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        const carry = value & 1;
        const new_value = (value >> 1) | (value & 0x80);
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = carry == 1,
        };
        return new_value;
    }

    // fn shift_left_logical(self: *CPU, value: u8) u8 {
    //     const carry = value >> 7;
    //     const new_value = value << 1;
    //     self.registers.F = .{
    //         .zero = new_value == 0,
    //         .subtract = false,
    //         .half_carry = false,
    //         .carry = carry == 1,
    //     };
    //     return new_value;
    // }

    fn shift_right_logical(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        const carry = value & 1;
        const new_value = value >> 1;
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = carry == 1,
        };
        return new_value;
    }

    fn swap(self: *CPU, value: u8, _: PrefixExtendedArgs) u8 {
        const new_value = (value >> 4) | (value << 4);
        self.registers.F = .{
            .zero = new_value == 0,
            .subtract = false,
            .half_carry = false,
            .carry = false,
        };
        return new_value;
    }
    fn bit(self: *CPU, value: u8, args: PrefixExtendedArgs) u8 {
        const bit_check = (value >> args.bit.?) & 1;
        self.registers.F = .{
            .zero = bit_check == 0,
            .subtract = false,
            .half_carry = true,
            .carry = self.registers.F.carry,
        };

        return value;
    }

    fn set(_: *CPU, value: u8, args: PrefixExtendedArgs) u8 {
        return value | (@as(u8, 1) << args.bit.?);
    }

    fn reset(_: *CPU, value: u8, args: PrefixExtendedArgs) u8 {
        return value & ~(@as(u8, 1) << args.bit.?);
    }

    // fn handle_prefix_instruction(self: *CPU, target: PrefixTarget, instruction: Instruction, op: *const fn (*CPU, u8) u8) u16 {
    fn handle_prefix_instruction(self: *CPU, target: PrefixTarget, op: *const fn (*CPU, u8, PrefixExtendedArgs) u8, args: PrefixExtendedArgs) void {
        switch (target) {
            PrefixTarget.A => {
                const value = self.registers.A;
                const new_value = op(self, value, args);
                self.registers.A = new_value;
                self.clock.t_cycles += args.r8_cycles;
            },
            PrefixTarget.B => {
                const value = self.registers.B;
                const new_value = op(self, value, args);
                self.registers.B = new_value;
                self.clock.t_cycles += args.r8_cycles;
            },
            PrefixTarget.C => {
                const value = self.registers.C;
                const new_value = op(self, value, args);
                self.registers.C = new_value;
                self.clock.t_cycles += args.r8_cycles;
            },
            PrefixTarget.D => {
                const value = self.registers.D;
                const new_value = op(self, value, args);
                self.registers.D = new_value;
                self.clock.t_cycles += args.r8_cycles;
            },
            PrefixTarget.E => {
                const value = self.registers.E;
                const new_value = op(self, value, args);
                self.registers.E = new_value;
                self.clock.t_cycles += args.r8_cycles;
            },
            PrefixTarget.H => {
                const value = self.registers.H;
                const new_value = op(self, value, args);
                self.registers.H = new_value;
                self.clock.t_cycles += args.r8_cycles;
            },
            PrefixTarget.L => {
                const value = self.registers.L;
                const new_value = op(self, value, args);
                self.registers.L = new_value;
                self.clock.t_cycles += args.r8_cycles;
            },
            PrefixTarget.HLI => {
                const value = self.bus.read_byte(self.registers.get_HL());
                const new_value = op(self, value, args);
                self.bus.write_byte(self.registers.get_HL(), new_value);
                self.clock.t_cycles += args.hl_cycles;
            },
        }
    }

    fn push(self: *CPU, value: u16) void {
        const high: u8 = @truncate(value >> 8);
        self.sp = self.sp -% 1;
        self.bus.write_byte(self.sp, high);

        const low: u8 = @truncate(value & 0xFF);
        self.sp = self.sp -% 1;
        self.bus.write_byte(self.sp, low);
    }

    fn pop(self: *CPU) u16 {
        const low = self.bus.read_byte(self.sp);
        self.sp = self.sp +% 1;
        const high = self.bus.read_byte(self.sp);
        self.sp = self.sp +% 1;
        return @as(u16, high) << 8 | @as(u16, low);
    }

    /// For the call opcode, we increment pc prior to the call
    /// wheras for interrupt usage we return to the current instruction so leave pc as is
    fn call(self: *CPU, next_pc: u16, should_call: bool) u16 {
        if (should_call) {
            self.push(next_pc);
            const address = self.read_next_word();
            return address;
        } else {
            return next_pc;
        }
    }

    fn interrupt_call(self: *CPU, address: u16) u16 {
        self.push(self.pc);
        return address;
    }

    fn ret(self: *CPU, should_return: bool) u16 {
        if (should_return) {
            const address = self.pop();
            return address;
        } else {
            return self.pc +% 1;
        }
    }

    fn di(self: *CPU) u16 {
        self.ime = IME.Disabled;
        return self.pc +% 1;
    }

    fn ei(self: *CPU) u16 {
        self.ime = IME.EILagCycle;
        return self.pc +% 1;
    }

    fn reti(self: *CPU) u16 {
        self.ime = IME.Enabled;
        const address = self.pop();
        return address;
    }
    fn rst(self: *CPU, location: RstLocation) u16 {
        const address: u16 = @intFromEnum(location);
        self.push(self.pc +% 1);
        return address;
    }

    pub fn new(filename: []u8) !CPU {
        const cpu: CPU = CPU{
            .registers = Registers{
                .A = 0x01,
                .B = 0x00,
                .C = 0x13,
                .D = 0x00,
                .E = 0xD8,
                .F = @bitCast(@as(u8, 0xB0)),
                // .F = .{
                //     .zero = false,
                //     .subtract = false,
                //     .half_carry = false,
                //     .carry = false,
                // },
                .H = 0x01,
                .L = 0x4D,
            },
            .pc = 0x0100,
            .sp = 0xFFFE,
            .bus = try MemoryBus.new(filename),
            .halt_state = HaltState.Disabled,
            .is_stopped = false,
            .ime = IME.Disabled,
            .pending_t_cycles = 0,
            .clock = .{ .t_cycles = 0 },
        };
        return cpu;
    }

    fn read_next_byte(self: *CPU) u8 {
        const byte = self.bus.read_byte(self.pc +% 1);
        return byte;
    }

    fn write_next_byte(self: *CPU, byte: u8) void {
        self.bus.write_byte(self.pc +% 1, byte);
    }

    fn read_next_word(self: *CPU) u16 {
        const low = self.bus.read_byte(self.pc +% 1);
        const high = self.bus.read_byte(self.pc +% 2);
        return @as(u16, high) << 8 | @as(u16, low);
    }
};

/// Prints state of cpu that can be diffed against using gameboy_doctor
/// just pipe GBEMU | gameboy_doctor
fn gameboy_doctor_print(self: *CPU) void {
    log.print("A:{x:0>2} F:{x:0>2} B:{x:0>2} C:{x:0>2} D:{x:0>2} E:{x:0>2} H:{x:0>2} L:{x:0>2} SP:{x:0>4} PC:{x:0>4} PCMEM:{x:0>2},{x:0>2},{x:0>2},{x:0>2}\n", .{
        self.registers.A,
        @as(u8, @bitCast(self.registers.F)),
        self.registers.B,
        self.registers.C,
        self.registers.D,
        self.registers.E,
        self.registers.H,
        self.registers.L,
        self.sp,
        self.pc,
        self.bus.read_byte(self.pc),
        self.bus.read_byte(self.pc +% 1),
        self.bus.read_byte(self.pc +% 2),
        self.bus.read_byte(self.pc +% 3),
    }) catch unreachable;

    std.debug.print("A:{x:0>2} F:{x:0>2} B:{x:0>2} C:{x:0>2} D:{x:0>2} E:{x:0>2} H:{x:0>2} L:{x:0>2} SP:{x:0>4} PC:{x:0>4} PCMEM:{x:0>2},{x:0>2},{x:0>2},{x:0>2}\n", .{
        self.registers.A,
        @as(u8, @bitCast(self.registers.F)),
        self.registers.B,
        self.registers.C,
        self.registers.D,
        self.registers.E,
        self.registers.H,
        self.registers.L,
        self.sp,
        self.pc,
        self.bus.read_byte(self.pc),
        self.bus.read_byte(self.pc +% 1),
        self.bus.read_byte(self.pc +% 2),
        self.bus.read_byte(self.pc +% 3),
    });
    return;
}

fn beeg_print(self: *CPU) void {
    // if (self.pc <= 0x100) {
    //     return;
    // }
    log.print("A: {X:0>2} F: {X:0>2} B: {X:0>2} C: {X:0>2} D: {X:0>2} E: {X:0>2} H: {X:0>2} L: {X:0>2} SP: {X:0>4} PC: 00:{X:0>4} ({X:0>2} {X:0>2} {X:0>2} {X:0>2})\n", .{
        self.registers.A,
        @as(u8, @bitCast(self.registers.F)),
        self.registers.B,
        self.registers.C,
        self.registers.D,
        self.registers.E,
        self.registers.H,
        self.registers.L,
        self.sp,
        self.pc,
        self.bus.read_byte(self.pc),
        self.bus.read_byte(self.pc +% 1),
        self.bus.read_byte(self.pc +% 2),
        self.bus.read_byte(self.pc +% 3),
    }) catch unreachable;

    // std.debug.print("A: {X:0>2} F: {X:0>2} B: {X:0>2} C: {X:0>2} D: {X:0>2} E: {X:0>2} H: {X:0>2} L: {X:0>2} SP: {X:0>4} PC: 00:{X:0>4} ({X:0>2} {X:0>2} {X:0>2} {X:0>2})\n", .{
    //     self.registers.A,
    //     @as(u8, @bitCast(self.registers.F)),
    //     self.registers.B,
    //     self.registers.C,
    //     self.registers.D,
    //     self.registers.E,
    //     self.registers.H,
    //     self.registers.L,
    //     self.sp,
    //     self.pc,
    //     self.bus.read_byte(self.pc),
    //     self.bus.read_byte(self.pc +% 1),
    //     self.bus.read_byte(self.pc +% 2),
    //     self.bus.read_byte(self.pc +% 3),
    // });
    return;
}
