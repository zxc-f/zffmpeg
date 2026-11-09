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

pub const DeliveryError = error{ OutputTooSmall, FrameCountMismatch };

/// The portion of a pending frame that fits in caller storage. A refused
/// read leaves the pending range and delivered count unchanged.
pub fn outputFrames(output_bytes: usize, frame_bytes: usize, pending: usize, delivered: u64, expected: ?u64) DeliveryError!usize {
    std.debug.assert(frame_bytes > 0 and pending > 0);
    const frames = @min(output_bytes / frame_bytes, pending);
    if (frames == 0) return error.OutputTooSmall;
    if (expected) |count| {
        if (delivered > count or frames > count - delivered) return error.FrameCountMismatch;
    }
    return frames;
}

/// Delivers planar float samples and advances the cursor only after copying.
/// Codec-specific frame acquisition and trimming stay with the reader.
pub fn readFloat(output: []u8, planes: []const []const f32, pending: *[2]u32, delivered: *u64, expected: ?u64) DeliveryError![]u8 {
    const frame_bytes = 4 * planes.len;
    const frames = try outputFrames(output.len, frame_bytes, pending[1] - pending[0], delivered.*, expected);
    interleave(output, planes, pending[0], frames);
    pending[0] += @intCast(frames);
    delivered.* += frames;
    return output[0 .. frames * frame_bytes];
}

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

/// Compare a reader interrupted by capacity refusals with an uninterrupted
/// reader, including partial deliveries, the final frame and stable EOF.
fn checkCapacity(comptime Reader: type, actual: *Reader, control: *Reader) !void {
    const header = try actual.readHeader();
    _ = try control.readHeader();
    const frame_bytes = header.format.bytesPerFrame();
    var got: [4096]u8 = undefined;
    var want: [4096]u8 = undefined;
    for ([_]usize{ 0, 1, frame_bytes - 1 }) |short| {
        try testing.expectError(error.OutputTooSmall, actual.readData(got[0..short]));
        try testing.expectEqual(0, actual.delivered);
    }
    var reads: usize = 0;
    while (true) : (reads += 1) {
        const room = if (reads == 0) frame_bytes else if (reads % 2 == 0) frame_bytes * 3 + 1 else got.len;
        const expected = try control.readData(want[0..room]);
        if (expected.len > 0) {
            try testing.expectError(error.OutputTooSmall, actual.readData(got[0 .. frame_bytes - 1]));
        }
        const bytes = try actual.readData(got[0..room]);
        try testing.expectEqualSlices(u8, expected, bytes);
        try testing.expectEqual(control.delivered, actual.delivered);
        if (bytes.len == 0) break;
    }
    try testing.expect(actual.delivered > 0);
    try testing.expectEqual(0, (try actual.readData(got[0..0])).len);
    try actual.finish();
    try control.finish();
}

test "review: decoded readers preserve pending samples after OutputTooSmall" {
    const fixtures = @import("../testing/fixtures.zig");
    const flac = @import("flac.zig");
    const ac3 = @import("ac3decode.zig");
    const cases = .{
        .{ @import("aacdecode.zig").DecodedReader, fixtures.aac.bytes("aac_ffmpeg_short"), null },
        .{ @import("mp3decode.zig").DecodedReader, fixtures.mp3.bytes("mp3_l3_short_ms"), null },
        .{ @import("oggdecode.zig").DecodedReader, fixtures.ogg.bytes("ogg_vorbis_ffmpeg_22k_short"), null },
        .{ @import("oggdecode.zig").DecodedReader, fixtures.ogg.bytes("ogg_opus_stereo"), null },
        .{ @import("oggdecode.zig").DecodedReader, fixtures.ogg.bytes("ogg_flac_stereo"), null },
        .{ flac.DecodedReader, fixtures.flac.bytes("flac_verbatim_stereo_44k1"), null },
        .{ ac3.DecodedReader, fixtures.ac3.bytes("ac3_ffmpeg_short"), @import("ac3.zig").Codec.ac3 },
        .{ ac3.DecodedReader, fixtures.eac3.bytes("eac3_ffmpeg_short"), @import("ac3.zig").Codec.eac3 },
    };
    inline for (cases) |case| {
        const Reader = case[0];
        var input: std.Io.Reader = .fixed(case[1]);
        var reference: std.Io.Reader = .fixed(case[1]);
        var actual = if (Reader == flac.DecodedReader) Reader.init(testing.allocator, &input, null) else if (Reader == ac3.DecodedReader)
            Reader.init(testing.allocator, &input, null, null, case[2])
        else
            Reader.init(testing.allocator, &input, null, null);
        defer actual.deinit();
        var control = if (Reader == flac.DecodedReader) Reader.init(testing.allocator, &reference, null) else if (Reader == ac3.DecodedReader)
            Reader.init(testing.allocator, &reference, null, null, case[2])
        else
            Reader.init(testing.allocator, &reference, null, null);
        defer control.deinit();
        try checkCapacity(Reader, &actual, &control);
    }
}
