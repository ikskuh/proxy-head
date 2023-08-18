const std = @import("std");

pub const SHM_Invariant_Header = extern struct {
    pub const magic: u32 = 0xAD_B7_57_21;

    // DO NOT CHANGE THE FOLLOWING EVER:
    magic_bytes: u32 = 0xAD_B7_57_21,
    version: u32 = 1,
};

pub const SHM_Header_Version1 = extern struct {
    pub const size = std.mem.alignForward(usize, @sizeOf(@This()), 16);

    invariant: SHM_Invariant_Header, // must come first

    environment: Environment,
    request: Request,
    input: Input,

    pub const Environment = extern struct {
        available_memory: u32, // total available video memory
        width: u32 = 0, // current window width
        height: u32 = 0, // current window height
        format: ColorFormat = .unset, // current color format
    };

    pub const Request = extern struct {
        width: u32 = 0,
        height: u32 = 0,
        format: ColorFormat = .unset,
        dirty_flag: u8 = 0, // set to 1 to request update, will be reset back to 0 when buffer was performed
        connected: u8 = 0, // set to 1 if a client connects, reset when disconnect
    };

    pub const Input = extern struct {
        keyboard: KeyboardState = std.mem.zeroes(KeyboardState),
        mouse_x: u32 = 0,
        mouse_y: u32 = 0,
        mouse_buttons: MouseButtons = std.mem.zeroes(MouseButtons),
    };
};
pub const MouseButtons = packed struct(u16) {
    left: bool,
    right: bool,
    middle: bool,
    padding: u13 = 0,
};

pub const KeyboardState = packed struct(u32) {
    up: bool, // UP, W
    down: bool, // DOWN, S
    left: bool, // LEFT, A
    right: bool, // RIGHT, D
    space: bool, // SPACE
    escape: bool, // ESCAPE
    shift: bool, // L-SHIFT, R-SHIFT
    ctrl: bool, // L-CTRL, R-CTRL
    padding: u24 = 0,
};

pub const ColorFormat = enum(u16) {
    unset = 0,
    index8 = 1,
    rgb565 = 2,
    bgr565 = 3,
    rgb888 = 4,
    rgbx8888 = 5,
    bgr888 = 6,
    bgrx8888 = 7,

    pub fn bytesPerPixel(fmt: ColorFormat) usize {
        return switch (fmt) {
            .unset => 0,
            .index8 => 1,
            .rgb565 => 2,
            .bgr565 => 2,
            .rgb888 => 3,
            .bgr888 => 3,
            .rgbx8888 => 4,
            .bgrx8888 => 4,
        };
    }

    pub fn PixelType(comptime fmt: ColorFormat) type {
        return switch (fmt) {
            .unset => @compileError("Format .unset has no associated type."),
            .index8 => Index8,
            .rgb565 => RGB565,
            .bgr565 => BGR565,
            .rgb888 => RGB888,
            .bgr888 => BGR888,
            .rgbx8888 => RGBX8888,
            .bgrx8888 => BGRX8888,
        };
    }

    pub const Index8 = u8;
    pub const RGB565 = packed struct(u16) {
        r: u5,
        g: u6,
        b: u5,
    };

    pub const BGR565 = packed struct(u16) {
        r: u5,
        g: u6,
        b: u5,
    };

    pub const RGB888 = extern struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub const BGR888 = extern struct {
        b: u8,
        g: u8,
        r: u8,
    };

    pub const RGBX8888 = extern struct {
        x: u8 = 0xFF,
        b: u8,
        g: u8,
        r: u8,
    };

    pub const BGRX8888 = extern struct {
        x: u8 = 0xFF,
        r: u8,
        g: u8,
        b: u8,
    };
};
