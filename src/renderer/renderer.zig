const std = @import("std");
const sdl_util = @import("../sdl_util.zig");
const sampler_allocator = @import("sampler_allocator.zig");
const c = @import("../clibs.zig");
const types = @import("types.zig");

const Window = @import("../window.zig").Window;
const Allocator = std.mem.Allocator;

const Texture = types.Texture;
const TextureHandle = types.TextureHandle;
const TextureFlags = types.TextureFlags;
const TextureFormat = types.TextureFormat;
const Buffer = types.Buffer;
const BufferHandle = types.BufferHandle;
const BufferFlags = types.BufferFlags;

const required_device_extensions = [_][*:0]const u8{ "VK_KHR_swapchain", "VK_KHR_dynamic_rendering" };

pub const Renderer = struct {
    const FRAMES_IN_FLIGHT = 3;

    instance: c.VkInstance,
    debug_utils: ?DebugUtilsMessengerExt,
    allocator: Allocator,
    vk_allocator: c.VmaAllocator,

    surface: c.VkSurfaceKHR,
    physical_device: VkPhysicalDevice,
    device: VkDevice,

    swapchain: Swapchain,

    render_states: []RenderState,
    render_list: RenderList,
    texture_allocator: TextureAllocator,
    sampler_allocator: sampler_allocator.SamplerAllocator,

    current_render_state: usize = 0,

    pub fn init(window: *Window, allocator: Allocator) !Renderer {
        const instance = try create_vulkan_instance(window.window, allocator);
        errdefer c.vkDestroyInstance(instance, null);

        const debug_utils = DebugUtilsMessengerExt.init(instance);

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

        var render_states = try allocator.alloc(RenderState, Renderer.FRAMES_IN_FLIGHT);
        errdefer allocator.free(render_states);

        for (0..Renderer.FRAMES_IN_FLIGHT) |i| {
            render_states[i] = try RenderState.init(device);
        }

        return .{
            .instance = instance,
            .allocator = allocator,
            .vk_allocator = vk_allocator,

            .debug_utils = debug_utils,
            .surface = surface,
            .physical_device = physical_device,
            .device = device,
            .swapchain = swapchain,

            .render_list = RenderList.init(allocator),
            .render_states = render_states,
            .texture_allocator = try TextureAllocator.init(device, allocator, vk_allocator),
            .sampler_allocator = sampler_allocator.SamplerAllocator.init(allocator, device.handle),
        };
    }

    pub fn deinit(this: *Renderer) void {
        vk_check(c.vkDeviceWaitIdle(this.device.handle), "Failed to wait for device idle in deinit");
        for (0..Renderer.FRAMES_IN_FLIGHT) |i| {
            this.render_states[i].deinit(this.device);
        }

        this.texture_allocator.deinit(this.device);
        this.sampler_allocator.deinit();
        this.render_list.deinit();

        c.vmaDestroyAllocator(this.vk_allocator);
        this.swapchain.deinit(this.device.handle, this.allocator);
        c.vkDestroyDevice(this.device.handle, null);
        c.vkDestroySurfaceKHR(this.instance, this.surface, null);

        if (this.debug_utils) |*utils| {
            utils.deinit(this.instance);
        }

        c.vkDestroyInstance(this.instance, null);
    }

    pub fn alloc_texture(this: *Renderer, description: Texture.CreateInfo) !Texture {
        const allocation = try this.texture_allocator.alloc_texture(this.device, &this.sampler_allocator, description);
        if (description.initial_bytes) |bytes| {
            // TODO: implement better copying strategy
            const texel_size_bytes = switch (description.format) {
                .rgba_8 => 4,
            };
            const total_size_needed = description.width * description.height * description.depth * texel_size_bytes;

            std.debug.assert(bytes.len >= total_size_needed);

            const staging_buffer = try this.create_staging_buffer(total_size_needed);
            var alloc_info = std.mem.zeroes(c.VmaAllocationInfo);
            c.vmaGetAllocationInfo(this.vk_allocator, staging_buffer.allocation, &alloc_info);
            const ptr: [*]u8 = @ptrCast(alloc_info.pMappedData);
            @memcpy(ptr, bytes);

            const cmd_buf = try this.allocate_oneshot_command_buffer();

            quick_transition_image(cmd_buf, .{
                .image = allocation.texture.image,
                .subresource = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
            }, .{}, .{
                .layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .access_flags = c.VK_ACCESS_2_MEMORY_WRITE_BIT,
                .pipeline_flags = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            });

            const regions = &[_]c.VkBufferImageCopy{c.VkBufferImageCopy{
                .imageSubresource = c.VkImageSubresourceLayers{
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                    .mipLevel = 0,
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                },
                .imageExtent = c.VkExtent3D{ .width = description.width, .height = description.height, .depth = description.depth },
            }};
            c.vkCmdCopyBufferToImage(cmd_buf, staging_buffer.buffer, allocation.texture.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, regions);

            quick_transition_image(cmd_buf, .{
                .image = allocation.texture.image,
                .subresource = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
            }, .{
                .layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .access_flags = c.VK_ACCESS_2_MEMORY_WRITE_BIT,
                .pipeline_flags = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            }, .{
                .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .access_flags = c.VK_ACCESS_2_SHADER_READ_BIT,
                .pipeline_flags = c.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
            });

            this.submit_oneshot_command_buffer(true, cmd_buf);
            c.vmaDestroyBuffer(this.vk_allocator, staging_buffer.buffer, staging_buffer.allocation);
        }
        return allocation.texture;
    }

    pub fn free_texture(this: *Renderer, texture: Texture) void {
        this.texture_allocator.free_texture(this.device, texture.handle);
    }

    pub fn start_rendering(this: *Renderer) !void {
        var render_state = &this.render_states[this.current_render_state];
        render_state.start_frame(this.device);
        this.render_list.clear();
        try this.swapchain.acquire_next_image(this.device);
    }

    pub fn render(this: *Renderer) !void {
        var render_state = &this.render_states[this.current_render_state];

        try this.texture_allocator.flush_updates(this.device);

        const current_img_view = this.swapchain.images[this.swapchain.current_image].view;
        const rendering_info = c.VkRenderingInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = c.VkRect2D{
                .offset = .{},
                .extent = this.swapchain.extents,
            },
            .pColorAttachments = &[1]c.VkRenderingAttachmentInfo{c.VkRenderingAttachmentInfo{ .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE, .imageView = current_img_view, .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .clearValue = c.VkClearValue{ .color = c.VkClearColorValue{
                .uint32 = [4]u32{ 0, 0, 0, 0 },
            } } }},
            .colorAttachmentCount = 1,
            .layerCount = 1,
            .pDepthAttachment = null,
        };
        c.vkCmdBeginRendering(render_state.main_command_buffer, &rendering_info);

        // Do something

        c.vkCmdEndRendering(render_state.main_command_buffer);

        render_state.end_frame(this.device);
        try this.swapchain.present(this.device);
        this.current_render_state = (this.current_render_state + 1) % Renderer.FRAMES_IN_FLIGHT;
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
            var indexing_features: c.VkPhysicalDeviceDescriptorIndexingFeatures = undefined;
            indexing_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES;
            indexing_features.pNext = null;

            var features_2: c.VkPhysicalDeviceFeatures2 = undefined;
            features_2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
            features_2.pNext = &indexing_features;

            c.vkGetPhysicalDeviceProperties(device, &properties);
            c.vkGetPhysicalDeviceFeatures2(device, &features_2);

            const supports_bindless_descriptors = indexing_features.descriptorBindingPartiallyBound == c.VK_TRUE and indexing_features.runtimeDescriptorArray == c.VK_TRUE and indexing_features.descriptorBindingSampledImageUpdateAfterBind == c.VK_TRUE;
            if (properties.deviceType != c.VK_PHYSICAL_DEVICE_TYPE_CPU and supports_bindless_descriptors) {
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

        try ensure_device_extensions_are_available(physical_device, allocator);

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

        // Request the features necessary for bindless texturess
        var indexing_features: c.VkPhysicalDeviceDescriptorIndexingFeatures = std.mem.zeroes(c.VkPhysicalDeviceDescriptorIndexingFeatures);
        indexing_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES;
        indexing_features.pNext = null;
        indexing_features.runtimeDescriptorArray = c.VK_TRUE;
        indexing_features.descriptorBindingPartiallyBound = c.VK_TRUE;
        indexing_features.descriptorBindingSampledImageUpdateAfterBind = c.VK_TRUE;

        var features_2: c.VkPhysicalDeviceFeatures2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
        features_2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        features_2.pNext = &indexing_features;

        var features13 = c.VkPhysicalDeviceVulkan13Features{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = &features_2,
            .synchronization2 = c.VK_TRUE,
            .dynamicRendering = c.VK_TRUE,
        };
        const device_create_info = c.VkDeviceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &features13, .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_create_info, .enabledExtensionCount = @intCast(required_device_extensions.len), .ppEnabledExtensionNames = &required_device_extensions };

        var device: c.VkDevice = undefined;
        vk_check(c.vkCreateDevice(physical_device.device, &device_create_info, null, &device), "Failed to create device");

        var queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, graphics_qfi.?, 0, &queue);

        return .{
            .handle = device,
            .queue = VkQueue{ .handle = queue, .qfi = graphics_qfi.? },
        };
    }

    fn create_buffer(this: *Renderer, info: Buffer.CreateInfo) !BufferAllocation {
        var usage: u32 = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        if (info.flags.transfer_src) {
            usage |= c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        }
        if (info.flags.vertex_buffer) {
            usage |= c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
        }
        if (info.flags.uniform_buffer) {
            usage |= c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        }
        if (info.flags.storage_buffer) {
            usage |= c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        }

        const buffer_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .usage = usage,
            .flags = 0,
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &[_]u32{this.device.queue.qfi},
            .size = info.size,
        };

        var buffer = std.mem.zeroes(c.VkBuffer);
        var alloc_info = std.mem.zeroes(c.VmaAllocationCreateInfo);
        alloc_info.usage = if (info.flags.cpu_readable) c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST else c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE;
        alloc_info.flags = if (info.flags.cpu_readable) c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT | c.VMA_ALLOCATION_CREATE_MAPPED_BIT else 0;
        var allocation: c.VmaAllocation = undefined;
        vk_check(c.vmaCreateBuffer(this.vk_allocator, &buffer_info, &alloc_info, &buffer, &allocation, null), "Failed to create buffer");

        return .{
            .buffer = buffer,
            .allocation = allocation,
        };
    }

    fn allocate_oneshot_command_buffer(this: *Renderer) !c.VkCommandBuffer {
        var cmd_buffers = [1]c.VkCommandBuffer{undefined};
        vk_check(c.vkAllocateCommandBuffers(this.device.handle, &c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = this.render_states[this.current_render_state].command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        }, &cmd_buffers), "Failed to allocate command buffer");

        vk_check(c.vkBeginCommandBuffer(cmd_buffers[0], &c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }), "Failed to begin command buffer");
        return cmd_buffers[0];
    }

    const TransitionInfo = struct {
        layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        pipeline_flags: c.VkPipelineStageFlags2 = 0,
        access_flags: c.VkAccessFlags2 = 0,
    };

    const ImageWithSubresource = struct {
        image: c.VkImage,
        subresource: c.VkImageSubresourceRange,
    };

    fn quick_transition_image(cmd_buf: c.VkCommandBuffer, image: ImageWithSubresource, source_image_info: TransitionInfo, dest_image_info: TransitionInfo) void {
        const image_barriers = [_]c.VkImageMemoryBarrier2{c.VkImageMemoryBarrier2{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .image = image.image,
            .oldLayout = source_image_info.layout,
            .srcAccessMask = source_image_info.access_flags,
            .srcStageMask = source_image_info.pipeline_flags,
            .newLayout = dest_image_info.layout,
            .dstAccessMask = dest_image_info.access_flags,
            .dstStageMask = dest_image_info.pipeline_flags,
            .subresourceRange = image.subresource,
        }};
        const dep_flags = c.VK_DEPENDENCY_BY_REGION_BIT;
        const dep_info = c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .bufferMemoryBarrierCount = 0,
            .memoryBarrierCount = 0,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &image_barriers,
            .dependencyFlags = dep_flags,
        };
        c.vkCmdPipelineBarrier2(cmd_buf, &dep_info);
    }

    fn submit_oneshot_command_buffer(this: *Renderer, free_command_buffer: bool, cmd_buf: c.VkCommandBuffer) void {
        vk_check(c.vkEndCommandBuffer(cmd_buf), "Failed to end command buffer");

        vk_check(c.vkQueueSubmit2(this.device.queue.handle, 1, &[1]c.VkSubmitInfo2{c.VkSubmitInfo2{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &[1]c.VkCommandBufferSubmitInfo{c.VkCommandBufferSubmitInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                .commandBuffer = cmd_buf,
                .deviceMask = 0,
            }},
            .pWaitSemaphoreInfos = null,
            .pSignalSemaphoreInfos = null,
        }}, null), "Failed to submit cbuffer");

        if (free_command_buffer) {
            vk_check(c.vkDeviceWaitIdle(this.device.handle), "Failed to wait device idle");
            c.vkFreeCommandBuffers(this.device.handle, this.render_states[this.current_render_state].command_pool, 1, &[_]c.VkCommandBuffer{cmd_buf});
        }
    }

    fn create_staging_buffer(this: *Renderer, size: u64) !BufferAllocation {
        return this.create_buffer(.{ .size = size, .flags = BufferFlags{
            .cpu_readable = true,
            .transfer_src = true,
        } });
    }
};

fn ensure_device_extensions_are_available(device: VkPhysicalDevice, allocator: Allocator) !void {
    var supported_extension_count: u32 = undefined;
    vk_check(c.vkEnumerateDeviceExtensionProperties(device.device, null, &supported_extension_count, null), "Failed to enumerate supported device extensions");
    const extensions = try allocator.alloc(c.VkExtensionProperties, supported_extension_count);
    vk_check(c.vkEnumerateDeviceExtensionProperties(device.device, null, &supported_extension_count, extensions.ptr), "Failed to get supported extensions");

    outer: for (required_device_extensions) |ext| {
        std.log.debug("Checking extension {s}", .{ext});
        const ext_zig = std.mem.span(ext);
        for (extensions) |dev_ext| {
            const dev_ext_zig_len = std.mem.len(@as([*:0]u8, @ptrCast(@constCast(&dev_ext.extensionName))));
            const dev_ext_zig = dev_ext.extensionName[0..dev_ext_zig_len];
            if (std.mem.eql(u8, dev_ext_zig, ext_zig)) {
                continue :outer;
            }
        }

        std.log.err("Device extension not supported {s}", .{ext});
        return error.DeviceExtensionNotSupported;
    }
}

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

pub fn vk_check(expr: c.VkResult, comptime errmsg: []const u8) void {
    if (expr != c.VK_SUCCESS) {
        vulkan_init_failure(errmsg);
    }
}

fn unopt(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .Optional) @compileError("T must be optional!");
    return info.Optional.child;
}

fn loadFunc(instance: c.VkInstance, comptime T: type, comptime funcname: [*c]const u8) T {
    const func: T = @ptrCast(c.vkGetInstanceProcAddr(instance, funcname));
    return func;
}

fn loadFuncAssert(instance: c.VkInstance, comptime T: type, comptime funcname: [*c]const u8) unopt(T) {
    return loadFunc(instance, T, funcname).?;
}

const DebugUtilsMessengerExt = struct {
    create_debug_messenger: unopt(c.PFN_vkCreateDebugUtilsMessengerEXT),
    destroy_debug_messenger: unopt(c.PFN_vkDestroyDebugUtilsMessengerEXT),
    instance: c.VkDebugUtilsMessengerEXT,

    fn init(instance: c.VkInstance) ?DebugUtilsMessengerExt {
        const debug_utils = c.VkDebugUtilsMessengerCreateInfoEXT{ .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT, .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT, .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT, .pfnUserCallback = message_callback };
        const create_debug_messenger = loadFuncAssert(instance, c.PFN_vkCreateDebugUtilsMessengerEXT, "vkCreateDebugUtilsMessengerEXT");
        const destroy_debug_messenger = loadFuncAssert(instance, c.PFN_vkDestroyDebugUtilsMessengerEXT, "vkDestroyDebugUtilsMessengerEXT");
        var debug_utils_messenger: c.VkDebugUtilsMessengerEXT = undefined;
        vk_check(create_debug_messenger(instance, &debug_utils, null, &debug_utils_messenger), "Failed to create debug messenger");
        return .{
            .create_debug_messenger = create_debug_messenger,
            .destroy_debug_messenger = destroy_debug_messenger,
            .instance = debug_utils_messenger,
        };
    }

    fn deinit(this: *DebugUtilsMessengerExt, instance: c.VkInstance) void {
        this.destroy_debug_messenger(instance, this.instance, null);
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

        const swapchain_create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = surface,
            .minImageCount = Renderer.FRAMES_IN_FLIGHT,
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

        var presentable_images: u32 = undefined;
        vk_check(c.vkGetSwapchainImagesKHR(device, swapchain_instance, &presentable_images, null), "Failed to get the number of presentable images");

        const images = try allocator.alloc(c.VkImage, Renderer.FRAMES_IN_FLIGHT);
        const views = try allocator.alloc(c.VkImageView, Renderer.FRAMES_IN_FLIGHT);
        defer allocator.free(images);
        defer allocator.free(views);

        vk_check(c.vkGetSwapchainImagesKHR(device, swapchain_instance, &presentable_images, images.ptr), "Failed to get images from swapchain");

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

const RenderState = struct {
    command_pool: c.VkCommandPool,
    work_done_fence: c.VkFence,
    main_command_buffer: c.VkCommandBuffer,

    fn init(device: VkDevice) !RenderState {
        var command_pool: c.VkCommandPool = undefined;
        vk_check(c.vkCreateCommandPool(device.handle, &c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .pNext = null, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = device.queue.qfi }, null, &command_pool), "Failed to create RenderState command pool");

        var command_buffer: c.VkCommandBuffer = undefined;
        vk_check(c.vkAllocateCommandBuffers(device.handle, &[_]c.VkCommandBufferAllocateInfo{
            c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .pNext = null, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandPool = command_pool, .commandBufferCount = 1 },
        }, &command_buffer), "Failed to allocate main command buffer");

        return .{
            .command_pool = command_pool,
            .work_done_fence = try make_fence(device.handle, true),
            .main_command_buffer = command_buffer,
        };
    }

    fn start_frame(this: *RenderState, device: VkDevice) void {
        vk_check(c.vkWaitForFences(device.handle, 1, &[_]c.VkFence{this.work_done_fence}, c.VK_TRUE, std.math.maxInt(u64)), "Could not wait for work done fence");
        vk_check(c.vkResetFences(device.handle, 1, &[_]c.VkFence{this.work_done_fence}), "Could not reset work done fence");
        const command_buffer_begin = c.VkCommandBufferBeginInfo{ .pNext = null, .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = 0, .pInheritanceInfo = null };

        vk_check(c.vkBeginCommandBuffer(this.main_command_buffer, &[_]c.VkCommandBufferBeginInfo{command_buffer_begin}), "Failed to begin command buffer");
    }

    fn end_frame(this: *RenderState, device: VkDevice) void {
        vk_check(c.vkEndCommandBuffer(this.main_command_buffer), "Failed to end main command buffer");
        const cmd_buf_info = c.VkCommandBufferSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .pNext = null, .deviceMask = 0, .commandBuffer = this.main_command_buffer };
        const submit_info = c.VkSubmitInfo2{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2, .flags = 0, .waitSemaphoreInfoCount = 0, .pWaitSemaphoreInfos = null, .commandBufferInfoCount = 1, .pCommandBufferInfos = &[_]c.VkCommandBufferSubmitInfo{cmd_buf_info}, .signalSemaphoreInfoCount = 0, .pSignalSemaphoreInfos = null };
        vk_check(c.vkQueueSubmit2(device.queue.handle, 1, &[_]c.VkSubmitInfo2{submit_info}, this.work_done_fence), "Failed to submit to main queue");
    }

    fn deinit(this: *RenderState, device: VkDevice) void {
        c.vkFreeCommandBuffers(device.handle, this.command_pool, 1, &[_]c.VkCommandBuffer{this.main_command_buffer});
        c.vkDestroyFence(device.handle, this.work_done_fence, null);
        c.vkDestroyCommandPool(device.handle, this.command_pool, null);
    }
};

const Textures = std.ArrayList(?Texture);
const TextureAllocation = struct { texture: Texture, handle: TextureHandle };

const TextureAllocator = struct {
    const num_descriptors: u32 = 16536;
    const bindless_textures_binding: u32 = 0;

    all_textures: Textures,

    bindless_descriptor_set: c.VkDescriptorSet,
    bindless_descriptor_set_layout: c.VkDescriptorSetLayout,
    bindless_descriptor_pool: c.VkDescriptorPool,

    nearest_sampler: c.VkSampler,

    allocator: Allocator,
    vk_allocator: c.VmaAllocator,
    unused_handles: std.ArrayList(TextureHandle),
    updates: std.ArrayList(BindlessSetUpdate),

    fn init(device: VkDevice, allocator: Allocator, vma: c.VmaAllocator) !TextureAllocator {
        var layout: c.VkDescriptorSetLayout = undefined;
        const bindings = [_]c.VkDescriptorSetLayoutBinding{c.VkDescriptorSetLayoutBinding{
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = num_descriptors,
            .binding = bindless_textures_binding,
            .stageFlags = c.VK_SHADER_STAGE_ALL,
            .pImmutableSamplers = null,
        }};

        const bindless_flags: u32 = @intCast(c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT | c.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT);
        const bindless_info = c.VkDescriptorSetLayoutBindingFlagsCreateInfoEXT{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, .pNext = null, .bindingCount = 1, .pBindingFlags = &bindless_flags };

        const info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = &bindless_info,
            .flags = c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT,
            .pBindings = &bindings,
            .bindingCount = @intCast(bindings.len),
        };

        vk_check(c.vkCreateDescriptorSetLayout(device.handle, &info, null, &layout), "Failed to create vk descriptor set layout");

        const pool_sizes = [_]c.VkDescriptorPoolSize{c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = num_descriptors,
        }};
        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .flags = c.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT,
            .maxSets = 4,
            .poolSizeCount = @intCast(pool_sizes.len),
            .pPoolSizes = &pool_sizes,
        };
        var descriptor_pool: c.VkDescriptorPool = undefined;
        vk_check(c.vkCreateDescriptorPool(device.handle, &pool_info, null, &descriptor_pool), "Failed to create bindless descriptor pool");

        const max_bindings = num_descriptors - 1;
        const bindless_set_info = c.VkDescriptorSetVariableDescriptorCountAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
            .pNext = null,
            .descriptorSetCount = 1,
            .pDescriptorCounts = &max_bindings,
        };
        const alloc_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = &bindless_set_info,
            .descriptorSetCount = 1,
            .descriptorPool = descriptor_pool,
            .pSetLayouts = &layout,
        };
        var descriptor_set: c.VkDescriptorSet = null;
        vk_check(c.vkAllocateDescriptorSets(device.handle, &alloc_info, &descriptor_set), "Failed to allocate bindless descriptor set");

        var nearest_sampler: c.VkSampler = undefined;
        const sampler_create = c.VkSamplerCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .magFilter = c.VK_FILTER_NEAREST,
            .minFilter = c.VK_FILTER_NEAREST,
            .maxLod = std.math.floatMax(f32),
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        };
        vk_check(c.vkCreateSampler(device.handle, &sampler_create, null, &nearest_sampler), "Failed to create nearest sampler");

        return .{
            .all_textures = Textures.init(allocator),
            .bindless_descriptor_set = descriptor_set,
            .bindless_descriptor_set_layout = layout,
            .bindless_descriptor_pool = descriptor_pool,

            .allocator = allocator,
            .vk_allocator = vma,
            .unused_handles = std.ArrayList(TextureHandle).init(allocator),
            .updates = std.ArrayList(BindlessSetUpdate).init(allocator),
            .nearest_sampler = nearest_sampler,
        };
    }

    fn alloc_texture(this: *TextureAllocator, device: VkDevice, sam_allocator: *sampler_allocator.SamplerAllocator, description: Texture.CreateInfo) !TextureAllocation {
        var texture_handle: TextureHandle = undefined;
        var texture: *?Texture = undefined;

        const sampler = try sam_allocator.get(description.sampler_config);

        if (this.unused_handles.items.len > 0) {
            texture_handle = this.unused_handles.pop();
            texture = &this.all_textures.items[texture_handle.id];
        } else {
            const len = this.all_textures.items.len;
            texture = try this.all_textures.addOne();
            texture_handle = TextureHandle{
                .id = @intCast(len),
            };
        }

        const usage: u32 = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        const format = switch (description.format) {
            .rgba_8 => c.VK_FORMAT_R8G8B8A8_UINT,
        };
        const image_type = c.VK_IMAGE_TYPE_2D;
        const image_desc = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .extent = c.VkExtent3D{
                .width = description.width,
                .height = description.height,
                .depth = description.depth,
            },
            .usage = usage,
            .tiling = if (description.flags.cpu_readable) c.VK_IMAGE_TILING_LINEAR else c.VK_IMAGE_TILING_OPTIMAL,
            .format = format,
            .imageType = image_type,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .mipLevels = 1,
            .arrayLayers = 1,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .pQueueFamilyIndices = &[_]u32{device.queue.qfi},
            .queueFamilyIndexCount = 1,
        };

        var image = std.mem.zeroes(c.VkImage);

        const mem_alloc_info = c.VmaAllocationCreateInfo{ .flags = 0, .usage = c.VMA_MEMORY_USAGE_AUTO, .memoryTypeBits = 0, .requiredFlags = 0 };
        var allocation = std.mem.zeroes(c.VmaAllocation);
        vk_check(c.vmaCreateImage(this.vk_allocator, &image_desc, &mem_alloc_info, &image, &allocation, null), "Failed to create image through vma");

        const image_view_desc = c.VkImageViewCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .pNext = null, .image = image, .format = format, .flags = 0, .components = c.VkComponentMapping{
            .r = c.VK_COMPONENT_SWIZZLE_R,
            .g = c.VK_COMPONENT_SWIZZLE_G,
            .b = c.VK_COMPONENT_SWIZZLE_B,
            .a = c.VK_COMPONENT_SWIZZLE_A,
        }, .viewType = c.VK_IMAGE_VIEW_TYPE_2D, .subresourceRange = c.VkImageSubresourceRange{ .layerCount = 1, .levelCount = 1, .baseMipLevel = 0, .baseArrayLayer = 0, .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT } };
        var image_view = std.mem.zeroes(c.VkImageView);
        vk_check(c.vkCreateImageView(device.handle, &image_view_desc, null, &image_view), "Could not create image view");

        texture.* = Texture{
            .handle = texture_handle,
            .view = image_view,
            .image = image,
            .sampler = sampler,
            .allocation = allocation,
        };

        try this.add_write_texture_to_descriptor_set(texture.*.?, texture_handle.id);
        return TextureAllocation{
            .handle = texture_handle,
            .texture = texture.*.?,
        };
    }

    const BindlessSetUpdate = struct {
        view: c.VkImageView,
        sampler: c.VkSampler,
        position_in_array: u32,
    };

    fn add_write_texture_to_descriptor_set(this: *TextureAllocator, texture: Texture, position_in_array: u32) !void {
        try this.updates.append(BindlessSetUpdate{
            .view = texture.view,
            .sampler = texture.sampler,
            .position_in_array = position_in_array,
        });
    }

    fn flush_updates(this: *TextureAllocator, device: VkDevice) !void {
        if (this.updates.items.len == 0) {
            return;
        }

        const image_infos = try this.allocator.alloc(c.VkDescriptorImageInfo, this.updates.items.len);
        const writes = try this.allocator.alloc(c.VkWriteDescriptorSet, this.updates.items.len);
        defer this.allocator.free(image_infos);
        defer this.allocator.free(writes);
        defer this.updates.clearRetainingCapacity();

        for (this.updates.items, 0..) |update, i| {
            image_infos[i] = c.VkDescriptorImageInfo{
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .imageView = update.view,
                .sampler = update.sampler,
            };

            writes[i] = c.VkWriteDescriptorSet{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstArrayElement = update.position_in_array, .dstSet = this.bindless_descriptor_set, .dstBinding = TextureAllocator.bindless_textures_binding, .pTexelBufferView = null, .pBufferInfo = null, .pImageInfo = &image_infos[i], .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER };
        }

        c.vkUpdateDescriptorSets(device.handle, @intCast(this.updates.items.len), writes.ptr, 0, null);
    }

    fn free_texture(this: *TextureAllocator, device: VkDevice, tex_handle: TextureHandle) void {
        const texture = this.all_textures.items[tex_handle.id].?;
        this.all_textures.items[tex_handle.id] = null;

        c.vkDestroyImageView(device.handle, texture.view, null);
        c.vmaDestroyImage(this.vk_allocator, texture.image, texture.allocation);
    }

    fn deinit(this: *TextureAllocator, device: VkDevice) void {
        for (this.all_textures.items) |tex_maybe| {
            if (tex_maybe) |*tex| {
                this.free_texture(device, tex.handle);
            }
        }

        c.vkDestroySampler(device.handle, this.nearest_sampler, null);
        c.vkDestroyDescriptorSetLayout(device.handle, this.bindless_descriptor_set_layout, null);
        c.vkDestroyDescriptorPool(device.handle, this.bindless_descriptor_pool, null);
    }
};

const BufferAllocation = struct {
    buffer: c.VkBuffer,
    allocation: c.VmaAllocation,
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
