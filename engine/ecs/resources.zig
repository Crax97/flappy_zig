const std = @import("std");
const Allocator = std.mem.Allocator;

const type_id = @import("core").type_id;

const ErasedResource = struct {
    type_id: usize,
    type_size: usize,
    data: []u8,
};

const ResourceContainer = std.AutoArrayHashMap(usize, ErasedResource);
pub const Resources = struct {
    resources: ResourceContainer,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Resources {
        return .{
            .resources = ResourceContainer.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(this: *Resources) void {
        this.resources.deinit();
    }

    pub fn add(this: *Resources, value: anytype) !void {
        const T = @TypeOf(value);
        const ty_id = type_id(T);

        const entry = try this.resources.getOrPut(ty_id);
        const entry_value = entry.value_ptr;
        if (!entry.found_existing) {
            entry_value.data.ptr = @ptrCast(@alignCast(try this.allocator.create(T)));
            entry_value.data.len = @sizeOf(T);
            entry_value.type_id = ty_id;
            entry_value.type_size = @sizeOf(T);
        }
        const val: *T = @ptrCast(@alignCast(entry.value_ptr.data.ptr));
        val.* = value;
    }

    // Don't store this pointer: it may get invalidated when adding another resource
    pub fn get(this: *Resources, comptime T: type) ?*T {
        const ty_id = type_id(T);
        const entry = this.resources.get(ty_id) orelse {
            return null;
        };

        std.debug.assert(@sizeOf(T) == entry.type_size);
        const val: *T = @ptrCast(@alignCast(entry.data.ptr));
        return val;
    }

    pub fn get_checked(this: *Resources, comptime T: type) *T {
        return this.get(T).?;
    }
};
