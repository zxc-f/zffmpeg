// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// Layout and sample-format names follow libavutil/channel_layout.h and
// samplefmt.c at the pinned reference revision; see port.md.
//! Audio stream descriptions: sample rate, channel layout and order, sample
//! format (storage, T20a), and borrowed interleaved samples.
//!
//! Layouts are only mono and stereo so far (T23b). Policy limits such as the
//! WAV parser's 192 kHz cap belong to the parser, not to these types.

const std = @import("std");
const time = @import("time.zig");

pub const ChannelLayout = enum {
    /// One channel: front center (FFmpeg `mono`).
    mono,
    /// Two channels, interleaved front left then front right (FFmpeg `stereo`).
    stereo,

    pub const Error = error{
        /// Zero channels.
        InvalidChannelCount,
        /// More channels than the supported layouts have.
        UnsupportedChannelCount,
    };

    pub fn fromChannelCount(count: u16) Error!ChannelLayout {
        return switch (count) {
            0 => error.InvalidChannelCount,
            1 => .mono,
            2 => .stereo,
            else => error.UnsupportedChannelCount,
        };
    }

    pub fn channelCount(layout: ChannelLayout) u16 {
        return switch (layout) {
            .mono => 1,
            .stereo => 2,
        };
    }

    /// FFmpeg's canonical layout name, as used in probe output.
    pub fn name(layout: ChannelLayout) []const u8 {
        return @tagName(layout);
    }
};

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
};

/// A validated description of an audio stream. Build it with `init`.
pub const Format = struct {
    /// Frames per second; never zero.
    sample_rate: u32,
    layout: ChannelLayout,
    sample_format: SampleFormat,

    pub const Error = ChannelLayout.Error || error{
        /// A sample rate of zero.
        InvalidSampleRate,
    };

    pub fn init(sample_rate: u32, channel_count: u16, sample_format: SampleFormat) Error!Format {
        if (sample_rate == 0) return error.InvalidSampleRate;
        return .{
            .sample_rate = sample_rate,
            .layout = try ChannelLayout.fromChannelCount(channel_count),
            .sample_format = sample_format,
        };
    }

    pub fn channelCount(format: Format) u16 {
        return format.layout.channelCount();
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

test "channel counts map to the supported layouts" {
    try std.testing.expectError(error.InvalidChannelCount, ChannelLayout.fromChannelCount(0));
    try std.testing.expectEqual(.mono, try ChannelLayout.fromChannelCount(1));
    try std.testing.expectEqual(.stereo, try ChannelLayout.fromChannelCount(2));
    try std.testing.expectError(error.UnsupportedChannelCount, ChannelLayout.fromChannelCount(3));
    try std.testing.expectError(error.UnsupportedChannelCount, ChannelLayout.fromChannelCount(std.math.maxInt(u16)));
    try std.testing.expectEqualStrings("mono", ChannelLayout.mono.name());
    try std.testing.expectEqualStrings("stereo", ChannelLayout.stereo.name());
    try std.testing.expectEqualStrings("s16", SampleFormat.s16.name());
}

test "formats reject a zero sample rate and bad channel counts" {
    try std.testing.expectError(error.InvalidSampleRate, Format.init(0, 2, .s16));
    try std.testing.expectError(error.InvalidChannelCount, Format.init(44100, 0, .s16));
    try std.testing.expectError(error.UnsupportedChannelCount, Format.init(44100, 3, .s16));
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
