const std = @import("std");
pub const math = @import("math/main.zig");

test "all" {
    std.testing.refAllDecls(@This());
}
