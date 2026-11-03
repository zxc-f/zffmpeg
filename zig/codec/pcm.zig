// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/pcm.c (pcm_s16le/pcm_s16be) at the pinned reference revision
// describes the corresponding C behavior; see port.md.
//! Signed 16-bit PCM sample conversion between wire bytes and `i16` samples.
//!
//! The kernels are scalar loops over caller-provided slices: no allocation, no
//! I/O and no stream state. Byte order is a `comptime` parameter, so each order
//! is its own specialization; sample counts stay runtime values.
//!
//! Ownership: the caller owns every slice. A returned slice is a prefix of the
//! caller's output and stays valid as long as that buffer does. Input and output
//! must not overlap; Debug and ReleaseSafe builds assert it. A call that returns
//! an error has written nothing to its output.

const std = @import("std");

pub const DecodeError = error{
    /// The input length is odd, so its last sample is incomplete.
    TruncatedSample,
    /// The output has room for fewer samples than the input holds.
    OutputTooSmall,
};

pub const EncodeError = error{
    /// The output has room for fewer bytes than the samples need.
    OutputTooSmall,
};

/// Decodes `bytes` as complete signed 16-bit samples in `endian` order into the
/// start of `output` and returns the decoded prefix of `output`.
pub fn decodeS16(
    comptime endian: std.lang.Endian,
    bytes: []const u8,
    output: []i16,
) DecodeError![]i16 {
    if (bytes.len % 2 != 0) return error.TruncatedSample;
    const count = bytes.len / 2;
    if (output.len < count) return error.OutputTooSmall;
    std.debug.assert(disjoint(bytes, std.mem.sliceAsBytes(output)));

    for (output[0..count], 0..) |*sample, i| {
        sample.* = std.mem.readInt(i16, bytes[i * 2 ..][0..2], endian);
    }
    return output[0..count];
}

/// Encodes `samples` as signed 16-bit values in `endian` order into the start of
/// `output` and returns the encoded prefix of `output`.
pub fn encodeS16(
    comptime endian: std.lang.Endian,
    samples: []const i16,
    output: []u8,
) EncodeError![]u8 {
    // An `i16` slice occupies `samples.len * 2` bytes of memory, so the product
    // cannot overflow `usize`.
    const byte_count = samples.len * 2;
    if (output.len < byte_count) return error.OutputTooSmall;
    std.debug.assert(disjoint(std.mem.sliceAsBytes(samples), output));

    for (samples, 0..) |sample, i| {
        std.mem.writeInt(i16, output[i * 2 ..][0..2], sample, endian);
    }
    return output[0..byte_count];
}

fn disjoint(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return true;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start + a.len <= b_start or b_start + b.len <= a_start;
}

test "signed PCM byte orders share the same kernel" {
    const expected = [_]i16{ 0, 32767, -32768, -1 };
    const le = [_]u8{ 0, 0, 255, 127, 0, 128, 255, 255 };
    const be = [_]u8{ 0, 0, 127, 255, 128, 0, 255, 255 };
    var output: [4]i16 = undefined;
    try std.testing.expectEqualSlices(i16, &expected, try decodeS16(.little, &le, &output));
    try std.testing.expectEqualSlices(i16, &expected, try decodeS16(.big, &be, &output));
}

test "invalid decode inputs fail before writing output" {
    var output = [_]i16{123};
    try std.testing.expectError(error.TruncatedSample, decodeS16(.little, &.{0}, &output));
    try std.testing.expectError(error.TruncatedSample, decodeS16(.little, &.{ 0, 0, 0 }, &output));
    try std.testing.expectError(error.OutputTooSmall, decodeS16(.little, &.{ 0, 0, 0, 0 }, &output));
    try std.testing.expectEqual(123, output[0]);
    try std.testing.expectEqual(0, (try decodeS16(.little, &.{}, &output)).len);
    try std.testing.expectEqual(123, output[0]);
}

test "decoding returns only the written prefix of a larger output" {
    var output: [4]i16 = @splat(7);
    const decoded = try decodeS16(.little, &.{ 1, 0, 2, 0 }, &output);
    try std.testing.expectEqualSlices(i16, &.{ 1, 2 }, decoded);
    try std.testing.expectEqualSlices(i16, &.{ 7, 7 }, output[2..]);
}

test "encoding writes both byte orders and the signed extrema" {
    const samples = [_]i16{ 0, 32767, -32768, -1 };
    var output: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 127, 0, 128, 255, 255 }, try encodeS16(.little, &samples, &output));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 127, 255, 128, 0, 255, 255 }, try encodeS16(.big, &samples, &output));
}

test "encoding fails before writing when the output is too small" {
    var output: [3]u8 = @splat(0xaa);
    try std.testing.expectError(error.OutputTooSmall, encodeS16(.little, &.{ 1, 2 }, &output));
    const untouched: [3]u8 = @splat(0xaa);
    try std.testing.expectEqualSlices(u8, &untouched, &output);
    try std.testing.expectEqual(0, (try encodeS16(.little, &.{}, &output)).len);
    try std.testing.expectEqualSlices(u8, &untouched, &output);
}

test "every 16-bit value round-trips in both byte orders" {
    inline for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var value: i32 = std.math.minInt(i16);
        while (value <= std.math.maxInt(i16)) : (value += 1) {
            const sample: i16 = @intCast(value);
            const one = [1]i16{sample};
            var bytes: [2]u8 = undefined;
            _ = try encodeS16(endian, &one, &bytes);

            // Check the wire bytes without std.mem.writeInt.
            const bits: u16 = @bitCast(sample);
            const low: u8 = @truncate(bits);
            const high: u8 = @truncate(bits >> 8);
            const expected: [2]u8 = if (endian == .little) .{ low, high } else .{ high, low };
            try std.testing.expectEqualSlices(u8, &expected, &bytes);

            var decoded: [1]i16 = undefined;
            try std.testing.expectEqual(sample, (try decodeS16(endian, &bytes, &decoded))[0]);
        }
    }
}

test "kernels agree with the independently generated writer-output fixtures" {
    const fixtures = @import("../testing/fixtures.zig");
    // Canonical files: RIFF header (12), 16-byte `fmt ` chunk (24), `data` header (8).
    const header_len = 44;
    const max_samples = 64;
    inline for (fixtures.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            comptime std.debug.assert(stream.samples.len <= max_samples);
            const file = fixtures.bytes(fixture.name);
            try std.testing.expectEqualStrings("data", file[36..40]);
            const data = file[header_len..];

            var decoded: [max_samples]i16 = undefined;
            try std.testing.expectEqualSlices(i16, stream.samples, try decodeS16(.little, data, &decoded));
            var encoded: [max_samples * 2]u8 = undefined;
            try std.testing.expectEqualSlices(u8, data, try encodeS16(.little, stream.samples, &encoded));
        }
    }
}
