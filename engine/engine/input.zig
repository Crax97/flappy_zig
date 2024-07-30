const std = @import("std");
const c = @import("renderer").c;

const Allocator = std.mem.Allocator;

var current_key_states: []bool = undefined;
var previous_key_states: []bool = undefined;
var key_ptr: [*c]const u8 = undefined;
var num_keys: c_int = 0;
var allocator: Allocator = undefined;

pub fn init(a: Allocator) !void {
    key_ptr = c.SDL_GetKeyboardState(&num_keys);
    current_key_states = try a.alloc(bool, @intCast(num_keys));
    previous_key_states = try a.alloc(bool, @intCast(num_keys));
    allocator = a;
}

pub fn update() void {
    const nk: usize = @intCast(num_keys);
    for (0..nk) |i| {
        current_key_states[i] = (key_ptr[i] == c.SDL_TRUE);
    }
}

pub fn is_key_down(key: c.SDL_Scancode) bool {
    return current_key_states[key];
}

pub fn is_key_up(key: c.SDL_Scancode) bool {
    return !is_key_down(key);
}

pub fn is_key_just_down(key: c.SDL_Scancode) bool {
    return current_key_states[key] and !previous_key_states[key];
}

pub fn is_key_just_up(key: c.SDL_Scancode) bool {
    return !current_key_states[key] and previous_key_states[key];
}

pub fn end_frame() void {
    @memcpy(previous_key_states, current_key_states);
}

pub fn deinit() void {
    allocator.free(current_key_states);
    allocator.free(previous_key_states);
}
