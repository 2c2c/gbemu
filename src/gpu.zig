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
    return .{.{.Zero} ** 8} ** 8;
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
    cycles: usize,

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

        const objects = [_]Object{.{
            .y = 0,
            .x = 0,
            .tile_index = 0,
            .attributes = @bitCast(@as(u8, 0)),
        }} ** 40;

        return GPU{
            .tile_canvas = [_]u8{0} ** DRAW_WIDTH ** DRAW_HEIGHT,
            .canvas = [_]u8{0} ** (DRAW_WIDTH * DRAW_HEIGHT * 3),
            .full_bg_canvas = [_]u8{0} ** (BACKGROUND_WIDTH * BACKGROUND_HEIGHT * 3),
            .palette_canvas = [_]u8{0} ** (8 * 8 * 4 * 3 * 3),
            .vram = [_]u8{0} ** 0x10000,
            .tile_set = .{empty_tile()} ** 384,
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
        };
    }

    /// update the respective IF flag with the respective true result
    const IFEnableRequests = struct {
        lcd_stat: bool,
        vblank: bool,
    };
    pub fn step(self: *GPU, cycles: u64) IFEnableRequests {
        var updated_flags = IFEnableRequests{ .lcd_stat = false, .vblank = false };
        if (!self.lcdc.lcd_enable) {
            return updated_flags;
        }

        self.cycles += cycles;

        switch (self.stat.ppu_mode) {
            // Horizontal blank
            0b00 => {
                if (self.cycles >= 204) {
                    self.cycles = self.cycles % 204;
                    self.ly += 1;

                    if (self.ly >= 144) {
                        // if (self.ly >= 90) {
                        self.stat.ppu_mode = 0b01;
                        updated_flags.vblank = true;
                        if (self.stat.mode_1_interrupt_enabled) {
                            updated_flags.lcd_stat = true;
                        }
                    } else {
                        self.stat.ppu_mode = 0b10;
                        if (self.stat.mode_2_interrupt_enabled) {
                            updated_flags.lcd_stat = true;
                        }
                    }
                    self.lyc_ly_check(&updated_flags);
                }
            },
            // Vertical blank
            0b01 => {
                if (self.cycles >= 456) {
                    self.cycles = self.cycles % 456;
                    self.ly += 1;
                    if (self.ly >= 154) {
                        self.ly = 0;
                        self.internal_window_counter = 0;
                        self.stat.ppu_mode = 0b10;
                        if (self.stat.mode_2_interrupt_enabled) {
                            updated_flags.lcd_stat = true;
                        }
                        // self.render_full_bg();
                    }
                    self.lyc_ly_check(&updated_flags);
                }
            },
            // OAM read
            0b10 => {
                if (self.cycles >= 80) {
                    self.cycles = self.cycles % 80;
                    self.stat.ppu_mode = 0b11;
                }
            },
            // VRAM read
            0b11 => {
                if (self.cycles >= 172) {
                    self.cycles = self.cycles % 172;
                    if (self.stat.mode_0_interrupt_enabled) {
                        updated_flags.lcd_stat = true;
                    }
                    self.stat.ppu_mode = 0b00;
                    self.render_scanline();

                    // log.debug("scx {} scy {} ly {}  wx {} wy {}\n", .{
                    //     self.background_viewport.scx,
                    //     self.background_viewport.scy,
                    //     self.ly,
                    //     self.window_position.wx,
                    //     self.window_position.wy,
                    // });

                    // log.debug("BGP 0b{b:0>8} OBP0 0b{b:0>8} OBP1 0b{b:0>8}\n", .{
                    //     @as(u8, @bitCast(self.bgp)),
                    //     @as(u8, @bitCast(self.obp[0])),
                    //     @as(u8, @bitCast(self.obp[1])),
                    // });
                }
            },
        }
        // log.debug("cycles {} ly {} ppu_mode {}\n", .{ self.cycles, self.ly, self.stat.ppu_mode });
        return updated_flags;
    }

    fn lyc_ly_check(self: *GPU, request: *IFEnableRequests) void {
        const check = self.ly == self.lyc;
        if (check and self.stat.lyc_int_interrupt_enabled) {
            request.lcd_stat = true;
        }
        self.stat.lyc_ly_compare = check;
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
        var renderable_objects = std.ArrayList(Object).init(allocator);
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

        var objectpair_hash = std.AutoHashMap(i16, std.ArrayList(ObjectIndexPair)).init(allocator);
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
                gop.value_ptr.* = std.ArrayList(ObjectIndexPair).init(allocator);
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
            var identical_x_objects = std.ArrayList(Object).init(allocator);
            defer identical_x_objects.deinit();
            for (objectpairs.*.items) |objectpair| {
                identical_x_objects.append(objectpair.object) catch unreachable;
            }

            self.render_objects_list(identical_x_objects);
        }
    }

    pub fn render_objects_list(self: *GPU, renderable_objects: std.ArrayList(Object)) void {
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
                    const draw_x = @as(usize, @intCast(object.x)) + x;
                    if (draw_x >= 0 and draw_x < SCREEN_WIDTH) {
                        const buffer_index: usize = @as(usize, self.ly) * SCREEN_WIDTH * 3 + @as(usize, draw_x) * 3;
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
            0 => self.objects[object_index].y = value -% 0x10,
            1 => self.objects[object_index].x = value -% 0x08,
            2 => self.objects[object_index].tile_index = value,
            3 => self.objects[object_index].attributes = @bitCast(value),
            else => {},
        }
    }
};
