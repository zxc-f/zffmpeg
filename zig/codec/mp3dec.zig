// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/mpegaudiodec_template.c (the Layer III
// path of mp_decode_layer3 with region_offset2size, init_short_region,
// init_long_region, compute_band_indexes, lsf_sf_expand,
// exponents_from_scale_factors, switch_buffer, huffman_decode, l3_unscale,
// reorder_block, compute_stereo, compute_antialias, compute_imdct and
// imdct12; mp_decode_frame, decode_frame and mp_flush) as
// mpegaudiodec_float.c instantiates it (USE_FLOATS), with float_dsp.c's
// butterflies_float, at the pinned reference revision.
// Copyright (c) 2001, 2002 Fabrice Bellard
// Copyright (c) 2010 Michael Niedermayer
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float MP3 decoder, `mp3float` (TODO.md T29b): MPEG-1, 2 and
//! 2.5 Layer III frames, mono, stereo, dual channel and joint stereo (M/S
//! and intensity), long, short and mixed blocks, through the bit reservoir
//! that carries main data across frames, into planar float samples. Every
//! sample is FFmpeg's bit for bit (vectors/mp3_decode.txt): the same
//! tables (codec/mp3_tab.zig), the same float operations in the same order
//! (codec/mpadsp.zig for the IMDCT and the synthesis), the same reads past
//! the end of a frame and of the reservoir.
//!
//! `Decoder.decodeFrame` is `decode_frame`: it decodes the first frame of
//! a packet (one parsed MPEG audio frame, as the mp3 demuxer gives them)
//! and says how many bytes it used, so a caller modeling libavcodec's
//! decode.c (`decode_simple_internal`) passes the rest of a longer packet
//! again. The samples land in planes the decoder owns, valid until its next
//! `decodeFrame` or `flush`. libavcodec's skipping of the encoder delay and
//! padding (side data from the demuxer) is the caller's, as decode.c's is.
//!
//! Layer I and II frames, which FFmpeg's mp3float decodes too, are refused
//! until T29c (notes.md "MP3 decoding"). The decoder does not allocate.

const std = @import("std");
const bits = @import("bits.zig");
const vlc = @import("vlc.zig");
const mpegaudio = @import("mpegaudio.zig");
const tab = @import("mp3_tab.zig");
const dsp = @import("mpadsp.zig");
const float_dsp = @import("float_dsp.zig");

const BitReader = bits.BitReader;
const sblimit = dsp.sblimit;

/// `BACKSTEP_SIZE`: the most main data a frame keeps for the next.
const backstep_size = 512;
/// `EXTRABYTES`: room for the start of the frame's own main data after the
/// reservoir, so a code that crosses from one into the other reads on.
const extrabytes = 24;
/// `LAST_BUF_SIZE`.
const last_buf_size = 2 * backstep_size + extrabytes;
/// `HEADER_SIZE`.
const header_size = 4;
/// `MPA_MAX_CODED_FRAME_SIZE`: more than a Layer III frame's 1441 bytes.
const max_coded_frame_size = 1792;
/// The bytes past a frame its reader can see: the count stops 8 bits past
/// the end, where a 32-bit read reaches 5 bytes on.
const past_frame = 8;

/// `MODE_EXT_MS_STEREO`, `MODE_EXT_I_STEREO`.
const mode_ext_ms_stereo = 2;
const mode_ext_i_stereo = 1;
/// `MPA_JSTEREO`.
const mode_joint_stereo = 1;

/// The most samples per channel a frame decodes to (`MPA_FRAME_SIZE`).
pub const max_samples = 1152;

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA for the packet: fewer than 4 bytes
    /// after its leading zeros, no valid header ("Header missing"), a free
    /// format frame, or a frame whose side information FFmpeg refuses (big
    /// values past 288, block type 0) that is the whole packet.
    InvalidData,
    /// A Layer I or II frame, which FFmpeg's mp3float decoder decodes and
    /// the port does not yet (TODO.md T29c).
    UnsupportedFormat,
};

/// A decoded frame's parameters, which FFmpeg sets on the codec context
/// for each frame.
pub const Frame = struct {
    /// Samples per channel: 1152, or 576 for MPEG-2 and 2.5.
    samples: u32,
    /// 1 or 2.
    channels: u2,
    sample_rate: u32,
    bit_rate: u32,
};

/// What `decodeFrame` did with a packet.
pub const Decoded = struct {
    /// The bytes it used: the frame (the header's size, or the packet's
    /// when shorter) and the zero bytes before it; all of an ID3v1 tag.
    consumed: usize,
    /// The frame, or null when the bytes give none: an ID3v1 tag, or a
    /// damaged frame with more of the packet after it, which FFmpeg skips
    /// without an error.
    frame: ?Frame,
};

/// `GranuleDef`: one channel's granule.
const Granule = struct {
    scfsi: u8 = 0,
    part2_3_length: i32 = 0,
    big_values: i32 = 0,
    global_gain: i32 = 0,
    scalefac_compress: u16 = 0,
    block_type: u2 = 0,
    switch_point: bool = false,
    table_select: [3]u5 = @splat(0),
    subblock_gain: [3]u3 = @splat(0),
    scalefac_scale: u1 = 0,
    count1table_select: u1 = 0,
    /// Pairs of samples in each Huffman region.
    region_size: [3]i32 = @splat(0),
    preflag: u1 = 0,
    /// The first short band and the end of the long bands.
    short_start: u8 = 0,
    long_end: u8 = 0,
    scale_factors: [40]u8 = @splat(0),
    /// The 576 samples (`sb_hybrid`).
    sb_hybrid: [576]f32 = @splat(0),
};

/// The bit readers of a frame being decoded: `gb` reads the reservoir
/// first, then the frame (`in_gb`, null once switched to).
const Readers = struct {
    gb: BitReader,
    in_gb: ?BitReader = null,
    /// The bytes of the frame copied after the reservoir.
    extrasize: i32 = 0,

    fn count(r: *const Readers) i32 {
        return @intCast(r.gb.count());
    }

    fn sizeInBits(r: *const Readers) i32 {
        return @intCast(r.gb.size);
    }

    /// `switch_buffer`: past the reservoir's own bytes, continue in the
    /// frame where the reservoir's copy of it left off.
    fn switchBuffer(r: *Readers, pos: *i32, end_pos: *i32, end_pos2: *i32) void {
        const in_gb = r.in_gb orelse return;
        if (pos.* < r.sizeInBits() - r.extrasize * 8) return;
        r.gb = in_gb;
        r.in_gb = null;
        r.extrasize = 0;
        r.gb.skipLong(pos.* - end_pos.*);
        end_pos2.* = end_pos2.* + r.count() - pos.*;
        end_pos.* = end_pos2.*;
        pos.* = r.count();
    }
};

/// `MPADecodeContext`: what persists from frame to frame.
pub const Decoder = struct {
    /// `last_buf`: the reservoir, the main data a later frame may start
    /// in. Bytes past `reservoir_len` keep what earlier frames left there,
    /// which a read past the end of the reservoir sees, as FFmpeg's.
    last_buf: [last_buf_size]u8 = @splat(0),
    /// `last_buf_size`.
    reservoir_len: u32 = 0,
    synth: [2]dsp.Synth = .{ .{}, .{} },
    /// `sb_samples`: each channel's 36 rows of 32 subband samples.
    sb_samples: [2][36 * sblimit]f32 = @splat(@splat(0)),
    /// `mdct_buf`: each channel's IMDCT overlap.
    mdct_buf: [2][576]f32 = @splat(@splat(0)),
    granules: [2][2]Granule = @splat(@splat(.{})),
    /// The last frame's planar samples.
    output: [2][max_samples]f32 = @splat(@splat(0)),

    /// A decoder as `decode_init` leaves it (the context zeroed).
    pub const init: Decoder = .{};

    /// `mp_flush`: the synthesis and overlap state and the reservoir
    /// cleared. The reservoir's bytes stay, unused, as in FFmpeg.
    pub fn flush(d: *Decoder) void {
        for (&d.synth) |*s| s.buf = @splat(0);
        d.mdct_buf = @splat(@splat(0));
        d.reservoir_len = 0;
    }

    /// The samples of channel `channel` of the last frame, `frame` being
    /// what `decodeFrame` returned for it (empty for a channel the frame
    /// lacks). Valid until the next `decodeFrame` or `flush`.
    pub fn plane(d: *const Decoder, frame: Frame, channel: u1) []const f32 {
        if (channel >= frame.channels) return &.{};
        return d.output[channel][0..@min(frame.samples, max_samples)];
    }

    /// `decode_frame`: the frame at the start of `packet` (after any zero
    /// bytes) decoded into the decoder's planes. `tail` is what follows
    /// the packet in FFmpeg's memory (`demux.Packet.tail`), which a frame
    /// that ends with the packet reads past its end; zeros past it.
    pub fn decodeFrame(d: *Decoder, packet: []const u8, tail: []const u8) Error!Decoded {
        var skipped: usize = 0;
        while (skipped < packet.len and packet[skipped] == 0) skipped += 1;
        const buf = packet[skipped..];
        if (buf.len < header_size) return error.InvalidData;
        const header = std.mem.readInt(u32, buf[0..header_size], .big);
        // An ID3v1 tag ("TAG").
        if (header >> 8 == 0x544147) return .{ .consumed = packet.len, .frame = null };
        const hdr = mpegaudio.decodeHeader(header) orelse return error.InvalidData;
        // Free format: FFmpeg does not compute its frame size.
        if (hdr.freeFormat()) return error.InvalidData;
        // "incorrect frame size - multiple frames in buffer?"
        const buf_size = @min(buf.len, hdr.frame_size);
        if (hdr.layer != 3) return error.UnsupportedFormat;
        // A Layer III frame is at most 1441 bytes (320 kbit/s at 32 kHz;
        // the frame size test below checks every header).
        std.debug.assert(hdr.frame_size <= max_coded_frame_size);

        // The frame and the bytes a read past its end sees: the packet's,
        // then `tail`, then zeros.
        var mem: [max_coded_frame_size + past_frame]u8 = undefined;
        const end = buf_size + past_frame;
        const in_packet = @min(buf.len, end);
        @memcpy(mem[0..in_packet], buf[0..in_packet]);
        const from_tail = @min(tail.len, end - in_packet);
        @memcpy(mem[in_packet..][0..from_tail], tail[0..from_tail]);
        @memset(mem[in_packet + from_tail .. end], 0);

        const frame = d.decodeLayer3Frame(hdr, mem[0..end], buf_size) catch |err| {
            // Only a frame that is the whole packet fails it; otherwise
            // its bytes are skipped.
            if (buf_size == packet.len) return err;
            return .{ .consumed = buf_size + skipped, .frame = null };
        };
        return .{ .consumed = buf_size + skipped, .frame = frame };
    }

    /// `mp_decode_frame` for Layer III: the frame `buf[0 .. buf_size]`
    /// (`past_frame` bytes readable past it), the reservoir updated even
    /// when the frame fails.
    fn decodeLayer3Frame(d: *Decoder, hdr: mpegaudio.Header, buf: []const u8, buf_size: usize) error{InvalidData}!Frame {
        // buf_size is at most a frame's size.
        var r: Readers = .{ .gb = BitReader.initIn(buf[header_size..], buf_size - header_size) catch return error.InvalidData };
        // The CRC, which FFmpeg checks only with err_detect crccheck
        // (notes.md "MP3 decoding").
        if (hdr.error_protection) _ = r.gb.bits(16);

        const result = d.decodeLayer3(hdr, &r);

        const failed = if (result) |_| false else |_| true;
        d.reservoir_len = 0;
        if (r.in_gb) |in_gb| {
            // The frame never reached its own main data: what the
            // reservoir has left becomes the next frame's.
            r.gb.alignByte();
            const left = (r.gb.left() >> 3) - r.extrasize;
            if (left >= 0 and left <= backstep_size) {
                const n: usize = @intCast(left);
                const from = r.gb.count() >> 3;
                std.mem.copyForwards(u8, d.last_buf[0..n], d.last_buf[from..][0..n]);
                d.reservoir_len = @intCast(n);
            }
            r.gb = in_gb;
            r.in_gb = null;
            r.extrasize = 0;
        }
        r.gb.alignByte();
        const keep = (r.gb.left() >> 3) - r.extrasize;
        // The frame's last bytes join the reservoir: its main data after
        // what this frame used, or its last 512 bytes when that does not
        // fit or the frame failed.
        const n: usize = if (keep < 0 or keep > backstep_size or failed) @min(backstep_size, buf_size - header_size) else @intCast(keep);
        @memcpy(d.last_buf[d.reservoir_len..][0..n], buf[buf_size - n .. buf_size]);
        d.reservoir_len += @intCast(n);

        const nb_frames = try result;

        // The synthesis filter, planar.
        for (0..hdr.nb_channels) |ch| {
            for (0..nb_frames) |i| {
                d.synth[ch].filter(d.output[ch][32 * i ..][0..32], d.sb_samples[ch][sblimit * i ..][0..sblimit]);
            }
        }
        return .{
            .samples = @intCast(32 * nb_frames),
            .channels = hdr.nb_channels,
            .sample_rate = hdr.sample_rate,
            .bit_rate = hdr.bit_rate,
        };
    }

    /// `mp_decode_layer3`: the side information, then each granule's
    /// scale factors and spectrum from the reservoir and the frame, through
    /// the stereo processing and the IMDCT into `sb_samples`; returns the
    /// rows of subband samples (18 per granule).
    fn decodeLayer3(d: *Decoder, hdr: mpegaudio.Header, r: *Readers) error{InvalidData}!u32 {
        const nb_channels: usize = hdr.nb_channels;
        const sr = hdr.sample_rate_index;
        // The side information. FFmpeg's handle_crc is a no-op without
        // err_detect crccheck.
        var main_data_begin: u32 = undefined;
        var nb_granules: usize = undefined;
        if (hdr.lsf) {
            main_data_begin = r.gb.bits(8);
            r.gb.skip(nb_channels);
            nb_granules = 1;
        } else {
            main_data_begin = r.gb.bits(9);
            r.gb.skip(if (nb_channels == 2) 3 else 5);
            nb_granules = 2;
            for (0..nb_channels) |ch| {
                d.granules[ch][0].scfsi = 0; // all scale factors are transmitted
                d.granules[ch][1].scfsi = @intCast(r.gb.bits(4));
            }
        }

        for (0..nb_granules) |gr| {
            for (0..nb_channels) |ch| {
                const g = &d.granules[ch][gr];
                g.part2_3_length = @intCast(r.gb.bits(12));
                g.big_values = @intCast(r.gb.bits(9));
                if (g.big_values > 288) return error.InvalidData; // "big_values too big"
                g.global_gain = @intCast(r.gb.bits(8));
                // With M/S stereo alone, the 1/sqrt(2) of the M/S matrix
                // goes into the gain. FFmpeg reads mode_ext in any mode.
                if (hdr.mode_ext & (mode_ext_ms_stereo | mode_ext_i_stereo) == mode_ext_ms_stereo) g.global_gain -= 2;
                g.scalefac_compress = @intCast(r.gb.bits(if (hdr.lsf) 9 else 4));
                if (r.gb.bit() == 1) {
                    // blocksplit_flag
                    g.block_type = @intCast(r.gb.bits(2));
                    if (g.block_type == 0) return error.InvalidData; // "invalid block type"
                    g.switch_point = r.gb.bit() == 1;
                    for (0..2) |i| g.table_select[i] = @intCast(r.gb.bits(5));
                    for (0..3) |i| g.subblock_gain[i] = @intCast(r.gb.bits(3));
                    initShortRegion(sr, g);
                } else {
                    g.block_type = 0;
                    g.switch_point = false;
                    for (0..3) |i| g.table_select[i] = @intCast(r.gb.bits(5));
                    const region_address1 = r.gb.bits(4);
                    const region_address2 = r.gb.bits(3);
                    initLongRegion(sr, g, region_address1, region_address2);
                }
                regionOffsetToSize(g);
                computeBandIndexes(sr, g);
                g.preflag = 0;
                if (!hdr.lsf) g.preflag = r.gb.bit();
                g.scalefac_scale = r.gb.bit();
                g.count1table_select = r.gb.bit();
            }
        }

        // The main data starts main_data_begin bytes before this frame's,
        // in the reservoir.
        const frame_gb = r.gb;
        const main_start = frame_gb.count() >> 3;
        const extrasize = std.math.clamp((frame_gb.left() >> 3) - r.extrasize, 0, @max(0, @as(i64, last_buf_size) - d.reservoir_len));
        r.extrasize = @intCast(extrasize);
        const extra: usize = @intCast(extrasize);
        // `ptr` lies within the frame when extrasize is not 0.
        if (extra != 0) @memcpy(d.last_buf[d.reservoir_len..][0..extra], frame_gb.bytes[main_start..][0..extra]);
        r.in_gb = frame_gb;
        r.gb = BitReader.initIn(&d.last_buf, d.reservoir_len + extra) catch unreachable; // at most last_buf_size bytes
        var reservoir_bits: i64 = @as(i64, d.reservoir_len) << 3;
        var gr: usize = 0;
        // Granules whose data starts before the reservoir: silence, through
        // the IMDCT so the overlap goes on.
        while (gr < nb_granules and (reservoir_bits >> 3) < main_data_begin) : (gr += 1) {
            for (0..nb_channels) |ch| {
                const g = &d.granules[ch][gr];
                reservoir_bits += g.part2_3_length;
                g.sb_hybrid = @splat(0);
                computeImdct(g, d.sb_samples[ch][18 * sblimit * gr ..][0 .. 18 * sblimit], &d.mdct_buf[ch]);
            }
        }
        const skip = reservoir_bits - 8 * @as(i64, main_data_begin);
        if (skip >= r.sizeInBits() - r.extrasize * 8 and r.in_gb != null) {
            var in_gb = r.in_gb.?; // checked on this line
            in_gb.skipLong(skip - r.sizeInBits() + r.extrasize * 8);
            r.gb = in_gb;
            r.in_gb = null;
            r.extrasize = 0;
        } else {
            r.gb.skipLong(skip);
        }

        var exponents: [576]i16 = undefined;
        while (gr < nb_granules) : (gr += 1) {
            for (0..nb_channels) |ch| {
                const g = &d.granules[ch][gr];
                const bits_pos = r.count();
                if (!hdr.lsf) {
                    readScaleFactorsMpeg1(r, g, &d.granules[ch][0].scale_factors);
                } else {
                    readScaleFactorsLsf(r, g, hdr.mode_ext & mode_ext_i_stereo != 0 and ch == 1);
                }
                exponentsFromScaleFactors(sr, g, &exponents);
                huffmanDecode(r, g, &exponents, bits_pos + g.part2_3_length);
            }
            if (hdr.mode == mode_joint_stereo) computeStereo(hdr, &d.granules[0][gr], &d.granules[1][gr]);
            for (0..nb_channels) |ch| {
                const g = &d.granules[ch][gr];
                reorderBlock(sr, g);
                computeAntialias(g);
                computeImdct(g, d.sb_samples[ch][18 * sblimit * gr ..][0 .. 18 * sblimit], &d.mdct_buf[ch]);
            }
        }
        // FFmpeg then skips back to 0 a negative bit count, which its
        // clipped reader never has.
        return @intCast(nb_granules * 18);
    }
};

/// `region_offset2size`: the regions' ends, in pairs, into their sizes,
/// cut at `big_values`.
fn regionOffsetToSize(g: *Granule) void {
    g.region_size[2] = 576 / 2;
    var j: i32 = 0;
    for (0..3) |i| {
        const k = @min(g.region_size[i], g.big_values);
        g.region_size[i] = k - j;
        j = k;
    }
}

/// `init_short_region`.
fn initShortRegion(sr: u4, g: *Granule) void {
    if (g.block_type == 2) {
        g.region_size[0] = if (sr != 8) 36 / 2 else 72 / 2;
    } else {
        g.region_size[0] = if (sr <= 2) 36 / 2 else if (sr != 8) 54 / 2 else 108 / 2;
    }
    g.region_size[1] = 576 / 2;
}

/// `init_long_region`.
fn initLongRegion(sr: u4, g: *Granule, ra1: u32, ra2: u32) void {
    g.region_size[0] = tab.band_index_long[sr][ra1 + 1];
    // should not overflow
    const l = @min(ra1 + ra2 + 2, 22);
    g.region_size[1] = tab.band_index_long[sr][l];
}

/// `compute_band_indexes`.
fn computeBandIndexes(sr: u4, g: *Granule) void {
    if (g.block_type == 2) {
        if (g.switch_point) {
            // The first 36 samples (72 at 8 kHz, which FFmpeg asks a
            // sample of) as long blocks.
            g.long_end = if (sr <= 2) 8 else 6;
            g.short_start = 3;
        } else {
            g.long_end = 0;
            g.short_start = 0;
        }
    } else {
        g.short_start = 13;
        g.long_end = 22;
    }
}

/// MPEG-1's scale factors: `scfsi` copies groups from granule 0's
/// (`first`, which may be the previous frame's when the reservoir skipped
/// granule 0, as in FFmpeg).
fn readScaleFactorsMpeg1(r: *Readers, g: *Granule, first: *const [40]u8) void {
    const slen1: u6 = @intCast(tab.slen_table[0][g.scalefac_compress]);
    const slen2: u6 = @intCast(tab.slen_table[1][g.scalefac_compress]);
    var j: usize = 0;
    if (g.block_type == 2) {
        const n: usize = if (g.switch_point) 17 else 18;
        for (0..n) |_| {
            g.scale_factors[j] = @intCast(r.gb.bits(slen1));
            j += 1;
        }
        if (slen2 != 0) {
            for (0..18) |_| {
                g.scale_factors[j] = @intCast(r.gb.bits(slen2));
                j += 1;
            }
            for (0..3) |_| {
                g.scale_factors[j] = 0;
                j += 1;
            }
        } else {
            for (0..21) |_| {
                g.scale_factors[j] = 0;
                j += 1;
            }
        }
    } else {
        for (0..4) |k| {
            const n: usize = if (k == 0) 6 else 5;
            if (g.scfsi & (@as(u8, 0x8) >> @intCast(k)) == 0) {
                const slen = if (k < 2) slen1 else slen2;
                for (0..n) |_| {
                    g.scale_factors[j] = @intCast(r.gb.bits(slen));
                    j += 1;
                }
            } else {
                // simply copy from last granule
                for (0..n) |_| {
                    g.scale_factors[j] = first[j];
                    j += 1;
                }
            }
        }
        g.scale_factors[j] = 0;
    }
}

/// `SPLIT(dst, sf, n)`: the low part of `sf` in base `n` (3 to 6; others
/// give 0), `sf` divided by it, with FFmpeg's reciprocal multiplications.
fn split(sf: *u32, n: u32) u32 {
    switch (n) {
        3 => {
            const m = (sf.* * 171) >> 9;
            defer sf.* = m;
            return sf.* - 3 * m;
        },
        4 => {
            defer sf.* >>= 2;
            return sf.* & 3;
        },
        5 => {
            const m = (sf.* * 205) >> 10;
            defer sf.* = m;
            return sf.* - 5 * m;
        },
        6 => {
            const m = (sf.* * 171) >> 10;
            defer sf.* = m;
            return sf.* - 6 * m;
        },
        else => return 0,
    }
}

/// `lsf_sf_expand`: MPEG-2's scale factor lengths from `scalefac_compress`.
fn lsfSfExpand(sf_in: u32, n1: u32, n2: u32, n3: u32) [4]u32 {
    var sf = sf_in;
    var slen: [4]u32 = undefined;
    slen[3] = split(&sf, n3);
    slen[2] = split(&sf, n2);
    slen[1] = split(&sf, n1);
    slen[0] = sf;
    return slen;
}

/// MPEG-2 and 2.5's scale factors, the right channel's under intensity
/// stereo (`intensity`) from its own partitions.
fn readScaleFactorsLsf(r: *Readers, g: *Granule, intensity: bool) void {
    const tindex: usize = if (g.block_type == 2) (if (g.switch_point) 2 else 1) else 0;
    var sf: u32 = g.scalefac_compress;
    var slen: [4]u32 = undefined;
    var tindex2: usize = undefined;
    if (intensity) {
        sf >>= 1;
        if (sf < 180) {
            slen = lsfSfExpand(sf, 6, 6, 0);
            tindex2 = 3;
        } else if (sf < 244) {
            slen = lsfSfExpand(sf - 180, 4, 4, 0);
            tindex2 = 4;
        } else {
            slen = lsfSfExpand(sf - 244, 3, 0, 0);
            tindex2 = 5;
        }
    } else {
        if (sf < 400) {
            slen = lsfSfExpand(sf, 5, 4, 4);
            tindex2 = 0;
        } else if (sf < 500) {
            slen = lsfSfExpand(sf - 400, 5, 4, 0);
            tindex2 = 1;
        } else {
            slen = lsfSfExpand(sf - 500, 3, 0, 0);
            tindex2 = 2;
            g.preflag = 1;
        }
    }
    var j: usize = 0;
    for (0..4) |k| {
        const n = tab.lsf_nsf_table[tindex2][tindex][k];
        // At most 5 bits: scalefac_compress is 9 bits.
        const sl: u6 = @intCast(slen[k]);
        for (0..n) |_| {
            g.scale_factors[j] = @intCast(r.gb.bits(sl));
            j += 1;
        }
    }
    // XXX: should compute exact size
    while (j < 40) : (j += 1) g.scale_factors[j] = 0;
}

/// `exponents_from_scale_factors`: each sample's quantizer exponent, 400
/// above the gain in quarter steps. With the bands' bounds (gains of 0 to
/// 255, scale factors of at most 5 bits, subblock gains of 3) the
/// exponents lie in [8, 445], inside the power tables.
fn exponentsFromScaleFactors(sr: u4, g: *const Granule, exponents: *[576]i16) void {
    var at: usize = 0;
    const gain = g.global_gain - 210;
    const shift: u5 = @as(u5, g.scalefac_scale) + 1;
    const pretab = &tab.pretab[g.preflag];
    for (0..g.long_end) |i| {
        const v0 = gain - ((@as(i32, g.scale_factors[i]) + pretab[i]) << shift) + 400;
        const len = tab.band_size_long[sr][i];
        @memset(exponents[at..][0..len], @intCast(v0));
        at += len;
    }
    if (g.short_start < 13) {
        var gains: [3]i32 = undefined;
        for (&gains, g.subblock_gain) |*v, sg| v.* = gain - (@as(i32, sg) << 3);
        var k: usize = g.long_end;
        for (g.short_start..13) |i| {
            const len = tab.band_size_short[sr][i];
            for (0..3) |l| {
                const v0 = gains[l] - (@as(i32, g.scale_factors[k]) << shift) + 400;
                k += 1;
                @memset(exponents[at..][0..len], @intCast(v0));
                at += len;
            }
        }
    }
}

/// `l3_unscale`: value^(4/3) * 2^(exponent / 4), normalized to FRAC_BITS,
/// as an int (the C returns the unsigned mantissa as one).
fn l3Unscale(value: u32, exponent: u32) i32 {
    const idx = 4 * value + (exponent & 3);
    const e = @as(i32, tab.table_4_3.exp[idx]) - @as(i32, @intCast(exponent >> 2));
    // `e > (SUINT)31`: a negative shift is out of range too.
    if (e < 0 or e > 31) return 0;
    const se: u5 = @intCast(e);
    var m = tab.table_4_3.value[idx];
    m = (m + ((@as(u32, 1) << se) >> 1)) >> se;
    return @bitCast(m);
}

/// The sample `x`'s float from the power table, its sign from the next
/// bit (`READ_FLIP_SIGN`: the bit XORed into the float's sign).
inline fn readFlipSign(gb: *BitReader, v: f32) f32 {
    const sign: u32 = @as(u32, gb.bit()) << 31;
    return @bitCast(@as(u32, @bitCast(v)) ^ sign);
}

/// A sample past the table (`x` of 15 with linbits): `l3_unscale`, then
/// the sign, then C's int to float conversion.
inline fn readLinbits(gb: *BitReader, x: u32, linbits: u6, exponent: u32) f32 {
    const value = x + if (linbits == 0) 0 else gb.bits(linbits);
    var v = l3Unscale(value, exponent);
    // `v = -v` of the int: the reference build wraps INT_MIN.
    if (gb.bit() == 1) v = 0 -% v;
    return @floatFromInt(v);
}

/// `huffman_decode`: the granule's big values (three regions, each with its
/// table) and its count1 quadruples, from `r` until `end_pos2`, then the
/// rest of the 576 samples zeroed.
fn huffmanDecode(r: *Readers, g: *Granule, exponents: *const [576]i16, end_pos2_in: i32) void {
    var end_pos2 = end_pos2_in;
    var end_pos = @min(end_pos2, r.sizeInBits() - r.extrasize * 8);
    const sb = &g.sb_hybrid;
    const expval = &tab.exp_tables.expval;

    // low frequencies (called big values)
    var s_index: usize = 0;
    for (0..3) |i| {
        var j = g.region_size[i];
        if (j == 0) continue;
        // select vlc table
        const k = g.table_select[i];
        const l = tab.huff_data[k][0];
        const linbits: u6 = @intCast(tab.huff_data[k][1]);
        if (l == 0) {
            const n: usize = @intCast(2 * j);
            @memset(sb[s_index..][0..n], 0);
            s_index += n;
            continue;
        }
        const table = tab.huff_vlc[l].table;

        // read huffcode and compute each couple
        while (j > 0) : (j -= 1) {
            var pos = r.count();
            if (pos >= end_pos) {
                r.switchBuffer(&pos, &end_pos, &end_pos2);
                if (pos >= end_pos) break;
            }
            const code = vlc.lookup(BitReader, table, &r.gb, 7, 3);
            // The tables are complete (mp3_tab.zig): no code is -1.
            std.debug.assert(code >= 0);
            const y_code: u32 = @intCast(code);
            if (y_code == 0) {
                sb[s_index] = 0;
                sb[s_index + 1] = 0;
                s_index += 2;
                continue;
            }
            const exponent: u32 = @intCast(exponents[s_index]);
            var x = y_code >> 5;
            const y = y_code & 0x0f;
            if (y_code & 16 != 0) {
                sb[s_index] = if (x < 15) readFlipSign(&r.gb, expval[exponent][x]) else readLinbits(&r.gb, x, linbits, exponent);
                sb[s_index + 1] = if (y < 15) readFlipSign(&r.gb, expval[exponent][y]) else readLinbits(&r.gb, y, linbits, exponent);
            } else {
                x += y;
                const at = s_index + @intFromBool(y != 0);
                sb[at] = if (x < 15) readFlipSign(&r.gb, expval[exponent][x]) else readLinbits(&r.gb, x, linbits, exponent);
                sb[s_index + @intFromBool(y == 0)] = 0;
            }
            s_index += 2;
        }
    }

    // high frequencies
    const quad = tab.huff_quad_vlc[g.count1table_select];
    var last_pos: i32 = 0;
    while (s_index <= 572) {
        var pos = r.count();
        if (pos >= end_pos) {
            if (pos > end_pos2 and last_pos != 0) {
                // some encoders generate an incorrect size for this
                // part. We must go back into the data
                s_index -= 4;
                r.gb.skipLong(last_pos - pos);
                break;
            }
            r.switchBuffer(&pos, &end_pos, &end_pos2);
            if (pos >= end_pos) break;
        }
        last_pos = pos;

        var code: u32 = @intCast(vlc.lookup(BitReader, quad.table, &r.gb, quad.bits, 1));
        sb[s_index..][0..4].* = @splat(0);
        while (code != 0) {
            const idxtab = [16]u2{ 3, 3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
            const at = s_index + idxtab[code];
            code ^= @as(u32, 8) >> idxtab[code];
            sb[at] = readFlipSign(&r.gb, tab.exp_tables.exp[@intCast(exponents[at])]);
        }
        s_index += 4;
    }
    // skip extension bits
    const bits_left = end_pos2 - r.count();
    @memset(sb[s_index..], 0);
    r.gb.skipLong(bits_left);

    var i = r.count();
    r.switchBuffer(&i, &end_pos, &end_pos2);
}

/// `reorder_block`: a short block's samples from the bitstream's order
/// (window by window within each band) to interleaved.
fn reorderBlock(sr: u4, g: *Granule) void {
    if (g.block_type != 2) return;
    var ptr: usize = if (g.switch_point) (if (sr != 8) 36 else 72) else 0;
    var tmp: [576]f32 = undefined;
    for (g.short_start..13) |i| {
        const len: usize = tab.band_size_short[sr][i];
        const ptr1 = ptr;
        for (0..len) |j| {
            tmp[3 * j + 0] = g.sb_hybrid[ptr + j];
            tmp[3 * j + 1] = g.sb_hybrid[ptr + j + len];
            tmp[3 * j + 2] = g.sb_hybrid[ptr + j + 2 * len];
        }
        ptr += 3 * len;
        @memcpy(g.sb_hybrid[ptr1..][0 .. 3 * len], tmp[0 .. 3 * len]);
    }
}

/// `ISQRT2`.
const isqrt2: f32 = @floatCast(@as(f64, 0.70710678118654752440));

/// The M/S matrix on one band of both channels.
fn msBand(tab0: []f32, tab1: []f32) void {
    for (tab0, tab1) |*a, *b| {
        const tmp0 = a.*;
        const tmp1 = b.*;
        a.* = isqrt2 * (tmp0 + tmp1);
        b.* = isqrt2 * (tmp0 - tmp1);
    }
}

/// Intensity stereo on one band: the left channel's samples weighted into
/// both.
fn isBand(tab0: []f32, tab1: []f32, v1: f32, v2: f32) void {
    for (tab0, tab1) |*a, *b| {
        const tmp0 = a.*;
        a.* = v1 * tmp0;
        b.* = v2 * tmp0;
    }
}

/// Whether a band holds a nonzero sample (as floats: -0 is zero).
fn anyNonzero(band: []const f32) bool {
    for (band) |v| if (v != 0) return true;
    return false;
}

/// `compute_stereo`: joint stereo on granule `g0` (left) and `g1` (right).
/// Intensity stereo walks the right channel's bands from the top down
/// while they are zero, M/S (when also on) takes the bands below.
fn computeStereo(hdr: mpegaudio.Header, g0: *Granule, g1: *Granule) void {
    @setFloatMode(.strict);
    const sr = hdr.sample_rate_index;
    const ms = hdr.mode_ext & mode_ext_ms_stereo != 0;
    if (hdr.mode_ext & mode_ext_i_stereo != 0) {
        const is_tab: *const [2][16]f32 = if (!hdr.lsf) &tab.is_table else &tab.is_table_lsf[g1.scalefac_compress & 1];
        const sf_max: u8 = if (!hdr.lsf) 7 else 16;
        var at: usize = 576;
        var non_zero_found_short = [3]bool{ false, false, false };
        var k: usize = (13 - @as(usize, g1.short_start)) * 3 + g1.long_end - 3;
        var i: usize = 13;
        while (i > g1.short_start) {
            i -= 1;
            // for last band, use previous scale factor
            if (i != 11) k -= 3;
            const len: usize = tab.band_size_short[sr][i];
            var l: usize = 3;
            while (l > 0) {
                l -= 1;
                at -= len;
                const tab0 = g0.sb_hybrid[at..][0..len];
                const tab1 = g1.sb_hybrid[at..][0..len];
                intensity: {
                    if (non_zero_found_short[l]) break :intensity;
                    // test if non zero band. if so, stop doing i-stereo
                    if (anyNonzero(tab1)) {
                        non_zero_found_short[l] = true;
                        break :intensity;
                    }
                    const sf = g1.scale_factors[k + l];
                    if (sf >= sf_max) break :intensity;
                    isBand(tab0, tab1, is_tab[0][sf], is_tab[1][sf]);
                    continue;
                }
                // found1: lower part of the spectrum: do ms stereo if
                // enabled
                if (ms) msBand(tab0, tab1);
            }
        }

        var non_zero_found = non_zero_found_short[0] or non_zero_found_short[1] or non_zero_found_short[2];

        i = g1.long_end;
        while (i > 0) {
            i -= 1;
            const len: usize = tab.band_size_long[sr][i];
            at -= len;
            const tab0 = g0.sb_hybrid[at..][0..len];
            const tab1 = g1.sb_hybrid[at..][0..len];
            intensity: {
                if (non_zero_found) break :intensity;
                // test if non zero band. if so, stop doing i-stereo
                if (anyNonzero(tab1)) {
                    non_zero_found = true;
                    break :intensity;
                }
                // for last band, use previous scale factor
                const sf = g1.scale_factors[if (i == 21) 20 else i];
                if (sf >= sf_max) break :intensity;
                isBand(tab0, tab1, is_tab[0][sf], is_tab[1][sf]);
                continue;
            }
            // found2
            if (ms) msBand(tab0, tab1);
        }
    } else if (ms) {
        // ms stereo ONLY: the 1/sqrt(2) normalization factor is included
        // in the global gain.
        float_dsp.butterflies(&g0.sb_hybrid, &g1.sb_hybrid);
    }
}

/// `compute_antialias`: the butterflies across the long subbands'
/// boundaries (only the first with a mixed block, none for short).
fn computeAntialias(g: *Granule) void {
    @setFloatMode(.strict);
    var n: usize = undefined;
    if (g.block_type == 2) {
        if (!g.switch_point) return;
        // XXX: check this for 8000Hz case
        n = 1;
    } else {
        n = sblimit - 1;
    }
    var ptr: usize = 18;
    for (0..n) |_| {
        inline for (0..8) |j| {
            const tmp0 = g.sb_hybrid[ptr - 1 - j];
            const tmp1 = g.sb_hybrid[ptr + j];
            g.sb_hybrid[ptr - 1 - j] = tmp0 * tab.csa_table[j][0] - tmp1 * tab.csa_table[j][1];
            g.sb_hybrid[ptr + j] = tmp0 * tab.csa_table[j][1] + tmp1 * tab.csa_table[j][0];
        }
        ptr += 18;
    }
}

// The 12-point IMDCT's constants (the template's, not mpadsp's C3 to C6).
const imdct12_c3 = @as(f32, @floatCast(@as(f64, 0.86602540378443864676) / 2));
const imdct12_c4 = @as(f32, @floatCast(@as(f64, 0.70710678118654752439) / 2));
const imdct12_c5 = @as(f32, @floatCast(@as(f64, 0.51763809020504152469) / 2));
const imdct12_c6 = @as(f32, @floatCast(@as(f64, 1.93185165257813657349) / 4));

/// `imdct12`: a short window's 6 coefficients (`in` at stride 3) to 12
/// samples, factorized by hand as FFmpeg's.
fn imdct12(out: *[12]f32, in: []const f32) void {
    @setFloatMode(.strict);
    var in0 = in[0 * 3];
    var in1 = in[1 * 3] + in[0 * 3];
    var in2 = in[2 * 3] + in[1 * 3];
    var in3 = in[3 * 3] + in[2 * 3];
    var in4 = in[4 * 3] + in[3 * 3];
    var in5 = in[5 * 3] + in[4 * 3];
    in5 += in3;
    in3 += in1;

    // MULH3(x, c, s): (s * c) * x.
    in2 = (2 * imdct12_c3) * in2;
    in3 = (4 * imdct12_c3) * in3;

    const t1 = in0 - in4;
    const t2 = (2 * imdct12_c4) * (in1 - in5);

    out[7] = t1 + t2;
    out[10] = out[7];
    out[1] = t1 - t2;
    out[4] = out[1];

    in0 += in4 * 0.5;
    in4 = in0 + in2;
    in5 += 2 * in1;
    in1 = imdct12_c5 * (in5 + in3);
    out[8] = in4 + in1;
    out[9] = out[8];
    out[2] = in4 - in1;
    out[3] = out[2];

    in0 -= in2;
    in5 = (2 * imdct12_c6) * (in5 - in3);
    out[0] = in0 - in5;
    out[5] = out[0];
    out[6] = in0 + in5;
    out[11] = out[6];
}

/// `compute_imdct`: the granule's subbands to 18 rows of subband samples
/// (`sb_samples`, stride 32) with the overlap `mdct_buf`: long blocks
/// through `imdct36Blocks`, short ones through three `imdct12` each, the
/// subbands above the last nonzero one only the overlap.
fn computeImdct(g: *Granule, sb_samples: *[18 * sblimit]f32, mdct_buf: *[576]f32) void {
    @setFloatMode(.strict);
    // find last non zero block: the int32 bits, so -0 counts
    var ptr: usize = 576;
    while (ptr >= 2 * 18) {
        ptr -= 6;
        const nonzero = for (g.sb_hybrid[ptr..][0..6]) |v| {
            if (@as(u32, @bitCast(v)) != 0) break true;
        } else false;
        if (nonzero) break;
    }
    const last: usize = ptr / 18 + 1;

    const mdct_long_end: usize = if (g.block_type == 2)
        // XXX: check for 8000 Hz
        (if (g.switch_point) 2 else 0)
    else
        last;

    dsp.imdct36Blocks(sb_samples, mdct_buf, &g.sb_hybrid, mdct_long_end, g.switch_point, g.block_type);

    var out2: [12]f32 = undefined;
    for (mdct_long_end..last) |j| {
        const buf = mdct_buf[dsp.overlapOffset(j)..];
        // select frequency inversion
        const win = &dsp.mdct_win[2 + (4 & (0 -% (j & 1)))];
        const out = sb_samples[j..];
        const in = g.sb_hybrid[18 * j ..];

        for (0..6) |i| out[i * sblimit] = buf[4 * i];
        imdct12(&out2, in[0..]);
        for (0..6) |i| {
            out[(6 + i) * sblimit] = out2[i] * win[i] + buf[4 * (i + 6 * 1)];
            buf[4 * (i + 6 * 2)] = out2[i + 6] * win[i + 6];
        }
        imdct12(&out2, in[1..]);
        for (0..6) |i| {
            out[(12 + i) * sblimit] = out2[i] * win[i] + buf[4 * (i + 6 * 2)];
            buf[4 * (i + 6 * 0)] = out2[i + 6] * win[i + 6];
        }
        imdct12(&out2, in[2..]);
        for (0..6) |i| {
            buf[4 * (i + 6 * 0)] = out2[i] * win[i] + buf[4 * (i + 6 * 0)];
            buf[4 * (i + 6 * 1)] = out2[i + 6] * win[i + 6];
            buf[4 * (i + 6 * 2)] = 0;
        }
    }
    // zero bands
    for (last..sblimit) |j| {
        // overlap
        const buf = mdct_buf[dsp.overlapOffset(j)..];
        for (0..18) |i| {
            sb_samples[j + i * sblimit] = buf[4 * i];
            buf[4 * i] = 0;
        }
    }
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const mp3 = @import("../format/mp3.zig");
const demux = @import("../format/demux.zig");
const oggdecode = @import("../format/oggdecode.zig");
const decode_vectors = @embedFile("../testing/vectors/mp3_decode.txt");

/// One fixture's block of mp3_decode.txt, after its `F` line.
fn vectorBlock(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, decode_vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, decode_vectors, at, '\n') orelse decode_vectors.len;
        const end = std.mem.findPos(u8, decode_vectors, line_end, "\nF ") orelse decode_vectors.len;
        if (std.mem.eql(u8, decode_vectors[at + 2 .. line_end], name)) return decode_vectors[line_end + 1 .. @min(end + 1, decode_vectors.len)];
        start = end;
    }
    return null;
}

/// mp3_decode_vectors.c's `D` line for the kept samples of a frame.
fn printFrame(gpa: std.mem.Allocator, out: *std.ArrayList(u8), d: *const Decoder, frame: Frame, kept: [2]u32) !void {
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (0..frame.channels) |c| {
        for (d.plane(frame, @intCast(c))[kept[0]..kept[1]]) |v| {
            var le: [4]u8 = undefined;
            std.mem.writeInt(u32, &le, @bitCast(v), .little);
            md5.update(&le);
        }
    }
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    try out.print(gpa, "D {d} {x}\n", .{ kept[1] - kept[0], digest });
}

/// mp3_decode_vectors.c's lines for one fixture: the input opened as the
/// ffmpeg program opens it, each packet sent to the decoder through a
/// model of libavcodec's decode.c (`avcodec_send_packet` decodes until a
/// frame is kept or the packet is used up, `avcodec_receive_frame` goes
/// on with the rest; skip samples and discard padding from the packets'
/// side data).
fn decodeVectorLines(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const dm = mp3.Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{}) catch |err| switch (err) {
        error.InvalidMp3 => return out.appendSlice(gpa, "O INVALIDDATA\n"),
        else => return err,
    };
    defer dm.deinit();
    var layer = demux.Layer(mp3.Demuxer).init(gpa, dm);
    defer layer.deinit();
    try layer.findStreamInfo();
    const params = try layer.codecParams(0);
    if (params.mpa_codec) |c| if (c != .mp3) return out.appendSlice(gpa, "O DECODER_NOT_FOUND\n");
    try out.appendSlice(gpa, "O ok\n");
    const d = try gpa.create(Decoder);
    defer gpa.destroy(d);
    d.* = .init;
    var discard: oggdecode.Discard = .{};
    while (try layer.next()) |p| {
        var data = p.data;
        var sent = false;
        while (data.len != 0) {
            const decoded = d.decodeFrame(data, &p.tail) catch |err| {
                if (!sent) {
                    try out.print(gpa, "P {d} INVALIDDATA\n", .{p.data.len});
                    sent = true;
                } else try out.appendSlice(gpa, "E INVALIDDATA\n");
                try testing.expectEqual(error.InvalidData, err);
                break;
            };
            data = data[@min(decoded.consumed, data.len)..];
            const frame = decoded.frame orelse continue;
            const kept = discard.apply(frame.samples, p.skip) orelse continue;
            if (!sent) {
                try out.print(gpa, "P {d} 0\n", .{p.data.len});
                sent = true;
            }
            try printFrame(gpa, out, d, frame, kept);
        }
        if (!sent) try out.print(gpa, "P {d} 0\n", .{p.data.len});
    }
}

test "every MP3 fixture decodes as FFmpeg's mp3float decodes it (vectors/mp3_decode.txt)" {
    const gpa = testing.allocator;
    inline for (fixtures.mp3.all) |fixture| {
        const want = vectorBlock(fixture.name) orelse return error.MissingVector;
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try decodeVectorLines(gpa, fixtures.mp3.bytes(fixture.name), &got);
        testing.expectEqualStrings(want, got.items) catch |err| {
            std.debug.print("mp3 fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

// Crafted frames -------------------------------------------------------

const hostile = @import("../testing/hostile.zig");

/// MPEG-1 Layer III, 128 kbit/s, 44.1 kHz, mono, no padding: 417 bytes.
const mono_header: u32 = 0xFFFB90C4;
const mono_frame_size = 417;

/// One granule's side information, for `monoFrame`.
const CraftedGranule = struct {
    part2_3_length: u12 = 0,
    big_values: u9 = 0,
    global_gain: u8 = 210,
    scalefac_compress: u4 = 0,
    /// Null for no block split.
    block_type: ?u2 = null,
    table_select: [3]u5 = @splat(0),
};

/// A mono frame with the given side information, its main data `fill`.
fn monoFrame(main_data_begin: u9, granules: [2]CraftedGranule, fill: u8) [mono_frame_size]u8 {
    var frame: [mono_frame_size]u8 = @splat(fill);
    std.mem.writeInt(u32, frame[0..4], mono_header, .big);
    var side: [17]u8 = @splat(0);
    var w: bits.BitWriter = .init(&side);
    w.bits(9, main_data_begin);
    w.bits(5, 0); // private bits
    w.bits(4, 0); // scfsi
    for (granules) |g| {
        w.bits(12, g.part2_3_length);
        w.bits(9, g.big_values);
        w.bits(8, g.global_gain);
        w.bits(4, g.scalefac_compress);
        if (g.block_type) |block_type| {
            w.bits(1, 1);
            w.bits(2, block_type);
            w.bits(1, 0); // switch_point
            for (g.table_select[0..2]) |t| w.bits(5, t);
            w.bits(9, 0); // subblock gains
        } else {
            w.bits(1, 0);
            for (g.table_select) |t| w.bits(5, t);
            w.bits(4, 0); // region0_count
            w.bits(3, 0); // region1_count
        }
        w.bits(3, 0); // preflag, scalefac_scale, count1table_select
    }
    std.debug.assert(!w.overflow); // 17 bytes hold every field
    @memcpy(frame[4..][0..17], &side);
    return frame;
}

test "packets without a frame header are invalid, an ID3v1 tag gives no frame" {
    const d = try testing.allocator.create(Decoder);
    defer testing.allocator.destroy(d);
    d.* = .init;
    try testing.expectError(error.InvalidData, d.decodeFrame(&.{}, &.{}));
    try testing.expectError(error.InvalidData, d.decodeFrame(&.{ 0, 0, 0, 0, 0, 0 }, &.{}));
    try testing.expectError(error.InvalidData, d.decodeFrame(&.{ 0, 0xFF, 0xFB, 0x90 }, &.{}));
    try testing.expectError(error.InvalidData, d.decodeFrame(&.{ 0x12, 0x34, 0x56, 0x78, 0x9a }, &.{}));
    // Free format (bit rate index 0): no frame size.
    try testing.expectError(error.InvalidData, d.decodeFrame(&.{ 0xFF, 0xFB, 0x00, 0xC4, 1, 2, 3 }, &.{}));
    var tag: [128]u8 = @splat(' ');
    @memcpy(tag[0..3], "TAG");
    const got = try d.decodeFrame(&tag, &.{});
    try testing.expectEqual(128, got.consumed);
    try testing.expectEqual(null, got.frame);
    // Leading zero bytes are consumed with the tag.
    var zeros_tag: [131]u8 = @splat(0);
    @memcpy(zeros_tag[3..], &tag);
    try testing.expectEqual(131, (try d.decodeFrame(&zeros_tag, &.{})).consumed);
}

test "Layer I and II frames are refused until T29c" {
    var d: Decoder = .init;
    var frame = monoFrame(0, .{ .{}, .{} }, 0);
    // Layer II, then Layer I.
    std.mem.writeInt(u32, frame[0..4], 0xFFFD90C4, .big);
    try testing.expectError(error.UnsupportedFormat, d.decodeFrame(&frame, &.{}));
    std.mem.writeInt(u32, frame[0..4], 0xFFFF90C4, .big);
    try testing.expectError(error.UnsupportedFormat, d.decodeFrame(&frame, &.{}));
}

test "a frame FFmpeg refuses fails a packet it fills, and is skipped in a longer one" {
    var d: Decoder = .init;
    // big_values past 288, then a block split of type 0.
    const bad = [_][mono_frame_size]u8{
        monoFrame(0, .{ .{ .big_values = 289 }, .{} }, 0x55),
        monoFrame(0, .{ .{ .block_type = 0 }, .{} }, 0x55),
    };
    for (bad) |frame| {
        try testing.expectError(error.InvalidData, d.decodeFrame(&frame, &.{}));
        // The failed frame's last 512 bytes, all it has after the header,
        // become the reservoir.
        try testing.expectEqual(mono_frame_size - 4, d.reservoir_len);
        try testing.expectEqualSlices(u8, frame[4..], d.last_buf[0 .. mono_frame_size - 4]);
        const two = frame ++ monoFrame(0, .{ .{}, .{} }, 0);
        const first = try d.decodeFrame(&two, &.{});
        try testing.expectEqual(mono_frame_size, first.consumed);
        try testing.expectEqual(null, first.frame);
        // Leading zeros count, so a refused frame after them is skipped
        // too: it is not the whole packet.
        const padded = [_]u8{ 0, 0 } ++ frame;
        const after_zeros = try d.decodeFrame(&padded, &.{});
        try testing.expectEqual(padded.len, after_zeros.consumed);
        try testing.expectEqual(null, after_zeros.frame);
    }
}

test "main data before the stream's start decodes to silence; a cut frame reads zeros past the packet" {
    const d = try testing.allocator.create(Decoder);
    defer testing.allocator.destroy(d);
    d.* = .init;
    // main_data_begin 511 with an empty reservoir: both granules skipped.
    const frame = monoFrame(511, .{ .{ .part2_3_length = 4000, .big_values = 288, .table_select = .{ 24, 15, 31 } }, .{ .part2_3_length = 4000, .big_values = 288 } }, 0xA5);
    const got = try d.decodeFrame(&frame, &.{});
    const f = got.frame.?;
    try testing.expectEqual(1152, f.samples);
    try testing.expectEqual(1, f.channels);
    try testing.expectEqual(44100, f.sample_rate);
    try testing.expectEqual(128000, f.bit_rate);
    for (d.plane(f, 0)) |v| try testing.expectEqual(0, v);
    try testing.expectEqual(0, d.plane(f, 1).len);
    // The same frame reading its main data now (main_data_begin 0), the
    // part lengths running far past it, and cut to 60 bytes: every read
    // past the packet is a zero, and the samples stay finite.
    d.flush();
    const live = monoFrame(0, .{ .{ .part2_3_length = 4000, .big_values = 288, .table_select = .{ 24, 15, 31 } }, .{ .part2_3_length = 4000, .big_values = 288, .table_select = .{ 13, 16, 7 } } }, 0xA5);
    for ([_]usize{ 60, mono_frame_size }) |cut| {
        const cut_got = try d.decodeFrame(live[0..cut], &.{});
        try testing.expectEqual(cut, cut_got.consumed);
        for (d.plane(cut_got.frame.?, 0)) |v| try testing.expect(std.math.isFinite(v));
    }
}

test "every Layer III header's frame fits the decoder's frame buffer" {
    var largest: u32 = 0;
    var header: u32 = 0xFFE20000; // Layer III, every version and field
    while (true) : (header += 1 << 9) {
        if (mpegaudio.decodeHeader(header)) |h| {
            if (h.layer == 3) largest = @max(largest, h.frame_size);
        }
        if (header >> 9 == 0xFFFFFFFF >> 9) break;
    }
    try testing.expectEqual(1441, largest);
    try testing.expect(largest <= max_coded_frame_size);
}

test "l3_unscale: shifts past 31 or below 0 give 0" {
    try testing.expectEqual(0, l3Unscale(8206, 445));
    try testing.expect(l3Unscale(1, 400) > 0);
    try testing.expectEqual(0, l3Unscale(0, 400));
}

test "flush clears the overlap, the synthesis and the reservoir" {
    const d = try testing.allocator.create(Decoder);
    defer testing.allocator.destroy(d);
    d.* = .init;
    const bytes = fixtures.mp3.bytes("mp3_l3_long_stereo");
    const frame_size = mpegaudio.decodeHeader(std.mem.readInt(u32, bytes[0..4], .big)).?.frame_size;
    _ = try d.decodeFrame(bytes[0..frame_size], &.{});
    try testing.expect(d.reservoir_len > 0);
    d.flush();
    try testing.expectEqual(0, d.reservoir_len);
    for (d.mdct_buf) |b| for (b) |v| try testing.expectEqual(0, v);
    for (d.synth) |s| for (s.buf) |v| try testing.expectEqual(0, v);
    // The first frame again decodes as it did from the start (its main
    // data is its own, main_data_begin 0).
    const first = try d.decodeFrame(bytes[0..frame_size], &.{});
    const again = try testing.allocator.create(Decoder);
    defer testing.allocator.destroy(again);
    again.* = .init;
    const fresh = try again.decodeFrame(bytes[0..frame_size], &.{});
    // The synthesis offset is not reset by FFmpeg's flush, so compare the
    // IMDCT's output, which the flush made start over.
    try testing.expectEqual(fresh.frame.?.samples, first.frame.?.samples);
    try testing.expectEqualSlices(f32, &again.sb_samples[0], &d.sb_samples[0]);
}

// Fuzzing --------------------------------------------------------------

/// A fuzz input's stream: up to 16 KiB of MPEG audio bytes (the first
/// slice), cut into packets by FFmpeg's mpegaudio parser (the first value
/// 0, each frame followed by the stream's next bytes, as the parser's
/// uncopied first frame is) or into raw pieces of 1 to 4096 bytes (the
/// second value) holding several frames or parts of one; the decoder
/// flushed before packet number `flush_at` (the third value; none past the
/// last). Returns the frames decoded.
fn fuzzRun(smith: *std.testing.Smith) !u32 {
    const gpa = testing.allocator;
    var input: [16384 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const stream = input[0..len];
    const parsed = smith.valueRangeAtMost(u8, 0, 1) == 0;
    const chunk = smith.valueRangeAtMost(u16, 1, 4096);
    const flush_at = smith.valueRangeAtMost(u16, 0, 1000);
    const d = try gpa.create(Decoder);
    defer gpa.destroy(d);
    d.* = .init;
    var parser: mpegaudio.Parser = .{};
    defer parser.deinit(gpa);
    var ctx: mpegaudio.Context = .{};
    var frames: u32 = 0;
    var packets: u32 = 0;
    var at: usize = 0;
    while (true) {
        var packet: []const u8 = undefined;
        var tail: []const u8 = &.{};
        if (parsed) {
            // At the end, the parser's held frame (flush calls).
            const flushing = at == stream.len;
            const res = try parser.parse(gpa, &ctx, stream[at..]);
            at += res.consumed;
            packet = res.frame orelse if (flushing) break else continue;
            if (packet.ptr != parser.pc.buffer.items.ptr) tail = stream[at..][0..@min(stream.len - at, demux.tail_len)];
        } else {
            if (at == stream.len) break;
            const n = @min(chunk, stream.len - at);
            packet = stream[at..][0..n];
            at += n;
        }
        if (packets == flush_at) d.flush();
        packets += 1;
        // decode.c's loop over the packet.
        var data = packet;
        while (data.len != 0) {
            const got = d.decodeFrame(data, tail) catch break;
            try testing.expect(got.consumed > 0 and got.consumed <= data.len);
            data = data[got.consumed..];
            const f = got.frame orelse continue;
            try testing.expect(f.samples == 576 or f.samples == 1152);
            for (0..f.channels) |c| for (d.plane(f, @intCast(c))) |v| std.mem.doNotOptimizeAway(v);
            frames += 1;
        }
    }
    return frames;
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    _ = try fuzzRun(smith);
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_long_stereo"), &.{ 0, 4096, 1000 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_reservoir_mono"), &.{ 0, 4096, 3 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_window_switching"), &.{ 1, 1000, 1000 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_short_ms"), &.{ 0, 4096, 1000 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_intensity_ms"), &.{ 1, 333, 2 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_mpeg2_22k_intensity"), &.{ 0, 4096, 1 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_mpeg2_24k_switch"), &.{ 0, 4096, 1000 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_mpeg25_8k_switch"), &.{ 1, 4096, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_crc_linbits"), &.{ 0, 4096, 5 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_reservoir_missing"), &.{ 0, 4096, 1000 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_truncated"), &.{ 1, 100, 1000 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_short_part"), &.{ 0, 4096, 1000 }),
};

test "fuzz: the MP3 decoder on arbitrary streams, parsed or in raw pieces, with a flush" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the MP3 decoder's fuzz entry decodes frames" {
    for (fuzz_corpus) |seed| {
        var smith: std.testing.Smith = .{ .in = seed };
        try testing.expect(try fuzzRun(&smith) > 0);
    }
}

test "mutation smoke: the MP3 decoder on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 48, 0x6d703364);
}
