const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig");

const Swapchain = @This();

allocator: Allocator,
swapchain_khr: vk.SwapchainKHR,
images: []SwapImage,
format: vk.Format,
extent: vk.Extent2D,
support_details: SupportDetails,

const Config = struct {
    sharing_mode: vk.SharingMode,
    index_count: u32,
    p_indices: [*]const u32,
};

pub fn init(allocator: Allocator, ctx: Context, extent: vk.Extent2D, old_swapchain: ?vk.SwapchainKHR) !Swapchain {
    const supportDetails = try SupportDetails.init(allocator, ctx);
    errdefer supportDetails.deinit(allocator);

    const swapchain_extent = supportDetails.constructSwapChainExtent(extent);

    const sc_create_info = blk1: {
        const format = supportDetails.selectSwapChainFormat();
        const present_mode = supportDetails.selectSwapchainPresentMode();

        const image_count = std.math.min(supportDetails.capabilities.min_image_count + 1, supportDetails.capabilities.max_image_count);
        const sharing_config = blk2: {
            if (ctx.queue_indices.graphics != ctx.queue_indices.present) {
                const indices_arr = [_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.present };
                break :blk2 Config{
                    .sharing_mode = vk.SharingMode.concurrent, // TODO: read up on ownership in this context
                    .index_count = indices_arr.len,
                    .p_indices = @ptrCast([*]const u32, &indices_arr[0..indices_arr.len]),
                };
            } else {
                const indices_arr = [_]u32{ ctx.queue_indices.graphics, ctx.queue_indices.present };
                break :blk2 Config{
                    .sharing_mode = vk.SharingMode.exclusive,
                    .index_count = 0,
                    .p_indices = @ptrCast([*]const u32, &indices_arr[0..indices_arr.len]),
                };
            }
        };

        break :blk1 vk.SwapchainCreateInfoKHR{
            .flags = .{},
            .surface = ctx.surface,
            .min_image_count = image_count,
            .image_format = format.format,
            .image_color_space = format.color_space,
            .image_extent = swapchain_extent,
            .image_array_layers = 1,
            .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },
            .image_sharing_mode = sharing_config.sharing_mode,
            .queue_family_index_count = sharing_config.index_count,
            .p_queue_family_indices = sharing_config.p_indices,
            .pre_transform = supportDetails.capabilities.current_transform,
            .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain orelse vk.SwapchainKHR.null_handle,
        };
    };

    const swapchain_khr = try ctx.vkd.createSwapchainKHR(ctx.device, &sc_create_info, null);

    var image_count: u32 = 0;

    _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain_khr, &image_count, null);

    const images = try allocator.alloc(vk.Image, image_count);
    defer allocator.free(images);

    _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain_khr, &image_count, images.ptr);

    var swapchain_images = try allocator.alloc(SwapImage, image_count);
    errdefer allocator.free(swapchain_images);

    for (images) |image, index| {
        swapchain_images[index] = try SwapImage.init(ctx, image, sc_create_info.image_format);
        errdefer swapchain_images[index].deinit(ctx);
    }

    return Swapchain{
        .allocator = allocator,
        .support_details = supportDetails,
        .format = sc_create_info.image_format,
        .extent = swapchain_extent,
        .swapchain_khr = swapchain_khr,
        .images = swapchain_images,
    };
}

pub fn deinit(self: Swapchain, ctx: Context) void {
    for (self.images) |image| {
        image.deinit(ctx);
    }
    self.support_details.deinit(self.allocator);
    ctx.vkd.destroySwapchainKHR(ctx.device, self.swapchain_khr, null);
}

pub const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,
    cmdbuf: ?vk.CommandBuffer = null,

    fn init(
        ctx: Context,
        image: vk.Image,
        format: vk.Format,
    ) !SwapImage {
        const components = vk.ComponentMapping{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        };

        const subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const create_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = components,
            .subresource_range = subresource_range,
        };

        const imageView = try ctx.vkd.createImageView(ctx.device, &create_info, null);
        errdefer ctx.vkd.destroyImageView(ctx.device, imageView, null);

        const image_acquired = try ctx.vkd.createSemaphore(
            ctx.device,
            &vk.SemaphoreCreateInfo{ .flags = .{} },
            null,
        );
        errdefer ctx.vkd.destroySemaphore(ctx.device, image_acquired, null);

        const render_finished = try ctx.vkd.createSemaphore(
            ctx.device,
            &vk.SemaphoreCreateInfo{ .flags = .{} },
            null,
        );
        errdefer ctx.vkd.destroySemaphore(ctx.device, render_finished, null);

        const frame_fence = try ctx.vkd.createFence(
            ctx.device,
            &vk.FenceCreateInfo{ .flags = .{} },
            null,
        );
        errdefer ctx.vkd.destroyFence(ctx.device, frame_fence, null);

        return SwapImage{
            .image = image,
            .view = imageView,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, ctx: Context) void {
        self.waitForFence(ctx) catch return;
        ctx.vkd.destroyImage(ctx.device, self.image, null);
        ctx.vkd.destroyImageView(ctx.device, self.view, null);
        ctx.vkd.destroySemaphore(ctx.device, self.image_acquired, null);
        ctx.vkd.destroySemaphore(ctx.device, self.render_finished, null);
        ctx.vkd.destroyFence(ctx.device, self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, ctx: Context) !void {
        _ = try ctx.vkd.waitForFences(ctx.device, 1, @ptrCast([*]const vk.Fence, &self.frame_fence), vk.TRUE, std.math.maxInt(u64));
    }
};

pub const SupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,

    /// caller has to make sure to also call deinit
    pub fn init(allocator: Allocator, ctx: Context) !SupportDetails {
        const capabilities = try ctx.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface);

        var format_count: u32 = 0;

        _ = try ctx.vki.getPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, null);
        if (format_count <= 0) {
            return error.NoSurfaceFormatsSupported;
        }
        const formats = blk: {
            var formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
            _ = try ctx.vki.getPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, formats.ptr);
            formats.len = format_count;
            break :blk formats;
        };
        errdefer allocator.free(formats);

        var present_modes_count: u32 = 0;
        _ = try ctx.vki.getPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &present_modes_count, null);
        if (present_modes_count <= 0) {
            return error.NoPresentModesSupported;
        }
        const present_modes = blk: {
            var present_modes = try allocator.alloc(vk.PresentModeKHR, present_modes_count);
            _ = try ctx.vki.getPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &present_modes_count, present_modes.ptr);
            present_modes.len = present_modes_count;
            break :blk present_modes;
        };
        errdefer allocator.free(present_modes);

        return SupportDetails{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    pub fn selectSwapChainFormat(self: SupportDetails) vk.SurfaceFormatKHR {
        std.debug.assert(self.formats.len > 0);

        for (self.formats) |format| {
            if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                return format;
            }
        }

        return self.formats[0];
    }

    pub fn selectSwapchainPresentMode(self: SupportDetails) vk.PresentModeKHR {
        for (self.present_modes) |present_mode| {
            if (present_mode == .mailbox_khr) {
                return present_mode;
            }
        }

        return .fifo_khr;
    }

    pub fn constructSwapChainExtent(self: SupportDetails, window_size: vk.Extent2D) vk.Extent2D {
        if (self.capabilities.current_extent.width != std.math.maxInt(u32)) {
            return self.capabilities.current_extent;
        } else {
            const clamp = std.math.clamp;
            const min = self.capabilities.min_image_extent;
            const max = self.capabilities.max_image_extent;
            return vk.Extent2D{
                .width = clamp(window_size.width, min.width, max.width),
                .height = clamp(window_size.height, min.height, max.height),
            };
        }
    }

    pub fn deinit(self: SupportDetails, allocator: Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
    }
};
