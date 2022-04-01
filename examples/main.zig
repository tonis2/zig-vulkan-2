const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw");
const engine = @import("engine");

const Pipeline = @import("./pipelines/3d.zig");
const Buffer = engine.Buffer;
const Swapchain = engine.Swapchain;

const Vec3 = Pipeline.Vec3;
const Vertex = Pipeline.Vertex;

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

    var swapchain = try Swapchain.init(allocator, ctx, size, null);

    defer swapchain.deinit(ctx);

    const commandBuffers = try ctx.createCommandBuffers(allocator, @truncate(u32, swapchain.images.len));
    defer ctx.deinitCmdBuffer(allocator, commandBuffers);

    const vertices = [_]Vertex{
        Vertex{ .pos = Vec3.new(0.0, 0.0, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
        Vertex{ .pos = Vec3.new(300, 0.0, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
        Vertex{ .pos = Vec3.new(300, 300, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
        Vertex{ .pos = Vec3.new(0.0, 300, 1.0), .color = Vec3.new(1.0, 1.0, 1.0) },
    };

    const v_indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

    const vertexBuffer = try Buffer.init(ctx, Buffer.CreateInfo{
        .size = @sizeOf(Vertex) * vertices.len,
        .buffer_usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .memory_usage = .gpu_only,
        .memory_flags = .{},
    });
    defer vertexBuffer.deinit(ctx);

    try vertexBuffer.upload(Vertex, ctx, &vertices);

    const indexBuffer = try Buffer.init(ctx, Buffer.CreateInfo{
        .size = @sizeOf(u16) * v_indices.len,
        .buffer_usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        .memory_usage = .gpu_only,
        .memory_flags = .{},
    });
    defer indexBuffer.deinit(ctx);

    try indexBuffer.upload(u16, ctx, &v_indices);

    const pipeline = try Pipeline.init(ctx, allocator, swapchain);
    defer pipeline.deinit(ctx);

    const clear_color = [_]vk.ClearColorValue{
        .{
            .float_32 = [_]f32{ 0.0, 1.0, 0.0, 1.0 },
        },
    };

    while (!window.shouldClose()) {
        const command_buffer = commandBuffers[swapchain.image_index];
        const command_begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try ctx.vkd.beginCommandBuffer(command_buffer, &command_begin_info);
        const render_begin_info = vk.RenderPassBeginInfo{
            .render_pass = pipeline.renderpass,
            .framebuffer = pipeline.framebuffers[swapchain.image_index],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
            .clear_value_count = clear_color.len,
            .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear_color),
        };

        const viewport = [1]vk.Viewport{
            .{ .x = 0, .y = 0, .width = @intToFloat(f32, swapchain.extent.width), .height = @intToFloat(f32, swapchain.extent.height), .min_depth = 0.0, .max_depth = 1.0 },
        };

        const scissors = [1]vk.Rect2D{
            .{ .offset = .{
                .x = 0,
                .y = 0,
            }, .extent = swapchain.extent },
        };

        ctx.vkd.cmdSetViewport(command_buffer, 0, 1, &viewport);
        ctx.vkd.cmdSetScissor(command_buffer, 0, 1, &scissors);
        ctx.vkd.cmdBindPipeline(command_buffer, vk.PipelineBindPoint.graphics, pipeline.pipeline);
        ctx.vkd.cmdBeginRenderPass(command_buffer, &render_begin_info, vk.SubpassContents.@"inline");
        ctx.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast([*]const vk.Buffer, &vertexBuffer.buffer), @ptrCast([*]const vk.DeviceSize, &[_]vk.DeviceSize{0}));
        ctx.vkd.cmdBindIndexBuffer(command_buffer, indexBuffer.buffer, 0, .uint32);
        ctx.vkd.cmdDrawIndexed(command_buffer, v_indices.len, 1, 0, 0, 0);
        ctx.vkd.cmdEndRenderPass(command_buffer);

        try ctx.vkd.endCommandBuffer(command_buffer);
        const state = swapchain.present(ctx, command_buffer) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        _ = state;
    }

    for (swapchain.images) |img| img.waitForFence(ctx) catch {};
}
