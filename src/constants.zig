pub const CPU_HZ: u32 = 4_194_304; // 4.194304 MHz
pub const FRAME_CYCLES: u32 = 70_224; // DMG cycles per frame (approx 59.7275 Hz)
pub const FRAME_RATE: f64 = @as(f64, CPU_HZ) / @as(f64, FRAME_CYCLES); // ~=59.7275005696
