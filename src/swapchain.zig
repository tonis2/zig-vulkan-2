const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig");

const Swapchain = @This();

allocator: Allocator,
swapchain: vk.SwapchainKHR,
images: []vk.Image,
image_views: []vk.ImageView,
format: vk.Format,
extent: vk.Extent2D,
support_details: SupportDetails,

const Config = struct {
    sharing_mode: vk.SharingMode,
    index_count: u32,
    p_indices: [*]const u32,
};

pub fn init(allocator: Allocator, ctx: Context, extent: vk.Extent2D, old_swapchain: ?vk.SwapchainKHR) !Swapchain {
    const support_details = try SupportDetails.init(allocator, ctx);
    errdefer support_details.deinit(allocator);
    const swapchain_extent = support_details.constructSwapChainExtent(extent);

    const sc_create_info = blk1: {
        const format = support_details.selectSwapChainFormat();
        const present_mode = support_details.selectSwapchainPresentMode();

        const image_count = std.math.min(support_details.capabilities.min_image_count + 1, support_details.capabilities.max_image_count);
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
            .pre_transform = support_details.capabilities.current_transform,
            .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain orelse vk.SwapchainKHR.null_handle,
        };
    };

    const swapchain_khr = try ctx.vkd.createSwapchainKHR(ctx.device, &sc_create_info, null);
    const swapchain_images = blk: {
        var image_count: u32 = 0;

        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain_khr, &image_count, null);

        var images = try allocator.alloc(vk.Image, image_count);
        errdefer allocator.free(images);

        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain_khr, &image_count, images.ptr);
        images.len = image_count;
        break :blk images;
    };
    errdefer allocator.free(swapchain_images);

    const image_views = blk: {
        const image_view_count = swapchain_images.len;
        var views = try allocator.alloc(vk.ImageView, image_view_count);
        errdefer allocator.free(views);

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
        {
            var i: u32 = 0;
            while (i < image_view_count) : (i += 1) {
                const create_info = vk.ImageViewCreateInfo{
                    .flags = .{},
                    .image = swapchain_images[i],
                    .view_type = .@"2d",
                    .format = sc_create_info.image_format,
                    .components = components,
                    .subresource_range = subresource_range,
                };
                views[i] = try ctx.vkd.createImageView(ctx.device, &create_info, null);
            }
        }

        break :blk views;
    };
    errdefer allocator.free(image_views);

    return Swapchain{
        .allocator = allocator,
        .swapchain = swapchain_khr,
        .images = swapchain_images,
        .image_views = image_views,
        .format = sc_create_info.image_format,
        .extent = sc_create_info.image_extent,
        .support_details = support_details,
    };
}

pub fn deinit(self: Swapchain, ctx: Context) void {
    for (self.image_views) |view| {
        ctx.vkd.destroyImageView(ctx.device, view, null);
    }
    self.allocator.free(self.image_views);
    self.allocator.free(self.images);
    self.support_details.deinit(self.allocator);

    ctx.vkd.destroySwapchainKHR(ctx.device, self.swapchain, null);
}

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
