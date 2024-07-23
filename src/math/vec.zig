const std = @import("std");

pub fn vec_t(comptime T: type, comptime N: comptime_int) type {
    return struct {
        const This = @This();
        const F = scalar(T);

        data: [N]T = std.mem.zeroes([N]T),

        pub fn make(arr: [N]T) This {
            return This{ .data = arr };
        }

        pub fn zero() This {
            return .{};
        }

        pub fn one() This {
            return splat(1.0);
        }

        pub fn splat(value: F) This {
            var ret = This.zero();

            inline for (0..N) |i| {
                ret.data[i] = value;
            }

            return ret;
        }

        pub fn magnitude_squared(this: *This) F {
            var accum: F = std.mem.zeroes(F);

            inline for (0..N) |i| {
                accum += this.data[i] * this.data[i];
            }
            return accum;
        }

        pub fn magnitude(this: *This) F {
            return std.math.sqrt(this.magnitude_squared(this));
        }

        pub fn add(this: *This, other: This) This {
            var ret = This.zero();

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] + other.data[i];
            }

            return ret;
        }

        pub fn sub(this: *This, other: This) This {
            var ret = This.zero();

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] - other.data[i];
            }

            return ret;
        }

        pub fn mul(this: *This, other: This) This {
            var ret = This.zero();

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] * other.data[i];
            }

            return ret;
        }

        pub fn scale(this: *This, amount: T) This {
            var ret = This.zero();

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] * amount;
            }

            return ret;
        }

        pub fn div(this: *This, other: This) This {
            var ret = This.zero();

            inline for (0..N) |i| {
                ret.data[i] = this.data[i] / other.data[i];
            }

            return ret;
        }

        pub fn neg(this: *This) This {
            var ret = This.zero();

            inline for (0..N) |i| {
                ret.data[i] = -this.data[i];
            }

            return ret;
        }

        pub fn normalize(this: *This) This {
            const len = this.magnitude();
            return this.scale(len);
        }

        pub fn dot(this: *This, other: This) F {
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

fn scalar(comptime T: type) type {
    if (@sizeOf(T) > 4) {
        return f64;
    } else {
        return f32;
    }
}
