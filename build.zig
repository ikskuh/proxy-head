const std = @import("std");

const SDL2 = @import("sdl2");

pub fn build(b: *std.Build) void {
    const sdl_sdk = SDL2.init(b, null);

    const proxy_head_module = b.addModule("ProxyHead", .{
        .source_file = .{ .path = "src/ProxyClient.zig" },
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "proxy-head",
        .root_source_file = .{ .path = "src/server.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("sdl2", sdl_sdk.getWrapperModule());
    sdl_sdk.link(exe, .dynamic);
    b.installArtifact(exe);

    const demo = b.addExecutable(.{
        .name = "proxy-head-demo",
        .root_source_file = .{ .path = "src/demo.zig" },
        .target = target,
        .optimize = optimize,
    });
    demo.addModule("ProxyHead", proxy_head_module);
    b.installArtifact(demo);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
