const vec = @import("vec.zig");

fn rect_t(comptime T: type, comptime N: comptime_int) type {
    return struct {
        offset: vec.vec_t(T, N),
        extent: vec.vec_t(T, N),
    };
}

pub const vec2 = vec.vec_t(f32, 2);
pub const vec3 = vec.vec_t(f32, 3);
pub const vec4 = vec.vec_t(f32, 4);

pub const rect2 = rect_t(f32, 2);
pub const rect3 = rect_t(f32, 3);

pub fn cross(this: *vec3, other: vec3) vec3 {
    const c1: @Vector(3, f32) = .{ this.data[1], this.data[2], this.data[0] };
    const c2: @Vector(3, f32) = .{ other.data[2], other.data[0], other.data[1] };
    const a = c1 * c2;

    const c3: @Vector(3, f32) = .{ this.data[2], this.data[0], this.data[1] };
    const c4: @Vector(3, f32) = .{ other.data[1], other.data[2], other.data[0] };
    const b = c3 * c4;
    const ret = a - b;

    return vec3{ .data = [3]f32{ ret[0], ret[1], ret[2] } };
}
