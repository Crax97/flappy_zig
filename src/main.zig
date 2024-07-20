const std = @import("std");
const gen_arena = @import("gen_arena.zig");
const world = @import("ecs/world.zig");
const ComponentBegin = @import("ecs/component.zig").ComponentBegin;
const ComponentUpdate = @import("ecs/component.zig").ComponentUpdate;
const ComponentDestroyed = @import("ecs/component.zig").ComponentDestroyed;
const window = @import("window.zig");
const sdl_util = @import("sdl_util.zig");
const engine = @import("engine.zig");

const SDL = @import("clibs.zig");

const World = world.World;

const FlappyGame = struct {
    // bird_texture: engine.Texture = undefined,

    pub fn init(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        _ = self;
        _ = engine_inst;
        // self.bird_texture = try load_texture_from_file(engine_inst, "./bird.png");
    }
    pub fn update(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        _ = self;
        _ = engine_inst;

        // var renderer = &engine_inst.renderer;
        // renderer.draw_texture(self.bird_texture, vec3(bird_transform, 0.0));
    }
    pub fn end(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        _ = self;
        _ = engine_inst;
    }
};

fn load_texture_from_file(inst: *engine.Engine, path: []const u8) anyerror!engine.Texture {
    _ = path;
    _ = inst;

    return undefined;
}

pub fn main() !void {
    if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_JOYSTICK | SDL.SDL_INIT_GAMECONTROLLER) != 0) {
        sdl_util.sdl_panic();
    }
    defer SDL.SDL_Quit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var engine_instance = try engine.Engine.init(.{}, allocator);
    defer engine_instance.deinit();

    var game = FlappyGame{};
    try engine_instance.run_loop(engine.Game.make(FlappyGame, &game));
}

fn update(engine_inst: *engine.Engine) !void {
    _ = engine_inst;
}
