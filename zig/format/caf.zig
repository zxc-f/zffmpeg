// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/cafdec.c, caf.c and isom.h (ff_mov_get_lpcm_codec_id) at the
// pinned reference revision describe FFmpeg's behavior; see
// zig/testing/fixtures/caf/README.md. The `chan` chunk is read by
// mov_chan.zig, as cafdec.c uses mov_chan.c.
//! Bounded Apple CAF (Core Audio Format) reading (TODO.md T22d): linear PCM
//! (`lpcm`: s8, s16, s24, s32 and s64 integers and f32 and f64 floats, in
//! either byte order), A-law (`alaw`) and µ-law (`ulaw`), with 1 to
//! `max_channels` channels (T23b) in the layout FFmpeg reads: unspecified, or
//! what a `chan` chunk before `data` gives (mov_chan.zig).
//!
//! A file is `caff`, version 1, then a 32-byte `desc` chunk describing the
//! stream, then chunks with 64-bit big-endian sizes to the end of the input,
//! one of them `data`. The parser is sequential and never seeks: every chunk
//! before and after `data` is read or skipped and validated, and a `data`
//! size of -1 (unknown length) runs to the end of the input, behind the same
//! `unknown_length` option as WAV and AU. Its accepted subset, error names
//! and error precedence are the contract in zig/testing/fixtures/caf/README.md;
//! every fixture there is tested below. Nothing is allocated. There is no
//! writer: FFmpeg's CAF muxer is not part of T22d.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");
const pcm = @import("../codec/pcm.zig");
const skip = @import("../io/skip.zig");
const pcmdata = @import("pcmdata.zig");
const mov_chan = @import("mov_chan.zig");

/// Contract errors (see the CAF fixture README), plus `IoFailure` for a
/// failing reader.
pub const Error = error{
    InvalidCaf,
    InvalidFormat,
    Truncated,
    UnsupportedFormat,
    UnsupportedStreamingSize,
    LimitExceeded,
    IoFailure,
    /// `readSamples` or `readData` got an output that cannot hold one frame
    /// while data remains (T65b).
    OutputTooSmall,
};

/// Configurable policy limits; exceeding one is `error.LimitExceeded`.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// libswresample's `SWR_CH_MAX`: more channels than FFmpeg converts.
    max_channels: u16 = max_channels,
    /// Counts every chunk header after `desc`.
    max_chunks: u32 = 4096,
    /// Read a `data` size of -1 to the end of the input, in whole frames,
    /// instead of `UnsupportedStreamingSize`; the frame count is then unknown.
    unknown_length: bool = false,
};

pub const Info = struct {
    codec: pcm.Codec,
    /// The decoded stream: `sample_format` is `codec.storage()`.
    format: audio.Format,
    /// Sample frames in `data`; null when its length is unknown.
    frame_count: ?u64,
};

/// The default channel limit.
pub const max_channels = 64;

/// The 8-byte file header and the `desc` chunk's 12-byte header.
const file_header_len = 8;
const chunk_header_len = 12;
/// The `desc` body: the AudioStreamBasicDescription.
const desc_len = 32;

/// The most bytes `probeScore` reads.
pub const probe_bytes = file_header_len + chunk_header_len;

/// FFmpeg's content probe (`probe` in cafdec.c), a score from 0 to 100 for the
/// first bytes of a stream: `caff`, version 1, then a `desc` chunk of size
/// 32 score 100.
pub fn probeScore(head: []const u8) u8 {
    if (head.len < probe_bytes or !std.mem.eql(u8, head[0..4], "caff")) return 0;
    if (std.mem.readInt(u16, head[4..6], .big) != 1) return 0;
    if (!std.mem.eql(u8, head[8..12], "desc")) return 0;
    if (std.mem.readInt(u64, head[12..20], .big) != desc_len) return 0;
    return 100;
}

/// `kCAFLinearPCMFormatFlagIsFloat` and `...IsLittleEndian`.
const flag_float: u32 = 1;
const flag_little_endian: u32 = 2;

/// The codec of a `desc`, as `read_desc_chunk` chooses it: `lpcm` by the
/// flags and the sample size in whole bytes (always signed, as FFmpeg passes
/// it), `alaw` and `ulaw` by their format ID.
fn codecFor(format_id: *const [4]u8, flags: u32, bits: u32) ?pcm.Codec {
    if (std.mem.eql(u8, format_id, "alaw")) return .alaw;
    if (std.mem.eql(u8, format_id, "ulaw")) return .mulaw;
    if (!std.mem.eql(u8, format_id, "lpcm")) return null;
    const little = flags & flag_little_endian != 0;
    if (flags & flag_float != 0) return switch (bits) {
        32 => if (little) .f32le else .f32be,
        64 => if (little) .f64le else .f64be,
        else => null,
    };
    return switch (bits) {
        8 => .s8,
        16 => if (little) .s16le else .s16be,
        24 => if (little) .s24le else .s24be,
        32 => if (little) .s32le else .s32be,
        64 => if (little) .s64le else .s64be,
        else => null,
    };
}

/// Whether CAF carries `codec`: every PCM codec but u8, which `lpcm` cannot
/// name since FFmpeg reads it as signed.
pub fn carries(codec: pcm.Codec) bool {
    return codec != .u8;
}

/// The sample rate, a big-endian double: truncated toward zero as FFmpeg's
/// `av_clipd` and int conversion do. Below 1 (zero, negative or NaN) is
/// `InvalidFormat`; above the limit, `LimitExceeded`.
fn sampleRate(bytes: *const [8]u8, max_sample_rate: u32) Error!u32 {
    const value: f64 = @bitCast(std.mem.readInt(u64, bytes, .big));
    if (!(value >= 1)) return error.InvalidFormat;
    const limit: f64 = @floatFromInt(max_sample_rate);
    if (value >= limit + 1) return error.LimitExceeded;
    return @intFromFloat(@trunc(value));
}

const ChunkHeader = struct {
    id: [4]u8,
    /// Signed, as CAF defines it: -1 is an unknown `data` size.
    size: i64,
};

/// Reads one CAF stream from a borrowed reader.
///
/// Call `readHeader` once, then `readData` (or, for encodings stored as s16,
/// `readSamples`) until it returns nothing (or not at all), then `finish`,
/// which skips any unread data and validates the chunks after it. The stream
/// is valid only if `finish` succeeds.
pub const Parser = struct {
    reader: *std.Io.Reader,
    limits: Limits,
    codec: pcm.Codec = .s16be,
    /// Bytes of one frame (a CAF packet of PCM); set by `readHeader`.
    frame_bytes: u32 = 0,
    chunks: u32 = 0,
    /// The sample data's reader (T65b), set at `data`: the bytes not yet
    /// delivered, or none when the data runs to the end of the input.
    data: pcmdata.Data = .{},
    state: State = .header,

    const State = enum { header, data, done };

    pub fn init(reader: *std.Io.Reader, limits: Limits) Parser {
        return .{ .reader = reader, .limits = limits };
    }

    /// Reads the file header, `desc`, and every chunk up to the samples.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        const header = try p.readArray(file_header_len + chunk_header_len);
        if (!std.mem.eql(u8, header[0..4], "caff")) return error.InvalidCaf;
        // header[6..8] are the file flags, which no version-1 reader uses.
        if (std.mem.readInt(u16, header[4..6], .big) != 1) return error.InvalidCaf;
        if (!std.mem.eql(u8, header[8..12], "desc")) return error.InvalidCaf;
        if (std.mem.readInt(u64, header[12..20], .big) != desc_len) return error.InvalidCaf;

        // The description, checked as the contract orders it: the rate, the
        // codec, the channels, then the packet layout.
        const desc = try p.readArray(desc_len);
        const rate = try sampleRate(desc[0..8], p.limits.max_sample_rate);
        const flags = std.mem.readInt(u32, desc[12..16], .big);
        const bytes_per_packet = std.mem.readInt(u32, desc[16..20], .big);
        const frames_per_packet = std.mem.readInt(u32, desc[20..24], .big);
        const channels = std.mem.readInt(u32, desc[24..28], .big);
        const bits = std.mem.readInt(u32, desc[28..32], .big);
        const codec = codecFor(desc[8..12], flags, bits) orelse return error.UnsupportedFormat;
        if (channels == 0) return error.InvalidFormat;
        if (channels > p.limits.max_channels) return error.LimitExceeded;
        // max_channels is a u16.
        const channel_count: u16 = @intCast(channels);
        // Without `chan` FFmpeg leaves the layout unspecified.
        var layout: audio.ChannelLayout = .{ .unspecified = channel_count };
        // At most 8 bytes times 65535 channels: no overflow.
        const sample_bytes: u32 = codec.bytesPerSample();
        const frame_bytes = sample_bytes * channel_count;
        // PCM is one frame per packet of exactly the frame's bytes.
        if (frames_per_packet != 1 or bytes_per_packet != frame_bytes) return error.InvalidFormat;
        p.codec = codec;
        p.frame_bytes = frame_bytes;

        while (true) {
            const chunk = try p.nextChunk() orelse return error.InvalidCaf; // no `data`
            if (std.mem.eql(u8, &chunk.id, "data")) {
                const frame_count = try p.beginData(chunk.size);
                p.state = .data;
                const format: audio.Format = .{ .sample_rate = rate, .layout = layout, .sample_format = codec.storage() };
                return .{ .codec = codec, .format = format, .frame_count = frame_count };
            }
            if (std.mem.eql(u8, &chunk.id, "chan")) {
                // A `chan` keeps the count `desc` gave: only its layout changes.
                layout = try p.readChan(chunk.size, layout);
            } else {
                try p.skipChunk(chunk);
            }
        }
    }

    /// `chan` before `data`: FFmpeg's `ff_mov_read_chan`. After `data` it is
    /// skipped like any other chunk, as the stream is reported by then.
    fn readChan(p: *Parser, size: i64, layout: audio.ChannelLayout) Error!audio.ChannelLayout {
        if (size < 0) return error.InvalidCaf;
        return mov_chan.read(p.reader, @intCast(size), layout) catch |err| switch (err) {
            error.InvalidFormat => error.InvalidFormat,
            error.Truncated => error.Truncated,
            error.LimitExceeded => error.LimitExceeded,
            error.IoFailure => error.IoFailure,
        };
    }

    /// `data`: a 4-byte edit count, then the samples.
    fn beginData(p: *Parser, size: i64) Error!?u64 {
        if (size == -1) {
            if (!p.limits.unknown_length) return error.UnsupportedStreamingSize;
            _ = try p.readArray(4);
            p.data = .init(p.reader, p.frame_bytes, null);
            return null;
        }
        if (size < 4) return error.InvalidCaf;
        _ = try p.readArray(4);
        // Positive, so it fits in u64.
        const data_bytes: u64 = @intCast(size - 4);
        if (data_bytes % p.frame_bytes != 0) return error.InvalidFormat;
        p.data = .init(p.reader, p.frame_bytes, data_bytes);
        return data_bytes / p.frame_bytes;
    }

    /// Any chunk but `desc` and `data`: skipped, except a packet table,
    /// which FFmpeg uses to trim samples.
    fn skipChunk(p: *Parser, chunk: ChunkHeader) Error!void {
        if (std.mem.eql(u8, &chunk.id, "pakt")) return error.UnsupportedFormat;
        if (std.mem.eql(u8, &chunk.id, "desc")) return error.InvalidCaf;
        if (chunk.size < 0) return error.InvalidCaf;
        const size: u64 = @intCast(chunk.size);
        skip.discardAll(p.reader, size) catch |err| return mapRead(err);
    }

    /// The next chunk header, or null at the end of the input exactly
    /// between chunks.
    fn nextChunk(p: *Parser) Error!?ChunkHeader {
        var bytes: [chunk_header_len]u8 = undefined;
        const len = p.reader.readSliceShort(&bytes) catch |err| switch (err) {
            error.ReadFailed => return error.IoFailure,
        };
        if (len == 0) return null;
        if (len < bytes.len) return error.Truncated;
        if (p.chunks >= p.limits.max_chunks) return error.LimitExceeded;
        p.chunks += 1;
        return .{ .id = bytes[0..4].*, .size = std.mem.readInt(i64, bytes[4..12], .big) };
    }

    /// Decodes whole frames of interleaved samples into the start of `output`
    /// and returns the decoded prefix, empty at the end of the data; an
    /// output that cannot hold one frame while data remains is
    /// `OutputTooSmall`, and before `readHeader` the end. Only for encodings stored as s16 (others are `UnsupportedFormat`); use `readData` and
    /// `pcm.decode` for the others.
    pub fn readSamples(p: *Parser, output: []i16) Error![]i16 {
        return p.data.readSamples(p.codec, output);
    }

    /// Reads whole frames of data, still encoded, into the start of `output`
    /// and returns that prefix: the stream-copy counterpart of `readSamples`,
    /// with its end and `OutputTooSmall`.
    pub fn readData(p: *Parser, output: []u8) Error![]u8 {
        return p.data.readData(output);
    }

    /// Skips any unread data, then validates the chunks after it to the end
    /// of the input; a second `data` is `InvalidCaf`. Data of unknown length
    /// is skipped to the end of the input, which must end on a whole frame.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        const runs_to_end = p.data.left == null;
        try p.data.skipRest();
        if (!runs_to_end) {
            while (try p.nextChunk()) |chunk| {
                if (std.mem.eql(u8, &chunk.id, "data")) return error.InvalidCaf;
                try p.skipChunk(chunk);
            }
        }
        p.state = .done;
    }

    fn readArray(p: *Parser, comptime n: usize) Error![n]u8 {
        var bytes: [n]u8 = undefined;
        p.reader.readSliceAll(&bytes) catch |err| return mapRead(err);
        return bytes;
    }
};

fn mapRead(err: std.Io.Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

/// Validates a complete CAF stream without decoding its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    try parser.finish();
    return info;
}

pub const DecodeError = Error || std.Io.Writer.Error;

/// Decodes a CAF stream and writes its samples to `out` as raw little-endian
/// samples of its storage format, using fixed working storage. The caller
/// flushes `out`. A frame wider than that storage (4 KiB, possible only with a
/// channel limit above the default) is `LimitExceeded`.
pub fn decodeToRaw(reader: *std.Io.Reader, out: *std.Io.Writer, limits: Limits) DecodeError!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    // readData delivers nothing when a frame does not fit, which would end
    // the loop below early; only a channel limit above the default allows it.
    if (parser.frame_bytes > pcmdata.scratch_len) return error.LimitExceeded;
    try parser.data.decodeToRaw(info.codec, info.format, out);
    try parser.finish();
    return info;
}

const fixtures = @import("../testing/fixtures.zig");

/// The implementation's codec for a manifest codec; the names are FFmpeg's.
fn codecOf(comptime codec: fixtures.Codec) pcm.Codec {
    return comptime std.meta.stringToEnum(pcm.Codec, @tagName(codec)["pcm_".len..]).?;
}

const Decoded = struct {
    info: Info,
    raw: []const u8,
};

fn decodeAll(reader: *std.Io.Reader, limits: Limits, storage: []u8) DecodeError!Decoded {
    var out: std.Io.Writer = .fixed(storage);
    const info = try decodeToRaw(reader, &out, limits);
    return .{ .info = info, .raw = out.buffered() };
}

/// The parser error each fixture failure names. The manifest's `Failure` stays
/// independent of the parser; this exhaustive switch is the only link.
fn expectedError(failure: fixtures.caf.Failure) Error {
    return switch (failure) {
        .InvalidCaf => error.InvalidCaf,
        .InvalidFormat => error.InvalidFormat,
        .Truncated => error.Truncated,
        .UnsupportedFormat => error.UnsupportedFormat,
        .UnsupportedStreamingSize => error.UnsupportedStreamingSize,
        .LimitExceeded => error.LimitExceeded,
    };
}

fn expectInfo(comptime stream: fixtures.Stream, info: Info) !void {
    try std.testing.expectEqual(codecOf(stream.codec), info.codec);
    try std.testing.expectEqual(stream.channels, info.format.channelCount());
    try stream.expectLayout(info.format.layout);
    try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
    try std.testing.expectEqual(codecOf(stream.codec).storage(), info.format.sample_format);
    // Unknown-length data has no count; the samples still fix the length.
    if (info.frame_count) |count| try std.testing.expectEqual(stream.frameCount(), count);
}

fn expectFixture(comptime fixture: fixtures.caf.Fixture, comptime unknown_length: bool, reader: *std.Io.Reader) !void {
    var storage: [1024]u8 = undefined;
    const result = decodeAll(reader, .{ .unknown_length = unknown_length }, &storage);
    errdefer std.debug.print("fixture {s}, unknown_length {}\n", .{ fixture.name, unknown_length });
    switch (comptime fixture.result(unknown_length)) {
        .accept => |stream| {
            const decoded = try result;
            try expectInfo(stream, decoded.info);
            var expected: [1024]u8 = undefined;
            try std.testing.expectEqualSlices(u8, stream.samples.littleEndian(&expected), decoded.raw);
        },
        .reject => |failure| try std.testing.expectError(expectedError(failure), result),
    }
}

test "every CAF fixture gives its contract result from memory" {
    inline for (fixtures.caf.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var reader: std.Io.Reader = .fixed(fixtures.caf.bytes(fixture.name));
            try expectFixture(fixture, unknown_length, &reader);
        }
    }
}

test "every CAF fixture gives the same result from one-byte reads" {
    inline for (fixtures.caf.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var buffer: [1]u8 = undefined;
            var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.caf.bytes(fixture.name) }});
            source.artificial_limit = .limited(1);
            try expectFixture(fixture, unknown_length, &source.interface);
        }
    }
}

test "probing validates without decoding and agrees with decoding" {
    @setEvalBranchQuota(10_000);
    inline for (fixtures.caf.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var reader: std.Io.Reader = .fixed(fixtures.caf.bytes(fixture.name));
            const result = probe(&reader, .{ .unknown_length = unknown_length });
            switch (comptime fixture.result(unknown_length)) {
                .accept => |stream| try expectInfo(stream, try result),
                .reject => |failure| try std.testing.expectError(expectedError(failure), result),
            }
        }
    }
}

test "readSamples gives s16 samples for every encoding stored as s16" {
    var checked: usize = 0;
    inline for (fixtures.caf.all) |fixture| {
        if (fixture.expected == .accept and fixture.expected.accept.samples == .s16) {
            var reader: std.Io.Reader = .fixed(fixtures.caf.bytes(fixture.name));
            var parser: Parser = .init(&reader, .{});
            _ = try parser.readHeader();
            var storage: [256]i16 = undefined;
            var len: usize = 0;
            while (true) {
                const decoded = try parser.readSamples(storage[len..]);
                if (decoded.len == 0) break;
                len += decoded.len;
            }
            try parser.finish();
            try std.testing.expectEqualSlices(i16, fixture.expected.accept.samples.s16, storage[0..len]);
            checked += 1;
        }
    }
    // Both 16-bit byte orders, A-law and µ-law among them.
    try std.testing.expect(checked > 4);
}

test "limits are configurable" {
    var storage: [16]u8 = undefined;
    var fast: std.Io.Reader = .fixed(fixtures.caf.bytes("caf_rate_over_limit"));
    const decoded = try decodeAll(&fast, .{ .max_sample_rate = 192_001 }, &storage);
    try std.testing.expectEqual(192_001, decoded.info.format.sample_rate);
    var slow: std.Io.Reader = .fixed(fixtures.caf.bytes("caf_s16be_mono_8k"));
    try std.testing.expectError(error.LimitExceeded, probe(&slow, .{ .max_sample_rate = 7999 }));
    // caf_chunks_around_data has six chunks after `desc`: free, chan, info,
    // kuki, data and free.
    var few: std.Io.Reader = .fixed(fixtures.caf.bytes("caf_chunks_around_data"));
    try std.testing.expectError(error.LimitExceeded, probe(&few, .{ .max_chunks = 5 }));
    var enough: std.Io.Reader = .fixed(fixtures.caf.bytes("caf_chunks_around_data"));
    _ = try probe(&enough, .{ .max_chunks = 6 });
}

fn rateBytes(value: f64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .big);
    return bytes;
}

test "the rate is truncated, and a rate just above the limit is refused" {
    try std.testing.expectEqual(192_000, try sampleRate(&rateBytes(192_000.99), 192_000));
    try std.testing.expectError(error.LimitExceeded, sampleRate(&rateBytes(192_001), 192_000));
    try std.testing.expectError(error.InvalidFormat, sampleRate(&rateBytes(-8000), 192_000));
    try std.testing.expectError(error.InvalidFormat, sampleRate(&rateBytes(0.5), 192_000));
    try std.testing.expectError(error.LimitExceeded, sampleRate(&rateBytes(std.math.inf(f64)), 192_000));
}

test "unknown-length CAF data past 4 GiB is read to the end of the input" {
    const synthetic = @import("../testing/synthetic.zig");
    // The header of caf_data_size_unknown, up to its samples: s16be mono.
    const fixture = fixtures.caf.bytes("caf_data_size_unknown");
    const header = fixture[0 .. fixture.len - 8];
    const limits: Limits = .{ .unknown_length = true };
    var reader_buffer: [64]u8 = undefined;
    var whole: synthetic.ZeroStream = .init(header, 5 << 30, "", &reader_buffer);
    try std.testing.expectEqual(null, (try probe(&whole.interface, limits)).frame_count);
    var partial: synthetic.ZeroStream = .init(header, (5 << 30) + 1, "", &reader_buffer);
    try std.testing.expectError(error.Truncated, probe(&partial.interface, limits));
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    var storage: [2048]u8 = undefined;
    // Any contract error is acceptable; the parser must not crash or overrun.
    inline for (.{ false, true }) |unknown_length| {
        var reader: std.Io.Reader = .fixed(input[0..len]);
        _ = decodeAll(&reader, .{ .unknown_length = unknown_length }, &storage) catch {};
    }
}

test "fuzz: arbitrary input never crashes the CAF parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        hostile.fuzzSeed(fixtures.caf.bytes("caf_s16be_mono_8k"), &.{}),
        hostile.fuzzSeed(fixtures.caf.bytes("caf_chunks_around_data"), &.{}),
        hostile.fuzzSeed(fixtures.caf.bytes("caf_f64be_stereo_96k"), &.{}),
        hostile.fuzzSeed(fixtures.caf.bytes("caf_data_size_unknown"), &.{}),
    } });
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}

test "a chunk of 4 GiB ends as truncation" {
    // Skipping `free` overflowed the reader's position on 32-bit targets.
    // 8000 Hz (a big-endian f64), lpcm, flags 0, 2 bytes per packet, 1
    // frame per packet, 1 channel, 16 bits.
    const desc = [8]u8{ 0x40, 0xbf, 0x40, 0, 0, 0, 0, 0 } ++ "lpcm".* ++ [4]u8{ 0, 0, 0, 0 } ++
        [4]u8{ 0, 0, 0, 2 } ++ [4]u8{ 0, 0, 0, 1 } ++ [4]u8{ 0, 0, 0, 1 } ++ [4]u8{ 0, 0, 0, 16 };
    const file = "caff".* ++ [4]u8{ 0, 1, 0, 0 } ++ "desc".* ++ [8]u8{ 0, 0, 0, 0, 0, 0, 0, 32 } ++ desc ++
        "free".* ++ [8]u8{ 0, 0, 0, 1, 0, 0, 0, 0 } ++ @as([64]u8, @splat(0));
    var reader: std.Io.Reader = .fixed(&file);
    try std.testing.expectError(error.Truncated, probe(&reader, .{}));
}

const hostile = @import("../testing/hostile.zig");
