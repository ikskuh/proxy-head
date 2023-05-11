const std = @import("std");
const sdl2 = @import("sdl2");

const proxy_head = @import("proxy-head.zig");

const shared_memory_data_size = 16 * 1024 * 1024;
const shared_memory_header_size = proxy_head.SHM_Header_Version1.size;

const shared_memory_total_size = shared_memory_data_size + shared_memory_header_size;

pub fn main() !void {
    var shm_folder = try std.fs.cwd().openDir("/dev/shm", .{});
    defer shm_folder.close();

    var shm_file = try shm_folder.createFile("proxy-head", .{
        .truncate = true,
        .read = true,
    });
    defer {
        shm_file.close();
        shm_folder.deleteFile("proxy-head") catch |err| std.log.err("failed to delete /dev/shm/proxy-head: {s}", .{@errorName(err)});
    }

    try shm_file.seekTo(shared_memory_total_size - 1);
    try shm_file.writeAll(".");

    const mapped_memory = try std.os.mmap(
        null,
        shared_memory_total_size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.SHARED,
        shm_file.handle,
        0,
    );
    defer std.os.munmap(mapped_memory);

    const header = @ptrCast(*volatile proxy_head.SHM_Header_Version1, mapped_memory.ptr);
    header.* = proxy_head.SHM_Header_Version1{
        .invariant = .{},
        .environment = .{
            .available_memory = shared_memory_data_size,
            .width = 800,
            .height = 600,
            .format = .unset,
        },
        .request = .{},
        .input = .{},
    };
    const video_memory: []align(16) u8 = @alignCast(16, mapped_memory[shared_memory_header_size..]);

    try sdl2.init(sdl2.InitFlags.everything);
    defer sdl2.quit();

    var window = try sdl2.createWindow("", .default, .default, 800, 600, .{ .vis = .shown });
    defer window.destroy();

    var renderer = try sdl2.createRenderer(window, null, .{ .present_vsync = true });
    defer renderer.destroy();

    var current_video_buffer: ?VideoBuffer = null;

    var mouse_x: c_int = 0;
    var mouse_y: c_int = 0;

    app_loop: while (true) {
        while (sdl2.pollEvent()) |event| {
            switch (event) {
                .quit => break :app_loop,
                .mouse_motion => |pos| {
                    mouse_x = pos.x;
                    mouse_y = pos.y;
                },
                else => {},
            }
        }

        const kbd = sdl2.getKeyboardState();

        const keyboard = proxy_head.KeyboardState{
            .left = kbd.isPressed(.a) or kbd.isPressed(.left),
            .right = kbd.isPressed(.d) or kbd.isPressed(.right),
            .up = kbd.isPressed(.w) or kbd.isPressed(.up),
            .down = kbd.isPressed(.s) or kbd.isPressed(.down),

            .space = kbd.isPressed(.space),
            .escape = kbd.isPressed(.escape),
            .shift = kbd.isPressed(.left_shift) or kbd.isPressed(.right_shift),
            .ctrl = kbd.isPressed(.left_control) or kbd.isPressed(.right_control),
        };

        const mouse = sdl2.getMouseState();

        const mouse_buttons = proxy_head.MouseButtons{
            .left = (mouse.buttons.storage & 1) != 0,
            .middle = (mouse.buttons.storage & 2) != 0,
            .right = (mouse.buttons.storage & 4) != 0,
        };

        const window_size = window.getSize();

        header.environment.width = @intCast(u32, window_size.width);
        header.environment.height = @intCast(u32, window_size.height);

        if (header.request.connected != 0) {
            if (header.request.dirty_flag != 0) {
                const width = header.request.width;
                const height = header.request.height;
                const format = header.request.format;

                if (format == .unset) {
                    if (current_video_buffer) |*vb| {
                        vb.destroy();
                    }
                    current_video_buffer = null;
                } else {
                    if (VideoBuffer.create(renderer, width, height, format)) |new_vb| {
                        if (current_video_buffer) |*vb| {
                            vb.destroy();
                        }
                        current_video_buffer = new_vb;
                    } else |err| {
                        std.log.err("failed to create video buffer with settings: width={}, height={}, format={s}: {s}", .{
                            width,           height, @tagName(format),
                            @errorName(err),
                        });
                    }
                }

                header.request.dirty_flag = 0;
            }
        } else {
            if (current_video_buffer) |*vb| {
                vb.destroy();
            }
            current_video_buffer = null;
        }

        if (current_video_buffer) |*vb| {
            header.environment.format = vb.format;

            try vb.update(video_memory);

            try renderer.setColorRGB(0x00, 0x00, 0xAA);
            try renderer.clear();

            const scale = @intCast(u32, @max(
                1,
                @min(
                    @intCast(usize, window_size.width) / vb.width,
                    @intCast(usize, window_size.height) / vb.height,
                ),
            ));

            const rect = sdl2.Rectangle{
                .x = @divFloor(window_size.width -| @intCast(c_int, scale * vb.width), 2),
                .y = @divFloor(window_size.height -| @intCast(c_int, scale * vb.height), 2),
                .width = @min(@intCast(c_int, scale * vb.width), window_size.width),
                .height = @min(@intCast(c_int, scale * vb.height), window_size.height),
            };

            header.input.mouse_x = @intCast(u32, std.math.clamp(mouse_x - rect.x, 0, rect.width - 1)) / scale;
            header.input.mouse_y = @intCast(u32, std.math.clamp(mouse_y - rect.y, 0, rect.height - 1)) / scale;
            header.input.mouse_buttons = mouse_buttons;
            header.input.keyboard = keyboard;

            try renderer.copy(vb.texture, rect, null);
        } else {
            header.environment.format = .unset;
            header.input = .{};

            if (header.request.connected != 0) {
                try renderer.setColorRGB(0x88, 0x00, 0x00);
            } else {
                try renderer.setColorRGB(0x00, 0x00, 0xAA);
            }
            try renderer.clear();
        }

        renderer.present();
    }
}

fn colorToSdlFormat(fmt: proxy_head.ColorFormat) ?sdl2.PixelFormatEnum {
    return switch (fmt) {
        .unset => null,
        inline else => |item| return @field(sdl2.PixelFormatEnum, @tagName(item)),
    };
}

const VideoBuffer = struct {
    texture: sdl2.Texture,
    width: usize,
    height: usize,
    format: proxy_head.ColorFormat,

    pub fn create(renderer: sdl2.Renderer, width: usize, height: usize, format: proxy_head.ColorFormat) !VideoBuffer {
        const sdl_format = colorToSdlFormat(format) orelse return error.UnsupportedFormat;

        var texture = try sdl2.createTexture(renderer, sdl_format, .streaming, width, height);
        errdefer texture.destroy();

        return VideoBuffer{
            .texture = texture,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn destroy(vb: *VideoBuffer) void {
        vb.texture.destroy();
        vb.* = undefined;
    }

    pub fn update(vb: *VideoBuffer, storage: []const u8) !void {
        try vb.texture.update(storage, vb.width * vb.format.bytesPerPixel(), null);
    }
};
