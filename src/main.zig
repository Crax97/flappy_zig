const std = @import("std");
const gen_arena = @import("gen_arena.zig");
const world = @import("ecs/world.zig");
const ComponentBegin = @import("ecs/component.zig").ComponentBegin;
const ComponentUpdate = @import("ecs/component.zig").ComponentUpdate;
const ComponentDestroyed = @import("ecs/component.zig").ComponentDestroyed;

const World = world.World;

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
    lifetime: f32 = 10.0,
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
    spawn_timer: f32,
    current_time: f32 = 0,
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
            new_entity.add_component(BulletComponent{ .direction = vec3.zero(), .id = this.id_counter }) catch {
                std.debug.panic("alloc", .{});
            };
            const id = new_entity.id();

            this.id_counter += 1;
            this.current_time = this.current_time - this.spawn_timer;
            std.debug.print("BulletSpawner spawn bullet id {d}\n", .{id.id.inner_index.index});
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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
