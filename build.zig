const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Pkg = std.build.Pkg;
const FileSource = std.build.FileSource;
const glfw = @import("dependencies/mach-glfw/build.zig");
const ArrayList = std.ArrayList;

pub fn build(b: *Builder) !void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("triangle", "examples/triangle/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    glfw.link(b, exe, .{});

    exe.linkLibCpp();
    exe.addCSourceFile("dependencies/vma/vk_allocator.cpp", &.{"-std=c++14"});

    const vk = Pkg{ .name = "vulkan", .path = FileSource{ .path = "dependencies/vk/vk.zig" } };
    const vma = Pkg{ .name = "vma", .path = FileSource{ .path = "dependencies/vma/vk_allocator.zig" }, .dependencies = &.{vk} };
    const glfw_main = Pkg{ .name = "glfw", .path = FileSource{ .path = "dependencies/mach-glfw/src/main.zig" } };
    const zalgebra = Pkg{ .name = "zalgebra", .path = FileSource{ .path = "dependencies/zalgebra/src/main.zig" } };
    exe.addPackage(zalgebra);
    exe.addPackage(vk);
    exe.addPackage(glfw_main);
    exe.addPackage(Pkg{ .name = "engine", .path = FileSource{ .path = "src/context.zig" }, .dependencies = &.{ vk, glfw_main, vma } });
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("triangle", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
