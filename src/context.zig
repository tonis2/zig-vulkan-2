const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const PhysicalDevice = @import("physical_device.zig");
const glfw = @import("glfw");
const vma = @import("vma");

const QueueFamilyIndices = PhysicalDevice.QueueFamilyIndices;
const ArrayList = std.ArrayList;

// Constants
pub const enable_safety = builtin.mode == .Debug;
pub const engine_name = "engine";
pub const engine_version = vk.makeApiVersion(0, 0, 1, 0);
pub const application_version = vk.makeApiVersion(0, 0, 1, 0);
pub const logicical_device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
pub const max_frames_in_flight = 2;

// const required_validation_features = [_]vk.ValidationFeatureEnableEXT{
//     .gpu_assisted_ext,
//     .best_practices_ext,
//     .synchronization_validation_ext,
// };

const debug_extensions = [_][*:0]const u8{
    vk.extension_info.ext_debug_report.name,
    vk.extension_info.ext_debug_utils.name,
};

const required_instance_layers = [_][*:0]const u8{
    "VK_LAYER_LUNARG_standard_validation",
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(vkd: Device, dev: vk.Device, family: u32) Queue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};

const Self = @This();

allocator: vma.Allocator,
vkb: Base,
vki: Instance,
vkd: Device,
surface: vk.SurfaceKHR,
instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,
props: vk.PhysicalDeviceProperties,
feature: vk.PhysicalDeviceFeatures,
memory_properties: vk.PhysicalDeviceMemoryProperties,
compute_queue: Queue,
graphics_queue: Queue,
present_queue: Queue,
queue_indices: QueueFamilyIndices,
gfx_pool: vk.CommandPool,
messenger: ?vk.DebugUtilsMessengerEXT,

// Caller should make sure to call deinit
pub fn init(allocator: Allocator, application_name: []const u8, window: *glfw.Window) !Self {
    const app_name = try std.cstr.addNullByte(allocator, application_name);
    defer allocator.destroy(app_name.ptr);

    const app_info = vk.ApplicationInfo{
        .p_next = null,
        .p_application_name = app_name,
        .application_version = application_version,
        .p_engine_name = engine_name,
        .engine_version = engine_version,
        .api_version = vk.API_VERSION_1_2,
    };

    const glfw_exts = try glfw.getRequiredInstanceExtensions();

    var instance_exts = blk: {
        if (enable_safety) {
            var exts = try std.ArrayList([*:0]const u8).initCapacity(
                allocator,
                glfw_exts.len + debug_extensions.len,
            );
            {
                try exts.appendSlice(glfw_exts);
                for (debug_extensions) |e| {
                    try exts.append(e);
                }
            }
            break :blk exts.toOwnedSlice();
        }

        break :blk glfw_exts;
    };

    defer if (enable_safety) {
        allocator.free(instance_exts);
    };

    const validation_features = blk: {
        if (enable_safety) {
            break :blk &vk.ValidationFeaturesEXT{
                .enabled_validation_feature_count = @truncate(u32, debug_extensions.len),
                .p_enabled_validation_features = @ptrCast(
                    [*]const vk.ValidationFeatureEnableEXT,
                    &debug_extensions,
                ),
                .disabled_validation_feature_count = 0,
                .p_disabled_validation_features = undefined,
            };
        }

        break :blk null;
    };

    var self: Self = undefined;

    const vk_proc = @ptrCast(vk.PfnGetInstanceProcAddr, glfw.getInstanceProcAddress);
    self.vkb = try Base.load(vk_proc);

    if (!(try utils.isInstanceExtensionsPresent(allocator, self.vkb, instance_exts))) {
        return error.InstanceExtensionNotPresent;
    }

    self.instance = blk: {
        const instanceInfo = vk.InstanceCreateInfo{
            .p_next = validation_features,
            .flags = .{},
            .p_application_info = &app_info,
            .enabled_layer_count = if (enable_safety) 1,
            .pp_enabled_layer_names = &required_instance_layers,
            .enabled_extension_count = @intCast(u32, instance_exts.len),
            .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, instance_exts),
        };
        break :blk try self.vkb.createInstance(&instanceInfo, null);
    };

    self.vki = try Instance.load(self.instance, vk_proc);
    errdefer self.vki.destroyInstance(self.instance, null);

    if ((try glfw.createWindowSurface(self.instance, window.*, null, &self.surface)) != @enumToInt(vk.Result.success)) {
        return error.SurfaceInitFailed;
    }

    errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);

    var device_candidate = try PhysicalDevice.DeviceCandidate.init(self.vki, self.instance, allocator, self.surface);
    self.physical_device = device_candidate.pdev;
    self.device = try device_candidate.initDevice(self.vki);
    self.queue_indices = device_candidate.queues;

    self.messenger = blk: {
        if (!enable_safety) break :blk null;
        const create_info = vk.DebugUtilsMessengerCreateInfoEXT{
            .flags = .{},
            .message_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
                .verbose_bit_ext = true,
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = vk.DebugUtilsMessageTypeFlagsEXT{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
            },
            .pfn_user_callback = debugCallback,
            .p_user_data = null,
        };
        break :blk self.vki.createDebugUtilsMessengerEXT(self.instance, &create_info, null) catch {
            std.debug.panic("failed to create debug messenger", .{});
        };
    };

    self.vkd = try Device.load(self.device, self.vki.dispatch.vkGetDeviceProcAddr);
    errdefer self.vkd.destroyDevice(self.device, null);

    self.compute_queue = Queue.init(self.vkd, self.device, self.queue_indices.compute.?);
    self.graphics_queue = Queue.init(self.vkd, self.device, self.queue_indices.graphics.?);
    self.present_queue = Queue.init(self.vkd, self.device, self.queue_indices.present.?);
    self.memory_properties = self.vki.getPhysicalDeviceMemoryProperties(self.physical_device);

    const vma_fns = getVmaVulkanFunction(self.vki, self.vkd);
    self.allocator = try vma.Allocator.create(.{
        .flags = .{},
        .physicalDevice = self.physical_device,
        .device = self.device,
        .instance = self.instance,
        .frameInUseCount = 0,
        .pVulkanFunctions = &vma_fns,
        .vulkanApiVersion = vk.API_VERSION_1_1,
    });
    // self.gfx_cmd_pool = blk: {
    //     const pool_info = vk.CommandPoolCreateInfo{
    //         .flags = .{},
    //         .queue_family_index = self.queue_indices.graphics.?,
    //     };
    //     break :blk try self.vkd.createCommandPool(self.device, &pool_info, null);
    // };

    // self.comp_cmd_pool = blk: {
    //     const pool_info = vk.CommandPoolCreateInfo{
    //         .flags = .{},
    //         .queue_family_index = self.queue_indices.compute.?,
    //     };
    //     break :blk try self.vkd.createCommandPool(self.device, &pool_info, null);
    // };

    return self;
}

pub fn deinit(self: Self) void {
    self.vkd.destroyCommandPool(self.device, self.gfx_pool, null);
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);
    self.vkd.destroyDevice(self.device, null);

    if (enable_safety) {
        self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger.?, null);
    }
    self.vki.destroyInstance(self.instance, null);
}

pub const Base = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceExtensionProperties = true,
    .enumerateInstanceLayerProperties = true,
});

pub const Instance = vk.InstanceWrapper(.{
    //vma
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceMemoryProperties = true,

    //debug
    .createDebugUtilsMessengerEXT = enable_safety,
    .destroyDebugUtilsMessengerEXT = enable_safety,

    //normal
    .destroyInstance = true,
    .createDevice = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getDeviceProcAddr = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceFeatures2 = true,
    .getPhysicalDeviceFormatProperties = true,
});

pub const Device = vk.DeviceWrapper(.{
    //vma
    .createImage = true,
    .destroyImage = true,
    .bindImageMemory = true,
    .getImageMemoryRequirements2 = true,
    .getBufferMemoryRequirements2 = true,
    .flushMappedMemoryRanges = true,
    //debug

    // .cmdInsertDebugUtilsLabelEXT = enable_safety,
    // .setDebugUtilsObjectNameEXT = enable_safety,

    //normal
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSemaphore = true,
    .createFence = true,
    .createImageView = true,
    .destroyImageView = true,
    .destroySemaphore = true,
    .destroyFence = true,
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .acquireNextImageKHR = true,
    .deviceWaitIdle = true,
    .waitForFences = true,
    .resetFences = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .queueWaitIdle = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createRenderPass = true,
    .destroyRenderPass = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .allocateMemory = true,
    .freeMemory = true,
    .createBuffer = true,
    .destroyBuffer = true,
    .getBufferMemoryRequirements = true,
    .mapMemory = true,
    .unmapMemory = true,
    .bindBufferMemory = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdBindVertexBuffers = true,
    .cmdCopyBuffer = true,
});

// zig fmt: on

pub const BeginCommandBufferError = Device.BeginCommandBufferError;

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_types;
    _ = p_user_data;

    if (p_callback_data) |data| {
        const level = (vk.DebugUtilsMessageSeverityFlagsEXT{
            .warning_bit_ext = true,
        }).toInt();
        if (message_severity >= level) {
            std.log.info("{s}", .{data.p_message});

            if (data.object_count > 0) {
                std.log.info("----------Objects {}-----------\n", .{data.object_count});
                var i: u32 = 0;
                while (i < data.object_count) : (i += 1) {
                    const o: vk.DebugUtilsObjectNameInfoEXT = data.p_objects[i];
                    std.log.info("[{}-{s}]: {s}", .{
                        i,
                        @tagName(o.object_type),
                        o.p_object_name,
                    });
                }
                std.log.info("----------End Object-----------\n", .{});
            }
            if (data.cmd_buf_label_count > 0) {
                std.log.info("----------Labels {}------------\n", .{data.object_count});
                var i: u32 = 0;
                while (i < data.cmd_buf_label_count) : (i += 1) {
                    const o: vk.DebugUtilsLabelEXT = data.p_cmd_buf_labels[i];
                    std.log.info("[{}]: {s}", .{
                        i,
                        o.p_label_name,
                    });
                }
                std.log.info("----------End Label------------\n", .{});
            }
        }
    }

    return vk.FALSE;
}

pub fn getVmaVulkanFunction(vki: Instance, vkd: Device) vma.VulkanFunctions {
    return .{
        .getInstanceProcAddr = undefined,
        .getDeviceProcAddr = undefined,
        .getPhysicalDeviceProperties = vki.dispatch.vkGetPhysicalDeviceProperties,
        .getPhysicalDeviceMemoryProperties = vki.dispatch.vkGetPhysicalDeviceMemoryProperties,
        .allocateMemory = vkd.dispatch.vkAllocateMemory,
        .freeMemory = vkd.dispatch.vkFreeMemory,
        .mapMemory = vkd.dispatch.vkMapMemory,
        .unmapMemory = vkd.dispatch.vkUnmapMemory,
        .flushMappedMemoryRanges = vkd.dispatch.vkFlushMappedMemoryRanges,
        .invalidateMappedMemoryRanges = undefined,
        .bindBufferMemory = vkd.dispatch.vkBindBufferMemory,
        .bindImageMemory = vkd.dispatch.vkBindImageMemory,
        .getBufferMemoryRequirements = undefined,
        .getImageMemoryRequirements = undefined,
        .createBuffer = vkd.dispatch.vkCreateBuffer,
        .destroyBuffer = vkd.dispatch.vkDestroyBuffer,
        .createImage = vkd.dispatch.vkCreateImage,
        .destroyImage = vkd.dispatch.vkDestroyImage,
        .cmdCopyBuffer = vkd.dispatch.vkCmdCopyBuffer,
        .getBufferMemoryRequirements2 = vkd.dispatch.vkGetBufferMemoryRequirements2,
        .getImageMemoryRequirements2 = vkd.dispatch.vkGetImageMemoryRequirements2,
        .bindBufferMemory2 = undefined,
        .bindImageMemory2 = undefined,
        .getPhysicalDeviceMemoryProperties2 = undefined,
    };
}
