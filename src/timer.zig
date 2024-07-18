// passes all of mooneye besides div_write and rapid_toggle. seems like div_write should work, dunno
const std = @import("std");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.timer);

pub const Frequency = enum(u2) {
    Hz4096 = 0b00,
    Hz262144 = 0b01,
    Hz65536 = 0b10,
    Hz16384 = 0b11,
    /// effective number of tcycles for a given clockrate
    fn cycles_per_tick(self: Frequency) usize {
        return switch (self) {
            Frequency.Hz4096 => 1024,
            Frequency.Hz262144 => 16,
            Frequency.Hz65536 => 64,
            Frequency.Hz16384 => 256,
        };
    }

    fn clock_bit_to_check(self: Frequency) u6 {
        return switch (self) {
            Frequency.Hz4096 => 9,
            Frequency.Hz16384 => 7,
            Frequency.Hz65536 => 5,
            Frequency.Hz262144 => 3,
        };
    }
};

pub const Tac = packed struct {
    frequency: Frequency,
    enabled: bool,
    _padding: u5 = 0,
};
pub const Timer = struct {
    /// FF07
    /// 00: 4096Hz
    /// 01: 262144Hz
    /// 10: 65536Hz
    /// 11: 16384Hz
    /// 0b0000_0100 -> enabled
    tac: Tac,

    /// interally div is just the upper 8 bits of a 16bit counter (measured in t-cycles)
    /// most of the docs related to this will be in terms of m-cycles, and talk about 14bits
    /// better accuracy to track this and handle the actual bit logic used by the hardware
    ///
    /// FF04
    /// 16384Hz increment. writing to it sets to 0. continuing from stop resets to 0
    /// internal_clock.bits.div
    internal_clock: cpu.Clock,

    /// FF05
    /// increases at rate of TAC frequency
    /// when overflows, resets to TMA + interrupt is called
    tima: u8,
    tima_reload_cycle: bool,
    tima_cycles_till_interrupt: u8,
    /// FF06
    /// Timer Modulo. tima is set to this value when tima overflows
    tma: u8,
    tma_reload_cycle: bool,
    total_cycles: usize,

    prev_bit: u1 = 0,

    pub fn new() Timer {
        return Timer{
            .tac = @bitCast(@as(u8, 0)),
            .tima = 0,
            .tima_reload_cycle = false,
            .tima_cycles_till_interrupt = 0,
            .tma = 0,
            .tma_reload_cycle = false,
            .total_cycles = 0,
            .internal_clock = @bitCast(@as(u64, 0)),
            .prev_bit = 0,
        };
    }
    pub fn step(self: *Timer) bool {
        self.tima_reload_cycle = false;
        if (self.tima_cycles_till_interrupt > 0) {
            self.tima_cycles_till_interrupt -= 4;
            if (self.tima_cycles_till_interrupt == 0) {
                // interrupt
                self.tima = self.tma;
                self.tima_reload_cycle = true;
            }
        }
        const new_clock = cpu.Clock{ .t_cycles = self.internal_clock.t_cycles + 4 };
        self.clock_update(new_clock);

        // std.debug.print("clock 0b{b>0:16} div {} tima {} tma {} tac {}\n", .{
        //     self.internal_clock.t_cycles,
        //     self.internal_clock.bits.div,
        //     self.tima,
        //     self.tma,
        //     self.tac.frequency,
        // });

        // interrupt fires when true
        return self.tima_reload_cycle;
    }

    /// TIMA updates are determined by specific bit falling from 1 -> 0
    /// The particular bit is determined by TAC. ie 0b01 -> check for 3rd bit falling
    /// this logic is additionally ran through an AND gate with TAC's enabled bit
    /// meaning if previously 3rd bit was 1, and the next cycle it was still 1, but TAC's enable bit is now 0,
    /// you get an early TIMA tick
    pub fn clock_update(self: *Timer, clock: cpu.Clock) void {
        self.internal_clock = clock;

        const check_bit = self.tac.frequency.clock_bit_to_check();
        var new_bit: u1 = @truncate(@as(u64, @bitCast(self.internal_clock)) >> check_bit & 1);
        new_bit = new_bit & @intFromBool(self.tac.enabled);

        self.check_falling_edge(self.prev_bit, new_bit);
        // std.debug.print("clock 0b{b:0>16} check_bit {} prev_bit {} new_bit {} div {} tima {} tma {} tac {} tac_bits 0b{b:0>2}\n", .{
        //     self.internal_clock.t_cycles,
        //     check_bit,
        //     self.prev_bit,
        //     new_bit,
        //     self.internal_clock.bits.div,
        //     self.tima,
        //     self.tma,
        //     self.tac.frequency,
        //     @intFromEnum(self.tac.frequency),
        // });
        self.prev_bit = new_bit;
    }

    pub fn check_falling_edge(self: *Timer, old_bit: u1, new_bit: u1) void {
        if (old_bit == 1 and new_bit == 0) {
            const res: u8, const overflow: u1 = @addWithOverflow(self.tima, 1);
            if (overflow == 1) {
                self.tima_cycles_till_interrupt = 4;
            }
            self.tima = res;
        }
    }
};
