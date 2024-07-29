const std = @import("std");
const component = @import("component.zig");

pub const GenericComponent = component.GenericComponent;
pub const ComponentHandle = component.ComponentHandle;
pub const ErasedComponentHandle = component.ErasedComponentHandle;

const type_id = @import("../util.zig").type_id;

const Allocator = std.mem.Allocator;

pub const GenericEventDispatcher = struct {
    target: ErasedComponentHandle,
    callback: *const fn (ErasedComponentHandle, []u8, storage: *component.ComponentStorage) anyerror!void,
};

const EventDispatcherList = std.ArrayList(GenericEventDispatcher);
const EventDispatcherMap = std.AutoArrayHashMap(usize, EventDispatcherList);
pub const EventQueue = struct {
    allocator: Allocator,
    dispatchers: EventDispatcherMap,

    pub fn init(allocator: Allocator) EventQueue {
        return .{
            .allocator = allocator,
            .dispatchers = EventDispatcherMap.init(allocator),
        };
    }

    pub fn deinit(this: *EventQueue) void {
        for (this.dispatchers.values()) |val| {
            val.deinit();
        }
        this.dispatchers.deinit();
    }

    pub fn register_dispatcher(this: *EventQueue, target: ErasedComponentHandle, F: anytype) !void {
        const f_ty_id = @TypeOf(F);
        const ty_info = @typeInfo(f_ty_id);
        if (ty_info != .Fn) @compileError("Only functions can be registered as dispatchers");
        if (ty_info.Fn.params.len != 2) @compileError("An event dispatcher must have two args: the self param, and the event type");
        const arg_self = ty_info.Fn.params[0];
        const arg_event = ty_info.Fn.params[1];
        const ty_info_self_p = @typeInfo(arg_self.type.?);

        const ty_event = arg_event.type.?;

        const ty_info_event = @typeInfo(ty_event);
        if (ty_info_self_p != .Pointer) @compileError("Self arg must be a pointer to a struct");
        const ty_self = ty_info_self_p.Pointer.child;
        if (@typeInfo(ty_self) != .Struct) @compileError("Self arg must be a pointer to a struct");
        if (ty_info_event != .Struct) @compileError("Self arg must be a struct");

        const ty_id_event = type_id(ty_event);
        // if (target.type_id != ty_id_self) @compileError("Component Handle type and target types must be the same! Func self is " ++ @typeName(ty_self));
        var dispatchers = try this.dispatchers.getOrPut(ty_id_event);
        if (!dispatchers.found_existing) {
            dispatchers.value_ptr.* = EventDispatcherList.init(this.allocator);
        }

        const gen = struct {
            fn callback(handle: ErasedComponentHandle, event_slice: []u8, storage: *component.ComponentStorage) anyerror!void {
                const component_p = storage.get_component(ty_self, handle) orelse {
                    return;
                };
                const event_t: *ty_event = @ptrCast(@alignCast(event_slice.ptr));
                return try F(component_p, event_t.*);
            }
        };

        try dispatchers.value_ptr.append(GenericEventDispatcher{
            .target = target,
            .callback = gen.callback,
        });
    }

    pub fn push_event(this: *EventQueue, event: anytype, component_storage_map: *std.AutoArrayHashMap(usize, component.ComponentStorage)) !void {
        const ty_id = type_id(@TypeOf(event));

        const dispatchers_for_event = this.dispatchers.getPtr(ty_id) orelse {
            return;
        };
        const event_ptr: [*]u8 = @constCast(@ptrCast(@alignCast(&event)));
        const event_slice = event_ptr[0..@sizeOf(@TypeOf(event))];
        for (dispatchers_for_event.items) |cb| {
            const storage = component_storage_map.getPtr(cb.target.type_id) orelse {
                return;
            };
            try cb.callback(cb.target, event_slice, storage);
        }
    }
};
