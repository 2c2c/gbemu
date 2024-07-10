const std = @import("std");
const IERegister = @import("ie_register.zig").IERegister;

pub const VRAM_BEGIN: u16 = 0x8000;
pub const VRAM_END: u16 = 0x9FFF;
// const VRAM_SIZE: usize = VRAM_END - VRAM_BEGIN + 1;
//
pub const OAM_BEGIN: usize = 0xFE00;
pub const OAM_END: usize = 0xFE9F;
pub const OAM_SIZE: usize = OAM_END - OAM_BEGIN + 1;

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

pub const GPU = struct {
    canvas: [SCREEN_WIDTH * SCREEN_HEIGHT * 3]u8,
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
            .canvas = [_]u8{0} ** (SCREEN_WIDTH * SCREEN_HEIGHT * 3),
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
                        // if (self.ly >= 90) {
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
        self.render_bg();
        self.render_objects();
    }

    fn render_bg(self: *GPU) void {
        var buffer_index = @as(usize, self.ly) * SCREEN_WIDTH * 3;
        var x: u8 = 0;
        // std.debug.print("render_bg ly={x} scy={x}\n", .{ self.ly, self.background_viewport.scy });
        var y: u16 = @as(u16, self.ly) + @as(u16, self.background_viewport.scy);
        // const win_x: i16 = @as(i16, @as(i8, @bitCast(self.window_position.wx))) - @as(u16, 7);
        const win_x: u8 = @max(self.window_position.wx, 7) - 7;
        // const win_x: u8 = @max(self.window_position.wx, 7);
        const win_y = self.window_position.wy;

        const render_window = self.lcdc.window_enable and win_y <= self.ly and win_x <= x;
        const bg_tile_map_base: u16 = if (self.lcdc.bg_tile_map) 0x9C00 else 0x9800;
        const tile_base: u16 = if (self.lcdc.bg_tile_set) 0x8000 else 0x8800;
        const win_tile_map_base: u16 = if (self.lcdc.window_tile_map) 0x9C00 else 0x9800;
        const win_tile_base: u16 = if (self.lcdc.bg_tile_set) 0x8000 else 0x8800;

        while (x < 160) : (x += 1) {
            var tile_line: u16 = 0;
            var tile_x: u3 = 0;
            if (render_window and win_x <= x and self.lcdc.bg_enable) {
                y = self.ly - win_y;
                const temp_x = x - win_x;
                const tile_y = y & 7;
                tile_x = @truncate(temp_x & 7);

                const tile_index = self.read_vram(win_tile_map_base + ((@as(u16, y) / 8) * 32) + (temp_x / 8)); // & 31?
                if (tile_base == 0x8000) {
                    tile_line = self.read_vram16(win_tile_base + (@as(u16, tile_index) * 16) + @as(u16, tile_y) * 2);
                } else {
                    // const tile_index_signed = @as(i8, @bitCast(tile_index));
                    const tile_index_signed = @as(i16, @as(i8, @bitCast(tile_index)));
                    var addr: u16 = 0x9000 + @as(u16, tile_y) * 2;
                    if (tile_index_signed < 0) {
                        addr -= @abs(tile_index_signed * 16);
                    } else {
                        addr += @abs(tile_index_signed * 16);
                    }
                    tile_line = self.read_vram16(addr);
                }
            } else if (self.lcdc.bg_enable) {
                y = @as(u16, self.ly) + @as(u16, self.background_viewport.scy);
                const tile_y = y % 8;

                const temp_x = x +% self.background_viewport.scx;
                tile_x = @truncate(temp_x % 8);

                const tile_index = self.read_vram(bg_tile_map_base + ((@as(u16, y) / 8) * 32) + (temp_x / 8)); // & 31?
                if (tile_base == 0x8000) {
                    tile_line = self.read_vram16(tile_base + (@as(u16, tile_index) * 16) + @as(u16, tile_y) * 2);
                } else {
                    // const tile_index_signed = @as(i8, @bitCast(tile_index));
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
            const color: TilePixelValue = @enumFromInt(GPU.color_from_palette(self.bgp, color_id));
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

        // limit of 10 objects per scanline
        var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_allocator.deinit();
        const allocator = arena_allocator.allocator();
        var renderable_objects = std.ArrayList(Object).init(allocator);
        defer renderable_objects.deinit();
        // todo drop the static object storage, just cast and handle x/y offsets here
        for (self.objects) |object| {
            // std.debug.print("object.y {}\n", .{object.y});
            const start_y = object.y;
            const end_y = start_y + object_height;
            if (start_y <= self.ly and end_y > self.ly) {
                renderable_objects.append(object) catch unreachable;
            }
            if (renderable_objects.items.len == 10) {
                break;
            }
        }
        // std.debug.print("num objects {}\n", .{renderable_objects.items.len});
        // if (!self.lcdc.obj_size) {
        //     // ?
        //     return;
        // }

        for (renderable_objects.items) |object| {
            if (object.x >= 0 and object.x <= SCREEN_WIDTH) {
                // const tile_y = if (object.attributes.y_flip) 7 - (self.ly - object.y - 0x10) else ((self.ly - object.y - 0x10) & 7);
                // const tile_y = if (object.attributes.y_flip) 7 - (self.ly - (object.y - 16)) else ((self.ly - (object.y - 16)) & 7);
                // const tile_y = if (object.attributes.y_flip) 7 - (self.ly - (object.y - 16)) else ((self.ly - (object.y - 16)) & 7);
                // std.debug.print("ly {}, object.y {} - height {}\n", .{ self.ly, object.y, object_height });
                var tile_y: i16 = undefined;
                if (self.lcdc.obj_size) {
                    tile_y = if (object.attributes.y_flip) 15 -% (self.ly - (object.y)) else ((self.ly -% (object.y)) & 15);
                } else {
                    tile_y = if (object.attributes.y_flip) 7 -% (self.ly - (object.y)) else ((self.ly -% (object.y)) & 7);
                }

                const palatte = if (object.attributes.dmg_palette) self.obp[1] else self.obp[0];

                var buffer_index: usize = @as(usize, self.ly) * SCREEN_WIDTH * 3 + @as(u16, @bitCast(object.x)) * 3;
                const tile_index = if (self.lcdc.obj_size) object.tile_index & 0xFE else object.tile_index;

                for (0..8) |x| {
                    const tile_line = self.read_vram16(0x8000 + (@as(u16, tile_index) << 4) + (@as(u16, @bitCast(tile_y)) << 1));
                    const tile_x: u3 = if (object.attributes.x_flip) 7 -% @as(u3, @truncate(x)) else @as(u3, @truncate(x));
                    const high: u8 = @as(u8, @truncate(tile_line >> 8)) & 0xFF;
                    const low: u8 = @as(u8, @truncate(tile_line)) & 0xFF;
                    // const color_id: u2 = (@as(u2, @truncate(high >> tile_x)) & 1) << 1 | (@as(u2, @truncate(low >> tile_x)) & 1);
                    const color_id: u2 = (@as(u2, @truncate(high >> (7 - tile_x))) & 1) << 1 | (@as(u2, @truncate(low >> (7 - tile_x))) & 1);
                    const color: TilePixelValue = @enumFromInt(GPU.color_from_palette(palatte, color_id));

                    // goofy
                    if (object.attributes.priority and
                        self.canvas[buffer_index] == 0xFF and
                        self.canvas[buffer_index +% 1] == 0xFF and
                        self.canvas[buffer_index +% 2] == 0xFF)
                    {
                        // std.debug.print("TileColorZero\n", .{});
                        continue;
                    }
                    // TODO: can sprites write on 00 bg palette? i saw code that suggested

                    // if (object.x - 8 + x >= SCREEN_WIDTH) {
                    //     // std.debug.print("x dont fit\n", .{});
                    //     continue;
                    // }

                    self.canvas[buffer_index] = color.to_color();
                    self.canvas[buffer_index +% 1] = color.to_color();
                    self.canvas[buffer_index +% 2] = color.to_color();

                    buffer_index += 3;
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
    pub fn color_from_palette(palette: Palette, color: u2) u2 {
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
