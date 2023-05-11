const std = @import("std");
const sdl2 = @import("sdl2");
const args = @import("args");

const proxy_head = @import("proxy-head.zig");

const shared_memory_data_size = 16 * 1024 * 1024;
const shared_memory_header_size = proxy_head.SHM_Header_Version1.size;

const shared_memory_total_size = shared_memory_data_size + shared_memory_header_size;

const CliOptions = struct {
    palette: ?[]const u8 = null,
    geometry: WindowSize = .{ .width = 800, .height = 600 },
    help: bool = false,

    pub const shorthands = .{
        .p = "palette",
        .g = "geometry",
        .h = "help",
    };
};

const WindowSize = struct {
    width: u32,
    height: u32,

    pub fn parse(str: []const u8) !WindowSize {
        var items = std.mem.split(u8, str, "x");

        const w_str = items.next() orelse return error.InvalidFormat;
        const h_str = items.next() orelse return error.InvalidFormat;
        if (items.next() != null) return error.InvalidFormat;

        return WindowSize{
            .width = try std.fmt.parseInt(u32, w_str, 0),
            .height = try std.fmt.parseInt(u32, h_str, 0),
        };
    }
};

var system_palette: Palette = undefined;

pub fn main() !u8 {
    var cli = args.parseForCurrentProcess(CliOptions, std.heap.c_allocator, .print) catch return 1;
    defer cli.deinit();

    if (cli.options.palette) |palette_file| {
        var file = std.fs.cwd().openFile(palette_file, .{}) catch |err| {
            std.log.err("failed to open palette file: {s}", .{@errorName(err)});
            return 1;
        };
        defer file.close();

        system_palette = Palette.parse(file.reader()) catch |err| {
            std.log.err("invalid palette file: {s}", .{@errorName(err)});
            return 1;
        };
    } else {
        var fbr = std.io.fixedBufferStream(@embedFile("data/windows-95-256-colours.gpl"));
        system_palette = Palette.parse(fbr.reader()) catch unreachable;
    }

    const resolution = cli.options.geometry;

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
            .width = resolution.width,
            .height = resolution.height,
            .format = .unset,
        },
        .request = .{},
        .input = .{},
    };
    const video_memory: []align(16) u8 = @alignCast(16, mapped_memory[shared_memory_header_size..]);

    try sdl2.init(sdl2.InitFlags.everything);
    defer sdl2.quit();

    var window = try sdl2.createWindow(
        "Proxy: Head",
        .default,
        .default,
        header.environment.width,
        header.environment.height,
        .{ .vis = .shown },
    );
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
                    if (VideoBuffer.create(std.heap.c_allocator, renderer, width, height, format)) |new_vb| {
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

    return 0;
}

fn colorToSdlFormat(fmt: proxy_head.ColorFormat) ?sdl2.PixelFormatEnum {
    return switch (fmt) {
        .unset => null,
        .index8 => .rgbx8888,
        inline else => |item| return @field(sdl2.PixelFormatEnum, @tagName(item)),
    };
}

const VideoBuffer = struct {
    texture: sdl2.Texture,
    width: usize,
    height: usize,
    format: proxy_head.ColorFormat,
    intermediate_buffer: []Palette.Color,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, renderer: sdl2.Renderer, width: usize, height: usize, format: proxy_head.ColorFormat) !VideoBuffer {
        const sdl_format = colorToSdlFormat(format) orelse return error.UnsupportedFormat;

        var texture = try sdl2.createTexture(renderer, sdl_format, .streaming, width, height);
        errdefer texture.destroy();

        const buffer = switch (format) {
            .index8 => try allocator.alloc(Palette.Color, width * height),
            else => try allocator.alloc(Palette.Color, 0),
        };

        return VideoBuffer{
            .texture = texture,
            .width = width,
            .height = height,
            .format = format,
            .intermediate_buffer = buffer,
            .allocator = allocator,
        };
    }

    pub fn destroy(vb: *VideoBuffer) void {
        vb.allocator.free(vb.intermediate_buffer);
        vb.texture.destroy();
        vb.* = undefined;
    }

    pub fn update(vb: *VideoBuffer, storage: []const u8) !void {
        switch (vb.format) {
            .index8 => {
                for (vb.intermediate_buffer, storage[0..vb.intermediate_buffer.len]) |*dst, src| {
                    dst.* = system_palette.items[src];
                }
                try vb.texture.update(std.mem.sliceAsBytes(vb.intermediate_buffer), vb.width * @sizeOf(Palette.Color), null);
            },
            else => try vb.texture.update(storage, vb.width * vb.format.bytesPerPixel(), null),
        }
    }
};

const Palette = struct {
    const Color = proxy_head.ColorFormat.RGBX8888;

    items: [256]Color,

    fn parse(stream: anytype) !Palette {
        var buffered = std.io.bufferedReader(stream);
        const reader = buffered.reader();

        const ParserState = union(enum) {
            await_header,
            color: u8,
            eof,
        };

        var result = Palette{
            .items = [1]Color{Color{ .r = 0xFF, .g = 0x00, .b = 0xFF }} ** 256,
        };

        var line_buffer: [1024]u8 = undefined;

        var state: ParserState = .await_header;
        while (try reader.readUntilDelimiterOrEof(&line_buffer, '\n')) |raw_line| {
            const comment_pos = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
            const line = std.mem.trim(u8, raw_line[0..comment_pos], "\r\n \t");
            if (line.len == 0)
                continue;

            switch (state) {
                .await_header => {
                    if (!std.ascii.eqlIgnoreCase(line, "GIMP Palette")) {
                        return error.InvalidFormat;
                    }
                    state = .{ .color = 0 };
                },
                .color => |*index| {
                    var items = std.mem.tokenize(u8, line, " \r\t");

                    const r_str = items.next() orelse return error.InvalidFormat;
                    const g_str = items.next() orelse return error.InvalidFormat;
                    const b_str = items.next() orelse return error.InvalidFormat;

                    const r_int = try std.fmt.parseInt(u8, r_str, 0);
                    const g_int = try std.fmt.parseInt(u8, g_str, 0);
                    const b_int = try std.fmt.parseInt(u8, b_str, 0);

                    result.items[index.*] = .{
                        .r = r_int,
                        .g = g_int,
                        .b = b_int,
                    };

                    if (index.* == 0xFF) {
                        state = .eof;
                    } else {
                        index.* += 1;
                    }
                },
                .eof => return error.UnexpectedData,
            }
        }

        return result;
    }
};
