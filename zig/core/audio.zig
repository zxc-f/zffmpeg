// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// Layout and sample-format names follow libavutil/channel_layout.h and
// samplefmt.c at the pinned reference revision; see port.md.
//! Audio stream descriptions: sample rate, channel layout (FFmpeg's
//! `AVChannelLayout`, core/channel_layout.zig, T23b), sample format
//! (storage, T20a), and borrowed interleaved samples.
//!
//! Policy limits such as the parsers' 192 kHz and channel caps belong to the
//! parsers, not to these types.

const std = @import("std");
const time = @import("time.zig");

/// FFmpeg's channel layouts: native (a speaker mask), custom or unspecified.
pub const ChannelLayout = @import("channel_layout.zig").Layout;

/// The layout FFmpeg's command line gives a stream whose layout is
/// unspecified (`guess_input_channel_layout`): the default for its channel
/// count when that is native, else unchanged.
pub fn guessLayout(layout: ChannelLayout) ChannelLayout {
    return switch (layout) {
        .unspecified => |count| switch (ChannelLayout.default(count)) {
            .native => |mask| .{ .native = mask },
            .unspecified, .custom => layout,
        },
        .native, .custom => layout,
    };
}

/// How decoded samples are stored (TODO.md T20a): a sample type, packed
/// (channels interleaved in one plane) or planar (one plane per channel). This
/// is storage only, separate from codec identity and from what a container
/// carries. Tags are FFmpeg's names; FFmpeg's `dsd` is not supported.
pub const SampleFormat = enum {
    /// Unsigned 8-bit, packed; silence is 0x80.
    u8,
    /// Signed 16-bit, packed.
    s16,
    s32,
    s64,
    /// 32-bit float, packed (FFmpeg `flt`).
    flt,
    /// 64-bit float, packed (FFmpeg `dbl`).
    dbl,
    /// The planar forms of the same types.
    u8p,
    s16p,
    s32p,
    s64p,
    fltp,
    dblp,

    /// The storage element, shared by packed and planar forms. Arithmetic
    /// accumulator types remain specific to each DSP algorithm.
    pub fn Element(comptime format: SampleFormat) type {
        return switch (format) {
            .u8, .u8p => u8,
            .s16, .s16p => i16,
            .s32, .s32p => i32,
            .s64, .s64p => i64,
            .flt, .fltp => f32,
            .dbl, .dblp => f64,
        };
    }

    pub fn bytesPerSample(format: SampleFormat) u8 {
        return switch (format) {
            .u8, .u8p => 1,
            .s16, .s16p => 2,
            .s32, .s32p, .flt, .fltp => 4,
            .s64, .s64p, .dbl, .dblp => 8,
        };
    }

    /// One plane per channel, rather than channels interleaved in one plane.
    pub fn isPlanar(format: SampleFormat) bool {
        return switch (format) {
            .u8, .s16, .s32, .s64, .flt, .dbl => false,
            .u8p, .s16p, .s32p, .s64p, .fltp, .dblp => true,
        };
    }

    /// The packed form of the same sample type.
    pub fn packedForm(format: SampleFormat) SampleFormat {
        return switch (format) {
            .u8, .u8p => .u8,
            .s16, .s16p => .s16,
            .s32, .s32p => .s32,
            .s64, .s64p => .s64,
            .flt, .fltp => .flt,
            .dbl, .dblp => .dbl,
        };
    }

    /// The planar form of the same sample type.
    pub fn planarForm(format: SampleFormat) SampleFormat {
        return switch (format) {
            .u8, .u8p => .u8p,
            .s16, .s16p => .s16p,
            .s32, .s32p => .s32p,
            .s64, .s64p => .s64p,
            .flt, .fltp => .fltp,
            .dbl, .dblp => .dblp,
        };
    }

    /// The byte every byte of a silent sample holds: 0x80 for unsigned 8-bit,
    /// 0 otherwise (all-zero is also 0.0 for both float types).
    pub fn silenceByte(format: SampleFormat) u8 {
        return if (format.packedForm() == .u8) 0x80 else 0;
    }

    /// FFmpeg's sample-format name, as used in probe output.
    pub fn name(format: SampleFormat) []const u8 {
        return @tagName(format);
    }

    /// The format FFmpeg calls `text`, or `null`.
    pub fn fromName(text: []const u8) ?SampleFormat {
        return std.meta.stringToEnum(SampleFormat, text);
    }

    /// The formats in FFmpeg's `enum AVSampleFormat` order, which its format
    /// lists follow (TODO.md T25a).
    pub const ffmpeg_order = [_]SampleFormat{ .u8, .s16, .s32, .flt, .dbl, .u8p, .s16p, .s32p, .fltp, .dblp, .s64, .s64p };

    /// FFmpeg's number for the format (`AV_SAMPLE_FMT_*`).
    pub fn ffmpegId(format: SampleFormat) u8 {
        for (ffmpeg_order, 0..) |f, i| {
            if (f == format) return @intCast(i);
        }
        unreachable; // every format is listed
    }

    /// The format FFmpeg numbers `id`, or `null`.
    pub fn fromFfmpegId(id: i64) ?SampleFormat {
        if (id < 0 or id >= ffmpeg_order.len) return null;
        return ffmpeg_order[@intCast(id)];
    }
};

test "FFmpeg numbers the sample formats in its own order" {
    try std.testing.expectEqual(0, SampleFormat.u8.ffmpegId());
    try std.testing.expectEqual(3, SampleFormat.flt.ffmpegId());
    try std.testing.expectEqual(11, SampleFormat.s64p.ffmpegId());
    for (SampleFormat.ffmpeg_order, 0..) |f, i| try std.testing.expectEqual(f, SampleFormat.fromFfmpegId(@intCast(i)).?);
    try std.testing.expectEqual(null, SampleFormat.fromFfmpegId(12));
    try std.testing.expectEqual(null, SampleFormat.fromFfmpegId(-1));
}

/// A validated description of an audio stream. Build it with `init` or
/// `initLayout`.
pub const Format = struct {
    /// Frames per second; never zero.
    sample_rate: u32,
    /// At least one channel, and at most 65535: every count a container
    /// header can hold.
    layout: ChannelLayout,
    sample_format: SampleFormat,

    pub const Error = error{
        /// A sample rate of zero.
        InvalidSampleRate,
        /// No channels.
        InvalidChannelCount,
        /// More than 65535 channels.
        UnsupportedChannelCount,
    };

    /// A format with FFmpeg's default layout for `channel_count`
    /// (`av_channel_layout_default`): mono, stereo, 2.1, 4.0, ... where one
    /// is named, else that many unspecified channels.
    pub fn init(sample_rate: u32, channel_count: u16, sample_format: SampleFormat) Error!Format {
        return initLayout(sample_rate, .default(channel_count), sample_format);
    }

    pub fn initLayout(sample_rate: u32, layout: ChannelLayout, sample_format: SampleFormat) Error!Format {
        if (sample_rate == 0) return error.InvalidSampleRate;
        const count = layout.channelCount();
        if (count == 0) return error.InvalidChannelCount;
        if (count > std.math.maxInt(u16)) return error.UnsupportedChannelCount;
        return .{ .sample_rate = sample_rate, .layout = layout, .sample_format = sample_format };
    }

    pub fn channelCount(format: Format) u16 {
        // `initLayout` bounds the count.
        return @intCast(format.layout.channelCount());
    }

    /// The same stream description: rate, sample format, and the same
    /// layout as FFmpeg compares them (labels aside).
    pub fn eql(a: Format, b: Format) bool {
        return a.sample_rate == b.sample_rate and a.sample_format == b.sample_format and a.layout.eql(&b.layout);
    }

    /// Bytes in one interleaved frame: one sample per channel.
    pub fn bytesPerFrame(format: Format) u32 {
        const channels: u32 = format.channelCount();
        return channels * format.sample_format.bytesPerSample();
    }

    /// The time base in which a timestamp is a frame index: `1 / sample_rate`.
    pub fn timeBase(format: Format) time.TimeBase {
        return .{ .num = 1, .den = format.sample_rate };
    }

    /// The number of whole frames in `byte_count` bytes.
    pub fn framesInBytes(format: Format, byte_count: u64) error{IncompleteFrame}!u64 {
        const frame_bytes = format.bytesPerFrame();
        if (byte_count % frame_bytes != 0) return error.IncompleteFrame;
        return byte_count / frame_bytes;
    }

    /// The number of bytes that `frames` frames occupy.
    pub fn bytesForFrames(format: Format, frames: u64) error{Overflow}!u64 {
        return std.math.mul(u64, frames, format.bytesPerFrame());
    }
};

/// A borrowed view of interleaved signed 16-bit samples: frame `i` holds one
/// sample per channel in layout order. The view does not own `samples`; it is
/// valid as long as the caller's buffer is, and copying it copies only the view.
pub const S16Frames = struct {
    layout: ChannelLayout,
    samples: []const i16,

    pub fn init(layout: ChannelLayout, samples: []const i16) error{IncompleteFrame}!S16Frames {
        if (samples.len % layout.channelCount() != 0) return error.IncompleteFrame;
        return .{ .layout = layout, .samples = samples };
    }

    pub fn frameCount(frames: S16Frames) usize {
        return frames.samples.len / frames.layout.channelCount();
    }

    /// The samples of frame `index` in channel order. `index` must be below
    /// `frameCount()`.
    pub fn frame(frames: S16Frames, index: usize) []const i16 {
        std.debug.assert(index < frames.frameCount());
        const channels = frames.layout.channelCount();
        return frames.samples[index * channels ..][0..channels];
    }
};

test "channel counts take FFmpeg's default layouts, and the guess keeps known ones" {
    try std.testing.expectEqual(ChannelLayout.mono, (try Format.init(8000, 1, .s16)).layout);
    try std.testing.expectEqual(ChannelLayout.stereo, (try Format.init(8000, 2, .s16)).layout);
    try std.testing.expectEqual(ChannelLayout{ .unspecified = 9 }, (try Format.init(8000, 9, .s16)).layout);
    try std.testing.expectEqual(ChannelLayout.default(6), guessLayout(.{ .unspecified = 6 }));
    try std.testing.expectEqual(ChannelLayout{ .unspecified = 9 }, guessLayout(.{ .unspecified = 9 }));
    const side: ChannelLayout = .{ .native = 0x60f };
    try std.testing.expectEqual(side, guessLayout(side));
    try std.testing.expectEqualStrings("s16", SampleFormat.s16.name());
}

test "formats reject a zero sample rate and bad channel counts" {
    try std.testing.expectError(error.InvalidSampleRate, Format.init(0, 2, .s16));
    try std.testing.expectError(error.InvalidChannelCount, Format.init(44100, 0, .s16));
    try std.testing.expectError(error.InvalidChannelCount, Format.initLayout(44100, .{ .unspecified = 0 }, .s16));
    try std.testing.expectError(error.UnsupportedChannelCount, Format.initLayout(44100, .{ .unspecified = 65536 }, .s16));
    try std.testing.expectEqual(65535, (try Format.init(44100, 65535, .s16)).channelCount());
    // No rate cap here: the WAV parser applies its own policy limit.
    const fastest = try Format.init(std.math.maxInt(u32), 1, .s16);
    try std.testing.expectEqual(std.math.maxInt(u32), fastest.sample_rate);
}

test "frame sizes and time base follow the layout and rate" {
    const mono = try Format.init(8000, 1, .s16);
    const stereo = try Format.init(44100, 2, .s16);
    try std.testing.expectEqual(2, mono.bytesPerFrame());
    try std.testing.expectEqual(4, stereo.bytesPerFrame());
    const base = stereo.timeBase();
    try std.testing.expectEqual(1, base.num);
    try std.testing.expectEqual(44100, base.den);
    try std.testing.expectEqual(44100, try time.rescale(1, .{ .num = 1, .den = 1 }, base, .nearest));
}

test "byte counts must hold whole frames" {
    const mono = try Format.init(8000, 1, .s16);
    const stereo = try Format.init(44100, 2, .s16);
    try std.testing.expectEqual(0, try stereo.framesInBytes(0));
    try std.testing.expectEqual(2, try stereo.framesInBytes(8));
    try std.testing.expectError(error.IncompleteFrame, stereo.framesInBytes(6));
    try std.testing.expectError(error.IncompleteFrame, mono.framesInBytes(std.math.maxInt(u64)));
    try std.testing.expectEqual(std.math.maxInt(u64) / 2, try mono.framesInBytes(std.math.maxInt(u64) - 1));
}

test "frame byte counts report overflow at the u64 boundary" {
    const mono = try Format.init(8000, 1, .s16);
    const stereo = try Format.init(44100, 2, .s16);
    const max = std.math.maxInt(u64);
    try std.testing.expectEqual(max - 1, try mono.bytesForFrames(max / 2));
    try std.testing.expectError(error.Overflow, mono.bytesForFrames(max / 2 + 1));
    try std.testing.expectEqual(max - 3, try stereo.bytesForFrames(max / 4));
    try std.testing.expectError(error.Overflow, stereo.bytesForFrames(max / 4 + 1));
}

test "interleaved views require whole frames and expose them in channel order" {
    const samples = [_]i16{ 10, -10, 20, -20, 30, -30 };
    try std.testing.expectError(error.IncompleteFrame, S16Frames.init(.stereo, samples[0..5]));
    const stereo = try S16Frames.init(.stereo, &samples);
    try std.testing.expectEqual(3, stereo.frameCount());
    try std.testing.expectEqualSlices(i16, &.{ 20, -20 }, stereo.frame(1));
    const mono = try S16Frames.init(.mono, &samples);
    try std.testing.expectEqual(6, mono.frameCount());
    try std.testing.expectEqualSlices(i16, &.{-30}, mono.frame(5));
    const empty = try S16Frames.init(.stereo, &.{});
    try std.testing.expectEqual(0, empty.frameCount());
}

test "sample storage types agree with packed and planar byte sizes" {
    inline for (SampleFormat.ffmpeg_order) |format| {
        try std.testing.expectEqual(format.bytesPerSample(), @sizeOf(format.Element()));
        const packed_format = comptime format.packedForm();
        const planar_format = comptime format.planarForm();
        try std.testing.expect(format.Element() == packed_format.Element());
        try std.testing.expect(format.Element() == planar_format.Element());
    }
}
