const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const Context = @import("engine");
const Swapchain = Context.Swapchain;
const Camera = @import("utils").Camera;
const Buffer = Context.Buffer;
const zalgebra = @import("zalgebra");

const Self = @This();

pub const Vec3 = zalgebra.Vec3;
pub const Vertex = struct {
    pos: [3]f32,
    color: [3]f32,

    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };
};

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
renderpass: vk.RenderPass,
framebuffers: []vk.Framebuffer,
descriptor_pool: vk.DescriptorPool,
descriptor_sets: []vk.DescriptorSet,
descriptor_layout: vk.DescriptorSetLayout,
camera_buffers: []Buffer,
allocator: Allocator,

pub fn init(ctx: Context, allocator: Allocator, swapchain: Swapchain) !Self {
    var camera = Camera.new(1400, 900, 400);

    var camera_buffers = brk: {
        var buffers = try allocator.alloc(Buffer, swapchain.images.len);
        for (buffers) |*buffer| {
            buffer.* = try Buffer.init(ctx, Buffer.CreateInfo{
                .size = @sizeOf(Camera),
                .buffer_usage = .{ .uniform_buffer_bit = true },
                .memory_usage = .cpu_to_gpu,
                .memory_flags = .{},
            });

            try buffer.upload(Camera, ctx, &[_]Camera{camera});
        }
        break :brk buffers;
    };

    const dslb = [1]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true },
            .p_immutable_samplers = null,
        },
    };

    var descriptor_layout = try ctx.vkd.createDescriptorSetLayout(ctx.device, &.{
        .binding_count = @truncate(u32, dslb.len),
        .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &dslb),
        .flags = .{},
    }, null);

    const image_count = @intCast(u32, swapchain.images.len);

    var descriptor_pool = brk: {
        var pool_size = [1]vk.DescriptorPoolSize{.{
            .@"type" = .uniform_buffer,
            .descriptor_count = image_count,
        }};
        break :brk try ctx.vkd.createDescriptorPool(ctx.device, &vk.DescriptorPoolCreateInfo{
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &pool_size),
            .max_sets = image_count,
            .flags = .{},
        }, null);
    };

    var descriptor_sets = brk: {
        var layouts = try allocator.alloc(vk.DescriptorSetLayout, image_count);
        var sets = try allocator.alloc(vk.DescriptorSet, image_count);
        defer allocator.free(layouts);

        for (layouts) |*l| {
            l.* = descriptor_layout;
        }

        const dsai = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = image_count,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, layouts),
        };

        try ctx.vkd.allocateDescriptorSets(ctx.device, &dsai, sets.ptr);

        for (sets) |_, i| {
            const dbi = vk.DescriptorBufferInfo{
                .buffer = camera_buffers[i].buffer,
                .offset = 0,
                .range = @sizeOf(Camera),
            };
            const wds = [1]vk.WriteDescriptorSet{
                .{
                    .dst_set = sets[i],
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .uniform_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &dbi),
                    .p_texel_buffer_view = undefined,
                },
            };

            ctx.vkd.updateDescriptorSets(
                ctx.device,
                @truncate(u32, wds.len),
                @ptrCast([*]const vk.WriteDescriptorSet, &wds),
                0,
                undefined,
            );
        }

        break :brk sets;
    };

    const renderpass = brk: {
        const color_attachment = vk.AttachmentDescription{
            .flags = .{},
            .format = swapchain.format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .@"undefined",
            .final_layout = .present_src_khr,
        };

        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };

        const subpass = vk.SubpassDescription{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .input_attachment_count = 0,
            .p_input_attachments = undefined,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast([*]const vk.AttachmentReference, &color_attachment_ref),
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = null,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = undefined,
        };

        break :brk try ctx.vkd.createRenderPass(ctx.device, &.{
            .flags = .{},
            .attachment_count = 1,
            .p_attachments = @ptrCast([*]const vk.AttachmentDescription, &color_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast([*]const vk.SubpassDescription, &subpass),
            .dependency_count = 0,
            .p_dependencies = undefined,
        }, null);
    };

    const framebuffers = brk: {
        var framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.images.len);
        errdefer allocator.free(framebuffers);

        for (swapchain.images) |image, i| {
            var attachments = [_]vk.ImageView{image.view};
            const framebuffer_info = vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = renderpass,
                .attachment_count = attachments.len,
                .p_attachments = @ptrCast([*]const vk.ImageView, &attachments),
                .width = swapchain.extent.width,
                .height = swapchain.extent.height,
                .layers = 1,
            };
            framebuffers[i] = try ctx.vkd.createFramebuffer(ctx.device, &framebuffer_info, null);
            errdefer ctx.vkd.destroyFramebuffer(ctx.device, framebuffers[i], null);
        }
        break :brk framebuffers;
    };

    const pipeline_layout = try ctx.vkd.createPipelineLayout(ctx.device, &vk.PipelineLayoutCreateInfo{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_layout),
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);

    const vert_code align(4) = @embedFile("./shaders/vert.spv").*;
    const frag_code align(4) = @embedFile("./shaders/frag.spv").*;

    const vertexShader = try ctx.vkd.createShaderModule(ctx.device, &.{
        .flags = .{},
        .code_size = vert_code.len,
        .p_code = std.mem.bytesAsSlice(u32, vert_code[0..]).ptr,
    }, null);

    const fragShader = try ctx.vkd.createShaderModule(ctx.device, &.{
        .flags = .{},
        .code_size = frag_code.len,
        .p_code = std.mem.bytesAsSlice(u32, frag_code[0..]).ptr,
    }, null);

    defer ctx.vkd.destroyShaderModule(ctx.device, vertexShader, null);
    defer ctx.vkd.destroyShaderModule(ctx.device, fragShader, null);

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &[_]vk.PipelineShaderStageCreateInfo{
            .{
                .flags = .{},
                .stage = .{ .vertex_bit = true },
                .module = vertexShader,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{
                .flags = .{},
                .stage = .{ .fragment_bit = true },
                .module = fragShader,
                .p_name = "main",
                .p_specialization_info = null,
            },
        },
        .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &Vertex.binding_description),
            .vertex_attribute_description_count = Vertex.attribute_description.len,
            .p_vertex_attribute_descriptions = &Vertex.attribute_description,
        },
        .p_input_assembly_state = &vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        },
        .p_tessellation_state = null,
        .p_viewport_state = &vk.PipelineViewportStateCreateInfo{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = undefined,
            .scissor_count = 1,
            .p_scissors = undefined,
        },
        .p_rasterization_state = &vk.PipelineRasterizationStateCreateInfo{
            .flags = .{},
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        },
        .p_depth_stencil_state = null,
        .p_color_blend_state = &vk.PipelineColorBlendStateCreateInfo{
            .flags = .{},
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &pcbas),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        },
        .layout = pipeline_layout,
        .render_pass = renderpass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try ctx.vkd.createGraphicsPipelines(
        ctx.device,
        .null_handle,
        1,
        @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &gpci),
        null,
        @ptrCast([*]vk.Pipeline, &pipeline),
    );

    return Self{
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .renderpass = renderpass,
        .framebuffers = framebuffers,
        .descriptor_pool = descriptor_pool,
        .descriptor_sets = descriptor_sets,
        .descriptor_layout = descriptor_layout,
        .camera_buffers = camera_buffers,
        .allocator = allocator,
    };
}

pub fn deinit(self: Self, ctx: Context) void {
    ctx.vkd.deviceWaitIdle(ctx.device) catch {};
    ctx.vkd.destroyRenderPass(ctx.device, self.renderpass, null);
    ctx.vkd.destroyDescriptorPool(ctx.device, self.descriptor_pool, null);

    for (self.camera_buffers) |buffer| buffer.deinit(ctx);
    ctx.vkd.destroyDescriptorSetLayout(ctx.device, self.descriptor_layout, null);
    for (self.framebuffers) |buffer| ctx.vkd.destroyFramebuffer(ctx.device, buffer, null);

    self.allocator.free(self.framebuffers);
    self.allocator.free(self.descriptor_sets);
    self.allocator.free(self.camera_buffers);

    ctx.vkd.destroyPipelineLayout(ctx.device, self.pipeline_layout, null);
    ctx.vkd.destroyPipeline(ctx.device, self.pipeline, null);
}
