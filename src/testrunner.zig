//! Native headless accuracy-test runner (ReleaseFast — far faster than
//! wasm-in-Node for sweeping hundreds of ROMs). Grades each ROM by its suite's
//! convention and prints one line per ROM plus a summary.
//!
//!   testrunner <blargg|mooneye> <rom> [rom...]
//!
//! - blargg : serial output text ("Passed"/"Failed"), with the $A000 protocol
//!            (signature DE B0 61 + status byte + text) as a fallback for the
//!            RAM-backed APU tests.
//! - mooneye: the register "fibonacci" magic — B,C,D,E,H,L == 3,5,8,13,21,34
//!            on pass.
//!
//! A test is bailed early once it produces a result, or once its serial output
//! has been quiet for a while with the CPU spinning (a hang = fail).

const std = @import("std");
const Gameboy = @import("gameboy.zig").Gameboy;

const Verdict = enum { pass, fail, timeout, load_error };

const Result = struct { verdict: Verdict, detail: []const u8 };

const BLARGG_FRAMES = 8000; // generous: blargg computes silently for a long stretch before printing
const MOONEYE_FRAMES = 4000;
const FROZEN_FRAMES = 200; // PC unchanged this long => reached an idle loop (test ended / hung)

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn gradeBlargg(gb: *Gameboy, detail_buf: []u8) Result {
    // blargg prints the test name, computes *silently* for a long stretch, then
    // prints "Passed"/"Failed" and spins in a `JR -2` loop (PC frozen). So we
    // poll for the result every frame, and treat a frozen PC as "test finished"
    // (read whatever it printed) rather than giving up on serial quiet.
    var frozen: u32 = 0;
    var last_pc: u16 = 0xFFFF;
    var i: u32 = 0;
    while (i < BLARGG_FRAMES) : (i += 1) {
        gb.frame();

        const sl = gb.memory_bus.serial_len;
        const serial = gb.memory_bus.serial_out[0..sl];

        // $A000 protocol (APU tests have cart RAM)
        if (gb.memory_bus.read_byte(0xA001) == 0xDE and
            gb.memory_bus.read_byte(0xA002) == 0xB0 and
            gb.memory_bus.read_byte(0xA003) == 0x61)
        {
            const status = gb.memory_bus.read_byte(0xA000);
            if (status != 0x80) {
                var n: usize = 0;
                var a: u16 = 0xA004;
                while (a < 0xA200 and n < detail_buf.len) : (a += 1) {
                    const c = gb.memory_bus.read_byte(a);
                    if (c == 0) break;
                    detail_buf[n] = if (c == '\n') ' ' else c;
                    n += 1;
                }
                return .{ .verdict = if (status == 0) .pass else .fail, .detail = std.mem.trim(u8, detail_buf[0..n], " ") };
            }
        }

        if (contains(serial, "Passed")) return .{ .verdict = .pass, .detail = flatten(serial, detail_buf) };
        if (contains(serial, "Failed") or contains(serial, "Error")) return .{ .verdict = .fail, .detail = flatten(serial, detail_buf) };

        // PC frozen => reached an idle loop. With no Passed/Failed in serial, that
        // is a genuine hang (or a result-less crash loop).
        if (gb.cpu.pc == last_pc) {
            frozen += 1;
            if (frozen >= FROZEN_FRAMES) {
                return .{ .verdict = .timeout, .detail = if (sl > 0) flatten(serial, detail_buf) else "idle loop, no result (hang)" };
            }
        } else {
            frozen = 0;
            last_pc = gb.cpu.pc;
        }
    }
    return .{ .verdict = .timeout, .detail = flatten(gb.memory_bus.serial_out[0..gb.memory_bus.serial_len], detail_buf) };
}

fn flatten(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (n >= buf.len) break;
        buf[n] = if (c == '\n' or c == '\r') ' ' else c;
        n += 1;
    }
    return std.mem.trim(u8, buf[0..n], " ");
}

fn gradeMooneye(gb: *Gameboy, detail_buf: []u8) Result {
    var i: u32 = 0;
    while (i < MOONEYE_FRAMES) : (i += 1) {
        gb.frame();
        const r = &gb.cpu.registers;
        if (r.B == 3 and r.C == 5 and r.D == 8 and r.E == 13 and r.H == 21 and r.L == 34)
            return .{ .verdict = .pass, .detail = "fib magic" };
        if (r.B == 0x42 and r.C == 0x42 and r.D == 0x42 and r.E == 0x42 and r.H == 0x42 and r.L == 0x42)
            return .{ .verdict = .fail, .detail = "failure magic (0x42)" };
    }
    const r = &gb.cpu.registers;
    const d = std.fmt.bufPrint(detail_buf, "no magic; B={X:0>2} C={X:0>2} D={X:0>2} E={X:0>2} H={X:0>2} L={X:0>2}", .{ r.B, r.C, r.D, r.E, r.H, r.L }) catch "no magic";
    return .{ .verdict = .fail, .detail = d };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena_alloc);
    if (args.len < 3) {
        std.debug.print("usage: testrunner <blargg|mooneye> <rom> [rom...]\n", .{});
        return error.Usage;
    }
    const mode = args[1];
    const is_blargg = std.mem.eql(u8, mode, "blargg");

    var pass: u32 = 0;
    var fail: u32 = 0;
    var other: u32 = 0;

    var detail_buf: [512]u8 = undefined;

    for (args[2..]) |rom_path| {
        // Fresh arena per ROM so memory doesn't accumulate across the sweep.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const rom_bytes = std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited) catch {
            std.debug.print("LOAD_ERR  {s}\n", .{rom_path});
            other += 1;
            continue;
        };
        var gb = Gameboy.newFromRomBytes(rom_bytes, a) catch {
            std.debug.print("LOAD_ERR  {s}\n", .{rom_path});
            other += 1;
            continue;
        };

        const r = if (is_blargg) gradeBlargg(&gb, &detail_buf) else gradeMooneye(&gb, &detail_buf);
        const tag = switch (r.verdict) {
            .pass => "PASS    ",
            .fail => "FAIL    ",
            .timeout => "TIMEOUT ",
            .load_error => "LOAD_ERR",
        };
        switch (r.verdict) {
            .pass => pass += 1,
            .fail => fail += 1,
            else => other += 1,
        }
        if (r.verdict == .pass)
            std.debug.print("{s} {s}\n", .{ tag, rom_path })
        else
            std.debug.print("{s} {s} :: {s}\n", .{ tag, rom_path, r.detail });
    }

    std.debug.print("\n=== {s}: {d}/{d} passed ({d} failed, {d} timeout/error) ===\n", .{ mode, pass, args.len - 2, fail, other });
}
