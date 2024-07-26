const std = @import("std");
const c = @import("clibs.zig");
const gen_arena = @import("gen_arena.zig");
const world = @import("ecs/world.zig");
const ComponentBegin = @import("ecs/component.zig").ComponentBegin;
const ComponentUpdate = @import("ecs/component.zig").ComponentUpdate;
const ComponentDestroyed = @import("ecs/component.zig").ComponentDestroyed;
const window = @import("engine/window.zig");
const sdl_util = @import("sdl_util.zig");
const engine = @import("engine/engine.zig");

const math = @import("math/main.zig");
const Vec2 = math.Vec2;
const Rect2 = math.Rect2;
const vec2 = math.vec2;

const TextureHandle = engine.TextureHandle;

const SDL = @import("clibs.zig");

const World = world.World;

const FlappyGame = struct {
    const SPEED: f32 = 100.0;
    bird_texture: TextureInfo = undefined,
    pear_texture: TextureInfo = undefined,
    velocity: Vec2 = Vec2.ZERO,
    pos: Vec2 = Vec2.ZERO,
    rot: f32 = 0.0,

    pub fn init(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        self.bird_texture = try load_texture_from_file(engine_inst, "./assets/apple.png");
        self.pear_texture = try load_texture_from_file(engine_inst, "./assets/pear.png");
    }
    pub fn update(self: *FlappyGame, engine_inst: *engine.Engine, delta_seconds: f64) anyerror!void {
        var renderer = &engine_inst.renderer;
        if (engine.Input.is_key_down(c.SDL_SCANCODE_SPACE)) {
            self.velocity.set_y(-10.0);
        }

        self.velocity.set_y(self.velocity.y() + @as(f32, @floatCast(delta_seconds)) * 10.0);

        self.pos = self.pos.add(self.velocity);
        try renderer.draw_texture(engine.renderer.TextureDrawInfo{
            .texture = self.bird_texture.handle,
            .position = self.pos,
            .rotation = self.rot,
            .scale = Vec2.ONE,
            .region = Rect2{
                .offset = Vec2.ZERO,
                .extent = self.bird_texture.extents,
            },
            .z_index = -1,
        });

        try renderer.draw_rect(engine.renderer.RectDrawInfo{
            .color = math.vec4(0.0, 1.0, 0.0, 1.0),
            .rect = Rect2{
                .offset = vec2(50.0, 0.0),
                .extent = vec2(30.0, 60.0),
            },
        });
    }
    pub fn end(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        engine_inst.renderer.free_texture(self.pear_texture.handle);
        engine_inst.renderer.free_texture(self.bird_texture.handle);
    }
};

const TextureInfo = struct {
    handle: TextureHandle,
    extents: Vec2,
};

fn load_texture_from_file(inst: *engine.Engine, path: []const u8) anyerror!TextureInfo {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;

    const data_p = SDL.stbi_load(path.ptr, &width, &height, &channels, 4);
    std.debug.assert(data_p != null);
    defer SDL.stbi_image_free(data_p);
    const data_size = width * height * channels;
    const format = switch (channels) {
        4 => engine.renderer.TextureFormat.rgba_8,
        else => unreachable,
    };
    const data = data_p[0..@intCast(data_size)];

    const handle = try inst.renderer.alloc_texture(engine.Texture.CreateInfo{
        .width = @intCast(width),
        .height = @intCast(height),
        .format = format,
        .initial_bytes = data,
        .sampler_config = engine.renderer.SamplerConfig.NEAREST,
    });

    return TextureInfo{
        .handle = handle,
        .extents = vec2(@floatFromInt(width), @floatFromInt(height)),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var engine_instance = try engine.Engine.init(.{
        .width = 400,
        .height = 600,
        .name = "Flappy Game",
    }, allocator);
    defer engine_instance.deinit();

    var game = FlappyGame{};
    try engine_instance.run_loop(engine.Game.make(FlappyGame, &game));
}

fn update(engine_inst: *engine.Engine) !void {
    _ = engine_inst;
}
