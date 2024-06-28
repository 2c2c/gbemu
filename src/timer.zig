/// FF04
/// 16384Hz increment. writing to it sets to 0. continuing from stop resets to 0
const DIV = 0;

/// FF05
/// increases at rate of TAC frequency
/// when overflows, resets to TMA + interrupt is called
const TIMA: u8 = 0;
/// FF06
/// Timer Modulo
///
const TMA: u8 = 0;
/// FF07
const TAC = packed struct {
    /// 4096, 262144, 65536, 16384
    frequency: u2,
    enabled: bool,
    _padding: u5 = 0,
};

pub const Frequency = enum(u3) {
    Hz4096,
    Hz262144,
    Hz65536,
    Hz16384,
    fn cycles_per_tick(self: Frequency) usize {
        return switch (self) {
            Frequency.Hz4096 => 1024,
            Frequency.Hz262144 => 16,
            Frequency.Hz16384 => 256,
            Frequency.Hz65536 => 64,
        };
    }
};

pub const Timer = struct {
    tac: TAC,
    div: u8,
    tima: u8,
    tma: u8,
    total_cycles: u64,

    // frequency: Frequency,
    // cycles: usize,
    // value: u8,
    // overflow: u8,
    // enabled: bool,
    pub fn new() Timer {
        return Timer{
            .tac = @bitCast(@as(u8, 0)),
            .div = 0,
            .tima = 0,
            .tma = 0,

            // .frequency = Frequency.Hz4096,
            // .cycles = 0,
            // .value = 0,
            // .overflow = 0,
            // .enabled = false,
        };
    }
    pub fn step(self: *Timer, cycles: u8, div: u8) bool {
        _ = cycles; // autofix
        if (!self.tac.enabled) {
            return false;
        }
        self.div = div;
        const freq: Frequency = @enumFromInt(self.tac.frequency);
        const cycles_per_tick = freq.cycles_per_tick();
        const did_overflow = blk: {
            if (self.div >= cycles_per_tick) {
                self.div = self.div % cycles_per_tick;

                const res: u8, const overflow: u1 = @addWithOverflow(self.tima, 1);
                self.tima = res;
                break :blk overflow == 1;
            } else {
                break :blk false;
            }
        };
        if (did_overflow) {
            self.tima = self.tma;
        }
        return did_overflow;
    }
};
