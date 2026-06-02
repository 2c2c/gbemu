const std = @import("std");
const IERegister = @import("ie_register.zig").IERegister;
const cpu = @import("cpu.zig");

pub const BACKGROUND_WIDTH: usize = 256;
pub const BACKGROUND_HEIGHT: usize = 256;

pub const SCREEN_WIDTH: usize = 160;
pub const SCREEN_HEIGHT: usize = 144;

pub const PALETTE_DEBUG_WIDTH: usize = 8;

pub const DRAW_WIDTH: usize = SCREEN_WIDTH;
pub const DRAW_HEIGHT: usize = SCREEN_HEIGHT;

// Debug calibration knob (default 0 = no effect on production/wasm/games). When
// >0, the pixel FIFO delays the start of visible emission by this many dots,
// modelling a pixel-output latch so a mid-mode-3 register write lands on the
// correct pixel (mealybug Bucket B). Set by testrunner from $EMIT_LEAD; never
// touched by gameboy.frame(), so games are unaffected unless this is changed.
pub var dbg_emit_lead: u8 = 0;

pub const VRAM_BEGIN: u16 = 0x8000;
pub const VRAM_END: u16 = 0x9FFF;
// const VRAM_SIZE: usize = VRAM_END - VRAM_BEGIN + 1;
//
pub const OAM_BEGIN: u16 = 0xFE00;
pub const OAM_END: u16 = 0xFE9F;
// pub const OAM_SIZE: u16 = OAM_END - OAM_BEGIN + 1;

const log = std.log.scoped(.gpu);

pub const TilePixelValue = enum(u2) {
    /// white
    Zero,
    /// light gray
    One,
    /// dark gray
    Two,
    /// black
    Three,
    pub fn to_color(self: TilePixelValue) u8 {
        return switch (self) {
            TilePixelValue.Zero => 0xFF,
            TilePixelValue.One => 0xAA,
            TilePixelValue.Two => 0x55,
            TilePixelValue.Three => 0x00,
        };
    }
};

const Tile = [8][8]TilePixelValue;

fn empty_tile() Tile {
    const row: [8]TilePixelValue = @splat(.Zero);
    return @splat(row);
}

/// FE00-FE9F
/// 40 objects at 4 bytes each
const Object = struct {
    y: i16,
    x: i16,
    tile_index: u8,
    attributes: packed struct {
        // gbc
        cgb_palette: u3,
        bank: bool,

        dmg_palette: bool,
        x_flip: bool,
        y_flip: bool,
        priority: bool,
    },
};

/// FF40 LCD Control
const LCDC = packed struct {
    bg_window_enable: bool,
    obj_enable: bool,

    /// 8x8 8x16
    obj_size: bool,

    /// 0x9800-0x9BFF 0x9C00-0x9FFF
    bg_tile_map: bool,

    /// 0x8800-0x97FF 0x8000-0x8FFF
    bg_window_tiles: bool,

    window_enable: bool,

    /// 0x9800-0x9BFF 0x9C00-0x9FFF
    window_tile_map: bool,

    lcd_enable: bool,
};

/// FF41 STAT LCD Status
pub const Stat = packed struct {
    /// 0: HBlank, 1: VBlank, 2: OAM, 3: VRAM
    ppu_mode: u2,
    lyc_ly_compare: bool,

    /// hblank
    mode_0_interrupt_enabled: bool,
    /// vblank
    mode_1_interrupt_enabled: bool,
    /// oam
    mode_2_interrupt_enabled: bool,
    lyc_int_interrupt_enabled: bool,
    _padding: u1 = 0,
};

/// viewport only displays 160x144 out of the entire 256x256 background
///
const BackgroundViewport = packed struct {
    /// FF42 SCY
    scy: u8,
    /// FF43 SCX
    scx: u8,
    fn bottom(self: *const BackgroundViewport) u8 {
        return self.scy +% 143;
    }
    fn right(self: *const BackgroundViewport) u8 {
        return self.scx +% 159;
    }
};

/// WX=7, WY=0 is the top left corner of the window
/// viewport only displays 160x144 out of the entire 256x256 background
///
const WindowPosition = packed struct {
    /// FF4A WY
    /// 0-143
    wy: u8,
    /// FF4B WX
    /// 0-166
    wx: u8,
};

const Palette = packed struct {
    color_0: TilePixelValue,
    color_1: TilePixelValue,
    color_2: TilePixelValue,
    color_3: TilePixelValue,
};

/// FF47
/// bg pallette
/// assigns colors to bg / window
/// tiles are indexed by two bits into bgp to derive its color
/// this lets dev tweak the color of the game by changing just bgp
/// rather than changing every single tile indepenently
const BGP = Palette;

/// same for but for objects
/// lower 2 bits are ignored transparent
const OBP = [2]Palette;

pub const GPU = struct {
    tile_canvas: [DRAW_WIDTH * DRAW_HEIGHT]u8,
    canvas: [DRAW_WIDTH * DRAW_HEIGHT * 3]u8,
    full_bg_canvas: [BACKGROUND_WIDTH * BACKGROUND_HEIGHT * 3]u8,

    /// 8x8 tiles * 4 palette possibilities * 3 palette sets * 3rgb
    palette_canvas: [8 * 8 * 4 * 3 * 3]u8,

    objects: [40]Object,
    vram: [0x10000]u8,
    tile_set: [384]Tile,
    lcdc: LCDC,
    stat: Stat,
    background_viewport: BackgroundViewport,
    bgp: BGP,
    obp: OBP,
    window_position: WindowPosition,

    /// FF44
    /// current horizontal line
    /// 0-153, 144-153 are vblank
    /// (readonly)
    ly: u8,

    /// poorly undocumented internal ppu counter that isn't exposed as an io register
    /// increments when ly is incremented if and only if lcdc.window_enable is set
    internal_window_counter: u8,

    /// FF45
    /// LY == LYC trigger STAT interrupt
    /// 0-153
    lyc: u8,
    /// Dot position within the current scanline (0..455). The PPU is stepped one
    /// dot per T-cycle, so this is the cycle-accurate horizontal position that
    /// drives mode 2/3/0 transitions.
    cycles: usize,

    /// Mode 3 (pixel transfer) length in dots for the current scanline, latched
    /// when mode 3 begins. Base 172 + the SCX fine-scroll penalty (SCX & 7),
    /// + sprite penalties. Mode 0 (HBlank) fills the rest of the 456-dot line.
    line3_len: u16 = 172,

    /// Previous state of the combined STAT interrupt line (OR of the enabled
    /// mode/LYC sources). The STAT interrupt fires only on its rising edge, which
    /// is the "STAT blocking" behaviour mooneye stat_irq_blocking checks.
    stat_irq_line: bool = false,

    /// The PPU's true current mode, used for the STAT-interrupt sources, the
    /// mode-change edges (VBlank IRQ, scanline render), and LCD-on bookkeeping.
    /// The mode reported in the STAT *register* (`stat.ppu_mode`) lags this by one
    /// dot — a CPU read latches near the end of its M-cycle and sees the previous
    /// dot's mode, which is the boundary mooneye intr_2_mode0/mode3_timing pin.
    internal_mode: u2 = 1,

    /// The PPU's true current LY==LYC coincidence. The flag reported in the STAT
    /// register (`stat.lyc_ly_compare`) lags this by one dot: when LY increments
    /// into a match the register bit sets a dot later (mooneye lcdon_timing-GS).
    /// The STAT interrupt source uses this immediate value, not the delayed one.
    internal_lyc_compare: bool = true,

    /// Set when the LCD is switched on, cleared once LY leaves line 0. The first
    /// scanline after enabling the LCD is special: there is no OAM scan (mode 2),
    /// so the would-be mode-2 window reads as mode 0 and fires no OAM STAT IRQ, and
    /// the line is 4 dots short (LY reaches 1 at dot 452, not 456). mooneye
    /// lcdon_timing-GS / lcdon_write_timing-GS pin this.
    lcd_first_line: bool = false,

    // ---- Pixel-FIFO renderer (mode 3) ----------------------------------------
    // A per-dot background/window fetcher + 8-pixel BG FIFO + sprite (OBJ) FIFO
    // that produces one visible pixel per dot during pixel transfer, sampling the
    // PPU registers *live* so a mid-scanline CPU write to BGP/SCX/LCDC/OBP/WX
    // affects only the pixels drawn after it — the behaviour the mealybug
    // rendering tests pin and the whole reason for this rewrite. Mode-3 *length*
    // (timing) stays driven by mode3_length(); the FIFO always emits its 160
    // pixels within that window (fifo_flush completes any remainder), so the
    // 12/12 acceptance/ppu timing contract is untouched. All state is rebuilt at
    // the start of each visible line by fifo_start().
    fifo: Fifo = .{},

    pub const Fifo = struct {
        lcd_x: u8 = 0, // visible pixels emitted this line (0..160)
        discard: u8 = 0, // BG/window pixels still to throw away (SCX&7, or WX<7)

        // Background/window fetcher. One tile (8 pixels) is fetched in phases of
        // 2 dots each (tile id, data low, data high) then pushed to the BG FIFO
        // when it drains. The very first fetch of a line is discarded (the 6-dot
        // dummy fetch real hardware performs), which is what makes the minimum
        // mode-3 length 172 rather than 166.
        fetch_phase: u2 = 0, // 0 tile, 1 low, 2 high, 3 ready-to-push
        fetch_sub: u1 = 0, // sub-dot within a 2-dot phase
        fetch_col: u8 = 0, // next tile column to fetch (BG map col, or window col)
        first_fetch: bool = true, // the line's first fetch is thrown away
        window: bool = false, // fetcher is reading the window, not the BG
        group: [8]u2 = @splat(0), // the 8 pixels of the tile being assembled

        // BG FIFO: an 8-entry ring, refilled a whole tile at a time when empty.
        bg_pix: [8]u2 = @splat(0),
        bg_head: u8 = 0,
        bg_len: u8 = 0,

        // OBJ FIFO: 8 entries aligned so slot i is screen column (lcd_x + i).
        // color 0 == empty/transparent; pal selects OBP0/1; prio is the
        // OBJ-behind-BG attribute bit (drawn only over BG colour 0).
        obj_color: [8]u2 = @splat(0),
        obj_pal: [8]u1 = @splat(0),
        obj_prio: [8]bool = @splat(false),

        // This line's OAM-scan result (≤10 objects, in OAM order for the DMG
        // priority tie-break) and which have already been merged into the OBJ FIFO.
        objs: [10]Object = undefined,
        obj_count: u8 = 0,
        obj_done: [10]bool = @splat(false),

        // Per-object mode-3 fetch penalty (dots), mirroring mode3_length()'s
        // per-object term, paid as an emission stall when the BG reaches each
        // object's column — so a mid-mode-3 write near a sprite lands on the same
        // pixel hardware draws it. Total equals mode3_length()'s object penalty, so
        // the FIFO paces over the full analytic mode-3 window (rendering only; the
        // 12/12 timing contract stays owned by mode3_length()).
        obj_stall: [10]u16 = @splat(0),
        obj_stalled: [10]bool = @splat(false),
        sprite_stall: u16 = 0, // remaining stall dots before the next emit

        window_triggered: bool = false, // window already activated on this line
        warmup: u8 = 0, // dbg_emit_lead: dots to stall before the first visible pixel
    };

    pub fn new() GPU {
        // const obp: [2]Palette = .{
        //     .{
        //         .color_0 = TilePixelValue.Zero,
        //         .color_1 = TilePixelValue.Zero,
        //         .color_2 = TilePixelValue.Zero,
        //         .color_3 = TilePixelValue.Zero,
        //     },
        //     .{
        //         .color_0 = TilePixelValue.Zero,
        //         .color_1 = TilePixelValue.Zero,
        //         .color_2 = TilePixelValue.Zero,
        //         .color_3 = TilePixelValue.Zero,
        //     },
        // };
        const obp: [2]Palette = .{
            .{
                .color_0 = TilePixelValue.Zero,
                .color_1 = TilePixelValue.One,
                .color_2 = TilePixelValue.Two,
                .color_3 = TilePixelValue.Three,
            },
            .{
                .color_0 = TilePixelValue.Zero,
                .color_1 = TilePixelValue.One,
                .color_2 = TilePixelValue.Two,
                .color_3 = TilePixelValue.Three,
            },
        };

        const objects: [40]Object = @splat(.{
            .y = 0,
            .x = 0,
            .tile_index = 0,
            .attributes = @bitCast(@as(u8, 0)),
        });

        return GPU{
            .tile_canvas = @splat(0),
            .canvas = @splat(0),
            .full_bg_canvas = @splat(0),
            .palette_canvas = @splat(0),
            .vram = @splat(0),
            .tile_set = @splat(empty_tile()),
            // ai says htis is default value
            .lcdc = @bitCast(@as(u8, 0x91)),
            .stat = @bitCast(@as(u8, 0x85)),
            .background_viewport = .{ .scy = 0, .scx = 0 },
            .ly = 0,
            .internal_window_counter = 0,
            .lyc = 0,
            .bgp = @bitCast(@as(u8, 0xFC)),
            .obp = obp,
            .objects = objects,
            .window_position = .{ .wy = 0, .wx = 0 },
            .cycles = 0,
            .internal_mode = 1,
            .internal_lyc_compare = true,
        };
    }

    /// update the respective IF flag with the respective true result
    const IFEnableRequests = struct {
        lcd_stat: bool,
        vblank: bool,
    };
    // PPU timing (DMG, in dots == T-cycles).
    const DOTS_PER_LINE: usize = 456;
    const FIRST_LINE_DOTS: usize = 452; // line 0 after LCD-on is 4 dots short
    const MODE2_DOTS: usize = 80; // OAM scan
    const MODE3_BASE: u16 = 172; // pixel transfer, before SCX/sprite penalties
    const VBLANK_LY: u8 = 144;
    const TOTAL_LINES: u8 = 154;

    pub fn step(self: *GPU, cycles: u64) IFEnableRequests {
        var flags = IFEnableRequests{ .lcd_stat = false, .vblank = false };
        if (!self.lcdc.lcd_enable) return flags;
        // The PPU is stepped one dot per T-cycle (gpu.step(1)); loop for safety in
        // case it is ever called with a lump.
        var n: u64 = cycles;
        while (n > 0) : (n -= 1) self.tick_dot(&flags);
        return flags;
    }

    /// Advance the PPU one dot. Drives mode 2 -> 3 -> 0 across each visible line
    /// and mode 1 over VBlank, fires the VBlank IRQ on entering line 144, renders
    /// a scanline when pixel transfer (mode 3) ends, and raises the STAT IRQ on
    /// the rising edge of the combined (mode + LYC) STAT line.
    fn tick_dot(self: *GPU, flags: *IFEnableRequests) void {
        // Advance the horizontal dot; wrap to the next scanline. Line 0 after
        // LCD-on is 4 dots short (FIRST_LINE_DOTS); every other line is 456.
        self.cycles += 1;
        const line_len: usize = if (self.lcd_first_line) FIRST_LINE_DOTS else DOTS_PER_LINE;
        if (self.cycles >= line_len) {
            self.cycles = 0;
            self.ly += 1;
            self.lcd_first_line = false; // the special first line is over
            if (self.ly >= TOTAL_LINES) {
                self.ly = 0;
                self.internal_window_counter = 0;
            }
        }
        const dot = self.cycles;

        // The first line after LCD-on has no OAM scan and its pixel transfer
        // begins one dot early (at dot 79, not 80) — the whole mode-3 window is
        // shifted left by one so the 1-dot-delayed STAT register and the mode-gated
        // VRAM/OAM access both show mode 3 over [80,252) (mooneye lcdon_timing-GS).
        const m3_start: usize = if (self.lcd_first_line) MODE2_DOTS - 1 else MODE2_DOTS;

        // Latch this line's mode-3 length when pixel transfer begins (samples SCX)
        // and (re)initialise the pixel FIFO for the line.
        if (self.ly < VBLANK_LY and dot == m3_start) {
            self.line3_len = self.mode3_length();
            self.fifo_start();
        }

        // Mode implied by the current (ly, dot) — the PPU's true internal mode,
        // which drives the interrupt sources, the mode-change edges, and rendering.
        const mode: u2 = if (self.ly >= VBLANK_LY)
            1
        else if (dot < m3_start)
            // Before pixel transfer: OAM scan (mode 2), except the first line after
            // LCD-on has no OAM scan and reads as mode 0.
            (if (self.lcd_first_line) @as(u2, 0) else 2)
        else if (dot < m3_start + self.line3_len)
            3
        else
            0;

        // Drive the FIFO one dot for every dot of pixel transfer. It samples the
        // PPU registers live, so any CPU write between dots (BGP, SCX, OBP, LCDC,
        // WX, ...) lands on exactly the pixels drawn afterwards.
        if (mode == 3) self.fifo_tick();

        if (mode != self.internal_mode) {
            // Pixel transfer just finished: complete the line (emit any pixels the
            // FIFO had not yet reached — normally none, the analytic mode-3 length
            // leaves slack) so the framebuffer is always a full 160-wide scanline.
            if (mode == 0 and self.internal_mode == 3) self.fifo_flush();
            // Entering VBlank (LY=144) requests the VBlank interrupt.
            if (mode == 1) flags.vblank = true;
        }

        // The STAT register reports the mode one dot late: set it to the *previous*
        // dot's mode (still held in internal_mode) before advancing internal_mode.
        self.stat.ppu_mode = self.internal_mode;
        self.internal_mode = mode;

        // LYC==LY: the compare is redone one dot into each line, so on the first
        // dot (cycles==0, right after LY changed) the register bit reads 0 even on
        // a match; from the next dot it reflects ly==lyc (mooneye lcdon_timing-GS).
        // The interrupt source uses the immediate compare (internal_lyc_compare).
        self.stat.lyc_ly_compare = (self.cycles != 0) and (self.ly == self.lyc);
        self.internal_lyc_compare = (self.ly == self.lyc);

        // Re-evaluate the combined STAT line; fire on its rising edge.
        if (self.refresh_stat_line()) flags.lcd_stat = true;
    }

    /// Recompute the combined STAT interrupt line (OR of the enabled mode/LYC
    /// sources) from the current state, latch it, and return true if it just rose.
    /// The interrupt fires only on this rising edge — the "STAT blocking" behaviour
    /// (mooneye stat_irq_blocking). Driven every dot by tick_dot and also after the
    /// register writes that change the line combinationally (LCD enable, LYC, STAT
    /// enable bits), so e.g. enabling the LCD into a fresh LY==LYC match fires
    /// immediately (mooneye stat_lyc_onoff).
    pub fn refresh_stat_line(self: *GPU) bool {
        var line = false;
        if (self.lcdc.lcd_enable) {
            const mode = self.internal_mode;
            // The OAM (mode 2) source also pulses at the start of line 144 — the
            // VBlank line triggers the OAM-scan STAT signal in addition to the
            // VBlank one (mooneye vblank_stat_intr).
            const oam_source = mode == 2 or (self.ly == VBLANK_LY and self.cycles < MODE2_DOTS);
            line =
                (self.stat.mode_0_interrupt_enabled and mode == 0) or
                (self.stat.mode_1_interrupt_enabled and mode == 1) or
                (self.stat.mode_2_interrupt_enabled and oam_source) or
                (self.stat.lyc_int_interrupt_enabled and self.internal_lyc_compare);
        } else {
            // LCD off: the mode sources are quiet, but the LYC comparator is frozen
            // and can still hold the line high.
            line = self.stat.lyc_int_interrupt_enabled and self.internal_lyc_compare;
        }
        const rose = line and !self.stat_irq_line;
        self.stat_irq_line = line;
        return rose;
    }

    /// Mode 3 (pixel transfer) length for the current line: base 172 dots plus the
    /// SCX fine-scroll penalty (the first SCX&7 pixels are discarded, extending
    /// mode 3 by that many dots) plus the per-object penalty.
    ///
    /// Object penalty (Pan Docs): every object the PPU fetches costs a 6-dot base.
    /// The first object on a given background tile column additionally waits for
    /// the in-progress BG fetch — `5 - min(5, (x+SCX)&7)` dots — so a sprite hard
    /// against the left of its tile costs the full 11, one further right costs
    /// less, and a run of objects sharing a tile column pays that wait only once.
    /// Objects are selected by the OAM scan (vertical overlap only, max 10); one
    /// fully off the right edge (OAM x >= 168) is selected but never fetched.
    /// (mooneye intr_2_mode0_timing_sprites pins every step of this.)
    fn mode3_length(self: *GPU) u16 {
        var len: u16 = MODE3_BASE + (self.background_viewport.scx & 7);
        if (!self.lcdc.obj_enable) return len;

        const obj_height: i16 = if (self.lcdc.obj_size) 16 else 8;
        const scx: u16 = self.background_viewport.scx;
        const ly_i: i16 = @intCast(self.ly);

        var count: u8 = 0;
        var last_tile: i32 = -1; // tile column of the previously penalised object
        for (self.objects) |obj| {
            // Selected by the OAM scan when the object covers this line vertically.
            if (obj.y <= ly_i and obj.y + obj_height > ly_i) {
                count += 1;
                if (count > 10) break;
                // objects store screen x (= OAM x - 8); recover OAM x. One whose
                // left edge is past pixel 159 (OAM x >= 168) is never fetched.
                const oam_x: i16 = obj.x + 8;
                if (oam_x >= 168) continue;
                const xs: u16 = @intCast(oam_x); // 0..167
                len += 6; // base object fetch
                const tile_col: i32 = @intCast((xs + scx) >> 3);
                if (tile_col != last_tile) {
                    len += 5 - @min(@as(u16, 5), (xs + scx) & 7);
                    last_tile = tile_col;
                }
            }
        }
        return len;
    }

    // =====================================================================
    //  Pixel-FIFO renderer (mode 3). Produces the visible scanline one pixel
    //  per dot, sampling registers live so mid-line writes affect only the
    //  pixels after them. See the `Fifo` field for the high-level rationale.
    // =====================================================================

    /// (Re)initialise the FIFO at the start of a visible line's pixel transfer:
    /// scan OAM into this line's object list, reset the BG/window fetcher, set up
    /// the SCX fine-scroll discard, and advance the window line counter exactly as
    /// the previous scanline renderer did (so window games stay pixel-identical).
    fn fifo_start(self: *GPU) void {
        const f = &self.fifo;
        f.* = .{};

        const win_x: i16 = @as(i16, self.window_position.wx) - 7;
        if (self.ly == self.window_position.wy) self.internal_window_counter = 0;
        if (self.lcdc.window_enable and self.lcdc.bg_window_enable and
            self.ly >= self.window_position.wy and win_x < 160)
        {
            self.internal_window_counter +%= 1;
        }

        // OAM scan: up to 10 objects covering this line, kept in OAM order (the DMG
        // same-X priority tie-break is "lower OAM index wins").
        const h: i16 = if (self.lcdc.obj_size) 16 else 8;
        const ly_i: i16 = @intCast(self.ly);
        var n: u8 = 0;
        for (self.objects) |obj| {
            if (obj.y <= ly_i and obj.y + h > ly_i) {
                f.objs[n] = obj;
                n += 1;
                if (n == 10) break;
            }
        }
        f.obj_count = n;

        // The first SCX&7 background pixels of the line are discarded (fine scroll).
        f.discard = self.background_viewport.scx & 7;

        // Per-object fetch penalties, computed exactly as mode3_length()'s object
        // term (same selected set, same OAM order, same shared-column wait) so their
        // sum equals that penalty — paid back as emission stalls in fifo_tick when
        // the BG reaches each object's column. Gated on the start-of-line obj-enable
        // (mode3_length() returns early when objects are off), so a mid-line LCDC.1
        // toggle does not change this line's pacing.
        if (self.lcdc.obj_enable) {
            const scx: u16 = self.background_viewport.scx;
            var last_tile: i32 = -1;
            var i: u8 = 0;
            while (i < f.obj_count) : (i += 1) {
                const oam_x: i16 = f.objs[i].x + 8; // recover OAM x from screen x
                if (oam_x >= 168) continue; // selected but never fetched (cost 0)
                const xs: u16 = @intCast(oam_x);
                var cost: u16 = 6; // base object fetch
                const tile_col: i32 = @intCast((xs + scx) >> 3);
                if (tile_col != last_tile) {
                    cost += 5 - @min(@as(u16, 5), (xs + scx) & 7);
                    last_tile = tile_col;
                }
                f.obj_stall[i] = cost;
            }
        }

        // Calibration: optionally stall the first visible pixel by dbg_emit_lead
        // dots (pixel-output latch model). 0 in production, so no effect on games.
        f.warmup = dbg_emit_lead;
    }

    /// Advance the FIFO one dot: maybe activate the window, step the fetcher, then
    /// shift out at most one pixel (discarding fine-scroll pixels, mixing BG/window
    /// with sprites). Reads VRAM/OAM directly — rendering is not subject to the
    /// CPU's mode-3 access lock.
    fn fifo_tick(self: *GPU) void {
        const f = &self.fifo;
        if (f.lcd_x >= SCREEN_WIDTH) return;

        self.fifo_check_window();
        self.fifo_step_fetcher();

        if (f.bg_len == 0) return; // fetcher still warming up — no pixel this dot

        if (f.discard > 0) {
            _ = self.fifo_pop_bg();
            f.discard -= 1;
            return;
        }

        // Pixel-output latch (calibration): hold the BG FIFO full for warmup dots
        // so the first emitted pixel — and thus every pixel — lands warmup dots
        // later, sampling registers warmup dots further into mode 3.
        if (f.warmup > 0) {
            f.warmup -= 1;
            return;
        }

        // Object fetch stalls: when the BG reaches an object's column, pause
        // emission for its precomputed fetch cost before drawing that pixel — so
        // the pixels after a sprite (and any mid-mode-3 write among them) land where
        // hardware draws them. Several objects due at the same column accumulate.
        {
            const lx: i16 = @intCast(f.lcd_x);
            var i: u8 = 0;
            while (i < f.obj_count) : (i += 1) {
                if (f.obj_stalled[i]) continue;
                if (f.objs[i].x > lx) continue; // BG has not reached it yet
                f.obj_stalled[i] = true;
                f.sprite_stall += f.obj_stall[i];
            }
        }
        if (f.sprite_stall > 0) {
            f.sprite_stall -= 1;
            return;
        }

        self.fifo_emit_pixel();
    }

    /// Finish the line: tick until all 160 pixels are emitted. Normally the
    /// analytic mode-3 length leaves the FIFO a handful of idle dots so this does
    /// nothing, but it guarantees a complete scanline regardless of any drift
    /// between the FIFO's natural length and mode3_length().
    fn fifo_flush(self: *GPU) void {
        var guard: u32 = 0;
        while (self.fifo.lcd_x < SCREEN_WIDTH and guard < 4000) : (guard += 1) {
            self.fifo_tick();
        }
    }

    /// Activate the window the first dot the current column reaches it. Clears the
    /// BG FIFO and restarts the fetcher in window mode (WX<7 starts the window off
    /// the left edge, so the leading 7-WX pixels are discarded).
    fn fifo_check_window(self: *GPU) void {
        const f = &self.fifo;
        if (f.window_triggered) return;
        const win_x: i16 = @as(i16, self.window_position.wx) - 7;
        if (self.lcdc.window_enable and self.lcdc.bg_window_enable and
            self.ly >= self.window_position.wy and win_x < 160 and
            @as(i16, @intCast(f.lcd_x)) >= win_x)
        {
            f.window_triggered = true;
            f.window = true;
            f.fetch_col = 0;
            f.fetch_phase = 0;
            f.fetch_sub = 0;
            f.first_fetch = false; // window trigger costs one fetch, not the dummy
            f.bg_len = 0;
            f.discard = if (win_x < 0) @intCast(-win_x) else 0;
        }
    }

    /// Step the BG/window fetcher one dot. Phases tile→low→high take two dots each;
    /// the assembled 8 pixels are pushed into the BG FIFO once it drains. The
    /// line's first fetch is thrown away (real hardware's 6-dot dummy fetch), which
    /// is what makes the minimum mode-3 length 172 rather than 166.
    fn fifo_step_fetcher(self: *GPU) void {
        const f = &self.fifo;
        if (f.fetch_phase == 3) {
            if (f.bg_len != 0) return; // FIFO still full — wait to push
            if (f.first_fetch) {
                f.first_fetch = false;
            } else {
                var i: u8 = 0;
                while (i < 8) : (i += 1) f.bg_pix[(f.bg_head +% i) & 7] = f.group[i];
                f.bg_len = 8;
                f.fetch_col +%= 1;
            }
            f.fetch_phase = 0;
            f.fetch_sub = 0;
            return;
        }
        if (f.fetch_sub == 0) {
            f.fetch_sub = 1;
            return;
        }
        f.fetch_sub = 0;
        f.fetch_phase += 1;
        if (f.fetch_phase == 3) self.fifo_fetch_tile();
    }

    /// Assemble the 8 colour-index pixels of the current BG or window tile column
    /// into the fetcher's group buffer, using the live tile-map / tile-data select.
    fn fifo_fetch_tile(self: *GPU) void {
        const f = &self.fifo;
        var lo: u8 = 0;
        var hi: u8 = 0;
        if (f.window) {
            const wrow: u16 = self.internal_window_counter -% 1;
            const map_base: u16 = if (self.lcdc.window_tile_map) 0x9C00 else 0x9800;
            const tile_index = self.read_vram(map_base + (wrow / 8) * 32 + f.fetch_col);
            const line = self.fifo_tile_line(tile_index, wrow & 7);
            lo = @truncate(line);
            hi = @truncate(line >> 8);
        } else {
            // BG row wraps mod 256 on hardware (8-bit add of LY and SCY). The
            // previous renderer used % 255, an off-by-one that misaligns any
            // scanline where ly+scy >= 255 by one row (mealybug m3_scy_change).
            const y: u8 = self.ly +% self.background_viewport.scy;
            const map_base: u16 = if (self.lcdc.bg_tile_map) 0x9C00 else 0x9800;
            const map_x: u16 = ((@as(u16, self.background_viewport.scx) >> 3) +% f.fetch_col) & 31;
            const tile_index = self.read_vram(map_base + (@as(u16, y) / 8) * 32 + map_x);
            const line = self.fifo_tile_line(tile_index, y & 7);
            lo = @truncate(line);
            hi = @truncate(line >> 8);
        }
        var p: u3 = 0;
        while (true) : (p += 1) {
            const bit: u3 = 7 - p;
            f.group[p] = (@as(u2, @truncate(hi >> bit)) & 1) << 1 | (@as(u2, @truncate(lo >> bit)) & 1);
            if (p == 7) break;
        }
    }

    /// Read a BG/window tile's two bit-plane bytes for row `tile_y`, honouring the
    /// 0x8000 (unsigned) vs 0x8800 (signed, base 0x9000) addressing select.
    fn fifo_tile_line(self: *GPU, tile_index: u8, tile_y: u16) u16 {
        if (self.lcdc.bg_window_tiles) {
            return self.read_vram16(0x8000 + @as(u16, tile_index) * 16 + tile_y * 2);
        }
        const signed: i16 = @as(i8, @bitCast(tile_index));
        var addr: u16 = 0x9000 + tile_y * 2;
        if (signed < 0) {
            addr -%= @intCast(@abs(signed) * 16);
        } else {
            addr +%= @intCast(signed * 16);
        }
        return self.read_vram16(addr);
    }

    fn fifo_pop_bg(self: *GPU) u2 {
        const f = &self.fifo;
        const v = f.bg_pix[f.bg_head & 7];
        f.bg_head +%= 1;
        f.bg_len -= 1;
        return v;
    }

    /// Merge every object now due at the current column (screen x == lcd_x, or
    /// already past it for off-left objects) into the OBJ FIFO. Lower-X objects are
    /// due earlier so they fill the FIFO first; an occupied slot is never
    /// overwritten, which gives the DMG "smaller X wins, then lower OAM index" rule.
    fn fifo_merge_sprites(self: *GPU) void {
        const f = &self.fifo;
        if (!self.lcdc.obj_enable) return;
        const lx: i16 = @intCast(f.lcd_x);
        const h: i16 = if (self.lcdc.obj_size) 16 else 8;
        var i: u8 = 0;
        while (i < f.obj_count) : (i += 1) {
            if (f.obj_done[i]) continue;
            const obj = f.objs[i];
            if (obj.x > lx) continue; // not due yet
            f.obj_done[i] = true;

            const row: i16 = @as(i16, @intCast(self.ly)) - obj.y; // 0..h-1
            const tile_y: u16 = @intCast(if (obj.attributes.y_flip) (h - 1 - row) else row);
            const tile_index: u8 = if (self.lcdc.obj_size) (obj.tile_index & 0xFE) else obj.tile_index;
            const line = self.read_vram16(0x8000 + (@as(u16, tile_index) << 4) + (tile_y << 1));
            const lo: u8 = @truncate(line);
            const hi: u8 = @truncate(line >> 8);
            const pal: u1 = if (obj.attributes.dmg_palette) 1 else 0;

            var p: u8 = 0;
            while (p < 8) : (p += 1) {
                const col: i16 = obj.x + @as(i16, @intCast(p));
                if (col < lx) continue; // pixel already shifted out (off-left)
                const slot: i16 = col - lx;
                if (slot >= 8) break; // beyond the 8-wide OBJ FIFO window
                if (col >= SCREEN_WIDTH) break; // off the right edge
                const uslot: usize = @intCast(slot);
                if (f.obj_color[uslot] != 0) continue; // earlier (higher-prio) object wins
                const bit: u3 = if (obj.attributes.x_flip) @intCast(p) else @intCast(7 - p);
                const cid: u2 = (@as(u2, @truncate(hi >> bit)) & 1) << 1 | (@as(u2, @truncate(lo >> bit)) & 1);
                if (cid == 0) continue; // transparent
                f.obj_color[uslot] = cid;
                f.obj_pal[uslot] = pal;
                f.obj_prio[uslot] = obj.attributes.priority;
            }
        }
    }

    /// Shift one finished pixel to the LCD: mix the BG/window colour-index with the
    /// front OBJ FIFO slot (respecting LCDC.0 BG-enable, OBJ-behind-BG priority, and
    /// transparency), write it to the canvas, then advance the OBJ FIFO and lcd_x.
    fn fifo_emit_pixel(self: *GPU) void {
        const f = &self.fifo;
        self.fifo_merge_sprites();

        const bg_raw = self.fifo_pop_bg();
        const bg_id: u2 = if (self.lcdc.bg_window_enable) bg_raw else 0;
        var color = GPU.color_from_palette(self.bgp, bg_id);

        const oc = f.obj_color[0];
        if (self.lcdc.obj_enable and oc != 0) {
            const behind = f.obj_prio[0] and bg_id != 0;
            if (!behind) color = GPU.color_from_palette(self.obp[f.obj_pal[0]], oc);
        }

        const px = @as(usize, self.ly) * SCREEN_WIDTH + f.lcd_x;
        const c = color.to_color();
        self.canvas[px * 3] = c;
        self.canvas[px * 3 + 1] = c;
        self.canvas[px * 3 + 2] = c;

        var i: usize = 0;
        while (i < 7) : (i += 1) {
            f.obj_color[i] = f.obj_color[i + 1];
            f.obj_pal[i] = f.obj_pal[i + 1];
            f.obj_prio[i] = f.obj_prio[i + 1];
        }
        f.obj_color[7] = 0;
        f.obj_pal[7] = 0;
        f.obj_prio[7] = false;

        f.lcd_x += 1;
    }

    /// Whether the CPU is locked out of OAM (mode 2/3). The lock is asymmetric: it
    /// engages immediately when the PPU enters mode 2/3 (true internal_mode) but
    /// releases one dot late (the register mode lags) — so OAM stays locked through
    /// the last dot of mode 3 (mooneye intr_2_oam_ok_timing) yet locks on the very
    /// first dot of the next line's OAM scan (mooneye lcdon_timing-GS).
    pub fn oam_locked(self: *const GPU) bool {
        if (!self.lcdc.lcd_enable) return false;
        return self.internal_mode == 2 or self.internal_mode == 3 or
            self.stat.ppu_mode == 2 or self.stat.ppu_mode == 3;
    }

    /// Whether the CPU is locked out of VRAM (mode 3), with the same immediate-lock
    /// / delayed-release asymmetry as oam_locked.
    pub fn vram_locked(self: *const GPU) bool {
        if (!self.lcdc.lcd_enable) return false;
        return self.internal_mode == 3 or self.stat.ppu_mode == 3;
    }

    /// Whether a CPU *write* to OAM is dropped. Writes lock a dot later than reads:
    /// at the mode 0->2 line boundary the write still lands (register mode is still
    /// 0) and at the mode 2->3 boundary there is a one-dot window where the write
    /// lands again (register mode 2, internal already 3) — so the block is the
    /// delayed register mode minus that transition dot (mooneye lcdon_write_timing).
    pub fn oam_write_blocked(self: *const GPU) bool {
        if (!self.lcdc.lcd_enable) return false;
        return self.stat.ppu_mode == 3 or (self.stat.ppu_mode == 2 and self.internal_mode == 2);
    }

    /// Whether a CPU *write* to VRAM is dropped — purely the delayed register mode 3
    /// (writes lock/release a dot later than reads; mooneye lcdon_write_timing-GS).
    pub fn vram_write_blocked(self: *const GPU) bool {
        if (!self.lcdc.lcd_enable) return false;
        return self.stat.ppu_mode == 3;
    }

    pub fn read_vram(self: *const GPU, address: usize) u8 {
        return self.vram[address];
    }

    pub fn read_vram16(self: *const GPU, address: usize) u16 {
        return @as(u16, self.vram[address]) | (@as(u16, self.vram[address +% 1]) << 8);
    }

    pub fn write_vram(self: *GPU, addr: usize, byte: u8) void {
        self.vram[addr] = byte;

        if (addr >= 0x9800) {
            return;
        }
        const normalized_addr = addr & 0xFFFE;
        const byte1 = self.vram[normalized_addr];
        const byte2 = self.vram[normalized_addr + 1];

        const index = (addr - VRAM_BEGIN);
        const tile_index = (index) / 16;
        const row_index = (index % 16) / 2;

        for (0..8) |pixel_index| {
            const mask = @as(u8, 1) << @intCast(7 - pixel_index);
            const low = @intFromBool((byte1 & mask) > 0);
            const high = @intFromBool((byte2 & mask) > 0);
            const pixel_value = @as(u2, low) | (@as(u2, high) << 1);

            self.tile_set[tile_index][row_index][pixel_index] = @enumFromInt(pixel_value);
        }
    }
    pub fn color_from_palette(palette: Palette, color: u2) TilePixelValue {
        return switch (color) {
            0b00 => return palette.color_0,
            0b01 => return palette.color_1,
            0b10 => return palette.color_2,
            0b11 => return palette.color_3,
        };
    }

    pub fn write_oam(self: *GPU, addr: usize, value: u8) void {
        std.debug.assert(addr >= OAM_BEGIN and addr <= OAM_END);
        self.vram[addr] = value;
        const object_index = (addr - OAM_BEGIN) / 4;
        if (object_index >= 40) {
            return;
        }

        // objects are 4 bytes, select the byte and switch on which part of the object to update
        const byte = (addr - OAM_BEGIN) % 4;
        switch (byte) {
            // Signed subtraction: sprites partially off the top/left have negative on-screen
            // positions (OAM stores Y+16, X+8). Doing this in u8 wrapped -8 to 248, so the
            // off-edge half was culled / pushed off-screen.
            0 => self.objects[object_index].y = @as(i16, value) - 0x10,
            1 => self.objects[object_index].x = @as(i16, value) - 0x08,
            2 => self.objects[object_index].tile_index = value,
            3 => self.objects[object_index].attributes = @bitCast(value),
            else => {},
        }
    }
};
