const vk = @import("headers/vulkan.zig");

pub const validation_layers = [_][*c]const u8{
    "VK_LAYER_KHRONOS_validation",
};

pub const device_extensions = [_][*c]const u8{
    vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    "VK_KHR_portability_subset",
};
