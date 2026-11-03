// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/wavdec.c, wavenc.c, riffdec.c and riffenc.c at the pinned
// reference revision describe FFmpeg's more permissive behavior; see
// zig/testing/fixtures/README.md.
//! Bounded RIFF/WAVE reading and known-length writing for the WAV PCM
//! encodings (TODO.md T21a): u8, s16, s24, s32 and s64 PCM, 32- and 64-bit
//! float, A-law and mu-law, as plain or WAVE_FORMAT_EXTENSIBLE `fmt ` chunks.
//!
//! The parser is sequential and never seeks, so it works on pipes. It reads
//! every field exactly into local arrays, keeps only the `fmt ` fields, and
//! validates the whole declared RIFF extent, including the chunks after `data`.
//! Its accepted subset, error names and error precedence are the contract in
//! zig/testing/fixtures/README.md; every fixture there is tested below.
//!
//! The writer emits the header FFmpeg's `riffenc.c` chooses: extensible above
//! 48 kHz or above 16 bits (except float), a `fact` chunk for every encoding
//! but tag 1, and exact sizes, known up front.
//!
//! Parser errors and writer I/O errors are terminal: discard the parser or
//! writer afterward. The writer's frame-count errors (`IncompleteFrame`,
//! `TooManyFrames`, `TooFewFrames`) write nothing and leave it usable. Errors
//! found after samples were delivered still fail the stream; output is not
//! atomic. Neither the parser nor the writer allocates.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");
const pcm = @import("../codec/pcm.zig");
const Prefix = @import("prefix.zig").Prefix;

/// Contract errors (see the fixture README), plus `IoFailure` for a failing
/// reader. File adapters in zig/io/file.zig replace `IoFailure` with the cause.
pub const Error = error{
    InvalidRiff,
    InvalidWave,
    InvalidFormat,
    Truncated,
    UnsupportedFormat,
    UnsupportedStreamingSize,
    LimitExceeded,
    IoFailure,
};

/// Configurable policy limits; exceeding one is `error.LimitExceeded`.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// Counts every chunk header inside the RIFF extent, `fmt ` and `data` included.
    max_chunks: u32 = 4096,
};

pub const Info = struct {
    codec: pcm.Codec,
    /// The decoded stream: `sample_format` is `codec.storage()`.
    format: audio.Format,
    /// Sample frames in the `data` chunk.
    frame_count: u64,
};

/// Size of the header the writer emits for 16-bit PCM up to 48 kHz: RIFF
/// header, 16-byte `fmt ` chunk and `data` chunk header. `headerLen` gives it
/// for every encoding.
pub const canonical_header_len = 44;

/// Bytes decoded per read; a whole number of frames of every encoding.
const scratch_len = 4096;

const tag_pcm = 1;
const tag_float = 3;
const tag_alaw = 6;
const tag_mulaw = 7;
const tag_extensible = 0xFFFE;

/// The KSDATAFORMAT subformat GUIDs share these last 12 bytes; the first 4
/// are the format tag, little-endian.
const subformat_base = [12]u8{ 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 };

/// The writer's plain `fmt ` up to this rate, as `riffenc.c`.
const max_plain_rate = 48_000;

/// The WAV encoding for a format tag and bit depth: whole-byte depths only.
fn codecFor(tag: u32, bits: u16) ?pcm.Codec {
    return switch (tag) {
        tag_pcm => switch (bits) {
            8 => .u8,
            16 => .s16le,
            24 => .s24le,
            32 => .s32le,
            64 => .s64le,
            else => null,
        },
        tag_float => switch (bits) {
            32 => .f32le,
            64 => .f64le,
            else => null,
        },
        tag_alaw => if (bits == 8) .alaw else null,
        tag_mulaw => if (bits == 8) .mulaw else null,
        else => null,
    };
}

/// The format tag that carries `codec` in WAV, or `null` if WAV cannot.
fn tagFor(codec: pcm.Codec) ?u16 {
    return switch (codec) {
        .u8, .s16le, .s24le, .s32le, .s64le => tag_pcm,
        .f32le, .f64le => tag_float,
        .alaw => tag_alaw,
        .mulaw => tag_mulaw,
        .s8, .s16be, .s24be, .s32be, .s64be, .f32be, .f64be => null,
    };
}

/// Whether WAV carries `codec`.
pub fn carries(codec: pcm.Codec) bool {
    return tagFor(codec) != null;
}

/// The WAVE_FORMAT_EXTENSIBLE speaker mask of a layout.
fn channelMask(layout: audio.ChannelLayout) u32 {
    return switch (layout) {
        .mono => 0x4, // front center
        .stereo => 0x3, // front left | front right
    };
}

const ChunkHeader = struct {
    id: [4]u8,
    size: u32,
};

/// Reads one WAV stream from a borrowed reader.
///
/// Call `readHeader` once, then `readData` (or, for encodings stored as s16,
/// `readSamples`) until it returns nothing (or not at all), then `finish`,
/// which skips any unread data and validates the rest of the RIFF extent. The
/// stream is valid only if `finish` succeeds.
pub const Parser = struct {
    reader: *std.Io.Reader,
    limits: Limits,
    /// Bytes content detection already read; they come before the reader's.
    prefix: Prefix = .{},
    /// Bytes of the declared RIFF extent not yet consumed.
    extent_left: u32 = 0,
    chunks: u32 = 0,
    /// Set together by the `fmt ` chunk.
    format: ?audio.Format = null,
    codec: pcm.Codec = .s16le,
    /// Bytes of one encoded frame.
    frame_bytes: u32 = 0,
    /// Bytes of `data` not yet delivered.
    data_left: u32 = 0,
    /// The `data` size is odd, so a pad byte follows it.
    data_padded: bool = false,
    state: State = .header,

    const State = enum { header, data, done };

    pub fn init(reader: *std.Io.Reader, limits: Limits) Parser {
        return .{ .reader = reader, .limits = limits };
    }

    /// Like `init`, for a stream whose first bytes content detection already
    /// read (format/detect.zig). The parser reads them first.
    pub fn initPrefixed(reader: *std.Io.Reader, limits: Limits, prefix: Prefix) Parser {
        return .{ .reader = reader, .limits = limits, .prefix = prefix };
    }

    /// Reads the RIFF header and every chunk up to the start of `data`.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        const tag = try p.readArray(4);
        if (!std.mem.eql(u8, &tag, "RIFF")) {
            for ([_]*const [4]u8{ "RIFX", "RF64", "BW64", "riff" }) |unsupported| {
                if (std.mem.eql(u8, &tag, unsupported)) return error.UnsupportedFormat;
            }
            return error.InvalidRiff;
        }
        const size_bytes = try p.readArray(4);
        const riff_size = std.mem.readInt(u32, &size_bytes, .little);
        if (riff_size == 0 or riff_size == std.math.maxInt(u32)) return error.UnsupportedStreamingSize;
        if (riff_size < 4) return error.InvalidRiff;
        const form = try p.readArray(4);
        if (!std.mem.eql(u8, &form, "WAVE")) return error.InvalidWave;
        p.extent_left = riff_size - 4;

        while (true) {
            // The extent ended before `data`: `fmt ` or `data` is missing.
            const header = try p.nextChunk() orelse return error.InvalidWave;
            if (std.mem.eql(u8, &header.id, "fmt ")) {
                try p.readFormat(header.size);
            } else if (std.mem.eql(u8, &header.id, "data")) {
                return p.beginData(header.size);
            } else {
                try p.skipChunk(header.size);
            }
        }
    }

    /// Decodes whole frames of interleaved samples into the start of `output`
    /// and returns the decoded prefix. Returns no samples once the data is
    /// exhausted, or when `output` cannot hold one frame. Only for encodings
    /// stored as s16 (s16le, A-law, mu-law); use `readData` and `pcm.decode`
    /// for the others.
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

    /// Reads whole frames of `data`, still encoded, into the start of `output`
    /// and returns that prefix: the stream-copy counterpart of `readSamples`.
    /// Returns no bytes once the data is exhausted, or when `output` cannot
    /// hold one frame.
    pub fn readData(p: *Parser, output: []u8) Error![]u8 {
        std.debug.assert(p.state == .data);
        const data_left: usize = p.data_left;
        const want = @min(data_left, output.len - output.len % p.frame_bytes);
        p.reader.readSliceAll(output[0..want]) catch |err| return mapRead(err);
        p.data_left -= @intCast(want);
        return output[0..want];
    }

    /// Skips any unread data, then validates the chunks after `data` up to the
    /// end of the RIFF extent. Bytes after the extent are never read.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        p.reader.discardAll(p.data_left) catch |err| return mapRead(err);
        p.data_left = 0;
        if (p.data_padded) try p.skipPad(1);
        while (try p.nextChunk()) |header| {
            if (std.mem.eql(u8, &header.id, "fmt ") or std.mem.eql(u8, &header.id, "data")) {
                return error.InvalidWave;
            }
            try p.skipChunk(header.size);
        }
        p.state = .done;
    }

    fn nextChunk(p: *Parser) Error!?ChunkHeader {
        if (p.extent_left == 0) return null;
        if (p.extent_left < 8) return error.InvalidRiff;
        const bytes = try p.readArray(8);
        p.extent_left -= 8;
        if (p.chunks >= p.limits.max_chunks) return error.LimitExceeded;
        p.chunks += 1;
        return .{ .id = bytes[0..4].*, .size = std.mem.readInt(u32, bytes[4..8], .little) };
    }

    /// The `fmt ` checks, in the contract's order: the format tag, the
    /// extensible layout and subformat, the bit depth, channels and mask,
    /// rate, `block_align`, then the size of a plain chunk.
    fn readFormat(p: *Parser, size: u32) Error!void {
        if (p.format != null) return error.InvalidWave;
        if (size < 16) return error.InvalidFormat;
        try p.checkExtent(size);
        const fields = try p.readArray(16);
        const tag = std.mem.readInt(u16, fields[0..2], .little);
        const channels = std.mem.readInt(u16, fields[2..4], .little);
        const rate = std.mem.readInt(u32, fields[4..8], .little);
        // fields[8..12] is byte_rate: informational, never validated or used.
        const block_align = std.mem.readInt(u16, fields[12..14], .little);
        const bits = std.mem.readInt(u16, fields[14..16], .little);

        const extensible = tag == tag_extensible;
        var sub_tag: u32 = tag;
        var mask: ?u32 = null;
        var valid_bits: u16 = 0;
        if (extensible) {
            if (size != 40) return error.UnsupportedFormat;
            const extension = try p.readArray(24);
            if (std.mem.readInt(u16, extension[0..2], .little) != 22) return error.UnsupportedFormat;
            valid_bits = std.mem.readInt(u16, extension[2..4], .little);
            mask = std.mem.readInt(u32, extension[4..8], .little);
            if (!std.mem.eql(u8, extension[12..24], &subformat_base)) return error.UnsupportedFormat;
            sub_tag = std.mem.readInt(u32, extension[8..12], .little);
        }
        switch (sub_tag) {
            tag_pcm, tag_float, tag_alaw, tag_mulaw => {},
            else => return error.UnsupportedFormat,
        }
        const codec = codecFor(sub_tag, bits) orelse return error.UnsupportedFormat;
        if (valid_bits != 0 and valid_bits != bits) return error.UnsupportedFormat;
        const layout = audio.ChannelLayout.fromChannelCount(channels) catch |err| switch (err) {
            error.InvalidChannelCount => return error.InvalidFormat,
            error.UnsupportedChannelCount => return error.UnsupportedFormat,
        };
        if (mask) |m| {
            if (m != 0 and m != channelMask(layout)) return error.UnsupportedFormat;
        }
        if (rate == 0) return error.InvalidFormat;
        if (rate > p.limits.max_sample_rate) return error.LimitExceeded;
        // At most 8 bytes times 2 channels.
        const sample_bytes: u32 = codec.bytesPerSample();
        const frame_bytes = sample_bytes * channels;
        if (block_align != frame_bytes) return error.InvalidFormat;
        if (!extensible) switch (size) {
            16 => {},
            18 => {
                const extension = try p.readArray(2);
                if (std.mem.readInt(u16, &extension, .little) != 0) return error.UnsupportedFormat;
            },
            else => return error.UnsupportedFormat,
        };
        // Accepted sizes are even, so no pad byte follows.
        p.extent_left -= size;
        p.format = .{ .sample_rate = rate, .layout = layout, .sample_format = codec.storage() };
        p.codec = codec;
        p.frame_bytes = frame_bytes;
    }

    fn beginData(p: *Parser, size: u32) Error!Info {
        // Data is read straight from the reader; the prefix was consumed first.
        std.debug.assert(p.prefix.pending().len == 0);
        const format = p.format orelse return error.InvalidWave;
        if (size == std.math.maxInt(u32)) return error.UnsupportedStreamingSize;
        if (size % p.frame_bytes != 0) return error.InvalidFormat;
        try p.checkExtent(size);
        p.extent_left -= size;
        // An odd size (8-bit mono, or 24-bit with an odd frame count) is
        // followed by a pad byte, which `finish` skips like a chunk's.
        p.data_left = size;
        p.data_padded = size % 2 == 1;
        p.state = .data;
        return .{ .codec = p.codec, .format = format, .frame_count = size / p.frame_bytes };
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

    fn checkExtent(p: *Parser, size: u32) Error!void {
        if (size > p.extent_left) return error.InvalidRiff;
    }

    /// Every header and chunk field goes through here, so the first read takes
    /// any detection prefix; later reads find it empty.
    fn readArray(p: *Parser, comptime n: usize) Error![n]u8 {
        var bytes: [n]u8 = undefined;
        p.prefix.readAll(p.reader, &bytes) catch |err| return mapRead(err);
        return bytes;
    }
};

fn mapRead(err: std.Io.Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

/// Validates a complete WAV stream without decoding its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    try parser.finish();
    return info;
}

pub const DecodeError = Error || std.Io.Writer.Error;

/// Decodes a WAV stream and writes its samples to `out` as raw little-endian
/// samples of the stream's storage format (`Info.format.sample_format`; s16
/// for 16-bit PCM), using fixed working storage. The caller flushes `out`.
pub fn decodeToRaw(reader: *std.Io.Reader, out: *std.Io.Writer, limits: Limits) DecodeError!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    var encoded: [scratch_len]u8 = undefined;
    // Storage is at most twice the encoded size (A-law and mu-law to s16).
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
    /// WAV does not carry the codec, or the format's storage is not the codec's.
    UnsupportedFormat,
    /// A zero sample rate.
    InvalidFormat,
    /// The sample rate is above `Limits.max_sample_rate`.
    LimitExceeded,
    /// The `data` or RIFF size would not fit in 32 bits.
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

/// The largest header: RIFF header, a 40-byte extensible `fmt `, `fact`, and
/// the `data` chunk header.
const max_header_len = 12 + 8 + 40 + 12 + 8;

const Header = struct {
    bytes: [max_header_len]u8,
    len: usize,
};

/// The bytes before the samples, as the writer emits them for `codec` and
/// `format`.
pub fn headerLen(codec: pcm.Codec, format: audio.Format) usize {
    const tag = tagFor(codec) orelse 1;
    const fmt_len: usize = if (useExtensible(codec, format.sample_rate)) 40 else if (tag == tag_pcm) 16 else 18;
    const fact_len: usize = if (tag == tag_pcm) 0 else 12;
    return 12 + 8 + fmt_len + fact_len + 8;
}

/// `riffenc.c`'s choice for mono and stereo: extensible above 48 kHz, or
/// above 16 bits unless the samples are float.
fn useExtensible(codec: pcm.Codec, sample_rate: u32) bool {
    const sample_bytes: u32 = codec.bytesPerSample();
    const bits = sample_bytes * 8;
    return sample_rate > max_plain_rate or (bits > 16 and tagFor(codec) != tag_float);
}

/// Writes one known-length WAV stream to a borrowed writer: the header with
/// exact sizes, then the samples. No seeking and no placeholder sizes.
pub const Writer = struct {
    out: *std.Io.Writer,
    codec: pcm.Codec,
    format: audio.Format,
    frames_expected: u32,
    frames_written: u32 = 0,

    /// Checks every size, then writes the header. Nothing is written when a
    /// check fails. `format.sample_format` must be `codec.storage()`.
    pub fn begin(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, frame_count: u64, limits: Limits) WriteError!Writer {
        const header = try encodeHeader(codec, format, frame_count, limits);
        try out.writeAll(header.bytes[0..header.len]);
        // encodeHeader checked that the data size, and so the frame count, fits in u32.
        return .{ .out = out, .codec = codec, .format = format, .frames_expected = @intCast(frame_count) };
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(codec: pcm.Codec, format: audio.Format, frame_count: u64, limits: Limits) HeaderError!void {
        _ = try encodeHeader(codec, format, frame_count, limits);
    }

    fn encodeHeader(codec: pcm.Codec, format: audio.Format, frame_count: u64, limits: Limits) HeaderError!Header {
        const tag = tagFor(codec) orelse return error.UnsupportedFormat;
        if (format.sample_format != codec.storage()) return error.UnsupportedFormat;
        if (format.sample_rate == 0) return error.InvalidFormat;
        if (format.sample_rate > limits.max_sample_rate) return error.LimitExceeded;
        const sample_bytes: u16 = codec.bytesPerSample();
        const bits = sample_bytes * 8;
        // At most 8 bytes times 2 channels.
        const block_align = sample_bytes * format.channelCount();
        const header_len = headerLen(codec, format);
        const data_bytes = std.math.mul(u64, frame_count, block_align) catch return error.SizeOverflow;
        // A pad byte follows odd data, inside the RIFF extent.
        const riff_size = std.math.add(u64, data_bytes + data_bytes % 2, header_len - 8) catch return error.SizeOverflow;
        if (riff_size > std.math.maxInt(u32)) return error.SizeOverflow;
        const byte_rate = std.math.mul(u32, format.sample_rate, block_align) catch return error.SizeOverflow;
        const extensible = useExtensible(codec, format.sample_rate);

        var header: Header = .{ .bytes = undefined, .len = header_len };
        var w: std.Io.Writer = .fixed(&header.bytes);
        // max_header_len bytes always hold these fields.
        w.writeAll("RIFF") catch unreachable;
        writeLittle(&w, u32, @intCast(riff_size));
        w.writeAll("WAVE") catch unreachable;
        w.writeAll("fmt ") catch unreachable;
        writeLittle(&w, u32, if (extensible) 40 else if (tag == tag_pcm) 16 else 18);
        writeLittle(&w, u16, if (extensible) tag_extensible else tag);
        writeLittle(&w, u16, format.channelCount());
        writeLittle(&w, u32, format.sample_rate);
        writeLittle(&w, u32, byte_rate);
        writeLittle(&w, u16, block_align);
        writeLittle(&w, u16, bits);
        if (extensible) {
            writeLittle(&w, u16, 22);
            writeLittle(&w, u16, bits);
            writeLittle(&w, u32, channelMask(format.layout));
            writeLittle(&w, u32, tag);
            w.writeAll(&subformat_base) catch unreachable;
        } else if (tag != tag_pcm) {
            writeLittle(&w, u16, 0);
        }
        if (tag != tag_pcm) {
            w.writeAll("fact") catch unreachable;
            writeLittle(&w, u32, 4);
            writeLittle(&w, u32, @intCast(frame_count));
        }
        w.writeAll("data") catch unreachable;
        writeLittle(&w, u32, @intCast(data_bytes));
        std.debug.assert(w.buffered().len == header_len);
        return header;
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

    /// Writes whole frames already encoded as the writer's codec, unchanged:
    /// the stream-copy counterpart of `writeFrames`. Fails without writing
    /// when the frames are incomplete or exceed the declared count.
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
    /// that odd data needs, then flushes `out`.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.frames_written != w.frames_expected) return error.TooFewFrames;
        const frames: u64 = w.frames_written;
        const data_bytes = frames * w.codec.bytesPerSample() * w.format.channelCount();
        if (data_bytes % 2 == 1) try w.out.writeAll(&.{0});
        try w.out.flush();
    }
};

fn writeLittle(w: *std.Io.Writer, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    // The header buffer is sized for every field.
    w.writeAll(&bytes) catch unreachable;
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

fn expectStream(comptime stream: fixtures.Stream, decoded: Decoded) !void {
    try std.testing.expectEqual(codecOf(stream.codec), decoded.info.codec);
    try std.testing.expectEqual(stream.channels, decoded.info.format.channelCount());
    try std.testing.expectEqual(stream.sample_rate, decoded.info.format.sample_rate);
    try std.testing.expectEqual(codecOf(stream.codec).storage(), decoded.info.format.sample_format);
    try std.testing.expectEqual(stream.frameCount(), decoded.info.frame_count);
    var expected: [1024]u8 = undefined;
    try std.testing.expectEqualSlices(u8, stream.samples.littleEndian(&expected), decoded.raw);
}

/// The parser error each fixture failure names. The manifest's `Failure` stays
/// independent of the parser; this exhaustive switch is the only link.
fn expectedError(failure: fixtures.Failure) Error {
    return switch (failure) {
        .InvalidRiff => error.InvalidRiff,
        .InvalidWave => error.InvalidWave,
        .InvalidFormat => error.InvalidFormat,
        .Truncated => error.Truncated,
        .UnsupportedFormat => error.UnsupportedFormat,
        .UnsupportedStreamingSize => error.UnsupportedStreamingSize,
        .LimitExceeded => error.LimitExceeded,
    };
}

fn expectFixture(comptime fixture: fixtures.Fixture, reader: *std.Io.Reader) !void {
    var storage: [1024]u8 = undefined;
    const result = decodeAll(reader, .{}, &storage);
    switch (fixture.expected) {
        .accept => |stream| {
            const decoded = result catch |err| {
                std.debug.print("fixture {s}: expected acceptance, got error.{t}\n", .{ fixture.name, err });
                return err;
            };
            expectStream(stream, decoded) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        },
        .reject => |failure| std.testing.expectError(expectedError(failure), result) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        },
    }
}

test "every fixture gives its contract result from memory" {
    inline for (fixtures.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
        try expectFixture(fixture, &reader);
    }
}

test "every fixture gives the same result from one-byte reads" {
    inline for (fixtures.all) |fixture| {
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.bytes(fixture.name) }});
        source.artificial_limit = .limited(1);
        try expectFixture(fixture, &source.interface);
    }
}

test "probing validates without decoding and agrees with decoding" {
    inline for (fixtures.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
        const result = probe(&reader, .{});
        switch (fixture.expected) {
            .accept => |stream| {
                const info = try result;
                try std.testing.expectEqual(codecOf(stream.codec), info.codec);
                try std.testing.expectEqual(stream.channels, info.format.channelCount());
                try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
                try std.testing.expectEqual(stream.frameCount(), info.frame_count);
            },
            .reject => |failure| try std.testing.expectError(expectedError(failure), result),
        }
    }
}

test "readSamples gives s16 samples for every encoding stored as s16" {
    var checked: usize = 0;
    inline for (fixtures.all) |fixture| {
        if (fixture.expected == .accept and fixture.expected.accept.samples == .s16) {
            const stream = fixture.expected.accept;
            var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
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
            try std.testing.expectEqualSlices(i16, stream.samples.s16, storage[0..len]);
            checked += 1;
        }
    }
    // s16le, A-law and mu-law fixtures among them.
    try std.testing.expect(checked > 3);
}

test "an error after data is reported after the earlier frames were delivered" {
    var reader: std.Io.Reader = .fixed(fixtures.bytes("duplicate_data"));
    var parser: Parser = .init(&reader, .{});
    const info = try parser.readHeader();
    try std.testing.expectEqual(2, info.frame_count);
    var storage: [8]i16 = undefined;
    try std.testing.expectEqualSlices(i16, &.{ 0, 1 }, try parser.readSamples(&storage));
    try std.testing.expectEqual(0, (try parser.readSamples(&storage)).len);
    try std.testing.expectError(error.InvalidWave, parser.finish());
}

test "limits are configurable" {
    var at_limit: std.Io.Reader = .fixed(fixtures.bytes("chunks_at_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&at_limit, .{ .max_chunks = 4095 }));
    var fast: std.Io.Reader = .fixed(fixtures.bytes("mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&fast, .{ .max_sample_rate = 191_999 }));
    var faster: std.Io.Reader = .fixed(fixtures.bytes("fmt_rate_over_limit"));
    const info = try probe(&faster, .{ .max_sample_rate = 192_001 });
    try std.testing.expectEqual(192_001, info.format.sample_rate);
}

test "the synthesized 2 MiB skip vector is accepted" {
    const gpa = std.testing.allocator;
    const list_len = 2 * 1024 * 1024;
    const total = canonical_header_len + 8 + list_len + 8;
    const bytes = try gpa.alloc(u8, total);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const mono_8k = fixtures.bytes("mono_8k");
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], total - 8, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..36], mono_8k[12..36]); // the `fmt ` chunk of mono_8k
    @memcpy(bytes[36..40], "LIST");
    std.mem.writeInt(u32, bytes[40..44], list_len, .little);
    const data_at = 44 + list_len;
    @memcpy(bytes[data_at..][0..4], "data");
    std.mem.writeInt(u32, bytes[data_at + 4 ..][0..4], 8, .little);
    @memcpy(bytes[data_at + 8 ..][0..8], mono_8k[44..52]);

    // Same bytes as generate.py's large_skip_vector (fixture README).
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("e3edce59e7710b921c2082f76f1b97a299b1a869a8ecf594dcf7099fb7e0414b", &hex);

    var reader: std.Io.Reader = .fixed(bytes);
    var storage: [16]u8 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(u8, mono_8k[44..52], decoded.raw);
}

test "odd data is followed by a pad byte, which both directions handle" {
    // Three u8 mono frames: 3 data bytes, a pad byte, then a chunk.
    const mono = try audio.Format.init(8000, 1, .u8);
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var writer = try Writer.begin(&out, .u8, mono, 3, .{});
    try writer.writeData(&.{ 1, 2, 3 });
    try writer.finish();
    const written = out.buffered();
    try std.testing.expectEqual(headerLen(.u8, mono) + 4, written.len);
    try std.testing.expectEqual(written.len - 8, std.mem.readInt(u32, written[4..8], .little));

    var file: [128]u8 = undefined;
    @memcpy(file[0..written.len], written);
    @memcpy(file[written.len..][0..8], "JUNK\x00\x00\x00\x00");
    std.mem.writeInt(u32, file[4..8], @intCast(written.len), .little);
    var reader: std.Io.Reader = .fixed(file[0 .. written.len + 8]);
    var storage: [16]u8 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, decoded.raw);
    // A pad byte inside the extent but missing from the input is truncation.
    var short: std.Io.Reader = .fixed(file[0 .. written.len - 1]);
    try std.testing.expectError(error.Truncated, decodeAll(&short, .{}, &storage));
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

test "fuzz: arbitrary input never crashes the parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.bytes("mono_8k"),
        fixtures.bytes("stereo_44k1"),
        fixtures.bytes("unknown_chunks"),
        fixtures.bytes("odd_final_chunk_pad_missing"),
        fixtures.bytes("s24_stereo_48k_extensible"),
        fixtures.bytes("f64_stereo_96k_extensible"),
        fixtures.bytes("alaw_mono_8k"),
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
    return pcm.encode(codec, buffer, 0, frames, out);
}

test "the writer reproduces every writer-output fixture byte for byte" {
    var count: usize = 0;
    inline for (fixtures.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            const codec = codecOf(stream.codec);
            const format = try audio.Format.init(stream.sample_rate, stream.channels, codec.storage());
            var encoded: [1024]u8 = undefined;
            const data = try encodeExpected(stream, &encoded);
            var buffer: [1024]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            var writer = try Writer.begin(&out, codec, format, stream.frameCount(), .{});
            // One frame per call exercises repeated writes.
            const frame_bytes = codec.bytesPerSample() * stream.channels;
            var i: usize = 0;
            while (i < data.len) : (i += frame_bytes) try writer.writeData(data[i..][0..frame_bytes]);
            try writer.finish();
            std.testing.expectEqualSlices(u8, fixtures.bytes(fixture.name), out.buffered()) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
            try std.testing.expectEqual(headerLen(codec, format), out.buffered().len - data.len - data.len % 2);
            count += 1;
        }
    }
    // Every encoding, plain and extensible.
    try std.testing.expect(count >= 13);
}

test "writeFrames encodes s16 samples as the writer's codec" {
    inline for (.{ "mono_8k", "alaw_mono_8k", "mulaw_mono_8k" }) |name| {
        const stream = comptime for (fixtures.all) |f| {
            if (std.mem.eql(u8, f.name, name)) break f.expected.accept;
        } else unreachable;
        const codec = codecOf(stream.codec);
        const format = try audio.Format.init(stream.sample_rate, stream.channels, .s16);
        var buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var writer = try Writer.begin(&out, codec, format, stream.frameCount(), .{});
        try writer.writeFrames(stream.samples.s16);
        try writer.finish();
        try std.testing.expectEqualSlices(u8, fixtures.bytes(name), out.buffered());
    }
}

test "the writer rejects frame-count mismatches and incomplete frames" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var writer = try Writer.begin(&out, .s16le, stereo, 2, .{});
    try std.testing.expectError(error.IncompleteFrame, writer.writeFrames(&.{ 1, 2, 3 }));
    try std.testing.expectError(error.TooManyFrames, writer.writeFrames(&.{ 1, 2, 3, 4, 5, 6 }));
    try std.testing.expectError(error.IncompleteFrame, writer.writeData(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(canonical_header_len, out.buffered().len);
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
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16le, mono, std.math.maxInt(u64), .{}));
    // The largest mono stream whose RIFF size still fits in 32 bits.
    const max_frames = (std.math.maxInt(u32) - 36) / 2;
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16le, mono, max_frames + 1, .{}));
    const fast = try audio.Format.init(192_001, 1, .s16);
    try std.testing.expectError(error.LimitExceeded, Writer.begin(&out, .s16le, fast, 0, .{}));
    const zero_rate: audio.Format = .{ .sample_rate = 0, .layout = .mono, .sample_format = .s16 };
    try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, .s16le, zero_rate, 0, .{}));
    // WAV does not carry big-endian encodings, and the storage must match.
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s16be, mono, 0, .{}));
    const floats = try audio.Format.init(8000, 1, .flt);
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s16le, floats, 0, .{}));
    try std.testing.expectEqual(0, out.buffered().len);

    _ = try Writer.begin(&out, .s16le, mono, max_frames, .{});
    const header = out.buffered();
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, std.mem.readInt(u32, header[4..8], .little));
    try std.testing.expectEqual(max_frames * 2, std.mem.readInt(u32, header[40..44], .little));

    // A 24-bit stream has the extensible header and a 3-byte frame.
    const s24 = try audio.Format.init(8000, 1, .s32);
    try std.testing.expectEqual(68, headerLen(.s24le, s24));
    const max_s24 = (std.math.maxInt(u32) - (68 - 8) - 1) / 3;
    try Writer.check(.s24le, s24, max_s24, .{});
    try std.testing.expectError(error.SizeOverflow, Writer.check(.s24le, s24, max_s24 + 1, .{}));
    try std.testing.expect(carries(.f64le) and !carries(.s8) and !carries(.f32be));
}

test "the writer reports write and flush failures" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var small: [10]u8 = undefined;
    var short: std.Io.Writer = .fixed(&small);
    try std.testing.expectError(error.WriteFailed, Writer.begin(&short, .s16le, mono, 1, .{}));

    // The header fits in the buffer, so the failure surfaces at the flush.
    var buffer: [64]u8 = undefined;
    var failing_flush: std.Io.Writer = .{ .vtable = &.{ .drain = std.Io.Writer.failingDrain }, .buffer = &buffer };
    var writer = try Writer.begin(&failing_flush, .s16le, mono, 1, .{});
    try writer.writeFrames(&.{7});
    try std.testing.expectError(error.WriteFailed, writer.finish());
}
