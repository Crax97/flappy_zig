const std = @import("std");
const world_mod = @import("world.zig");
const World = world_mod.World;
const EntityID = world_mod.EntityID;

const ErasedArena = @import("../gen_arena.zig").ErasedArena;
const ErasedIndex = @import("../gen_arena.zig").ErasedIndex;

const Allocator = std.mem.Allocator;

const type_id = @import("../util.zig").type_id;

pub const ErasedComponentHandle = struct {
    type_id: usize,
    index: ErasedIndex,
};

pub fn ComponentHandle(comptime T: type) type {
    return struct {
        handle: ErasedComponentHandle,
        world: *World,

        pub fn erase(this: @This()) ErasedComponentHandle {
            return this.handle;
        }

        pub fn is_valid(this: @This()) bool {
            const storage = this.world.get_storage(T);
            if (storage.arena.get_ptr(T, this.handle.index)) |_| {
                return true;
            } else {
                return false;
            }
        }
        pub fn get(this: @This()) *T {
            std.debug.assert(this.is_valid());

            const storage = this.world.get_storage(T);
            return storage.arena.get_ptr(T, this.handle.index).?;
        }
    };
}

pub const ComponentBegin = struct {
    world: *World,
    entity: EntityID,
};
pub const ComponentDestroyed = struct {
    world: *World,
    entity: EntityID,
};

pub const ComponentUpdate = struct {
    world: *World,
    entity: EntityID,
    delta_time: f64,
};
pub const ComponentVTable = struct {
    begin: ?*const fn (self: *anyopaque, ctx: ComponentBegin) anyerror!void,
    update: *const fn (self: *anyopaque, ctx: ComponentUpdate) anyerror!void,
    destroyed: ?*const fn (self: *anyopaque, ctx: ComponentDestroyed) anyerror!void,

    pub fn of(comptime T: type) ComponentVTable {
        const type_info = @typeInfo(T);
        comptime if (type_info != .Struct) {
            @compileError("Only structs are supported at the moment");
        };

        comptime if (!@hasDecl(T, "update")) {
            @compileError("A component must at least have an update function!");
        };

        const update = &(struct {
            fn update(self_erased: *anyopaque, ctx: ComponentUpdate) anyerror!void {
                const self: *T = @ptrCast(@alignCast(self_erased));
                return self.update(ctx);
            }
        }).update;
        comptime var begin: ?*const fn (self: *anyopaque, ctx: ComponentBegin) anyerror!void = null;
        comptime if (@hasDecl(T, "begin")) {
            begin = &(struct {
                fn begin_fn(self_erased: *anyopaque, ctx: ComponentBegin) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(self_erased));
                    return self.begin(ctx);
                }
            }).begin_fn;
        };
        comptime var destroyed: ?*const fn (self: *anyopaque, ctx: ComponentDestroyed) anyerror!void = null;
        comptime if (@hasDecl(T, "destroyed")) {
            destroyed = &(struct {
                fn destroyed_fn(self_erased: *anyopaque, ctx: ComponentDestroyed) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(self_erased));
                    return self.destroyed(ctx);
                }
            }).destroyed_fn;
        };
        return .{ .begin = begin, .update = update, .destroyed = destroyed };
    }
};

pub const GenericComponent = struct {
    this: *anyopaque,
    pub fn make(comptime T: type, component: *T) GenericComponent {
        const vtable = ComponentVTable.of(T);
        return .{ .this = component, .vtable = vtable };
    }
};

pub const ComponentStorage = struct {
    arena: ErasedArena,
    erased_arena_vtable: ComponentArenaVTable,
    component_vtable: ComponentVTable,

    pub fn add_component(this: *ComponentStorage, component: anytype) Allocator.Error!ErasedComponentHandle {
        const T = @TypeOf(component);
        const index = try this.arena.push(T, component);
        return ErasedComponentHandle{ .type_id = type_id(T), .index = index };
    }

    // fn get_component(this: *World, allocator: Allocator, index: ErasedComponentHandle) Allocator.Error!?*anyopaque {
    //     const id = index.type_id;
    //     var map = try this.storage.getOrPut(id);
    //     if (!map.found_existing) {
    //         map.value_ptr.* = ComponentStorage{
    //             .arena = try ErasedArena.init(T, allocator),
    //             .vtable = ComponentVTable.of(T),
    //         };
    //     }

    //     return try map.value_ptr.arena.get_ptr(T, index.index);
    // }
};

pub const ComponentArenaVTable = struct {
    begin_all_fn: *const fn (arena: *ErasedArena, context: *World) anyerror!void,
    call_begin_at: *const fn (arena: *ErasedArena, index: ErasedIndex, world: *World, id: EntityID) anyerror!void,
    update_all_fn: *const fn (
        arena: *ErasedArena,
        context: *World,
        delta_time: f64,
    ) anyerror!void,
    destroy_all_fn: *const fn (arena: *ErasedArena, context: *World) anyerror!void,

    pub fn of(comptime T: type) ComponentArenaVTable {
        const info = @typeInfo(T);
        if (info == .Pointer) @compileError("Pointers aren't supported");

        const gen = struct {
            fn begin_all(arena: *ErasedArena, world: *World) anyerror!void {
                if (@hasDecl(T, "begin")) {
                    var arena_interator = arena.iterator(T);
                    while (arena_interator.next()) |value| {
                        try value.begin(ComponentBegin{
                            .world = world,
                            .entity = undefined,
                        });
                    }
                }
            }
            fn call_begin_at(arena: *ErasedArena, index: ErasedIndex, world: *World, id: EntityID) anyerror!void {
                if (@hasDecl(T, "begin")) {
                    const entry = arena.get_ptr(T, index).?;
                    return entry.*.begin(ComponentBegin{
                        .world = world,
                        .entity = id,
                    });
                }
            }
            fn update_all(arena: *ErasedArena, world: *World, dt: f64) anyerror!void {
                var arena_interator = arena.iterator(T);
                while (arena_interator.next()) |value| {
                    try value.update(ComponentUpdate{
                        .delta_time = dt,
                        .world = world,
                        .entity = undefined,
                    });
                }
            }
            fn destroy_all(arena: *ErasedArena, world: *World) anyerror!void {
                if (@hasDecl(T, "destroyed")) {
                    var arena_interator = arena.iterator(T);
                    while (arena_interator.next()) |value| {
                        try value.destroyed(ComponentDestroyed{ .entity = undefined, .world = world });
                    }
                }
            }
        };

        return ComponentArenaVTable{
            .begin_all_fn = gen.begin_all,
            .call_begin_at = gen.call_begin_at,
            .update_all_fn = gen.update_all,
            .destroy_all_fn = gen.destroy_all,
        };
    }
};
