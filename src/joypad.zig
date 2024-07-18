const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const Gameboy = @import("gameboy.zig").Gameboy;

const log = std.log.scoped(.joy);

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

    pub fn update_joyp_keys(gb: *Gameboy) bool {
        // log.debug("Updating joypad keys\n", .{});
        var old_bits: u4 = undefined;
        switch (gb.joypad.joyp.select) {
            .Both => {
                old_bits = gb.joypad.joyp.unpressed;
                gb.joypad.joyp.unpressed = ~(gb.joypad.button.bits | gb.joypad.dpad.bits);
            },
            .Action => {
                old_bits = gb.joypad.joyp.unpressed;
                gb.joypad.joyp.unpressed = ~gb.joypad.button.bits;
            },
            .Direction => {
                old_bits = gb.joypad.joyp.unpressed;
                gb.joypad.joyp.unpressed = ~gb.joypad.dpad.bits;
            },
            .None => {
                old_bits = gb.joypad.joyp.unpressed;
                gb.joypad.joyp.unpressed = 0xF;
            },
        }
        const fire_interrupt = old_bits == 0xF and (gb.joypad.joyp.unpressed != 0xF);
        return fire_interrupt;
    }
};
