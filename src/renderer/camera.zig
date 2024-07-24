const std = @import("std");

const math = @import("../math/main.zig");

const Vec2 = math.Vec2;
const Mat4 = math.Mat4;

const vec3 = math.vec3;

pub const Camera2D = struct {
    position: Vec2 = Vec2.ZERO,
    rotation: f32 = 0.0,
    zoom: f32 = 1.0,

    near: f32 = 0.001,
    far: f32 = 1000.0,

    extents: Vec2 = Vec2.new(.{ 1240, 720 }),

    pub fn view_matrix(this: *const Camera2D) Mat4 {
        return math.translation(this.position.neg().extend(0.0)).mul(math.scaling(vec3(this.zoom, this.zoom, 1.0))).mul(math.rot_z(std.math.degreesToRadians(this.zoom)));
    }

    pub fn projection_matrix(this: *const Camera2D) Mat4 {
        return math.ortho(-this.extents.x() * 0.5, this.extents.x() * 0.5, -this.extents.y() * 0.5, this.extents.y() * 0.5, this.near, this.far);
    }
};
