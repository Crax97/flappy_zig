const std = @import("std");

const mat = @import("mat.zig");

pub fn vec_t(comptime T: type, comptime N: comptime_int) type {
    return extern struct {
        const This = @This();
        const F = scalar(T);
        const V = @Vector(N, T);

        data: V,

        pub const ZERO: This = splat(0.0);
        pub const ONE: This = splat(1.0);

        pub fn new(arr: [N]T) This {
            return This{ .data = arr };
        }

        pub fn splat(value: F) This {
            return .{
                .data = @splat(value),
            };
        }

        pub fn x(this: *const This) T {
            return this.data[0];
        }

        pub fn y(this: *const This) T {
            if (N < 2) @compileError("Not enough elements! ");
            return this.data[1];
        }

        pub fn z(this: *const This) T {
            if (N < 3) @compileError("Not enough elements! ");
            return this.data[2];
        }

        pub fn w(this: *const This) T {
            if (N < 4) @compileError("Not enough elements! ");
            return this.data[3];
        }

        pub fn set_x(this: *This, value: T) void {
            this.data[0] = value;
        }

        pub fn set_y(this: *This, value: T) void {
            if (N < 2) @compileError("Not enough elements! ");
            this.data[1] = value;
        }

        pub fn set_z(this: *This, value: T) void {
            if (N < 3) @compileError("Not enough elements! ");
            this.data[2] = value;
        }

        pub fn set_w(this: *This, value: T) void {
            if (N < 4) @compileError("Not enough elements! ");
            this.data[3] = value;
        }

        pub fn transform(this: *const This, transformation: mat.mat_t(T, N + 1)) vec_t(T, N + 1) {
            const vec_ext = this.extend(1.0);
            var res = std.mem.zeroes([N + 1]T);
            inline for (0..N + 1) |i| {
                res[i] = transformation.row(i).dot(vec_ext);
            }

            return .{ .data = res };
        }

        pub fn extend(this: *const This, value: T) vec_t(T, N + 1) {
            var data_ext = std.mem.zeroes([N + 1]T);
            inline for (0..N) |i| {
                data_ext[i] = this.data[i];
            }
            data_ext[N] = value;
            return .{ .data = data_ext };
        }

        pub fn truncate(this: *const This) vec_t(T, N - 1) {
            if (N <= 1) @compileError("Can't truncate a vec to less than 1 elements!");
            var data_trunc = std.mem.zeroes([N - 1]T);
            inline for (0..N - 1) |i| {
                data_trunc[i] = this.data[i];
            }
            return .{ .data = data_trunc };
        }

        // Prefer eql_approx, as it is faster
        pub fn eql(this: *const This, other: This) bool {
            inline for (0..N) |i| {
                if (this.data[i] != other.data[i]) {
                    return false;
                }
            }
            return true;
        }
        pub fn eql_approx(this: *const This, other: This, tolerance: T) bool {
            return @abs(@reduce(.Max, this.data - other.data)) < tolerance;
        }

        pub fn magnitude_squared(this: *const This) F {
            return this.dot(this.*);
        }

        pub fn magnitude(this: *const This) F {
            return @sqrt(this.magnitude_squared(this));
        }

        pub fn add(this: *const This, other: This) This {
            return .{
                .data = this.data + other.data,
            };
        }

        pub fn sub(this: *const This, other: This) This {
            return .{
                .data = this.data - other.data,
            };
        }

        pub fn mul(this: *const This, other: This) This {
            return .{
                .data = this.data * other.data,
            };
        }

        pub fn scale(this: *const This, amount: T) This {
            const S: V = @splat(amount);
            return .{
                .data = this.data * S,
            };
        }

        pub fn div(this: *const This, other: This) This {
            return .{
                .data = this.data / other.data,
            };
        }

        pub fn neg(this: *const This) This {
            return .{
                .data = -this.data,
            };
        }

        pub fn normalize(this: *const This) This {
            const len = this.magnitude();
            return this.scale(len);
        }

        pub inline fn dot(this: *const This, other: This) F {
            const D = this.data * other.data;
            return @reduce(.Add, D);
        }

        pub fn array(this: *const This) [N]T {
            return this.data;
        }
    };
}

pub fn scalar(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .Float) {
        return T;
    }
    if (@sizeOf(T) > 4) {
        return f64;
    } else {
        return f32;
    }
}
