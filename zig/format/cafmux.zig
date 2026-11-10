// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/cafenc.c (caf_write_header, caf_write_packet,
// caf_write_trailer, put_variable_length_num), mov_chan.c
// (ff_mov_write_chan) and libavcodec's encode.c (an encoder with
// AV_CODEC_CAP_SMALL_LAST_FRAME) at the pinned reference revision describe
// the behavior, restated here.
//! FFmpeg's CAF muxer (TODO.md T31b): PCM (`lpcm`, A-law and µ-law) and
//! ALAC, encoded by FFmpeg's ALAC encoder (`codec/alac.zig`) from 16-bit or
//! 32-bit samples in frames of 4096, the last one short. The header is
//! `caff`, `desc`, `chan` for a named layout, the ALAC magic cookie
//! (`kuki`), the tags (`info`) and `data` sized -1; on an output that can
//! seek back the trailer writes the data's size and, for ALAC, the packet
//! table (`pakt`) after it, as FFmpeg's muxer does. ALAC's variable packets
//! need that table, so ALAC needs a seekable output, as FFmpeg's.

const std = @import("std");
const audio = @import("../core/audio.zig");
const metadata = @import("../core/metadata.zig");
const pcm = @import("../codec/pcm.zig");
const alac = @import("../codec/alac.zig");
const mov_chan = @import("mov_chan.zig");
const seek = @import("seek.zig");

/// What the writer's `data` holds.
pub const Coding = union(enum) {
    /// A PCM codec FFmpeg's CAF muxer takes (`carries`).
    pcm: pcm.Codec,
    /// ALAC from s16 (16 bits) or s32 (24 bits) samples.
    alac: alac.EncodeOptions,
};

/// Whether CAF's muxer carries `codec` (ff_codec_caf_tags): every PCM codec
/// but u8 and the 64-bit integers.
pub fn carries(codec: pcm.Codec) bool {
    return switch (codec) {
        .u8, .s64le, .s64be => false,
        else => true,
    };
}

/// The checks `check` and `begin` share.
pub const HeaderError = error{
    /// CAF does not carry the codec, or the samples' storage is not the
    /// codec's (s16 or s32 for ALAC); more channels than ALAC's encoder
    /// takes.
    UnsupportedFormat,
    /// A zero sample rate, or no channels.
    InvalidFormat,
    /// ALAC's options (prediction orders).
    InvalidOption,
    /// ALAC on an output that cannot seek back for its packet table:
    /// "Muxing variable packet size not supported on non seekable output".
    UnsupportedStreamingSize,
    /// The tags do not fit in an `info` chunk.
    LimitExceeded,
};

pub const WriteError = std.Io.Writer.Error || HeaderError || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
    OutOfMemory,
    /// The seek back to the header failed.
    IoFailure,
};

/// `codec_flags`: kCAFLinearPCMFormatFlagIsFloat (1) and IsLittleEndian
/// (2), as cafenc.c sets them (s8, big-endian integers, A-law and µ-law: 0).
fn codecFlags(codec: pcm.Codec) u32 {
    return switch (codec) {
        .f32be, .f64be => 1,
        .s16le, .s24le, .s32le => 2,
        .f32le, .f64le => 3,
        else => 0,
    };
}

fn formatId(coding: Coding) [4]u8 {
    return switch (coding) {
        .alac => "alac".*,
        .pcm => |codec| switch (codec) {
            .alaw => "alaw".*,
            .mulaw => "ulaw".*,
            else => "lpcm".*,
        },
    };
}

pub const Writer = struct {
    /// ALAC's buffers and packet table; PCM allocates nothing.
    gpa: ?std.mem.Allocator,
    out: *std.Io.Writer,
    seeker: ?seek.OutputSeeker,
    coding: Coding,
    channels: u32,
    /// The offset of `data`'s size field.
    data_at: u64,
    /// ALAC: the encoder, each channel's samples of the frame being filled
    /// (owned) and how many it holds, one packet's buffer, the packet
    /// table's sizes, and the counts the trailer writes.
    encoder: ?*alac.Encoder = null,
    pending: []i32 = &.{},
    pending_len: u32 = 0,
    packet: []u8 = &.{},
    pakt: std.ArrayList(u8) = .empty,
    packets: u64 = 0,
    total_duration: u64 = 0,
    /// Bytes of one input sample: 2 for s16, 4 for s32.
    sample_bytes: u32,

    fn storageOk(coding: Coding, format: audio.Format) bool {
        return switch (coding) {
            .pcm => |codec| carries(codec) and format.sample_format == codec.storage(),
            .alac => format.sample_format == .s16 or format.sample_format == .s32,
        };
    }

    /// Runs `begin`'s checks without writing, so a caller can refuse an
    /// operation before its output exists. `seekable`: the output can seek
    /// back.
    pub fn check(coding: Coding, format: audio.Format, seekable: bool, tags: ?*const metadata.Dictionary) HeaderError!void {
        if (!storageOk(coding, format)) return error.UnsupportedFormat;
        if (format.sample_rate == 0 or format.channelCount() == 0) return error.InvalidFormat;
        switch (coding) {
            .alac => |o| {
                if (format.channelCount() > alac.max_channels) return error.UnsupportedFormat;
                if (!seekable) return error.UnsupportedStreamingSize;
                const in_range = struct {
                    fn f(v: i32) bool {
                        return v >= 1 and v <= 30;
                    }
                }.f;
                if (!in_range(o.min_prediction_order) or !in_range(o.max_prediction_order) or
                    o.max_prediction_order < o.min_prediction_order) return error.InvalidOption;
            },
            .pcm => {},
        }
        _ = try infoLen(tags);
    }

    /// Checks the request, opens the ALAC encoder and writes the header.
    /// `seeker` moves `out` for the trailer; null on a stream (PCM only).
    pub fn begin(gpa: ?std.mem.Allocator, out: *std.Io.Writer, seeker: ?seek.OutputSeeker, coding: Coding, format: audio.Format, tags: ?*const metadata.Dictionary) WriteError!Writer {
        try check(coding, format, seeker != null, tags);
        const channels: u32 = format.channelCount();
        var w: Writer = .{
            .gpa = gpa,
            .out = out,
            .seeker = seeker,
            .coding = coding,
            .channels = channels,
            .data_at = 0,
            .sample_bytes = format.sample_format.bytesPerSample(),
        };
        errdefer w.deinit();
        var cookie: ?[alac.cookie_len]u8 = null;
        switch (coding) {
            .alac => |options| {
                const a = gpa orelse return error.OutOfMemory; // ALAC allocates
                const bits: u32 = if (format.sample_format == .s16) 16 else 24;
                w.encoder = alac.Encoder.create(a, channels, bits, format.sample_rate, options) catch |err| return switch (err) {
                    error.InvalidOption => error.InvalidOption,
                    error.OutOfMemory => error.OutOfMemory,
                };
                cookie = w.encoder.?.cookie();
                w.pending = try a.alloc(i32, channels * alac.frame_size);
                // A short frame has 32 more header bits: room for them too.
                w.packet = try a.alloc(u8, w.encoder.?.maxPacket(alac.frame_size) + 64);
            },
            .pcm => {},
        }
        // caf_write_header.
        try out.writeAll("caff");
        try writeBig(out, u16, 1);
        try writeBig(out, u16, 0);
        try out.writeAll("desc");
        try writeBig(out, u64, 32);
        try writeBig(out, u64, @bitCast(@as(f64, @floatFromInt(format.sample_rate))));
        try out.writeAll(&formatId(coding));
        const flags: u32, const block_align: u32, const frames_per_packet: u32, const bits: u32 = switch (coding) {
            .pcm => |codec| .{ codecFlags(codec), @as(u32, codec.bytesPerSample()) * channels, 1, @as(u32, codec.bytesPerSample()) * 8 },
            // av_get_bits_per_sample(ALAC) is 0.
            .alac => .{ 0, 0, alac.frame_size, 0 },
        };
        try writeBig(out, u32, flags);
        try writeBig(out, u32, block_align);
        try writeBig(out, u32, frames_per_packet);
        try writeBig(out, u32, channels);
        try writeBig(out, u32, bits);
        switch (format.layout) {
            .native => |mask| {
                try out.writeAll("chan");
                try writeBig(out, u64, mov_chan.header_len);
                try out.writeAll(&mov_chan.encode(mask));
            },
            .unspecified, .custom => {},
        }
        if (cookie) |c| {
            try out.writeAll("kuki");
            try writeBig(out, u64, 12 + alac.cookie_len);
            try out.writeAll("\x00\x00\x00\x0cfrmaalac");
            try out.writeAll(&c);
        }
        const info_len = try infoLen(tags);
        if (info_len > 0) {
            const dictionary = tags.?; // a nonzero length means tags
            try out.writeAll("info");
            try writeBig(out, u64, info_len + 4);
            try writeBig(out, u32, @intCast(dictionary.count()));
            for (dictionary.items()) |entry| {
                try out.writeAll(entry.key);
                try out.writeByte(0);
                try out.writeAll(entry.value);
                try out.writeByte(0);
            }
        }
        try out.writeAll("data");
        if (seeker) |sk| {
            try out.flush();
            w.data_at = sk.position();
        }
        try writeBig(out, u64, std.math.maxInt(u64)); // -1: unknown
        try writeBig(out, u32, 0); // mEditCount
        return w;
    }

    pub fn deinit(w: *Writer) void {
        const gpa = w.gpa orelse return;
        if (w.encoder) |e| e.destroy();
        gpa.free(w.pending);
        gpa.free(w.packet);
        w.pakt.deinit(gpa);
        w.encoder = null;
        w.pending = &.{};
        w.packet = &.{};
    }

    /// Whole frames: for PCM, encoded as the codec; for ALAC, interleaved
    /// s16le or s32le samples, every 4096 of a channel a packet.
    pub fn writeData(w: *Writer, data: []const u8) WriteError!void {
        const frame_bytes = switch (w.coding) {
            .pcm => |codec| @as(usize, codec.bytesPerSample()) * w.channels,
            .alac => @as(usize, w.sample_bytes) * w.channels,
        };
        if (data.len % frame_bytes != 0) return error.IncompleteFrame;
        if (w.coding == .pcm) return w.out.writeAll(data);
        const channels: usize = w.channels;
        var rest = data;
        while (rest.len != 0) {
            const take = @min(alac.frame_size - w.pending_len, rest.len / frame_bytes);
            for (0..take) |i| {
                for (0..channels) |c| {
                    const at = rest[(i * channels + c) * w.sample_bytes ..];
                    const v: i32 = if (w.sample_bytes == 2) std.mem.readInt(i16, at[0..2], .little) else std.mem.readInt(i32, at[0..4], .little);
                    w.pending[c * alac.frame_size + w.pending_len + i] = v;
                }
            }
            w.pending_len += take;
            rest = rest[take * frame_bytes ..];
            if (w.pending_len == alac.frame_size) try w.emit();
        }
    }

    /// The pending frame encoded (short only at the end), written and
    /// entered in the packet table (`put_variable_length_num`).
    fn emit(w: *Writer) WriteError!void {
        var planes: [alac.max_channels][]const i32 = undefined;
        for (0..w.channels) |c| planes[c] = w.pending[c * alac.frame_size ..][0..w.pending_len];
        const packet = w.encoder.?.encode(planes[0..w.channels], w.pending_len, w.packet);
        try w.out.writeAll(packet);
        var digits: [5]u8 = undefined;
        try w.pakt.appendSlice(w.gpa.?, variableLengthNum(@intCast(packet.len), &digits));
        w.packets += 1;
        w.total_duration += w.pending_len;
        w.pending_len = 0;
    }

    /// The last ALAC frame, then caf_write_trailer on a seekable output:
    /// the data's size, and for ALAC the packet table after the data; then
    /// a flush.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.coding == .alac and w.pending_len != 0) try w.emit();
        if (w.seeker) |sk| {
            try w.out.flush();
            const file_size = sk.position();
            try sk.seekTo(w.data_at);
            try writeBig(w.out, u64, file_size - w.data_at - 8);
            try w.out.flush();
            try sk.seekTo(file_size);
            if (w.coding == .alac) {
                // ALAC's frame size is 4096: the packets' frames less the
                // samples, the last packet's padding, are its remainder.
                const valid_frames = w.packets * alac.frame_size;
                const remainder = valid_frames - w.total_duration;
                try w.out.writeAll("pakt");
                try writeBig(w.out, u64, 24 + w.pakt.items.len);
                try writeBig(w.out, u64, w.packets);
                try writeBig(w.out, u64, valid_frames - remainder);
                try writeBig(w.out, u32, 0); // mPrimingFrames
                try writeBig(w.out, u32, @intCast(remainder));
                try w.out.writeAll(w.pakt.items);
            }
        }
        try w.out.flush();
    }
};

/// put_variable_length_num: 7 bits a byte, most significant first, the
/// high bit set on all but the last.
fn variableLengthNum(num: u32, buf: *[5]u8) []const u8 {
    var n: usize = 0;
    var j: u5 = 4;
    while (j > 0) : (j -= 1) {
        const top = num >> (@as(u5, j) * 7);
        // FFmpeg stores `top | 128` in a byte: its low 7 bits are the digit.
        if (top != 0) {
            buf[n] = @as(u8, @truncate(top)) | 128;
            n += 1;
        }
    }
    buf[n] = @truncate(num & 127);
    return buf[0 .. n + 1];
}

/// The `info` body's tag bytes (keys and values, each with its NUL), 0
/// without tags.
fn infoLen(tags: ?*const metadata.Dictionary) HeaderError!u64 {
    const dictionary = tags orelse return 0;
    var len: u64 = 0;
    for (dictionary.items()) |entry| len += entry.key.len + entry.value.len + 2;
    if (dictionary.count() > std.math.maxInt(u32)) return error.LimitExceeded;
    return len;
}

fn writeBig(out: *std.Io.Writer, comptime T: type, value: T) std.Io.Writer.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try out.writeAll(&bytes);
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const hostile = @import("../testing/hostile.zig");
const caf = @import("caf.zig");

/// Every sample of an ALAC fixture's packets, as the decoder gives them
/// before any discarding, interleaved as the writer takes them (s16le, or
/// s32le above 16 bits), with the stream's format.
fn decodePackets(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !audio.Format {
    var reader: std.Io.Reader = .fixed(bytes);
    var parser: caf.Parser = .init(&reader, .{});
    parser.enableAlac(gpa, seek.Seeker.fixed(&reader));
    defer parser.deinit();
    const info = try parser.readHeader();
    const a = info.alac.?;
    var decoder: alac.Decoder = .init(gpa, try alac.Config.parse(&a.cookie.?, a.channels));
    defer decoder.deinit();
    const buffer = try gpa.alloc(u8, a.max_packet);
    defer gpa.free(buffer);
    const wide = decoder.config.sample_size > 16;
    while (try parser.nextPacket(buffer)) |packet| {
        const frame = (try decoder.decode(packet.data)).?;
        for (0..frame.samples) |i| {
            for (frame.planes) |plane| {
                if (wide) {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(i32, &b, plane[i], .little);
                    try out.appendSlice(gpa, &b);
                } else {
                    var b: [2]u8 = undefined;
                    std.mem.writeInt(i16, &b, @intCast(plane[i]), .little);
                    try out.appendSlice(gpa, &b);
                }
            }
        }
    }
    var format = info.format;
    format.sample_format = if (wide) .s32 else .s16;
    return format;
}

test "ALAC written again from FFmpeg's CAF files' samples gives the same files" {
    const gpa = testing.allocator;
    inline for (fixtures.alac.all) |fixture| {
        if (comptime std.mem.startsWith(u8, fixture.name, "alac_ffmpeg_")) {
            errdefer std.debug.print("fixture {s}\n", .{fixture.name});
            const bytes = fixtures.alac.bytes(fixture.name);
            var samples: std.ArrayList(u8) = .empty;
            defer samples.deinit(gpa);
            const format = try decodePackets(gpa, bytes, &samples);
            // FFmpeg's encoder options are in the cookie's history fields
            // (level 0 leaves them zero), and the fixture's name.
            var options: alac.EncodeOptions = .{};
            if (comptime std.mem.endsWith(u8, fixture.name, "level0")) options.compression_level = 0;
            if (comptime std.mem.endsWith(u8, fixture.name, "level1")) options.compression_level = 1;
            if (comptime std.mem.endsWith(u8, fixture.name, "orders")) {
                options.min_prediction_order = 1;
                options.max_prediction_order = 30;
            }
            const storage = try gpa.alloc(u8, bytes.len + 4096);
            defer gpa.free(storage);
            var out: std.Io.Writer = .fixed(storage);
            var w: Writer = try .begin(gpa, &out, .fixed(&out), .{ .alac = options }, format, null);
            defer w.deinit();
            // In uneven pieces.
            const frame_bytes = format.bytesPerFrame();
            var at: usize = 0;
            while (at < samples.items.len) {
                const take = @min(samples.items.len - at, frame_bytes * 1000);
                try w.writeData(samples.items[at..][0..take]);
                at += take;
            }
            try w.finish();
            try testing.expectEqualSlices(u8, bytes, out.buffered());
        }
    }
}

test "PCM: FFmpeg's header and flags, the size left -1 on a stream and written on a file" {
    const stereo = try audio.Format.initLayout(8000, audio.ChannelLayout.stereo, .s16);
    const samples = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var stream_bytes: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&stream_bytes);
    var w: Writer = try .begin(null, &stream, null, .{ .pcm = .s16le }, stereo, null);
    try w.writeData(&samples);
    try w.finish();
    const got = stream.buffered();
    // caff 1 0, desc 32, 8000.0, lpcm, flags 2 (little-endian), 4 bytes a
    // packet, 1 frame, 2 channels, 16 bits; chan (stereo's tag); data.
    try testing.expectEqualSlices(u8, "caff\x00\x01\x00\x00desc", got[0..12]);
    try testing.expectEqualSlices(u8, "lpcm\x00\x00\x00\x02\x00\x00\x00\x04\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x10chan", got[28..56]);
    const data = std.mem.indexOf(u8, got, "data").?;
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xff)), got[data + 4 ..][0..8]);
    try testing.expectEqualSlices(u8, &samples, got[data + 16 ..]);
    // A file: the data's size written back.
    var file_bytes: [256]u8 = undefined;
    var file: std.Io.Writer = .fixed(&file_bytes);
    var f: Writer = try .begin(null, &file, .fixed(&file), .{ .pcm = .s16le }, stereo, null);
    try f.writeData(&samples);
    try f.finish();
    try testing.expectEqual(12, std.mem.readInt(u64, file.buffered()[data + 4 ..][0..8], .big));
    try testing.expectEqualSlices(u8, got[0 .. data + 4], file.buffered()[0 .. data + 4]);
    // An incomplete frame, a codec CAF does not carry, a storage that is not the codec's.
    try testing.expectError(error.IncompleteFrame, f.writeData(samples[0..3]));
    try testing.expectError(error.UnsupportedFormat, Writer.check(.{ .pcm = .u8 }, try audio.Format.initLayout(8000, audio.ChannelLayout.mono, .u8), true, null));
    try testing.expectError(error.UnsupportedFormat, Writer.check(.{ .pcm = .s24le }, stereo, true, null));
}

test "ALAC needs an output that seeks back, and its options in range" {
    const stereo = try audio.Format.initLayout(44100, audio.ChannelLayout.stereo, .s16);
    try testing.expectError(error.UnsupportedStreamingSize, Writer.check(.{ .alac = .{} }, stereo, false, null));
    try testing.expectError(error.InvalidOption, Writer.check(.{ .alac = .{ .min_prediction_order = 0 } }, stereo, true, null));
    try testing.expectError(error.InvalidOption, Writer.check(.{ .alac = .{ .min_prediction_order = 9, .max_prediction_order = 8 } }, stereo, true, null));
    const nine = try audio.Format.initLayout(44100, .{ .unspecified = 9 }, .s16);
    try testing.expectError(error.UnsupportedFormat, Writer.check(.{ .alac = .{} }, nine, true, null));
    try Writer.check(.{ .alac = .{} }, stereo, true, null);
}

fn writeUnderFailures(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var samples: std.ArrayList(u8) = .empty;
    defer samples.deinit(gpa);
    const format = decodePackets(gpa, bytes, &samples) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    const storage = try gpa.alloc(u8, bytes.len + 4096);
    defer gpa.free(storage);
    var out: std.Io.Writer = .fixed(storage);
    var w = Writer.begin(gpa, &out, .fixed(&out), .{ .alac = .{} }, format, null) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    defer w.deinit();
    w.writeData(samples.items) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    w.finish() catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
}

test "the ALAC writer frees everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, fixtures.alac.bytes("alac_ffmpeg_one_sample"), writeUnderFailures);
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.fail, fixtures.alac.bytes("alac_ffmpeg_mono_8k"), writeUnderFailures);
}
