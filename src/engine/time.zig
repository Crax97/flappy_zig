const std = @import("std");
const c = @import("renderer").c;

const Allocator = std.mem.Allocator;

var current_time_ms: u64 = 0;
var last_time_ms: u64 = 0;
var total_seconds: f64 = 0.0;
var delta_secs: f64 = 0.0;

pub fn time_since_start() f64 {
    return total_seconds;
}

pub fn delta_seconds() f64 {
    return delta_secs;
}

pub fn end_frame() void {
    current_time_ms = c.SDL_GetTicks64();
    total_seconds = @as(f64, @floatFromInt(current_time_ms)) / 1000.0;
    const delta = current_time_ms - last_time_ms;
    last_time_ms = current_time_ms;

    delta_secs = @as(f64, @floatFromInt(delta)) / 1000.0;
}
