const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const Context = @import("context.zig");

pub const CreateInfo = struct {
    size: vk.DeviceSize,
    buffer_usage: vk.BufferUsageFlags,
    memory_usage: vma.MemoryUsage,
    memory_flags: vma.AllocationCreateFlags,
};

buffer: vk.Buffer,
allocation: vma.Allocation,
info: vma.AllocationInfo,
create_info: CreateInfo,

const Self = @This();

pub fn init(context: Context, create_info: CreateInfo) !Self {
    var allocation_info: vma.AllocationInfo = undefined;
    const result = try context.allocator.createBufferAndGetInfo(
        .{
            .flags = .{},
            .size = create_info.size,
            .usage = create_info.buffer_usage,
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        },
        .{
            .flags = create_info.memory_flags,
            .usage = create_info.memory_usage,
        },
        &allocation_info,
    );

    return Self{ .buffer = result.buffer, .allocation = result.allocation, .info = allocation_info, .create_info = create_info };
}

pub fn deinit(self: Self, context: Context) void {
    context.allocator.destroyBuffer(self.buffer, self.allocation);
}

pub fn upload(self: Self, comptime T: type, context: Context, data: []const T) !void {
    switch (self.create_info.memory_usage) {
        .gpu_only => {
            const size = @sizeOf(T) * data.len;
            const stage_buffer = try Self.init(context, .{
                .size = size,
                .buffer_usage = .{ .transfer_src_bit = true },
                .memory_usage = .cpu_to_gpu,
                .memory_flags = .{},
            });
            defer stage_buffer.deinit(context);
            stage_buffer.upload(T, context, data) catch unreachable;
            try stage_buffer.copyToBuffer(self, context);
        },
        .cpu_to_gpu => {
            const gpu_mem = if (self.info.pMappedData) |mem|
                @intToPtr([*]T, @ptrToInt(mem))
            else
                try context.allocator.mapMemory(self.allocation, T);

            for (data) |d, i| {
                gpu_mem[i] = d;
            }

            // Flush allocation
            try context.allocator.flushAllocation(self.allocation, 0, self.info.size);
            if (self.info.pMappedData == null) {
                context.allocator.unmapMemory(self.allocation);
            }
        },
        else => unreachable,
    }
}

pub fn mapMemory(self: Self, context: Context, comptime T: type) ![*]T {
    // make sure it a stage bufffer
    std.debug.assert(self.create_info.memory_usage == .cpu_to_gpu);
    return if (self.info.pMappedData) |mem|
        @intToPtr([*]T, @ptrToInt(mem))
    else
        try context.allocator.mapMemory(self.allocation, T);
}

pub fn flushAllocation(self: Self, context: Context) !void {
    try context.allocator.flushAllocation(self.allocation, 0, self.info.size);
    if (self.info.pMappedData == null) {
        context.allocator.unmapMemory(self.allocation);
    }
}

fn copyToBuffer(src: Self, dst: Self, context: Context) !void {
    // TODO: because smallest buffer size is 256 byte.
    // if data size is < 256, group multiple data to one buffer
    // std.log.info("src: info size: {}, data size: {}", .{src.info.size, src.size});
    // std.log.info("dst: info size: {}, data size: {}", .{dst.info.size, dst.size});
    const cmdbuf = try context.beginOneTimeCommandBuffer();

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = src.create_info.size,
    };
    context.vkd.cmdCopyBuffer(cmdbuf, src.buffer, dst.buffer, 1, @ptrCast([*]const vk.BufferCopy, &region));

    try context.endOneTimeCommandBuffer(cmdbuf);
}
