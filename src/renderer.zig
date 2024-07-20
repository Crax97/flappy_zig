// const std = @import("std");
// const sdl = @import("sdl2");
// const sdl_util = @import("sdl_util.zig");
// const vk = @import("vk");
// const Window = @import("window.zig").Window;
// const Allocator = std.mem.Allocator;

// const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
// const apis: []const vk.ApiInfo = &.{
//     vk.features.version_1_0,
//     vk.features.version_1_1,
//     vk.features.version_1_2,
//     vk.features.version_1_3,
//     vk.extensions.khr_surface,
//     vk.extensions.khr_swapchain,
//     vk.extensions.ext_debug_utils,
// };

// const BaseDispatch = vk.BaseWrapper(apis);
// const InstanceDispatch = vk.InstanceWrapper(apis);
// const DeviceDispatch = vk.DeviceWrapper(apis);
// // Also create some proxying wrappers, which also have the respective handles
// const Instance = vk.InstanceProxy(apis);
// const Device = vk.DeviceProxy(apis);

// const VkPhysicalDevice = struct {
//     device: vk.PhysicalDevice,
//     properties: vk.PhysicalDeviceProperties,
//     device_memory: vk.PhysicalDeviceMemoryProperties,
// };

// const VkQueue = struct {
//     handle: vk.Queue,
//     qfi: u32,
// };

// const VkDevice = struct {
//     handle: Device,
//     queue: VkQueue,
// };
// const SwapchainImage = struct {
//     image: vk.Image,
//     view: vk.ImageView,
// };

// pub const TextureFormat = enum {
//     rgba_8,
// };

// pub const TextureFlags = packed struct {};

// pub const Texture = struct {
//     pub const CreateInfo = struct {
//         width: usize,
//         height: usize,
//         format: TextureFormat,
//         initial_bytes: ?[]const u8,
//         flags: TextureFlags = .{},
//     };
//     image: vk.Image,
//     view: vk.ImageView,
// };

// const Swapchain = struct {
//     handle: ?vk.SwapchainKHR = null,
//     images: []SwapchainImage = &[0]SwapchainImage{},
//     format: vk.SurfaceFormatKHR = undefined,
//     present_mode: vk.PresentModeKHR = undefined,
//     extents: vk.Extent2D = undefined,
//     current_image: u32 = undefined,

//     acquire_fence: vk.Fence = vk.Fence.null_handle,

//     fn init(this: *Swapchain, instance: Instance, physical_device: vk.PhysicalDevice, device: Device, surface: vk.SurfaceKHR, queue: vk.Queue, qfi: u32, allocator: Allocator) !void {
//         this.deinit(device, allocator);
//         if (this.images.len > 0) {
//             allocator.free(this.images);
//         }

//         const acquire_fence = try make_fence(device, false);

//         const surface_info = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);
//         const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, allocator);
//         defer allocator.free(surface_formats);

//         const img_format = surface_formats[0];
//         const present_mode = vk.PresentModeKHR.fifo_khr;
//         const flags = vk.ImageUsageFlags{
//             .sampled_bit = true,
//             .transfer_src_bit = true,
//             .transfer_dst_bit = true,
//             .color_attachment_bit = true,
//         };

//         var image_count: u32 = 3;

//         const swapchain_create_info = vk.SwapchainCreateInfoKHR{
//             .s_type = vk.StructureType.swapchain_create_info_khr,
//             .surface = surface,
//             .min_image_count = image_count,
//             .image_format = img_format.format,
//             .image_color_space = img_format.color_space,
//             .image_sharing_mode = vk.SharingMode.exclusive,
//             .queue_family_index_count = 1,
//             .p_queue_family_indices = &[1]u32{qfi},
//             .image_usage = flags,
//             .clipped = vk.TRUE,
//             .pre_transform = surface_info.current_transform,
//             .image_extent = surface_info.current_extent,
//             .image_array_layers = 1,
//             .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
//             .present_mode = present_mode,
//         };

//         const swapchain_instance = try device.createSwapchainKHR(&swapchain_create_info, null);
//         errdefer device.destroySwapchainKHR(swapchain_instance, null);
//         this.* = Swapchain{ .handle = swapchain_instance, .current_image = 0, .extents = swapchain_create_info.image_extent, .format = img_format, .images = try allocator.alloc(SwapchainImage, 3), .present_mode = present_mode, .acquire_fence = acquire_fence };

//         const images = try allocator.alloc(vk.Image, image_count);
//         const views = try allocator.alloc(vk.ImageView, image_count);
//         defer allocator.free(images);
//         defer allocator.free(views);

//         if (try device.getSwapchainImagesKHR(swapchain_instance, &image_count, images.ptr) != vk.Result.success) {
//             vulkan_init_failure("Failed to get swapchain images!");
//         }

//         const cmd_pool = try device.createCommandPool(&vk.CommandPoolCreateInfo{ .s_type = vk.StructureType.command_pool_create_info, .flags = vk.CommandPoolCreateFlags{ .reset_command_buffer_bit = true }, .queue_family_index = qfi }, null);
//         defer device.destroyCommandPool(cmd_pool, null);

//         var cmd_buffers = [1]vk.CommandBuffer{vk.CommandBuffer.null_handle};
//         try device.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
//             .s_type = vk.StructureType.command_buffer_allocate_info,
//             .command_pool = cmd_pool,
//             .level = vk.CommandBufferLevel.primary,
//             .command_buffer_count = 1,
//         }, &cmd_buffers);

//         try device.beginCommandBuffer(cmd_buffers[0], &vk.CommandBufferBeginInfo{
//             .s_type = vk.StructureType.command_buffer_begin_info,
//             .flags = vk.CommandBufferUsageFlags{ .one_time_submit_bit = true },
//         });

//         const image_mem_barriers = try allocator.alloc(vk.ImageMemoryBarrier2, images.len);
//         defer allocator.free(image_mem_barriers);

//         for (images, 0..) |image, i| {
//             const subresource_range = vk.ImageSubresourceRange{ .aspect_mask = vk.ImageAspectFlags{ .color_bit = true }, .base_array_layer = 0, .base_mip_level = 0, .layer_count = 1, .level_count = 1 };
//             const view = try device.createImageView(&vk.ImageViewCreateInfo{ .s_type = vk.StructureType.image_view_create_info, .image = image, .format = img_format.format, .subresource_range = subresource_range, .view_type = vk.ImageViewType.@"2d", .components = vk.ComponentMapping{
//                 .a = vk.ComponentSwizzle.a,
//                 .r = vk.ComponentSwizzle.r,
//                 .g = vk.ComponentSwizzle.g,
//                 .b = vk.ComponentSwizzle.b,
//             } }, null);
//             this.images[i] = .{ .image = image, .view = view };
//             image_mem_barriers[i] = vk.ImageMemoryBarrier2{
//                 .s_type = vk.StructureType.image_memory_barrier_2,
//                 .image = image,
//                 .new_layout = vk.ImageLayout.present_src_khr,
//                 .old_layout = vk.ImageLayout.undefined,
//                 .subresource_range = subresource_range,
//                 .src_queue_family_index = qfi,
//                 .dst_queue_family_index = qfi,
//                 .src_access_mask = vk.AccessFlags2{},
//                 .src_stage_mask = vk.PipelineStageFlags2{},
//                 .dst_access_mask = vk.AccessFlags2{},
//                 .dst_stage_mask = vk.PipelineStageFlags2{
//                     .bottom_of_pipe_bit = true,
//                 },
//             };
//         }
//         device.cmdPipelineBarrier2(cmd_buffers[0], &vk.DependencyInfo{
//             .s_type = vk.StructureType.dependency_info,
//             .buffer_memory_barrier_count = 0,
//             .memory_barrier_count = 0,
//             .image_memory_barrier_count = @intCast(image_mem_barriers.len),
//             .p_image_memory_barriers = image_mem_barriers.ptr,
//         });
//         try device.endCommandBuffer(cmd_buffers[0]);

//         try device.queueSubmit2(queue, 1, &[1]vk.SubmitInfo2{vk.SubmitInfo2{
//             .s_type = vk.StructureType.submit_info_2,
//             .command_buffer_info_count = 1,
//             .p_command_buffer_infos = &[1]vk.CommandBufferSubmitInfo{vk.CommandBufferSubmitInfo{
//                 .s_type = vk.StructureType.command_buffer_submit_info,
//                 .command_buffer = cmd_buffers[0],
//                 .device_mask = 0,
//             }},
//             .p_wait_semaphore_infos = null,
//             .p_signal_semaphore_infos = null,
//         }}, vk.Fence.null_handle);
//         try device.deviceWaitIdle();
//         try device.resetCommandPool(cmd_pool, vk.CommandPoolResetFlags{ .release_resources_bit = true });
//     }

//     fn deinit(this: *Swapchain, device: Device, allocator: Allocator) void {
//         if (this.handle == null) {
//             return;
//         }

//         device.destroyFence(this.acquire_fence, null);
//         defer allocator.free(this.images);
//         for (this.images) |image| {
//             device.destroyImageView(image.view, null);
//         }
//         device.destroySwapchainKHR(this.handle.?, null);
//     }

//     fn acquire_next_image(this: *Swapchain, device: Device) !void {
//         std.debug.assert(this.acquire_fence != vk.Fence.null_handle);
//         const acquire = try device.acquireNextImageKHR(this.handle.?, std.math.maxInt(u64), vk.Semaphore.null_handle, this.acquire_fence);
//         const fences = [1]vk.Fence{this.acquire_fence};
//         if (try device.waitForFences(1, &fences, vk.TRUE, std.math.maxInt(u64)) != vk.Result.success) {
//             vulkan_init_failure("Failed to acquire swapchain next image!");
//         }

//         try device.resetFences(1, &fences);

//         this.current_image = acquire.image_index;
//     }

//     fn present(this: *Swapchain, device: Device, queue: vk.Queue) !void {
//         const present_info = vk.PresentInfoKHR{
//             .s_type = vk.StructureType.present_info_khr,
//             .p_image_indices = &[1]u32{this.current_image},
//             .p_results = null,
//             .p_swapchains = &[1]vk.SwapchainKHR{this.handle.?},
//             .swapchain_count = 1,
//             .p_wait_semaphores = null,
//             .wait_semaphore_count = 0,
//         };
//         const result = try device.queuePresentKHR(queue, &present_info);
//         if (result != vk.Result.success) {
//             vulkan_init_failure("Failed to present acquired image");
//         }
//     }
// };

// const TextureDrawInfo = struct {
//     texture: Texture,
// };

// const RenderTextures = std.ArrayList(TextureDrawInfo);
// const RenderList = struct {
//     textures: RenderTextures,

//     fn init(allocator: Allocator) RenderList {
//         return .{
//             .textures = RenderTextures.init(allocator),
//         };
//     }

//     fn clear(this: *RenderList) void {
//         this.textures.clearRetainingCapacity();
//     }
// };

// pub const Renderer = struct {
//     instance: Instance,
//     surface: vk.SurfaceKHR,
//     physical_device: VkPhysicalDevice,
//     device: VkDevice,
//     swapchain: Swapchain,

//     debug_utils_messenger: vk.DebugUtilsMessengerEXT,

//     allocator: Allocator,

//     render_list: RenderList,

//     pub fn init(window: *Window, allocator: Allocator) !Renderer {
//         const vk_loader = sdl.SDL_Vulkan_GetVkGetInstanceProcAddr().?;
//         const vkb = try BaseDispatch.load(vk_loader);
//         const instance = try create_vulkan_instance(&vkb, window.window, allocator);
//         errdefer instance.destroyInstance(null);

//         const debug_utils = vk.DebugUtilsMessengerCreateInfoEXT{ .s_type = vk.StructureType.debug_utils_messenger_create_info_ext, .message_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
//             .error_bit_ext = true,
//             .info_bit_ext = true,
//             .verbose_bit_ext = true,
//             .warning_bit_ext = true,
//         }, .message_type = vk.DebugUtilsMessageTypeFlagsEXT{
//             .general_bit_ext = true,
//             .performance_bit_ext = true,
//             .validation_bit_ext = true,
//         }, .pfn_user_callback = message_callback };
//         const debug_utils_messenger = try instance.createDebugUtilsMessengerEXT(&debug_utils, null);

//         const surface = try create_vulkan_surface(window.window, instance);
//         errdefer instance.destroySurfaceKHR(surface, null);

//         const physical_device = try select_physical_device(instance, allocator);
//         const device = try init_logical_device(instance, physical_device, surface, allocator);
//         errdefer device.handle.destroyDevice(null);

//         var swapchain = Swapchain{};
//         try swapchain.init(instance, physical_device.device, device.handle, surface, device.queue.handle, device.queue.qfi, allocator);

//         std.log.info("Picked device {s}\n", .{physical_device.properties.device_name});

//         return .{
//             .instance = instance,
//             .debug_utils_messenger = debug_utils_messenger,
//             .surface = surface,
//             .physical_device = physical_device,
//             .device = device,
//             .swapchain = swapchain,
//             .allocator = allocator,

//             .render_list = RenderList.init(allocator),
//         };
//     }

//     pub fn deinit(this: *Renderer) void {
//         this.swapchain.deinit(this.device.handle, this.allocator);
//         this.instance.destroySurfaceKHR(this.surface, null);
//         this.device.handle.destroyDevice(null);
//         this.instance.destroyDebugUtilsMessengerEXT(this.debug_utils_messenger, null);
//         this.instance.destroyInstance(null);
//     }

//     pub fn start_rendering(this: *Renderer) !void {
//         this.render_list.clear();
//         try this.swapchain.acquire_next_image(this.device.handle);
//     }

//     pub fn render(this: *Renderer) !void {
//         try this.swapchain.present(this.device.handle, this.device.queue.handle);
//     }

//     fn create_vulkan_instance(vkb: *const BaseDispatch, window: *sdl.SDL_Window, allocator: Allocator) !Instance {
//         const vk_loader = sdl.SDL_Vulkan_GetVkGetInstanceProcAddr().?;

//         const app_info = vk.ApplicationInfo{
//             .p_application_name = "EngineApplication",
//             .p_engine_name = "Engine",
//             .api_version = vk.API_VERSION_1_3,
//             .engine_version = vk.makeApiVersion(0, 0, 0, 0),
//             .application_version = vk.makeApiVersion(0, 0, 0, 0),
//         };
//         var ext_counts: c_uint = 0;
//         if (sdl.SDL_Vulkan_GetInstanceExtensions(window, &ext_counts, null) != sdl.SDL_TRUE) {
//             sdl_util.sdl_panic();
//         }

//         var exts = std.ArrayList([*:0]const u8).init(allocator);
//         defer exts.deinit();
//         _ = try exts.addManyAsSlice(ext_counts);
//         try exts.append(vk.extensions.ext_debug_utils.name);

//         if (sdl.SDL_Vulkan_GetInstanceExtensions(window, &ext_counts, exts.items.ptr) != sdl.SDL_TRUE) {
//             sdl_util.sdl_panic();
//         }

//         const required_layers: [*]const [*:0]const u8 = &.{"VK_LAYER_KHRONOS_validation"};

//         const instance = try vkb.createInstance(&.{
//             .p_application_info = &app_info,
//             .enabled_extension_count = @intCast(exts.items.len),
//             .pp_enabled_extension_names = exts.items.ptr,
//             .enabled_layer_count = 1,
//             .pp_enabled_layer_names = required_layers,
//         }, null);

//         const vki = try allocator.create(InstanceDispatch);
//         errdefer allocator.destroy(vki);

//         vki.* = try InstanceDispatch.load(instance, vk_loader);
//         const vk_inst = Instance.init(instance, vki);

//         return vk_inst;
//     }

//     fn create_vulkan_surface(window: *sdl.SDL_Window, instance: Instance) !vk.SurfaceKHR {
//         var surface: vk.SurfaceKHR = undefined;
//         if (sdl.SDL_Vulkan_CreateSurface(window, instance.handle, &surface) != sdl.SDL_TRUE) {
//             sdl_util.sdl_panic();
//         }
//         return surface;
//     }

//     fn select_physical_device(instance: Instance, allocator: Allocator) !VkPhysicalDevice {
//         const funcs = struct {
//             const SortContext = struct {
//                 instance: Instance,
//             };
//             fn device_ty_priority(device_type: vk.PhysicalDeviceType) usize {
//                 return switch (device_type) {
//                     vk.PhysicalDeviceType.discrete_gpu => 3,
//                     vk.PhysicalDeviceType.integrated_gpu => 2,
//                     vk.PhysicalDeviceType.virtual_gpu => 1,
//                     else => 0,
//                 };
//             }
//             fn sort_physical_devices(context: SortContext, a: vk.PhysicalDevice, b: vk.PhysicalDevice) bool {
//                 const props_a = context.instance.getPhysicalDeviceProperties(a);
//                 const props_b = context.instance.getPhysicalDeviceProperties(b);

//                 const device_ty_a = device_ty_priority(props_a.device_type);
//                 const device_ty_b = device_ty_priority(props_b.device_type);

//                 return device_ty_a > device_ty_b;
//             }
//         };
//         var pdevice_count: u32 = undefined;
//         if (try instance.enumeratePhysicalDevices(&pdevice_count, null) != vk.Result.success) {
//             vulkan_init_failure("Failed to count physical devices");
//         }
//         const devices = try allocator.alloc(vk.PhysicalDevice, pdevice_count);
//         defer allocator.free(devices);

//         if (try instance.enumeratePhysicalDevices(&pdevice_count, devices.ptr) != vk.Result.success) {
//             vulkan_init_failure("Failed to enumerate physical devices");
//         }
//         std.mem.sort(vk.PhysicalDevice, devices, funcs.SortContext{ .instance = instance }, funcs.sort_physical_devices);

//         std.log.debug("{d} candidate devices", .{pdevice_count});

//         for (devices, 0..) |device, idx| {
//             const properties = instance.getPhysicalDeviceProperties(device);
//             std.log.debug("\t{d}) Device {s}", .{ idx, properties.device_name });
//         }

//         for (devices) |device| {
//             const properties = instance.getPhysicalDeviceProperties(device);
//             if (properties.device_type != .cpu) {
//                 const device_mem = instance.getPhysicalDeviceMemoryProperties(device);

//                 return .{
//                     .device = device,
//                     .properties = properties,
//                     .device_memory = device_mem,
//                 };
//             }
//         }
//         vulkan_init_failure("Failed to pick valid device");
//     }

//     fn init_logical_device(
//         instance: Instance,
//         physical_device: VkPhysicalDevice,
//         surface: vk.SurfaceKHR,
//         allocator: Allocator,
//     ) !VkDevice {
//         const props = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device.device, allocator);
//         defer allocator.free(props);

//         var graphics_qfi: ?u32 = null;
//         for (props, 0..) |prop, idx| {
//             if (prop.queue_flags.graphics_bit and try instance.getPhysicalDeviceSurfaceSupportKHR(physical_device.device, @intCast(idx), surface) == vk.TRUE) {
//                 graphics_qfi = @intCast(idx);
//             }
//         }

//         if (graphics_qfi == null) {
//             vulkan_init_failure("Failed to pick a vulkan graphics queue");
//         }

//         const prios: [1]f32 = .{1.0};

//         const queue_create_info: [1]vk.DeviceQueueCreateInfo = .{
//             vk.DeviceQueueCreateInfo{
//                 .s_type = vk.StructureType.device_queue_create_info,
//                 .queue_count = 1,
//                 .queue_family_index = graphics_qfi.?,
//                 .p_queue_priorities = &prios,
//             },
//         };

//         var synchronization2 = vk.PhysicalDeviceSynchronization2Features{
//             .p_next = null,
//             .s_type = vk.StructureType.physical_device_synchronization_2_features,
//             .synchronization_2 = vk.TRUE,
//         };
//         var features2 = vk.PhysicalDeviceFeatures2{ .s_type = vk.StructureType.physical_device_features_2, .p_next = &synchronization2, .features = .{} };
//         const device_create_info = vk.DeviceCreateInfo{ .s_type = vk.StructureType.device_create_info, .p_next = &features2, .queue_create_info_count = 1, .p_queue_create_infos = &queue_create_info, .enabled_extension_count = @intCast(required_device_extensions.len), .pp_enabled_extension_names = &required_device_extensions };

//         const device = try instance.createDevice(physical_device.device, &device_create_info, null);
//         const vkd = try allocator.create(DeviceDispatch);
//         errdefer allocator.destroy(vkd);
//         vkd.* = try DeviceDispatch.load(device, instance.wrapper.dispatch.vkGetDeviceProcAddr);
//         const dev = Device.init(device, vkd);
//         const queue = dev.getDeviceQueue(graphics_qfi.?, 0);

//         return .{
//             .handle = dev,
//             .queue = VkQueue{ .handle = queue, .qfi = graphics_qfi.? },
//         };
//     }
// };

// fn message_callback(
//     message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
//     message_types: vk.DebugUtilsMessageTypeFlagsEXT,
//     p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
//     p_user_data: ?*anyopaque,
// ) callconv(vk.vulkan_call_conv) vk.Bool32 {
//     if (p_callback_data == null) {
//         return vk.FALSE;
//     }
//     if (p_callback_data.?.p_message == null) {
//         return vk.FALSE;
//     }
//     _ = p_user_data;
//     const format = "vulkan message: {s}";
//     if (message_severity.info_bit_ext) {
//         std.log.info(format, .{p_callback_data.?.p_message.?});
//     } else if (message_severity.warning_bit_ext) {
//         std.log.warn(format, .{p_callback_data.?.p_message.?});
//     } else if (message_severity.error_bit_ext) {
//         std.log.err(format, .{p_callback_data.?.p_message.?});

//         if (message_types.validation_bit_ext) {
//             std.debug.panic("Vulkan failure", .{});
//         }
//     }
//     return vk.FALSE;
// }

// fn vulkan_init_failure(message: []const u8) noreturn {
//     sdl_util.message_box("Vulkan initialization failed", message, .Error);
//     std.debug.panic("Vulkan  init error", .{});
// }

// fn make_fence(device: Device, signaled: bool) !vk.Fence {
//     return try device.createFence(&vk.FenceCreateInfo{ .s_type = vk.StructureType.fence_create_info, .flags = vk.FenceCreateFlags{ .signaled_bit = signaled } }, null);
// }

// fn make_semaphore(device: Device) !vk.Semaphore {
//     return try device.createSemaphore(&vk.SemaphoreCreateInfo{
//         .s_type = vk.StructureType.semaphore_create_info,
//     }, null);
// }
