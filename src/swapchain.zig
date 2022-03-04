const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig");

pub const PresentState = enum {
    optimal,
    suboptimal,
};

const Self = @This();

allocator: Allocator,
surface_format: vk.SurfaceFormatKHR,
present_mode: vk.PresentModeKHR,
extent: vk.Extent2D,
handle: vk.SwapchainKHR,
swap_images: []SwapImage,
image_index: u32,

pub fn init(ctx: Context, allocator: Allocator, extent: vk.Extent2D) !Self {
    return try Self.recreate(ctx, allocator, extent, .null_handle);
}

pub fn recreate(ctx: Context, allocator: Allocator, extent: vk.Extent2D, old_handle: vk.SwapchainKHR) !Self {
    const caps = try ctx.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface);
    const actual_extent = findActualExtent(caps, extent);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const surface_format = try findSurfaceFormat(ctx, allocator);
    const present_mode = try findPresentMode(ctx, allocator);

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) {
        image_count = std.math.min(image_count, caps.max_image_count);
    }

    const qfi = [_]u32{ ctx.graphics_queue.family, ctx.present_queue.family };
    const sharing_mode: vk.SharingMode = if (ctx.graphics_queue.family != ctx.present_queue.family)
        .concurrent
    else
        .exclusive;

    const handle = try ctx.vkd.createSwapchainKHR(ctx.device, &.{
        .flags = .{},
        .surface = ctx.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .queue_family_index_count = qfi.len,
        .p_queue_family_indices = &qfi,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = old_handle,
    }, null);
    errdefer ctx.vkd.destroySwapchainKHR(ctx.device, handle, null);

    if (old_handle != .null_handle) {
        ctx.vkd.destroySwapchainKHR(ctx.device, old_handle, null);
    }

    const swap_images = images: {
        var count: u32 = undefined;
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, handle, &count, null);

        const images = try allocator.alloc(vk.Image, count);
        const swap_images = try allocator.alloc(SwapImage, count);

        defer allocator.free(images);
        defer allocator.free(swap_images);
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, handle, &count, images.ptr);
        errdefer allocator.free(swap_images);

        for (images) |image, index| swap_images[index] = try SwapImage.init(ctx, image, surface_format.format);

        errdefer {
            for (swap_images[0..i]) |img| img.deinit(ctx);
            allocator.free(swap_images);
        }
        break :images swap_images;
    };
    // zig fmt: off
    return Self{
        .allocator = allocator,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .extent = actual_extent,
        .handle = handle,
        .swap_images = swap_images,
        .image_index = 0
    };
    // zig fmt: on
}

pub fn deinit(self: Self, ctx: Context) void {
    for (self.swap_images) |img| img.deinit(ctx);
    self.allocator.free(self.swap_images);
    ctx.vkd.destroySwapchainKHR(ctx.device, self.handle, null);
}

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(ctx: Context, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try ctx.vkd.createImageView(ctx.device, &.{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer ctx.vkd.destroyImageView(ctx.device, view, null);

        const image_acquired = try ctx.vkd.createSemaphore(ctx.device, &.{ .flags = .{} }, null);
        errdefer ctx.vkd.destroySemaphore(ctx.device, image_acquired, null);

        const render_finished = try ctx.vkd.createSemaphore(ctx.device, &.{ .flags = .{} }, null);
        errdefer ctx.vkd.destroySemaphore(ctx.device, render_finished, null);

        const frame_fence = try ctx.vkd.createFence(ctx.device, &.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer ctx.vkd.destroyFence(ctx.device, frame_fence, null);

        return SwapImage{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, ctx: Context) void {
        self.waitForFence(ctx) catch return;
        ctx.vkd.destroyImageView(ctx.device, self.view, null);
        ctx.vkd.destroySemaphore(ctx.device, self.image_acquired, null);
        ctx.vkd.destroySemaphore(ctx.device, self.render_finished, null);
        ctx.vkd.destroyFence(ctx.device, self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, ctx: Context) !void {
        _ = try ctx.vkd.waitForFences(ctx.device, 1, @ptrCast([*]const vk.Fence, &self.frame_fence), vk.TRUE, std.math.maxInt(u64));
    }
};

fn findSurfaceFormat(ctx: Context, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    var count: u32 = undefined;
    _ = try ctx.vki.getPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &count, null);
    const surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
    defer allocator.free(surface_formats);
    _ = try ctx.vki.getPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &count, surface_formats.ptr);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

fn findPresentMode(ctx: Context, allocator: Allocator) !vk.PresentModeKHR {
    var count: u32 = undefined;
    _ = try ctx.vki.getPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &count, null);
    const present_modes = try allocator.alloc(vk.PresentModeKHR, count);
    defer allocator.free(present_modes);
    _ = try ctx.vki.getPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &count, present_modes.ptr);

    const preferred = [_]vk.PresentModeKHR{
        .fifo_khr,
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}
