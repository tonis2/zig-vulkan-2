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
    .sample_rate_shading = vk.TRUE,
    .texture_compression_bc = vk.TRUE,
    .shader_int_16 = vk.TRUE,
};

pub const QueueFamilyIndices = struct {
    compute: ?u32,
    graphics: ?u32,
    present: ?u32,
};

pub const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    feature: vk.PhysicalDeviceFeatures,
    queues: QueueFamilyIndices,

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

        for (pdevs) |pdev| {
            if (try checkSuitable(vki, pdev, allocator, surface)) |device| {
                return device;
            }
        }

        return error.NoSuitableDevice;
    }

    fn checkSuitable(
        vki: Context.Instance,
        pdev: vk.PhysicalDevice,
        allocator: Allocator,
        surface: vk.SurfaceKHR,
    ) !?DeviceCandidate {
        const props = vki.getPhysicalDeviceProperties(pdev);
        _ = try checkExtensionSupport(vki, pdev, allocator);
        _ = try checkSurfaceSupport(vki, pdev, surface);

        const feature = vki.getPhysicalDeviceFeatures(pdev);
        inline for (std.meta.fields(vk.PhysicalDeviceFeatures)) |field| {
            if (@field(required_device_feature, field.name) == vk.TRUE) {
                if (@field(feature, field.name) == vk.FALSE) return null;
            }
        }
        if (try allocateQueues(vki, pdev, allocator, surface)) |queues| {
            return DeviceCandidate{ .pdev = pdev, .props = props, .feature = feature, .queues = queues };
        }
        return null;
    }

    pub fn initDevice(self: *DeviceCandidate, vki: Context.Instance) !vk.Device {
        const priority = [_]f32{1};
        const qci = [_]vk.DeviceQueueCreateInfo{
            .{
                .flags = .{},
                .queue_family_index = self.queues.graphics.?,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .flags = .{},
                .queue_family_index = self.queues.present.?,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .flags = .{},
                .queue_family_index = self.queues.compute.?,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        var storage_16 = vk.PhysicalDevice16BitStorageFeatures{
            .storage_buffer_16_bit_access = vk.TRUE,
            .uniform_and_storage_buffer_16_bit_access = vk.TRUE,
        };

        var khr_synchronization_2 = vk.PhysicalDeviceSynchronization2Features{
            .synchronization_2 = vk.TRUE,
            .p_next = @ptrCast(*anyopaque, &storage_16),
        };
        const descriptor_indexing = vk.PhysicalDeviceDescriptorIndexingFeatures{
            .p_next = @ptrCast(*anyopaque, &khr_synchronization_2),
            // .shader_input_attachment_array_dynamic_indexing= Bool32 = FALSE,
            // .shader_uniform_texel_buffer_array_dynamic_indexing= Bool32 = FALSE,
            // .shader_storage_texel_buffer_array_dynamic_indexing= Bool32 = FALSE,
            // .shader_uniform_buffer_array_non_uniform_indexing= Bool32 = FALSE,
            .shader_sampled_image_array_non_uniform_indexing = vk.TRUE,
            // .shader_storage_buffer_array_non_uniform_indexing= Bool32 = FALSE,
            // .shader_storage_image_array_non_uniform_indexing= Bool32 = FALSE,
            // .shader_input_attachment_array_non_uniform_indexing= Bool32 = FALSE,
            // .shader_uniform_texel_buffer_array_non_uniform_indexing= Bool32 = FALSE,
            // .shader_storage_texel_buffer_array_non_uniform_indexing= Bool32 = FALSE,
            // .descriptor_binding_uniform_buffer_update_after_bind= Bool32 = FALSE,
            // .descriptor_binding_sampled_image_update_after_bind= Bool32 = FALSE,
            // .descriptor_binding_storage_image_update_after_bind= Bool32 = FALSE,
            // .descriptor_binding_storage_buffer_update_after_bind= Bool32 = FALSE,
            // .descriptor_binding_uniform_texel_buffer_update_after_bind= Bool32 = FALSE,
            // .descriptor_binding_storage_texel_buffer_update_after_bind= Bool32 = FALSE,
            .descriptor_binding_update_unused_while_pending = vk.TRUE,
            .descriptor_binding_partially_bound = vk.TRUE,
            .descriptor_binding_variable_descriptor_count = vk.TRUE,
            .runtime_descriptor_array = vk.TRUE,
        };

        return try vki.createDevice(self.pdev, &.{
            .flags = .{},
            .p_next = @ptrCast(*const anyopaque, &descriptor_indexing),
            .queue_create_info_count = 3,
            .p_queue_create_infos = &qci,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = undefined,
            .enabled_extension_count = required_device_extensions.len,
            .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, &required_device_extensions),
            .p_enabled_features = &required_device_feature,
        }, null);
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
        return QueueFamilyIndices{ .graphics = graphics_family.?, .present = present_family.?, .compute = compute_family.? };
    }

    return null;
}

fn checkSurfaceSupport(vki: Context.Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn isFormatSupport(vki: Context.Instance, p_dev: vk.PhysicalDevice, format: vk.Format) bool {
    const fp = vki.getPhysicalDeviceFormatProperties(p_dev, format);
    return fp.optimal_tiling_features.contains(.{
        .sampled_image_bit = true,
        .transfer_dst_bit = true,
    });
}

fn checkExtensionSupport(
    vki: Context.Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    var count: u32 = undefined;
    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, propsv.ptr);

    // for (propsv) |props| {
    //     const len = std.mem.indexOfScalar(u8, &props.extension_name, 0).?;
    //     const prop_ext_name = props.extension_name[0..len];
    //     std.log.info("{s}", .{prop_ext_name});
    // }

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            const len = std.mem.indexOfScalar(u8, &props.extension_name, 0).?;
            const prop_ext_name = props.extension_name[0..len];
            if (std.mem.eql(u8, std.mem.span(ext), prop_ext_name)) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}
