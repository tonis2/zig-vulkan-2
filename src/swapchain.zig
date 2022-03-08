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

pub fn init(allocator: Allocator, ctx: Context, extent: vk.Extent2D, old_swapchain: ?vk.SwapchainKHR) !void {
    const support_details = try SupportDetails.init(allocator, ctx);
    errdefer support_details.deinit(allocator);
    const swapchain_extent = support_details.constructSwapChainExtent(extent);
    _ = swapchain_extent;
    _ = old_swapchain;
    defer support_details.deinit(allocator);
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
