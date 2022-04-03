const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const glfw = @import("vendor/mach/glfw/build.zig");
const ft = @import("src/freetype/build.zig");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("ghostty", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
    exe.addIncludeDir("vendor/stb");
    exe.addCSourceFile("src/stb/stb.c", &.{});
    exe.addPackagePath("glfw", "vendor/mach/glfw/src/main.zig");
    glfw.link(b, exe, .{});

    const ftlib = try ft.create(b, target, mode, .{});
    ftlib.link(exe);

    exe.linkSystemLibrary("epoxy");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
