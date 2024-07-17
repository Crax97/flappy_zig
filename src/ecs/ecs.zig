const std = @import("std");
pub const component = @import("component.zig");
pub const world = @import("world.zig");

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
    var spawn_counter = game_world.new_entity();
    try spawn_counter.add_component(Counter{});
    const entity = try spawn_counter.spawn();

    try game_world.begin();

    const sixty_fps_ms = 1.0 / 60.0;
    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);

    const counter_1 = game_world.get_component(Counter, entity).?;

    try std.testing.expectEqual(4, counter_1.get().count);

    spawn_counter = game_world.new_entity();
    try spawn_counter.add_component(Counter{});
    const entity_2 = try spawn_counter.spawn();

    try game_world.update(sixty_fps_ms);
    try game_world.update(sixty_fps_ms);

    const component_ref_2 = game_world.get_component(Counter, entity_2).?;

    try std.testing.expectEqual(2, component_ref_2.get().count);
    try std.testing.expectEqual(6, counter_1.get().count);
}
