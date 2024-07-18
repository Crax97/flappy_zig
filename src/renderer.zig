const std = @import("std");
const sdl = @import("sdl2");
const sdl_util = @import("sdl_util.zig");
const vk = @import("vk");
const Window = @import("window.zig").Window;
const Allocator = std.mem.Allocator;

const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
const apis: []const vk.ApiInfo = &.{
    .{
        .base_commands = .{
            .createInstance = true,
        },
        .instance_commands = .{
            .createDevice = true,
        },
    },
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

pub const Renderer = struct {
    instance: Instance,
    // device: Device,

    pub fn init(window: *Window, allocator: Allocator) !Renderer {
        const vk_loader = sdl.SDL_Vulkan_GetVkGetInstanceProcAddr().?;
        const vkb = try BaseDispatch.load(vk_loader);
        const app_info = vk.ApplicationInfo{
            .p_application_name = "EngineApplication",
            .p_engine_name = "Engine",
            .api_version = vk.API_VERSION_1_3,
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
        };

        var ext_counts: c_uint = 0;
        if (sdl.SDL_Vulkan_GetInstanceExtensions(window.window, &ext_counts, null) != sdl.SDL_TRUE) {
            sdl_util.sdl_panic();
        }

        var exts = std.ArrayList([*:0]const u8).init(allocator);
        defer exts.deinit();
        _ = try exts.addManyAsSlice(ext_counts);
        try exts.append("VK_EXT_debug_utils");

        if (sdl.SDL_Vulkan_GetInstanceExtensions(window.window, &ext_counts, exts.items.ptr) != sdl.SDL_TRUE) {
            sdl_util.sdl_panic();
        }

        const instance = try vkb.createInstance(&.{ .p_application_info = &app_info, .enabled_extension_count = @intCast(exts.items.len), .pp_enabled_extension_names = exts.items.ptr }, null);

        const vki = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(vki);

        vki.* = try InstanceDispatch.load(instance, vk_loader);
        const vk_inst = Instance.init(instance, vki);
        errdefer vk_inst.destroyInstance(null);

        return .{
            .instance = vk_inst,
        };
    }

    pub fn deinit(this: *Renderer) void {
        this.instance.destroyInstance(null);
    }
};
