const std = @import("std");
const vec = @import("vec.zig");
const scalar = vec.scalar;

// Matrices are column-major
pub fn mat_t(comptime T: type, comptime N: comptime_int) type {
    return extern struct {
        pub const Vec = vec.vec_t(T, N);
        const This = @This();
        cols: [N]Vec,

        pub const IDENTITY: This = identity(T, N);

        pub const ZEROES: This = zeroes(T, N);

        pub fn new_cols(data: [N * N]T) This {
            var cols = std.mem.zeroes([N]Vec);
            inline for (0..N) |i| {
                inline for (0..N) |j| {
                    cols[i].data[j] = data[i * N + j];
                }
            }
            return .{ .cols = cols };
        }
        pub fn new_rows(data: [N * N]T) This {
            var cols = std.mem.zeroes([N]Vec);
            inline for (0..N) |i| {
                inline for (0..N) |j| {
                    cols[j].data[i] = data[i * N + j];
                }
            }
            return .{ .cols = cols };
        }

        pub fn mul(this: *const This, other: This) This {
            var res = This.ZEROES;
            inline for (0..N) |i| {
                inline for (0..N) |j| {
                    res.cols[i].data[j] = this.col(i).dot(other.row(j));
                }
            }

            return res;
        }

        pub fn col(this: *const This, i: usize) Vec {
            return this.cols[i];
        }

        pub fn row(this: *const This, i: usize) Vec {
            var res = Vec.ZERO;
            inline for (0..N) |j| {
                res.data[j] = this.cols[j].data[i];
            }
            return res;
        }

        pub fn det(this: *const This) scalar(T) {
            if (N == 1) {
                return this.cols[0].data[0];
            }

            if (N == 2) {
                return this.el(0, 0) * this.el(1, 1) - this.el(0, 1) * this.el(1, 0);
            }
            if (N == 3) {
                return this.el(0, 0) * this.el(1, 1) * this.el(2, 2) + this.el(0, 1) * this.el(1, 2) * this.el(2, 0) + this.el(0, 2) * this.el(1, 0) + this.el(2, 1) -
                    (this.el(0, 2) * this.el(1, 1) * this.el(2, 0) + this.el(0, 1) * this.el(1, 0) * this.el(2, 2) - this.el(0, 0) * this.el(1, 2) * this.el(2, 1));
            } else {
                return det_doolittle(T, N, this);
            }
        }
        pub fn scaled(this: *const This, value: T) This {
            var res = this.*;
            inline for (0..N) |i| {
                inline for (0..N) |j| {
                    res.cols[j].data[i] *= value;
                }
            }
            return res;
        }

        pub fn expand(this: *const This) mat_t(T, N + 1) {
            var ret = mat_t(T, N + 1).ZEROES;

            inline for (0..N) |i| {
                inline for (0..N) |j| {
                    ret.set(i, j, this.el(i, j));
                }
            }
            ret.cols[N].data[N] = 1.0;
            return ret;
        }

        pub fn truncate(this: *const This) mat_t(T, N - 1) {
            var ret = mat_t(T, N - 1).ZEROES;

            inline for (0..N - 1) |i| {
                inline for (0..N - 1) |j| {
                    ret.set(i, j, this.el(i, j));
                }
            }
            return ret;
        }

        pub fn invert(this: *const This) ?This {
            if (N == 1) {
                const d = this.det();
                if (std.math.approxEqAbs(scalar(T), d, 0.0, 0.0005)) {
                    return null;
                }
                const rep_d = 1.0 / d;
                return .{ .cols = [1]Vec{Vec.new(.{rep_d})} };
            } else if (N == 2) {
                const d = this.det();
                if (std.math.approxEqAbs(scalar(T), d, 0.0, 0.0005)) {
                    return null;
                }
                const rep_d = 1.0 / d;
                return This.new_cols(.{
                    this.el(1, 1),  -this.el(0, 1),
                    -this.el(1, 0), this.el(0, 0),
                }).scaled(rep_d);
            } else if (N == 3) {
                const d = this.det();
                if (std.math.approxEqAbs(scalar(T), d, 0.0, 0.0005)) {
                    return null;
                }
                // TODO: Better algo, extending to mat4, inverting
                // and truncating might not be the best option
                const inv = this.expand().invert().?;
                return inv.truncate();
            } else if (N == 4) {
                // From https://stackoverflow.com/questions/1148309/inverting-a-4x4-matrix
                const A2323 = this.el(2, 2) * this.el(3, 3) - this.el(2, 3) * this.el(3, 2);
                const A1323 = this.el(2, 1) * this.el(3, 3) - this.el(2, 3) * this.el(3, 1);
                const A1223 = this.el(2, 1) * this.el(3, 2) - this.el(2, 2) * this.el(3, 1);
                const A0323 = this.el(2, 0) * this.el(3, 3) - this.el(2, 3) * this.el(3, 0);
                const A0223 = this.el(2, 0) * this.el(3, 2) - this.el(2, 2) * this.el(3, 0);
                const A0123 = this.el(2, 0) * this.el(3, 1) - this.el(2, 1) * this.el(3, 0);
                const A2313 = this.el(1, 2) * this.el(3, 3) - this.el(1, 3) * this.el(3, 2);
                const A1313 = this.el(1, 1) * this.el(3, 3) - this.el(1, 3) * this.el(3, 1);
                const A1213 = this.el(1, 1) * this.el(3, 2) - this.el(1, 2) * this.el(3, 1);
                const A2312 = this.el(1, 2) * this.el(2, 3) - this.el(1, 3) * this.el(2, 2);
                const A1312 = this.el(1, 1) * this.el(2, 3) - this.el(1, 3) * this.el(2, 1);
                const A1212 = this.el(1, 1) * this.el(2, 2) - this.el(1, 2) * this.el(2, 1);
                const A0313 = this.el(1, 0) * this.el(3, 3) - this.el(1, 3) * this.el(3, 0);
                const A0213 = this.el(1, 0) * this.el(3, 2) - this.el(1, 2) * this.el(3, 0);
                const A0312 = this.el(1, 0) * this.el(2, 3) - this.el(1, 3) * this.el(2, 0);
                const A0212 = this.el(1, 0) * this.el(2, 2) - this.el(1, 2) * this.el(2, 0);
                const A0113 = this.el(1, 0) * this.el(3, 1) - this.el(1, 1) * this.el(3, 0);
                const A0112 = this.el(1, 0) * this.el(2, 1) - this.el(1, 1) * this.el(2, 0);

                var mat_d = this.el(0, 0) * (this.el(1, 1) * A2323 - this.el(1, 2) * A1323 + this.el(1, 3) * A1223) - this.el(0, 1) * (this.el(1, 0) * A2323 - this.el(1, 2) * A0323 + this.el(1, 3) * A0223) + this.el(0, 2) * (this.el(1, 0) * A1323 - this.el(1, 1) * A0323 + this.el(1, 3) * A0123) - this.el(0, 3) * (this.el(1, 0) * A1223 - this.el(1, 1) * A0223 + this.el(1, 2) * A0123);
                if (std.math.approxEqAbs(T, mat_d, 0.0, 0.005)) {
                    return null;
                }
                mat_d = 1 / mat_d;

                return This.new_cols(.{
                    mat_d * (this.el(1, 1) * A2323 - this.el(1, 2) * A1323 + this.el(1, 3) * A1223),
                    mat_d * -(this.el(0, 1) * A2323 - this.el(0, 2) * A1323 + this.el(0, 3) * A1223),
                    mat_d * (this.el(0, 1) * A2313 - this.el(0, 2) * A1313 + this.el(0, 3) * A1213),
                    mat_d * -(this.el(0, 1) * A2312 - this.el(0, 2) * A1312 + this.el(0, 3) * A1212),
                    mat_d * -(this.el(1, 0) * A2323 - this.el(1, 2) * A0323 + this.el(1, 3) * A0223),
                    mat_d * (this.el(0, 0) * A2323 - this.el(0, 2) * A0323 + this.el(0, 3) * A0223),
                    mat_d * -(this.el(0, 0) * A2313 - this.el(0, 2) * A0313 + this.el(0, 3) * A0213),
                    mat_d * (this.el(0, 0) * A2312 - this.el(0, 2) * A0312 + this.el(0, 3) * A0212),
                    mat_d * (this.el(1, 0) * A1323 - this.el(1, 1) * A0323 + this.el(1, 3) * A0123),
                    mat_d * -(this.el(0, 0) * A1323 - this.el(0, 1) * A0323 + this.el(0, 3) * A0123),
                    mat_d * (this.el(0, 0) * A1313 - this.el(0, 1) * A0313 + this.el(0, 3) * A0113),
                    mat_d * -(this.el(0, 0) * A1312 - this.el(0, 1) * A0312 + this.el(0, 3) * A0112),
                    mat_d * -(this.el(1, 0) * A1223 - this.el(1, 1) * A0223 + this.el(1, 2) * A0123),
                    mat_d * (this.el(0, 0) * A1223 - this.el(0, 1) * A0223 + this.el(0, 2) * A0123),
                    mat_d * -(this.el(0, 0) * A1213 - this.el(0, 1) * A0213 + this.el(0, 2) * A0113),
                    mat_d * (this.el(0, 0) * A1212 - this.el(0, 1) * A0212 + this.el(0, 2) * A0112),
                }).transpose();
            } else {
                @compileError("TODO");
            }
        }

        pub fn el(this: *const This, i: usize, j: usize) T {
            return this.cols[j].data[i];
        }
        pub fn set(this: *This, i: usize, j: usize, value: T) void {
            this.cols[j].data[i] = value;
        }

        pub fn transpose(this: *const This) This {
            const arr = this.flat_arr();
            var new_arr = std.mem.zeroes([N * N]T);
            inline for (0..N) |i| {
                inline for (0..N) |j| {
                    new_arr[i * N + j] = arr[j * N + i];
                }
            }
            return new_cols(new_arr);
        }

        pub fn flat_arr(this: *const This) [N * N]T {
            var arr = std.mem.zeroes([N * N]T);
            inline for (0..N) |i| {
                inline for (0..N) |j| {
                    arr[i * N + j] = this.cols[i].data[j];
                }
            }
            return arr;
        }
    };
}

fn identity(comptime T: type, comptime N: comptime_int) mat_t(T, N) {
    var cols = std.mem.zeroes([N]vec.vec_t(T, N));
    for (0..N) |i| {
        cols[i].data[i] = 1.0;
    }
    return .{ .cols = cols };
}
fn zeroes(comptime T: type, comptime N: comptime_int) mat_t(T, N) {
    const cols = std.mem.zeroes([N]vec.vec_t(T, N));
    return .{ .cols = cols };
}

// Stolen from https://www.geeksforgeeks.org/doolittle-algorithm-lu-decomposition/
fn det_doolittle(comptime T: type, comptime N: comptime_int, mat: *const mat_t(T, N)) scalar(T) {
    const S = scalar(T);
    var L = mat_t(S, N).ZEROES;
    var U = mat_t(S, N).ZEROES;

    for (0..N) |i| {
        // U
        for (i..N) |k| {
            var sum: S = 0.0;
            for (0..i) |j| {
                sum += L.el(i, j) * U.el(j, k);
            }
            U.set(i, k, mat.el(i, k) - sum);
        }

        // L
        for (i..N) |k| {
            if (i == k) {
                L.set(i, i, 1.0);
            } else {
                var sum: S = 0.0;
                for (0..i) |j| {
                    sum += L.el(k, j) * U.el(j, i);
                }

                L.set(k, i, (mat.el(k, i) - sum) / U.el(i, i));
            }
        }
    }

    var det: S = 1.0;
    for (0..N) |i| {
        det *= @floatCast(U.el(i, i));
    }
    return det;
}
