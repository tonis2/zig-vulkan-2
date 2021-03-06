const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const Context = @import("context.zig");
const Buffer = @import("buffer.zig");

const Image = @This();

image: vk.Image,
allocation: vma.Allocation,
layout: vk.ImageLayout,
format: vk.Format,
width: u32,
height: u32,

pub const AccessMask = struct {
    src: vk.AccessFlags2,
    dst: vk.AccessFlags2,
};

pub const CreateInfo = struct {
    flags: vk.ImageCreateFlags,
    image_type: vk.ImageType,
    format: vk.Format,
    extent: vk.Extent3D,
    mip_levels: u32,
    array_layers: u32,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    memory_usage: vma.MemoryUsage,
    memory_flags: vma.AllocationCreateFlags,
};

pub fn init(ctx: Context, create_info: CreateInfo) !Image {
    const result = try ctx.allocator.createImage(
        .{
            .flags = create_info.flags,
            .image_type = create_info.image_type,
            .format = create_info.format,
            .extent = create_info.extent,
            .mip_levels = create_info.mip_levels,
            .array_layers = create_info.array_layers,
            .samples = create_info.samples,
            .tiling = create_info.tiling,
            .usage = create_info.usage,
            .initial_layout = .@"undefined",
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        },
        .{
            .flags = create_info.memory_flags,
            .usage = create_info.memory_usage,
        },
    );

    // zig fmt: off
    return .{
        .image = result.image,
        .allocation = result.allocation,
        .layout = .@"undefined",
        .format = create_info.format,
        .width = create_info.extent.width,
        .height = create_info.extent.height
    };
    // zig fmt: on
}

pub fn deinit(self: Image, ctx: Context) void {
    ctx.allocator.destroyImage(self.image, self.allocation);
}

pub fn changeLayout(
    self: *Image,
    ctx: Context,
    cmdbuf: vk.CommandBuffer,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    access_mask: AccessMask,
    src_stage_mask: vk.PipelineStageFlags2,
    dst_stage_mask: vk.PipelineStageFlags2,
    subresource_range: vk.ImageSubresourceRange,
) void {
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = src_stage_mask,
        .src_access_mask = access_mask.src,
        .dst_stage_mask = dst_stage_mask,
        .dst_access_mask = access_mask.dst,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = subresource_range,
    };
    const di = vk.DependencyInfo{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = undefined,
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = undefined,
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast([*]const vk.ImageMemoryBarrier2, &barrier),
    };
    ctx.vkd.cmdPipelineBarrier2(cmdbuf, &di);
    self.layout = new_layout;
}

pub fn accessMaskFrom(old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) AccessMask {
    var src: vk.AccessFlags2 = switch (old_layout) {
        // Image layout is undefined (or does not matter)
        // Only valid as initial layout
        // No flags required, listed only for completeness
        .@"undefined" => .{},

        // Image is preinitialized
        // Only valid as initial layout for linear images, preserves memory contents
        // Make sure host writes have been finished
        .preinitialized => .{ .host_write_bit = true },

        // Image is a color attachment
        // Make sure any writes to the color buffer have been finished
        .color_attachment_optimal => .{ .color_attachment_write_bit = true },

        // Image is a depth/stencil attachment
        // Make sure any writes to the depth/stencil buffer have been finished
        .depth_attachment_optimal => .{ .depth_stencil_attachment_write_bit = true },

        // Image is a transfer source
        // Make sure any reads from the image have been finished
        .transfer_src_optimal => .{ .transfer_read_bit = true },

        // Image is a transfer destination
        // Make sure any writes to the image have been finished
        .transfer_dst_optimal => .{ .transfer_write_bit = true },

        // Image is read by a shader
        // Make sure any shader reads from the image have been finished
        .shader_read_only_optimal => .{ .shader_read_bit = true },

        // Other source layouts aren't handled (yet)
        else => unreachable,
    };

    // Target layouts (new)
    // Destination access mask controls the dependency for the new image layout
    const dst: vk.AccessFlags2 = switch (new_layout) {
        // case VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
        // Image will be used as a transfer destination
        // Make sure any writes to the image have been finished
        vk.ImageLayout.transfer_dst_optimal => .{ .transfer_write_bit = true },

        // Image will be used as a transfer source
        // Make sure any reads from the image have been finished
        vk.ImageLayout.transfer_src_optimal => .{ .transfer_read_bit = true },

        // Image will be used as a color attachment
        // Make sure any writes to the color buffer have been finished
        vk.ImageLayout.color_attachment_optimal => .{ .color_attachment_write_bit = true },

        // Image layout will be used as a depth/stencil attachment
        // Make sure any writes to depth/stencil buffer have been finished
        // imageMemoryBarrier.dstAccessMask | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        vk.ImageLayout.depth_attachment_optimal => .{ .depth_stencil_attachment_write_bit = true },

        // Image will be read in a shader (sampler, input attachment)
        // Make sure any writes to the image have been finished
        vk.ImageLayout.shader_read_only_optimal => blk: {
            if (src.toInt() == 0) {
                src = src.merge(.{ .host_write_bit = true, .transfer_write_bit = true });
            }
            break :blk .{ .shader_read_bit = true };
        },

        // Other source layouts aren't handled (yet)
        else => unreachable,
    };
    return .{
        .src = src,
        .dst = dst,
    };
}

pub fn generateMipMap(
    self: *Image,
    ctx: Context,
    cmdbuf: vk.CommandBuffer,
    subresource_range: vk.ImageSubresourceRange,
) void {
    // std.debug.assert(self.layout == .transfer_dst_optimal);
    var sr = subresource_range;
    sr.level_count = 1;
    sr.base_mip_level = 0;

    // Transition first mip level to transfer source for read during blit
    self.changeLayout(
        ctx,
        cmdbuf,
        .transfer_dst_optimal,
        .transfer_src_optimal,
        accessMaskFrom(.transfer_dst_optimal, .transfer_src_optimal),
        .{ .all_transfer_bit = true },
        .{ .all_transfer_bit = true },
        sr,
    );

    // generate mip level
    var i: u5 = 1;
    while (i < subresource_range.level_count) : (i += 1) {
        const ib = vk.ImageBlit{
            .src_subresource = .{
                .aspect_mask = sr.aspect_mask,
                .mip_level = i - 1,
                .base_array_layer = sr.base_array_layer,
                .layer_count = 1,
            },
            .src_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{
                    .x = @intCast(i32, self.width >> (i - 1)),
                    .y = @intCast(i32, self.height >> (i - 1)),
                    .z = 1,
                },
            },
            .dst_subresource = .{
                .aspect_mask = sr.aspect_mask,
                .mip_level = i,
                .base_array_layer = sr.base_array_layer,
                .layer_count = 1,
            },
            .dst_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{
                    .x = @intCast(i32, self.width >> i),
                    .y = @intCast(i32, self.height >> i),
                    .z = 1,
                },
            },
        };
        // Prepare current mip level as image blit destination
        sr.base_mip_level = i;
        self.changeLayout(
            ctx,
            cmdbuf,
            .@"undefined",
            .transfer_dst_optimal,
            comptime accessMaskFrom(.@"undefined", .transfer_dst_optimal),
            .{ .all_transfer_bit = true },
            .{ .all_transfer_bit = true },
            sr,
        );
        // Blit from previous level
        ctx.vkd.cmdBlitImage(
            cmdbuf,
            self.image,
            .transfer_src_optimal,
            self.image,
            .transfer_dst_optimal,
            1,
            @ptrCast([*]const vk.ImageBlit, &ib),
            .linear,
        );
        // Prepare current mip level as image blit source for next level
        self.changeLayout(
            ctx,
            cmdbuf,
            .transfer_dst_optimal,
            .transfer_src_optimal,
            comptime accessMaskFrom(.transfer_dst_optimal, .transfer_src_optimal),
            .{ .all_transfer_bit = true },
            .{ .all_transfer_bit = true },
            sr,
        );
    }
    // After the loop, all mip layers are in TRANSFER_SRC layout, so transition all to SHADER_READ
    self.changeLayout(
        ctx,
        cmdbuf,
        .transfer_src_optimal,
        .shader_read_only_optimal,
        comptime accessMaskFrom(.transfer_src_optimal, .shader_read_only_optimal),
        .{ .all_transfer_bit = true },
        .{ .fragment_shader_bit = true },
        subresource_range,
    );
}
