// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/mpegaudioenc.c (mpa_encode_init, idct32,
// filter, compute_scale_factors, psycho_acoustic_model,
// compute_bit_allocation, encode_subbands, encode_frame, mpa_encode_frame)
// and mpegaudiotab.h (costab32, bitinv32, quant_snr, fixed_smr,
// nb_scale_factors) at the pinned reference revision, with encode.c's
// padding of a short last frame.
// Copyright (c) 2000, 2001 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's MP2 encoders (TODO.md T29d): `mp2`, which quantizes in floating
//! point, and `mp2fixed`, in fixed point. MPEG-1 and MPEG-2 (LSF) Layer II,
//! mono or stereo, 16-bit samples in frames of 1152, the polyphase analysis
//! filter in FFmpeg's integer arithmetic, scale factors grouped by their
//! transmission codes, and the bit allocation FFmpeg's "simplest" encoder
//! makes from a fixed signal-to-mask table (no psychoacoustic model),
//! packet for packet as the pinned libavcodec writes them
//! (vectors/mp2enc.txt). The encoder does not allocate.

const std = @import("std");
const mpegaudio = @import("mpegaudio.zig");
const tab = @import("mp3_tab.zig");
const dsp = @import("mpadsp.zig");
const bits = @import("bits.zig");
const libm = @import("../core/libm.zig");
const cconv = @import("../core/cconv.zig");

const sblimit = dsp.sblimit;

/// `MPA_FRAME_SIZE`: the samples a frame codes, per channel.
pub const frame_samples = 1152;

/// `initial_padding`: the analysis filter's delay, 512 - 32 + 1 samples,
/// which FFmpeg subtracts from each packet's timestamp.
pub const initial_padding = 512 - 32 + 1;

/// The largest packet: 384 kbit/s at 32 kHz, padded.
pub const max_packet = frame_samples * 384000 / (32000 * 8) + 1;

/// `FRAC_BITS` of the subband samples and the transform.
const frac_bits = 15;
/// `WFRAC_BITS` of the window.
const wfrac_bits = 14;
/// `WSHIFT`.
const wshift = wfrac_bits + 15 - frac_bits;
/// `P`, the fixed quantizer's precision.
const p_bits = 15;
/// `SAMPLES_BUF_SIZE`.
const samples_buf_size = 4096;

/// `MUL`: a 64-bit product shifted down, stored into the C's `int`.
inline fn mul(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * b) >> frac_bits);
}

/// `FIX(a)`: `(int)(a * FRAC_ONE)`, truncated.
fn fix(comptime a: f64) i32 {
    return @intFromFloat(@trunc(a * (1 << frac_bits)));
}

/// `costab32`.
const costab32 = [30]i32{
    fix(0.54119610014619701222), fix(1.3065629648763763537),
    fix(0.50979557910415917998), fix(2.5629154477415054814),
    fix(0.89997622313641556513), fix(0.60134488693504528634),
    fix(0.5024192861881556782),  fix(5.1011486186891552563),
    fix(0.78815462345125020249), fix(0.64682178335999007679),
    fix(0.56694403481635768927), fix(1.0606776859903470633),
    fix(1.7224470982383341955),  fix(0.52249861493968885462),
    fix(10.19000812354803287),   fix(0.674808341455005678),
    fix(1.1694399334328846596),  fix(0.53104259108978413284),
    fix(2.0577810099534108446),  fix(0.58293496820613388554),
    fix(0.83934964541552681272), fix(0.50547095989754364798),
    fix(3.4076084184687189804),  fix(0.62250412303566482475),
    fix(0.97256823786196078263), fix(0.51544730992262455249),
    fix(1.4841646163141661852),  fix(0.5531038960344445421),
    fix(0.74453627100229857749), fix(0.5006029982351962726),
};

/// `bitinv32`.
const bitinv32 = [32]u8{ 0, 16, 8, 24, 4, 20, 12, 28, 2, 18, 10, 26, 6, 22, 14, 30, 1, 17, 9, 25, 5, 21, 13, 29, 3, 19, 11, 27, 7, 23, 15, 31 };

/// `quant_snr`: each quantizer's signal-to-noise ratio, dB times 10.
const quant_snr = [17]u16{ 70, 110, 160, 208, 253, 316, 378, 439, 499, 559, 620, 680, 740, 800, 861, 920, 980 };

/// `fixed_smr`: the signal-to-mask ratio of each subband, from toolame.
const fixed_smr = [sblimit]f32{
    30,  17,  16,  10,  3,   12,   8,    2.5,
    5,   5,   6,   6,   5,   6,    10,   6,
    -4,  -10, -21, -30, -42, -55,  -68,  -75,
    -75, -75, -75, -75, -91, -107, -110, -108,
};

/// `psycho_acoustic_model`: `(int)(fixed_smr[i] * 10)`, a float product,
/// the same for every frame and channel.
const smr_table: [sblimit]i16 = blk: {
    var t: [sblimit]i16 = undefined;
    for (&t, fixed_smr) |*v, s| v.* = @intFromFloat(@trunc(s * @as(f32, 10)));
    break :blk t;
};

/// `nb_scale_factors`, by scale code.
const nb_scale_factors = [4]u8{ 3, 2, 1, 2 };

/// The analysis window: `ff_mpa_enwindow` rounded to WFRAC_BITS, mirrored.
const filter_bank: [512]i16 = blk: {
    var t: [512]i16 = undefined;
    for (0..257) |i| {
        var v: i32 = dsp.enwindow[i];
        v = (v + (1 << (16 - wfrac_bits - 1))) >> (16 - wfrac_bits);
        t[i] = @intCast(v);
        if ((i & 63) != 0) v = -v;
        if (i != 0) t[512 - i] = @intCast(v);
    }
    break :blk t;
};

/// `scale_diff_table`: a scale factor difference (biased by 64) as one of
/// five classes.
const scale_diff_table: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*out, i| {
        const v = @as(i32, i) - 64;
        out.* = if (v <= -3) 0 else if (v < 0) 1 else if (v == 0) 2 else if (v < 3) 3 else 4;
    }
    break :blk t;
};

/// `total_quant_bits`: the bits of 12 samples (three groups of three, or
/// twelve codes) at each quantizer.
const total_quant_bits: [17]u16 = blk: {
    var t: [17]u16 = undefined;
    for (&t, tab.quant_bits) |*out, b| out.* = 12 * @as(u16, if (b < 0) @intCast(-b) else @as(u16, @intCast(b)) * 3);
    break :blk t;
};

pub const Options = struct {
    /// The bit rate in bit/s (FFmpeg's `-b:a`, `avctx->bit_rate`); 0 takes
    /// the highest the version allows, 384 kbit/s or 160 kbit/s.
    bit_rate: i64 = 0,
    /// `mp2fixed`: the fixed-point quantizer.
    fixed: bool = false,
};

pub const Error = error{
    /// A sample rate other than 32, 44.1, 48, 16, 22.05 and 24 kHz, or a
    /// channel count other than 1 or 2 (CODEC_SAMPLERATES and
    /// CODEC_CH_LAYOUTS, which avcodec_open2 checks).
    UnsupportedFormat,
    /// A bit rate the version has no index for ("bitrate %d is not allowed
    /// in mp2", AVERROR(EINVAL)).
    InvalidOption,
};

pub const FrameError = error{
    /// Samples that are not whole sample frames of the encoder's channels,
    /// or more than 1152 of them.
    InvalidFrame,
};

pub const Encoder = struct {
    nb_channels: u2,
    lsf: bool,
    bitrate_index: u4,
    freq_index: u2,
    /// The frame's bits without padding.
    frame_size: i32,
    fixed: bool,
    /// The padding accumulator, in 1/65536 byte.
    frame_frac: i32 = 0,
    frame_frac_incr: i32,
    do_padding: bool = false,
    /// `avctx->bit_rate` after opening, in bit/s.
    bit_rate: i64,
    samples_buf: [2][samples_buf_size]i16 = @splat(@splat(0)),
    samples_offset: [2]usize = .{ 0, 0 },
    /// [channel][part][sample][subband].
    sb_samples: [2][3][12][sblimit]i32 = @splat(@splat(@splat(@splat(0)))),
    scale_factors: [2][sblimit][3]u8 = @splat(@splat(@splat(0))),
    scale_code: [2][sblimit]u8 = @splat(@splat(0)),
    sb_limit: usize,
    alloc_table: []const u8,
    scale_factor_table: [64]i32,
    scale_factor_inv_table: [64]f32,
    scale_factor_shift: [64]i8,
    scale_factor_mult: [64]u16,

    /// `mpa_encode_init` (with avcodec_open2's checks of the rate and the
    /// channels).
    pub fn init(sample_rate: u32, channels: u32, options: Options) Error!Encoder {
        if (channels < 1 or channels > 2) return error.UnsupportedFormat;
        var lsf = false;
        const freq_index: u2 = for (mpegaudio.freq_tab, 0..) |f, i| {
            if (f == sample_rate) break @intCast(i);
            if (f / 2 == sample_rate) {
                lsf = true;
                break @intCast(i);
            }
        } else return error.UnsupportedFormat;

        // `int bitrate = avctx->bit_rate`: the 64-bit option into the C's
        // int, which keeps its low 32 bits on the reference build (notes.md
        // "FFmpeg's MP2 encoder quirks kept").
        const c_bit_rate: i32 = @truncate(options.bit_rate);
        var bitrate: i32 = @divTrunc(c_bit_rate, 1000);
        var actual_bit_rate = options.bit_rate;
        const lsf_index: usize = @intFromBool(lsf);
        var index: u4 = for (1..15) |i| {
            if (mpegaudio.bitrate_tab[lsf_index][1][i] == bitrate) break @intCast(i);
        } else 15;
        if (index == 15 and options.bit_rate == 0) {
            index = 14;
            bitrate = mpegaudio.bitrate_tab[lsf_index][1][index];
            actual_bit_rate = @as(i64, bitrate) * 1000;
        }
        if (index == 15) return error.InvalidOption;

        // `a = (float)(bitrate * 1000 * MPA_FRAME_SIZE) / (freq * 8.0)`: the
        // int's float, a double division, stored into a float.
        // At most 384 * 1000 * 1152, within the C's int.
        const numerator: i32 = bitrate * 1000 * frame_samples;
        const a: f32 = @floatCast(@as(f64, @as(f32, @floatFromInt(numerator))) / (@as(f64, @floatFromInt(sample_rate)) * 8.0));
        const whole: i32 = @intFromFloat(@trunc(a)); // positive, below 2^11
        const a64: f64 = a;

        const table = tab.l2SelectTable(@intCast(bitrate), channels, sample_rate, lsf);
        var e: Encoder = .{
            .nb_channels = @intCast(channels),
            .lsf = lsf,
            .bitrate_index = index,
            .freq_index = freq_index,
            .frame_size = whole * 8,
            .fixed = options.fixed,
            .frame_frac_incr = @intFromFloat(@trunc((a64 - @floor(a64)) * 65536.0)),
            .bit_rate = actual_bit_rate,
            .sb_limit = tab.sblimit_table[table],
            .alloc_table = tab.alloc_tables[table],
            .scale_factor_table = undefined,
            .scale_factor_inv_table = @splat(0),
            .scale_factor_shift = @splat(0),
            .scale_factor_mult = @splat(0),
        };
        for (0..64) |i| {
            const third = @as(f64, @floatFromInt(3 - @as(i32, @intCast(i)))) / 3.0;
            // `(int)(exp2((3 - i) / 3.0) * (1 << 20))`: positive, below 2^22.
            var v: i32 = @intFromFloat(@trunc(libm.exp2(third) * (1 << 20)));
            if (v <= 0) v = 1;
            e.scale_factor_table[i] = v;
            if (e.fixed) {
                e.scale_factor_shift[i] = @intCast(21 - p_bits - @as(i32, @intCast(i / 3)));
                // `(1 << P) * exp2((i % 3) / 3.0)` into an unsigned short.
                e.scale_factor_mult[i] = @intFromFloat(@trunc((1 << p_bits) * libm.exp2(@as(f64, @floatFromInt(i % 3)) / 3.0)));
            } else {
                // `exp2(-(3 - i) / 3.0) / (float)(1 << 20)`, in double, into
                // a float.
                const neg = @as(f64, @floatFromInt(-(3 - @as(i32, @intCast(i))))) / 3.0;
                e.scale_factor_inv_table[i] = @floatCast(libm.exp2(neg) / @as(f64, 1 << 20));
            }
        }
        return e;
    }

    /// `mpa_encode_frame`: one frame of interleaved 16-bit samples, at most
    /// 1152 per channel (fewer are padded with silence, as encode.c pads a
    /// short last frame), into `out`; returns the packet.
    pub fn encodeFrame(e: *Encoder, samples: []const i16, out: *[max_packet]u8) FrameError![]u8 {
        const channels: usize = e.nb_channels;
        if (samples.len % channels != 0 or samples.len > frame_samples * channels) return error.InvalidFrame;
        var frame: [frame_samples * 2]i16 = @splat(0);
        @memcpy(frame[0..samples.len], samples);

        for (0..channels) |ch| e.filter(ch, frame[ch..], channels);
        for (0..channels) |ch| e.computeScaleFactors(ch);
        var bit_alloc: [2][sblimit]u8 = undefined;
        var padding: i32 = undefined;
        const size = e.computeBitAllocation(&bit_alloc, &padding);
        const packet = out[0..size];
        e.encodeFrameBits(packet, &bit_alloc);
        return packet;
    }

    /// `filter`: 36 rows of 32 subband samples from 1152 input samples (every
    /// `incr`th of `samples`), through the windowed history and `idct32`.
    fn filter(e: *Encoder, ch: usize, samples: []const i16, incr: usize) void {
        var offset = e.samples_offset[ch];
        const buf = &e.samples_buf[ch];
        var at: usize = 0;
        for (0..36) |j| {
            for (0..32) |i| {
                buf[offset + (31 - i)] = samples[at];
                at += incr;
            }
            var tmp: [64]i32 = undefined;
            // The C's int sums wrap on the reference build (notes.md
            // "Follow the reference build").
            for (0..64) |i| {
                var sum: i32 = 0;
                for (0..8) |k| sum +%= @as(i32, buf[offset + i + k * 64]) * filter_bank[i + k * 64];
                tmp[i] = sum;
            }
            var tmp1: [32]i32 = undefined;
            tmp1[0] = tmp[16] >> wshift;
            for (1..17) |i| tmp1[i] = (tmp[i + 16] +% tmp[16 - i]) >> wshift;
            for (17..32) |i| tmp1[i] = (tmp[i + 16] -% tmp[80 - i]) >> wshift;
            idct32(&e.sb_samples[ch][j / 12][j % 12], &tmp1);

            // advance of 32 samples, wrapping around the buffer
            if (offset < 32) {
                std.mem.copyBackwards(i16, buf[samples_buf_size - (512 - 32) ..], buf[0 .. 512 - 32]);
                offset = samples_buf_size - 512;
            } else {
                offset -= 32;
            }
        }
        e.samples_offset[ch] = offset;
    }

    /// `compute_scale_factors`: each subband's three scale factors (the
    /// smallest index whose value is at least the part's largest sample),
    /// then their transmission code, which merges close ones.
    fn computeScaleFactors(e: *Encoder, ch: usize) void {
        for (0..e.sb_limit) |j| {
            const sf = &e.scale_factors[ch][j];
            for (0..3) |i| {
                var vmax: u32 = 0;
                for (0..12) |k| vmax = @max(vmax, @abs(e.sb_samples[ch][i][k][j]));
                var index: i32 = undefined;
                if (vmax > 1) {
                    const n: i32 = std.math.log2_int(u32, vmax);
                    index = (21 - n) * 3 - 3;
                    if (index >= 0) {
                        while (vmax <= e.scale_factor_table[@intCast(index + 1)]) index += 1;
                    } else {
                        index = 0; // very unlikely case of overflow
                    }
                } else {
                    index = 62; // value 63 is not allowed
                }
                sf[i] = @intCast(index);
            }
            const d1 = scale_diff_table[@as(usize, sf[0]) + 64 - sf[1]];
            const d2 = scale_diff_table[@as(usize, sf[1]) + 64 - sf[2]];
            var code: u8 = undefined;
            switch (d1 * 5 + d2) {
                0 * 5 + 0, 0 * 5 + 4, 3 * 5 + 4, 4 * 5 + 0, 4 * 5 + 4 => code = 0,
                0 * 5 + 1, 0 * 5 + 2, 4 * 5 + 1, 4 * 5 + 2 => {
                    code = 3;
                    sf[2] = sf[1];
                },
                0 * 5 + 3, 4 * 5 + 3 => {
                    code = 3;
                    sf[1] = sf[2];
                },
                1 * 5 + 0, 1 * 5 + 4, 2 * 5 + 4 => {
                    code = 1;
                    sf[1] = sf[0];
                },
                1 * 5 + 1, 1 * 5 + 2, 2 * 5 + 0, 2 * 5 + 1, 2 * 5 + 2 => {
                    code = 2;
                    sf[1] = sf[0];
                    sf[2] = sf[0];
                },
                2 * 5 + 3, 3 * 5 + 3 => {
                    code = 2;
                    sf[0] = sf[2];
                    sf[1] = sf[2];
                },
                3 * 5 + 0, 3 * 5 + 1, 3 * 5 + 2 => {
                    code = 2;
                    sf[0] = sf[1];
                    sf[2] = sf[1];
                },
                1 * 5 + 3 => {
                    code = 2;
                    if (sf[0] > sf[2]) sf[0] = sf[2];
                    sf[1] = sf[0];
                    sf[2] = sf[0];
                },
                else => unreachable, // d1 and d2 are 0 to 4: 25 cases, all above
            }
            e.scale_code[ch][j] = code;
        }
    }

    /// `compute_bit_allocation`: the frame's size (with the padding byte the
    /// accumulator asks for), then allocations given one step at a time to
    /// the subband with the largest remaining signal-to-mask ratio while the
    /// bits fit. Returns the packet's bytes; `padding` is the bits left.
    fn computeBitAllocation(e: *Encoder, bit_alloc: *[2][sblimit]u8, padding: *i32) usize {
        const channels: usize = e.nb_channels;
        const SubbandStatus = enum { not_allocated, allocated, no_more };
        var smr: [2][sblimit]i16 = .{ smr_table, smr_table };
        var status: [2][sblimit]SubbandStatus = @splat(@splat(.not_allocated));
        bit_alloc.* = @splat(@splat(0));

        var max_frame_size = e.frame_size;
        e.frame_frac += e.frame_frac_incr;
        if (e.frame_frac >= 65536) {
            e.frame_frac -= 65536;
            e.do_padding = true;
            max_frame_size += 8;
        } else {
            e.do_padding = false;
        }

        // the header and the bit allocation fields
        var current: i32 = 32;
        var j: usize = 0;
        for (0..e.sb_limit) |_| {
            const incr = e.alloc_table[j];
            current += @as(i32, incr) * @as(i32, e.nb_channels);
            j += @as(usize, 1) << @intCast(incr);
        }
        while (true) {
            // the subband with the largest signal to mask ratio
            var max_smr: i32 = std.math.minInt(i32);
            var max_ch: usize = 0;
            var max_sb: ?usize = null;
            for (0..channels) |ch| {
                for (0..e.sb_limit) |i| {
                    if (smr[ch][i] > max_smr and status[ch][i] != .no_more) {
                        max_smr = smr[ch][i];
                        max_sb = i;
                        max_ch = ch;
                    }
                }
            }
            const sb = max_sb orelse break;
            var alloc: usize = 0;
            for (0..sb) |_| alloc += @as(usize, 1) << @intCast(e.alloc_table[alloc]);
            const table = e.alloc_table[alloc..];

            var incr: i32 = undefined;
            if (status[max_ch][sb] == .not_allocated) {
                // nothing was coded for this band: add the necessary bits
                incr = 2 + @as(i32, nb_scale_factors[e.scale_code[max_ch][sb]]) * 6;
                incr += total_quant_bits[table[1]];
            } else {
                const b = bit_alloc[max_ch][sb];
                incr = @as(i32, total_quant_bits[table[b + 1]]) - total_quant_bits[table[b]];
            }
            if (current + incr <= max_frame_size) {
                bit_alloc[max_ch][sb] += 1;
                const b = bit_alloc[max_ch][sb];
                current += incr;
                // decrease smr by the resolution we added; a short in the C
                smr[max_ch][sb] = @truncate(@as(i32, smr_table[sb]) - quant_snr[table[b]]);
                status[max_ch][sb] = if (b == (@as(u32, 1) << @intCast(table[0])) - 1) .no_more else .allocated;
            } else {
                status[max_ch][sb] = .no_more;
            }
        }
        padding.* = max_frame_size - current;
        std.debug.assert(padding.* >= 0);
        return @intCast(@divTrunc(max_frame_size, 8));
    }

    /// `encode_frame` with `encode_subbands`: the header, the allocations,
    /// scale codes and scale factors, then the quantized samples, three at a
    /// time; the rest of the packet zero.
    fn encodeFrameBits(e: *Encoder, packet: []u8, bit_alloc: *const [2][sblimit]u8) void {
        const channels: usize = e.nb_channels;
        var w: bits.BitWriter = .init(packet);
        w.bits(12, 0xfff);
        w.bits(1, @intFromBool(!e.lsf)); // 1 = MPEG-1 ID, 0 = MPEG-2 lsf ID
        w.bits(2, 4 - 2); // layer 2
        w.bits(1, 1); // no error protection
        w.bits(4, e.bitrate_index);
        w.bits(2, e.freq_index);
        w.bits(1, @intFromBool(e.do_padding));
        w.bits(1, 0); // private_bit
        w.bits(2, if (channels == 2) 0 else 3); // MPA_STEREO or MPA_MONO
        w.bits(2, 0); // mode_ext
        w.bits(1, 0); // no copyright
        w.bits(1, 1); // original
        w.bits(2, 0); // no emphasis

        var j: usize = 0;
        for (0..e.sb_limit) |i| {
            const alloc_bits = e.alloc_table[j];
            for (0..channels) |ch| w.bits(@intCast(alloc_bits), bit_alloc[ch][i]);
            j += @as(usize, 1) << @intCast(alloc_bits);
        }
        for (0..e.sb_limit) |i| {
            for (0..channels) |ch| {
                if (bit_alloc[ch][i] != 0) w.bits(2, e.scale_code[ch][i]);
            }
        }
        for (0..e.sb_limit) |i| {
            for (0..channels) |ch| {
                if (bit_alloc[ch][i] == 0) continue;
                const sf = e.scale_factors[ch][i];
                switch (e.scale_code[ch][i]) {
                    0 => w.bits(18, (@as(u32, sf[0]) << 12) | (@as(u32, sf[1]) << 6) | sf[2]),
                    3, 1 => w.bits(12, (@as(u32, sf[0]) << 6) | sf[2]),
                    2 => w.bits(6, sf[0]),
                    else => unreachable, // computeScaleFactors writes 0 to 3
                }
            }
        }

        for (0..3) |k| {
            var l: usize = 0;
            while (l < 12) : (l += 3) {
                j = 0;
                for (0..e.sb_limit) |i| {
                    const alloc_bits = e.alloc_table[j];
                    for (0..channels) |ch| {
                        const b = bit_alloc[ch][i];
                        if (b == 0) continue;
                        // three subband samples of the same subband at a time
                        const qindex = e.alloc_table[j + b];
                        const steps: u32 = tab.quant_steps[qindex];
                        var q: [3]u32 = undefined;
                        for (&q, 0..) |*qm, m| qm.* = e.quantize(e.sb_samples[ch][k][l + m][i], e.scale_factors[ch][i][k], steps);
                        const qbits = tab.quant_bits[qindex];
                        if (qbits < 0) {
                            // group the 3 values to save bits
                            w.bits(@intCast(-qbits), q[0] + steps * (q[1] + steps * q[2]));
                        } else {
                            for (q) |qm| w.bits(@intCast(qbits), qm);
                        }
                    }
                    j += @as(usize, 1) << @intCast(alloc_bits);
                }
            }
        }
        std.debug.assert(!w.overflow);
        w.flush();
        @memset(packet[w.pos..], 0);
    }

    /// One sample's quantizer step: divided by its scale factor, mapped to
    /// [0, steps), as `encode_subbands` does in float or fixed point.
    fn quantize(e: *const Encoder, sample: i32, scale: u8, steps: u32) u32 {
        var q: i32 = undefined;
        if (!e.fixed) {
            // `float a = (float)sample * inv`, then `(int)((a + 1.0) * steps
            // * 0.5)` in double, converted as the reference build converts
            // it (notes.md "Follow the reference build").
            const a = @as(f32, @floatFromInt(sample)) * e.scale_factor_inv_table[scale];
            q = cconv.cvttsd2si32((@as(f64, a) + 1.0) * @as(f64, @floatFromInt(steps)) * 0.5);
        } else {
            const shift = e.scale_factor_shift[scale];
            const mult: i32 = e.scale_factor_mult[scale];
            // normalize to P bits; the C's int arithmetic wraps on the
            // reference build (notes.md "Follow the reference build")
            var q1: i32 = if (shift < 0) sample *% (@as(i32, 1) << @intCast(-shift)) else sample >> @intCast(shift);
            q1 = (q1 *% mult) >> p_bits;
            q1 +%= 1 << p_bits;
            if (q1 < 0) q1 = 0;
            // `(q1 * (unsigned)steps) >> (P + 1)`: an unsigned product.
            q = @bitCast((@as(u32, @bitCast(q1)) *% steps) >> (p_bits + 1));
        }
        if (q >= steps) q = @intCast(steps - 1);
        // The scale factor bounds the sample, so q is never negative; the
        // C's put_bits would take its low bits.
        return @intCast(@max(q, 0));
    }
};

/// `idct32`: FFmpeg's 32-point integer transform, in place on `tab_in`,
/// into `out` in bit-reversed order. The C's int arithmetic, which wraps
/// on the reference build (notes.md "Follow the reference build").
fn idct32(out: *[32]i32, t: *[32]i32) void {
    var xp: usize = 0;
    {
        var j: usize = 31;
        while (j >= 3) : (j -= 2) t[j] +%= t[j - 2];
    }
    {
        var at: usize = 30;
        while (at != 2) : (at -= 4) {
            t[at] +%= t[at - 4];
            t[at + 1] +%= t[at + 1 - 4];
        }
    }
    {
        var at: usize = 28;
        while (at != 4) : (at -= 8) {
            inline for (0..4) |d| t[at + d] +%= t[at + d - 8];
        }
    }
    {
        var at: usize = 0;
        while (at != 32) : (at += 16) {
            inline for (.{ 3, 6, 11, 12, 13, 15 }) |d| t[at + d] = 0 -% t[at + d];
        }
    }
    const half_sqrt2 = fix(std.math.sqrt2 * 0.5);
    for (0..8) |k| {
        var x3 = mul(t[k + 16], half_sqrt2);
        const x4 = t[k] -% x3;
        x3 = t[k] +% x3;
        var x2 = mul(0 -% (t[k + 24] +% t[k + 8]), half_sqrt2);
        const x1 = mul(t[k + 8] -% x2, costab32[xp + 0]);
        x2 = mul(t[k + 8] +% x2, costab32[xp + 1]);
        t[k + 0] = x3 +% x1;
        t[k + 8] = x4 -% x2;
        t[k + 16] = x4 +% x2;
        t[k + 24] = x3 -% x1;
    }
    xp += 2;
    for (0..4) |k| {
        var xr = mul(t[k + 28], costab32[xp + 0]);
        t[k + 28] = t[k] -% xr;
        t[k] = t[k] +% xr;
        xr = mul(t[k + 4], costab32[xp + 1]);
        t[k + 4] = t[k + 24] -% xr;
        t[k + 24] = t[k + 24] +% xr;
        xr = mul(t[k + 20], costab32[xp + 2]);
        t[k + 20] = t[k + 8] -% xr;
        t[k + 8] = t[k + 8] +% xr;
        xr = mul(t[k + 12], costab32[xp + 3]);
        t[k + 12] = t[k + 16] -% xr;
        t[k + 16] = t[k + 16] +% xr;
    }
    xp += 4;
    for (0..4) |i| {
        var xr = mul(t[30 - i * 4], costab32[xp + 0]);
        t[30 - i * 4] = t[i * 4] -% xr;
        t[i * 4] = t[i * 4] +% xr;
        xr = mul(t[2 + i * 4], costab32[xp + 1]);
        t[2 + i * 4] = t[28 - i * 4] -% xr;
        t[28 - i * 4] = t[28 - i * 4] +% xr;
        xr = mul(t[31 - i * 4], costab32[xp + 0]);
        t[31 - i * 4] = t[1 + i * 4] -% xr;
        t[1 + i * 4] = t[1 + i * 4] +% xr;
        xr = mul(t[3 + i * 4], costab32[xp + 1]);
        t[3 + i * 4] = t[29 - i * 4] -% xr;
        t[29 - i * 4] = t[29 - i * 4] +% xr;
        xp += 2;
    }
    for (0..16) |k| {
        const hi = 30 - 2 * k;
        const lo = 1 + 2 * k;
        const xr = mul(t[lo], costab32[xp]);
        t[lo] = t[hi] -% xr;
        t[hi] = t[hi] +% xr;
        xp += 1;
    }
    for (out, bitinv32) |*o, b| o.* = t[b];
}

const testing = std.testing;
const hostile = @import("../testing/hostile.zig");

/// mp2enc_vectors.c's signal generator: xorshift32 seeded by the case.
const Signal = struct {
    state: u32,
    filter: [2]i32 = .{ 0, 0 },

    fn rng(s: *Signal) u32 {
        var x = s.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        s.state = x;
        return x;
    }

    fn sample(s: *Signal, kind: []const u8, c: usize, i: usize) i16 {
        const noise: i32 = @as(i32, @intCast(s.rng() & 0xffff)) - 0x8000;
        var v: i32 = undefined;
        if (std.mem.eql(u8, kind, "tone")) {
            const period: i32 = 64 + 24 * @as(i32, @intCast(c));
            const phase: i32 = @intCast(@rem(@as(i64, @intCast(i)), period));
            const tri = if (phase < @divTrunc(period, 2)) phase else period - phase;
            v = @divTrunc((tri * 2 - @divTrunc(period, 2)) * 16384, @divTrunc(period, 2)) + @divTrunc(noise, 8);
        } else if (std.mem.eql(u8, kind, "noise")) {
            v = noise;
        } else if (std.mem.eql(u8, kind, "smooth")) {
            s.filter[c] += @divTrunc(noise - s.filter[c], 8);
            v = s.filter[c] * 2;
        } else if (std.mem.eql(u8, kind, "silence")) {
            v = 0;
        } else if (std.mem.eql(u8, kind, "extremes")) {
            v = if (((i + c) & 1) != 0) 32767 else -32768;
            if (s.rng() & 1 != 0) v = -32768;
        } else unreachable; // the oracle's signals
        return @intCast(std.math.clamp(v, -32768, 32767));
    }
};

test "every case encodes as FFmpeg's MP2 encoders encode it (vectors/mp2enc.txt)" {
    const vectors = @embedFile("../testing/vectors/mp2enc.txt");
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    var line = lines.next();
    while (line) |c_line| {
        if (c_line.len == 0) {
            line = lines.next();
            continue;
        }
        var f = std.mem.tokenizeScalar(u8, c_line, ' ');
        try testing.expectEqualStrings("C", f.next().?);
        const name = f.next().?;
        const encoder = f.next().?;
        const kind = f.next().?;
        const channels = try std.fmt.parseInt(u32, f.next().?, 10);
        const rate = try std.fmt.parseInt(u32, f.next().?, 10);
        const bit_rate = try std.fmt.parseInt(i64, f.next().?, 10);
        const total = try std.fmt.parseInt(usize, f.next().?, 10);
        const open = lines.next().?;
        line = lines.next();
        const result = Encoder.init(rate, channels, .{ .bit_rate = bit_rate, .fixed = std.mem.eql(u8, encoder, "mp2fixed") });
        if (!std.mem.eql(u8, open, "O ok")) {
            try testing.expectEqualStrings("O EINVAL", open);
            try testing.expect(std.meta.isError(result));
            cases += 1;
            continue;
        }
        var e = try result;
        var info = std.mem.tokenizeScalar(u8, line.?, ' ');
        _ = info.next();
        try testing.expectEqual(try std.fmt.parseInt(i64, info.next().?, 10), e.bit_rate);
        line = lines.next();

        var signal: Signal = .{ .state = 0x9E3779B9 ^ @as(u32, @intCast(channels * 1000003 + total)) };
        var start: usize = 0;
        var frame: [frame_samples * 2]i16 = undefined;
        var out: [max_packet]u8 = undefined;
        while (start < total) : (start += frame_samples) {
            const n = @min(total - start, frame_samples);
            for (0..n) |i| {
                for (0..channels) |c| frame[i * channels + c] = signal.sample(kind, c, start + i);
            }
            const packet = try e.encodeFrame(frame[0 .. n * channels], &out);
            var digest: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(packet, &digest, .{});
            var want = std.mem.tokenizeScalar(u8, line.?, ' ');
            try testing.expectEqualStrings("P", want.next().?);
            try testing.expectEqual(@as(i64, @intCast(start)) - initial_padding, try std.fmt.parseInt(i64, want.next().?, 10));
            try testing.expectEqual(frame_samples, try std.fmt.parseInt(usize, want.next().?, 10));
            testing.expectEqual(try std.fmt.parseInt(usize, want.next().?, 10), packet.len) catch |err| {
                std.debug.print("mp2enc case {s}, frame at {d}\n", .{ name, start });
                return err;
            };
            testing.expectEqualStrings(want.next().?, &std.fmt.bytesToHex(digest, .lower)) catch |err| {
                std.debug.print("mp2enc case {s}, frame at {d}\n", .{ name, start });
                return err;
            };
            line = lines.next();
        }
        cases += 1;
    }
    try testing.expectEqual(18, cases);
}

test "the encoder refuses rates, channel counts and bit rates FFmpeg's refuses" {
    try testing.expectError(error.UnsupportedFormat, Encoder.init(8000, 2, .{}));
    try testing.expectError(error.UnsupportedFormat, Encoder.init(44100, 3, .{}));
    try testing.expectError(error.UnsupportedFormat, Encoder.init(44100, 0, .{}));
    try testing.expectError(error.InvalidOption, Encoder.init(44100, 2, .{ .bit_rate = 100000 }));
    // An LSF rate takes LSF bit rates: 8 kbit/s is one, 384 is not.
    _ = try Encoder.init(22050, 1, .{ .bit_rate = 8000 });
    try testing.expectError(error.InvalidOption, Encoder.init(22050, 1, .{ .bit_rate = 384000 }));
    const e = try Encoder.init(24000, 2, .{});
    try testing.expectEqual(160000, e.bit_rate);
    // The C keeps the low 32 bits of a 64-bit rate: 2^32 + 128000 is
    // 128 kbit/s, which avctx->bit_rate keeps as given.
    const wrapped = try Encoder.init(44100, 2, .{ .bit_rate = (1 << 32) + 128000 });
    try testing.expectEqual(8, wrapped.bitrate_index);
    try testing.expectEqual((1 << 32) + 128000, wrapped.bit_rate);
}

test "a frame of the wrong length is refused" {
    var e = try Encoder.init(44100, 2, .{});
    var out: [max_packet]u8 = undefined;
    const samples: [frame_samples * 2 + 2]i16 = @splat(0);
    try testing.expectError(error.InvalidFrame, e.encodeFrame(samples[0..3], &out));
    try testing.expectError(error.InvalidFrame, e.encodeFrame(&samples, &out));
    _ = try e.encodeFrame(samples[0..0], &out);
}

/// One fuzz run: an encoder from the input's rate, channels, bit rate and
/// quantizer, then its samples, frame by frame. Every packet is a frame
/// whose header gives the packet's own size, with the stream's rate and
/// channel mode.
fn fuzzRun(smith: *std.testing.Smith) !u32 {
    var input: [4 * frame_samples * 2 * 2 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const rates = [_]u32{ 44100, 48000, 32000, 22050, 24000, 16000 };
    const rate = rates[smith.valueRangeAtMost(u8, 0, rates.len - 1)];
    const channels = smith.valueRangeAtMost(u32, 1, 2);
    const bit_rate: i64 = @bitCast(smith.value(u64));
    const fixed = smith.value(bool);
    var e = Encoder.init(rate, channels, .{ .bit_rate = bit_rate, .fixed = fixed }) catch |err| switch (err) {
        error.InvalidOption => return 0,
        error.UnsupportedFormat => unreachable, // the rates and channels above
    };
    const frame_bytes = 2 * channels;
    const usable = len - len % frame_bytes;
    var frames: u32 = 0;
    var start: usize = 0;
    var samples: [frame_samples * 2]i16 = undefined;
    var out: [max_packet]u8 = undefined;
    while (start < usable or frames == 0) {
        const n = @min(usable - start, frame_samples * frame_bytes) / 2;
        for (0..n) |i| samples[i] = std.mem.readInt(i16, input[start + 2 * i ..][0..2], .little);
        const packet = try e.encodeFrame(samples[0..n], &out);
        const header = mpegaudio.decodeHeader(std.mem.readInt(u32, packet[0..4], .big)).?;
        try testing.expectEqual(packet.len, header.frame_size);
        try testing.expectEqual(rate, header.sample_rate);
        try testing.expectEqual(channels, header.nb_channels);
        start += 2 * n;
        frames += 1;
    }
    return frames;
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    _ = try fuzzRun(smith);
}

fn seedBytes(comptime n: usize) [n]u8 {
    var out: [n]u8 = undefined;
    @setEvalBranchQuota(4 * n + 1000);
    var x: u32 = 0x12345678;
    for (&out) |*b| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.* = @truncate(x);
    }
    return out;
}

const seed_samples = seedBytes(2 * frame_samples * 2 * 2 + 100);
const fuzz_corpus: []const []const u8 = &.{
    // The values: the rate's index, the channels, the bit rate, fixed.
    hostile.fuzzSeed(&seed_samples, &.{ 0, 2, 128000, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 1, 1, 384000, 1 }),
    hostile.fuzzSeed(&seed_samples, &.{ 3, 2, 0, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 5, 1, 8000, 1 }),
    hostile.fuzzSeed(&(@as([2 * frame_samples * 2]u8, @splat(0x80)) ++ @as([2 * frame_samples * 2]u8, @splat(0x7f))), &.{ 2, 2, 0, 1 }),
    hostile.fuzzSeed("", &.{ 4, 2, 64000, 0 }),
};

test "fuzz: the MP2 encoder on arbitrary samples, rates and bit rates" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the MP2 encoder's fuzz entry encodes frames" {
    for (fuzz_corpus) |seed| {
        var smith: std.testing.Smith = .{ .in = seed };
        try testing.expect(try fuzzRun(&smith) > 0);
    }
}

test "mutation smoke: the MP2 encoder on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 48, 0x6d703265);
}
