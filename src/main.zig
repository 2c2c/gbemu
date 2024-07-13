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

test {
    std.testing.refAllDeclsRecursive(@This());
    // or refAllDeclsRecursive
}
