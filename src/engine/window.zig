const std = @import("std");
const SDL = @import("renderer").c;

const math = @import("math");

const sdl_panic = @import("renderer").sdl_util.sdl_panic;

pub const WindowConfig = struct {
    name: []const u8 = "Game",
    width: u32 = 800,
    height: u32 = 600,
};

pub const Window = struct {
    window: *SDL.SDL_Window,
    config: WindowConfig,

    pub fn init(window_config: WindowConfig) Window {
        const width: c_int = @intCast(window_config.width);
        const height: c_int = @intCast(window_config.height);
        const sdl_win = SDL.SDL_CreateWindow(window_config.name.ptr, SDL.SDL_WINDOWPOS_CENTERED, SDL.SDL_WINDOWPOS_CENTERED, width, height, SDL.SDL_WINDOW_VULKAN | SDL.SDL_WINDOW_SHOWN) orelse {
            return sdl_panic();
        };

        return .{ .window = sdl_win, .config = window_config };
    }

    pub fn deinit(this: *Window) void {
        SDL.SDL_DestroyWindow(this.window);
    }

    pub fn viewport_extents(this: *const Window) math.Vec2 {
        return math.vec2(@floatFromInt(this.config.width), @floatFromInt(this.config.height));
    }
};
