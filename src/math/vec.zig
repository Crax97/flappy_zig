const std = @import("std");

const mat = @import("mat.zig");

pub fn vec_t(comptime T: type, comptime N: comptime_int) type {
    return struct {
        const This = @This();
        const F = scalar(T);

        data: [N]T align(1) = std.mem.zeroes([N]T),

        pub const ZERO: This = splat(0.0);
        pub const ONE: This = splat(1.0);

        pub fn new(arr: [N]T) This {
            return This{ .data = arr };
        }

        pub fn splat(value: F) This {
            var ret = std.mem.zeroes(This);

            inline for (0..N) |i| {
                ret.data[i] = value;
            }

            return ret;
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
            @memcpy(data_ext[0..N], &this.data);
            data_ext[N] = value;
            return .{ .data = data_ext };
        }

        pub fn truncate(this: *const This) vec_t(T, N - 1) {
            if (N <= 1) @compileError("Can't truncate a vec to less than 1 elements!");
            var data_trunc = std.mem.zeroes([N - 1]T);
            @memcpy(data_trunc[0 .. N - 1], this.data[0 .. N - 1]);
            return .{ .data = data_trunc };
        }

        pub fn eql(this: *const This, other: This) bool {
            inline for (0..N) |i| {
                if (this.data[i] != other.data[i]) {
                    return false;
                }
            }
            return true;
        }
        pub fn eql_approx(this: *const This, other: This, tolerance: T) bool {
            inline for (0..N) |i| {
                if (!std.math.approxEqAbs(T, this.data[i], other.data[i], tolerance)) {
                    return false;
                }
            }
            return true;
        }

        pub fn magnitude_squared(this: *const This) F {
            var accum: F = std.mem.zeroes(F);

            inline for (0..N) |i| {
                accum += this.data[i] * this.data[i];
            }
            return accum;
        }

        pub fn magnitude(this: *const This) F {
            return @sqrt(this.magnitude_squared(this));
        }

        pub fn add(this: *const This, other: This) This {
            var ret = This.ZERO;

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] + other.data[i];
            }

            return ret;
        }

        pub fn sub(this: *const This, other: This) This {
            var ret = This.ZERO;

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] - other.data[i];
            }

            return ret;
        }

        pub fn mul(this: *const This, other: This) This {
            var ret = This.ZERO;

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] * other.data[i];
            }

            return ret;
        }

        pub fn scale(this: *const This, amount: T) This {
            var ret = This.ZERO;

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] * amount;
            }

            return ret;
        }

        pub fn div(this: *const This, other: This) This {
            var ret = This.ZERO;

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] / other.data[i];
            }

            return ret;
        }

        pub fn neg(this: *const This) This {
            var ret = This.ZERO;

            inline for (0..N) |i| {
                ret.data[i] = -this.data[i];
            }

            return ret;
        }

        pub fn normalize(this: *const This) This {
            const len = this.magnitude();
            return this.scale(len);
        }

        pub inline fn dot(this: *const This, other: This) F {
            var accum: F = std.mem.zeroes(F);
            inline for (0..N) |i| {
                const x: F = @floatCast(this.data[i]);
                const y: F = @floatCast(other.data[i]);
                accum += x * y;
            }
            return accum;
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
