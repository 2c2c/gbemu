/// FF26 - NR52 - Sound on/off
const NR52 = packed struct {
    channel_1: bool,
    channel_2: bool,
    channel_3: bool,
    channel_4: bool,
    _padding: u3,
    audio_on: bool,
};

/// FF25 - NR51 - Sound panning
const NR51 = packed struct {
    right_channel_1: bool,
    right_channel_2: bool,
    right_channel_3: bool,
    right_channel_4: bool,
    left_channel_1: bool,
    left_channel_2: bool,
    left_channel_3: bool,
    left_channel_4: bool,
};

/// FF24 - NR50 - Master volume/switch
const NR50 = packed struct {
    right_volume: u3,
    vin_right: bool,
    left_volume: u3,
    vin_left: bool,
};

/// FF10 - NR10 - Channel 1 sweep register
const NR10 = packed struct {
    sweep_step: u3,
    sweep_direction: bool,
    sweep_pace: u3,
    _padding: u1,
};

/// FF11 - NR11 - Channel 1 sound length/wave pattern duty
const NR11 = packed struct {
    sound_length: u6,
    wave_pattern_duty: u2,
};

/// FF12 - NR12 - Channel 1 volume envelope
///
const NR12 = packed struct {
    sweep_pace: u3,
    env_direction: bool,
    initial_volume: u4,
};

/// FF13 - NR13 - Channel 1 frequency low
const NR13 = packed struct {
    period_low: u8,
};

/// FF14 - NR14 - Channel 1 frequency high
const NR14 = packed struct {
    period_high: u3,
    _padding: u3,
    length_enable: bool,
    trigger: bool,
};

/// FF16 - NR21 - Channel 2 sound length/wave pattern duty
const NR21 = NR11;
/// FF17 - NR22 - Channel 2 volume envelope
const NR22 = NR12;
/// FF18 - NR23 - Channel 2 frequency low
const NR23 = NR13;
//// FF19 - NR24 - Channel 2 frequency high
const NR24 = NR14;

/// FF1A - NR30 - Channel 3 sound on/off
const NR30 = struct {
    _padding: u7,
    dac_on: bool,
};

/// FF1B - NR31 - Channel 3 sound length
const NR31 = packed struct {
    initial_length_timer: u8,
};

/// FF1C - NR32 - Channel 3 select output level
const NR32 = packed struct {
    _padding: u5,
    output_level: u2,
    _padding2: u1,
};

/// FF1D - NR33 - Channel 3 frequency low
const NR33 = NR13;

//// FF1E - NR34 - Channel 3 frequency high
const NR34 = NR14;

/// FF30-FF3F - Wave pattern RAM
const wave_ram = packed struct {
    wave_pattern: u128,
};

/// FF20 - NR41 - Channel 4 sound length
const NR41 = packed struct {
    initial_length_timer: u5,
    _padding: u3,
};

/// FF21 - NR42 - Channel 4 volume envelope
const NR42 = NR11;

const NR43 = packed struct {
    clock_divider: u3,
    lsfr_width: u1,
    clock_shift: u4,
};
