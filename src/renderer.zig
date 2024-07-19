const std = @import("std");
const sdl = @import("sdl2");
const sdl_util = @import("sdl_util.zig");
const vk = @import("vk");
const Window = @import("window.zig").Window;
const Allocator = std.mem.Allocator;

const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
};

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);
// Also create some proxying wrappers, which also have the respective handles
const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);

const VkPhysicalDevice = struct {
    device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    device_memory: vk.PhysicalDeviceMemoryProperties,
};

const VkQueue = struct {
    handle: vk.Queue,
    qfi: u32,
};

const VkDevice = struct {
    handle: Device,
    queue: VkQueue,
};

pub const Renderer = struct {
    instance: Instance,
    surface: vk.SurfaceKHR,
    physical_device: VkPhysicalDevice,
    device: VkDevice,

    pub fn init(window: *Window, allocator: Allocator) !Renderer {
        const vk_loader = sdl.SDL_Vulkan_GetVkGetInstanceProcAddr().?;
        const vkb = try BaseDispatch.load(vk_loader);
        const instance = try create_vulkan_instance(&vkb, window.window, allocator);
        errdefer instance.destroyInstance(null);

        const surface = try create_vulkan_surface(window.window, instance);
        errdefer instance.destroySurfaceKHR(surface, null);

        const physical_device = try select_physical_device(instance, allocator);
        const device = try init_logical_device(instance, physical_device, surface, allocator);
        errdefer device.handle.destroyDevice(null);

        std.log.info("Picked device {s}\n", .{physical_device.properties.device_name});

        return .{ .instance = instance, .surface = surface, .physical_device = physical_device, .device = device };
    }

    pub fn deinit(this: *Renderer) void {
        this.instance.destroySurfaceKHR(this.surface, null);
        this.device.handle.destroyDevice(null);
        this.instance.destroyInstance(null);
    }

    fn create_vulkan_instance(vkb: *const BaseDispatch, window: *sdl.SDL_Window, allocator: Allocator) !Instance {
        const vk_loader = sdl.SDL_Vulkan_GetVkGetInstanceProcAddr().?;

        const app_info = vk.ApplicationInfo{
            .p_application_name = "EngineApplication",
            .p_engine_name = "Engine",
            .api_version = vk.API_VERSION_1_3,
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
        };
        var ext_counts: c_uint = 0;
        if (sdl.SDL_Vulkan_GetInstanceExtensions(window, &ext_counts, null) != sdl.SDL_TRUE) {
            sdl_util.sdl_panic();
        }

        var exts = std.ArrayList([*:0]const u8).init(allocator);
        defer exts.deinit();
        _ = try exts.addManyAsSlice(ext_counts);
        try exts.append("VK_EXT_debug_utils");

        if (sdl.SDL_Vulkan_GetInstanceExtensions(window, &ext_counts, exts.items.ptr) != sdl.SDL_TRUE) {
            sdl_util.sdl_panic();
        }

        const instance = try vkb.createInstance(&.{ .p_application_info = &app_info, .enabled_extension_count = @intCast(exts.items.len), .pp_enabled_extension_names = exts.items.ptr }, null);

        const vki = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(vki);

        vki.* = try InstanceDispatch.load(instance, vk_loader);
        const vk_inst = Instance.init(instance, vki);

        return vk_inst;
    }

    fn create_vulkan_surface(window: *sdl.SDL_Window, instance: Instance) !vk.SurfaceKHR {
        var surface: vk.SurfaceKHR = undefined;
        if (sdl.SDL_Vulkan_CreateSurface(window, instance.handle, &surface) != sdl.SDL_TRUE) {
            sdl_util.sdl_panic();
        }
        return surface;
    }

    fn select_physical_device(instance: Instance, allocator: Allocator) !VkPhysicalDevice {
        const funcs = struct {
            const SortContext = struct {
                instance: Instance,
            };
            fn sort_physical_devices(context: SortContext, a: vk.PhysicalDevice, b: vk.PhysicalDevice) bool {
                const props_a = context.instance.getPhysicalDeviceProperties(a);
                const props_b = context.instance.getPhysicalDeviceProperties(b);
                const device_ty_a: usize = switch (props_a.device_type) {
                    vk.PhysicalDeviceType.discrete_gpu => 3,
                    vk.PhysicalDeviceType.integrated_gpu, vk.PhysicalDeviceType.virtual_gpu => 2,
                    else => 1,
                };
                const device_ty_b: usize = switch (props_b.device_type) {
                    vk.PhysicalDeviceType.discrete_gpu => 3,
                    vk.PhysicalDeviceType.integrated_gpu, vk.PhysicalDeviceType.virtual_gpu => 2,
                    else => 1,
                };

                return device_ty_a > device_ty_b;
            }
        };
        var pdevice_count: u32 = undefined;
        if (try instance.enumeratePhysicalDevices(&pdevice_count, null) != vk.Result.success) {
            vulkan_init_failure("Failed to count physical devices");
        }
        const devices = try allocator.alloc(vk.PhysicalDevice, pdevice_count);
        defer allocator.free(devices);
        std.mem.sort(vk.PhysicalDevice, devices, funcs.SortContext{ .instance = instance }, funcs.sort_physical_devices);

        if (try instance.enumeratePhysicalDevices(&pdevice_count, devices.ptr) != vk.Result.success) {
            vulkan_init_failure("Failed to enumerate physical devices");
        }
        std.log.debug("{d} candidate devices", .{pdevice_count});

        for (devices, 0..) |device, idx| {
            const properties = instance.getPhysicalDeviceProperties(device);
            std.log.debug("\t{d}) Device {s}", .{ idx, properties.device_name });
        }

        for (devices) |device| {
            const properties = instance.getPhysicalDeviceProperties(device);
            if (properties.device_type != .cpu) {
                const device_mem = instance.getPhysicalDeviceMemoryProperties(device);

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
        instance: Instance,
        physical_device: VkPhysicalDevice,
        surface: vk.SurfaceKHR,
        allocator: Allocator,
    ) !VkDevice {
        const props = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device.device, allocator);
        defer allocator.free(props);

        var graphics_qfi: ?u32 = null;
        for (props, 0..) |prop, idx| {
            if (prop.queue_flags.graphics_bit and try instance.getPhysicalDeviceSurfaceSupportKHR(physical_device.device, @intCast(idx), surface) == vk.TRUE) {
                graphics_qfi = @intCast(idx);
            }
        }

        if (graphics_qfi == null) {
            vulkan_init_failure("Failed to pick a vulkan graphics queue");
        }

        const prios: [1]f32 = .{1.0};

        const queue_create_info: [1]vk.DeviceQueueCreateInfo = .{
            vk.DeviceQueueCreateInfo{
                .s_type = vk.StructureType.device_queue_create_info,
                .queue_count = 1,
                .queue_family_index = graphics_qfi.?,
                .p_queue_priorities = &prios,
            },
        };

        const device_create_info = vk.DeviceCreateInfo{ .queue_create_info_count = 1, .p_queue_create_infos = &queue_create_info, .enabled_extension_count = @intCast(required_device_extensions.len), .pp_enabled_extension_names = &required_device_extensions };

        const device = try instance.createDevice(physical_device.device, &device_create_info, null);
        const vkd = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(vkd);
        vkd.* = try DeviceDispatch.load(device, instance.wrapper.dispatch.vkGetDeviceProcAddr);
        const dev = Device.init(device, vkd);
        const queue = dev.getDeviceQueue(graphics_qfi.?, 0);

        return .{
            .handle = dev,
            .queue = VkQueue{ .handle = queue, .qfi = graphics_qfi.? },
        };
    }
};

fn vulkan_init_failure(message: []const u8) noreturn {
    sdl_util.message_box("Vulkan initialization failed", message, .Error);
    std.debug.panic("Vulkan  init error", .{});
}
