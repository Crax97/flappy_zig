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

var rand_gen: std.Random = undefined;
var running: bool = true;

const FlappyGame = struct {
    const SPEED: f32 = 100.0;
    bird_texture: TextureInfo = undefined,
    pear_texture: TextureInfo = undefined,
    velocity: Vec2 = Vec2.ZERO,
    pos: Vec2 = Vec2.ZERO,
    rot: f32 = 0.0,
    pipe_manager: PipeManager = .{},
    pub fn init(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        try self.pipe_manager.init();
        self.bird_texture = try load_texture_from_file(engine_inst, "./assets/apple.png");
        self.pear_texture = try load_texture_from_file(engine_inst, "./assets/pear.png");
    }
    pub fn update(self: *FlappyGame, engine_inst: *engine.Engine, delta_seconds: f64) anyerror!void {
        var renderer = &engine_inst.renderer;
        if (engine.Input.is_key_just_down(SDL.SDL_SCANCODE_R)) {
            try self.pipe_manager.init();
            self.pos = Vec2.ZERO;
            self.velocity = Vec2.ZERO;
            running = true;
        }
        if (engine.Input.is_key_down(c.SDL_SCANCODE_SPACE) and running) {
            self.velocity.set_y(-5.0);
        }

        self.velocity.set_y(self.velocity.y() + @as(f32, @floatCast(delta_seconds)) * 10.0);
        self.pos = self.pos.add(self.velocity);

        if (self.pos.y() < -400.0 or self.pos.y() > 400.0) {
            self.pos.set_y(std.math.clamp(self.pos.y(), -400.0, 400.0));
            running = false;
        }

        try renderer.draw_texture(engine.renderer.TextureDrawInfo{
            .texture = self.bird_texture.handle,
            .position = self.pos,
            .rotation = self.rot,
            .scale = Vec2.ONE,
            .region = Rect2{
                .offset = Vec2.ZERO,
                .extent = self.bird_texture.extents,
            },
            .z_index = -5,
        });

        try self.pipe_manager.update(engine_inst, delta_seconds, self.pos);
    }
    pub fn end(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        engine_inst.renderer.free_texture(self.pear_texture.handle);
        engine_inst.renderer.free_texture(self.bird_texture.handle);
    }
};

const Pipe = struct {
    pos: Vec2 = Vec2.ZERO,
    hit: bool = false,
};
const PipeManager = struct {
    const PIPE_HEIGHT: f32 = 600.0;
    const PIPE_WIDTH: f32 = 30.0;
    const PIPE_GAP: f32 = 200.0;
    const PIPE_SPEED: f32 = 300.0;
    const PIPE_DIST: f32 = 300.0;
    pipes: [5]Pipe = .{
        .{},
        .{},
        .{},
        .{},
        .{},
    },

    fn new() PipeManager {
        return .{};
    }

    fn init(this: *PipeManager) !void {
        for (&this.pipes, 0..) |*pipe, i| {
            try reset_pipe(pipe, @intCast(i));
        }
    }

    fn reset_pipe(pipe: *Pipe, index_mult: u32) !void {
        pipe.pos.set_x(700.0 + @as(f32, @floatFromInt(index_mult)) * PIPE_DIST);
        const y = 160.0 * rand_gen.float(f32);
        pipe.pos.set_y(y);
        pipe.hit = false;
    }

    fn update(this: *PipeManager, engine_inst: *engine.Engine, delta_secs: f64, player_pos: Vec2) !void {
        for (&this.pipes) |*pipe| {
            if (running) {
                pipe.pos.set_x(pipe.pos.x() - PIPE_SPEED * @as(f32, @floatCast(delta_secs)));
                if (pipe.pos.x() <= -(600.0 + 2.0 * PIPE_WIDTH)) {
                    try reset_pipe(pipe, 0);
                }
            }

            const rect_1 = Rect2{
                .offset = vec2(pipe.pos.x(), pipe.pos.y() + (PIPE_HEIGHT + PIPE_GAP) * 0.5),
                .extent = vec2(PIPE_WIDTH, PIPE_HEIGHT),
            };

            const rect_2 = Rect2{
                .offset = vec2(pipe.pos.x(), pipe.pos.y() - (PIPE_HEIGHT + PIPE_GAP) * 0.5),
                .extent = vec2(PIPE_WIDTH, PIPE_HEIGHT),
            };

            const gap_rect = Rect2{
                .offset = vec2(pipe.pos.x(), pipe.pos.y() - PIPE_GAP * 0.5),
                .extent = vec2(PIPE_WIDTH, PIPE_HEIGHT),
            };

            var color_1 = math.vec4(0.0, 1.0, 0.0, 1.0);
            var color_2 = math.vec4(0.0, 1.0, 0.0, 1.0);

            if (rect_1.intersects(Rect2{
                .offset = player_pos,
                .extent = vec2(32.0, 32.0),
            })) {
                color_1 = math.vec4(1.0, 0.0, 0.0, 1.0);
                running = false;
            }
            if (rect_2.intersects(Rect2{
                .offset = player_pos,
                .extent = vec2(32.0, 32.0),
            })) {
                color_2 = math.vec4(1.0, 0.0, 0.0, 1.0);
                running = false;
            }

            if (running and gap_rect.intersects(Rect2{
                .offset = player_pos,
                .extent = vec2(32.0, 32.0),
            }) and !pipe.hit) {
                std.debug.print("Point!\n", .{});
                pipe.hit = true;
            }

            var renderer = &engine_inst.renderer;
            try renderer.draw_rect(engine.renderer.RectDrawInfo{
                .color = color_1,
                .rect = rect_1,
            });

            try renderer.draw_rect(engine.renderer.RectDrawInfo{
                .color = color_2,
                .rect = rect_2,
            });
        }
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

    var rand = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    rand_gen = rand.random();

    var engine_instance = try engine.Engine.init(.{
        .width = 400,
        .height = 600,
        .name = "Flappy Game",
    }, allocator);
    defer engine_instance.deinit();

    var game = FlappyGame{};
    try engine_instance.run_loop(engine.Game.make(FlappyGame, &game));
}
