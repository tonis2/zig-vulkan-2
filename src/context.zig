const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const PhysicalDevice = @import("physical_device.zig");
const glfw = @import("glfw");

const QueueFamilyIndices = PhysicalDevice.QueueFamilyIndices;
const ArrayList = std.ArrayList;

// Constants
pub const enable_safety = builtin.mode == .Debug;
pub const engine_name = "engine";
pub const engine_version = vk.makeApiVersion(0, 0, 1, 0);
pub const application_version = vk.makeApiVersion(0, 0, 1, 0);
pub const logicical_device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
pub const max_frames_in_flight = 2;

const required_validation_features = [_]vk.ValidationFeatureEnableEXT{
    .gpu_assisted_ext,
    .best_practices_ext,
    .synchronization_validation_ext,
};

const required_instance_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_synchronization2",
} ++ if (enable_safety) [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"} else [_][*:0]const u8{};

const Self = @This();

allocator: Allocator,
vkb: Base,
vki: Instance,
vkd: Device,
instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,

props: vk.PhysicalDeviceProperties,
feature: vk.PhysicalDeviceFeatures,

compute_queue: vk.Queue,
graphics_queue: vk.Queue,
present_queue: vk.Queue,

surface: vk.SurfaceKHR,
queue_indices: QueueFamilyIndices,

gfx_cmd_pool: vk.CommandPool,
comp_cmd_pool: vk.CommandPool,

// TODO: utilize comptime for this (emit from struct if we are in release mode)
messenger: ?vk.DebugUtilsMessengerEXT,

/// pointer to the window handle. Caution is adviced when using this pointer ...
// window_ptr: *glfw.Window,

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

    // TODO: move to global scope (currently crashes the zig compiler :') )
    const common_extensions = [_][*:0]const u8{vk.extension_info.khr_surface.name};
    const application_extensions = blk: {
        if (enable_safety) {
            const debug_extensions = [_][*:0]const u8{
                vk.extension_info.ext_debug_report.name,
                vk.extension_info.ext_debug_utils.name,
            } ++ common_extensions;
            break :blk debug_extensions[0..];
        }
        break :blk common_extensions[0..];
    };

    const glfw_exts = try glfw.getRequiredInstanceExtensions();

    var instance_exts = blk: {
        if (enable_safety) {
            var exts = try std.ArrayList([*:0]const u8).initCapacity(
                allocator,
                glfw_exts.len + application_extensions.len,
            );
            {
                try exts.appendSlice(glfw_exts);
                for (application_extensions) |e| {
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
                .enabled_validation_feature_count = @truncate(u32, application_extensions.len),
                .p_enabled_validation_features = @ptrCast(
                    [*]const vk.ValidationFeatureEnableEXT,
                    &application_extensions,
                ),
                .disabled_validation_feature_count = 0,
                .p_disabled_validation_features = undefined,
            };
        }

        break :blk null;
    };

    var self: Self = undefined;
    self.allocator = allocator;

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
            .enabled_layer_count = if (enable_safety) 2 else 1,
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
    // self.queue_indices = try QueueFamilyIndices.init(allocator, self.vki, self.physical_device, self.surface);

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
    // self.compute_queue = self.vkd.getDeviceQueue(self.physical_device, self.queue_indices.compute, 0);
    // self.graphics_queue = self.vkd.getDeviceQueue(self.physical_device, self.queue_indices.graphics, 0);
    // self.present_queue = self.vkd.getDeviceQueue(self.physical_device, self.queue_indices.present, 0);

    self.gfx_cmd_pool = blk: {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = self.queue_indices.graphics.?,
        };
        break :blk try self.vkd.createCommandPool(self.device, &pool_info, null);
    };

    self.comp_cmd_pool = blk: {
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = self.queue_indices.compute.?,
        };
        break :blk try self.vkd.createCommandPool(self.device, &pool_info, null);
    };

    // possibly a bit wasteful, but to get compile errors when forgetting to
    // init a variable the partial Self variables are moved to a new Self which we return
    return self;
}

// TODO: remove create/destroy that are thin wrappers (make data public instead)
/// caller must destroy returned module
pub fn createShaderModule(self: Self, spir_v: []const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .p_code = @ptrCast([*]const u32, @alignCast(4, spir_v.ptr)),
        .code_size = spir_v.len,
    };
    return self.vkd.createShaderModule(self.device, &create_info, null);
}

pub fn destroyShaderModule(self: Self, module: vk.ShaderModule) void {
    self.vkd.destroyShaderModule(self.device, module, null);
}

/// caller must destroy returned module 
pub fn createPipelineLayout(self: Self, create_info: vk.PipelineLayoutCreateInfo) !vk.PipelineLayout {
    return self.vkd.createPipelineLayout(self.device, &create_info, null);
}

pub fn destroyPipelineLayout(self: Self, pipeline_layout: vk.PipelineLayout) void {
    self.vkd.destroyPipelineLayout(self.device, pipeline_layout, null);
}

/// caller must destroy pipeline from vulkan
pub inline fn createGraphicsPipeline(self: Self, create_info: vk.GraphicsPipelineCreateInfo) !vk.Pipeline {
    const create_infos = [_]vk.GraphicsPipelineCreateInfo{
        create_info,
    };
    var pipeline: vk.Pipeline = undefined;
    const result = try self.vkd.createGraphicsPipelines(self.device, .null_handle, create_infos.len, @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &create_infos), null, @ptrCast([*]vk.Pipeline, &pipeline));
    if (result != vk.Result.success) {
        // TODO: not panic?
        std.debug.panic("failed to initialize pipeline!", .{});
    }
    return pipeline;
}

/// caller must both destroy pipeline from the heap and in vulkan
pub fn createComputePipeline(self: Self, allocator: Allocator, create_info: vk.ComputePipelineCreateInfo) !*vk.Pipeline {
    var pipeline = try allocator.create(vk.Pipeline);
    errdefer allocator.destroy(pipeline);

    const create_infos = [_]vk.ComputePipelineCreateInfo{
        create_info,
    };
    const result = try self.vkd.createComputePipelines(self.device, .null_handle, create_infos.len, @ptrCast([*]const vk.ComputePipelineCreateInfo, &create_infos), null, @ptrCast([*]vk.Pipeline, pipeline));
    if (result != vk.Result.success) {
        // TODO: not panic?
        std.debug.panic("failed to initialize pipeline!", .{});
    }

    return pipeline;
}

/// destroy pipeline from vulkan *not* from the application memory
pub fn destroyPipeline(self: Self, pipeline: *vk.Pipeline) void {
    self.vkd.destroyPipeline(self.device, pipeline.*, null);
}

/// caller must destroy returned render pass
pub fn createRenderPass(self: Self, format: vk.Format) !vk.RenderPass {
    const color_attachment = [_]vk.AttachmentDescription{
        .{
            .flags = .{},
            .format = format,
            .samples = .{
                .@"1_bit" = true,
            },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .@"undefined",
            .final_layout = .present_src_khr,
        },
    };
    const color_attachment_refs = [_]vk.AttachmentReference{
        .{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        },
    };
    const subpass = [_]vk.SubpassDescription{
        .{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .input_attachment_count = 0,
            .p_input_attachments = undefined,
            .color_attachment_count = color_attachment_refs.len,
            .p_color_attachments = &color_attachment_refs,
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = null,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = undefined,
        },
    };
    const subpass_dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{
            .color_attachment_output_bit = true,
        },
        .dst_stage_mask = .{
            .color_attachment_output_bit = true,
        },
        .src_access_mask = .{},
        .dst_access_mask = .{
            .color_attachment_write_bit = true,
        },
        .dependency_flags = .{},
    };
    const render_pass_info = vk.RenderPassCreateInfo{
        .flags = .{},
        .attachment_count = color_attachment.len,
        .p_attachments = &color_attachment,
        .subpass_count = subpass.len,
        .p_subpasses = &subpass,
        .dependency_count = 1,
        .p_dependencies = @ptrCast([*]const vk.SubpassDependency, &subpass_dependency),
    };
    return try self.vkd.createRenderPass(self.device, &render_pass_info, null);
}

pub fn destroyRenderPass(self: Self, render_pass: vk.RenderPass) void {
    self.vkd.destroyRenderPass(self.device, render_pass, null);
}

pub fn deinit(self: Self) void {
    self.vkd.destroyCommandPool(self.device, self.gfx_cmd_pool, null);
    self.vkd.destroyCommandPool(self.device, self.comp_cmd_pool, null);
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
    .createImage = true,
    .createBuffer = true,
    .destroyImage = true,
    .destroyBuffer = true,
    .cmdCopyBuffer = true,
    .bindImageMemory = true,
    .bindBufferMemory = true,
    .getImageMemoryRequirements2 = true,
    .getBufferMemoryRequirements2 = true,
    .mapMemory = true,
    .freeMemory = true,
    .unmapMemory = true,
    .allocateMemory = true,
    .flushMappedMemoryRanges = true,

    //debug
    .cmdBeginDebugUtilsLabelEXT = enable_safety,
    .cmdEndDebugUtilsLabelEXT = enable_safety,
    .cmdInsertDebugUtilsLabelEXT = enable_safety,
    .setDebugUtilsObjectNameEXT = enable_safety,

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
    .createDescriptorSetLayout = true,
    .destroyDescriptorSetLayout = true,
    .createSampler = true,
    .destroySampler = true,
    .createDescriptorPool = true,
    .destroyDescriptorPool = true,
    .allocateDescriptorSets = true,
    .updateDescriptorSets = true,
    .beginCommandBuffer = true,
    .resetCommandPool = true,
    .endCommandBuffer = true,
    .cmdDraw = true,
    .cmdBlitImage = true,
    .cmdSetScissor = true,
    .cmdSetViewport = true,
    .cmdDrawIndexed = true,
    .cmdBindPipeline = true,
    .cmdPushConstants = true,
    .cmdEndRenderPass = true,
    .cmdBeginRenderPass = true,
    .queueSubmit2 = true,
    // .queueSubmit = true,
    // .cmdSetEvent2 = true,
    // .cmdResetEvent2 = true,
    // .cmdWaitEvents2 = true,
    .cmdBindIndexBuffer = true,
    .cmdCopyBufferToImage = true,
    .cmdBindVertexBuffers = true,
    .cmdBindDescriptorSets = true,
    .cmdPipelineBarrier2 = true,
    .cmdPushDescriptorSetKHR = true,
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
