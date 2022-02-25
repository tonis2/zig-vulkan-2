const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Pkg = std.build.Pkg;
const FileSource = std.build.FileSource;
const glfw = @import("dependencies/mach-glfw/build.zig");

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("main", "examples/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    glfw.link(b, exe, .{});
    exe.linkLibC();
    exe.linkSystemLibrary("glfw");

    const vk = Pkg{ .name = "vulkan", .path = FileSource{ .path = "dependencies/vk/vk.zig" } };
    const glfw_main = Pkg{ .name = "glfw", .path = FileSource{ .path = "dependencies/mach-glfw/src/main.zig" } };

    exe.addPackage(vk);
    exe.addPackage(glfw_main);
    exe.addPackage(Pkg{ .name = "engine", .path = FileSource{ .path = "src/context.zig" }, .dependencies = &.{ vk, glfw_main } });

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("main", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
