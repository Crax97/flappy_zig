const std = @import("std");
const SDL = @import("clibs.zig");

pub fn sdl_panic() noreturn {
    const sdl_err = SDL.SDL_GetError();
    std.debug.panic("SDL Error {s}", .{sdl_err});
}

pub const MessageBoxKind = enum { Error, Warning, Info };

pub fn message_box(title: []const u8, content: []const u8, kind: MessageBoxKind) void {
    const sdl_mbox_flags = switch (kind) {
        .Error => SDL.SDL_MESSAGEBOX_ERROR,
        .Info => SDL.SDL_MESSAGEBOX_INFORMATION,
        .Warning => SDL.SDL_MESSAGEBOX_WARNING,
    };

    if (SDL.SDL_ShowSimpleMessageBox(@intCast(sdl_mbox_flags), title.ptr, content.ptr, null) != 0) {
        sdl_panic();
    }
}
