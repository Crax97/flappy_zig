const std = @import("std");
const al = @import("clibs.zig");
const core = @import("core");
const wav = @import("wav.zig");

const Allocator = std.mem.Allocator;

pub const SoundEffectHandle = core.Index(SoundEffect);
pub const AudioFormat = enum { Mono, Stereo };

pub const SoundEffectInfo = struct {
    data: []const u8,
    format: AudioFormat,
    byte_size: u32,
    frequency: u32,
};

const SoundEffect = struct {
    buffer: al.ALuint,
    source: al.ALuint,
};
const SoundEffectList = core.GenArena(SoundEffect);
pub const AudioSystem = struct {
    device: ?*al.ALCdevice = null,
    context: ?*al.ALCcontext = null,
    loaded_sound_effects: SoundEffectList,
    alloc: Allocator = undefined,
    pub fn init(allocator: Allocator) !AudioSystem {
        const device = al.alcOpenDevice(null);

        if (device == null) {
            std.debug.panic("Failed to initialize OpenAL", .{});
        }

        if (al.alcIsExtensionPresent(null, "ALC_ENUMERATION_EXT") == al.AL_TRUE) {
            const device_name = al.alcGetString(device, al.ALC_DEVICE_SPECIFIER);
            std.log.info("OpenAL: initialized with device '{s}'", .{device_name});
        } else {
            std.log.info("OpenAL: initialized with unknown devicee", .{});
        }

        const context = al.alcCreateContext(device, null);
        al_check(al.alcMakeContextCurrent(context), "Failed to create context from selected device");

        return .{
            .device = device,
            .context = context,
            .loaded_sound_effects = try SoundEffectList.init(allocator),
            .alloc = allocator,
        };
    }

    pub fn deinit(this: *AudioSystem) void {
        al.alcDestroyContext(this.context);
        al_check(al.alcCloseDevice(this.device), "Failed to close device");
    }

    pub fn create_sound_effect(this: *AudioSystem, info: SoundEffectInfo) !SoundEffectHandle {
        var buffers = [1]al.ALuint{0};
        var sources = [1]al.ALuint{0};
        al_checkv(al.alGenBuffers(1, &buffers), "Failed to create sound buffers");
        al_checkv(al.alGenSources(1, &sources), "Failed to create sound source");
        al_checkv(al.alBufferData(buffers[0], al_format(info), info.data.ptr, @intCast(info.data.len), @intCast(info.frequency)), "Failed to fill sample buffer");

        al_checkv(al.alSourcei(sources[0], al.AL_BUFFER, @intCast(buffers[0])), "Failed to set buffer for source");

        const effect = SoundEffect{
            .buffer = buffers[0],
            .source = sources[0],
        };
        const handle = try this.loaded_sound_effects.push(effect);
        return handle;
    }

    pub fn play_sound_effect(this: *AudioSystem, handle: SoundEffectHandle) void {
        const effect = this.loaded_sound_effects.get(handle).?;
        al_checkv(al.alSourcePlay(effect.source), "Failed to play source");
    }

    pub fn pause_sound_effect(this: *AudioSystem, handle: SoundEffectHandle) void {
        const effect = this.loaded_sound_effects.get(handle).?;
        al_checkv(al.alSourcePause(effect.source), "Failed to pause source");
    }

    pub fn destroy_sound_effect(this: *AudioSystem, handle: SoundEffectHandle) void {
        const effect = this.loaded_sound_effects.get(handle).?;
        al_checkv(al.alDeleteSources(1, &[1]al.ALuint{effect.source}), "Failed to delete source for sound effect!");
        al_checkv(al.alDeleteBuffers(1, &[1]al.ALuint{effect.buffer}), "Failed to delete buffer for sound effect!");
    }
};
fn al_check(result: al.ALboolean, comptime errmsg: []const u8) void {
    const err_id = al.alGetError();
    if (result != al.AL_TRUE) {
        std.debug.panic("AL function call failed with error '{s}', message: " ++ errmsg, .{al_error_msg(err_id)});
    }
}
fn al_checkv(result: void, comptime errmsg: []const u8) void {
    _ = result;
    const err_id = al.alGetError();
    if (err_id != al.AL_NO_ERROR) {
        std.debug.panic("AL function call failed with error '{s}', message: " ++ errmsg, .{al_error_msg(err_id)});
    }
}

fn al_error_msg(err_id: al.ALenum) []const u8 {
    return switch (err_id) {
        al.AL_NO_ERROR => "No error",
        al.AL_INVALID_NAME => "An invalid name was passed to an OpenAL function",
        al.AL_INVALID_ENUM => "An invalid enum value was passed to an OpenAL function",
        al.AL_INVALID_VALUE => "An invalid value was passed to an OpenAL function",
        al.AL_INVALID_OPERATION => "The requested operation is not valid",
        al.AL_OUT_OF_MEMORY => "The requested operation resulted in OpenAL running out of memory",
        else => unreachable,
    };
}

fn al_format(info: SoundEffectInfo) al.ALenum {
    if (info.format == .Mono) {
        if (info.byte_size == 1) {
            return al.AL_FORMAT_MONO8;
        } else if (info.byte_size == 2) {
            return al.AL_FORMAT_MONO16;
        }
    } else if (info.format == .Stereo) {
        if (info.byte_size == 1) {
            return al.AL_FORMAT_STEREO8;
        } else if (info.byte_size == 2) {
            return al.AL_FORMAT_STEREO16;
        }
    }
    unreachable;
}
