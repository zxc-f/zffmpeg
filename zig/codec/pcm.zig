// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/pcm.c at the pinned reference revision describes the
// corresponding C behavior; see port.md. A-law and mu-law use g711.zig.
//! PCM codecs (TODO.md T20b): u8, s8, s16/s24/s32/s64 and f32/f64 in both
//! byte orders, A-law and mu-law, decoded into and encoded from the packed
//! sample storage of core/samples.zig, as FFmpeg's decoders store them.
//!
//! The kernels are scalar loops over caller-provided memory: no allocation, no
//! I/O and no stream state. Each codec is a `comptime` specialization of one
//! per-sample conversion; sample counts stay runtime values. `decodeS16` and
//! `encodeS16` are the same conversion over `i16` slices.
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
const builtin = @import("builtin");
const audio = @import("../core/audio.zig");
const sample_buffers = @import("../core/samples.zig");
const g711 = @import("g711.zig");
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
    return decodeToS16(if (endian == .little) .s16le else .s16be, bytes, output);
}

/// Encodes `samples` as signed 16-bit values in `endian` order into the start of
/// `output` and returns the encoded prefix of `output`.
pub fn encodeS16(
    comptime endian: std.lang.Endian,
    samples: []const i16,
    output: []u8,
) EncodeError![]u8 {
    return encodeFromS16(if (endian == .little) .s16le else .s16be, samples, output);
}

/// Decodes `bytes`, whole samples of `codec`, into the start of `output` and
/// returns that prefix. `codec` must be stored as s16: `s16le`, `s16be`,
/// `alaw` or `mulaw`.
pub fn decodeToS16(codec: Codec, bytes: []const u8, output: []i16) DecodeError![]i16 {
    std.debug.assert(codec.storage() == .s16);
    const width = codec.bytesPerSample();
    if (bytes.len % width != 0) return error.TruncatedSample;
    const count = bytes.len / width;
    if (output.len < count) return error.OutputTooSmall;
    std.debug.assert(disjoint(bytes, std.mem.sliceAsBytes(output)));
    switch (codec) {
        inline .s16le, .s16be, .alaw, .mulaw => |c| {
            const w = comptime c.bytesPerSample();
            for (output[0..count], 0..) |*sample, i| sample.* = decodeSample(c, bytes[i * w ..][0..w]);
        },
        else => unreachable, // asserted above
    }
    return output[0..count];
}

/// Encodes `samples` as `codec` into the start of `output` and returns that
/// prefix. `codec` must be stored as s16.
pub fn encodeFromS16(codec: Codec, samples: []const i16, output: []u8) EncodeError![]u8 {
    std.debug.assert(codec.storage() == .s16);
    // At most 2 bytes per sample: an `i16` slice already spans that much
    // memory, so the product cannot overflow `usize`.
    const byte_count = samples.len * codec.bytesPerSample();
    if (output.len < byte_count) return error.OutputTooSmall;
    std.debug.assert(disjoint(std.mem.sliceAsBytes(samples), output));
    switch (codec) {
        inline .s16le, .s16be, .alaw, .mulaw => |c| {
            const w = comptime c.bytesPerSample();
            for (samples, 0..) |sample, i| output[i * w ..][0..w].* = encodeSample(c, sample);
        },
        else => unreachable, // asserted above
    }
    return output[0..byte_count];
}

/// Reorders stored samples of `format`, held in the target's byte order, to
/// little-endian in place (nothing to do on little-endian targets). This is
/// how FFmpeg's `-c:a pcm_<storage>le` serializes decoded samples.
pub fn storedToLittle(format: audio.SampleFormat, bytes: []u8) void {
    const size = format.bytesPerSample();
    if (native_endian == .little or size == 1) return;
    var i: usize = 0;
    while (i + size <= bytes.len) : (i += size) std.mem.reverse(u8, bytes[i..][0..size]);
}

/// A PCM encoding: codec identity, separate from the storage its samples
/// decode to and from the containers that carry it.
pub const Codec = enum {
    u8,
    s8,
    s16le,
    s16be,
    s24le,
    s24be,
    s32le,
    s32be,
    s64le,
    s64be,
    f32le,
    f32be,
    f64le,
    f64be,
    alaw,
    mulaw,

    /// FFmpeg's codec name, such as `pcm_s16le`.
    pub fn name(codec: Codec) []const u8 {
        return switch (codec) {
            inline else => |c| "pcm_" ++ @tagName(c),
        };
    }

    /// The packed sample format FFmpeg's decoder gives: s8 is stored offset
    /// as u8, s24 shifted into the top of s32, A-law and mu-law as s16.
    pub fn storage(codec: Codec) audio.SampleFormat {
        return switch (codec) {
            .u8, .s8 => .u8,
            .s16le, .s16be, .alaw, .mulaw => .s16,
            .s24le, .s24be, .s32le, .s32be => .s32,
            .s64le, .s64be => .s64,
            .f32le, .f32be => .flt,
            .f64le, .f64be => .dbl,
        };
    }

    /// Bytes per encoded sample.
    pub fn bytesPerSample(codec: Codec) u8 {
        return switch (codec) {
            .u8, .s8, .alaw, .mulaw => 1,
            .s16le, .s16be => 2,
            .s24le, .s24be => 3,
            .s32le, .s32be, .f32le, .f32be => 4,
            .s64le, .s64be, .f64le, .f64be => 8,
        };
    }
};

/// The integer that holds one stored sample of `codec`. Floats are kept as
/// their bit patterns, so every value, NaN payloads included, round-trips.
fn Stored(comptime codec: Codec) type {
    return switch (codec.storage()) {
        .u8 => u8,
        .s16 => i16,
        .s32 => i32,
        .s64 => i64,
        .flt => u32,
        .dbl => u64,
        .u8p, .s16p, .s32p, .s64p, .fltp, .dblp => unreachable, // storage() is packed
    };
}

/// Decodes one sample: the single conversion every kernel here uses.
fn decodeSample(comptime codec: Codec, bytes: *const [codec.bytesPerSample()]u8) Stored(codec) {
    return switch (codec) {
        .u8 => bytes[0],
        .s8 => bytes[0] ^ 0x80,
        .s16le, .s32le, .s64le, .f32le, .f64le => std.mem.readInt(Stored(codec), bytes, .little),
        .s16be, .s32be, .s64be, .f32be, .f64be => std.mem.readInt(Stored(codec), bytes, .big),
        .s24le, .s24be => blk: {
            const raw: u32 = std.mem.readInt(u24, bytes, if (codec == .s24le) .little else .big);
            break :blk @bitCast(raw << 8);
        },
        .alaw => g711.decodeAlaw(bytes[0]),
        .mulaw => g711.decodeMulaw(bytes[0]),
    };
}

/// Encodes one sample, the inverse of `decodeSample` (s24 drops the low 8
/// bits; A-law and mu-law quantize).
fn encodeSample(comptime codec: Codec, value: Stored(codec)) [codec.bytesPerSample()]u8 {
    var bytes: [codec.bytesPerSample()]u8 = undefined;
    switch (codec) {
        .u8 => bytes[0] = value,
        .s8 => bytes[0] = value ^ 0x80,
        .s16le, .s32le, .s64le, .f32le, .f64le => std.mem.writeInt(Stored(codec), &bytes, value, .little),
        .s16be, .s32be, .s64be, .f32be, .f64be => std.mem.writeInt(Stored(codec), &bytes, value, .big),
        .s24le, .s24be => {
            const bits: u32 = @bitCast(value);
            std.mem.writeInt(u24, &bytes, @truncate(bits >> 8), if (codec == .s24le) .little else .big);
        },
        .alaw => bytes[0] = g711.encodeAlaw(value),
        .mulaw => bytes[0] = g711.encodeMulaw(value),
    }
    return bytes;
}

/// Stored samples are in the target's own byte order, as FFmpeg keeps them.
const native_endian = builtin.cpu.arch.endian();

pub const CodecError = error{
    /// The buffer's sample format is not the codec's storage.
    FormatMismatch,
    /// The bytes are not whole frames: one encoded sample per channel.
    IncompleteFrame,
    /// The destination cannot hold every frame.
    OutputTooSmall,
};

/// Decodes `bytes`, whole frames of interleaved encoded samples, into `out`
/// from frame `offset` (at most `out.layout.samples`), and returns the number
/// of frames decoded. `out` must be in `codec.storage()`. On failure nothing
/// is written.
pub fn decode(codec: Codec, bytes: []const u8, out: sample_buffers.Buffer, offset: u32) CodecError!u32 {
    std.debug.assert(offset <= out.layout.samples);
    if (out.layout.format != codec.storage()) return error.FormatMismatch;
    const width: usize = codec.bytesPerSample();
    const frame_bytes = width * out.layout.channels;
    if (bytes.len % frame_bytes != 0) return error.IncompleteFrame;
    const frames = bytes.len / frame_bytes;
    if (frames > out.layout.samples - offset) return error.OutputTooSmall;
    const dest = out.plane(0)[offset * out.layout.blockAlign() ..];
    switch (codec) {
        inline else => |c| {
            const in_width = comptime c.bytesPerSample();
            const out_width = @sizeOf(Stored(c));
            for (0..bytes.len / in_width) |i| {
                const value = decodeSample(c, bytes[i * in_width ..][0..in_width]);
                std.mem.writeInt(Stored(c), dest[i * out_width ..][0..out_width], value, native_endian);
            }
        },
    }
    // frames <= out.layout.samples, a u32.
    return @intCast(frames);
}

/// Encodes `frames` frames of `in` from frame `offset` into the start of
/// `out` and returns the encoded prefix. `in` must be in `codec.storage()`
/// and hold those frames. On failure nothing is written.
pub fn encode(codec: Codec, in: sample_buffers.View, offset: u32, frames: u32, out: []u8) CodecError![]u8 {
    const start: u64 = offset;
    std.debug.assert(start + frames <= in.layout.samples);
    if (in.layout.format != codec.storage()) return error.FormatMismatch;
    const frame_count: usize = frames;
    const count = frame_count * in.layout.channels;
    const out_len = count * codec.bytesPerSample();
    if (out.len < out_len) return error.OutputTooSmall;
    const source = in.plane(0)[offset * in.layout.blockAlign() ..];
    switch (codec) {
        inline else => |c| {
            const in_width = @sizeOf(Stored(c));
            const out_width = comptime c.bytesPerSample();
            for (0..count) |i| {
                const value = std.mem.readInt(Stored(c), source[i * in_width ..][0..in_width], native_endian);
                out[i * out_width ..][0..out_width].* = encodeSample(c, value);
            }
        },
    }
    return out[0..out_len];
}

fn disjoint(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return true;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start + a.len <= b_start or b_start + b.len <= a_start;
}

/// Decodes packets of any codec into frames of its storage format
/// (`codec.storage()`, packed).
///
/// Holds at most one frame. A received frame borrows the caller's `storage`
/// and stays valid until the next `send` or `reset`. A packet is read during
/// `send` and not retained. A failed `send` consumes nothing and leaves the
/// state unchanged, so the decoder stays usable.
pub const Decoder = struct {
    codec: Codec,
    format: audio.Format,
    storage: []u8,
    pending: ?Frame = null,
    state: stage.State = .accepting,

    pub const Error = stage.SendError || time.RescaleError || error{
        /// The packet does not hold whole frames.
        IncompleteFrame,
        /// `storage` cannot hold the packet's decoded samples.
        OutputTooSmall,
    };

    /// `storage` bounds the packet size: its samples, decoded, must fit in
    /// `storage.len` bytes. `format.sample_format` must be `codec.storage()`.
    pub fn init(codec: Codec, format: audio.Format, storage: []u8) Decoder {
        std.debug.assert(format.sample_format == codec.storage());
        return .{ .codec = codec, .format = format, .storage = storage };
    }

    pub fn send(d: *Decoder, packet: Packet) Error!stage.Send {
        if (d.state != .accepting) return error.InputAfterEnd;
        if (d.pending != null) return .full;
        const width: usize = d.codec.bytesPerSample();
        const channels = d.format.channelCount();
        if (packet.data.len % (width * channels) != 0) return error.IncompleteFrame;
        const frames = packet.data.len / (width * channels);
        const out_len = frames * d.format.bytesPerFrame();
        if (out_len > d.storage.len) return error.OutputTooSmall;
        const pts = try time.rescaleTimestamp(packet.pts, packet.time_base, d.format.timeBase(), .nearest);
        if (frames > 0) {
            // At most storage.len bytes, so the count fits in u32 for any
            // storage a caller can hold; the sizes were checked above.
            const count = std.math.cast(u32, frames) orelse return error.OutputTooSmall;
            const layout = sample_buffers.Layout.init(d.codec.storage(), channels, count, .{ .line = 1 }) catch return error.OutputTooSmall;
            const buffer = sample_buffers.Buffer.init(layout, d.storage) catch unreachable;
            _ = decode(d.codec, packet.data, buffer, 0) catch unreachable;
        }
        d.pending = .{ .format = d.format, .data = d.storage[0..out_len], .pts = pts };
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

/// Encodes frames of a codec's storage format into packets of any codec.
///
/// Holds at most one packet. A received packet borrows the caller's `storage`
/// and stays valid until the next `send` or `reset`. Its time base is the
/// format's `1/sample_rate`, its duration the frame count, and every packet is
/// a key packet. A frame is read during `send` and not retained; a failed
/// `send` consumes nothing and leaves the state unchanged.
pub const Encoder = struct {
    codec: Codec,
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
    /// `format.sample_format` must be `codec.storage()`.
    pub fn init(codec: Codec, format: audio.Format, storage: []u8) Encoder {
        std.debug.assert(format.sample_format == codec.storage());
        return .{ .codec = codec, .format = format, .storage = storage };
    }

    pub fn send(e: *Encoder, frame: Frame) Error!stage.Send {
        if (e.state != .accepting) return error.InputAfterEnd;
        if (e.pending != null) return .full;
        if (!std.meta.eql(frame.format, e.format)) return error.FormatMismatch;
        const frames = frame.frameCount();
        const width: usize = e.codec.bytesPerSample();
        const out_len = frames * e.format.channelCount() * width;
        if (out_len > e.storage.len) return error.OutputTooSmall;
        if (frames > 0) {
            // The format matches the codec's storage and the size was checked.
            _ = encode(e.codec, frame.view(), 0, @intCast(frames), e.storage) catch unreachable;
        }
        e.pending = .{
            .data = e.storage[0..out_len],
            .time_base = e.format.timeBase(),
            .pts = frame.pts,
            .dts = frame.pts,
            .duration = @intCast(frames),
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

/// Native-endian bytes of s16 samples, as a frame of them holds.
fn s16Bytes(comptime values: []const i16) []const u8 {
    return std.mem.sliceAsBytes(values);
}

test "the decoder turns one packet into one frame and applies backpressure" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var storage: [16]u8 = undefined;
    var decoder: Decoder = .init(.s16be, stereo, &storage);
    const packet: Packet = .{ .data = &.{ 0, 1, 0, 2, 255, 255, 128, 0 }, .time_base = stereo.timeBase(), .pts = 10 };
    try std.testing.expectEqual(stage.Send.accepted, try decoder.send(packet));
    // A second packet before receiving is rejected without being consumed.
    try std.testing.expectEqual(stage.Send.full, try decoder.send(packet));
    const frame = decoder.receive().output;
    try std.testing.expectEqualSlices(u8, s16Bytes(&.{ 1, 2, -1, -32768 }), frame.data);
    try std.testing.expectEqual(10, frame.pts);
    try std.testing.expectEqual(2, frame.frameCount());
    // Retrying the rejected packet yields it exactly once more.
    try std.testing.expectEqual(stage.Send.accepted, try decoder.send(packet));
    try std.testing.expect(decoder.receive() == .output);
    try std.testing.expect(decoder.receive() == .need_input);
}

test "the decoder drains once, stays drained and resets" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var storage: [8]u8 = undefined;
    var decoder: Decoder = .init(.s16le, mono, &storage);
    _ = try decoder.send(.{ .data = &.{ 7, 0 }, .time_base = mono.timeBase(), .pts = 0 });
    decoder.finishInput();
    decoder.finishInput(); // Idempotent.
    try std.testing.expectError(error.InputAfterEnd, decoder.send(.{ .data = &.{ 0, 0 }, .time_base = mono.timeBase() }));
    // The buffered frame still comes out, then drained on every later call.
    try std.testing.expectEqualSlices(u8, s16Bytes(&.{7}), decoder.receive().output.data);
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
    var storage: [4]u8 = undefined;
    var decoder: Decoder = .init(.s16le, stereo, &storage);
    const tb = stereo.timeBase();
    const two_frames: [8]u8 = @splat(0);
    try std.testing.expectError(error.IncompleteFrame, decoder.send(.{ .data = &.{ 0, 0 }, .time_base = tb }));
    try std.testing.expectError(error.OutputTooSmall, decoder.send(.{ .data = &two_frames, .time_base = tb }));
    const coarse: time.TimeBase = .{ .num = std.math.maxInt(u32), .den = 1 };
    try std.testing.expectError(error.Overflow, decoder.send(.{ .data = &.{ 0, 0, 0, 0 }, .time_base = coarse, .pts = std.math.maxInt(i64) }));
    try std.testing.expect(decoder.receive() == .need_input);
    try std.testing.expectEqual(stage.Send.accepted, try decoder.send(.{ .data = &.{ 1, 0, 2, 0 }, .time_base = tb }));
    try std.testing.expectEqualSlices(u8, s16Bytes(&.{ 1, 2 }), decoder.receive().output.data);
}

test "decoder timestamps are rescaled to the sample-rate time base, and missing ones stay missing" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var storage: [4]u8 = undefined;
    var decoder: Decoder = .init(.s16le, mono, &storage);
    const millis: time.TimeBase = .{ .num = 1, .den = 1000 };
    _ = try decoder.send(.{ .data = &.{ 0, 0 }, .time_base = millis, .pts = 3 });
    try std.testing.expectEqual(24, decoder.receive().output.pts);
    _ = try decoder.send(.{ .data = &.{ 0, 0 }, .time_base = millis });
    try std.testing.expectEqual(null, decoder.receive().output.pts);
}

test "the decoder and encoder take every codec in its storage format" {
    // 24-bit stereo: one frame of 3-byte samples decodes to two s32 values.
    const stereo = try audio.Format.init(48000, 2, .s32);
    var storage: [8]u8 = undefined;
    var decoder: Decoder = .init(.s24le, stereo, &storage);
    const packet = [_]u8{ 0x01, 0x02, 0x03, 0xff, 0xff, 0xff };
    _ = try decoder.send(.{ .data = &packet, .time_base = stereo.timeBase() });
    const frame = decoder.receive().output;
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]i32{ 0x03020100, -256 }), frame.data);
    var bytes: [6]u8 = undefined;
    var encoder: Encoder = .init(.s24le, stereo, &bytes);
    _ = try encoder.send(frame);
    try std.testing.expectEqualSlices(u8, &packet, encoder.receive().output.data);
    // An empty packet is an empty frame and an empty packet again.
    _ = try decoder.send(.{ .data = &.{}, .time_base = stereo.timeBase() });
    const empty = decoder.receive().output;
    try std.testing.expectEqual(0, empty.frameCount());
    _ = try encoder.send(empty);
    try std.testing.expectEqual(0, encoder.receive().output.data.len);
}

test "the encoder turns frames into key packets with timing" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var storage: [8]u8 = undefined;
    var encoder: Encoder = .init(.s16le, stereo, &storage);
    const frame = try Frame.fromS16(stereo, &.{ 1, 2, -1, -32768 }, 4);
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
    try std.testing.expectError(error.FormatMismatch, encoder.send(try Frame.fromS16(mono, &.{1}, null)));
    const three_frames: [6]i16 = @splat(0);
    const big = try Frame.fromS16(stereo, &three_frames, null);
    try std.testing.expectError(error.OutputTooSmall, encoder.send(big));
    encoder.finishInput();
    try std.testing.expectError(error.InputAfterEnd, encoder.send(frame));
    try std.testing.expect(encoder.receive() == .drained);
    encoder.reset();
    try std.testing.expectEqual(stage.Send.accepted, try encoder.send(frame));
}

test "decoding then encoding a packet gives the same bytes in either order" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var samples: [8]u8 = undefined;
    var bytes: [8]u8 = undefined;
    const input = [_]u8{ 0x12, 0x34, 0xff, 0x7f, 0x00, 0x80, 0xff, 0xff };
    inline for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const codec: Codec = if (endian == .little) .s16le else .s16be;
        var decoder: Decoder = .init(codec, mono, &samples);
        var encoder: Encoder = .init(codec, mono, &bytes);
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
        // 16-bit PCM up to 48 kHz has the plain 44-byte header.
        const plain = comptime fixture.plainWriterOutput() and fixture.expected.accept.codec == .pcm_s16le and
            fixture.expected.accept.sample_rate <= 48000;
        if (plain) {
            const stream = fixture.expected.accept;
            comptime std.debug.assert(stream.samples.s16.len <= max_samples);
            const file = fixtures.bytes(fixture.name);
            try std.testing.expectEqualStrings("data", file[36..40]);
            const data = file[header_len..];

            var decoded: [max_samples]i16 = undefined;
            try std.testing.expectEqualSlices(i16, stream.samples.s16, try decodeS16(.little, data, &decoded));
            var encoded: [max_samples * 2]u8 = undefined;
            try std.testing.expectEqualSlices(u8, data, try encodeS16(.little, stream.samples.s16, &encoded));
        }
    }
}

// zig/testing/vectors/pcm.txt holds SHA-256 digests of what the pinned
// FFmpeg's PCM decoders and encoders produce (zig/testing/reference/
// pcm_vectors.c) from the patterns `fillPattern` regenerates. Every line is
// checked; the count makes a missing or truncated file fail.
const pcm_vectors = @embedFile("../testing/vectors/pcm.txt");
const pcm_vector_count = 32;

/// The input patterns pcm_vectors.c defines, with `width` bytes per sample;
/// returns the sample count.
fn fillPattern(name: []const u8, width: usize, out: []u8) error{UnknownPattern}!usize {
    if (std.mem.eql(u8, name, "all8")) {
        for (out[0..256], 0..) |*byte, i| byte.* = @intCast(i);
        return 256 / width;
    }
    if (std.mem.eql(u8, name, "all16")) {
        for (0..65536) |k| std.mem.writeInt(u16, out[2 * k ..][0..2], @intCast(k), .little);
        return 131072 / width;
    }
    if (std.mem.eql(u8, name, "lcg")) {
        // A 64-bit LCG: the wrapping arithmetic is the generator's definition.
        var x: u64 = 1;
        for (out[0 .. 65536 * width]) |*byte| {
            x = x *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(x >> 56);
        }
        return 65536;
    }
    return error.UnknownPattern;
}

fn codecFromName(text: []const u8) ?Codec {
    if (!std.mem.startsWith(u8, text, "pcm_")) return null;
    return std.meta.stringToEnum(Codec, text[4..]);
}

fn vectorField(fields: *std.mem.TokenIterator(u8, .scalar)) error{MalformedVector}![]const u8 {
    return fields.next() orelse error.MalformedVector;
}

test "every codec decodes and encodes exactly as FFmpeg's" {
    const gpa = std.testing.allocator;
    const pattern = try gpa.alloc(u8, 65536 * 8 + 131072);
    defer gpa.free(pattern);
    var lines = std.mem.tokenizeAny(u8, pcm_vectors, "\r\n");
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line[2..], ' ');
        const codec = codecFromName(try vectorField(&fields)) orelse return error.MalformedVector;
        const pattern_name = try vectorField(&fields);
        const count = try std.fmt.parseInt(u32, try vectorField(&fields), 10);
        try std.testing.expectEqualStrings(try vectorField(&fields), codec.storage().name());
        const want = try vectorField(&fields);

        const layout = try sample_buffers.Layout.init(codec.storage(), 1, count, .{ .line = 1 });
        var owned = try sample_buffers.Buffer.alloc(gpa, layout);
        defer owned.deinit();
        const stored_size = codec.storage().bytesPerSample();
        var digest: [32]u8 = undefined;
        switch (line[0]) {
            'D' => {
                const width = codec.bytesPerSample();
                try std.testing.expectEqual(count, try fillPattern(pattern_name, width, pattern));
                try std.testing.expectEqual(count, try decode(codec, pattern[0 .. count * width], owned.buffer, 0));
                storedToLittle(codec.storage(), owned.buffer.bytes);
                std.crypto.hash.sha2.Sha256.hash(owned.buffer.bytes, &digest, .{});
            },
            'E' => {
                try std.testing.expectEqual(count, try fillPattern(pattern_name, stored_size, pattern));
                @memcpy(owned.buffer.bytes, pattern[0 .. count * stored_size]);
                storedToLittle(codec.storage(), owned.buffer.bytes);
                const out = try gpa.alloc(u8, count * codec.bytesPerSample());
                defer gpa.free(out);
                std.crypto.hash.sha2.Sha256.hash(try encode(codec, owned.buffer.view(), 0, count, out), &digest, .{});
            },
            else => return error.MalformedVector,
        }
        const hex = std.fmt.bytesToHex(digest, .lower);
        std.testing.expectEqualStrings(want, &hex) catch |err| {
            std.debug.print("vector \"{s}\"\n", .{line});
            return err;
        };
        seen += 1;
    }
    try std.testing.expectEqual(pcm_vector_count, seen);
}

test "codecs name themselves as FFmpeg does and store as its decoders do" {
    try std.testing.expectEqualStrings("pcm_s24be", Codec.s24be.name());
    try std.testing.expectEqualStrings("pcm_mulaw", Codec.mulaw.name());
    try std.testing.expectEqual(audio.SampleFormat.u8, Codec.s8.storage());
    try std.testing.expectEqual(audio.SampleFormat.s32, Codec.s24le.storage());
    try std.testing.expectEqual(audio.SampleFormat.s16, Codec.alaw.storage());
    try std.testing.expectEqual(3, Codec.s24be.bytesPerSample());
    try std.testing.expectEqual(Codec.f64le, codecFromName("pcm_f64le").?);
    try std.testing.expectEqual(null, codecFromName("pcm_vidc"));
}

test "short input, a wrong format and a small destination write nothing" {
    const stereo = try sample_buffers.Layout.init(.s32, 2, 4, .{ .line = 1 });
    var bytes: [32]u8 = @splat(0xee);
    const buffer = try sample_buffers.Buffer.init(stereo, &bytes);
    // One s24 sample is 3 bytes; a stereo frame 6.
    try std.testing.expectError(error.IncompleteFrame, decode(.s24le, &.{ 1, 2, 3, 4, 5 }, buffer, 0));
    try std.testing.expectError(error.IncompleteFrame, decode(.s24le, &.{ 1, 2, 3 }, buffer, 0));
    try std.testing.expectError(error.FormatMismatch, decode(.s16le, &.{ 1, 2, 3, 4 }, buffer, 0));
    const five_frames: [30]u8 = @splat(1);
    try std.testing.expectError(error.OutputTooSmall, decode(.s24le, &five_frames, buffer, 0));
    try std.testing.expectError(error.OutputTooSmall, decode(.s24le, five_frames[0..12], buffer, 3));
    const untouched: [32]u8 = @splat(0xee);
    try std.testing.expectEqualSlices(u8, &untouched, &bytes);
    var small: [11]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, encode(.s24be, buffer.view(), 0, 2, &small));
    try std.testing.expectError(error.FormatMismatch, encode(.f32le, buffer.view(), 0, 1, &small));
}

test "frames land at the requested offset, interleaved, from misaligned input" {
    const stereo = try sample_buffers.Layout.init(.s32, 2, 3, .{ .line = 1 });
    var bytes: [24]u8 = @splat(0);
    const buffer = try sample_buffers.Buffer.init(stereo, &bytes);
    // Start the input at an odd address: kernels read bytes, not aligned words.
    var storage: [13]u8 = undefined;
    const input = storage[1..13];
    @memcpy(input, &[_]u8{ 0x01, 0x00, 0x00, 0x80, 0xff, 0xff, 0x7f, 0x02, 0x03, 0x04, 0x05, 0x06 });
    const s24 = input[0..6]; // one stereo frame of s24le
    try std.testing.expectEqual(1, try decode(.s24le, s24, buffer, 2));
    const stored = buffer.plane(0)[16..24];
    try std.testing.expectEqual(0x00000100, std.mem.readInt(i32, stored[0..4], native_endian));
    // 0xffff80 shifted into the top: 0xffff8000.
    try std.testing.expectEqual(-0x8000, std.mem.readInt(i32, stored[4..8], native_endian));
    try std.testing.expectEqual(0, std.mem.readInt(i32, buffer.plane(0)[0..4], native_endian));
    // And back, to a misaligned destination.
    var out_storage: [7]u8 = undefined;
    try std.testing.expectEqualSlices(u8, s24, try encode(.s24le, buffer.view(), 2, 1, out_storage[1..7]));
    // Two stereo frames of s32be, the second into frame 1.
    try std.testing.expectEqual(1, try decode(.s32be, input[4..12], buffer, 1));
    const left_bits: u32 = 0xffff7f02;
    const left: i32 = @bitCast(left_bits);
    try std.testing.expectEqual(left, std.mem.readInt(i32, buffer.plane(0)[8..12], native_endian));
    try std.testing.expectEqual(0x03040506, std.mem.readInt(i32, buffer.plane(0)[12..16], native_endian));
}

test "s8 and u8 differ only by the offset of 128" {
    const layout = try sample_buffers.Layout.init(.u8, 1, 3, .{ .line = 1 });
    var bytes: [3]u8 = undefined;
    const buffer = try sample_buffers.Buffer.init(layout, &bytes);
    _ = try decode(.s8, &.{ 0x00, 0x7f, 0x80 }, buffer, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0xff, 0x00 }, &bytes);
    var out: [3]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0xff, 0x00 }, try encode(.u8, buffer.view(), 0, 3, &out));
}
