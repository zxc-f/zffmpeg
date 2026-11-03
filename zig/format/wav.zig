// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/wavdec.c, wavenc.c, riffdec.c and riffenc.c at the pinned
// reference revision describe FFmpeg's more permissive behavior; see
// zig/testing/fixtures/README.md.
//! Bounded RIFF/WAVE reading and known-length writing for the WAV PCM
//! encodings (TODO.md T21a): u8, s16, s24, s32 and s64 PCM, 32- and 64-bit
//! float, A-law and mu-law, as plain or WAVE_FORMAT_EXTENSIBLE `fmt ` chunks.
//! The same parser and writer handle Sony Wave64 (T21b), whose GUID chunk IDs
//! and 64-bit sizes frame the same chunks (`Variant`).
//!
//! The parser is sequential and never seeks, so it works on pipes. It reads
//! every field exactly into local arrays, keeps only the `fmt ` fields, and
//! validates the whole declared RIFF extent, including the chunks after `data`.
//! RF64 and BW64 carry 64-bit sizes; the unknown sizes streaming writers leave
//! are rejected unless `Limits.unknown_length` opts in (T21b). Its accepted
//! subset, error names and error precedence are the contract in
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

/// Configurable parser policy: limits, where exceeding one is
/// `error.LimitExceeded`, and the unknown-length opt-in.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// Counts every chunk header inside the RIFF extent, `fmt ` and `data` included.
    max_chunks: u32 = 4096,
    /// Accept the unknown-size sentinels streaming writers leave (T21b),
    /// rather than rejecting them as `UnsupportedStreamingSize`. A plain RIFF
    /// size of 0 or 0xFFFFFFFF makes the extent the rest of the stream, which
    /// may then end between chunks. A `data` size of 0xFFFFFFFF outside RF64
    /// makes the data the rest of the stream, ending on a whole frame;
    /// `Info.frame_count` is then null and nothing after the data is read, so
    /// a known RIFF size goes unchecked. A `data` size of 0 is still empty.
    unknown_length: bool = false,
};

pub const Info = struct {
    codec: pcm.Codec,
    /// The decoded stream: `sample_format` is `codec.storage()`.
    format: audio.Format,
    /// Sample frames in the `data` chunk; null when its length is unknown
    /// (`Limits.unknown_length`) and the data runs to the end of the stream.
    frame_count: ?u64,
    /// RIFF (or RF64/BW64), or Wave64.
    variant: Variant,
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

/// The two chunk layouts this file reads and writes, by FFmpeg's format
/// names: RIFF (and RF64/BW64) with 4-byte IDs and 32-bit sizes, padded to 2
/// bytes, or Sony Wave64 (T21b) with GUIDs and 64-bit sizes that count the
/// 24-byte chunk header, padded to 8 bytes.
pub const Variant = enum {
    wav,
    w64,

    /// Bytes of a chunk header.
    fn chunkHeaderLen(variant: Variant) usize {
        return switch (variant) {
            .wav => 8,
            .w64 => w64_chunk_header_len,
        };
    }

    /// Pad bytes after a chunk body of `size` bytes.
    pub fn padAfter(variant: Variant, size: u64) u8 {
        return switch (variant) {
            .wav => @intCast(size % 2),
            // Chunks start 8-byte aligned and the header is 24 bytes.
            .w64 => @intCast((8 - size % 8) % 8),
        };
    }
};

/// Wave64 GUIDs: `riff` has its own; `wave`, `fmt `, `fact` and `data` are
/// the 4-character code followed by a shared suffix (`libavformat/w64.c`).
const w64_riff_suffix = [12]u8{ 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00 };
const w64_suffix = [12]u8{ 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A };
const w64_chunk_header_len = 24;
/// The `riff` GUID and size, then the `wave` GUID.
const w64_header_len = 40;

fn w64Guid(comptime code: *const [4]u8) [16]u8 {
    return code.* ++ w64_suffix;
}

const ChunkHeader = struct {
    /// The RIFF chunk ID, or for Wave64 the 4-character code of a GUID with
    /// the shared suffix (zeros for any other GUID).
    id: [4]u8,
    /// Bytes of the body, without the header or pad bytes.
    size: u64,
    /// The size field holds an unknown-size sentinel; only `data` uses this.
    unknown: bool,
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
    /// Bytes of the declared RIFF (or RF64) extent not yet consumed; null
    /// when the RIFF size is unknown and the extent is the rest of the stream.
    extent_left: ?u64 = 0,
    /// RF64/BW64: the `data` size from `ds64`, for a `data` chunk sized 0xFFFFFFFF.
    ds64_data_size: ?u64 = null,
    chunks: u32 = 0,
    /// Set together by the `fmt ` chunk.
    format: ?audio.Format = null,
    codec: pcm.Codec = .s16le,
    /// Bytes of one encoded frame.
    frame_bytes: u32 = 0,
    /// Bytes of `data` not yet delivered; null when the data runs to the end
    /// of the stream.
    data_left: ?u64 = 0,
    /// Pad bytes after `data`: 1 after odd RIFF data, up to 7 in Wave64.
    data_pad: u8 = 0,
    /// Set by the first bytes `readHeader` reads.
    variant: Variant = .wav,
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

    /// Reads the RIFF (or RF64/BW64, or Wave64) header and every chunk up to
    /// the start of `data`.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        const tag = try p.readArray(4);
        if (std.mem.eql(u8, &tag, "riff")) {
            try p.readW64Header();
        } else {
            try p.readRiffHeader(tag);
        }

        while (true) {
            // The extent ended before `data`: `fmt ` or `data` is missing.
            const header = try p.nextChunk() orelse return error.InvalidWave;
            if (std.mem.eql(u8, &header.id, "fmt ")) {
                try p.readFormat(header.size);
            } else if (std.mem.eql(u8, &header.id, "data")) {
                return p.beginData(header);
            } else {
                try p.skipChunk(header.size);
            }
        }
    }

    /// The rest of a Wave64 header after `riff`: the GUID's suffix, the
    /// 64-bit file size (which counts the whole header), and the `wave` GUID.
    fn readW64Header(p: *Parser) Error!void {
        p.variant = .w64;
        const suffix = try p.readArray(12);
        if (!std.mem.eql(u8, &suffix, &w64_riff_suffix)) return error.InvalidRiff;
        const size_bytes = try p.readArray(8);
        const riff_size = std.mem.readInt(u64, &size_bytes, .little);
        // FFmpeg's muxer leaves all ones on a pipe.
        const unknown_size = riff_size == std.math.maxInt(u64);
        if (unknown_size) {
            if (!p.limits.unknown_length) return error.UnsupportedStreamingSize;
        } else if (riff_size < w64_header_len) {
            return error.InvalidRiff;
        }
        const form = try p.readArray(16);
        if (!std.mem.eql(u8, &form, &w64Guid("wave"))) return error.InvalidWave;
        p.extent_left = if (unknown_size) null else riff_size - w64_header_len;
    }

    /// The rest of a RIFF, RF64 or BW64 header after the 4-byte `tag`.
    fn readRiffHeader(p: *Parser, tag: [4]u8) Error!void {
        const rf64 = std.mem.eql(u8, &tag, "RF64") or std.mem.eql(u8, &tag, "BW64");
        if (!rf64 and !std.mem.eql(u8, &tag, "RIFF")) {
            if (std.mem.eql(u8, &tag, "RIFX")) return error.UnsupportedFormat;
            return error.InvalidRiff;
        }
        const size_bytes = try p.readArray(4);
        const riff_size = std.mem.readInt(u32, &size_bytes, .little);
        const unknown_size = !rf64 and (riff_size == 0 or riff_size == std.math.maxInt(u32));
        if (rf64) {
            // RF64 keeps its sizes in `ds64`; the 32-bit field must say so.
            if (riff_size != std.math.maxInt(u32)) return error.InvalidRiff;
        } else if (unknown_size) {
            if (!p.limits.unknown_length) return error.UnsupportedStreamingSize;
        } else if (riff_size < 4) {
            return error.InvalidRiff;
        }
        const form = try p.readArray(4);
        if (!std.mem.eql(u8, &form, "WAVE")) return error.InvalidWave;
        if (rf64) {
            try p.readDs64();
        } else {
            p.extent_left = if (unknown_size) null else riff_size - 4;
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
        const whole = output[0 .. output.len - output.len % p.frame_bytes];
        const data_left = p.data_left orelse {
            // The data runs to the end of the stream: a short read ends it.
            const len = p.reader.readSliceShort(whole) catch |err| return mapShort(err);
            if (len % p.frame_bytes != 0) return error.Truncated;
            return whole[0..len];
        };
        const want = @min(std.math.cast(usize, data_left) orelse std.math.maxInt(usize), whole.len);
        p.reader.readSliceAll(whole[0..want]) catch |err| return mapRead(err);
        p.data_left = data_left - want;
        return whole[0..want];
    }

    /// Skips any unread data, then validates the chunks after `data` up to the
    /// end of the RIFF extent. Bytes after the extent are never read. When the
    /// data runs to the end of the stream, only the skip remains.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        const data_left = p.data_left orelse {
            try p.discardToEnd();
            p.state = .done;
            return;
        };
        p.reader.discardAll64(data_left) catch |err| return mapRead(err);
        p.data_left = 0;
        try p.skipPad(p.data_pad);
        while (try p.nextChunk()) |header| {
            if (std.mem.eql(u8, &header.id, "fmt ") or std.mem.eql(u8, &header.id, "data")) {
                return error.InvalidWave;
            }
            try p.skipChunk(header.size);
        }
        p.state = .done;
    }

    fn nextChunk(p: *Parser) Error!?ChunkHeader {
        // The prefix is consumed by now: the container tag took it.
        std.debug.assert(p.prefix.pending().len == 0);
        var buffer: [w64_chunk_header_len]u8 = undefined;
        const bytes = buffer[0..p.variant.chunkHeaderLen()];
        if (p.extent_left) |*left| {
            if (left.* == 0) return null;
            if (left.* < bytes.len) return error.InvalidRiff;
            p.reader.readSliceAll(bytes) catch |err| return mapRead(err);
            left.* -= bytes.len;
        } else {
            // The extent is the rest of the stream, which may end between chunks.
            const len = p.reader.readSliceShort(bytes) catch |err| return mapShort(err);
            if (len == 0) return null;
            if (len < bytes.len) return error.Truncated;
        }
        if (p.chunks >= p.limits.max_chunks) return error.LimitExceeded;
        p.chunks += 1;
        switch (p.variant) {
            .wav => {
                const size = std.mem.readInt(u32, bytes[4..8], .little);
                return .{ .id = bytes[0..4].*, .size = size, .unknown = size == std.math.maxInt(u32) };
            },
            .w64 => {
                const declared = std.mem.readInt(u64, bytes[16..24], .little);
                // FFmpeg's muxer leaves INT64_MAX in `data` on a pipe.
                const unknown = declared == std.math.maxInt(u64) or declared == std.math.maxInt(i64);
                if (declared < w64_chunk_header_len) return error.InvalidRiff;
                const known_guid = std.mem.eql(u8, bytes[4..16], &w64_suffix);
                return .{
                    .id = if (known_guid) bytes[0..4].* else @splat(0),
                    .size = declared - w64_chunk_header_len,
                    .unknown = unknown,
                };
            },
        }
    }

    /// The `fmt ` checks, in the contract's order: the format tag, the
    /// extensible layout and subformat, the bit depth, channels and mask,
    /// rate, `block_align`, then the size of a plain chunk.
    fn readFormat(p: *Parser, size: u64) Error!void {
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
        if (!extensible) {
            // FFmpeg's Wave64 muxer counts the 6 pad bytes after an 18-byte
            // `fmt ` in its size; they are skipped like padding.
            const ffmpeg_w64_padded = p.variant == .w64 and size == 24;
            if (size != 16 and size != 18 and !ffmpeg_w64_padded) return error.UnsupportedFormat;
            if (size > 16) {
                const extension = try p.readArray(2);
                if (std.mem.readInt(u16, &extension, .little) != 0) return error.UnsupportedFormat;
                const rest: usize = @intCast(size - 18); // 0 or 6
                p.reader.discardAll(rest) catch |err| return mapRead(err);
            }
        }
        p.consumeExtent(size);
        try p.skipPad(p.variant.padAfter(size));
        p.format = .{ .sample_rate = rate, .layout = layout, .sample_format = codec.storage() };
        p.codec = codec;
        p.frame_bytes = frame_bytes;
    }

    fn beginData(p: *Parser, header: ChunkHeader) Error!Info {
        const format = p.format orelse return error.InvalidWave;
        const size: u64 = if (!header.unknown) header.size else p.ds64_data_size orelse {
            if (!p.limits.unknown_length) return error.UnsupportedStreamingSize;
            // The data is the rest of the stream; `finish` reads nothing after it.
            p.data_left = null;
            p.state = .data;
            return .{ .codec = p.codec, .format = format, .frame_count = null, .variant = p.variant };
        };
        if (size % p.frame_bytes != 0) return error.InvalidFormat;
        try p.checkExtent(size);
        p.consumeExtent(size);
        // Odd RIFF data (8-bit mono, or 24-bit with an odd frame count) is
        // followed by a pad byte, and Wave64 data by up to 7; `finish` skips
        // them like a chunk's.
        p.data_left = size;
        p.data_pad = p.variant.padAfter(size);
        p.state = .data;
        return .{ .codec = p.codec, .format = format, .frame_count = size / p.frame_bytes, .variant = p.variant };
    }

    fn skipChunk(p: *Parser, size: u64) Error!void {
        try p.checkExtent(size);
        p.reader.discardAll64(size) catch |err| return mapRead(err);
        p.consumeExtent(size);
        try p.skipPad(p.variant.padAfter(size));
    }

    /// Pad bytes that would lie outside a known extent are not read; in an
    /// unknown one they must be present.
    fn skipPad(p: *Parser, pad: u8) Error!void {
        const len = if (p.extent_left) |left| @min(pad, left) else pad;
        if (len == 0) return;
        p.reader.discardAll(len) catch |err| return mapRead(err);
        p.consumeExtent(len);
    }

    /// Data of unknown length: skips to the end of the stream, which must end
    /// on a whole frame. Counts modulo the frame size, so no total overflows.
    fn discardToEnd(p: *Parser) Error!void {
        const step = 1 << 16;
        var partial: usize = 0;
        while (true) {
            const skipped = p.reader.discardShort(step) catch |err| return mapShort(err);
            partial = (partial + skipped) % p.frame_bytes;
            if (skipped < step) break;
        }
        if (partial != 0) return error.Truncated;
    }

    /// RF64/BW64: the `ds64` chunk that must come first, holding the 64-bit
    /// RIFF and `data` sizes. Its sample count is informational, like `fact`;
    /// a table of other chunks' 64-bit sizes is not supported.
    fn readDs64(p: *Parser) Error!void {
        const header = try p.readArray(8);
        if (!std.mem.eql(u8, header[0..4], "ds64")) return error.InvalidRiff;
        const size = std.mem.readInt(u32, header[4..8], .little);
        if (size < 28) return error.InvalidRiff;
        const fields = try p.readArray(28);
        const riff_size = std.mem.readInt(u64, fields[0..8], .little);
        const data_size = std.mem.readInt(u64, fields[8..16], .little);
        // fields[16..24] is the sample count: informational, never used.
        const table_len = std.mem.readInt(u32, fields[24..28], .little);
        // The extent after the form type must hold this chunk and its pad.
        const body: u64 = size;
        const chunk_len = 8 + body + body % 2;
        if (riff_size < 4 or riff_size - 4 < chunk_len) return error.InvalidRiff;
        if (table_len != 0) return error.UnsupportedFormat;
        p.reader.discardAll64(body - 28 + body % 2) catch |err| return mapRead(err);
        p.extent_left = riff_size - 4 - chunk_len;
        // `ds64` counts toward the chunk limit like every other header.
        p.chunks = 1;
        p.ds64_data_size = data_size;
    }

    /// An unknown extent holds anything; the stream's end bounds it instead.
    fn checkExtent(p: *Parser, size: u64) Error!void {
        const left = p.extent_left orelse return;
        if (size > left) return error.InvalidRiff;
    }

    /// After `checkExtent(size)` passed, or for a pad byte inside the extent.
    fn consumeExtent(p: *Parser, size: u64) void {
        if (p.extent_left) |*left| left.* -= size;
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

/// Short reads end at the end of the stream; the caller decides what that means.
fn mapShort(err: std.Io.Reader.ShortError) Error {
    return switch (err) {
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
    /// The sample rate is above `WriteOptions.max_sample_rate`.
    LimitExceeded,
    /// The sizes do not fit: 32 bits with `rf64 = .never`, else 64.
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

/// When the writer emits RF64 (64-bit sizes in a `ds64` chunk), as FFmpeg's
/// `-rf64` option names it.
pub const Rf64 = enum {
    /// Never: sizes past 32 bits are `SizeOverflow`.
    never,
    /// Exactly when the RIFF or `data` size would not fit in 32 bits; the
    /// writer knows the length up front, so it decides before the header.
    auto,
    /// Always, also for small streams.
    always,
};

pub const WriteOptions = struct {
    max_sample_rate: u32 = 192_000,
    /// RIFF only: Wave64 sizes are always 64 bits.
    rf64: Rf64 = .auto,
    variant: Variant = .wav,
};

/// The header layouts the writer emits.
pub const HeaderForm = enum { riff, rf64, w64 };

/// The largest header: Wave64's, with a 40-byte extensible `fmt ` and `fact`.
const max_header_len = w64_header_len + (w64_chunk_header_len + 40) + (w64_chunk_header_len + 8) + w64_chunk_header_len;

/// Bytes of the `ds64` chunk, header included.
const ds64_len = 8 + 28;

comptime {
    // RF64 header, `ds64`, extensible `fmt `, `fact` and the `data` header.
    std.debug.assert(max_header_len >= 12 + ds64_len + 8 + 40 + 12 + 8);
}

const Header = struct {
    bytes: [max_header_len]u8,
    len: usize,
};

/// The bytes before the samples, as the writer emits them for `codec` and
/// `format` in `form`.
pub fn headerLen(codec: pcm.Codec, format: audio.Format, form: HeaderForm) usize {
    const fmt_len = fmtLen(codec, format.sample_rate);
    const fact = tagFor(codec) != tag_pcm;
    return switch (form) {
        .riff, .rf64 => {
            const ds64: usize = if (form == .rf64) ds64_len else 0;
            const fact_len: usize = if (fact) 12 else 0;
            return 12 + ds64 + 8 + fmt_len + fact_len + 8;
        },
        .w64 => {
            const fact_len: usize = if (fact) w64_chunk_header_len + 8 else 0;
            return w64_header_len + w64_chunk_header_len + fmt_len + Variant.w64.padAfter(fmt_len) +
                fact_len + w64_chunk_header_len;
        },
    };
}

/// Bytes of the `fmt ` body the writer emits: 16 for tag 1, 18 for the other
/// tags, 40 for WAVE_FORMAT_EXTENSIBLE.
fn fmtLen(codec: pcm.Codec, sample_rate: u32) usize {
    if (useExtensible(codec, sample_rate)) return 40;
    return if (tagFor(codec) == tag_pcm) 16 else 18;
}

/// `riffenc.c`'s choice for mono and stereo: extensible above 48 kHz, or
/// above 16 bits unless the samples are float.
fn useExtensible(codec: pcm.Codec, sample_rate: u32) bool {
    const sample_bytes: u32 = codec.bytesPerSample();
    const bits = sample_bytes * 8;
    return sample_rate > max_plain_rate or (bits > 16 and tagFor(codec) != tag_float);
}

/// Writes one known-length WAV or Wave64 stream to a borrowed writer: the
/// header with exact sizes (RIFF, or RF64 as `WriteOptions.rf64` decides, or
/// Wave64), then the samples. No seeking and no placeholder sizes.
pub const Writer = struct {
    out: *std.Io.Writer,
    codec: pcm.Codec,
    format: audio.Format,
    variant: Variant,
    frames_expected: u64,
    frames_written: u64 = 0,

    /// Checks every size, then writes the header. Nothing is written when a
    /// check fails. `format.sample_format` must be `codec.storage()`.
    pub fn begin(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) WriteError!Writer {
        const header = try encodeHeader(codec, format, frame_count, options);
        try out.writeAll(header.bytes[0..header.len]);
        return .{ .out = out, .codec = codec, .format = format, .variant = options.variant, .frames_expected = frame_count };
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) HeaderError!void {
        _ = try encodeHeader(codec, format, frame_count, options);
    }

    fn encodeHeader(codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) HeaderError!Header {
        const tag = tagFor(codec) orelse return error.UnsupportedFormat;
        if (format.sample_format != codec.storage()) return error.UnsupportedFormat;
        if (format.sample_rate == 0) return error.InvalidFormat;
        if (format.sample_rate > options.max_sample_rate) return error.LimitExceeded;
        const sample_bytes: u16 = codec.bytesPerSample();
        const bits = sample_bytes * 8;
        // At most 8 bytes times 2 channels.
        const block_align = sample_bytes * format.channelCount();
        const byte_rate = std.math.mul(u32, format.sample_rate, block_align) catch return error.SizeOverflow;
        const data_bytes = std.math.mul(u64, frame_count, block_align) catch return error.SizeOverflow;
        // Pad bytes follow the data inside the extent.
        const padded_data = std.math.add(u64, data_bytes, options.variant.padAfter(data_bytes)) catch return error.SizeOverflow;
        const max32 = std.math.maxInt(u32);
        const form: HeaderForm = switch (options.variant) {
            .w64 => .w64,
            .wav => form: {
                const plain_riff = std.math.add(u64, padded_data, headerLen(codec, format, .riff) - 8) catch return error.SizeOverflow;
                break :form switch (options.rf64) {
                    .always => .rf64,
                    .auto => if (plain_riff > max32) .rf64 else .riff,
                    .never => if (plain_riff > max32) return error.SizeOverflow else .riff,
                };
            },
        };
        const header_len = headerLen(codec, format, form);
        const fmt_len = fmtLen(codec, format.sample_rate);

        // The `fmt ` body, shared by both layouts.
        var fmt_bytes: [40]u8 = undefined;
        var f: std.Io.Writer = .fixed(&fmt_bytes);
        const extensible = fmt_len == 40;
        writeLittle(&f, u16, if (extensible) tag_extensible else tag);
        writeLittle(&f, u16, format.channelCount());
        writeLittle(&f, u32, format.sample_rate);
        writeLittle(&f, u32, byte_rate);
        writeLittle(&f, u16, block_align);
        writeLittle(&f, u16, bits);
        if (extensible) {
            writeLittle(&f, u16, 22);
            writeLittle(&f, u16, bits);
            writeLittle(&f, u32, channelMask(format.layout));
            writeLittle(&f, u32, tag);
            f.writeAll(&subformat_base) catch unreachable;
        } else if (tag != tag_pcm) {
            writeLittle(&f, u16, 0);
        }
        std.debug.assert(f.buffered().len == fmt_len);

        var header: Header = .{ .bytes = undefined, .len = header_len };
        var w: std.Io.Writer = .fixed(&header.bytes);
        // max_header_len bytes always hold these fields.
        switch (form) {
            .riff, .rf64 => {
                const rf64 = form == .rf64;
                const riff_size = std.math.add(u64, padded_data, header_len - 8) catch return error.SizeOverflow;
                // In RF64 the 32-bit sizes say 0xFFFFFFFF: the real ones are in `ds64`.
                w.writeAll(if (rf64) "RF64" else "RIFF") catch unreachable;
                writeLittle(&w, u32, if (rf64) max32 else @intCast(riff_size));
                w.writeAll("WAVE") catch unreachable;
                if (rf64) {
                    w.writeAll("ds64") catch unreachable;
                    writeLittle(&w, u32, 28);
                    writeLittle(&w, u64, riff_size);
                    writeLittle(&w, u64, data_bytes);
                    writeLittle(&w, u64, frame_count);
                    writeLittle(&w, u32, 0); // no table of other chunks' sizes
                }
                w.writeAll("fmt ") catch unreachable;
                writeLittle(&w, u32, @intCast(fmt_len));
                w.writeAll(f.buffered()) catch unreachable;
                if (tag != tag_pcm) {
                    w.writeAll("fact") catch unreachable;
                    writeLittle(&w, u32, 4);
                    // As FFmpeg's RF64 writer: 0xFFFFFFFF when the count needs ds64.
                    writeLittle(&w, u32, std.math.cast(u32, frame_count) orelse max32);
                }
                w.writeAll("data") catch unreachable;
                writeLittle(&w, u32, if (rf64) max32 else @intCast(data_bytes));
            },
            .w64 => {
                // Sizes count the 24-byte chunk header but not the padding,
                // as the Sony specification and libsndfile write them
                // (FFmpeg's muxer also counts the padding). FFmpeg reads them
                // as signed, so the whole file stays below 2^63.
                const file_size = std.math.add(u64, padded_data, header_len) catch return error.SizeOverflow;
                if (file_size > std.math.maxInt(i64)) return error.SizeOverflow;
                w.writeAll("riff" ++ w64_riff_suffix) catch unreachable;
                writeLittle(&w, u64, file_size);
                w.writeAll(&w64Guid("wave")) catch unreachable;
                w.writeAll(&w64Guid("fmt ")) catch unreachable;
                writeLittle(&w, u64, w64_chunk_header_len + fmt_len);
                w.writeAll(f.buffered()) catch unreachable;
                w.splatByteAll(0, Variant.w64.padAfter(fmt_len)) catch unreachable;
                if (tag != tag_pcm) {
                    w.writeAll(&w64Guid("fact")) catch unreachable;
                    writeLittle(&w, u64, w64_chunk_header_len + 8);
                    writeLittle(&w, u64, frame_count);
                }
                w.writeAll(&w64Guid("data")) catch unreachable;
                writeLittle(&w, u64, w64_chunk_header_len + data_bytes);
            },
        }
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
        w.frames_written += frames;
    }

    /// Verifies that every declared frame was written, writes the pad bytes
    /// the data needs (one after odd RIFF data, up to 7 in Wave64), then
    /// flushes `out`.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.frames_written != w.frames_expected) return error.TooFewFrames;
        // begin checked that the data size fits in u64.
        const data_bytes = w.frames_written * w.codec.bytesPerSample() * w.format.channelCount();
        try w.out.splatByteAll(0, w.variant.padAfter(data_bytes));
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
    // Unknown-length data has no count; the samples below still fix the length.
    if (decoded.info.frame_count) |count| try std.testing.expectEqual(stream.frameCount(), count);
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

/// Decodes one fixture with the `unknown_length` option off or on and checks
/// the result the manifest gives for that setting.
fn expectFixture(comptime fixture: fixtures.Fixture, comptime unknown_length: bool, reader: *std.Io.Reader) !void {
    var storage: [1024]u8 = undefined;
    const result = decodeAll(reader, .{ .unknown_length = unknown_length }, &storage);
    errdefer std.debug.print("fixture {s}, unknown_length {}\n", .{ fixture.name, unknown_length });
    switch (comptime fixture.result(unknown_length)) {
        .accept => |stream| try expectStream(stream, try result),
        .reject => |failure| try std.testing.expectError(expectedError(failure), result),
    }
}

test "every fixture gives its contract result from memory" {
    inline for (fixtures.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
            try expectFixture(fixture, unknown_length, &reader);
        }
    }
}

test "every fixture gives the same result from one-byte reads" {
    inline for (fixtures.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var buffer: [1]u8 = undefined;
            var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.bytes(fixture.name) }});
            source.artificial_limit = .limited(1);
            try expectFixture(fixture, unknown_length, &source.interface);
        }
    }
}

test "probing validates without decoding and agrees with decoding" {
    inline for (fixtures.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
            const result = probe(&reader, .{ .unknown_length = unknown_length });
            switch (comptime fixture.result(unknown_length)) {
                .accept => |stream| {
                    const info = try result;
                    try std.testing.expectEqual(codecOf(stream.codec), info.codec);
                    try std.testing.expectEqual(stream.channels, info.format.channelCount());
                    try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
                    if (info.frame_count) |count| try std.testing.expectEqual(stream.frameCount(), count);
                },
                .reject => |failure| try std.testing.expectError(expectedError(failure), result),
            }
        }
    }
}

test "unknown length: a count when the data size is known, none when it is not" {
    const limits: Limits = .{ .unknown_length = true };
    var known: std.Io.Reader = .fixed(fixtures.bytes("riff_size_unknown"));
    try std.testing.expectEqual(4, (try probe(&known, limits)).frame_count);
    var empty: std.Io.Reader = .fixed(fixtures.bytes("unknown_riff_empty_data"));
    try std.testing.expectEqual(0, (try probe(&empty, limits)).frame_count);
    var unknown: std.Io.Reader = .fixed(fixtures.bytes("data_size_unknown"));
    try std.testing.expectEqual(null, (try probe(&unknown, limits)).frame_count);
}

test "unknown-length data past 4 GiB is read to the end of the stream" {
    // The header of unknown_length_pipe: RIFF and `data` sizes 0xFFFFFFFF.
    const header = fixtures.bytes("unknown_length_pipe")[0..canonical_header_len];
    try std.testing.expectEqual(std.math.maxInt(u32), std.mem.readInt(u32, header[40..44], .little));
    const limits: Limits = .{ .unknown_length = true };
    var reader_buffer: [64]u8 = undefined;
    var whole: synthetic.ZeroStream = .init(header, 5 << 30, "", &reader_buffer);
    try std.testing.expectEqual(null, (try probe(&whole.interface, limits)).frame_count);
    // One byte past a whole frame is a partial frame at the end.
    var partial: synthetic.ZeroStream = .init(header, (5 << 30) + 1, "", &reader_buffer);
    try std.testing.expectError(error.Truncated, probe(&partial.interface, limits));
    // Off by default, whatever follows.
    var off: synthetic.ZeroStream = .init(header, 5 << 30, "", &reader_buffer);
    try std.testing.expectError(error.UnsupportedStreamingSize, probe(&off.interface, .{}));
}

test "unknown-length data is delivered in whole frames up to the end" {
    var reader: std.Io.Reader = .fixed(fixtures.bytes("unknown_length_pipe"));
    var parser: Parser = .init(&reader, .{ .unknown_length = true });
    try std.testing.expectEqual(null, (try parser.readHeader()).frame_count);
    // 3 bytes hold one 2-byte frame; the 8 frames arrive one at a time.
    var output: [3]u8 = undefined;
    var frames: usize = 0;
    while ((try parser.readData(&output)).len != 0) frames += 1;
    try std.testing.expectEqual(8, frames);
    try parser.finish();
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
    try std.testing.expectEqual(headerLen(.u8, mono, .riff) + 4, written.len);
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
            const options: WriteOptions = switch (fixture.writer_header) {
                .riff => .{},
                .rf64 => .{ .rf64 = .always },
                .w64 => .{ .variant = .w64 },
            };
            const form: HeaderForm = switch (fixture.writer_header) {
                .riff => .riff,
                .rf64 => .rf64,
                .w64 => .w64,
            };
            var writer = try Writer.begin(&out, codec, format, stream.frameCount(), options);
            // One frame per call exercises repeated writes.
            const frame_bytes = codec.bytesPerSample() * stream.channels;
            var i: usize = 0;
            while (i < data.len) : (i += frame_bytes) try writer.writeData(data[i..][0..frame_bytes]);
            try writer.finish();
            std.testing.expectEqualSlices(u8, fixtures.bytes(fixture.name), out.buffered()) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
            const pad = options.variant.padAfter(data.len);
            try std.testing.expectEqual(headerLen(codec, format, form), out.buffered().len - data.len - pad);
            count += 1;
        }
    }
    // Every encoding, plain and extensible, and Wave64.
    try std.testing.expect(count >= 16);
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
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16le, mono, max_frames + 1, .{ .rf64 = .never }));
    // 64 bits overflow whatever the option.
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16le, mono, std.math.maxInt(u64) / 2, .{}));
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
    try std.testing.expectEqual(68, headerLen(.s24le, s24, .riff));
    const max_s24 = (std.math.maxInt(u32) - (68 - 8) - 1) / 3;
    try Writer.check(.s24le, s24, max_s24, .{});
    try std.testing.expectError(error.SizeOverflow, Writer.check(.s24le, s24, max_s24 + 1, .{ .rf64 = .never }));
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

const synthetic = @import("../testing/synthetic.zig");

/// The header the writer emits for `frame_count` frames, with `options`.
fn writtenHeader(codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions, out: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    _ = try Writer.begin(&w, codec, format, frame_count, options);
    return w.buffered();
}

test "RF64 past 4 GiB: the writer switches to it, and the parser reads it" {
    const mono = try audio.Format.init(8000, 1, .s16);
    const frames: u64 = (5 << 30) / 2; // 5 GiB of 16-bit samples
    var buffer: [max_header_len]u8 = undefined;
    // auto (the default) chooses RF64 because 32 bits cannot hold the sizes.
    const header = try writtenHeader(.s16le, mono, frames, .{}, &buffer);
    try std.testing.expectEqualStrings("RF64", header[0..4]);
    try std.testing.expectEqual(headerLen(.s16le, mono, .rf64), header.len);
    // ds64: the RIFF size (data plus the header after the first 8 bytes), then the data size.
    try std.testing.expectEqual((5 << 30) + header.len - 8, std.mem.readInt(u64, header[20..28], .little));
    try std.testing.expectEqual(5 << 30, std.mem.readInt(u64, header[28..36], .little));
    try std.testing.expectEqual(std.math.maxInt(u32), std.mem.readInt(u32, header[header.len - 4 ..][0..4], .little));

    // The parser reads the 5 GiB stream through the synthetic reader; probing
    // skips the zeros without producing them.
    var reader_buffer: [64]u8 = undefined;
    var stream: synthetic.ZeroStream = .init(header, 5 << 30, "", &reader_buffer);
    const info = try probe(&stream.interface, .{});
    try std.testing.expectEqual(frames, info.frame_count);
}

test "a 5 GiB RF64 stream is written with exact sizes and frame counts" {
    const mono = try audio.Format.init(8000, 1, .u8);
    const total: u64 = 5 << 30;
    var discard_buffer: [0]u8 = .{};
    var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);
    var writer = try Writer.begin(&discarding.writer, .u8, mono, total, .{});
    const block: [1 << 20]u8 = @splat(0x80);
    var written: u64 = 0;
    while (written < total) : (written += block.len) try writer.writeData(&block);
    try std.testing.expectError(error.TooManyFrames, writer.writeData(block[0..1]));
    try writer.finish();
    try std.testing.expectEqual(headerLen(.u8, mono, .rf64) + total, discarding.fullCount());
}

test "Wave64 past 4 GiB: 64-bit sizes are written and read, with the data's padding" {
    const mono = try audio.Format.init(8000, 1, .u8);
    // An odd byte count: 5 pad bytes follow the data.
    const frames: u64 = (5 << 30) + 3;
    var buffer: [max_header_len]u8 = undefined;
    const header = try writtenHeader(.u8, mono, frames, .{ .variant = .w64 }, &buffer);
    try std.testing.expectEqual(headerLen(.u8, mono, .w64), header.len);
    try std.testing.expectEqualSlices(u8, "riff", header[0..4]);
    // The file size counts the header, the data and its padding.
    try std.testing.expectEqual(header.len + frames + 5, std.mem.readInt(u64, header[16..24], .little));
    // The `data` size counts its 24-byte header but not the padding.
    try std.testing.expectEqual(24 + frames, std.mem.readInt(u64, header[header.len - 8 ..][0..8], .little));

    var reader_buffer: [64]u8 = undefined;
    var stream: synthetic.ZeroStream = .init(header, frames + 5, "", &reader_buffer);
    const info = try probe(&stream.interface, .{});
    try std.testing.expectEqual(frames, info.frame_count);
    try std.testing.expectEqual(Variant.w64, info.variant);
    // Without the padding the size still counts it: the input is short.
    var short: synthetic.ZeroStream = .init(header, frames + 4, "", &reader_buffer);
    try std.testing.expectError(error.Truncated, probe(&short.interface, .{}));
}

test "Wave64 sizes stay below 2^63, which FFmpeg reads as signed" {
    const stereo = try audio.Format.init(8000, 2, .dbl);
    const frame_bytes = 16;
    var buffer: [max_header_len]u8 = undefined;
    const largest = (std.math.maxInt(i64) - headerLen(.f64le, stereo, .w64)) / frame_bytes;
    _ = try writtenHeader(.f64le, stereo, largest, .{ .variant = .w64 }, &buffer);
    try std.testing.expectError(error.SizeOverflow, Writer.check(.f64le, stereo, largest + 1, .{ .variant = .w64 }));
    // rf64 has no effect on Wave64.
    const small = try writtenHeader(.f64le, stereo, 1, .{ .variant = .w64, .rf64 = .always }, &buffer);
    try std.testing.expectEqualSlices(u8, "riff", small[0..4]);
}

test "RF64 and plain RIFF agree below 4 GiB, and never refuses what needs 64 bits" {
    const stereo = try audio.Format.init(48000, 2, .s32);
    var rf64_buffer: [max_header_len]u8 = undefined;
    var riff_buffer: [max_header_len]u8 = undefined;
    const rf64 = try writtenHeader(.s24le, stereo, 100, .{ .rf64 = .always }, &rf64_buffer);
    const riff = try writtenHeader(.s24le, stereo, 100, .{}, &riff_buffer);
    try std.testing.expectEqualStrings("RIFF", riff[0..4]);
    // Same fmt and data chunk header after RF64's ds64.
    try std.testing.expectEqualSlices(u8, riff[12 .. riff.len - 4], rf64[12 + ds64_len .. rf64.len - 4]);
    const mono = try audio.Format.init(8000, 1, .s16);
    try std.testing.expectError(error.SizeOverflow, Writer.check(.s16le, mono, 3 << 30, .{ .rf64 = .never }));
}
