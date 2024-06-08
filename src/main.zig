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

const JumpTest = enum {
    NotZero,
    Zero,
    NotCarry,
    Carry,
    Always,
};

const LoadByteTarget = enum { A, B, C, D, E, H, L, HLI };

const LoadByteSource = enum { A, B, C, D, E, H, L, D8, HLI };

const LoadType = union(enum) { Byte: struct { target: LoadByteTarget, source: LoadByteSource } };

const StackTarget = enum { BC, DE, HL, AF };

const Instruction = union(enum) {
    ADD: ArithmeticTarget,
    JP: JumpTest,
    LD: LoadType,
    PUSH: StackTarget,
    POP: StackTarget,
    CALL: JumpTest,
    RET: JumpTest,
    fn from_byte(byte: u8, prefixed: bool) ?Instruction {
        if (prefixed) {
            return Instruction.from_byte_prefixed(byte);
        } else {
            return Instruction.from_byte_not_prefixed(byte);
        }
    }

    fn from_byte_not_prefixed(byte: u8) ?Instruction {
        const inst = switch (byte) {
            // 0x80 => return Instruction{ .ADD = ArithmeticTarget.A },
            // 0x81 => return Instruction{ .ADD = ArithmeticTarget.B },
            _ => unreachable,
        };
        return inst;
    }
    fn from_byte_prefixed(byte: u8) ?Instruction {
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
    sp: u16,
    bus: MemoryBus,
    fn execute(self: *CPU, instruction: Instruction) u16 {
        const res = blk: {
            switch (instruction) {
                Instruction.CALL => |jt| {
                    const flags = u8_to_flag(self.registers.F);
                    const jump_condition = jmpBlk: {
                        switch (jt) {
                            JumpTest.NotZero => {
                                std.debug.print("CALL NZ\n", .{});
                                break :jmpBlk !flags.zero;
                            },
                            JumpTest.NotCarry => {
                                std.debug.print("CALL NC\n", .{});
                                break :jmpBlk !flags.carry;
                            },
                            JumpTest.Zero => {
                                std.debug.print("CALL Z\n", .{});
                                break :jmpBlk flags.zero;
                            },
                            JumpTest.Carry => {
                                std.debug.print("CALL C\n", .{});
                                break :jmpBlk flags.carry;
                            },
                            JumpTest.Always => {
                                std.debug.print("CALL\n", .{});
                                break :jmpBlk true;
                            },
                        }
                    };
                    self.call(jump_condition);
                },
                Instruction.RET => |jt| {
                    const flags = u8_to_flag(self.registers.F);
                    const jump_condition = jmpBlk: {
                        switch (jt) {
                            JumpTest.NotZero => {
                                std.debug.print("RET NZ\n", .{});
                                break :jmpBlk !flags.zero;
                            },
                            JumpTest.NotCarry => {
                                std.debug.print("RET NC\n", .{});
                                break :jmpBlk !flags.carry;
                            },
                            JumpTest.Zero => {
                                std.debug.print("RET Z\n", .{});
                                break :jmpBlk flags.zero;
                            },
                            JumpTest.Carry => {
                                std.debug.print("RET C\n", .{});
                                break :jmpBlk flags.carry;
                            },
                            JumpTest.Always => {
                                std.debug.print("RET\n", .{});
                                break :jmpBlk true;
                            },
                        }
                    };
                    self.ret(jump_condition);
                },
                Instruction.POP => |target| {
                    const result = self.pop();
                    switch (target) {
                        StackTarget.BC => {
                            std.debug.print("POP BC\n", .{});
                            self.registers.set_BC(result);
                        },
                        _ => {
                            std.debug.panic!("Unknown POP target");
                        },
                    }
                    const next_pc = self.pc +% 1;
                    break :blk next_pc;
                },
                Instruction.PUSH => |target| {
                    const value = pushBlk: {
                        switch (target) {
                            StackTarget.BC => {
                                std.debug.print("PUSH BC\n", .{});
                                break :pushBlk self.registers.get_BC();
                            },
                            _ => {
                                std.debug.panic!("Unknown PUSH target");
                            },
                        }
                    };
                    self.push(value);
                    const next_pc = self.pc +% 1;
                    break :blk next_pc;
                },
                Instruction.LD => |load| {
                    switch (load) {
                        LoadType.Byte => |byte| {
                            std.debug.print("LD target {} source {}\n", .{ byte.target, byte.source });
                            const source_value = sourceBlk: {
                                switch (byte.source) {
                                    LoadByteSource.A => {
                                        std.debug.print("LD A\n", .{});
                                        break :sourceBlk self.registers.A;
                                    },
                                    LoadByteSource.B => {
                                        std.debug.print("LD B\n", .{});
                                        break :sourceBlk self.registers.B;
                                    },
                                    LoadByteSource.C => {
                                        std.debug.print("LD C\n", .{});
                                        break :sourceBlk self.registers.C;
                                    },
                                    LoadByteSource.D => {
                                        std.debug.print("LD D\n", .{});
                                        break :sourceBlk self.registers.D;
                                    },
                                    LoadByteSource.E => {
                                        std.debug.print("LD E\n", .{});
                                        break :sourceBlk self.registers.E;
                                    },
                                    LoadByteSource.H => {
                                        std.debug.print("LD H\n", .{});
                                        break :sourceBlk self.registers.H;
                                    },
                                    LoadByteSource.L => {
                                        std.debug.print("LD L\n", .{});
                                        break :sourceBlk self.registers.L;
                                    },
                                    LoadByteSource.D8 => {
                                        std.debug.print("LD D8\n", .{});
                                        self.read_next_byte();
                                    },
                                    LoadByteSource.HLI => {
                                        std.debug.print("LD HLI\n", .{});
                                        self.bus.read_bytes(self.registers.get_HL());
                                    },
                                }
                            };
                            switch (byte.target) {
                                LoadByteTarget.A => {
                                    std.debug.print("LD A\n", .{});
                                    self.registers.A = source_value;
                                },
                                LoadByteTarget.B => {
                                    std.debug.print("LD B\n", .{});
                                    self.registers.B = source_value;
                                },
                                LoadByteTarget.C => {
                                    std.debug.print("LD C\n", .{});
                                    self.registers.C = source_value;
                                },
                                LoadByteTarget.D => {
                                    std.debug.print("LD D\n", .{});
                                    self.registers.D = source_value;
                                },
                                LoadByteTarget.E => {
                                    std.debug.print("LD E\n", .{});
                                    self.registers.E = source_value;
                                },
                                LoadByteTarget.H => {
                                    std.debug.print("LD H\n", .{});
                                    self.registers.H = source_value;
                                },
                                LoadByteTarget.L => {
                                    std.debug.print("LD L\n", .{});
                                    self.registers.L = source_value;
                                },
                                LoadByteTarget.HLI => {
                                    std.debug.print("LD HLI\n", .{});
                                    self.bus.write_byte(self.registers.get_HL(), source_value);
                                },
                            }
                            const next_pc = pcBlk: {
                                switch (byte.source) {
                                    LoadByteSource.D8 => {
                                        break :pcBlk self.pc +% 2;
                                    },
                                    _ => {
                                        break :pcBlk self.pc +% 1;
                                    },
                                }
                            };
                            return next_pc;
                        },
                    }
                },
                Instruction.JP => |jt| {
                    const flags = u8_to_flag(self.registers.F);
                    const jump_condition = jpblk: {
                        switch (jt) {
                            JumpTest.NotZero => {
                                std.debug.print("JP NZ\n", .{});
                                break :jpblk !flags.zero;
                            },
                            JumpTest.NotCarry => {
                                std.debug.print("JP NC\n", .{});
                                break :jpblk !flags.carry;
                            },
                            JumpTest.Zero => {
                                std.debug.print("JP Z\n", .{});
                                break :jpblk flags.zero;
                            },
                            JumpTest.Carry => {
                                std.debug.print("JP C\n", .{});
                                break :jpblk flags.carry;
                            },
                            JumpTest.Always => {
                                std.debug.print("JP\n", .{});
                                break :jpblk true;
                            },
                        }
                    };
                    const new_pc = self.jump(jump_condition);
                    break :blk new_pc;
                },

                Instruction.ADD => |target| {
                    switch (target) {
                        ArithmeticTarget.A => {
                            std.debug.print("ADD A\n", .{});
                            break :blk 0;
                        },
                        ArithmeticTarget.B => {
                            std.debug.print("ADD B\n", .{});
                            break :blk 0;
                        },
                        ArithmeticTarget.C => {
                            const value = self.registers.C;
                            const new_value = self.add(value);
                            self.registers.A = new_value;
                            const new_pc: u16 = self.pc +% 1;
                            break :blk new_pc;
                        },
                        ArithmeticTarget.D => {
                            std.debug.print("ADD D\n", .{});
                            break :blk 0;
                        },
                        ArithmeticTarget.E => {
                            std.debug.print("ADD E\n", .{});
                            break :blk 0;
                        },
                        ArithmeticTarget.H => {
                            std.debug.print("ADD H\n", .{});
                            break :blk 0;
                        },
                        ArithmeticTarget.L => {
                            std.debug.print("ADD L\n", .{});
                            break :blk 0;
                        },
                    }
                },
            }
        };
        return res;
    }
    fn step(self: *const CPU) void {
        var instruction_byte = self.bus.read_bytes(self.pc);
        const prefixed = instruction_byte == 0xCB;
        if (prefixed) {
            instruction_byte = self.bus.read_bytes(self.pc +% 1);
        }
        const next_pc = if (Instruction.from_byte(instruction_byte)) |instruction| {
            self.execute(instruction);
        } else {
            std.debug.panic("Unknown instruction for 0x{}{x}\n", .{ if (prefixed) "cb" else "", instruction_byte });
        };

        self.pc = next_pc;
    }
    fn jump(self: *CPU, should_jump: bool) u16 {
        if (should_jump) {
            const low = self.bus.read_bytes(self.pc +% 1);
            const high = self.bus.read_bytes(self.pc +% 2);
            const address = @as(u16, high) << 8 | @as(u16, low);
            return address;
        } else {
            return self.pc +% 3;
        }
    }
    fn add(self: *CPU, value: u8) u8 {
        const result = @addWithOverflow(self.registers.A, value);
        const sum = result[0];
        const carry = result[1];
        const flags = flag_to_u8(FlagRegister{
            .zero = if (sum == 0) 1 else 0,
            .subtract = 0,
            .carry = carry,
            .half_carry = if (((self.registers.A & 0xF) + (value & 0xF)) > 0xF) 1 else 0,
        });
        self.registers.F = flags;
        return sum;
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
        const low = self.bus.read_bytes(self.sp);
        self.sp = self.sp +% 1;
        const high = self.bus.read_bytes(self.sp);
        self.sp = self.sp +% 1;
        return @as(u16, high) << 8 | @as(u16, low);
    }

    fn call(self: *CPU, should_call: bool) void {
        const next_pc = self.pc +% 3;
        if (should_call) {
            self.push(next_pc);
            const address = self.read_next_word();
            return address;
        } else {
            return next_pc;
        }
    }

    fn ret(self: *CPU, should_return: bool) void {
        if (should_return) {
            const address = self.pop();
            return address;
        } else {
            return self.pc +% 1;
        }
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
            .sp = 0x00,
            .bus = MemoryBus.new(),
        };
        return cpu;
    }

    fn read_next_byte(self: *CPU) u8 {
        const byte = self.bus.read_bytes(self.pc +% 1);
        return byte;
    }

    fn write_next_byte(self: *CPU, byte: u8) void {
        self.bus.write_byte(self.pc +% 1, byte);
    }

    fn read_next_word(self: *CPU) u16 {
        const low = self.bus.read_bytes(self.pc +% 1);
        const high = self.bus.read_bytes(self.pc +% 2);
        return @as(u16, high) << 8 | @as(u16, low);
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
    fn write_byte(self: *MemoryBus, addr: u16, byte: u8) void {
        self.memory[addr] = byte;
    }
};

pub fn main() !void {}

test "simple test" {
    std.debug.print("Hello, world!\n", .{});
    const insta = Instruction{ .ADD = ArithmeticTarget.A };
    const instc = Instruction{ .ADD = ArithmeticTarget.C };
    var cpu = CPU.new();
    std.debug.print("A: {x}\n", .{cpu.registers.A});
    _ = cpu.execute(insta);
    _ = cpu.execute(instc);

    std.debug.print("A: {x}\n", .{cpu.registers.A});
}
