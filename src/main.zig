const std = @import("std");
const gen_arena = @import("gen_arena.zig");
const world = @import("ecs/world.zig");
const ComponentBegin = @import("ecs/component.zig").ComponentBegin;
const ComponentUpdate = @import("ecs/component.zig").ComponentUpdate;
const ComponentDestroyed = @import("ecs/component.zig").ComponentDestroyed;
const window = @import("window.zig");
const sdl_util = @import("sdl_util.zig");
const engine = @import("engine.zig");

const math = @import("math/main.zig");
const Vec2 = math.Vec2;
const Rect2 = math.Rect2;

const SDL = @import("clibs.zig");

const World = world.World;

const FlappyGame = struct {
    bird_texture: engine.TextureHandle = undefined,
    pear_texture: engine.TextureHandle = undefined,

    pub fn init(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        self.bird_texture = try load_texture_from_file(engine_inst, "./assets/apple.png");
        self.bird_texture = try load_texture_from_file(engine_inst, "./assets/pear.png");
    }
    pub fn update(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        var renderer = &engine_inst.renderer;
        try renderer.draw_texture(engine.renderer.TextureDrawInfo{
            .texture = self.bird_texture,
            .position = Vec2.new(.{ -0.5, 0.2 }),
            .scale = Vec2.one(),
            .region = Rect2{
                .offset = Vec2.zero(),
                .extent = Vec2{
                    .data = .{ 512.0, 512.0 },
                },
            },
        });
        try renderer.draw_texture(engine.renderer.TextureDrawInfo{
            .texture = self.pear_texture,
            .position = Vec2.new(.{ 0.5, 0.2 }),
            .scale = Vec2.one(),
            .region = Rect2{
                .offset = Vec2.zero(),
                .extent = Vec2{
                    .data = .{ 512.0, 512.0 },
                },
            },
        });
    }
    pub fn end(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        engine_inst.renderer.free_texture(self.bird_texture);
    }
};

fn load_texture_from_file(inst: *engine.Engine, path: []const u8) anyerror!engine.TextureHandle {
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

    return try inst.renderer.alloc_texture(engine.Texture.CreateInfo{ .width = @intCast(width), .height = @intCast(height), .format = format, .initial_bytes = data });
}

pub fn main() !void {
    const buf =
        try std.fs.realpathAlloc(std.heap.page_allocator, ".");
    std.debug.print("cwd {s}\n", .{buf});
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
