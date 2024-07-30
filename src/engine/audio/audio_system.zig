const std = @import("std");
const al = @import("clibs.zig");
const wav = @import("wav.zig");

var device: ?*al.ALCdevice = null;
var context: ?*al.ALCcontext = null;

pub fn init() void {
    std.debug.assert(device == null);
    device = al.alcOpenDevice(null);

    if (device == null) {
        std.debug.panic("Failed to initialize OpenAL", .{});
    }

    if (al.alcIsExtensionPresent(null, "ALC_ENUMERATION_EXT") == al.AL_TRUE) {
        const device_name = al.alcGetString(device, al.ALC_DEVICE_SPECIFIER);
        std.log.info("OpenAL: initialized with device '{s}'", .{device_name});
    } else {
        std.log.info("OpenAL: initialized with unknown devicee", .{});
    }

    context = al.alcCreateContext(device, null);
    al_check(al.alcMakeContextCurrent(context), "Failed to create context from selected device");
}

pub fn deinit() void {
    al.alcDestroyContext(context);
    al_check(al.alcCloseDevice(device), "Failed to close device");
}

fn al_check(result: al.ALboolean, comptime errmsg: []const u8) void {
    if (result != al.AL_TRUE) {
        const err_id = al.alGetError();
        std.debug.panic("AL function call failed with error code 0x{x}, message: " ++ errmsg, .{err_id});
    }
}
