const std = @import("std");
const cpu = @import("cpu.zig");
const SDL = @import("sdl2");

const log = std.log.scoped(.apu);

pub const SDL_SAMPLE_SIZE = 2048;
pub const SAMPLE_RATE = 48000;
pub const CPU_SPEED_HZ = 4194304;

pub var count: u64 = 0;
var prev_sdl_ticks: u64 = 0;

const DutyCycles: [4][8]u1 = .{
    // 12.5
    .{ 0, 0, 0, 0, 0, 0, 0, 1 },
    // 25
    .{ 0, 0, 0, 0, 0, 0, 1, 1 },
    // 50
    .{ 0, 0, 0, 0, 1, 1, 1, 1 },
    // 75
    .{ 1, 1, 1, 1, 1, 1, 0, 0 },
};

/// FF26 - NR52 - Sound on/off
pub const NR52 = packed struct {
    channel_1: bool,
    channel_2: bool,
    channel_3: bool,
    channel_4: bool,
    _padding: u3,
    audio_on: bool,
};

/// FF25 - NR51 - Sound panning
pub const NR51 = packed struct {
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
pub const NR50 = packed struct {
    right_volume: u3,
    vin_right: bool,
    left_volume: u3,
    vin_left: bool,
};

/// FF10 - NR10 - Channel 1 sweep register
pub const NR10 = packed struct {
    /// How often sweep iterations happenl in units of 128hz ticks
    /// not reread until sweep finishes
    sweep_step: u3,
    /// 0 = period increases, 1 = period decreases
    sweep_direction: bool,
    /// On each iteration, the period is shifted by this amount
    sweep_pace: u3,
    _padding: u1,
};

/// FF11 - NR11 - Channel 1 sound length/wave pattern duty
pub const NR11 = packed struct {
    sound_length: u6,
    wave_pattern_duty: u2,
};

/// FF12 - NR12 - Channel 1 volume envelope
///
pub const NR12 = packed struct {
    env_sweep_pace: u3,
    env_direction: bool,
    env_initial_volume: u4,
};

/// FF13 - NR13 - Channel 1 frequency low
pub const NR13 = packed struct {
    period_low: u8,
};

/// FF14 - NR14 - Channel 1 frequency high
pub const NR14 = packed struct {
    period_high: u3,
    _padding: u3,
    length_enable: bool,
    trigger: bool,
};

/// FF16 - NR21 - Channel 2 sound length/wave pattern duty
pub const NR21 = NR11;
/// FF17 - NR22 - Channel 2 volume envelope
pub const NR22 = NR12;
/// FF18 - NR23 - Channel 2 frequency low
pub const NR23 = NR13;
//// FF19 - NR24 - Channel 2 frequency high
pub const NR24 = NR14;

/// FF1A - NR30 - Channel 3 sound on/off
pub const NR30 = packed struct {
    _padding: u7,
    dac_on: bool,
};

/// FF1B - NR31 - Channel 3 sound length
pub const NR31 = packed struct {
    initial_length_timer: u8,
};

/// FF1C - NR32 - Channel 3 select output level
pub const NR32 = packed struct {
    _padding: u5,
    output_level: u2,
    _padding2: u1,
};

/// FF1D - NR33 - Channel 3 frequency low
pub const NR33 = NR13;

//// FF1E - NR34 - Channel 3 frequency high
pub const NR34 = NR14;

/// FF30-FF3F - Wave pattern RAM
pub const WaveRam = struct {
    byte: [16]u8,
};

/// FF20 - NR41 - Channel 4 sound length
pub const NR41 = packed struct {
    initial_length_timer: u5,
    _padding: u3,
};

/// FF21 - NR42 - Channel 4 volume envelope
pub const NR42 = NR12;

pub const NR43 = packed struct {
    clock_divider: u3,
    lsfr_width: bool,
    clock_shift: u4,
};

pub const NR44 = packed struct {
    _padding: u6,
    length_enable: bool,
    trigger: bool,
};

pub const APU = struct {
    sdl_audio_spec: SDL.SDL_AudioSpec,
    sdl_audio_device: SDL.SDL_AudioDeviceID,

    audio_buffer_downsample_count: usize,
    audio_buffer_count: usize,
    audio_buffer: [SDL_SAMPLE_SIZE * 2]f32,

    length_step: bool,
    envelope_step: bool,
    sweep_step: bool,
    frame_sequence: u64,
    internal_clock: cpu.Clock,
    nr52: NR52,
    nr51: NR51,
    nr50: NR50,

    channel_1: Channel1,
    channel_2: Channel2,
    channel_3: Channel3,
    channel_4: Channel4,

    sdl_total_ticks: u64,

    pub fn new() APU {
        if (SDL.SDL_Init(SDL.SDL_INIT_AUDIO) < 0) {
            sdlPanic();
        }
        // defer SDL.SDL_Quit();

        var audio_spec: SDL.SDL_AudioSpec = .{
            .freq = SAMPLE_RATE,
            .format = SDL.AUDIO_F32SYS,
            .channels = 2,
            .samples = SDL_SAMPLE_SIZE,
            .callback = null,
            .padding = 0,
            .size = 0,
            .silence = 0,
            .userdata = null,
        };
        const audio_device = SDL.SDL_OpenAudioDevice(
            null,
            0,
            &audio_spec,
            null,
            0,
        );
        log.debug("audio_device = {}", .{audio_device});
        SDL.SDL_PauseAudioDevice(audio_device, 0);
        const status = SDL.SDL_GetAudioDeviceStatus(audio_device);
        log.debug("status = {}", .{status});

        var apu = APU{
            .sdl_total_ticks = 0,
            .sdl_audio_spec = audio_spec,
            .sdl_audio_device = audio_device,
            .audio_buffer_downsample_count = 0,
            .audio_buffer_count = 0,
            .audio_buffer = [_]f32{0} ** (SDL_SAMPLE_SIZE * 2),
            .nr52 = NR52{
                .channel_1 = false,
                .channel_2 = false,
                .channel_3 = false,
                .channel_4 = false,
                ._padding = 0,
                .audio_on = false,
            },
            .nr51 = NR51{
                .right_channel_1 = false,
                .right_channel_2 = false,
                .right_channel_3 = false,
                .right_channel_4 = false,
                .left_channel_1 = false,
                .left_channel_2 = false,
                .left_channel_3 = false,
                .left_channel_4 = false,
            },
            .nr50 = NR50{
                .right_volume = 0,
                .vin_right = false,
                .left_volume = 0,
                .vin_left = false,
            },
            .internal_clock = @bitCast(@as(u64, 0)),
            .length_step = false,
            .envelope_step = false,
            .sweep_step = false,
            .frame_sequence = 0,
            .channel_1 = Channel1.new(),
            .channel_2 = Channel2.new(),
            .channel_3 = Channel3.new(),
            .channel_4 = Channel4.new(),
        };

        apu.reset_registers();
        return apu;
    }

    pub fn step(self: *APU, clock: cpu.Clock) void {
        var apu_sample_left: f32 = 0;
        var apu_sample_right: f32 = 0;

        if (self.nr52.audio_on) {
            self.length_step = false;
            self.sweep_step = false;
            self.envelope_step = false;

            const old_bit = (self.internal_clock.bits.div >> 4) & 1;
            const new_bit = (clock.bits.div >> 4) & 1;

            if (old_bit == 1 and new_bit == 0) {
                self.frame_sequence += 1;
                // unsure if these ticks have the same falling edge behavior clock
                self.length_step = if (self.frame_sequence % 2 == 0) true else false;
                self.sweep_step = if (self.frame_sequence % 4 == 0) true else false;
                self.envelope_step = if (self.frame_sequence % 8 == 0) true else false;
            }

            self.internal_clock = clock;

            const ch1_out = self.channel_1.step(self);
            // const ch2_out = self.channel_2.step(self);
            // const ch3_out = self.channel_3.step(self);
            // const ch4_out = self.channel_4.step(self);
            // const ch1_out: f32 = 0;
            const ch2_out: f32 = 0;
            const ch3_out: f32 = 0;
            const ch4_out: f32 = 0;

            const apu_sample_ch1_left = if (self.nr51.left_channel_1) ch1_out / 4 else 0;
            const apu_sample_ch2_left = if (self.nr51.left_channel_2) ch2_out / 4 else 0;
            const apu_sample_ch3_left = if (self.nr51.left_channel_3) ch3_out / 4 else 0;
            const apu_sample_ch4_left = if (self.nr51.left_channel_4) ch4_out / 4 else 0;
            apu_sample_left = apu_sample_ch1_left + apu_sample_ch2_left + apu_sample_ch3_left + apu_sample_ch4_left;
            apu_sample_left = apu_sample_left * (@as(f32, @floatFromInt(self.nr50.left_volume)) / 7.0);

            const apu_sample_ch1_right = if (self.nr51.right_channel_1) ch1_out / 4 else 0;
            const apu_sample_ch2_right = if (self.nr51.right_channel_2) ch2_out / 4 else 0;
            const apu_sample_ch3_right = if (self.nr51.right_channel_3) ch3_out / 4 else 0;
            const apu_sample_ch4_right = if (self.nr51.right_channel_4) ch4_out / 4 else 0;
            apu_sample_right = apu_sample_ch1_right + apu_sample_ch2_right + apu_sample_ch3_right + apu_sample_ch4_right;
            apu_sample_right = apu_sample_right * (@as(f32, @floatFromInt(self.nr50.right_volume)) / 7.0);
            // log.debug("ch3_out = {}, left_channel_3 = {}, left_volume = {}, apu_sample_left = {}, apu_sample_right = {}", .{
            //     ch4_out,
            //     self.nr51.left_channel_4,
            //     self.nr50.left_volume,
            //     apu_sample_left,
            //     apu_sample_right,
            // });
            // if (apu_sample_left > 0 or apu_sample_right > 0) {
            //     log.debug("apu_sample_left = {}, apu_sample_right = {}", .{ apu_sample_left, apu_sample_right });
            // }
        }

        count += 1;
        self.audio_buffer_downsample_count += SAMPLE_RATE;
        // after ~87 cycles, we add to audio buffer
        if (self.audio_buffer_downsample_count >= CPU_SPEED_HZ) {
            count = 0;
            self.audio_buffer_downsample_count -= CPU_SPEED_HZ;

            self.audio_buffer[self.audio_buffer_count] = apu_sample_left;
            self.audio_buffer_count += 1;
            self.audio_buffer[self.audio_buffer_count] = apu_sample_right;
            self.audio_buffer_count += 1;

            // when the audio buffer is filled, we queue it to the audio device
            if (self.audio_buffer_count == SDL_SAMPLE_SIZE * 2) {
                self.audio_buffer_count = 0;
                // const queued_audio_size = SDL.SDL_GetQueuedAudioSize(self.sdl_audio_device);
                // log.debug("queued_audio_size = {}", .{queued_audio_size});
                while (SDL.SDL_GetQueuedAudioSize(self.sdl_audio_device) > SDL_SAMPLE_SIZE * 8) {
                    log.debug("waiting", .{});
                    SDL.SDL_Delay(1);
                }
                self.sdl_total_ticks = SDL.SDL_GetTicks();
                const ticks = self.sdl_total_ticks - prev_sdl_ticks;
                prev_sdl_ticks = self.sdl_total_ticks;
                log.debug("sdl_ticks = {}, ticks = {} count = {}\n ", .{ self.sdl_total_ticks, ticks, count });

                // sample size * 2 channels * 4 bytes per float
                const res = SDL.SDL_QueueAudio(self.sdl_audio_device, &self.audio_buffer, SDL_SAMPLE_SIZE * 8);
                // log.debug("audio buffer::", .{});
                // log.debug("{any}", .{self.audio_buffer});
                var minf = std.math.floatMax(f32);
                var maxf = std.math.floatMin(f32);

                for (self.audio_buffer) |sample| {
                    minf = @min(minf, sample);
                    maxf = @max(maxf, sample);
                }

                // clamp check
                if (minf < -1 or maxf > 1) {
                    log.debug("min = {}, max = {}", .{ minf, maxf });
                }
                // log.debug("min = {}, max = {}", .{ minf, maxf });
                // log.debug("device_id = {}", .{self.sdl_audio_device});

                if (res < 0) {
                    sdlPanic();
                }
                // log.debug("res = {}", .{res});
            }
        }

        self.nr52.channel_1 = self.channel_1.enabled;
        self.nr52.channel_2 = self.channel_2.enabled;

        if (self.channel_3.enabled and self.channel_3.dac_enabled) {
            self.nr52.channel_3 = true;
        } else {
            self.nr52.channel_3 = false;
        }

        self.nr52.channel_4 = self.channel_4.enabled;
    }

    pub fn reset_registers(self: *APU) void {
        self.channel_1.nr10 = @bitCast(@as(u8, 0x80));
        self.channel_1.nr11 = @bitCast(@as(u8, 0xBF));
        self.channel_1.nr12 = @bitCast(@as(u8, 0xF3));
        self.channel_1.nr13 = @bitCast(@as(u8, 0xFF));
        self.channel_1.nr14 = @bitCast(@as(u8, 0xBF));
        self.channel_1.ch1_volume = 0;
        self.channel_1.ch1_duty_pos = 0;
        self.channel_1.frequency = 0;
        self.channel_1.ch1_frequency = 0;
        self.channel_1.ch1_shadow_frequency = 0;
        self.channel_1.ch1_sweep_timer = 0;
        self.channel_1.ch1_sweep_enable = false;
        self.channel_1.ch1_envelope_timer = 0;
        self.channel_1.ch1_length_timer = 0;
        self.channel_1.enabled = false;

        self.channel_2.nr21 = @bitCast(@as(u8, 0x3F));
        self.channel_2.nr22 = @bitCast(@as(u8, 0x00));
        self.channel_2.nr23 = @bitCast(@as(u8, 0xFF));
        self.channel_2.nr24 = @bitCast(@as(u8, 0xBF));

        self.channel_2.enabled = false;
        self.channel_2.timer = 0;
        self.channel_2.volume = 0;
        self.channel_2.duty_pos = 0;
        self.channel_2.envelope_timer = 0;
        self.channel_2.length_timer = 0;

        self.channel_3.nr30 = @bitCast(@as(u8, 0x7F));
        self.channel_3.nr31 = @bitCast(@as(u8, 0xFF));
        self.channel_3.nr32 = @bitCast(@as(u8, 0x9F));
        self.channel_3.nr33 = @bitCast(@as(u8, 0xFF));
        self.channel_3.nr34 = @bitCast(@as(u8, 0xBF));

        self.channel_3.enabled = false;
        self.channel_3.current_sample = 0;
        self.channel_3.timer = 0;
        self.channel_3.length_timer = 0;
        self.channel_3.dac_enabled = false;

        self.channel_4.nr41 = @bitCast(@as(u8, 0xFF));
        self.channel_4.nr42 = @bitCast(@as(u8, 0x00));
        self.channel_4.nr43 = @bitCast(@as(u8, 0x00));
        self.channel_4.nr44 = @bitCast(@as(u8, 0xBF));

        self.channel_4.enabled = false;
        self.channel_4.timer = 0;
        self.channel_4.length_timer = 0;
        self.channel_4.envelope_timer = 0;
        self.channel_4.volume = 0;
        self.channel_4.lsfr = 0;

        self.nr51 = @bitCast(@as(u8, 0x00));
        self.nr50 = @bitCast(@as(u8, 0x77));
        self.nr52 = @bitCast(@as(u8, 0xF1));

        self.audio_buffer_count = 0;
        self.audio_buffer_downsample_count = 0;

        self.audio_buffer = std.mem.zeroes([SDL_SAMPLE_SIZE * 2]f32);

        self.frame_sequence = 0;
    }
    pub fn read_apu_register(self: *APU, addr: u16) u8 {
        switch (addr) {
            0xFF10 => {
                // log.debug("read nr10 {b:0>8}\n", .{@as(u8, @bitCast(self.channel_1.nr10))});
                return @as(u8, @bitCast(self.channel_1.nr10)) | 0b1000_0000;
            },
            // 0xFF11 => return  @bitCast(self.nr11),
            // 0-5 bits are write only, might have to adjust
            0xFF11 => {
                // log.debug("read nr11 {b:0>8}\n", .{@as(u8, @bitCast(self.channel_1.nr11))});
                return @as(u8, @bitCast(self.channel_1.nr11)) | 0b0011_1111;
            },
            0xFF12 => {
                // log.debug("read nr12 {b:0>8}\n", .{@as(u8, @bitCast(self.channel_1.nr12))});
                return @as(u8, @bitCast(self.channel_1.nr12));
            },
            //write only
            0xFF13 => return 0xFF,
            // parts are write only
            0xFF14 => {
                // log.debug("read nr14 {b:0>8}\n", .{@as(u8, @bitCast(self.channel_1.nr14))});
                return @as(u8, @bitCast(self.channel_1.nr14)) | 0xBF;
            },
            0xFF16 => return @as(u8, @bitCast(self.channel_2.nr21)) | 0b0011_1111,
            0xFF17 => return @bitCast(self.channel_2.nr22),
            //write only
            0xFF18 => return 0xFF,
            0xFF19 => return @as(u8, @bitCast(self.channel_2.nr24)) | 0xBF,

            0xFF1A => return @as(u8, @bitCast(self.channel_3.nr30)) | 0b0111_1111,
            0xFF1B => return 0xFF,
            0xFF1C => return @as(u8, @bitCast(self.channel_3.nr32)) | 0b1001_1111,
            // 0xFF1D => return  @bitCast(self.nr33),
            0xFF1D => return 0xFF,
            0xFF1E => return @as(u8, @bitCast(self.channel_3.nr34)) | 0b1011_1111,

            // 0xFF20 => return  @bitCast(self.nr41),
            0xFF20 => return 0xFF,
            0xFF21 => return @bitCast(self.channel_4.nr42),
            0xFF22 => return @bitCast(self.channel_4.nr43),
            0xFF23 => return @as(u8, @bitCast(self.channel_4.nr44)) | 0b1011_1111,

            0xFF24 => return @bitCast(self.nr50),
            0xFF25 => return @bitCast(self.nr51),
            0xFF26 => {
                var nr52 = self.nr52;
                nr52._padding = 0b111;
                nr52.channel_1 = self.channel_1.enabled;
                nr52.channel_2 = self.channel_2.enabled;
                nr52.channel_3 = self.channel_3.enabled;
                nr52.channel_4 = self.channel_4.enabled;

                return @as(u8, @bitCast(nr52));
            },
            0xFF30...0xFF3F => {
                const wave_ram_offset = addr - 0xFF30;
                return self.channel_3.wave_ram.byte[wave_ram_offset];
            },
            else => return 0xFF,
        }
    }

    pub fn write_apu_register(self: *APU, addr: u16, byte: u8) void {
        // if audio is off and addr isnt equal to waveram or nrx1 addresses we skip
        if (!(self.nr52.audio_on or
            addr == 0xFF26 or
            addr >= 0xFF30 and addr <= 0xFF3F or
            addr == 0xFF11 or
            addr == 0xFF16 or
            addr == 0xFF1B or
            addr == 0xFF20))
        {
            return;
        }

        switch (addr) {
            0xFF10 => {
                // log.debug("write nr10 {b:0>8}\n", .{byte});
                self.channel_1.nr10 = @bitCast(byte);
            },
            0xFF11 => {
                // log.debug("write nr11 {b:0>8}\n", .{byte});
                self.channel_1.nr11 = @bitCast(byte | 0b0011_1111);
            },
            0xFF12 => {
                // log.debug("write nr12 {b:0>8}\n", .{byte});
                self.channel_1.nr12 = @bitCast(byte);
                if (self.channel_1.nr12.env_initial_volume == 0xF and self.channel_1.nr12.env_direction) {
                    self.channel_1.enabled = false;
                }
            },
            // part of the two part period value, will probably need changes
            0xFF13 => {
                // log.debug("write nr13 {b:0>8}\n", .{byte});
                self.channel_1.nr13 = @bitCast(byte);
            },
            0xFF14 => {
                // log.debug("write nr14 {b:0>8}\n", .{byte});
                //   sweep_period                = (NR10 >> 4) & 0x07;
                self.channel_1.nr14 = @bitCast(byte | 0b0011_1000);
                if (self.channel_1.nr14.trigger) {
                    // log.info("TRIGGER write nr14 {b:0>8}\n", .{byte});
                    self.channel_1.enabled = true;
                    self.channel_1.ch1_envelope_timer = self.channel_1.nr12.env_sweep_pace;
                    self.channel_1.ch1_length_timer = 64 - @as(u16, self.channel_1.nr11.sound_length);
                    self.channel_1.ch1_volume = self.channel_1.nr12.env_initial_volume;
                    self.channel_1.frequency = @as(u16, self.channel_1.nr14.period_high) << 8 | self.channel_1.nr13.period_low;
                    self.channel_1.ch1_frequency = self.channel_1.frequency;
                    self.channel_1.ch1_shadow_frequency = self.channel_1.frequency;
                    self.channel_1.ch1_sweep_timer = if (self.channel_1.nr10.sweep_pace == 0) 8 else self.channel_1.nr10.sweep_pace;
                    self.channel_1.ch1_sweep_enable = if (self.channel_1.nr10.sweep_pace != 0 or self.channel_1.nr10.sweep_step == 0) true else false;
                }
            },
            0xFF15 => {},
            0xFF16 => {
                self.channel_2.nr21 = @bitCast(byte | 0b0011_1111);
            },
            0xFF17 => {
                // log.info("write nr22 {b:0>8}\n", .{byte});
                self.channel_2.nr22 = @bitCast(byte);
                if (self.channel_2.nr22.env_initial_volume == 0xF and self.channel_2.nr22.env_direction) {
                    self.channel_2.enabled = false;
                }
            },
            // part of the two part period value, will probably need changes
            0xFF18 => {
                self.channel_2.nr23 = @bitCast(byte);
            },
            0xFF19 => {
                // log.debug("write nr24 {b:0>8}\n", .{byte});
                //   sweep_period                = (nr20 >> 4) & 0x07;
                self.channel_2.nr24 = @bitCast(byte | 0b0011_1000);
                const freq = @as(u16, self.channel_2.nr24.period_high) << 8 | self.channel_2.nr23.period_low;

                if (self.channel_2.nr24.trigger) {
                    // log.info("TRIGGER write nr24 {b:0>8}\n", .{byte});
                    self.channel_2.enabled = true;
                    self.channel_2.length_timer = 64 - @as(u16, self.channel_2.nr21.sound_length);
                    self.channel_2.volume = self.channel_2.nr22.env_initial_volume;
                    self.channel_2.timer = (2048 - freq) * 4;
                    self.channel_2.envelope_timer = self.channel_2.nr22.env_sweep_pace;
                }
            },
            0xFF1A => {
                self.channel_3.nr30 = @bitCast(byte | 0b0111_1111);

                // not needed
                if (self.channel_3.nr30.dac_on) {
                    self.channel_3.dac_enabled = true;
                } else {
                    self.channel_3.dac_enabled = false;
                }
            },
            0xFF1B => {
                // self.channel_3.nr31 = @bitCast(byte | 0b1111_1111);
                self.channel_3.nr31 = @bitCast(byte);
            },
            0xFF1C => {
                self.channel_3.nr32 = @bitCast(byte | 0b1001_1111);
            },
            0xFF1D => {
                self.channel_3.nr33 = @bitCast(byte);
            },
            0xFF1E => {
                self.channel_3.nr34 = @bitCast(byte | 0b0011_1000);

                const freq = @as(u16, self.channel_3.nr34.period_high) << 8 | self.channel_3.nr33.period_low;
                if (self.channel_3.nr34.trigger and self.channel_3.dac_enabled) {
                    self.channel_3.enabled = true;
                    // ?
                    self.channel_3.current_sample = 0;
                    self.channel_3.length_timer = 256 - @as(u16, self.channel_3.nr31.initial_length_timer);
                    self.channel_3.timer = (2048 - freq) * 2;
                }
            },
            0xFF20 => {
                self.channel_4.nr41 = @bitCast(byte | 0b0011_1111);
            },
            0xFF21 => {
                self.channel_4.nr42 = @bitCast(byte);
                if (self.channel_4.nr42.env_initial_volume == 0xF and self.channel_4.nr42.env_direction) {
                    self.channel_4.enabled = false;
                }
            },
            0xFF22 => {
                self.channel_4.nr43 = @bitCast(byte);
            },
            0xFF23 => {
                self.channel_4.nr44 = @bitCast(byte | 0b0011_1111);
                if (self.channel_4.nr44.trigger) {
                    self.channel_4.enabled = true;
                    self.channel_4.timer = self.channel_4.freq();
                    self.channel_4.length_timer = 64 - @as(u16, self.channel_4.nr41.initial_length_timer);
                    self.channel_4.volume = self.channel_4.nr42.env_initial_volume;
                    self.channel_4.envelope_timer = self.channel_4.nr42.env_sweep_pace;
                    self.channel_4.lsfr = 0;
                }
            },
            0xFF24 => {
                self.nr50 = @bitCast(byte);
            },
            0xFF25 => {
                self.nr51 = @bitCast(byte);
            },
            0xFF26 => {
                const enabled = (byte & 0x80) == 1;
                if (!enabled and self.nr52.audio_on) {
                    for (0xFF10..0xFF26) |reset_addr| {
                        self.write_apu_register(@truncate(reset_addr), 0);
                    }
                    // self.nr52.audio_on = false;
                } else {
                    self.nr52.audio_on = true;
                    self.frame_sequence = 0;
                    self.channel_1.ch1_duty_pos = 0;
                    self.channel_2.duty_pos = 0;
                    self.channel_3.current_sample = 0;
                }
            },
            0xFF30...0xFF3F => {
                const wave_ram_offset = addr - 0xFF30;
                self.channel_3.wave_ram.byte[wave_ram_offset] = byte;
            },
            else => {},
        }
    }
};

const Channel1 = struct {
    enabled: bool,
    nr10: NR10,
    nr11: NR11,
    nr12: NR12,
    nr13: NR13,
    nr14: NR14,

    frequency: u16,
    ch1_frequency: u16,
    ch1_shadow_frequency: u16,

    ch1_timer: u16,
    ch1_envelope_timer: u16,
    ch1_length_timer: u16,
    ch1_sweep_timer: u16,
    ch1_sweep_enable: bool,

    ch1_volume: u4,
    ch1_duty_pos: u16,

    pub fn new() Channel1 {
        return Channel1{
            .enabled = false,
            .ch1_timer = 0,
            .ch1_envelope_timer = 0,
            .ch1_length_timer = 0,
            .ch1_volume = 0,
            .ch1_duty_pos = 0,
            .nr10 = NR10{
                .sweep_step = 0,
                .sweep_direction = false,
                .sweep_pace = 0,
                ._padding = 0,
            },
            .nr11 = NR11{
                .sound_length = 0,
                .wave_pattern_duty = 0,
            },
            .nr12 = NR12{
                .env_sweep_pace = 0,
                .env_direction = false,
                .env_initial_volume = 0,
            },
            .nr13 = NR13{
                .period_low = 0,
            },
            .nr14 = NR14{
                .period_high = 0,
                ._padding = 0,
                .length_enable = false,
                .trigger = false,
            },
            .frequency = 0,
            .ch1_frequency = 0,
            .ch1_shadow_frequency = 0,
            .ch1_sweep_timer = 0,
            .ch1_sweep_enable = false,
        };
    }

    pub fn step(self: *Channel1, apu: *APU) f32 {
        // log.debug("in ch1.step", .{});
        if (!self.enabled) {
            return 0;
        }

        // log.debug("enabled ch1 step", .{});
        // log.debug("before self.duty_pos = {}", .{self.ch1_duty_pos});
        self.ch1_timer -%= 1;
        if (self.ch1_timer == 0) {
            self.ch1_timer = (2048 - self.ch1_frequency) * 4;
            self.ch1_duty_pos = (self.ch1_duty_pos + 1) % 8;
        }
        // log.debug("after self.duty_pos = {}", .{self.ch1_duty_pos});

        // tune by volume?
        const amp = DutyCycles[self.nr11.wave_pattern_duty][self.ch1_duty_pos];

        // log.debug("DutyCycles[{}][{}] = {}", .{
        //     .duty = self.nr11.wave_pattern_duty,
        //     .pos = self.ch1_duty_pos,
        //     .amp = amp,
        // });

        if (apu.length_step and self.nr14.length_enable) {
            self.ch1_length_timer -%= 1;
            if (self.ch1_length_timer == 0) {
                self.enabled = false;
            }
        }

        // TODO: setup env int volume to ch1_volume during trigger event
        if (apu.envelope_step and self.nr12.env_sweep_pace != 0) {
            self.ch1_envelope_timer -%= 1;
            if (self.ch1_envelope_timer == self.nr12.env_sweep_pace) {
                self.ch1_envelope_timer = self.nr12.env_sweep_pace;
                if (self.nr12.env_direction and self.ch1_volume != 0xF) {
                    self.ch1_volume += 1;
                }
                if (!self.nr12.env_direction and self.ch1_volume != 0x0) {
                    self.ch1_volume -= 1;
                }
            }
        }

        if (apu.sweep_step) {
            self.ch1_sweep_timer -%= 1;
            if (self.ch1_sweep_timer == 0) {
                self.ch1_sweep_timer = if (self.nr10.sweep_pace == 0) 8 else self.nr10.sweep_pace;

                // unsure if I need an enabled flag instead of using pace
                if (self.ch1_sweep_enable and self.nr10.sweep_pace > 0) {
                    var new_freq: u16 = self.ch1_shadow_frequency >> self.nr10.sweep_pace;
                    if (!self.nr10.sweep_direction) {
                        new_freq -%= self.ch1_shadow_frequency;
                    } else {
                        new_freq +%= self.ch1_shadow_frequency;
                    }

                    if (new_freq > 2048 or new_freq == 0) {
                        self.enabled = false;
                    }

                    if (self.enabled and apu.sweep_step) {
                        self.ch1_frequency = new_freq;
                        self.ch1_shadow_frequency = new_freq;
                    }
                }
            }
        }

        return dac_volume_convert(amp * self.ch1_volume);
    }
};

const Channel2 = struct {
    nr21: NR21,
    nr22: NR22,
    nr23: NR23,
    nr24: NR24,

    enabled: bool,
    volume: u4,
    timer: u16,
    envelope_timer: u16,
    length_timer: u16,
    duty_pos: u16,

    pub fn new() Channel2 {
        return Channel2{
            .enabled = false,
            .timer = 0,
            .envelope_timer = 0,
            .length_timer = 0,
            .volume = 0,
            .duty_pos = 0,
            .nr21 = NR21{
                .sound_length = 0,
                .wave_pattern_duty = 0,
            },
            .nr22 = NR22{
                .env_sweep_pace = 0,
                .env_direction = false,
                .env_initial_volume = 0,
            },
            .nr23 = NR23{
                .period_low = 0,
            },
            .nr24 = NR24{
                .period_high = 0,
                ._padding = 0,
                .length_enable = false,
                .trigger = false,
            },
        };
    }

    pub fn step(self: *Channel2, apu: *APU) f32 {
        // log.debug("in ch1.step", .{});
        if (!self.enabled) {
            return 0;
        }

        const freq: u16 = @as(u16, self.nr24.period_high) << 8 | @as(u16, self.nr23.period_low);
        const initial_freq = (2048 - freq) * 4;
        self.timer -%= 1;
        if (self.timer == 0) {
            self.timer = initial_freq;
            self.duty_pos = (self.duty_pos + 1) % 8;
        }
        // log.debug("after self.duty_pos = {}", .{self.duty_pos});

        // tune by volume?
        const amp = DutyCycles[self.nr21.wave_pattern_duty][self.duty_pos];

        // log.debug("DutyCycles[{}][{}] = {}", .{
        //     .duty = self.nr21.wave_pattern_duty,
        //     .pos = self.duty_pos,
        //     .amp = amp,
        // });

        if (apu.length_step and self.nr24.length_enable) {
            self.length_timer -%= 1;
            if (self.length_timer == 0) {
                self.enabled = false;
            }
        }

        // log.debug("envelope_step = {} env_sweep_pace = {}", .{ apu.envelope_step, self.nr22.env_sweep_pace });
        // if (apu.envelope_step) {
        //     log.debug("envelope_step = {} env_sweep_pace = {}", .{ apu.envelope_step, self.nr22.env_sweep_pace });
        // }
        // log.debug("nr22 {b:0>8}", .{@as(u8, @bitCast(self.nr22))});
        // if (self.nr22.env_sweep_pace != 0) {
        //     log.debug("envelope_step = {} env_sweep_pace = {}", .{ apu.envelope_step, self.nr22.env_sweep_pace });
        // }
        if (apu.envelope_step and self.nr22.env_sweep_pace != 0) {
            // log.debug("envelope_step = {} env_sweep_pace = {}", .{ apu.envelope_step, self.nr22.env_sweep_pace });
            self.envelope_timer -%= 1;
            if (self.envelope_timer == 0) {
                self.envelope_timer = self.nr22.env_sweep_pace;
                if (self.nr22.env_direction and self.volume != 0xF) {
                    self.volume += 1;
                }
                if (!self.nr22.env_direction and self.volume != 0x0) {
                    self.volume -= 1;
                }
            }
        }

        // log.debug("amp = {} volume = {}", .{ amp, self.volume });
        return dac_volume_convert(amp * self.volume);
    }
};

const Channel3 = struct {
    nr30: NR30,
    nr31: NR31,
    nr32: NR32,
    nr33: NR33,
    nr34: NR34,

    enabled: bool,
    current_sample: u8,
    timer: u16,
    length_timer: u16,
    dac_enabled: bool,

    wave_ram: WaveRam,

    pub fn new() Channel3 {
        return Channel3{
            .enabled = false,
            .current_sample = 0,
            .timer = 0,
            .length_timer = 0,
            .dac_enabled = false,
            .wave_ram = WaveRam{
                .byte = [_]u8{0} ** 16,
            },
            .nr30 = NR30{
                ._padding = 0,
                .dac_on = false,
            },
            .nr31 = NR31{
                .initial_length_timer = 0,
            },
            .nr32 = NR32{
                ._padding = 0,
                .output_level = 0,
                ._padding2 = 0,
            },
            .nr33 = NR33{
                .period_low = 0,
            },
            .nr34 = NR34{
                .period_high = 0,
                ._padding = 0,
                .length_enable = false,
                .trigger = false,
            },
        };
    }

    pub fn step(self: *Channel3, apu: *APU) f32 {
        // log.debug("in ch1.step", .{});
        if (!self.enabled) {
            return 0;
        }

        const freq: u16 = @as(u16, self.nr34.period_high) << 8 | @as(u16, self.nr33.period_low);
        const initial_freq = (2048 - freq) * 2;
        self.timer -%= 1;
        if (self.timer == 0) {
            self.timer = initial_freq;
            self.current_sample = (self.current_sample + 1) % 32;
        }

        const amp_byte = @as(u8, self.wave_ram.byte[self.current_sample / 2]);
        var amp_nibble: u8 = 0;
        if (self.current_sample % 2 == 0) {
            amp_nibble = @truncate((amp_byte >> 4) & 0xF);
        } else {
            amp_nibble = @truncate(amp_byte & 0xF);
        }

        switch (self.nr32.output_level) {
            0b00 => amp_nibble = amp_nibble >> 4,
            0b01 => amp_nibble = amp_nibble,
            0b10 => amp_nibble = amp_nibble >> 1,
            0b11 => amp_nibble = amp_nibble >> 2,
        }

        // log.debug("amp_nibble = {} output_level = {} current_samp_nibblele = {}", .{
        //     amp_nibble,
        //     self.nr32.output_level,
        //     self.current_samp_nibblele,
        // });

        if (apu.length_step and self.nr34.length_enable) {
            self.length_timer -%= 1;
            if (self.length_timer == 0) {
                self.enabled = false;
            }
        }

        // log.debug("amp_nibble = {} volume = {}", .{ amp_nibble, self.volume });
        if (!self.dac_enabled) {
            return 0;
        }

        // log.debug("amp_nibble = {}", .{amp_nibble});
        return dac_volume_convert(@truncate(amp_nibble));
    }
};

const Channel4 = struct {
    nr41: NR41,
    nr42: NR42,
    nr43: NR43,
    nr44: NR44,

    enabled: bool,
    timer: u16,
    length_timer: u16,
    envelope_timer: u16,
    volume: u4,
    lsfr: u16,

    pub fn new() Channel4 {
        return Channel4{
            .enabled = false,
            .timer = 0,
            .length_timer = 0,
            .envelope_timer = 0,
            .volume = 0,
            .lsfr = 0,

            .nr41 = NR41{
                .initial_length_timer = 0,
                ._padding = 0,
            },
            .nr42 = NR42{
                .env_sweep_pace = 0,
                .env_direction = false,
                .env_initial_volume = 0,
            },
            .nr43 = NR43{
                .clock_divider = 0,
                .lsfr_width = false,
                .clock_shift = 0,
            },
            .nr44 = NR44{
                ._padding = 0,
                .length_enable = false,
                .trigger = false,
            },
        };
    }

    pub fn freq(self: *Channel4) u16 {
        var base: u16 = 0;
        switch (self.nr43.clock_divider) {
            0b000 => base = 8,
            0b001 => base = 16,
            0b010 => base = 32,
            0b011 => base = 48,
            0b100 => base = 64,
            0b101 => base = 80,
            0b110 => base = 96,
            0b111 => base = 112,
        }
        return base << self.nr43.clock_shift;
    }

    pub fn step(self: *Channel4, apu: *APU) f32 {
        if (!self.enabled) {
            return 0;
        }

        self.timer -%= 1;
        if (self.timer == 0) {
            self.timer = self.freq();

            const lsfr_bit0 = self.lsfr & 1;
            const lsfr_bit1 = (self.lsfr >> 1) & 1;
            const new_bit = lsfr_bit0 ^ lsfr_bit1;
            self.lsfr >>= 1;
            self.lsfr |= new_bit << 14;
            // log.debug("bit0 = {} bit1 = {} new_bit = {} lsfr = {}", .{
            //     lsfr_bit0,
            //     lsfr_bit1,
            //     new_bit,
            //     self.lsfr,
            // });
            if (self.nr43.lsfr_width) {
                self.lsfr &= ~(@as(u16, 1) << 6);
                self.lsfr |= new_bit << 6;
            }
        }

        const amp: u4 = @truncate(~self.lsfr & 1);

        // log.debug("lsfr = {}", .{self.lsfr});
        // log.debug("amp = {}", .{amp});

        if (apu.length_step and self.nr44.length_enable) {
            self.length_timer -%= 1;
            if (self.length_timer == 0) {
                self.enabled = false;
            }
        }

        if (apu.envelope_step and self.nr42.env_sweep_pace != 0) {
            // log.debug("envelope_step = {} env_sweep_pace = {}", .{ apu.envelope_step, self.nr42.env_sweep_pace });
            self.envelope_timer -%= 1;
            if (self.envelope_timer == 0) {
                self.envelope_timer = self.nr42.env_sweep_pace;
                if (self.nr42.env_direction and self.volume != 0xF) {
                    self.volume += 1;
                }
                if (!self.nr42.env_direction and self.volume != 0x0) {
                    self.volume -= 1;
                }
            }
        }

        // log.debug("amp = {}, volume = {}", .{ amp, self.volume });
        return dac_volume_convert(amp * self.volume);
    }
};

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}

fn dac_volume_convert(amp: u4) f32 {
    return (@as(f32, @floatFromInt(amp)) / 7.5) - 1.0;
}
