const std = @import("std");

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
    LD: LoadType,
    PUSH: StackTarget,
    POP: StackTarget,
    CALL: JumpTest,
    RET: JumpTest,
    NOP: void,
    HALT: void,
    fn from_byte(byte: u8, prefixed: bool) ?Instruction {
        if (prefixed) {
            return Instruction.from_byte_prefixed(byte);
        } else {
            return Instruction.from_byte_not_prefixed(byte);
        }
    }

    fn from_byte_not_prefixed(byte: u8) ?Instruction {
        const inst = switch (byte) {
            0x80 => return Instruction{ .ADD = ArithmeticTarget.B },
            0x81 => return Instruction{ .ADD = ArithmeticTarget.C },
            0x82 => return Instruction{ .ADD = ArithmeticTarget.D },
            0x83 => return Instruction{ .ADD = ArithmeticTarget.E },
            0x84 => return Instruction{ .ADD = ArithmeticTarget.H },
            0x85 => return Instruction{ .ADD = ArithmeticTarget.L },
            // HL
            // 0x86 => return Instruction{ .ADD = ArithmeticTarget.C },
            0x87 => return Instruction{ .ADD = ArithmeticTarget.A },
            _ => unreachable,
        };
        return inst;
    }
    fn from_byte_prefixed(byte: u8) ?Instruction {
        const inst = switch (byte) {
            // 0x80 => return Instruction{ .ADD = ArithmeticTarget.A },
            // 0x81 => return Instruction{ .ADD = ArithmeticTarget.B },
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
    is_halted: bool,
    fn execute(self: *CPU, instruction: Instruction) u16 {
        if (self.is_halted) {
            return self.pc;
        }
        const res = blk: {
            switch (instruction) {
                Instruction.NOP => {
                    const next_pc = self.pc +% 1;
                    break :blk next_pc;
                },
                Instruction.HALT => {
                    self.is_halted = true;
                    const next_pc = self.pc +% 1;
                    break :blk next_pc;
                },
                Instruction.CALL => |jt| {
                    const jump_condition = jmpBlk: {
                        switch (jt) {
                            JumpTest.NotZero => {
                                std.debug.print("CALL NZ\n", .{});
                                break :jmpBlk !self.registers.F.zero;
                            },
                            JumpTest.NotCarry => {
                                std.debug.print("CALL NC\n", .{});
                                break :jmpBlk !self.registers.F.carry;
                            },
                            JumpTest.Zero => {
                                std.debug.print("CALL Z\n", .{});
                                break :jmpBlk self.registers.F.zero;
                            },
                            JumpTest.Carry => {
                                std.debug.print("CALL C\n", .{});
                                break :jmpBlk self.registers.F.carry;
                            },
                            JumpTest.Always => {
                                std.debug.print("CALL\n", .{});
                                break :jmpBlk true;
                            },
                        }
                    };
                    const next_pc = self.call(jump_condition);
                    break :blk next_pc;
                },
                Instruction.RET => |jt| {
                    const jump_condition = jmpBlk: {
                        switch (jt) {
                            JumpTest.NotZero => {
                                std.debug.print("RET NZ\n", .{});
                                break :jmpBlk !self.registers.F.zero;
                            },
                            JumpTest.NotCarry => {
                                std.debug.print("RET NC\n", .{});
                                break :jmpBlk !self.registers.F.carry;
                            },
                            JumpTest.Zero => {
                                std.debug.print("RET Z\n", .{});
                                break :jmpBlk self.registers.F.zero;
                            },
                            JumpTest.Carry => {
                                std.debug.print("RET C\n", .{});
                                break :jmpBlk self.registers.F.carry;
                            },
                            JumpTest.Always => {
                                std.debug.print("RET\n", .{});
                                break :jmpBlk true;
                            },
                        }
                    };
                    const next_pc = self.ret(jump_condition);
                    break :blk next_pc;
                },
                Instruction.POP => |target| {
                    const result = self.pop();
                    switch (target) {
                        StackTarget.BC => {
                            std.debug.print("POP BC\n", .{});
                            self.registers.set_BC(result);
                        },
                        else => {
                            std.debug.print("Unknown POP target\n", .{});
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
                            else => {
                                std.debug.print("Unknown POP target\n", .{});
                                break :pushBlk 0xFFFF;
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
                                        const next_byte = self.read_next_byte();
                                        break :sourceBlk next_byte;
                                    },
                                    LoadByteSource.HLI => {
                                        std.debug.print("LD HLI\n", .{});
                                        const hl_byte = self.bus.read_byte(self.registers.get_HL());
                                        break :sourceBlk hl_byte;
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
                                    else => {
                                        break :pcBlk self.pc +% 1;
                                    },
                                }
                            };
                            break :blk next_pc;
                        },
                        LoadType.Word => |word| {
                            std.debug.print("LD Word {} source \n", .{word});
                            const source_value = self.read_next_word();
                            switch (word) {
                                LoadWordTarget.BC => {
                                    std.debug.print("LD BC\n", .{});
                                    self.registers.set_BC(source_value);
                                },
                                LoadWordTarget.DE => {
                                    std.debug.print("LD DE\n", .{});
                                    self.registers.set_DE(source_value);
                                },
                                LoadWordTarget.HL => {
                                    std.debug.print("LD HL\n", .{});
                                    self.registers.set_HL(source_value);
                                },
                                LoadWordTarget.SP => {
                                    std.debug.print("LD SP\n", .{});
                                    self.sp = source_value;
                                },
                            }
                            const next_pc = self.pc +% 3;
                            break :blk next_pc;
                        },
                        LoadType.AFromIndirect => |indirect| {
                            const value = sourceBlk: {
                                switch (indirect) {
                                    Indirect.BCIndirect => {
                                        std.debug.print("LD A (BC)\n", .{});
                                        break :sourceBlk self.bus.read_byte(self.registers.get_BC());
                                    },
                                    Indirect.DEIndirect => {
                                        std.debug.print("LD A (DE)\n", .{});
                                        break :sourceBlk self.bus.read_byte(self.registers.get_DE());
                                    },
                                    Indirect.HLIndirectPlus => {
                                        std.debug.print("LD A (HL+)\n", .{});
                                        const hl = self.registers.get_HL();
                                        const value = self.bus.read_byte(hl);
                                        self.registers.set_HL(hl +% 1);
                                        break :sourceBlk value;
                                    },
                                    Indirect.HLIndirectMinus => {
                                        std.debug.print("LD A (HL-)\n", .{});
                                        const hl = self.registers.get_HL();
                                        const value = self.bus.read_byte(hl);
                                        self.registers.set_HL(hl -% 1);
                                        break :sourceBlk value;
                                    },
                                    Indirect.WordIndirect => {
                                        std.debug.print("LD A (nn)\n", .{});
                                        const address = self.read_next_word();
                                        break :sourceBlk self.bus.read_byte(address);
                                    },
                                    Indirect.LastByteIndirect => {
                                        std.debug.print("LD A (FF00 + C)\n", .{});
                                        const address = 0xFF00 +% @as(u16, self.registers.C);
                                        break :sourceBlk self.bus.read_byte(address);
                                    },
                                }
                            };
                            self.registers.A = value;
                            switch (indirect) {
                                Indirect.WordIndirect => {
                                    const next_pc = self.pc +% 3;
                                    break :blk next_pc;
                                },
                                else => {
                                    const next_pc = self.pc +% 1;
                                    break :blk next_pc;
                                },
                            }
                        },
                        LoadType.IndirectFromA => |indirect| {
                            const value = self.registers.A;
                            switch (indirect) {
                                Indirect.BCIndirect => {
                                    std.debug.print("LD (BC) A\n", .{});
                                    self.bus.write_byte(self.registers.get_BC(), value);
                                },
                                Indirect.DEIndirect => {
                                    std.debug.print("LD (DE) A\n", .{});
                                    self.bus.write_byte(self.registers.get_DE(), value);
                                },
                                Indirect.HLIndirectPlus => {
                                    std.debug.print("LD (HL+) A\n", .{});
                                    const hl = self.registers.get_HL();
                                    self.bus.write_byte(hl, value);
                                    self.registers.set_HL(hl +% 1);
                                },
                                Indirect.HLIndirectMinus => {
                                    std.debug.print("LD (HL-) A\n", .{});
                                    const hl = self.registers.get_HL();
                                    self.bus.write_byte(hl, value);
                                    self.registers.set_HL(hl -% 1);
                                },
                                Indirect.WordIndirect => {
                                    std.debug.print("LD (nn) A\n", .{});
                                    const address = self.read_next_word();
                                    self.bus.write_byte(address, value);
                                },
                                Indirect.LastByteIndirect => {
                                    std.debug.print("LD (FF00 + C) A\n", .{});
                                    const address = 0xFF00 +% @as(u16, self.registers.C);
                                    self.bus.write_byte(address, value);
                                },
                            }
                            switch (indirect) {
                                Indirect.WordIndirect => {
                                    const next_pc = self.pc +% 3;
                                    break :blk next_pc;
                                },
                                else => {
                                    const next_pc = self.pc +% 1;
                                    break :blk next_pc;
                                },
                            }
                        },
                        LoadType.AFromByteAddress => {
                            const offset = @as(u16, self.read_next_byte());
                            self.registers.A = self.bus.read_byte(0xFF00 +% offset);
                            const next_pc = self.pc +% 2;
                            break :blk next_pc;
                        },
                        LoadType.ByteAddressFromA => {
                            const offset = @as(u16, self.read_next_byte());
                            self.bus.write_byte(0xFF00 + offset, self.registers.A);
                            const next_pc = self.pc +% 2;
                            break :blk next_pc;
                        },
                        LoadType.SPFromHL => {
                            self.sp = self.registers.get_HL();
                            const next_pc = self.pc +% 1;
                            break :blk next_pc;
                        },
                        LoadType.HLFromSPN => {
                            const n = self.read_next_byte();
                            const signed: i8 = @bitCast(n);
                            const extended: u16 = @intCast(signed);
                            self.registers.set_HL(extended);
                            self.registers.F.zero = false;
                            self.registers.F.subtract = false;
                            self.registers.F.half_carry = (self.sp & 0xF) + (extended & 0xF) > 0xF;
                            self.registers.F.carry = (self.sp & 0xFF) + (extended & 0xFF) > 0xFF;
                            const next_pc = self.pc +% 2;
                            break :blk next_pc;
                        },
                        LoadType.IndirectFromSP => {
                            const address = self.read_next_word();
                            self.bus.write_word(address, self.sp);
                            const next_pc = self.pc +% 3;
                            break :blk next_pc;
                        },
                    }
                },
                Instruction.JP => |jt| {
                    const jump_condition = jpblk: {
                        switch (jt) {
                            JumpTest.NotZero => {
                                std.debug.print("JP NZ\n", .{});
                                break :jpblk !self.registers.F.zero;
                            },
                            JumpTest.NotCarry => {
                                std.debug.print("JP NC\n", .{});
                                break :jpblk !self.registers.F.carry;
                            },
                            JumpTest.Zero => {
                                std.debug.print("JP Z\n", .{});
                                break :jpblk self.registers.F.zero;
                            },
                            JumpTest.Carry => {
                                std.debug.print("JP C\n", .{});
                                break :jpblk self.registers.F.carry;
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
                    const value = addBlk: {
                        switch (target) {
                            ArithmeticTarget.A => {
                                std.debug.print("ADD A\n", .{});
                                const value = self.registers.A;
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.B => {
                                std.debug.print("ADD B\n", .{});
                                const value = self.registers.B;
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.C => {
                                std.debug.print("ADD C\n", .{});
                                const value = self.registers.C;
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.D => {
                                std.debug.print("ADD D\n", .{});
                                const value = self.registers.D;
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.E => {
                                std.debug.print("ADD E\n", .{});
                                const value = self.registers.E;
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.H => {
                                std.debug.print("ADD H\n", .{});
                                const value = self.registers.H;
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.L => {
                                std.debug.print("ADD L\n", .{});
                                const value = self.registers.L;
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.HL => {
                                std.debug.print("ADD HL\n", .{});
                                const value = self.bus.read_byte(self.registers.get_HL());
                                const new_value = self.add(value);
                                break :addBlk new_value;
                            },
                            ArithmeticTarget.D8 => {
                                std.debug.print("ADD D8\n", .{});
                                const value = self.read_next_byte();
                                const new_value = self.add(value);
                                self.pc = self.pc +% 1;
                                break :addBlk new_value;
                            },
                        }
                    };
                    self.registers.A = value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.ADC => |target| {
                    const value = adcBlk: {
                        switch (target) {
                            ArithmeticTarget.A => {
                                std.debug.print("adc A\n", .{});
                                const value = self.registers.A;
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.B => {
                                std.debug.print("adc B\n", .{});
                                const value = self.registers.B;
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.C => {
                                std.debug.print("adc C\n", .{});
                                const value = self.registers.C;
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.D => {
                                std.debug.print("adc D\n", .{});
                                const value = self.registers.D;
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.E => {
                                std.debug.print("adc E\n", .{});
                                const value = self.registers.E;
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.H => {
                                std.debug.print("adc H\n", .{});
                                const value = self.registers.H;
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.L => {
                                std.debug.print("adc L\n", .{});
                                const value = self.registers.L;
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.HL => {
                                std.debug.print("ADC HL\n", .{});
                                const value = self.bus.read_byte(self.registers.get_HL());
                                const new_value = self.adc(value);
                                break :adcBlk new_value;
                            },
                            ArithmeticTarget.D8 => {
                                std.debug.print("ADC D8\n", .{});
                                const value = self.read_next_byte();
                                const new_value = self.adc(value);
                                self.pc = self.pc +% 1;
                                break :adcBlk new_value;
                            },
                        }
                    };
                    self.registers.A = value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.SUB => |target| {
                    const value = subBlk: {
                        switch (target) {
                            ArithmeticTarget.A => {
                                std.debug.print("sub A\n", .{});
                                const value = self.registers.A;
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.B => {
                                std.debug.print("sub B\n", .{});
                                const value = self.registers.B;
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.C => {
                                std.debug.print("sub C\n", .{});
                                const value = self.registers.C;
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.D => {
                                std.debug.print("sub D\n", .{});
                                const value = self.registers.D;
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.E => {
                                std.debug.print("sub E\n", .{});
                                const value = self.registers.E;
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.H => {
                                std.debug.print("sub H\n", .{});
                                const value = self.registers.H;
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.L => {
                                std.debug.print("sub L\n", .{});
                                const value = self.registers.L;
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.HL => {
                                std.debug.print("SUB HL\n", .{});
                                const value = self.bus.read_byte(self.registers.get_HL());
                                const new_value = self.sub(value);
                                break :subBlk new_value;
                            },
                            ArithmeticTarget.D8 => {
                                std.debug.print("SUB D8\n", .{});
                                const value = self.read_next_byte();
                                const new_value = self.sub(value);
                                self.pc = self.pc +% 1;
                                break :subBlk new_value;
                            },
                        }
                    };
                    self.registers.A = value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.SBC => |target| {
                    const value = sbcBlk: {
                        switch (target) {
                            ArithmeticTarget.A => {
                                std.debug.print("sbc A\n", .{});
                                const value = self.registers.A;
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.B => {
                                std.debug.print("sbc B\n", .{});
                                const value = self.registers.B;
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.C => {
                                std.debug.print("sbc C\n", .{});
                                const value = self.registers.C;
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.D => {
                                std.debug.print("sbc D\n", .{});
                                const value = self.registers.D;
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.E => {
                                std.debug.print("sbc E\n", .{});
                                const value = self.registers.E;
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.H => {
                                std.debug.print("sbc H\n", .{});
                                const value = self.registers.H;
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.L => {
                                std.debug.print("sbc L\n", .{});
                                const value = self.registers.L;
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.HL => {
                                std.debug.print("sbc HL\n", .{});
                                const value = self.bus.read_byte(self.registers.get_HL());
                                const new_value = self.sbc(value);
                                break :sbcBlk new_value;
                            },
                            ArithmeticTarget.D8 => {
                                std.debug.print("sbc D8\n", .{});
                                const value = self.read_next_byte();
                                const new_value = self.sbc(value);
                                self.pc = self.pc +% 1;
                                break :sbcBlk new_value;
                            },
                        }
                    };
                    self.registers.A = value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.AND => |target| {
                    const value = andBlk: {
                        switch (target) {
                            ArithmeticTarget.A => {
                                std.debug.print("and A\n", .{});
                                const value = self.registers.A;
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.B => {
                                std.debug.print("and B\n", .{});
                                const value = self.registers.B;
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.C => {
                                std.debug.print("and C\n", .{});
                                const value = self.registers.C;
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.D => {
                                std.debug.print("and D\n", .{});
                                const value = self.registers.D;
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.E => {
                                std.debug.print("and E\n", .{});
                                const value = self.registers.E;
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.H => {
                                std.debug.print("and H\n", .{});
                                const value = self.registers.H;
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.L => {
                                std.debug.print("and L\n", .{});
                                const value = self.registers.L;
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.HL => {
                                std.debug.print("and HL\n", .{});
                                const value = self.bus.read_byte(self.registers.get_HL());
                                const new_value = self.and_(value);
                                break :andBlk new_value;
                            },
                            ArithmeticTarget.D8 => {
                                std.debug.print("and D8\n", .{});
                                const value = self.read_next_byte();
                                const new_value = self.and_(value);
                                self.pc = self.pc +% 1;
                                break :andBlk new_value;
                            },
                        }
                    };
                    self.registers.A = value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.XOR => |target| {
                    const value = xorBlk: {
                        switch (target) {
                            ArithmeticTarget.A => {
                                std.debug.print("xor A\n", .{});
                                const value = self.registers.A;
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.B => {
                                std.debug.print("xor B\n", .{});
                                const value = self.registers.B;
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.C => {
                                std.debug.print("xor C\n", .{});
                                const value = self.registers.C;
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.D => {
                                std.debug.print("xor D\n", .{});
                                const value = self.registers.D;
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.E => {
                                std.debug.print("xor E\n", .{});
                                const value = self.registers.E;
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.H => {
                                std.debug.print("xor H\n", .{});
                                const value = self.registers.H;
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.L => {
                                std.debug.print("xor L\n", .{});
                                const value = self.registers.L;
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.HL => {
                                std.debug.print("xor HL\n", .{});
                                const value = self.bus.read_byte(self.registers.get_HL());
                                const new_value = self.xor(value);
                                break :xorBlk new_value;
                            },
                            ArithmeticTarget.D8 => {
                                std.debug.print("xor D8\n", .{});
                                const value = self.read_next_byte();
                                const new_value = self.xor(value);
                                self.pc = self.pc +% 1;
                                break :xorBlk new_value;
                            },
                        }
                    };
                    self.registers.A = value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.OR => |target| {
                    const value = orBlk: {
                        switch (target) {
                            ArithmeticTarget.A => {
                                std.debug.print("or A\n", .{});
                                const value = self.registers.A;
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.B => {
                                std.debug.print("or B\n", .{});
                                const value = self.registers.B;
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.C => {
                                std.debug.print("or C\n", .{});
                                const value = self.registers.C;
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.D => {
                                std.debug.print("or D\n", .{});
                                const value = self.registers.D;
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.E => {
                                std.debug.print("or E\n", .{});
                                const value = self.registers.E;
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.H => {
                                std.debug.print("or H\n", .{});
                                const value = self.registers.H;
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.L => {
                                std.debug.print("or L\n", .{});
                                const value = self.registers.L;
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.HL => {
                                std.debug.print("or HL\n", .{});
                                const value = self.bus.read_byte(self.registers.get_HL());
                                const new_value = self.or_(value);
                                break :orBlk new_value;
                            },
                            ArithmeticTarget.D8 => {
                                std.debug.print("or D8\n", .{});
                                const value = self.read_next_byte();
                                const new_value = self.or_(value);
                                self.pc = self.pc +% 1;
                                break :orBlk new_value;
                            },
                        }
                    };
                    self.registers.A = value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.CP => |target| {
                    switch (target) {
                        ArithmeticTarget.A => {
                            std.debug.print("cp A\n", .{});
                            const value = self.registers.A;
                            self.cp(value);
                        },
                        ArithmeticTarget.B => {
                            std.debug.print("cp B\n", .{});
                            const value = self.registers.B;
                            self.cp(value);
                        },
                        ArithmeticTarget.C => {
                            std.debug.print("cp C\n", .{});
                            const value = self.registers.C;
                            self.cp(value);
                        },
                        ArithmeticTarget.D => {
                            std.debug.print("cp D\n", .{});
                            const value = self.registers.D;
                            self.cp(value);
                        },
                        ArithmeticTarget.E => {
                            std.debug.print("cp E\n", .{});
                            const value = self.registers.E;
                            self.cp(value);
                        },
                        ArithmeticTarget.H => {
                            std.debug.print("cp H\n", .{});
                            const value = self.registers.H;
                            self.cp(value);
                        },
                        ArithmeticTarget.L => {
                            std.debug.print("cp L\n", .{});
                            const value = self.registers.L;
                            self.cp(value);
                        },
                        ArithmeticTarget.HL => {
                            std.debug.print("cp HL\n", .{});
                            const value = self.bus.read_byte(self.registers.get_HL());
                            self.cp(value);
                        },
                        ArithmeticTarget.D8 => {
                            std.debug.print("cp D8\n", .{});
                            const value = self.read_next_byte();
                            self.pc = self.pc +% 1;
                            self.cp(value);
                        },
                    }
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.INC => |target| {
                    switch (target) {
                        ArithmeticTarget.A => {
                            std.debug.print("inc A\n", .{});
                            const value = self.registers.A;
                            _ = self.inc(value);
                            self.registers.A = value;
                        },
                        ArithmeticTarget.B => {
                            std.debug.print("inc B\n", .{});
                            const value = self.registers.B;
                            _ = self.inc(value);
                            self.registers.B = value;
                        },
                        ArithmeticTarget.C => {
                            std.debug.print("inc C\n", .{});
                            const value = self.registers.C;
                            _ = self.inc(value);
                            self.registers.C = value;
                        },
                        ArithmeticTarget.D => {
                            std.debug.print("inc D\n", .{});
                            const value = self.registers.D;
                            _ = self.inc(value);
                            self.registers.D = value;
                        },
                        ArithmeticTarget.E => {
                            std.debug.print("inc E\n", .{});
                            const value = self.registers.E;
                            _ = self.inc(value);
                            self.registers.E = value;
                        },
                        ArithmeticTarget.H => {
                            std.debug.print("inc H\n", .{});
                            const value = self.registers.H;
                            _ = self.inc(value);
                            self.registers.H = value;
                        },
                        ArithmeticTarget.L => {
                            std.debug.print("inc L\n", .{});
                            const value = self.registers.L;
                            _ = self.inc(value);
                            self.registers.L = value;
                        },
                        ArithmeticTarget.HL => {
                            std.debug.print("inc HL\n", .{});
                            const HL = self.registers.get_HL();
                            const value = self.bus.read_byte(HL);
                            _ = self.inc(value);
                            self.bus.write_byte(HL, value);
                        },
                        else => {
                            std.debug.print("Unknown INC target\n", .{});
                        },
                    }
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.DEC => |target| {
                    switch (target) {
                        ArithmeticTarget.A => {
                            std.debug.print("dec A\n", .{});
                            const value = self.registers.A;
                            _ = self.dec(value);
                            self.registers.A = value;
                        },
                        ArithmeticTarget.B => {
                            std.debug.print("dec B\n", .{});
                            const value = self.registers.B;
                            _ = self.dec(value);
                            self.registers.B = value;
                        },
                        ArithmeticTarget.C => {
                            std.debug.print("dec C\n", .{});
                            const value = self.registers.C;
                            _ = self.dec(value);
                            self.registers.C = value;
                        },
                        ArithmeticTarget.D => {
                            std.debug.print("dec D\n", .{});
                            const value = self.registers.D;
                            _ = self.dec(value);
                            self.registers.D = value;
                        },
                        ArithmeticTarget.E => {
                            std.debug.print("dec E\n", .{});
                            const value = self.registers.E;
                            _ = self.dec(value);
                            self.registers.E = value;
                        },
                        ArithmeticTarget.H => {
                            std.debug.print("dec H\n", .{});
                            const value = self.registers.H;
                            _ = self.dec(value);
                            self.registers.H = value;
                        },
                        ArithmeticTarget.L => {
                            std.debug.print("dec L\n", .{});
                            const value = self.registers.L;
                            _ = self.dec(value);
                            self.registers.L = value;
                        },
                        ArithmeticTarget.HL => {
                            std.debug.print("dec HL\n", .{});
                            const HL = self.registers.get_HL();
                            const value = self.bus.read_byte(HL);
                            _ = self.dec(value);
                            self.bus.write_byte(HL, value);
                        },
                        else => {
                            std.debug.print("Unknown DEC target\n", .{});
                        },
                    }
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.WADD => |target| {
                    const value = waddBlk: {
                        switch (target) {
                            WideArithmeticTarget.HL => {
                                std.debug.print("wadd HL\n", .{});
                                const value = self.registers.get_HL();
                                const new_value = self.wadd(value);
                                break :waddBlk new_value;
                            },
                            WideArithmeticTarget.BC => {
                                std.debug.print("wadd BC\n", .{});
                                const value = self.registers.get_BC();
                                const new_value = self.wadd(value);
                                break :waddBlk new_value;
                            },
                            WideArithmeticTarget.DE => {
                                std.debug.print("wadd DE\n", .{});
                                const value = self.registers.get_DE();
                                const new_value = self.wadd(value);
                                break :waddBlk new_value;
                            },
                            WideArithmeticTarget.SP => {
                                std.debug.print("wadd SP\n", .{});
                                const value = self.sp;
                                const new_value = self.wadd(value);
                                break :waddBlk new_value;
                            },
                        }
                    };
                    self.registers.set_HL(value);
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.WINC => |target| {
                    switch (target) {
                        WideArithmeticTarget.HL => {
                            std.debug.print("winc HL\n", .{});
                            const value = self.registers.get_HL();
                            const new_value = self.winc(value);
                            self.registers.set_HL(new_value);
                        },
                        WideArithmeticTarget.BC => {
                            std.debug.print("winc BC\n", .{});
                            const value = self.registers.get_BC();
                            const new_value = self.winc(value);
                            self.registers.set_BC(new_value);
                        },
                        WideArithmeticTarget.DE => {
                            std.debug.print("winc DE\n", .{});
                            const value = self.registers.get_DE();
                            const new_value = self.winc(value);
                            self.registers.set_DE(new_value);
                        },
                        WideArithmeticTarget.SP => {
                            std.debug.print("winc SP\n", .{});
                            const value = self.sp;
                            const new_value = self.winc(value);
                            self.sp = new_value;
                        },
                    }
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.WDEC => |target| {
                    switch (target) {
                        WideArithmeticTarget.HL => {
                            std.debug.print("wdec HL\n", .{});
                            const value = self.registers.get_HL();
                            const new_value = self.wdec(value);
                            self.registers.set_HL(new_value);
                        },
                        WideArithmeticTarget.BC => {
                            std.debug.print("wdec BC\n", .{});
                            const value = self.registers.get_BC();
                            const new_value = self.wdec(value);
                            self.registers.set_BC(new_value);
                        },
                        WideArithmeticTarget.DE => {
                            std.debug.print("wdec DE\n", .{});
                            const value = self.registers.get_DE();
                            const new_value = self.wdec(value);
                            self.registers.set_DE(new_value);
                        },
                        WideArithmeticTarget.SP => {
                            std.debug.print("wdec SP\n", .{});
                            const value = self.sp;
                            const new_value = self.wdec(value);
                            self.sp = new_value;
                        },
                    }
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.SPADD => |_| {
                    const value = self.read_next_byte();
                    const new_value = self.spadd(value);
                    self.sp = new_value;
                    const new_pc: u16 = self.pc +% 2;
                    break :blk new_pc;
                },
                Instruction.DAA => |_| {
                    std.debug.print("DAA\n", .{});
                    const new_value = self.daa(self.registers.A);
                    self.registers.A = new_value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.CPL => |_| {
                    std.debug.print("CPL\n", .{});
                    _ = self.cpl();
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.CCF => |_| {
                    std.debug.print("CCF\n", .{});
                    _ = self.ccf();
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.SCF => |_| {
                    std.debug.print("SCF\n", .{});
                    _ = self.scf();
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.RLA => |_| {
                    std.debug.print("RLA\n", .{});
                    const new_value = self.rotate_left(self.registers.A);
                    self.registers.A = new_value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.RLCA => |_| {
                    std.debug.print("RLCA\n", .{});
                    const new_value = self.rotate_left_use_carry(self.registers.A);
                    self.registers.A = new_value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.RRA => |_| {
                    std.debug.print("RRA\n", .{});
                    const new_value = self.rotate_right(self.registers.A);
                    self.registers.A = new_value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
                Instruction.RRCA => |_| {
                    std.debug.print("RRCA\n", .{});
                    const new_value = self.rotate_right_use_carry(self.registers.A);
                    self.registers.A = new_value;
                    const new_pc: u16 = self.pc +% 1;
                    break :blk new_pc;
                },
            }
        };
        return res;
    }
    fn step(self: *const CPU) void {
        var instruction_byte = self.bus.read_byte(self.pc);
        const prefixed = instruction_byte == 0xCB;
        if (prefixed) {
            instruction_byte = self.bus.read_byte(self.pc +% 1);
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
            const low = self.bus.read_byte(self.pc +% 1);
            const high = self.bus.read_byte(self.pc +% 2);
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

        // zig fmt: off
        self.registers.F = .{
            .zero = sum == 0,
            .subtract = false,
            .carry = carry == 1,
            .half_carry = (((self.registers.A & 0xF) + (value & 0xF)) > 0xF),
        };
        // zig fmt: on
        return sum;
    }

    fn wadd(self: *CPU, value: u16) u16 {
        const result = @addWithOverflow(self.registers.get_HL(), value);
        const sum = result[0];
        const carry = result[1];

        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .carry = carry == 1,
            .half_carry = (((self.registers.get_HL() & 0x7FF) + (value & 0x7FF)) > 0x7FF),
        };
        return sum;
    }

    fn spadd(self: *CPU, value: u8) u16 {
        const signed: i8 = @bitCast(value);
        const extended: u16 = @intCast(signed);
        const sum = self.sp +% extended;
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .carry = (((self.sp & 0xFF) + (extended & 0xFF)) > 0xFF),
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
            .half_carry = (((self.registers.A & 0xF) + (value & 0xF) + overflow) > 0xF),
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
            .half_carry = (((@as(i16, self.registers.A) & 0xF) - (@as(i16, value) & 0xF) - overflow) < 0),
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
        self.registers.F = .{
            .zero = result == 0,
            .subtract = false,
            .half_carry = (value & 0xF) == 0xF,
            .carry = false,
        };
        return result;
    }

    fn winc(_: *CPU, value: u16) u16 {
        const result = value +% 1;
        return result;
    }

    fn dec(self: *CPU, value: u8) u8 {
        const result = value -% 1;
        self.registers.F = .{
            .zero = result == 0,
            .subtract = true,
            .half_carry = (value & 0xF) == 0,
            .carry = false,
        };
        return result;
    }

    fn wdec(_: *CPU, value: u16) u16 {
        const result = value -% 1;
        return result;
    }

    fn daa(self: *CPU, value: u8) u8 {
        var carry = false;

        const result = blk: {
            if (!self.registers.F.subtract) {
                var result = value;
                if (self.registers.F.carry or value > 0x99) {
                    result = result +% 0x60;
                    carry = true;
                } else if (self.registers.F.half_carry or (value & 0xF) > 0x9) {
                    result = result +% 0x06;
                }
                break :blk result;
            } else if (self.registers.F.carry) {
                carry = true;
                var result = value;
                if (self.registers.F.half_carry) {
                    result = result -% 0x66;
                } else {
                    result = result -% 0x60;
                }
                break :blk result;
            } else if (self.registers.F.half_carry) {
                const result = value -% 0x06;
                break :blk result;
            } else {
                break :blk value;
            }
        };

        self.registers.F.zero = result == 0;
        self.registers.F.carry = carry;
        self.registers.F.half_carry = false;

        return result;
    }

    fn cpl(self: *CPU) void {
        self.registers.A = self.registers.A ^ 0xFF;
        self.registers.F = .{
            .zero = false,
            .subtract = true,
            .half_carry = true,
            .carry = self.registers.F.carry,
        };
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

    fn rotate_left(self: *CPU, value: u8) u8 {
        const carry = value >> 7;
        const new_value = (value << 1) | carry;
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = carry == 1,
        };

        return new_value;
    }

    fn rotate_left_use_carry(self: *CPU, value: u8) u8 {
        const new_value = (value << 1) | @intFromBool(self.registers.F.carry);
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = value >> 7 == 1,
        };
        return new_value;
    }

    fn rotate_right(self: *CPU, value: u8) u8 {
        const carry = value & 1;
        const new_value = (value >> 1) | (carry << 7);
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = carry == 1,
        };
        return new_value;
    }

    fn rotate_right_use_carry(self: *CPU, value: u8) u8 {
        const new_value = (value >> 1) | (@as(u8, @intFromBool(self.registers.F.carry)) << @intCast(7));
        self.registers.F = .{
            .zero = false,
            .subtract = false,
            .half_carry = false,
            .carry = value & 1 == 1,
        };
        return new_value;
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

    fn call(self: *CPU, should_call: bool) u16 {
        const next_pc = self.pc +% 3;
        if (should_call) {
            self.push(next_pc);
            const address = self.read_next_word();
            return address;
        } else {
            return next_pc;
        }
    }

    fn ret(self: *CPU, should_return: bool) u16 {
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
                .A = 0x00,
                .B = 0x00,
                .C = 0x00,
                .D = 0x00,
                .E = 0x00,
                .F = .{
                    .zero = false,
                    .subtract = false,
                    .half_carry = false,
                    .carry = false,
                },
                .H = 0x00,
                .L = 0x00,
            },
            .pc = 0x00,
            .sp = 0x00,
            .bus = MemoryBus.new(),
            .is_halted = false,
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

const MemoryBus = struct {
    memory: [0x10000]u8,
    gpu: GPU,
    pub fn new() MemoryBus {
        return MemoryBus{
            .memory = [_]u8{0} ** 0x10000,
            .gpu = GPU.new(),
        };
    }
    fn read_byte(self: *const MemoryBus, address: u16) u8 {
        const addr = @as(usize, address);
        switch (addr) {
            VRAM_BEGIN...VRAM_END => {
                std.debug.print("Vram byte read\n", .{});
                return self.gpu.read_vram(addr - VRAM_BEGIN);
            },
            else => {
                std.debug.print("Non Vram byte read\n", .{});
            },
        }
        return self.memory[address];
    }
    fn write_byte(self: *MemoryBus, address: u16, byte: u8) void {
        const addr = @as(usize, address);
        switch (addr) {
            VRAM_BEGIN...VRAM_END => {
                self.gpu.write_vram(addr - VRAM_BEGIN, byte);
                return;
            },
            else => {
                std.debug.print("Implement other writes\n", .{});
            },
        }
        self.memory[addr] = byte;
    }

    fn read_word(self: *MemoryBus, address: u16) u16 {
        const low = self.read_byte(address);
        const high = self.read_byte(address +% 1);
        return @as(u16, high) << 8 | @as(u16, low);
    }

    fn write_word(self: *MemoryBus, address: u16, word: u16) void {
        const low: u8 = @truncate(word);
        const high: u8 = @truncate(word >> 8);
        self.write_byte(address, low);
        self.write_byte(address +% 1, high);
    }
};

const VRAM_BEGIN: usize = 0x8000;
const VRAM_END: usize = 0x9FFF;
const VRAM_SIZE: usize = VRAM_END - VRAM_BEGIN + 1;

const TilePixelValue = enum {
    Zero,
    One,
    Two,
    Three,
};

const Tile = [8][8]TilePixelValue;

fn empty_tile() Tile {
    return .{.{.Zero} ** 8} ** 8;
}

const GPU = struct {
    vram: [VRAM_SIZE]u8,
    tile_set: [384]Tile,

    pub fn new() GPU {
        return GPU{
            .vram = [_]u8{0} ** VRAM_SIZE,
            .tile_set = .{empty_tile()} ** 384,
        };
    }

    fn read_vram(self: *const GPU, address: usize) u8 {
        return self.vram[address];
    }

    fn write_vram(self: *GPU, index: usize, byte: u8) void {
        self.vram[index] = byte;

        if (index >= 0x1800) {
            return;
        }
        const normalized_index = index & 0xFFFE;
        const byte1 = self.vram[normalized_index];
        const byte2 = self.vram[normalized_index + 1];

        const tile_index = index / 16;
        const row_index = (index % 16) / 2;

        for (0..8) |pixel_index| {
            const mask = @as(u8, 1) << @intCast(7 - pixel_index);
            const low = @intFromBool((byte1 & mask) > 0);
            const high = @intFromBool((byte2 & mask) > 0);
            const pixel_value = @as(u2, low) | (@as(u2, high) << 1);

            // const value = blk: {
            //     switch (v) {
            //         0b11 => break :blk TilePixelValue.Three,
            //         0b10 => break :blk TilePixelValue.Two,
            //         0b01 => break :blk TilePixelValue.One,
            //         0b00 => break :blk TilePixelValue.Zero,
            //     }
            // };

            self.tile_set[tile_index][row_index][pixel_index] = @enumFromInt(pixel_value);
        }
    }
};

pub fn main() !void {}

test "Add A + C" {
    std.debug.print("Add A + C\n", .{});
    const instc = Instruction{ .ADD = ArithmeticTarget.C };
    var cpu = CPU.new();
    cpu.registers.A = 0xFF;
    cpu.registers.C = 0x02;
    std.debug.print("A: {x}, C: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.C, @as(u8, @bitCast(cpu.registers.F)) });

    _ = cpu.execute(instc);
    std.debug.print("A: {x}, C: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.C, @as(u8, @bitCast(cpu.registers.F)) });
}

test "Adc A + E" {
    std.debug.print("Adc A + E\n", .{});
    const inste = Instruction{ .ADC = ArithmeticTarget.E };
    var cpu = CPU.new();
    cpu.registers.F = .{
        .zero = true,
        .subtract = false,
        .carry = true,
        .half_carry = false,
    };

    cpu.registers.A = 0xFE;
    cpu.registers.E = 0x01;
    std.debug.print("A: {x}, E: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.E, @as(u8, @bitCast(cpu.registers.F)) });

    _ = cpu.execute(inste);
    std.debug.print("A: {x}, E: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.E, @as(u8, @bitCast(cpu.registers.F)) });
}

test "Sub A + D" {
    std.debug.print("Sub A + D\n", .{});
    const instd = Instruction{ .SUB = ArithmeticTarget.D };
    var cpu = CPU.new();
    cpu.registers.A = 0x01;
    cpu.registers.D = 0x01;
    std.debug.print("A: {x}, D: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.D, @as(u8, @bitCast(cpu.registers.F)) });

    _ = cpu.execute(instd);
    std.debug.print("A: {x}, D: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.D, @as(u8, @bitCast(cpu.registers.F)) });
}

test "Sbc A + B" {
    std.debug.print("Sbc A + D\n", .{});
    const instb = Instruction{ .SBC = ArithmeticTarget.B };
    var cpu = CPU.new();
    cpu.registers.F = .{
        .zero = true,
        .subtract = false,
        .carry = true,
        .half_carry = false,
    };
    cpu.registers.A = 0x01;
    cpu.registers.B = 0x01;
    std.debug.print("A: {x}, B: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.B, @as(u8, @bitCast(cpu.registers.F)) });

    _ = cpu.execute(instb);
    std.debug.print("A: {x}, B: {x}, FLAGS: {b:0>8} \n", .{ cpu.registers.A, cpu.registers.B, @as(u8, @bitCast(cpu.registers.F)) });
}

test "sp add" {
    std.debug.print("SP ADD\n", .{});
    const inst = Instruction{ .SPADD = {} };
    var cpu = CPU.new();
    cpu.sp = 0xFFFF;
    cpu.bus.memory[0x0001] = 0x05;
    std.debug.print("SP: {x} FLAGS: {b:0>8}\n", .{ cpu.sp, @as(u8, @bitCast(cpu.registers.F)) });
    _ = cpu.execute(inst);
    std.debug.print("SP: {x} FLAGS: {b:0>8}\n", .{ cpu.sp, @as(u8, @bitCast(cpu.registers.F)) });
}

test "Jump" {
    std.debug.print("Jump\n", .{});
    const jp_inst = Instruction{ .JP = JumpTest.Always };
    var cpu = CPU.new();
    const old_pos = 0x0000;
    const new_pos = 0x1234;
    cpu.bus.memory[old_pos + 1] = 0x34;
    cpu.bus.memory[old_pos + 2] = 0x12;
    cpu.pc = old_pos;
    std.debug.print("PC: {x}\n", .{cpu.pc});

    const jp_result = cpu.execute(jp_inst);
    std.debug.assert(jp_result == new_pos);
}

test "overflow" {
    std.debug.print("overflow test\n", .{});
    const comp_a: u8 = 0xFF;
    const comp_b: u8 = @bitCast(@as(i8, -0x01));
    const res = @addWithOverflow(comp_a, comp_b);
    std.debug.print("0xFF + -1 = {d} {d}\n", .{ res[0], res[1] });
}
