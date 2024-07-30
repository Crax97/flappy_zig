const gen_arena = @import("gen_arena.zig");
const util = @import("util.zig");

pub const GenArena = gen_arena.GenArena;
pub const Index = gen_arena.Index;
pub const ErasedArena = gen_arena.ErasedArena;
pub const ErasedIndex = gen_arena.ErasedIndex;

pub const type_id = util.type_id;

test "all" {
    @import("std").testing.refAllDecls(@This());
}
