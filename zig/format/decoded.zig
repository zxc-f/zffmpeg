// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/decode.c (discard_samples, the skip-samples side data) and
// fftools/ffmpeg_dec.c (the decode error rate) at the pinned reference
// revision describe the behavior, restated here.
//! What the decoded inputs share (`format/oggdecode.zig`, T27d;
//! `format/mp3decode.zig`, T29b): libavcodec's discarding of the samples a
//! decoder or the demuxer asks to skip, the ffmpeg program's decode error
//! rate, the header a decoded input reports, and planar float frames
//! delivered as interleaved f32le.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const codecs = @import("../codec/registry.zig");

/// A decoded input's stream, as `readHeader` reports it.
pub const Header = struct {
    /// The stream's codec.
    stream: codecs.Codec,
    /// The encoding of the bytes `readData` gives.
    codec: pcm.Codec,
    format: audio.Format,
    /// The stream's sample count, when counted ahead.
    frame_count: ?u64,
    /// The decoded samples' bits (`bits_per_raw_sample` for an encoder).
    bits: u8,
};

/// libavcodec's decode.c around a decoder (discard_samples): the samples
/// still to skip, from the decoder (its first frame) or a packet's
/// skip-samples side data, and the end padding a packet asks to drop.
pub const Discard = struct {
    skip: i64 = 0,

    /// The kept part of a decoded frame of `n` samples, as [start, end);
    /// null when the whole frame is dropped.
    pub fn apply(x: *Discard, n: u32, side: ?[2]u32) ?[2]u32 {
        var padding: u32 = 0;
        if (side) |s| {
            const skip: i32 = @bitCast(s[0]);
            if (skip != 0) x.skip = skip;
            x.skip = @max(0, x.skip);
            padding = s[1];
        }
        var start: u32 = 0;
        var count = n;
        if (x.skip > 0) {
            if (count <= x.skip) {
                x.skip -= count;
                return null;
            }
            start = @intCast(x.skip);
            count -= start;
            x.skip = 0;
        }
        if (padding > 0 and padding <= n) {
            const drop = @min(padding, count);
            if (drop == count) return null;
            count -= drop;
        }
        return .{ start, start + count };
    }
};

/// The ffmpeg program's decoder statistics: the frames the decoder
/// returned and the packets or frames it failed.
pub const ErrorRate = struct {
    frames_decoded: u64 = 0,
    decode_errors: u64 = 0,

    /// The program's check at the end of decoding: the share of failed
    /// decodes, in single precision, above `-max_error_rate` (2/3).
    pub fn check(e: ErrorRate) error{DecodeErrorRate}!void {
        if (e.frames_decoded == 0 and e.decode_errors == 0) return;
        const errors: f32 = @floatFromInt(e.decode_errors);
        const all: f32 = @floatFromInt(e.frames_decoded + e.decode_errors);
        if (errors / all > @as(f32, 2.0 / 3.0)) return error.DecodeErrorRate;
    }
};

/// Frames `start ..` of `planes`, `frames` of them, interleaved into
/// `output` as f32le; `output` holds them.
pub fn interleave(output: []u8, planes: []const []const f32, start: usize, frames: usize) void {
    const channels = planes.len;
    std.debug.assert(output.len >= frames * channels * 4);
    for (0..frames) |f| {
        for (planes, 0..) |plane, c| {
            std.mem.writeInt(u32, output[(f * channels + c) * 4 ..][0..4], @bitCast(plane[start + f]), .little);
        }
    }
}

const testing = std.testing;

test "discard: a skip across frames, then the end padding" {
    var d: Discard = .{};
    try testing.expectEqual(null, d.apply(100, .{ 150, 0 }));
    try testing.expectEqual([2]u32{ 50, 100 }, d.apply(100, null).?);
    try testing.expectEqual([2]u32{ 0, 70 }, d.apply(100, .{ 0, 30 }).?);
    // Padding of the whole frame drops it; padding past it is ignored.
    try testing.expectEqual(null, d.apply(100, .{ 0, 100 }));
    try testing.expectEqual([2]u32{ 0, 100 }, d.apply(100, .{ 0, 101 }).?);
}

test "the error rate fails above two thirds" {
    try (ErrorRate{}).check();
    try (ErrorRate{ .frames_decoded = 1, .decode_errors = 2 }).check();
    try testing.expectError(error.DecodeErrorRate, (ErrorRate{ .frames_decoded = 1, .decode_errors = 3 }).check());
}

test "interleave: planes into f32le frames" {
    const left = [_]f32{ 1, 2, 3 };
    const right = [_]f32{ -1, -2, -3 };
    var out: [16]u8 = undefined;
    interleave(&out, &.{ &left, &right }, 1, 2);
    const want = [_]f32{ 2, -2, 3, -3 };
    for (want, 0..) |v, i| try testing.expectEqual(v, @as(f32, @bitCast(std.mem.readInt(u32, out[4 * i ..][0..4], .little))));
}
