const std = @import("std");
const c = @import("../clibs.zig");
const types = @import("../types.zig");
const renderer = @import("../renderer.zig");

const TextureFormat = types.TextureFormat;
const Allocator = std.mem.Allocator;
const VkDevice = renderer.VkDevice;
const vk_check = renderer.vk_check;

pub const RenderTarget = struct {
    view: c.VkImageView,
    image: c.VkImage,
};
pub const RenderTargetAllocator = struct {
    const MAX_LIFETIME: usize = 5;
    pub const RenderTargetDesc = struct {
        width: u32,
        height: u32,
        format: TextureFormat,
    };
    const RenderTargetAllocation = struct {
        target: RenderTarget,
        memory_alloc: c.VmaAllocation,
        lifetime: usize,
    };

    const RenderTargets = std.AutoArrayHashMap(RenderTargetDesc, RenderTargetAllocation);

    textures: RenderTargets,
    allocator: Allocator,
    vk_allocator: c.VmaAllocator,

    pub fn init(allocator: Allocator, vk_allocator: c.VmaAllocator) RenderTargetAllocator {
        return .{ .textures = RenderTargets.init(allocator), .allocator = allocator, .vk_allocator = vk_allocator };
    }

    pub fn deinit(this: *RenderTargetAllocator, device: VkDevice) void {
        for (this.textures.values()) |val| {
            c.vkDestroyImageView(device.handle, val.target.view, null);
            c.vmaDestroyImage(this.vk_allocator, val.target.image, val.memory_alloc);
        }

        this.textures.deinit();
    }

    pub fn get(this: *RenderTargetAllocator, device: VkDevice, desc: RenderTargetDesc) !RenderTarget {
        const value = try this.textures.getOrPut(desc);
        if (!value.found_existing) {
            value.value_ptr.* = try this.create_render_target(device, desc);
        }
        value.value_ptr.*.lifetime = RenderTargetAllocator.MAX_LIFETIME;
        return value.value_ptr.*.target;
    }

    pub fn update(this: *RenderTargetAllocator, device: VkDevice) !void {
        var entries_to_remove = std.ArrayList(RenderTargetDesc).init(this.allocator);
        defer entries_to_remove.deinit();

        var iterator = this.textures.iterator();
        while (iterator.next()) |*entry| {
            entry.value_ptr.lifetime -= 1;
            if (entry.value_ptr.lifetime == 0) {
                try entries_to_remove.append(entry.key_ptr.*);
            }
        }

        for (entries_to_remove.items) |entry| {
            const render_target = this.textures.fetchSwapRemove(entry).?.value;
            c.vkDestroyImageView(device.handle, render_target.target.view, null);
            c.vmaDestroyImage(this.vk_allocator, render_target.target.image, render_target.memory_alloc);
        }
    }

    fn create_render_target(this: *RenderTargetAllocator, device: VkDevice, desc: RenderTargetDesc) !RenderTargetAllocation {
        const attachment_usage = types.vk_attachment_usage(desc.format);
        const aspect_mask = types.vk_aspect(desc.format);
        const image_desc = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .usage = attachment_usage | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
            .extent = c.VkExtent3D{
                .width = desc.width,
                .height = desc.height,
                .depth = 1,
            },
            .format = types.vk_format(desc.format),
            .imageType = c.VK_IMAGE_TYPE_2D,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .mipLevels = 1,
            .arrayLayers = 1,
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &[_]u32{device.queue.qfi},
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
        };

        var vk_image: c.VkImage = undefined;
        var allocation: c.VmaAllocation = undefined;
        var alloc_info = std.mem.zeroes(c.VmaAllocationCreateInfo);
        alloc_info.usage = c.VMA_MEMORY_USAGE_AUTO;
        vk_check(c.vmaCreateImage(this.vk_allocator, &image_desc, &alloc_info, &vk_image, &allocation, null), "Failed to allocate render target image");

        const image_view_desc = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .components = c.VkComponentMapping{
                .r = c.VK_COMPONENT_SWIZZLE_R,
                .g = c.VK_COMPONENT_SWIZZLE_G,
                .b = c.VK_COMPONENT_SWIZZLE_B,
                .a = c.VK_COMPONENT_SWIZZLE_A,
            },
            .format = types.vk_format(desc.format),
            .image = vk_image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .subresourceRange = c.VkImageSubresourceRange{
                .aspectMask = aspect_mask,
                .baseArrayLayer = 0,
                .baseMipLevel = 0,
                .layerCount = 1,
                .levelCount = 1,
            },
        };

        var view: c.VkImageView = undefined;
        vk_check(c.vkCreateImageView(device.handle, &image_view_desc, null, &view), "Failed to create render target image view");

        return RenderTargetAllocation{
            .target = RenderTarget{
                .image = vk_image,
                .view = view,
            },
            .memory_alloc = allocation,
            .lifetime = RenderTargetAllocator.MAX_LIFETIME,
        };
    }
};
