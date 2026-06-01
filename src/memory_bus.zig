const std = @import("std");

const joypad = @import("joypad.zig");
const timer = @import("timer.zig");
const cartridge = @import("cartridge.zig");
const MBC = cartridge.MBC;
const IERegister = @import("ie_register.zig").IERegister;
const gpu = @import("gpu.zig");
const GPU = gpu.GPU;
const apu = @import("apu.zig");
const APU = apu.APU;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = std.log.scoped(.bus);

const WRAM_BEGIN: u16 = 0xC000;
const WRAM_END: u16 = 0xDFFF;
const ECHO_RAM_BEGIN: u16 = 0xE000;
const ECHO_RAM_END: u16 = 0xFDFF;

/// Cycle-accurate OAM DMA. Writing FF46 schedules a 160-byte transfer from
/// XX00-XX9F into OAM (FE00-FE9F), one byte per M-cycle, after a short startup
/// delay. While the transfer runs the source bus is held: a CPU access on that
/// bus reads open bus (0xFF) and OAM writes are dropped. The transfer is stepped
/// once per CPU M-cycle (dma_step).
pub const OamDma = struct {
    active: bool = false,
    source_high: u8 = 0, // source base = source_high << 8 for the running transfer
    index: u16 = 0, // next OAM byte to copy (0..159)
    // A write to FF46 doesn't take effect immediately: the new transfer begins
    // after this many M-cycles (mooneye oam_dma_start/restart probe this). While
    // a startup is pending, any already-running transfer keeps going (restart).
    starting: u8 = 0,
    pending_source: u8 = 0,
    reg: u8 = 0xFF, // last value written to FF46 (reads back unchanged)

    pub fn request(self: *OamDma, source_high: u8) void {
        self.pending_source = source_high;
        self.reg = source_high;
        // Setup M-cycles before byte 0 is copied. A fresh DMA (idle) or one that
        // restarts mid-transfer (active) takes the full 3 — this places the
        // 160-cycle window where oam_dma_timing/restart + the *_timing family
        // expect it. But a second write while still in the *startup* delay does
        // NOT restart the countdown (only the source latches), so the back-to-back
        // FF46 writes in oam_dma_start's restart round leave it measuring B=0.
        if (self.active or self.starting == 0) self.starting = 3;
    }

    /// Whether a `source`-bus DMA holds the bus `addr` lives on. The DMG has two
    /// memory buses — external (ROM/SRAM/WRAM: 0000-7FFF, A000-FDFF) and video
    /// (VRAM/OAM: 8000-9FFF, FE00-FE9F) — and the DMA only holds the one its source
    /// sits on. HRAM/IO at FF00+ are on neither and stay accessible.
    fn busHeld(source: u8, addr: u16) bool {
        if (addr >= 0xFF00) return false;
        const src_video = source >= 0x80 and source <= 0x9F;
        const addr_video = (addr >= 0x8000 and addr <= 0x9FFF) or (addr >= 0xFE00 and addr <= 0xFE9F);
        return src_video == addr_video;
    }

    /// Conflict for a data read/write — held only while bytes actually transfer.
    pub fn conflicts(self: *const OamDma, addr: u16) bool {
        return self.active and busHeld(self.source_high, addr);
    }

    /// Conflict for an instruction fetch. A fetch reads the bus at the very start
    /// of its M-cycle, so it already sees the bus taken on the DMA's final setup
    /// cycle — one M-cycle before the first byte transfers. This is the offset
    /// mooneye oam_dma_start measures (executing OAM as code) vs oam_dma_timing,
    /// which reads a cycle later as data.
    pub fn conflictsFetch(self: *const OamDma, addr: u16) bool {
        if (self.active) return busHeld(self.source_high, addr);
        if (self.starting == 1) return busHeld(self.pending_source, addr);
        return false;
    }
};

pub const MemoryBus = struct {
    memory: [0x10000]u8,

    gpu: *GPU,
    apu: *APU,
    joypad: *joypad.Joypad,
    timer: *timer.Timer,
    mbc: *MBC,

    interrupt_enable: IERegister,
    interrupt_flag: IERegister,

    dma: OamDma,

    // Serial output capture — side channel for headless test harnesses (blargg
    // writes its pass/fail text to serial). Does not affect emulation state.
    serial_sb: u8,
    serial_out: [1024]u8,
    serial_len: usize,

    pub fn new(mbc_: *MBC, gpu_: *GPU, apu_: *APU, timer_: *timer.Timer, joypad_: *joypad.Joypad) MemoryBus {
        var memory: [0x10000]u8 = @splat(0);
        std.mem.copyForwards(u8, memory[0..0x7FFF], mbc_.rom[cartridge.FULL_ROM_START..cartridge.FULL_ROM_END]);

        return MemoryBus{
            .memory = memory,

            .gpu = gpu_,
            .apu = apu_,
            .joypad = joypad_,
            .timer = timer_,
            .mbc = mbc_,

            .interrupt_enable = @bitCast(@as(u8, 0)),
            .interrupt_flag = @bitCast(@as(u8, 0)),

            .dma = .{},

            .serial_sb = 0,
            .serial_out = @splat(0),
            .serial_len = 0,
        };
    }

    pub fn update_if_flags(self: *MemoryBus, new_enabled_if_flags: IERegister) void {
        self.interrupt_flag.enable_vblank = if (new_enabled_if_flags.enable_vblank) true else self.interrupt_flag.enable_vblank;
        self.interrupt_flag.enable_lcd_stat = if (new_enabled_if_flags.enable_lcd_stat) true else self.interrupt_flag.enable_lcd_stat;
        self.interrupt_flag.enable_timer = if (new_enabled_if_flags.enable_timer) true else self.interrupt_flag.enable_timer;
        self.interrupt_flag.enable_joypad = if (new_enabled_if_flags.enable_joypad) true else self.interrupt_flag.enable_joypad;
        self.interrupt_flag.enable_serial = if (new_enabled_if_flags.enable_serial) true else self.interrupt_flag.enable_serial;
    }

    pub fn has_interrupt(self: *MemoryBus) bool {
        return self.interrupt_flag.enable_vblank and self.interrupt_enable.enable_vblank or
            self.interrupt_flag.enable_timer and self.interrupt_enable.enable_timer or
            self.interrupt_flag.enable_lcd_stat and self.interrupt_enable.enable_lcd_stat or
            self.interrupt_flag.enable_serial and self.interrupt_enable.enable_serial or
            self.interrupt_flag.enable_joypad and self.interrupt_enable.enable_joypad;
    }

    /// Advance the OAM DMA by one CPU M-cycle: run down the startup delay, then
    /// copy one byte from the source into OAM. Called once per CPU M-cycle (from
    /// CPU.mcycle) so the transfer is exactly 160 M-cycles and stays aligned with
    /// instruction memory accesses. The source byte is read raw (the DMA is the
    /// bus master, so it is not subject to its own conflict).
    pub fn dma_step(self: *MemoryBus) void {
        if (self.dma.starting > 0) {
            self.dma.starting -= 1;
            if (self.dma.starting == 0) {
                self.dma.active = true;
                self.dma.source_high = self.dma.pending_source;
                self.dma.index = 0;
            }
        }
        if (self.dma.active) {
            const raw_src = (@as(u16, self.dma.source_high) << 8) | self.dma.index;
            // Source high bytes E0-FF read from the internal RAM bus (the WRAM
            // echo continues), not OAM/IO — so $FE/$FF DMA copies WRAM, matching
            // $E0 (mooneye oam_dma/sources). $E000-$FDFF already echo via
            // read_byte_raw; this also redirects $FE00-$FFFF.
            const src = if (self.dma.source_high >= 0xE0) (0xC000 | (raw_src & 0x1FFF)) else raw_src;
            self.gpu.write_oam(gpu.OAM_BEGIN + self.dma.index, self.read_byte_raw(src));
            self.dma.index += 1;
            if (self.dma.index >= 0xA0) self.dma.active = false;
        }
    }

    pub fn read_byte(self: *const MemoryBus, address: u16) u8 {
        // OAM DMA bus conflict: while the transfer holds a bus, a CPU access on
        // that same bus reads open bus (0xFF) — the held bus is inaccessible.
        // (mooneye oam_dma_start times this by executing OAM as code: a corrupted
        // fetch becomes RST $38, not the source byte.) HRAM/IO and the other bus
        // stay accessible.
        if (self.dma.conflicts(address)) {
            return 0xFF;
        }
        return self.read_byte_raw(address);
    }

    /// Opcode fetch read — conflicts one M-cycle earlier than a data read
    /// (see OamDma.conflictsFetch).
    pub fn read_fetch(self: *const MemoryBus, address: u16) u8 {
        if (self.dma.conflictsFetch(address)) {
            return 0xFF;
        }
        return self.read_byte_raw(address);
    }

    pub fn read_byte_raw(self: *const MemoryBus, address: u16) u8 {
        switch (address) {
            cartridge.FULL_ROM_START...cartridge.FULL_ROM_END => |rom_addr| {
                switch (rom_addr) {
                    // 0x0000...0x00FF => {
                    //     // log.debug("Attempted read from boot rom\n", .{});
                    //     return self.memory[address];
                    // },
                    0x0000...0x7FFF => {
                        return self.mbc.read_rom(rom_addr);
                    },
                    else => {},
                }
            },
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                // log.debug("Vram byte read\n", .{});
                return self.gpu.read_vram(address);
            },
            // external ram
            cartridge.RAM_BANK_START...cartridge.RAM_BANK_END => {
                return self.mbc.read_ram(address);
            },
            WRAM_BEGIN...WRAM_END => {
                return self.memory[address];
            },
            ECHO_RAM_BEGIN...ECHO_RAM_END => {
                const new_addr = WRAM_BEGIN + (address & 0x1FFF);
                return self.memory[new_addr];
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                // OAM is stored in the GPU's memory (where write_oam puts it), not
                // the flat `memory` array — read it back from the same place.
                return self.gpu.read_vram(address);
            },
            0xFEA0...0xFEFF => {
                // log.debug("Attempted read from unusable memory\n", .{});
            },
            0xFF00...0xFF7F => {
                return self.read_io(address);
            },
            0xFF80...0xFFFE => {
                return self.memory[address];
            },
            0xFFFF => {
                return @bitCast(self.interrupt_enable);
            },
        }
        return 0xFF;
    }
    pub fn write_byte(self: *MemoryBus, address: u16, byte: u8) void {
        switch (address) {
            0x0000...0x7FFF => {
                // log.debug("Attempted write to rom\n", .{});
                self.mbc.handle_register(address, byte);
                return;
            },
            gpu.VRAM_BEGIN...gpu.VRAM_END => {
                self.gpu.write_vram(address, byte);
                return;
            },
            cartridge.RAM_BANK_START...cartridge.RAM_BANK_END => {
                // log.debug("Attempted write to external ram\n", .{});
                self.mbc.write_ram(address, byte);
                return;
            },
            WRAM_BEGIN...WRAM_END => {
                self.memory[address] = byte;
                return;
            },
            ECHO_RAM_BEGIN...ECHO_RAM_END => {
                const new_addr = WRAM_BEGIN + (address & 0x1FFF);
                self.memory[new_addr] = byte;
                return;
            },
            gpu.OAM_BEGIN...gpu.OAM_END => {
                // CPU writes to OAM are dropped while the DMA holds the bus.
                if (self.dma.active) return;
                self.gpu.write_oam(address, byte);
                return;
            },
            0xFEA0...0xFEFF => {
                // log.debug("Attempted write to unusable memory\n", .{});
                // self.memory[address] = byte;
                return;
            },
            0xFF00...0xFF7F => {
                self.write_io(address, byte);
                return;
            },
            0xFF80...0xFFFE => {
                self.memory[address] = byte;
                return;
            },
            0xFFFF => {
                self.interrupt_enable = @bitCast(byte);
                return;
            },
        }
    }

    pub fn read_word(self: *MemoryBus, address: u16) u16 {
        const low = self.read_byte(address);
        const high = self.read_byte(address +% 1);
        return @as(u16, high) << 8 | @as(u16, low);
    }

    pub fn write_word(self: *MemoryBus, address: u16, word: u16) void {
        const low: u8 = @truncate(word);
        const high: u8 = @truncate(word >> 8);
        self.write_byte(address, low);
        self.write_byte(address +% 1, high);
    }

    pub fn read_io(self: *const MemoryBus, io_addr: u16) u8 {
        return blk: {
            switch (io_addr) {
                0xFF00 => {
                    // break :blk self.joypad.joyp.unpressed;
                    // masking the front bits to 11 fixes a load screen issue in the game Donkey Kong
                    // need to validate this lines up with explainer here
                    // https://www.reddit.com/r/EmuDev/comments/5bgcw1/gb_lcd_disableenable_behavior/
                    break :blk 0b1100_0000 | @as(u8, (@bitCast(self.joypad.joyp)));
                },
                0xFF01 => break :blk self.serial_sb,
                0xFF02 => break :blk 0x00,
                0xFF04 => break :blk self.timer.internal_clock.bits.div,
                0xFF05 => break :blk self.timer.tima,
                0xFF06 => break :blk self.timer.tma,
                0xFF07 => break :blk @bitCast(self.timer.tac),
                // IF bits 5-7 are unimplemented and always read back as 1.
                0xFF0F => break :blk 0xE0 | @as(u8, @bitCast(self.interrupt_flag)),
                0xFF10...0xFF3F => break :blk self.apu.read_apu_register(io_addr),
                0xFF40 => break :blk @bitCast(self.gpu.lcdc),
                0xFF41 => break :blk @bitCast(self.gpu.stat),
                // 0xFF41 => break :blk @as(u8, @bitCast(self.gpu.stat)) | 0b1100_0000,
                0xFF42 => break :blk self.gpu.background_viewport.scy,
                // debug
                // 0xFF44 => break :blk 0x90,
                0xFF43 => break :blk self.gpu.background_viewport.scx,
                0xFF44 => break :blk self.gpu.ly,
                0xFF45 => break :blk self.gpu.lyc,
                0xFF46 => break :blk self.dma.reg,
                0xFF47 => break :blk @bitCast(self.gpu.bgp),
                0xFF48 => break :blk @bitCast(self.gpu.obp[0]),
                0xFF49 => break :blk @bitCast(self.gpu.obp[1]),
                0xFF4A => break :blk self.gpu.window_position.wy,
                0xFF4B => break :blk self.gpu.window_position.wx,
                0xFFFF => break :blk @bitCast(self.interrupt_enable),
                else => break :blk 0xFF,
            }
        };
    }

    pub fn write_io(self: *MemoryBus, io_addr: u16, byte: u8) void {
        const res = blk: {
            switch (io_addr) {
                0xFF00 => {
                    // possibly need to not overwrite the lower 4 bits
                    self.joypad.joyp.select = @enumFromInt((byte >> 4) & 0b11);
                },
                // Serial: capture output for headless test harnesses (blargg writes
                // its pass/fail text here). Side channel only — emulation unchanged.
                0xFF01 => self.serial_sb = byte,
                0xFF02 => {
                    if ((byte & 0x80) != 0 and self.serial_len < self.serial_out.len) {
                        self.serial_out[self.serial_len] = self.serial_sb;
                        self.serial_len += 1;
                    }
                },
                0xFF04 => {
                    const before_delay = self.timer.tima_cycles_till_interrupt;
                    self.timer.clock_update(@bitCast(@as(u64, 0)));
                    // A DIV reset can drop the selected mux bit and glitch-overflow
                    // TIMA; like the TAC case, recognize the interrupt at this
                    // instruction's boundary rather than 4 T-cycles late.
                    if (before_delay == 0 and self.timer.tima_cycles_till_interrupt > 0) {
                        self.timer.tima = self.timer.tma;
                        self.timer.tima_cycles_till_interrupt = 0;
                        self.interrupt_flag.enable_timer = true;
                    }
                    log.debug("div reset 0b{b:0>8}\n", .{@as(u64, @bitCast(self.timer.internal_clock))});
                },
                0xFF05 => {
                    if (!self.timer.tima_reload_cycle) {
                        self.timer.tima = byte;
                    }
                    if (self.timer.tima_cycles_till_interrupt > 0) {
                        self.timer.tima_cycles_till_interrupt = 0;
                    }
                    log.debug("tima {}\n", .{self.timer.tima});
                },
                0xFF06 => {
                    if (self.timer.tima_reload_cycle) {
                        self.timer.tima = byte;
                    }
                    self.timer.tma = byte;
                    log.debug("tma {}\n", .{self.timer.tima});
                },
                0xFF07 => {
                    // Writing TAC can glitch the timer: the multiplexer output is
                    // (selected DIV bit) AND (enable), not just the enable bit. Set
                    // the new TAC, then re-evaluate that output against the *unchanged*
                    // internal counter via clock_update so a 1->0 transition produces
                    // the hardware's spurious TIMA increment (and prev_bit is left
                    // holding the real bit). The old code used only the enable bit,
                    // which broke rapid_toggle and corrupted prev_bit for div_write.
                    const before_delay = self.timer.tima_cycles_till_interrupt;
                    self.timer.tac = @bitCast(byte);
                    self.timer.clock_update(self.timer.internal_clock);
                    // If the glitch overflowed TIMA, the write lands at the end of
                    // its own M-cycle, so the reload + interrupt are recognized at
                    // this instruction's boundary rather than 4 T-cycles later. With
                    // cycle-accurate inline timer stepping those 4 cycles would
                    // otherwise spill into the next instruction and shift the
                    // interrupt one instruction late (mooneye rapid_toggle).
                    if (before_delay == 0 and self.timer.tima_cycles_till_interrupt > 0) {
                        self.timer.tima = self.timer.tma;
                        self.timer.tima_cycles_till_interrupt = 0;
                        self.interrupt_flag.enable_timer = true;
                    }
                },
                0xFF0F => {
                    self.interrupt_flag = @bitCast(byte);
                },
                0xFF10...0xFF3F => {
                    self.apu.write_apu_register(io_addr, byte);
                },
                0xFF40 => {
                    self.gpu.lcdc = @bitCast(byte);
                    if (!self.gpu.lcdc.lcd_enable) {
                        self.gpu.ly = 0;
                        self.gpu.internal_window_counter = 0;
                        self.gpu.stat.ppu_mode = 0;
                        self.gpu.stat.lyc_ly_compare = false;
                        // self.gpu.stat.mode_0_interrupt_enabled = false;
                        // self.gpu.stat.mode_1_interrupt_enabled = false;
                        // self.gpu.stat.mode_2_interrupt_enabled = false;
                        // self.gpu.stat.lyc_int_interrupt_enabled = false;
                    }
                },
                0xFF41 => {
                    var stat: gpu.Stat = @bitCast(byte);
                    stat.ppu_mode = self.gpu.stat.ppu_mode;
                    stat.lyc_ly_compare = self.gpu.stat.lyc_ly_compare;

                    self.gpu.stat = stat;
                },
                0xFF42 => {
                    self.gpu.background_viewport.scy = byte;
                },
                0xFF43 => {
                    self.gpu.background_viewport.scx = byte;
                },
                0xFF45 => {
                    self.gpu.lyc = byte;
                },
                0xFF46 => {
                    // Schedule a cycle-accurate OAM DMA instead of an instant copy.
                    // The transfer is driven one byte per CPU M-cycle by dma_step().
                    self.dma.request(byte);
                },
                0xFF47 => {
                    self.gpu.bgp = @bitCast(byte);
                },
                0xFF48 => {
                    self.gpu.obp[0] = @bitCast(byte);
                },
                0xFF49 => {
                    self.gpu.obp[1] = @bitCast(byte);
                },
                0xFF4A => {
                    self.gpu.window_position.wy = byte;
                },
                0xFF4B => {
                    self.gpu.window_position.wx = byte;
                },
                0xFF50 => {
                    // disable boot rom
                    // for (0x00..0x100) |i| {
                    //     self.memory[i] = 0;
                    // }
                },
                0xFFFF => {
                    self.interrupt_enable = @bitCast(byte);
                },

                else => break :blk,
            }
        };
        _ = res; // autofix
    }
};
