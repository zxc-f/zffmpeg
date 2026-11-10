// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/mov.c (mov_read_default, mov_probe,
// mov_read_ftyp, mov_read_moov, mov_read_mvhd, mov_read_trak,
// mov_read_tkhd, mov_read_mdhd, mov_read_hdlr, mov_read_stsd,
// ff_mov_read_stsd_entries, mov_codec_id, mov_parse_stsd_audio,
// mov_parse_stsd_data, mov_finalize_stsd_codec, mov_read_wave,
// mov_read_alac, mov_read_extradata, mov_read_glbl, mov_read_dfla,
// mov_read_dops, mov_read_dac3, mov_read_dec3, mov_read_chan,
// mov_read_enda, mov_read_srat, mov_read_stts, mov_read_ctts,
// mov_read_stsc, mov_read_stsz, mov_read_stco, mov_read_stss,
// mov_read_stps, mov_read_sdtp, mov_read_sgpd, mov_read_sbgp,
// mov_read_elst, mov_read_dref, mov_read_mdat, mov_read_wide,
// mov_read_free, mov_merge_tts_data, mov_build_index, mov_fix_index's
// identity case, sanity_checks, fix_timescale, mov_read_header,
// mov_find_next_sample, mov_switch_root, mov_finalize_packet,
// mov_read_packet; T33a2: mov_read_udta_string, mov_read_mac_string,
// mov_metadata_track_or_disc_number, mov_metadata_int8_bypass_padding,
// mov_metadata_int8_no_padding, mov_metadata_gnre, mov_metadata_loci,
// mov_metadata_hmmt, mov_read_covr, mov_read_meta, mov_read_ilst,
// mov_read_keys, mov_read_custom, mov_read_chpl, mov_read_chap,
// mov_read_chapters, mov_read_kind, mov_read_uuid,
// mov_parse_uuid_spherical, mov_parse_stsd_subtitle),
// libavformat/isom.c (ff_mp4_obj_type, ff_mov_lang_to_iso639,
// ff_mp4_read_descr, ff_mp4_parse_es_descr, ff_mp4_read_dec_config_descr,
// ff_codec_movsubtitle_tags, ff_mov_track_kind_table),
// libavformat/isom_tags.c (ff_codec_movaudio_tags), libavformat/isom.h
// (ff_mov_get_lpcm_codec_id), libavformat/aviobuf.c (avio_get_str,
// avio_get_str16be, avio_get_str16le, read_string_to_bprint),
// libavutil/common.h (GET_UTF16, PUT_UTF8),
// libavformat/utils.c (ff_get_pcm_codec_id), libavformat/mov_esds.c
// (ff_mov_read_esds) and libavformat/aviobuf.c's avio_seek and avio_feof
// at the pinned reference revision.
// Copyright (c) 2001 Fabrice Bellard
// Copyright (c) 2002 Francois Revol <revol@free.fr>
// Copyright (c) 2006 Baptiste Coudurier <baptiste.coudurier@free.fr>
// Copyright (c) 2009 Jon Brandon
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's mov demuxer (`mov,mp4,m4a,3gp,3g2,mj2`, TODO.md T33a1) for
//! audio and data tracks: the box walk of `mov_read_default` with FFmpeg's
//! size rules (32- and 64-bit sizes, a size of 0 running to the parent's
//! end, nesting deeper than 10 refused), the movie and track headers, the
//! sample descriptions (QuickTime versions 0 to 2 and MP4, `wave`, `esds`,
//! `alac`, `dfLa`, `dOps`, `dac3`, `dec3`, `chan`, `glbl`, `enda`,
//! `srat`), the sample tables, the sample index `mov_build_index` makes of
//! them (PCM grouped into packets of up to 1024 samples per chunk when
//! every sample lasts one tick), and `mov_read_packet`'s choice of the
//! next sample across tracks. demux.zig's `Layer` adds libavformat's
//! timestamps, parsers (MPEG audio in QuickTime files, AC-3 and E-AC-3)
//! and the stream-info read-ahead.
//!
//! The input is read as FFmpeg's `AVIOContext` reads it (`Input`): the
//! box readers read past a box's end when its contents say so, and the walk
//! seeks back, as `mov_read_default` does. A `moov` after `mdat` is read
//! by seeking; from a source that cannot seek it is `UnsupportedStreamingSize`.
//!
//! Metadata (T33a2): `udta` strings, `meta` with its `hdlr`, `keys` and
//! iTunes `ilst` tags, `----` (iTunSMPB's gapless counts, ReplayGain), `kind`
//! dispositions, `uuid` (XMP skipped, an ISML manifest's bit rates), the
//! chapters of `chpl`, `HMMT` and QuickTime chapter tracks (`tref`/`chap`),
//! which on a seekable input become discarded data streams as FFmpeg makes
//! them, and on a pipe stay subtitle streams.
//!
//! Refused here, where FFmpeg reads on (notes.md "MP4 demuxing"): an edit
//! list that changes the index (T33b), video tracks and subtitle tracks
//! other than chapter tracks (T33a3), fragments (`moof`, T33c), compressed
//! movie headers (`cmov`), a `dref` alias that may name another file, a WAV
//! codec tag in an `ms` sample entry, and a cover picture (`covr`) inside a
//! track or before one. A cover picture after the tracks, which FFmpeg makes
//! an attached-picture stream, is skipped.

const std = @import("std");
const demux = @import("demux.zig");
const chapters_mod = @import("chapters.zig");
const mp3 = @import("mp3.zig");
const id3v1 = @import("id3v1.zig");
const seek = @import("seek.zig");
const rational = @import("../core/rational.zig");
const metadata = @import("../core/metadata.zig");
const channel_layout = @import("../core/channel_layout.zig");
const mov_chan = @import("mov_chan.zig");
const mpeg4audio = @import("../codec/mpeg4audio.zig");
const alac = @import("../codec/alac.zig");
const opusdec = @import("../codec/opusdec.zig");
const flac = @import("../codec/flac.zig");
const mpegaudio = @import("../codec/mpegaudio.zig");
const skip = @import("../io/skip.zig");

const Layout = channel_layout.Layout;

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA: no `moov`, a box FFmpeg refuses, a
    /// track whose tables contradict each other.
    InvalidMov,
    /// FFmpeg's AVERROR_EOF from a box read: the input ends inside a table
    /// FFmpeg reads to its end.
    Truncated,
    /// FFmpeg's AVERROR_PATCHWELCOME: an `mdhd` of version 2 or more.
    PatchWelcome,
    /// What the port does not demux yet (an edit list that changes the
    /// index, video or subtitle tracks, fragments, `cmov`, an external
    /// data reference, a WAV codec tag in an `ms` sample entry).
    UnsupportedFormat,
    /// A `moov` after `mdat` on a source that cannot seek.
    UnsupportedStreamingSize,
    /// FFmpeg's AVERROR(ERANGE): an `sdtp` box under 4 bytes.
    OutOfRange,
    /// A count or size over `Limits`, or one FFmpeg fails to allocate
    /// (AVERROR(ENOMEM) past 2 GiB).
    LimitExceeded,
    IoFailure,
    OutOfMemory,
};

pub const Limits = struct {
    /// Entries in one sample table (`stts`, `ctts`, `stsc`, `stsz`, `stco`,
    /// `stss`, `stps`, `sdtp`, `sbgp`, `elst`); FFmpeg allocates what a
    /// table declares, up to 2 GiB.
    max_entries: u32 = 1 << 24,
    /// Index entries a track's samples make (`mov_build_index`); FFmpeg
    /// allocates them up to 2 GiB.
    max_samples: u32 = 1 << 22,
    /// The tracks; FFmpeg has no limit.
    max_tracks: u32 = 1024,
    /// The bytes of a box read into memory: extradata, a `chan` body, an
    /// `hdlr` name, the compatible brands, a tag's value.
    max_box_bytes: u32 = 1 << 26,
    /// The chapters; FFmpeg has no limit.
    max_chapters: u32 = 1 << 20,
};

pub const nopts: i64 = std.math.minInt(i64);
const time_base_units: i64 = 1_000_000;

/// MKTAG: a four-character code as `AV_RL32` reads it.
fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

// ---- The input ----

/// FFmpeg's `AVIOContext` as the mov demuxer meets it: a position, the
/// `eof_reached` flag reads past the end set (with zeros read), skips and
/// seeks. On a source that cannot seek, the last bytes read stay
/// available for the short seeks back the box walk makes.
const Input = struct {
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    /// `avio_tell`.
    pos: i64,
    /// Where the reader is.
    under: i64,
    /// `eof_reached`.
    eof: bool = false,
    /// `avio_size` on a seekable source.
    size: ?i64,
    /// On a pipe: bytes before `under`, for seeks back within them.
    history: std.ArrayList(u8) = .empty,
    keep_history: bool = true,

    /// How much a pipe keeps for seeks back (FFmpeg's buffer, about).
    const history_keep = 64 * 1024;

    fn deinit(in: *Input, gpa: std.mem.Allocator) void {
        in.history.deinit(gpa);
    }

    fn seekable(in: *const Input) bool {
        return in.seeker != null;
    }

    /// Up to `buf.len` bytes from `pos`; fewer at the end, which sets
    /// `eof`.
    fn read(in: *Input, gpa: std.mem.Allocator, buf: []u8) Error!usize {
        var n: usize = 0;
        while (n < buf.len) {
            if (in.pos < in.under) {
                if (in.seeker) |sk| {
                    sk.seekTo(@intCast(in.pos)) catch return error.IoFailure;
                    in.under = in.pos;
                    continue;
                }
                const behind: usize = @intCast(in.under - in.pos);
                // Seeks back on a pipe stay within the history.
                std.debug.assert(behind <= in.history.items.len);
                const from = in.history.items.len - behind;
                const take = @min(behind, buf.len - n);
                @memcpy(buf[n..][0..take], in.history.items[from..][0..take]);
                n += take;
                in.pos += @intCast(take);
                continue;
            }
            if (in.pos > in.under) {
                if (in.seeker) |sk| {
                    if (in.size) |size| if (in.pos >= size) {
                        in.eof = true;
                        return n;
                    };
                    sk.seekTo(@intCast(in.pos)) catch return error.IoFailure;
                    in.under = in.pos;
                    continue;
                }
                // `seekTo` keeps a pipe's position at or before the reader.
                unreachable;
            }
            const want = buf.len - n;
            const got = in.reader.readSliceShort(buf[n..]) catch return error.IoFailure;
            if (!in.seekable() and in.keep_history) try in.remember(gpa, buf[n..][0..got]);
            n += got;
            in.pos += @intCast(got);
            in.under += @intCast(got);
            if (got < want) {
                in.eof = true;
                break;
            }
        }
        return n;
    }

    fn remember(in: *Input, gpa: std.mem.Allocator, data: []const u8) Error!void {
        try in.history.appendSlice(gpa, data);
        if (in.history.items.len > 2 * history_keep) {
            const drop = in.history.items.len - history_keep;
            std.mem.copyForwards(u8, in.history.items[0..history_keep], in.history.items[drop..]);
            in.history.shrinkRetainingCapacity(history_keep);
        }
    }

    fn bytes(in: *Input, gpa: std.mem.Allocator, comptime n: usize) Error![n]u8 {
        var b: [n]u8 = @splat(0);
        _ = try in.read(gpa, &b);
        return b;
    }

    fn r8(in: *Input, gpa: std.mem.Allocator) Error!u8 {
        return (try in.bytes(gpa, 1))[0];
    }
    fn rb16(in: *Input, gpa: std.mem.Allocator) Error!u16 {
        return std.mem.readInt(u16, &(try in.bytes(gpa, 2)), .big);
    }
    fn rb24(in: *Input, gpa: std.mem.Allocator) Error!u32 {
        return std.mem.readInt(u24, &(try in.bytes(gpa, 3)), .big);
    }
    fn rb32(in: *Input, gpa: std.mem.Allocator) Error!u32 {
        return std.mem.readInt(u32, &(try in.bytes(gpa, 4)), .big);
    }
    fn rl32(in: *Input, gpa: std.mem.Allocator) Error!u32 {
        return std.mem.readInt(u32, &(try in.bytes(gpa, 4)), .little);
    }
    fn rb64(in: *Input, gpa: std.mem.Allocator) Error!u64 {
        return std.mem.readInt(u64, &(try in.bytes(gpa, 8)), .big);
    }

    /// `avio_seek(SEEK_SET)`: false where FFmpeg's fails. Forward past the
    /// end of a file, or through the end of a pipe, the position stops at
    /// the end with `eof` set (FFmpeg's short seek reads up to it); back
    /// on a pipe, only within the history.
    fn seekTo(in: *Input, gpa: std.mem.Allocator, target: i64) Error!bool {
        if (target < 0) return false;
        if (in.seeker != null) {
            if (in.size) |size| if (target > size) {
                in.pos = size;
                in.eof = true;
                return false;
            };
            in.pos = target;
            in.eof = false;
            return true;
        }
        if (target <= in.under) {
            if (in.under - target > in.history.items.len) return false;
            in.pos = target;
            in.eof = false;
            return true;
        }
        // Forward through a pipe: the bytes before the target are read.
        in.pos = in.under;
        const want: u64 = @intCast(target - in.under);
        var got: u64 = 0;
        if (in.keep_history) {
            var chunk: [4096]u8 = undefined;
            while (got < want) {
                const step: usize = @min(want - got, chunk.len);
                const n = try in.read(gpa, chunk[0..step]);
                got += n;
                if (n < step) break;
            }
        } else {
            got = skip.discardShort(in.reader, want) catch return error.IoFailure;
            in.under += @intCast(got);
            in.pos = in.under;
        }
        if (got < want) {
            in.eof = true;
            return false;
        }
        in.eof = false;
        return true;
    }

    /// `avio_skip`.
    fn skipBy(in: *Input, gpa: std.mem.Allocator, n: i64) Error!bool {
        const target = std.math.add(i64, in.pos, n) catch return false;
        return in.seekTo(gpa, target);
    }

    /// `avio_feof`: the flag cleared, then set again when no byte follows.
    fn feof(in: *Input, gpa: std.mem.Allocator) Error!bool {
        if (!in.eof) return false;
        in.eof = false;
        if (in.seeker != null) {
            if (in.size) |size| if (in.pos >= size) {
                in.eof = true;
            };
            return in.eof;
        }
        if (in.pos < in.under) return false;
        var one: [1]u8 = undefined;
        const got = in.reader.readSliceShort(&one) catch return error.IoFailure;
        if (got == 0) {
            in.eof = true;
            return true;
        }
        try in.history.append(gpa, one[0]);
        in.under += 1;
        return false;
    }

    /// Up to `n` bytes skipped, as reads skip them: the count present (the
    /// rest past the end, which sets `eof`).
    fn skipCount(in: *Input, gpa: std.mem.Allocator, n: u64) Error!u64 {
        const start = in.pos;
        const step = std.math.cast(i64, n) orelse std.math.maxInt(i64);
        _ = try in.seekTo(gpa, in.pos +| step);
        return @intCast(in.pos - start);
    }

    /// `ffio_read_size` into owned memory: all `n` bytes, else null
    /// (FFmpeg's AVERROR_INVALIDDATA). The buffer grows with the bytes
    /// read, so a size the input does not hold allocates no more than it
    /// does.
    fn readOwned(in: *Input, gpa: std.mem.Allocator, n: u64) Error!?[]u8 {
        if (in.size) |size| if (in.pos >= size or n > @as(u64, @intCast(size - in.pos))) {
            // The read would come short: it runs to the end, as FFmpeg's.
            _ = try in.seekTo(gpa, size);
            in.eof = true;
            return null;
        };
        const len = std.math.cast(usize, n) orelse return error.LimitExceeded;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        while (buf.items.len < len) {
            const old = buf.items.len;
            const step = @min(len - old, 64 * 1024);
            try buf.resize(gpa, old + step);
            const got = try in.read(gpa, buf.items[old..]);
            if (got < step) {
                buf.deinit(gpa);
                return null;
            }
        }
        return try buf.toOwnedSlice(gpa);
    }
};

// ---- Codecs ----

/// The codecs a track can name: `ff_codec_movaudio_tags`, the MP4 object
/// types (`ff_mp4_obj_type`), `ff_mov_get_lpcm_codec_id`'s PCM, the data
/// tags, and `none`.
pub const Codec = enum {
    none,
    aac,
    apple_apac,
    ac3,
    ac4,
    adpcm_ima_qt,
    alac,
    amr_nb,
    amr_wb,
    dts,
    eac3,
    dvaudio,
    gsm,
    ilbc,
    mace3,
    mace6,
    mp1,
    mp2,
    mp3,
    mp3on4,
    nellymoser,
    pcm_alaw,
    pcm_mulaw,
    pcm_f32be,
    pcm_f32le,
    pcm_f64be,
    pcm_f64le,
    pcm_s8,
    pcm_u8,
    pcm_s16be,
    pcm_s16le,
    pcm_u16be,
    pcm_u16le,
    pcm_s24be,
    pcm_s24le,
    pcm_u24be,
    pcm_u24le,
    pcm_s32be,
    pcm_s32le,
    pcm_u32be,
    pcm_u32le,
    pcm_s64be,
    pcm_s64le,
    qcelp,
    qdm2,
    qdmc,
    speex,
    evrc,
    smv,
    flac,
    truehd,
    opus,
    mpegh_3d_audio,
    mp4als,
    vorbis,
    // Object types that are not audio, which an `esds` can name in any
    // track.
    mov_text,
    eia_608,
    ttml,
    mpeg4,
    h264,
    hevc,
    vvc,
    mpeg2video,
    mpeg1video,
    mjpeg,
    png,
    jpeg2000,
    vc1,
    dirac,
    vp9,
    tscc2,
    dvd_subtitle,
    mpeg4systems,
    bin_data,

    /// `avcodec_get_name`.
    pub fn name(c: Codec) []const u8 {
        return switch (c) {
            .mpeg4systems => "unknown_codec",
            else => @tagName(c),
        };
    }

    /// `av_get_bits_per_sample`.
    pub fn bitsPerSample(c: Codec) u32 {
        return switch (c) {
            .adpcm_ima_qt => 4,
            .pcm_alaw, .pcm_mulaw, .pcm_s8, .pcm_u8 => 8,
            .pcm_s16be, .pcm_s16le, .pcm_u16be, .pcm_u16le => 16,
            .pcm_s24be, .pcm_s24le, .pcm_u24be, .pcm_u24le => 24,
            .pcm_s32be, .pcm_s32le, .pcm_u32be, .pcm_u32le, .pcm_f32be, .pcm_f32le => 32,
            .pcm_s64be, .pcm_s64le, .pcm_f64be, .pcm_f64le => 64,
            else => 0,
        };
    }

    /// `AV_CODEC_PROP_INTRA_ONLY` in FFmpeg's descriptor.
    pub fn intraOnly(c: Codec) bool {
        return switch (c) {
            .none, .aac, .apple_apac, .ac4, .truehd, .mpegh_3d_audio, .mov_text, .eia_608, .ttml, .mpeg4, .h264, .hevc, .vvc, .mpeg2video, .mpeg1video, .png, .vc1, .dirac, .vp9, .tscc2, .dvd_subtitle, .mpeg4systems, .bin_data => false,
            else => true,
        };
    }

    /// The reference build has a decoder for it.
    fn hasDecoder(c: Codec) bool {
        return switch (c) {
            .aac, .ac3, .eac3, .alac, .flac, .mp1, .mp2, .mp3, .opus, .vorbis => true,
            .pcm_alaw, .pcm_mulaw, .pcm_f32be, .pcm_f32le, .pcm_f64be, .pcm_f64le, .pcm_s8, .pcm_u8, .pcm_s16be, .pcm_s16le, .pcm_s24be, .pcm_s24le, .pcm_s32be, .pcm_s32le, .pcm_s64be, .pcm_s64le => true,
            else => false,
        };
    }

    /// The media type a codec's descriptor gives (`mov_codec_id`'s
    /// lookups set it from the table they found the tag in).
    fn isVideo(c: Codec) bool {
        return switch (c) {
            .mpeg4, .h264, .hevc, .vvc, .mpeg2video, .mpeg1video, .mjpeg, .png, .jpeg2000, .vc1, .dirac, .vp9, .tscc2 => true,
            else => false,
        };
    }
};

/// `ff_codec_movaudio_tags`, in its order (the first match wins).
const movaudio_tags = [_]struct { u32, Codec }{
    .{ tag("mp4a"), .aac },       .{ tag("apac"), .apple_apac },     .{ tag("ac-3"), .ac3 },        .{ tag("sac3"), .ac3 },
    .{ tag("ac-4"), .ac4 },       .{ tag("ima4"), .adpcm_ima_qt },   .{ tag("alac"), .alac },       .{ tag("samr"), .amr_nb },
    .{ tag("sawb"), .amr_wb },    .{ tag("dtsc"), .dts },            .{ tag("dtsh"), .dts },        .{ tag("dtsl"), .dts },
    .{ tag("dtse"), .dts },       .{ tag("DTS "), .dts },            .{ tag("ec-3"), .eac3 },       .{ tag("vdva"), .dvaudio },
    .{ tag("dvca"), .dvaudio },   .{ tag("agsm"), .gsm },            .{ tag("ilbc"), .ilbc },       .{ tag("MAC3"), .mace3 },
    .{ tag("MAC6"), .mace6 },     .{ tag(".mp1"), .mp1 },            .{ tag(".mp2"), .mp2 },        .{ tag(".mp3"), .mp3 },
    .{ tag("mp3 "), .mp3 },       .{ 0x6D730055, .mp3 },             .{ tag("nmos"), .nellymoser }, .{ tag("NELL"), .nellymoser },
    .{ tag("alaw"), .pcm_alaw },  .{ tag("fl32"), .pcm_f32be },      .{ tag("fl64"), .pcm_f64be },  .{ tag("ulaw"), .pcm_mulaw },
    .{ tag("twos"), .pcm_s16be }, .{ tag("sowt"), .pcm_s16le },      .{ tag("lpcm"), .pcm_s16be },  .{ tag("in24"), .pcm_s24be },
    .{ tag("42ni"), .pcm_s24le }, .{ tag("in32"), .pcm_s32be },      .{ tag("23ni"), .pcm_s32le },  .{ tag("raw "), .pcm_u8 },
    .{ tag("NONE"), .pcm_u8 },    .{ tag("Qclp"), .qcelp },          .{ tag("Qclq"), .qcelp },      .{ tag("sqcp"), .qcelp },
    .{ tag("QDM2"), .qdm2 },      .{ tag("QDMC"), .qdmc },           .{ tag("spex"), .speex },      .{ tag("SPXN"), .speex },
    .{ tag("sevc"), .evrc },      .{ tag("ssmv"), .smv },            .{ tag("fLaC"), .flac },       .{ tag("mlpa"), .truehd },
    .{ tag("Opus"), .opus },      .{ tag("mhm1"), .mpegh_3d_audio },
};

fn movAudioCodec(format: u32) Codec {
    for (movaudio_tags) |e| if (e[0] == format) return e[1];
    return .none;
}

/// `ff_mp4_obj_type`, in its order.
fn objectTypeCodec(object_type: u8) Codec {
    return switch (object_type) {
        0x08 => .mov_text,
        0x20 => .mpeg4,
        0x21 => .h264,
        0x23 => .hevc,
        0x33 => .vvc,
        0x40, 0x66, 0x67, 0x68 => .aac,
        0x60...0x65 => .mpeg2video,
        0x69, 0x6B => .mp3,
        0x6A => .mpeg1video,
        0x6C => .mjpeg,
        0x6D => .png,
        0x6E => .jpeg2000,
        0xA3 => .vc1,
        0xA4 => .dirac,
        0xA5 => .ac3,
        0xA6 => .eac3,
        0xA9 => .dts,
        0xAD => .opus,
        0xB1 => .vp9,
        0xD0 => .tscc2,
        0xD1 => .evrc,
        0xDD => .vorbis,
        0xE0 => .dvd_subtitle,
        0xE1 => .qcelp,
        0x01, 0x02 => .mpeg4systems,
        else => .none,
    };
}

/// `ff_get_pcm_codec_id`.
fn pcmCodec(bps: i64, float: bool, big_endian: bool, signed_flags: u32) Codec {
    if (bps <= 0 or bps > 64) return .none;
    if (float) return switch (bps) {
        32 => if (big_endian) .pcm_f32be else .pcm_f32le,
        64 => if (big_endian) .pcm_f64be else .pcm_f64le,
        else => .none,
    };
    const bytes: u5 = @intCast((bps + 7) >> 3);
    if (signed_flags & (@as(u32, 1) << (bytes - 1)) != 0) return switch (bytes) {
        1 => .pcm_s8,
        2 => if (big_endian) .pcm_s16be else .pcm_s16le,
        3 => if (big_endian) .pcm_s24be else .pcm_s24le,
        4 => if (big_endian) .pcm_s32be else .pcm_s32le,
        8 => if (big_endian) .pcm_s64be else .pcm_s64le,
        else => .none,
    };
    return switch (bytes) {
        1 => .pcm_u8,
        2 => if (big_endian) .pcm_u16be else .pcm_u16le,
        3 => if (big_endian) .pcm_u24be else .pcm_u24le,
        4 => if (big_endian) .pcm_u32be else .pcm_u32le,
        else => .none,
    };
}

/// `ff_mov_get_lpcm_codec_id`: flags 1 float, 2 big-endian, 4 signed.
fn lpcmCodec(bps: i64, flags: u32) Codec {
    return pcmCodec(bps, flags & 1 != 0, flags & 2 != 0, if (flags & 4 != 0) 0xffff_ffff else 0);
}

/// `mov_mdhd_language_map`.
const language_map = [_][]const u8{
    "eng", "fra", "ger", "ita", "dut", "sve", "spa", "dan", "por", "nor", "heb", "jpn", "ara", "fin", "gre",
    "ice", "mlt", "tur", "hr ", "chi", "urd", "hin", "tha", "kor", "lit", "pol", "hun", "est", "lav", "smi",
    "fo ", "per", "rus", "chi", "",    "iri", "alb", "ron", "ces", "slk", "slv", "yid", "sr ", "mac", "bul",
    "ukr", "bel", "uzb", "kaz", "aze", "aze", "arm", "geo", "mol", "kir", "tgk", "tuk", "mon", "",    "pus",
    "kur", "kas", "snd", "tib", "nep", "san", "mar", "ben", "asm", "guj", "pa ", "ori", "mal", "kan", "tam",
    "tel", "sin", "bur", "khm", "lao", "vie", "ind", "tgl", "may", "may", "amh", "tir", "orm", "som", "swa",
    "kin", "run", "nya", "mlg", "epo", "",    "",    "",    "",    "",    "",    "",    "",    "",    "",
    "",    "",    "",    "",    "",    "",    "",    "",    "",    "",    "",    "",    "",    "",    "",
    "",    "",    "",    "wel", "baq", "cat", "lat", "que", "grn", "aym", "tat", "uig", "dzo", "jav",
};

/// `ff_mov_lang_to_iso639`: the language's code, or null.
fn languageCode(code_in: u16, out: *[3]u8) ?[]const u8 {
    var code = code_in;
    if (code >= 0x400 and code != 0x7fff) {
        var i: usize = 3;
        while (i > 0) {
            i -= 1;
            out[i] = 0x60 + @as(u8, @truncate(code & 0x1f));
            code >>= 5;
        }
        // A letter of 0 bits is 0x60; the string ends at no NUL here.
        return out;
    }
    if (code >= language_map.len) return null;
    const lang = language_map[code];
    if (lang.len == 0) return null;
    return lang;
}
/// The video codec tags `ff_codec_movvideo_tags` and `ff_codec_bmp_tags`
/// hold in the reference build, sorted: a data track's sample entry whose
/// format is one of them is a video track to FFmpeg (`mov_codec_id`).
const video_tags = [_]u32{
    0x00000000, 0x00000001, 0x00000002, 0x00000003, 0x00000004, 0x10000001, 0x10000002, 0x10000004,
    0x20203859, 0x20474e4d, 0x20525644, 0x20616774, 0x20636d73, 0x20637664, 0x20656c72, 0x20666967,
    0x20676e70, 0x20696773, 0x206c7664, 0x20727865, 0x2076316d, 0x20776172, 0x20787064, 0x302e3151,
    0x30303859, 0x30313243, 0x30313259, 0x30313272, 0x30313276, 0x30313449, 0x30313459, 0x30313476,
    0x30315742, 0x30323449, 0x3032344a, 0x30323452, 0x30324d4c, 0x30324d54, 0x30325254, 0x30325442,
    0x30333145, 0x30335056, 0x3033564d, 0x30343449, 0x3034344a, 0x30344e53, 0x30345056, 0x30345652,
    0x30355056, 0x30355649, 0x30355844, 0x30357664, 0x30365056, 0x30365652, 0x30375056, 0x30385056,
    0x30395056, 0x30434c59, 0x3047304d, 0x3047384d, 0x30484c55, 0x304c4f43, 0x304d4741, 0x30514853,
    0x3052304d, 0x3059304d, 0x3059384d, 0x30594c55, 0x30595155, 0x305a4c42, 0x30726853, 0x312d6376,
    0x312e3151, 0x3130314d, 0x3130374d, 0x31305641, 0x31307661, 0x31313449, 0x31313452, 0x31313459,
    0x31325452, 0x3132564e, 0x31335056, 0x31335649, 0x31345041, 0x3134504d, 0x31345649, 0x31356478,
    0x31363248, 0x31365056, 0x31375056, 0x3141534d, 0x31435156, 0x31435657, 0x31474e50, 0x31495641,
    0x314c4f43, 0x314d4741, 0x314d4950, 0x31514853, 0x31515653, 0x31524356, 0x31535046, 0x3153534d,
    0x31564646, 0x3156474b, 0x31564944, 0x31564c46, 0x31564c50, 0x31564d57, 0x31564e57, 0x31565053,
    0x31565341, 0x31565346, 0x31565452, 0x31584d56, 0x31617664, 0x31626d64, 0x31636c6e, 0x31637661,
    0x31637665, 0x31637668, 0x3163766c, 0x31637676, 0x31645641, 0x31656c72, 0x3167706d, 0x31687664,
    0x31697676, 0x31706148, 0x31717673, 0x31726853, 0x31755632, 0x3176316d, 0x3176326d, 0x31766164,
    0x31766468, 0x31766478, 0x31766568, 0x31767061, 0x31767975, 0x3230314d, 0x3230374d, 0x3231564e,
    0x32315659, 0x32316961, 0x32323449, 0x3232344a, 0x32323450, 0x32323456, 0x32323459, 0x32335641,
    0x32335649, 0x32335652, 0x3234504d, 0x32356961, 0x32365056, 0x32424752, 0x32435156, 0x3243534d,
    0x32435354, 0x32484c55, 0x32484d55, 0x32495641, 0x324a5049, 0x324b4d44, 0x324d3247, 0x324d4741,
    0x324d4950, 0x32504d4c, 0x32505657, 0x32514853, 0x32524356, 0x32525541, 0x3253344d, 0x3253534d,
    0x3253544d, 0x32535641, 0x32564933, 0x32564944, 0x32564d53, 0x32564d57, 0x32565341, 0x3259304d,
    0x3259384d, 0x32594c55, 0x32594d55, 0x32595155, 0x32595559, 0x32637661, 0x3267706d, 0x32686478,
    0x32687664, 0x326a5641, 0x32706a6d, 0x32726853, 0x32737661, 0x32766468, 0x32766478, 0x32767561,
    0x32767579, 0x32797862, 0x3330374d, 0x33316961, 0x3334504d, 0x33356961, 0x33363248, 0x33363249,
    0x3336324c, 0x3336324d, 0x33363253, 0x33363254, 0x33363255, 0x33363258, 0x33363268, 0x33363273,
    0x33445844, 0x3347504d, 0x334d3247, 0x334d4741, 0x33514853, 0x33515653, 0x3354344d, 0x33564944,
    0x33564d57, 0x33585644, 0x33637661, 0x33687664, 0x33726853, 0x33737661, 0x33766468, 0x33766478,
    0x3430374d, 0x3432524a, 0x34325652, 0x34325659, 0x34343449, 0x3434344a, 0x34355053, 0x34356478,
    0x34363247, 0x34363248, 0x34363251, 0x34363256, 0x34363258, 0x34363268, 0x34363278, 0x34367672,
    0x3447504d, 0x34484c55, 0x34484d55, 0x344d3247, 0x344d4741, 0x344d4d49, 0x344d4e4d, 0x344d5356,
    0x344d5447, 0x344d5944, 0x34504d46, 0x34504d47, 0x34504d51, 0x34504d52, 0x34504d53, 0x34504d55,
    0x34504d5a, 0x34514853, 0x34534141, 0x34564944, 0x34564c46, 0x34564c47, 0x34584448, 0x3459304d,
    0x3459384d, 0x34594c55, 0x34594d55, 0x34637661, 0x34687664, 0x34726853, 0x34766468, 0x34766478,
    0x34767579, 0x3530374d, 0x35315652, 0x35316961, 0x35324c53, 0x35327664, 0x3535354c, 0x35356478,
    0x35356961, 0x35363542, 0x3536354c, 0x354d3247, 0x354d4741, 0x354d4d49, 0x35514853, 0x35564443,
    0x35564944, 0x35687664, 0x35706148, 0x35726853, 0x35766468, 0x35766478, 0x36313259, 0x36313459,
    0x36314f4e, 0x36315652, 0x36315659, 0x36316961, 0x36356961, 0x364d4741, 0x364d4d49, 0x36564944,
    0x36687664, 0x36726853, 0x36766468, 0x36766478, 0x374d4741, 0x37514853, 0x37726853, 0x37766468,
    0x37766478, 0x38303376, 0x38303476, 0x38303479, 0x38307076, 0x38565559, 0x38766468, 0x38766478,
    0x39307076, 0x39356478, 0x39514853, 0x39555659, 0x39565559, 0x39766468, 0x39766478, 0x41303449,
    0x41323449, 0x41344d45, 0x41365056, 0x41424752, 0x4148564d, 0x41507464, 0x4152304d, 0x4152324d,
    0x4152344d, 0x4152384d, 0x41524742, 0x41524c55, 0x41524d55, 0x41525155, 0x41525541, 0x41564d57,
    0x41565559, 0x4159384d, 0x415a5052, 0x41706148, 0x42313459, 0x42323459, 0x42393049, 0x42393249,
    0x42393449, 0x42413049, 0x42413249, 0x42413449, 0x42433049, 0x42433249, 0x42433449, 0x42463049,
    0x42463449, 0x42494c5a, 0x43324a4c, 0x43324a4d, 0x43425241, 0x4343344d, 0x43435349, 0x4343534d,
    0x43435352, 0x43475253, 0x434c4641, 0x434c4c43, 0x434d4e49, 0x43534141, 0x43534152, 0x43534454,
    0x4353574d, 0x43564144, 0x43564147, 0x43564d46, 0x43564d4b, 0x4356534d, 0x43565543, 0x43594448,
    0x4441454c, 0x44435343, 0x44484643, 0x44495658, 0x444f4344, 0x444f4355, 0x44564933, 0x454c4256,
    0x454c5257, 0x45565847, 0x46315657, 0x46365056, 0x46564d41, 0x47423432, 0x47444553, 0x4745504d,
    0x47455051, 0x474e504d, 0x47504a43, 0x47504a49, 0x47504a4c, 0x47504a4d, 0x47504a5a, 0x47504d58,
    0x4752304d, 0x4752324d, 0x4752344d, 0x4752384d, 0x47524c55, 0x47524d55, 0x47525155, 0x47564951,
    0x48535356, 0x48564443, 0x48564646, 0x485a534d, 0x49445844, 0x49474944, 0x49544c55, 0x49555641,
    0x4a445641, 0x4a4d4c53, 0x4a53544d, 0x4b315856, 0x4b324a4c, 0x4b435544, 0x4c393049, 0x4c393249,
    0x4c393449, 0x4c413049, 0x4c413249, 0x4c413449, 0x4c433049, 0x4c433249, 0x4c433449, 0x4c463049,
    0x4c463449, 0x4c47504a, 0x4c584956, 0x4d414857, 0x4d415243, 0x4d444956, 0x4d475844, 0x4d58564d,
    0x4d706148, 0x4e313036, 0x4f43455a, 0x4f434f4c, 0x4f4f5644, 0x50313036, 0x50313459, 0x504a4d4d,
    0x504a564d, 0x50504953, 0x50564d57, 0x5243534c, 0x52474241, 0x52474742, 0x524a4c43, 0x52504353,
    0x5334504d, 0x53444646, 0x53445553, 0x53454d4d, 0x5347414c, 0x534c4a4d, 0x53504238, 0x53564143,
    0x544d5948, 0x544e7464, 0x55575246, 0x55594648, 0x55595659, 0x56324d45, 0x56344d44, 0x56344d50,
    0x56344d53, 0x56424d5a, 0x56434946, 0x56444341, 0x56444c53, 0x5644564d, 0x56485045, 0x564c4a49,
    0x564d4357, 0x564d5834, 0x564e5559, 0x564e5955, 0x564f4547, 0x56534d55, 0x56555941, 0x56555943,
    0x56555949, 0x56574157, 0x56595559, 0x57415257, 0x57465646, 0x574f4e53, 0x58444c55, 0x58495658,
    0x584f4547, 0x58505356, 0x58514843, 0x58564944, 0x58657244, 0x59455247, 0x5947414d, 0x594e5955,
    0x59555956, 0x59565955, 0x59706148, 0x5a455650, 0x5a544456, 0x61343662, 0x61356478, 0x61706a6d,
    0x61707464, 0x61766468, 0x61766478, 0x617a7072, 0x62356478, 0x62706a6d, 0x62766478, 0x63356478,
    0x63617264, 0x63637374, 0x63696c66, 0x636c636e, 0x636e4d56, 0x63766463, 0x63766470, 0x63766478,
    0x6376736d, 0x64356478, 0x64686478, 0x64687374, 0x64687664, 0x64697663, 0x646f6369, 0x64737664,
    0x64766478, 0x65356478, 0x65687664, 0x656c726d, 0x65766478, 0x66356478, 0x66666974, 0x66696c73,
    0x66766478, 0x67303152, 0x67363162, 0x67627862, 0x6765706a, 0x6765706d, 0x676c6178, 0x676c7661,
    0x67727862, 0x68347061, 0x68637061, 0x68645641, 0x68727061, 0x69717673, 0x6b303152, 0x6b426b51,
    0x6c737664, 0x6d616877, 0x6d617263, 0x6d76736c, 0x6e33786d, 0x6e34786d, 0x6e357664, 0x6e35786d,
    0x6e525641, 0x6e617858, 0x6e637061, 0x6e645641, 0x6e695641, 0x6e727061, 0x6f47795a, 0x6f637061,
    0x6f656874, 0x70316961, 0x7033786d, 0x7034786d, 0x70356961, 0x70357664, 0x7035786d, 0x70637664,
    0x70687664, 0x706c7664, 0x706d5641, 0x70707664, 0x70725641, 0x70755641, 0x71316961, 0x71356961,
    0x71687664, 0x72383462, 0x726f7478, 0x72707a61, 0x73637061, 0x73637664, 0x73697664, 0x73767579,
    0x746c7870, 0x746e7464, 0x7631706d, 0x76323130, 0x76323161, 0x7632706d, 0x7634706d, 0x76617664,
    0x76645641, 0x7667706d, 0x76797862, 0x77726471, 0x78315641, 0x78347061, 0x78766961, 0x79757632,
};

fn isVideoTag(format: u32) bool {
    var lo: usize = 0;
    var hi: usize = video_tags.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (video_tags[mid] == format) return true;
        if (video_tags[mid] < format) lo = mid + 1 else hi = mid;
    }
    return false;
}

/// `ff_ac3_channel_layout_tab`.
const ac3_layouts = [8]u64{ 0x3, 0x4, 0x3, 0x7, 0x103, 0x107, 0x603, 0x607 };
const low_frequency: u64 = 0x8;
/// `AV_AUDIO_SERVICE_TYPE_KARAOKE`.
const karaoke: u8 = 8;

// ---- Tracks ----

/// `AVMediaType` of a track.
pub const Media = enum { audio, video, data, subtitle };

const Stts = struct { count: u32, duration: u32 };
const Ctts = struct { count: u32, offset: i32 };
const Stsc = struct { first: i32, count: i32, id: i32 };
const Elst = struct { duration: i64, time: i64 };
const Sbgp = struct { count: u32, index: u32 };
/// `MOVTimeToSample`.
const Tts = struct { count: u32 = 0, offset: i32 = 0, duration: u32 = 0 };

/// An `AVIndexEntry`.
pub const IndexEntry = struct {
    pos: i64,
    timestamp: i64,
    size: u32,
    key: bool,
};

/// A track: FFmpeg's `AVStream` with its codec parameters and the mov
/// demuxer's `MOVStreamContext`.
pub const Track = struct {
    // AVStream.
    /// `st->id`: the track id, -1 before `tkhd`.
    id: i32 = -1,
    /// `sc->id`, which a chapter reference names: the track id, 0 before
    /// `tkhd`.
    sc_id: i32 = 0,
    /// `avformat_new_stream`'s 1/90000 until the track's time scale is
    /// known.
    time_base: rational.Rational = .{ .num = 1, .den = 90000 },
    /// `AV_DISPOSITION_DEFAULT` from `tkhd`, and the service type's.
    disposition: u32 = 0,
    duration: i64 = nopts,
    start_time: i64 = nopts,
    nb_frames: i64 = 0,
    /// `AVDISCARD_ALL`: a data track whose samples all last 0.
    discard: bool = false,
    tags: metadata.Dictionary = .empty,
    // Codec parameters.
    media: Media = .data,
    codec: Codec = .none,
    codec_tag: u32 = 0,
    sample_rate: i64 = 0,
    /// The channel count as the sample description gave it, and the layout.
    channels: i64 = 0,
    layout: ?Layout = null,
    bits_per_coded_sample: i64 = 0,
    frame_size: i64 = 0,
    block_align: i64 = 0,
    bit_rate: i64 = 0,
    initial_padding: i64 = 0,
    seek_preroll: i64 = 0,
    /// `codecpar->extradata`.
    extradata: ?[]u8 = null,
    /// `need_parsing`: FFmpeg's parser runs on the track's packets.
    parse_full: bool = false,
    /// `AV_AUDIO_SERVICE_TYPE` side data from `dac3` or `dec3`.
    service_type: ?u8 = null,
    /// `AV_PKT_DATA_REPLAYGAIN` coded side data from the format's tags.
    replaygain: ?mp3.ReplayGain = null,
    /// `sti->skip_samples` at the start: an AAC track's initial padding.
    skip_samples: i64 = 0,
    // MOVStreamContext.
    time_scale: i32 = 0,
    stsd_version: u8 = 0,
    stsd_count: u32 = 0,
    /// Each sample description's extradata; null before `stsd`.
    stsd_extradata: ?[]?[]u8 = null,
    last_stsd_index: i32 = 0,
    pseudo_stream_id: i32 = 0,
    dref_id: i32 = 1,
    format: u32 = 0,
    audio_cid: i16 = 0,
    samples_per_frame: u32 = 0,
    bytes_per_frame: u32 = 0,
    sample_size: u32 = 0,
    stsz_sample_size: u32 = 0,
    sample_count: u32 = 0,
    sample_sizes: std.ArrayList(u32) = .empty,
    data_size: i64 = 0,
    chunk_offsets: std.ArrayList(i64) = .empty,
    stts: std.ArrayList(Stts) = .empty,
    stts_count: u32 = 0,
    ctts: std.ArrayList(Ctts) = .empty,
    ctts_count: u32 = 0,
    dts_shift: i32 = 0,
    stsc: std.ArrayList(Stsc) = .empty,
    keyframes: std.ArrayList(u32) = .empty,
    keyframe_absent: bool = false,
    stps: std.ArrayList(u32) = .empty,
    sdtp: std.ArrayList(u8) = .empty,
    rap_group: std.ArrayList(Sbgp) = .empty,
    elst: std.ArrayList(Elst) = .empty,
    duration_for_fps: i64 = 0,
    nb_frames_for_fps: i32 = 0,
    /// The index (`index_entries`) and the per-sample time-to-sample
    /// entries `mov_merge_tts_data` makes.
    index: std.ArrayList(IndexEntry) = .empty,
    tts: std.ArrayList(Tts) = .empty,
    /// `tts_count`: the entries the tables filled.
    tts_count: u32 = 0,
    /// `chunk_count`, which outlives the chunk offsets.
    chunk_count: u32 = 0,
    /// The discard window `mov_finalize_packet` sets at the last packet
    /// (FFStream's), 0 when unset.
    first_discard_sample: i64 = 0,
    last_discard_sample: i64 = 0,
    // Reading state.
    current_sample: u32 = 0,
    tts_index: u32 = 0,
    tts_sample: u32 = 0,
    stsc_index: u32 = 0,
    stsc_sample: u32 = 0,
    /// The decoder FFmpeg's read-ahead opens (decided at open, from the
    /// codec and its extradata).
    decoder: demux.Decoder = .none,

    fn deinit(t: *Track, gpa: std.mem.Allocator) void {
        t.tags.deinit(gpa);
        if (t.extradata) |e| gpa.free(e);
        if (t.stsd_extradata) |list| {
            for (list) |e| if (e) |b| gpa.free(b);
            gpa.free(list);
        }
        inline for (.{ "sample_sizes", "chunk_offsets", "stts", "ctts", "stsc", "keyframes", "stps", "sdtp", "rap_group", "elst", "index", "tts" }) |field| {
            @field(t, field).deinit(gpa);
        }
    }

    /// The channel count the codec parameters hold.
    pub fn channelCount(t: *const Track) i64 {
        if (t.layout) |l| return l.channelCount();
        return t.channels;
    }

    fn setChannels(t: *Track, count: i64) void {
        t.channels = count;
        t.layout = null;
    }

    fn setLayout(t: *Track, layout: Layout) void {
        t.channels = layout.channelCount();
        t.layout = layout;
    }

    /// `ff_get_extradata` / `ff_alloc_extradata`: the old extradata freed,
    /// the new one owned.
    fn replaceExtradata(t: *Track, gpa: std.mem.Allocator, data: ?[]u8) void {
        if (t.extradata) |e| gpa.free(e);
        t.extradata = data;
    }

    fn extradataLen(t: *const Track) usize {
        return if (t.extradata) |e| e.len else 0;
    }

    /// mov_read_custom's iTunSMPB: the priming as the initial padding, and
    /// the remainder as the discard window at the end, in samples.
    fn applySmpb(t: *Track, counts: mp3.SmpbCounts) void {
        // codecpar->sample_rate, an int.
        const samples: rational.Rational = .{ .num = 1, .den = @truncate(t.sample_rate) };
        if (counts.priming > 0 and counts.priming < 16384) {
            // An int field.
            t.initial_padding = @as(i32, @truncate(rational.rescaleQ(counts.priming, t.time_base, samples)));
        }
        if (counts.remainder > 0) {
            const duration = rational.rescaleQ(t.duration, t.time_base, samples);
            const remainder = rational.rescaleQ(counts.remainder, t.time_base, samples);
            const total = rational.rescaleQ(counts.samples, t.time_base, samples);
            if (duration > remainder and duration > total) {
                t.first_discard_sample = duration - remainder;
                t.last_discard_sample = duration;
            }
        }
    }
};

const Atom = struct { type: u32, size: i64 };

/// The `free` box contents FFmpeg treats as a fragment index hint.
const anevia = "Anevia\x1A\x1A";

pub const Demuxer = struct {
    /// The error set demux.zig's layer returns.
    pub const ReadError = Error;

    gpa: std.mem.Allocator,
    in: Input,
    limits: Limits,
    tracks: std.ArrayList(Track) = .empty,
    /// The format's tags (`ftyp`, `mvhd`).
    tags: metadata.Dictionary = .empty,
    isom: bool = false,
    found_moov: bool = false,
    found_mdat: bool = false,
    moov_retry: bool = false,
    /// `mvhd`'s time scale.
    time_scale: i32 = 0,
    trak_index: ?usize = null,
    atom_depth: u32 = 0,
    next_root_atom: i64 = 0,
    /// `use_mfra_for` set by a `free` box of Anevia's.
    use_mfra: bool = false,
    found_hdlr_mdta: bool = false,
    /// libavformat's `data_offset`: where the header parse left the input.
    data_offset: i64 = 0,
    /// The packet returned last.
    current: std.ArrayList(u8) = .empty,
    new_extradata: ?[]const u8 = null,
    // Metadata (T33a2).
    /// Inside `ilst`: tags are iTunes `data` atoms.
    itunes_metadata: bool = false,
    /// `keys`' names (index 0 none, a key of another namespace none);
    /// empty before a `keys` box.
    meta_keys: std.ArrayList(?[]u8) = .empty,
    /// From an `encoder` tag of HandBrake's: its version.
    handbrake_version: i32 = 0,
    /// `chap` references: the chapter tracks' ids.
    chapter_tracks: std.ArrayList(i32) = .empty,
    chapters: chapters_mod.Chapters = .{},
    /// An ISML manifest's bit rates, by stream.
    bitrates: std.ArrayList(i64) = .empty,
    /// The attached pictures FFmpeg made of `covr` atoms (streams after
    /// the tracks, not kept).
    pictures: u32 = 0,

    /// The demuxer on a source that cannot seek (a pipe): a `moov` after
    /// `mdat` is `UnsupportedStreamingSize`.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) Error!*Demuxer {
        return initWith(gpa, reader, null, limits);
    }

    /// The demuxer on a seekable source read from its start (a file).
    pub fn initSeekable(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: seek.Seeker, limits: Limits) Error!*Demuxer {
        return initWith(gpa, reader, seeker, limits);
    }

    fn initWith(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker, limits: Limits) Error!*Demuxer {
        const d = try gpa.create(Demuxer);
        errdefer gpa.destroy(d);
        const start: i64 = if (seeker) |sk| std.math.cast(i64, sk.position()) orelse return error.IoFailure else 0;
        const size: ?i64 = if (seeker) |sk| if (sk.size()) |n| std.math.cast(i64, n) orelse std.math.maxInt(i64) else null else null;
        d.* = .{ .gpa = gpa, .in = .{ .reader = reader, .seeker = seeker, .pos = start, .under = start, .size = size }, .limits = limits };
        errdefer d.deinitFields();
        try d.readHeader();
        return d;
    }

    fn deinitFields(d: *Demuxer) void {
        for (d.tracks.items) |*t| t.deinit(d.gpa);
        d.tracks.deinit(d.gpa);
        d.tags.deinit(d.gpa);
        for (d.meta_keys.items) |k| if (k) |b| d.gpa.free(b);
        d.meta_keys.deinit(d.gpa);
        d.chapter_tracks.deinit(d.gpa);
        d.chapters.deinit(d.gpa);
        d.bitrates.deinit(d.gpa);
        d.in.deinit(d.gpa);
        d.current.deinit(d.gpa);
    }

    pub fn deinit(d: *Demuxer) void {
        d.deinitFields();
        d.gpa.destroy(d);
    }

    /// The last stream when it is a track: none before the first, or
    /// after an attached picture, whose context FFmpeg's boxes would act
    /// on (the port keeps none for it).
    fn lastTrack(d: *Demuxer) ?*Track {
        if (d.tracks.items.len == 0 or d.pictures > 0) return null;
        return &d.tracks.items[d.tracks.items.len - 1];
    }

    /// FFmpeg has a stream (`nb_streams >= 1`): a track or a picture.
    fn hasStream(d: *const Demuxer) bool {
        return d.tracks.items.len > 0 or d.pictures > 0;
    }

    /// `av_dict_set` of a C string: the value ends at its first NUL.
    fn putTag(gpa: std.mem.Allocator, dict: *metadata.Dictionary, key: []const u8, value: []const u8, dup: metadata.Duplicates) Error!void {
        const end = std.mem.findScalar(u8, value, 0) orelse value.len;
        dict.put(gpa, key, value[0..end], dup) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidTag => unreachable, // the value is cut at its NUL; the keys are literals
        };
    }

    // ---- The header ----

    /// mov_read_header up to the streams' parameters, then its
    /// post-processing.
    fn readHeader(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const root: Atom = .{ .type = tag("root"), .size = d.in.size orelse std.math.maxInt(i64) };
        while (true) {
            if (d.moov_retry) _ = try d.in.seekTo(gpa, 0);
            try d.readDefault(root);
            if (d.in.seekable() and !d.found_moov and !d.moov_retry) {
                d.moov_retry = true;
                continue;
            }
            break;
        }
        if (!d.found_moov) return error.InvalidMov;
        d.data_offset = d.in.pos;
        try d.finishHeader();
    }

    /// mov_read_default.
    fn readDefault(d: *Demuxer, atom_in: Atom) Error!void {
        const gpa = d.gpa;
        if (d.atom_depth > 10) return error.InvalidMov;
        d.atom_depth += 1;
        defer d.atom_depth -= 1;
        var atom = atom_in;
        if (atom.size < 0) atom.size = std.math.maxInt(i64);
        var total_size: i64 = 0;
        while (total_size <= atom.size - 8) {
            var a: Atom = .{ .size = try d.in.rb32(gpa), .type = try d.in.rl32(gpa) };
            if (try d.in.feof(gpa)) break;
            if (((a.type == tag("free") and d.moov_retry) or a.type == tag("hoov")) and a.size >= 8) {
                _ = try d.in.skipBy(gpa, 4);
                const inner = try d.in.rl32(gpa);
                if (try d.in.feof(gpa)) break;
                _ = try d.in.skipBy(gpa, -8);
                if (inner == tag("mvhd") or inner == tag("cmov")) a.type = tag("moov");
            }
            if (atom.type != tag("root") and atom.type != tag("moov")) {
                if (a.type == tag("trak") or a.type == tag("mdat")) {
                    // "Broken file, trak/mdat not at top-level".
                    _ = try d.in.skipBy(gpa, -8);
                    return;
                }
            }
            total_size += 8;
            if (a.size == 1 and total_size + 8 <= atom.size) {
                // A 64-bit size; FFmpeg's int64_t takes the unsigned value
                // as it is (notes.md "MP4 demuxing").
                a.size = @as(i64, @bitCast(try d.in.rb64(gpa))) -% 8;
                total_size += 8;
            }
            if (a.size == 0) a.size = atom.size - total_size + 8;
            if (a.size < 0) break;
            a.size -= 8;
            if (a.size < 0) break;
            a.size = @min(a.size, atom.size - total_size);

            const start_pos = d.in.pos;
            const parsed = try d.parseAtom(a, atom.type);
            if (!parsed) {
                _ = try d.in.skipBy(gpa, a.size);
            } else {
                if (d.found_moov and d.found_mdat and a.size <= std.math.maxInt(i64) - start_pos and
                    (!d.in.seekable() or start_pos + a.size == d.in.size))
                {
                    if (!d.in.seekable()) d.next_root_atom = start_pos + a.size;
                    return;
                }
                const left = a.size - d.in.pos + start_pos;
                if (left > 0) {
                    _ = try d.in.skipBy(gpa, left);
                } else if (left < 0) {
                    // "overread end of atom": back to its end.
                    _ = try d.in.skipBy(gpa, left);
                }
            }
            total_size += a.size;
        }
        if (total_size < atom.size and atom.size < 0x7ffff) _ = try d.in.skipBy(gpa, atom.size - total_size);
    }

    /// The parse table's entry for `a` in a box of type `parent`, run;
    /// false when FFmpeg's table has none and the box is skipped.
    fn parseAtom(d: *Demuxer, a: Atom, parent: u32) Error!bool {
        const t = a.type;
        switch (t) {
            tag("moov") => try d.readMoov(a),
            tag("trak") => try d.readTrak(a),
            tag("mdia"), tag("minf"), tag("stbl"), tag("edts"), tag("dinf"), tag("tref") => try d.readDefault(a),
            tag("ftyp") => try d.readFtyp(a),
            tag("mvhd") => try d.readMvhd(),
            tag("tkhd") => try d.readTkhd(),
            tag("mdhd") => try d.readMdhd(),
            tag("hdlr") => try d.readHdlr(a),
            tag("stsd") => try d.readStsd(a),
            tag("stts") => try d.readStts(),
            tag("ctts") => try d.readCtts(),
            tag("stsc") => try d.readStsc(a),
            tag("stsz"), tag("stz2") => try d.readStsz(a),
            tag("stco"), tag("co64") => try d.readStco(a),
            tag("stss") => try d.readStss(),
            tag("stps") => try d.readStps(),
            tag("sdtp") => try d.readSdtp(a),
            tag("sgpd") => try d.readSgpd(a),
            tag("sbgp") => try d.readSbgp(),
            tag("elst") => try d.readElst(a),
            tag("dref") => try d.readDref(a),
            tag("mdat") => {
                // A moov after mdat is read by seeking back to the samples.
                if (a.size != 0 and !d.found_moov and !d.in.seekable()) return error.UnsupportedStreamingSize;
                d.readMdat(a);
            },
            tag("wide") => try d.readWide(a),
            tag("free") => try d.readFree(a),
            tag("esds") => try d.readEsds(),
            tag("wave") => try d.readWave(a),
            tag("alac") => try d.readAlac(a),
            tag("glbl"), tag("avcC"), tag("hvcC"), tag("vvcC"), tag("av1C"), tag("evcC"), tag("lvcC"), tag("apvC") => try d.readGlbl(a),
            tag("dfLa") => try d.readDfla(a),
            tag("dOps") => try d.readDops(a),
            tag("dac3") => try d.readDac3(),
            tag("dec3") => try d.readDec3(a),
            tag("chan") => try d.readChan(a),
            tag("enda") => try d.readEnda(),
            tag("srat") => try d.readSrat(a),
            tag("frma") => try d.readFrma(),
            // Metadata and chapters (T33a2).
            tag("udta") => try d.readDefault(a),
            tag("meta") => try d.readMeta(a),
            tag("ilst") => try d.readIlst(a),
            tag("uuid") => try d.readUuid(a),
            tag("chpl") => try d.readChpl(a),
            tag("----") => try d.readCustom(a),
            tag("chap") => try d.readChap(a),
            tag("kind") => try d.readKind(a),
            // The rest of FFmpeg's parse table: fragments (T33c),
            // compressed headers, encryption, images, timecodes, track
            // groups, and the boxes of video sample entries. Refused.
            tag("moof"), tag("mvex"), tag("traf"), tag("tfdt"), tag("tfhd"), tag("trex"), tag("trun"), tag("sidx"), tag("cmov"), tag("adrm"), tag("sinf"), tag("senc"), tag("saiz"), tag("saio"), tag("pssh"), tag("schm"), tag("schi"), tag("tenc"), tag("iloc"), tag("pitm"), tag("auxC"), tag("idat"), tag("imir"), tag("iref"), tag("ispe"), tag("irot"), tag("iprp"), tag("iinf"), tag("tmcd"), tag("cdsc"), tag("rndr"), tag("sbas"), tag("vdep"), tag("ACLR"), tag("APRG"), tag("AALP"), tag("ARES"), tag("avss"), tag("colr"), tag("DpxE"), tag("fiel"), tag("jp2h"), tag("SMI "), tag("pasp"), tag("clap"), tag("strf"), tag("ddts"), tag("wfex"), tag("chnl"), tag("dvc1"), std.mem.readInt(u32, &[4]u8{ 'C', 'i', 'n', 0x8e }, .little), tag("st3d"), tag("sv3d"), tag("vexu"), tag("hfov"), tag("dmlp"), tag("SmDm"), tag("CoLL"), tag("vpcC"), tag("mdcv"), tag("clli"), tag("dvcC"), tag("dvvC"), tag("dvwC"), tag("hvcE"), tag("SA3D"), tag("SAND"), tag("pcmC"), tag("amve"), tag("lhvC"), tag("mhaC"), tag("vmhd"), tag("iacb") => return error.UnsupportedFormat,
            else => {
                // A box of user data: a tag.
                if (parent == tag("udta") or parent == tag("ilst")) {
                    try d.udtaString(a);
                } else if (d.found_hdlr_mdta and parent == tag("meta") and t == tag("keys") and d.meta_keys.items.len == 0) {
                    try d.readKeys(a);
                } else return false;
            },
        }
        return true;
    }

    fn readMoov(d: *Demuxer, a: Atom) Error!void {
        if (d.found_moov) {
            // "Found duplicated MOOV Atom. Skipped it".
            _ = try d.in.skipBy(d.gpa, a.size);
            return;
        }
        try d.readDefault(a);
        d.found_moov = true;
    }

    fn readMdat(d: *Demuxer, a: Atom) void {
        if (a.size == 0) return; // "wrong one (MP4)"
        d.found_mdat = true;
    }

    fn readWide(d: *Demuxer, a: Atom) Error!void {
        if (a.size < 8) return;
        if (try d.in.rb32(d.gpa) != 0) {
            _ = try d.in.skipBy(d.gpa, a.size - 4);
            return;
        }
        const inner: Atom = .{ .type = try d.in.rl32(d.gpa), .size = a.size - 8 };
        if (inner.type != tag("mdat")) {
            _ = try d.in.skipBy(d.gpa, inner.size);
            return;
        }
        d.readMdat(inner);
    }

    fn readFree(d: *Demuxer, a: Atom) Error!void {
        if (a.size < 8) return;
        var content: [16]u8 = undefined;
        const n: usize = @intCast(@min(content.len, a.size));
        if (try d.in.read(d.gpa, content[0..n]) != n) return error.InvalidMov;
        if (!d.found_moov and !d.found_mdat and std.mem.eql(u8, content[0..8], anevia)) d.use_mfra = true;
    }

    fn readFtyp(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        var major: [4]u8 = undefined;
        if (try d.in.read(gpa, &major) != 4) return error.InvalidMov;
        // "Ignoring duplicate FTYP".
        if (d.tracks.items.len > 0) return;
        if (!std.mem.eql(u8, &major, "qt  ")) d.isom = true;
        try putTag(gpa, &d.tags, "major_brand", &major, .replace);
        const minor = try d.in.rb32(gpa);
        var buf: [10]u8 = undefined;
        try putTag(gpa, &d.tags, "minor_version", std.fmt.bufPrint(&buf, "{d}", .{minor}) catch unreachable, .replace);
        const size = a.size - 8;
        if (size < 0 or size == std.math.maxInt(i32)) return error.InvalidMov;
        if (size > d.limits.max_box_bytes) return error.LimitExceeded;
        const brands = try d.in.readOwned(gpa, @intCast(size)) orelse return error.InvalidMov;
        defer gpa.free(brands);
        try putTag(gpa, &d.tags, "compatible_brands", brands, .replace);
    }

    fn readMvhd(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const version = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        try d.creationTime(&d.tags, version);
        d.time_scale = @bitCast(try d.in.rb32(gpa));
        if (d.time_scale <= 0) d.time_scale = 1;
        if (version == 1) _ = try d.in.rb64(gpa) else _ = try d.in.rb32(gpa);
        _ = try d.in.rb32(gpa);
        _ = try d.in.rb16(gpa);
        _ = try d.in.skipBy(gpa, 10);
        for (0..9 + 7) |_| _ = try d.in.rb32(gpa);
    }

    /// mov_metadata_creation_time.
    fn creationTime(d: *Demuxer, dict: *metadata.Dictionary, version: u8) Error!void {
        const gpa = d.gpa;
        var time: i64 = undefined;
        if (version == 1) {
            time = @bitCast(try d.in.rb64(gpa));
            _ = try d.in.rb64(gpa);
            if (time < 0) return;
        } else {
            time = try d.in.rb32(gpa);
            _ = try d.in.rb32(gpa);
            if (time > 0 and time < 2082844800) time += 2082844800;
        }
        if (time == 0) return;
        time -= 2082844800;
        // "creation_time is not representable": time * 1000000 overflows.
        _ = std.math.mul(i64, time, 1_000_000) catch return;
        var buf: [40]u8 = undefined;
        try putTag(gpa, dict, "creation_time", formatTimestamp(&buf, time), .replace);
    }

    fn readTrak(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        if (d.tracks.items.len >= d.limits.max_tracks) return error.LimitExceeded;
        // A track after an attached picture: FFmpeg's streams would not be
        // the tracks in order (not modelled).
        if (d.pictures > 0) return error.UnsupportedFormat;
        try d.tracks.append(gpa, .{});
        const index = d.tracks.items.len - 1;
        d.trak_index = index;
        try d.readDefault(a);
        d.trak_index = null;
        const t = &d.tracks.items[index];
        // Subtitle tracks wait for the chapter references (finishHeader).
        if (t.media == .video) return error.UnsupportedFormat; // T33a3
        // An stsc of a track without samples, cleared.
        if (t.chunk_offsets.items.len == 0 and t.stts_count == 0 and t.stsc.items.len > 0) t.stsc.clearRetainingCapacity();
        switch (sanityChecks(t)) {
            0 => {},
            1 => return,
            else => return error.InvalidMov,
        }
        fixTimescale(t, d.time_scale);
        t.time_base = .{ .num = 1, .den = t.time_scale };
        try d.buildIndex(t);
        // A constant duration across `stts` keeps MP3 unparsed.
        if (t.codec == .mp3 and t.time_scale == t.sample_rate) {
            var constant = true;
            if (t.stts_count > 0 and t.tts.items.len > 1) {
                for (t.tts.items[1..]) |e| if (e.duration != t.tts.items[0].duration) {
                    constant = false;
                };
            }
            if (!constant) t.parse_full = true;
        }
        t.chunk_count = @intCast(t.chunk_offsets.items.len);
        // The tables FFmpeg frees here.
        inline for (.{ "chunk_offsets", "sample_sizes", "keyframes", "stps", "elst", "rap_group" }) |field| {
            @field(t, field).clearAndFree(gpa);
        }
    }

    fn readTkhd(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (t.id != -1) return error.InvalidMov;
        const version = try d.in.r8(gpa);
        const flags = try d.in.rb24(gpa);
        if (flags & 1 != 0) t.disposition |= 1;
        if (version == 1) {
            _ = try d.in.rb64(gpa);
            _ = try d.in.rb64(gpa);
        } else {
            _ = try d.in.rb32(gpa);
            _ = try d.in.rb32(gpa);
        }
        t.id = @bitCast(try d.in.rb32(gpa));
        t.sc_id = t.id;
        _ = try d.in.rb32(gpa);
        if (version == 1) _ = try d.in.rb64(gpa) else _ = try d.in.rb32(gpa);
        _ = try d.in.rb32(gpa);
        _ = try d.in.rb32(gpa);
        for (0..4) |_| _ = try d.in.rb16(gpa);
        for (0..9 + 2) |_| _ = try d.in.rb32(gpa);
    }

    fn readMdhd(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (t.time_scale != 0) return error.InvalidMov; // "Multiple mdhd?"
        const version = try d.in.r8(gpa);
        if (version > 1) return error.PatchWelcome;
        _ = try d.in.rb24(gpa);
        try d.creationTime(&t.tags, version);
        t.time_scale = @bitCast(try d.in.rb32(gpa));
        if (t.time_scale <= 0) t.time_scale = 1;
        if (version == 1) {
            const v = try d.in.rb64(gpa);
            t.duration = if (v == std.math.maxInt(u64)) 0 else @bitCast(v);
        } else {
            const v = try d.in.rb32(gpa);
            t.duration = if (v == std.math.maxInt(u32)) 0 else v;
        }
        var buf: [3]u8 = undefined;
        if (languageCode(try d.in.rb16(gpa), &buf)) |lang| try putTag(gpa, &t.tags, "language", lang, .replace);
        _ = try d.in.rb16(gpa);
    }

    fn readHdlr(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        _ = try d.in.rl32(gpa);
        const ty = try d.in.rl32(gpa);
        if (d.trak_index == null) {
            if (ty == tag("mdta")) d.found_hdlr_mdta = true;
            return;
        }
        const t = d.lastTrack() orelse return;
        if (ty == tag("vide")) {
            t.media = .video;
        } else if (ty == tag("soun")) {
            t.media = .audio;
        } else if (ty == tag("m1a ")) {
            t.codec = .mp2;
        } else if (ty == tag("subp") or ty == tag("clcp")) {
            t.media = .subtitle;
        }
        for (0..3) |_| _ = try d.in.rb32(gpa);
        const title_size = a.size - 24;
        if (title_size <= 0) return;
        if (title_size > std.math.maxInt(i32)) return error.InvalidMov;
        if (title_size > d.limits.max_box_bytes) return error.LimitExceeded;
        const title = try d.in.readOwned(gpa, @intCast(title_size)) orelse return error.InvalidMov;
        defer gpa.free(title);
        if (title[0] == 0) return;
        // A Pascal string in a QuickTime file.
        const off: usize = @intFromBool(!d.isom and title[0] == title_size - 1);
        try putTag(gpa, &t.tags, "handler_name", title[off..], .keep_existing);
    }

    // ---- Sample descriptions ----

    fn readStsd(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (t.stsd_extradata != null) return error.InvalidMov; // "Duplicate stsd"
        t.stsd_version = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const entries: i32 = @bitCast(try d.in.rb32(gpa));
        if (entries <= 0 or entries > @divTrunc(a.size, 8) or entries > 1024) return error.InvalidMov;
        const list = try gpa.alloc(?[]u8, @intCast(entries));
        @memset(list, null);
        t.stsd_extradata = list;
        d.readStsdEntries(@intCast(entries)) catch |err| {
            // The entries' extradata freed, the count reset.
            const tr = d.lastTrack().?;
            if (tr.stsd_extradata) |l| {
                for (l) |e| if (e) |b| gpa.free(b);
                gpa.free(l);
            }
            tr.stsd_extradata = null;
            tr.stsd_count = 0;
            return err;
        };
        const tr = d.lastTrack().?;
        // The primary extradata: the first description's.
        const first = tr.stsd_extradata.?[0];
        const copy: ?[]u8 = if (first) |b| try gpa.dupe(u8, b) else null;
        tr.replaceExtradata(gpa, copy);
        try d.finalizeStsdCodec(tr);
    }

    /// ff_mov_read_stsd_entries.
    fn readStsdEntries(d: *Demuxer, entries: u32) Error!void {
        const gpa = d.gpa;
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            var dref_id: i32 = 1;
            const start_pos = d.in.pos;
            const size: i64 = try d.in.rb32(gpa);
            const format = try d.in.rl32(gpa);
            if (size >= 16) {
                _ = try d.in.rb32(gpa);
                _ = try d.in.rb16(gpa);
                dref_id = try d.in.rb16(gpa);
            } else if (size <= 7) {
                return error.InvalidMov;
            }
            var t = d.lastTrack().?;
            if (skipMultipleStsd(t.codec_tag, format)) {
                _ = try d.in.skipBy(gpa, size - (d.in.pos - start_pos));
                t.stsd_count += 1;
                continue;
            }
            t.pseudo_stream_id = if (t.codec_tag != 0) -1 else @intCast(i);
            t.dref_id = dref_id;
            t.format = format;
            const id = try codecFromTag(t, format);
            t.codec = id;
            switch (t.media) {
                .video => return error.UnsupportedFormat, // T33a3
                // mov_parse_stsd_subtitle: the description's rest is its
                // extradata (none for `mp4s`, which holds an esds, or
                // ISMV's `dfxp`).
                .subtitle => if (t.codec_tag != tag("mp4s") and t.codec_tag != tag("dfxp")) {
                    try d.readGlbl(.{ .type = 0, .size = size - (d.in.pos - start_pos) });
                },
                .audio => {
                    try d.parseStsdAudio(t);
                    if (t.sample_rate < 0) return error.InvalidMov;
                    if (t.channelCount() < 0) return error.InvalidMov;
                },
                .data => {
                    if (t.codec_tag == tag("tmcd") or t.codec == .none and t.codec_tag == tag("it35")) return error.UnsupportedFormat;
                    _ = try d.in.skipBy(gpa, size - (d.in.pos - start_pos));
                },
            }
            // The boxes after the description (wave, esds, alac, chan...).
            const rest: Atom = .{ .type = tag("stsd"), .size = size - (d.in.pos - start_pos) };
            if (rest.size > 8) {
                try d.readDefault(rest);
            } else if (rest.size > 0) {
                _ = try d.in.skipBy(gpa, rest.size);
            }
            t = d.lastTrack().?;
            if (t.extradata) |e| {
                // The description's extradata moves to its slot.
                const list = t.stsd_extradata.?;
                if (list[i]) |old| gpa.free(old);
                list[i] = e;
                t.extradata = null;
            }
            t.stsd_count += 1;
        }
        if (d.in.eof) return error.Truncated; // "reached eof, corrupted STSD atom"
    }

    /// mov_parse_stsd_audio.
    fn parseStsdAudio(d: *Demuxer, t: *Track) Error!void {
        const gpa = d.gpa;
        const version = try d.in.rb16(gpa);
        if (d.isom) {
            _ = try d.in.skipBy(gpa, 6);
        } else {
            _ = try d.in.rb16(gpa);
            const vendor = try d.in.rl32(gpa);
            var buf: [32]u8 = undefined;
            try putTag(gpa, &t.tags, "vendor_id", fourccString(&buf, vendor), .replace);
        }
        t.setChannels(try d.in.rb16(gpa));
        t.bits_per_coded_sample = try d.in.rb16(gpa);
        t.audio_cid = @bitCast(try d.in.rb16(gpa));
        _ = try d.in.rb16(gpa);
        t.sample_rate = (try d.in.rb32(gpa)) >> 16;
        const qt_brand = if (d.tags.get("compatible_brands")) |brands| std.mem.find(u8, brands, "qt  ") != null else false;
        if (!d.isom or qt_brand or (t.stsd_version == 0 and version > 0)) {
            if (version == 1) {
                t.samples_per_frame = try d.in.rb32(gpa);
                _ = try d.in.rb32(gpa);
                t.bytes_per_frame = try d.in.rb32(gpa);
                _ = try d.in.rb32(gpa);
            } else if (version == 2) {
                _ = try d.in.rb32(gpa);
                const rate: f64 = @bitCast(try d.in.rb64(gpa));
                if (rate < 0 or rate > std.math.maxInt(i32) or std.math.isNan(rate)) return error.InvalidMov;
                // In [0, INT_MAX]: the conversion truncates as C's does.
                t.sample_rate = @trunc(rate);
                t.setChannels(@as(i32, @bitCast(try d.in.rb32(gpa))));
                _ = try d.in.rb32(gpa);
                t.bits_per_coded_sample = @as(i32, @bitCast(try d.in.rb32(gpa)));
                const flags = try d.in.rb32(gpa);
                t.bytes_per_frame = try d.in.rb32(gpa);
                t.samples_per_frame = try d.in.rb32(gpa);
                if (t.codec_tag == tag("lpcm")) t.codec = lpcmCodec(t.bits_per_coded_sample, flags);
            }
            if (version == 0 or (version == 1 and t.audio_cid != -2)) {
                // "can't correctly handle variable sized packet as audio unit"
                if (t.codec == .mp2 or t.codec == .mp3) t.parse_full = true;
            }
        }
        if (t.format == 0) {
            if (t.bits_per_coded_sample == 8) {
                t.codec = try codecFromTag(t, tag("raw "));
            } else if (t.bits_per_coded_sample == 16) {
                t.codec = try codecFromTag(t, tag("twos"));
            }
        }
        switch (t.codec) {
            .pcm_s8, .pcm_u8 => if (t.bits_per_coded_sample == 16) {
                t.codec = .pcm_s16be;
            },
            .pcm_s16le, .pcm_s16be => {
                const be = t.codec == .pcm_s16be;
                switch (t.bits_per_coded_sample) {
                    8 => t.codec = .pcm_s8,
                    24 => t.codec = if (be) .pcm_s24be else .pcm_s24le,
                    32 => t.codec = if (be) .pcm_s32be else .pcm_s32le,
                    else => {},
                }
            },
            // The values for the old format before stsd version 1.
            .mace3 => {
                t.samples_per_frame = 6;
                t.bytes_per_frame = @truncate(@as(u64, @bitCast(2 *% t.channelCount())));
            },
            .mace6 => {
                t.samples_per_frame = 6;
                t.bytes_per_frame = @truncate(@as(u64, @bitCast(t.channelCount())));
            },
            .adpcm_ima_qt => {
                t.samples_per_frame = 64;
                t.bytes_per_frame = @truncate(@as(u64, @bitCast(34 *% t.channelCount())));
            },
            .gsm => {
                t.samples_per_frame = 160;
                t.bytes_per_frame = 33;
            },
            else => {},
        }
        const bps = t.codec.bitsPerSample();
        // `(bits >> 3) * (uint64_t)channels <= INT_MAX`; a negative count
        // is a huge unsigned one.
        const channels_u: u64 = @bitCast(t.channelCount());
        if (bps != 0) {
            const product, const overflow = @mulWithOverflow(@as(u64, bps >> 3), channels_u);
            if (overflow == 0 and product <= std.math.maxInt(i32)) {
                t.bits_per_coded_sample = bps;
                t.sample_size = @intCast(product);
            }
        }
    }

    /// mov_finalize_stsd_codec.
    fn finalizeStsdCodec(d: *Demuxer, t: *Track) Error!void {
        _ = d;
        if (t.media == .audio and t.sample_rate == 0 and t.time_scale > 1) t.sample_rate = t.time_scale;
        switch (t.codec) {
            .qcelp => {
                t.setLayout(Layout.mono);
                if (t.codec_tag != tag("Qclp")) t.sample_rate = 8000;
                t.samples_per_frame = 160;
                if (t.bytes_per_frame == 0) t.bytes_per_frame = 35;
            },
            .amr_nb => {
                t.setLayout(Layout.mono);
                t.sample_rate = 8000;
            },
            .amr_wb => {
                t.setLayout(Layout.mono);
                t.sample_rate = 16000;
            },
            .mp2, .mp3 => t.media = .audio,
            .gsm, .ilbc, .mace3, .mace6, .qdm2 => t.block_align = t.bytes_per_frame,
            .alac => if (t.extradata) |e| if (e.len == 36) {
                const count = e[21];
                if (t.channelCount() != count) t.setChannels(count);
                t.sample_rate = std.mem.readInt(i32, e[32..36], .big);
            },
            .ac3, .eac3 => t.parse_full = true,
            else => {},
        }
    }

    // ---- Codec configuration boxes ----

    /// ff_get_extradata into the last track: `size` bytes read, else
    /// FFmpeg's AVERROR_INVALIDDATA (its extradata freed).
    fn getExtradata(d: *Demuxer, t: *Track, size: i64) Error!void {
        if (size < 0 or size >= std.math.maxInt(i32) - 64) return error.InvalidMov; // EINVAL
        if (size > d.limits.max_box_bytes) return error.LimitExceeded;
        t.replaceExtradata(d.gpa, null);
        const data = try d.in.readOwned(d.gpa, @intCast(size)) orelse return error.InvalidMov;
        t.replaceExtradata(d.gpa, data);
    }

    /// ff_mov_read_esds and ff_mp4_read_dec_config_descr.
    fn readEsds(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        _ = try d.in.rb32(gpa);
        if ((try d.readDescr()).tag == 3) {
            // ff_mp4_parse_es_descr.
            _ = try d.in.rb16(gpa);
            const flags = try d.in.r8(gpa);
            if (flags & 0x80 != 0) _ = try d.in.rb16(gpa);
            if (flags & 0x40 != 0) _ = try d.in.skipBy(gpa, try d.in.r8(gpa));
            if (flags & 0x20 != 0) _ = try d.in.rb16(gpa);
        } else {
            _ = try d.in.rb16(gpa);
        }
        if ((try d.readDescr()).tag != 4) return;
        const object_type = try d.in.r8(gpa);
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        _ = try d.in.rb32(gpa);
        t.bit_rate = try d.in.rb32(gpa);
        const id = objectTypeCodec(object_type);
        if (id != .none) t.codec = id;
        const descr = try d.readDescr();
        if (descr.tag != 5) return;
        // No decoder specific info for MPEG-1 or MPEG-2 audio.
        if (object_type == 0x69 or object_type == 0x6b) return;
        if (descr.len == 0 or descr.len > 1 << 30) return error.InvalidMov;
        try d.getExtradata(t, descr.len);
        if (t.codec != .aac) return;
        const parsed = mpeg4audio.parse(t.extradata.?, true) catch return error.InvalidMov;
        const cfg = parsed.config;
        if (cfg.channels != t.channelCount()) t.setChannels(cfg.channels);
        if (cfg.object_type == 29 and cfg.sampling_index < 3) {
            // The old mp3on4 draft.
            t.sample_rate = mpegaudio.freq_tab[@intCast(cfg.sampling_index)];
        } else if (cfg.ext_sample_rate != 0) {
            t.sample_rate = cfg.ext_sample_rate;
        } else {
            t.sample_rate = cfg.sample_rate;
        }
        switch (cfg.object_type) {
            mpeg4audio.aot.aac_main, mpeg4audio.aot.aac_lc, mpeg4audio.aot.aac_ssr, mpeg4audio.aot.aac_ltp, mpeg4audio.aot.er_aac_lc, mpeg4audio.aot.er_aac_ld, mpeg4audio.aot.er_aac_eld, mpeg4audio.aot.usac => t.frame_size = cfg.frame_length,
            else => {},
        }
        // mp4_audio_types.
        t.codec = switch (cfg.object_type) {
            29, 32, 33, 34 => .mp3on4,
            36 => .mp4als,
            else => .aac,
        };
    }

    /// ff_mp4_read_descr: a tag and the length after it (at most four
    /// bytes of seven bits).
    fn readDescr(d: *Demuxer) Error!struct { tag: u8, len: i64 } {
        const t = try d.in.r8(d.gpa);
        var len: i64 = 0;
        for (0..4) |_| {
            const c = try d.in.r8(d.gpa);
            len = (len << 7) | (c & 0x7f);
            if (c & 0x80 == 0) break;
        }
        return .{ .tag = t, .len = len };
    }

    fn readWave(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (a.size > 1 << 30) return error.InvalidMov;
        switch (t.codec) {
            .qdm2, .qdmc, .speex => return d.getExtradata(t, a.size),
            else => {},
        }
        if (a.size <= 8) {
            _ = try d.in.skipBy(gpa, a.size);
            return;
        }
        var inner = a;
        if (t.codec == .alac and a.size >= 24) {
            const buffer = try d.in.rb64(gpa);
            inner.size -= 8;
            if (buffer & 0xFFFFFFFF == std.mem.readInt(u32, "frma", .big) and buffer >> 32 <= inner.size and buffer >> 32 >= 8) {
                _ = try d.in.skipBy(gpa, -8);
                inner.size += 8;
            } else if (t.extradataLen() == 0) {
                // An ALAC cookie of 36 bytes from the box's start.
                const e = try gpa.alloc(u8, 36);
                @memset(e, 0);
                std.mem.writeInt(u32, e[0..4], 36, .big);
                std.mem.writeInt(u32, e[4..8], tag("alac"), .little);
                std.mem.writeInt(u64, e[12..20], buffer, .big);
                t.replaceExtradata(gpa, e);
                _ = try d.in.read(gpa, e[20..36]);
                _ = try d.in.skipBy(gpa, inner.size - 24);
                return;
            }
        }
        try d.readDefault(inner);
    }

    /// mov_read_alac (mov_read_extradata): the whole box, header included,
    /// appended to the extradata, an ALAC track's only.
    fn readAlac(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (t.codec != .alac) return;
        const total = @as(u64, t.extradataLen()) + @as(u64, @intCast(a.size)) + 8;
        if (total + 64 > std.math.maxInt(i32) or a.size > std.math.maxInt(i32)) return error.InvalidMov;
        if (a.size > d.limits.max_box_bytes) return error.LimitExceeded;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        if (t.extradata) |e| try buf.appendSlice(gpa, e);
        var head: [8]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], @truncate(@as(u64, @intCast(a.size)) + 8), .big);
        std.mem.writeInt(u32, head[4..8], a.type, .little);
        try buf.appendSlice(gpa, &head);
        // A box cut short keeps what was read (the extradata shrinks).
        const body = try d.in.readOwned(gpa, @intCast(a.size));
        if (body) |b| {
            defer gpa.free(b);
            try buf.appendSlice(gpa, b);
        } else {
            // ffio_read_size failed: the header fails (the errdefer frees
            // the new bytes).
            return error.InvalidMov;
        }
        const owned = try buf.toOwnedSlice(gpa);
        t.replaceExtradata(gpa, owned);
    }

    fn readGlbl(d: *Demuxer, a_in: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        var a = a_in;
        if (a.size > 1 << 30) return error.InvalidMov;
        if (a.type == tag("vvcC")) {
            _ = try d.in.skipBy(gpa, 4);
            a.size -= 4;
        }
        if (a.size >= 10) {
            const size = try d.in.rb32(gpa);
            const ty = try d.in.rl32(gpa);
            if (try d.in.feof(gpa)) return error.InvalidMov;
            _ = try d.in.skipBy(gpa, -8);
            if (ty == tag("fiel") and size == a.size) return d.readDefault(a);
        }
        if (t.extradataLen() > 1) return; // "ignoring multiple glbl"
        try d.getExtradata(t, a.size);
    }

    fn readDfla(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (a.size > 1 << 30 or a.size < 42) return error.InvalidMov;
        if (try d.in.r8(gpa) != 0) return error.InvalidMov;
        _ = try d.in.rb24(gpa);
        var head: [4]u8 = undefined;
        if (try d.in.read(gpa, &head) != 4) return error.InvalidMov;
        const block_type = head[0] & 0x7f;
        const size = std.mem.readInt(u24, head[1..4], .big);
        if (block_type != 0 or size != 34) return error.InvalidMov;
        try d.getExtradata(t, size);
    }

    fn readDops(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (a.size > 1 << 30 or a.size < 11 or t.extradata != null) return error.InvalidMov;
        if (try d.in.r8(gpa) != 0) return error.InvalidMov;
        if (a.size > d.limits.max_box_bytes) return error.LimitExceeded;
        const body = try d.in.readOwned(gpa, @intCast(a.size - 1)) orelse return error.InvalidMov;
        defer gpa.free(body);
        const e = try gpa.alloc(u8, body.len + 9);
        t.replaceExtradata(gpa, e);
        @memcpy(e[0..8], "OpusHead");
        e[8] = 1;
        @memcpy(e[9..], body);
        // The big-endian fields of the box, little-endian in OpusHead.
        const pre_skip = std.mem.readInt(u16, e[10..12], .big);
        std.mem.writeInt(u16, e[10..12], pre_skip, .little);
        std.mem.writeInt(u32, e[12..16], std.mem.readInt(u32, e[12..16], .big), .little);
        std.mem.writeInt(u16, e[16..18], std.mem.readInt(u16, e[16..18], .big), .little);
        t.initial_padding = pre_skip;
        t.seek_preroll = 3840; // 80 ms at 48 kHz
    }

    fn readDac3(d: *Demuxer) Error!void {
        const t = d.lastTrack() orelse return;
        const info = try d.in.rb24(d.gpa);
        const bsmod: u8 = @intCast((info >> 14) & 7);
        const acmod = (info >> 11) & 7;
        var mask = ac3_layouts[acmod];
        if ((info >> 10) & 1 != 0) mask |= low_frequency;
        t.setLayout(.{ .native = mask });
        t.service_type = if (@popCount(mask) > 1 and bsmod == 7) karaoke else bsmod;
    }

    fn readDec3(d: *Demuxer, a: Atom) Error!void {
        const t = d.lastTrack() orelse return;
        if (a.size < 5 or a.size > 1 << 30) return error.InvalidMov;
        try d.getExtradata(t, a.size);
        const e = t.extradata.?;
        const info = std.mem.readInt(u24, e[2..5], .big);
        const bsmod: u8 = @intCast((info >> 12) & 0x1f);
        const acmod = (info >> 9) & 7;
        var mask = ac3_layouts[acmod];
        if ((info >> 8) & 1 != 0) mask |= low_frequency;
        t.setLayout(.{ .native = mask });
        t.service_type = if (@popCount(mask) > 1 and bsmod == 7) karaoke else bsmod;
    }

    /// mov_read_chan: ff_mov_read_chan's layout, when it gives one; its
    /// errors are ignored.
    fn readChan(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        if (a.size < 16) return;
        _ = try d.in.skipBy(gpa, 4);
        const size: u64 = @intCast(a.size - 4);
        // The fixed fields (zeros past the end, as avio_rb32 reads them).
        var head = try d.in.bytes(gpa, mov_chan.header_len);
        const described: u64 = std.mem.readInt(u32, head[8..12], .big);
        // "size < 12 + num_descr * 20": the layout stays.
        if (size < mov_chan.header_len + described * mov_chan.description_len) return;
        const tag_value = std.mem.readInt(u32, head[0..4], .big);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        // The descriptions mov_chan.read reads (FFmpeg caps them at the
        // channel count); none for the other tags.
        var used: u64 = 0;
        if (tag_value == mov_chan.tags.use_descriptions) {
            const count: u64 = @max(t.channelCount(), 0);
            used = @min(described, count);
        }
        std.mem.writeInt(u32, head[8..12], @intCast(used), .big);
        try body.appendSlice(gpa, &head);
        if (used > 0) {
            const wanted = used * mov_chan.description_len;
            if (wanted > d.limits.max_box_bytes) return error.LimitExceeded;
            try body.appendNTimes(gpa, 0, @intCast(wanted));
            const got = try d.in.read(gpa, body.items[mov_chan.header_len..]);
            // FFmpeg checks for the end before each description: one that
            // ends inside the last is read with zeros.
            if (got < wanted and got < (used - 1) * mov_chan.description_len) return;
        }
        const current: Layout = t.layout orelse .{ .unspecified = std.math.cast(u32, t.channelCount()) orelse return };
        var reader: std.Io.Reader = .fixed(body.items);
        const layout = mov_chan.read(&reader, body.items.len, current) catch return;
        t.setLayout(layout);
    }

    /// mov_read_frma outside encrypted sample entries (refused at their
    /// `sinf`): the format is only compared.
    fn readFrma(d: *Demuxer) Error!void {
        _ = try d.in.rl32(d.gpa);
    }

    fn readEnda(d: *Demuxer) Error!void {
        const little = (try d.in.rb16(d.gpa)) & 0xff;
        if (little != 1) return;
        const t = d.lastTrack() orelse return;
        t.codec = switch (t.codec) {
            .pcm_s16be => .pcm_s16le,
            .pcm_s24be => .pcm_s24le,
            .pcm_s32be => .pcm_s32le,
            .pcm_f32be => .pcm_f32le,
            .pcm_f64be => .pcm_f64le,
            else => t.codec,
        };
    }

    fn readSrat(d: *Demuxer, a: Atom) Error!void {
        if (a.size < 8) return;
        const t = d.lastTrack() orelse return;
        if (t.media != .audio or !d.isom) return;
        _ = try d.in.skipBy(d.gpa, 4);
        const rate: i32 = @bitCast(try d.in.rb32(d.gpa));
        if (rate > 0) t.sample_rate = rate;
    }

    // ---- Metadata (T33a2) ----

    /// `ffio_read_size` of a tag's bytes: null where FFmpeg's read comes
    /// short (AVERROR_INVALIDDATA), `LimitExceeded` over the limit.
    fn readSized(d: *Demuxer, n: u64) Error!?[]u8 {
        if (d.in.size) |size| if (d.in.pos >= size or n > @as(u64, @intCast(size - d.in.pos))) {
            _ = try d.in.seekTo(d.gpa, size);
            d.in.eof = true;
            return null;
        };
        if (n > d.limits.max_box_bytes) return error.LimitExceeded;
        return d.in.readOwned(d.gpa, n);
    }

    /// The dictionary a user data string goes to: the track's inside a
    /// `trak`, else the format's.
    fn udtaTags(d: *Demuxer) *metadata.Dictionary {
        if (d.trak_index) |i| return &d.tracks.items[i].tags;
        return &d.tags;
    }

    /// mov_read_udta_string: a QuickTime user data string (a length, a
    /// language and the text), a raw one, or iTunes `data` atoms inside
    /// `ilst` (several make one value joined by `;`), into the track's or
    /// the format's tags; some keys are numbers, a genre or a location,
    /// `covr` is a picture.
    fn udtaString(d: *Demuxer, a_in: Atom) Error!void {
        const gpa = d.gpa;
        var a = a_in;
        if (a.type == tag("HMMT")) return d.readHmmt(@truncate(@as(u64, @bitCast(a.size))));
        if (a.type == tag("loci")) return d.readLoci(@truncate(@as(u64, @bitCast(a.size))));
        const entry = udtaKey(a.type);
        var key: ?[]const u8 = if (entry) |e| e.key else null;
        var raw = if (entry) |e| e.parse == .raw else false;
        const parse: UdtaParse = if (entry) |e| e.parse else .none;
        var data_type: u32 = 0;
        var langcode: u16 = 0;
        var lang_buf: [3]u8 = undefined;
        var language: ?[]const u8 = null;
        var str_size: u64 = undefined;
        retry: while (true) {
            if (d.itunes_metadata and a.size > 8) {
                const data_size: i32 = @bitCast(try d.in.rb32(gpa));
                const data_tag = try d.in.rl32(gpa);
                if (!(data_tag == tag("data") and data_size <= a.size and data_size >= 16)) return;
                data_type = try d.in.rb32(gpa);
                _ = try d.in.rb32(gpa);
                str_size = @intCast(data_size - 16);
                a.size -= 16;
                if (key == null and d.found_hdlr_mdta and d.meta_keys.items.len > 0) {
                    // The index of `keys`, big-endian, read as a type.
                    const index = @byteSwap(a.type);
                    if (index < d.meta_keys.items.len and index > 0) if (d.meta_keys.items[index]) |name| {
                        key = cString(name);
                    };
                }
                if (a.type == tag("covr") or (key != null and std.mem.eql(u8, key.?, "com.apple.quicktime.artwork"))) {
                    try d.readCovr(data_type, str_size);
                    a.size -= @intCast(str_size);
                    if (a.size > 8) continue :retry;
                    return;
                }
            } else if (a.size > 4 and key != null and !d.itunes_metadata and !raw) {
                str_size = try d.in.rb16(gpa);
                if (str_size > a.size) {
                    // "UDTA parsing failed retrying raw".
                    raw = true;
                    _ = try d.in.skipBy(gpa, -2);
                    continue :retry;
                }
                langcode = try d.in.rb16(gpa);
                language = languageCode(langcode, &lang_buf);
                a.size -= 4;
            } else {
                str_size = @bitCast(a.size);
            }
            const k = key orelse return;
            if (a.size < 0 or str_size >= std.math.maxInt(i32) / 2) return error.InvalidMov;
            if (parse != .none and parse != .raw) return d.udtaNumber(parse, str_size, k);
            const num = data_type >= 21 and data_type <= 23;
            // The value's buffer: room for a number, the bytes, or Mac
            // Roman's UTF-8 at two bytes a byte.
            const alloc: u64 = (if (num) 512 else if (raw) str_size else str_size * 2) + 1;
            var value: std.ArrayList(u8) = .empty;
            defer value.deinit(gpa);
            if (!raw and (data_type == 3 or (data_type == 0 and (langcode < 0x400 or langcode == 0x7fff)))) {
                try d.macString(str_size, alloc - 1, &value);
            } else if (data_type == 21) {
                const v: i32 = switch (str_size) {
                    1 => @as(i8, @bitCast(try d.in.r8(gpa))),
                    2 => @as(i16, @bitCast(try d.in.rb16(gpa))),
                    3 => @as(i24, @bitCast(@as(u24, @intCast(try d.in.rb24(gpa))))),
                    4 => @bitCast(try d.in.rb32(gpa)),
                    else => 0,
                };
                try value.print(gpa, "{d}", .{v});
            } else if (data_type == 22) {
                const v: u32 = switch (str_size) {
                    1 => try d.in.r8(gpa),
                    2 => try d.in.rb16(gpa),
                    3 => try d.in.rb24(gpa),
                    4 => try d.in.rb32(gpa),
                    else => 0,
                };
                try value.print(gpa, "{d}", .{v});
            } else if (data_type == 23 and str_size >= 4) {
                const v: f32 = @bitCast(try d.in.rb32(gpa));
                try formatFixed(gpa, &value, v, .{ .precision = 6 });
            } else if (data_type > 1 and data_type != 4) {
                // "Skipping unhandled metadata": UTF-16, a picture, ...
                return;
            } else {
                const bytes = try d.readSized(str_size) orelse return error.InvalidMov;
                defer gpa.free(bytes);
                try value.appendSlice(gpa, bytes);
            }
            const dict = d.udtaTags();
            const text = value.items[0 .. std.mem.findScalar(u8, value.items, 0) orelse value.items.len];
            if (d.itunes_metadata and dict.get(k) != null) try putTag(gpa, dict, k, ";", .append);
            try putTag(gpa, dict, k, text, if (d.itunes_metadata) .append else .replace);
            if (language) |lang| if (!std.mem.eql(u8, lang, "und")) {
                // snprintf into `char key2[32]`: at most 31 bytes (the
                // table's keys leave room).
                var key2: [64]u8 = undefined;
                const joined = std.fmt.bufPrint(&key2, "{s}-{s}", .{ k, lang }) catch unreachable; // a key of the table: at most 21 bytes
                try putTag(gpa, dict, joined[0..@min(joined.len, 31)], text, .replace);
            };
            if (std.mem.eql(u8, k, "encoder")) if (handBrakeVersion(text)) |v| {
                d.handbrake_version = v;
            };
            a.size -%= @bitCast(str_size);
            // The rest of a multi-valued iTunes tag.
            if (d.itunes_metadata and a.size > 8) continue :retry;
            return;
        }
    }

    /// The parse helpers' tags, which go to the format's tags wherever the
    /// box is (mov_metadata_track_or_disc_number, the int8 ones, gnre).
    fn udtaNumber(d: *Demuxer, parse: UdtaParse, len: u64, key: []const u8) Error!void {
        const gpa = d.gpa;
        var buf: [32]u8 = undefined;
        const text: []const u8 = switch (parse) {
            .number => blk: {
                _ = try d.in.rb16(gpa);
                const current: i16 = @bitCast(try d.in.rb16(gpa));
                var total: i16 = 0;
                if (@as(u32, @truncate(len)) >= 6) total = @bitCast(try d.in.rb16(gpa));
                break :blk if (total == 0)
                    std.fmt.bufPrint(&buf, "{d}", .{current}) catch unreachable // at most 6 bytes
                else
                    std.fmt.bufPrint(&buf, "{d}/{d}", .{ current, total }) catch unreachable;
            },
            .int8_padded => blk: {
                for (0..3) |_| _ = try d.in.r8(gpa);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{try d.in.r8(gpa)}) catch unreachable;
            },
            .int8 => std.fmt.bufPrint(&buf, "{d}", .{try d.in.r8(gpa)}) catch unreachable,
            .gnre => blk: {
                _ = try d.in.r8(gpa);
                const genre = try d.in.r8(gpa);
                if (genre < 1 or genre > id3v1.genre_max) return;
                break :blk id3v1.genres[genre - 1];
            },
            .none, .raw => unreachable, // the caller reads those as strings
        };
        try putTag(gpa, &d.tags, key, text, .replace);
    }

    /// mov_read_mac_string: `len` bytes of Mac Roman as UTF-8, at most
    /// `max` bytes of it (a character cut at the end); the text ends at a
    /// NUL, and so where the input ends (FFmpeg reads zeros there).
    fn macString(d: *Demuxer, len: u64, max: u64, out: *std.ArrayList(u8)) Error!void {
        const gpa = d.gpa;
        const limit = std.math.cast(usize, max) orelse std.math.maxInt(usize);
        var left = len;
        var ended = false;
        var chunk: [4096]u8 = undefined;
        while (left > 0) {
            const step: usize = @min(left, chunk.len);
            const got = try d.in.read(gpa, chunk[0..step]);
            for (chunk[0..got]) |c| {
                if (ended or out.items.len >= limit) continue;
                if (c == 0) {
                    ended = true;
                } else if (c < 0x80) {
                    try out.append(gpa, c);
                } else {
                    try putUtf8(gpa, out, mac_to_unicode[c - 0x80], limit);
                }
            }
            left -= got;
            if (got < step) break;
        }
    }

    /// mov_read_covr: a picture (JPEG, PNG or BMP) FFmpeg makes an
    /// attached-picture stream of, which the port skips; another type is
    /// skipped by FFmpeg too.
    fn readCovr(d: *Demuxer, data_type: u32, len: u64) Error!void {
        switch (data_type) {
            0xd, 0xe, 0x1b => {},
            else => {
                // "Unknown cover type".
                _ = try d.in.skipBy(d.gpa, @intCast(len));
                return;
            },
        }
        // A picture inside a track would come between the tracks.
        if (d.trak_index != null) return error.UnsupportedFormat;
        if (d.tracks.items.len + d.pictures >= d.limits.max_tracks) return error.LimitExceeded;
        // av_get_packet: what is there; none is AVERROR_EOF.
        const got = try d.in.skipCount(d.gpa, len);
        if (len > 0 and got == 0) return error.Truncated;
        d.pictures += 1;
    }

    /// mov_metadata_loci: a 3GPP location as `location` (and with its
    /// language).
    fn readLoci(d: *Demuxer, len_in: u32) Error!void {
        const gpa = d.gpa;
        var len = len_in;
        if (len < 4 + 2 + 1 + 1 + 4 + 4 + 4) return error.InvalidMov; // "loci too short"
        _ = try d.in.skipBy(gpa, 4);
        var lang_buf: [3]u8 = undefined;
        const language = languageCode(try d.in.rb16(gpa), &lang_buf);
        len -= 6;
        // avio_get_str's int maxlen: past INT_MAX it is negative, reads
        // nothing and returns itself, which leaves no length.
        if (len > std.math.maxInt(i32)) return error.InvalidMov; // "place name too long"
        var place: std.ArrayList(u8) = .empty;
        defer place.deinit(gpa);
        len -= try d.getStr(len, 100, &place);
        if (len < 1) return error.InvalidMov; // "place name too long"
        _ = try d.in.skipBy(gpa, 1);
        len -= 1;
        if (len < 12) return error.InvalidMov;
        const longitude = fixed16(try d.in.rb32(gpa));
        const latitude = fixed16(try d.in.rb32(gpa));
        const altitude = fixed16(try d.in.rb32(gpa));
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try formatFixed(gpa, &buf, latitude, .{ .precision = 4, .plus = true, .width = 8 });
        try formatFixed(gpa, &buf, longitude, .{ .precision = 4, .plus = true, .width = 9 });
        if (altitude != 0) try formatFixed(gpa, &buf, altitude, .{ .precision = 6, .plus = true });
        try buf.print(gpa, "/{s}", .{place.items});
        if (language) |lang| if (!std.mem.eql(u8, lang, "und")) {
            var key2: [16]u8 = undefined;
            try putTag(gpa, &d.tags, std.fmt.bufPrint(&key2, "location-{s}", .{lang}) catch unreachable, buf.items, .replace);
        };
        try putTag(gpa, &d.tags, "location", buf.items, .replace);
    }

    /// avio_get_str: a NUL-ended string of at most `maxlen` bytes, at most
    /// `buflen - 1` of them kept; the bytes read.
    fn getStr(d: *Demuxer, maxlen: u32, buflen: u32, out: *std.ArrayList(u8)) Error!u32 {
        const keep = @min(buflen - 1, maxlen);
        var i: u32 = 0;
        while (i < keep) : (i += 1) {
            const c = try d.in.r8(d.gpa);
            if (c == 0) return i + 1;
            try out.append(d.gpa, c);
        }
        while (i < maxlen) : (i += 1) {
            if (try d.in.r8(d.gpa) == 0) return i + 1;
        }
        return maxlen;
    }

    /// mov_metadata_hmmt: chapter marks in milliseconds, without titles.
    fn readHmmt(d: *Demuxer, len: u32) Error!void {
        if (len < 2) return;
        const count = try d.in.rb32(d.gpa);
        if (count > len / 4) return error.InvalidMov; // an int compared unsigned
        var i: u32 = 0;
        while (i < count and !d.in.eof) : (i += 1) {
            const time: i32 = @bitCast(try d.in.rb32(d.gpa));
            try d.addChapter(i, .{ .num = 1, .den = 1000 }, time, nopts, null);
        }
        if (try d.in.feof(d.gpa)) return error.InvalidMov;
    }

    fn addChapter(d: *Demuxer, id: i64, time_base: rational.Rational, start: i64, end: i64, title: ?[]const u8) Error!void {
        if (d.chapters.items.items.len >= d.limits.max_chapters) return error.LimitExceeded;
        try d.chapters.add(d.gpa, id, time_base, start, end, title);
    }

    /// mov_read_meta: the `hdlr` found 4 bytes at a time (after a full
    /// box's version and flags in MP4, at once in QuickTime), then the
    /// boxes from it.
    fn readMeta(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        var size = a.size;
        while (size > 8) {
            if (try d.in.feof(gpa)) return error.Truncated;
            const t = try d.in.rl32(gpa);
            size -= 4;
            if (t == tag("hdlr")) {
                _ = try d.in.skipBy(gpa, -8);
                size += 8;
                return d.readDefault(.{ .type = tag("meta"), .size = size });
            }
        }
    }

    /// mov_read_ilst: iTunes tags; leaving any `ilst` ends the mode, an
    /// outer one's too.
    fn readIlst(d: *Demuxer, a: Atom) Error!void {
        d.itunes_metadata = true;
        const result = d.readDefault(a);
        d.itunes_metadata = false;
        return result;
    }

    /// mov_read_keys: the names an `mdta` `ilst` indexes.
    fn readKeys(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        if (a.size < 8) return;
        _ = try d.in.skipBy(gpa, 4);
        const count = try d.in.rb32(gpa);
        var size = a.size - 8;
        if (count > @divTrunc(size, 8) or count >= std.math.maxInt(u32) / 8) return error.InvalidMov;
        // av_malloc_array(count + 1, 8): ENOMEM past INT_MAX.
        if ((@as(u64, count) + 1) * 8 > std.math.maxInt(i32)) return error.LimitExceeded;
        try d.meta_keys.append(gpa, null);
        var i: u32 = 1;
        while (i <= count) : (i += 1) {
            const key_size = try d.in.rb32(gpa);
            const ty = try d.in.rl32(gpa);
            try d.meta_keys.append(gpa, null);
            if (key_size < 8 or key_size > size) return error.InvalidMov;
            size -= key_size;
            if (ty != tag("mdta")) {
                _ = try d.in.skipBy(gpa, key_size - 8);
                continue;
            }
            // A C string, cut at its NUL where it is used.
            d.meta_keys.items[i] = try d.readSized(key_size - 8) orelse return error.InvalidMov;
        }
    }

    /// mov_read_custom: iTunes' `----` (mean, name, data): a format tag
    /// by its name, iTunSMPB's gapless counts for the last track,
    /// `DISCSUBTITLE` as `disc_subtitle`, `cdec` dropped.
    fn readCustom(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const end = rational.satAdd(d.in.pos, a.size);
        if (!d.hasStream()) return;
        var parts: [3]?[]u8 = .{ null, null, null }; // mean, name, data
        defer for (parts) |p| if (p) |b| gpa.free(b);
        var failed: ?Error = null;
        for (0..3) |_| {
            if (end - d.in.pos <= 12) break;
            const len = try d.in.rb32(gpa);
            const t = try d.in.rl32(gpa);
            _ = try d.in.skipBy(gpa, 4);
            if (len < 12 or @as(i64, len - 12) > end - d.in.pos) break;
            var n = len - 12;
            const slot: usize = if (t == tag("mean")) 0 else if (t == tag("name")) 1 else if (t == tag("data") and n > 4) blk: {
                _ = try d.in.skipBy(gpa, 4);
                n -= 4;
                break :blk 2;
            } else break;
            if (parts[slot] != null) break;
            parts[slot] = d.readSized(n) catch |err| {
                failed = err;
                break;
            } orelse {
                failed = error.InvalidMov;
                break;
            };
        }
        if (parts[0] != null and parts[1] != null and parts[2] != null) {
            const mean = cString(parts[0].?);
            const key = cString(parts[1].?);
            const val = cString(parts[2].?);
            if (std.mem.eql(u8, key, "iTunSMPB")) if (mp3.parseSmpb(val)) |counts| if (d.lastTrack()) |t| t.applySmpb(counts);
            var consumed = false;
            if (std.mem.eql(u8, mean, "com.apple.iTunes") and std.mem.eql(u8, key, "DISCSUBTITLE")) {
                try putTag(gpa, &d.tags, "disc_subtitle", val, .replace);
                consumed = true;
            }
            if (!std.mem.eql(u8, key, "cdec")) {
                // The value went to disc_subtitle: av_dict_set with none
                // removes the key.
                if (consumed) _ = d.tags.remove(gpa, key) else try putTag(gpa, &d.tags, key, val, .replace);
            }
        }
        _ = try d.in.seekTo(gpa, end);
        if (failed) |err| return err;
    }

    /// mov_read_chpl: Nero chapters, in 100 ns units, with titles.
    fn readChpl(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        var size = a.size - 5;
        if (size < 0) return;
        const version = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        // Not counted in the size, as FFmpeg does not.
        if (version != 0) _ = try d.in.rb32(gpa);
        const count = try d.in.r8(gpa);
        for (0..count) |i| {
            if (size < 9) return;
            const start: i64 = @bitCast(try d.in.rb64(gpa));
            const len = try d.in.r8(gpa);
            size -= 9 + @as(i64, len);
            if (size < 0) return;
            var title: [255]u8 = undefined;
            if (try d.in.read(gpa, title[0..len]) != len) return error.InvalidMov;
            try d.addChapter(@intCast(i), .{ .num = 1, .den = 10_000_000 }, start, nopts, title[0..len]);
        }
    }

    /// mov_read_chap: the chapter tracks' ids (the last `chap` wins).
    fn readChap(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        // An unsigned count of the int64 size, as C truncates it.
        const num: u32 = @truncate(@as(u64, @bitCast(@divTrunc(a.size, 4))));
        // av_malloc_array: ENOMEM past INT_MAX.
        if (@as(u64, num) * 4 > std.math.maxInt(i32)) return error.LimitExceeded;
        d.chapter_tracks.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < num and !d.in.eof) : (i += 1) {
            try d.checkEntries(@as(u64, i) + 1);
            try d.chapter_tracks.append(gpa, @bitCast(try d.in.rb32(gpa)));
        }
    }

    /// mov_read_kind: a DASH role's dispositions for the last track.
    fn readKind(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        if (a.size < 6) return error.InvalidMov;
        if (!d.hasStream()) return;
        const version = try d.in.r8(gpa);
        const flags = try d.in.rb24(gpa);
        var size = a.size - 4;
        if (version != 0 or flags != 0) return error.InvalidMov;
        var scheme: std.ArrayList(u8) = .empty;
        defer scheme.deinit(gpa);
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(gpa);
        const scheme_len = try d.readString(&scheme, size);
        if (scheme_len + 1 >= size) return error.InvalidMov;
        size -= scheme_len + 1;
        const value_len = try d.readString(&value, size);
        // No NUL after the value.
        if (value_len == size) return error.InvalidMov;
        const t = d.lastTrack() orelse return; // a picture's
        if (!std.mem.startsWith(u8, scheme.items, "urn:mpeg:dash:role:2011")) return;
        for (dash_roles) |role| {
            if (std.mem.startsWith(u8, value.items, role.value)) t.disposition |= role.disposition;
        }
    }

    /// read_string_to_bprint: bytes up to a NUL or `max_len` of them; the
    /// count, AVERROR_EOF for an empty string the input ended.
    fn readString(d: *Demuxer, out: *std.ArrayList(u8), max_len: i64) Error!i64 {
        if (max_len == 0) return 0;
        var read: i64 = 0;
        var last: u8 = 0;
        while (true) {
            last = try d.in.r8(d.gpa);
            if (last == 0) break;
            if (out.items.len >= d.limits.max_box_bytes) return error.LimitExceeded;
            try out.append(d.gpa, last);
            read += 1;
            if (read >= max_len) break;
        }
        if (last == 0 and read == 0 and try d.in.feof(d.gpa)) return error.Truncated;
        return read;
    }

    /// mov_read_uuid: an ISML manifest's bit rates, XMP (skipped, as
    /// `export_xmp` is off) and spherical video metadata (read, of no use
    /// to audio).
    fn readUuid(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        if (a.size < 16 or a.size >= std.math.maxInt(i32)) return error.InvalidMov;
        if (!d.hasStream()) return;
        var uuid: [16]u8 = undefined;
        if (try d.in.read(gpa, &uuid) != 16) return error.InvalidMov;
        const len: u64 = @intCast(a.size - 16);
        if (std.mem.eql(u8, &uuid, &uuid_isml_manifest)) {
            if (len < 4) return error.InvalidMov;
            _ = try d.in.skipBy(gpa, 4);
            const buffer = try d.readSized(len - 4) orelse return error.InvalidMov;
            defer gpa.free(buffer);
            try d.readBitrates(cString(buffer));
        } else if (std.mem.eql(u8, &uuid, &uuid_xmp)) {
            if (!try d.in.skipBy(gpa, @intCast(len))) return error.Truncated;
        } else if (std.mem.eql(u8, &uuid, &uuid_spherical)) {
            if (try d.in.skipCount(gpa, len) != len) return error.InvalidMov;
        }
    }

    /// Each `systemBitrate="` of a manifest (ASCII case aside): the number
    /// after it, or 0 unless it is a whole non-negative `long` ending at a
    /// quote.
    fn readBitrates(d: *Demuxer, text: []const u8) Error!void {
        const needle = "systemBitrate=\"";
        var at: usize = 0;
        while (std.ascii.findIgnoreCasePos(text, at, needle)) |found| {
            at = found + needle.len;
            const rest = text[at..];
            // strtol's end pointer stays at the start without a digit.
            const parsed = strtol10(rest);
            const rate: i64 = if (!parsed.overflow and parsed.value >= 0 and parsed.len < rest.len and rest[parsed.len] == '"') parsed.value else 0;
            try d.bitrates.append(d.gpa, rate);
        }
    }

    /// mov_read_chapters: each chapter track's samples as chapters (a
    /// length, then UTF-8 or a UTF-16 text with its byte order mark), the
    /// track made a discarded data stream; on a seekable input, as FFmpeg
    /// reads them.
    fn readChapterTracks(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        for (d.chapter_tracks.items) |id| {
            const t = for (d.tracks.items) |*x| {
                if (x.sc_id == id) break x;
            } else continue; // "Referenced QT chapter track not found"
            const saved = d.in.pos;
            // Video tracks are refused before this.
            t.media = .data;
            t.codec = .bin_data;
            t.discard = true;
            var title: std.ArrayList(u8) = .empty;
            defer title.deinit(gpa);
            const index = t.index.items;
            for (index, 0..) |sample, i| {
                var end = if (i + 1 < index.len) index[i + 1].timestamp else t.duration;
                // "ignoring stream duration which is shorter than chapters"
                if (end < sample.timestamp) end = nopts;
                // "Chapter %d not found in file": the track's last.
                if (!try d.in.seekTo(gpa, sample.pos)) break;
                const len = try d.in.rb16(gpa);
                if (@as(i64, len) > @as(i64, sample.size) - 2) continue;
                title.clearRetainingCapacity();
                // The C buffer of 2 * len + 1 bytes.
                const limit = 2 * @as(usize, len);
                if (len != 0) {
                    const ch = try d.in.rb16(gpa);
                    if (ch == 0xfeff) {
                        try d.getStr16(.big, len, limit, &title);
                    } else if (ch == 0xfffe) {
                        try d.getStr16(.little, len, limit, &title);
                    } else {
                        try title.appendSlice(gpa, &.{ @truncate(ch >> 8), @truncate(ch) });
                        if (len == 1 or len == 2) {
                            title.shrinkRetainingCapacity(len);
                        } else {
                            // avio_get_str reads on to a NUL, which the
                            // seek to the next sample makes moot.
                            var k: usize = 0;
                            while (k < len - 2) : (k += 1) {
                                const c = try d.in.r8(gpa);
                                if (c == 0) break;
                                try title.append(gpa, c);
                            }
                        }
                    }
                }
                try d.addChapter(@intCast(i), t.time_base, sample.timestamp, end, cString(title.items));
            }
            _ = try d.in.seekTo(gpa, saved);
        }
    }

    /// avio_get_str16be / avio_get_str16le: UTF-16 of at most `maxlen`
    /// bytes to a NUL, as UTF-8 of at most `limit` bytes; a bad surrogate
    /// ends it.
    fn getStr16(d: *Demuxer, endian: std.lang.Endian, maxlen: u32, limit: usize, out: *std.ArrayList(u8)) Error!void {
        const gpa = d.gpa;
        var ret: u32 = 0;
        while (ret + 1 < maxlen) {
            ret += 2;
            var ch: u32 = if (ret <= maxlen) try d.read16(endian) else 0;
            const hi = ch -% 0xD800;
            if (hi < 0x800) {
                ret += 2;
                const low: u32 = if (ret <= maxlen) try d.read16(endian) else 0;
                ch = low -% 0xDC00;
                if (ch > 0x3FF or hi > 0x3FF) break;
                ch += (hi << 10) + 0x10000;
            }
            if (ch == 0) break;
            try putUtf8(gpa, out, ch, limit);
        }
    }

    fn read16(d: *Demuxer, endian: std.lang.Endian) Error!u16 {
        return std.mem.readInt(u16, &(try d.in.bytes(d.gpa, 2)), endian);
    }

    // ---- Sample tables ----

    /// The track a sample table belongs to: none outside a `trak` (FFmpeg
    /// warns and skips the box).
    fn tableTrack(d: *Demuxer) ?*Track {
        if (d.trak_index == null) return null;
        return d.lastTrack();
    }

    fn checkEntries(d: *Demuxer, count: u64) Error!void {
        if (count > d.limits.max_entries) return error.LimitExceeded;
    }

    fn readStts(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.tableTrack() orelse return;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const entries = try d.in.rb32(gpa);
        t.stts.clearRetainingCapacity();
        t.stts_count = 0;
        // av_fast_realloc's ENOMEM.
        if (entries >= std.math.maxInt(i32) / 8) return error.LimitExceeded;
        var duration: i64 = 0;
        var total_sample_count: i64 = 0;
        var current_dts: i64 = 0;
        var corrected_dts: i64 = 0;
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            try d.checkEntries(@as(u64, i) + 1);
            const count = try d.in.rb32(gpa);
            const sample_duration = try d.in.rb32(gpa);
            var e: Stts = .{ .count = count, .duration = sample_duration };
            // STTS offsets are unsigned, but some files store negative
            // corrections; large ones are clipped to 1.
            if (sample_duration > max_stts_delta) {
                const magnitude: i32 = @bitCast(sample_duration);
                e.duration = 1;
                corrected_dts = rational.satAdd(corrected_dts, (if (magnitude < 0) @as(i64, magnitude) else 1) * @as(i64, count));
            } else {
                corrected_dts +%= @bitCast(@as(u64, sample_duration) *% count);
            }
            current_dts +%= @bitCast(@as(u64, e.duration) *% count);
            if (current_dts > corrected_dts) {
                const drift = @divTrunc(rational.satSub(current_dts, corrected_dts), @max(count, 1));
                // `correction` is unsigned: a duration of 0 makes it wrap.
                const correction: u32 = if (e.duration > drift) @intCast(drift) else e.duration -% 1;
                current_dts -%= @bitCast(@as(u64, correction) *% count);
                e.duration -%= correction;
            }
            duration +%= @bitCast(@as(u64, @as(u64, e.duration) *% count));
            total_sample_count += count;
            try t.stts.append(gpa, e);
        }
        t.stts_count = i;
        if (duration > 0 and duration <= std.math.maxInt(i64) - t.duration_for_fps and
            total_sample_count <= std.math.maxInt(i32) - @as(i64, t.nb_frames_for_fps))
        {
            t.duration_for_fps += duration;
            t.nb_frames_for_fps += @intCast(total_sample_count);
        }
        if (d.in.eof) return error.Truncated; // "reached eof, corrupted STTS atom"
        t.nb_frames = total_sample_count;
        if (duration != 0) t.duration = @min(t.duration, duration);
        // Samples that all last 0 in a data track: discarded.
        if (duration == 0 and t.stts_count > 0 and t.media == .data) t.discard = true;
    }

    fn readCtts(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.tableTrack() orelse return;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const entries = try d.in.rb32(gpa);
        if (entries == 0) return;
        if (entries >= std.math.maxInt(u32) / 8) return error.InvalidMov;
        // av_fast_realloc of every entry at once: ENOMEM past INT_MAX.
        if (@as(u64, entries) * 8 > std.math.maxInt(i32) - 32) return error.LimitExceeded;
        t.ctts.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            const count: i32 = @bitCast(try d.in.rb32(gpa));
            const offset: i32 = @bitCast(try d.in.rb32(gpa));
            if (count <= 0) continue; // "ignoring CTTS entry"
            try d.checkEntries(@as(u64, t.ctts.items.len) + 1);
            try t.ctts.append(gpa, .{ .count = @intCast(count), .offset = offset });
            // The last two entries do not move the shift.
            if (@as(u64, i) + 2 < entries) {
                if (offset < 0) {
                    const shift = if (offset == std.math.minInt(i32)) std.math.maxInt(i32) else -offset;
                    t.dts_shift = @max(t.dts_shift, shift);
                }
            }
        }
        t.ctts_count = @intCast(t.ctts.items.len);
        if (d.in.eof) return error.Truncated;
    }

    fn readStsc(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.tableTrack() orelse return;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const entries = try d.in.rb32(gpa);
        if (@as(u64, entries) * 12 + 4 > a.size) return error.InvalidMov;
        if (entries == 0) return;
        if (t.stsc.items.len > 0) return; // "Ignoring duplicated STSC atom"
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            try d.checkEntries(@as(u64, i) + 1);
            try t.stsc.append(gpa, .{
                .first = @bitCast(try d.in.rb32(gpa)),
                .count = @bitCast(try d.in.rb32(gpa)),
                .id = @bitCast(try d.in.rb32(gpa)),
            });
        }
        fixStsc(&t.stsc);
        if (d.in.eof) return error.Truncated;
    }

    fn readStsz(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.tableTrack() orelse return;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        var sample_size: u32 = 0;
        var field_size: u32 = undefined;
        if (a.type == tag("stsz")) {
            sample_size = try d.in.rb32(gpa);
            // The value computed from stsd is kept.
            if (t.sample_size == 0) t.sample_size = sample_size;
            t.stsz_sample_size = sample_size;
            field_size = 32;
        } else {
            _ = try d.in.rb24(gpa);
            field_size = try d.in.r8(gpa);
        }
        const entries = try d.in.rb32(gpa);
        t.sample_count = entries;
        if (sample_size != 0) return;
        if (field_size != 4 and field_size != 8 and field_size != 16 and field_size != 32) return error.InvalidMov;
        if (entries == 0) return;
        if (entries >= (std.math.maxInt(i32) - 4 - 8 * 64) / field_size) return error.InvalidMov;
        try d.checkEntries(entries);
        t.sample_sizes.clearRetainingCapacity();
        t.sample_count = 0;
        // Fits in 32 bits: entries * field_size is below INT_MAX.
        const num_bytes = (entries * field_size + 4) >> 3;
        const buf = try d.in.readOwned(gpa, num_bytes) orelse return; // "STSZ atom truncated"
        defer gpa.free(buf);
        try t.sample_sizes.ensureTotalCapacity(gpa, entries);
        var bit: u64 = 0;
        for (0..entries) |_| {
            const size: u32 = switch (field_size) {
                4 => @as(u32, buf[bit / 8] >> @intCast(4 - (bit % 8))) & 0xf,
                8 => buf[bit / 8],
                16 => std.mem.readInt(u16, buf[bit / 8 ..][0..2], .big),
                else => std.mem.readInt(u32, buf[bit / 8 ..][0..4], .big),
            };
            bit += field_size;
            if (size > std.math.maxInt(i64) - t.data_size) return error.InvalidMov; // "Sample size overflow"
            t.data_size += size;
            t.sample_sizes.appendAssumeCapacity(size);
        }
        t.sample_count = entries;
    }

    fn readStco(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.tableTrack() orelse return;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const wide = a.type == tag("co64");
        const declared = try d.in.rb32(gpa);
        // The count clamped to the box (the end of the input is not an
        // error here).
        const width: i64 = if (wide) 8 else 4;
        const fit: i64 = @max(0, @divTrunc(a.size - 8, width));
        const entries: u32 = @intCast(@min(declared, fit));
        if (entries == 0) return;
        if (t.chunk_offsets.items.len > 0) return; // "Ignoring duplicated STCO atom"
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            try d.checkEntries(@as(u64, i) + 1);
            var offset: i64 = undefined;
            if (wide) {
                offset = @bitCast(try d.in.rb64(gpa));
                if (offset < 0) offset = 0; // "Impossible chunk_offset"
            } else {
                offset = try d.in.rb32(gpa);
            }
            try t.chunk_offsets.append(gpa, offset);
        }
        if (d.in.eof) return error.Truncated;
    }

    fn readStss(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.tableTrack() orelse return;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const entries = try d.in.rb32(gpa);
        if (entries == 0) {
            t.keyframe_absent = true;
            return;
        }
        if (entries >= std.math.maxInt(u32) / 4) return error.InvalidMov;
        if (@as(u64, entries) * 4 > std.math.maxInt(i32) - 32) return error.LimitExceeded; // ENOMEM
        t.keyframes.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            try d.checkEntries(@as(u64, i) + 1);
            try t.keyframes.append(gpa, try d.in.rb32(gpa));
        }
        if (d.in.eof) return error.Truncated;
    }

    fn readStps(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.tableTrack() orelse return;
        _ = try d.in.rb32(gpa);
        const entries = try d.in.rb32(gpa);
        t.stps.clearRetainingCapacity();
        if (@as(u64, entries) * 4 > std.math.maxInt(i32) - 32) return error.LimitExceeded; // ENOMEM
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            try d.checkEntries(@as(u64, i) + 1);
            try t.stps.append(gpa, try d.in.rb32(gpa));
        }
        if (d.in.eof) return error.Truncated;
    }

    fn readSdtp(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        _ = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const entries = a.size - 4;
        t.sdtp.clearRetainingCapacity();
        if (entries < 0 or entries > std.math.maxInt(u32)) return error.OutOfRange;
        if (entries > std.math.maxInt(i32) - 32) return error.LimitExceeded; // ENOMEM
        var i: i64 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            try d.checkEntries(@intCast(i + 1));
            try t.sdtp.append(gpa, try d.in.r8(gpa));
        }
    }

    /// mov_read_sgpd: only `sync` groups are read (for HEVC); their bounds
    /// and the end of the input still count.
    fn readSgpd(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        _ = d.lastTrack() orelse return;
        const version = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        if (try d.in.rl32(gpa) != tag("sync")) return;
        const default_length: u32 = if (version >= 1) try d.in.rb32(gpa) else 0;
        if (version >= 2) _ = try d.in.rb32(gpa);
        const entries = try d.in.rb32(gpa);
        if (entries > a.size) return error.InvalidMov;
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            var length = default_length;
            if (version >= 1 and default_length == 0) length = try d.in.rb32(gpa);
            _ = try d.in.r8(gpa);
            length -%= 1;
            _ = try d.in.skipBy(gpa, length);
        }
        if (d.in.eof) return error.Truncated;
    }

    /// mov_read_sbgp: the `rap ` group marks keyframes; `sync` groups
    /// matter to HEVC only, and are read for their bounds.
    fn readSbgp(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        const version = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        const grouping = try d.in.rl32(gpa);
        const rap = grouping == tag("rap ");
        if (!rap and grouping != tag("sync")) return;
        if (version == 1) _ = try d.in.rb32(gpa);
        const entries = try d.in.rb32(gpa);
        if (entries == 0) return;
        if (@as(u64, entries) * 8 > std.math.maxInt(i32) - 32) return error.LimitExceeded; // ENOMEM
        if (rap) t.rap_group.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < entries and !d.in.eof) : (i += 1) {
            try d.checkEntries(@as(u64, i) + 1);
            const e: Sbgp = .{ .count = try d.in.rb32(gpa), .index = try d.in.rb32(gpa) };
            if (rap) try t.rap_group.append(gpa, e);
        }
        if (d.in.eof) return error.Truncated;
    }

    fn readElst(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        const t = d.lastTrack() orelse return;
        const version = try d.in.r8(gpa);
        _ = try d.in.rb24(gpa);
        var count: i64 = @as(i32, @bitCast(try d.in.rb32(gpa)));
        var size = a.size - 8;
        const entry_size: i64 = if (version == 1) 20 else 12;
        // The count from the box's size, truncated into an int as C does.
        if (size != count * entry_size) count = @as(i32, @truncate(@divTrunc(size, entry_size)));
        if (count <= 0) return;
        try d.checkEntries(@intCast(count));
        t.elst.clearRetainingCapacity();
        var i: i64 = 0;
        while (i < count and size > 0 and !d.in.eof) : (i += 1) {
            var e: Elst = undefined;
            if (version == 1) {
                e.duration = @bitCast(try d.in.rb64(gpa));
                e.time = @bitCast(try d.in.rb64(gpa));
                size -= 16;
            } else {
                e.duration = try d.in.rb32(gpa);
                e.time = @as(i32, @bitCast(try d.in.rb32(gpa)));
                size -= 8;
            }
            _ = try d.in.rb32(gpa); // rate
            size -= 4;
            if (e.duration < 0) return error.InvalidMov;
            try t.elst.append(gpa, e);
        }
    }

    /// mov_read_dref, as far as it refuses the box; an alias record of
    /// more than 150 bytes, which FFmpeg reads as a path to another file,
    /// is refused here.
    fn readDref(d: *Demuxer, a: Atom) Error!void {
        const gpa = d.gpa;
        _ = d.lastTrack() orelse return;
        _ = try d.in.rb32(gpa);
        const entries: i32 = @bitCast(try d.in.rb32(gpa));
        if (entries <= 0 or entries > @divTrunc(a.size - 1, 12) + 1) return error.InvalidMov;
        var i: i32 = 0;
        while (i < entries) : (i += 1) {
            const size = try d.in.rb32(gpa);
            var next_pos = d.in.pos;
            if (size < 12 or next_pos > std.math.maxInt(i64) - @as(i64, size)) return error.InvalidMov;
            next_pos += size - 4;
            const ty = try d.in.rl32(gpa);
            _ = try d.in.rb32(gpa);
            if (ty == tag("alis") and size > 150) return error.UnsupportedFormat;
            _ = try d.in.seekTo(gpa, next_pos);
        }
    }

    // ---- The index ----

    /// `av_realloc`'s limit: FFmpeg's allocations above `INT_MAX - 32`
    /// bytes fail.
    const max_alloc: u64 = std.math.maxInt(i32) - 32;

    /// The index entries FFmpeg would allocate for `count`: null when its
    /// allocation fails (the track is left without an index), else the
    /// count, refused over `Limits.max_samples`.
    fn indexCount(d: *Demuxer, count: u64) Error!?u32 {
        // `sizeof(AVIndexEntry)` is 24 and `MOVTimeToSample` 12.
        if (count >= std.math.maxInt(u32) / 24 or count * 24 > max_alloc) return null;
        if (count > d.limits.max_samples) return error.LimitExceeded;
        return @intCast(count);
    }

    /// mov_build_index, then mov_fix_index for an edit list that leaves
    /// the index as it is (any other is refused).
    fn buildIndex(d: *Demuxer, t: *Track) Error!void {
        const gpa = d.gpa;
        if (!(t.media == .audio and t.stts_count == 1 and t.stts.items.len > 0 and t.stts.items[0].duration == 1)) {
            try d.buildSampleIndex(t);
        } else {
            try d.buildChunkIndex(t);
        }
        _ = gpa;
        try d.checkEditList(t);
    }

    /// mov_merge_tts_data: the time-to-sample tables expanded to one entry
    /// per sample (`sample_count` of them, zeroed past the tables).
    fn mergeTts(d: *Demuxer, t: *Track, merge_stts: bool) Error!bool {
        const gpa = d.gpa;
        const ctts = t.ctts.items.len > 0;
        const stts = t.stts.items.len > 0 and merge_stts;
        if (t.ctts.items.len == 0 and t.stts.items.len == 0) return true;
        if (t.sample_count == 0 or @as(u64, t.sample_count) * 12 > max_alloc) return false;
        if (ctts or stts) {
            try t.tts.resize(gpa, t.sample_count);
            @memset(t.tts.items, .{});
        }
        var count: u32 = 0;
        if (ctts) {
            var idx: u32 = 0;
            outer: for (t.ctts.items) |e| {
                var j: u32 = 0;
                while (j < e.count) : (j += 1) {
                    if (idx >= t.sample_count) break :outer;
                    t.tts.items[idx] = .{ .count = 1, .offset = e.offset };
                    idx += 1;
                }
            }
            count = idx;
        } else {
            t.ctts_count = 0;
        }
        t.ctts.clearAndFree(gpa);
        if (stts) {
            var idx: u32 = 0;
            outer: for (t.stts.items) |e| {
                var j: u32 = 0;
                while (j < e.count) : (j += 1) {
                    if (idx >= t.sample_count) break :outer;
                    t.tts.items[idx].duration = e.duration;
                    t.tts.items[idx].count = 1;
                    idx += 1;
                }
            }
            count = @max(count, idx);
        } else {
            t.stts_count = 0;
        }
        t.stts.clearAndFree(gpa);
        if (ctts or stts) {
            // `tts_count`: the entries the tables filled; the rest stay
            // allocated and zeroed, and are read past the count.
            t.tts_count = count;
        }
        return true;
    }

    /// The index of one entry per sample.
    fn buildSampleIndex(d: *Demuxer, t: *Track) Error!void {
        const gpa = d.gpa;
        var current_dts: i64 = 0;
        if (current_dts < std.math.minInt(i64) + @as(i64, t.dts_shift)) return;
        current_dts -= t.dts_shift;
        if (t.sample_count == 0 or t.index.items.len > 0 or t.tts_count > 0) return;
        const n = try d.indexCount(t.sample_count) orelse return;
        try t.index.ensureTotalCapacity(gpa, n);
        if (!try d.mergeTts(t, true)) return;
        const keyframes = t.keyframes.items;
        const stps = t.stps.items;
        const stsc = t.stsc.items;
        const offsets = t.chunk_offsets.items;
        const key_off: u32 = @intFromBool((keyframes.len > 0 and keyframes[0] > 0) or (stps.len > 0 and stps[0] > 0));
        const rap_present = t.rap_group.items.len > 0;
        var stts_index: u32 = 0;
        var stsc_index: u32 = 0;
        var stss_index: u32 = 0;
        var stps_index: u32 = 0;
        var current_sample: u32 = 0;
        var stts_sample: u32 = 0;
        var rap_index: u32 = 0;
        var rap_sample: u32 = 0;
        var stream_size: u64 = 0;
        const tts_len: u32 = @intCast(t.tts.items.len);
        for (offsets, 0..) |chunk_offset, i| {
            const next_offset: i64 = if (i + 1 < offsets.len) offsets[i + 1] else std.math.maxInt(i64);
            var current_offset = chunk_offset;
            while (stsc_index + 1 < stsc.len and i + 1 == @as(u32, @bitCast(stsc[stsc_index + 1].first))) stsc_index += 1;
            const per_chunk: u32 = @bitCast(stsc[stsc_index].count);
            if (next_offset > current_offset and t.sample_size > 0 and t.sample_size < t.stsz_sample_size and
                @as(i64, stsc[stsc_index].count) * @as(i64, t.stsz_sample_size) > next_offset - current_offset)
            {
                // "STSZ sample size invalid (too large), ignoring".
                t.stsz_sample_size = t.sample_size;
            }
            if (t.stsz_sample_size > 0 and t.stsz_sample_size < t.sample_size) t.stsz_sample_size = t.sample_size;
            var j: u32 = 0;
            while (j < per_chunk) : (j += 1) {
                if (current_sample >= t.sample_count) return; // "wrong sample count"
                var keyframe = false;
                if (!t.keyframe_absent and (keyframes.len == 0 or current_sample +% key_off == keyframes[stss_index])) {
                    keyframe = true;
                    if (stss_index + 1 < keyframes.len) stss_index += 1;
                } else if (stps.len > 0 and current_sample +% key_off == stps[stps_index]) {
                    keyframe = true;
                    if (stps_index + 1 < stps.len) stps_index += 1;
                }
                if (rap_present and rap_index < t.rap_group.items.len) {
                    const g = t.rap_group.items[rap_index];
                    if (g.index > 0) keyframe = true;
                    rap_sample +%= 1;
                    if (rap_sample == g.count) {
                        rap_sample = 0;
                        rap_index += 1;
                    }
                }
                if (t.keyframe_absent and stps.len == 0 and !rap_present and (t.media == .audio or (i == 0 and j == 0))) keyframe = true;
                // A table shorter than the samples (FFmpeg reads past it)
                // ends the index.
                const sample_size: u32 = if (t.stsz_sample_size > 0) t.stsz_sample_size else if (current_sample < t.sample_sizes.items.len) t.sample_sizes.items[current_sample] else return;
                if (current_offset > std.math.maxInt(i64) - @as(i64, sample_size)) return;
                if (t.pseudo_stream_id == -1 or stsc[stsc_index].id -% 1 == t.pseudo_stream_id) {
                    if (sample_size > 0x3FFFFFFF) return; // "Sample size too large"
                    t.index.appendAssumeCapacity(.{ .pos = current_offset, .timestamp = current_dts, .size = sample_size, .key = keyframe });
                }
                current_offset += sample_size;
                stream_size +%= sample_size;
                // The merged entries are allocated for every sample.
                const delta: i64 = if (stts_index < tts_len) t.tts.items[stts_index].duration else 0;
                if (current_dts > std.math.maxInt(i64) - delta) return;
                current_dts += delta;
                stts_sample += 1;
                current_sample += 1;
                if (stts_index + 1 < t.tts_count and stts_sample == t.tts.items[stts_index].count) {
                    stts_sample = 0;
                    stts_index += 1;
                }
            }
        }
        if (t.duration > 0) {
            // Unsigned in FFmpeg: stream_size * 8 * time_scale / duration.
            const rate = stream_size *% 8 *% @as(u64, @intCast(t.time_scale)) / @as(u64, @intCast(t.duration));
            t.bit_rate = @bitCast(rate);
        }
    }

    /// The old uncompressed audio demuxing, when `stts` gives every sample
    /// one tick: a packet of up to 1024 samples (or whole frames) at a
    /// time from each chunk.
    fn buildChunkIndex(d: *Demuxer, t: *Track) Error!void {
        const gpa = d.gpa;
        const offsets = t.chunk_offsets.items;
        const stsc = t.stsc.items;
        if (offsets.len == 0 or t.tts_count > 0) return;
        const spf = t.samples_per_frame;
        var total: u32 = 0;
        for (stsc, 0..) |e, i| {
            const chunk_samples: u32 = @bitCast(e.count);
            if (i != stsc.len - 1 and spf != 0 and chunk_samples % spf != 0) return; // "error unaligned chunk"
            // Unsigned 32-bit arithmetic, as FFmpeg's.
            const count: u32 = if (spf >= 160)
                chunk_samples / spf
            else if (spf > 1) blk: {
                const samples = (1024 / spf) * spf;
                break :blk (chunk_samples +% samples -% 1) / samples;
            } else (chunk_samples +% 1023) / 1024;
            const chunk_count: u32 = if (i + 1 < stsc.len)
                @bitCast(stsc[i + 1].first -% e.first)
            else
                @as(u32, @intCast(offsets.len)) -% @as(u32, @bitCast(e.first -% 1));
            total +%= chunk_count *% count;
        }
        const n = try d.indexCount(total) orelse return;
        try t.index.ensureTotalCapacity(gpa, n);
        var current_dts: i64 = 0;
        var stsc_index: u32 = 0;
        for (offsets, 0..) |chunk_offset, i| {
            var current_offset = chunk_offset;
            if (stsc_index + 1 < stsc.len and i + 1 == @as(u32, @bitCast(stsc[stsc_index + 1].first))) stsc_index += 1;
            var chunk_samples: u32 = @bitCast(stsc[stsc_index].count);
            while (chunk_samples > 0) {
                if (spf > 1 and t.bytes_per_frame == 0) return; // "Zero bytes per frame"
                var samples: u32 = undefined;
                var size: u32 = undefined;
                if (spf >= 160) {
                    samples = spf;
                    size = t.bytes_per_frame;
                } else if (spf > 1) {
                    samples = @min((1024 / spf) * spf, chunk_samples);
                    size = (samples / spf) *% t.bytes_per_frame;
                } else {
                    samples = @min(1024, chunk_samples);
                    size = samples *% t.sample_size;
                }
                if (t.index.items.len >= total) return; // "wrong chunk count"
                if (size > 0x3FFFFFFF) return;
                t.index.appendAssumeCapacity(.{ .pos = current_offset, .timestamp = current_dts, .size = size, .key = true });
                current_offset +%= size;
                if (current_dts > std.math.maxInt(i64) - @as(i64, samples)) return;
                current_dts += samples;
                // Unsigned: a frame longer than the chunk wraps the count.
                chunk_samples -%= samples;
            }
        }
        _ = try d.mergeTts(t, false);
    }

    /// mov_fix_index with an edit list: accepted only when it leaves the
    /// index as it is (one edit from media time 0 covering every sample,
    /// rising timestamps from 0, no composition offsets), which sets the
    /// start time to 0, the duration to at most the edit's and the
    /// initial padding to 0. Any other edit list is refused (T33b).
    fn checkEditList(d: *Demuxer, t: *Track) Error!void {
        const edits = t.elst.items;
        if (edits.len == 0 or t.index.items.len == 0) return;
        const e = edits[0];
        if (edits.len != 1 or e.time != 0 or d.time_scale == 0 or t.dts_shift != 0) return error.UnsupportedFormat;
        for (t.tts.items[0..@min(t.tts_count, t.tts.items.len)]) |x| if (x.offset != 0) return error.UnsupportedFormat;
        var duration = rational.rescale(e.duration, t.time_scale, d.time_scale);
        if (duration < 0 or e.time > std.math.maxInt(i64) - duration) duration = 0;
        const index = t.index.items;
        if (index[0].timestamp != 0 or duration <= 0) return error.UnsupportedFormat;
        for (index[1..], 0..) |x, i| if (x.timestamp <= index[i].timestamp) return error.UnsupportedFormat;
        if (index[index.len - 1].timestamp >= duration) return error.UnsupportedFormat;
        t.start_time = 0;
        t.duration = @min(t.duration, duration);
        t.initial_padding = 0;
    }

    /// mov_read_header after the boxes: each track's primary extradata
    /// from the first sample's description, the bit rate of a file with a
    /// fragment index hint, and the decoder the read-ahead opens.
    fn finishHeader(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        if (d.in.seekable()) try d.readChapterTracks();
        for (d.tracks.items) |*t| {
            if (t.media == .video) return error.UnsupportedFormat;
            // A subtitle track is demuxed only as a chapter track that a
            // pipe leaves a subtitle stream (T33a3 for the others).
            if (t.media == .subtitle and (d.in.seekable() or std.mem.findScalar(i32, d.chapter_tracks.items, t.sc_id) == null))
                return error.UnsupportedFormat;
            fixTimescale(t, d.time_scale);
            if (t.stsc.items.len > 0) if (t.stsd_extradata) |list| {
                const id = t.stsc.items[0].id;
                if (id > 1 and id <= t.stsd_count) {
                    t.last_stsd_index = id - 1;
                    const chosen = list[@intCast(id - 1)];
                    const copy: ?[]u8 = if (chosen) |b| try gpa.dupe(u8, b) else null;
                    t.replaceExtradata(gpa, copy);
                }
            };
            if (t.media == .audio and t.codec == .aac) t.skip_samples = t.initial_padding;
            // HandBrake up to 0.10.2 wrote MP3 FFmpeg parses in full.
            if (d.handbrake_version != 0 and d.handbrake_version <= 1000000 * 0 + 1000 * 10 + 2 and t.codec == .mp3) t.parse_full = true;
        }
        for (d.tracks.items) |*t| {
            if (d.use_mfra and t.duration_for_fps > 0) {
                const rate = rational.rescale(t.data_size, @as(i64, t.time_scale) * 8, t.duration_for_fps);
                t.bit_rate = if (rate == std.math.minInt(i64)) 0 else rate;
            }
        }
        // An ISML manifest's bit rates, by stream.
        for (d.bitrates.items, 0..) |rate, i| {
            if (i >= d.tracks.items.len) break;
            if (rate != 0) d.tracks.items[i].bit_rate = rate;
        }
        for (d.tracks.items) |*t| {
            if (t.media == .audio) t.replaygain = mp3.replayGainFromTags(&d.tags);
            // A codec other than audio's in an audio track (an `esds`
            // object type), not modelled.
            if (t.media == .audio and (t.codec.isVideo() or t.codec == .mov_text or t.codec == .dvd_subtitle or t.codec == .mpeg4systems)) return error.UnsupportedFormat;
            t.decoder = decoderFor(t);
        }
    }

    // ---- Packets ----

    /// mov_find_next_sample: the track whose next sample comes first by
    /// position when the input cannot seek, else by time within a second
    /// and position, as FFmpeg interleaves.
    fn findNextSample(d: *Demuxer) ?usize {
        const no_interleave = !d.in.seekable();
        var best: ?usize = null;
        var best_dts: i64 = std.math.maxInt(i64);
        var best_pos: i64 = 0;
        for (d.tracks.items, 0..) |*t, i| {
            if (t.current_sample >= t.index.items.len) continue;
            const e = t.index.items[t.current_sample];
            const dts = rational.rescale(e.timestamp, time_base_units, t.time_scale);
            const diff: u64 = if (best_dts > dts) @as(u64, @bitCast(best_dts)) -% @as(u64, @bitCast(dts)) else @as(u64, @bitCast(dts)) -% @as(u64, @bitCast(best_dts));
            const take = best == null or (no_interleave and e.pos < best_pos) or
                (d.in.seekable() and dts != nopts and ((diff <= time_base_units and e.pos < best_pos) or
                    (diff > time_base_units and dts < best_dts)));
            if (take) {
                best = i;
                best_dts = dts;
                best_pos = e.pos;
            }
        }
        return best;
    }

    /// mov_read_packet: the next sample of any track, with mov_finalize_packet's
    /// timestamps, duration and flags; null at the end.
    pub fn next(d: *Demuxer) Error!?demux.SourcePacket {
        const gpa = d.gpa;
        d.in.keep_history = false;
        d.in.history.clearAndFree(gpa);
        d.new_extradata = null;
        while (true) {
            const i = d.findNextSample() orelse {
                if (d.next_root_atom == 0) return null;
                try d.switchRoot();
                continue;
            };
            const t = &d.tracks.items[i];
            var sample = t.index.items[t.current_sample];
            if (d.next_root_atom != 0 and sample.pos > d.next_root_atom) {
                try d.switchRoot();
                continue;
            }
            t.current_sample += 1;
            if (d.next_root_atom != 0) {
                sample.pos = @min(sample.pos, d.next_root_atom);
                sample.size = @intCast(@min(sample.size, d.next_root_atom - sample.pos));
            }
            var flags: u32 = 0;
            if (!t.discard) {
                if (!try d.in.seekTo(gpa, sample.pos)) {
                    // "partial file": AVERROR_EOF past the end, else tried
                    // again on the next read.
                    if (d.in.eof) return null;
                    t.current_sample -= 1;
                    return error.InvalidMov;
                }
                d.current.clearRetainingCapacity();
                try d.current.ensureTotalCapacity(gpa, @min(sample.size, 1 << 20));
                var left: usize = sample.size;
                while (left > 0) {
                    const step = @min(left, 1 << 20);
                    const old = d.current.items.len;
                    try d.current.resize(gpa, old + step);
                    const got = try d.in.read(gpa, d.current.items[old..]);
                    d.current.shrinkRetainingCapacity(old + got);
                    left -= got;
                    if (got < step) break;
                }
                if (left > 0) {
                    // av_get_packet: nothing read is the end; less, a
                    // corrupt packet.
                    if (d.current.items.len == 0) return null;
                    flags |= corrupt_flag;
                }
                // MP3 whose first packet has no frame header is parsed.
                if (t.codec == .mp3 and !t.parse_full and d.current.items.len > 4 and !mpegaudio.checkHeader(std.mem.readInt(u32, d.current.items[0..4], .big))) t.parse_full = true;
            }
            const pkt = d.finalizePacket(t, sample, flags);
            if (t.discard) continue;
            return pkt;
        }
    }

    const corrupt_flag: u32 = 2;
    const disposable_flag: u32 = 0x10;

    /// mov_finalize_packet.
    fn finalizePacket(d: *Demuxer, t: *Track, sample: IndexEntry, flags_in: u32) demux.SourcePacket {
        var flags = flags_in;
        const dts = sample.timestamp;
        var duration: i64 = 0;
        var pts: i64 = dts;
        const in_tts = t.tts_index < t.tts_count;
        if (t.stts_count > 0 and in_tts) duration = t.tts.items[t.tts_index].duration;
        if (t.ctts_count > 0 and in_tts) {
            pts = rational.satAdd(dts, rational.satAdd(t.dts_shift, t.tts.items[t.tts_index].offset));
        } else {
            if (duration == 0) {
                const next_dts = if (t.current_sample < t.index.items.len) t.index.items[t.current_sample].timestamp else t.duration;
                if (next_dts >= dts) duration = next_dts -% dts;
            }
        }
        if (t.media == .audio and t.current_sample >= t.index.items.len) {
            // The discard window at the end of the last packet.
            const rate_tb: rational.Rational = .{ .num = 1, .den = std.math.cast(i32, t.sample_rate) orelse 0 };
            const pts_samples = rational.rescaleQ(pts, t.time_base, rate_tb);
            const total = rational.rescaleQ(t.duration, t.time_base, rate_tb);
            var d_ticks: i64 = undefined;
            if (t.duration < pts) {
                d_ticks = 0;
            } else {
                // FFMIN of the duration with an unsigned difference.
                const diff: u64 = @as(u64, @bitCast(t.duration)) -% @as(u64, @bitCast(pts));
                d_ticks = @bitCast(@min(@as(u64, @bitCast(duration)), diff));
            }
            const d_samples = rational.rescaleQ(d_ticks, t.time_base, rate_tb);
            if (t.first_discard_sample == 0) t.first_discard_sample = rational.satAdd(pts_samples, d_samples);
            if (t.last_discard_sample == 0) t.last_discard_sample = total;
        }
        if (t.tts.items.len > 0 and in_tts) {
            t.tts_sample += 1;
            if (t.tts.items[t.tts_index].count == t.tts_sample) {
                t.tts_index += 1;
                t.tts_sample = 0;
            }
        }
        if (t.sdtp.items.len > 0 and t.current_sample <= t.sdtp.items.len) {
            const depended_on = (t.sdtp.items[t.current_sample - 1] >> 2) & 3;
            if (depended_on == 2) flags |= disposable_flag;
        }
        if (sample.key) flags |= demux.key_flag;
        // Multiple sample descriptions: new extradata when the chunk's
        // description changes.
        var new_extradata: ?[]const u8 = null;
        const stsc = t.stsc.items;
        if (stsc.len > 0) {
            const id = stsc[t.stsc_index].id;
            if (id > 0 and id - 1 < t.stsd_count and id - 1 != t.last_stsd_index) {
                t.last_stsd_index = id - 1;
                if (t.stsd_extradata) |list| if (list[@intCast(id - 1)]) |e| {
                    if (e.len > 0) new_extradata = e;
                };
            }
            t.stsc_sample += 1;
            const i = t.stsc_index;
            if (i + 1 < stsc.len and @as(i64, stsc[i + 1].first -% stsc[i].first) * stsc[i].count == t.stsc_sample) {
                t.stsc_index += 1;
                t.stsc_sample = 0;
            }
        }
        return .{
            .stream = d.trackIndex(t),
            .data = d.current.items,
            .pts = pts,
            .dts = dts,
            .duration = duration,
            .flags = flags,
            .pos = sample.pos,
            .new_extradata = new_extradata,
        };
    }

    fn trackIndex(d: *const Demuxer, t: *const Track) usize {
        return (@intFromPtr(t) - @intFromPtr(d.tracks.items.ptr)) / @sizeOf(Track);
    }

    /// mov_switch_root at `next_root_atom`, on a source that cannot seek:
    /// the boxes after the `mdat` read (a later `moov` is skipped).
    fn switchRoot(d: *Demuxer) Error!void {
        const gpa = d.gpa;
        const target = d.next_root_atom;
        if (target >= 0 and !try d.in.seekTo(gpa, target)) return error.InvalidMov; // "partial file"
        d.next_root_atom = 0;
        d.found_mdat = false;
        try d.readDefault(.{ .type = tag("root"), .size = std.math.maxInt(i64) });
        if (try d.in.feof(gpa)) d.next_root_atom = 0;
    }

    // ---- demux.zig's Source ----

    pub fn streamCount(d: *const Demuxer) usize {
        return d.tracks.items.len;
    }

    pub fn track(d: *const Demuxer, i: usize) *const Track {
        return &d.tracks.items[i];
    }

    /// What libavformat's layer needs of track `i`.
    pub fn setup(d: *const Demuxer, i: usize) demux.Setup {
        const t = &d.tracks.items[i];
        const audio = t.media == .audio;
        return .{
            .known = !audio or t.codec != .none,
            .media = switch (t.media) {
                .audio => .audio,
                .subtitle => .subtitle,
                .video, .data => .data,
            },
            .time_base = t.time_base,
            .sample_rate = std.math.cast(u32, t.sample_rate) orelse 0,
            .channels = std.math.cast(u8, t.channelCount()) orelse 0,
            .parser = if (!audio or !t.parse_full) .none else switch (t.codec) {
                .ac3, .eac3 => .ac3_full,
                .mp1, .mp2, .mp3 => .mpegaudio_full,
                else => .none,
            },
            .decoder = t.decoder,
            .intra_only = t.codec.intraOnly(),
            .bit_rate = t.bit_rate,
            .initial_padding = std.math.cast(u32, t.initial_padding) orelse 0,
            .seek_preroll = std.math.cast(u32, t.seek_preroll) orelse 0,
            .frame_size = std.math.cast(u32, t.frame_size) orelse 0,
            .skip_samples = t.skip_samples,
            .first_discard_sample = t.first_discard_sample,
            .last_discard_sample = t.last_discard_sample,
            .extradata = t.extradata orelse &.{},
            .mpa_codec = switch (t.codec) {
                .mp1 => .mp1,
                .mp2 => .mp2,
                .mp3 => .mp3,
                else => null,
            },
        };
    }

    pub fn durationOf(d: *Demuxer, i: usize) *i64 {
        return &d.tracks.items[i].duration;
    }

    pub fn startTime(d: *Demuxer, i: usize) *i64 {
        return &d.tracks.items[i].start_time;
    }

    pub fn fileSize(d: *const Demuxer) ?u64 {
        const size = d.in.size orelse return null;
        return @intCast(size);
    }

    pub fn dataOffset(d: *const Demuxer) i64 {
        return d.data_offset;
    }

    /// Seeking is T33b: the generic layer's byte seek repositions only.
    pub fn reposition(d: *Demuxer, pos: i64) Error!void {
        if (!d.in.seekable()) return error.IoFailure;
        _ = try d.in.seekTo(d.gpa, pos);
    }

    pub fn ioRepositioned(d: *Demuxer) void {
        _ = d;
    }

    pub fn readTimestamp(d: *Demuxer, i: usize, pos: *i64, pos_limit: i64) Error!i64 {
        _ = d;
        _ = i;
        _ = pos;
        _ = pos_limit;
        return nopts;
    }

    /// mov_read_seek is T33b: refused, so no seek moves the samples.
    pub fn readSeek(d: *Demuxer, layer: anytype, i: usize, ts: i64, flags: seek.Flags) Error!bool {
        _ = d;
        _ = layer;
        _ = i;
        _ = ts;
        _ = flags;
        return error.UnsupportedFormat;
    }
};

// ---- Metadata tables and text (T33a2) ----

/// How mov_read_udta_string reads a key's value.
const UdtaParse = enum {
    /// A string.
    none,
    /// The bytes as they are.
    raw,
    /// mov_metadata_int8_no_padding.
    int8,
    /// mov_metadata_int8_bypass_padding.
    int8_padded,
    /// mov_metadata_gnre.
    gnre,
    /// mov_metadata_track_or_disc_number.
    number,
};

const UdtaKey = struct { key: []const u8, parse: UdtaParse = .none };

/// A © tag: 0xA9 then three letters.
fn ctag(comptime s: *const [3]u8) u32 {
    return std.mem.readInt(u32, &([1]u8{0xa9} ++ s.*), .little);
}

/// mov_read_udta_string's keys (`XMP_` only with `export_xmp`, off).
fn udtaKey(t: u32) ?UdtaKey {
    return switch (t) {
        tag("@PRM") => .{ .key = "premiere_version", .parse = .raw },
        tag("@PRQ") => .{ .key = "quicktime_version", .parse = .raw },
        tag("aART") => .{ .key = "album_artist" },
        tag("akID") => .{ .key = "account_type", .parse = .int8 },
        tag("apID") => .{ .key = "account_id" },
        tag("catg") => .{ .key = "category" },
        tag("cpil") => .{ .key = "compilation", .parse = .int8 },
        tag("cprt") => .{ .key = "copyright" },
        tag("desc") => .{ .key = "description" },
        tag("disk") => .{ .key = "disc", .parse = .number },
        tag("egid") => .{ .key = "episode_uid", .parse = .int8 },
        tag("FIRM") => .{ .key = "firmware", .parse = .raw },
        tag("gnre") => .{ .key = "genre", .parse = .gnre },
        tag("hdvd") => .{ .key = "hd_video", .parse = .int8 },
        tag("keyw") => .{ .key = "keywords" },
        tag("ldes") => .{ .key = "synopsis" },
        tag("manu") => .{ .key = "make" },
        tag("modl") => .{ .key = "model" },
        tag("name") => .{ .key = "name" },
        tag("pcst") => .{ .key = "podcast", .parse = .int8 },
        tag("pgap") => .{ .key = "gapless_playback", .parse = .int8 },
        tag("purd") => .{ .key = "purchase_date" },
        tag("rtng") => .{ .key = "rating", .parse = .int8 },
        tag("soaa") => .{ .key = "sort_album_artist" },
        tag("soal") => .{ .key = "sort_album" },
        tag("soar") => .{ .key = "sort_artist" },
        tag("soco") => .{ .key = "sort_composer" },
        tag("sonm") => .{ .key = "sort_name" },
        tag("sosn") => .{ .key = "sort_show" },
        tag("stik") => .{ .key = "media_type", .parse = .int8 },
        tag("trkn") => .{ .key = "track", .parse = .number },
        tag("tven") => .{ .key = "episode_id" },
        tag("tves") => .{ .key = "episode_sort", .parse = .int8_padded },
        tag("tvnn") => .{ .key = "network" },
        tag("tvsh") => .{ .key = "show" },
        tag("tvsn") => .{ .key = "season_number", .parse = .int8_padded },
        ctag("ART") => .{ .key = "artist" },
        ctag("PRD") => .{ .key = "producer" },
        ctag("alb") => .{ .key = "album" },
        ctag("aut") => .{ .key = "artist" },
        ctag("chp") => .{ .key = "chapter" },
        ctag("cmt") => .{ .key = "comment" },
        ctag("com") => .{ .key = "composer" },
        ctag("cpy") => .{ .key = "copyright" },
        ctag("day") => .{ .key = "date" },
        ctag("dir") => .{ .key = "director" },
        ctag("dis") => .{ .key = "disclaimer" },
        ctag("ed1") => .{ .key = "edit_date" },
        ctag("enc") => .{ .key = "encoder" },
        ctag("fmt") => .{ .key = "original_format" },
        ctag("gen") => .{ .key = "genre" },
        ctag("grp") => .{ .key = "grouping" },
        ctag("hst") => .{ .key = "host_computer" },
        ctag("inf") => .{ .key = "comment" },
        ctag("lyr") => .{ .key = "lyrics" },
        ctag("mak") => .{ .key = "make" },
        ctag("mod") => .{ .key = "model" },
        ctag("nam") => .{ .key = "title" },
        ctag("ope") => .{ .key = "original_artist" },
        ctag("prd") => .{ .key = "producer" },
        ctag("prf") => .{ .key = "performers" },
        ctag("req") => .{ .key = "playback_requirements" },
        ctag("src") => .{ .key = "original_source" },
        ctag("st3") => .{ .key = "subtitle" },
        ctag("swr") => .{ .key = "encoder" },
        ctag("too") => .{ .key = "encoder" },
        ctag("trk") => .{ .key = "track" },
        ctag("url") => .{ .key = "URL" },
        ctag("wrn") => .{ .key = "warning" },
        ctag("wrt") => .{ .key = "composer" },
        ctag("xyz") => .{ .key = "location" },
        else => null,
    };
}

/// `mac_to_unicode`: Mac Roman's upper half.
const mac_to_unicode = [128]u16{
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
};

/// PUT_UTF8 into `out` while it holds fewer than `limit` bytes: a
/// character the limit cuts keeps its first bytes.
fn putUtf8(gpa: std.mem.Allocator, out: *std.ArrayList(u8), val: u32, limit: usize) error{OutOfMemory}!void {
    // Mac Roman's characters and UTF-16's: at most 4 bytes.
    std.debug.assert(val <= 0x10FFFF);
    if (val < 0x80) {
        if (out.items.len < limit) try out.append(gpa, @intCast(val));
        return;
    }
    // av_log2(val) + 4) / 5 bytes.
    const bytes: u5 = @intCast((31 - @clz(val) + 4) / 5);
    var shift: u5 = (bytes - 1) * 6;
    const lead: u32 = (@as(u32, 256) - (@as(u32, 256) >> bytes)) | (val >> shift);
    if (out.items.len < limit) try out.append(gpa, @truncate(lead));
    while (shift >= 6) {
        shift -= 6;
        if (out.items.len < limit) try out.append(gpa, @truncate(0x80 | ((val >> shift) & 0x3f)));
    }
}

/// A C string: the bytes before the first NUL.
fn cString(b: []const u8) []const u8 {
    return b[0 .. std.mem.findScalar(u8, b, 0) orelse b.len];
}

/// A 16.16 fixed-point value as FFmpeg computes it: the int made a float,
/// divided in float.
fn fixed16(raw: u32) f32 {
    const v: i32 = @bitCast(raw);
    const f: f32 = @floatFromInt(v);
    return f / 65536.0;
}

const FixedOptions = struct {
    precision: u5,
    /// The `+` flag.
    plus: bool = false,
    /// A minimum width, padded with zeros after the sign (the `0` flag).
    width: usize = 0,
};

/// glibc's `%f` of a float (promoted to double): the exact value rounded
/// to `precision` decimals, ties to even; `nan`, `inf` with their sign.
fn formatFixed(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: f32, opts: FixedOptions) error{OutOfMemory}!void {
    const bits: u32 = @bitCast(v);
    const negative = bits >> 31 != 0;
    const sign: []const u8 = if (negative) "-" else if (opts.plus) "+" else "";
    const exp_bits: u8 = @truncate(bits >> 23);
    const frac: u32 = bits & 0x7fffff;
    if (exp_bits == 0xff) {
        // The `0` flag pads these with spaces.
        const word: []const u8 = if (frac != 0) "nan" else "inf";
        const len = sign.len + word.len;
        if (opts.width > len) try out.appendNTimes(gpa, ' ', opts.width - len);
        try out.appendSlice(gpa, sign);
        try out.appendSlice(gpa, word);
        return;
    }
    // |v| = mantissa * 2^exponent, exactly.
    const mantissa: u256 = if (exp_bits == 0) frac else frac | (1 << 23);
    const exponent: i32 = (if (exp_bits == 0) @as(i32, 1) else exp_bits) - 150;
    var scale: u256 = 1;
    for (0..opts.precision) |_| scale *= 10;
    var scaled: u256 = undefined;
    if (exponent >= 0) {
        scaled = (mantissa << @intCast(exponent)) * scale;
    } else {
        const shift: u8 = @intCast(-exponent);
        const product = mantissa * scale;
        scaled = product >> shift;
        const rem = product - (scaled << shift);
        const half = @as(u256, 1) << (shift - 1);
        if (rem > half or (rem == half and scaled & 1 != 0)) scaled += 1;
    }
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(gpa);
    try digits.print(gpa, "{d}", .{scaled / scale});
    if (opts.precision > 0) {
        try digits.append(gpa, '.');
        var fraction = scaled % scale;
        const at = digits.items.len;
        try digits.appendNTimes(gpa, '0', opts.precision);
        var k: usize = opts.precision;
        while (k > 0) : (k -= 1) {
            digits.items[at + k - 1] = '0' + @as(u8, @intCast(fraction % 10));
            fraction /= 10;
        }
    }
    try out.appendSlice(gpa, sign);
    const len = sign.len + digits.items.len;
    if (opts.width > len) try out.appendNTimes(gpa, '0', opts.width - len);
    try out.appendSlice(gpa, digits.items);
}

/// `sscanf(str, "HandBrake %d.%d.%d")` matching all three: the version as
/// 1000000 * major + 1000 * minor + micro (an int, wrapping).
fn handBrakeVersion(text: []const u8) ?i32 {
    const prefix = "HandBrake";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    var at: usize = prefix.len;
    var parts: [3]i32 = undefined;
    for (&parts, 0..) |*part, i| {
        if (i > 0) {
            if (at >= text.len or text[at] != '.') return null;
            at += 1;
        }
        const parsed = scanInt(text[at..]) orelse return null;
        part.* = parsed.value;
        at += parsed.len;
    }
    // The reference build's int arithmetic wraps (notes.md "Follow the
    // reference build").
    return 1000000 *% parts[0] +% 1000 *% parts[1] +% parts[2];
}

/// scanf's `%d`: white space, a sign, decimal digits (at least one), as
/// strtol reads them (saturating), stored into an int (truncating, as
/// glibc stores its long).
fn scanInt(text: []const u8) ?struct { value: i32, len: usize } {
    const parsed = strtol10(text);
    if (parsed.len == 0) return null;
    return .{ .value = @truncate(parsed.value), .len = parsed.len };
}

/// strtol with base 10: white space, a sign, digits; the value, saturated
/// on overflow (when `errno` is ERANGE), and the bytes used (0 without a
/// digit).
fn strtol10(text: []const u8) struct { value: i64, len: usize, overflow: bool } {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    const start = i;
    var magnitude: u64 = 0;
    var overflow = false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        const step = @mulWithOverflow(magnitude, 10);
        const sum = @addWithOverflow(step[0], text[i] - '0');
        if (step[1] != 0 or sum[1] != 0) overflow = true;
        magnitude = sum[0];
    }
    if (i == start) return .{ .value = 0, .len = 0, .overflow = false };
    const limit: u64 = if (negative) 1 << 63 else std.math.maxInt(i64);
    if (overflow or magnitude > limit) {
        return .{ .value = if (negative) std.math.minInt(i64) else std.math.maxInt(i64), .len = i, .overflow = true };
    }
    const value: i64 = if (negative) @bitCast(0 -% magnitude) else @intCast(magnitude);
    return .{ .value = value, .len = i, .overflow = false };
}

/// `dash_role_map` of `ff_mov_track_kind_table`.
const dash_roles = [_]struct { value: []const u8, disposition: u32 }{
    .{ .value = "caption", .disposition = 0x80 | 0x10000 },
    .{ .value = "commentary", .disposition = 0x8 },
    .{ .value = "description", .disposition = 0x100 | 0x20000 },
    .{ .value = "dub", .disposition = 0x2 },
    .{ .value = "forced-subtitle", .disposition = 0x40 },
};

const uuid_isml_manifest = [16]u8{ 0xa5, 0xd4, 0x0b, 0x30, 0xe8, 0x14, 0x11, 0xdd, 0xba, 0x2f, 0x08, 0x00, 0x20, 0x0c, 0x9a, 0x66 };
const uuid_xmp = [16]u8{ 0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, 0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac };
const uuid_spherical = [16]u8{ 0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93, 0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd };

/// The `max_stts_delta` option's default: larger `stts` deltas are
/// corrections.
const max_stts_delta: u32 = std.math.maxInt(u32) - 48000 * 10;

/// mov_read_stsc's repair of invalid entries, from the last back.
fn fixStsc(list: *std.ArrayList(Stsc)) void {
    var i: usize = list.items.len;
    while (i > 0) {
        i -= 1;
        const data = list.items;
        const first_min: i64 = @intCast(i + 1);
        const e = &data[i];
        const invalid = (i + 1 < data.len and e.first >= data[i + 1].first) or
            (i > 0 and e.first <= data[i - 1].first) or
            e.first < first_min or e.count < 1 or e.id < 1;
        if (!invalid) continue;
        if (i + 1 >= data.len) {
            if (e.count == 0 and i > 0) {
                list.shrinkRetainingCapacity(list.items.len - 1);
                continue;
            }
            // first_min is at most the entry count, an int.
            e.first = @intCast(@max(e.first, first_min));
            if (i > 0 and e.first <= data[i - 1].first) e.first = @intCast(@min(@as(i64, data[i - 1].first) + 1, std.math.maxInt(i32)));
            e.count = @max(e.count, 1);
            e.id = @max(e.id, 1);
            continue;
        }
        // The next entry, already valid, starts at chunk 2 or later.
        e.* = .{ .first = data[i + 1].first - 1, .count = data[i + 1].count, .id = data[i + 1].id };
    }
}

/// sanity_checks: 0, 1 for a track left without its index, 2 for a broken
/// one.
fn sanityChecks(t: *const Track) u8 {
    const chunk_count = t.chunk_offsets.items.len;
    const has_sizes = t.sample_sizes.items.len > 0;
    if ((chunk_count > 0 and (t.stts_count == 0 or t.stsc.items.len == 0 or (t.sample_size == 0 and t.sample_count == 0))) or
        (t.sample_count > 0 and (chunk_count == 0 or (t.sample_size == 0 and !has_sizes))))
        return 1;
    if (t.stsc.items.len > 0 and t.stsc.items[t.stsc.items.len - 1].first > chunk_count) return 2;
    return 0;
}

fn fixTimescale(t: *Track, movie_time_scale: i32) void {
    if (t.time_scale > 0) return;
    t.time_scale = movie_time_scale;
    if (t.time_scale <= 0) t.time_scale = 1;
}

/// mov_skip_multiple_stsd: a second description of another format is
/// skipped (FFmpeg demuxes only one).
fn skipMultipleStsd(codec_tag: u32, format: u32) bool {
    return codec_tag != 0 and codec_tag != format and
        (codec_tag != tag("AV1x") or format != tag("AVup")) and
        codec_tag != tag("apcn") and codec_tag != tag("apch") and
        codec_tag != tag("dvpp") and codec_tag != tag("dvcp") and
        codec_tag != tag("jpeg");
}

/// mov_codec_id: the codec of a sample description's format, the track's
/// media type as the tag tables give it, and the codec tag.
fn codecFromTag(t: *Track, format: u32) Error!Codec {
    var id = movAudioCodec(format);
    if (id == .none and (format & 0xFFFF == 'm' + ('s' << 8) or format & 0xFFFF == 'T' + ('S' << 8))) {
        // A WAV codec tag (ff_codec_wav_tags), not modelled.
        return error.UnsupportedFormat;
    }
    if (t.media != .video and id != .none) {
        t.media = .audio;
    } else if (t.media != .audio and format != 0 and format != tag("mp4s")) {
        id = .none;
        if (isVideoTag(format)) {
            t.media = .video;
        } else if (t.media == .data or (t.media == .subtitle and t.codec == .none)) {
            // ff_codec_movsubtitle_tags, MP4's and ISMV's TTML, then
            // ff_codec_movdata_tags.
            if (format == tag("text") or format == tag("tx3g")) {
                id = .mov_text;
            } else if (format == tag("c608")) {
                id = .eia_608;
            } else if (format == tag("stpp") or format == tag("dfxp")) {
                id = .ttml;
            }
            if (id != .none) {
                t.media = .subtitle;
            } else if (format == tag("gpmd")) {
                id = .bin_data;
            } else if (format == tag("it35")) {
                return error.UnsupportedFormat; // itut_t35
            }
        }
    }
    t.codec_tag = format;
    return id;
}

/// av_fourcc_make_string.
fn fourccString(buf: *[32]u8, fourcc: u32) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var v = fourcc;
    for (0..4) |_| {
        const c: u8 = @truncate(v);
        const printable = std.ascii.isAlphanumeric(c) or c == '.' or c == ' ' or c == '-' or c == '_';
        if (printable) w.writeByte(c) catch unreachable else w.print("[{d}]", .{c}) catch unreachable; // at most 20 bytes
        v >>= 8;
    }
    return w.buffered();
}

/// ff_dict_set_timestamp's text for a whole second since 1970, UTC.
fn formatTimestamp(buf: *[40]u8, seconds: i64) []const u8 {
    const days = @divFloor(seconds, 86400);
    const rem = @mod(seconds, 86400);
    // Howard Hinnant's civil_from_days.
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000000Z", .{
        year, @as(u64, @intCast(month)), @as(u64, @intCast(day)), @as(u64, @intCast(@divTrunc(rem, 3600))), @as(u64, @intCast(@divTrunc(@mod(rem, 3600), 60))), @as(u64, @intCast(@mod(rem, 60))),
    }) catch unreachable; // a year of at most 12 digits
}

/// The decoder FFmpeg's read-ahead opens for a track, and whether it
/// accepts the track's parameters (avcodec_open2).
fn decoderFor(t: *const Track) demux.Decoder {
    if (t.media != .audio) return .none;
    const channels = t.channelCount();
    // avcodec_open2: more than FF_SANE_NB_CHANNELS fails.
    if (channels > 512) return if (t.codec.hasDecoder()) .refuses else .none;
    return switch (t.codec) {
        .aac => .aac,
        .ac3, .eac3 => .ac3,
        .mp1, .mp2, .mp3 => .mpegaudio,
        .flac => if (flacStreamInfo(t.extradata)) |_| .format_at_open else .refuses,
        .alac => blk: {
            const e = t.extradata orelse break :blk .refuses;
            _ = alac.Config.parse(e, std.math.cast(u32, channels) orelse 0) catch break :blk .refuses;
            break :blk .format_at_open;
        },
        .opus => blk: {
            const e = t.extradata orelse break :blk .refuses;
            _ = opusdec.Head.parse(e) catch break :blk .refuses;
            break :blk .format_at_open;
        },
        .vorbis => .refuses,
        else => if (t.codec.hasDecoder())
            // A decoder without AV_CODEC_CAP_CHANNEL_CONF needs a count.
            (if (channels > 0) .format_at_open else .refuses)
        else
            .none,
    };
}

/// ff_flac_is_extradata_valid and ff_flac_parse_streaminfo's checks: the
/// STREAMINFO FLAC's decoder opens with, or null where it refuses.
fn flacStreamInfo(extradata: ?[]const u8) ?flac.StreamInfo {
    const e = extradata orelse return null;
    if (e.len < flac.streaminfo_size) return null;
    var body: []const u8 = e;
    if (std.mem.eql(u8, e[0..4], "fLaC")) {
        if (e.len < 8 + flac.streaminfo_size) return null;
        body = e[8..];
    }
    const info = flac.StreamInfo.parse(body[0..flac.streaminfo_size]);
    if (info.max_blocksize < flac.min_blocksize or info.bps < 4) return null;
    return info;
}

/// A stream as avformat_find_stream_info leaves it: the demuxer's codec
/// parameters, what the decoder the read-ahead opened sets when it opens,
/// and what its parser and decoders set from the packets.
pub const StreamInfo = struct {
    media: Media,
    codec: []const u8,
    sample_rate: i64,
    /// The channel layout; unspecified holds the count.
    layout: Layout,
    time_base: rational.Rational,
    duration: i64,
    start_time: i64,
    initial_padding: i64,
    bit_rate: i64,
    disposition: u32,
    id: i32,
    codec_tag: u32,
    bits_per_coded_sample: i64,
    bits_per_raw_sample: i64,
    frame_size: i64,
    block_align: i64,
    /// `AV_PROFILE_UNKNOWN` is null.
    profile: ?i32,
    nb_frames: i64,
    seek_preroll: i64,
    extradata: []const u8,
};

/// `ff_flac_set_channel_layout`'s table.
const flac_layouts = [8]u64{ 0x4, 0x3, 0x7, 0x33, 0x607, 0x60f, 0x70f, 0x63f };

/// Track `i` after `layer`'s avformat_find_stream_info.
pub fn streamInfo(d: *Demuxer, layer: anytype, i: usize) Demuxer.ReadError!StreamInfo {
    const t = &d.tracks.items[i];
    const cp = try layer.contextParams(i);
    var codec: []const u8 = t.codec.name();
    var sample_rate = t.sample_rate;
    var layout: Layout = t.layout orelse .{ .unspecified = std.math.cast(u32, t.channels) orelse 0 };
    var bits_per_raw: i64 = 0;
    var frame_size = t.frame_size;
    var bit_rate = t.bit_rate;
    var profile: ?i32 = null;
    var seek_preroll = t.seek_preroll;
    var disposition = t.disposition;
    if (cp.decoder_opened) switch (t.codec) {
        .pcm_s24be, .pcm_s24le, .pcm_s32be, .pcm_s32le => bits_per_raw = t.codec.bitsPerSample(),
        .flac => if (flacStreamInfo(t.extradata)) |info| {
            sample_rate = info.sample_rate;
            bits_per_raw = info.bps;
            if (!(info.channels == layout.channelCount() and layout != .unspecified)) {
                layout = if (info.channels <= flac_layouts.len) .{ .native = flac_layouts[info.channels - 1] } else .{ .unspecified = info.channels };
            }
        },
        .alac => if (t.extradata) |e| if (alac.Config.parse(e, std.math.cast(u32, t.channelCount()) orelse 0)) |cfg| {
            bits_per_raw = cfg.sample_size;
            sample_rate = @as(i32, @bitCast(cfg.sample_rate));
            layout = .{ .native = alac.channel_masks[cfg.channels - 1] };
        } else |_| {},
        .opus => if (t.extradata) |e| if (opusdec.Head.parse(e)) |head| {
            sample_rate = 48000;
            layout = head.layout;
        } else |_| {},
        else => {},
    };
    if (cp.decoder_opened and bit_rate == 0) {
        // avcodec_open2's get_bit_rate for a decoder opened without one.
        const bps: i64 = t.codec.bitsPerSample();
        if (bps != 0) {
            const product = std.math.mul(i64, sample_rate, layout.channelCount()) catch 0;
            bit_rate = if (product > @divTrunc(std.math.maxInt(i64), bps)) 0 else product * bps;
        }
    }
    if (cp.sample_rate) |r| sample_rate = r;
    if (cp.mask) |m| {
        layout = .{ .native = m };
    } else if (cp.channels) |c| {
        if (cp.unspecified or c != layout.channelCount()) layout = if (cp.unspecified) .{ .unspecified = c } else Layout.default(c);
    }
    if (cp.frame_size) |f| frame_size = f;
    if (cp.bit_rate) |b| bit_rate = b;
    if (cp.profile) |p| profile = p;
    if (cp.seek_preroll) |p| seek_preroll = p;
    if (cp.mpa_codec) |c| codec = @tagName(c);
    if (cp.eac3) codec = "eac3";
    if (cp.service_type) |st| disposition |= switch (st) {
        1 => 0x200,
        3 => 0x100,
        4 => 0x80,
        5 => 0x8,
        8 => 0x20,
        else => 0,
    };
    // avcodec_parameters_from_context keeps the audio fields of audio
    // streams only (a chapter track made data loses its rate; its layout
    // is restored).
    const audio = t.media == .audio;
    return .{
        .media = t.media,
        .codec = if (t.codec == .none) "none" else codec,
        .sample_rate = if (audio) sample_rate else 0,
        .layout = layout,
        .time_base = t.time_base,
        .duration = t.duration,
        .start_time = t.start_time,
        .initial_padding = if (audio) t.initial_padding else 0,
        .bit_rate = bit_rate,
        .disposition = disposition,
        .id = t.id,
        .codec_tag = t.codec_tag,
        .bits_per_coded_sample = t.bits_per_coded_sample,
        .bits_per_raw_sample = bits_per_raw,
        .frame_size = if (audio) frame_size else 0,
        .block_align = if (audio) t.block_align else 0,
        .profile = profile,
        .nb_frames = t.nb_frames,
        .seek_preroll = if (audio) seek_preroll else 0,
        .extradata = t.extradata orelse &.{},
    };
}

/// The chapters after `layer`'s avformat_find_stream_info, which ends
/// them (compute_chapters_end) from the format's start and duration.
pub fn chapterList(d: *Demuxer, layer: anytype) error{OutOfMemory}![]const chapters_mod.Chapter {
    try d.chapters.computeEnds(d.gpa, layer.start_time, layer.duration);
    return d.chapters.items.items;
}

/// mov_probe on a probe buffer.
pub fn probeScore(buf: []const u8) u8 {
    var offset: u64 = 0;
    var score: u8 = 0;
    var moov_offset: ?u64 = null;
    const len: u64 = buf.len;
    while (true) {
        if (offset + 8 > len) break;
        const at: usize = @intCast(offset);
        var size: u64 = std.mem.readInt(u32, buf[at..][0..4], .big);
        var minsize: u64 = 8;
        if (size == 1 and offset + 16 <= len) {
            size = std.mem.readInt(u64, buf[at + 8 ..][0..8], .big);
            minsize = 16;
        } else if (size == 0) {
            size = len - offset;
        }
        // int64_t in FFmpeg: a size from 2^63 up is negative, below minsize.
        if (size >= 1 << 63 or size < minsize) {
            offset += 4;
            continue;
        }
        const t = std.mem.readInt(u32, buf[at + 4 ..][0..4], .little);
        switch (t) {
            tag("moov"), tag("mdat"), tag("pnot"), tag("udta"), tag("ftyp") => {
                if (t == tag("moov")) moov_offset = offset + 4;
                // The brand right after the type: past the buffer, FFmpeg's
                // padding reads zeros.
                const brand: u32 = if (offset + 12 <= len) std.mem.readInt(u32, buf[at + 8 ..][0..4], .little) else if (offset + 8 < len) blk: {
                    var b: [4]u8 = @splat(0);
                    @memcpy(b[0 .. len - offset - 8], buf[at + 8 ..]);
                    break :blk std.mem.readInt(u32, &b, .little);
                } else 0;
                if (t == tag("ftyp") and (brand == tag("jp2 ") or brand == tag("jpx ") or brand == tag("jxl "))) {
                    score = @max(score, 5);
                } else {
                    score = 100;
                }
            },
            tag("ediw"), tag("wide"), tag("free"), tag("junk"), tag("pict") => score = @max(score, 100 - 5),
            std.mem.readInt(u32, &[4]u8{ 0x82, 0x82, 0x7f, 0x7d }, .little) => score = @max(score, 50 - 5),
            tag("skip"), tag("uuid"), tag("prfl") => score = @max(score, 50),
            else => {},
        }
        if (size > std.math.maxInt(i64) - offset) break;
        offset += size;
    }
    if (score > 100 - 50) if (moov_offset) |start| {
        // A MOV-packed MPEG program stream: a low score.
        var o = start;
        while (len >= 16 and o < len - 16) : (o += 2) {
            const at: usize = @intCast(o);
            if (std.mem.readInt(u32, buf[at..][0..4], .little) == tag("hdlr") and
                std.mem.readInt(u32, buf[at + 8 ..][0..4], .little) == tag("mhlr") and
                std.mem.readInt(u32, buf[at + 12 ..][0..4], .little) == tag("MPEG"))
                return 5;
        }
    };
    return score;
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const vectors = @embedFile("../testing/vectors/mov.txt");

/// The vector lines of one fixture, after its `F` line.
fn block(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, vectors, at, '\n') orelse vectors.len;
        const end = std.mem.findPos(u8, vectors, line_end, "\nF ") orelse vectors.len;
        if (std.mem.eql(u8, vectors[at + 2 .. line_end], name)) return vectors[line_end + 1 .. @min(end + 1, vectors.len)];
        start = end;
    }
    return null;
}

/// Adler-32 from 0, as `av_adler32_update(0, ...)` gives it.
fn adler(data: []const u8) u32 {
    var a: u32 = 0;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeTs(out: *std.ArrayList(u8), gpa: std.mem.Allocator, ts: ?i64) !void {
    if (ts) |v| {
        if (v != nopts) return out.print(gpa, " {d}", .{v});
    }
    try out.appendSlice(gpa, " N");
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidMov => "INVALIDDATA",
        error.Truncated => "EOF",
        error.PatchWelcome => "PATCHWELCOME",
        error.OutOfRange => "-34",
        else => @errorName(err),
    };
}

const media_letter = [_]u8{ 'a', 'v', 'd', 's' };

/// mov_vectors.c's lines for a fixture, from the demuxer and libavformat's
/// layer.
fn vectorLines(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, out: *std.ArrayList(u8)) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const opened = if (seekable) Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{}) else Demuxer.init(gpa, &reader, .{});
    const d = opened catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return out.print(gpa, "O {s}\n", .{errorText(err)}),
    };
    defer d.deinit();
    var layer = demux.Layer(Demuxer).init(gpa, d);
    defer layer.deinit();
    layer.findStreamInfo() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return out.print(gpa, "O {s}\n", .{errorText(err)}),
    };
    try out.appendSlice(gpa, "O ok\nI mov,mp4,m4a,3gp,3g2,mj2\n");
    for (0..d.streamCount()) |i| {
        const s = try streamInfo(d, &layer, i);
        try out.print(gpa, "S {d} {c} {s} {d} {d} {d}/{d}", .{ i, media_letter[@backingInt(s.media)], s.codec, s.sample_rate, s.layout.channelCount(), s.time_base.num, s.time_base.den });
        try writeTs(out, gpa, s.duration);
        try writeTs(out, gpa, s.start_time);
        try out.print(gpa, " {d} {d} {x}\n", .{ s.initial_padding, s.bit_rate, s.disposition });
        try out.print(gpa, "C {d} {d} {x} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
            i,                    s.id,        s.codec_tag,    s.bits_per_coded_sample, s.bits_per_raw_sample,                              s.frame_size, s.block_align,
            s.profile orelse -99, s.nb_frames, s.seek_preroll, s.extradata.len,         if (s.extradata.len > 0) adler(s.extradata) else 0,
        });
        switch (s.layout) {
            .unspecified => |n| try out.print(gpa, "L {d} 0 {d} 0\n", .{ i, n }),
            .native => |m| try out.print(gpa, "L {d} 1 {d} {x}\n", .{ i, @popCount(m), m }),
            .custom => |*c| {
                try out.print(gpa, "L {d} 2 {d} ", .{ i, c.count });
                for (c.slice(), 0..) |ch, k| try out.print(gpa, "{s}{d}", .{ if (k > 0) "," else "", ch.channel.id() });
                try out.append(gpa, '\n');
            },
        }
        if (d.tracks.items[i].replaygain) |rg| try out.print(gpa, "Y {d} {d} {d} {d} {d}\n", .{ i, rg.track_gain, rg.track_peak, rg.album_gain, rg.album_peak });
        for (d.tracks.items[i].tags.items()) |e| try out.print(gpa, "M {d} {s}={s}\n", .{ i, e.key, e.value });
    }
    try out.appendSlice(gpa, "B");
    try writeTs(out, gpa, layer.start_time);
    try writeTs(out, gpa, layer.duration);
    try out.print(gpa, " {d}\n", .{layer.bit_rate});
    for (d.tags.items()) |e| try out.print(gpa, "G {s}={s}\n", .{ e.key, e.value });
    for (try chapterList(d, &layer)) |ch| {
        try out.print(gpa, "H {d} {d}/{d} {d} {d}\n", .{ ch.id, ch.time_base.num, ch.time_base.den, ch.start, ch.end });
        for (ch.tags.items()) |e| try out.print(gpa, "G {s}={s}\n", .{ e.key, e.value });
    }
    while (true) {
        const p = layer.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return out.print(gpa, "R {s}\n", .{errorText(err)}),
        } orelse break;
        try out.print(gpa, "P {d} {d}", .{ p.stream, p.data.len });
        try writeTs(out, gpa, p.pts);
        try writeTs(out, gpa, p.dts);
        try out.print(gpa, " {d} {x} {d} {d}\n", .{ p.duration, p.flags, p.pos, adler(p.data) });
        if (p.skip) |k| try out.print(gpa, "K {d} {d}\n", .{ k[0], k[1] });
        if (p.new_extradata) |e| try out.print(gpa, "Q {d} {d}\n", .{ e.len, adler(e) });
    }
    try out.appendSlice(gpa, "R EOF\n");
}

/// FFmpeg's lines without its attached-picture streams (`covr`), which
/// the port skips: their stream lines and packets (with the lines after
/// a packet). Pictures come after the tracks, so the tracks keep their
/// indexes.
fn withoutPictures(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var pictures: std.ArrayList(u32) = .empty;
    defer pictures.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "S ")) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next();
        const index = try std.fmt.parseInt(u32, fields.next().?, 10);
        const media = fields.next().?;
        // The last field is the disposition: AV_DISPOSITION_ATTACHED_PIC.
        const disposition = try std.fmt.parseInt(u32, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 16);
        if (std.mem.eql(u8, media, "v") and disposition & 0x400 != 0) try pictures.append(gpa, index);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    lines = std.mem.splitScalar(u8, text, '\n');
    var in_picture_packet = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const kind = line[0];
        var drop = false;
        if ((kind == 'S' or kind == 'C' or kind == 'L' or kind == 'M' or kind == 'Y' or kind == 'P') and line.len > 2) {
            const end = std.mem.findScalarPos(u8, line, 2, ' ') orelse line.len;
            const index = std.fmt.parseInt(u32, line[2..end], 10) catch std.math.maxInt(u32);
            drop = std.mem.findScalar(u32, pictures.items, index) != null;
            if (kind == 'P') in_picture_packet = drop;
        } else if (kind == 'K' or kind == 'Q' or kind == 'T') {
            drop = in_picture_packet;
        }
        if (drop) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn expectedError(e: anytype) Error {
    return switch (e) {
        inline else => |tag_value| @field(Error, @tagName(tag_value)),
    };
}

test "every MP4 fixture demuxes as FFmpeg's mov demuxer demuxes it (vectors/mov.txt)" {
    const gpa = testing.allocator;
    var failures: usize = 0;
    inline for (fixtures.mov.all) |fixture| {
        const bytes = fixtures.mov.bytes(fixture.name);
        switch (fixture.expected) {
            .reject => |e| {
                var reader: std.Io.Reader = .fixed(bytes);
                const got = Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
                if (got) |d| {
                    d.deinit();
                    std.debug.print("mov fixture {s}: opened, expected {t}\n", .{ fixture.name, e });
                    failures += 1;
                } else |err| if (err != expectedError(e)) {
                    std.debug.print("mov fixture {s}: {t}, expected {t}\n", .{ fixture.name, err, e });
                    failures += 1;
                }
                // Where FFmpeg refuses the file too, with the same error.
                const want = block(fixture.name) orelse return error.MissingVector;
                if (!std.mem.startsWith(u8, want, "O ok\n")) {
                    var line: [64]u8 = undefined;
                    const text = std.fmt.bufPrint(&line, "O {s}\n", .{errorText(expectedError(e))}) catch unreachable; // short names
                    if (!std.mem.eql(u8, want, text)) {
                        std.debug.print("mov fixture {s}: FFmpeg gives {s}", .{ fixture.name, want });
                        failures += 1;
                    }
                }
            },
            .accept => {
                const want = try withoutPictures(gpa, block(fixture.name) orelse return error.MissingVector);
                defer gpa.free(want);
                var got: std.ArrayList(u8) = .empty;
                defer got.deinit(gpa);
                try vectorLines(gpa, bytes, true, &got);
                if (!std.mem.eql(u8, want, got.items)) {
                    std.debug.print("mov fixture {s}\n@@GOT {s}\n{s}@@END\n", .{ fixture.name, fixture.name, got.items });
                    failures += 1;
                }
            },
        }
    }
    try testing.expectEqual(0, failures);
}

const pipe_vectors = @embedFile("../testing/vectors/mov_pipe.txt");

fn pipeBlock(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, pipe_vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, pipe_vectors, at, '\n') orelse pipe_vectors.len;
        const end = std.mem.findPos(u8, pipe_vectors, line_end, "\nF ") orelse pipe_vectors.len;
        if (std.mem.eql(u8, pipe_vectors[at + 2 .. line_end], name)) return pipe_vectors[line_end + 1 .. @min(end + 1, pipe_vectors.len)];
        start = end;
    }
    return null;
}

/// Whether a top-level `mdat` comes before the first `moov`.
fn mdatFirst(bytes: []const u8) bool {
    var o: usize = 0;
    while (o + 8 <= bytes.len) {
        var size: u64 = std.mem.readInt(u32, bytes[o..][0..4], .big);
        const kind = bytes[o + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "moov") or std.mem.eql(u8, kind, "hoov")) return false;
        if (std.mem.eql(u8, kind, "mdat")) return true;
        if (size == 1 and o + 16 <= bytes.len) size = std.mem.readInt(u64, bytes[o + 8 ..][0..8], .big);
        if (size < 8) return false;
        o = std.math.cast(usize, o + size) orelse return false;
    }
    return false;
}

test "every MP4 fixture demuxes from a pipe as FFmpeg demuxes it from one (vectors/mov_pipe.txt)" {
    const gpa = testing.allocator;
    var failures: usize = 0;
    inline for (fixtures.mov.all) |fixture| {
        if (fixture.expected == .accept) {
            const bytes = fixtures.mov.bytes(fixture.name);
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(gpa);
            try vectorLines(gpa, bytes, false, &got);
            if (mdatFirst(bytes)) {
                // FFmpeg reads such a file from a pipe only while the mdat
                // fits its buffer; the port refuses it.
                if (!std.mem.eql(u8, got.items, "O UnsupportedStreamingSize\n")) {
                    std.debug.print("mov pipe fixture {s}: {s}\n", .{ fixture.name, got.items });
                    failures += 1;
                }
            } else {
                const want = try withoutPictures(gpa, pipeBlock(fixture.name) orelse return error.MissingVector);
                defer gpa.free(want);
                if (!std.mem.eql(u8, want, got.items)) {
                    std.debug.print("mov fixture {s}\n@@GOT {s}\n{s}@@END\n", .{ fixture.name, fixture.name, got.items });
                    failures += 1;
                }
            }
        }
    }
    try testing.expectEqual(0, failures);
}

const hostile = @import("../testing/hostile.zig");

/// Opens MP4 bytes from a file or a pipe with `limits` and runs `plan` on
/// them; the packets returned (0 when opening fails).
fn exercise(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, limits: Limits, plan: hostile.TestPlan) error{OutOfMemory}!u32 {
    var reader: std.Io.Reader = .fixed(bytes);
    const opened = if (seekable) Demuxer.initSeekable(gpa, &reader, .fixed(&reader), limits) else Demuxer.init(gpa, &reader, limits);
    const d = opened catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    defer d.deinit();
    return hostile.runTestPlan(Demuxer, gpa, d, plan);
}

/// As `exercise` from a pipe that gives one byte per read.
fn exerciseFragmented(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!u32 {
    var buffer: [64]u8 = undefined;
    var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
    source.artificial_limit = .limited(1);
    const d = Demuxer.init(gpa, &source.interface, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    defer d.deinit();
    return hostile.runTestPlan(Demuxer, gpa, d, .{});
}

test "the mov demuxer from a pipe of one-byte reads returns what a whole buffer gives" {
    inline for (.{ "mov_aac_faststart", "mov_pcm_faststart_mov", "mov_stsc_runs", "mov_two_stsd", "mov_data_track", "mov_qt_v1_ima4", "mov_meta_chapter_track", "mov_meta_keys" }) |name| {
        const bytes = fixtures.mov.bytes(name);
        const expected = try exercise(testing.allocator, bytes, false, .{}, .{});
        try testing.expect(expected > 0);
        try testing.expectEqual(expected, try exerciseFragmented(testing.allocator, bytes));
    }
}

test "a moov after mdat from a pipe is UnsupportedStreamingSize" {
    var reader: std.Io.Reader = .fixed(fixtures.mov.bytes("mov_aac_stereo"));
    try testing.expectError(error.UnsupportedStreamingSize, Demuxer.init(testing.allocator, &reader, .{}));
}

/// The error opening `bytes` from a file gives, or null when it opens.
fn openError(bytes: []const u8, limits: Limits) !?Error {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = Demuxer.initSeekable(testing.allocator, &reader, .fixed(&reader), limits) catch |err| {
        const failure: ?Error = err;
        return failure;
    };
    d.deinit();
    return null;
}

test "the limits refuse tables, samples and tracks past them" {
    const aac = fixtures.mov.bytes("mov_aac_faststart");
    try testing.expectEqual(error.LimitExceeded, (try openError(aac, .{ .max_entries = 2 })).?);
    try testing.expectEqual(error.LimitExceeded, (try openError(aac, .{ .max_samples = 3 })).?);
    try testing.expectEqual(error.LimitExceeded, (try openError(fixtures.mov.bytes("mov_two_tracks"), .{ .max_tracks = 1 })).?);
    try testing.expectEqual(error.LimitExceeded, (try openError(aac, .{ .max_box_bytes = 4 })).?);
    try testing.expectEqual(null, try openError(aac, .{}));
}

test "every prefix of a file opens, refuses or ends as FFmpeg's walk allows, freeing everything" {
    inline for (.{ "mov_aac_faststart", "mov_qt_v1_ima4", "mov_two_stsd", "mov_alac_stereo", "mov_meta_ilst", "mov_meta_chapter_track" }) |name| {
        const bytes = fixtures.mov.bytes(name);
        var len: usize = 0;
        while (len <= bytes.len) : (len += if (len < 1200) 1 else 37) {
            _ = try exercise(testing.allocator, bytes[0..len], true, .{}, .{});
            _ = try exercise(testing.allocator, bytes[0..len], false, .{}, .{});
        }
    }
}

test "crafted boxes: 64-bit sizes past the input, sizes below 8, a size of 0 (FFmpeg's results)" {
    const ftyp = "\x00\x00\x00\x10ftypisom\x00\x00\x02\x00";
    // A moov whose 64-bit size claims far more than the input: clamped to
    // it, an empty movie (FFmpeg opens it too).
    try testing.expectEqual(null, try openError(ftyp ++ "\x00\x00\x00\x01moov\x7f\xff\xff\xff\xff\xff\xff\xff" ++ "\x00\x00\x00\x08free", .{}));
    // A box of size 4: the walk stops.
    try testing.expectEqual(error.InvalidMov, (try openError(ftyp ++ "\x00\x00\x00\x04moov", .{})).?);
    // A 64-bit size of 0x8000000000000000: negative, the walk stops.
    try testing.expectEqual(error.InvalidMov, (try openError(ftyp ++ "\x00\x00\x00\x01free\x80\x00\x00\x00\x00\x00\x00\x00", .{})).?);
    // An empty moov of size 0 runs to the end.
    try testing.expectEqual(null, try openError(ftyp ++ "\x00\x00\x00\x00moov", .{}));
}

/// A box of `parts`, its size the real one or `declared`, from `a`.
fn testBox(a: std.mem.Allocator, kind: []const u8, declared: ?u32, parts: []const []const u8) ![]const u8 {
    var len: usize = 8;
    for (parts) |p| len += p.len;
    const out = try a.alloc(u8, len);
    std.mem.writeInt(u32, out[0..4], declared orelse @intCast(len), .big);
    @memcpy(out[4..8], kind[0..4]);
    var at: usize = 8;
    for (parts) |p| {
        @memcpy(out[at..][0..p.len], p);
        at += p.len;
    }
    return out;
}

/// A fixture with `tail` after it: boxes at the top level, read after the
/// samples' `mdat`.
fn withTail(a: std.mem.Allocator, comptime name: []const u8, tail: []const []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(a, fixtures.mov.bytes(name));
    try parts.appendSlice(a, tail);
    return std.mem.concat(a, u8, parts.items);
}

/// An iTunes `data` atom.
fn testData(a: std.mem.Allocator, kind: u32, value: []const u8) ![]const u8 {
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], kind, .big);
    @memset(head[4..8], 0);
    return testBox(a, "data", null, &.{ &head, value });
}

/// Opens `bytes` (from a pipe unless `seekable`) and reads every packet;
/// the first error, or the demuxer for `check`.
fn openAndRead(bytes: []const u8, seekable: bool, limits: Limits) !*Demuxer {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = if (seekable) try Demuxer.initSeekable(testing.allocator, &reader, .fixed(&reader), limits) else try Demuxer.init(testing.allocator, &reader, limits);
    errdefer d.deinit();
    while (try d.next()) |_| {}
    return d;
}

test "metadata: a tag over the box limit is LimitExceeded, one cut by the end InvalidMov" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: [100]u8 = @splat('t');
    const name = try testBox(a, "\xa9nam", null, &.{ "\x00\x64\x15\xc7", &text });
    const file = try withTail(a, "mov_aac_faststart", &.{try testBox(a, "udta", null, &.{name})});
    try testing.expectEqual(error.LimitExceeded, (try openError(file, .{ .max_box_bytes = 64 })).?);
    const d = try openAndRead(file, true, .{});
    defer d.deinit();
    try testing.expectEqualStrings(&text, d.tags.get("title").?);
    try testing.expectEqualStrings(&text, d.tags.get("title-eng").?);
    // The length runs 4 bytes past the box at the end of the file.
    const cut = try testBox(a, "\xa9nam", null, &.{ "\x00\x08\x15\xc7", "abcdef" });
    try testing.expectEqual(error.InvalidMov, (try openError(try withTail(a, "mov_aac_faststart", &.{try testBox(a, "udta", null, &.{cut})}), .{})).?);
}

test "metadata: many data atoms of one iTunes tag join in linear time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const count = 20000;
    const one = try testData(a, 1, "x");
    const parts = try a.alloc([]const u8, count);
    @memset(parts, one);
    const artist = try testBox(a, "\xa9ART", null, parts);
    const file = try withTail(a, "mov_aac_faststart", &.{try testBox(a, "udta", null, &.{try testBox(a, "ilst", null, &.{artist})})});
    const d = try openAndRead(file, true, .{});
    defer d.deinit();
    const value = d.tags.get("artist").?;
    try testing.expectEqual(2 * count - 1, value.len);
    try testing.expectEqualStrings("x;x;", value[0..4]);
}

test "metadata: counts a box declares past a pipe's end stop with the input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ftyp = "\x00\x00\x00\x10ftypisom\x00\x00\x02\x00";
    const mvhd = fixtures.mov.bytes("mov_empty_moov");
    const mvhd_at = std.mem.find(u8, mvhd, "mvhd").? - 4;
    const mvhd_box = mvhd[mvhd_at..][0..std.mem.readInt(u32, mvhd[mvhd_at..][0..4], .big)];
    // keys declaring 16M names in a box declared huge: the names end at
    // the input, without an array of 16M.
    const hdlr = try testBox(a, "hdlr", null, &.{ "\x00\x00\x00\x00", "\x00\x00\x00\x00mdta", "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" });
    const keys = try testBox(a, "keys", 0x7fff_0000, &.{ "\x00\x00\x00\x00\x00\xff\xff\xff", "\x00\x00\x00\x0cmdtakey1" });
    const meta = try testBox(a, "meta", 0x7fff_f000, &.{ "\x00\x00\x00\x00", hdlr, keys });
    const moov = try testBox(a, "moov", 0x7fff_ff00, &.{ mvhd_box, meta });
    try testing.expectEqual(error.InvalidMov, Demuxer.init(testing.allocator, @constCast(&std.Io.Reader.fixed(try std.mem.concat(a, u8, &.{ ftyp, moov }))), .{}));
    // chap declaring 512M ids: those present, then the end.
    const chap = try testBox(a, "chap", 0x7fff_0000, &.{"\x00\x00\x00\x01\x00\x00\x00\x02"});
    const moov2 = try testBox(a, "moov", 0x7fff_ff00, &.{ mvhd_box, chap });
    var reader: std.Io.Reader = .fixed(try std.mem.concat(a, u8, &.{ ftyp, moov2 }));
    const d = try Demuxer.init(testing.allocator, &reader, .{});
    defer d.deinit();
    try testing.expectEqualSlices(i32, &.{ 1, 2, 0 }, d.chapter_tracks.items);
}

test "metadata: kind, ---- and covr cut on a pipe fail as FFmpeg's reads do" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "mov_aac_faststart";
    // A kind whose strings the input ends before: AVERROR_EOF.
    const kind = try testBox(a, "kind", 100, &.{"\x00\x00\x00\x00"});
    try testing.expectError(error.Truncated, openAndRead(try withTail(a, base, &.{kind}), false, .{}));
    // A kind value without its NUL: AVERROR_INVALIDDATA.
    const no_nul = try testBox(a, "kind", null, &.{ "\x00\x00\x00\x00", "urn\x00dub" });
    try testing.expectError(error.InvalidMov, openAndRead(try withTail(a, base, &.{no_nul}), true, .{}));
    // A ---- whose data the input ends inside: ffio_read_size's error.
    const mean = try testBox(a, "mean", null, &.{"\x00\x00\x00\x00com.apple.iTunes"});
    const name = try testBox(a, "name", null, &.{"\x00\x00\x00\x00iTunSMPB"});
    const custom = try testBox(a, "----", 1000, &.{ mean, name, "\x00\x00\x00\x64data\x00\x00\x00\x01\x00\x00\x00\x00 0000" });
    try testing.expectError(error.InvalidMov, openAndRead(try withTail(a, base, &.{custom}), false, .{}));
    // A cover with none of its bytes: AVERROR_EOF; with some: a picture.
    const covr = try testBox(a, "covr", 1000, &.{"\x00\x00\x03\x00data\x00\x00\x00\x0d\x00\x00\x00\x00"});
    const ilst = try testBox(a, "ilst", 1000, &.{covr});
    try testing.expectError(error.Truncated, openAndRead(try withTail(a, base, &.{ilst}), false, .{}));
    const partial = try testBox(a, "ilst", 1000, &.{try testBox(a, "covr", 1000, &.{ "\x00\x00\x03\x00data\x00\x00\x00\x0d\x00\x00\x00\x00", "\xff\xd8" })});
    const d = try openAndRead(try withTail(a, base, &.{partial}), false, .{});
    defer d.deinit();
    try testing.expectEqual(1, d.pictures);
}

test "metadata: an ISML manifest under 4 bytes and a short uuid are AVERROR_INVALIDDATA" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const isml = try testBox(a, "uuid", null, &.{ &uuid_isml_manifest, "\x00\x00" });
    try testing.expectEqual(error.InvalidMov, (try openError(try withTail(a, "mov_aac_faststart", &.{isml}), .{})).?);
    try testing.expectEqual(error.InvalidMov, (try openError(try withTail(a, "mov_aac_faststart", &.{try testBox(a, "uuid", null, &.{"short"})}), .{})).?);
}

test "metadata: numbers print as glibc's printf, versions as sscanf reads them" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // %+08.4f, %+09.4f and %+f of n / 65536 in float, from glibc (ties
    // to even at 2048, 6144, 10240).
    const loci = [_]struct { i32, []const u8, []const u8, []const u8 }{
        .{ 0, "+00.0000", "+000.0000", "+0.000000" },
        .{ -1, "-00.0000", "-000.0000", "-0.000015" },
        .{ 3277, "+00.0500", "+000.0500", "+0.050003" },
        .{ 3201851, "+48.8564", "+048.8564", "+48.856369" },
        .{ -803840, "-12.2656", "-012.2656", "-12.265625" },
        .{ std.math.maxInt(i32), "+32768.0000", "+32768.0000", "+32768.000000" },
        .{ std.math.minInt(i32), "-32768.0000", "-32768.0000", "-32768.000000" },
        .{ 16777217, "+256.0000", "+256.0000", "+256.000000" },
        .{ 13421773, "+204.8000", "+204.8000", "+204.800003" },
        .{ 2048, "+00.0312", "+000.0312", "+0.031250" },
        .{ 6144, "+00.0938", "+000.0938", "+0.093750" },
        .{ 10240, "+00.1562", "+000.1562", "+0.156250" },
    };
    for (loci) |c| {
        const v = fixed16(@bitCast(c[0]));
        inline for (.{ FixedOptions{ .precision = 4, .plus = true, .width = 8 }, FixedOptions{ .precision = 4, .plus = true, .width = 9 }, FixedOptions{ .precision = 6, .plus = true } }, 1..) |opts, k| {
            out.clearRetainingCapacity();
            try formatFixed(gpa, &out, v, opts);
            try testing.expectEqualStrings(c[k], out.items);
        }
    }
    const floats = [_]struct { u32, []const u8 }{
        .{ 0x7fc00000, "nan" },             .{ 0xffc00000, "-nan" },     .{ 0x7f800000, "inf" },                                            .{ 0xff800000, "-inf" },
        .{ 0x80000000, "-0.000000" },       .{ 0x00000001, "0.000000" }, .{ 0x7f7fffff, "340282346638528859811704183484516925440.000000" }, .{ 0x40490fd0, "3.141590" },
        .{ 0x4b800001, "16777218.000000" }, .{ 0x3e2aaaab, "0.166667" },
    };
    for (floats) |c| {
        out.clearRetainingCapacity();
        try formatFixed(gpa, &out, @bitCast(c[0]), .{ .precision = 6 });
        try testing.expectEqualStrings(c[1], out.items);
    }
    const versions = [_]struct { []const u8, ?i32 }{
        .{ "HandBrake 0.10.2", 10002 },               .{ "HandBrake0.10.2", 10002 },                       .{ "HandBrake  1.2.3x", 1002003 },
        .{ "HandBrake 1. 2.3", 1002003 },             .{ "HandBrake 1 .2.3", null },                       .{ "HandBrake +1.-2.3", 998003 },
        .{ "HandBrake 99999999999.0.0", 1568325056 }, .{ "HandBrake 1.2", null },                          .{ " HandBrake 1.2.3", null },
        .{ "HandBrake\t2147.483.647", 2147483647 },   .{ "HandBrake 99999999999999999999.0.0", -1000000 }, .{ "HandBrake -99999999999999999999.1.2", 1002 },
    };
    for (versions) |c| try testing.expectEqual(c[1], handBrakeVersion(c[0]));
    // PUT_UTF8 cut by the buffer: the first bytes of a character.
    out.clearRetainingCapacity();
    try putUtf8(gpa, &out, 0x1F600, 2);
    try testing.expectEqualSlices(u8, "\xf0\x9f", out.items);
}

test "the probe scores FFmpeg's boxes" {
    try testing.expectEqual(100, probeScore(fixtures.mov.bytes("mov_aac_stereo")[0..64]));
    try testing.expectEqual(95, probeScore("\x00\x00\x00\x08free\x00\x00\x00\x08junk"));
    try testing.expectEqual(50, probeScore("\x00\x00\x00\x08skip"));
    try testing.expectEqual(5, probeScore("\x00\x00\x00\x10ftypjp2 \x00\x00\x00\x00"));
    try testing.expectEqual(0, probeScore("RIFF\x00\x00\x00\x00WAVE"));
    var ps: [64]u8 = @splat(0);
    @memcpy(ps[0..8], "\x00\x00\x00\x40moov");
    @memcpy(ps[8..12], "hdlr");
    @memcpy(ps[16..24], "mhlrMPEG");
    try testing.expectEqual(5, probeScore(&ps));
}

test "the mov demuxer and the generic layer free everything under every allocation failure" {
    inline for (.{ "mov_aac_faststart", "mov_two_tracks_mov", "mov_two_stsd", "mov_mp2_mov", "mov_ac3_stereo_mov", "mov_qt_v1_ima4", "mov_data_track", "mov_cut_in_mdat", "mov_alac_editlist", "mov_meta_ilst", "mov_meta_keys", "mov_meta_itunsmpb", "mov_meta_in_trak", "mov_meta_udta_strings", "mov_meta_chapter_track", "mov_meta_hmmt", "mov_meta_covr", "mov_meta_uuid", "mov_meta_tags_mov" }) |name| {
        const bytes = fixtures.mov.bytes(name);
        try hostile.checkAll(exercise, .{ bytes, true, Limits{}, hostile.TestPlan{} });
        try hostile.checkAll(exercise, .{ bytes, false, Limits{}, hostile.TestPlan{ .max_packets = 8 } });
    }
}

/// Arbitrary bytes as MP4, from a file or a pipe (the first value), with
/// limits (the second: the defaults, small tables, few samples, small
/// boxes), then `hostile.drawTestPlan`'s plan.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    _ = try fuzzRun(smith);
}

fn fuzzRun(smith: *std.testing.Smith) error{OutOfMemory}!u32 {
    var input: [24000 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const seekable = !smith.value(bool);
    const limits: Limits = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => .{},
        1 => .{ .max_entries = 16 },
        2 => .{ .max_samples = 8, .max_tracks = 1 },
        else => .{ .max_box_bytes = 64 },
    };
    return exercise(testing.allocator, input[0..len], seekable, limits, hostile.drawTestPlan(smith, seekable));
}

fn fuzzSeed(comptime name: []const u8, comptime pipe: bool, comptime limit: u64, comptime s: ?hostile.TestPlan.Seek) []const u8 {
    return hostile.fuzzSeed(fixtures.mov.bytes(name), &([2]u64{ @intFromBool(pipe), limit } ++ hostile.seedValues(s)));
}

const fuzz_corpus: []const []const u8 = &.{
    fuzzSeed("mov_aac_stereo", false, 0, .{ .file = false, .stream = 0, .ts = 2000, .flags = .{ .byte = true } }),
    fuzzSeed("mov_aac_faststart", true, 0, null),
    fuzzSeed("mov_two_tracks_mov", false, 1, null),
    fuzzSeed("mov_mp2_mov", false, 0, null),
    fuzzSeed("mov_ac3_stereo_mov", false, 0, null),
    fuzzSeed("mov_qt_v1_ima4", false, 2, null),
    fuzzSeed("mov_two_stsd", true, 0, null),
    fuzzSeed("mov_stsc_repaired", false, 0, null),
    fuzzSeed("mov_stz2_4", false, 3, null),
    fuzzSeed("mov_data_track", true, 0, null),
    fuzzSeed("mov_ctts", false, 0, null),
    fuzzSeed("mov_alac_editlist", false, 0, .{ .ts = 3000 }),
    fuzzSeed("mov_opus_stereo", false, 0, null),
    fuzzSeed("mov_meta_ilst", false, 0, null),
    fuzzSeed("mov_meta_keys", true, 3, null),
    fuzzSeed("mov_meta_itunsmpb", false, 0, null),
    fuzzSeed("mov_meta_chapter_track", false, 1, null),
    fuzzSeed("mov_meta_chapter_track", true, 0, null),
    fuzzSeed("mov_meta_udta_strings", false, 0, null),
    fuzzSeed("mov_meta_covr", false, 0, null),
    fuzzSeed("mov_meta_hmmt", true, 0, null),
    fuzzSeed("mov_meta_uuid", false, 2, null),
    fuzzSeed("mov_meta_tags_mov", false, 0, null),
};

test "fuzz: the mov demuxer on arbitrary input, from a file or a pipe, with limits and a seek" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the mov fuzz entry opens and returns packets" {
    for (fuzz_corpus, 0..) |seed, i| {
        errdefer std.debug.print("mov fuzz seed {d}\n", .{i});
        var smith: std.testing.Smith = .{ .in = seed };
        try testing.expect(try fuzzRun(&smith) > 0);
    }
}

test "mutation smoke: the mov demuxer on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 16, 0x6d6f76);
}
