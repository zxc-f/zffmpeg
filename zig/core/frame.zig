// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavutil/frame.c and the audio fields of AVFrame in libavutil/frame.h at the
// pinned reference revision describe the corresponding C type.
//! Decoded audio frames (TODO.md T14a, widened by T23a).
//!
//! A `Frame` is a view of samples in any `audio.SampleFormat`: one plane of
//! interleaved samples when packed, or one plane per channel, back to back,
//! when planar, with no padding (line alignment 1), in the target's byte
//! order. It never owns `data`, and copying it copies only the view; the
//! producer says how long the samples stay valid. `clone` makes an `Owned`
//! frame that keeps a copy until `deinit`.

const std = @import("std");
const audio = @import("audio.zig");
const samples = @import("samples.zig");

pub const Frame = struct {
    format: audio.Format,
    /// The samples of `format.sample_format`, a whole number of frames,
    /// borrowed from the producer.
    data: []const u8,
    /// Presentation time in `format.timeBase()` units, or `null` when unknown.
    pts: ?i64 = null,

    /// Checks that `data` holds whole frames of `format`.
    pub fn init(format: audio.Format, data: []const u8, pts: ?i64) error{IncompleteFrame}!Frame {
        if (data.len % format.bytesPerFrame() != 0) return error.IncompleteFrame;
        return .{ .format = format, .data = data, .pts = pts };
    }

    /// A frame of packed s16 samples, the storage of the s16 codecs.
    pub fn fromS16(format: audio.Format, values: []const i16, pts: ?i64) error{ UnsupportedSampleFormat, IncompleteFrame }!Frame {
        if (format.sample_format != .s16) return error.UnsupportedSampleFormat;
        return init(format, std.mem.sliceAsBytes(values), pts);
    }

    /// Sample frames: samples per channel.
    pub fn frameCount(frame: Frame) usize {
        return frame.data.len / frame.format.bytesPerFrame();
    }

    /// The samples as the kernels read them. The frame must hold at least one
    /// sample frame, and fewer than 2^31 bytes (a decoder's or a stage's
    /// storage is far smaller).
    pub fn view(frame: Frame) samples.View {
        const count: u32 = @intCast(frame.frameCount());
        const layout = samples.Layout.init(frame.format.sample_format, frame.format.channelCount(), count, .{ .line = 1 }) catch unreachable;
        return samples.View.init(layout, frame.data) catch unreachable; // whole frames, so exactly layout.size
    }

    /// A frame that owns a copy of its samples.
    pub const Owned = struct {
        /// `frame.data` is owned; do not free it or point it elsewhere.
        frame: Frame,
        gpa: std.mem.Allocator,

        pub fn deinit(owned: *Owned) void {
            owned.gpa.free(owned.frame.data);
            owned.* = undefined;
        }
    };

    /// Copies the samples into storage from `gpa`, so the result outlives the
    /// producer's buffer. On failure nothing is allocated.
    pub fn clone(frame: Frame, gpa: std.mem.Allocator) std.mem.Allocator.Error!Owned {
        var copy = frame;
        copy.data = try gpa.dupe(u8, frame.data);
        return .{ .frame = copy, .gpa = gpa };
    }
};

test "a frame holds whole frames of any format and counts them" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    try std.testing.expectError(error.IncompleteFrame, Frame.fromS16(stereo, &.{ 1, 2, 3 }, null));
    const planar = try audio.Format.init(44100, 2, .s16p);
    try std.testing.expectError(error.UnsupportedSampleFormat, Frame.fromS16(planar, &.{ 1, 2 }, null));
    const frame = try Frame.fromS16(stereo, &.{ 1, 2, 3, 4 }, 10);
    try std.testing.expectEqual(2, frame.frameCount());
    try std.testing.expectEqual(10, frame.pts);
    // Planar 32-bit floats: 2 frames, 16 bytes, one plane per channel.
    const fltp = try audio.Format.init(48000, 2, .fltp);
    const floats = [_]f32{ 0.5, -0.5, 1, -1 };
    const planar_frame = try Frame.init(fltp, std.mem.sliceAsBytes(&floats), null);
    try std.testing.expectEqual(2, planar_frame.frameCount());
    try std.testing.expectEqual(8, planar_frame.view().layout.linesize);
    try std.testing.expectError(error.IncompleteFrame, Frame.init(fltp, std.mem.sliceAsBytes(floats[0..3]), null));
}

test "a clone owns its samples" {
    const gpa = std.testing.allocator;
    const mono = try audio.Format.init(8000, 1, .s16);
    var values = [_]i16{ 5, -5 };
    var owned = try (try Frame.fromS16(mono, &values, 0)).clone(gpa);
    defer owned.deinit();
    values[0] = 0;
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]i16{ 5, -5 }), owned.frame.data);
    try std.testing.expectEqual(0, owned.frame.pts);
}

fn cloneAndRelease(gpa: std.mem.Allocator) !void {
    const mono = try audio.Format.init(8000, 1, .s16);
    var owned = try (try Frame.fromS16(mono, &.{ 1, 2, 3 }, null)).clone(gpa);
    owned.deinit();
}

test "cloning a frame leaks nothing when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneAndRelease, .{});
}
