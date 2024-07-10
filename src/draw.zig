const std = @import("std");
const SDL = @import("sdl2");
const gpu = @import("gpu.zig");
const CPU = @import("cpu.zig").CPU;
const time = @import("std").time;

const ArenaAllocator = std.heap.ArenaAllocator;
const expect = std.testing.expect;
const test_allocator = std.testing.allocator;

const CPU_SPEED_HZ = 4194304;

pub fn setup_cpu() !CPU {
    const file = try std.fs.cwd().openFile("dmg-acid2.gb", .{});
    // const file = try std.fs.cwd().openFile("tetris.gb", .{});
    // const file = try std.fs.cwd().openFile("instr_timing.gb", .{});
    // const file = try std.fs.cwd().openFile("./02-interrupts.gb", .{});
    // const file = try std.fs.cwd().openFile("./03-op sp,hl.gb", .{});
    // const file = try std.fs.cwd().openFile("cpu_instrs.gb", .{});
    // const file = try std.fs.cwd().openFile("flappy_boy.gb", .{});
    // const file = try std.fs.cwd().openFile("Pokemon Blue.gb", .{});
    // vid roms
    //
    // const file = try std.fs.cwd().openFile("lycscx.gb", .{});
    // const file = try std.fs.cwd().openFile("lycscy.gb", .{});
    // const file = try std.fs.cwd().openFile("palettely.gb", .{});
    // const file = try std.fs.cwd().openFile("scxly.gb", .{});
    // const file = try std.fs.cwd().openFile("statcount.gb", .{});
    // const file = try std.fs.cwd().openFile("statcount-auto.gb", .{});
    // const file = try std.fs.cwd().openFile("winpos.gb", .{});
    // const file = try std.fs.cwd().openFile("Pokemon Blue.gb", .{});
    // const file = try std.fs.cwd().openFile("Pokemon Blue.gb", .{});
    defer file.close();

    const size = try file.getEndPos();

    var arena_allocator = ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    const game_rom = try allocator.alloc(u8, size);
    defer allocator.free(game_rom);
    _ = try file.readAll(game_rom);

    // for (game_rom) |rom| {
    //     std.debug.print("0x{x}\n", .{rom});
    // }

    const cpu = CPU.new(game_rom);
    return cpu;
}

const WIDTH = 160;
const HEIGHT = 144;
const SCALE = 1;

pub fn main() !void {
    if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0)
        sdlPanic();
    defer SDL.SDL_Quit();

    const window = SDL.SDL_CreateWindow(
        "SDL2 Native Demo",
        SDL.SDL_WINDOWPOS_CENTERED,
        SDL.SDL_WINDOWPOS_CENTERED,
        WIDTH * SCALE,
        HEIGHT * SCALE,
        SDL.SDL_WINDOW_SHOWN | SDL.SDL_WINDOW_RESIZABLE,
    ) orelse sdlPanic();
    defer _ = SDL.SDL_DestroyWindow(window);

    const renderer = SDL.SDL_CreateRenderer(window, -1, SDL.SDL_RENDERER_ACCELERATED) orelse sdlPanic();
    defer _ = SDL.SDL_DestroyRenderer(renderer);

    _ = SDL.SDL_SetHint(SDL.SDL_HINT_RENDER_SCALE_QUALITY, "0");

    const texture = SDL.SDL_CreateTexture(
        renderer,
        SDL.SDL_PIXELFORMAT_RGB24,
        // fuck u
        // SDL.SDL_PIXELFORMAT_RGB888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        WIDTH * SCALE,
        HEIGHT * SCALE,
    ) orelse sdlPanic();
    defer SDL.SDL_DestroyTexture(texture);
    _ = SDL.SDL_SetTextureScaleMode(texture, SDL.SDL_ScaleModeNearest);

    var cpu = try setup_cpu();

    var frame: usize = 0;
    mainLoop: while (true) {
        var ev: SDL.SDL_Event = undefined;
        while (SDL.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                SDL.SDL_QUIT => break :mainLoop,
                SDL.SDL_MOUSEBUTTONUP => {},
                SDL.SDL_KEYDOWN, SDL.SDL_KEYUP => {
                    const key = ev.key.keysym.sym;
                    const is_pressed = ev.key.state == SDL.SDL_KEYDOWN;
                    switch (key) {
                        SDL.SDLK_w => cpu.bus.joypad.dpad.pressed.UP = is_pressed,
                        SDL.SDLK_a => cpu.bus.joypad.dpad.pressed.LEFT = is_pressed,
                        SDL.SDLK_s => cpu.bus.joypad.dpad.pressed.DOWN = is_pressed,
                        SDL.SDLK_d => cpu.bus.joypad.dpad.pressed.RIGHT = is_pressed,
                        SDL.SDLK_j => cpu.bus.joypad.button.pressed.A = is_pressed,
                        SDL.SDLK_k => cpu.bus.joypad.button.pressed.B = is_pressed,
                        SDL.SDLK_RETURN => cpu.bus.joypad.button.pressed.START = is_pressed,
                        SDL.SDLK_QUOTE => cpu.bus.joypad.button.pressed.SELECT = is_pressed,
                        SDL.SDLK_ESCAPE => break,
                        else => {},
                    }
                },
                else => {},
            }
        }

        // while (true) {

        // todo
        // using cycles simulate 1/60th of a second of cycles, then sleep for the extra time
        // left
        // const start = time.nanoTimestamp();
        for (0..20000) |_| {
            cpu.frame_walk();
            frame += 1;
            std.time.sleep(10000); // 60 FPS
        }
        frame = 0;

        // if (frame % 70224 == 0) {
        //     print_canvas(&cpu);
        //     frame = 0;
        // }
        _ = SDL.SDL_UpdateTexture(texture, null, &cpu.bus.gpu.canvas, WIDTH * SCALE * 3);

        _ = SDL.SDL_RenderClear(renderer);
        _ = SDL.SDL_RenderCopy(renderer, texture, null, null);
        SDL.SDL_RenderPresent(renderer);

        std.time.sleep(4 * std.time.ns_per_ms); // 60 FPS
    }
}

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}

fn print_canvas(cpu: *CPU) void {
    // print the canvas to scale as hex bytes as 2d grid
    //
    for (0..HEIGHT) |y| {
        for (0..WIDTH) |x| {
            std.debug.print("0x{x:0>2}{x:0>2}{x:0>2}", .{
                cpu.bus.gpu.canvas[y * x + 0],
                cpu.bus.gpu.canvas[y * x + 1],
                cpu.bus.gpu.canvas[y * x + 2],
            });
        }
        std.debug.print("\n", .{});
    }
}
