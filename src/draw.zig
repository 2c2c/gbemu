const std = @import("std");
const SDL = @import("sdl2");
const gpu = @import("gpu.zig");
const CPU = @import("cpu.zig").CPU;

const ArenaAllocator = std.heap.ArenaAllocator;
const expect = std.testing.expect;
const test_allocator = std.testing.allocator;

pub fn setup_cpu() !CPU {
    const file = try std.fs.cwd().openFile("tetris.gb", .{});
    // const file = try std.fs.cwd().openFile("./02-interrupts.gb", .{});
    // const file = try std.fs.cwd().openFile("./03-op sp,hl.gb", .{});
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

// pub fn random_main() !void {
//     if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0)
//         sdlPanic();
//     defer SDL.SDL_Quit();
//
//     const WIDTH = 160;
//     const HEIGHT = 144;
//     const SCALE = 1;
//
//     // _ = SDL.SDL_SetHint(SDL.SDL_HINT_RENDER_SCALE_QUALITY, "linear");
//     const window = SDL.SDL_CreateWindow(
//         "SDL2 Native Demo",
//         SDL.SDL_WINDOWPOS_CENTERED,
//         SDL.SDL_WINDOWPOS_CENTERED,
//         WIDTH * SCALE,
//         HEIGHT * SCALE,
//         SDL.SDL_WINDOW_SHOWN | SDL.SDL_WINDOW_RESIZABLE,
//     ) orelse sdlPanic();
//
//     defer _ = SDL.SDL_DestroyWindow(window);
//     var prng = std.rand.DefaultPrng.init(blk: {
//         var seed: u64 = undefined;
//         try std.posix.getrandom(std.mem.asBytes(&seed));
//         break :blk seed;
//     });
//     const rand = prng.random();
//
//     const renderer = SDL.SDL_CreateRenderer(window, -1, SDL.SDL_RENDERER_ACCELERATED) orelse sdlPanic();
//     defer _ = SDL.SDL_DestroyRenderer(renderer);
//
//     const texture = SDL.SDL_CreateTexture(
//         renderer,
//         SDL.SDL_PIXELFORMAT_RGB888,
//         SDL.SDL_TEXTUREACCESS_TARGET,
//         WIDTH * SCALE,
//         HEIGHT * SCALE,
//     ) orelse sdlPanic();
//     defer SDL.SDL_DestroyTexture(texture);
//
//     mainLoop: while (true) {
//         var ev: SDL.SDL_Event = undefined;
//         while (SDL.SDL_PollEvent(&ev) != 0) {
//             if (ev.type == SDL.SDL_QUIT)
//                 break :mainLoop;
//             // if (ev.type == SDL.SDL_WINDOWEVENT and ev.window.event == SDL.SDL_WINDOWEVENT_RESIZED) {
//             //     const width = ev.window.data1;
//             //     const height = ev.window.data2;
//             //     _ = SDL.SDL_RenderSetLogicalSize(renderer, width, height);
//             // }
//         }
//         // Create array of 160x144 pixels with random rgb colors
//         var pixels: [WIDTH * HEIGHT * SCALE]gpu.TilePixelValue = undefined;
//         for (pixels, 0..) |_, index| {
//             const tile_pixel = rand.enumValue(gpu.TilePixelValue);
//             pixels[index] = tile_pixel;
//         }
//
//         _ = SDL.SDL_SetRenderTarget(renderer, texture);
//         // Render the array of pixels
//         for (0..HEIGHT * SCALE) |y| {
//             for (0..WIDTH * SCALE) |x| {
//                 const index = y * WIDTH + x;
//                 const r = pixels[index].to_color();
//                 const g = pixels[index].to_color();
//                 const b = pixels[index].to_color();
//                 std.debug.print("rgb: 0x{x:0>2}{x:0>2}{x:0>2}\n", .{ r, g, b });
//
//                 // SDL.SDL_GetRGB(pixels[index], SDL.SDL_AllocFormat(SDL.SDL_PIXELFORMAT_RGB888), &r, &g, &b);
//                 _ = SDL.SDL_SetRenderDrawColor(renderer, r, g, b, 0xFF);
//                 _ = SDL.SDL_RenderDrawPoint(renderer, @intCast(x), @intCast(y));
//             }
//         }
//
//         _ = SDL.SDL_SetRenderTarget(renderer, null);
//         _ = SDL.SDL_RenderClear(renderer);
//         _ = SDL.SDL_RenderCopy(renderer, texture, null, null);
//
//         // Update screen
//         SDL.SDL_RenderPresent(renderer);
//         // std.time.sleep(16 * std.time.ns_per_ms);
//     }
//
//
//
//

pub fn main() !void {
    if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0)
        sdlPanic();
    defer SDL.SDL_Quit();

    const WIDTH = 160;
    const HEIGHT = 144;
    const SCALE = 1;

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

    const texture = SDL.SDL_CreateTexture(
        renderer,
        SDL.SDL_PIXELFORMAT_RGB888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        WIDTH * SCALE,
        HEIGHT * SCALE,
    ) orelse sdlPanic();
    defer SDL.SDL_DestroyTexture(texture);

    var cpu = try setup_cpu();

    mainLoop: while (true) {
        var ev: SDL.SDL_Event = undefined;
        while (SDL.SDL_PollEvent(&ev) != 0) {
            if (ev.type == SDL.SDL_QUIT)
                break :mainLoop;
        }

        cpu.step();
        _ = SDL.SDL_UpdateTexture(texture, null, &cpu.bus.gpu.canvas, WIDTH * SCALE * 3);

        _ = SDL.SDL_RenderClear(renderer);
        _ = SDL.SDL_RenderCopy(renderer, texture, null, null);
        SDL.SDL_RenderPresent(renderer);

        std.time.sleep(0 * std.time.ns_per_ms); // 60 FPS
    }
}

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}

test "random numbers" {
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    const a = rand.float(f32);
    const b = rand.boolean();
    const c = rand.int(u8);
    const d = rand.intRangeAtMost(u8, 0, 255);

    //suppress unused constant compile error
    _ = .{ a, b, c, d };
}
