const std = @import("std");
const types = @import("../types.zig");
const c = @import("../clibs.zig");
const sampler_allocator = @import("./sampler_allocator.zig");
const renderer = @import("../renderer.zig");

const Allocator = std.mem.Allocator;
const Texture = types.Texture;
const TextureFlags = types.TextureFlags;
const TextureHandle = types.TextureHandle;
const VkDevice = renderer.VkDevice;

const Textures = std.ArrayList(?Texture);
pub const TextureAllocation = struct { texture: Texture, handle: TextureHandle };

const vk_check = renderer.vk_check;
pub const TextureAllocator = struct {
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

    pub fn init(device: VkDevice, allocator: Allocator, vma: c.VmaAllocator) !TextureAllocator {
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

    pub fn alloc_texture(this: *TextureAllocator, device: VkDevice, sam_allocator: *sampler_allocator.SamplerAllocator, description: Texture.CreateInfo) !TextureAllocation {
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

        var usage: u32 = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if (description.flags.render_attachment) {
            const attachment_bit = types.vk_attachment_usage(description.format);
            usage |= attachment_bit;
        }
        if (description.flags.trasfer_src) {
            usage |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        }
        const format = types.vk_format(description.format);
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

        const swizzle = if (description.format == .r_8) c.VkComponentMapping{
            .r = c.VK_COMPONENT_SWIZZLE_R,
            .g = c.VK_COMPONENT_SWIZZLE_R,
            .b = c.VK_COMPONENT_SWIZZLE_R,
            .a = c.VK_COMPONENT_SWIZZLE_R,
        } else c.VkComponentMapping{
            .r = c.VK_COMPONENT_SWIZZLE_R,
            .g = c.VK_COMPONENT_SWIZZLE_G,
            .b = c.VK_COMPONENT_SWIZZLE_B,
            .a = c.VK_COMPONENT_SWIZZLE_A,
        };

        const image_view_desc = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .image = image,
            .format = format,
            .flags = 0,
            .components = swizzle,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .subresourceRange = c.VkImageSubresourceRange{
                .layerCount = 1,
                .levelCount = 1,
                .baseMipLevel = 0,
                .baseArrayLayer = 0,
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            },
        };
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

    pub fn flush_updates(this: *TextureAllocator, device: VkDevice) !void {
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

    pub fn free_texture(this: *TextureAllocator, device: VkDevice, tex_handle: TextureHandle) void {
        const texture = this.all_textures.items[tex_handle.id].?;
        this.all_textures.items[tex_handle.id] = null;

        c.vkDestroyImageView(device.handle, texture.view, null);
        c.vmaDestroyImage(this.vk_allocator, texture.image, texture.allocation);
    }

    pub fn deinit(this: *TextureAllocator, device: VkDevice) void {
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
