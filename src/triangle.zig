const std = @import("std");
const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");
const build_options = @import("build_options");
const validation_layers = @import("validation_layers.zig").validation_layers;

fn createDebugUtilsMessengerEXT(
    instance: vk.VkInstance,
    create_info: *const vk.VkDebugUtilsMessengerCreateInfoEXT,
    allocator: ?*const vk.VkAllocationCallbacks,
    debug_messenger: *vk.VkDebugUtilsMessengerEXT,
) vk.VkResult {
    const func: vk.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(vk.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    if (func) |f| {
        f(instance, create_info, allocator, debug_messenger);
    } else return vk.VK_ERROR_EXTENSION_NOT_PRESENT;
}

fn destroyDebugUtilsMessengerEXT(
    instance: vk.VkInstance,
    debug_messenger: vk.VkDebugUtilsMessengerEXT,
    allocator: ?*const vk.VkAllocationCallbacks,
) void {
    const func: vk.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(vk.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT"));
    if (func) |f| f(instance, debug_messenger, allocator);
}

pub const TriangleApp = struct {
    width: u32,
    height: u32,
    title: []const u8,
    window: *glfw.GLFWwindow,
    allocator: std.mem.Allocator,
    instance: vk.VkInstance = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const width = 800;
        const height = 600;
        const title = "Vulkan Triangle";
        return .{
            .width = width,
            .height = height,
            .title = title,
            .window = initWindow(@intCast(width), @intCast(height), title),
            .allocator = allocator,
        };
    }

    pub fn run(self: *Self) void {
        self.initVulkan();
        self.mainLoop();
    }

    pub fn deinit(self: *Self) void {
        if (build_options.debug) destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        vk.vkDestroyInstance(self.instance, null);
        glfw.glfwDestroyWindow(self.window);
        glfw.glfwTerminate();
    }

    fn initWindow(width: c_int, height: c_int, title: [*:0]const u8) *glfw.GLFWwindow {
        _ = glfw.glfwInit();
        glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE);
        return glfw.glfwCreateWindow(width, height, title, null, null).?;
    }

    fn initVulkan(self: *Self) void {
        self.createInstance();
    }

    fn createInstance(self: *Self) void {
        if (build_options.debug and !self.checkValidationLayerSupport())
            @panic("Validation layer support not available");

        var app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = self.title.ptr,
            .applicationVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = vk.VK_API_VERSION_1_0,
        };

        var extensions = getAllRequiredExtensions(self.allocator) catch @panic("Could not get extensions due to OOM");
        defer extensions.deinit(self.allocator);

        var create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = @intCast(extensions.items.len),
            .ppEnabledExtensionNames = &extensions.items[0],
            .enabledLayerCount = 0,
            .flags = vk.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
        };

        var debug_create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{};
        if (build_options.debug) {
            create_info.enabledLayerCount = @intCast(validation_layers.len);
            create_info.ppEnabledLayerNames = &validation_layers[0];

            populateDebugMessengerCreateInfo(&debug_create_info);
            create_info.pNext = &debug_create_info;
        }

        const result = vk.vkCreateInstance(&create_info, null, &self.instance);
        if (result != vk.VK_SUCCESS) std.debug.panic("Failed to create VkInstance {}", .{result});
    }

    fn getAllRequiredExtensions(allocator: std.mem.Allocator) error{OutOfMemory}!std.ArrayList([*c]const u8) {
        var glfw_extension_count: u32 = 0;
        const glfw_extensions = glfw.glfwGetRequiredInstanceExtensions(&glfw_extension_count);
        var extensions = try std.ArrayList([*c]const u8).initCapacity(allocator, glfw_extension_count);
        for (0..glfw_extension_count) |i|
            try extensions.append(allocator, glfw_extensions[i]);
        try extensions.append(allocator, vk.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);

        if (build_options.debug)
            try extensions.append(allocator, vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);

        return extensions;
    }

    fn setupDebugMessenger(self: *Self) void {
        const debug_messenger_create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{};
        populateDebugMessengerCreateInfo(&debug_messenger_create_info);

        const result = createDebugUtilsMessengerEXT(
            self.instance,
            &debug_messenger_create_info,
            null,
            &self.debug_messenger,
        );
        if (result != vk.VK_SUCCESS)
            std.debug.panic("Could not create debug messenger {}", .{result});
    }

    fn populateDebugMessengerCreateInfo(create_info: *vk.VkDebugUtilsMessengerCreateInfoEXT) void {
        create_info.* = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = debugCallback,
            .pUserData = null,
        };
    }

    fn debugCallback(
        severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
        message_type: vk.VkDebugUtilsMessageTypeFlagsEXT,
        callback_data: [*c]const vk.VkDebugUtilsMessengerCallbackDataEXT,
        user_data: ?*anyopaque,
    ) callconv(.c) vk.VkBool32 {
        _ = message_type;
        _ = user_data;

        if (severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT)
            std.debug.print("Debug call {s}\n", .{callback_data.*.pMessage});

        return vk.VK_FALSE;
    }

    fn checkValidationLayerSupport(self: *Self) bool {
        var layer_count: u32 = 0;
        _ = vk.vkEnumerateInstanceLayerProperties(&layer_count, null);

        var available_layers = std.ArrayList(vk.VkLayerProperties).initCapacity(
            self.allocator,
            layer_count,
        ) catch @panic("OOM");
        defer available_layers.deinit(self.allocator);
        available_layers.resize(self.allocator, layer_count) catch @panic("OOM");

        _ = vk.vkEnumerateInstanceLayerProperties(&layer_count, available_layers.items.ptr);

        for (validation_layers) |layer_name| {
            var layer_found = true;

            for (available_layers.items) |layer_properties| {
                var name_len: usize = 0;
                while (layer_properties.layerName[name_len] != 0) name_len += 1;
                const layer_properties_name = layer_properties.layerName[0..name_len];

                if (std.mem.eql(u8, std.mem.span(layer_name), layer_properties_name)) {
                    layer_found = true;
                    break;
                }
            }

            if (!layer_found) return false;
        }

        return true;
    }

    fn mainLoop(self: *Self) void {
        while (glfw.glfwWindowShouldClose(self.window) != 1) {
            glfw.glfwPollEvents();
        }
    }
};
