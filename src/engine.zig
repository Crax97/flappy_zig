const std = @import("std");
const c = @import("clibs.zig");
const sdl_util = @import("sdl_util.zig");

const window = @import("window.zig");
const ecs = @import("ecs/ecs.zig");

pub const renderer = @import("renderer/main.zig");

pub const World = ecs.World;
pub const TextureHandle = renderer.TextureHandle;

pub const Texture = renderer.Texture;

pub const Game = struct {
    target: *anyopaque,

    init: *const fn (*anyopaque, engine: *Engine) anyerror!void,
    update: *const fn (*anyopaque, engine: *Engine) anyerror!void,
    end: *const fn (*anyopaque, engine: *Engine) anyerror!void,

    pub fn make(comptime T: type, target: *T) Game {
        const gen = struct {
            fn init(self: *anyopaque, engine: *Engine) anyerror!void {
                var game_inst: *T = @ptrCast(@alignCast(self));
                return game_inst.init(engine);
            }
            fn update(self: *anyopaque, engine: *Engine) anyerror!void {
                var game_inst: *T = @ptrCast(@alignCast(self));
                return game_inst.update(engine);
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
        var win = window.Window.init(window_config);

        const renderer_instance = try renderer.Renderer.init(&win, allocator);

        return .{ .window = win, .renderer = renderer_instance };
    }

    pub fn deinit(this: *Engine) void {
        this.renderer.deinit();
        this.window.deinit();
    }

    pub fn run_loop(this: *Engine, game: Game) !void {
        var move_cam_left: f32 = 0.0;
        try game.init(game.target, this);
        while (this.running) {
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    c.SDL_QUIT => {
                        this.running = false;
                    },
                    c.SDL_KEYDOWN => {
                        const key_event = event.key;
                        if (key_event.keysym.sym == c.SDLK_LEFT) {
                            move_cam_left = 1.0;
                        }
                        if (key_event.keysym.sym == c.SDLK_RIGHT) {
                            move_cam_left = -1.0;
                        }
                    },
                    c.SDL_KEYUP => {
                        const key_event = event.key;
                        if (key_event.keysym.sym == c.SDLK_LEFT or
                            key_event.keysym.sym == c.SDLK_RIGHT)
                        {
                            move_cam_left = 0.0;
                        }
                    },

                    else => {},
                }
            }

            const offset = @import("math/main.zig").vec2(move_cam_left, 0.0);
            this.renderer.camera.position = this.renderer.camera.position.add(offset);

            try this.renderer.start_rendering();
            try game.update(game.target, this);
            try this.renderer.render();
        }

        try game.end(game.target, this);
    }
};
