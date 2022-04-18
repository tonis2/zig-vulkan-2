const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Pkg = std.build.Pkg;
const FileSource = std.build.FileSource;
const glfw = @import("dependencies/mach-glfw/build.zig");
const ArrayList = std.ArrayList;

const examples = [2][]const u8{ "image", "triangle" };

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    inline for (examples) |name| {
        const exe = b.addExecutable(name, "examples/" ++ name ++ "/main.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);

        glfw.link(b, exe, .{});

        exe.linkLibCpp();
        exe.addCSourceFile("dependencies/vma/vk_allocator.cpp", &.{"-std=c++14"});

        const vk = Pkg{ .name = "vulkan", .path = FileSource{ .path = "dependencies/vk/vk.zig" } };
        const vma = Pkg{ .name = "vma", .path = FileSource{ .path = "dependencies/vma/vk_allocator.zig" }, .dependencies = &.{vk} };
        const glfw_main = Pkg{ .name = "glfw", .path = FileSource{ .path = "dependencies/mach-glfw/src/main.zig" } };
        const zalgebra = Pkg{ .name = "zalgebra", .path = FileSource{ .path = "dependencies/zalgebra/src/main.zig" } };
        const utils = Pkg{ .name = "utils", .path = FileSource{ .path = "examples/utils/index.zig" }, .dependencies = &.{zalgebra} };

        exe.addPackage(zalgebra);
        exe.addPackage(vk);
        exe.addPackage(glfw_main);
        exe.addPackage(utils);
        exe.addPackage(Pkg{ .name = "engine", .path = FileSource{ .path = "src/context.zig" }, .dependencies = &.{ vk, glfw_main, vma } });
        exe.install();

        const run_cmd = exe.run();

        // Build shaders
        const shader_path = "examples/" ++ name ++ "/shaders/";
        const vertexShader = b.addSystemCommand(&.{ "glslc", shader_path ++ "shader.vert", "-o", shader_path ++ "vert.spv" });
        const fragmentShader = b.addSystemCommand(&.{ "glslc", shader_path ++ "shader.frag", "-o", shader_path ++ "frag.spv" });

        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step(name, "Run" ++ name);

        run_step.dependOn(&vertexShader.step);
        run_step.dependOn(&fragmentShader.step);
        run_step.dependOn(&run_cmd.step);
    }
}
