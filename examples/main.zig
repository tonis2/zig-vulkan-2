const std = @import("std");
const vk = @import("vk");
const glfw = @import("glfw");
const engine = @import("engine");
const Swapchain = engine.Swapchain;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(!gpa.deinit());

    // Initialize the library *
    try glfw.init(.{});
    defer glfw.terminate();

    // Create a windowed mode window
    var window = glfw.Window.create(800, 800, "vulkan-test", null, null, .{ .client_api = .no_api }) catch |err| {
        std.debug.panic("failed to create window, code: {}", .{err});
    };
    defer window.destroy();

    const ctx = try engine.init(allocator, "sprite test", &window);
    defer ctx.deinit();

    const swapchain = try Swapchain.init(allocator, ctx, .{ .width = 800, .height = 800 }, null);
    const commandBuffers = try ctx.createCommandBuffers(allocator, @truncate(u32, swapchain.image_views.len));

    defer {
        swapchain.deinit(ctx);
        ctx.deinitCmdBuffer(allocator, commandBuffers);
    }

    // _ = ctx;
}
