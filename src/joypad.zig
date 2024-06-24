// FF00 - P1/JOYP - Joypad (R/W)
const JoypadAction = packed struct {
    A: bool,
    B: bool,
    SELECT: bool,
    START: bool,
    column: u1 = 0,
    _padding: u3 = 0,
};

const JoypadDirection = packed struct {
    RIGHT: bool,
    LEFT: bool,
    UP: bool,
    DOWN: bool,
    column: u1 = 1,
    _padding: u3 = 0,
};

pub const Joypad = struct {
    is_action_row: bool,
    action: JoypadAction,
    direction: JoypadDirection,

    pub fn new() Joypad {
        return Joypad{
            .is_action_row = false,
            .action = .{
                .A = false,
                .B = false,
                .SELECT = false,
                .START = false,
            },
            .direction = .{
                .RIGHT = false,
                .LEFT = false,
                .UP = false,
                .DOWN = false,
            },
        };
    }
    pub fn to_bytes(self: *const Joypad) u8 {
        if (self.is_action_row) {
            return @bitCast(self.action);
        } else {
            return @bitCast(self.direction);
        }
    }
};
