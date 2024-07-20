const std = @import("std");
const SDL = @import("clibs.zig");
const sdl_util = @import("sdl_util.zig");

const window = @import("window.zig");
const renderer = @import("renderer.zig");
const ecs = @import("ecs/ecs.zig");
const World = ecs.World;

// pub const Texture = renderer.Texture;

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
    // renderer: renderer.Renderer,
    running: bool = true,
    pub fn init(window_config: window.WindowConfig, allocator: std.mem.Allocator) !Engine {
        _ = allocator;
        const win = window.Window.init(window_config);

        // const renderer_instance = try renderer.Renderer.init(&win, allocator);

        // return .{ .window = win, .renderer = renderer_instance };

        return .{ .window = win };
    }

    pub fn deinit(this: *Engine) void {
        // this.renderer.deinit();
        this.window.deinit();
    }

    pub fn run_loop(this: *Engine, game: Game) !void {
        try game.init(game.target, this);
        while (this.running) {
            var event: SDL.SDL_Event = undefined;
            while (SDL.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    SDL.SDL_QUIT => {
                        this.running = false;
                    },
                    else => {},
                }
            }

            // try this.renderer.start_rendering();

            try game.update(game.target, this);

            // try this.renderer.render();
        }

        try game.end(game.target, this);
    }
};
