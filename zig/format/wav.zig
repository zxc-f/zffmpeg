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
//! The parser reads sequentially, so it works on pipes; with a seeker it
//! also seeks (`seekFrame`, T52a). It reads every field exactly into local
//! arrays, keeps the `fmt ` fields and, only when the caller collects tags
//! (`collectTags`, T21c), the tag chunks, within `Limits.max_retained_bytes`,
//! and validates the whole declared RIFF extent, including the chunks after
//! `data`.
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
//! atomic. The parser allocates only the tags it is asked to collect, with
//! the caller's allocator; the writer does not allocate.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");
const metadata = @import("../core/metadata.zig");
const pcm = @import("../codec/pcm.zig");
const skip = @import("../io/skip.zig");
const seek = @import("seek.zig");
const rational = @import("../core/rational.zig");

/// Contract errors (see the fixture README), plus `IoFailure` for a failing
/// reader and `OutOfMemory`, which only collecting tags can return. File
/// adapters in zig/io/file.zig replace `IoFailure` with the cause.
pub const Error = error{
    InvalidRiff,
    InvalidWave,
    InvalidFormat,
    Truncated,
    UnsupportedFormat,
    UnsupportedStreamingSize,
    LimitExceeded,
    IoFailure,
    OutOfMemory,
};

/// Configurable parser policy: limits, where exceeding one is
/// `error.LimitExceeded`, and the unknown-length opt-in.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// libswresample's `SWR_CH_MAX`: more channels than FFmpeg converts.
    max_channels: u16 = max_channels,
    /// Counts every chunk header inside the RIFF extent, `fmt ` and `data` included.
    max_chunks: u32 = 4096,
    /// Bytes of tag chunks (`LIST`/`INFO` and `bext` bodies) read into memory
    /// while collecting tags, over the whole stream. Skipped chunks never
    /// count, so without `Parser.collectTags` the limit never applies.
    max_retained_bytes: u32 = 1 << 20,
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

/// Where a parser puts the tags it reads (T21c): the `LIST`/`INFO` and `bext`
/// chunks of RIFF and RF64 streams, before or after `data`, under the keys the
/// file uses (`INAM`, `description`, ...) and in FFmpeg's demuxer order.
/// `genericTags` gives the names FFmpeg reports. Wave64 streams carry none:
/// FFmpeg reads only their `summarylist`, which is not supported.
pub const Tags = struct {
    gpa: std.mem.Allocator,
    dictionary: *metadata.Dictionary,
};

/// Bytes of a `bext` chunk before its coding history (EBU Tech 3285).
const bext_fixed_len = 602;

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
/// are the format tag, little-endian. The writer writes this family.
const subformat_base = [12]u8{ 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 };

/// Every base whose GUIDs `parse_waveformatex` (riffdec.c) reads as a format
/// tag and its 12-byte suffix: KSDATAFORMAT (`FF_MEDIASUBTYPE_BASE_GUID`),
/// the ambisonic B-format family (`FF_AMBISONIC_BASE_GUID`) and a shifted
/// KSDATAFORMAT some writers emit (`FF_BROKEN_BASE_GUID`).
const subformat_bases = [_][12]u8{
    subformat_base,
    .{ 0x21, 0x07, 0xd3, 0x11, 0x86, 0x44, 0xc8, 0xc1, 0xca, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa },
};

/// Whether `suffix` ends a subformat GUID FFmpeg maps through its format tag.
fn tagBasedSubformat(suffix: *const [12]u8) bool {
    for (&subformat_bases) |*base| {
        if (std.mem.eql(u8, suffix, base)) return true;
    }
    return false;
}

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

/// The default channel limit of the parser and the writer.
pub const max_channels = 64;

/// The layout FFmpeg reads from a `fmt ` (`ff_get_wav_header`): an
/// extensible mask naming exactly `channels` channels, else unspecified.
fn layoutFor(mask: ?u32, channels: u16) audio.ChannelLayout {
    if (mask) |m| {
        if (m != 0 and @popCount(m) == channels) return .{ .native = m };
    }
    return .{ .unspecified = channels };
}

/// The WAVE_FORMAT_EXTENSIBLE speaker mask FFmpeg writes
/// (`ff_put_wav_header`): a native layout's mask when it uses only the
/// first 18 positions, the ones WAVE defines, else 0.
fn extensibleMask(layout: audio.ChannelLayout) u32 {
    return switch (layout) {
        .native => |mask| std.math.cast(u18, mask) orelse 0,
        .unspecified, .custom => 0,
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

/// The most bytes `probeScore` reads.
pub const probe_bytes = 33;

/// FFmpeg's content probe for RIFF and RF64 WAV (`wav_probe` in wavdec.c), a
/// score from 0 to 100 for the first bytes of a stream: `WAVE` at 8 after
/// `RIFF` or `RIFX` scores 99, below the ACT demuxer; after `RF64` or `BW64`
/// with `ds64` at 12, 100. It needs more than 32 bytes.
pub fn probeScore(head: []const u8) u8 {
    if (head.len < probe_bytes or !std.mem.eql(u8, head[8..12], "WAVE")) return 0;
    const tag = head[0..4];
    if (std.mem.eql(u8, tag, "RIFF") or std.mem.eql(u8, tag, "RIFX")) return 99;
    if ((std.mem.eql(u8, tag, "RF64") or std.mem.eql(u8, tag, "BW64")) and std.mem.eql(u8, head[12..16], "ds64")) {
        return 100;
    }
    return 0;
}

/// The most bytes `w64ProbeScore` reads.
pub const w64_probe_bytes = 41;

/// FFmpeg's content probe for Sony Wave64 (`w64_probe` in wavdec.c): the
/// `riff` GUID at 0 and the `wave` GUID at 24, in more than 40 bytes, score 100.
pub fn w64ProbeScore(head: []const u8) u8 {
    if (head.len < w64_probe_bytes) return 0;
    const riff_guid = "riff" ++ w64_riff_suffix;
    if (std.mem.eql(u8, head[0..16], riff_guid) and std.mem.eql(u8, head[24..40], &w64Guid("wave"))) return 100;
    return 0;
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
    /// Set by `initVariant`: the only layout accepted.
    only: ?Variant = null,
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
    /// Set by `collectTags`.
    tags: ?Tags = null,
    /// Bytes of tag chunks read into memory so far (`Limits.max_retained_bytes`).
    retained: u64 = 0,
    state: State = .header,
    /// Set by `enableSeeking`: the source to reposition, and the absolute
    /// offsets of the data's start and end (null when it runs to the end of
    /// the stream), recorded at the start of `data`.
    seeker: ?seek.Seeker = null,
    data_offset: u64 = 0,
    data_end: ?u64 = null,
    /// A byte seek landed inside a frame: reads keep whole frames from
    /// there, and a final partial frame is dropped, as FFmpeg's decoder
    /// drops it.
    misaligned: bool = false,

    const State = enum { header, data, done };

    pub fn init(reader: *std.Io.Reader, limits: Limits) Parser {
        return .{ .reader = reader, .limits = limits };
    }

    /// Like `init`, accepting only `variant`, as FFmpeg's `wav` and `w64`
    /// demuxers each read only their own layout: a Wave64 stream read as WAV,
    /// or a RIFF one read as Wave64, is `InvalidRiff`.
    pub fn initVariant(reader: *std.Io.Reader, limits: Limits, variant: Variant) Parser {
        return .{ .reader = reader, .limits = limits, .only = variant };
    }

    /// Makes `readHeader` and `finish` add the stream's tags to
    /// `tags.dictionary` (see `Tags`), allocating with `tags.gpa`. Call it
    /// before `readHeader`. Tags after `data` arrive only with `finish`.
    /// Collecting never changes whether a stream is valid, except that the
    /// tag chunks then count toward `Limits.max_retained_bytes` and
    /// allocation can fail.
    pub fn collectTags(p: *Parser, tags: Tags) void {
        std.debug.assert(p.state == .header);
        p.tags = tags;
    }

    /// Makes `seekFrame` and `seekFile` available once the header is read:
    /// `seeker` repositions the stream this parser reads, from its start
    /// (T52a). Call it before `readHeader`.
    pub fn enableSeeking(p: *Parser, seeker: seek.Seeker) void {
        std.debug.assert(p.state == .header);
        p.seeker = seeker;
    }

    /// Reads the RIFF (or RF64/BW64, or Wave64) header and every chunk up to
    /// the start of `data`.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        const tag = try p.readArray(4);
        const variant: Variant = if (std.mem.eql(u8, &tag, "riff")) .w64 else .wav;
        // `initVariant` accepts only its own layout's start.
        if (p.only) |only| if (only != variant) return error.InvalidRiff;
        switch (variant) {
            .w64 => try p.readW64Header(),
            .wav => try p.readRiffHeader(tag),
        }

        while (true) {
            // The extent ended before `data`: `fmt ` or `data` is missing.
            const header = try p.nextChunk() orelse return error.InvalidWave;
            if (std.mem.eql(u8, &header.id, "fmt ")) {
                try p.readFormat(header.size);
            } else if (std.mem.eql(u8, &header.id, "data")) {
                return p.beginData(header);
            } else {
                try p.otherChunk(header);
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
            if (len % p.frame_bytes != 0) {
                if (!p.misaligned) return error.Truncated;
                return whole[0 .. len - len % p.frame_bytes];
            }
            return whole[0..len];
        };
        // Only a misaligned seek leaves a partial frame, which is not read.
        const frames_left = data_left - data_left % p.frame_bytes;
        const want = @min(std.math.cast(usize, frames_left) orelse std.math.maxInt(usize), whole.len);
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
        skip.discardAll(p.reader, data_left) catch |err| return mapRead(err);
        p.data_left = 0;
        try p.skipPad(p.data_pad);
        while (try p.nextChunk()) |header| {
            if (std.mem.eql(u8, &header.id, "fmt ") or std.mem.eql(u8, &header.id, "data")) {
                return error.InvalidWave;
            }
            try p.otherChunk(header);
        }
        p.state = .done;
    }

    fn nextChunk(p: *Parser) Error!?ChunkHeader {
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
            if (!tagBasedSubformat(extension[12..24])) return error.UnsupportedFormat;
            sub_tag = std.mem.readInt(u32, extension[8..12], .little);
        }
        switch (sub_tag) {
            tag_pcm, tag_float, tag_alaw, tag_mulaw => {},
            else => return error.UnsupportedFormat,
        }
        const codec = codecFor(sub_tag, bits) orelse return error.UnsupportedFormat;
        if (valid_bits != 0 and valid_bits != bits) return error.UnsupportedFormat;
        if (channels == 0) return error.InvalidFormat;
        if (channels > p.limits.max_channels) return error.LimitExceeded;
        const layout = layoutFor(mask, channels);
        if (rate == 0) return error.InvalidFormat;
        if (rate > p.limits.max_sample_rate) return error.LimitExceeded;
        // At most 8 bytes times 65535 channels: no overflow.
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
                skip.discardAll(p.reader, rest) catch |err| return mapRead(err);
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
            if (p.seeker) |seeker| p.data_offset = seeker.position();
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
        if (p.seeker) |seeker| {
            p.data_offset = seeker.position();
            p.data_end = std.math.add(u64, p.data_offset, size) catch return error.InvalidRiff;
        }
        return .{ .codec = p.codec, .format = format, .frame_count = size / p.frame_bytes, .variant = p.variant };
    }

    /// A chunk other than `fmt ` and `data`: tags when collecting them from a
    /// RIFF stream, else skipped.
    fn otherChunk(p: *Parser, header: ChunkHeader) Error!void {
        if (p.tags) |tags| if (p.variant == .wav) {
            // wavdec.c accepts both spellings of LIST.
            if (std.mem.eql(u8, &header.id, "LIST") or std.mem.eql(u8, &header.id, "list")) {
                return p.readList(tags, header.size);
            }
            if (std.mem.eql(u8, &header.id, "bext")) return p.readBext(tags, header.size);
        };
        return p.skipChunk(header.size);
    }

    /// A `LIST` chunk: an `INFO` list is read into memory and parsed; any other
    /// list type, or a chunk too short for one, is skipped.
    fn readList(p: *Parser, tags: Tags, size: u64) Error!void {
        if (size < 4) return p.skipChunk(size);
        try p.checkExtent(size);
        const list_type = try p.readArray(4);
        p.consumeExtent(4);
        if (!std.mem.eql(u8, &list_type, "INFO")) {
            skip.discardAll(p.reader, size - 4) catch |err| return mapRead(err);
            p.consumeExtent(size - 4);
            return p.skipPad(p.variant.padAfter(size));
        }
        // The buffer starts with the list type, which FFmpeg's recovery
        // from a missing pad byte can read back into (parseInfo).
        const list = try p.retain(tags, size);
        defer tags.gpa.free(list);
        list[0..4].* = list_type;
        p.reader.readSliceAll(list[4..]) catch |err| return mapRead(err);
        p.consumeExtent(size - 4);
        try p.skipPad(p.variant.padAfter(size));
        try parseInfo(tags, list);
    }

    /// A `bext` chunk. One shorter than its 602 fixed bytes is skipped without
    /// tags; FFmpeg would read the fields from the bytes after it.
    fn readBext(p: *Parser, tags: Tags, size: u64) Error!void {
        if (size < bext_fixed_len) return p.skipChunk(size);
        try p.checkExtent(size);
        const body = try p.retain(tags, size);
        defer tags.gpa.free(body);
        p.reader.readSliceAll(body) catch |err| return mapRead(err);
        p.consumeExtent(size);
        try p.skipPad(p.variant.padAfter(size));
        try parseBext(tags, body);
    }

    /// Counts `size` bytes against the retained limit and allocates them.
    fn retain(p: *Parser, tags: Tags, size: u64) Error![]u8 {
        const total = std.math.add(u64, p.retained, size) catch return error.LimitExceeded;
        if (total > p.limits.max_retained_bytes) return error.LimitExceeded;
        p.retained = total;
        // At most max_retained_bytes, a u32.
        const len: usize = @intCast(size);
        return tags.gpa.alloc(u8, len);
    }

    fn skipChunk(p: *Parser, size: u64) Error!void {
        try p.checkExtent(size);
        skip.discardAll(p.reader, size) catch |err| return mapRead(err);
        p.consumeExtent(size);
        try p.skipPad(p.variant.padAfter(size));
    }

    /// Pad bytes that would lie outside a known extent are not read; in an
    /// unknown one they must be present.
    fn skipPad(p: *Parser, pad: u8) Error!void {
        const len = if (p.extent_left) |left| @min(pad, left) else pad;
        if (len == 0) return;
        skip.discardAll(p.reader, len) catch |err| return mapRead(err);
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
        if (partial != 0 and !p.misaligned) return error.Truncated;
    }

    /// `av_seek_frame` on a WAV or Wave64 stream (`wav_read_seek`,
    /// `ff_pcm_read_seek`, `seek_frame_byte`): to a timestamp in the
    /// stream's 1/rate time base (stream 0) or in `seek.time_base_units`
    /// (stream -1), rounded to a frame up or, `backward`, down; or with
    /// `byte`, to a byte position clamped to the data's start and the
    /// source's last byte. A target past the data positions at its end.
    /// Needs `enableSeeking`; afterwards `readData` reads from there and
    /// `finish` still checks the chunks after the data.
    pub fn seekFrame(p: *Parser, stream: i32, timestamp: i64, flags: seek.Flags) seek.Error!seek.Position {
        std.debug.assert(p.state == .data);
        const seeker = p.seeker.?; // `enableSeeking` is the precondition
        if (flags.byte) {
            var pos: i64 = timestamp;
            const pos_min: i64 = @intCast(p.data_offset);
            if (pos < pos_min) {
                pos = pos_min;
            } else if (seeker.size()) |size| {
                const pos_max = std.math.cast(i64, size) orelse std.math.maxInt(i64);
                if (pos > pos_max - 1) pos = @max(pos_max - 1, pos_min);
            }
            return p.reposition(seeker, @intCast(pos), null);
        }
        if (stream != 0 and stream != -1) return error.InvalidStream;
        const format = p.format.?; // set before `data`
        const rate: i64 = format.sample_rate;
        const block_align: i64 = p.frame_bytes;
        // FFmpeg replaces a PCM header's byte rate with this one.
        const byte_rate = block_align * rate;
        var ts = timestamp;
        if (stream == -1) ts = seek.defaultStreamTimestamp(ts, .{ .num = 1, .den = @intCast(rate) });
        const offset: i64 = @intCast(p.data_offset);
        // Where ff_pcm_read_seek's arithmetic would overflow, FFmpeg falls
        // back to its packet index; the target is past any data here.
        if (@max(ts, 1) > @divTrunc(std.math.maxInt(i64), byte_rate)) return p.reposition(seeker, std.math.maxInt(u64), null);
        if (ts < 0) ts = 0;
        var pos = rational.rescaleRnd(ts * byte_rate, 1, rate * block_align, if (flags.backward) .down else .up);
        if (pos > @divTrunc(std.math.maxInt(i64) - offset, block_align)) return p.reposition(seeker, std.math.maxInt(u64), null);
        pos *= block_align;
        const cur_dts = rational.rescale(pos, rate, byte_rate);
        return p.reposition(seeker, @intCast(offset + pos), cur_dts);
    }

    /// `avformat_seek_file` on a WAV or Wave64 stream: `seekFrame` within
    /// `min_ts` and `max_ts`, as libavformat's fallback runs it.
    pub fn seekFile(p: *Parser, stream: i32, min_ts: i64, ts: i64, max_ts: i64, flags: seek.Flags) seek.Error!seek.Position {
        return seek.seekFile(p, seekFrame, stream, min_ts, ts, max_ts, flags);
    }

    /// Moves the source to `target`, at most to the data's end.
    fn reposition(p: *Parser, seeker: seek.Seeker, target: u64, timestamp: ?i64) seek.Error!seek.Position {
        var at = target;
        var at_end = false;
        if (p.data_end) |end| {
            if (target >= end) {
                at = end;
                at_end = true;
            }
            p.data_left = end - at;
        } else if (seeker.size()) |size| {
            at_end = target >= size;
        }
        try seeker.seekTo(at);
        p.misaligned = (at - p.data_offset) % p.frame_bytes != 0;
        return .{ .offset = target, .timestamp = timestamp, .at_end = at_end };
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
        skip.discardAll(p.reader, body - 28 + body % 2) catch |err| return mapRead(err);
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

    /// A header field, read exactly into a local array.
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

/// The tags of a buffered `LIST`/`INFO` chunk, as `riffdec.c`'s
/// `ff_read_riff_info` reads them. `list` starts with the `INFO` type. Each
/// subchunk is a 4-byte code (the key, up to its first NUL) and a value read
/// with its pad byte and cut at its first NUL; an all-zero code is skipped, and
/// a repeated code replaces the earlier one. Malformed content ends the list,
/// keeping the tags before it, as FFmpeg ignores the error. Unlike FFmpeg, a
/// value is never read past the end of the list.
fn parseInfo(tags: Tags, list: []const u8) error{OutOfMemory}!void {
    const end = list.len;
    var cur: usize = 4;
    while (end >= 8 and cur <= end - 8) {
        var start = cur;
        var size = std.mem.readInt(u32, list[start + 4 ..][0..4], .little);
        if (!infoFits(size, cur, end)) {
            // FFmpeg's recovery: an odd value whose pad byte is missing puts
            // the next header one byte earlier. cur is at least 4.
            start = cur - 1;
            size = std.mem.readInt(u32, list[start + 4 ..][0..4], .little);
            if (!infoFits(size, cur, end)) return;
        }
        const code = list[start..][0..4];
        // infoFits bounds size by the list length, so these fit in usize.
        const padded: usize = size + size % 2;
        const value_start = start + 8;
        cur = value_start + padded;
        if (std.mem.allEqual(u8, code, 0)) continue;
        const value = list[value_start..@min(cur, end)];
        try putTag(tags, untilNul(code), untilNul(value));
    }
}

/// FFmpeg's bound, which compares the size with the header's start rather
/// than its end.
fn infoFits(size: u32, header_start: usize, end: usize) bool {
    return size != std.math.maxInt(u32) and size <= end - header_start;
}

/// The tags of a buffered `bext` chunk of at least 602 bytes, as `wavdec.c`'s
/// `wav_parse_bext_tag` sets them: the five text fields when not empty, the
/// time reference in decimal, the UMID in hexadecimal when version 1 or later
/// has a nonzero one, and the coding history when present.
fn parseBext(tags: Tags, body: []const u8) error{OutOfMemory}!void {
    std.debug.assert(body.len >= bext_fixed_len);
    const fields = [_]struct { key: []const u8, len: usize }{
        .{ .key = "description", .len = 256 },
        .{ .key = "originator", .len = 32 },
        .{ .key = "originator_reference", .len = 32 },
        .{ .key = "origination_date", .len = 10 },
        .{ .key = "origination_time", .len = 8 },
    };
    var at: usize = 0;
    for (fields) |field| {
        const text = untilNul(body[at..][0..field.len]);
        if (text.len > 0) try putTag(tags, field.key, text);
        at += field.len;
    }
    var text_buffer: [2 + 8 * 16]u8 = undefined;
    const time_reference = std.mem.readInt(u64, body[338..346], .little);
    // 20 decimal digits fit.
    try putTag(tags, "time_reference", std.fmt.bufPrint(&text_buffer, "{d}", .{time_reference}) catch unreachable);
    const version = std.mem.readInt(u16, body[346..348], .little);
    if (version >= 1) {
        var parts: [8]u64 = undefined;
        for (&parts, 0..) |*part, i| part.* = std.mem.readInt(u64, body[348 + 8 * i ..][0..8], .big);
        if (!std.mem.allEqual(u64, &parts, 0)) {
            // SMPTE 330M: a basic UMID is 32 bytes, an extended one 64.
            const basic = std.mem.allEqual(u64, parts[4..], 0);
            var w: std.Io.Writer = .fixed(&text_buffer);
            w.writeAll("0x") catch unreachable;
            for (parts[0..if (basic) 4 else 8]) |part| w.print("{X:0>16}", .{part}) catch unreachable;
            try putTag(tags, "umid", w.buffered());
        }
    }
    if (body.len > bext_fixed_len) try putTag(tags, "coding_history", untilNul(body[bext_fixed_len..]));
}

fn untilNul(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.findScalar(u8, bytes, 0) orelse bytes.len];
}

/// `av_dict_set` without flags: a key already present is replaced.
fn putTag(tags: Tags, key: []const u8, value: []const u8) error{OutOfMemory}!void {
    tags.dictionary.put(tags.gpa, key, value, .replace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTag => unreachable, // every key and value is cut at its first NUL
    };
}

const Rename = struct { native: []const u8, generic: []const u8 };

/// `wav_metadata_conv` in wavdec.c.
const bext_names = [_]Rename{
    .{ .native = "description", .generic = "comment" },
    .{ .native = "originator", .generic = "encoded_by" },
    .{ .native = "origination_date", .generic = "date" },
    .{ .native = "origination_time", .generic = "creation_time" },
};

/// `ff_riff_info_conv` in riff.c. `track` has two codes; the writer uses the
/// first, `IPRT`, as FFmpeg's does.
const info_names = [_]Rename{
    .{ .native = "IART", .generic = "artist" },
    .{ .native = "ICMT", .generic = "comment" },
    .{ .native = "ICOP", .generic = "copyright" },
    .{ .native = "ICRD", .generic = "date" },
    .{ .native = "IGNR", .generic = "genre" },
    .{ .native = "ILNG", .generic = "language" },
    .{ .native = "INAM", .generic = "title" },
    .{ .native = "IPRD", .generic = "album" },
    .{ .native = "IPRT", .generic = "track" },
    .{ .native = "ITRK", .generic = "track" },
    .{ .native = "ISFT", .generic = "encoder" },
    .{ .native = "ISMP", .generic = "timecode" },
    .{ .native = "ITCH", .generic = "encoded_by" },
};

/// The tags `Parser.collectTags` stored, under the names FFmpeg reports, in
/// its order: `wavdec.c` renames the `bext` fields, then the INFO codes, each
/// pass keeping a duplicate key only with a different value. Other keys pass
/// unchanged.
pub fn genericTags(gpa: std.mem.Allocator, stored: *const metadata.Dictionary) std.mem.Allocator.Error!metadata.Dictionary {
    var bext_renamed = try renameTags(gpa, stored, &bext_names);
    defer bext_renamed.deinit(gpa);
    return renameTags(gpa, &bext_renamed, &info_names);
}

/// `ff_metadata_conv` from native to generic names (`metadata.c`).
fn renameTags(gpa: std.mem.Allocator, from: *const metadata.Dictionary, names: []const Rename) std.mem.Allocator.Error!metadata.Dictionary {
    var to: metadata.Dictionary = .empty;
    errdefer to.deinit(gpa);
    for (from.items()) |entry| {
        const key = for (names) |name| {
            if (std.ascii.eqlIgnoreCase(entry.key, name.native)) break name.generic;
        } else entry.key;
        to.put(gpa, key, entry.value, .keep_distinct) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTag => unreachable, // the entries of a dictionary hold no NUL
        };
    }
    return to;
}

/// The INFO codes FFmpeg's writer knows, in the order it writes them
/// (`riff_tags` in riffenc.c).
const riff_tags = [_]*const [4]u8{
    "IARL", "IART", "IAS1", "IAS2", "IAS3", "IAS4", "IAS5", "IAS6", "IAS7",
    "IAS8", "IAS9", "ICMS", "ICMT", "ICOP", "ICRD", "ICRP", "IDIM", "IDPI",
    "IENG", "IGNR", "IKEY", "ILGT", "ILNG", "IMED", "INAM", "IPLT", "IPRD",
    "IPRT", "ITRK", "ISBJ", "ISFT", "ISHP", "ISMP", "ISRC", "ISRF", "ITCH",
};

/// A tag's key as `ff_riff_write_info` sees it: a generic name becomes the
/// first INFO code with that name, and any other key stays.
fn nativeKey(key: []const u8) []const u8 {
    for (info_names) |name| {
        if (std.ascii.eqlIgnoreCase(key, name.generic)) return name.native;
    }
    return key;
}

/// The value FFmpeg's writer stores for `code`: the first tag whose renamed
/// key is exactly `code`, skipping one that the renaming drops as a duplicate
/// (an earlier tag with the same renamed key, in any case, and value). Found
/// without allocating, which the writer never does.
fn infoValue(tags: *const metadata.Dictionary, code: []const u8) ?[]const u8 {
    const entries = tags.items();
    for (entries, 0..) |entry, j| {
        if (!std.mem.eql(u8, nativeKey(entry.key), code)) continue;
        const dropped = for (entries[0..j]) |earlier| {
            if (std.ascii.eqlIgnoreCase(nativeKey(earlier.key), code) and std.mem.eql(u8, earlier.value, entry.value)) break true;
        } else false;
        if (!dropped) return entry.value;
    }
    return null;
}

/// Bytes of the `LIST`/`INFO` chunk FFmpeg's writer emits for `tags`, header
/// and pad included, or 0 when no tag has a known INFO code. A known code
/// with an empty value is not written, but still makes the list.
fn infoListLen(tags: *const metadata.Dictionary) u64 {
    var any = false;
    var body: u64 = 4; // "INFO"
    for (riff_tags) |code| {
        const value = infoValue(tags, code) orelse continue;
        any = true;
        if (value.len == 0) continue;
        const size: u64 = value.len + 1; // with its NUL
        body += 8 + size + size % 2;
    }
    return if (any) 8 + body else 0;
}

fn writeInfoList(out: *std.Io.Writer, tags: *const metadata.Dictionary, list_len: u64) std.Io.Writer.Error!void {
    std.debug.assert(list_len >= 12);
    try writeChunkHeader(out, "LIST", list_len - 8);
    try out.writeAll("INFO");
    for (riff_tags) |code| {
        const value = infoValue(tags, code) orelse continue;
        if (value.len == 0) continue;
        const size = value.len + 1;
        try writeChunkHeader(out, code, size);
        try out.writeAll(value);
        // The NUL, and a pad byte after an odd size.
        try out.splatByteAll(0, 1 + size % 2);
    }
}

fn writeChunkHeader(out: *std.Io.Writer, id: *const [4]u8, size: u64) std.Io.Writer.Error!void {
    var header: [8]u8 = undefined;
    header[0..4].* = id.*;
    // Callers checked that the chunk fits a 32-bit RIFF size.
    std.mem.writeInt(u32, header[4..8], @intCast(size), .little);
    try out.writeAll(&header);
}

/// Bytes of the `bext` body FFmpeg's writer emits with `-write_bext`: 602
/// fixed bytes, and the coding history with its NUL.
fn bextBodyLen(tags: ?*const metadata.Dictionary) u64 {
    var body: u64 = bext_fixed_len;
    if (tags) |t| if (t.get("coding_history")) |history| {
        body += history.len + 1;
    };
    return body;
}

/// `bwf_write_bext_chunk` in wavenc.c: the text fields cut to their lengths,
/// the time reference parsed as `strtoll` does, version 1, the UMID parsed in
/// 16-digit hexadecimal groups after its `0x` (at most 8), and the coding
/// history. The keys are the `bext` names, which `genericTags` renames, so
/// like FFmpeg's this writes back only what the caller names that way.
fn writeBext(out: *std.Io.Writer, tags: ?*const metadata.Dictionary, body_len: u64) std.Io.Writer.Error!void {
    try writeChunkHeader(out, "bext", body_len);
    const fields = [_]struct { key: []const u8, len: usize }{
        .{ .key = "description", .len = 256 },
        .{ .key = "originator", .len = 32 },
        .{ .key = "originator_reference", .len = 32 },
        .{ .key = "origination_date", .len = 10 },
        .{ .key = "origination_time", .len = 8 },
    };
    for (fields) |field| {
        const value = if (tags) |t| t.get(field.key) orelse "" else "";
        const text = value[0..@min(value.len, field.len)];
        try out.writeAll(text);
        try out.splatByteAll(0, field.len - text.len);
    }
    var numbers: [10]u8 = undefined;
    const time_reference: i64 = if (tags) |t| parseDecimal(t.get("time_reference") orelse "") else 0;
    const time_bits: u64 = @bitCast(time_reference);
    std.mem.writeInt(u64, numbers[0..8], time_bits, .little);
    std.mem.writeInt(u16, numbers[8..10], 1, .little);
    try out.writeAll(&numbers);
    var umid_parts: usize = 0;
    if (tags) |t| if (t.get("umid")) |umid| if (umid.len > 2) {
        const digits = umid[2..];
        umid_parts = @min(digits.len / 16, 8);
        for (0..umid_parts) |i| {
            var part: [8]u8 = undefined;
            std.mem.writeInt(u64, &part, parseHex(digits[16 * i ..][0..16]), .big);
            try out.writeAll(&part);
        }
    };
    try out.splatByteAll(0, 64 - 8 * umid_parts + 190);
    if (tags) |t| if (t.get("coding_history")) |history| {
        try out.writeAll(history);
        try out.writeByte(0);
    };
    const pad: usize = @intCast(body_len % 2);
    try out.splatByteAll(0, pad);
}

/// `strtoll` base 10: leading space, a sign, then digits up to the first
/// other byte; out of range saturates.
fn parseDecimal(text: []const u8) i64 {
    var rest = std.mem.trimStart(u8, text, " \t\n\r\x0b\x0c");
    var negative = false;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    var magnitude: u64 = 0;
    for (rest) |byte| {
        const digit = std.fmt.charToDigit(byte, 10) catch break;
        magnitude = std.math.add(u64, std.math.mul(u64, magnitude, 10) catch std.math.maxInt(u64), digit) catch std.math.maxInt(u64);
    }
    if (negative) {
        const limit: u64 = 1 << 63;
        if (magnitude >= limit) return std.math.minInt(i64);
        const positive: i64 = @intCast(magnitude);
        return -positive;
    }
    return std.math.cast(i64, magnitude) orelse std.math.maxInt(i64);
}

/// `strtoull` base 16 over one 16-character group: digits up to the first
/// other byte.
fn parseHex(group: *const [16]u8) u64 {
    var value: u64 = 0;
    for (group) |byte| {
        const digit = std.fmt.charToDigit(byte, 16) catch break;
        value = value << 4 | digit;
    }
    return value;
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
/// A frame wider than that storage (4 KiB, possible only with a channel
/// limit above the default) is `LimitExceeded`.
pub fn decodeToRaw(reader: *std.Io.Reader, out: *std.Io.Writer, limits: Limits) DecodeError!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    // readData delivers nothing when a frame does not fit, which would end
    // the loop below early; only a channel limit above the default allows it.
    if (parser.frame_bytes > scratch_len) return error.LimitExceeded;
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
    /// A zero sample rate, or no channels.
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

/// `Writer.rewriteHeader`'s failures: the header's, or moving the output.
pub const RewriteError = WriteError || error{IoFailure};

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
    max_channels: u16 = max_channels,
    /// RIFF only: Wave64 sizes are always 64 bits.
    rf64: Rf64 = .auto,
    variant: Variant = .wav,
    /// Tags to write (T21c), under FFmpeg's names as `genericTags` gives
    /// them: a `LIST`/`INFO` chunk before `data` holds every tag with an INFO
    /// code (`riff_tags`), as FFmpeg's writer chooses them. Read only by
    /// `begin`. RIFF only: Wave64 gets none, as from FFmpeg's.
    tags: ?*const metadata.Dictionary = null,
    /// Write a `bext` chunk from the `description`, `originator`, ...
    /// tags, as FFmpeg's `-write_bext`; RIFF only.
    bext: bool = false,
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

/// The fixed part of a header; the tag chunks go between `bytes[0..data_at]`
/// and the `data` chunk header after it.
const Header = struct {
    bytes: [max_header_len]u8,
    len: usize,
    data_at: usize,
    /// Body of the `bext` chunk, when one is written.
    bext_body: ?u64,
    /// The whole `LIST`/`INFO` chunk; 0 for none.
    info_len: u64,
};

/// The bytes before the samples, without tags, as the writer emits them for
/// `codec` and `format` in `form`.
pub fn headerLen(codec: pcm.Codec, format: audio.Format, form: HeaderForm) usize {
    const fmt_len = fmtLen(codec, format);
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
fn fmtLen(codec: pcm.Codec, format: audio.Format) usize {
    if (useExtensible(codec, format)) return 40;
    return if (tagFor(codec) == tag_pcm) 16 else 18;
}

/// `riffenc.c`'s choice: extensible for a native layout other than mono
/// and stereo, above 48 kHz, or above 16 bits unless the samples are float.
fn useExtensible(codec: pcm.Codec, format: audio.Format) bool {
    const sample_bytes: u32 = codec.bytesPerSample();
    const bits = sample_bytes * 8;
    const named_order = switch (format.layout) {
        .native => |mask| mask != audio.ChannelLayout.mono.native and mask != audio.ChannelLayout.stereo.native,
        .unspecified, .custom => false,
    };
    return named_order or format.sample_rate > max_plain_rate or (bits > 16 and tagFor(codec) != tag_float);
}

/// Writes one WAV or Wave64 stream to a borrowed writer: the header with
/// exact sizes (RIFF, or RF64 as `WriteOptions.rf64` decides, or Wave64),
/// then the samples. With a known length (`begin`) nothing seeks. Without one
/// (`beginDeferred`, a seekable output) the header is written for no frames
/// and `rewriteHeader` writes the real sizes over it at the end, as FFmpeg's
/// muxer rewrites a seekable output's header.
pub const Writer = struct {
    out: *std.Io.Writer,
    codec: pcm.Codec,
    format: audio.Format,
    variant: Variant,
    frames_expected: u64,
    frames_written: u64 = 0,
    /// Begun by `beginDeferred`: any number of frames, the header rewritten.
    deferred: bool = false,
    /// For `rewriteHeader`; its tags are borrowed until then.
    options: WriteOptions,

    /// Checks every size, then writes the header. Nothing is written when a
    /// check fails. `format.sample_format` must be `codec.storage()`.
    pub fn begin(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) WriteError!Writer {
        const header = try encodeHeader(codec, format, frame_count, options);
        try out.writeAll(header.bytes[0..header.data_at]);
        // wavenc.c's order: `bext`, then `LIST`, then `data`.
        if (header.bext_body) |body| try writeBext(out, options.tags, body);
        if (header.info_len > 0) {
            // A nonzero length means encodeHeader found tags.
            try writeInfoList(out, options.tags orelse unreachable, header.info_len);
        }
        try out.writeAll(header.bytes[header.data_at..header.len]);
        return .{ .out = out, .codec = codec, .format = format, .variant = options.variant, .frames_expected = frame_count, .options = options };
    }

    /// `begin` for a stream whose length is unknown until its end: the header
    /// says no frames until `rewriteHeader`. `options.tags` must stay valid
    /// until then.
    pub fn beginDeferred(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, options: WriteOptions) WriteError!Writer {
        var w = try begin(out, codec, format, 0, options);
        w.frames_expected = std.math.maxInt(u64);
        w.deferred = true;
        return w;
    }

    /// After `finish` (a no-op unless deferred): the header encoded for the
    /// frames written, over the provisional one (`seeker` moves `out`), then
    /// back to the end. Only the sizes change; a stream that needs RF64
    /// where the provisional header is RIFF cannot be rewritten in place
    /// (`SizeOverflow`).
    pub fn rewriteHeader(w: *Writer, seeker: seek.OutputSeeker) RewriteError!void {
        // A known-length header is already right.
        if (!w.deferred) return;
        const provisional = try encodeHeader(w.codec, w.format, 0, w.options);
        const header = try encodeHeader(w.codec, w.format, w.frames_written, w.options);
        if (header.len != provisional.len) return error.SizeOverflow;
        // The tag chunks between the header's two parts keep their bytes.
        const bext_len: u64 = if (header.bext_body) |body| 8 + body + body % 2 else 0;
        const end = seeker.position();
        try seeker.seekTo(0);
        try w.out.writeAll(header.bytes[0..header.data_at]);
        try seeker.seekTo(header.data_at + bext_len + header.info_len);
        try w.out.writeAll(header.bytes[header.data_at..header.len]);
        try seeker.seekTo(end);
        try w.out.flush();
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) HeaderError!void {
        _ = try encodeHeader(codec, format, frame_count, options);
    }

    fn encodeHeader(codec: pcm.Codec, format: audio.Format, frame_count: u64, options: WriteOptions) HeaderError!Header {
        const tag = tagFor(codec) orelse return error.UnsupportedFormat;
        if (format.sample_format != codec.storage()) return error.UnsupportedFormat;
        // avcodec_open2 refuses an encoder without channels; frame sizes divide by the count.
        if (format.sample_rate == 0 or format.channelCount() == 0) return error.InvalidFormat;
        if (format.sample_rate > options.max_sample_rate) return error.LimitExceeded;
        if (format.channelCount() > options.max_channels) return error.LimitExceeded;
        const sample_bytes: u16 = codec.bytesPerSample();
        const bits = sample_bytes * 8;
        // `block_align` is a 16-bit field.
        const block_align = std.math.mul(u16, sample_bytes, format.channelCount()) catch return error.UnsupportedFormat;
        const byte_rate = std.math.mul(u32, format.sample_rate, block_align) catch return error.SizeOverflow;
        const data_bytes = std.math.mul(u64, frame_count, block_align) catch return error.SizeOverflow;
        const max32 = std.math.maxInt(u32);
        // The tag chunks of a RIFF stream, each limited to a 32-bit size.
        const riff_tags_dictionary = if (options.variant == .wav) options.tags else null;
        const bext_body: ?u64 = if (options.bext and options.variant == .wav) bextBodyLen(options.tags) else null;
        const info_len: u64 = if (riff_tags_dictionary) |t| infoListLen(t) else 0;
        if ((bext_body orelse 0) > max32 or info_len > max32) return error.SizeOverflow;
        const tag_chunks = if (bext_body) |body| 8 + body + body % 2 + info_len else info_len;
        // Pad bytes follow the data inside the extent; the tag chunks precede it.
        const padded_data = std.math.add(u64, data_bytes, options.variant.padAfter(data_bytes)) catch return error.SizeOverflow;
        const after_header = std.math.add(u64, padded_data, tag_chunks) catch return error.SizeOverflow;
        const form: HeaderForm = switch (options.variant) {
            .w64 => .w64,
            .wav => form: {
                const plain_riff = std.math.add(u64, after_header, headerLen(codec, format, .riff) - 8) catch return error.SizeOverflow;
                break :form switch (options.rf64) {
                    .always => .rf64,
                    .auto => if (plain_riff > max32) .rf64 else .riff,
                    .never => if (plain_riff > max32) return error.SizeOverflow else .riff,
                };
            },
        };
        const header_len = headerLen(codec, format, form);
        const fmt_len = fmtLen(codec, format);

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
            writeLittle(&f, u32, extensibleMask(format.layout));
            writeLittle(&f, u32, tag);
            f.writeAll(&subformat_base) catch unreachable;
        } else if (tag != tag_pcm) {
            writeLittle(&f, u16, 0);
        }
        std.debug.assert(f.buffered().len == fmt_len);

        const data_header_len: usize = if (form == .w64) w64_chunk_header_len else 8;
        var header: Header = .{
            .bytes = undefined,
            .len = header_len,
            .data_at = header_len - data_header_len,
            .bext_body = bext_body,
            .info_len = info_len,
        };
        var w: std.Io.Writer = .fixed(&header.bytes);
        // max_header_len bytes always hold these fields.
        switch (form) {
            .riff, .rf64 => {
                const rf64 = form == .rf64;
                const riff_size = std.math.add(u64, after_header, header_len - 8) catch return error.SizeOverflow;
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
                const file_size = std.math.add(u64, after_header, header_len) catch return error.SizeOverflow;
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
            // The frames were checked above, so a chunk need not end on a
            // frame, which may be wider than the scratch. scratch_len / 2
            // samples encode into at most scratch_len bytes.
            const take = @min(rest.len, scratch_len / 2);
            try w.out.writeAll(pcm.encodeFromS16(w.codec, rest[0..take], &bytes) catch unreachable);
            rest = rest[take..];
        }
        w.frames_written += samples.len / channels;
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
        if (!w.deferred and w.frames_written != w.frames_expected) return error.TooFewFrames;
        // begin checked that the data size fits in u64; a deferred stream's
        // frames were written, so their bytes fit too.
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
    try stream.expectLayout(decoded.info.format.layout);
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
    @setEvalBranchQuota(10_000);
    inline for (fixtures.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
            const result = probe(&reader, .{ .unknown_length = unknown_length });
            switch (comptime fixture.result(unknown_length)) {
                .accept => |stream| {
                    const info = try result;
                    try std.testing.expectEqual(codecOf(stream.codec), info.codec);
                    try std.testing.expectEqual(stream.channels, info.format.channelCount());
                    try stream.expectLayout(info.format.layout);
                    try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
                    if (info.frame_count) |count| try std.testing.expectEqual(stream.frameCount(), count);
                },
                .reject => |failure| try std.testing.expectError(expectedError(failure), result),
            }
        }
    }
}

/// Reads a whole stream through the parser, data included.
fn readAll(parser: *Parser) Error!void {
    _ = try parser.readHeader();
    var buffer: [256]u8 = undefined;
    while ((try parser.readData(&buffer)).len != 0) {}
    try parser.finish();
}

fn expectTags(expected: []const fixtures.Tag, got: *const metadata.Dictionary) !void {
    try std.testing.expectEqual(expected.len, got.count());
    for (expected, got.items()) |want, entry| {
        try std.testing.expectEqualStrings(want.key, entry.key);
        try std.testing.expectEqualStrings(want.value, entry.value);
    }
}

/// Parses one fixture with tags collected: the result is the contract's, and
/// an accepted stream reports the manifest's tags under FFmpeg's names.
fn expectFixtureTags(comptime fixture: fixtures.Fixture, reader: *std.Io.Reader) !void {
    const gpa = std.testing.allocator;
    var stored: metadata.Dictionary = .empty;
    defer stored.deinit(gpa);
    var parser: Parser = .init(reader, .{});
    parser.collectTags(.{ .gpa = gpa, .dictionary = &stored });
    const result = readAll(&parser);
    errdefer std.debug.print("fixture {s}, tags collected\n", .{fixture.name});
    switch (fixture.expected) {
        .accept => {
            try result;
            var generic = try genericTags(gpa, &stored);
            defer generic.deinit(gpa);
            try expectTags(fixture.tags, &generic);
        },
        .reject => |failure| try std.testing.expectError(expectedError(failure), result),
    }
}

test "collecting tags keeps every fixture's result and gives the manifest's tags" {
    var tagged: usize = 0;
    inline for (fixtures.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
        try expectFixtureTags(fixture, &reader);
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.bytes(fixture.name) }});
        source.artificial_limit = .limited(1);
        try expectFixtureTags(fixture, &source.interface);
        if (fixture.tags.len > 0) tagged += 1;
    }
    try std.testing.expect(tagged >= 10);
}

test "tag chunks count toward the retained limit only when tags are collected" {
    const gpa = std.testing.allocator;
    const bytes = fixtures.bytes("bext_tags");
    // The bext body (616 bytes) and the INFO list (4 + 18 + 14 bytes).
    const retained = 616 + 36;
    for ([_]u32{ retained - 1, retained }) |limit| {
        var stored: metadata.Dictionary = .empty;
        defer stored.deinit(gpa);
        var reader: std.Io.Reader = .fixed(bytes);
        var parser: Parser = .init(&reader, .{ .max_retained_bytes = limit });
        parser.collectTags(.{ .gpa = gpa, .dictionary = &stored });
        if (limit < retained) {
            try std.testing.expectError(error.LimitExceeded, readAll(&parser));
        } else {
            try readAll(&parser);
        }
    }
    var reader: std.Io.Reader = .fixed(bytes);
    _ = try probe(&reader, .{ .max_retained_bytes = 0 });
}

fn collectUnderFailures(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var stored: metadata.Dictionary = .empty;
    defer stored.deinit(gpa);
    var reader: std.Io.Reader = .fixed(bytes);
    var parser: Parser = .init(&reader, .{});
    parser.collectTags(.{ .gpa = gpa, .dictionary = &stored });
    try readAll(&parser);
    var generic = try genericTags(gpa, &stored);
    defer generic.deinit(gpa);
}

test "an allocation failure while collecting tags is reported and leaks nothing" {
    inline for (.{ "bext_tags", "info_values", "info_duplicates" }) |name| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, collectUnderFailures, .{fixtures.bytes(name)});
    }
}

test "a bext chunk shorter than its fixed fields gives no tags" {
    const gpa = std.testing.allocator;
    // mono_8k with a 100-byte bext between `fmt ` and `data`.
    const mono_8k = comptime fixtures.bytes("mono_8k");
    var bytes: [mono_8k.len + 108]u8 = undefined;
    @memcpy(bytes[0..36], mono_8k[0..36]);
    @memcpy(bytes[36..40], "bext");
    std.mem.writeInt(u32, bytes[40..44], 100, .little);
    @memset(bytes[44..144], 'x');
    @memcpy(bytes[144..], mono_8k[36..]);
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .little);
    var stored: metadata.Dictionary = .empty;
    defer stored.deinit(gpa);
    var reader: std.Io.Reader = .fixed(&bytes);
    var parser: Parser = .init(&reader, .{});
    parser.collectTags(.{ .gpa = gpa, .dictionary = &stored });
    try readAll(&parser);
    try std.testing.expectEqual(0, stored.count());
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

/// Fuzz input: the stream, then the parser options. An option the input
/// does not supply reads as 0 (`std.testing.Smith`), which is the default.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    var limits: Limits = .{ .unknown_length = smith.value(bool) };
    const collect_tags = smith.value(bool);
    if (smith.value(bool)) {
        // Tight limits reach every LimitExceeded path; the retained bound
        // keeps tag allocations small.
        limits.max_sample_rate = smith.value(u32);
        limits.max_channels = smith.value(u16);
        limits.max_chunks = smith.valueRangeAtMost(u32, 0, 64);
        limits.max_retained_bytes = smith.valueRangeAtMost(u32, 0, 4096);
    }
    var reader: std.Io.Reader = .fixed(input[0..len]);
    // Any contract error is acceptable; the parser must not crash or overrun.
    if (collect_tags) {
        const gpa = std.testing.allocator;
        var stored: metadata.Dictionary = .empty;
        defer stored.deinit(gpa);
        var parser: Parser = .init(&reader, limits);
        parser.collectTags(.{ .gpa = gpa, .dictionary = &stored });
        readAll(&parser) catch {};
    } else {
        // At most 1024 encoded bytes, stored in at most twice that.
        var storage: [2048]u8 = undefined;
        _ = decodeAll(&reader, limits, &storage) catch {};
    }
}

/// A `fuzzOne` corpus entry: `stream` behind the length `Smith.slice`
/// reads, then the unknown-length and tag options as the 8-byte values
/// `Smith.value` reads.
fn fuzzSeed(comptime stream: []const u8, comptime unknown_length: bool, comptime collect_tags: bool) []const u8 {
    const seed = comptime seed: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, stream.len, .little);
        var options: [16]u8 = @splat(0);
        options[0] = if (unknown_length) 1 else 0;
        options[8] = if (collect_tags) 1 else 0;
        break :seed len ++ stream[0..stream.len].* ++ options;
    };
    return &seed;
}

fn le64Bytes(comptime value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}

/// Wave64 with the unknown RIFF size, then a chunk declaring 2^64 - 2 bytes:
/// with `unknown_length` no extent bounds the skip.
const w64_unknown_huge_chunk = "riff".* ++ w64_riff_suffix ++ le64Bytes(std.math.maxInt(u64)) ++
    w64Guid("wave") ++ w64Guid("fmt ") ++ le64Bytes(w64_chunk_header_len + 16) ++
    [16]u8{ 1, 0, 1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0 } ++
    w64Guid("junk") ++ le64Bytes(std.math.maxInt(u64) - 1) ++ @as([32]u8, @splat(0));

test "fuzz: arbitrary input never crashes the parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fuzzSeed(fixtures.bytes("mono_8k"), false, false),
        fuzzSeed(fixtures.bytes("stereo_44k1"), false, false),
        fuzzSeed(fixtures.bytes("unknown_chunks"), false, true),
        fuzzSeed(fixtures.bytes("odd_final_chunk_pad_missing"), false, false),
        fuzzSeed(fixtures.bytes("s24_stereo_48k_extensible"), true, false),
        fuzzSeed(fixtures.bytes("f64_stereo_96k_extensible"), false, false),
        fuzzSeed(fixtures.bytes("alaw_mono_8k"), false, false),
        fuzzSeed(&w64_unknown_huge_chunk, true, false),
        fuzzSeed(&w64_unknown_huge_chunk, true, true),
    } });
}

test "a chunk of nearly 2^64 bytes in an unknown Wave64 extent is truncation" {
    // Reader.discardAll64 overflowed its buffer position on this skip.
    var reader: std.Io.Reader = .fixed(&w64_unknown_huge_chunk);
    try std.testing.expectError(error.Truncated, probe(&reader, .{ .unknown_length = true }));
    var buffer: [7]u8 = undefined;
    var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = &w64_unknown_huge_chunk }});
    source.artificial_limit = .limited(5);
    try std.testing.expectError(error.Truncated, probe(&source.interface, .{ .unknown_length = true }));
    // Without the opt-in the unknown size is refused before any skip.
    var refused: std.Io.Reader = .fixed(&w64_unknown_huge_chunk);
    try std.testing.expectError(error.UnsupportedStreamingSize, probe(&refused, .{}));
}

/// Mono 16-bit extensible WAV, mask FC, subformat `tag` then `suffix`, with
/// the samples 0, 1, -1, 32767.
fn extensibleWav(comptime tag: u32, comptime suffix: [12]u8) [76]u8 {
    var tag_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &tag_bytes, tag, .little);
    return "RIFF".* ++ [4]u8{ 68, 0, 0, 0 } ++ "WAVEfmt ".* ++ [4]u8{ 40, 0, 0, 0 } ++
        [16]u8{ 0xfe, 0xff, 1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0 } ++
        [8]u8{ 22, 0, 16, 0, 4, 0, 0, 0 } ++ tag_bytes ++ suffix ++
        "data".* ++ [4]u8{ 8, 0, 0, 0 } ++ [8]u8{ 0, 0, 1, 0, 0xff, 0xff, 0xff, 0x7f };
}

test "extensible subformats of every base parse_waveformatex maps by tag" {
    inline for (subformat_bases) |suffix| {
        const file = extensibleWav(tag_pcm, suffix);
        var reader: std.Io.Reader = .fixed(&file);
        var storage: [16]u8 = undefined;
        const decoded = try decodeAll(&reader, .{}, &storage);
        // ffprobe: pcm_s16le, mono (the FC mask), 8000 Hz, 4 samples.
        try std.testing.expectEqual(.s16le, decoded.info.codec);
        try std.testing.expectEqual(audio.ChannelLayout.mono, decoded.info.format.layout);
        try std.testing.expectEqual(4, decoded.info.frame_count);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0xff, 0xff, 0xff, 0x7f }, decoded.raw);
        // The tag still selects the codec: ADPCM is refused in any family.
        const adpcm = extensibleWav(2, suffix);
        var refused: std.Io.Reader = .fixed(&adpcm);
        try std.testing.expectError(error.UnsupportedFormat, decodeAll(&refused, .{}, &storage));
    }
    // A GUID outside the three families (one suffix byte changed).
    const other_suffix = comptime suffix: {
        var changed = subformat_base;
        changed[11] ^= 1;
        break :suffix changed;
    };
    const other = extensibleWav(tag_pcm, other_suffix);
    var reader: std.Io.Reader = .fixed(&other);
    var storage: [16]u8 = undefined;
    try std.testing.expectError(error.UnsupportedFormat, decodeAll(&reader, .{}, &storage));
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

test "the writer reproduces every writer-output fixture byte for byte" {
    var count: usize = 0;
    inline for (fixtures.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            const codec = codecOf(stream.codec);
            const format = try audio.Format.initLayout(stream.sample_rate, stream.channelLayout(), codec.storage());
            var encoded: [1024]u8 = undefined;
            const data = try encodeExpected(stream, &encoded);
            var buffer: [1024]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            const gpa = std.testing.allocator;
            var tags: metadata.Dictionary = .empty;
            defer tags.deinit(gpa);
            for (fixture.writer_tags orelse fixture.tags) |tag| try tags.put(gpa, tag.key, tag.value, .keep);
            var options: WriteOptions = switch (fixture.writer_header) {
                .riff => .{},
                .rf64 => .{ .rf64 = .always },
                .w64 => .{ .variant = .w64 },
            };
            options.tags = &tags;
            options.bext = fixture.writer_bext;
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
            if (tags.count() == 0) {
                const pad = options.variant.padAfter(data.len);
                try std.testing.expectEqual(headerLen(codec, format, form), out.buffered().len - data.len - pad);
            }
            count += 1;
        }
    }
    // Every encoding, plain and extensible, Wave64, and tags.
    try std.testing.expect(count >= 18);
}

test "writeFrames encodes s16 samples as the writer's codec" {
    inline for (.{ "mono_8k", "alaw_mono_8k", "mulaw_mono_8k" }) |name| {
        const stream = comptime for (fixtures.all) |f| {
            if (std.mem.eql(u8, f.name, name)) break f.expected.accept;
        } else unreachable;
        const codec = codecOf(stream.codec);
        const format = try audio.Format.initLayout(stream.sample_rate, stream.channelLayout(), .s16);
        var buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var writer = try Writer.begin(&out, codec, format, stream.frameCount(), .{});
        try writer.writeFrames(stream.samples.s16);
        try writer.finish();
        try std.testing.expectEqualSlices(u8, fixtures.bytes(name), out.buffered());
    }
}

test "writeFrames takes frames wider than its encoding chunk allows evenly" {
    // 2048 samples, the writer's chunk, is not a whole number of
    // six-channel frames.
    const six = try audio.Format.init(8000, 6, .s16);
    const frame_count = 1000;
    var samples: [frame_count * 6]i16 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = @intCast(i % 30000);
    // The 5.1 default takes the 68-byte extensible header.
    var buffer: [68 + samples.len * 2]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var writer = try Writer.begin(&out, .s16le, six, frame_count, .{});
    try writer.writeFrames(&samples);
    try writer.finish();

    var reader: std.Io.Reader = .fixed(out.buffered());
    var storage: [samples.len * 2]u8 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqual(storage.len, decoded.raw.len);
    for (samples, 0..) |sample, i| {
        try std.testing.expectEqual(sample, std.mem.readInt(i16, decoded.raw[2 * i ..][0..2], .little));
    }
}

test "a deferred header, rewritten at the end, equals the known-length header" {
    const gpa = std.testing.allocator;
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    try tags.put(gpa, "title", "Deferred", .replace);
    try tags.put(gpa, "description", "bext body", .replace);
    const Case = struct { codec: pcm.Codec, frames: u32, options: WriteOptions };
    const cases = [_]Case{
        // Odd u8 data (a pad byte), with LIST/INFO and bext chunks between
        // the header's two parts.
        .{ .codec = .u8, .frames = 7, .options = .{ .tags = &tags, .bext = true } },
        // Float: a `fact` chunk holds the count too.
        .{ .codec = .f32le, .frames = 5, .options = .{} },
        .{ .codec = .s24le, .frames = 3, .options = .{ .rf64 = .always } },
        .{ .codec = .s16le, .frames = 9, .options = .{ .variant = .w64 } },
    };
    for (cases) |case| {
        const format = try audio.Format.init(8000, 2, case.codec.storage());
        var data: [9 * 2 * 4]u8 = undefined;
        for (&data, 0..) |*b, i| b.* = @truncate(i * 7);
        const bytes = data[0 .. case.frames * 2 * case.codec.bytesPerSample()];

        var known_buffer: [2048]u8 = undefined;
        var known: std.Io.Writer = .fixed(&known_buffer);
        var w = try Writer.begin(&known, case.codec, format, case.frames, case.options);
        try w.writeData(bytes);
        try w.finish();

        var deferred_buffer: [2048]u8 = undefined;
        var deferred: std.Io.Writer = .fixed(&deferred_buffer);
        var d = try Writer.beginDeferred(&deferred, case.codec, format, case.options);
        // In two pieces: the deferred writer takes any count.
        const half = (case.frames / 2) * 2 * case.codec.bytesPerSample();
        try d.writeData(bytes[0..half]);
        try d.writeData(bytes[half..]);
        try d.finish();
        try d.rewriteHeader(.fixed(&deferred));
        try std.testing.expectEqualSlices(u8, known.buffered(), deferred.buffered());
    }
}

test "a deferred RIFF header that would need RF64 at the end fails" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var d = try Writer.beginDeferred(&out, .s16le, stereo, .{ .rf64 = .auto });
    try d.finish();
    // As if 4 GiB of frames had been written: RF64's header is longer.
    d.frames_written = (1 << 30) + 1;
    try std.testing.expectError(error.SizeOverflow, d.rewriteHeader(.fixed(&out)));
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
    // No channels: every frame size would divide by zero.
    for ([_]audio.ChannelLayout{ .{ .unspecified = 0 }, .{ .native = 0 } }) |none| {
        const no_channels: audio.Format = .{ .sample_rate = 8000, .layout = none, .sample_format = .s16 };
        try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, .s16le, no_channels, 0, .{}));
    }
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
    const header_len: u64 = header.len;
    const riff_size = (5 << 30) + header_len - 8;
    try std.testing.expectEqual(riff_size, std.mem.readInt(u64, header[20..28], .little));
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

/// The bytes between `fmt ` and `data` the writer emits for `pairs`.
fn writtenTagChunks(pairs: []const [2][]const u8, bext: bool, out: []u8) ![]const u8 {
    const gpa = std.testing.allocator;
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    for (pairs) |pair| try tags.put(gpa, pair[0], pair[1], .keep);
    const mono = try audio.Format.init(8000, 1, .s16);
    var w: std.Io.Writer = .fixed(out);
    var writer = try Writer.begin(&w, .s16le, mono, 0, .{ .tags = &tags, .bext = bext });
    try writer.finish();
    const written = w.buffered();
    const fmt_end = canonical_header_len - 8;
    // The RIFF size counts the tag chunks.
    try std.testing.expectEqual(written.len - 8, std.mem.readInt(u32, written[4..8], .little));
    try std.testing.expectEqualStrings("data", written[written.len - 8 ..][0..4]);
    return written[fmt_end .. written.len - 8];
}

test "the writer chooses INFO tags as FFmpeg's does" {
    var buffer: [1024]u8 = undefined;
    // Generic names become codes, written in riff_tags order; an exact code
    // passes; a lowercase code is not one; an empty value is skipped; track's
    // first code takes the first track.
    const mixed = try writtenTagChunks(&.{
        .{ "comment", "c" }, .{ "track", "7" }, .{ "IENG", "eng" }, .{ "iart", "lower" },
        .{ "title", "" },    .{ "track", "8" }, .{ "artist", "A" },
    }, false, &buffer);
    try std.testing.expectEqualSlices(u8, "LIST\x2e\x00\x00\x00INFO" ++
        "IART\x02\x00\x00\x00A\x00" ++ "ICMT\x02\x00\x00\x00c\x00" ++
        "IENG\x04\x00\x00\x00eng\x00" ++ "IPRT\x02\x00\x00\x007\x00", mixed);
    // A tag the renaming drops as a duplicate of an earlier one (same key in
    // any case, same value) is not written; with no other, there is no list.
    try std.testing.expectEqualSlices(u8, "", try writtenTagChunks(&.{ .{ "iart", "X" }, .{ "artist", "X" } }, false, &buffer));
    // A known code with only an empty value still makes an empty list.
    try std.testing.expectEqualSlices(u8, "LIST\x04\x00\x00\x00INFO", try writtenTagChunks(&.{.{ "title", "" }}, false, &buffer));
    // Without tags, nothing at all.
    try std.testing.expectEqualSlices(u8, "", try writtenTagChunks(&.{}, false, &buffer));
}

test "the bext option writes the fixed fields and reads back under FFmpeg's names" {
    const gpa = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    // Too long a description is cut to 256 bytes; a negative time reference
    // is stored as its two's complement, as strtoll and a 64-bit write do.
    const long: [300]u8 = @splat('d');
    const chunks = try writtenTagChunks(&.{ .{ "description", &long }, .{ "time_reference", " -2x" } }, true, &buffer);
    try std.testing.expectEqualStrings("bext", chunks[0..4]);
    try std.testing.expectEqual(bext_fixed_len, std.mem.readInt(u32, chunks[4..8], .little));
    const body = chunks[8..];
    try std.testing.expectEqualSlices(u8, long[0..256], body[0..256]);
    try std.testing.expectEqual(-2, std.mem.readInt(i64, body[338..346], .little));
    try std.testing.expectEqual(1, std.mem.readInt(u16, body[346..348], .little));

    var stored: metadata.Dictionary = .empty;
    defer stored.deinit(gpa);
    try parseBext(.{ .gpa = gpa, .dictionary = &stored }, body);
    var generic = try genericTags(gpa, &stored);
    defer generic.deinit(gpa);
    try std.testing.expectEqual(256, (generic.get("comment") orelse return error.TestExpectedValue).len);
    try std.testing.expectEqualStrings("18446744073709551614", generic.get("time_reference") orelse return error.TestExpectedValue);
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
    const header_len: u64 = headerLen(.f64le, stereo, .w64);
    const largest = (std.math.maxInt(i64) - header_len) / frame_bytes;
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

const seek_vectors = @embedFile("../testing/vectors/seek.txt");

/// The oracle's lines for fixture `name`, without its `F` line.
fn seekBlock(name: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var lines = std.mem.splitScalar(u8, seek_vectors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "F ")) continue;
        const at = @intFromPtr(line.ptr) - @intFromPtr(seek_vectors.ptr);
        if (start) |s| return seek_vectors[s..at];
        if (std.mem.eql(u8, line[2..], name)) start = at + line.len + 1;
    }
    return if (start) |s| seek_vectors[s..] else null;
}

const SeekTally = struct {
    compared: usize = 0,
    /// FFmpeg's avio read-ahead hit the end and its packet index answered
    /// (port.md "Seeking").
    understood: usize = 0,
};

/// Up to 16 frames from the parser's position, decoded and stored
/// little-endian, as hexadecimal.
fn firstFramesHex(p: *Parser, out: []u8) ![]const u8 {
    var encoded: [16 * 8 * 64]u8 = undefined;
    const want = @min(encoded.len, 16 * @as(usize, p.frame_bytes));
    var got: usize = 0;
    while (got < want) {
        const bytes = try p.readData(encoded[got..want]);
        if (bytes.len == 0) break;
        got += bytes.len;
    }
    if (got == 0) return out[0..0];
    const format = p.format.?;
    const frames: u32 = @intCast(got / p.frame_bytes);
    var stored: [2 * encoded.len]u8 = undefined;
    const layout = try samples_storage.Layout.init(format.sample_format, format.channelCount(), frames, .{ .line = 1 });
    const buffer = try samples_storage.Buffer.init(layout, &stored);
    _ = try pcm.decode(p.codec, encoded[0..got], buffer, 0);
    pcm.storedToLittle(format.sample_format, buffer.bytes);
    return std.fmt.bufPrint(out, "{x}", .{buffer.bytes}) catch unreachable;
}

fn parseFlags(text: []const u8) !seek.Flags {
    const bits = try std.fmt.parseInt(u8, text, 16);
    return .{ .backward = bits & 1 != 0, .byte = bits & 2 != 0, .any = bits & 4 != 0 };
}

/// Replays one fixture's seeks against the oracle.
fn expectSeeks(bytes: []const u8, limits: Limits, block: []const u8, tally: *SeekTally) !void {
    var lines = std.mem.splitScalar(u8, block, '\n');
    const opened = lines.next() orelse return error.BadVector;
    if (!std.mem.eql(u8, opened, "O ok")) return; // FFmpeg cannot open it
    var info_fields = std.mem.tokenizeScalar(u8, lines.next() orelse return error.BadVector, ' ');
    _ = info_fields.next();
    const data_offset = try std.fmt.parseInt(i64, info_fields.next().?, 10);
    var pending: ?[]const u8 = lines.next();
    while (pending) |k_line| {
        pending = lines.next();
        if (k_line.len == 0) continue;
        if (k_line[0] != 'K') return error.BadVector;
        var f = std.mem.tokenizeScalar(u8, k_line, ' ');
        _ = f.next();
        const api = f.next().?[0];
        const stream = try std.fmt.parseInt(i32, f.next().?, 10);
        const ts = try std.fmt.parseInt(i64, f.next().?, 10);
        var min_ts: i64 = 0;
        var max_ts: i64 = 0;
        if (api == 's') {
            min_ts = try std.fmt.parseInt(i64, f.next().?, 10);
            max_ts = try std.fmt.parseInt(i64, f.next().?, 10);
        }
        const flags = try parseFlags(f.next().?);
        const ret = f.next().?;
        var packet: ?[]const u8 = null;
        var decoded: ?[]const u8 = null;
        if (std.mem.eql(u8, ret, "0")) {
            packet = pending;
            pending = lines.next();
            if (packet != null and !std.mem.eql(u8, packet.?, "P EOF")) {
                decoded = pending;
                pending = lines.next();
            }
        }
        errdefer std.debug.print("seek: {s}\n", .{k_line});

        var reader: std.Io.Reader = .fixed(bytes);
        var parser: Parser = .init(&reader, limits);
        parser.enableSeeking(.fixed(&reader));
        _ = try parser.readHeader();
        // FFmpeg's offset is its first packet's; empty data has none.
        if (data_offset >= 0) try std.testing.expectEqual(data_offset, @as(i64, @intCast(parser.data_offset)));
        const result = if (api == 'f')
            parser.seekFrame(stream, ts, flags)
        else
            parser.seekFile(stream, min_ts, ts, max_ts, flags);
        tally.compared += 1;
        if (std.mem.eql(u8, ret, "EINVAL")) {
            try std.testing.expectError(error.InvalidStream, result);
            continue;
        }
        const position = try result;
        if (std.mem.eql(u8, ret, "-1")) {
            // A target in FFmpeg's read-ahead window past the end, which it
            // then fails to find in its packet index: the end here.
            try std.testing.expect(position.at_end);
            tally.understood += 1;
            continue;
        }
        try std.testing.expectEqualStrings("0", ret);
        const p_line = packet orelse return error.BadVector;
        var hex: [16 * 8 * 64 * 2 * 2]u8 = undefined;
        const ours = try firstFramesHex(&parser, &hex);
        if (std.mem.eql(u8, p_line, "P EOF")) {
            try std.testing.expectEqual(0, ours.len);
            continue;
        }
        var pf = std.mem.tokenizeScalar(u8, p_line, ' ');
        _ = pf.next();
        const pts_text = pf.next().?;
        const pos = try std.fmt.parseInt(u64, pf.next().?, 10);
        if (position.at_end and pos < position.offset) {
            // FFmpeg's index answered a target past the end (as above),
            // landing at a packet it had read.
            tally.understood += 1;
            continue;
        }
        try std.testing.expectEqual(pos, position.offset);
        if (!flags.byte) try std.testing.expectEqual(try std.fmt.parseInt(i64, pts_text, 10), position.timestamp.?);
        const d_line = decoded orelse return error.BadVector;
        if (std.mem.eql(u8, d_line, "D none")) {
            try std.testing.expectEqual(0, ours.len);
            continue;
        }
        var df = std.mem.tokenizeScalar(u8, d_line, ' ');
        _ = df.next();
        _ = df.next();
        const theirs = df.next() orelse "";
        const common = @min(theirs.len, ours.len);
        try std.testing.expect(common > 0);
        try std.testing.expectEqualStrings(theirs[0..common], ours[0..common]);
    }
}

test "every accepted WAV fixture seeks as FFmpeg seeks it (vectors/seek.txt)" {
    var tally: SeekTally = .{};
    inline for (fixtures.all) |fixture| {
        const limits: ?Limits = switch (fixture.expected) {
            .accept => .{},
            .reject => if (fixture.unknown_length) |u| (if (u == .accept) Limits{ .unknown_length = true } else null) else null,
        };
        if (limits) |l| {
            if (seekBlock(fixture.name)) |block| {
                expectSeeks(fixtures.bytes(fixture.name), l, block, &tally) catch |err| {
                    std.debug.print("fixture {s}\n", .{fixture.name});
                    return err;
                };
            }
        }
    }
    // Every seek on the fixtures this parser accepts, 722 of them past the
    // data's end where FFmpeg's read-ahead and packet index answer.
    try std.testing.expectEqual(3548, tally.compared);
    try std.testing.expectEqual(722, tally.understood);
}

test "seeking a file: back and forth, then finish checks the chunks after the data" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.wav", .data = fixtures.bytes("info_after_data") });
    const file = try tmp.dir.openFile(io, "in.wav", .{});
    defer file.close(io);
    var buffer: [3]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var parser: Parser = .init(&reader.interface, .{});
    parser.enableSeeking(.file(&reader));
    _ = try parser.readHeader();
    var out: [64]u8 = undefined;
    // Frame 2 of 4, then frame 0, then past the end.
    const two = try parser.seekFrame(0, 2, .{});
    try std.testing.expectEqual(2, two.timestamp);
    try std.testing.expectEqual(parser.data_offset + 4, two.offset);
    try std.testing.expectEqual(4, (try parser.readData(&out)).len);
    _ = try parser.seekFrame(0, 0, .{ .backward = true });
    try std.testing.expectEqual(8, (try parser.readData(&out)).len);
    const end = try parser.seekFrame(-1, 10 * seek.time_base_units, .{});
    try std.testing.expect(end.at_end);
    try std.testing.expectEqual(0, (try parser.readData(&out)).len);
    // The trailing LIST chunk is still read and checked.
    try parser.finish();
}

test "a misaligned byte seek drops the final partial frame, known length or not" {
    for ([_]bool{ false, true }) |unknown| {
        const bytes = if (unknown) fixtures.bytes("riff_size_unknown") else fixtures.bytes("mono_8k");
        var reader: std.Io.Reader = .fixed(bytes);
        var parser: Parser = .init(&reader, .{ .unknown_length = unknown });
        parser.enableSeeking(.fixed(&reader));
        _ = try parser.readHeader();
        const position = try parser.seekFrame(0, @intCast(parser.data_offset + 1), .{ .byte = true });
        try std.testing.expectEqual(null, position.timestamp);
        var out: [64]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const data = try parser.readData(&out);
            if (data.len == 0) break;
            total += data.len;
        }
        // Every whole frame after the first byte; the odd byte at the end
        // is dropped.
        try std.testing.expectEqual(bytes.len - parser.data_offset - 2 - (bytes.len - parser.data_offset) % 2, total);
        try parser.finish();
    }
}

test "seekFile refuses an empty range and seeks within one" {
    var reader: std.Io.Reader = .fixed(fixtures.bytes("stereo_44k1"));
    var parser: Parser = .init(&reader, .{});
    parser.enableSeeking(.fixed(&reader));
    _ = try parser.readHeader();
    try std.testing.expectError(error.InvalidRange, parser.seekFile(0, 2, 1, 3, .{}));
    try std.testing.expectError(error.InvalidStream, parser.seekFrame(1, 0, .{}));
    const position = try parser.seekFile(0, 1, 2, 3, .{});
    try std.testing.expectEqual(2, position.timestamp);
}
