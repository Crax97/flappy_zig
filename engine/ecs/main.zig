const std = @import("std");
pub const component = @import("component.zig");
pub const world = @import("world.zig");
pub const events = @import("events.zig");

pub const World = world.World;
pub const EntityID = world.EntityID;
pub const EntityInfo = world.EntityInfo;
pub const GenericComponent = component.GenericComponent;
pub const ComponentHandle = component.ComponentHandle;
pub const ErasedComponentHandle = component.ErasedComponentHandle;
pub const ComponentVTable = component.ComponentVTable;
pub const ComponentBegin = component.ComponentBegin;
pub const ComponentDestroyed = component.ComponentDestroyed;
pub const ComponentUpdate = component.ComponentUpdate;

test "ecs basics: counter component" {
    const Counter = struct {
        count: u32 = 0.0,

        pub fn update(this: *@This(), ctx: ComponentUpdate) anyerror!void {
            _ = ctx;
            this.count += 1;
        }
    };

    var game_world = try World.init(std.testing.allocator);
    defer game_world.deinit();
    var spawn_counter = try game_world.new_entity();
    try spawn_counter.add_component(Counter{});
    const entity = spawn_counter.id();

    try game_world.begin();

    const sixty_fps_ms = 1.0 / 60.0;
    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);

    const counter_1 = game_world.get_component(Counter, entity).?;

    try std.testing.expectEqual(4, counter_1.get().count);

    spawn_counter = try game_world.new_entity();
    try spawn_counter.add_component(Counter{});
    const entity_2 = spawn_counter.id();

    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);

    const component_ref_2 = game_world.get_component(Counter, entity_2).?;

    try std.testing.expectEqual(2, component_ref_2.get().count);
    try std.testing.expectEqual(6, counter_1.get().count);
}

const vec3 = struct {
    val: union { array: [3]f32, fields: struct { x: f32, y: f32, z: f32 } },

    pub fn zero() vec3 {
        return .{ .val = .{ .fields = .{ .x = 0.0, .y = 0.0, .z = 0.0 } } };
    }
    pub fn add(self: vec3, other: vec3) vec3 {
        return .{ .val = .{ .fields = .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z } } };
    }
};

const BulletComponent = struct {
    direction: vec3,
    id: u32,
    lifetime: f64 = 10.0,
    pub fn begin(this: *BulletComponent, ctx: ComponentBegin) anyerror!void {
        _ = this;
        _ = ctx;
    }

    pub fn update(this: *BulletComponent, ctx: ComponentUpdate) anyerror!void {
        this.lifetime -= ctx.delta_time;
        std.debug.print("I'm a bullet! id {d} lifetime {d}\n", .{ this.id, this.lifetime });
    }
    pub fn destroy(this: *BulletComponent, ctx: ComponentDestroyed) anyerror!void {
        _ = this;
        _ = ctx;
    }
};

const BulletSpawnerComponent = struct {
    spawn_timer: f64,
    current_time: f64 = 0,
    id_counter: u32 = 0,
    pub fn begin(this: *BulletSpawnerComponent, ctx: ComponentBegin) anyerror!void {
        _ = ctx;
        this.spawn_timer = 7.0;
        this.current_time = 0.0;
        this.id_counter = 0;
    }

    pub fn update(this: *BulletSpawnerComponent, ctx: ComponentUpdate) anyerror!void {
        this.current_time += ctx.delta_time;
        if (this.current_time >= this.spawn_timer) {
            var new_entity = try ctx
                .world
                .new_entity();
            try new_entity.add_component(BulletComponent{ .direction = vec3.zero(), .id = this.id_counter });
            // const id = try new_entity.spawn();

            this.id_counter += 1;
            this.current_time = this.current_time - this.spawn_timer;
            // std.debug.print("BulletSpawner spawn bullet id {d}\n", .{id.id.inner_index.index});
        }
    }
};

test "ecs: spawning components" {
    const allocator = std.testing.allocator;

    var game_world = try World.init(allocator);
    defer game_world.deinit();

    var entt = try game_world.new_entity();
    try entt.add_component(BulletSpawnerComponent{ .spawn_timer = 7.0 });

    try game_world.begin();

    try game_world.update(5.0);
    try game_world.update(5.0);
    try game_world.update(5.0);

    try game_world.destroy();
}
