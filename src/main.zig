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
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
