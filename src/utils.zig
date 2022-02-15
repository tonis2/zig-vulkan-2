const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig");

pub fn isInstanceExtensionsPresent(allocator: Allocator, vkb: Context.Base, target_extensions: []const [*:0]const u8) !bool {
    // query extensions available
    var supported_extensions_count: u32 = 0;
    // TODO: handle "VkResult.incomplete"
    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, null);

    var extensions = try std.ArrayList(vk.ExtensionProperties).initCapacity(allocator, supported_extensions_count);
    defer extensions.deinit();

    _ = try vkb.enumerateInstanceExtensionProperties(null, &supported_extensions_count, extensions.items.ptr);
    extensions.items.len = supported_extensions_count;

    var matches: u32 = 0;
    for (target_extensions) |target_extension| {
        cmp: for (extensions.items) |existing| {
            const existing_name = @ptrCast([*:0]const u8, &existing.extension_name);
            if (std.cstr.cmp(target_extension, existing_name) == 0) {
                matches += 1;
                break :cmp;
            }
        }
    }

    return matches == target_extensions.len;
}
