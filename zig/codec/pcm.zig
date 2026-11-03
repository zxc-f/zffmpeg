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
//!
//! `Decoder` and `Encoder` wrap the kernels as stages with the send/receive
//! contract of core/stage.zig (TODO.md T14a): one packet becomes one frame and
//! back, with timestamps carried across. They write into caller storage and
//! never allocate.

const std = @import("std");
const audio = @import("../core/audio.zig");
const time = @import("../core/time.zig");
const stage = @import("../core/stage.zig");
const Packet = @import("../core/packet.zig").Packet;
const Frame = @import("../core/frame.zig").Frame;

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

/// Decodes signed 16-bit PCM packets into frames (`pcm_s16le`, `pcm_s16be`).
///
/// Holds at most one frame. A received frame borrows the caller's `storage`
/// and stays valid until the next `send` or `reset`. A packet is read during
/// `send` and not retained. A failed `send` consumes nothing and leaves the
/// state unchanged, so the decoder stays usable.
pub const Decoder = struct {
    endian: std.lang.Endian,
    format: audio.Format,
    storage: []i16,
    pending: ?Frame = null,
    state: stage.State = .accepting,

    pub const Error = stage.SendError || time.RescaleError || error{
        /// The packet does not hold whole frames.
        IncompleteFrame,
        /// `storage` cannot hold the packet's samples.
        OutputTooSmall,
    };

    /// `storage` bounds the packet size: at most `storage.len` samples.
    /// `format` must store packed s16, which the frames carry.
    pub fn init(endian: std.lang.Endian, format: audio.Format, storage: []i16) Decoder {
        std.debug.assert(format.sample_format == .s16);
        return .{ .endian = endian, .format = format, .storage = storage };
    }

    pub fn send(d: *Decoder, packet: Packet) Error!stage.Send {
        if (d.state != .accepting) return error.InputAfterEnd;
        if (d.pending != null) return .full;
        if (packet.data.len % d.format.bytesPerFrame() != 0) return error.IncompleteFrame;
        if (packet.data.len / 2 > d.storage.len) return error.OutputTooSmall;
        const pts = try time.rescaleTimestamp(packet.pts, packet.time_base, d.format.timeBase(), .nearest);
        // Whole frames are whole samples, and the size was checked above.
        const samples = switch (d.endian) {
            inline else => |endian| decodeS16(endian, packet.data, d.storage) catch unreachable,
        };
        d.pending = .{ .format = d.format, .samples = samples, .pts = pts };
        return .accepted;
    }

    pub fn finishInput(d: *Decoder) void {
        if (d.state == .accepting) d.state = .draining;
    }

    pub fn receive(d: *Decoder) stage.Receive(Frame) {
        if (d.pending) |frame| {
            d.pending = null;
            return .{ .output = frame };
        }
        switch (d.state) {
            .accepting => return .need_input,
            .draining, .drained => {
                d.state = .drained;
                return .drained;
            },
        }
    }

    pub fn reset(d: *Decoder) void {
        d.pending = null;
        d.state = .accepting;
    }
};

/// Encodes frames into signed 16-bit PCM packets (`pcm_s16le`, `pcm_s16be`).
///
/// Holds at most one packet. A received packet borrows the caller's `storage`
/// and stays valid until the next `send` or `reset`. Its time base is the
/// format's `1/sample_rate`, its duration the frame count, and every packet is
/// a key packet. A frame is read during `send` and not retained; a failed
/// `send` consumes nothing and leaves the state unchanged.
pub const Encoder = struct {
    endian: std.lang.Endian,
    format: audio.Format,
    storage: []u8,
    pending: ?Packet = null,
    state: stage.State = .accepting,

    pub const Error = stage.SendError || error{
        /// The frame's format is not the encoder's.
        FormatMismatch,
        /// `storage` cannot hold the frame's bytes.
        OutputTooSmall,
    };

    /// `storage` bounds the frame size: at most `storage.len` bytes encoded.
    /// `format` must store packed s16, which the frames carry.
    pub fn init(endian: std.lang.Endian, format: audio.Format, storage: []u8) Encoder {
        std.debug.assert(format.sample_format == .s16);
        return .{ .endian = endian, .format = format, .storage = storage };
    }

    pub fn send(e: *Encoder, frame: Frame) Error!stage.Send {
        if (e.state != .accepting) return error.InputAfterEnd;
        if (e.pending != null) return .full;
        if (!std.meta.eql(frame.format, e.format)) return error.FormatMismatch;
        const bytes = switch (e.endian) {
            inline else => |endian| try encodeS16(endian, frame.samples, e.storage),
        };
        e.pending = .{
            .data = bytes,
            .time_base = e.format.timeBase(),
            .pts = frame.pts,
            .dts = frame.pts,
            .duration = @intCast(frame.frameCount()),
            .flags = .{ .key = true },
        };
        return .accepted;
    }

    pub fn finishInput(e: *Encoder) void {
        if (e.state == .accepting) e.state = .draining;
    }

    pub fn receive(e: *Encoder) stage.Receive(Packet) {
        if (e.pending) |packet| {
            e.pending = null;
            return .{ .output = packet };
        }
        switch (e.state) {
            .accepting => return .need_input,
            .draining, .drained => {
                e.state = .drained;
                return .drained;
            },
        }
    }

    pub fn reset(e: *Encoder) void {
        e.pending = null;
        e.state = .accepting;
    }
};

test "the decoder turns one packet into one frame and applies backpressure" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var storage: [8]i16 = undefined;
    var decoder: Decoder = .init(.big, stereo, &storage);
    const packet: Packet = .{ .data = &.{ 0, 1, 0, 2, 255, 255, 128, 0 }, .time_base = stereo.timeBase(), .pts = 10 };
    try std.testing.expectEqual(stage.Send.accepted, try decoder.send(packet));
    // A second packet before receiving is rejected without being consumed.
    try std.testing.expectEqual(stage.Send.full, try decoder.send(packet));
    const frame = decoder.receive().output;
    try std.testing.expectEqualSlices(i16, &.{ 1, 2, -1, -32768 }, frame.samples);
    try std.testing.expectEqual(10, frame.pts);
    try std.testing.expectEqual(2, frame.frameCount());
    // Retrying the rejected packet yields it exactly once more.
    try std.testing.expectEqual(stage.Send.accepted, try decoder.send(packet));
    try std.testing.expect(decoder.receive() == .output);
    try std.testing.expect(decoder.receive() == .need_input);
}

test "the decoder drains once, stays drained and resets" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var storage: [4]i16 = undefined;
    var decoder: Decoder = .init(.little, mono, &storage);
    _ = try decoder.send(.{ .data = &.{ 7, 0 }, .time_base = mono.timeBase(), .pts = 0 });
    decoder.finishInput();
    decoder.finishInput(); // Idempotent.
    try std.testing.expectError(error.InputAfterEnd, decoder.send(.{ .data = &.{ 0, 0 }, .time_base = mono.timeBase() }));
    // The buffered frame still comes out, then drained on every later call.
    try std.testing.expectEqualSlices(i16, &.{7}, decoder.receive().output.samples);
    try std.testing.expect(decoder.receive() == .drained);
    try std.testing.expect(decoder.receive() == .drained);
    // Reset is not draining: it drops pending output and accepts input again.
    _ = decoder.receive();
    decoder.reset();
    try std.testing.expect(decoder.receive() == .need_input);
    _ = try decoder.send(.{ .data = &.{ 1, 0 }, .time_base = mono.timeBase() });
    decoder.reset();
    try std.testing.expect(decoder.receive() == .need_input);
}

test "decoder failures consume nothing and leave it usable" {
    const stereo = try audio.Format.init(48000, 2, .s16);
    var storage: [2]i16 = undefined;
    var decoder: Decoder = .init(.little, stereo, &storage);
    const tb = stereo.timeBase();
    const two_frames: [8]u8 = @splat(0);
    try std.testing.expectError(error.IncompleteFrame, decoder.send(.{ .data = &.{ 0, 0 }, .time_base = tb }));
    try std.testing.expectError(error.OutputTooSmall, decoder.send(.{ .data = &two_frames, .time_base = tb }));
    const coarse: time.TimeBase = .{ .num = std.math.maxInt(u32), .den = 1 };
    try std.testing.expectError(error.Overflow, decoder.send(.{ .data = &.{ 0, 0, 0, 0 }, .time_base = coarse, .pts = std.math.maxInt(i64) }));
    try std.testing.expect(decoder.receive() == .need_input);
    try std.testing.expectEqual(stage.Send.accepted, try decoder.send(.{ .data = &.{ 1, 0, 2, 0 }, .time_base = tb }));
    try std.testing.expectEqualSlices(i16, &.{ 1, 2 }, decoder.receive().output.samples);
}

test "decoder timestamps are rescaled to the sample-rate time base, and missing ones stay missing" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var storage: [2]i16 = undefined;
    var decoder: Decoder = .init(.little, mono, &storage);
    const millis: time.TimeBase = .{ .num = 1, .den = 1000 };
    _ = try decoder.send(.{ .data = &.{ 0, 0 }, .time_base = millis, .pts = 3 });
    try std.testing.expectEqual(24, decoder.receive().output.pts);
    _ = try decoder.send(.{ .data = &.{ 0, 0 }, .time_base = millis });
    try std.testing.expectEqual(null, decoder.receive().output.pts);
}

test "the encoder turns frames into key packets with timing" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var storage: [8]u8 = undefined;
    var encoder: Encoder = .init(.little, stereo, &storage);
    const frame = try Frame.init(stereo, &.{ 1, 2, -1, -32768 }, 4);
    try std.testing.expectEqual(stage.Send.accepted, try encoder.send(frame));
    try std.testing.expectEqual(stage.Send.full, try encoder.send(frame));
    const packet = encoder.receive().output;
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 255, 255, 0, 128 }, packet.data);
    try std.testing.expectEqual(4, packet.pts);
    try std.testing.expectEqual(4, packet.dts);
    try std.testing.expectEqual(2, packet.duration);
    try std.testing.expect(packet.flags.key);
    try std.testing.expectEqual(stereo.timeBase(), packet.time_base);

    const mono = try audio.Format.init(44100, 1, .s16);
    try std.testing.expectError(error.FormatMismatch, encoder.send(try Frame.init(mono, &.{1}, null)));
    const three_frames: [6]i16 = @splat(0);
    const big = try Frame.init(stereo, &three_frames, null);
    try std.testing.expectError(error.OutputTooSmall, encoder.send(big));
    encoder.finishInput();
    try std.testing.expectError(error.InputAfterEnd, encoder.send(frame));
    try std.testing.expect(encoder.receive() == .drained);
    encoder.reset();
    try std.testing.expectEqual(stage.Send.accepted, try encoder.send(frame));
}

test "decoding then encoding a packet gives the same bytes in either order" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var samples: [4]i16 = undefined;
    var bytes: [8]u8 = undefined;
    const input = [_]u8{ 0x12, 0x34, 0xff, 0x7f, 0x00, 0x80, 0xff, 0xff };
    inline for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var decoder: Decoder = .init(endian, mono, &samples);
        var encoder: Encoder = .init(endian, mono, &bytes);
        _ = try decoder.send(.{ .data = &input, .time_base = mono.timeBase(), .pts = 0 });
        _ = try encoder.send(decoder.receive().output);
        try std.testing.expectEqualSlices(u8, &input, encoder.receive().output.data);
    }
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
