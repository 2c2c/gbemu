const std = @import("std");
const CPU = @import("cpu.zig").CPU;

const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const expect = std.testing.expect;
const eql = std.mem.eql;
const test_allocator = std.testing.allocator;

pub fn main() !void {
    // const file = try std.fs.cwd().openFile("tetris.gb", .{});
    // const file = try std.fs.cwd().openFile("./01-special.gb", .{});
    // const file = try std.fs.cwd().openFile("./02-interrupts.gb", .{});
    const file = try std.fs.cwd().openFile("./03-op sp,hl.gb", .{});
    // const file = try std.fs.cwd().openFile("cpu_instrs.gb", .{});
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
        cpu.step();
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
    // or refAllDeclsRecursive
}

test "io reader usage" {
    const file = try std.fs.cwd().openFile("test_rom.gb", .{});
    defer file.close();

    const size = try file.getEndPos();
    const buffer = try test_allocator.alloc(u8, size);
    defer test_allocator.free(buffer);
    _ = try file.readAll(buffer);
}
