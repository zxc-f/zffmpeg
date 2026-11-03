// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavutil/frame.c and the audio fields of AVFrame in libavutil/frame.h at the
// pinned reference revision describe the corresponding C type.
//! Decoded audio frames (TODO.md T14a).
//!
//! A `Frame` is a view of interleaved signed 16-bit samples: one plane, the
//! only storage the supported sample format needs (planar layouts arrive with
//! TODO.md T20a). It never owns `samples`, and copying it copies only the view;
//! the producer says how long the samples stay valid. `clone` makes an `Owned`
//! frame that keeps a copy until `deinit`.

const std = @import("std");
const audio = @import("audio.zig");

pub const Frame = struct {
    format: audio.Format,
    /// Interleaved samples, a whole number of frames, borrowed from the producer.
    samples: []const i16,
    /// Presentation time in `format.timeBase()` units, or `null` when unknown.
    pts: ?i64 = null,

    /// Checks that `samples` holds whole frames of `format`.
    pub fn init(format: audio.Format, samples: []const i16, pts: ?i64) error{IncompleteFrame}!Frame {
        if (samples.len % format.channelCount() != 0) return error.IncompleteFrame;
        return .{ .format = format, .samples = samples, .pts = pts };
    }

    /// Sample frames: samples per channel.
    pub fn frameCount(frame: Frame) usize {
        return frame.samples.len / frame.format.channelCount();
    }

    /// A frame that owns a copy of its samples.
    pub const Owned = struct {
        /// `frame.samples` is owned; do not free it or point it elsewhere.
        frame: Frame,
        gpa: std.mem.Allocator,

        pub fn deinit(owned: *Owned) void {
            owned.gpa.free(owned.frame.samples);
            owned.* = undefined;
        }
    };

    /// Copies the samples into storage from `gpa`, so the result outlives the
    /// producer's buffer. On failure nothing is allocated.
    pub fn clone(frame: Frame, gpa: std.mem.Allocator) std.mem.Allocator.Error!Owned {
        var copy = frame;
        copy.samples = try gpa.dupe(i16, frame.samples);
        return .{ .frame = copy, .gpa = gpa };
    }
};

test "a frame holds whole frames and counts them" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    try std.testing.expectError(error.IncompleteFrame, Frame.init(stereo, &.{ 1, 2, 3 }, null));
    const frame = try Frame.init(stereo, &.{ 1, 2, 3, 4 }, 10);
    try std.testing.expectEqual(2, frame.frameCount());
    try std.testing.expectEqual(10, frame.pts);
}

test "a clone owns its samples" {
    const gpa = std.testing.allocator;
    const mono = try audio.Format.init(8000, 1, .s16);
    var samples = [_]i16{ 5, -5 };
    var owned = try (try Frame.init(mono, &samples, 0)).clone(gpa);
    defer owned.deinit();
    samples[0] = 0;
    try std.testing.expectEqualSlices(i16, &.{ 5, -5 }, owned.frame.samples);
    try std.testing.expectEqual(0, owned.frame.pts);
}

fn cloneAndRelease(gpa: std.mem.Allocator) !void {
    const mono = try audio.Format.init(8000, 1, .s16);
    var owned = try (try Frame.init(mono, &.{ 1, 2, 3 }, null)).clone(gpa);
    owned.deinit();
}

test "cloning a frame leaks nothing when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneAndRelease, .{});
}
