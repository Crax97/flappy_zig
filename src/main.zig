const std = @import("std");
const gen_arena = @import("gen_arena.zig");
const world = @import("world.zig");

const World = world.World;

const vec3 = struct {
    val: union { array: [3]f32, fields: struct { x: f32, y: f32, z: f32 } },

    pub fn add(self: vec3, other: vec3) vec3 {
        return .{ .val = .{ .fields = .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z } } };
    }
};

const BulletComponent = struct {
    direction: vec3,
    spawn_timer: f32,
    current_time: f32,
    fn begin(this: *BulletComponent, ctx: *World) void {
        _ = ctx;
        this.spawn_timer = 7.0;
        this.current_time = 0.0;
    }

    fn update(this: *BulletComponent, ctx: *World, dt: f32) void {
        _ = ctx;

        this.current_time += dt;
        if (this.current_time >= this.spawn_timer) {
            // ctx.spawn_entity()
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var game_world = try World.init(allocator);
    defer game_world.deinit();

    game_world.begin();

    game_world.update(1.0 / 60.0);
    game_world.update(1.0 / 30.0);
    game_world.update(1.0 / 15.0);

    game_world.destroy();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
