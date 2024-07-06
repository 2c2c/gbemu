const std = @import("std");
const IERegister = @import("ie_register.zig").IERegister;

pub const VRAM_BEGIN: u16 = 0x8000;
pub const VRAM_END: u16 = 0x9FFF;
// const VRAM_SIZE: usize = VRAM_END - VRAM_BEGIN + 1;

pub const TilePixelValue = enum {
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

const Object = packed struct {
    y: u8,
    x: u8,
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

/// FF04
/// 16384Hz increment. writing to it sets to 0. continuing from stop resets to 0
const DIV = 0;

/// FF05
/// when overflows, resets to TMA + interrupt is called
const TIMA: u8 = 0;
/// FF06
/// Timer Modulo
///
const TMA: u8 = 0;
/// FF07
const TAC = packed struct {
    /// 4096, 262144, 65536, 16384
    frequency: u2,
    enabled: bool,
    _padding: u5 = 0,
};

/// FF40 LCD Control
const LCDC = packed struct {
    bg_enable: bool,
    obj_enable: bool,

    /// 8x8 8x16
    obj_size: bool,

    /// 0x9800-0x9BFF 0x9C00-0x9FFF
    bg_tile_map: bool,

    /// 0x8800-0x97FF 0x8000-0x8FFF
    bg_tile_set: bool,

    window_enable: bool,

    /// 0x9800-0x9BFF 0x9C00-0x9FFF
    window_tile_map: bool,

    lcd_enable: bool,
};

/// FF41 STAT LCD Status
const Stat = packed struct {
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
    color_0: u2,
    color_1: u2,
    color_2: u2,
    color_3: u2,
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

const SCREEN_WIDTH: usize = 160;
const SCREEN_HEIGHT: usize = 144;
const SCALE: usize = 1;

pub const GPU = struct {
    canvas: [SCREEN_WIDTH * SCREEN_HEIGHT * SCALE * 3]u8,
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

    /// FF45
    /// LY == LYC trigger STAT interrupt
    /// 0-153
    lyc: u8,
    cycles: usize,

    pub fn new() GPU {
        const obp: [2]Palette = .{
            .{ .color_0 = 0, .color_1 = 1, .color_2 = 2, .color_3 = 3 },
            .{ .color_0 = 0, .color_1 = 1, .color_2 = 2, .color_3 = 3 },
        };
        const objects = [_]Object{.{
            .y = 0,
            .x = 0,
            .tile_index = 0,
            .attributes = @bitCast(@as(u8, 0)),
        }} ** 40;
        return GPU{
            .canvas = [_]u8{0} ** (SCREEN_WIDTH * SCREEN_HEIGHT * SCALE * 3),
            .vram = [_]u8{0} ** 0x10000,
            .tile_set = .{empty_tile()} ** 384,
            // ai says htis is default value
            .lcdc = @bitCast(@as(u8, 0x91)),
            .stat = @bitCast(@as(u8, 0x05)),
            .background_viewport = .{ .scy = 0, .scx = 1 },
            .ly = 0,
            .lyc = 0,
            .bgp = @bitCast(@as(u8, 0xFC)),
            .obp = obp,
            .objects = objects,
            .window_position = .{ .wy = 0, .wx = 0 },
            .cycles = 0,
        };
    }

    pub fn step(self: *GPU, cycles: u64) IERegister {
        var request: IERegister = @bitCast(@as(u8, 0));
        if (!self.lcdc.lcd_enable) {
            return request;
        }

        self.cycles += cycles;

        // std.debug.print("GPU STEP cycles: {}, ly: {}, mode: {}\n", .{ self.cycles, self.ly, self.stat.ppu_mode });
        switch (self.stat.ppu_mode) {
            // Horizontal blank
            0b00 => {
                if (self.cycles >= 204) {
                    self.cycles = self.cycles % 204;
                    self.ly += 1;

                    if (self.ly >= 144) {
                        self.stat.ppu_mode = 0b01;
                        request.enable_vblank = true;
                        if (self.stat.mode_1_interrupt_enabled) {
                            request.enable_lcd_stat = true;
                        }
                    } else {
                        self.stat.ppu_mode = 0b10;
                        if (self.stat.mode_2_interrupt_enabled) {
                            request.enable_lcd_stat = true;
                        }
                    }
                    self.lyc_ly_check(&request);
                }
            },
            // Vertical blank
            0b01 => {
                if (self.cycles >= 456) {
                    self.cycles = self.cycles % 456;
                    self.ly += 1;
                    if (self.ly >= 154) {
                        self.ly = 0;
                        self.stat.ppu_mode = 0b10;
                        if (self.stat.mode_2_interrupt_enabled) {
                            request.enable_lcd_stat = true;
                        }
                    }
                    self.lyc_ly_check(&request);
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
                        request.enable_lcd_stat = true;
                    }
                    self.stat.ppu_mode = 0b00;
                    self.render_scanline();
                }
                // render scan line
            },
        }
        return request;
    }

    fn lyc_ly_check(self: *GPU, request: *IERegister) void {
        const check = self.ly == self.lyc;
        if (check and self.stat.lyc_int_interrupt_enabled) {
            request.enable_lcd_stat = true;
        }
        self.stat.lyc_ly_compare = check;
    }

    fn render_scanline(self: *GPU) void {
        var scan_line: [SCREEN_WIDTH]TilePixelValue = [_]TilePixelValue{.Zero} ** SCREEN_WIDTH;
        if (self.lcdc.bg_enable) {
            var tile_x_index = self.background_viewport.scx / 8;
            const tile_y_index = self.ly +% self.background_viewport.scy;
            const tile_offset: u16 = (@as(u16, tile_y_index) / 8) * 32;

            const background_tile_map: u16 = if (self.lcdc.bg_tile_map) 0x9C00 else 0x9800;
            const tile_map_begin = background_tile_map;
            const tile_map_offset = tile_map_begin +% tile_offset;
            const row_y_offset = tile_y_index % 8;
            var pixel_x_index = self.background_viewport.scx % 8;
            if (!self.lcdc.bg_tile_set) {
                // handle 0x8800-0x97FF
                std.debug.panic("Implement 0x8800-0x97FF\n", .{});
            }
            var canvas_offset: usize = @as(usize, self.ly) * SCREEN_WIDTH * SCALE * 3;
            for (0..SCREEN_WIDTH) |line_x| {
                const tile_index = self.vram[tile_map_offset +% tile_x_index];
                const tile_value = self.tile_set[tile_index][row_y_offset][pixel_x_index];
                const color = tile_value.to_color();
                self.canvas[canvas_offset] = color;
                self.canvas[canvas_offset +% 1] = color;
                self.canvas[canvas_offset +% 2] = color;
                // why
                // alpha
                // self.canvas[canvas_offset +% 3] = 0xFF;
                // canvas_offset += 4;
                canvas_offset += 3;

                scan_line[line_x] = tile_value;
                pixel_x_index = (pixel_x_index + 1) % 8;

                if (pixel_x_index == 0) {
                    // tile_x_index = (tile_x_index + 1) % 32;
                    // tile_map_offset = tile_map_begin +% tile_offset +% tile_x_index;
                    tile_x_index += 1;
                }
                if (!self.lcdc.bg_tile_set) {
                    // handle 0x8800-0x97FF
                    std.debug.panic("Implement 0x8800-0x97FF\n", .{});
                }
            }
        }
        if (self.lcdc.obj_enable) {
            const object_height: u8 = if (self.lcdc.obj_size) 16 else 8;
            for (self.objects) |object| {
                if (object.y <= self.ly and object.y + object_height > self.ly) {
                    const pixel_y_offset = self.ly - object.y;
                    const tile_index: u8 = if ((object_height == 16) and (!object.attributes.y_flip and pixel_y_offset > 7)) blk: {
                        break :blk object.tile_index + 1;
                    } else blk: {
                        break :blk object.tile_index;
                    };

                    const tile = self.tile_set[tile_index];
                    const tile_row = if (object.attributes.y_flip) tile[7 - (pixel_y_offset % 8)] else tile[pixel_y_offset % 8];

                    // why signed
                    // const canvas_y_offset: i32 = @as(i32, self.ly) * @as(i32, SCREEN_WIDTH) * SCALE;
                    const canvas_y_offset: usize = @as(usize, self.ly) * @as(usize, SCREEN_WIDTH) * SCALE;
                    // var canvas_offset: usize = @intCast(@as(u32, canvas_y_offset + object.x) * SCALE);
                    var canvas_offset: usize = (canvas_y_offset + object.x) * SCALE * 3;
                    for (0..8) |x| {
                        const pixel_x_offset: usize = if (object.attributes.x_flip) 7 - x else x;
                        const x_offset = object.x + x;
                        const pixel = tile_row[pixel_x_offset];
                        if (x_offset >= 0 and
                            x_offset < SCREEN_WIDTH and
                            pixel != TilePixelValue.Zero and
                            (object.attributes.priority or scan_line[x_offset] == TilePixelValue.Zero))
                        {
                            const color = pixel.to_color();
                            self.canvas[canvas_offset] = color;
                            self.canvas[canvas_offset +% 1] = color;
                            self.canvas[canvas_offset +% 2] = color;
                            // self.canvas[canvas_offset +% 3] = 0xFF;
                            canvas_offset += 3;
                        }
                    }
                }
            }
        }
        if (self.lcdc.window_enable) {
            // TODO:
        }
    }
    pub fn read_vram(self: *const GPU, address: usize) u8 {
        return self.vram[address];
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
    pub fn write_oam(self: *GPU, addr: usize, value: u8) void {
        std.debug.assert(addr >= 0xFE00 and addr < 0xFEA0);
        self.vram[addr] = value;
        const object_index = (addr - 0xFE00) / 4;
        if (object_index >= 40) {
            return;
        }

        // could be cut, just lookup straight from memory instead
        const byte = (addr - 0xFE00) % 4;
        switch (byte) {
            0 => self.objects[object_index].y = value + 0x10,
            1 => self.objects[object_index].x = value + 0x08,
            2 => self.objects[object_index].tile_index = value,
            3 => self.objects[object_index].attributes = @bitCast(value),
            else => {},
        }
    }
};
