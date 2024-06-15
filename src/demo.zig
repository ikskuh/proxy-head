const std = @import("std");
const ProxyHead = @import("ProxyHead");

pub fn main() !void {
    var client = try ProxyHead.open();
    defer client.close();

    std.time.sleep(500 * std.time.ns_per_ms);

    {
        const fb = try client.requestFramebuffer(.rgbx8888, 400, 300, 200 * std.time.ns_per_ms);

        while (true) {
            const input = client.input.*;

            if (input.keyboard.space)
                break;

            var row = fb.base;
            for (0..fb.height) |y| {
                for (0..fb.width) |x| {
                    var color = ProxyHead.ColorFormat.RGBX8888{
                        .r = @as(u8, @truncate(x)),
                        .g = @as(u8, @truncate(y)),
                        .b = @as(u8, @truncate(x)) ^ @as(u8, @truncate(y)),
                    };

                    const dx = @as(isize, @intCast(x)) - input.mouse_x;
                    var dy = @as(isize, @intCast(y)) - input.mouse_y;
                    if (dy > 0) {
                        dy *= 2;
                    }

                    const d = (@abs(dx) + @abs(dy));
                    if (d < 8) {
                        color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
                        if (dy <= 0) {
                            if (dx < -3 and input.mouse_buttons.left) {
                                color = .{ .r = 0xFF, .g = 0x00, .b = 0x00 };
                            }
                            if (dx > -3 and dx < 3 and input.mouse_buttons.middle) {
                                color = .{ .r = 0xFF, .g = 0xFF, .b = 0x00 };
                            }
                            if (dx > 3 and input.mouse_buttons.right) {
                                color = .{ .r = 0x00, .g = 0x00, .b = 0xFF };
                            }
                        }
                    } else if (d == 8) {
                        color = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
                    }

                    row[x] = color;
                }

                row += fb.stride;
            }

            std.time.sleep(10 * std.time.ns_per_ms); // ~ 100 Hz
        }
    }

    while (client.input.keyboard.space) {
        std.time.sleep(10 * std.time.ns_per_ms); // ~ 100 Hz
    }

    {
        const fb = try client.requestFramebuffer(.index8, 256, 256, 200 * std.time.ns_per_ms);
        var loop: u8 = 0;
        while (true) {
            for (fb.base[0 .. fb.height * fb.stride], 0..) |*c, i| {
                c.* = @as(u8, @truncate(i ^ (i >> 8))) +% loop;
            }
            loop +%= 1;
            std.time.sleep(30 * std.time.ns_per_ms); // ~ 30 Hz
        }
        std.time.sleep(5 * std.time.ns_per_s);
    }

    try client.releaseFramebuffer(200 * std.time.ns_per_ms);

    std.time.sleep(1500 * std.time.ns_per_ms);
}
