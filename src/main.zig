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

pub fn main() !void {
    // try headless_main();
    try draw_main();
}

pub fn headless_main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args) |arg| {
        std.debug.print("{s}\n", .{arg});
    }

    const filename = args[1];
    var gb = try Gameboy.new(filename, allocator);
    while (true) {
        _ = gb.frame();
    }
}

pub fn draw_main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args) |arg| {
        std.debug.print("{s}\n", .{arg});
    }

    const filename = args[1];

    try draw.main(filename, allocator);
}

test {
    std.testing.refAllDeclsRecursive(@This());
    // or refAllDeclsRecursive
}
