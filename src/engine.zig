const std = @import("std");
const SDL = @import("sdl2");
const sdl_util = @import("sdl_util.zig");

const window = @import("window.zig");
const renderer = @import("renderer.zig");

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
        this.window.deinit();
    }

    pub fn run_loop(this: *Engine) void {
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
        }
    }
};
