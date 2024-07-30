const std = @import("std");
const c = @import("clibs.zig");
const ft = @import("freetype.zig");
const gen_arena = @import("gen_arena.zig");
const ecs = @import("ecs/ecs.zig");
const ComponentBegin = ecs.ComponentBegin;
const ComponentUpdate = ecs.ComponentUpdate;
const ComponentDestroyed = ecs.ComponentDestroyed;
const window = @import("engine/window.zig");
const sdl_util = @import("sdl_util.zig");
const engine = @import("engine/engine.zig");

const math = @import("math/main.zig");
const Vec2 = math.Vec2;
const Rect2 = math.Rect2;
const vec2 = math.vec2;

const TextureHandle = engine.TextureHandle;
const Engine = engine.Engine;
const EntityID = ecs.EntityID;
const ComponentHandle = ecs.ComponentHandle;

const SDL = @import("clibs.zig");

const World = ecs.World;

const GameState = struct {
    bird_alive: bool = true,
    points: u32 = 0,
    num_games: u32 = 0,
};

// from https://github.com/paulkr/Flappy-Bird/tree/master
const font = @embedFile("flappy-font.ttf");

var rand_gen: std.Random = undefined;

const FlappyGame = struct {
    font: engine.FontHandle = undefined,
    bg: TextureInfo = undefined,
    pub fn init(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        engine_inst.renderer.camera.extents = vec2(288.0, 512.0);
        try engine_inst.world.add_resource(GameState{});
        var bird_entity = try engine_inst.world.new_entity();
        try bird_entity.add_component(Bird{});

        var pipe_manager = try engine_inst.world.new_entity();
        try pipe_manager.add_component(PipeManager.new(bird_entity.id()));

        self.font = try engine_inst.font_manager.load(engine.FontDescription{
            .size = 36,
            .data = font,
            .sampler_settings = engine.renderer.SamplerConfig.NEAREST,
        });

        self.bg = try load_texture_from_file(engine_inst, "./assets/sprites/background-day.png");

        try engine_inst.world.add_generic_dispatcher(self, handle_restart_event);
    }

    pub fn handle_restart_event(this: *FlappyGame, event: RestartEvent) anyerror!void {
        _ = this;
        std.debug.print("The player has done {d} games\n", .{event.games});
    }

    pub fn update(self: *FlappyGame, engine_inst: *engine.Engine, delta_seconds: f64) anyerror!void {
        _ = delta_seconds;
        const state = engine_inst.world.get_resource_checked(GameState);

        try engine_inst.renderer.draw_texture(engine.renderer.TextureDrawInfo{
            .texture = self.bg.handle,
            .position = Vec2.ZERO,
            .rotation = 0.0,
            .scale = Vec2.ONE,
            .region = Rect2{
                .offset = Vec2.ZERO,
                .extent = self.bg.extents,
            },
            .z_index = -50,
        });

        try engine_inst.font_manager.render_text_formatted(
            &engine_inst.renderer,
            "{d}",
            .{state.points},
            .{
                .font = self.font,
                .offset = vec2(0.0, -230.0),
            },
        );
    }
    pub fn end(self: *FlappyGame, engine_inst: *engine.Engine) anyerror!void {
        _ = self;
        _ = engine_inst;
    }
};

const RestartEvent = struct { games: u32 };

const Bird = struct {
    const SPEED: f32 = 100.0;
    const GRAVITY: f32 = 20.0;
    const JUMP: f32 = -5.0;
    bird_texture_down: TextureInfo = undefined,
    bird_texture_mid: TextureInfo = undefined,
    bird_texture_up: TextureInfo = undefined,
    fg: TextureInfo = undefined,
    velocity: Vec2 = Vec2.ZERO,
    pos: Vec2 = Vec2.ZERO,
    rot: f32 = 0.0,

    pub fn begin(this: *Bird, ctx: ComponentBegin) anyerror!void {
        _ = ctx;
        this.bird_texture_down = try load_texture_from_file(Engine.instance(), "./assets/sprites/bluebird-downflap.png");
        this.bird_texture_mid = try load_texture_from_file(Engine.instance(), "./assets/sprites/bluebird-midflap.png");
        this.bird_texture_up = try load_texture_from_file(Engine.instance(), "./assets/sprites/bluebird-upflap.png");
        this.fg = try load_texture_from_file(Engine.instance(), "./assets/sprites/base.png");
    }

    pub fn update(this: *Bird, ctx: ComponentUpdate) anyerror!void {
        var renderer = &Engine.instance().renderer;
        const state = ctx.world.get_resource_checked(GameState);

        if (engine.Input.is_key_just_down(SDL.SDL_SCANCODE_R)) {
            this.pos = Vec2.ZERO;
            this.velocity = Vec2.ZERO;
            state.bird_alive = true;
            state.points = 0;
            state.num_games += 1;
            try ctx.world.push_event(RestartEvent{ .games = state.num_games });
        }
        if (engine.Input.is_key_down(c.SDL_SCANCODE_SPACE) and state.bird_alive) {
            this.velocity.set_y(-5.0);
        }

        this.velocity.set_y(this.velocity.y() + @as(f32, @floatCast(ctx.delta_time)) * GRAVITY);
        this.pos = this.pos.add(this.velocity);

        if (this.pos.y() < -256.0 or this.pos.y() > 256.0 - this.fg.extents.y()) {
            this.pos.set_y(std.math.clamp(this.pos.y(), -256.0, 256.0 - this.fg.extents.y()));
            state.bird_alive = false;
        }

        const texture = this.select_texture();
        this.update_rot(ctx.delta_time);

        try renderer.draw_texture(engine.renderer.TextureDrawInfo{
            .texture = texture.handle,
            .position = this.pos,
            .rotation = this.rot,
            .scale = Vec2.ONE,
            .region = Rect2{
                .offset = Vec2.ZERO,
                .extent = texture.extents,
            },
            .z_index = -5,
        });

        try renderer.draw_texture(engine.renderer.TextureDrawInfo{
            .texture = this.fg.handle,
            .position = vec2(0.0, 256.0 - this.fg.extents.y() * 0.5),
            .rotation = 0.0,
            .scale = vec2(1.0, 1.0),
            .region = Rect2{
                .offset = Vec2.ZERO,
                .extent = this.fg.extents,
            },
            .z_index = -7,
        });
    }

    fn select_texture(this: *const Bird) TextureInfo {
        if (this.velocity.y() > 0.5) {
            return this.bird_texture_down;
        }
        if (this.velocity.y() < 0.0) {
            return this.bird_texture_up;
        }
        return this.bird_texture_mid;
    }

    fn update_rot(this: *Bird, dt: f64) void {
        var target_rot: f32 = std.math.pi / 6.0;
        var lerp_speed: f32 = 5.0;
        if (this.velocity.y() < 0.0) {
            target_rot = -target_rot;
            lerp_speed = 30.0;
        }

        this.rot = std.math.lerp(this.rot, target_rot, lerp_speed * @as(f32, @floatCast(dt)));
    }

    pub fn destroyed(this: *Bird, ctx: ComponentDestroyed) anyerror!void {
        _ = ctx;
        Engine.instance().renderer.free_texture(this.bird_texture_down.handle);
        Engine.instance().renderer.free_texture(this.bird_texture_up.handle);
        Engine.instance().renderer.free_texture(this.bird_texture_mid.handle);
        Engine.instance().renderer.free_texture(this.fg.handle);
    }
};

const Pipe = struct {
    pos: Vec2 = Vec2.ZERO,
    hit: bool = false,
};
const PipeManager = struct {
    const PIPE_GAP: f32 = 150.0;
    const PIPE_SPEED: f32 = 200.0;
    const PIPE_DIST: f32 = 300.0;
    const PIPE_MAX_HEIGHT: f32 = 20.0;
    const PIPE_MIN_HEIGHT: f32 = -150.0;
    pipes: [5]Pipe = .{
        .{},
        .{},
        .{},
        .{},
        .{},
    },
    player: EntityID,
    bird: ComponentHandle(Bird) = undefined,
    pipe_texture: TextureInfo = undefined,
    last_reset_pipe: usize = 4,

    fn new(player: EntityID) PipeManager {
        return .{
            .player = player,
        };
    }

    pub fn begin(this: *PipeManager, ctx: ComponentBegin) anyerror!void {
        try this.init();
        this.bird = ctx.world.get_component(Bird, this.player).?;
        this.pipe_texture = try load_texture_from_file(Engine.instance(), "assets/sprites/pipe-green.png");

        try ctx.world.add_event_dispatcher(PipeManager, ctx.component_handle(PipeManager), on_restart_event);
    }

    pub fn on_restart_event(this: *PipeManager, event: RestartEvent) anyerror!void {
        try this.init();
        _ = event;
    }

    fn init(this: *PipeManager) !void {
        for (&this.pipes, 0..) |*pipe, i| {
            const x_off = 256.0 + @as(f32, @floatFromInt(i)) * PIPE_DIST;
            try reset_pipe(pipe, x_off);
        }
        this.last_reset_pipe = this.pipes.len - 1;
    }

    fn reset_pipe(pipe: *Pipe, x_off: f32) !void {
        pipe.pos.set_x(x_off);
        const y = PIPE_MIN_HEIGHT + (PIPE_MAX_HEIGHT - PIPE_MIN_HEIGHT) * rand_gen.float(f32);
        pipe.pos.set_y(y);
        pipe.hit = false;
    }

    pub fn update(this: *PipeManager, ctx: ComponentUpdate) !void {
        const bird = this.bird.get();
        const player_pos = bird.pos;
        const delta_secs = ctx.delta_time;
        var engine_inst = Engine.instance();
        const state = ctx.world.get_resource_checked(GameState);

        var renderer = &engine_inst.renderer;
        for (&this.pipes, 0..) |*pipe, i| {
            if (state.bird_alive) {
                pipe.pos.set_x(pipe.pos.x() - PIPE_SPEED * @as(f32, @floatCast(delta_secs)));
                if (pipe.pos.x() <= -(288.0 + 2.0 * this.pipe_texture.extents.x())) {
                    const furthest = this.pipes[this.last_reset_pipe].pos.x();
                    try reset_pipe(pipe, furthest + PIPE_DIST);
                    this.last_reset_pipe = i;
                }
            }

            const rect_1 = Rect2{
                .offset = vec2(pipe.pos.x(), pipe.pos.y() + (this.pipe_texture.extents.y() + PIPE_GAP) * 0.5),
                .extent = vec2(this.pipe_texture.extents.x(), this.pipe_texture.extents.y()),
            };

            const rect_2 = Rect2{
                .offset = vec2(pipe.pos.x(), pipe.pos.y() - (this.pipe_texture.extents.y() + PIPE_GAP) * 0.5),
                .extent = vec2(this.pipe_texture.extents.x(), this.pipe_texture.extents.y()),
            };

            const gap_rect = Rect2{
                .offset = vec2(pipe.pos.x(), pipe.pos.y() - PIPE_GAP * 0.5),
                .extent = vec2(this.pipe_texture.extents.x(), this.pipe_texture.extents.y()),
            };

            var color_1 = math.vec4(0.0, 1.0, 0.0, 1.0);
            var color_2 = math.vec4(0.0, 1.0, 0.0, 1.0);

            if (rect_1.intersects(Rect2{
                .offset = player_pos,
                .extent = vec2(32.0, 32.0),
            })) {
                color_1 = math.vec4(1.0, 0.0, 0.0, 1.0);
                state.bird_alive = false;
            }
            if (rect_2.intersects(Rect2{
                .offset = player_pos,
                .extent = vec2(32.0, 32.0),
            })) {
                color_2 = math.vec4(1.0, 0.0, 0.0, 1.0);
                state.bird_alive = false;
            }

            if (state.bird_alive and gap_rect.intersects(Rect2{
                .offset = player_pos,
                .extent = vec2(32.0, 32.0),
            }) and !pipe.hit) {
                state.points += 1;
                pipe.hit = true;
            }

            try renderer.draw_texture(engine.renderer.TextureDrawInfo{
                .texture = this.pipe_texture.handle,
                .position = rect_1.offset,
                .rotation = 0.0,
                .scale = Vec2.ONE,
                .region = Rect2{
                    .offset = Vec2.ZERO,
                    .extent = this.pipe_texture.extents,
                },
                .z_index = -10,
            });

            try renderer.draw_texture(engine.renderer.TextureDrawInfo{
                .texture = this.pipe_texture.handle,
                .position = rect_2.offset,
                .rotation = 0.0,
                .scale = vec2(1.0, -1.0),
                .region = Rect2{
                    .offset = Vec2.ZERO,
                    .extent = this.pipe_texture.extents,
                },
                .z_index = -10,
            });
        }
    }

    fn destroyed(this: *PipeManager, ctx: ComponentDestroyed, foo: u32) anyerror!void {
        _ = foo;
        _ = ctx;
        Engine.instance().renderer.free_texture(this.pipe_texture.handle);
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
    const data_size = width * height * 4;
    const format = engine.renderer.TextureFormat.rgba_8;
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

    var lib: ft.FT_Library = undefined;
    const err = ft.FT_Init_FreeType(&lib);
    if (err != ft.FT_Err_Ok) {
        std.debug.panic("Freetype err", .{});
    }

    var rand = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    rand_gen = rand.random();

    var engine_instance = try engine.Engine.init(.{
        .width = 288 * 2,
        .height = 512 * 2,
        .name = "Flappy Game",
    }, allocator);
    defer engine_instance.deinit();

    var game = FlappyGame{};
    try engine_instance.run_loop(engine.Game.make(FlappyGame, &game));
}
