const std = @import("std");
const proxy_head = @import("proxy-head.zig");

const Client = @This();

pub const Input = proxy_head.SHM_Header_Version1.Input;
pub const ColorFormat = proxy_head.ColorFormat;

shm_file: std.fs.File,
shm_buffer: []align(std.mem.page_size) u8,
video_memory: []align(16) u8,
input: *const volatile proxy_head.SHM_Header_Version1.Input,

pub fn open() !Client {
    var shm_file = try std.fs.cwd().openFile("/dev/shm/proxy-head", .{
        .mode = .read_write,
    });
    errdefer shm_file.close();

    const file_stat = try shm_file.stat();

    const mapped_memory = try std.os.mmap(
        null,
        file_stat.size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.SHARED,
        shm_file.handle,
        0,
    );
    errdefer std.os.munmap(mapped_memory);

    const invariant_header = @as(*volatile proxy_head.SHM_Invariant_Header, @ptrCast(mapped_memory.ptr));
    if (invariant_header.magic_bytes != proxy_head.SHM_Invariant_Header.magic)
        return error.InvalidMagic;
    if (invariant_header.version != 1)
        return error.UnsupportedVersion;

    const hdr = @as(*volatile proxy_head.SHM_Header_Version1, @ptrCast(mapped_memory.ptr));

    const available_memory = mapped_memory[proxy_head.SHM_Header_Version1.size..];
    if (available_memory.len < hdr.environment.available_memory)
        return error.CorruptConfiguration;

    const video_memory: []align(16) u8 = @alignCast(available_memory[0..hdr.environment.available_memory]);

    hdr.request.connected = 1;

    return Client{
        .shm_file = shm_file,
        .shm_buffer = mapped_memory,
        .video_memory = video_memory,
        .input = &hdr.input,
    };
}

pub fn close(client: *Client) void {
    client.header().request.connected = 0;
    std.os.munmap(client.shm_buffer);
    client.shm_file.close();
    client.* = undefined;
}

fn header(client: Client) *volatile proxy_head.SHM_Header_Version1 {
    return @as(*volatile proxy_head.SHM_Header_Version1, @ptrCast(client.shm_buffer.ptr));
}

pub fn requestFramebuffer(client: *Client, comptime format: proxy_head.ColorFormat, width: u32, height: u32, timeout: u64) error{Timeout}!Framebuffer(format.PixelType()) {
    const hdr = client.header();

    hdr.request.format = format;
    hdr.request.width = width;
    hdr.request.height = height;

    try client.performChange(timeout);

    const Pixel = format.PixelType();

    return Framebuffer(Pixel){
        .base = @as([*]align(16) Pixel, @ptrCast(client.video_memory.ptr)),
        .width = width,
        .height = height,
        .stride = width,
    };
}

pub fn releaseFramebuffer(client: *Client, timeout: u64) error{Timeout}!void {
    const hdr = client.header();

    hdr.request.width = 0;
    hdr.request.height = 0;
    hdr.request.format = .unset;

    try client.performChange(timeout);
}

pub fn Framebuffer(comptime Pixel: type) type {
    return struct {
        base: [*]Pixel,
        width: usize,
        height: usize,
        stride: usize,
    };
}

fn performChange(client: *Client, timeout: u64) error{Timeout}!void {
    const hdr = client.header();

    hdr.request.dirty_flag = 1;

    const end = std.time.nanoTimestamp() + timeout;
    while (hdr.request.dirty_flag != 0) {
        if (std.time.nanoTimestamp() >= end)
            return error.Timeout;
    }
}
