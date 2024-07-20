const std = @import("std");
const sdl_util = @import("sdl_util.zig");
const c = @import("clibs.zig");
const Window = @import("window.zig").Window;
const Allocator = std.mem.Allocator;

const required_device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

const VkPhysicalDevice = struct {
    device: c.VkPhysicalDevice,
    properties: c.VkPhysicalDeviceProperties,
    device_memory: c.VkPhysicalDeviceMemoryProperties,
};

const VkQueue = struct {
    handle: c.VkQueue,
    qfi: u32,
};

const VkDevice = struct {
    handle: c.VkDevice,
    queue: VkQueue,
};
const SwapchainImage = struct {
    image: c.VkImage,
    view: c.VkImageView,
};

pub const TextureFormat = enum {
    rgba_8,
};

pub const TextureFlags = packed struct {};

pub const Texture = struct {
    pub const CreateInfo = struct {
        width: usize,
        height: usize,
        format: TextureFormat,
        initial_bytes: ?[]const u8,
        flags: TextureFlags = .{},
    };
    image: c.VkImage,
    view: c.VkImageView,
};

fn vk_check(expr: c.VkResult, comptime errmsg: []const u8) void {
    if (expr != c.VK_SUCCESS) {
        vulkan_init_failure(errmsg);
    }
}
const VkFuncs = struct {
    create_debug_messenger: c.PFN_vkCreateDebugUtilsMessengerEXT,
    destroy_debug_messenger: c.PFN_vkDestroyDebugUtilsMessengerEXT,

    fn loadFunc(instance: c.VkInstance, comptime T: type, comptime funcname: [*c]const u8) T {
        const func: T = @ptrCast(c.vkGetInstanceProcAddr(instance, funcname));
        return func;
    }

    fn init(instance: c.VkInstance) VkFuncs {
        return .{
            .create_debug_messenger = loadFunc(instance, c.PFN_vkCreateDebugUtilsMessengerEXT, "vkCreateDebugUtilsMessengerEXT"),
            .destroy_debug_messenger = loadFunc(instance, c.PFN_vkDestroyDebugUtilsMessengerEXT, "vkDestroyDebugUtilsMessengerEXT"),
        };
    }
};

const Swapchain = struct {
    handle: ?c.VkSwapchainKHR = null,
    images: []SwapchainImage = &[0]SwapchainImage{},
    format: c.VkSurfaceFormatKHR = undefined,
    present_mode: c.VkPresentModeKHR = undefined,
    extents: c.VkExtent2D = undefined,
    current_image: u32 = undefined,

    acquire_fence: c.VkFence = null,

    fn init(this: *Swapchain, instance: c.VkInstance, physical_device: c.VkPhysicalDevice, device: c.VkDevice, surface: c.VkSurfaceKHR, queue: c.VkQueue, qfi: u32, allocator: Allocator) !void {
        _ = instance;
        this.deinit(device, allocator);
        if (this.images.len > 0) {
            allocator.free(this.images);
        }

        const acquire_fence = try make_fence(device, false);

        var surface_info: c.VkSurfaceCapabilitiesKHR = undefined;
        vk_check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_info), "failed to get surface capabilities");
        var surface_counts: u32 = undefined;
        vk_check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &surface_counts, null), "Failed to count num of surface formats");
        const surface_formats = try allocator.alloc(c.VkSurfaceFormatKHR, surface_counts);
        defer allocator.free(surface_formats);

        vk_check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &surface_counts, surface_formats.ptr), "Failed to get surface_formats");

        const img_format = surface_formats[0];
        const present_mode = c.VK_PRESENT_MODE_FIFO_KHR;
        const flags = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

        var image_count: u32 = 3;

        const swapchain_create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = surface,
            .minImageCount = image_count,
            .imageFormat = img_format.format,
            .imageColorSpace = img_format.colorSpace,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &[1]u32{qfi},
            .imageUsage = flags,
            .clipped = c.VK_TRUE,
            .preTransform = surface_info.currentTransform,
            .imageExtent = surface_info.currentExtent,
            .imageArrayLayers = 1,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
        };

        var swapchain_instance: c.VkSwapchainKHR = undefined;
        vk_check(c.vkCreateSwapchainKHR(device, &swapchain_create_info, null, &swapchain_instance), "Failed to create swapchain");
        errdefer c.vkDestroySwapchainKHR(device, swapchain_instance, null);
        this.* = Swapchain{ .handle = swapchain_instance, .current_image = 0, .extents = swapchain_create_info.imageExtent, .format = img_format, .images = try allocator.alloc(SwapchainImage, 3), .present_mode = present_mode, .acquire_fence = acquire_fence };

        const images = try allocator.alloc(c.VkImage, image_count);
        const views = try allocator.alloc(c.VkImageView, image_count);
        defer allocator.free(images);
        defer allocator.free(views);

        vk_check(c.vkGetSwapchainImagesKHR(device, swapchain_instance, &image_count, images.ptr), "Failed to get images from swapchain");
        var cmd_pool: c.VkCommandPool = undefined;
        vk_check(c.vkCreateCommandPool(device, &c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = qfi }, null, &cmd_pool), "Failed to create command pool");
        defer c.vkDestroyCommandPool(device, cmd_pool, null);

        var cmd_buffers = [1]c.VkCommandBuffer{undefined};
        vk_check(c.vkAllocateCommandBuffers(device, &c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = cmd_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        }, &cmd_buffers), "Failed to allocate command buffer");

        vk_check(c.vkBeginCommandBuffer(cmd_buffers[0], &c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }), "Failed to begin command buffer");

        const image_mem_barriers = try allocator.alloc(c.VkImageMemoryBarrier2, images.len);
        defer allocator.free(image_mem_barriers);

        for (images, 0..) |image, i| {
            const subresource_range = c.VkImageSubresourceRange{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseArrayLayer = 0, .baseMipLevel = 0, .layerCount = 1, .levelCount = 1 };
            var view: c.VkImageView = undefined;

            vk_check(c.vkCreateImageView(device, &c.VkImageViewCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image, .format = img_format.format, .subresourceRange = subresource_range, .viewType = c.VK_IMAGE_TYPE_2D, .components = c.VkComponentMapping{
                .a = c.VK_COMPONENT_SWIZZLE_A,
                .r = c.VK_COMPONENT_SWIZZLE_R,
                .g = c.VK_COMPONENT_SWIZZLE_G,
                .b = c.VK_COMPONENT_SWIZZLE_B,
            } }, null, &view), "Failed to create swapchain image view");
            this.images[i] = .{ .image = image, .view = view };
            image_mem_barriers[i] = c.VkImageMemoryBarrier2{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .image = image,
                .newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .subresourceRange = subresource_range,
                .srcQueueFamilyIndex = qfi,
                .dstQueueFamilyIndex = qfi,
                .srcAccessMask = 0,
                .srcStageMask = 0,
                .dstAccessMask = 0,
                .dstStageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            };
        }
        c.vkCmdPipelineBarrier2(cmd_buffers[0], &c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .bufferMemoryBarrierCount = 0,
            .memoryBarrierCount = 0,
            .imageMemoryBarrierCount = @intCast(image_mem_barriers.len),
            .pImageMemoryBarriers = image_mem_barriers.ptr,
        });
        vk_check(c.vkEndCommandBuffer(cmd_buffers[0]), "Failed to end command buffer");

        vk_check(c.vkQueueSubmit2(queue, 1, &[1]c.VkSubmitInfo2{c.VkSubmitInfo2{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &[1]c.VkCommandBufferSubmitInfo{c.VkCommandBufferSubmitInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                .commandBuffer = cmd_buffers[0],
                .deviceMask = 0,
            }},
            .pWaitSemaphoreInfos = null,
            .pSignalSemaphoreInfos = null,
        }}, null), "Failed to submit cbuffer");
        vk_check(c.vkDeviceWaitIdle(device), "Failed to wait device idle");
        vk_check(c.vkResetCommandPool(device, cmd_pool, c.VK_COMMAND_POOL_RESET_RELEASE_RESOURCES_BIT), "Failed to reset command pool");
    }

    fn deinit(this: *Swapchain, device: c.VkDevice, allocator: Allocator) void {
        if (this.handle == null) {
            return;
        }

        c.vkDestroyFence(device, this.acquire_fence, null);
        defer allocator.free(this.images);
        for (this.images) |image| {
            c.vkDestroyImageView(device, image.view, null);
        }
        c.vkDestroySwapchainKHR(device, this.handle.?, null);
    }

    fn acquire_next_image(this: *Swapchain, device: VkDevice) !void {
        std.debug.assert(this.acquire_fence != null);
        var image_index: u32 = undefined;
        vk_check(c.vkAcquireNextImageKHR(device.handle, this.handle.?, std.math.maxInt(u64), null, this.acquire_fence, &image_index), "Failed to acquire next image");
        const fences = [1]c.VkFence{this.acquire_fence};
        vk_check(c.vkWaitForFences(device.handle, 1, &fences, c.VK_TRUE, std.math.maxInt(u64)), "Failed to wait for fences");
        vk_check(c.vkResetFences(device.handle, 1, &fences), "Failed to reset fence");

        this.current_image = image_index;
    }

    fn present(this: *Swapchain, device: VkDevice) !void {
        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pImageIndices = &[1]u32{this.current_image},
            .pResults = null,
            .pSwapchains = &[1]c.VkSwapchainKHR{this.handle.?},
            .swapchainCount = 1,
            .pWaitSemaphores = null,
            .waitSemaphoreCount = 0,
        };
        vk_check(c.vkQueuePresentKHR(device.queue.handle, &present_info), "Failed to present image");
    }
};

const TextureDrawInfo = struct {
    texture: Texture,
};

const RenderTextures = std.ArrayList(TextureDrawInfo);
const RenderList = struct {
    textures: RenderTextures,

    fn init(allocator: Allocator) RenderList {
        return .{
            .textures = RenderTextures.init(allocator),
        };
    }

    fn clear(this: *RenderList) void {
        this.textures.clearRetainingCapacity();
    }

    fn deinit(this: *RenderList) void {
        this.textures.deinit();
    }
};

pub const Renderer = struct {
    instance: c.VkInstance,
    funcs: VkFuncs,
    allocator: Allocator,
    vk_allocator: c.VmaAllocator,

    debug_utils_messenger: c.VkDebugUtilsMessengerEXT,

    surface: c.VkSurfaceKHR,
    physical_device: VkPhysicalDevice,
    device: VkDevice,

    swapchain: Swapchain,

    render_list: RenderList,

    pub fn init(window: *Window, allocator: Allocator) !Renderer {
        const instance = try create_vulkan_instance(window.window, allocator);
        errdefer c.vkDestroyInstance(instance, null);

        const funcs = VkFuncs.init(instance);

        const debug_utils = c.VkDebugUtilsMessengerCreateInfoEXT{ .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT, .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT, .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT, .pfnUserCallback = message_callback };
        var debug_utils_messenger: c.VkDebugUtilsMessengerEXT = undefined;
        vk_check(funcs.create_debug_messenger.?(instance, &debug_utils, null, &debug_utils_messenger), "Failed to create debug messenger");

        const surface = create_vulkan_surface(window.window, instance);
        errdefer c.vkDestroySurfaceKHR(instance, surface, null);

        const physical_device = try select_physical_device(instance, allocator);
        const device = try init_logical_device(physical_device, surface, allocator);
        errdefer c.vkDestroyDevice(device.handle, null);

        var swapchain = Swapchain{};
        try swapchain.init(instance, physical_device.device, device.handle, surface, device.queue.handle, device.queue.qfi, allocator);

        std.log.info("Picked device {s}\n", .{physical_device.properties.deviceName});

        var vk_allocator: c.VmaAllocator = undefined;

        vk_check(c.vmaCreateAllocator(&c.VmaAllocatorCreateInfo{
            .flags = 0,
            .device = device.handle,
            .instance = instance,
            .physicalDevice = physical_device.device,
        }, &vk_allocator), "Failed to create vma allocator");

        return .{
            .instance = instance,
            .allocator = allocator,
            .vk_allocator = vk_allocator,

            .funcs = funcs,
            .debug_utils_messenger = debug_utils_messenger,
            .surface = surface,
            .physical_device = physical_device,
            .device = device,
            .swapchain = swapchain,

            .render_list = RenderList.init(allocator),
        };
    }

    pub fn deinit(this: *Renderer) void {
        this.render_list.deinit();

        c.vmaDestroyAllocator(this.vk_allocator);
        this.swapchain.deinit(this.device.handle, this.allocator);
        c.vkDestroyDevice(this.device.handle, null);
        c.vkDestroySurfaceKHR(this.instance, this.surface, null);
        this.funcs.destroy_debug_messenger.?(this.instance, this.debug_utils_messenger, null);
        c.vkDestroyInstance(this.instance, null);
    }

    pub fn start_rendering(this: *Renderer) !void {
        this.render_list.clear();
        try this.swapchain.acquire_next_image(this.device);
    }

    pub fn render(this: *Renderer) !void {
        try this.swapchain.present(this.device);
    }

    fn create_vulkan_instance(window: *c.SDL_Window, allocator: Allocator) !c.VkInstance {
        const app_info = c.VkApplicationInfo{
            .pApplicationName = "EngineApplication",
            .pEngineName = "Engine",
            .apiVersion = c.VK_API_VERSION_1_3,
            .engineVersion = c.VK_MAKE_VERSION(0, 0, 0),
            .applicationVersion = c.VK_MAKE_VERSION(0, 0, 0),
        };
        var ext_counts: c_uint = 0;
        if (c.SDL_Vulkan_GetInstanceExtensions(window, &ext_counts, null) != c.SDL_TRUE) {
            sdl_util.sdl_panic();
        }

        var exts = std.ArrayList([*c]const u8).init(allocator);
        defer exts.deinit();
        _ = try exts.addManyAsSlice(ext_counts);
        try exts.append("VK_EXT_debug_utils");

        if (c.SDL_Vulkan_GetInstanceExtensions(window, &ext_counts, exts.items.ptr) != c.SDL_TRUE) {
            sdl_util.sdl_panic();
        }

        const required_layers: [*]const [*:0]const u8 = &.{"VK_LAYER_KHRONOS_validation"};

        var instance: c.VkInstance = undefined;
        vk_check(c.vkCreateInstance(&.{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = @intCast(exts.items.len),
            .ppEnabledExtensionNames = exts.items.ptr,
            .enabledLayerCount = 1,
            .ppEnabledLayerNames = required_layers,
        }, null, &instance), "Failed to create instance");

        return instance;
    }

    fn create_vulkan_surface(window: *c.SDL_Window, instance: c.VkInstance) c.VkSurfaceKHR {
        var surface: c.VkSurfaceKHR = undefined;
        if (c.SDL_Vulkan_CreateSurface(window, instance, &surface) != c.SDL_TRUE) {
            sdl_util.sdl_panic();
        }
        return surface;
    }

    fn select_physical_device(instance: c.VkInstance, allocator: Allocator) !VkPhysicalDevice {
        const funcs = struct {
            const SortContext = struct {
                instance: c.VkInstance,
            };

            fn device_ty_priority(device_type: c.VkPhysicalDeviceType) usize {
                return switch (device_type) {
                    c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 3,
                    c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2,
                    c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1,
                    else => 0,
                };
            }
            fn sort_physical_devices(context: SortContext, a: c.VkPhysicalDevice, b: c.VkPhysicalDevice) bool {
                _ = context;
                var props_a: c.VkPhysicalDeviceProperties = undefined;
                var props_b: c.VkPhysicalDeviceProperties = undefined;
                c.vkGetPhysicalDeviceProperties(a, &props_a);
                c.vkGetPhysicalDeviceProperties(b, &props_b);
                const device_ty_a = device_ty_priority(props_a.deviceType);
                const device_ty_b = device_ty_priority(props_b.deviceType);

                return device_ty_a > device_ty_b;
            }
        };
        var pdevice_count: u32 = undefined;
        vk_check(c.vkEnumeratePhysicalDevices(instance, &pdevice_count, null), "Failed to enumerate devices");
        const devices = try allocator.alloc(c.VkPhysicalDevice, pdevice_count);
        defer allocator.free(devices);

        vk_check(c.vkEnumeratePhysicalDevices(instance, &pdevice_count, devices.ptr), "Failed to get physical devices");

        std.mem.sort(c.VkPhysicalDevice, devices, funcs.SortContext{ .instance = instance }, funcs.sort_physical_devices);

        std.log.debug("{d} candidate devices", .{pdevice_count});

        for (devices, 0..) |device, idx| {
            var properties: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(device, &properties);
            std.log.debug("\t{d}) Device {s}", .{ idx, properties.deviceName });
        }

        for (devices) |device| {
            var properties: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(device, &properties);
            if (properties.deviceType != c.VK_PHYSICAL_DEVICE_TYPE_CPU) {
                var device_mem: c.VkPhysicalDeviceMemoryProperties = undefined;
                c.vkGetPhysicalDeviceMemoryProperties(device, &device_mem);

                return .{
                    .device = device,
                    .properties = properties,
                    .device_memory = device_mem,
                };
            }
        }
        vulkan_init_failure("Failed to pick valid device");
    }

    fn init_logical_device(
        physical_device: VkPhysicalDevice,
        surface: c.VkSurfaceKHR,
        allocator: Allocator,
    ) !VkDevice {
        var props_count: u32 = undefined;
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device.device, &props_count, null);
        const props = try allocator.alloc(c.VkQueueFamilyProperties, props_count);
        defer allocator.free(props);
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device.device, &props_count, props.ptr);

        var graphics_qfi: ?u32 = null;
        for (props, 0..) |prop, idx| {
            var supported: u32 = c.VK_FALSE;
            if (prop.queueFlags & c.VK_QUEUE_GRAPHICS_BIT > 0 and c.vkGetPhysicalDeviceSurfaceSupportKHR(physical_device.device, @intCast(idx), surface, &supported) == c.VK_SUCCESS and supported == c.VK_TRUE) {
                graphics_qfi = @intCast(idx);
            }
        }

        if (graphics_qfi == null) {
            vulkan_init_failure("Failed to pick a vulkan graphics queue");
        }

        const prios: [1]f32 = .{1.0};

        const queue_create_info: [1]c.VkDeviceQueueCreateInfo = .{
            c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueCount = 1,
                .queueFamilyIndex = graphics_qfi.?,
                .pQueuePriorities = &prios,
            },
        };

        var synchronization2 = c.VkPhysicalDeviceSynchronization2Features{
            .pNext = null,
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
            .synchronization2 = c.VK_TRUE,
        };
        var features2 = c.VkPhysicalDeviceFeatures2{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &synchronization2, .features = .{} };
        const device_create_info = c.VkDeviceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &features2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_create_info, .enabledExtensionCount = @intCast(required_device_extensions.len), .ppEnabledExtensionNames = &required_device_extensions };

        var device: c.VkDevice = undefined;
        vk_check(c.vkCreateDevice(physical_device.device, &device_create_info, null, &device), "Failed to create device");

        var queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, graphics_qfi.?, 0, &queue);

        return .{
            .handle = device,
            .queue = VkQueue{ .handle = queue, .qfi = graphics_qfi.? },
        };
    }
};

fn message_callback(
    message_severity: c.VkDebugUtilsMessageSeverityFlagsEXT,
    message_types: c.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.C) c.VkBool32 {
    if (p_callback_data == null) {
        return c.VK_FALSE;
    }
    if (p_callback_data[0].pMessage == null) {
        return c.VK_FALSE;
    }
    _ = p_user_data;
    const format = "vulkan message: {s}";
    if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) > 0) {
        std.log.info(format, .{p_callback_data[0].pMessage});
    } else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) > 0) {
        std.log.warn(format, .{p_callback_data[0].pMessage});
    } else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) > 0) {
        std.log.err(format, .{p_callback_data[0].pMessage});

        if ((message_types & c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) > 0) {
            std.debug.panic("Vulkan failure", .{});
        }
    }
    return c.VK_FALSE;
}

fn vulkan_init_failure(message: []const u8) noreturn {
    sdl_util.message_box("Vulkan initialization failed", message, .Error);
    std.debug.panic("Vulkan  init error", .{});
}

fn make_fence(device: c.VkDevice, signaled: bool) !c.VkFence {
    var vk_fence: c.VkFence = undefined;
    vk_check(c.vkCreateFence(device, &c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = if (signaled)
        c.VK_FENCE_CREATE_SIGNALED_BIT
    else
        0 }, null, &vk_fence), "Failed to create vulkan fence");
    return vk_fence;
}

// fn make_semaphore(device: Device) !vk.Semaphore {
//     return try device.createSemaphore(&vk.SemaphoreCreateInfo{
//         .s_type = vk.StructureType.semaphore_create_info,
//     }, null);
// }
