const std = @import("std");

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
};

pub const Timer = struct {
    /// FF07
    /// 00: 4096Hz
    /// 01: 262144Hz
    /// 10: 65536Hz
    /// 11: 16384Hz
    /// 0b0000_0100 -> enabled
    tac: packed struct {
        frequency: u2,
        enabled: bool,
        _padding: u5 = 0,
    },
    /// FF04
    /// 16384Hz increment. writing to it sets to 0. continuing from stop resets to 0
    div: u8,
    /// FF05
    /// increases at rate of TAC frequency
    /// when overflows, resets to TMA + interrupt is called
    tima: u8,
    /// FF06
    /// Timer Modulo. tima is set to this value when tima overflows
    tma: u8,
    total_cycles: usize,

    pub fn new() Timer {
        return Timer{
            .tac = @bitCast(@as(u8, 0)),
            .div = 0,
            .tima = 0,
            .tma = 0,
            .total_cycles = 0,
        };
    }
    pub fn step(self: *Timer, cycles: u64, div: u8) bool {
        self.div = div;
        self.total_cycles += cycles;
        if (!self.tac.enabled) {
            return false;
        }

        const freq: Frequency = @enumFromInt(self.tac.frequency);
        const cycles_per_tick = freq.cycles_per_tick();
        // std.debug.print("tc {}, cpt {}, tima {}\n", .{
        //     self.total_cycles,
        //     cycles_per_tick,
        //     self.tima,
        // });
        const tac_overflow = blk: {
            if (self.total_cycles >= cycles_per_tick) {
                self.total_cycles = self.total_cycles % cycles_per_tick;

                const res: u8, const overflow: u1 = @addWithOverflow(self.tima, 1);
                self.tima = res;
                break :blk overflow == 1;
            } else {
                break :blk false;
            }
        };
        if (tac_overflow) {
            self.tima = self.tma;
        }
        return tac_overflow;
    }
};
