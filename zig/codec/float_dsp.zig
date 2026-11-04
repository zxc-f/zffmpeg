// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavutil/float_dsp.c (vector_fmul_window_c,
// vector_fmac_scalar_c, vector_fmul_scalar_c) at the pinned reference
// revision. Copyright 2005 Balatoni Denes, copyright 2006 Loren Merritt.
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! libavutil's float DSP kernels that more than one decoder calls (Vorbis,
//! Opus), as their C versions compute them: the reference build has no
//! assembly, and the same operation order keeps every result bit-exact.
//! The slices may alias where the C callers' pointers do.

const std = @import("std");

/// vector_fmul_window_c: `dst[0 .. 2 * len]` from the end of the saved
/// block `src0[0 .. len]` and the start of the new one `src1[0 .. len]`
/// under the window `win[0 .. 2 * len]`. Each step reads `src0[n]` and
/// `src1[len - 1 - n]` before writing `dst[n]` and `dst[2 * len - 1 - n]`,
/// so `dst` may be `src0` and `src1` may start at `dst[len]`, as Opus
/// CELT's overlap-add has them.
pub fn fmulWindow(dst: []f32, src0: []const f32, src1: []const f32, win: []const f32, len: usize) void {
    for (0..len) |n| {
        const m = 2 * len - 1 - n;
        const s0 = src0[n];
        const s1 = src1[len - 1 - n];
        const wi = win[n];
        const wj = win[m];
        dst[n] = s0 * wj - s1 * wi;
        dst[m] = s0 * wi + s1 * wj;
    }
}

/// vector_fmac_scalar_c: `dst[i] += src[i] * mul`.
pub fn fmacScalar(dst: []f32, src: []const f32, mul: f32) void {
    for (dst, src[0..dst.len]) |*d, s| d.* += s * mul;
}

/// vector_fmul_scalar_c: `dst[i] = src[i] * mul`, in place where `dst` is
/// `src`.
pub fn fmulScalar(dst: []f32, src: []const f32, mul: f32) void {
    for (dst, src[0..dst.len]) |*d, s| d.* = s * mul;
}

const testing = std.testing;

test "the window overlap-add in place equals it out of place" {
    var win: [8]f32 = undefined;
    for (&win, 0..) |*w, i| w.* = @as(f32, @floatFromInt(i + 1)) / 8;
    var a: [8]f32 = .{ 1, -2, 3, -4, 5, -6, 7, -8 };
    var want: [8]f32 = undefined;
    fmulWindow(&want, a[0..4], a[4..8], &win, 4);
    fmulWindow(&a, a[0..4], a[4..8], &win, 4);
    try testing.expectEqualSlices(f32, &want, &a);
    try testing.expectEqual(1 * win[7] - -8 * win[0], want[0]);
}

test "the scalar kernels" {
    var d: [3]f32 = .{ 1, 2, 3 };
    fmacScalar(&d, &.{ 1, 1, 2 }, 0.5);
    try testing.expectEqualSlices(f32, &.{ 1.5, 2.5, 4 }, &d);
    fmulScalar(&d, &d, 2);
    try testing.expectEqualSlices(f32, &.{ 3, 5, 8 }, &d);
}
