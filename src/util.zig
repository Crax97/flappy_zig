const std = @import("std");

pub fn type_id(comptime T: type) usize {
    const H = struct {
        var x: ?T = null;
    };
    return @intFromPtr(&H.x);
}

test "type id" {
    try std.testing.expectEqual(type_id(u32), type_id(u32));
    try std.testing.expect(type_id(u32) != type_id(i32));
    const Foo = struct {
        value: []const u8,
    };

    const Bar = struct {
        value: []const u8,
    };
    try std.testing.expectEqual(type_id(Foo), type_id(Foo));
    try std.testing.expect(type_id(Foo) != type_id(Bar));
}
