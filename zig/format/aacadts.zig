// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/adtsenc.c, libavcodec's encode.c and the ffmpeg program's
// frame grouping for an encoder with a fixed frame size
// (av_buffersink_set_frame_size) and its flush at the end of the stream, at
// the pinned reference revision, describe the behavior, restated here.
//! FFmpeg's AAC encoder before its adts muxer, as a PCM writer (TODO.md
//! T32d): 32-bit float samples in, grouped into frames of 1024 samples as
//! the ffmpeg program's filter graph groups them for the encoder, the last
//! one short (the encoder pads it), then the encoder's flush; each packet
//! gets the ADTS header the muxer makes of the encoder's
//! AudioSpecificConfig. The bytes are the same on a file and a pipe. The
//! encoder is `codec/aacenc.zig`, the muxer `adtsmux.zig`.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const aacenc = @import("../codec/aacenc.zig");
const adtsmux = @import("adtsmux.zig");

pub const Options = aacenc.Options;

/// The checks `check` and `begin` share: the encoder's (aacenc.Error), a
/// storage other than 32-bit float, and a configuration the adts muxer
/// refuses (UnsupportedFormat).
pub const HeaderError = aacenc.Error;

pub const WriteError = std.Io.Writer.Error || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
    /// The input holds NaN or infinite samples, or values whose
    /// coefficients reach 1e16 ("Input contains (near) NaN/+-Inf",
    /// EINVAL).
    InvalidSamples,
    /// A frame past ADTS's 13-bit length (FFmpeg's "frame size too
    /// large", AVERROR_INVALIDDATA from the muxer).
    FrameTooLarge,
};

/// The native mask the encoder takes for `layout`: its own, or for an
/// unspecified layout the default the ffmpeg program guesses for the
/// count. Null when it has none.
fn layoutMask(layout: audio.ChannelLayout) ?u64 {
    return switch (audio.guessLayout(layout)) {
        .native => |mask| mask,
        .unspecified, .custom => null,
    };
}

pub const Writer = struct {
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    encoder: *aacenc.Encoder,
    muxer: adtsmux.Muxer,
    channels: usize,
    /// Samples not yet a whole frame, de-interleaved.
    pending: [aacenc.max_channels][aacenc.frame_samples]f32 = undefined,
    pending_len: usize = 0,
    packet: []u8,

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(gpa: std.mem.Allocator, codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!void {
        const e = try encoderFor(gpa, codec, format, options);
        defer e.deinit();
        // The muxer writes nothing before the first packet.
        var sink: std.Io.Writer = .fixed(&.{});
        _ = try muxerFor(&sink, e);
    }

    /// The adts muxer for the encoder's AudioSpecificConfig. It refuses a
    /// channel configuration above 7, which the encoder gives 6.1, 7.1 and
    /// 7.1(top) without `aac_pce` ("channelConfiguration > 7 is not
    /// supported in ADTS", AVERROR_INVALIDDATA when FFmpeg writes the
    /// header); the encoder's profile, rate and frame length are ones ADTS
    /// takes.
    fn muxerFor(out: *std.Io.Writer, e: *const aacenc.Encoder) HeaderError!adtsmux.Muxer {
        return adtsmux.Muxer.init(out, e.extradata(), .{}) catch |err| switch (err) {
            error.InvalidData => error.UnsupportedFormat,
        };
    }

    fn encoderFor(gpa: std.mem.Allocator, codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!*aacenc.Encoder {
        if (codec != .f32le or format.sample_format != .flt) return error.UnsupportedFormat;
        const mask = layoutMask(format.layout) orelse return error.UnsupportedFormat;
        return aacenc.Encoder.init(gpa, format.sample_rate, mask, options);
    }

    /// Checks the request as `check` does; writes nothing yet (ADTS has no
    /// file header).
    pub fn begin(gpa: std.mem.Allocator, out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, options: Options) HeaderError!Writer {
        const e = try encoderFor(gpa, codec, format, options);
        errdefer e.deinit();
        const packet = try gpa.alloc(u8, e.packetCapacity());
        errdefer gpa.free(packet);
        const muxer = try muxerFor(out, e);
        return .{ .out = out, .gpa = gpa, .encoder = e, .muxer = muxer, .channels = format.channelCount(), .packet = packet };
    }

    pub fn deinit(w: *Writer) void {
        w.gpa.free(w.packet);
        w.encoder.deinit();
        w.* = undefined;
    }

    /// Whole frames of f32le samples; every 1024 of them go to the encoder.
    pub fn writeData(w: *Writer, data: []const u8) WriteError!void {
        const frame_bytes = 4 * w.channels;
        if (data.len % frame_bytes != 0) return error.IncompleteFrame;
        var rest = data;
        while (rest.len != 0) {
            const take = @min(aacenc.frame_samples - w.pending_len, rest.len / frame_bytes);
            for (0..take) |i| {
                for (0..w.channels) |c| {
                    const at = (i * w.channels + c) * 4;
                    w.pending[c][w.pending_len + i] = @bitCast(std.mem.readInt(u32, rest[at..][0..4], .little));
                }
            }
            w.pending_len += take;
            rest = rest[take * frame_bytes ..];
            if (w.pending_len == aacenc.frame_samples) try w.emit();
        }
    }

    fn emit(w: *Writer) WriteError!void {
        var planes: [aacenc.max_channels][]const f32 = undefined;
        for (planes[0..w.channels], w.pending[0..w.channels]) |*p, *s| p.* = s;
        const got = w.encoder.encodeFrame(planes[0..w.channels], w.pending_len, w.packet) catch |err| return switch (err) {
            error.InvalidInput => error.InvalidSamples,
            // `planes` has the encoder's channels and at most a frame.
            error.InvalidFrame => unreachable,
        };
        w.pending_len = 0;
        if (got) |bytes| try w.writePacket(bytes);
    }

    fn writePacket(w: *Writer, bytes: []const u8) WriteError!void {
        w.muxer.writePacket(bytes, null) catch |err| return switch (err) {
            error.WriteFailed => error.WriteFailed,
            error.InvalidData => error.FrameTooLarge,
        };
    }

    /// The last frame, short when the samples end inside it, then the
    /// encoder's flush and the output's.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.pending_len != 0) try w.emit();
        while (true) {
            const got = w.encoder.encodeFrame(null, 0, w.packet) catch |err| return switch (err) {
                error.InvalidInput => error.InvalidSamples,
                error.InvalidFrame => unreachable, // a flush takes no samples
            };
            const bytes = got orelse break;
            try w.writePacket(bytes);
        }
        try w.muxer.finish();
    }
};

const testing = std.testing;

fn testBytes(comptime n: usize, comptime channels: usize) [n * channels * 4]u8 {
    var bytes: [n * channels * 4]u8 = undefined;
    for (0..n * channels) |i| {
        const s: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.01) * 0.5;
        std.mem.writeInt(u32, bytes[4 * i ..][0..4], @bitCast(s), .little);
    }
    return bytes;
}

test "the writer groups samples into frames, flushes and checks the request" {
    // 2500 stereo frames in uneven pieces: two whole frames, a short third
    // and the flush, each packet the encoder's for the same samples behind
    // the muxer's header.
    const n = 2500;
    const bytes = testBytes(n, 2);
    const format = try audio.Format.init(44100, 2, .flt);
    const options: Options = .{ .coder = .twoloop };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w = try Writer.begin(testing.allocator, &out.writer, .f32le, format, options);
    defer w.deinit();
    try w.writeData(bytes[0..400]);
    try w.writeData(bytes[400..9000]);
    try w.writeData(bytes[9000..]);
    try w.finish();

    const e = try aacenc.Encoder.init(testing.allocator, 44100, 0x3, options);
    defer e.deinit();
    var want: std.Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    var m = try adtsmux.Muxer.init(&want.writer, e.extradata(), .{});
    const packet = try testing.allocator.alloc(u8, e.packetCapacity());
    defer testing.allocator.free(packet);
    var left: [aacenc.frame_samples]f32 = undefined;
    var right: [aacenc.frame_samples]f32 = undefined;
    var packets: usize = 0;
    var start: usize = 0;
    while (start < n) : (start += aacenc.frame_samples) {
        const count = @min(n - start, aacenc.frame_samples);
        for (0..count) |i| {
            left[i] = @bitCast(std.mem.readInt(u32, bytes[8 * (start + i) ..][0..4], .little));
            right[i] = @bitCast(std.mem.readInt(u32, bytes[8 * (start + i) + 4 ..][0..4], .little));
        }
        if (try e.encodeFrame(&.{ &left, &right }, count, packet)) |got| {
            try m.writePacket(got, null);
            packets += 1;
        }
    }
    while (try e.encodeFrame(null, 0, packet)) |got| {
        try m.writePacket(got, null);
        packets += 1;
    }
    try m.finish();
    // 2500 samples after the encoder's 1024 of delay: four packets.
    try testing.expectEqual(4, packets);
    try testing.expectEqualSlices(u8, want.written(), out.written());
    try testing.expectEqual(0xff, out.written()[0]);
    try testing.expectError(error.IncompleteFrame, w.writeData(bytes[0..6]));

    try testing.expectError(error.UnsupportedFormat, Writer.check(testing.allocator, .s16le, try audio.Format.init(44100, 2, .s16), options));
    try testing.expectError(error.UnsupportedFormat, Writer.check(testing.allocator, .f32le, try audio.Format.init(44000, 2, .flt), options));
    // 7.1 takes channel configuration 12, which ADTS cannot carry, unless
    // in a PCE.
    try testing.expectError(error.UnsupportedFormat, Writer.check(testing.allocator, .f32le, try audio.Format.init(48000, 8, .flt), options));
    try Writer.check(testing.allocator, .f32le, try audio.Format.init(48000, 8, .flt), .{ .coder = .twoloop, .pce = 1 });
    // The default coder, nmr.
    try Writer.check(testing.allocator, .f32le, format, .{});
    try testing.expectError(error.InvalidOption, Writer.check(testing.allocator, .f32le, format, .{ .profile = 2 }));
}

test "the writer refuses NaN samples and reports a failing output" {
    const format = try audio.Format.init(48000, 1, .flt);
    var bytes = testBytes(3 * aacenc.frame_samples, 1);
    std.mem.writeInt(u32, bytes[4 * 1500 ..][0..4], @bitCast(std.math.nan(f32)), .little);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w = try Writer.begin(testing.allocator, &out.writer, .f32le, format, .{ .coder = .fast });
    defer w.deinit();
    try testing.expectError(error.InvalidSamples, w.writeData(&bytes));

    var failing: std.Io.Writer = .failing;
    var f = try Writer.begin(testing.allocator, &failing, .f32le, format, .{ .coder = .fast });
    defer f.deinit();
    const clean = testBytes(3 * aacenc.frame_samples, 1);
    try testing.expectError(error.WriteFailed, f.writeData(&clean));
}
