const std = @import("std");
const audio_system = @import("audio_system.zig");

pub const WavLoadingError = error{
    NotEnoughData,
    MalformedRiffHeader,
    MalformedFmtHeader,
    MalformedDataHeader,
};

pub const Wav = struct {
    channels: WavChannels,
    audio_format: WavAudioFormat,
    frequency: u32,
    bytes_per_second: u32,
    bytes_per_block: u32,
    sample_size_bits: u32,
    data: []const u8,
};

const WavChannels = enum(u16) {
    Mono = 1,
    Stereo = 2,
};

const WavAudioFormat = enum(u16) {
    PCM = 1,
    Float = 3, // IEEE 754
};

const RIFF: [4]u8 = .{ 'R', 'I', 'F', 'F' };
const WAVE: [4]u8 = .{ 'W', 'A', 'V', 'E' };
const FMT: [4]u8 = .{ 'f', 'm', 't', ' ' };
const DATA: [4]u8 = .{ 'd', 'a', 't', 'a' };

const RiffHeader = extern struct {
    header_id: [4]u8, // Must be 'RIFF'
    file_size: u32, // minus 8 bytes
    file_format: [4]u8, // Must be 'WAVE'
};
const FmtHeader = extern struct {
    format_block: [4]u8, // Must be 'fmt '
    block_size: u32, // Minus 8 bytes
    audio_fmt: WavAudioFormat,
    channels: WavChannels,
    frequency: u32,
    bytes_per_sec: u32, // Frequency * #channels * bits_per_sample/8
    bytes_per_block: u16, // #channels * bits_per_sample / 8
    sample_size_bits: u16,
};
const DataHeader = extern struct {
    data_block_id: [4]u8, // Must be 'data'
    data_size: u32,
};

/// Tries to load a wave file from memory
pub fn wav_parse_from_memory(data: []const u8) WavLoadingError!Wav {
    if (data.len < @sizeOf(RiffHeader) + @sizeOf(FmtHeader) + @sizeOf(DataHeader)) {
        return WavLoadingError.NotEnoughData;
    }
    const riff_header: *align(1) const RiffHeader = @ptrCast(@alignCast(data.ptr));
    if (!std.mem.eql(u8, &riff_header.header_id, &RIFF) or
        !std.mem.eql(u8, &riff_header.file_format, &WAVE))
    {
        return WavLoadingError.MalformedRiffHeader;
    }

    var it: usize = @sizeOf(RiffHeader);
    while (!std.mem.eql(u8, data[it .. it + 4], &FMT) and it < data.len) {
        it += 1;
    }
    if (data[it..].len < @sizeOf(FmtHeader)) {
        return WavLoadingError.NotEnoughData;
    }
    const fmt_header: *align(1) const FmtHeader = @ptrCast(@alignCast(data[it..].ptr));
    if (!std.mem.eql(u8, &fmt_header.format_block, &FMT)) {
        return WavLoadingError.MalformedFmtHeader;
    }
    it += @sizeOf(FmtHeader);

    while (!std.mem.eql(u8, data[it .. it + 4], &DATA) and it < data.len) {
        it += 1;
    }
    if (data[it..].len < @sizeOf(DataHeader)) {
        return WavLoadingError.NotEnoughData;
    }
    const data_header: *align(1) const DataHeader = @ptrCast(@alignCast(data[it..].ptr));
    if (!std.mem.eql(u8, &data_header.data_block_id, &DATA)) {
        std.debug.print("data {s}\n", .{data_header.data_block_id});
        return WavLoadingError.MalformedDataHeader;
    }
    it += @sizeOf(DataHeader);
    if (data[it..].len < data_header.data_size) {
        return WavLoadingError.NotEnoughData;
    }

    return Wav{
        .audio_format = fmt_header.audio_fmt,
        .bytes_per_second = fmt_header.bytes_per_sec,
        .bytes_per_block = @intCast(fmt_header.bytes_per_block),
        .channels = fmt_header.channels,
        .frequency = fmt_header.frequency,
        .sample_size_bits = @intCast(fmt_header.sample_size_bits),
        .data = data[it .. it + data_header.data_size],
    };
}

/// Reads a wav file and duplicates the wav content inside the input 'data' array
/// Remember to free the data with `allocator.free(wav.data)`;
pub fn wav_load_from_memory_alloc(data: []const u8, allocator: std.mem.Allocator) WavLoadingError!Wav {
    var wav = try wav_parse_from_memory(data);
    wav.data = allocator.dupe(u8, wav.data);
    return wav;
}

test "load simple" {
    const source = @embedFile("hit.wav");
    const wav = try wav_parse_from_memory(source);
    try std.testing.expectEqual(176400, wav.bytes_per_second);
    try std.testing.expectEqual(44100, wav.frequency);
    try std.testing.expectEqual(WavChannels.Stereo, wav.channels);
}
