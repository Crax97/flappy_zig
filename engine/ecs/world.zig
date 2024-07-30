const std = @import("std");
const core = @import("core");
const resources = @import("resources.zig");
const events = @import("events.zig");
pub const component_mod = @import("component.zig");

const ComponentVTable = component_mod.ComponentVTable;
const ComponentBegin = component_mod.ComponentBegin;
const ComponentUpdate = component_mod.ComponentUpdate;
const ComponentDestroyed = component_mod.ComponentDestroyed;
const ErasedComponentHandle = component_mod.ErasedComponentHandle;
const ComponentHandle = component_mod.ComponentHandle;
const ComponentStorage = component_mod.ComponentStorage;
const ComponentArenaVTable = component_mod.ComponentArenaVTable;

const Resources = resources.Resources;
const EventQueue = events.EventQueue;

const ErasedArena = core.ErasedArena;
const Allocator = std.mem.Allocator;

const type_id = core.type_id;

const EntityInfoIndex = core.Index(EntityInfo);
pub const EntityID = struct {
    id: EntityInfoIndex,
};

pub const EntityInfo = struct {
    components: std.ArrayList(ErasedComponentHandle),
};
pub const EntityIndex = EntityInfoIndex;

const ComponentMap = std.AutoArrayHashMap(usize, ComponentStorage);
const Entities = core.GenArena(EntityInfo);
const NewComponent = struct {
    data: *anyopaque,
    component_type_id: usize,
    create_storage_fn: *const fn (world: *World) Allocator.Error!ComponentStorage,
    free_fn: *const fn (allocator: Allocator, data: *anyopaque) void,
    add_into_storage_fn: *const fn (storage: *ComponentStorage, value: *anyopaque) Allocator.Error!ErasedComponentHandle,
};
const NewComponents = std.AutoArrayHashMap(usize, NewComponent);
const NewEntity = struct { id: EntityID, components: NewComponents };
const NewEntities = std.ArrayList(NewEntity);

pub const SpawnEntity = struct {
    world: *World,
    new_entity: *NewEntity,
    pub fn new(world: *World) Allocator.Error!SpawnEntity {
        const new_entity = try world.new_entities.addOne();
        new_entity.* = .{
            .id = EntityID{ .id = try world.entities.reserve_index() },
            .components = NewComponents.init(world.allocator),
        };
        return .{
            .world = world,
            .new_entity = new_entity,
        };
    }
    pub fn add_component(this: *SpawnEntity, component: anytype) Allocator.Error!void {
        const T = @TypeOf(component);
        const component_ty_id = type_id(T);
        const component_entry = try this.new_entity.components.getOrPut(component_ty_id);

        if (component_entry.found_existing) {
            std.debug.panic("Component {s} already defined for entity!\n", .{@typeName(T)});
        }

        const gen = struct {
            fn create_storage_fn(world: *World) Allocator.Error!ComponentStorage {
                return ComponentStorage{
                    .arena = try ErasedArena.init(T, world.allocator),
                    .erased_arena_vtable = ComponentArenaVTable.of(T),
                    .component_vtable = ComponentVTable.of(T),
                };
            }
            fn free_fn(allocator: Allocator, data: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(data));
                allocator.destroy(typed);
            }
            fn add_into_storage_fn(storage: *ComponentStorage, value: *anyopaque) Allocator.Error!ErasedComponentHandle {
                const value_typed: *T = @ptrCast(@alignCast(value));
                return try storage.add_component(value_typed.*);
            }
        };

        const new_component = NewComponent{
            .component_type_id = component_ty_id,
            .data = try this.world.allocator.create(T),
            .create_storage_fn = gen.create_storage_fn,
            .free_fn = gen.free_fn,
            .add_into_storage_fn = gen.add_into_storage_fn,
        };
        const val: *T = @ptrCast(@alignCast(new_component.data));
        val.* = component;
        component_entry.value_ptr.* = new_component;
    }
    pub fn id(this: *@This()) EntityID {
        return this.new_entity.id;
    }
};

pub const World = struct {
    storage: ComponentMap,
    allocator: Allocator,
    entities: Entities,
    new_entities: NewEntities,
    resources: Resources,
    event_queue: EventQueue,

    pub fn init(allocator: Allocator) Allocator.Error!World {
        return .{
            .storage = ComponentMap.init(allocator),
            .allocator = allocator,
            .entities = try Entities.init(allocator),
            .new_entities = NewEntities.init(allocator),
            .resources = Resources.init(allocator),
            .event_queue = EventQueue.init(allocator),
        };
    }

    pub fn deinit(this: *World) void {
        var iterator = this.entities.iterator();
        while (iterator.next()) |ent| {
            ent.components.deinit();
        }
        this.entities.deinit();

        for (this.storage.values()) |val| {
            val.arena.deinit();
        }

        this.storage.deinit();

        for (this.new_entities.items) |*ent| {
            var itr = ent.components.iterator();
            while (itr.next()) |comp| {
                comp.value_ptr.free_fn(this.allocator, comp.value_ptr.data);
            }

            ent.components.deinit();
        }
        this.resources.deinit();
        this.new_entities.deinit();
        this.event_queue.deinit();
    }

    pub fn new_entity(this: *World) Allocator.Error!SpawnEntity {
        return SpawnEntity.new(this);
    }

    pub fn begin(this: *World) anyerror!void {
        var iter = this.storage.iterator();
        while (iter.next()) |storage| {
            try storage.value_ptr.erased_arena_vtable.begin_all_fn(&storage.value_ptr.arena, this);
        }
    }

    pub fn update(this: *World, dt: f64) anyerror!void {
        try this.spawn_new_entities();
        var iter = this.storage.iterator();
        while (iter.next()) |storage| {
            try storage.value_ptr.erased_arena_vtable.update_all_fn(&storage.value_ptr.arena, this, dt);
        }
    }

    pub fn destroy(this: *World) anyerror!void {
        var iter = this.storage.iterator();
        while (iter.next()) |storage| {
            try storage.value_ptr.erased_arena_vtable.destroy_all_fn(&storage.value_ptr.arena, this);
        }
    }

    pub fn get_component(this: *World, comptime T: type, entity: EntityID) ?ComponentHandle(T) {
        const info = this.entities.get_ptr(entity.id);
        if (info) |entity_info| {
            // TODO: Convert this to use something else (e.g sparse set, hash map)
            for (entity_info.components.items) |component_handle| {
                if (component_handle.type_id == type_id(T)) {
                    return ComponentHandle(T){ .handle = component_handle, .world = this };
                }
            }
        }
        return null;
    }

    pub fn add_resource(this: *World, resource: anytype) !void {
        try this.resources.add(resource);
    }

    pub fn get_resource(this: *World, comptime T: type) ?*T {
        return this.resources.get(T);
    }

    pub fn get_resource_checked(this: *World, comptime T: type) *T {
        return this.resources.get_checked(T);
    }

    /// Adds an event dispatcher tied to a component.
    /// Prefer this to `add_generic_dispatcher` when you know that the target is a component.
    /// The reason is that a component's address isn't pinned in memory:
    /// their backing storage may be moved around during the lifetime of the application.
    pub fn add_event_dispatcher(this: *World, comptime T: type, handle: ComponentHandle(T), func: anytype) !void {
        return try this.event_queue.register_component_dispatcher(T, handle, func);
    }

    /// Adds a generic event dispatcher to the global event list.
    /// NOTE: The `this` pointer MUST not move in memory after the event dispatcher has been registered!
    /// Violating this invariant will result in undefined behavior! If you can, prefer using the safer
    /// `add_event_dispatcher`
    pub fn add_generic_dispatcher(this: *World, target: anytype, func: anytype) !void {
        return try this.event_queue.register_any_dispatcher(target, func);
    }
    pub fn push_event(this: *World, event: anytype) !void {
        return try this.event_queue.push_event(event, this);
    }

    pub fn get_storage(this: *World, comptime T: type) *ComponentStorage {
        return this.storage.getPtr(type_id(T)).?;
    }

    fn spawn_new_entities(this: *World) anyerror!void {
        for (this.new_entities.items) |*entity| {
            defer entity.components.deinit();

            var entity_info = EntityInfo{ .components = std.ArrayList(ErasedComponentHandle).init(this.allocator) };

            var new_component_itr = entity.components.iterator();
            while (new_component_itr.next()) |new_component| {
                const component_info = new_component.value_ptr;
                const component_ptr = component_info.data;
                defer component_info.free_fn(this.allocator, component_ptr);

                const map = try this.storage.getOrPut(new_component.key_ptr.*);
                if (!map.found_existing) {
                    const storage = try new_component.value_ptr.create_storage_fn(this);
                    map.value_ptr.* = storage;
                }
                const storage = map.value_ptr;

                const handle = try component_info.add_into_storage_fn(storage, component_ptr);
                try entity_info.components.append(handle);
            }

            this.entities.replace_at(entity.id.id, entity_info);

            for (entity_info.components.items) |component| {
                const storage = this.storage.getPtr(component.type_id).?;
                try storage.erased_arena_vtable.call_begin_at(&storage.arena, component.index, this, entity.id);
            }
        }

        this.new_entities.clearRetainingCapacity();
    }
};
