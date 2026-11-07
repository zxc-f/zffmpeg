// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
//! The PCM data reader the WAV, Wave64, AU, AIFF, CAF and raw parsers share
//! (TODO.md T65b): it owns the validated frame size and the bytes left in
//! the data (or none for data running to the end of the input), and reads
//! whole frames, still encoded or decoded to s16, skips the rest and counts
//! the frames read. Headers, limits, error precedence, padding and what
//! follows the data stay with each format.
//!
//! An empty result means the end of the data. An output that cannot hold
//! one frame while data remains is `OutputTooSmall` (the owner's choice;
//! notes.md "One PCM data path"); with data of unknown length on a reader
//! without a buffer, the end cannot be peeked, and such an output is
//! `OutputTooSmall` there too.

const std = @import("std");
const pcm = @import("../codec/pcm.zig");
const skip = @import("../io/skip.zig");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");

pub const Error = error{
    /// The input ended inside the data, or inside a frame of data of
    /// unknown length.
    Truncated,
    IoFailure,
    /// The output cannot hold one frame, and data remains.
    OutputTooSmall,
    /// `readSamples` with a codec not stored as s16.
    UnsupportedFormat,
};

/// A format's sample data, from its first byte.
pub const Data = struct {
    /// Null in the default value: no data, which reads as its end (a
    /// parser read before its header).
    reader: ?*std.Io.Reader = null,
    /// The bytes of one frame, validated by the format (at least 1).
    frame_bytes: u32 = 1,
    /// The bytes left; null when the data runs to the end of the input.
    left: ?u64 = 0,
    /// A misaligned byte seek (WAV) left a partial frame at the end of the
    /// data: it is dropped, not `Truncated`.
    misaligned: bool = false,
    /// Whole frames read or skipped so far.
    frames_read: u64 = 0,

    pub fn init(reader: *std.Io.Reader, frame_bytes: u32, left: ?u64) Data {
        std.debug.assert(frame_bytes > 0);
        return .{ .reader = reader, .frame_bytes = frame_bytes, .left = left };
    }

    /// Whole frames, still encoded, into the start of `output`; the prefix
    /// read, empty at the end of the data.
    pub fn readData(d: *Data, output: []u8) Error![]u8 {
        const whole = output[0 .. output.len - output.len % d.frame_bytes];
        if (whole.len == 0) {
            if (try d.atEnd()) return output[0..0];
            return error.OutputTooSmall;
        }
        const len = if (d.left) |left| len: {
            // Only a misaligned seek leaves a partial frame, which is not
            // read.
            const frames_left = left - left % d.frame_bytes;
            const want = @min(std.math.cast(usize, frames_left) orelse std.math.maxInt(usize), whole.len);
            if (want == 0) return output[0..0];
            d.reader.?.readSliceAll(whole[0..want]) catch |err| return mapRead(err);
            d.left = left - want;
            break :len want;
        } else len: {
            // The data runs to the end of the input: a short read ends it.
            // Only `init` makes data of unknown length, with its reader.
            const got = d.reader.?.readSliceShort(whole) catch |err| switch (err) {
                error.ReadFailed => return error.IoFailure,
            };
            const partial = got % d.frame_bytes;
            if (partial != 0 and !d.misaligned) return error.Truncated;
            break :len got - partial;
        };
        d.frames_read += len / d.frame_bytes;
        return whole[0..len];
    }

    /// Whole frames decoded to interleaved s16 into the start of `output`;
    /// the prefix decoded, empty at the end of the data. Only for `codec`s
    /// stored as s16; use `readData` and `pcm.decode` for the others.
    pub fn readSamples(d: *Data, codec: pcm.Codec, output: []i16) Error![]i16 {
        if (codec.storage() != .s16) return error.UnsupportedFormat;
        if (try d.atEnd()) return output[0..0];
        const width = codec.bytesPerSample();
        // At least one: a format's frame holds whole samples.
        const channels = d.frame_bytes / width;
        if (output.len < channels) return error.OutputTooSmall;
        // Whole frames, read into the end of the output's own memory and
        // decoded in place: at most 2 bytes per sample, which an i16 spans.
        const frames = output.len / channels;
        const samples = frames * channels;
        const bytes = std.mem.sliceAsBytes(output[0..samples]);
        const encoded = samples * width;
        const got = try d.readData(bytes[bytes.len - encoded ..]);
        if (got.len == 0) return output[0..0];
        // A short read: the frames read sit at the start of the tail; move
        // them to its end so the in-place decoding finds them there.
        const count = got.len / width;
        const tail = bytes[bytes.len - encoded ..];
        if (got.len < encoded) std.mem.copyBackwards(u8, tail[encoded - got.len ..], got);
        const produced = output[samples - count .. samples];
        pcm.decodeToS16InPlace(codec, produced);
        std.mem.copyForwards(i16, output[0..count], produced);
        return output[0..count];
    }

    /// Skips the rest of the data, counting its frames. With a known length
    /// the input must hold it; otherwise it must end on a whole frame
    /// (after a misaligned seek, a partial last frame is dropped).
    pub fn skipRest(d: *Data) Error!void {
        if (d.left) |left| {
            if (left != 0) skip.discardAll(d.reader.?, left) catch |err| return mapRead(err);
            d.frames_read += left / d.frame_bytes;
        } else {
            const step = 1 << 16;
            // Whole frames are counted as they pass; at most one partial
            // frame is carried, so nothing overflows.
            var partial: u64 = 0;
            while (true) {
                const skipped = d.reader.?.discardShort(step) catch |err| switch (err) {
                    error.ReadFailed => return error.IoFailure,
                };
                partial += skipped;
                d.frames_read += partial / d.frame_bytes;
                partial %= d.frame_bytes;
                if (skipped < step) break;
            }
            if (partial != 0 and !d.misaligned) return error.Truncated;
        }
        d.left = 0;
    }

    /// The rest of the data decoded and written to `out` as raw
    /// little-endian samples of `format`'s storage, through fixed working
    /// storage: a frame must fit `scratch_len` bytes (the caller checks).
    pub fn decodeToRaw(d: *Data, codec: pcm.Codec, format: audio.Format, out: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
        std.debug.assert(d.frame_bytes <= scratch_len);
        var encoded: [scratch_len]u8 = undefined;
        // Storage is at most twice the encoded size (A-law and µ-law to s16).
        var stored: [2 * scratch_len]u8 = undefined;
        const channels = format.channelCount();
        while (true) {
            const bytes = try d.readData(&encoded);
            if (bytes.len == 0) break;
            // At most scratch_len frames of at least one byte.
            const frames: u32 = @intCast(bytes.len / d.frame_bytes);
            // The storage holds twice the scratch, which holds these frames.
            const layout = samples_storage.Layout.init(format.sample_format, channels, frames, .{ .line = 1 }) catch unreachable;
            const buffer = samples_storage.Buffer.init(layout, &stored) catch unreachable;
            _ = pcm.decode(codec, bytes, buffer, 0) catch unreachable;
            pcm.storedToLittle(format.sample_format, buffer.bytes);
            try out.writeAll(buffer.bytes);
        }
    }

    /// Whether no whole frame remains. For data of unknown length the input
    /// is peeked, which a reader without a buffer cannot do: there the end
    /// is not seen, and an output too small for a frame is `OutputTooSmall`
    /// even after the last frame.
    fn atEnd(d: *Data) Error!bool {
        if (d.left) |left| return left < d.frame_bytes;
        const r = d.reader.?;
        if (r.buffer.len == 0) return false;
        _ = r.peekByte() catch |err| return switch (err) {
            error.EndOfStream => true,
            error.ReadFailed => error.IoFailure,
        };
        return false;
    }
};

/// The working storage `decodeToRaw` and `writeS16` use: a format's frame
/// must fit it for `decodeToRaw` (`LimitExceeded` otherwise).
pub const scratch_len = 4096;

/// Writes `samples`, stored as s16, encoded as `codec` (which must be
/// stored as s16), in chunks of the scratch; the caller has checked the
/// frames, so a chunk need not end on one.
pub fn writeS16(out: *std.Io.Writer, codec: pcm.Codec, samples: []const i16) std.Io.Writer.Error!void {
    std.debug.assert(codec.storage() == .s16);
    var bytes: [scratch_len]u8 = undefined;
    var rest = samples;
    while (rest.len > 0) {
        // scratch_len / 2 samples encode into at most scratch_len bytes.
        const take = @min(rest.len, scratch_len / 2);
        try out.writeAll(pcm.encodeFromS16(codec, rest[0..take], &bytes) catch unreachable);
        rest = rest[take..];
    }
}

fn mapRead(err: std.Io.Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

const testing = std.testing;

test "whole frames, the end, and an output too small while data remains" {
    const bytes = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0 };
    var r: std.Io.Reader = .fixed(&bytes);
    var d: Data = .init(&r, 4, bytes.len);
    var small: [3]u8 = undefined;
    try testing.expectError(error.OutputTooSmall, d.readData(&small));
    var out: [10]u8 = undefined;
    try testing.expectEqualSlices(u8, bytes[0..8], try d.readData(&out));
    var samples: [1]i16 = undefined;
    try testing.expectError(error.OutputTooSmall, d.readSamples(.s16le, &samples));
    var two: [2]i16 = undefined;
    try testing.expectEqualSlices(i16, &.{ 5, 6 }, try d.readSamples(.s16le, &two));
    try testing.expectEqual(0, (try d.readData(&small)).len);
    try testing.expectEqual(0, (try d.readSamples(.s16le, &samples)).len);
    try testing.expectEqual(3, d.frames_read);
}

test "data of unknown length: a partial frame is Truncated, unless after a misaligned seek" {
    const bytes = [_]u8{ 1, 0, 2, 0, 3 };
    var r: std.Io.Reader = .fixed(&bytes);
    var d: Data = .init(&r, 2, null);
    var out: [8]u8 = undefined;
    try testing.expectError(error.Truncated, d.readData(&out));
    var r2: std.Io.Reader = .fixed(&bytes);
    var m: Data = .init(&r2, 2, null);
    m.misaligned = true;
    try testing.expectEqual(4, (try m.readData(&out)).len);
    try testing.expectEqual(0, (try m.readData(&out)).len);
    var r3: std.Io.Reader = .fixed(&bytes);
    var s: Data = .init(&r3, 2, null);
    try testing.expectError(error.Truncated, s.skipRest());
    try testing.expectEqual(2, s.frames_read);
}

test "a wide frame decodes through the scratch alone" {
    // 3000 channels of s16: one frame is wider than half the scratch.
    var bytes: [12000]u8 = @splat(0);
    bytes[0] = 7;
    var r: std.Io.Reader = .fixed(&bytes);
    var d: Data = .init(&r, 6000, bytes.len);
    var out: [6000]i16 = undefined;
    const got = try d.readSamples(.s16le, &out);
    try testing.expectEqual(6000, got.len);
    try testing.expectEqual(7, got[0]);
}

test "the default value reads as the end of empty data" {
    var d: Data = .{};
    var out: [4]u8 = undefined;
    try testing.expectEqual(0, (try d.readData(&out)).len);
    var samples: [4]i16 = undefined;
    try testing.expectEqual(0, (try d.readSamples(.s16le, &samples)).len);
    try testing.expectError(error.UnsupportedFormat, d.readSamples(.f32le, &samples));
    try d.skipRest();
}

test "fragmented input: one-byte reads give the same frames" {
    const bytes = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0 };
    for ([_]?u64{ bytes.len, null }) |left| {
        var buffer: [1]u8 = undefined;
        var src: std.testing.Reader = .init(&buffer, &.{.{ .buffer = &bytes }});
        src.artificial_limit = .limited(1);
        var d: Data = .init(&src.interface, 4, left);
        var out: [6]i16 = undefined;
        try testing.expectEqualSlices(i16, &.{ 1, 2, 3, 4, 5, 6 }, try d.readSamples(.s16le, &out));
        try testing.expectEqual(0, (try d.readSamples(.s16le, &out)).len);
        try d.skipRest();
        try testing.expectEqual(3, d.frames_read);
    }
}

test "a failing reader is IoFailure" {
    var failing: std.Io.Reader = .failing;
    var d: Data = .init(&failing, 2, null);
    var out: [4]u8 = undefined;
    try testing.expectError(error.IoFailure, d.readData(&out));
    // Without a buffer the end cannot be peeked.
    var small: [1]u8 = undefined;
    try testing.expectError(error.OutputTooSmall, d.readData(&small));
    try testing.expectError(error.IoFailure, d.skipRest());
}
