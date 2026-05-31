//! No-op stand-in for the `sdl2` import.
//!
//! The real SDL2 binding (lib/SDL.zig) can't build on newer Zig releases, and
//! the user asked to defer resolving the SDL dependency until the toolchain is
//! at latest. SDL only drives audio/video *output* and input polling — it never
//! feeds back into emulation state (see gameboy.frame(): apu.sdl_total_ticks is
//! stored but never read). So swapping the real binding for this stub lets the
//! whole project build on any Zig version while leaving emulation bit-for-bit
//! identical. The headless harness exercises the emulator core with this stub.
//!
//! Every declaration here mirrors exactly the surface that apu.zig and draw.zig
//! consume; functions are no-ops that return benign values.

// ---- Opaque resource handles ----
pub const SDL_Window = opaque {};
pub const SDL_Renderer = opaque {};
pub const SDL_Texture = opaque {};

// ---- Init / lifecycle ----
pub const SDL_INIT_AUDIO: u32 = 0x00000010;
pub const SDL_INIT_VIDEO: u32 = 0x00000020;
pub const SDL_INIT_EVENTS: u32 = 0x00004000;

pub fn SDL_Init(flags: u32) c_int {
    _ = flags;
    return 0;
}
pub fn SDL_Quit() void {}

pub fn SDL_GetError() ?[*:0]const u8 {
    return "sdl_stub: no error";
}

// ---- Audio ----
pub const SDL_AudioFormat = u16;
pub const AUDIO_F32SYS: SDL_AudioFormat = 0x8120;
pub const SDL_AudioDeviceID = u32;

pub const SDL_AudioSpec = extern struct {
    freq: c_int = 0,
    format: SDL_AudioFormat = 0,
    channels: u8 = 0,
    silence: u8 = 0,
    samples: u16 = 0,
    padding: u16 = 0,
    size: u32 = 0,
    callback: ?*const anyopaque = null,
    userdata: ?*anyopaque = null,
};

pub fn SDL_OpenAudioDevice(
    device: ?[*:0]const u8,
    iscapture: c_int,
    desired: *const SDL_AudioSpec,
    obtained: ?*SDL_AudioSpec,
    allowed_changes: c_int,
) SDL_AudioDeviceID {
    _ = device;
    _ = iscapture;
    _ = desired;
    _ = obtained;
    _ = allowed_changes;
    return 1; // a non-zero, "valid" device id
}

pub fn SDL_PauseAudioDevice(dev: SDL_AudioDeviceID, pause_on: c_int) void {
    _ = dev;
    _ = pause_on;
}

pub fn SDL_GetAudioDeviceStatus(dev: SDL_AudioDeviceID) c_int {
    _ = dev;
    return 0;
}

pub fn SDL_GetQueuedAudioSize(dev: SDL_AudioDeviceID) u32 {
    _ = dev;
    return 0; // never makes the producer wait
}

pub fn SDL_QueueAudio(dev: SDL_AudioDeviceID, data: *const anyopaque, len: u32) c_int {
    _ = dev;
    _ = data;
    _ = len;
    return 0;
}

pub fn SDL_Delay(ms: u32) void {
    _ = ms;
}

pub fn SDL_GetTicks() u32 {
    return 0;
}

// ---- Window / renderer / texture ----
pub const SDL_WINDOWPOS_CENTERED: c_int = 0x2FFF0000;
pub const SDL_WINDOW_SHOWN: u32 = 0x00000004;
pub const SDL_WINDOW_RESIZABLE: u32 = 0x00000020;
pub const SDL_RENDERER_ACCELERATED: u32 = 0x00000002;

pub const SDL_PIXELFORMAT_RGB24: u32 = 0x17101803;
pub const SDL_PIXELFORMAT_RGB888: u32 = 0x16161804;
pub const SDL_TEXTUREACCESS_STREAMING: c_int = 1;
pub const SDL_ScaleModeNearest: c_int = 0;

pub const SDL_HINT_RENDER_SCALE_QUALITY: [*c]const u8 = "SDL_RENDER_SCALE_QUALITY";

pub fn SDL_CreateWindow(
    title: [*c]const u8,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    flags: u32,
) ?*SDL_Window {
    _ = title;
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = flags;
    return null;
}
pub fn SDL_DestroyWindow(window: ?*SDL_Window) void {
    _ = window;
}
pub fn SDL_SetWindowTitle(window: ?*SDL_Window, title: [*c]const u8) void {
    _ = window;
    _ = title;
}

pub fn SDL_CreateRenderer(window: ?*SDL_Window, index: c_int, flags: u32) ?*SDL_Renderer {
    _ = window;
    _ = index;
    _ = flags;
    return null;
}
pub fn SDL_DestroyRenderer(renderer: ?*SDL_Renderer) void {
    _ = renderer;
}
pub fn SDL_RenderClear(renderer: ?*SDL_Renderer) c_int {
    _ = renderer;
    return 0;
}
pub fn SDL_RenderCopy(
    renderer: ?*SDL_Renderer,
    texture: ?*SDL_Texture,
    srcrect: ?*const anyopaque,
    dstrect: ?*const anyopaque,
) c_int {
    _ = renderer;
    _ = texture;
    _ = srcrect;
    _ = dstrect;
    return 0;
}
pub fn SDL_RenderPresent(renderer: ?*SDL_Renderer) void {
    _ = renderer;
}

pub fn SDL_CreateTexture(
    renderer: ?*SDL_Renderer,
    format: u32,
    access: c_int,
    w: c_int,
    h: c_int,
) ?*SDL_Texture {
    _ = renderer;
    _ = format;
    _ = access;
    _ = w;
    _ = h;
    return null;
}
pub fn SDL_DestroyTexture(texture: ?*SDL_Texture) void {
    _ = texture;
}
pub fn SDL_SetTextureScaleMode(texture: ?*SDL_Texture, scaleMode: c_int) c_int {
    _ = texture;
    _ = scaleMode;
    return 0;
}
pub fn SDL_UpdateTexture(
    texture: ?*SDL_Texture,
    rect: ?*const anyopaque,
    pixels: *const anyopaque,
    pitch: c_int,
) c_int {
    _ = texture;
    _ = rect;
    _ = pixels;
    _ = pitch;
    return 0;
}

pub fn SDL_SetHint(name: [*c]const u8, value: [*c]const u8) c_int {
    _ = name;
    _ = value;
    return 0;
}

// ---- Events / input ----
pub const SDL_QUIT: u32 = 0x100;
pub const SDL_KEYDOWN: u32 = 0x300;
pub const SDL_KEYUP: u32 = 0x301;
pub const SDL_MOUSEBUTTONUP: u32 = 0x402;

pub const SDLK_RETURN: c_int = '\r';
pub const SDLK_ESCAPE: c_int = 27;
pub const SDLK_TAB: c_int = '\t';
pub const SDLK_QUOTE: c_int = '\'';
pub const SDLK_a: c_int = 'a';
pub const SDLK_d: c_int = 'd';
pub const SDLK_j: c_int = 'j';
pub const SDLK_k: c_int = 'k';
pub const SDLK_m: c_int = 'm';
pub const SDLK_p: c_int = 'p';
pub const SDLK_s: c_int = 's';
pub const SDLK_w: c_int = 'w';

pub const SDL_Keysym = extern struct {
    scancode: c_int = 0,
    sym: c_int = 0,
    mod: u16 = 0,
    unused: u32 = 0,
};
pub const SDL_KeyboardEvent = extern struct {
    type: u32 = 0,
    timestamp: u32 = 0,
    windowID: u32 = 0,
    state: u8 = 0,
    repeat: u8 = 0,
    padding2: u8 = 0,
    padding3: u8 = 0,
    keysym: SDL_Keysym = .{},
};
pub const SDL_Event = extern union {
    type: u32,
    key: SDL_KeyboardEvent,
    padding: [56]u8,
};

pub fn SDL_PollEvent(event: *SDL_Event) c_int {
    _ = event;
    return 0; // no events; main loop's event drain is a no-op
}
