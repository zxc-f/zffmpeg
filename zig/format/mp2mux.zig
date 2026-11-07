// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/rawenc.c (ff_mp2_muxer, ff_raw_write_packet), libavcodec's
// encode.c (pad_last_frame) and the ffmpeg program's frame grouping for an
// encoder with a fixed frame size (av_buffersink_set_frame_size) at the
// pinned reference revision describe the behavior, restated here.
//! FFmpeg's mp2 muxer with its MP2 encoder, as a PCM writer (TODO.md T29d):
//! 16-bit samples in, grouped into frames of 1152 samples as the ffmpeg
//! program's filter graph groups them for the encoder, the last one padded
//! with silence as encode.c pads it, and each packet written as it is (the
//! raw muxer adds nothing). The bytes are the same on a file and a pipe.
//! The encoder is `codec/mp2enc.zig`; the writer does not allocate.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const mp2enc = @import("../codec/mp2enc.zig");

pub const Options = mp2enc.Options;

/// The checks `check` and `begin` share: the encoder's (mp2enc.Error), and
/// a storage other than s16.
pub const HeaderError = mp2enc.Error;

pub const WriteError = std.Io.Writer.Error || HeaderError || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
};

pub const Writer = struct {
    out: *std.Io.Writer,
    encoder: mp2enc.Encoder,
    channels: usize,
    /// Samples (interleaved) not yet a whole frame.
    pending: [mp2enc.frame_samples * 2]i16 = undefined,
    pending_len: usize = 0,

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists: the samples must be s16 (the
    /// encoder's only format), the layout mono or stereo (or two
    /// unnamed channels), the rate, channels and bit rate the encoder's.
    pub fn check(codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!void {
        _ = try encoderFor(codec, format, options);
    }

    fn encoderFor(codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!mp2enc.Encoder {
        if (codec != .s16le or format.sample_format != .s16) return error.UnsupportedFormat;
        const layout_ok = switch (format.layout) {
            .unspecified => true,
            .native, .custom => format.layout.eql(&audio.ChannelLayout.mono) or format.layout.eql(&audio.ChannelLayout.stereo),
        };
        if (!layout_ok) return error.UnsupportedFormat;
        return mp2enc.Encoder.init(format.sample_rate, format.channelCount(), options);
    }

    /// Checks the request as `check` does; writes nothing (the raw muxer has
    /// no header).
    pub fn begin(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!Writer {
        return .{ .out = out, .encoder = try encoderFor(codec, format, options), .channels = format.channelCount() };
    }

    /// Whole frames of s16le samples; every 1152 of them make a packet.
    pub fn writeData(w: *Writer, data: []const u8) WriteError!void {
        const frame_bytes = 2 * w.channels;
        if (data.len % frame_bytes != 0) return error.IncompleteFrame;
        const full = mp2enc.frame_samples * w.channels;
        var rest = data;
        while (rest.len != 0) {
            const take = @min(full - w.pending_len, rest.len / 2);
            for (0..take) |i| w.pending[w.pending_len + i] = std.mem.readInt(i16, rest[2 * i ..][0..2], .little);
            w.pending_len += take;
            rest = rest[2 * take ..];
            if (w.pending_len == full) try w.emit();
        }
    }

    fn emit(w: *Writer) std.Io.Writer.Error!void {
        var packet: [mp2enc.max_packet]u8 = undefined;
        // `writeData` fills `pending` with whole sample frames, at most 1152
        // of them, so the encoder's length check always passes.
        const bytes = w.encoder.encodeFrame(w.pending[0..w.pending_len], &packet) catch unreachable;
        try w.out.writeAll(bytes);
        w.pending_len = 0;
    }

    /// The last frame, padded with silence when short, then a flush.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.pending_len != 0) try w.emit();
        try w.out.flush();
    }
};

const testing = std.testing;

test "the writer groups samples into frames, pads the last and checks the request" {
    // 2600 stereo frames in uneven pieces: two whole frames and a padded
    // third, each packet the encoder's for the same samples.
    var samples: [2600 * 2]i16 = undefined;
    for (&samples, 0..) |*s, i| s.* = @truncate(@as(i32, @intCast(i)) * 37);
    var bytes: [samples.len * 2]u8 = undefined;
    for (samples, 0..) |s, i| std.mem.writeInt(i16, bytes[2 * i ..][0..2], s, .little);
    const format = try audio.Format.init(44100, 2, .s16);

    var out_buffer: [4 * mp2enc.max_packet]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    var w = try Writer.begin(&out, .s16le, format, .{ .bit_rate = 128000 });
    try w.writeData(bytes[0..400]);
    try w.writeData(bytes[400..7000]);
    try w.writeData(bytes[7000..]);
    try w.finish();

    var e = try mp2enc.Encoder.init(44100, 2, .{ .bit_rate = 128000 });
    var want: [4 * mp2enc.max_packet]u8 = undefined;
    var len: usize = 0;
    var start: usize = 0;
    while (start < samples.len) : (start += 2 * mp2enc.frame_samples) {
        var packet: [mp2enc.max_packet]u8 = undefined;
        const got = try e.encodeFrame(samples[start..@min(samples.len, start + 2 * mp2enc.frame_samples)], &packet);
        @memcpy(want[len..][0..got.len], got);
        len += got.len;
    }
    try testing.expectEqualSlices(u8, want[0..len], out.buffered());
    try testing.expectError(error.IncompleteFrame, w.writeData(bytes[0..3]));

    try testing.expectError(error.UnsupportedFormat, Writer.check(.s32le, try audio.Format.init(44100, 2, .s32), .{}));
    try testing.expectError(error.UnsupportedFormat, Writer.check(.s16le, try audio.Format.init(8000, 2, .s16), .{}));
    try testing.expectError(error.UnsupportedFormat, Writer.check(.s16le, try audio.Format.initLayout(44100, .{ .native = 0x1 | 0x4 }, .s16), .{}));
    try testing.expectError(error.InvalidOption, Writer.check(.s16le, format, .{ .bit_rate = 100000 }));
    try Writer.check(.s16le, try audio.Format.init(16000, 1, .s16), .{ .fixed = true });
}
