const std = @import("std");

const math = @import("math");

const Vec2 = math.Vec2;
const Mat4 = math.Mat4;

const vec3 = math.vec3;

pub const Camera2D = struct {
    position: Vec2 = Vec2.ZERO,
    rotation: f32 = 0.0,
    zoom: f32 = 1.0,

    plane_size: f32 = 1024.0,

    extents: Vec2 = Vec2.new(.{ 1240, 720 }),

    pub fn view_matrix(this: *const Camera2D) Mat4 {
        return math.transformation(
            this.position.extend(0.0),
            vec3(this.zoom, this.zoom, 1.0),
            vec3(0.0, 0.0, std.math.degreesToRadians(this.rotation)),
        )
            .invert().?;
    }

    pub fn projection_matrix(this: *const Camera2D, viewport_extents: Vec2) Mat4 {
        const V = viewport_extents.x() / viewport_extents.y();
        const A = this.extents.x() / this.extents.y();
        const m = V / A;
        const w = this.extents.x() * 0.5;
        const h = this.extents.y() * 0.5;
        const s = this.plane_size * 0.5;
        return math.ortho(-m * w, m * w, -h, h, -s, s);
    }
};
