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
    get_AF: *const fn (self: *Registers) u16,
    set_AF: *const fn (self: *Registers, value: u16) void,
    get_BC: *const fn (self: *Registers) u16,
    set_BC: *const fn (self: *Registers, value: u16) void,
    get_DE: *const fn (self: *Registers) u16,
    set_DE: *const fn (self: *Registers, value: u16) void,
    get_HL: *const fn (self: *Registers) u16,
    set_HL: *const fn (self: *Registers, value: u16) void,
};

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
};

const CPU = struct {
    registers: Registers,
    execute: *const fn (self: *const CPU, instruction: Instruction) void,
    add: *const fn (self: *const CPU, value: u8) u8,
};

fn execute(self: *const CPU, instruction: Instruction) void {
    switch (instruction) {
        Instruction.ADD => |target| {
            switch (target) {
                ArithmeticTarget.A => std.debug.print("ADD A\n", .{}),
                ArithmeticTarget.B => std.debug.print("ADD B\n", .{}),
                ArithmeticTarget.C => {
                    const value = self.registers.C;
                    const new_value = self.add(self, value);
                    self.registers.A = new_value;
                },
                ArithmeticTarget.D => std.debug.print("ADD D\n", .{}),
                ArithmeticTarget.E => std.debug.print("ADD E\n", .{}),
                ArithmeticTarget.H => std.debug.print("ADD H\n", .{}),
                ArithmeticTarget.L => std.debug.print("ADD L\n", .{}),
            }
        },
    }
}

fn add(self: *const CPU, value: u8) u8 {
    const result: u8 = @addWithOverflow(self.registers.A, value);
    self.registers.F.zero = result == 0;
    self.registers.F.subtract = 0;
    if (result.overflow) {
        self.registers.F.carry = 1;
    }
    self.registers.F.half_carry = ((self.registers.A & 0xF) + (value & 0xF)) > 0xF;
    return result;
}

pub fn main() !void {
    var regs = Registers{
        .A = 0x12,
        .B = 0x34,
        .C = 0x56,
        .D = 0x78,
        .E = 0x9A,
        .F = 0xBC,
        .H = 0xDE,
        .L = 0xF0,
        .get_AF = get_AF,
        .set_AF = set_AF,
        .get_BC = get_BC,
        .set_BC = set_BC,
        .get_DE = get_DE,
        .set_DE = set_DE,
        .get_HL = get_HL,
        .set_HL = set_HL,
    };
    regs.set_AF(&regs, 0x1234);
    std.debug.print("{x}\n", .{regs.get_AF(&regs)});

    const insta = Instruction{ .ADD = ArithmeticTarget.A };
    const instd = Instruction{ .ADD = ArithmeticTarget.D };
    const cpu = CPU{ .execute = execute };
    cpu.execute(&cpu, insta);
    cpu.execute(&cpu, instd);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
