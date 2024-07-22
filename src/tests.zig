const std = @import("std");
pub const gen_arena = @import("gen_arena.zig");
pub const ecs = @import("ecs/ecs.zig");
pub const util = @import("util.zig");
pub const math = @import("math/main.zig");

test "all" {
    std.testing.refAllDecls(@This());
}
