const std = @import("std");

const Registers = struct {
    A: u8,
    B: u8,
    C: u8,
    D: u8,
    E: u8,
    F: u8,
    H: u8,
    L: u8,
    fn get_AF(self: *Registers) u16 {
        return @as(u16, self.A) << 8 | @as(u16, self.F);
    }

    fn set_AF(self: *Registers, value: u16) void {
        self.A = @truncate((value & 0xFF00) >> 8);
        self.F = @truncate(value & 0xFF);
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

const FlagRegister = struct {
    zero: u1,
    subtract: u1,
    half_carry: u1,
    carry: u1,
};

fn flag_to_u8(flag: FlagRegister) u8 {
    return @as(u8, flag.zero) << 7 | @as(u8, flag.subtract) << 6 | @as(u8, flag.half_carry) << 5 | @as(u8, flag.carry) << 4;
}
fn u8_to_flag(value: u8) FlagRegister {
    return FlagRegister{
        .zero = (value & 0b1000_0000) != 0,
        .subtract = (value & 0b0100_0000) != 0,
        .half_carry = (value & 0b0010_0000) != 0,
        .carry = (value & 0b0001_0000) != 0,
    };
}

const ArithmeticTarget = enum {
    A,
    B,
    C,
    D,
    E,
    H,
    L,
};

const Instruction = union(enum) {
    ADD: ArithmeticTarget,
    fn from_byte(byte: u8) Instruction {
        const inst = switch (byte) {
            0x80 => return Instruction{ .ADD = ArithmeticTarget.A },
            0x81 => return Instruction{ .ADD = ArithmeticTarget.B },
            _ => unreachable,
        };
        return inst;
    }
};

const CPU = struct {
    registers: Registers,
    pc: u16,
    bus: MemoryBus,
    fn execute(self: *CPU, instruction: Instruction) void {
        switch (instruction) {
            Instruction.ADD => |target| {
                switch (target) {
                    ArithmeticTarget.A => std.debug.print("ADD A\n", .{}),
                    ArithmeticTarget.B => std.debug.print("ADD B\n", .{}),
                    ArithmeticTarget.C => {
                        const value = self.registers.C;
                        const new_value = self.add(value);
                        self.registers.A = new_value;
                        self.pc = self.pc +% 1;
                    },
                    ArithmeticTarget.D => std.debug.print("ADD D\n", .{}),
                    ArithmeticTarget.E => std.debug.print("ADD E\n", .{}),
                    ArithmeticTarget.H => std.debug.print("ADD H\n", .{}),
                    ArithmeticTarget.L => std.debug.print("ADD L\n", .{}),
                }
            },
        }
    }
    fn step(self: *const CPU) void {
        const instruction_byte = self.bus.read_bytes(self.pc);
        const next_pc = if (Instruction.from_byte(instruction_byte)) |instruction| {
            self.execute(instruction);
        } else {
            std.debug.panic("Unknown instruction for 0x{x}\n", .{instruction_byte});
        };
        self.pc = next_pc;
    }
    fn add(self: *CPU, value: u8) u8 {
        const result = @addWithOverflow(self.registers.A, value);
        const sum = result[0];
        const carry = result[1];
        const flags = flag_to_u8(.{
            .zero = if (sum == 0) 1 else 0,
            .subtract = 0,
            .carry = carry,
            .half_carry = if (((self.registers.A & 0xF) + (value & 0xF)) > 0xF) 1 else 0,
        });
        self.registers.F = flags;
        return sum;
    }
    pub fn new() CPU {
        const cpu: CPU = CPU{
            .registers = Registers{
                .A = 0x12,
                .B = 0x34,
                .C = 0x56,
                .D = 0x78,
                .E = 0x9A,
                .F = 0xBC,
                .H = 0xDE,
                .L = 0xF0,
            },
            .pc = 0x00,
            .bus = MemoryBus.new(),
        };
        return cpu;
    }
};

const MemoryBus = struct {
    memory: [0x10000]u8,
    pub fn new() MemoryBus {
        return MemoryBus{
            .memory = [_]u8{0} ** 0x10000,
        };
    }
    fn read_bytes(self: *const MemoryBus, address: u16) u8 {
        return self.memory[address];
    }
};

pub fn main() !void {}

test "simple test" {
    std.debug.print("Hello, world!\n", .{});
    const insta = Instruction{ .ADD = ArithmeticTarget.A };
    const instc = Instruction{ .ADD = ArithmeticTarget.C };
    var cpu = CPU.new();
    std.debug.print("A: {x}\n", .{cpu.registers.A});
    cpu.execute(insta);
    cpu.execute(instc);

    std.debug.print("A: {x}\n", .{cpu.registers.A});
}
