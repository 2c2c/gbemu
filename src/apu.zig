const std = @import("std");
const cpu = @import("cpu.zig");
const builtin = @import("builtin");
const have_sdl = builtin.cpu.arch != .wasm32;
const SDL = if (have_sdl) @import("sdl2") else struct {
    pub const SDL_INIT_AUDIO: u32 = 0;
    pub const AUDIO_F32SYS: u16 = 0;
    pub const SDL_AudioDeviceID = u32;
    pub const SDL_AudioSpec = extern struct {
        freq: c_int,
        format: u16,
        channels: u8,
        samples: u16,
        callback: ?*const anyopaque,
        padding: u32,
        size: u32,
        silence: u8,
        userdata: ?*anyopaque,
    };
    pub fn SDL_Init(flags: u32) c_int { _ = flags; return 0; }
    pub fn SDL_OpenAudioDevice(dev: ?[*:0]const u8, iscapture: c_int, desired: *SDL_AudioSpec, obtained: ?*SDL_AudioSpec, allowed_changes: c_int) SDL_AudioDeviceID {
        _ = .{ dev, iscapture, desired, obtained, allowed_changes };
        return 1;
    }
    pub fn SDL_PauseAudioDevice(dev: SDL_AudioDeviceID, pause_on: c_int) void { _ = .{ dev, pause_on }; }
    pub fn SDL_GetAudioDeviceStatus(dev: SDL_AudioDeviceID) c_int { _ = dev; return 0; }
    pub fn SDL_GetQueuedAudioSize(dev: SDL_AudioDeviceID) usize { _ = dev; return 0; }
    pub fn SDL_Delay(ms: u32) void { _ = ms; }
    pub fn SDL_GetTicks() u32 { return 0; }
    pub fn SDL_QueueAudio(dev: SDL_AudioDeviceID, data: *const anyopaque, len: usize) c_int { _ = .{ dev, data, len }; return 0; }
    pub fn SDL_GetError() ?[*:0]const u8 { return null; }
};

const log = std.log.scoped(.apu);

pub const SDL_SAMPLE_SIZE = 2048;
pub const SAMPLE_RATE = 48000;
// pub const SAMPLE_RATE = 48000 * 4;
pub const CPU_SPEED_HZ = 4194304;

// Anti-aliasing FIR low-pass used when decimating the CPU-rate (4.19 MHz) audio down to
// SAMPLE_RATE. A windowed-sinc kernel (Blackman window) gives a flat passband and a deep
// stopband, so high-frequency content (e.g. high-rate noise) is band-limited instead of
// aliasing into audible static. FIR_TAPS is a power of two so the ring buffer index masks.
const FIR_TAPS: usize = 2048;
const FIR_CUTOFF_HZ: f64 = 22000.0;
var fir_kernel: [FIR_TAPS]f32 = @splat(0);
var fir_kernel_ready: bool = false;
fn build_fir_kernel() void {
    if (fir_kernel_ready) return;
    const pi = std.math.pi;
    const fc: f64 = FIR_CUTOFF_HZ / @as(f64, CPU_SPEED_HZ); // cutoff normalized to input rate
    const m: f64 = @floatFromInt(FIR_TAPS - 1);
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < FIR_TAPS) : (i += 1) {
        const n: f64 = @floatFromInt(i);
        const x: f64 = n - m / 2.0;
        var h: f64 = if (x == 0) 2.0 * fc else std.math.sin(2.0 * pi * fc * x) / (pi * x);
        const w: f64 = 0.42 - 0.5 * std.math.cos(2.0 * pi * n / m) + 0.08 * std.math.cos(4.0 * pi * n / m);
        h *= w;
        fir_kernel[i] = @floatCast(h);
        sum += h;
    }
    i = 0;
    while (i < FIR_TAPS) : (i += 1) {
        fir_kernel[i] = @floatCast(@as(f64, fir_kernel[i]) / sum); // unity DC gain
    }
    fir_kernel_ready = true;
}

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
    // 6-bit length (NR41 bits 0-5). Was u5, which capped length_timer at >=33 ticks so short
    // noise bursts (e.g. a sword slash) couldn't end and droned on.
    initial_length_timer: u6,
    _padding: u2,
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
    // FIR anti-aliasing decimator state: ring buffer of recent per-cycle samples, low-pass
    // filtered with fir_kernel before decimating to the 48 kHz output (see build_fir_kernel).
    fir_buf_l: [FIR_TAPS]f32,
    fir_buf_r: [FIR_TAPS]f32,
    fir_pos: usize,
    // Native UI toggles. mute zeros the output (pacing still works because silence is still
    // queued). speed is the emulation multiplier (2 = fast-forward): we emit 1/speed as many
    // output samples per emulated second, so the audio-queue backpressure — which drains at a
    // fixed 48 kHz — paces the emulator `speed`x faster (the audio plays sped up).
    mute: bool,
    speed: usize,

    length_step: bool,
    envelope_step: bool,
    sweep_step: bool,
    // Frame sequencer phase. `frame_step` is the NEXT of the 8 steps (0-7) to run;
    // it advances on the falling edge of the system DIV bit 12 (tracked via
    // `prev_div_bit`), so DIV writes shift its phase exactly like real hardware
    // (blargg 07 / the sync_apu/sync_sweep test helpers).
    frame_step: u3,
    prev_div_bit: u1,
    // Monotonic per-T-cycle counter (never reset by DIV writes) used as the time
    // reference for the channel-3 wave-RAM access window (blargg 09/10/12).
    current_tick: u64,
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
    if (have_sdl) sdlPanic();
        }
        // defer SDL.SDL_Quit();

        var audio_spec: SDL.SDL_AudioSpec = .{
            .freq = 48000,
            .format = SDL.AUDIO_F32SYS,
            .channels = 2,
            .samples = SDL_SAMPLE_SIZE,
            .callback = null,
            .padding = 0,
            .size = 0,
            .silence = 0,
            .userdata = null,
        };
        const audio_device = SDL.SDL_OpenAudioDevice(null, 0, &audio_spec, null, 0);
        if (have_sdl) {
            log.debug("audio_device = {}", .{audio_device});
            SDL.SDL_PauseAudioDevice(audio_device, 0);
            const status = SDL.SDL_GetAudioDeviceStatus(audio_device);
            log.debug("status = {}", .{status});
        }

        var apu = APU{
            .sdl_total_ticks = 0,
            .sdl_audio_spec = audio_spec,
            .sdl_audio_device = audio_device,
            .audio_buffer_downsample_count = 0,
            .audio_buffer_count = 0,
            .audio_buffer = @splat(0),
            .fir_buf_l = @splat(0),
            .fir_buf_r = @splat(0),
            .fir_pos = 0,
            .mute = false,
            .speed = 1,
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
            .length_step = false,
            .envelope_step = false,
            .sweep_step = false,
            .frame_step = 0,
            .prev_div_bit = 0,
            .current_tick = 0,
            .channel_1 = Channel1.new(),
            .channel_2 = Channel2.new(),
            .channel_3 = Channel3.new(),
            .channel_4 = Channel4.new(),
        };

        build_fir_kernel();
        apu.reset_registers();
        return apu;
    }

    /// Steps the APU one T-cycle. `div_clock` is the *system* DIV counter (the
    /// timer's internal_clock) already advanced for this T-cycle — the frame
    /// sequencer is derived from it so DIV writes shift its phase.
    pub fn step(self: *APU, div_clock: cpu.Clock) void {
        var apu_sample_left: f32 = 0;
        var apu_sample_right: f32 = 0;

        self.current_tick +%= 1;

        // DIV bit 12 (= bit 4 of the DIV upper byte) clocks the 512 Hz frame sequencer.
        const div_bit: u1 = @truncate((div_clock.bits.div >> 4) & 1);

        if (self.nr52.audio_on) {
            self.length_step = false;
            self.sweep_step = false;
            self.envelope_step = false;

            // Falling edge of DIV bit 12 -> advance the frame sequencer one step.
            // Length clocks on steps 0,2,4,6; sweep on 2,6; envelope on 7.
            if (self.prev_div_bit == 1 and div_bit == 0) {
                switch (self.frame_step) {
                    0, 4 => self.length_step = true,
                    2, 6 => {
                        self.length_step = true;
                        self.sweep_step = true;
                    },
                    7 => self.envelope_step = true,
                    else => {},
                }
                self.frame_step +%= 1;
            }

            // Length counters are clocked even while the channel is disabled (blargg
            // 02 #11), so they run here independent of each channel's enabled gate.
            if (self.length_step) {
                self.channel_1.clock_length();
                self.channel_2.clock_length();
                self.channel_3.clock_length();
                self.channel_4.clock_length();
            }

            const ch1_out = self.channel_1.step(self);
            const ch2_out = self.channel_2.step(self);
            const ch3_out = self.channel_3.step(self);
            const ch4_out = self.channel_4.step(self);
            // const ch1_out: f32 = 0;
            // const ch2_out: f32 = 0;
            // const ch3_out: f32 = 0;
            // const ch4_out: f32 = 0;

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

        // Track DIV bit 12 every cycle (even while powered off) so that on power-up
        // the next frame-sequencer step's timing follows the current DIV phase
        // rather than a fresh counter (blargg 07).
        self.prev_div_bit = div_bit;

        if (self.mute) {
            apu_sample_left = 0;
            apu_sample_right = 0;
        }

        // Push the current per-cycle sample into the FIR ring buffer (anti-aliasing decimator).
        self.fir_buf_l[self.fir_pos] = apu_sample_left;
        self.fir_buf_r[self.fir_pos] = apu_sample_right;
        self.fir_pos = (self.fir_pos + 1) & (FIR_TAPS - 1);

        count += 1;
        self.audio_buffer_downsample_count += SAMPLE_RATE / @max(self.speed, 1);
        // after ~87 cycles (or ~87*speed for fast-forward) we add to audio buffer
        if (self.audio_buffer_downsample_count >= CPU_SPEED_HZ) {
            count = 0;
            self.audio_buffer_downsample_count -= CPU_SPEED_HZ;

            // Low-pass the last FIR_TAPS samples (newest-to-oldest) with the windowed-sinc kernel.
            var out_left: f32 = 0;
            var out_right: f32 = 0;
            var idx: usize = (self.fir_pos + FIR_TAPS - 1) & (FIR_TAPS - 1);
            var j: usize = 0;
            while (j < FIR_TAPS) : (j += 1) {
                const kf = fir_kernel[j];
                out_left += kf * self.fir_buf_l[idx];
                out_right += kf * self.fir_buf_r[idx];
                idx = (idx + FIR_TAPS - 1) & (FIR_TAPS - 1);
            }

            if (!have_sdl) {
                // Web build: the JS side drains this buffer on its own clock (gb_audio_consume).
                // Append a stereo sample only if there is room; if JS briefly falls behind, drop
                // new samples rather than wrap and overwrite unconsumed ones (which corrupts
                // playback / causes static). No mid-stream reset here — only the consumer resets.
                if (self.audio_buffer_count + 2 <= SDL_SAMPLE_SIZE * 2) {
                    self.audio_buffer[self.audio_buffer_count] = out_left;
                    self.audio_buffer[self.audio_buffer_count + 1] = out_right;
                    self.audio_buffer_count += 2;
                }
            } else {
                self.audio_buffer[self.audio_buffer_count] = out_left;
                self.audio_buffer_count += 1;
                self.audio_buffer[self.audio_buffer_count] = out_right;
                self.audio_buffer_count += 1;

                // when the audio buffer is filled, we queue it to the audio device
                if (self.audio_buffer_count == SDL_SAMPLE_SIZE * 2) {
                    self.audio_buffer_count = 0;
                    while (SDL.SDL_GetQueuedAudioSize(self.sdl_audio_device) > SDL_SAMPLE_SIZE * 8) {
                        SDL.SDL_Delay(1);
                    }
                    if (have_sdl) self.sdl_total_ticks = SDL.SDL_GetTicks();

                    // sample size * 2 channels * 4 bytes per float
                    const res = SDL.SDL_QueueAudio(self.sdl_audio_device, &self.audio_buffer, SDL_SAMPLE_SIZE * 8);
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

                    if (res < 0) {
                        sdlPanic();
                    }
                }
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

        self.channel_1.volume = 0;
        self.channel_1.duty_pos = 0;
        self.channel_1._frequency = 0;
        self.channel_1.frequency = 0;
        self.channel_1.shadow_frequency = 0;
        self.channel_1.sweep_timer = 0;
        self.channel_1.sweep_enable = false;
        self.channel_1.sweep_negate_used = false;
        self.channel_1.envelope_timer = 0;
        self.channel_1.length_timer = 0;
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
        self.channel_3.sample_time = 0;

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
        self.fir_buf_l = std.mem.zeroes([FIR_TAPS]f32);
        self.fir_buf_r = std.mem.zeroes([FIR_TAPS]f32);
        self.fir_pos = 0;

        self.audio_buffer = std.mem.zeroes([SDL_SAMPLE_SIZE * 2]f32);

        self.frame_step = 0;
        self.prev_div_bit = 0;
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
                // While ch3 plays, DMG only exposes wave RAM on the exact tick the wave
                // unit fetches a byte (then any address reads that byte); otherwise 0xFF.
                if (self.channel_3.enabled) {
                    if (self.current_tick == self.channel_3.sample_time) {
                        return self.channel_3.wave_ram.byte[self.channel_3.current_sample / 2];
                    }
                    return 0xFF;
                }
                return self.channel_3.wave_ram.byte[wave_ram_offset];
            },
            else => return 0xFF,
        }
    }

    /// True when the frame sequencer's NEXT step (`frame_step`) will NOT clock the
    /// length counter (odd steps 1,3,5,7). Writing NRx4 to enable length, or
    /// triggering with a freshly-reloaded length, in this window applies one extra
    /// immediate length clock — the "extra length clock" quirk (blargg 03).
    fn extra_length_clock(self: *APU) bool {
        return (self.frame_step & 1) == 1;
    }

    pub fn write_apu_register(self: *APU, addr: u16, byte: u8) void {
        // DMG power-off write gate. While the APU is off (NR52 bit 7 = 0) the hardware
        // ignores writes to every register EXCEPT:
        //   - NR52 ($FF26) itself (used to power back on),
        //   - wave RAM ($FF30-$FF3F), still freely accessible,
        //   - the length-load registers NR11/NR21/NR31/NR41, and only their *length*
        //     portion (the length counters keep running while powered off — this is the
        //     DMG-specific exception blargg's 01/08/11 tests probe).
        // The duty/other bits of NR11/NR21 are NOT writable while off, so we mask.
        if (!self.nr52.audio_on) {
            switch (addr) {
                0xFF26 => {}, // NR52: always writable (power control)
                0xFF30...0xFF3F => {}, // wave RAM: always accessible
                0xFF11 => {
                    self.channel_1.nr11.sound_length = @truncate(byte & 0x3F);
                    self.channel_1.length_timer = 64 - @as(u16, self.channel_1.nr11.sound_length);
                    return;
                },
                0xFF16 => {
                    self.channel_2.nr21.sound_length = @truncate(byte & 0x3F);
                    self.channel_2.length_timer = 64 - @as(u16, self.channel_2.nr21.sound_length);
                    return;
                },
                0xFF1B => {
                    self.channel_3.nr31.initial_length_timer = byte;
                    self.channel_3.length_timer = 256 - @as(u16, byte);
                    return;
                },
                0xFF20 => {
                    self.channel_4.nr41.initial_length_timer = @truncate(byte & 0x3F);
                    self.channel_4.length_timer = 64 - @as(u16, self.channel_4.nr41.initial_length_timer);
                    return;
                },
                else => return,
            }
        }

        switch (addr) {
            0xFF10 => {
                // log.debug("write nr10 {b:0>8}\n", .{byte});
                const was_negate = self.channel_1.nr10.sweep_direction;
                self.channel_1.nr10 = @bitCast(byte);
                // Clearing the negate bit after at least one negate-mode sweep
                // calculation immediately disables the channel (blargg 05 #4).
                if (was_negate and !self.channel_1.nr10.sweep_direction and self.channel_1.sweep_negate_used) {
                    self.channel_1.enabled = false;
                }
            },
            0xFF11 => {
                // log.debug("write nr11 {b:0>8}\n", .{byte});
                // Store the written value as-is. The 0b0011_1111 mask is a READ-side quirk
                // (sound_length bits read back as 1); applying it on WRITE forced sound_length
                // to 63, so any length-enabled note died after one tick (silent SFX, e.g. SML stomp).
                self.channel_1.nr11 = @bitCast(byte);
                // Writing NRx1 reloads the length counter immediately (blargg 02 #3).
                self.channel_1.length_timer = 64 - @as(u16, self.channel_1.nr11.sound_length);
            },
            0xFF12 => {
                // log.debug("write nr12 {b:0>8}\n", .{byte});
                self.channel_1.nr12 = @bitCast(byte);
                // DAC is off when NR12's upper 5 bits are 0 (volume 0, direction down); that
                // disables the channel. Games use this to silence a note (e.g. SML ends its
                // jump sweep with NR12=0) — without it the channel rings until re-triggered.
                if (self.channel_1.nr12.env_initial_volume == 0 and !self.channel_1.nr12.env_direction) {
                    self.channel_1.enabled = false;
                }
            },
            // part of the two part period value, will probably need changes
            0xFF13 => {
                // log.debug("write nr13 {b:0>8}\n", .{byte});
                self.channel_1.nr13 = @bitCast(byte);
                // Keep the live playing frequency in sync with the register (low 8 bits) so
                // mid-note frequency writes take effect without a re-trigger. SML drives its
                // SFX pitch sweeps (jump, stomp) this way rather than via the hardware sweep.
                self.channel_1.frequency = (self.channel_1.frequency & 0x0700) | @as(u16, byte);
            },
            0xFF14 => {
                // log.debug("write nr14 {b:0>8}\n", .{byte});
                const prev_len_en = self.channel_1.nr14.length_enable;
                self.channel_1.nr14 = @bitCast(byte | 0b0011_1000);
                // Sync live frequency high bits (see NR13 note above).
                self.channel_1.frequency = (self.channel_1.frequency & 0x00FF) | (@as(u16, self.channel_1.nr14.period_high) << 8);

                const trigger = self.channel_1.nr14.trigger;
                const len_en = self.channel_1.nr14.length_enable;
                const extra = self.extra_length_clock();

                // Enabling length (0->1) in the extra-clock window clocks length once now.
                if (extra and !prev_len_en and len_en and self.channel_1.length_timer > 0) {
                    self.channel_1.length_timer -= 1;
                    if (self.channel_1.length_timer == 0 and !trigger) self.channel_1.enabled = false;
                }

                if (trigger) {
                    // log.info("TRIGGER write nr14 {b:0>8}\n", .{byte});
                    self.channel_1.enabled = true;
                    self.channel_1.envelope_timer = self.channel_1.nr12.env_sweep_pace;
                    // Trigger reloads a zeroed length counter to max; if length is now
                    // enabled and we're in the extra-clock window it's clocked once more.
                    if (self.channel_1.length_timer == 0) {
                        self.channel_1.length_timer = 64;
                        if (len_en and extra) self.channel_1.length_timer -= 1;
                    }
                    self.channel_1.volume = self.channel_1.nr12.env_initial_volume;
                    self.channel_1._frequency = @as(u16, self.channel_1.nr14.period_high) << 8 | self.channel_1.nr13.period_low;
                    self.channel_1.frequency = self.channel_1._frequency;
                    self.channel_1.shadow_frequency = self.channel_1._frequency;
                    self.channel_1.sweep_timer = if (self.channel_1.nr10.sweep_pace == 0) 8 else self.channel_1.nr10.sweep_pace;
                    self.channel_1.sweep_enable = if (self.channel_1.nr10.sweep_pace > 0 or self.channel_1.nr10.sweep_step > 0) true else false;
                    self.channel_1.sweep_negate_used = false;
                    self.channel_1.timer = (2048 - self.channel_1.frequency) * 4;
                    // On trigger, if the sweep shift is non-zero the overflow check runs
                    // immediately and can disable the channel (blargg 04 #2 / 06).
                    if (self.channel_1.nr10.sweep_step > 0) {
                        _ = self.channel_1.sweep_calculate();
                    }
                    // A trigger only keeps the channel enabled if its DAC is on. With the
                    // DAC off (NR12 upper 5 bits = 0) the channel disables again immediately,
                    // so NR52's status bit reads 0 (blargg 11 subtest #2).
                    if (self.channel_1.nr12.env_initial_volume == 0 and !self.channel_1.nr12.env_direction) {
                        self.channel_1.enabled = false;
                    }
                }
            },
            0xFF15 => {},
            0xFF16 => {
                // See NR11 note: don't OR the length bits on write (read-only quirk).
                self.channel_2.nr21 = @bitCast(byte);
                self.channel_2.length_timer = 64 - @as(u16, self.channel_2.nr21.sound_length);
            },
            0xFF17 => {
                // log.info("write nr22 {b:0>8}\n", .{byte});
                self.channel_2.nr22 = @bitCast(byte);
                // DAC off (upper 5 bits of NR22 zero) disables the channel. See NR12 note.
                if (self.channel_2.nr22.env_initial_volume == 0 and !self.channel_2.nr22.env_direction) {
                    self.channel_2.enabled = false;
                }
            },
            // part of the two part period value, will probably need changes
            0xFF18 => {
                self.channel_2.nr23 = @bitCast(byte);
            },
            0xFF19 => {
                // log.debug("write nr24 {b:0>8}\n", .{byte});
                const prev_len_en = self.channel_2.nr24.length_enable;
                self.channel_2.nr24 = @bitCast(byte | 0b0011_1000);
                const freq = @as(u16, self.channel_2.nr24.period_high) << 8 | self.channel_2.nr23.period_low;

                const trigger = self.channel_2.nr24.trigger;
                const len_en = self.channel_2.nr24.length_enable;
                const extra = self.extra_length_clock();

                if (extra and !prev_len_en and len_en and self.channel_2.length_timer > 0) {
                    self.channel_2.length_timer -= 1;
                    if (self.channel_2.length_timer == 0 and !trigger) self.channel_2.enabled = false;
                }

                if (trigger) {
                    // log.info("TRIGGER write nr24 {b:0>8}\n", .{byte});
                    self.channel_2.enabled = true;
                    if (self.channel_2.length_timer == 0) {
                        self.channel_2.length_timer = 64;
                        if (len_en and extra) self.channel_2.length_timer -= 1;
                    }
                    self.channel_2.volume = self.channel_2.nr22.env_initial_volume;
                    self.channel_2.timer = (2048 - freq) * 4;
                    self.channel_2.envelope_timer = self.channel_2.nr22.env_sweep_pace;
                    // DAC-off trigger leaves the channel disabled (see channel 1 note).
                    if (self.channel_2.nr22.env_initial_volume == 0 and !self.channel_2.nr22.env_direction) {
                        self.channel_2.enabled = false;
                    }
                }
            },
            0xFF1A => {
                self.channel_3.nr30 = @bitCast(byte | 0b0111_1111);
                self.channel_3.dac_enabled = self.channel_3.nr30.dac_on;
                // Turning the DAC off immediately disables the channel (blargg 02 #13).
                if (!self.channel_3.dac_enabled) {
                    self.channel_3.enabled = false;
                }
            },
            0xFF1B => {
                // self.channel_3.nr31 = @bitCast(byte | 0b1111_1111);
                self.channel_3.nr31 = @bitCast(byte);
                self.channel_3.length_timer = 256 - @as(u16, byte);
            },
            0xFF1C => {
                self.channel_3.nr32 = @bitCast(byte | 0b1001_1111);
            },
            0xFF1D => {
                self.channel_3.nr33 = @bitCast(byte);
            },
            0xFF1E => {
                const prev_len_en = self.channel_3.nr34.length_enable;
                const was_playing = self.channel_3.enabled;
                self.channel_3.nr34 = @bitCast(byte | 0b0011_1000);
                const freq = @as(u16, self.channel_3.nr34.period_high) << 8 | self.channel_3.nr33.period_low;

                const trigger = self.channel_3.nr34.trigger;
                const len_en = self.channel_3.nr34.length_enable;
                const extra = self.extra_length_clock();

                if (extra and !prev_len_en and len_en and self.channel_3.length_timer > 0) {
                    self.channel_3.length_timer -= 1;
                    if (self.channel_3.length_timer == 0 and !trigger) self.channel_3.enabled = false;
                }

                if (trigger) {
                    // DMG wave-RAM corruption: re-triggering while the channel is still
                    // playing and exactly 2 ticks from fetching the next byte rewrites the
                    // first bytes of wave RAM (blargg 10).
                    if (was_playing and self.channel_3.timer == 2) {
                        const position: u8 = (self.channel_3.current_sample + 1) & 31;
                        const byte_index: usize = position >> 1;
                        if (position < 8) {
                            self.channel_3.wave_ram.byte[0] = self.channel_3.wave_ram.byte[byte_index];
                        } else {
                            const src: usize = byte_index & 12;
                            var i: usize = 0;
                            while (i < 4) : (i += 1) {
                                self.channel_3.wave_ram.byte[i] = self.channel_3.wave_ram.byte[src + i];
                            }
                        }
                    }

                    // Trigger effects happen regardless of the DAC, but the channel only
                    // actually enables if the DAC is on (blargg 03 #11/#12, 02 #14).
                    self.channel_3.enabled = self.channel_3.dac_enabled;
                    self.channel_3.current_sample = 0;
                    if (self.channel_3.length_timer == 0) {
                        self.channel_3.length_timer = 256;
                        if (len_en and extra) self.channel_3.length_timer -= 1;
                    }
                    // First fetch after trigger is delayed an extra 6 ticks on DMG.
                    self.channel_3.timer = (2048 - freq) * 2 + 6;
                }
            },
            0xFF20 => {
                // See NR11 note: don't OR the length bits on write (read-only quirk).
                self.channel_4.nr41 = @bitCast(byte);
                self.channel_4.length_timer = 64 - @as(u16, self.channel_4.nr41.initial_length_timer);
            },
            0xFF21 => {
                self.channel_4.nr42 = @bitCast(byte);
                // DAC off (upper 5 bits of NR42 zero) disables the channel. See NR12 note.
                if (self.channel_4.nr42.env_initial_volume == 0 and !self.channel_4.nr42.env_direction) {
                    self.channel_4.enabled = false;
                }
            },
            0xFF22 => {
                self.channel_4.nr43 = @bitCast(byte);
            },
            0xFF23 => {
                const prev_len_en = self.channel_4.nr44.length_enable;
                self.channel_4.nr44 = @bitCast(byte | 0b0011_1111);

                const trigger = self.channel_4.nr44.trigger;
                const len_en = self.channel_4.nr44.length_enable;
                const extra = self.extra_length_clock();

                if (extra and !prev_len_en and len_en and self.channel_4.length_timer > 0) {
                    self.channel_4.length_timer -= 1;
                    if (self.channel_4.length_timer == 0 and !trigger) self.channel_4.enabled = false;
                }

                if (trigger) {
                    self.channel_4.enabled = true;
                    self.channel_4.timer = self.channel_4.freq();
                    if (self.channel_4.length_timer == 0) {
                        self.channel_4.length_timer = 64;
                        if (len_en and extra) self.channel_4.length_timer -= 1;
                    }
                    self.channel_4.volume = self.channel_4.nr42.env_initial_volume;
                    self.channel_4.envelope_timer = self.channel_4.nr42.env_sweep_pace;
                    self.channel_4.lsfr = ~@as(u16, 0);
                    // DAC-off trigger leaves the channel disabled (see channel 1 note).
                    if (self.channel_4.nr42.env_initial_volume == 0 and !self.channel_4.nr42.env_direction) {
                        self.channel_4.enabled = false;
                    }
                }
            },
            0xFF24 => {
                self.nr50 = @bitCast(byte);
            },
            0xFF25 => {
                self.nr51 = @bitCast(byte);
            },
            0xFF26 => {
                // NR52 bit 7 = master audio enable. (Was `& 0x80 == 1`, which is always false:
                // `byte & 0x80` is 0 or 0x80, never 1 — so enabling the APU wrongly hit the
                // reset/off path. Bits 0-3 are read-only channel status.)
                const enabled = (byte & 0x80) != 0;
                if (!enabled and self.nr52.audio_on) {
                    // Power off: clear all sound registers (NR10-NR51) and disable.
                    // On DMG the length counters are NOT reset by power-off (blargg 08),
                    // so save/restore them around the register-clearing writes (which
                    // would otherwise reload them via the NRx1 length-load side effect).
                    const l1 = self.channel_1.length_timer;
                    const l2 = self.channel_2.length_timer;
                    const l3 = self.channel_3.length_timer;
                    const l4 = self.channel_4.length_timer;
                    for (0xFF10..0xFF26) |reset_addr| {
                        self.write_apu_register(@truncate(reset_addr), 0);
                    }
                    self.channel_1.length_timer = l1;
                    self.channel_2.length_timer = l2;
                    self.channel_3.length_timer = l3;
                    self.channel_4.length_timer = l4;
                    self.nr52.audio_on = false;
                } else if (enabled and !self.nr52.audio_on) {
                    // Power on (off -> on transition): reset the frame-sequencer phase
                    // to step 0. prev_div_bit is intentionally left as-is so the first
                    // step fires at the next DIV bit-12 falling edge (blargg 07).
                    self.nr52.audio_on = true;
                    self.frame_step = 0;
                    self.channel_1.duty_pos = 0;
                    self.channel_2.duty_pos = 0;
                    self.channel_3.current_sample = 0;
                }
            },
            0xFF30...0xFF3F => {
                const wave_ram_offset = addr - 0xFF30;
                // Mirror the read window: while playing, a write only lands (on the byte
                // being fetched) during the access tick; otherwise it is dropped (blargg 12).
                if (self.channel_3.enabled) {
                    if (self.current_tick == self.channel_3.sample_time) {
                        self.channel_3.wave_ram.byte[self.channel_3.current_sample / 2] = byte;
                    }
                } else {
                    self.channel_3.wave_ram.byte[wave_ram_offset] = byte;
                }
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

    _frequency: u16,
    frequency: u16,
    shadow_frequency: u16,

    timer: u16,
    envelope_timer: u16,
    length_timer: u16,
    sweep_timer: u16,
    sweep_enable: bool,
    // True once a sweep calculation has run in negate (decrease) mode since the
    // last trigger. Clearing NR10's negate bit afterwards disables the channel
    // (blargg 05 #4 "Exiting negate mode after calculation disables channel").
    sweep_negate_used: bool,

    volume: u4,
    duty_pos: u16,

    pub fn new() Channel1 {
        return Channel1{
            .enabled = false,
            .timer = 0,
            .envelope_timer = 0,
            .length_timer = 0,
            .volume = 0,
            .duty_pos = 0,
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
            ._frequency = 0,
            .frequency = 0,
            .shadow_frequency = 0,
            .sweep_timer = 0,
            .sweep_enable = false,
            .sweep_negate_used = false,
        };
    }

    // Sweep frequency calculation + overflow check. Takes the shadow frequency,
    // shifts it right by the sweep shift (NR10 bits 0-2), optionally negates, and
    // sums with the shadow. If the result overflows (> 2047) the channel is
    // disabled. The new frequency is returned but NOT written back here — the
    // caller decides whether to commit it (gbdev "Frequency Sweep").
    fn sweep_calculate(self: *Channel1) u16 {
        const delta: u16 = self.shadow_frequency >> self.nr10.sweep_step;
        const new_freq: u16 = if (self.nr10.sweep_direction)
            self.shadow_frequency -% delta
        else
            self.shadow_frequency +% delta;
        if (self.nr10.sweep_direction) self.sweep_negate_used = true;
        if (new_freq > 2047) {
            self.enabled = false;
        }
        return new_freq;
    }

    // One 128 Hz sweep-unit clock. Decrement the timer; on underflow reload it
    // (period 0 reloads as 8 — blargg 05 "Timer treats period 0 as 8") and, if the
    // sweep is enabled with a non-zero period, run the calculate→write-back→
    // calculate-again sequence. The first calc may disable on overflow; if it
    // survives and the shift is non-zero, the result is committed to the shadow +
    // live frequency (and NR13/NR14) and a second calc runs purely for its overflow
    // check (which can still disable the channel).
    fn sweep_clock(self: *Channel1) void {
        if (self.sweep_timer > 0) self.sweep_timer -= 1;
        if (self.sweep_timer != 0) return;

        self.sweep_timer = if (self.nr10.sweep_pace == 0) 8 else self.nr10.sweep_pace;

        if (self.sweep_enable and self.nr10.sweep_pace > 0) {
            const new_freq = self.sweep_calculate();
            if (new_freq <= 2047 and self.nr10.sweep_step > 0) {
                self.shadow_frequency = new_freq;
                self.frequency = new_freq;
                self.nr13.period_low = @truncate(new_freq & 0xFF);
                self.nr14.period_high = @truncate((new_freq >> 8) & 0x7);
                // Second calculation — overflow check only, result discarded.
                _ = self.sweep_calculate();
            }
        }
    }

    // Clock the length counter (called on frame-sequencer length steps regardless
    // of whether the channel is enabled — blargg 02 #11). When it reaches zero the
    // channel is disabled.
    fn clock_length(self: *Channel1) void {
        if (self.nr14.length_enable and self.length_timer > 0) {
            self.length_timer -= 1;
            if (self.length_timer == 0) self.enabled = false;
        }
    }

    pub fn step(self: *Channel1, apu: *APU) f32 {
        // log.debug("in ch1.step", .{});
        if (!self.enabled) {
            return 0;
        }

        // log.debug("enabled ch1 step", .{});
        // log.debug("before self.duty_pos = {}", .{self.ch1_duty_pos});
        self.timer -%= 1;
        if (self.timer == 0) {
            self.timer = (2048 - self.frequency) * 4;
            self.duty_pos = (self.duty_pos + 1) % 8;
        }
        // log.debug("after self.duty_pos = {}", .{self.ch1_duty_pos});

        // tune by volume?
        const amp = DutyCycles[self.nr11.wave_pattern_duty][self.duty_pos];

        // log.debug("DutyCycles[{}][{}] = {}", .{
        //     .duty = self.nr11.wave_pattern_duty,
        //     .pos = self.ch1_duty_pos,
        //     .amp = amp,
        // });

        if (apu.envelope_step and self.nr12.env_sweep_pace != 0) {
            log.debug("envelope_timer {}", .{self.envelope_timer});
            if (self.envelope_timer > 0) self.envelope_timer -= 1;
            if (self.envelope_timer == 0) {
                self.envelope_timer = self.nr12.env_sweep_pace;
                if (self.nr12.env_direction and self.volume != 0xF) {
                    self.volume += 1;
                    log.debug("volume increase {}", .{self.volume});
                }
                if (!self.nr12.env_direction and self.volume != 0x0) {
                    self.volume -= 1;
                    log.debug("volume decrease {}", .{self.volume});
                }
            }
        }

        if (apu.sweep_step) {
            self.sweep_clock();
        }

        return dac_volume_convert(amp * self.volume);
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

    fn clock_length(self: *Channel2) void {
        if (self.nr24.length_enable and self.length_timer > 0) {
            self.length_timer -= 1;
            if (self.length_timer == 0) self.enabled = false;
        }
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

        if (apu.envelope_step and self.nr22.env_sweep_pace != 0) {
            if (self.envelope_timer > 0) self.envelope_timer -= 1;
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
    // Absolute APU tick at which the wave unit last fetched a byte. On DMG the CPU
    // can only see/alter wave RAM on that exact tick (blargg 09/10/12).
    sample_time: u64,

    wave_ram: WaveRam,

    pub fn new() Channel3 {
        return Channel3{
            .enabled = false,
            .current_sample = 0,
            .timer = 0,
            .length_timer = 0,
            .dac_enabled = false,
            .sample_time = 0,
            .wave_ram = WaveRam{
                .byte = @splat(0),
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

    fn clock_length(self: *Channel3) void {
        if (self.nr34.length_enable and self.length_timer > 0) {
            self.length_timer -= 1;
            if (self.length_timer == 0) self.enabled = false;
        }
    }

    pub fn step(self: *Channel3, apu: *APU) f32 {
        // log.debug("in ch1.step", .{});
        if (!self.enabled) {
            return 0;
        }

        const freq: u16 = @as(u16, self.nr34.period_high) << 8 | @as(u16, self.nr33.period_low);
        const initial_freq = (2048 - freq) * 2;
        // const initial_freq = (2048 - freq);
        self.timer -%= 1;
        if (self.timer == 0) {
            self.timer = initial_freq;
            self.current_sample = (self.current_sample + 1) % 32;
            // Mark the tick of this wave-RAM fetch — the only moment a CPU access
            // to wave RAM lands on the byte being played (DMG access window).
            self.sample_time = apu.current_tick;
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

    fn clock_length(self: *Channel4) void {
        if (self.nr44.length_enable and self.length_timer > 0) {
            self.length_timer -= 1;
            if (self.length_timer == 0) self.enabled = false;
        }
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

        if (apu.envelope_step and self.nr42.env_sweep_pace != 0) {
            // log.debug("envelope_step = {} env_sweep_pace = {}", .{ apu.envelope_step, self.nr42.env_sweep_pace });
            if (self.envelope_timer > 0) self.envelope_timer -= 1;
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
    if (have_sdl) {
        const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";
        @panic(std.mem.sliceTo(str, 0));
    } else {
        @panic("SDL not available (wasm build)");
    }
}

fn dac_volume_convert(amp: u4) f32 {
    const normalized_value = @as(f32, @floatFromInt(amp)) / 15.0; // Normalize to 0.0 - 1.0 range
    return (normalized_value * 2.0) - 1.0; // Scale to -1.0 - 1.0 range
}
// fn dac_volume_convert(amp: u4) f32 {
//     return (@as(f32, @floatFromInt(amp)) / 7.5) - 1.0;
// }
