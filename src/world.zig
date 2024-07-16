const std = @import("std");
const gen_arena = @import("gen_arena.zig");
const util = @import("util.zig");

const ErasedArena = gen_arena.ErasedArena;
const Allocator = std.mem.Allocator;

const type_id = util.type_id;

const ErasedComponentHandle = struct {
    type_id: usize,
    index: gen_arena.ErasedIndex,
};

pub const World = struct {
    const ComponentMap = std.AutoArrayHashMap(usize, ComponentStorage);

    storage: ComponentMap,
    allocator: Allocator,

    pub fn ComponentHandle(comptime T: type) type {
        return struct {
            index: gen_arena.ErasedIndex,

            pub fn erase(this: @This()) ErasedComponentHandle {
                return .{ .type_id = type_id(T), .index = this.index };
            }
        };
    }

    pub fn init(allocator: Allocator) Allocator.Error!World {
        return .{
            .storage = ComponentMap.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(this: *World) void {
        for (this.storage.values()) |val| {
            val.arena.deinit();
        }

        this.storage.deinit();
    }

    pub fn add_component(this: *World, comptime T: type, component: T) Allocator.Error!ComponentHandle(T) {
        const id = type_id(T);
        var map = try this.storage.getOrPut(id);
        if (!map.found_existing) {
            map.value_ptr.* = ComponentStorage{
                .arena = try ErasedArena.init(T, this.allocator),
                .vtable = ComponentVTable.of(T),
            };
        }

        const index = try map.value_ptr.arena.push(T, component);
        return ComponentHandle(T){ .index = index };
    }

    pub fn get_component(this: *World, comptime T: type, index: ComponentHandle(T)) Allocator.Error!?*T {
        const id = type_id(T);
        var map = try this.storage.getOrPut(id);
        if (!map.found_existing) {
            map.value_ptr.* = ComponentStorage{
                .arena = try ErasedArena.init(T, this.allocator),
                .vtable = ComponentVTable.of(T),
            };
        }

        return try map.value_ptr.arena.get_ptr(T, index.index);
    }

    pub fn begin(this: *World) void {
        for (this.storage.values()) |val| {
            var val_arena = val;
            val.vtable.begin_all_fn(&val_arena.arena, this);
        }
    }

    pub fn update(this: *World, dt: f32) void {
        for (this.storage.values()) |val| {
            var val_arena = val;
            val.vtable.update_all_fn(&val_arena.arena, this, dt);
        }
    }

    pub fn destroy(this: *World) void {
        for (this.storage.values()) |val| {
            var val_arena = val;
            val.vtable.destroy_all_fn(&val_arena.arena, this);
        }
    }
};

const ComponentStorage = struct {
    arena: ErasedArena,
    vtable: ComponentVTable,
};

const ComponentVTable = struct {
    begin_all_fn: *const fn (arena: *ErasedArena, context: *World) void,
    update_all_fn: *const fn (
        arena: *ErasedArena,
        context: *World,
        delta_time: f32,
    ) void,
    destroy_all_fn: *const fn (arena: *ErasedArena, context: *World) void,

    fn of(comptime T: type) ComponentVTable {
        const info = @typeInfo(T);
        if (info == .Pointer) @compileError("Pointers aren't supported");

        const gen = struct {
            fn begin_all(arena: *ErasedArena, context: *World) void {
                var arena_interator = arena.iterator(T);
                while (arena_interator.next()) |value| {
                    value.begin(context);
                }
            }
            fn update_all(arena: *ErasedArena, context: *World, dt: f32) void {
                var arena_interator = arena.iterator(T);
                while (arena_interator.next()) |value| {
                    value.update(context, dt);
                }
            }
            fn destroy_all(arena: *ErasedArena, context: *World) void {
                var arena_interator = arena.iterator(T);
                while (arena_interator.next()) |value| {
                    value.destroy(context);
                }
            }
        };

        return ComponentVTable{
            .begin_all_fn = gen.begin_all,
            .update_all_fn = gen.update_all,
            .destroy_all_fn = gen.destroy_all,
        };
    }
};
