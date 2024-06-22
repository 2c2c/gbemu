/// FF04
/// 16384Hz increment. writing to it sets to 0. continuing from stop resets to 0
const DIV = 0;

/// FF05
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

const Frequency = enum(u2) {
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

const Timer = struct {
    tac: TAC,
    div: u8,
    tima: u8,
    tma: u8,

    frequency: Frequency,
    cycles: usize,
    value: u8,
    modulo: u8,
    enabled: bool,
    fn new() Timer {
        return Timer{
            .tac = @bitCast(0),
            .div = 0,
            .tima = 0,
            .tma = 0,

            .frequency = Frequency.Hz4096,
            .cycles = 0,
            .value = 0,
            .modulo = 0,
            .enabled = false,
        };
    }
    fn step(self: *Timer, cycles: u8) bool {
        if (!self.enabled) {
            return false;
        }
        self.cycles += @as(usize, cycles);
        const cycles_per_tick = self.frequency.cycles_per_tick();
        const did_overflow = blk: {
            if (self.cycles >= cycles_per_tick) {
                self.cycles = self.cycles % cycles_per_tick;

                const res: u8, const overflow: u1 = @addWithOverflow(self.value, 1);
                self.value = res;
                break :blk overflow;
            } else {
                break :blk false;
            }
        };
        if (did_overflow) {
            self.value = self.modulo;
        }
        return did_overflow;
    }
};
