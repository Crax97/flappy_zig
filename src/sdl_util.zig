const std = @import("std");
const SDL = @import("sdl2");

pub fn sdl_panic() noreturn {
    const sdl_err = SDL.SDL_GetError();
    std.debug.panic("SDL Error {s}", .{sdl_err});
}
