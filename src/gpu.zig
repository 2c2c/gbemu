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

        // Latch this line's mode-3 length when pixel transfer begins (samples SCX).
        if (self.ly < VBLANK_LY and dot == m3_start) {
            self.line3_len = self.mode3_length();
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

        if (mode != self.internal_mode) {
            // Pixel transfer just finished: emit the scanline for this line.
            if (mode == 0 and self.internal_mode == 3) self.render_scanline();
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

    fn render_scanline(self: *GPU) void {
        self.render_bg();
        self.render_objects();
    }

    fn render_palettes(self: *GPU) void {
        const palette_sets = 3;
        const colors_per_palette = 4;
        const tile_size = 8;
        const rgb_values = 3;

        for (0..palette_sets) |palette_index| {
            const palette = blk: {
                switch (palette_index) {
                    0 => break :blk self.bgp,
                    1 => break :blk self.obp0,
                    2 => break :blk self.obp1,
                    else => unreachable,
                }
            };

            for (0..colors_per_palette) |color_index| {
                const color = GPU.color_from_palette(palette, @truncate(color_index));
                const x = color_index * tile_size;
                const y = palette_index * tile_size;

                for (0..tile_size) |ty| {
                    for (0..tile_size) |tx| {
                        const pixel_x = x + tx;
                        const pixel_y = y + ty;
                        const pixel_index = (pixel_y * (tile_size * colors_per_palette) + pixel_x) * rgb_values;

                        self.palette_canvas[pixel_index] = color[0];
                        self.palette_canvas[pixel_index + 1] = color[1];
                        self.palette_canvas[pixel_index + 2] = color[2];
                    }
                }
            }
        }
    }
    fn render_full_bg(self: *GPU) void {
        const bg_tile_map_base: usize = if (self.lcdc.bg_tile_map) 0x9C00 else 0x9800;
        const tile_base: usize = if (self.lcdc.bg_window_tiles) 0x8000 else 0x8800;

        for (0..BACKGROUND_HEIGHT - 1) |y| {
            for (0..BACKGROUND_WIDTH - 1) |x| {
                var tile_line: u16 = 0;
                var tile_x: u3 = 0;

                const tile_y = y % 8;
                tile_x = @truncate(x % 8);

                const tile_addr = bg_tile_map_base + (y / 8 * 32) + (x / 8);
                const tile_index = self.read_vram(tile_addr);
                if (tile_base == 0x8000) {
                    tile_line = self.read_vram16(tile_base + (tile_index * 16) + tile_y * 2);
                } else {
                    const tile_index_signed = @as(i16, @as(u8, @intCast(tile_index)));
                    var addr = 0x9000 + tile_y * 2;
                    if (tile_index_signed < 0) {
                        addr -= @abs(tile_index_signed * 16);
                    } else {
                        addr += @abs(tile_index_signed * 16);
                    }
                    tile_line = self.read_vram16(addr);
                }

                // log.debug("{},{} tb 0x{x} tmp 0x{x}+{x} tile_addr 0x{x} tile_index 0x{x} tile_line 0x{x}\n", .{
                //     x,
                //     y,
                //     tile_base,
                //     bg_tile_map_base,
                //     y * 32 + x / 8,
                //     tile_addr,
                //     tile_index,
                //     tile_line,
                // });
                const high: u8 = @as(u8, @truncate(tile_line >> 8)) & 0xFF;
                const low: u8 = @as(u8, @truncate(tile_line)) & 0xFF;
                const color_id: u2 = (@as(u2, @truncate(high >> (7 - tile_x))) & 1) << 1 | (@as(u2, @truncate(low >> (7 - tile_x))) & 1);
                const color: TilePixelValue = GPU.color_from_palette(self.bgp, color_id);
                const pixel_index = (y * BACKGROUND_WIDTH + x) * 3;
                self.full_bg_canvas[pixel_index] = color.to_color();
                self.full_bg_canvas[pixel_index + 1] = color.to_color();
                self.full_bg_canvas[pixel_index + 2] = color.to_color();
            }
        }
    }
    fn render_full_bg2(self: *GPU) void {
        var buffer_index = @as(usize, self.ly) * BACKGROUND_WIDTH * 3;
        const win_x: i16 = @as(i16, self.window_position.wx) - 7; // Adjust to potentially handle negative values
        const win_y = self.window_position.wy;

        const bg_tile_map_base: u16 = if (self.lcdc.bg_tile_map) 0x9C00 else 0x9800;
        const tile_base: u16 = if (self.lcdc.bg_window_tiles) 0x8000 else 0x8800;
        const win_tile_map_base: u16 = if (self.lcdc.window_tile_map) 0x9C00 else 0x9800;
        const win_tile_base: u16 = if (self.lcdc.bg_window_tiles) 0x8000 else 0x8800;

        if (self.ly == win_y) {
            self.internal_window_counter = 0;
        }

        if (self.lcdc.window_enable and self.ly >= win_y and self.lcdc.bg_window_enable and win_x < 160) {
            self.internal_window_counter += 1;
        }

        var x: u16 = 0;
        while (x < BACKGROUND_WIDTH) : (x += 1) {
            var tile_line: u16 = 0;
            var tile_x: u3 = 0;

            if (self.lcdc.window_enable and self.ly >= win_y and x >= win_x and self.lcdc.bg_window_enable and win_x < 160) {
                const adjusted_y: u16 = self.internal_window_counter - 1;
                const temp_x: i16 = @as(i16, @intCast(x)) - win_x;
                const tile_y: u8 = @truncate(adjusted_y & 7);
                tile_x = @truncate(@as(u16, @bitCast(temp_x)) & 7);

                // const tile_index: u8 = self.read_vram(win_tile_map_base + ((@as(u16, adjusted_y) / 8) * 32) + (@as(u16, @bitCast(temp_x)) / 8));
                const tile_index: u8 = self.read_vram(win_tile_map_base + ((@as(u16, adjusted_y) / 8) * 32) + (@as(u16, @bitCast(temp_x)) / 8));
                if (tile_base == 0x8000) {
                    tile_line = self.read_vram16(win_tile_base + (@as(u16, tile_index) * 16) + @as(u16, tile_y) * 2);
                } else {
                    const tile_index_signed = @as(i16, @as(i8, @bitCast(tile_index)));
                    var addr: u16 = 0x9000 + @as(u16, tile_y) * 2;
                    if (tile_index_signed < 0) {
                        addr -= @abs(tile_index_signed * 16);
                    } else {
                        addr += @abs(tile_index_signed * 16);
                    }
                    tile_line = self.read_vram16(addr);
                }
            } else if (self.lcdc.bg_window_enable) {
                const y_coord = @as(u16, self.ly) + @as(u16, self.background_viewport.scy);
                const tile_y = y_coord % 8;

                const x_coord = ((@as(u16, self.background_viewport.scx) / 8) + x) & 31;
                tile_x = @truncate(x_coord % 8);

                const tile_index = self.read_vram(bg_tile_map_base + (((@as(u16, y_coord) / 8) * 32) & 0x3FF) + (x_coord)); // & 31?
                if (tile_base == 0x8000) {
                    tile_line = self.read_vram16(tile_base + (@as(u16, tile_index) * 16) + @as(u16, tile_y) * 2);
                } else {
                    const tile_index_signed = @as(i16, @as(i8, @bitCast(tile_index)));
                    var addr: u16 = 0x9000 + @as(u16, tile_y) * 2;
                    if (tile_index_signed < 0) {
                        addr -= @abs(tile_index_signed * 16);
                    } else {
                        addr += @abs(tile_index_signed * 16);
                    }
                    tile_line = self.read_vram16(addr);
                }
            }

            const high: u8 = @as(u8, @truncate(tile_line >> 8)) & 0xFF;
            const low: u8 = @as(u8, @truncate(tile_line)) & 0xFF;
            const color_id: u2 = (@as(u2, @truncate(high >> (7 - tile_x))) & 1) << 1 | (@as(u2, @truncate(low >> (7 - tile_x))) & 1);
            const color: TilePixelValue = GPU.color_from_palette(self.bgp, color_id);
            // self.tile_canvas[buffer_index / 3] = color;
            self.full_bg_canvas[buffer_index] = color.to_color();
            self.full_bg_canvas[buffer_index +% 1] = color.to_color();
            self.full_bg_canvas[buffer_index +% 2] = color.to_color();
            buffer_index += 3;
        }
    }

    fn render_bg(self: *GPU) void {
        var buffer_index = @as(usize, self.ly) * SCREEN_WIDTH * 3;
        var x: u8 = 0;
        const win_x: i16 = @as(i16, self.window_position.wx) - 7; // Adjust to potentially handle negative values
        const win_y = self.window_position.wy;

        const bg_tile_map_base: u16 = if (self.lcdc.bg_tile_map) 0x9C00 else 0x9800;
        const tile_base: u16 = if (self.lcdc.bg_window_tiles) 0x8000 else 0x8800;
        const win_tile_map_base: u16 = if (self.lcdc.window_tile_map) 0x9C00 else 0x9800;
        const win_tile_base: u16 = if (self.lcdc.bg_window_tiles) 0x8000 else 0x8800;

        if (self.ly == win_y) {
            self.internal_window_counter = 0;
        }

        if (self.lcdc.window_enable and self.ly >= win_y and self.lcdc.bg_window_enable and win_x < 160) {
            self.internal_window_counter += 1;
        }

        while (x < 160) : (x += 1) {
            var tile_line: u16 = 0;
            var tile_x: u3 = 0;

            if (self.lcdc.window_enable and self.ly >= win_y and x >= win_x and self.lcdc.bg_window_enable and win_x < 160) {
                const adjusted_y: u16 = self.internal_window_counter - 1;
                const temp_x: i16 = x - win_x;
                const tile_y: u8 = @truncate(adjusted_y & 7);
                tile_x = @truncate(@as(u16, @bitCast(temp_x)) & 7);

                const tile_index: u8 = self.read_vram(win_tile_map_base + ((@as(u16, adjusted_y) / 8) * 32) + (@as(u16, @bitCast(temp_x)) / 8));
                if (tile_base == 0x8000) {
                    tile_line = self.read_vram16(win_tile_base + (@as(u16, tile_index) * 16) + @as(u16, tile_y) * 2);
                } else {
                    const tile_index_signed = @as(i16, @as(i8, @bitCast(tile_index)));
                    var addr: u16 = 0x9000 + @as(u16, tile_y) * 2;
                    if (tile_index_signed < 0) {
                        addr -= @abs(tile_index_signed * 16);
                    } else {
                        addr += @abs(tile_index_signed * 16);
                    }
                    tile_line = self.read_vram16(addr);
                }
            } else if (self.lcdc.bg_window_enable) {
                const y = (@as(u16, self.ly) + @as(u16, self.background_viewport.scy)) % 255;
                const tile_y = y % 8;

                const temp_x = self.background_viewport.scx +% x;
                tile_x = @truncate((x +% self.background_viewport.scx) % 8);

                const tile_index = self.read_vram(bg_tile_map_base + ((@as(u16, y) / 8) * 32) + ((temp_x / 8) & 31));
                if (tile_base == 0x8000) {
                    tile_line = self.read_vram16(tile_base + (@as(u16, tile_index) * 16) + @as(u16, tile_y) * 2);
                } else {
                    const tile_index_signed = @as(i16, @as(i8, @bitCast(tile_index)));
                    var addr: u16 = 0x9000 + @as(u16, tile_y) * 2;
                    if (tile_index_signed < 0) {
                        addr -= @abs(tile_index_signed * 16);
                    } else {
                        addr += @abs(tile_index_signed * 16);
                    }
                    tile_line = self.read_vram16(addr);
                }
                // log.debug("x {} y {} scx {} scy {} ly {}\n", .{
                //     x,
                //     y,
                //     self.background_viewport.scx,
                //     self.background_viewport.scy,
                //     self.ly,
                // });
            }

            const high: u8 = @as(u8, @truncate(tile_line >> 8)) & 0xFF;
            const low: u8 = @as(u8, @truncate(tile_line)) & 0xFF;
            const color_id: u2 = (@as(u2, @truncate(high >> (7 - tile_x))) & 1) << 1 | (@as(u2, @truncate(low >> (7 - tile_x))) & 1);
            const color: TilePixelValue = GPU.color_from_palette(self.bgp, color_id);

            self.tile_canvas[buffer_index / 3] = color_id;
            self.canvas[buffer_index] = color.to_color();
            self.canvas[buffer_index +% 1] = color.to_color();
            self.canvas[buffer_index +% 2] = color.to_color();
            buffer_index += 3;
        }
    }

    pub fn render_objects(self: *GPU) void {
        if (!self.lcdc.obj_enable) {
            return;
        }
        const object_height: u8 = if (self.lcdc.obj_size) 16 else 8;

        // there is a limit of 10 objects per scanline
        var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_allocator.deinit();
        const allocator = arena_allocator.allocator();
        var renderable_objects = std.array_list.Managed(Object).init(allocator);
        defer renderable_objects.deinit();
        for (self.objects) |object| {
            const start_y = object.y;
            const end_y = start_y + object_height;
            if (start_y <= self.ly and end_y > self.ly) {
                renderable_objects.append(object) catch unreachable;
            }
            if (renderable_objects.items.len == 10) {
                break;
            }
        }

        // there are two difficult forms of priority
        // * an object more leftward takes priority over something to its right
        // * two objects with the same x, the one with the lower oam index takes priority
        //
        // Sort objects by x position, descending. overlapping leftmosttiles will always overwrite rightmost tiles
        // Hash objects by x position inside an array. sort those arrays by oam index, descending. the leftmost oam indexed tile will always overwrite the rightmost
        // iterate through the first, then do a second pass against the hash for any array with more than one object
        const ObjectIndexPair = struct {
            object: Object,
            index: usize,
        };

        var objectpair_hash = std.AutoHashMap(i16, std.array_list.Managed(ObjectIndexPair)).init(allocator);
        defer {
            var itr = objectpair_hash.valueIterator();
            while (itr.next()) |objects| {
                objects.deinit();
            }
            objectpair_hash.deinit();
        }

        for (renderable_objects.items, 0..) |object, oam_index| {
            const gop = objectpair_hash.getOrPut(object.x) catch unreachable;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.array_list.Managed(ObjectIndexPair).init(allocator);
            }
            const pair = ObjectIndexPair{ .object = object, .index = oam_index };
            gop.value_ptr.*.append(pair) catch unreachable;
        }

        const comparator = struct {
            pub fn object_index(_: void, a: ObjectIndexPair, b: ObjectIndexPair) bool {
                return a.index > b.index;
            }
            pub fn object_x(_: void, a: Object, b: Object) bool {
                return a.x > b.x;
            }
        };

        var keys = objectpair_hash.keyIterator();
        while (keys.next()) |key| {
            const objects = objectpair_hash.getPtr(key.*).?;
            std.mem.sort(ObjectIndexPair, objects.*.items, {}, comparator.object_index);
        }

        std.mem.sort(Object, renderable_objects.items, {}, comparator.object_x);

        self.render_objects_list(renderable_objects);

        // do a second pass on objects with the same object.x position
        var objectpairs_itr = objectpair_hash.valueIterator();
        while (objectpairs_itr.next()) |objectpairs| {
            if (objectpairs.*.items.len <= 1) {
                continue;
            }
            var identical_x_objects = std.array_list.Managed(Object).init(allocator);
            defer identical_x_objects.deinit();
            for (objectpairs.*.items) |objectpair| {
                identical_x_objects.append(objectpair.object) catch unreachable;
            }

            self.render_objects_list(identical_x_objects);
        }
    }

    pub fn render_objects_list(self: *GPU, renderable_objects: std.array_list.Managed(Object)) void {
        for (renderable_objects.items) |object| {
            if (self.ly < SCREEN_HEIGHT) {
                var tile_y: i16 = undefined;
                if (self.lcdc.obj_size) {
                    tile_y = if (object.attributes.y_flip) 15 -% (self.ly - (object.y)) else ((self.ly -% (object.y)) & 15);
                } else {
                    tile_y = if (object.attributes.y_flip) 7 -% (self.ly - (object.y)) else ((self.ly -% (object.y)) & 7);
                }

                const palette = if (object.attributes.dmg_palette) self.obp[1] else self.obp[0];
                const tile_index = if (self.lcdc.obj_size) object.tile_index & 0xFE else object.tile_index;

                for (0..8) |x| {
                    const draw_x: i16 = object.x + @as(i16, @intCast(x));
                    if (draw_x >= 0 and draw_x < SCREEN_WIDTH) {
                        const buffer_index: usize = @as(usize, self.ly) * SCREEN_WIDTH * 3 + @as(usize, @intCast(draw_x)) * 3;
                        const tile_line = self.read_vram16(0x8000 + (@as(u16, tile_index) << 4) + (@as(u16, @bitCast(tile_y)) << 1));
                        const tile_x: u3 = if (object.attributes.x_flip) 7 -% @as(u3, @truncate(x)) else @as(u3, @truncate(x));
                        const high: u8 = @as(u8, @truncate(tile_line >> 8));
                        const low: u8 = @as(u8, @truncate(tile_line)) & 0xFF;
                        const color_id: u2 = (@as(u2, @truncate(high >> (7 - tile_x))) & 1) << 1 | (@as(u2, @truncate(low >> (7 - tile_x))) & 1);
                        const color: TilePixelValue = GPU.color_from_palette(palette, color_id);

                        const draw_over_bg_and_window = !object.attributes.priority or
                            (object.attributes.priority and self.tile_canvas[buffer_index / 3] == 0);

                        if (draw_over_bg_and_window and color_id != 0) {
                            self.tile_canvas[buffer_index / 3] = color_id;
                            self.canvas[buffer_index] = color.to_color();
                            self.canvas[buffer_index + 1] = color.to_color();
                            self.canvas[buffer_index + 2] = color.to_color();
                        }
                    }
                }
            }
        }
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
