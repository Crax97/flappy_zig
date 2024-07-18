const std = @import("std");
const SDL = @import("sdl2");
const sdl_util = @import("sdl_util.zig");

const window = @import("window.zig");

pub const Engine = struct {
    window: window.Window,
    running: bool = true,
    pub fn init(window_config: window.WindowConfig) Engine {
        const win = window.Window.init(window_config);

        return .{ .window = win };
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
