const std = @import("std");
const SDL = @import("sdl2");
const gen_arena = @import("gen_arena.zig");
const world = @import("ecs/world.zig");
const ComponentBegin = @import("ecs/component.zig").ComponentBegin;
const ComponentUpdate = @import("ecs/component.zig").ComponentUpdate;
const ComponentDestroyed = @import("ecs/component.zig").ComponentDestroyed;
const window = @import("window.zig");
const sdl_util = @import("sdl_util.zig");
const engine = @import("engine.zig");

const World = world.World;

pub fn main() !void {
    if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_JOYSTICK | SDL.SDL_INIT_GAMECONTROLLER) != 0) {
        sdl_util.sdl_panic();
    }
    defer SDL.SDL_Quit();

    var engine_instance = engine.Engine.init(.{});
    defer engine_instance.deinit();

    engine_instance.run_loop();
}
