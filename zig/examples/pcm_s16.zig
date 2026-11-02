// SPDX-License-Identifier: LGPL-2.1-or-later
// Original example for this project; not translated from FFmpeg source.
// FFmpeg's libavcodec/pcm.c at the pinned reference revision describes the
// corresponding C behavior; see port.md.
//! Standalone Zig 0.17 signed 16-bit PCM decoding kernel for both byte orders.
//! Run: zig test zig/examples/pcm_s16.zig
//! This is a design example, not a complete codec or a stable library API.

const std = @import("std");

/// Decodes complete signed 16-bit samples from `bytes` into `output`.
/// The caller owns `output`; the returned slice borrows it. Input and output must
/// not overlap. On error, nothing has been written to `output`.
fn decodeS16(
    comptime endian: std.lang.Endian,
    bytes: []const u8,
    output: []i16,
) error{ TruncatedSample, OutputTooSmall }![]i16 {
    if (bytes.len % 2 != 0) return error.TruncatedSample;
    const count = bytes.len / 2;
    if (output.len < count) return error.OutputTooSmall;

    for (output[0..count], 0..) |*sample, i| {
        sample.* = std.mem.readInt(i16, bytes[i * 2 ..][0..2], endian);
    }
    return output[0..count];
}

test "signed PCM byte orders share the same kernel" {
    const expected = [_]i16{ 0, 32767, -32768, -1 };
    const le = [_]u8{ 0, 0, 255, 127, 0, 128, 255, 255 };
    const be = [_]u8{ 0, 0, 127, 255, 128, 0, 255, 255 };
    var output: [4]i16 = undefined;
    try std.testing.expectEqualSlices(i16, &expected, try decodeS16(.little, &le, &output));
    try std.testing.expectEqualSlices(i16, &expected, try decodeS16(.big, &be, &output));
}

test "invalid buffers fail before writing output" {
    var output = [_]i16{123};
    try std.testing.expectError(error.TruncatedSample, decodeS16(.little, &.{0}, &output));
    try std.testing.expectError(error.OutputTooSmall, decodeS16(.little, &.{ 0, 0, 0, 0 }, &output));
    try std.testing.expectEqual(@as(i16, 123), output[0]);
    try std.testing.expectEqual(@as(usize, 0), (try decodeS16(.little, &.{}, &output)).len);
}
