const std = @import("std");
const ProxyHead = @import("ProxyHead");

pub fn main() !void {
    var client = try ProxyHead.open();
    defer client.close();

    std.time.sleep(500 * std.time.ns_per_ms);

    const fb = try client.requestFramebuffer(.rgbx8888, 400, 300, 200 * std.time.ns_per_ms);

    while (true) {
        const input = client.input.*;

        var row = fb.base;
        var y: usize = 0;
        while (y < fb.height) : (y += 1) {
            var x: usize = 0;
            while (x < fb.width) : (x += 1) {
                var color = ProxyHead.ColorFormat.RGBX8888{
                    .r = @truncate(u8, x),
                    .g = @truncate(u8, y),
                    .b = @truncate(u8, x) ^ @truncate(u8, y),
                };

                const dx = @intCast(isize, x) - input.mouse_x;
                var dy = @intCast(isize, y) - input.mouse_y;
                if (dy > 0) {
                    dy *= 2;
                }

                const d = (std.math.absCast(dx) + std.math.absCast(dy));
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

    try client.releaseFramebuffer(200 * std.time.ns_per_ms);

    std.time.sleep(1500 * std.time.ns_per_ms);
}
