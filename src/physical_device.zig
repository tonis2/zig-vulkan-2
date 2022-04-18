/// Abstractions around vulkan physical device
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const vk = @import("vulkan");
const utils = @import("utils.zig");
const Context = @import("context.zig");

const required_device_extensions = [_][*:0]const u8{
    vk.extension_info.khr_swapchain.name,
    // vk.extension_info.ext_descriptor_indexing.name,
    // vk.extension_info.khr_synchronization_2.name,
    vk.extension_info.khr_push_descriptor.name,
};

const required_device_feature = vk.PhysicalDeviceFeatures{
    .sampler_anisotropy = vk.TRUE,
};

pub const QueueFamilyIndices = struct {
    compute: ?u32,
    graphics: u32,
    present: u32,
};

pub const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    feature: vk.PhysicalDeviceFeatures,
    queues: QueueFamilyIndices,
    extensions: u32,

    pub fn init(
        vki: Context.Instance,
        instance: vk.Instance,
        allocator: Allocator,
        surface: vk.SurfaceKHR,
    ) !DeviceCandidate {
        var device_count: u32 = undefined;
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);

        const pdevs = try allocator.alloc(vk.PhysicalDevice, device_count);
        defer allocator.free(pdevs);

        _ = try vki.enumeratePhysicalDevices(instance, &device_count, pdevs.ptr);

        const deviceCandidates = try allocator.alloc(DeviceCandidate, device_count);
        defer allocator.free(deviceCandidates);

        for (pdevs) |pdev, index| {
            const device = try checkSuitable(vki, pdev, allocator, surface);
            if (device != null) deviceCandidates[index] = device.?;
        }

        var extensions: u32 = 0;
        var best_candidate: ?DeviceCandidate = null;
        for (deviceCandidates) |candidate| {
            if (candidate.extensions > extensions) {
                best_candidate = candidate;
            }
        }

        if (best_candidate != null) {
            std.debug.print("Using GPU {s} \n", .{best_candidate.?.props.device_name});
            return best_candidate.?;
        }
        return error.NoSuitableDevice;
    }

    fn checkSuitable(
        vki: Context.Instance,
        pdev: vk.PhysicalDevice,
        allocator: Allocator,
        surface: vk.SurfaceKHR,
    ) !?DeviceCandidate {
        const extensionSupport: ?u32 = blk: {
            var count: u32 = undefined;
            _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, null);

            const propsv = try allocator.alloc(vk.ExtensionProperties, count);
            defer allocator.free(propsv);

            _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, propsv.ptr);

            for (required_device_extensions) |ext| {
                for (propsv) |props| {
                    const len = std.mem.indexOfScalar(u8, &props.extension_name, 0).?;
                    const prop_ext_name = props.extension_name[0..len];
                    if (std.mem.eql(u8, std.mem.span(ext), prop_ext_name)) {
                        break;
                    }
                } else {
                    return error.NoExtensions;
                }
            }

            break :blk count;
        };

        const feature = vki.getPhysicalDeviceFeatures(pdev);
        const supportsDeviceFeatures: bool = brk: {
            inline for (std.meta.fields(vk.PhysicalDeviceFeatures)) |field| {
                if (@field(required_device_feature, field.name) == vk.TRUE) {
                    if (@field(feature, field.name) == 0) break :brk false;
                }
            }
            break :brk true;
        };
        if (!supportsDeviceFeatures) return null;

        const surfaceSupport = brk: {
            var format_count: u32 = undefined;
            _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

            var present_mode_count: u32 = undefined;
            _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

            break :brk format_count > 0 and present_mode_count > 0;
        };

        if (!surfaceSupport) return null;
        if (try allocateQueues(vki, pdev, allocator, surface)) |queues| {
            // zig fmt: off
            return DeviceCandidate{ 
                .pdev = pdev, 
                .props = vki.getPhysicalDeviceProperties(pdev), 
                .feature = feature, 
                .queues = queues, 
                .extensions = extensionSupport orelse 0, 
            // zig fmt: on
            };
        }
        return null;
    }
};

fn allocateQueues(vki: Context.Instance, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueFamilyIndices {
    var family_count: u32 = undefined;
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;
    var compute_family: ?u32 = null;

    for (families) |properties, i| {
        const family = @intCast(u32, i);

        if (compute_family == null and properties.queue_flags.compute_bit) {
            compute_family = family;
        }

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueFamilyIndices{ .graphics = graphics_family.?, .present = present_family.?, .compute = compute_family };
    }

    return null;
}

fn isFormatSupport(vki: Context.Instance, p_dev: vk.PhysicalDevice, format: vk.Format) bool {
    const fp = vki.getPhysicalDeviceFormatProperties(p_dev, format);
    return fp.optimal_tiling_features.contains(.{
        .sampled_image_bit = true,
        .transfer_dst_bit = true,
    });
}

// fn checkExtensionSupport(
//     vki: Context.Instance,
//     pdev: vk.PhysicalDevice,
//     allocator: Allocator,
// ) !bool {

//     return true;
// }
