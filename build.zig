const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Pkg = std.build.Pkg;
const FileSource = std.build.FileSource;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const vk = Pkg{ .name = "vk", .path = FileSource{ .path = "dependencies/vk/vk.zig" } };
    const engine = Pkg{ .name = "engine", .path = FileSource{ .path = "src/context.zig" } };

    const exe = b.addExecutable("main", "examples/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.linkLibC();
    exe.linkSystemLibrary("glfw");

    exe.addPackage(vk);
    exe.addPackage(engine);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("main", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
