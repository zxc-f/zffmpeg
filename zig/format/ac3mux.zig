// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/rawenc.c (ff_ac3_muxer, ff_raw_write_packet), libavcodec's
// encode.c and the ffmpeg program's frame grouping for an encoder with a
// fixed frame size (av_buffersink_set_frame_size) and its flush at the end
// of the stream, at the pinned reference revision, describe the behavior,
// restated here.
//! FFmpeg's ac3 muxer with its AC-3 encoder, as a PCM writer (TODO.md
//! T32c): 32-bit float samples in, grouped into frames of 1536 samples as
//! the ffmpeg program's filter graph groups them for the encoder, the last
//! one short (the encoder pads it), then the encoder's flush, and each
//! packet written as it is (the raw muxer adds nothing). The bytes are the
//! same on a file and a pipe. The encoder is `codec/ac3enc.zig`.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const ac3enc = @import("../codec/ac3enc.zig");

pub const Options = ac3enc.Options;

/// The checks `check` and `begin` share: the encoder's (ac3enc.Error), and
/// a storage other than 32-bit float.
pub const HeaderError = ac3enc.Error;

pub const WriteError = std.Io.Writer.Error || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
    /// The encoder found no SNR offset that fits the frame (FFmpeg's "Bit
    /// allocation failed", EINVAL).
    BitAllocationFailed,
};

/// The native mask the encoder takes for `layout`: its own, or for an
/// unspecified layout the default the ffmpeg program guesses for the
/// count; a custom layout whose channels are in native order counts as
/// that mask. Null when it has none.
fn layoutMask(layout: audio.ChannelLayout) ?u64 {
    return switch (audio.guessLayout(layout)) {
        .native => |mask| mask,
        .unspecified => null,
        .custom => |*custom| blk: {
            var mask: u64 = 0;
            var last: i32 = -1;
            for (custom.channels[0..custom.count]) |c| {
                const bit: i32 = @backingInt(c.channel);
                if (bit <= last or bit >= 63) break :blk null;
                mask |= @as(u64, 1) << @intCast(bit);
                last = bit;
            }
            break :blk mask;
        },
    };
}

pub const Writer = struct {
    out: *std.Io.Writer,
    encoder: *ac3enc.Encoder,
    channels: usize,
    /// Samples not yet a whole frame, de-interleaved.
    pending: [6][ac3enc.frame_samples]f32 = undefined,
    pending_len: usize = 0,

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists: the samples must be 32-bit
    /// float (the encoder's format), the layout and rate the encoder's,
    /// the options valid.
    pub fn check(gpa: std.mem.Allocator, codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!void {
        const e = try encoderFor(gpa, codec, format, options);
        e.deinit();
    }

    fn encoderFor(gpa: std.mem.Allocator, codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!*ac3enc.Encoder {
        if (codec != .f32le or format.sample_format != .flt) return error.UnsupportedFormat;
        const mask = layoutMask(format.layout) orelse return error.UnsupportedFormat;
        return ac3enc.Encoder.init(gpa, format.sample_rate, mask, options);
    }

    /// Checks the request as `check` does; writes nothing (the raw muxer has
    /// no header).
    pub fn begin(gpa: std.mem.Allocator, out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!Writer {
        return .{ .out = out, .encoder = try encoderFor(gpa, codec, format, options), .channels = format.channelCount() };
    }

    pub fn deinit(w: *Writer) void {
        w.encoder.deinit();
        w.* = undefined;
    }

    /// The encoder's bit rate (`avctx->bit_rate` after opening).
    pub fn bitRate(w: *const Writer) i32 {
        return w.encoder.bitRate();
    }

    /// Whole frames of f32le samples; every 1536 of them make a packet.
    pub fn writeData(w: *Writer, data: []const u8) WriteError!void {
        const frame_bytes = 4 * w.channels;
        if (data.len % frame_bytes != 0) return error.IncompleteFrame;
        var rest = data;
        while (rest.len != 0) {
            const take = @min(ac3enc.frame_samples - w.pending_len, rest.len / frame_bytes);
            for (0..take) |i| {
                for (0..w.channels) |c| {
                    const at = (i * w.channels + c) * 4;
                    w.pending[c][w.pending_len + i] = @bitCast(std.mem.readInt(u32, rest[at..][0..4], .little));
                }
            }
            w.pending_len += take;
            rest = rest[take * frame_bytes ..];
            if (w.pending_len == ac3enc.frame_samples) try w.emit();
        }
    }

    fn emit(w: *Writer) WriteError!void {
        var planes: [6][]const f32 = undefined;
        for (planes[0..w.channels], w.pending[0..w.channels]) |*p, *s| p.* = s;
        var packet: [ac3enc.max_packet]u8 = undefined;
        const bytes = w.encoder.encodeFrame(planes[0..w.channels], w.pending_len, &packet) catch |err| return switch (err) {
            error.BitAllocationFailed => error.BitAllocationFailed,
            // `planes` has the encoder's channels and at most a frame.
            error.InvalidFrame => unreachable,
        };
        try w.out.writeAll(bytes.?);
        w.pending_len = 0;
    }

    /// The last frame, short when the samples end inside it, then the
    /// encoder's flush and the output's.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.pending_len != 0) try w.emit();
        var packet: [ac3enc.max_packet]u8 = undefined;
        while (true) {
            const got = w.encoder.encodeFrame(null, 0, &packet) catch |err| return switch (err) {
                error.BitAllocationFailed => error.BitAllocationFailed,
                error.InvalidFrame => unreachable, // a flush takes no samples
            };
            const bytes = got orelse break;
            try w.out.writeAll(bytes);
        }
        try w.out.flush();
    }
};

const testing = std.testing;

test "the writer groups samples into frames, flushes and checks the request" {
    // 3200 stereo frames in uneven pieces: two whole frames, a short third
    // and the flush, each packet the encoder's for the same samples.
    const n = 3200;
    var samples: [n * 2]f32 = undefined;
    for (&samples, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.01) * 0.5;
    var bytes: [samples.len * 4]u8 = undefined;
    for (samples, 0..) |s, i| std.mem.writeInt(u32, bytes[4 * i ..][0..4], @bitCast(s), .little);
    const format = try audio.Format.init(48000, 2, .flt);

    var out_buffer: [5 * ac3enc.max_packet]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    var w = try Writer.begin(testing.allocator, &out, .f32le, format, .{ .bit_rate = 128000 });
    defer w.deinit();
    try w.writeData(bytes[0..400]);
    try w.writeData(bytes[400..17000]);
    try w.writeData(bytes[17000..]);
    try w.finish();

    const e = try ac3enc.Encoder.init(testing.allocator, 48000, 0x3, .{ .bit_rate = 128000 });
    defer e.deinit();
    var want: [5 * ac3enc.max_packet]u8 = undefined;
    var len: usize = 0;
    var start: usize = 0;
    var left: [ac3enc.frame_samples]f32 = undefined;
    var right: [ac3enc.frame_samples]f32 = undefined;
    while (start < n) : (start += ac3enc.frame_samples) {
        const count = @min(n - start, ac3enc.frame_samples);
        for (0..count) |i| {
            left[i] = samples[2 * (start + i)];
            right[i] = samples[2 * (start + i) + 1];
        }
        var packet: [ac3enc.max_packet]u8 = undefined;
        const got = (try e.encodeFrame(&.{ &left, &right }, count, &packet)).?;
        @memcpy(want[len..][0..got.len], got);
        len += got.len;
    }
    var packet: [ac3enc.max_packet]u8 = undefined;
    while (try e.encodeFrame(null, 0, &packet)) |got| {
        @memcpy(want[len..][0..got.len], got);
        len += got.len;
    }
    // 3200 + 256 samples: two whole frames and a short third, which holds
    // the rest, so no flush packet.
    try testing.expectEqual(3 * 512, len);
    try testing.expectEqualSlices(u8, want[0..len], out.buffered());
    try testing.expectError(error.IncompleteFrame, w.writeData(bytes[0..6]));

    try testing.expectError(error.UnsupportedFormat, Writer.check(testing.allocator, .s16le, try audio.Format.init(48000, 2, .s16), .{}));
    try testing.expectError(error.UnsupportedFormat, Writer.check(testing.allocator, .f32le, try audio.Format.init(22050, 2, .flt), .{}));
    try testing.expectError(error.UnsupportedFormat, Writer.check(testing.allocator, .f32le, try audio.Format.init(48000, 8, .flt), .{}));
    try testing.expectError(error.InvalidOption, Writer.check(testing.allocator, .f32le, format, .{ .mixing_level = 70 }));
    try Writer.check(testing.allocator, .f32le, try audio.Format.init(32000, 6, .flt), .{});
}
