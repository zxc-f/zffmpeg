// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/aiffdec.c, aiffenc.c and aiff.c at the pinned reference
// revision describe FFmpeg's behavior; see zig/testing/fixtures/aiff/README.md.
//! Bounded AIFF and AIFF-C reading and known-length writing (TODO.md T22b):
//! s8, s16, s24 and s32 big-endian PCM in plain AIFF, and in AIFF-C also u8
//! (`raw `), s16 little-endian (`sowt`), 32- and 64-bit big-endian float
//! (`fl32`, `fl64`), A-law (`alaw`) and µ-law (`ulaw`).
//!
//! The parser is sequential and never seeks, so it works on pipes: `COMM`
//! must come before `SSND`, which FFmpeg also needs on non-seekable input.
//! It reads every field exactly into local arrays and validates the whole
//! declared FORM extent, including the chunks after the sound data. The
//! 80-bit extended sample rate is converted as FFmpeg converts it. Its
//! accepted subset, error names and error precedence are the contract in
//! zig/testing/fixtures/aiff/README.md; every fixture there is tested below.
//!
//! The writer emits the header FFmpeg's muxer writes on seekable output
//! without metadata: plain AIFF for the big-endian integer encodings, AIFF-C
//! with an `FVER` chunk and the compression type for the others, exact sizes
//! known up front, and a pad byte after odd data. Neither the parser nor the
//! writer allocates.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");
const pcm = @import("../codec/pcm.zig");

/// Contract errors (see the AIFF fixture README), plus `IoFailure` for a
/// failing reader.
pub const Error = error{
    InvalidAiff,
    InvalidFormat,
    Truncated,
    UnsupportedFormat,
    LimitExceeded,
    IoFailure,
};

/// Configurable policy limits; exceeding one is `error.LimitExceeded`.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// Counts every chunk header inside the FORM extent.
    max_chunks: u32 = 4096,
};

pub const Info = struct {
    codec: pcm.Codec,
    /// The decoded stream: `sample_format` is `codec.storage()`.
    format: audio.Format,
    /// Sample frames in `SSND`, which `COMM` declares too.
    frame_count: u64,
    /// The FORM type is `AIFC`.
    aifc: bool,
};

/// `AIFF_C_VERSION1`: the `FVER` timestamp that makes `COMM` carry a
/// compression type.
const aifc_version1: u32 = 0xA2805140;

/// Bytes decoded per read; a whole number of frames of every encoding.
const scratch_len = 4096;

/// The codec of plain AIFF, or of AIFF-C compressed as `NONE` or `twos`,
/// from the sample size: whole bytes only (FFmpeg rounds other sizes up).
fn codecForBits(bits: u16) ?pcm.Codec {
    return switch (bits) {
        8 => .s8,
        16 => .s16be,
        24 => .s24be,
        32 => .s32be,
        else => null,
    };
}

/// An AIFF-C compression type, matched case-insensitively as FFmpeg's
/// `ff_codec_get_id` does in its second pass over `ff_codec_aiff_tags`.
/// `NONE` and `twos` take the codec from the sample size; the others ignore it.
fn codecForCompression(compression: [4]u8, bits: u16) ?pcm.Codec {
    const types = [_]struct { tag: *const [4]u8, codec: ?pcm.Codec }{
        .{ .tag = "NONE", .codec = null },
        .{ .tag = "twos", .codec = null },
        .{ .tag = "raw ", .codec = .u8 },
        .{ .tag = "sowt", .codec = .s16le },
        .{ .tag = "fl32", .codec = .f32be },
        .{ .tag = "fl64", .codec = .f64be },
        .{ .tag = "alaw", .codec = .alaw },
        .{ .tag = "ulaw", .codec = .mulaw },
        .{ .tag = "in24", .codec = .s24be },
        .{ .tag = "in32", .codec = .s32be },
    };
    for (types) |entry| {
        if (std.ascii.eqlIgnoreCase(&compression, entry.tag)) return entry.codec orelse codecForBits(bits);
    }
    return null;
}

/// The compression type the writer stores for `codec`, the first match in
/// `ff_codec_aiff_tags`: `NONE` means plain AIFF.
fn compressionFor(codec: pcm.Codec) ?*const [4]u8 {
    return switch (codec) {
        .s8, .s16be, .s24be, .s32be => "NONE",
        .u8 => "raw ",
        .s16le => "sowt",
        .f32be => "fl32",
        .f64be => "fl64",
        .alaw => "alaw",
        .mulaw => "ulaw",
        .s24le, .s32le, .s64le, .s64be, .f32le, .f64le => null,
    };
}

/// Whether AIFF carries `codec`.
pub fn carries(codec: pcm.Codec) bool {
    return compressionFor(codec) != null;
}

/// The most bytes `probeScore` reads.
pub const probe_bytes = 12;

/// FFmpeg's content probe (`aiff_probe` in aiffdec.c), a score from 0 to 100
/// for the first bytes of a stream: `FORM`, a big-endian size of at least 4,
/// then `AIFF` or `AIFC` score 100. FFmpeg's zero padding makes shorter
/// input fail, as here.
pub fn probeScore(head: []const u8) u8 {
    if (head.len < probe_bytes or !std.mem.eql(u8, head[0..4], "FORM")) return 0;
    if (std.mem.readInt(u32, head[4..8], .big) < 4) return 0;
    if (!std.mem.eql(u8, head[8..12], "AIFF") and !std.mem.eql(u8, head[8..12], "AIFC")) return 0;
    return 100;
}

/// The sample size the writer stores in `COMM`: the codec's bits.
fn bitsFor(codec: pcm.Codec) u16 {
    const sample_bytes: u16 = codec.bytesPerSample();
    return sample_bytes * 8;
}

/// The 80-bit extended sample rate, converted as `get_aiff_header` does: the
/// exponent must leave a shift of at most 63 either way; a right shift rounds
/// half up, with the 64-bit wrap FFmpeg's unsigned arithmetic has. Zero is
/// `InvalidFormat`, and a rate above the limit (FFmpeg would truncate one
/// that overflows its `int`) is `LimitExceeded`.
fn sampleRate(bytes: *const [10]u8, max_sample_rate: u32) Error!u32 {
    const exponent_field = std.mem.readInt(u16, bytes[0..2], .big);
    const mantissa = std.mem.readInt(u64, bytes[2..10], .big);
    const field: i32 = exponent_field;
    const exponent = field - 16383 - 63;
    if (exponent < -63 or exponent > 63) return error.InvalidFormat;
    const rate: u64 = if (exponent >= 0) rate: {
        const shift: u6 = @intCast(exponent);
        const wide_shift: u7 = shift;
        // A set bit shifted out makes the rate overflow FFmpeg's int as well.
        if (shift > 0 and mantissa >> @intCast(64 - wide_shift) != 0) return error.LimitExceeded;
        break :rate mantissa << shift;
    } else rate: {
        const shift: u6 = @intCast(-exponent);
        const one: u64 = 1;
        const half = one << (shift - 1);
        break :rate (mantissa +% half) >> shift;
    };
    if (rate == 0) return error.InvalidFormat;
    if (rate > max_sample_rate) return error.LimitExceeded;
    return @intCast(rate);
}

/// The 80-bit extended form of an integer rate, as `aiff_write_header`
/// writes it from the rate's double: exponent 16383 + floor(log2 rate), and
/// the rate shifted up to set bit 63.
fn encodeRate(rate: u32) [10]u8 {
    std.debug.assert(rate > 0);
    const top: u6 = @intCast(31 - @clz(rate));
    var bytes: [10]u8 = undefined;
    const exponent: u16 = top;
    std.mem.writeInt(u16, bytes[0..2], 16383 + exponent, .big);
    const wide: u64 = rate;
    std.mem.writeInt(u64, bytes[2..10], wide << (63 - top), .big);
    return bytes;
}

const ChunkHeader = struct {
    id: [4]u8,
    size: u32,
};

/// Reads one AIFF or AIFF-C stream from a borrowed reader.
///
/// Call `readHeader` once, then `readData` (or, for encodings stored as s16,
/// `readSamples`) until it returns nothing (or not at all), then `finish`,
/// which skips any unread data and validates the rest of the FORM extent.
/// The stream is valid only if `finish` succeeds.
pub const Parser = struct {
    reader: *std.Io.Reader,
    limits: Limits,
    /// Bytes of the declared FORM extent not yet consumed.
    extent_left: u64 = 0,
    chunks: u32 = 0,
    /// The FORM type is `AIFC`, and `FVER` may change the version.
    aifc: bool = false,
    version: u32 = 0,
    /// Set by `COMM`.
    format: ?audio.Format = null,
    codec: pcm.Codec = .s16be,
    frame_bytes: u32 = 0,
    declared_frames: u32 = 0,
    /// Bytes of sound data not yet delivered.
    data_left: u64 = 0,
    /// The `SSND` size is odd, so a pad byte follows it.
    data_padded: bool = false,
    state: State = .header,

    const State = enum { header, data, done };

    pub fn init(reader: *std.Io.Reader, limits: Limits) Parser {
        return .{ .reader = reader, .limits = limits };
    }

    /// Reads the FORM header and every chunk up to the start of the sound data.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        const form = try p.readArray(12);
        if (!std.mem.eql(u8, form[0..4], "FORM")) return error.InvalidAiff;
        const form_size = std.mem.readInt(u32, form[4..8], .big);
        if (form_size < 4) return error.InvalidAiff;
        if (std.mem.eql(u8, form[8..12], "AIFC")) {
            p.aifc = true;
            p.version = aifc_version1;
        } else if (!std.mem.eql(u8, form[8..12], "AIFF")) {
            return error.InvalidAiff;
        }
        p.extent_left = form_size - 4;

        while (true) {
            // The extent ended before `SSND`: `COMM` or `SSND` is missing.
            const header = try p.nextChunk() orelse return error.InvalidAiff;
            if (std.mem.eql(u8, &header.id, "COMM")) {
                try p.readCommon(header.size);
            } else if (std.mem.eql(u8, &header.id, "SSND")) {
                return p.beginSound(header.size);
            } else if (std.mem.eql(u8, &header.id, "FVER") and header.size >= 4) {
                try p.checkExtent(header.size);
                const version = try p.readArray(4);
                p.version = std.mem.readInt(u32, &version, .big);
                p.reader.discardAll(header.size - 4) catch |err| return mapRead(err);
                p.extent_left -= header.size;
                try p.skipPad(header.size);
            } else {
                try p.skipChunk(header.size);
            }
        }
    }

    /// Decodes whole frames of interleaved samples into the start of `output`
    /// and returns the decoded prefix. Returns no samples once the data is
    /// exhausted, or when `output` cannot hold one frame. Only for encodings
    /// stored as s16; use `readData` and `pcm.decode` for the others.
    pub fn readSamples(p: *Parser, output: []i16) Error![]i16 {
        std.debug.assert(p.codec.storage() == .s16);
        const width = p.codec.bytesPerSample();
        var scratch: [scratch_len]u8 = undefined;
        var produced: usize = 0;
        while (true) {
            // At most 2 bytes per sample: an i16 slice already spans that much.
            const room_bytes = @min(scratch_len, (output.len - produced) * width);
            const bytes = try p.readData(scratch[0..room_bytes]);
            if (bytes.len == 0) break;
            // Whole frames of at most room_bytes bytes fit in the output.
            const decoded = pcm.decodeToS16(p.codec, bytes, output[produced..]) catch unreachable;
            produced += decoded.len;
        }
        return output[0..produced];
    }

    /// Reads whole frames of sound data, still encoded, into the start of
    /// `output` and returns that prefix. Returns no bytes once the data is
    /// exhausted, or when `output` cannot hold one frame.
    pub fn readData(p: *Parser, output: []u8) Error![]u8 {
        std.debug.assert(p.state == .data);
        const whole = output[0 .. output.len - output.len % p.frame_bytes];
        const want = @min(std.math.cast(usize, p.data_left) orelse std.math.maxInt(usize), whole.len);
        p.reader.readSliceAll(whole[0..want]) catch |err| return mapRead(err);
        p.data_left -= want;
        return whole[0..want];
    }

    /// Skips any unread data, then validates the chunks after `SSND` up to the
    /// end of the FORM extent. Bytes after the extent are never read.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        p.reader.discardAll64(p.data_left) catch |err| return mapRead(err);
        p.data_left = 0;
        if (p.data_padded) try p.skipPad(1);
        while (try p.nextChunk()) |header| {
            if (std.mem.eql(u8, &header.id, "COMM") or std.mem.eql(u8, &header.id, "SSND")) {
                return error.InvalidAiff;
            }
            try p.skipChunk(header.size);
        }
        p.state = .done;
    }

    fn nextChunk(p: *Parser) Error!?ChunkHeader {
        if (p.extent_left == 0) return null;
        if (p.extent_left < 8) return error.InvalidAiff;
        const bytes = try p.readArray(8);
        p.extent_left -= 8;
        if (p.chunks >= p.limits.max_chunks) return error.LimitExceeded;
        p.chunks += 1;
        return .{ .id = bytes[0..4].*, .size = std.mem.readInt(u32, bytes[4..8], .big) };
    }

    /// `COMM`, in the contract's order: its size, channels, the sample rate,
    /// then the codec from the compression type (AIFF-C version 1 with room
    /// for one) or the sample size.
    fn readCommon(p: *Parser, size: u32) Error!void {
        if (p.format != null) return error.InvalidAiff;
        if (size < 18) return error.InvalidFormat;
        try p.checkExtent(size);
        const fields = try p.readArray(18);
        const channels = std.mem.readInt(u16, fields[0..2], .big);
        const frames = std.mem.readInt(u32, fields[2..6], .big);
        const bits = std.mem.readInt(u16, fields[6..8], .big);
        if (channels == 0) return error.InvalidFormat;
        if (channels > 2) return error.UnsupportedFormat;
        // Without `CHAN` FFmpeg leaves the layout unspecified.
        const layout: audio.ChannelLayout = .{ .unspecified = channels };
        const rate = try sampleRate(fields[8..18], p.limits.max_sample_rate);
        var rest = size - 18;
        const codec = if (p.version == aifc_version1 and rest >= 4) codec: {
            const compression = try p.readArray(4);
            rest -= 4;
            break :codec codecForCompression(compression, bits) orelse return error.UnsupportedFormat;
        } else codecForBits(bits) orelse return error.UnsupportedFormat;
        p.reader.discardAll(rest) catch |err| return mapRead(err);
        p.extent_left -= size;
        try p.skipPad(size);
        const sample_bytes: u32 = codec.bytesPerSample();
        p.format = .{ .sample_rate = rate, .layout = layout, .sample_format = codec.storage() };
        p.codec = codec;
        p.frame_bytes = sample_bytes * channels;
        p.declared_frames = frames;
    }

    /// `SSND`: its 8-byte offset and block size, the data offset skipped, then
    /// whole frames, as many as `COMM` declares.
    fn beginSound(p: *Parser, size: u32) Error!Info {
        const format = p.format orelse return error.InvalidAiff;
        if (size < 8) return error.InvalidAiff;
        try p.checkExtent(size);
        const fields = try p.readArray(8);
        const offset = std.mem.readInt(u32, fields[0..4], .big);
        // fields[4..8] is the block size: informational, as in FFmpeg.
        if (offset > size - 8) return error.InvalidAiff;
        const data_bytes: u64 = size - 8 - offset;
        if (data_bytes % p.frame_bytes != 0) return error.InvalidFormat;
        const frame_count = data_bytes / p.frame_bytes;
        if (frame_count != p.declared_frames) return error.InvalidFormat;
        p.reader.discardAll(offset) catch |err| return mapRead(err);
        p.extent_left -= size;
        p.data_left = data_bytes;
        p.data_padded = size % 2 == 1;
        p.state = .data;
        return .{ .codec = p.codec, .format = format, .frame_count = frame_count, .aifc = p.aifc };
    }

    fn skipChunk(p: *Parser, size: u32) Error!void {
        try p.checkExtent(size);
        p.reader.discardAll(size) catch |err| return mapRead(err);
        p.extent_left -= size;
        try p.skipPad(size);
    }

    /// A pad byte that would lie outside the extent is not read.
    fn skipPad(p: *Parser, size: u32) Error!void {
        if (size % 2 == 1 and p.extent_left > 0) {
            p.reader.discardAll(1) catch |err| return mapRead(err);
            p.extent_left -= 1;
        }
    }

    fn checkExtent(p: *Parser, size: u64) Error!void {
        if (size > p.extent_left) return error.InvalidAiff;
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

/// Validates a complete AIFF stream without decoding its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    try parser.finish();
    return info;
}

pub const DecodeError = Error || std.Io.Writer.Error;

/// Decodes an AIFF stream and writes its samples to `out` as raw
/// little-endian samples of its storage format, using fixed working storage.
/// The caller flushes `out`.
pub fn decodeToRaw(reader: *std.Io.Reader, out: *std.Io.Writer, limits: Limits) DecodeError!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    var encoded: [scratch_len]u8 = undefined;
    // Storage is at most twice the encoded size (A-law and µ-law to s16).
    var stored: [2 * scratch_len]u8 = undefined;
    const channels = info.format.channelCount();
    while (true) {
        const bytes = try parser.readData(&encoded);
        if (bytes.len == 0) break;
        const frames: u32 = @intCast(bytes.len / parser.frame_bytes);
        const layout = samples_storage.Layout.init(info.format.sample_format, channels, frames, .{ .line = 1 }) catch unreachable;
        const buffer = samples_storage.Buffer.init(layout, &stored) catch unreachable;
        _ = pcm.decode(info.codec, bytes, buffer, 0) catch unreachable;
        pcm.storedToLittle(info.format.sample_format, buffer.bytes);
        try out.writeAll(buffer.bytes);
    }
    try parser.finish();
    return info;
}

/// The header checks `Writer.check` and `Writer.begin` share.
pub const HeaderError = error{
    /// AIFF does not carry the codec, or the format's storage is not the codec's.
    UnsupportedFormat,
    /// A zero sample rate.
    InvalidFormat,
    /// The sample rate is above `WriteOptions.max_sample_rate`.
    LimitExceeded,
    /// The FORM size or the frame count does not fit in 32 bits.
    SizeOverflow,
};

pub const WriteError = std.Io.Writer.Error || HeaderError || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
    /// More frames than declared to `begin`.
    TooManyFrames,
    /// `finish` was called before all declared frames were written.
    TooFewFrames,
};

pub const WriteOptions = struct {
    max_sample_rate: u32 = 192_000,
};

/// The bytes before the samples, as the writer emits them for `codec`: plain
/// AIFF (FORM header, 18-byte `COMM`, `SSND` header) or AIFF-C (with `FVER`
/// and a 24-byte `COMM`).
pub fn headerLen(codec: pcm.Codec) usize {
    const plain = std.mem.eql(u8, compressionFor(codec) orelse "NONE", "NONE");
    return if (plain) 12 + 26 + 16 else 12 + 12 + 32 + 16;
}

const max_header_len = 12 + 12 + 32 + 16;

/// Writes one known-length AIFF or AIFF-C stream to a borrowed writer: the
/// header with exact sizes, then the samples. No seeking and no placeholder
/// sizes.
pub const Writer = struct {
    out: *std.Io.Writer,
    codec: pcm.Codec,
    format: audio.Format,
    frames_expected: u32,
    frames_written: u32 = 0,

    /// Checks every size, then writes the header. Nothing is written when a
    /// check fails. `format.sample_format` must be `codec.storage()`.
    pub fn begin(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) WriteError!Writer {
        var header: [max_header_len]u8 = undefined;
        const bytes = try encodeHeader(codec, format, frame_count, options, &header);
        try out.writeAll(bytes);
        // encodeHeader checked that the frame count fits in u32.
        return .{ .out = out, .codec = codec, .format = format, .frames_expected = @intCast(frame_count) };
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) HeaderError!void {
        var header: [max_header_len]u8 = undefined;
        _ = try encodeHeader(codec, format, frame_count, options, &header);
    }

    fn encodeHeader(codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions, out: *[max_header_len]u8) HeaderError![]const u8 {
        const compression = compressionFor(codec) orelse return error.UnsupportedFormat;
        if (format.sample_format != codec.storage()) return error.UnsupportedFormat;
        if (format.sample_rate == 0) return error.InvalidFormat;
        if (format.sample_rate > options.max_sample_rate) return error.LimitExceeded;
        // Mono and stereo only, until this container's T23b part.
        if (format.channelCount() > 2) return error.UnsupportedFormat;
        const frames = std.math.cast(u32, frame_count) orelse return error.SizeOverflow;
        const sample_bytes: u32 = codec.bytesPerSample();
        const frame_bytes = sample_bytes * format.channelCount();
        const data_bytes = std.math.mul(u64, frames, frame_bytes) catch return error.SizeOverflow;
        const header_len = headerLen(codec);
        // The FORM size counts everything after its 8 bytes, the pad included.
        const form_size = std.math.add(u64, header_len - 8, data_bytes + data_bytes % 2) catch return error.SizeOverflow;
        if (form_size > std.math.maxInt(u32)) return error.SizeOverflow;
        const aifc = !std.mem.eql(u8, compression, "NONE");

        var w: std.Io.Writer = .fixed(out);
        // max_header_len bytes always hold these fields.
        w.writeAll("FORM") catch unreachable;
        writeBig(&w, u32, @intCast(form_size));
        w.writeAll(if (aifc) "AIFC" else "AIFF") catch unreachable;
        if (aifc) {
            w.writeAll("FVER") catch unreachable;
            writeBig(&w, u32, 4);
            writeBig(&w, u32, aifc_version1);
        }
        w.writeAll("COMM") catch unreachable;
        writeBig(&w, u32, if (aifc) 24 else 18);
        writeBig(&w, u16, format.channelCount());
        writeBig(&w, u32, frames);
        writeBig(&w, u16, bitsFor(codec));
        w.writeAll(&encodeRate(format.sample_rate)) catch unreachable;
        if (aifc) {
            w.writeAll(compression) catch unreachable;
            // An empty compression name: a zero length and its pad byte.
            writeBig(&w, u16, 0);
        }
        w.writeAll("SSND") catch unreachable;
        // The SSND size counts the offset and block size, not the pad.
        writeBig(&w, u32, @intCast(data_bytes + 8));
        writeBig(&w, u32, 0);
        writeBig(&w, u32, 0);
        std.debug.assert(w.buffered().len == header_len);
        return w.buffered();
    }

    /// Writes whole interleaved frames of samples stored as s16, encoded as
    /// the writer's codec (which must be stored as s16). Fails without writing
    /// when the frames are incomplete or exceed the declared count.
    pub fn writeFrames(w: *Writer, samples: []const i16) WriteError!void {
        std.debug.assert(w.codec.storage() == .s16);
        const channels = w.format.channelCount();
        if (samples.len % channels != 0) return error.IncompleteFrame;
        if (samples.len / channels > w.frames_expected - w.frames_written) return error.TooManyFrames;
        var bytes: [scratch_len]u8 = undefined;
        var rest = samples;
        while (rest.len > 0) {
            // scratch_len / 2 samples are whole mono and stereo frames and
            // encode into at most scratch_len bytes.
            const take = @min(rest.len, scratch_len / 2);
            try w.writeData(pcm.encodeFromS16(w.codec, rest[0..take], &bytes) catch unreachable);
            rest = rest[take..];
        }
    }

    /// Writes whole frames already encoded as the writer's codec, unchanged.
    /// Fails without writing when the frames are incomplete or exceed the
    /// declared count.
    pub fn writeData(w: *Writer, bytes: []const u8) WriteError!void {
        const sample_bytes: usize = w.codec.bytesPerSample();
        const frame_bytes = sample_bytes * w.format.channelCount();
        if (bytes.len % frame_bytes != 0) return error.IncompleteFrame;
        const frames = bytes.len / frame_bytes;
        if (frames > w.frames_expected - w.frames_written) return error.TooManyFrames;
        try w.out.writeAll(bytes);
        w.frames_written += @intCast(frames);
    }

    /// Verifies that every declared frame was written, writes the pad byte
    /// odd data needs, then flushes `out`.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.frames_written != w.frames_expected) return error.TooFewFrames;
        const sample_bytes: u64 = w.codec.bytesPerSample();
        const data_bytes = w.frames_written * sample_bytes * w.format.channelCount();
        if (data_bytes % 2 == 1) try w.out.writeAll(&.{0});
        try w.out.flush();
    }
};

fn writeBig(w: *std.Io.Writer, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    // The header buffer is sized for every field.
    w.writeAll(&bytes) catch unreachable;
}

test "80-bit rates convert as FFmpeg's, both ways" {
    for ([_]u32{ 1, 8000, 11025, 22050, 44100, 48000, 96000, 192_000 }) |rate| {
        const encoded = encodeRate(rate);
        try std.testing.expectEqual(rate, try sampleRate(&encoded, 192_000));
    }
    // 44100 Hz as every AIFF writer stores it.
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0 }, &encodeRate(44100));
    // A fractional rate rounds half up: 8000.5 is exponent 0x400B, mantissa FA04...
    var half: [10]u8 = .{ 0x40, 0x0B, 0xFA, 0x04, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(8001, try sampleRate(&half, 192_000));
    half[0] = 0x00; // an exponent far below range
    try std.testing.expectError(error.InvalidFormat, sampleRate(&half, 192_000));
    const zero: [10]u8 = @splat(0);
    try std.testing.expectError(error.InvalidFormat, sampleRate(&zero, 192_000));
    try std.testing.expectError(error.LimitExceeded, sampleRate(&encodeRate(192_001), 192_000));
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
fn expectedError(failure: fixtures.aiff.Failure) Error {
    return switch (failure) {
        .InvalidAiff => error.InvalidAiff,
        .InvalidFormat => error.InvalidFormat,
        .Truncated => error.Truncated,
        .UnsupportedFormat => error.UnsupportedFormat,
        .LimitExceeded => error.LimitExceeded,
    };
}

fn expectInfo(comptime stream: fixtures.Stream, info: Info) !void {
    try std.testing.expectEqual(codecOf(stream.codec), info.codec);
    try std.testing.expectEqual(stream.channels, info.format.channelCount());
    try stream.expectLayout(info.format.layout);
    try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
    try std.testing.expectEqual(codecOf(stream.codec).storage(), info.format.sample_format);
    try std.testing.expectEqual(stream.frameCount(), info.frame_count);
}

fn expectFixture(comptime fixture: fixtures.aiff.Fixture, reader: *std.Io.Reader) !void {
    var storage: [1024]u8 = undefined;
    const result = decodeAll(reader, .{}, &storage);
    errdefer std.debug.print("fixture {s}\n", .{fixture.name});
    switch (fixture.expected) {
        .accept => |stream| {
            const decoded = try result;
            try expectInfo(stream, decoded.info);
            var expected: [1024]u8 = undefined;
            try std.testing.expectEqualSlices(u8, stream.samples.littleEndian(&expected), decoded.raw);
        },
        .reject => |failure| try std.testing.expectError(expectedError(failure), result),
    }
}

test "every AIFF fixture gives its contract result from memory" {
    inline for (fixtures.aiff.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.aiff.bytes(fixture.name));
        try expectFixture(fixture, &reader);
    }
}

test "every AIFF fixture gives the same result from one-byte reads" {
    inline for (fixtures.aiff.all) |fixture| {
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.aiff.bytes(fixture.name) }});
        source.artificial_limit = .limited(1);
        try expectFixture(fixture, &source.interface);
    }
}

test "probing validates without decoding and agrees with decoding" {
    @setEvalBranchQuota(10_000);
    inline for (fixtures.aiff.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.aiff.bytes(fixture.name));
        const result = probe(&reader, .{});
        switch (fixture.expected) {
            .accept => |stream| try expectInfo(stream, try result),
            .reject => |failure| try std.testing.expectError(expectedError(failure), result),
        }
    }
}

test "the form type is reported" {
    var plain: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_mono_8k"));
    try std.testing.expect(!(try probe(&plain, .{})).aifc);
    var compressed: std.Io.Reader = .fixed(fixtures.aiff.bytes("aifc_sowt"));
    try std.testing.expect((try probe(&compressed, .{})).aifc);
}

test "readSamples gives s16 samples for every encoding stored as s16" {
    var checked: usize = 0;
    inline for (fixtures.aiff.all) |fixture| {
        if (fixture.expected == .accept and fixture.expected.accept.samples == .s16) {
            var reader: std.Io.Reader = .fixed(fixtures.aiff.bytes(fixture.name));
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
    // s16be, sowt, A-law and µ-law among them.
    try std.testing.expect(checked > 4);
}

test "truncated data fails after the earlier frames were delivered" {
    var reader: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_truncated_data"));
    var parser: Parser = .init(&reader, .{});
    const info = try parser.readHeader();
    try std.testing.expectEqual(4, info.frame_count);
    var storage: [2]i16 = undefined;
    try std.testing.expectEqualSlices(i16, &.{ 0, 1 }, try parser.readSamples(&storage));
    try std.testing.expectError(error.Truncated, parser.readSamples(&storage));
}

test "limits are configurable" {
    var storage: [16]u8 = undefined;
    var fast: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_rate_over_limit"));
    const decoded = try decodeAll(&fast, .{ .max_sample_rate = 192_001 }, &storage);
    try std.testing.expectEqual(192_001, decoded.info.format.sample_rate);
    var slow: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_mono_8k"));
    try std.testing.expectError(error.LimitExceeded, decodeAll(&slow, .{ .max_sample_rate = 7999 }, &storage));

    // aiff_other_chunks has five chunks: NAME, COMM, ANNO, SSND and APPL.
    var few: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_other_chunks"));
    try std.testing.expectError(error.LimitExceeded, decodeAll(&few, .{ .max_chunks = 4 }, &storage));
    var enough: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_other_chunks"));
    _ = try decodeAll(&enough, .{ .max_chunks = 5 }, &storage);
}

test "a FORM extent that ends inside a chunk header is invalid" {
    // aiff_mono_8k with 4 bytes of a fifth chunk header counted in the FORM size.
    const base = comptime fixtures.aiff.bytes("aiff_mono_8k");
    var bytes: [base.len + 4]u8 = undefined;
    @memcpy(bytes[0..base.len], base);
    @memcpy(bytes[base.len..], "APPL");
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .big);
    var reader: std.Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.InvalidAiff, probe(&reader, .{}));
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    var reader: std.Io.Reader = .fixed(input[0..len]);
    // At most 1024 encoded bytes, stored in at most twice that.
    var storage: [2048]u8 = undefined;
    // Any contract error is acceptable; the parser must not crash or overrun.
    _ = decodeAll(&reader, .{}, &storage) catch {};
}

test "fuzz: arbitrary input never crashes the AIFF parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.aiff.bytes("aiff_mono_8k"),
        fixtures.aiff.bytes("aiff_s24_stereo"),
        fixtures.aiff.bytes("aiff_other_chunks"),
        fixtures.aiff.bytes("aiff_ssnd_offset"),
        fixtures.aiff.bytes("aifc_sowt"),
        fixtures.aiff.bytes("aifc_ulaw"),
    } });
}

/// Encodes the manifest's samples as `codec`, through T20a storage.
fn encodeExpected(comptime stream: fixtures.Stream, out: []u8) ![]const u8 {
    var stored: [1024]u8 = undefined;
    const raw = stream.samples.littleEndian(&stored);
    const codec = codecOf(stream.codec);
    pcm.storedToLittle(codec.storage(), stored[0..raw.len]); // little-endian to stored, a swap either way
    const frames: u32 = @intCast(stream.frameCount());
    if (frames == 0) return out[0..0];
    const layout = try samples_storage.Layout.init(codec.storage(), stream.channels, frames, .{ .line = 1 });
    const buffer = try samples_storage.Buffer.init(layout, stored[0..raw.len]);
    return pcm.encode(codec, buffer.view(), 0, frames, out);
}

test "the writer reproduces every AIFF writer-output fixture byte for byte" {
    var count: usize = 0;
    inline for (fixtures.aiff.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            const codec = codecOf(stream.codec);
            const format = try audio.Format.initLayout(stream.sample_rate, stream.channelLayout(), codec.storage());
            var encoded: [1024]u8 = undefined;
            const data = try encodeExpected(stream, &encoded);
            var buffer: [1024]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            var writer = try Writer.begin(&out, codec, format, stream.frameCount(), .{});
            try std.testing.expectEqual(headerLen(codec), out.buffered().len);
            // One frame per call exercises repeated writes.
            const frame_bytes = codec.bytesPerSample() * stream.channels;
            var i: usize = 0;
            while (i < data.len) : (i += frame_bytes) try writer.writeData(data[i..][0..frame_bytes]);
            try writer.finish();
            std.testing.expectEqualSlices(u8, fixtures.aiff.bytes(fixture.name), out.buffered()) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
            count += 1;
        }
    }
    // Four plain AIFF encodings, six AIFF-C ones, an empty and an odd stream.
    try std.testing.expect(count >= 13);
}

test "writeFrames encodes s16 samples as the writer's codec" {
    inline for (.{ "aiff_mono_8k", "aifc_sowt", "aifc_alaw", "aifc_ulaw" }) |name| {
        const stream = comptime for (fixtures.aiff.all) |f| {
            if (std.mem.eql(u8, f.name, name)) break f.expected.accept;
        } else unreachable;
        const codec = codecOf(stream.codec);
        const format = try audio.Format.initLayout(stream.sample_rate, stream.channelLayout(), .s16);
        var buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var writer = try Writer.begin(&out, codec, format, stream.frameCount(), .{});
        try writer.writeFrames(stream.samples.s16);
        try writer.finish();
        try std.testing.expectEqualSlices(u8, fixtures.aiff.bytes(name), out.buffered());
    }
}

test "the writer rejects frame-count mismatches and incomplete frames" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var writer = try Writer.begin(&out, .s16be, stereo, 2, .{});
    try std.testing.expectError(error.IncompleteFrame, writer.writeFrames(&.{ 1, 2, 3 }));
    try std.testing.expectError(error.TooManyFrames, writer.writeFrames(&.{ 1, 2, 3, 4, 5, 6 }));
    try std.testing.expectError(error.IncompleteFrame, writer.writeData(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(headerLen(.s16be), out.buffered().len);
    try writer.writeFrames(&.{ 1, 2 });
    try std.testing.expectError(error.TooFewFrames, writer.finish());
    try writer.writeFrames(&.{ 3, 4 });
    try writer.finish();

    var reader: std.Io.Reader = .fixed(out.buffered());
    var storage: [16]u8 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0, 4, 0 }, decoded.raw);
}

test "the writer checks every size and the codec before writing the header" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16be, mono, std.math.maxInt(u64), .{}));
    // The FORM size counts the header after its first 8 bytes, the data and
    // the pad; the largest mono s16 stream fills it to 0xFFFFFFFE.
    const max_frames = (std.math.maxInt(u32) - (headerLen(.s16be) - 8)) / 2;
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16be, mono, max_frames + 1, .{}));
    const fast = try audio.Format.init(192_001, 1, .s16);
    try std.testing.expectError(error.LimitExceeded, Writer.begin(&out, .s16be, fast, 0, .{}));
    const zero_rate: audio.Format = .{ .sample_rate = 0, .layout = .mono, .sample_format = .s16 };
    try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, .s16be, zero_rate, 0, .{}));
    const planar = try audio.Format.init(8000, 1, .s16p);
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s16be, planar, 0, .{}));
    // AIFF does not carry these encodings, and the storage must match.
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s24le, mono, 0, .{}));
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s24be, mono, 0, .{}));
    try std.testing.expectEqual(0, out.buffered().len);
    try std.testing.expect(carries(.u8) and carries(.s16le) and carries(.mulaw) and !carries(.s64be) and !carries(.f32le));

    _ = try Writer.begin(&out, .s16be, mono, max_frames, .{});
    const header = out.buffered();
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, std.mem.readInt(u32, header[4..8], .big));
    try std.testing.expectEqual(max_frames, std.mem.readInt(u32, header[22..26], .big));
}

test "the writer reports write and flush failures" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var small: [10]u8 = undefined;
    var short: std.Io.Writer = .fixed(&small);
    try std.testing.expectError(error.WriteFailed, Writer.begin(&short, .s16be, mono, 1, .{}));

    // The header fits in the buffer, so the failure surfaces at the flush.
    var buffer: [128]u8 = undefined;
    var failing_flush: std.Io.Writer = .{ .vtable = &.{ .drain = std.Io.Writer.failingDrain }, .buffer = &buffer };
    var writer = try Writer.begin(&failing_flush, .s16be, mono, 1, .{});
    try writer.writeFrames(&.{7});
    try std.testing.expectError(error.WriteFailed, writer.finish());
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}
