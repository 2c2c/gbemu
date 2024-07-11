const std = @import("std");
const CPU = @import("cpu.zig").CPU;
/// FF00 - P1/JOYP - Joypad (R/W)
const Joyp = packed struct {
    unpressed: u4 = 0x0,
    select: enum(u2) {
        Both = 0b00,
        Action = 0b01,
        Direction = 0b10,
        None = 0b11,
    },
    _padding: u2 = 0x0,
};

pub const Joypad = struct {
    joyp: packed struct {
        unpressed: u4 = 0xF,
        select: enum(u2) {
            Both = 0b00,
            Action = 0b01,
            Direction = 0b10,
            None = 0b11,
        },
        _padding: u2 = 0x0,
    },
    button: packed union {
        pressed: packed struct {
            A: bool,
            B: bool,
            SELECT: bool,
            START: bool,
        },
        bits: u4,
    },
    dpad: packed union {
        pressed: packed struct {
            RIGHT: bool,
            LEFT: bool,
            UP: bool,
            DOWN: bool,
        },
        bits: u4,
    },

    pub fn new() Joypad {
        return Joypad{
            .joyp = @bitCast(@as(u8, 0xFF)),
            .button = .{
                .pressed = .{
                    .A = false,
                    .B = false,
                    .SELECT = false,
                    .START = false,
                },
            },
            .dpad = .{
                .pressed = .{
                    .RIGHT = false,
                    .LEFT = false,
                    .UP = false,
                    .DOWN = false,
                },
            },
        };
    }

    pub fn update_joyp_keys(cpu: *CPU) void {
        // std.debug.print("Updating joypad keys\n", .{});
        switch (cpu.bus.joypad.joyp.select) {
            .Both => cpu.bus.joypad.joyp.unpressed = ~(cpu.bus.joypad.button.bits | cpu.bus.joypad.dpad.bits),
            .Action => cpu.bus.joypad.joyp.unpressed = ~cpu.bus.joypad.button.bits,
            .Direction => cpu.bus.joypad.joyp.unpressed = ~cpu.bus.joypad.dpad.bits,
            .None => cpu.bus.joypad.joyp.unpressed = 0xF,
        }
        // std.debug.print("writing joypad keys to joyp: 0b{b:0>8}\n", .{@as(u8, @bitCast(cpu.bus.joypad.joyp))});
    }
    // not sure how id like to store joyp yet
    // pub fn joy_lower_nibble(cpu: *CPU) u4 {
    //     switch (selector) {
    //         .Both => cpu.bus.write_io(0xFF00, ~(cpu.bus.joypad.button.bits | cpu.bus.joypad.dpad.bits)),
    //         .Action => cpu.bus.write_io(0xFF00, ~cpu.bus.joypad.button.bits),
    //         .Direction => cpu.bus.write_io(0xFF00, ~cpu.bus.joypad.dpad.bits),
    //         .None => cpu.bus.write_io(0xFF00, 0xF),
    //     }
    // }
};
