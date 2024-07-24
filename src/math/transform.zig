const std = @import("std");
const main = @import("main.zig");

const Mat4 = main.Mat4;
const Vec2 = main.Vec2;

pub const Transform2D = struct {
    position: Vec2,
    rotation: f32,
    z_index: f32,
    scale: Vec2,
};
