const std = @import("std");
const component = @import("component.zig");
const world = @import("world.zig");

pub const GenericComponent = component.GenericComponent;
pub const ComponentHandle = component.ComponentHandle;
pub const ErasedComponentHandle = component.ErasedComponentHandle;
const World = world.World;

const type_id = @import("core").type_id;

const Allocator = std.mem.Allocator;

const EventTargetKind = enum { Component, GenericStruct, FreeFunction };

const EventTarget = union(EventTargetKind) { Component: ErasedComponentHandle, GenericStruct: *anyopaque, FreeFunction };

pub const GenericEventDispatcher = struct {
    target: EventTarget,
    callback: *const fn (EventTarget, []u8, ctx: *World) anyerror!void,
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

    pub fn register_component_dispatcher(this: *EventQueue, comptime T: type, target: ComponentHandle(T), F: anytype) !void {
        const types = infer_event_types(@TypeOf(F));

        const ty_id_event = type_id(types.ty_event);
        const ty_id_self = type_id(types.ty_self);
        if (type_id(T) != ty_id_self) {
            std.debug.panic("Component Handle type and target types must be the same! Func self is {s}", .{@typeName(types.ty_self)});
        }
        var dispatchers = try this.dispatchers.getOrPut(ty_id_event);
        if (!dispatchers.found_existing) {
            dispatchers.value_ptr.* = EventDispatcherList.init(this.allocator);
        }

        const gen = struct {
            fn callback(tgt: EventTarget, event_slice: []u8, ctx: *World) anyerror!void {
                switch (tgt) {
                    .Component => |handle| {
                        std.debug.assert(handle.type_id == type_id(T));
                        const storage = ctx.storage.getPtr(handle.type_id) orelse {
                            return;
                        };
                        const component_p = storage.get_component(types.ty_self, handle) orelse {
                            return;
                        };
                        const event_t: *types.ty_event = @ptrCast(@alignCast(event_slice.ptr));
                        return try F(component_p, event_t.*);
                    },
                    else => {},
                }
            }
        };

        try dispatchers.value_ptr.append(GenericEventDispatcher{
            .target = .{ .Component = target.erase() },
            .callback = gen.callback,
        });
    }

    pub fn register_any_dispatcher(this: *EventQueue, target: anytype, F: anytype) !void {
        const types = infer_event_types(@TypeOf(F));

        const target_ty_info = @typeInfo(@TypeOf(target));
        if (target_ty_info != .Pointer) @compileError("Target must be a pointer to struct!");
        if (types.ty_self != target_ty_info.Pointer.child) @compileError("Target's type must be the same as the first argument of F!");

        const ty_id_event = type_id(types.ty_event);
        var dispatchers = try this.dispatchers.getOrPut(ty_id_event);
        if (!dispatchers.found_existing) {
            dispatchers.value_ptr.* = EventDispatcherList.init(this.allocator);
        }

        const gen = struct {
            fn callback(tgt: EventTarget, event_slice: []u8, ctx: *World) anyerror!void {
                switch (tgt) {
                    .GenericStruct => |ptr| {
                        _ = ctx;
                        const event_t: *types.ty_event = @ptrCast(@alignCast(event_slice.ptr));
                        const component_p: *types.ty_self = @ptrCast(@alignCast(ptr));
                        return try F(component_p, event_t.*);
                    },
                    else => unreachable,
                }
            }
        };

        try dispatchers.value_ptr.append(GenericEventDispatcher{
            .target = .{ .GenericStruct = target },
            .callback = gen.callback,
        });
    }

    pub fn push_event(this: *EventQueue, event: anytype, ctx: *World) !void {
        const ty_id = type_id(@TypeOf(event));

        const dispatchers_for_event = this.dispatchers.getPtr(ty_id) orelse {
            return;
        };
        const event_ptr: [*]u8 = @constCast(@ptrCast(@alignCast(&event)));
        const event_slice = event_ptr[0..@sizeOf(@TypeOf(event))];
        for (dispatchers_for_event.items) |cb| {
            try cb.callback(cb.target, event_slice, ctx);
        }
    }

    const EventTypes = struct {
        ty_event: type,
        ty_self: type,
    };

    fn infer_event_types(comptime F: type) EventTypes {
        const ty_info = @typeInfo(F);
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

        return EventTypes{
            .ty_event = ty_event,
            .ty_self = ty_self,
        };
    }
};
