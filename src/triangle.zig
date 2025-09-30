const std = @import("std");
const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");
const build_options = @import("build_options");
const validation_layers = @import("validation_layers.zig").validation_layers;

pub const TriangleApp = struct {
    width: u32,
    height: u32,
    title: []const u8,
    window: *glfw.GLFWwindow,
    instance: vk.VkInstance = null,
    allocator: std.mem.Allocator,

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
            .apiVersion = vk.VK_VERSION_1_0,
        };

        var extension_count: u32 = 0;
        const extensions = glfw.glfwGetRequiredInstanceExtensions(&extension_count);

        var create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = extension_count,
            .ppEnabledExtensionNames = extensions,
            .enabledLayerCount = 0,
        };

        if (build_options.debug) {
            create_info.enabledLayerCount = @intCast(validation_layers.len);
            create_info.ppEnabledLayerNames = validation_layers[0..].ptr;
        }

        const result = vk.vkCreateInstance(&create_info, null, &self.instance);
        if (result != vk.VK_SUCCESS) std.debug.panic("Failed to create VkInstance {}", .{result});
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
