const std = @import("std");
const c = @import("../clibs.zig");
const types = @import("../types.zig");

const SamplerConfig = types.SamplerConfig;
const Allocator = std.mem.Allocator;
const vk_check = @import("../renderer.zig").vk_check;

const Samplers = std.AutoArrayHashMap(SamplerConfig, c.VkSampler);
pub const SamplerAllocator = struct {
    samplers: Samplers,
    device: c.VkDevice,
    allocator: Allocator,

    pub fn init(allocator: Allocator, device: c.VkDevice) SamplerAllocator {
        return .{
            .samplers = Samplers.init(allocator),
            .device = device,
            .allocator = allocator,
        };
    }

    pub fn deinit(this: *SamplerAllocator) void {
        for (this.samplers.values()) |sampler| {
            c.vkDestroySampler(this.device, sampler, null);
        }
    }

    pub fn get(this: *SamplerAllocator, config: SamplerConfig) !c.VkSampler {
        const entry = try this.samplers.getOrPut(config);
        if (!entry.found_existing) {
            entry.value_ptr.* = try this.create_sampler(config);
        }

        return entry.value_ptr.*;
    }

    fn create_sampler(this: *SamplerAllocator, config: SamplerConfig) !c.VkSampler {
        const sampler_create_info = c.VkSamplerCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .addressModeU = vk_address_mode(config.address_u),
            .addressModeV = vk_address_mode(config.address_v),
            .addressModeW = vk_address_mode(config.address_w),
            .minFilter = vk_filter(config.min_filter),
            .magFilter = vk_filter(config.mag_filter),
            .mipmapMode = vk_mipmap_mode(config.mipmap_mode),
            .compareEnable = if (config.compare_op) |_| c.VK_TRUE else c.VK_FALSE,
            .compareOp = if (config.compare_op) |op| vk_compare_op(op) else 0,
            .maxLod = std.math.floatMax(f32),
        };

        var sampler: c.VkSampler = undefined;
        vk_check(c.vkCreateSampler(this.device, &sampler_create_info, null, &sampler), "Failed to create sampler");
        return sampler;
    }
};

fn vk_address_mode(mode: types.AddressMode) c.VkSamplerAddressMode {
    return switch (mode) {
        .ClampToBorder => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .ClampToEdge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .Repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
    };
}

fn vk_filter(filter: types.Filter) c.VkFilter {
    return switch (filter) {
        .Linear => c.VK_FILTER_LINEAR,
        .Nearest => c.VK_FILTER_NEAREST,
    };
}

fn vk_mipmap_mode(mode: types.MipMode) c.VkSamplerMipmapMode {
    return switch (mode) {
        .Linear => c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .Nearest => c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
    };
}

fn vk_compare_op(op: types.CompareOp) c.VkCompareOp {
    // TODO
    _ = op;
    return 0;
}
