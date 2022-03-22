const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw");
const engine = @import("engine");
const Buffer = engine.Buffer;
const Swapchain = engine.Swapchain;
const zalgebra = @import("zalgebra");
const Vec3 = zalgebra.Vec3;

pub const Vertex = struct {
    pos: Vec3,
    color: Vec3,
};

pub fn main() !void {
    const size = vk.Extent2D{ .width = 1400, .height = 900 };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(!gpa.deinit());

    // Initialize the library *
    try glfw.init(.{});
    defer glfw.terminate();

    // Create a windowed mode window
    var window = glfw.Window.create(size.width, size.height, "vulkan-test", null, null, .{ .client_api = .no_api }) catch |err| {
        std.debug.panic("failed to create window, code: {}", .{err});
    };

    defer window.destroy();

    const ctx = try engine.init(allocator, "vulkan-test", &window);
    defer ctx.deinit();

    const swapchain = try Swapchain.init(allocator, ctx, size, null);
    const commandBuffers = try ctx.createCommandBuffers(allocator, @truncate(u32, swapchain.images.len));

    const vertices = [_]Vertex{
        Vertex{ .pos = Vec3.new(0.0, 0.0, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
        Vertex{ .pos = Vec3.new(300, 0.0, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
        Vertex{ .pos = Vec3.new(300, 300, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
        Vertex{ .pos = Vec3.new(0.0, 300, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
    };

    const v_indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

    const VertexBuffer = try Buffer.init(ctx, Buffer.CreateInfo{
        .size = @sizeOf(Vertex) * vertices.len,
        .buffer_usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .memory_usage = .gpu_only,
        .memory_flags = .{},
    });

    try VertexBuffer.upload(Vertex, ctx, &vertices);

    const IndexBuffer = try Buffer.init(ctx, Buffer.CreateInfo{
        .size = @sizeOf(u16) * v_indices.len,
        .buffer_usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        .memory_usage = .gpu_only,
        .memory_flags = .{},
    });

    try IndexBuffer.upload(u16, ctx, &v_indices);

    defer {
        VertexBuffer.deinit(ctx);
        IndexBuffer.deinit(ctx);
        swapchain.deinit(ctx);
        ctx.deinitCmdBuffer(allocator, commandBuffers);
    }
}
