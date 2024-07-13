const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const draw = @import("draw.zig");

const ArenaAllocator = std.heap.ArenaAllocator;
const expect = std.testing.expect;
const test_allocator = std.testing.allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args) |arg| {
        std.debug.print("{s}\n", .{arg});
    }

    const filename = args[1];

    try draw.main(filename);
}

pub fn cpumain() !void {
    // const file = try std.fs.cwd().openFile("tetris.gb", .{});
    // pass
    // const file = try std.fs.cwd().openFile("./01-special.gb", .{});
    // const file = try std.fs.cwd().openFile("./02-interrupts.gb", .{});
    // const file = try std.fs.cwd().openFile("./03-op sp,hl.gb", .{});
    // const file = try std.fs.cwd().openFile("./04-op r,imm.gb", .{});
    // const file = try std.fs.cwd().openFile("./05-op rp.gb", .{});
    // const file = try std.fs.cwd().openFile("./06-ld r,r.gb", .{});
    // const file = try std.fs.cwd().openFile("./07-jr,jp,call,ret,rst.gb", .{});
    // const file = try std.fs.cwd().openFile("./08-misc instrs.gb", .{});
    // const file = try std.fs.cwd().openFile("./09-op r,r.gb", .{});
    // const file = try std.fs.cwd().openFile("./10-bit ops.gb", .{});
    // const file = try std.fs.cwd().openFile("./11-op a,(hl).gb", .{});
    const file = try std.fs.cwd().openFile("cpu_instrs.gb", .{});
    // const file = try std.fs.cwd().openFile("test_rom.gb", .{});
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

    var cpu = try CPU.new(game_rom);
    while (true) {
        cpu.frame_walk();
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
    // or refAllDeclsRecursive
}
