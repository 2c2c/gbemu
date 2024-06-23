pub const IERegister = packed struct {
    enable_vblank: bool,
    enable_lcd_stat: bool,
    enable_timer: bool,
    enable_serial: bool,
    enable_joypad: bool,
    _padding: u3 = 0,
};
