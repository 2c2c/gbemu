const std = @import("std");
const CPU = @import("cpu.zig").CPU;

const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn main() !void {
    var cpu = try CPU.new();
    while (true) {
        cpu.step();
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
    // or refAllDeclsRecursive
}
