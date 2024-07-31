const std = @import("std");
const math = @import("math");
const sdl_util = @import("sdl_util.zig");
const sampler_allocator = @import("allocators/sampler_allocator.zig");
const rta = @import("allocators/render_target_allocator.zig");
const ta = @import("allocators/texture_allocator.zig");
pub const c = @import("clibs.zig");
const types = @import("types.zig");
const camera = @import("camera.zig");

const Allocator = std.mem.Allocator;

const Texture = types.Texture;
const TextureHandle = types.TextureHandle;
const TextureFlags = types.TextureFlags;
const TextureFormat = types.TextureFormat;
const Buffer = types.Buffer;
const BufferHandle = types.BufferHandle;
const BufferFlags = types.BufferFlags;
const RenderTarget = rta.RenderTarget;
const RenderTargetAllocator = rta.RenderTargetAllocator;
const TextureAllocator = ta.TextureAllocator;
const TextureAllocation = ta.TextureAllocation;

const Vec2 = math.Vec2;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Rect2 = math.Rect2;

const vec3 = math.vec3;

const Camera2D = camera.Camera2D;

const vk_format = types.vk_format;

const shaders = struct {
    const DEFAULT_TEXTURE_VS = @embedFile("renderer/spirv/default_textures.vert.spv");
    const DEFAULT_TEXTURE_FS = @embedFile("renderer/spirv/default_fragment.frag.spv");
};

const required_device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

const WORLD_SCALE: f32 = 1.0;
const INV_WORLD_SCALE: f32 = 1.0 / WORLD_SCALE;

pub const Renderer = struct {
    const FRAMES_IN_FLIGHT = 3;

    const default_color_format = vk_format(TextureFormat.rgba_8);
    const default_depth_format = vk_format(TextureFormat.depth_32);

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

    white_texture: TextureHandle = undefined,

    default_texture_pipeline_layout: c.VkPipelineLayout,
    default_texture_pipeline: c.VkPipeline,

    camera: Camera2D = .{},

    current_render_state: usize = 0,

    pub fn init(window: *c.SDL_Window, allocator: Allocator) !Renderer {
        const instance = try create_vulkan_instance(window, allocator);
        errdefer c.vkDestroyInstance(instance, null);

        const debug_utils = DebugUtilsMessengerExt.init(instance);

        const surface = create_vulkan_surface(window, instance);
        errdefer c.vkDestroySurfaceKHR(instance, surface, null);

        const physical_device = try select_physical_device(instance, allocator);
        const device = try init_logical_device(physical_device, surface, allocator);
        errdefer c.vkDestroyDevice(device.handle, null);

        var swapchain = Swapchain{};
        try swapchain.init(window, instance, physical_device.device, device.handle, surface, device.queue.handle, device.queue.qfi, allocator);

        std.log.info("Picked device {s}\n", .{physical_device.properties.deviceName});

        var vk_allocator: c.VmaAllocator = undefined;

        vk_check(c.vmaCreateAllocator(&c.VmaAllocatorCreateInfo{
            .flags = c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT,
            .device = device.handle,
            .instance = instance,
            .physicalDevice = physical_device.device,
        }, &vk_allocator), "Failed to create vma allocator");

        var render_states = try allocator.alloc(RenderState, Renderer.FRAMES_IN_FLIGHT);
        errdefer allocator.free(render_states);

        const sam_allocator = sampler_allocator.SamplerAllocator.init(allocator, device.handle);
        const texture_allocator = try TextureAllocator.init(device, allocator, vk_allocator);

        for (0..Renderer.FRAMES_IN_FLIGHT) |i| {
            render_states[i] = try RenderState.init(device, allocator, vk_allocator);
        }

        const pipeline_layout = create_pipeline_layout(device, &texture_allocator);

        var inst = Renderer{
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
            .texture_allocator = texture_allocator,
            .sampler_allocator = sam_allocator,

            .default_texture_pipeline_layout = pipeline_layout,
            .default_texture_pipeline = try create_default_texture_graphics_pipeline(device, pipeline_layout),
        };

        try inst.create_defaults();

        return inst;
    }

    fn create_defaults(this: *Renderer) !void {
        this.white_texture = try this.alloc_texture(.{
            .width = 1,
            .height = 1,
            .format = .rgba_8,
            .initial_bytes = &.{ 255, 255, 255, 255 },
            .sampler_config = types.SamplerConfig.NEAREST,
        });
    }

    pub fn deinit(this: *Renderer) void {
        vk_check(c.vkDeviceWaitIdle(this.device.handle), "Failed to wait for device idle in deinit");
        for (0..Renderer.FRAMES_IN_FLIGHT) |i| {
            this.render_states[i].deinit(this.device);
        }

        this.free_texture(this.white_texture);

        c.vkDestroyPipeline(this.device.handle, this.default_texture_pipeline, null);
        c.vkDestroyPipelineLayout(this.device.handle, this.default_texture_pipeline_layout, null);

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

    pub fn alloc_texture(this: *Renderer, description: Texture.CreateInfo) !TextureHandle {
        const allocation = try this.texture_allocator.alloc_texture(this.device, &this.sampler_allocator, description);
        if (description.initial_bytes) |bytes| {
            // TODO: implement better copying strategy
            const texel_size_bytes: u32 = switch (description.format) {
                .r_8 => 1,
                .rgba_8, .depth_32 => 4,
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
                .access_flags = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
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
                .access_flags = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
                .pipeline_flags = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            }, .{
                .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .access_flags = c.VK_ACCESS_2_SHADER_READ_BIT,
                .pipeline_flags = c.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT,
            });

            // it will be resetted by resetCommandPool
            this.submit_oneshot_command_buffer(false, cmd_buf);
            vk_check(c.vkDeviceWaitIdle(this.device.handle), "Failed to wait device idle");
            c.vmaDestroyBuffer(this.vk_allocator, staging_buffer.buffer, staging_buffer.allocation);
        }
        return allocation.handle;
    }

    pub fn free_texture(this: *Renderer, texture: TextureHandle) void {
        this.texture_allocator.free_texture(this.device, texture);
    }

    pub fn start_rendering(this: *Renderer) !void {
        var render_state = &this.render_states[this.current_render_state];
        render_state.start_frame(this.device);
        this.render_list.clear();
        try this.swapchain.acquire_next_image(this.device);
    }

    pub fn draw_texture(this: *Renderer, draw_info: TextureDrawInfo) !void {
        try this.render_list.textures.append(draw_info);
    }

    pub fn draw_rect(this: *Renderer, draw_info: RectDrawInfo) !void {
        try this.draw_texture(TextureDrawInfo{
            .texture = this.white_texture,
            .position = draw_info.rect.offset,
            .scale = draw_info.rect.extent,
            .color = draw_info.color,
            .region = Rect2{ .offset = Vec2.ZERO, .extent = Vec2.ONE },
            .rotation = draw_info.rotation,
            .z_index = draw_info.z_index,
        });
    }

    pub fn render(this: *Renderer, viewport_extents: Vec2) !void {
        var render_state = &this.render_states[this.current_render_state];
        this.update_primitive_buffers(render_state, viewport_extents);

        try this.texture_allocator.flush_updates(this.device);

        const width: u32 = @intFromFloat(viewport_extents.x());
        const height: u32 = @intFromFloat(viewport_extents.y());
        const current_swapchain_img = this.swapchain.images[this.swapchain.current_image];
        const current_render_texture = try render_state.render_target_allocator.get(this.device, .{
            .width = width,
            .height = height,
            .format = .rgba_8,
        });

        const current_depth_attachment = try render_state.render_target_allocator.get(this.device, .{
            .width = width,
            .height = height,
            .format = .depth_32,
        });

        const rendering_info = c.VkRenderingInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = c.VkRect2D{
                .offset = .{},
                .extent = c.VkExtent2D{
                    .width = @intFromFloat(viewport_extents.x()),
                    .height = @intFromFloat(viewport_extents.y()),
                },
            },
            .pColorAttachments = &[1]c.VkRenderingAttachmentInfo{
                c.VkRenderingAttachmentInfo{
                    .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                    .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                    .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                    .imageView = current_render_texture.view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    .clearValue = c.VkClearValue{
                        .color = c.VkClearColorValue{
                            .uint32 = [4]u32{ 0, 0, 0, 0 },
                        },
                    },
                },
            },
            .colorAttachmentCount = 1,
            .layerCount = 1,
            .pDepthAttachment = &c.VkRenderingAttachmentInfo{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .imageView = current_depth_attachment.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
                .clearValue = c.VkClearValue{
                    .depthStencil = c.VkClearDepthStencilValue{
                        .depth = 1.0,
                    },
                },
            },
        };

        const cmd_buf = render_state.main_command_buffer;

        try quick_transition_images(cmd_buf, &[2]ImageTransition{
            .{
                .image = current_render_texture.image,
                .subresource = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
                .source_info = .{},
                .dest_info = .{
                    .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    .access_flags = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                    .pipeline_flags = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                },
            },

            .{
                .image = current_depth_attachment.image,
                .subresource = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
                .source_info = .{},
                .dest_info = .{
                    .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    .access_flags = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                    .pipeline_flags = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
                },
            },
        }, this.allocator);
        c.vkCmdBeginRendering(cmd_buf, &rendering_info);

        c.vkCmdBindPipeline(cmd_buf, c.VK_PIPELINE_BIND_POINT_GRAPHICS, this.default_texture_pipeline);
        c.vkCmdBindDescriptorSets(
            cmd_buf,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            this.default_texture_pipeline_layout,
            0,
            1,
            &[1]c.VkDescriptorSet{this.texture_allocator.bindless_descriptor_set},
            0,
            null,
        );

        const push_constant = TextureDrawInfo.PushConstantData{
            .tex_buffer_address = render_state.textures_buffer_address,
            .scene_constant_address = render_state.per_frame_buffer_address,
        };

        c.vkCmdPushConstants(
            cmd_buf,
            this.default_texture_pipeline_layout,
            c.VK_SHADER_STAGE_ALL,
            0,
            @sizeOf(TextureDrawInfo.PushConstantData),
            &push_constant,
        );

        c.vkCmdSetViewport(
            cmd_buf,
            0,
            1,
            &[1]c.VkViewport{
                c.VkViewport{
                    .width = viewport_extents.x(),
                    .height = viewport_extents.y(),
                    .minDepth = 0.0,
                    .maxDepth = 1.0,
                    .x = 0,
                    .y = 0,
                },
            },
        );

        c.vkCmdSetScissor(
            cmd_buf,
            0,
            1,
            &[1]c.VkRect2D{
                c.VkRect2D{
                    .extent = c.VkExtent2D{
                        .width = width,
                        .height = height,
                    },
                    .offset = .{
                        .x = 0,
                        .y = 0,
                    },
                },
            },
        );

        const num_textures: u32 = @intCast(this.render_list.textures.items.len);
        c.vkCmdDraw(cmd_buf, 6, num_textures, 0, 0);
        c.vkCmdEndRendering(cmd_buf);

        const final_transitions = [2]ImageTransition{
            ImageTransition{
                .image = current_render_texture.image,
                .subresource = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
                .source_info = .{
                    .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    .access_flags = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                    .pipeline_flags = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                },
                .dest_info = .{
                    .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    .access_flags = c.VK_ACCESS_2_TRANSFER_READ_BIT,
                    .pipeline_flags = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
                },
            },
            ImageTransition{
                .image = current_swapchain_img.image,
                .subresource = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
                .source_info = .{},
                .dest_info = .{
                    .layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    .access_flags = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
                    .pipeline_flags = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
                },
            },
        };
        try quick_transition_images(cmd_buf, &final_transitions, this.allocator);

        const regions = &[1]c.VkImageBlit{
            c.VkImageBlit{ .srcOffsets = .{
                c.VkOffset3D{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                c.VkOffset3D{
                    .x = @intCast(width),
                    .y = @intCast(height),
                    .z = 1,
                },
            }, .srcSubresource = c.VkImageSubresourceLayers{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseArrayLayer = 0,
                .layerCount = 1,
                .mipLevel = 0,
            }, .dstOffsets = .{
                c.VkOffset3D{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                c.VkOffset3D{
                    .x = @intCast(this.swapchain.extents.width),
                    .y = @intCast(this.swapchain.extents.height),
                    .z = 1,
                },
            }, .dstSubresource = c.VkImageSubresourceLayers{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseArrayLayer = 0,
                .layerCount = 1,
                .mipLevel = 0,
            } },
        };

        c.vkCmdBlitImage(
            cmd_buf,
            current_render_texture.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            current_swapchain_img.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            regions,
            c.VK_FILTER_NEAREST,
        );
        quick_transition_image(
            cmd_buf,
            .{
                .image = current_swapchain_img.image,
                .subresource = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
            },
            .{
                .layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .access_flags = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
                .pipeline_flags = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            },
            .{
                .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .access_flags = 0,
                .pipeline_flags = c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            },
        );
        try render_state.end_frame(this.device);
        try this.swapchain.present(this.device, render_state.work_done_semaphore);
        this.current_render_state = (this.current_render_state + 1) % Renderer.FRAMES_IN_FLIGHT;
    }

    fn sort_texture_draw_info(ctx: void, a: TextureDrawInfo, b: TextureDrawInfo) bool {
        _ = ctx;

        return a.z_index < b.z_index;
    }

    fn update_primitive_buffers(
        this: *const Renderer,
        render_state: *RenderState,
        viewport_extents: Vec2,
    ) void {
        {
            var buffer_alloc_info: c.VmaAllocationInfo = undefined;
            c.vmaGetAllocationInfo(this.vk_allocator, render_state.textures_mem_allocation, &buffer_alloc_info);
            const data: [*]TextureDrawInfo.GpuData = @ptrCast(@alignCast(buffer_alloc_info.pMappedData.?));

            std.mem.sortUnstable(TextureDrawInfo, this.render_list.textures.items, {}, sort_texture_draw_info);
            for (this.render_list.textures.items, 0..) |tex, i| {
                const gpu_info = TextureDrawInfo.GpuData.from(tex);
                data[i] = gpu_info;
            }
        }
        {
            var buffer_alloc_info: c.VmaAllocationInfo = undefined;
            c.vmaGetAllocationInfo(this.vk_allocator, render_state.per_frame_buffer_allocation, &buffer_alloc_info);
            const data: [*]RenderState.RenderPOV = @ptrCast(@alignCast(buffer_alloc_info.pMappedData.?));

            data[0] = RenderState.RenderPOV{
                .projection_matrix = this.camera.projection_matrix(viewport_extents),
                .view_matrix = this.camera.view_matrix(),
            };
        }
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
        vulkan_failure("Failed to pick valid device");
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
            vulkan_failure("Failed to pick a vulkan graphics queue");
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

        var buffer_ext = c.VkPhysicalDeviceBufferDeviceAddressFeatures{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES,
            .pNext = null,
            .bufferDeviceAddress = c.VK_TRUE,
            .bufferDeviceAddressCaptureReplay = c.VK_TRUE,
        };

        // Request the features necessary for bindless texturess
        var indexing_features: c.VkPhysicalDeviceDescriptorIndexingFeatures = std.mem.zeroes(c.VkPhysicalDeviceDescriptorIndexingFeatures);
        indexing_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES;
        indexing_features.pNext = &buffer_ext;
        indexing_features.runtimeDescriptorArray = c.VK_TRUE;
        indexing_features.descriptorBindingPartiallyBound = c.VK_TRUE;
        indexing_features.descriptorBindingSampledImageUpdateAfterBind = c.VK_TRUE;
        indexing_features.shaderSampledImageArrayNonUniformIndexing = c.VK_TRUE;

        var features_2: c.VkPhysicalDeviceFeatures2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
        features_2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        features_2.pNext = &indexing_features;
        features_2.features = .{ .shaderInt64 = c.VK_TRUE };

        var features13 = c.VkPhysicalDeviceVulkan13Features{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = &features_2,
            .synchronization2 = c.VK_TRUE,
            .dynamicRendering = c.VK_TRUE,
        };
        const device_create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &features13,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledExtensionCount = @intCast(required_device_extensions.len),
            .ppEnabledExtensionNames = &required_device_extensions,
            .pEnabledFeatures = null,
        };

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

    const ImageTransition = struct {
        image: c.VkImage,
        subresource: c.VkImageSubresourceRange,
        source_info: TransitionInfo,
        dest_info: TransitionInfo,
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

    fn quick_transition_images(cmd_buf: c.VkCommandBuffer, transitions: []const ImageTransition, allocator: Allocator) !void {
        var image_barriers = try allocator.alloc(c.VkImageMemoryBarrier2, transitions.len);
        defer allocator.free(image_barriers);

        for (transitions, 0..) |trans, i| {
            const image_barrier = c.VkImageMemoryBarrier2{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .image = trans.image,
                .oldLayout = trans.source_info.layout,
                .srcAccessMask = trans.source_info.access_flags,
                .srcStageMask = trans.source_info.pipeline_flags,
                .newLayout = trans.dest_info.layout,
                .dstAccessMask = trans.dest_info.access_flags,
                .dstStageMask = trans.dest_info.pipeline_flags,
                .subresourceRange = trans.subresource,
            };

            image_barriers[i] = image_barrier;
        }
        const dep_flags = c.VK_DEPENDENCY_BY_REGION_BIT;
        const dep_info = c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .bufferMemoryBarrierCount = 0,
            .memoryBarrierCount = 0,
            .imageMemoryBarrierCount = @intCast(image_barriers.len),
            .pImageMemoryBarriers = image_barriers.ptr,
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
            c.vkFreeCommandBuffers(this.device.handle, this.render_states[this.current_render_state].command_pool, 1, &[_]c.VkCommandBuffer{cmd_buf});
        }
    }

    fn create_staging_buffer(this: *Renderer, size: u64) !BufferAllocation {
        return this.create_buffer(.{ .size = size, .flags = BufferFlags{
            .cpu_readable = true,
            .transfer_src = true,
        } });
    }

    fn create_pipeline_layout(device: VkDevice, tex_allocator: *const TextureAllocator) c.VkPipelineLayout {
        const push_constant_range = c.VkPushConstantRange{
            .offset = 0,
            .size = @intCast(@sizeOf(TextureDrawInfo.PushConstantData)),
            .stageFlags = c.VK_SHADER_STAGE_ALL,
        };
        const create_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .setLayoutCount = 1,
            .pSetLayouts = &[_]c.VkDescriptorSetLayout{tex_allocator.bindless_descriptor_set_layout},
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &[_]c.VkPushConstantRange{push_constant_range},
        };

        var layout: c.VkPipelineLayout = null;
        vk_check(c.vkCreatePipelineLayout(device.handle, &create_info, null, &layout), "Failed to create descriptor layout");
        return layout;
    }

    fn create_default_texture_graphics_pipeline(device: VkDevice, pipeline_layout: c.VkPipelineLayout) !c.VkPipeline {
        var vertex_module: c.VkShaderModule = undefined;
        var fragment_module: c.VkShaderModule = undefined;

        // zig fmt: off
        const vert_module_create_info: c.VkShaderModuleCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .codeSize = shaders.DEFAULT_TEXTURE_VS.len,
            .pCode = @ptrCast(@alignCast(shaders.DEFAULT_TEXTURE_VS.ptr)),
            .flags = 0
        };
        const frag_module_create_info: c.VkShaderModuleCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .codeSize = shaders.DEFAULT_TEXTURE_FS.len,
            .pCode = @ptrCast(@alignCast(shaders.DEFAULT_TEXTURE_FS.ptr)),
            .flags = 0
        };
        // zig fmt: on

        vk_check(c.vkCreateShaderModule(device.handle, &vert_module_create_info, null, &vertex_module), "Failed to create vertex module");
        vk_check(c.vkCreateShaderModule(device.handle, &frag_module_create_info, null, &fragment_module), "Failed to create vertex module");
        defer c.vkDestroyShaderModule(device.handle, vertex_module, null);
        defer c.vkDestroyShaderModule(device.handle, fragment_module, null);

        const stages: [2]c.VkPipelineShaderStageCreateInfo = .{
            c.VkPipelineShaderStageCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .module = vertex_module,
                .pName = "main",
                .pSpecializationInfo = null,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            },
            c.VkPipelineShaderStageCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .module = fragment_module,
                .pName = "main",
                .pSpecializationInfo = null,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        };

        // zig fmt: off

        const dynamic_info = c.VkPipelineRenderingCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .colorAttachmentCount = 1,
            //.depthAttachmentFormat = Renderer.default_depth_format,
            .depthAttachmentFormat = Renderer.default_depth_format,
            .pColorAttachmentFormats = &[1]c.VkFormat{Renderer.default_color_format},
            .stencilAttachmentFormat = 0,
            .viewMask = 0,
        };

        const dynamic_states: [2]c.VkDynamicState = .{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR
        };

        const info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &dynamic_info,
            .flags = 0,
            .stageCount = 2,
            .pStages = &stages,
            .pVertexInputState = &c.VkPipelineVertexInputStateCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                .pNext = null,
                .vertexBindingDescriptionCount = 0,
                .vertexAttributeDescriptionCount = 0,
            },
            .pInputAssemblyState = &c.VkPipelineInputAssemblyStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                .pNext = null,
                .primitiveRestartEnable = c.VK_FALSE,
                .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
            },
            .pTessellationState = null,
            .pViewportState = &c.VkPipelineViewportStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .pNext = null, .viewportCount = 1, .scissorCount = 1, .pScissors = null, .pViewports = null },
            .pRasterizationState = &c.VkPipelineRasterizationStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                .pNext = null,
                .depthBiasEnable = c.VK_FALSE,
                .rasterizerDiscardEnable = c.VK_FALSE,
                .polygonMode = c.VK_POLYGON_MODE_FILL,
                .cullMode = c.VK_CULL_MODE_NONE,
                .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
                .depthClampEnable = c.VK_FALSE,
                .lineWidth = 1.0,
            },
            .pMultisampleState = &c.VkPipelineMultisampleStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                .pNext = null,
                .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
                .sampleShadingEnable = c.VK_FALSE,
                .minSampleShading = 0.0,
                .pSampleMask = null,
                .alphaToCoverageEnable = c.VK_FALSE,
                .alphaToOneEnable = c.VK_FALSE,
            },
            .pDepthStencilState = &c.VkPipelineDepthStencilStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
                .pNext = null,
                .depthTestEnable = c.VK_TRUE,
                .depthWriteEnable = c.VK_TRUE,
                .depthCompareOp = c.VK_COMPARE_OP_LESS,
                .depthBoundsTestEnable = c.VK_FALSE,
                .stencilTestEnable = c.VK_FALSE,
                .front = std.mem.zeroes(c.VkStencilOpState),
                .back = std.mem.zeroes(c.VkStencilOpState),
                .minDepthBounds = 0.0,
                .maxDepthBounds = 1.0,
            },
            .pColorBlendState = &c.VkPipelineColorBlendStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .logicOpEnable = c.VK_FALSE,
                .logicOp = c.VK_LOGIC_OP_NO_OP,
                .attachmentCount = 1,
                .pAttachments = &[1]c.VkPipelineColorBlendAttachmentState{ .{
                    .blendEnable = c.VK_TRUE,
                    .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
                    .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                    .colorBlendOp = c.VK_BLEND_OP_ADD,
                    .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
                    .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                    .alphaBlendOp = c.VK_BLEND_OP_ADD,
                    .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
                    },
                },

            },
            .pDynamicState = &c.VkPipelineDynamicStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                .pNext = null,
                .dynamicStateCount = @intCast(dynamic_states.len),
                .pDynamicStates = &dynamic_states,
            },
            .layout = pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = 0,
        };

        // zig fmt: on
        const infos: [1]c.VkGraphicsPipelineCreateInfo = .{info};
        var pipelines: [1]c.VkPipeline = [1]c.VkPipeline{undefined};

        vk_check(c.vkCreateGraphicsPipelines(device.handle, null, 1, &infos, null, &pipelines), "Failed to create default graphics pipeline");
        return pipelines[0];
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

pub const VkDevice = struct {
    handle: c.VkDevice,
    queue: VkQueue,
};
const SwapchainImage = struct {
    image: c.VkImage,
    view: c.VkImageView,
};

pub fn vk_check(expr: c.VkResult, comptime errmsg: []const u8) void {
    if (expr != c.VK_SUCCESS) {
        std.log.err("Vulkan error '{s}'", .{vk_err_msg(expr)});
        vulkan_failure(errmsg);
    }
}

fn vk_err_msg(expr: c.VkResult) []const u8 {
    const msg = c.string_VkResult(expr);
    return std.mem.span(msg);
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
    image_count: u32 = 0,

    fn init(this: *Swapchain, window: *c.SDL_Window, instance: c.VkInstance, physical_device: c.VkPhysicalDevice, device: c.VkDevice, surface: c.VkSurfaceKHR, queue: c.VkQueue, qfi: u32, allocator: Allocator) !void {
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

        var width_c: c_int = 0;
        var height_c: c_int = 0;
        c.SDL_GetWindowSize(window, &width_c, &height_c);

        var width: u32 = @intCast(width_c);
        var height: u32 = @intCast(height_c);

        width = std.math.clamp(width, surface_info.minImageExtent.width, surface_info.maxImageExtent.width);
        height = std.math.clamp(height, surface_info.minImageExtent.height, surface_info.maxImageExtent.height);

        const extent = c.VkExtent2D{ .width = width, .height = height };

        this.image_count = @intCast(Renderer.FRAMES_IN_FLIGHT);
        if (this.image_count < surface_info.minImageCount) {
            this.image_count = surface_info.minImageCount;
        }

        const swapchain_create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = surface,
            .minImageCount = this.image_count,
            .imageFormat = img_format.format,
            .imageColorSpace = img_format.colorSpace,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &[1]u32{qfi},
            .imageUsage = flags,
            .clipped = c.VK_TRUE,
            .preTransform = surface_info.currentTransform,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
        };

        var swapchain_instance: c.VkSwapchainKHR = undefined;
        vk_check(c.vkCreateSwapchainKHR(device, &swapchain_create_info, null, &swapchain_instance), "Failed to create swapchain");
        errdefer c.vkDestroySwapchainKHR(device, swapchain_instance, null);
        this.* = Swapchain{ .handle = swapchain_instance, .current_image = 0, .extents = swapchain_create_info.imageExtent, .format = img_format, .images = try allocator.alloc(SwapchainImage, @intCast(this.image_count)), .present_mode = present_mode, .acquire_fence = acquire_fence, .image_count = this.image_count };

        var presentable_images: u32 = undefined;
        vk_check(c.vkGetSwapchainImagesKHR(device, swapchain_instance, &presentable_images, null), "Failed to get the number of presentable images");

        const images = try allocator.alloc(c.VkImage, @intCast(this.image_count));
        const views = try allocator.alloc(c.VkImageView, @intCast(this.image_count));
        defer allocator.free(images);
        defer allocator.free(views);

        vk_check(c.vkGetSwapchainImagesKHR(device, swapchain_instance, &presentable_images, images.ptr), "Failed to get images from swapchain");

        var cmd_pool: c.VkCommandPool = undefined;
        vk_check(c.vkCreateCommandPool(
            device,
            &c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = qfi },
            null,
            &cmd_pool,
        ), "Failed to create command pool");
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

    fn present(this: *Swapchain, device: VkDevice, wait_semaphore: c.VkSemaphore) !void {
        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pImageIndices = &[1]u32{this.current_image},
            .pResults = null,
            .pSwapchains = &[1]c.VkSwapchainKHR{this.handle.?},
            .swapchainCount = 1,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &[1]c.VkSemaphore{wait_semaphore},
        };
        vk_check(c.vkQueuePresentKHR(device.queue.handle, &present_info), "Failed to present image");
    }
};

pub const TextureDrawInfo = struct {
    const GpuData = extern struct {
        transform_matrix: Mat4,
        offset_extent_px: Vec4,
        color: Vec4,
        tex_id: u32,
        _pad_0: u32 = 0,
        _pad_1: u32 = 0,
        _pad_2: u32 = 0,

        fn from(info: TextureDrawInfo) GpuData {
            const arr_off = info.region.offset.data;
            const arr_ext = info.region.extent.data;

            return .{
                .transform_matrix = math.transformation(info.position.scale(INV_WORLD_SCALE).extend(@floatFromInt(info.z_index)), info.scale.mul(info.region.extent).extend(1.0), vec3(0.0, 0.0, info.rotation)),
                .offset_extent_px = math.vec4(arr_off[0], arr_off[1], arr_ext[0], arr_ext[1]),
                .color = info.color,
                .tex_id = info.texture.id,
            };
        }
    };

    const PushConstantData = packed struct {
        tex_buffer_address: c.VkDeviceAddress,
        scene_constant_address: c.VkDeviceAddress,
    };

    texture: TextureHandle,
    position: Vec2,
    scale: Vec2 = Vec2.ONE,
    color: Vec4 = Vec4.ONE,
    region: Rect2,
    rotation: f32 = 0.0,
    z_index: i32 = 0,
    flags: packed struct {
        is_text: bool = false,
    } = .{},
};

pub const RectDrawInfo = struct {
    rect: Rect2,
    rotation: f32 = 0.0,
    color: Vec4 = Vec4.ONE,
    z_index: i32 = 0,
};

const TextureDrawList = std.ArrayList(TextureDrawInfo);
const RenderList = struct {
    textures: TextureDrawList,

    fn init(allocator: Allocator) RenderList {
        return .{
            .textures = TextureDrawList.init(allocator),
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
    const RenderPOV = struct {
        projection_matrix: math.Mat4 align(1),
        view_matrix: math.Mat4 align(1),
    };

    command_pool: c.VkCommandPool,
    work_done_fence: c.VkFence,
    work_done_semaphore: c.VkSemaphore,
    main_command_buffer: c.VkCommandBuffer,

    render_target_allocator: RenderTargetAllocator,

    vk_allocator: c.VmaAllocator,

    per_frame_buffer: c.VkBuffer,
    per_frame_buffer_address: c.VkDeviceAddress,
    per_frame_buffer_allocation: c.VmaAllocation,

    textures_buffer_address: c.VkDeviceAddress,
    textures_buffer: c.VkBuffer,
    textures_mem_allocation: c.VmaAllocation,

    fn init(
        device: VkDevice,
        allocator: Allocator,
        vk_allocator: c.VmaAllocator,
    ) !RenderState {
        const texture_buf_size: u32 = @intCast(@sizeOf(TextureDrawInfo.GpuData) * 8192 * 2);

        var command_pool: c.VkCommandPool = undefined;
        vk_check(c.vkCreateCommandPool(device.handle, &c.VkCommandPoolCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .pNext = null, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = device.queue.qfi }, null, &command_pool), "Failed to create RenderState command pool");

        var command_buffer: c.VkCommandBuffer = undefined;
        vk_check(c.vkAllocateCommandBuffers(device.handle, &[_]c.VkCommandBufferAllocateInfo{
            c.VkCommandBufferAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .pNext = null, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandPool = command_pool, .commandBufferCount = 1 },
        }, &command_buffer), "Failed to allocate main command buffer");

        const render_target_allocator = RenderTargetAllocator.init(allocator, vk_allocator);

        var alloc_info = std.mem.zeroes(c.VmaAllocationCreateInfo);
        alloc_info.usage = c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST;
        alloc_info.flags = c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT | c.VMA_ALLOCATION_CREATE_MAPPED_BIT;
        alloc_info.requiredFlags = c.VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;

        const buf_usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
        var textures_buffer: c.VkBuffer = undefined;
        const buf_create_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .pQueueFamilyIndices = &[1]u32{device.queue.qfi},
            .queueFamilyIndexCount = 1,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .flags = 0,
            .usage = buf_usage,
            .size = texture_buf_size,
        };

        var textures_mem_allocation: c.VmaAllocation = undefined;
        vk_check(c.vmaCreateBuffer(vk_allocator, &buf_create_info, &alloc_info, &textures_buffer, &textures_mem_allocation, null), "Failed to allocate texture data buffer");

        const textures_buffer_address = c.vkGetBufferDeviceAddress(device.handle, &c.VkBufferDeviceAddressInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
            .pNext = null,
            .buffer = textures_buffer,
        });

        var per_frame_buffer: c.VkBuffer = undefined;
        const per_frame_buffer_buffer_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .pQueueFamilyIndices = &[1]u32{device.queue.qfi},
            .queueFamilyIndexCount = 1,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .flags = 0,
            .usage = buf_usage,
            .size = texture_buf_size,
        };

        var per_frame_buffer_allocation: c.VmaAllocation = undefined;
        vk_check(c.vmaCreateBuffer(vk_allocator, &per_frame_buffer_buffer_info, &alloc_info, &per_frame_buffer, &per_frame_buffer_allocation, null), "Failed to allocate texture data buffer");

        const per_frame_buffer_address = c.vkGetBufferDeviceAddress(device.handle, &c.VkBufferDeviceAddressInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
            .pNext = null,
            .buffer = per_frame_buffer,
        });

        return .{
            .command_pool = command_pool,
            .work_done_fence = try make_fence(device.handle, true),
            .work_done_semaphore = make_semaphore(device.handle),
            .main_command_buffer = command_buffer,
            .render_target_allocator = render_target_allocator,
            .vk_allocator = vk_allocator,

            .textures_buffer_address = textures_buffer_address,
            .textures_buffer = textures_buffer,
            .textures_mem_allocation = textures_mem_allocation,
            .per_frame_buffer_address = per_frame_buffer_address,
            .per_frame_buffer = per_frame_buffer,
            .per_frame_buffer_allocation = per_frame_buffer_allocation,
        };
    }

    fn start_frame(this: *RenderState, device: VkDevice) void {
        vk_check(c.vkWaitForFences(device.handle, 1, &[_]c.VkFence{this.work_done_fence}, c.VK_TRUE, std.math.maxInt(u64)), "Could not wait for work done fence");
        vk_check(c.vkResetFences(device.handle, 1, &[_]c.VkFence{this.work_done_fence}), "Could not reset work done fence");
        const command_buffer_begin = c.VkCommandBufferBeginInfo{
            .pNext = null,
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        vk_check(c.vkResetCommandPool(device.handle, this.command_pool, c.VK_COMMAND_POOL_RESET_RELEASE_RESOURCES_BIT), "Failed to reset command pool");

        vk_check(c.vkBeginCommandBuffer(this.main_command_buffer, &[_]c.VkCommandBufferBeginInfo{command_buffer_begin}), "Failed to begin command buffer");
    }

    fn end_frame(this: *RenderState, device: VkDevice) !void {
        vk_check(c.vkEndCommandBuffer(this.main_command_buffer), "Failed to end main command buffer");
        const cmd_buf_info = c.VkCommandBufferSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .pNext = null,
            .deviceMask = 0,
            .commandBuffer = this.main_command_buffer,
        };

        const semaphore_submit_info = [1]c.VkSemaphoreSubmitInfo{
            c.VkSemaphoreSubmitInfo{
                .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                .pNext = null,
                .semaphore = this.work_done_semaphore,
                .stageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            },
        };

        const submit_info = c.VkSubmitInfo2{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .flags = 0,
            .waitSemaphoreInfoCount = 0,
            .pWaitSemaphoreInfos = null,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &[_]c.VkCommandBufferSubmitInfo{cmd_buf_info},
            .signalSemaphoreInfoCount = @intCast(semaphore_submit_info.len),
            .pSignalSemaphoreInfos = &semaphore_submit_info,
        };
        vk_check(c.vkQueueSubmit2(device.queue.handle, 1, &[_]c.VkSubmitInfo2{submit_info}, this.work_done_fence), "Failed to submit to main queue");

        try this.render_target_allocator.update(device);
    }

    fn deinit(this: *RenderState, device: VkDevice) void {
        this.render_target_allocator.deinit(device);

        c.vmaDestroyBuffer(this.vk_allocator, this.per_frame_buffer, this.per_frame_buffer_allocation);
        c.vmaDestroyBuffer(this.vk_allocator, this.textures_buffer, this.textures_mem_allocation);

        c.vkFreeCommandBuffers(device.handle, this.command_pool, 1, &[_]c.VkCommandBuffer{this.main_command_buffer});
        c.vkDestroySemaphore(device.handle, this.work_done_semaphore, null);
        c.vkDestroyFence(device.handle, this.work_done_fence, null);
        c.vkDestroyCommandPool(device.handle, this.command_pool, null);
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

fn vulkan_failure(message: []const u8) noreturn {
    sdl_util.message_box("Vulkan failure: ", message, .Error);
    std.debug.panic("Vulkan failure", .{});
}

fn make_fence(device: c.VkDevice, signaled: bool) !c.VkFence {
    var vk_fence: c.VkFence = undefined;
    vk_check(c.vkCreateFence(
        device,
        &c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = if (signaled)
            c.VK_FENCE_CREATE_SIGNALED_BIT
        else
            0 },
        null,
        &vk_fence,
    ), "Failed to create vulkan fence");
    return vk_fence;
}

fn make_semaphore(device: c.VkDevice) c.VkSemaphore {
    var semaphore: c.VkSemaphore = undefined;

    vk_check(c.vkCreateSemaphore(device, &c.VkSemaphoreCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    }, null, &semaphore), "Could not create semaphore");
    return semaphore;
}
