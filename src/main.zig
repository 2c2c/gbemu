const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const Gameboy = @import("gameboy.zig").Gameboy;
const draw = @import("draw.zig");

const ArenaAllocator = std.heap.ArenaAllocator;
const expect = std.testing.expect;

pub const std_options: std.Options = .{
    // .log_level = std.log.Level.info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .gb, .level = .info },
        .{ .scope = .cpu, .level = .debug },
        .{ .scope = .gpu, .level = .info },
        .{ .scope = .mbc, .level = .info },
        .{ .scope = .timer, .level = .info },
        .{ .scope = .joy, .level = .info },
        .{ .scope = .bus, .level = .info },
    },
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
