const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const Gameboy = @import("gameboy.zig").Gameboy;
const draw = @import("draw.zig");

const ArenaAllocator = std.heap.ArenaAllocator;
const expect = std.testing.expect;

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .gb, .level = .info },
        .{ .scope = .cpu, .level = .info },
        .{ .scope = .gpu, .level = .info },
        .{ .scope = .apu, .level = .debug },
        .{ .scope = .mbc, .level = .info },
        .{ .scope = .timer, .level = .info },
        .{ .scope = .joy, .level = .info },
        .{ .scope = .bus, .level = .info },
    },
    // .log_scope_levels = &[_]std.log.ScopeLevel{
    //     .{ .scope = .gb, .level = .err },
    //     .{ .scope = .cpu, .level = .err },
    //     .{ .scope = .gpu, .level = .err },
    //     .{ .scope = .apu, .level = .err },
    //     .{ .scope = .mbc, .level = .err },
    //     .{ .scope = .timer, .level = .err },
    //     .{ .scope = .joy, .level = .err },
    //     .{ .scope = .bus, .level = .err },
    // },
};

// Zig 0.16+ hands the program a `std.process.Init` providing io, allocators,
// and command-line args (std.process.argsAlloc was removed).
pub fn main(init: std.process.Init) !void {
    // try headless_main(init);
    try draw_main(init);
}

pub fn headless_main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| {
        std.debug.print("{s}\n", .{arg});
    }

    const filename = args[1];
    var gb = try Gameboy.new(filename, init.io, allocator);
    while (true) {
        gb.frame();
    }
}

pub fn draw_main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| {
        std.debug.print("{s}\n", .{arg});
    }

    const filename = args[1];

    try draw.main(filename, init.io, allocator);
}

test {
    // Zig 0.16 removed refAllDeclsRecursive.
    std.testing.refAllDecls(@This());
}
