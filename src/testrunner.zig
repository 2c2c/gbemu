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
const timer_mod = @import("timer.zig");

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
    const d = std.fmt.bufPrint(detail_buf, "no magic; PC={X:0>4} SP={X:0>4} LY={d} B={X:0>2} C={X:0>2} D={X:0>2} E={X:0>2} H={X:0>2} L={X:0>2}", .{ gb.cpu.pc, gb.cpu.sp, gb.gpu.ly, r.B, r.C, r.D, r.E, r.H, r.L }) catch "no magic";
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

    // Render mode: run N frames and write the framebuffer as a P6 PPM (the exact
    // format tools/screenshot.mjs emits), so a shasum compares byte-for-byte
    // against the WASM-captured baselines. Read-only w.r.t. the core — a fast
    // native rendering-regression net for the PPU FIFO work.
    //   testrunner render <rom> <out.ppm> [frames=600]
    if (std.mem.eql(u8, mode, "render")) {
        const rom_path = args[2];
        const out_path = args[3];
        const frames: u32 = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 600;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited);
        var gb = try Gameboy.newFromRomBytes(rom_bytes, a);
        var i: u32 = 0;
        while (i < frames) : (i += 1) gb.frame();
        var buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ @as(usize, 160), @as(usize, 144) });
        var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll(header);
        try w.interface.writeAll(&gb.gpu.canvas);
        try w.interface.flush();
        std.debug.print("wrote {s} ({d} frames)\n", .{ out_path, frames });
        return;
    }

    // Debug mode: step a ROM until PC hits a watch address, print registers.
    //   testrunner watch <rom> <hexaddr>
    if (std.mem.eql(u8, mode, "watch")) {
        const rom_path = args[2];
        const watch = try std.fmt.parseInt(u16, args[3], 16);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited);
        var gb = try Gameboy.newFromRomBytes(rom_bytes, a);
        var steps: u64 = 0;
        while (steps < 200_000_000) : (steps += 1) {
            if (gb.cpu.pc == watch) {
                const r = &gb.cpu.registers;
                std.debug.print("HIT {X:0>4} after {d} steps: BC={X:0>2}{X:0>2} DE={X:0>2}{X:0>2} HL={X:0>2}{X:0>2} A={X:0>2}\n", .{ watch, steps, r.B, r.C, r.D, r.E, r.H, r.L, r.A });
                std.debug.print("  GPU: LY={d} LYC={d} mode={d} cycles={d} clock=0x{X} (DIV={X:0>2})\n", .{ gb.gpu.ly, gb.gpu.lyc, gb.gpu.stat.ppu_mode, gb.gpu.cycles, @as(u64, @bitCast(gb.timer.internal_clock)), gb.timer.internal_clock.bits.div });
                return;
            }
            _ = gb.cpu.step();
            gb.cpu.hit_vblank = false;
            var rem = gb.cpu.pending_t_cycles - gb.cpu.inline_ticked;
            while (rem > 0) : (rem -= 1) gb.cpu.tick_peripherals_one();
        }
        std.debug.print("never hit {X:0>4}\n", .{watch});
        return;
    }

    // Debug mode: run the boot ROM until handoff (PC reaches $0100) and dump the
    // CPU + IO state the mooneye boot_regs/boot_hwio/boot_div tests sample there.
    //   testrunner bootdump <rom>
    if (std.mem.eql(u8, mode, "bootdump")) {
        const rom_path = args[2];
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited);
        var gb = try Gameboy.newFromRomBytes(rom_bytes, a);
        var steps: u64 = 0;
        // Capture the clock the first time PC reaches each checkpoint in the
        // SameBoy DMG boot ROM, so we can attribute pre-LCD-enable cycles to
        // segments: VRAM clear, logo decode, tilemap setup, then LCD enable.
        const checkpoints = [_]u16{ 0x0006, 0x000C, 0x0026, 0x0034, 0x0040, 0x0055, 0x005B };
        var cp_clock: [checkpoints.len]u64 = @splat(0);
        var cp_hit: [checkpoints.len]bool = @splat(false);
        while (steps < 50_000_000 and gb.cpu.pc != 0x0100) : (steps += 1) {
            for (checkpoints, 0..) |cp, idx| {
                if (!cp_hit[idx] and gb.cpu.pc == cp) {
                    cp_hit[idx] = true;
                    cp_clock[idx] = @bitCast(gb.timer.internal_clock);
                }
            }
            _ = gb.cpu.step();
            gb.cpu.hit_vblank = false;
            var rem = gb.cpu.pending_t_cycles - gb.cpu.inline_ticked;
            while (rem > 0) : (rem -= 1) gb.cpu.tick_peripherals_one();
        }
        for (checkpoints, 0..) |cp, idx| {
            const prev: u64 = if (idx == 0) 0 else cp_clock[idx - 1];
            std.debug.print("  PC {X:0>4}: clock={d}  (segment delta={d})\n", .{ cp, cp_clock[idx], cp_clock[idx] - prev });
        }
        const r = &gb.cpu.registers;
        std.debug.print("handoff at PC={X:0>4} after {d} steps (boot_active={})\n", .{ gb.cpu.pc, steps, gb.memory_bus.boot_rom_active });
        std.debug.print("AF={X:0>2}{X:0>2} BC={X:0>2}{X:0>2} DE={X:0>2}{X:0>2} HL={X:0>2}{X:0>2} SP={X:0>4}\n", .{ r.A, @as(u8, @bitCast(r.F)), r.B, r.C, r.D, r.E, r.H, r.L, gb.cpu.sp });
        std.debug.print("DIV(FF04)={X:0>2}  internal_clock=0x{X}\n", .{ gb.timer.internal_clock.bits.div, @as(u64, @bitCast(gb.timer.internal_clock)) });
        var addr: u16 = 0xFF00;
        while (addr <= 0xFF4B) : (addr += 1) {
            std.debug.print("{X:0>4}={X:0>2} ", .{ addr, gb.memory_bus.read_io(addr) });
            if ((addr & 0x7) == 0x7) std.debug.print("\n", .{});
        }
        std.debug.print("\nFF50={X:0>2} FFFF(IE)={X:0>2}\n", .{ gb.memory_bus.read_byte(0xFF50), @as(u8, @bitCast(gb.memory_bus.interrupt_enable)) });
        return;
    }

    // Debug mode: run a mooneye test to its result, then dump the mismatch
    // record the mooneye test framework leaves in HRAM ($FF80 = addr LE,
    // $FF82 = expected, $FF83 = actual). Lets us see exactly which IO register
    // the boot_hwio sweep rejected.
    //   testrunner mismatch <rom>
    if (std.mem.eql(u8, mode, "mismatch")) {
        const rom_path = args[2];
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited);
        var gb = try Gameboy.newFromRomBytes(rom_bytes, a);
        var i: u32 = 0;
        while (i < MOONEYE_FRAMES) : (i += 1) {
            gb.frame();
            const r = &gb.cpu.registers;
            const passed = r.B == 3 and r.C == 5 and r.D == 8 and r.E == 13 and r.H == 21 and r.L == 34;
            const failed = r.B == 0x42 and r.C == 0x42 and r.D == 0x42;
            if (passed or failed) break;
        }
        const lo = gb.memory_bus.read_byte(0xFF80);
        const hi = gb.memory_bus.read_byte(0xFF81);
        const addr = (@as(u16, hi) << 8) | lo;
        std.debug.print("mismatch addr={X:0>4} expected={X:0>2} actual={X:0>2}\n", .{ addr, gb.memory_bus.read_byte(0xFF82), gb.memory_bus.read_byte(0xFF83) });
        return;
    }

    // Debug mode: sweep the power-on DIV counter and report which values make a
    // mooneye test reach its pass magic. Used to pin the boot_div offset.
    //   testrunner divsweep <rom> <start_hex> <end_hex> <step_hex>
    if (std.mem.eql(u8, mode, "divsweep")) {
        const rom_path = args[2];
        const start = try std.fmt.parseInt(u64, args[3], 16);
        const end = try std.fmt.parseInt(u64, args[4], 16);
        const step = try std.fmt.parseInt(u64, args[5], 16);
        var first_pass: ?u64 = null;
        var last_pass: ?u64 = null;
        var off = start;
        while (off <= end) : (off += step) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited);
            timer_mod.Timer.div_power_on = off;
            var gb = try Gameboy.newFromRomBytes(rom_bytes, a);
            var i: u32 = 0;
            var passed = false;
            while (i < MOONEYE_FRAMES) : (i += 1) {
                gb.frame();
                const r = &gb.cpu.registers;
                if (r.B == 3 and r.C == 5 and r.D == 8 and r.E == 13 and r.H == 21 and r.L == 34) {
                    passed = true;
                    break;
                }
                if (r.B == 0x42 and r.C == 0x42 and r.D == 0x42) break;
            }
            if (passed) {
                if (first_pass == null) first_pass = off;
                last_pass = off;
            }
            std.debug.print("offset=0x{X:0>4} -> {s}\n", .{ off, if (passed) "PASS" else "fail" });
        }
        timer_mod.Timer.div_power_on = 0;
        if (first_pass) |fp| std.debug.print("PASS window: 0x{X:0>4} .. 0x{X:0>4}\n", .{ fp, last_pass.? }) else std.debug.print("no passing offset in range\n", .{});
        return;
    }

    // Debug mode: run a mooneye PPU timing test to its result, then dump the
    // measured register snapshot (regs_save, FF80-FF87) against the expected
    // values (regs_assert, FF89-FF90) and the check mask (regs_flags, FF88).
    // The save/assert layout is f,a,c,b,e,d,l,h (see the *.sym files).
    //   testrunner ppudump <rom>
    if (std.mem.eql(u8, mode, "ppudump")) {
        const rom_path = args[2];
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited);
        var gb = try Gameboy.newFromRomBytes(rom_bytes, a);
        var i: u32 = 0;
        while (i < MOONEYE_FRAMES) : (i += 1) {
            gb.frame();
            const r = &gb.cpu.registers;
            const passed = r.B == 3 and r.C == 5 and r.D == 8 and r.E == 13 and r.H == 21 and r.L == 34;
            const failed = r.B == 0x42 and r.C == 0x42 and r.D == 0x42;
            if (passed or failed) break;
        }
        const flags = gb.memory_bus.read_byte(0xFF88);
        // save:   FF80=F FF81=A FF82=C FF83=B FF84=E FF85=D FF86=L FF87=H
        // assert: FF89=F FF8A=A FF8B=C FF8C=B FF8D=E FF8E=D FF8F=L FF90=H
        const names = [_][]const u8{ "F", "A", "C", "B", "E", "D", "L", "H" };
        std.debug.print("regs_flags(FF88) = 0x{X:0>2}\n", .{flags});
        std.debug.print("reg  actual  expected\n", .{});
        for (names, 0..) |name, idx| {
            const actual = gb.memory_bus.read_byte(@intCast(0xFF80 + idx));
            const expected = gb.memory_bus.read_byte(@intCast(0xFF89 + idx));
            std.debug.print("  {s}   0x{X:0>2}    0x{X:0>2}\n", .{ name, actual, expected });
        }
        return;
    }

    // Debug mode: run lcdon_timing-GS until the Nth call of verify_results
    // (PC=0x4B89), then dump the 24-byte measured buffer (FF80-FF97) beside the
    // expected table that DE points at, so mismatched samples are obvious.
    //   testrunner lcdondump <rom> <which: 0=LY 1=STAT0 2=STAT1 3=OAM 4=VRAM>
    if (std.mem.eql(u8, mode, "lcdondump")) {
        const rom_path = args[2];
        const which = try std.fmt.parseInt(u32, args[3], 10);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, a, .unlimited);
        var gb = try Gameboy.newFromRomBytes(rom_bytes, a);
        var hits: u32 = 0;
        var steps: u64 = 0;
        while (steps < 200_000_000) : (steps += 1) {
            if (gb.cpu.pc == 0x4B89) {
                if (hits == which) {
                    const de = (@as(u16, gb.cpu.registers.D) << 8) | gb.cpu.registers.E;
                    std.debug.print("verify #{d}  expected_table=0x{X:0>4}\n", .{ which, de });
                    std.debug.print("idx  off   actual expected\n", .{});
                    const offs = [_]u16{ 8, 76, 248, 448, 528, 704, 904, 984, 12, 80, 252, 452, 532, 708, 908, 988, 16, 84, 256, 456, 536, 712, 912, 992 };
                    var i: u16 = 0;
                    while (i < 24) : (i += 1) {
                        const actual = gb.memory_bus.read_byte(0xFF80 + i);
                        const expected = gb.memory_bus.read_byte(de + i);
                        const mark = if (actual != expected) " <--" else "";
                        std.debug.print("{d:2}  {d:4}   0x{X:0>2}    0x{X:0>2}{s}\n", .{ i, offs[i], actual, expected, mark });
                    }
                    return;
                }
                hits += 1;
            }
            _ = gb.cpu.step();
            gb.cpu.hit_vblank = false;
            var rem = gb.cpu.pending_t_cycles - gb.cpu.inline_ticked;
            while (rem > 0) : (rem -= 1) gb.cpu.tick_peripherals_one();
        }
        std.debug.print("verify_results #{d} never reached\n", .{which});
        return;
    }

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
