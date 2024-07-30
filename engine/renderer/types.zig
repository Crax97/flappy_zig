const std = @import("std");
const c = @import("clibs.zig");

pub fn Handle(comptime T: type) type {
    _ = T;
    return struct {
        const NULL = std.math.maxInt(u32);
        id: u32 = NULL,

        fn is_null(this: @This()) bool {
            return this.id == NULL;
        }
    };
}
pub const TextureHandle = Handle(Texture);
pub const BufferHandle = Handle(Buffer);

pub const Texture = struct {
    pub const CreateInfo = struct {
        width: u32,
        height: u32,
        depth: u32 = 1,
        format: TextureFormat,
        initial_bytes: ?[]const u8 = null,
        flags: TextureFlags = .{},

        sampler_config: SamplerConfig = .{},
    };
    handle: TextureHandle,
    image: c.VkImage,
    view: c.VkImageView,
    sampler: c.VkSampler,
    allocation: c.VmaAllocation,
};

pub const Filter = enum {
    Linear,
    Nearest,
};
pub const MipMode = enum {
    Linear,
    Nearest,
};
pub const AddressMode = enum {
    ClampToBorder,
    ClampToEdge,
    Repeat,
};

pub const CompareOp = enum {};

pub const SamplerConfig = struct {
    min_filter: Filter = Filter.Linear,
    mag_filter: Filter = Filter.Linear,
    mipmap_mode: MipMode = MipMode.Linear,
    address_u: AddressMode = AddressMode.ClampToBorder,
    address_v: AddressMode = AddressMode.ClampToBorder,
    address_w: AddressMode = AddressMode.ClampToBorder,
    compare_op: ?CompareOp = null,

    pub const NEAREST = SamplerConfig{
        .min_filter = Filter.Nearest,
        .mag_filter = Filter.Nearest,
        .mipmap_mode = MipMode.Nearest,
    };
    pub const LINEAR = SamplerConfig{
        .min_filter = Filter.Linear,
        .mag_filter = Filter.Linear,
        .mipmap_mode = MipMode.Linear,
    };
};

pub const Buffer = struct {
    pub const CreateInfo = struct {
        size: u64,
        flags: BufferFlags = .{},
    };

    allocation: c.VmaAllocation,
    buffer: c.VkBuffer,
    info: CreateInfo,
};

pub const TextureFormat = enum {
    r_8,
    rgba_8,
    depth_32,
};

pub const TextureFlags = packed struct {
    cpu_readable: bool = false,
    storage_image: bool = false,
    trasfer_src: bool = false,
    render_attachment: bool = false,
};

pub const BufferFlags = packed struct {
    cpu_readable: bool = false,
    transfer_src: bool = true,
    vertex_buffer: bool = false,
    storage_buffer: bool = false,
    uniform_buffer: bool = false,
};

pub fn vk_format(format: TextureFormat) c.VkFormat {
    return switch (format) {
        .r_8 => c.VK_FORMAT_R8_UNORM,
        .rgba_8 => c.VK_FORMAT_R8G8B8A8_UNORM,
        .depth_32 => c.VK_FORMAT_D32_SFLOAT,
    };
}

pub fn vk_aspect(format: TextureFormat) c.VkImageAspectFlags {
    return switch (format) {
        .rgba_8, .r_8 => c.VK_IMAGE_ASPECT_COLOR_BIT,
        .depth_32 => c.VK_IMAGE_ASPECT_DEPTH_BIT,
    };
}
pub fn vk_attachment_usage(format: TextureFormat) c.VkImageUsageFlags {
    return switch (format) {
        .rgba_8, .r_8 => c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .depth_32 => c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
    };
}
