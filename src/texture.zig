const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const Context = @import("context.zig");
const Buffer = @import("buffer.zig");
const Image = @import("image.zig");

pub const TextureType = enum {
    /// photos/albedo textures
    srgb,

    /// for normal, metallic, ao roughness
    unorm,

    /// cube_map always in srgb space
    cube_map,
};

pub const Config = struct {
    /// true mean enable anisotropy
    anisotropy: bool = true,
    layers: u16 = 1,
    /// true mean enable mip map
    mip_map: bool = true,
};

pub const Texture = struct {
    image: Image,
    config: Config,
    view: vk.ImageView,

    pub fn loadFromMemory(
        ctx: Context,
        @"type": TextureType,
        buffer: []const u8,
        width: u32,
        height: u32,
        channels: u32,
        config: Config,
    ) !Texture {
        const stage_buffer = try Buffer.init(ctx, .{
            .size = buffer.len,
            .buffer_usage = .{ .transfer_src_bit = true },
            .memory_usage = .cpu_to_gpu,
            .memory_flags = .{},
        });
        defer stage_buffer.deinit(ctx);
        try stage_buffer.upload(u8, ctx, buffer);

        const mip_levels = if (config.mip_map) calcMipLevel(width, height) else 1;

        var image = try Image.init(ctx, .{
            .flags = if (@"type" == .cube_map) .{ .cube_compatible_bit = true } else .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_srgb,
            .extent = .{
                .width = width,
                .height = height,
                .depth = 1,
            },
            .mip_levels = mip_levels,
            .array_layers = config.layers,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            .memory_usage = .gpu_only,
            .memory_flags = .{},
        });

        var subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            // Only copy to the first mip map level,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = config.layers,
        };

        const cmdbuf = try ctx.beginOneTimeCommandBuffer();

        image.changeLayout(
            ctx,
            cmdbuf,
            .@"undefined",
            .transfer_dst_optimal,
            Image.accessMaskFrom(.@"undefined", .transfer_dst_optimal),
            if (config.mip_map) .{ .all_transfer_bit = true } else .{},
            .{ .all_transfer_bit = true },
            subresource_range,
        );

        const bic = blk: {
            if (@"type" == .cube_map) {
                var temp: [6]vk.BufferImageCopy = undefined;
                const base_offset = channels * width;
                for (temp) |*t, index| {
                    const i = @truncate(u32, index);
                    t.* = vk.BufferImageCopy{
                        .buffer_offset = base_offset * i,
                        .buffer_row_length = width,
                        .buffer_image_height = height,
                        .image_subresource = .{
                            .aspect_mask = .{ .color_bit = true },
                            .mip_level = 0,
                            .base_array_layer = i,
                            .layer_count = 1,
                        },
                        .image_offset = .{
                            .x = 0,
                            .y = 0,
                            .z = 0,
                        },
                        .image_extent = .{
                            .width = width,
                            .height = height,
                            .depth = 1,
                        },
                    };
                }
                break :blk temp;
            }
            break :blk [_]vk.BufferImageCopy{.{
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .image_offset = .{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                .image_extent = .{
                    .width = width,
                    .height = height,
                    .depth = 1,
                },
            }};
        };

        ctx.vkd.cmdCopyBufferToImage(
            cmdbuf,
            stage_buffer.buffer,
            image.image,
            .transfer_dst_optimal,
            bic.len,
            &bic,
        );

        if (mip_levels > 1) {
            // pass total mip level to generate
            subresource_range.level_count = mip_levels;
            subresource_range.layer_count = 1;
            if (@"type" == .cube_map) {
                var i: u32 = 0;
                while (i < 6) : (i += 1) {
                    subresource_range.base_array_layer = i;
                    image.generateMipMap(ctx, cmdbuf, subresource_range);
                }
            } else {
                image.generateMipMap(ctx, cmdbuf, subresource_range);
            }
        } else {
            image.changeLayout(
                ctx,
                cmdbuf,
                .transfer_dst_optimal,
                .shader_read_only_optimal,
                Image.accessMaskFrom(.transfer_dst_optimal, .shader_read_only_optimal),
                .{ .all_transfer_bit = true },
                .{ .fragment_shader_bit = true },
                subresource_range,
            );
        }
        try ctx.endOneTimeCommandBuffer(cmdbuf);

        // zig fmt: off
        const imageViewInfo = vk.ImageViewCreateInfo{
            .flags = .{}, .image = image.image, 
            .view_type = if (@"type" == .cube_map) .cube else .@"2d", 
            .format = image.format, 
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity }, 
            .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = mip_levels,
            .base_array_layer = 0,
            .layer_count = config.layers,
        }};
       
        return Texture{ .image = image, .view = try ctx.vkd.createImageView(imageViewInfo) };
    }

    pub fn createDepthStencilTexture(ctx: Context, width: u32, height: u32) !Texture {
        var image = try Image.init(ctx, .{
            .flags = .{},
            .image_type = .@"2d",
            .format = .d32_sfloat_s8_uint,
            .extent = .{
                .width = width,
                .height = height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"4_bit" = true },
            .tiling = .optimal,
            .usage = .{
                .depth_stencil_attachment_bit = true,
            },
            .memory_usage = .gpu_only,
            .memory_flags = .{},
        });

        const subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .depth_bit = true, .stencil_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const cmdbuf = try ctx.beginOneTimeCommandBuffer();
        image.changeLayout(
            ctx,
            cmdbuf,
            .@"undefined",
            .depth_attachment_optimal,
             Image.accessMaskFrom(.@"undefined", .depth_attachment_optimal),
            .{},
            .{ .early_fragment_tests_bit = true },
            subresource_range,
        );
        try ctx.endOneTimeCommandBuffer(cmdbuf);


        const imageView = try ctx.vkd.createImageView(vk.ImageViewCreateInfo{
            .flags = .{},
            .image = image.image,
            .view_type = .@"2d",
            .format = image.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = subresource_range,
        });

        return Texture {
            .image = image,
            .view = imageView,
        };
    }
};

fn calcMipLevel(width: u32, height: u32) u32 {
    const log2 = std.math.log2(std.math.max(width, height));
    return @floatToInt(u32, std.math.floor(@intToFloat(f32, log2))) + 1;
}
