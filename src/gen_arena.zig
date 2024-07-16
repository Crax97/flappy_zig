const std = @import("std");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const type_id = util.type_id;

pub const ErasedIndex = struct {
    index: usize,
    generation: usize,
};

fn ArenaIterator(comptime T: type) type {
    return struct {
        arena: *const ErasedArena,
        current: usize,

        pub fn next(this: *@This()) ?*T {
            while (this.current < this.arena.capacity) {
                const entry = this.arena.entry_ptr(T, this.current);
                this.current += 1;

                if (entry.value) |*value| {
                    return value;
                }
            }
            return null;
        }
    };
}

const EMPTY_ARR: [0]u8 = ([0]u8{});
const EMPTY: []u8 = EMPTY_ARR[0..0];

pub const ErasedArena = struct {
    data: []u8,
    type_info: TypeInfo,
    len: usize,
    capacity: usize,
    free_indices: std.ArrayList(ErasedIndex),
    allocator: Allocator,
    vtable: ErasedArenaVTable,

    const This = @This();
    pub fn init(comptime T: type, allocator: Allocator) Allocator.Error!ErasedArena {
        const type_info = TypeInfo.of(T);

        const gen = struct {
            fn clear(self: *ErasedArena) Allocator.Error!void {
                const entries_ptr: [*]Entry(T) = @ptrCast(@alignCast(self.data));

                for (0..self.capacity) |i| {
                    const entry = &entries_ptr[i];
                    if (entry.*.value) |_| {
                        entry.*.value = null;
                        entry.*.generation += 1;
                        try self.free_indices.append(ErasedIndex{ .index = i, .generation = entry.generation });
                    }
                }
            }
        };

        return .{ .data = EMPTY, .type_info = type_info, .len = 0, .capacity = 0, .free_indices = std.ArrayList(ErasedIndex).init(allocator), .allocator = allocator, .vtable = ErasedArenaVTable{
            .clear_func = gen.clear,
        } };
    }

    pub fn reserve_index(self: *This) Allocator.Error!ErasedIndex {
        return self.get_index();
    }

    pub fn deinit(self: *const This) void {
        self.free_indices.deinit();
        self.allocator.free(self.data);
    }

    pub fn push(self: *This, comptime T: type, value: T) Allocator.Error!ErasedIndex {
        std.debug.assert(type_id(T) == self.type_info.type_id);
        const index = try self.get_index();
        const entry = self.entry_ptr(T, index.index);
        entry.* = Entry(T){ .generation = index.generation, .value = value };
        self.len += 1;
        return index;
    }

    pub fn get(self: *This, comptime T: type, index: ErasedIndex) ?T {
        std.debug.assert(type_id(T) == self.type_info.type_id);
        const entry = self.entry_ptr(T, index.index);
        if (entry.generation == index.generation) {
            return entry.value;
        } else {
            return null;
        }
    }

    pub fn get_ptr(self: *This, comptime T: type, index: ErasedIndex) ?*T {
        std.debug.assert(type_id(T) == self.type_info.type_id);

        const entry = self.entry_ptr(T, index.index);
        if (entry.generation == index.generation) {
            return &entry.value.?;
        } else {
            return null;
        }
    }

    pub fn entry_ptr(self: *const This, comptime T: type, index: usize) *Entry(T) {
        std.debug.assert(index <= self.capacity);
        const ptr: [*]Entry(T) = @ptrCast(@alignCast(self.data.ptr));
        return &ptr[index];
    }

    pub fn remove(self: *This, comptime T: type, index: ErasedIndex) Allocator.Error!?T {
        std.debug.assert(type_id(T) == self.type_info.type_id);
        const entry = self.entry_ptr(T, index.index);
        if (entry.generation == index.generation) {
            const value = entry.value;
            entry.*.value = null;
            entry.*.generation += 1;
            try self.free_indices.append(ErasedIndex{ .index = index.index, .generation = index.generation + 1 });
            self.len -= 1;

            return value;
        } else {
            return null;
        }
    }

    pub fn iterator(self: *This, comptime T: type) ArenaIterator(T) {
        std.debug.assert(type_id(T) == self.type_info.type_id);
        return ArenaIterator(T){ .arena = self, .current = 0 };
    }

    pub fn clear(self: *This) Allocator.Error!void {
        try self.vtable.clear_func(self);
        self.len = 0;
    }

    fn get_index(self: *This) Allocator.Error!ErasedIndex {
        if (self.free_indices.items.len > 0) {
            return self.free_indices.pop();
        } else {
            const index = self.capacity;
            try self.grow(1);
            return ErasedIndex{ .index = index, .generation = 0 };
        }
    }

    fn grow(self: *This, delta: usize) Allocator.Error!void {
        self.capacity += delta;
        const new_count = ErasedArena.array_size(self.type_info, self.capacity);
        if (self.data.ptr == EMPTY.ptr) {
            self.data = try self.allocator.alloc(u8, new_count);
        } else {
            self.data = try self.allocator.realloc(self.data, new_count);
        }
    }

    fn array_size(info: TypeInfo, count: usize) usize {
        return info.size * count;
    }
};
pub fn Index(comptime T: type) type {
    _ = T;
    return struct {
        inner_index: ErasedIndex,
    };
}
pub fn GenArena(comptime T: type) type {
    return struct {
        const This = @This();
        inner: ErasedArena,

        pub fn init(allocator: Allocator) Allocator.Error!This {
            return .{ .inner = try ErasedArena.init(T, allocator) };
        }

        pub fn reserve_index(self: *This) Allocator.Error!Index(T) {
            const erased_index = try self.inner.reserve_index();
            return Index(T){ .inner_index = erased_index };
        }

        pub fn replace_at(self: *This, index: Index(T), value: T) void {
            const entry = self.inner.entry_ptr(T, index.inner_index.index);
            entry.* = Entry(T){ .generation = index.inner_index.generation, .value = value };
        }

        pub fn len(self: *const This) usize {
            return self.inner.len;
        }

        pub fn push(self: *This, value: T) Allocator.Error!Index(T) {
            const erased_index = try self.inner.push(T, value);

            return Index(T){ .inner_index = erased_index };
        }

        pub fn get(self: *This, index: Index(T)) ?T {
            return self.inner.get(T, index.inner_index);
        }

        pub fn get_ptr(self: *This, index: Index(T)) ?*T {
            return self.inner.get_ptr(T, index.inner_index);
        }

        pub fn remove(self: *This, index: Index(T)) Allocator.Error!?T {
            return try self.inner.remove(T, index.inner_index);
        }

        pub fn clear(self: *This) Allocator.Error!void {
            try self.inner.clear();
        }

        pub fn deinit(self: *This) void {
            self.inner.deinit();
        }
    };
}

const ErasedArenaVTable = struct {
    clear_func: *const fn (*ErasedArena) Allocator.Error!void,
};

const TypeInfo = struct {
    type_id: usize,
    size: usize,
    alignment: usize,

    fn of(comptime T: type) @This() {
        return .{
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .type_id = type_id(T),
        };
    }
};

fn Entry(comptime T: type) type {
    return struct {
        value: ?T,
        generation: usize,
    };
}

test "erased gen arena basics" {
    var gen_arena_u32 = try ErasedArena.init(u32, std.testing.allocator);
    defer gen_arena_u32.deinit();

    const index_1 = try gen_arena_u32.push(u32, 1);
    const index_2 = try gen_arena_u32.push(u32, 2);
    const index_3 = try gen_arena_u32.push(u32, 3);

    try std.testing.expectEqual(gen_arena_u32.len, 3);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_1), 1);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_2), 2);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_3), 3);

    try std.testing.expectEqual(gen_arena_u32.remove(u32, index_1), 1);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_1), null);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_2), 2);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_3), 3);

    try gen_arena_u32.clear();

    try std.testing.expectEqual(gen_arena_u32.get(u32, index_1), null);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_2), null);
    try std.testing.expectEqual(gen_arena_u32.get(u32, index_3), null);
}

test "gen arena basics" {
    var gen_arena_u32 = try GenArena.init(std.testing.allocator);
    defer gen_arena_u32.deinit();

    const index_1 = try gen_arena_u32.push(1);
    const index_2 = try gen_arena_u32.push(2);
    const index_3 = try gen_arena_u32.push(3);

    try std.testing.expectEqual(gen_arena_u32.len(), 3);
    try std.testing.expectEqual(gen_arena_u32.get(index_1), 1);
    try std.testing.expectEqual(gen_arena_u32.get(index_2), 2);
    try std.testing.expectEqual(gen_arena_u32.get(index_3), 3);

    try std.testing.expectEqual(gen_arena_u32.remove(index_1), 1);
    try std.testing.expectEqual(gen_arena_u32.get(index_1), null);
    try std.testing.expectEqual(gen_arena_u32.get(index_2), 2);
    try std.testing.expectEqual(gen_arena_u32.get(index_3), 3);

    try gen_arena_u32.clear();

    try std.testing.expectEqual(gen_arena_u32.get(index_1), null);
    try std.testing.expectEqual(gen_arena_u32.get(index_2), null);
    try std.testing.expectEqual(gen_arena_u32.get(index_3), null);
}
