const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig");

const Self = @This();

layouts: []vk.DescriptorSetLayout,
poolSizes: []vk.DescriptorPoolSize,
sets: []vk.DescriptorSet,
pool: vk.DescriptorPool,
allocator: Allocator,

pub fn new(descriptorInfo: vk.DescriptorSetLayoutCreateInfo, ctx: Context, max_size: usize, allocator: Allocator) !Self {
    var layouts = try allocator.alloc(vk.DescriptorSetLayout, max_size);
    var sets = try allocator.alloc(vk.DescriptorSet, max_size);
    var poolSizes = try allocator.alloc(vk.DescriptorPoolSize, descriptorInfo.binding_count);

    var pool = try ctx.vkd.createDescriptorPool(ctx.device, &vk.DescriptorPoolCreateInfo{
        .pool_size_count = 1,
        .p_pool_sizes = poolSizes.ptr,
        .max_sets = @intCast(u32, max_size),
        .flags = .{},
    }, null);

    errdefer ctx.vkd.destroyDescriptorPool(ctx.device, pool, null);

    for (poolSizes) |*poolSize, i| {
        poolSize.* = vk.DescriptorPoolSize{
            .type = descriptorInfo.p_bindings[i].descriptor_type,
            .descriptor_count = @intCast(u32, max_size),
        };
    }

    for (layouts) |_, index| {
        layouts[index] = try ctx.vkd.createDescriptorSetLayout(ctx.device, &descriptorInfo, null);
        errdefer ctx.vkd.destroyDescriptorSetLayout(ctx.device, layouts[index], null);
    }

    try ctx.vkd.allocateDescriptorSets(ctx.device, &vk.DescriptorSetAllocateInfo{
        .descriptor_pool = pool,
        .descriptor_set_count = @intCast(u32, max_size),
        .p_set_layouts = layouts.ptr,
    }, sets.ptr);

    return Self{
        .allocator = allocator,
        .poolSizes = poolSizes,
        .pool = pool,
        .layouts = layouts,
        .sets = sets,
    };
}

pub fn deinit(self: Self, ctx: Context) void {
    for (self.layouts) |layout| {
        ctx.vkd.destroyDescriptorSetLayout(ctx.device, layout, null);
    }

    ctx.vkd.destroyDescriptorPool(ctx.device, self.pool, null);

    self.allocator.free(self.poolSizes);
    self.allocator.free(self.layouts);
    self.allocator.free(self.sets);
}
