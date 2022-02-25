const std = @import("std");
const vk = @import("vk");
const glfw = @import("glfw");
const engine = @import("engine");

pub fn main() !void {
    // create a gpa with default configuration
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};

    // Initialize the library *
    try glfw.init(.{});
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) {
        std.debug.panic("vulkan not supported on device (glfw)", .{});
    }

    // Create a windowed mode window
    var window = glfw.Window.create(800, 800, "sprite test", null, null, .{ .client_api = .no_api }) catch |err| {
        std.debug.panic("failed to create window, code: {}", .{err});
        return;
    };
    defer window.destroy();

    const ctx = try engine.init(alloc.allocator(), "sprite test", &window);
    defer ctx.deinit();

    _ = ctx;
}
