const std = @import("std");
const c = @import("../clibs.zig");
const sdl_util = @import("../sdl_util.zig");
const input = @import("input.zig");
const window = @import("window.zig");
const time = @import("time.zig");
const ecs = @import("../ecs/ecs.zig");

pub const renderer = @import("../renderer/main.zig");

pub const World = ecs.World;
pub const TextureHandle = renderer.TextureHandle;

pub const Texture = renderer.Texture;

pub const Game = struct {
    target: *anyopaque,

    init: *const fn (*anyopaque, engine: *Engine) anyerror!void,
    update: *const fn (*anyopaque, engine: *Engine, delta_seconds: f64) anyerror!void,
    end: *const fn (*anyopaque, engine: *Engine) anyerror!void,

    pub fn make(comptime T: type, target: *T) Game {
        const gen = struct {
            fn init(self: *anyopaque, engine: *Engine) anyerror!void {
                var game_inst: *T = @ptrCast(@alignCast(self));
                return game_inst.init(engine);
            }
            fn update(self: *anyopaque, engine: *Engine, delta_seconds: f64) anyerror!void {
                var game_inst: *T = @ptrCast(@alignCast(self));
                return game_inst.update(engine, delta_seconds);
            }
            fn end(self: *anyopaque, engine: *Engine) anyerror!void {
                var game_inst: *T = @ptrCast(@alignCast(self));
                return game_inst.end(engine);
            }
        };

        return Game{
            .target = target,
            .init = gen.init,
            .update = gen.update,
            .end = gen.end,
        };
    }
};

pub const Engine = struct {
    window: window.Window,
    renderer: renderer.Renderer,
    running: bool = true,
    pub fn init(window_config: window.WindowConfig, allocator: std.mem.Allocator) !Engine {
        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK | c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_TIMER) != 0) {
            sdl_util.sdl_panic();
        }
        var win = window.Window.init(window_config);

        const renderer_instance = try renderer.Renderer.init(&win, allocator);

        try input.init(allocator);

        return .{ .window = win, .renderer = renderer_instance };
    }

    pub fn deinit(this: *Engine) void {
        input.deinit();
        this.renderer.deinit();
        this.window.deinit();
        c.SDL_Quit();
    }

    pub fn run_loop(this: *Engine, game: Game) !void {
        try game.init(game.target, this);
        while (this.running) {
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    c.SDL_QUIT => {
                        this.running = false;
                    },

                    else => {},
                }
            }

            input.update();
            try this.renderer.start_rendering();
            try game.update(game.target, this, time.delta_seconds());
            try this.renderer.render(this.window.viewport_extents());
            input.end_frame();
            time.end_frame();
        }

        try game.end(game.target, this);
    }
};

pub const Input = struct {
    pub const is_key_down = input.is_key_down;
    pub const is_key_up = input.is_key_up;
    pub const is_key_just_down = input.is_key_just_down;
    pub const is_key_just_up = input.is_key_just_up;
};

pub const Time = struct {
    pub const time_since_start = time.time_since_start;
    pub const delta_seconds = time.delta_seconds;
};