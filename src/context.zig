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

pub const Swapchain = @import("swapchain.zig");
pub const Buffer = @import("buffer.zig");
pub const Descriptor = @import("descriptor.zig");

// Constants
pub const enable_safety = builtin.mode == .Debug;
pub const engine_name = "engine";
pub const engine_version = vk.makeApiVersion(0, 0, 1, 0);
pub const application_version = vk.makeApiVersion(0, 0, 1, 0);
pub const logicical_device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
pub const max_frames_in_flight = 2;

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
command_pool: vk.CommandPool,
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
            .enabled_layer_count = if (enable_safety) 1 else 0,
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
    self.graphics_queue = Queue.init(self.vkd, self.device, self.queue_indices.graphics);
    self.present_queue = Queue.init(self.vkd, self.device, self.queue_indices.present);
    self.memory_properties = self.vki.getPhysicalDeviceMemoryProperties(self.physical_device);

    self.allocator = try vma.Allocator.create(.{
        .flags = .{},
        .physicalDevice = self.physical_device,
        .device = self.device,
        .instance = self.instance,
        .frameInUseCount = 0,
        .pVulkanFunctions = &getVmaVulkanFunction(self.vki, self.vkd),
        .vulkanApiVersion = vk.API_VERSION_1_2,
    });

    self.command_pool = try self.vkd.createCommandPool(self.device, &.{
        .flags = .{},
        .queue_family_index = self.graphics_queue.family,
    }, null);
    errdefer self.vkd.destroyCommandPool(self.device, self.command_pool, null);

    return self;
}

pub fn beginOneTimeCommandBuffer(self: Self) !vk.CommandBuffer {
    var cmdbuf: vk.CommandBuffer = undefined;
    try self.vkd.allocateCommandBuffers(self.device, &.{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast([*]vk.CommandBuffer, &cmdbuf));

    try self.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });
    return cmdbuf;
}

pub fn endOneTimeCommandBuffer(self: Self, cmdbuf: vk.CommandBuffer) !void {
    try self.vkd.endCommandBuffer(cmdbuf);
    // Create fence to ensure that the command buffer has finished executing

    const fence = try self.vkd.createFence(self.device, &.{ .flags = .{} }, null);
    errdefer self.vkd.destroyFence(self.device, fence, null);

    // Submit to the queue
    try self.vkd.queueSubmit2(self.graphics_queue.handle, 1, &[_]vk.SubmitInfo2{.{
        .flags = .{},
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = undefined,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &[_]vk.CommandBufferSubmitInfo{.{
            .command_buffer = cmdbuf,
            .device_mask = 0,
        }},
        .signal_semaphore_info_count = 0,
        .p_signal_semaphore_infos = undefined,
    }}, fence);

    // Wait for the fence to signal that command buffer has finished executing
    _ = try self.vkd.waitForFences(self.device, 1, @ptrCast([*]const vk.Fence, &fence), vk.TRUE, std.math.maxInt(u64));

    self.vkd.destroyFence(self.device, fence, null);
    self.vkd.freeCommandBuffers(self.device, self.command_pool, 1, @ptrCast([*]const vk.CommandBuffer, &cmdbuf));
}

pub fn createCommandBuffers(self: Self, allocator: Allocator, len: u32) ![]vk.CommandBuffer {
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, len);
    errdefer allocator.free(cmdbufs);

    try self.vkd.allocateCommandBuffers(self.device, &.{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = len,
    }, cmdbufs.ptr);
    errdefer self.vkd.freeCommandBuffers(self.device, self.command_pool, len, cmdbufs.ptr);
    return cmdbufs;
}

pub fn deinitCmdBuffer(self: Self, allocator: Allocator, buffers: []vk.CommandBuffer) void {
    self.vkd.freeCommandBuffers(self.device, self.command_pool, @truncate(u32, buffers.len), buffers.ptr);
    allocator.free(buffers);
}

pub fn deinit(self: Self) void {
    self.vkd.destroyCommandPool(self.device, self.command_pool, null);
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
    .queueSubmit2 = true,
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
    .createDescriptorPool = true,
    .destroyDescriptorPool = true,
    .createDescriptorSetLayout = true,
    .destroyDescriptorSetLayout = true,
    .allocateDescriptorSets = true,
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
    .cmdBindIndexBuffer = true,
    .cmdDrawIndexed = true,
});

// zig fmt: on

pub fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = p_user_data;
    _ = message_types;

    const error_mask = comptime blk: {
        break :blk vk.DebugUtilsMessageSeverityFlagsEXT{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        };
    };
    const is_severe = error_mask.toInt() & message_severity > 0;
    const writer = if (is_severe) std.io.getStdErr().writer() else std.io.getStdOut().writer();

    if (p_callback_data) |data| {
        writer.print("validation layer: {s}\n", .{data.p_message}) catch {
            std.debug.print("error from stdout print in message callback", .{});
        };
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
