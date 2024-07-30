const std = @import("std");
pub const core = @import("core");
pub const math = @import("math");
pub const ecs = @import("ecs");

test "all" {
    std.testing.refAllDecls(@This());
}
