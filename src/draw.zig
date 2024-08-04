const std = @import("std");
const SDL = @import("sdl2");
const gpu = @import("gpu.zig");
const cpu = @import("cpu.zig");
const apu = @import("apu.zig");
const time = @import("std").time;

const CPU = cpu.CPU;
const Gameboy = @import("gameboy.zig").Gameboy;

const ArenaAllocator = std.heap.ArenaAllocator;
const expect = std.testing.expect;
const test_allocator = std.testing.allocator;

const CPU_SPEED_HZ = 4194304;

const SCALE = 3;

pub fn main(filename: []u8, alloc: std.mem.Allocator) !void {
    var gb = try Gameboy.new(filename, alloc);
    defer gb.deinit();

    if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0)
        sdlPanic();
    defer SDL.SDL_Quit();

    const window = SDL.SDL_CreateWindow(
        "SDL2 Native Demo",
        SDL.SDL_WINDOWPOS_CENTERED,
        SDL.SDL_WINDOWPOS_CENTERED,
        gpu.DRAW_WIDTH * SCALE,
        gpu.DRAW_HEIGHT * SCALE,
        SDL.SDL_WINDOW_SHOWN | SDL.SDL_WINDOW_RESIZABLE,
    ) orelse sdlPanic();
    defer _ = SDL.SDL_DestroyWindow(window);

    const renderer = SDL.SDL_CreateRenderer(window, -1, SDL.SDL_RENDERER_ACCELERATED) orelse sdlPanic();
    defer _ = SDL.SDL_DestroyRenderer(renderer);

    _ = SDL.SDL_SetHint(SDL.SDL_HINT_RENDER_SCALE_QUALITY, "0");

    const texture = SDL.SDL_CreateTexture(
        renderer,
        SDL.SDL_PIXELFORMAT_RGB24,
        // SDL.SDL_PIXELFORMAT_RGB888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        gpu.DRAW_WIDTH,
        gpu.DRAW_HEIGHT,
    ) orelse sdlPanic();
    defer SDL.SDL_DestroyTexture(texture);
    _ = SDL.SDL_SetTextureScaleMode(texture, SDL.SDL_ScaleModeNearest);

    const title = try alloc.alloc(u8, 256);
    defer alloc.free(title);

    var frame: u128 = 0;

    mainLoop: while (true) {
        // var timer = try std.time.Timer.start();
        var ev: SDL.SDL_Event = undefined;
        while (SDL.SDL_PollEvent(&ev) > 0) {
            switch (ev.type) {
                SDL.SDL_QUIT => break :mainLoop,
                SDL.SDL_MOUSEBUTTONUP => {},
                SDL.SDL_KEYDOWN => {
                    const key = ev.key.keysym.sym;
                    const is_pressed = ev.type == SDL.SDL_KEYDOWN;
                    // std.debug.print("Key down event: {d} pressed\n", .{key});
                    switch (key) {
                        SDL.SDLK_w => gb.joypad.dpad.pressed.UP = is_pressed,
                        SDL.SDLK_a => gb.joypad.dpad.pressed.LEFT = is_pressed,
                        SDL.SDLK_s => gb.joypad.dpad.pressed.DOWN = is_pressed,
                        SDL.SDLK_d => gb.joypad.dpad.pressed.RIGHT = is_pressed,
                        SDL.SDLK_j => gb.joypad.button.pressed.A = is_pressed,
                        SDL.SDLK_k => gb.joypad.button.pressed.B = is_pressed,
                        SDL.SDLK_RETURN => gb.joypad.button.pressed.START = is_pressed,
                        SDL.SDLK_QUOTE => gb.joypad.button.pressed.SELECT = is_pressed,
                        SDL.SDLK_ESCAPE => break :mainLoop,
                        else => {},
                    }
                },
                SDL.SDL_KEYUP => {
                    const key = ev.key.keysym.sym;
                    const is_pressed = ev.type == SDL.SDL_KEYDOWN;
                    // std.debug.print("Key up event: {d} released\n", .{key});
                    switch (key) {
                        SDL.SDLK_w => gb.joypad.dpad.pressed.UP = is_pressed,
                        SDL.SDLK_a => gb.joypad.dpad.pressed.LEFT = is_pressed,
                        SDL.SDLK_s => gb.joypad.dpad.pressed.DOWN = is_pressed,
                        SDL.SDLK_d => gb.joypad.dpad.pressed.RIGHT = is_pressed,
                        SDL.SDLK_j => gb.joypad.button.pressed.A = is_pressed,
                        SDL.SDLK_k => gb.joypad.button.pressed.B = is_pressed,
                        SDL.SDLK_RETURN => gb.joypad.button.pressed.START = is_pressed,
                        SDL.SDLK_QUOTE => gb.joypad.button.pressed.SELECT = is_pressed,
                        SDL.SDLK_ESCAPE => break :mainLoop,
                        else => {},
                    }
                },
                else => {},
            }
        }

        gb.frame();
        frame += 1;

        // std.debug.print("frame_cycles {} timer {} \n", .{ frame_cycles, timer.read() / std.time.ms_per_s });

        _ = std.fmt.bufPrintZ(title, "Frame {} | Seconds {}", .{ frame, frame / 60 }) catch unreachable;
        SDL.SDL_SetWindowTitle(window, title.ptr);
        _ = SDL.SDL_UpdateTexture(texture, null, &gb.gpu.canvas, gpu.DRAW_WIDTH * 3);

        _ = SDL.SDL_RenderClear(renderer);
        _ = SDL.SDL_RenderCopy(renderer, texture, null, null);
        SDL.SDL_RenderPresent(renderer);
        // const hz_60_nanos: u64 = std.time.ns_per_s / 60;
        // while (timer.read() < hz_60_nanos) {}
    }
}

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}

test "test" {
    const hz_60_micros: u64 = 60 * 16667;
    const start_us = std.time.microTimestamp();
    std.debug.print("start\n", .{});
    while (true) {
        const time_diff = std.time.microTimestamp() - start_us;
        if (time_diff >= hz_60_micros) {
            break;
        }
    }
    std.debug.print("end\n", .{});
}
