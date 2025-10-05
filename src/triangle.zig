const std = @import("std");
const glfw = @import("headers/glfw.zig");
const vk = @import("headers/vulkan.zig");
const build_options = @import("build_options");
const validation_layers = @import("validation_layers.zig").validation_layers;
const device_extensions = @import("validation_layers.zig").device_extensions;

fn createDebugUtilsMessengerEXT(
    instance: vk.VkInstance,
    create_info: *const vk.VkDebugUtilsMessengerCreateInfoEXT,
    allocator: ?*const vk.VkAllocationCallbacks,
    debug_messenger: *vk.VkDebugUtilsMessengerEXT,
) vk.VkResult {
    const func: vk.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(vk.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    if (func) |f| {
        _ = f(instance, create_info, allocator, debug_messenger);
    } else return vk.VK_ERROR_EXTENSION_NOT_PRESENT;

    return vk.VK_SUCCESS;
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
    surface: vk.VkSurfaceKHR = null,
    swap_chain: vk.VkSwapchainKHR = null,
    swap_chain_image_format: vk.VkFormat = 0,
    swap_chain_extent: vk.VkExtent2D = .{},
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    graphics_queue: vk.VkQueue = null,
    present_queue: vk.VkQueue = null,
    render_pass: vk.VkRenderPass = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    pipeline: vk.VkPipeline = null,
    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,
    image_available_semaphore: vk.VkSemaphore = null,
    image_finished_semaphore: vk.VkSemaphore = null,
    in_flight_fence: vk.VkFence = null,

    swap_chain_images: std.array_list.Aligned(vk.VkImage, null),
    swap_chain_image_views: std.array_list.Aligned(vk.VkImageView, null),
    framebuffers: std.array_list.Aligned(vk.VkFramebuffer, null),

    const Self = @This();

    const QueueFamilyIndices = struct {
        graphics_family: ?u32 = null,
        present_family: ?u32 = null,

        pub fn isComplete(self: *const QueueFamilyIndices) bool {
            return self.graphics_family != null and self.present_family != null;
        }
    };

    const SwapChainSupportDetails = struct {
        capabilities: vk.VkSurfaceCapabilitiesKHR = .{},
        formats: ?std.array_list.Aligned(vk.VkSurfaceFormatKHR, null) = null,
        present_modes: ?std.array_list.Aligned(vk.VkPresentModeKHR, null) = null,
    };

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
            .swap_chain_images = std.ArrayList(vk.VkImage).initCapacity(allocator, 0) catch unreachable,
            .swap_chain_image_views = std.ArrayList(vk.VkImageView).initCapacity(allocator, 0) catch unreachable,
            .framebuffers = std.ArrayList(vk.VkFramebuffer).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn run(self: *Self) void {
        self.initVulkan();
        self.mainLoop();
    }

    pub fn deinit(self: *Self) void {
        vk.vkDestroySemaphore(self.device, self.image_available_semaphore, null);
        vk.vkDestroySemaphore(self.device, self.image_finished_semaphore, null);
        vk.vkDestroyFence(self.device, self.in_flight_fence, null);

        for (self.swap_chain_image_views.items) |image_view|
            vk.vkDestroyImageView(self.device, image_view, null);
        for (self.framebuffers.items) |framebuffer|
            vk.vkDestroyFramebuffer(self.device, framebuffer, null);

        self.swap_chain_images.deinit(self.allocator);
        self.swap_chain_image_views.deinit(self.allocator);
        self.framebuffers.deinit(self.allocator);

        if (build_options.debug) destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        vk.vkDestroyCommandPool(self.device, self.command_pool, null);
        vk.vkDestroyPipeline(self.device, self.pipeline, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vk.vkDestroyRenderPass(self.device, self.render_pass, null);
        vk.vkDestroySwapchainKHR(self.device, self.swap_chain, null);
        vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        vk.vkDestroyDevice(self.device, null);
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
        self.setupDebugMessenger();
        self.createSurface();
        self.pickPhysicalDevice();
        self.createLogicalDevice();
        self.createSwapChain();
        self.createImageViews();
        self.createRenderPass();
        self.createGraphicsPipeline();
        self.createFramebuffers();
        self.createCommandPool();
        self.createCommandBuffer();
        self.createSyncObjects();
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

        var extensions = getAllRequiredExtensions(self.allocator) catch @panic("OOM");
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
        if (result != vk.VK_SUCCESS) std.debug.panic("Failed to create VkInstance {}\n", .{result});
    }

    fn getAllRequiredExtensions(allocator: std.mem.Allocator) error{OutOfMemory}!std.ArrayList([*c]const u8) {
        var glfw_extension_count: u32 = 0;
        const glfw_extensions = glfw.glfwGetRequiredInstanceExtensions(&glfw_extension_count);
        var extensions = try std.ArrayList([*c]const u8).initCapacity(allocator, glfw_extension_count);
        for (0..glfw_extension_count) |i|
            try extensions.append(allocator, glfw_extensions[i]);
        try extensions.append(allocator, vk.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        try extensions.append(allocator, vk.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
        try extensions.append(allocator, "VK_MVK_macos_surface");

        if (build_options.debug)
            try extensions.append(allocator, vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);

        return extensions;
    }

    fn setupDebugMessenger(self: *Self) void {
        var debug_messenger_create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{};
        populateDebugMessengerCreateInfo(&debug_messenger_create_info);

        const result = createDebugUtilsMessengerEXT(
            self.instance,
            &debug_messenger_create_info,
            null,
            &self.debug_messenger,
        );
        if (result != vk.VK_SUCCESS)
            std.debug.panic("Could not create debug messenger {}\n", .{result});
    }

    fn createSurface(self: *Self) void {
        const result = glfw.glfwCreateWindowSurface(
            @ptrCast(self.instance),
            self.window,
            null,
            &self.surface,
        );
        if (result != vk.VK_SUCCESS) std.debug.panic("Could not create surface {}\n", .{result});
    }

    fn pickPhysicalDevice(self: *Self) void {
        var device_count: u32 = 0;
        _ = vk.vkEnumeratePhysicalDevices(self.instance, &device_count, null);
        if (device_count == 0) @panic("There were no physical devices found");

        var physical_devices = std.ArrayList(vk.VkPhysicalDevice).initCapacity(
            self.allocator,
            device_count,
        ) catch @panic("OOM");
        defer physical_devices.deinit(self.allocator);
        physical_devices.resize(self.allocator, device_count) catch @panic("OOM");

        _ = vk.vkEnumeratePhysicalDevices(
            self.instance,
            &device_count,
            physical_devices.items.ptr,
        );

        for (physical_devices.items) |device| {
            if (self.isDeviceSuitable(device)) {
                self.physical_device = device;
                break;
            }
        }

        if (self.physical_device == null)
            @panic("There are no suitable physical devices");
    }

    fn isDeviceSuitable(self: *Self, physical_device: vk.VkPhysicalDevice) bool {
        const indices = self.findQueueFamilies(physical_device);
        const extensions_supported = self.checkDeviceExtensionSupport(physical_device);

        var swap_chain_adequate = false;
        if (extensions_supported) {
            var details = self.querySwapChainSupport(physical_device);
            defer details.formats.?.deinit(self.allocator);
            defer details.present_modes.?.deinit(self.allocator);
            swap_chain_adequate = details.formats.?.items.len > 0 and details.present_modes.?.items.len > 0;
        }

        return indices.isComplete() and extensions_supported and swap_chain_adequate;
    }

    fn checkDeviceExtensionSupport(self: *Self, physcial_device: vk.VkPhysicalDevice) bool {
        var extension_count: u32 = 0;
        _ = vk.vkEnumerateDeviceExtensionProperties(
            physcial_device,
            null,
            &extension_count,
            null,
        );

        var extensions = std.ArrayList(vk.VkExtensionProperties).initCapacity(
            self.allocator,
            extension_count,
        ) catch @panic("OOM");
        defer extensions.deinit(self.allocator);
        extensions.resize(self.allocator, extension_count) catch @panic("OOM");
        _ = vk.vkEnumerateDeviceExtensionProperties(
            physcial_device,
            null,
            &extension_count,
            &extensions.items[0],
        );

        for (device_extensions) |required_extension| {
            var extension_found = false;

            for (extensions.items) |extension| {
                var name_len: usize = 0;
                while (extension.extensionName[name_len] != 0) name_len += 1;
                const extension_name = extension.extensionName[0..name_len];
                if (std.mem.eql(u8, std.mem.span(required_extension), extension_name)) {
                    extension_found = true;
                    break;
                }
            }

            if (!extension_found) return false;
        }

        return true;
    }

    fn findQueueFamilies(self: *Self, physical_device: vk.VkPhysicalDevice) QueueFamilyIndices {
        var indices: QueueFamilyIndices = .{};

        var queue_family_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);
        var queue_families = std.ArrayList(vk.VkQueueFamilyProperties).initCapacity(
            self.allocator,
            queue_family_count,
        ) catch @panic("OOM");
        defer queue_families.deinit(self.allocator);
        queue_families.resize(self.allocator, queue_family_count) catch @panic("OOM");

        vk.vkGetPhysicalDeviceQueueFamilyProperties(
            physical_device,
            &queue_family_count,
            queue_families.items.ptr,
        );

        for (queue_families.items, 0..) |queue_family, i| {
            var present_support: vk.VkBool32 = 0;
            _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(
                physical_device,
                @intCast(i),
                self.surface,
                &present_support,
            );

            if (present_support != 0) indices.present_family = @intCast(i);

            if (queue_family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) {
                indices.graphics_family = @intCast(i);
                if (indices.isComplete()) break;
            }
        }

        return indices;
    }

    fn createLogicalDevice(self: *Self) void {
        const indices = self.findQueueFamilies(self.physical_device);

        var queue_create_infos = std.ArrayList(vk.VkDeviceQueueCreateInfo).initCapacity(
            self.allocator,
            2,
        ) catch @panic("OOM");
        defer queue_create_infos.deinit(self.allocator);
        var unique_queue_families = std.AutoHashMap(u32, void).init(self.allocator);
        defer unique_queue_families.deinit();
        unique_queue_families.put(indices.graphics_family.?, {}) catch unreachable;
        unique_queue_families.put(indices.present_family.?, {}) catch unreachable;

        const queue_priority: f32 = 1.0;
        var queue_family_iter = unique_queue_families.keyIterator();
        while (queue_family_iter.next()) |queue_family| {
            const queue_create_info = vk.VkDeviceQueueCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = queue_family.*,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_create_infos.append(self.allocator, queue_create_info) catch unreachable;
        }

        const device_features: vk.VkPhysicalDeviceFeatures = .{};

        var device_create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pQueueCreateInfos = &queue_create_infos.items[0],
            .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
            .pEnabledFeatures = &device_features,
            .enabledExtensionCount = @intCast(device_extensions.len),
            .ppEnabledExtensionNames = &device_extensions[0],
            .enabledLayerCount = 0,
        };

        if (build_options.debug) {
            device_create_info.enabledLayerCount = 1;
            device_create_info.ppEnabledLayerNames = &validation_layers[0];
        }

        const result = vk.vkCreateDevice(self.physical_device, &device_create_info, null, &self.device);
        if (result != vk.VK_SUCCESS) std.debug.panic("Could not create logical device {}\n", .{result});

        vk.vkGetDeviceQueue(self.device, indices.graphics_family.?, 0, &self.graphics_queue);
        vk.vkGetDeviceQueue(self.device, indices.present_family.?, 0, &self.present_queue);
    }

    fn createSwapChain(self: *Self) void {
        var swap_chain_support_details = self.querySwapChainSupport(self.physical_device);
        defer swap_chain_support_details.formats.?.deinit(self.allocator);
        defer swap_chain_support_details.present_modes.?.deinit(self.allocator);
        const surface_format = chooseSwapChainSurfaceFormat(swap_chain_support_details.formats.?);
        const present_mode = chooseSwapChainPresentMode(swap_chain_support_details.present_modes.?);
        const extent = self.chooseSwapExtent(swap_chain_support_details.capabilities);

        var min_image_count = swap_chain_support_details.capabilities.minImageCount + 1;
        if (swap_chain_support_details.capabilities.maxImageCount > 0 and min_image_count > swap_chain_support_details.capabilities.maxImageCount) {
            min_image_count = swap_chain_support_details.capabilities.maxImageCount;
        }

        var create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = min_image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .presentMode = present_mode,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .preTransform = swap_chain_support_details.capabilities.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = null,
        };

        const indices = self.findQueueFamilies(self.physical_device);
        if (indices.graphics_family != indices.present_family) {
            create_info.imageSharingMode = vk.VK_SHARING_MODE_CONCURRENT;
            create_info.pQueueFamilyIndices = &[_]u32{ indices.graphics_family.?, indices.present_family.? };
            create_info.queueFamilyIndexCount = 2;
        } else {
            create_info.imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
            create_info.pQueueFamilyIndices = null;
            create_info.queueFamilyIndexCount = 0;
        }

        const result = vk.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swap_chain);
        if (result != vk.VK_SUCCESS) std.debug.panic("Could not create swap chain {}\n", .{result});

        self.swap_chain_image_format = surface_format.format;
        self.swap_chain_extent = extent;

        var image_count: u32 = 0;
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swap_chain, &image_count, null);
        self.swap_chain_images.resize(self.allocator, image_count) catch @panic("OOM");
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swap_chain, &image_count, &self.swap_chain_images.items[0]);
    }

    fn createImageViews(self: *Self) void {
        self.swap_chain_image_views.resize(self.allocator, self.swap_chain_images.items.len) catch @panic("OOM");
        for (self.swap_chain_images.items, 0..) |image, i| {
            const image_view_create_info = vk.VkImageViewCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image, .viewType = vk.VK_IMAGE_VIEW_TYPE_2D, .format = self.swap_chain_image_format, .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_R,
                .g = vk.VK_COMPONENT_SWIZZLE_G,
                .b = vk.VK_COMPONENT_SWIZZLE_B,
                .a = vk.VK_COMPONENT_SWIZZLE_A,
            }, .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            } };

            const result = vk.vkCreateImageView(
                self.device,
                &image_view_create_info,
                null,
                &self.swap_chain_image_views.items[i],
            );
            if (result != vk.VK_SUCCESS) std.debug.panic("Could not create image view {}\n", .{result});
        }
    }

    fn createRenderPass(self: *Self) void {
        const color_attachment = vk.VkAttachmentDescription{
            .format = self.swap_chain_image_format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const color_attachment_ref = vk.VkAttachmentReference{
            .attachment = 0,
            .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = vk.VkSubpassDescription{
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
        };

        const subpass_dependency = vk.VkSubpassDependency{
            .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        const render_pass_create_info = vk.VkRenderPassCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &subpass_dependency,
        };

        const result = vk.vkCreateRenderPass(self.device, &render_pass_create_info, null, &self.render_pass);
        if (result != vk.VK_SUCCESS) std.debug.panic("Could not create render pass {}\n", .{result});
    }

    fn createGraphicsPipeline(self: *Self) void {
        const vert_shader_code: []const u8 = @embedFile("shaders/spir-v/triangle.vert.spv");
        const frag_shader_code: []const u8 = @embedFile("shaders/spir-v/triangle.frag.spv");
        const reinterpret_vert_code: *const [vert_shader_code.len / 4]u32 = @ptrCast(@alignCast(vert_shader_code.ptr));
        const reinterpret_frag_code: *const [frag_shader_code.len / 4]u32 = @ptrCast(@alignCast(frag_shader_code.ptr));

        const vert_shader_module = self.createShaderModule(&reinterpret_vert_code.*);
        const frag_shader_module = self.createShaderModule(&reinterpret_frag_code.*);
        defer vk.vkDestroyShaderModule(self.device, vert_shader_module, null);
        defer vk.vkDestroyShaderModule(self.device, frag_shader_module, null);

        const vert_shader_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_shader_module,
            .pName = "main",
        };

        const frag_shader_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_shader_module,
            .pName = "main",
        };

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
            vert_shader_stage_info,
            frag_shader_stage_info,
        };

        const vertex_input_state = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const dynamic_state_buffer = [_]vk.VkDynamicState{
            vk.VK_DYNAMIC_STATE_VIEWPORT,
            vk.VK_DYNAMIC_STATE_SCISSOR,
        };
        var dynamic_states = std.ArrayList(vk.VkDynamicState).initCapacity(
            self.allocator,
            dynamic_state_buffer.len,
        ) catch @panic("OOM");
        dynamic_states.insertSlice(self.allocator, 0, &dynamic_state_buffer) catch @panic("OOM");
        defer dynamic_states.deinit(self.allocator);
        const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = @intCast(dynamic_states.items.len),
            .pDynamicStates = &dynamic_states.items[0],
        };

        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.VK_FALSE,
        };

        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swap_chain_extent.width),
            .height = @floatFromInt(self.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swap_chain_extent,
        };

        const viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,
        };

        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = vk.VK_CULL_MODE_BACK_BIT,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = vk.VK_FALSE,
        };

        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = vk.VK_FALSE,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        };

        const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
            .blendEnable = vk.VK_FALSE,
        };

        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vk.VK_FALSE,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
        };

        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        };

        const layout_result = vk.vkCreatePipelineLayout(
            self.device,
            &pipeline_layout_info,
            null,
            &self.pipeline_layout,
        );
        if (layout_result != vk.VK_SUCCESS)
            std.debug.panic("Could not create pipeline layout {}\n", .{layout_result});

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = @intCast(shader_stages.len),
            .pStages = &shader_stages[0],
            .pVertexInputState = &vertex_input_state,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
        };

        const graphics_pipeline_result = vk.vkCreateGraphicsPipelines(
            self.device,
            null,
            1,
            &pipeline_info,
            null,
            &self.pipeline,
        );
        if (graphics_pipeline_result != vk.VK_SUCCESS)
            std.debug.print("Could not create graphics pipeline {}\n", .{graphics_pipeline_result});
    }

    fn createShaderModule(self: *Self, code: []const u32) vk.VkShaderModule {
        const create_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len * 4,
            .pCode = code.ptr,
        };

        var shader_module: vk.VkShaderModule = null;
        const result = vk.vkCreateShaderModule(self.device, &create_info, null, &shader_module);
        if (result != vk.VK_SUCCESS) std.debug.panic("Could not create shader module {}\n", .{result});
        return shader_module;
    }

    fn createFramebuffers(self: *Self) void {
        self.framebuffers.resize(self.allocator, self.swap_chain_image_views.items.len) catch @panic("OOM");

        for (self.swap_chain_image_views.items, 0..) |image_view, i| {
            const framebuffer_info = vk.VkFramebufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = &image_view,
                .width = self.swap_chain_extent.width,
                .height = self.swap_chain_extent.height,
                .layers = 1,
            };

            const result = vk.vkCreateFramebuffer(
                self.device,
                &framebuffer_info,
                null,
                &self.framebuffers.items[i],
            );
            if (result != vk.VK_SUCCESS) std.debug.panic("Could not create frame buffer {}\n", .{result});
        }
    }

    fn createCommandPool(self: *Self) void {
        const queue_family_indices = self.findQueueFamilies(self.physical_device);

        const create_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = queue_family_indices.graphics_family.?,
        };

        const result = vk.vkCreateCommandPool(self.device, &create_info, null, &self.command_pool);
        if (result != vk.VK_SUCCESS) std.debug.panic("Could not create command pool {}\n", .{result});
    }

    fn createCommandBuffer(self: *Self) void {
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        const result = vk.vkAllocateCommandBuffers(self.device, &alloc_info, &self.command_buffer);
        if (result != vk.VK_SUCCESS) std.debug.panic("Could not allocate command buffer {}\n", .{result});
    }

    fn createSyncObjects(self: *Self) void {
        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        const result = vk.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available_semaphore) == vk.VK_SUCCESS and
            vk.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_finished_semaphore) == vk.VK_SUCCESS and
            vk.vkCreateFence(self.device, &fence_info, null, &self.in_flight_fence) == vk.VK_SUCCESS;
        if (!result) std.debug.panic("Could not create sync objects\n", .{});
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
            std.debug.print("{s}\n", .{callback_data.*.pMessage});

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
            var layer_found = false;

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

    fn querySwapChainSupport(self: *Self, physical_device: vk.VkPhysicalDevice) SwapChainSupportDetails {
        var details = SwapChainSupportDetails{};
        details.formats = std.ArrayList(vk.VkSurfaceFormatKHR).initCapacity(self.allocator, 0) catch unreachable;
        details.present_modes = std.ArrayList(vk.VkPresentModeKHR).initCapacity(self.allocator, 0) catch unreachable;

        _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            physical_device,
            self.surface,
            &details.capabilities,
        );

        var format_mode_count: u32 = 0;
        _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            physical_device,
            self.surface,
            &format_mode_count,
            null,
        );

        if (format_mode_count != 0) {
            details.formats.?.resize(self.allocator, format_mode_count) catch @panic("OOM");
            _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
                physical_device,
                self.surface,
                &format_mode_count,
                &details.formats.?.items[0],
            );
        }

        var present_mode_count: u32 = 0;
        _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
            physical_device,
            self.surface,
            &present_mode_count,
            null,
        );

        if (present_mode_count != 0) {
            details.present_modes.?.resize(self.allocator, present_mode_count) catch @panic("OOM");
            _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
                physical_device,
                self.surface,
                &present_mode_count,
                &details.present_modes.?.items[0],
            );
        }

        return details;
    }

    fn chooseSwapChainSurfaceFormat(available_formats: std.array_list.Aligned(vk.VkSurfaceFormatKHR, null)) vk.VkSurfaceFormatKHR {
        for (available_formats.items) |format| {
            if (format.format == vk.VK_FORMAT_B8G8R8_SRGB and format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
                return format;
        }

        return available_formats.items[0];
    }

    fn chooseSwapChainPresentMode(available_present_modes: std.array_list.Aligned(vk.VkPresentModeKHR, null)) vk.VkPresentModeKHR {
        for (available_present_modes.items) |present_mode| {
            if (present_mode == vk.VK_PRESENT_MODE_MAILBOX_KHR)
                return present_mode;
        }

        return vk.VK_PRESENT_MODE_FIFO_KHR;
    }

    fn chooseSwapExtent(self: *Self, capabilities: vk.VkSurfaceCapabilitiesKHR) vk.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        } else {
            var width: c_int = 0;
            var height: c_int = 0;
            glfw.glfwGetFramebufferSize(self.window, &width, &height);

            var actual_extent = vk.VkExtent2D{
                .width = @intCast(width),
                .height = @intCast(height),
            };

            actual_extent.width = std.math.clamp(
                actual_extent.width,
                capabilities.minImageExtent.width,
                capabilities.maxImageExtent.width,
            );

            actual_extent.height = std.math.clamp(
                actual_extent.height,
                capabilities.minImageExtent.height,
                capabilities.maxImageExtent.height,
            );

            return actual_extent;
        }
    }

    fn recordCommandBuffer(self: *Self, command_buffer: vk.VkCommandBuffer, image_index: u32) void {
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };

        const begin_result = vk.vkBeginCommandBuffer(command_buffer, &begin_info);
        if (begin_result != vk.VK_SUCCESS) std.debug.panic("Could not begin command buffer {}\n", .{begin_result});

        const clear_color = vk.VkClearValue{
            .color = .{
                .float32 = .{ 0.0, 0.0, 0.0, 1.0 },
            },
        };

        const render_pass_info = vk.VkRenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers.items[image_index],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swap_chain_extent,
            },
            .clearValueCount = 1,
            .pClearValues = &clear_color,
        };

        vk.vkCmdBeginRenderPass(command_buffer, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);
        defer _ = vk.vkEndCommandBuffer(command_buffer);

        vk.vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);

        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swap_chain_extent.width),
            .height = @floatFromInt(self.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swap_chain_extent,
        };
        vk.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        vk.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        vk.vkCmdEndRenderPass(command_buffer);
    }

    fn mainLoop(self: *Self) void {
        while (glfw.glfwWindowShouldClose(self.window) != 1) {
            glfw.glfwPollEvents();
            self.drawFrame();
        }

        _ = vk.vkDeviceWaitIdle(self.device);
    }

    fn drawFrame(self: *Self) void {
        _ = vk.vkWaitForFences(self.device, 1, &self.in_flight_fence, vk.VK_TRUE, std.math.maxInt(u64));
        _ = vk.vkResetFences(self.device, 1, &self.in_flight_fence);

        var image_index: u32 = 0;
        _ = vk.vkAcquireNextImageKHR(
            self.device,
            self.swap_chain,
            std.math.maxInt(u64),
            self.image_available_semaphore,
            null,
            &image_index,
        );

        _ = vk.vkResetCommandBuffer(self.command_buffer, 0);
        self.recordCommandBuffer(self.command_buffer, image_index);

        const wait_semaphores = [_]vk.VkSemaphore{self.image_available_semaphore};
        const signal_semaphores = [_]vk.VkSemaphore{self.image_finished_semaphore};
        const wait_stages = [_]u32{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores[0],
            .pWaitDstStageMask = &wait_stages[0],
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores[0],
        };

        const result = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight_fence);
        if (result != vk.VK_SUCCESS) std.debug.panic("Failed to submit draw command buffer {}\n", .{result});

        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal_semaphores[0],
            .swapchainCount = 1,
            .pSwapchains = &self.swap_chain,
            .pImageIndices = &image_index,
        };

        _ = vk.vkQueuePresentKHR(self.present_queue, &present_info);
    }
};
