const std = @import("std");
const world_mod = @import("world.zig");
const core = @import("core");
const World = world_mod.World;
const EntityID = world_mod.EntityID;

const ErasedArena = core.ErasedArena;
const ErasedIndex = core.ErasedIndex;

const Allocator = std.mem.Allocator;

const type_id = core.type_id;

pub const ErasedComponentHandle = struct {
    type_id: usize,
    index: ErasedIndex,
    pub fn upcast(this: ErasedComponentHandle, comptime T: type, world: *World) ComponentHandle(T) {
        std.debug.assert(type_id(T) == this.type_id);
        const handle = ComponentHandle(T){
            .handle = this,
            .world = world,
        };
        return handle;
    }
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
    handle: ErasedComponentHandle,

    pub fn component_handle(this: *const ComponentBegin, comptime T: type) ComponentHandle(T) {
        return this.handle.upcast(T, this.world);
    }
};
pub const ComponentDestroyed = struct {
    world: *World,
    entity: EntityID,
    handle: ErasedComponentHandle,

    fn component_handle(this: *const ComponentDestroyed, comptime T: type) ComponentHandle(T) {
        return this.handle.upcast(T, this.world);
    }
};

pub const ComponentUpdate = struct {
    world: *World,
    entity: EntityID,
    handle: ErasedComponentHandle,
    delta_time: f64,

    fn component_handle(this: *const ComponentUpdate, comptime T: type) ComponentHandle(T) {
        return this.handle.upcast(T, this.world);
    }
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

    pub fn get_component(this: *ComponentStorage, comptime T: type, index: ErasedComponentHandle) ?*T {
        return this.arena.get_ptr(T, index.index);
    }
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
                    var arena_interator = arena.iterator_with_index(T);
                    while (arena_interator.next()) |value| {
                        try value.ptr.begin(ComponentBegin{
                            .world = world,
                            .entity = undefined,
                            .handle = ErasedComponentHandle{
                                .index = value.index,
                                .type_id = type_id(T),
                            },
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
                        .handle = ErasedComponentHandle{
                            .index = index,
                            .type_id = type_id(T),
                        },
                    });
                }
            }
            fn update_all(arena: *ErasedArena, world: *World, dt: f64) anyerror!void {
                var arena_interator = arena.iterator_with_index(T);
                while (arena_interator.next()) |value| {
                    try value.ptr.update(ComponentUpdate{
                        .delta_time = dt,
                        .world = world,
                        .entity = undefined,
                        .handle = ErasedComponentHandle{
                            .index = value.index,
                            .type_id = type_id(T),
                        },
                    });
                }
            }
            fn destroy_all(arena: *ErasedArena, world: *World) anyerror!void {
                if (@hasDecl(T, "destroyed")) {
                    var arena_interator = arena.iterator_with_index(T);
                    while (arena_interator.next()) |value| {
                        try value.ptr.destroyed(ComponentDestroyed{
                            .entity = undefined,
                            .world = world,
                            .handle = ErasedComponentHandle{
                                .index = value.index,
                                .type_id = type_id(T),
                            },
                        });
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
