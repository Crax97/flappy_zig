pub const std = @import("std");

pub const vec2 = @Vector(2, f32);
pub const vec3 = @Vector(3, f32);
pub const vec4 = @Vector(4, f32);
pub const dvec2 = @Vector(2, f64);
pub const dvec3 = @Vector(3, f64);
pub const dvec4 = @Vector(4, f64);

pub fn dot(a: anytype, b: anytype) @TypeOf(a) {
    if (@TypeOf(a) != @TypeOf(b)) @compileError("Type of a and b must be equal!");
    const info = @typeInfo(@TypeOf(a));
    if (info != .Vector) @compileError("length can only be called on vectors!");
    const F = info.Vector.child;

    if (info != .Vector) @compileError("Arguments must be vectors!");

    const vv = a * b;
    var accum: F = std.mem.zeroes(F);
    for (0..info.Vector.len) |i| {
        accum += vv[i];
    }
    return accum;
}

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

pub fn length_squared(v: anytype) scalar(@TypeOf(v)) {
    const info = @typeInfo(@TypeOf(v));
    if (info != .Vector) @compileError("length can only be called on vectors!");
    const F = info.Vector.child;

    const vv = v * v;
    var accum: F = std.mem.zeroes(F);
    for (0..info.Vector.len) |i| {
        accum += vv[i];
    }
    return accum;
}

pub fn length(v: anytype) scalar(@TypeOf(v)) {
    return std.math.sqrt(length_squared(v));
}

pub fn normalized(v: anytype) @TypeOf(v) {
    const len = length_squared(v);
    const len_inv = 1.0 / len;
    const splat: @TypeOf(v) = @splat(len_inv);
    return v * splat;
}

fn scalar(comptime V: type) type {
    const info = @typeInfo(V);
    if (info != .Vector) @compileError("length can only be called on vectors!");
    return info.Vector.child;
}
