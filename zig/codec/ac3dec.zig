// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/ac3dec.c, ac3dec_float.c, ac3dec.h,
// ac3dec_data.c, ac3.c (ff_ac3_bit_alloc_calc_psd,
// ff_ac3_bit_alloc_calc_mask), ac3dsp.c (ac3_bit_alloc_calc_bap_c) and
// ac3tab.c at the pinned reference revision.
// Copyright (c) 2007-2008 Bartlomiej Wolowiec <bartek.wolowiec@gmail.com>
// Copyright (c) 2007-2008 Justin Ruggles <justin.ruggles@gmail.com>
// Copyright (c) 2007 Kostya Shishkov
// Copyright (c) 2006 Justin Ruggles
// Copyright (c) 2001-2003 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float AC-3 decoder (`ac3`, TODO.md T32a), sample for sample:
//! exponents, bit allocation, mantissas with dither, coupling,
//! rematrixing, dynamic range, the 256- and 128-point IMDCTs and the KBD
//! window, and its error concealment, which repeats a block's output when
//! a frame fails. Its options keep FFmpeg's defaults (no downmix, the
//! dynamic range scale 1, no heavy compression, no target level, no
//! consistent noise): the decoder gives every coded channel in
//! `ff_ac3_channel_layout_tab`'s layout. The reference build has no E-AC-3
//! decoder, so an E-AC-3 frame fails as FFmpeg's "E-AC-3 support not
//! compiled in" (notes.md "AC-3").

const std = @import("std");
const bits = @import("bits.zig");
const ac3 = @import("ac3.zig");
const tx = @import("tx.zig");
const float_dsp = @import("float_dsp.zig");
const aac_tab = @import("aac_tab.zig");
const Lfg = @import("../core/lfg.zig").Lfg;

pub const max_channels = 7; // AC3_MAX_CHANNELS, the coupling channel included
const cpl_ch = 0;
const max_coefs = 256;
pub const block_size = 256;
const max_blocks = 6;
const critical_bands = 50;
const max_cpl_bands = 18;
/// AC3_FRAME_BUFFER_SIZE.
const frame_buffer_size = 32768;
const output_lfeon = 8;

const exp_reuse = 0;
const exp_d45 = 3;
const dba_new = 1;
const dba_none = 2;
const dba_reserved = 3;

// --- Tables -----------------------------------------------------------------

/// 2^v, exactly, for the dynamic range tables' `powf(2.0f, v)`.
fn exp2i(v: i32) f32 {
    return if (v >= 0) @floatFromInt(@as(u32, 1) << @intCast(v)) else 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << @intCast(-v)));
}

/// `dynamic_range_tab`: code to scale factor (7.7.1).
const dynamic_range_tab: [256]f32 = blk: {
    var t: [256]f32 = undefined;
    for (&t, 0..) |*x, i| {
        const v: i32 = @as(i32, i >> 5) - @as(i32, (i >> 7) << 3) - 5;
        x.* = exp2i(v) * @as(f32, @floatFromInt((i & 0x1F) | 0x20));
    }
    break :blk t;
};

/// `scale_factors`: 2^-exp.
const scale_factors: [25]f32 = blk: {
    var t: [25]f32 = undefined;
    for (&t, 0..) |*x, i| x.* = exp2i(-@as(i32, i));
    break :blk t;
};

/// SYMMETRIC_DEQUANT, with C's truncating division.
fn symmetricDequant(code: i32, levels: i32) i32 {
    return @divTrunc((code - (levels >> 1)) * (1 << 24), levels);
}

const ungroup_3_in_7: [128][3]u8 = blk: {
    var t: [128][3]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = .{ i / 25, (i % 25) / 5, (i % 25) % 5 };
    break :blk t;
};

const ungroup_3_in_5: [32][3]u8 = blk: {
    var t: [32][3]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = .{ i / 9, (i % 9) / 3, (i % 9) % 3 };
    break :blk t;
};

const bap1_mantissas: [32][3]i32 = blk: {
    var t: [32][3]i32 = undefined;
    for (&t, ungroup_3_in_5) |*x, g| {
        for (x, g) |*m, c| m.* = symmetricDequant(c, 3);
    }
    break :blk t;
};

const bap2_mantissas: [128][3]i32 = blk: {
    var t: [128][3]i32 = undefined;
    for (&t, ungroup_3_in_7) |*x, g| {
        for (x, g) |*m, c| m.* = symmetricDequant(c, 5);
    }
    break :blk t;
};

const bap4_mantissas: [128][2]i32 = blk: {
    var t: [128][2]i32 = undefined;
    for (&t, 0..) |*x, i| x.* = .{ symmetricDequant(i / 11, 11), symmetricDequant(i % 11, 11) };
    break :blk t;
};

/// `ff_ac3_bap3_mantissas`: seven levels, then 0.
const bap3_mantissas: [8]i32 = blk: {
    var t: [8]i32 = @splat(0);
    for (0..7) |i| t[i] = symmetricDequant(i, 7);
    break :blk t;
};

const bap5_mantissas: [16]i32 = blk: {
    var t: [16]i32 = @splat(0);
    for (0..15) |i| t[i] = symmetricDequant(i, 15);
    break :blk t;
};

const quantization_tab = [16]u8{ 0, 3, 5, 7, 11, 15, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16 };

const bap_tab = [64]u8{
    0,  1,  1,  1,  1,  1,  2,  2,  3,  3,  3,  4,  4,  5,  5,  6,
    6,  6,  6,  7,  7,  7,  7,  8,  8,  8,  8,  9,  9,  9,  9,  10,
    10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14,
    14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15,
};

const slow_decay_tab = [4]i32{ 0x0f, 0x11, 0x13, 0x15 };
const fast_decay_tab = [4]i32{ 0x3f, 0x53, 0x67, 0x7b };
const slow_gain_tab = [4]i32{ 0x540, 0x4d8, 0x478, 0x410 };
const db_per_bit_tab = [4]i32{ 0x000, 0x700, 0x900, 0xb00 };
/// `ff_ac3_floor_tab` (int16_t: 0xf800 is -2048).
const floor_tab = [8]i32{ 0x2f0, 0x2b0, 0x270, 0x230, 0x1f0, 0x170, 0x0f0, -0x800 };
const fast_gain_tab = [8]i32{ 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380, 0x400 };

const rematrix_band_tab = [5]u8{ 13, 25, 37, 61, 253 };
const default_cpl_band_struct = [18]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1 };

/// `ff_ac3_dec_channel_map`: by channel mode and LFE, each output channel's
/// coded channel.
const dec_channel_map = [8][2][6]u8{
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 0, 0, 0 } },
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 2, 1, 0, 0, 0 }, .{ 0, 2, 1, 3, 0, 0 } },
    .{ .{ 0, 1, 2, 0, 0, 0 }, .{ 0, 1, 3, 2, 0, 0 } },
    .{ .{ 0, 2, 1, 3, 0, 0 }, .{ 0, 2, 1, 4, 3, 0 } },
    .{ .{ 0, 1, 2, 3, 0, 0 }, .{ 0, 1, 4, 2, 3, 0 } },
    .{ .{ 0, 2, 1, 3, 4, 0 }, .{ 0, 2, 1, 5, 3, 4 } },
};

pub const band_start_tab = [critical_bands + 1]u8{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,   10,  11,  12,  13,  14,  15,  16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26,  27,  28,  31,  34,  37,  40,  43,
    46, 49, 55, 61, 67, 73, 79, 85, 97, 109, 121, 133, 157, 181, 205, 229, 253,
};

/// `ff_ac3_bin_to_band_tab`: each bin's critical band.
pub const bin_to_band_tab: [253]u8 = blk: {
    var t: [253]u8 = undefined;
    for (0..critical_bands) |band| {
        for (band_start_tab[band]..band_start_tab[band + 1]) |bin| t[bin] = band;
    }
    break :blk t;
};

const log_add_tab = [260]u8{
    0x40, 0x3f, 0x3e, 0x3d, 0x3c, 0x3b, 0x3a, 0x39, 0x38, 0x37, 0x36, 0x35, 0x34, 0x34, 0x33, 0x32, 0x31, 0x30, 0x2f, 0x2f,
    0x2e, 0x2d, 0x2c, 0x2c, 0x2b, 0x2a, 0x29, 0x29, 0x28, 0x27, 0x26, 0x26, 0x25, 0x24, 0x24, 0x23, 0x23, 0x22, 0x21, 0x21,
    0x20, 0x20, 0x1f, 0x1e, 0x1e, 0x1d, 0x1d, 0x1c, 0x1c, 0x1b, 0x1b, 0x1a, 0x1a, 0x19, 0x19, 0x18, 0x18, 0x17, 0x17, 0x16,
    0x16, 0x15, 0x15, 0x15, 0x14, 0x14, 0x13, 0x13, 0x13, 0x12, 0x12, 0x12, 0x11, 0x11, 0x11, 0x10, 0x10, 0x10, 0x0f, 0x0f,
    0x0f, 0x0e, 0x0e, 0x0e, 0x0d, 0x0d, 0x0d, 0x0d, 0x0c, 0x0c, 0x0c, 0x0c, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0a, 0x0a, 0x0a,
    0x0a, 0x09, 0x09, 0x09, 0x09, 0x09, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

const hearing_threshold_tab = [critical_bands][3]i32{
    .{ 0x04d0, 0x04f0, 0x0580 }, .{ 0x04d0, 0x04f0, 0x0580 }, .{ 0x0440, 0x0460, 0x04b0 }, .{ 0x0400, 0x0410, 0x0450 },
    .{ 0x03e0, 0x03e0, 0x0420 }, .{ 0x03c0, 0x03d0, 0x03f0 }, .{ 0x03b0, 0x03c0, 0x03e0 }, .{ 0x03b0, 0x03b0, 0x03d0 },
    .{ 0x03a0, 0x03b0, 0x03c0 }, .{ 0x03a0, 0x03a0, 0x03b0 }, .{ 0x03a0, 0x03a0, 0x03b0 }, .{ 0x03a0, 0x03a0, 0x03b0 },
    .{ 0x03a0, 0x03a0, 0x03a0 }, .{ 0x0390, 0x03a0, 0x03a0 }, .{ 0x0390, 0x0390, 0x03a0 }, .{ 0x0390, 0x0390, 0x03a0 },
    .{ 0x0380, 0x0390, 0x03a0 }, .{ 0x0380, 0x0380, 0x03a0 }, .{ 0x0370, 0x0380, 0x03a0 }, .{ 0x0370, 0x0380, 0x03a0 },
    .{ 0x0360, 0x0370, 0x0390 }, .{ 0x0360, 0x0370, 0x0390 }, .{ 0x0350, 0x0360, 0x0390 }, .{ 0x0350, 0x0360, 0x0390 },
    .{ 0x0340, 0x0350, 0x0380 }, .{ 0x0340, 0x0350, 0x0380 }, .{ 0x0330, 0x0340, 0x0380 }, .{ 0x0320, 0x0340, 0x0370 },
    .{ 0x0310, 0x0320, 0x0360 }, .{ 0x0300, 0x0310, 0x0350 }, .{ 0x02f0, 0x0300, 0x0340 }, .{ 0x02f0, 0x02f0, 0x0330 },
    .{ 0x02f0, 0x02f0, 0x0320 }, .{ 0x02f0, 0x02f0, 0x0310 }, .{ 0x0300, 0x02f0, 0x0300 }, .{ 0x0310, 0x0300, 0x02f0 },
    .{ 0x0340, 0x0320, 0x02f0 }, .{ 0x0390, 0x0350, 0x02f0 }, .{ 0x03e0, 0x0390, 0x0300 }, .{ 0x0420, 0x03e0, 0x0310 },
    .{ 0x0460, 0x0420, 0x0330 }, .{ 0x0490, 0x0450, 0x0350 }, .{ 0x04a0, 0x04a0, 0x03c0 }, .{ 0x0460, 0x0490, 0x0410 },
    .{ 0x0440, 0x0460, 0x0470 }, .{ 0x0440, 0x0440, 0x04a0 }, .{ 0x0520, 0x0480, 0x0460 }, .{ 0x0800, 0x0630, 0x0440 },
    .{ 0x0840, 0x0840, 0x0450 }, .{ 0x0840, 0x0840, 0x04e0 },
};

/// The decoder's KBD window, alpha 5 over 256 samples.
const window: [256]f32 = aac_tab.kbdWindow(256, 5.0);

// --- Bit allocation (ac3.c, ac3dsp.c) ----------------------------------------

const BitAllocParams = struct {
    sr_code: u8 = 0,
    sr_shift: u8 = 0,
    slow_gain: i32 = 0,
    slow_decay: i32 = 0,
    fast_decay: i32 = 0,
    db_per_bit: i32 = 0,
    floor: i32 = 0,
    cpl_fast_leak: i32 = 0,
    cpl_slow_leak: i32 = 0,
};

fn calcLowcomp1(a: i32, b0: i32, b1: i32, c: i32) i32 {
    if (b0 + 256 == b1) return c;
    if (b0 > b1) return @max(a - 64, 0);
    return a;
}

fn calcLowcomp(a: i32, b0: i32, b1: i32, bin: usize) i32 {
    if (bin < 7) return calcLowcomp1(a, b0, b1, 384);
    if (bin < 20) return calcLowcomp1(a, b0, b1, 320);
    return @max(a - 128, 0);
}

/// ff_ac3_bit_alloc_calc_psd. The int16_t stores keep the low bits (the
/// values stay well inside them for exponents 0 to 24).
fn calcPsd(exp: []const i8, start: usize, end: usize, psd: []i16, band_psd: []i16) void {
    for (start..end) |bin| psd[bin] = @truncate(3072 - (@as(i32, exp[bin]) << 7));
    var bin = start;
    while (bin < @min(end, 28)) : (bin += 1) band_psd[bin] = psd[bin];
    if (bin >= end) return;
    var band: usize = bin_to_band_tab[bin];
    while (true) {
        var v: i32 = psd[bin];
        bin += 1;
        const band_end = @min(band_start_tab[band + 1], end);
        while (bin < band_end) : (bin += 1) {
            const p: i32 = psd[bin];
            const max = @max(v, p);
            const adr: usize = @intCast(@min(max - ((v + p + 1) >> 1), 255));
            v = max + log_add_tab[adr];
        }
        band_psd[band] = @truncate(v);
        band += 1;
        if (!(end > band_start_tab[band])) break;
    }
}

const Dba = struct { mode: i32, nsegs: i32, offsets: []const u8, lengths: []const u8, values: []const u8 };

/// ff_ac3_bit_alloc_calc_mask; false where FFmpeg returns an error.
fn calcMask(s: *const BitAllocParams, band_psd: []const i16, start: usize, end: usize, fast_gain: i32, is_lfe: bool, dba: Dba, mask: []i16) bool {
    var excite: [critical_bands]i16 = undefined;
    if (end <= 0) return false;
    const band_start: usize = bin_to_band_tab[start];
    const band_end: usize = @as(usize, bin_to_band_tab[end - 1]) + 1;
    var begin: usize = undefined;
    var fastleak: i32 = undefined;
    var slowleak: i32 = undefined;
    const bp = struct {
        fn at(p: []const i16, i: usize) i32 {
            return p[i];
        }
    }.at;
    if (band_start == 0) {
        var lowcomp: i32 = 0;
        lowcomp = calcLowcomp1(lowcomp, bp(band_psd, 0), bp(band_psd, 1), 384);
        excite[0] = @truncate(bp(band_psd, 0) - fast_gain - lowcomp);
        lowcomp = calcLowcomp1(lowcomp, bp(band_psd, 1), bp(band_psd, 2), 384);
        excite[1] = @truncate(bp(band_psd, 1) - fast_gain - lowcomp);
        begin = 7;
        var band: usize = 2;
        while (band < 7) : (band += 1) {
            if (!(is_lfe and band == 6)) lowcomp = calcLowcomp1(lowcomp, bp(band_psd, band), bp(band_psd, band + 1), 384);
            fastleak = bp(band_psd, band) - fast_gain;
            slowleak = bp(band_psd, band) - s.slow_gain;
            excite[band] = @truncate(fastleak - lowcomp);
            if (!(is_lfe and band == 6)) {
                if (bp(band_psd, band) <= bp(band_psd, band + 1)) {
                    begin = band + 1;
                    break;
                }
            }
        }
        const end1 = @min(band_end, 22);
        band = begin;
        while (band < end1) : (band += 1) {
            if (!(is_lfe and band == 6)) lowcomp = calcLowcomp(lowcomp, bp(band_psd, band), bp(band_psd, band + 1), band);
            fastleak = @max(fastleak - s.fast_decay, bp(band_psd, band) - fast_gain);
            slowleak = @max(slowleak - s.slow_decay, bp(band_psd, band) - s.slow_gain);
            excite[band] = @truncate(@max(fastleak - lowcomp, slowleak));
        }
        begin = 22;
    } else {
        // The coupling channel.
        begin = band_start;
        fastleak = (s.cpl_fast_leak << 8) + 768;
        slowleak = (s.cpl_slow_leak << 8) + 768;
    }
    var band = begin;
    while (band < band_end) : (band += 1) {
        fastleak = @max(fastleak - s.fast_decay, bp(band_psd, band) - fast_gain);
        slowleak = @max(slowleak - s.slow_decay, bp(band_psd, band) - s.slow_gain);
        excite[band] = @truncate(@max(fastleak, slowleak));
    }
    // The masking curve.
    band = band_start;
    while (band < band_end) : (band += 1) {
        const tmp = s.db_per_bit - bp(band_psd, band);
        if (tmp > 0) excite[band] = @truncate(@as(i32, excite[band]) + (tmp >> 2));
        mask[band] = @truncate(@max(hearing_threshold_tab[band >> @intCast(s.sr_shift)][s.sr_code], @as(i32, excite[band])));
    }
    // Delta bit allocation.
    if (dba.mode == 0 or dba.mode == dba_new) {
        if (dba.nsegs > 8) return false;
        band = band_start;
        for (0..@intCast(dba.nsegs)) |seg| {
            band += dba.offsets[seg];
            if (band >= critical_bands or dba.lengths[seg] > critical_bands - band) return false;
            const delta: i32 = if (dba.values[seg] >= 4) (@as(i32, dba.values[seg]) - 3) * 128 else (@as(i32, dba.values[seg]) - 4) * 128;
            for (0..dba.lengths[seg]) |_| {
                mask[band] = @truncate(@as(i32, mask[band]) + delta);
                band += 1;
            }
        }
    }
    return true;
}

/// ac3_bit_alloc_calc_bap_c.
fn calcBap(mask: []const i16, psd: []const i16, start: usize, end: usize, snr_offset: i32, floor: i32, bap: []u8) void {
    if (snr_offset == -960) {
        @memset(bap[0..max_coefs], 0);
        return;
    }
    var bin = start;
    while (bin < @min(end, 28)) : (bin += 1) {
        const m = (@max(@as(i32, mask[bin]) - snr_offset - floor, 0) & 0x1FE0) + floor;
        bap[bin] = bap_tab[clipUintp2_6((@as(i32, psd[bin]) - m) >> 5)];
    }
    if (bin >= end) return;
    var band: usize = bin_to_band_tab[bin];
    while (true) {
        const m = (@max(@as(i32, mask[band]) - snr_offset - floor, 0) & 0x1FE0) + floor;
        band += 1;
        const band_end = @min(band_start_tab[band], end);
        while (bin < band_end) : (bin += 1) bap[bin] = bap_tab[clipUintp2_6((@as(i32, psd[bin]) - m) >> 5)];
        if (!(end > band_end)) break;
    }
}

/// av_clip_uintp2(a, 6).
fn clipUintp2_6(a: i32) usize {
    return @intCast(std.math.clamp(a, 0, 63));
}

// --- The decoder --------------------------------------------------------------

/// A decode call's failure, as FFmpeg's return code names it.
pub const Error = error{
    /// AVERROR_INVALIDDATA.
    InvalidData,
    /// AVERROR(ENOSYS): an E-AC-3 frame, which the reference build's decoder
    /// does not decode ("E-AC-3 support not compiled in").
    Unsupported,
    /// An AC3_PARSE_ERROR_* code, which ac3_decode_frame returns as it is
    /// when the header after a frame does not parse (`errorCode`).
    NextSync,
    NextBsid,
    NextSampleRate,
    NextFrameSize,
    NextFrameType,
    NextChannelMap,
};

/// The int ac3_decode_frame returns for `err`, as libavcodec passes it on.
pub fn errorCode(err: Error) i32 {
    return switch (err) {
        error.InvalidData => -0x41444e49, // AVERROR_INVALIDDATA
        error.Unsupported => -38, // AVERROR(ENOSYS)
        error.NextSync => -0x1030c0a,
        error.NextBsid => -0x2030c0a,
        error.NextSampleRate => -0x3030c0a,
        error.NextFrameSize => -0x4030c0a,
        error.NextFrameType => -0x5030c0a,
        error.NextChannelMap => -0x7030c0a,
    };
}

/// Where an output "pointer" (`output[]`, `outptr[]`) points: a channel's
/// last block (`s->output`) or a place in the frame's buffer.
const Ptr = struct { frame: bool, ch: u8, off: u16 };

/// The flushable part of `AC3DecodeContext` that AC-3 uses, zeroed at the
/// start (FFmpeg's zeroed private data).
const State = struct {
    frame_type: u8 = 0,
    substreamid: i32 = 0,
    superframe_size: u32 = 0,
    frame_size: u32 = 0,
    sample_rate: u32 = 0,
    bit_rate: u32 = 0,
    num_blocks: u32 = 0,
    bitstream_id: u8 = 0,
    bitstream_mode: u8 = 0,
    channel_mode: u8 = 0,
    lfe_on: u8 = 0,
    center_mix_level: i32 = 0,
    surround_mix_level: i32 = 0,
    dolby_surround_mode: i32 = 0,
    snr_offset_strategy: u8 = 0,
    block_switch_syntax: bool = false,
    dither_flag_syntax: bool = false,
    bit_allocation_syntax: bool = false,
    fast_gain_syntax: bool = false,
    dba_syntax: bool = false,
    skip_syntax: bool = false,

    cpl_in_use: [max_blocks]bool = @splat(false),
    channel_in_cpl: [max_channels]bool = @splat(false),
    phase_flags_in_use: bool = false,
    phase_flags: [max_cpl_bands]bool = @splat(false),
    num_cpl_bands: usize = 0,
    cpl_band_struct: [max_cpl_bands]u8 = @splat(0),
    cpl_band_sizes: [max_cpl_bands]u8 = @splat(0),
    first_cpl_coords: [max_channels]bool = @splat(false),
    cpl_coords: [max_channels][max_cpl_bands]i32 = @splat(@splat(0)),

    fbw_channels: u8 = 0,
    channels: u8 = 0,
    lfe_ch: u8 = 0,
    /// Starts set: FFmpeg's init sets `downmixed` after the zeroed
    /// context, and a flush (not modeled) would clear it.
    downmixed: bool = true,
    output_mode: u8 = 0,
    out_channels: u8 = 0,

    dynamic_range: [2]f32 = .{ 0, 0 },
    start_freq: [max_channels]usize = @splat(0),
    end_freq: [max_channels]usize = @splat(0),
    num_rematrixing_bands: usize = 0,
    rematrixing_flags: [4]bool = @splat(false),
    num_exp_groups: [max_channels]usize = @splat(0),
    dexps: [max_channels][max_coefs]i8 = @splat(@splat(0)),
    exp_strategy: [max_blocks][max_channels]u8 = @splat(@splat(0)),
    bit_alloc_params: BitAllocParams = .{},
    first_cpl_leak: bool = false,
    snr_offset: [max_channels]i32 = @splat(0),
    fast_gain: [max_channels]i32 = @splat(0),
    bap: [max_channels][max_coefs]u8 = @splat(@splat(0)),
    psd: [max_channels][max_coefs]i16 = @splat(@splat(0)),
    band_psd: [max_channels][critical_bands]i16 = @splat(@splat(0)),
    mask: [max_channels][critical_bands]i16 = @splat(@splat(0)),
    dba_mode: [max_channels]i32 = @splat(0),
    dba_nsegs: [max_channels]i32 = @splat(0),
    dba_offsets: [max_channels][8]u8 = @splat(@splat(0)),
    dba_lengths: [max_channels][8]u8 = @splat(@splat(0)),
    dba_values: [max_channels][8]u8 = @splat(@splat(0)),
    dither_flag: [max_channels]bool = @splat(false),
    block_switch: [max_channels]bool = @splat(false),

    coeffs: [max_channels][max_coefs]f32 = @splat(@splat(0)),
    transform_coeffs: [max_channels][max_coefs]f32 = @splat(@splat(0)),
    delay: [max_channels][block_size]f32 = @splat(@splat(0)),
    tmp_output: [block_size]f32 = @splat(0),
    /// `s->output`: each output channel's last block, for concealment.
    output: [max_channels][block_size]f32 = @splat(@splat(0)),
    /// `s->output_buffer`: the frame's samples, by output channel.
    output_buffer: [max_channels][block_size * max_blocks]f32 = @splat(@splat(0)),
    outptr: [max_channels]Ptr = undefined,
};

/// What a call gives: the bytes consumed and, when it made one, a frame.
pub const Decoded = struct {
    consumed: usize,
    frame: ?Frame,
};

/// A decoded frame: planar float samples, valid until the next call.
pub const Frame = struct {
    planes: [max_channels][]const f32,
    channels: u8,
    /// The output's channel mask (ff_ac3_channel_layout_tab, LFE added).
    channel_layout: u64,
    samples: u32,
    sample_rate: u32,
    /// `decode_error_flags`: the frame repeats concealed blocks.
    concealed: bool,
    /// The AVDownmixInfo side data, for a stream coded with more than two
    /// channels: the header's center and surround mix levels (Lo/Ro, as
    /// AC-3's preferred downmix is never indicated); its LFE level is 0.
    downmix: ?Downmix,
};

pub const Downmix = struct { center_mix_level: f64, surround_mix_level: f64 };

/// `ff_ac3_gain_levels`, a float table.
const gain_levels = [9]f32{
    std.math.sqrt2,     1.1892071150027209, 1.0, 0.8408964152537145, std.math.sqrt1_2,
    0.5946035575013605, 0.5,                0.0, 0.3535533905932738,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    mdct128: tx.Mdct,
    mdct256: tx.Mdct,
    dith_state: Lfg,
    /// `avctx->sample_rate`: the stream's (the parser's), then each good
    /// frame's.
    sample_rate: u32,
    /// `avctx->bit_rate` as each good frame sets it (`bit_rate` plus a
    /// dependent frame's, which AC-3 has none of); null before one.
    bit_rate: ?u32 = null,
    s: *State,
    /// `input_buffer`, kept across calls as FFmpeg's is (a byte-swapped
    /// frame of odd length leaves the last byte from before).
    input: *[frame_buffer_size + 64]u8,

    /// ac3_decode_init for a stream the demuxer gave `sample_rate` (0 when
    /// none).
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32) error{OutOfMemory}!Decoder {
        var m128 = tx.Mdct.init(gpa, 128, true, 1.0) catch return error.OutOfMemory;
        errdefer m128.deinit();
        var m256 = tx.Mdct.init(gpa, 256, true, 1.0) catch return error.OutOfMemory;
        errdefer m256.deinit();
        const s = try gpa.create(State);
        errdefer gpa.destroy(s);
        s.* = .{};
        const input = try gpa.create([frame_buffer_size + 64]u8);
        @memset(input, 0);
        return .{ .gpa = gpa, .mdct128 = m128, .mdct256 = m256, .dith_state = .init(0), .sample_rate = sample_rate, .s = s, .input = input };
    }

    pub fn deinit(d: *Decoder) void {
        d.mdct128.deinit();
        d.mdct256.deinit();
        d.gpa.destroy(d.s);
        d.gpa.destroy(d.input);
        d.* = undefined;
    }

    fn slice(d: *Decoder, p: Ptr) []f32 {
        return if (p.frame) d.s.output_buffer[p.ch][p.off..] else d.s.output[p.ch][p.off..];
    }

    /// parse_frame_header; null on success.
    fn parseFrameHeader(d: *Decoder, r: *bits.BitReader) ?anyerror {
        const s = d.s;
        const hdr = ac3.parseHeader(r) catch |err| return err;
        s.bit_alloc_params.sr_code = hdr.sr_code;
        s.bitstream_id = hdr.bitstream_id;
        s.bitstream_mode = hdr.bitstream_mode;
        s.channel_mode = hdr.channel_mode;
        s.lfe_on = hdr.lfe_on;
        s.bit_alloc_params.sr_shift = hdr.sr_shift;
        s.sample_rate = hdr.sample_rate;
        s.bit_rate = hdr.bit_rate;
        s.channels = hdr.channels;
        s.fbw_channels = s.channels - s.lfe_on;
        s.lfe_ch = s.fbw_channels + 1;
        s.frame_size = hdr.frame_size;
        s.superframe_size += hdr.frame_size;
        if (hdr.bitstream_id <= 10) {
            s.center_mix_level = hdr.center_mix_level;
            s.surround_mix_level = hdr.surround_mix_level;
        }
        s.num_blocks = @intCast(hdr.num_blocks);
        s.frame_type = hdr.frame_type;
        s.substreamid = hdr.substreamid;
        s.dolby_surround_mode = hdr.dolby_surround_mode;
        if (s.lfe_on != 0) {
            s.start_freq[s.lfe_ch] = 0;
            s.end_freq[s.lfe_ch] = 7;
            s.num_exp_groups[s.lfe_ch] = 2;
            s.channel_in_cpl[s.lfe_ch] = false;
        }
        if (s.bitstream_id <= 10) {
            s.snr_offset_strategy = 2;
            s.block_switch_syntax = true;
            s.dither_flag_syntax = true;
            s.bit_allocation_syntax = true;
            s.fast_gain_syntax = false;
            s.first_cpl_leak = false;
            s.dba_syntax = true;
            s.skip_syntax = true;
            // The dialog normalization and heavy compression values only
            // serve the target_level and heavy_compr options, off.
            return null;
        }
        return error.Unsupported;
    }

    /// decode_exponents; false on an out-of-range group or exponent.
    fn decodeExponents(r: *bits.BitReader, exp_strategy: u8, ngrps: usize, absexp: u8, dexps: []i8) bool {
        var dexp: [256]u8 = undefined;
        const group_size: usize = @as(usize, exp_strategy) + @intFromBool(exp_strategy == exp_d45);
        var i: usize = 0;
        for (0..ngrps) |_| {
            const expacc = r.bits(7);
            if (expacc >= 125) return false;
            dexp[i] = ungroup_3_in_7[expacc][0];
            dexp[i + 1] = ungroup_3_in_7[expacc][1];
            dexp[i + 2] = ungroup_3_in_7[expacc][2];
            i += 3;
        }
        var prevexp: i32 = absexp;
        var j: usize = 0;
        for (dexp[0 .. ngrps * 3]) |dx| {
            prevexp += @as(i32, dx) - 2;
            if (prevexp < 0 or prevexp > 24) return false;
            const v: i8 = @intCast(prevexp);
            @memset(dexps[j..][0..group_size], v);
            j += group_size;
        }
        return true;
    }

    fn calcTransformCoeffsCpl(d: *Decoder) void {
        const s = d.s;
        var bin = s.start_freq[cpl_ch];
        for (0..s.num_cpl_bands) |band| {
            const band_start = bin;
            const band_end = bin + s.cpl_band_sizes[band];
            for (1..@as(usize, s.fbw_channels) + 1) |ch| {
                if (!s.channel_in_cpl[ch]) continue;
                // The int coordinate, exactly a float (few significant bits).
                const cpl_coord = @as(f32, @floatFromInt(s.cpl_coords[ch][band])) * (1.0 / @as(f32, 1 << 23));
                bin = band_start;
                while (bin < band_end) : (bin += 1) s.coeffs[ch][bin] = s.coeffs[cpl_ch][bin] * cpl_coord;
                if (ch == 2 and s.phase_flags[band]) {
                    bin = band_start;
                    while (bin < band_end) : (bin += 1) s.coeffs[2][bin] = -s.coeffs[2][bin];
                }
            }
            bin = band_end;
        }
    }

    const MantGroups = struct {
        b1_mant: [2]i32 = .{ 0, 0 },
        b2_mant: [2]i32 = .{ 0, 0 },
        b4_mant: i32 = 0,
        b1: u8 = 0,
        b2: u8 = 0,
        b4: u8 = 0,
    };

    /// ac3_decode_transform_coeffs_ch.
    fn decodeTransformCoeffsCh(d: *Decoder, r: *bits.BitReader, ch_index: usize, m: *MantGroups) void {
        const s = d.s;
        const dither = ch_index == cpl_ch or s.dither_flag[ch_index];
        for (s.start_freq[ch_index]..s.end_freq[ch_index]) |freq| {
            const bap = s.bap[ch_index][freq];
            var mantissa: i32 = undefined;
            switch (bap) {
                0 => {
                    // Random noise of about -0.707 to 0.707.
                    mantissa = if (dither) @as(i32, @intCast((((d.dith_state.get() >> 8) * 181) >> 8))) - 5931008 else 0;
                },
                1 => if (m.b1 != 0) {
                    m.b1 -= 1;
                    mantissa = m.b1_mant[m.b1];
                } else {
                    const code = r.bits(5);
                    mantissa = bap1_mantissas[code][0];
                    m.b1_mant[1] = bap1_mantissas[code][1];
                    m.b1_mant[0] = bap1_mantissas[code][2];
                    m.b1 = 2;
                },
                2 => if (m.b2 != 0) {
                    m.b2 -= 1;
                    mantissa = m.b2_mant[m.b2];
                } else {
                    const code = r.bits(7);
                    mantissa = bap2_mantissas[code][0];
                    m.b2_mant[1] = bap2_mantissas[code][1];
                    m.b2_mant[0] = bap2_mantissas[code][2];
                    m.b2 = 2;
                },
                3 => mantissa = bap3_mantissas[r.bits(3)],
                4 => if (m.b4 != 0) {
                    m.b4 = 0;
                    mantissa = m.b4_mant;
                } else {
                    const code = r.bits(7);
                    mantissa = bap4_mantissas[code][0];
                    m.b4_mant = bap4_mantissas[code][1];
                    m.b4 = 1;
                },
                5 => mantissa = bap5_mantissas[r.bits(4)],
                else => {
                    // 6 to 15 (AC-3's bap table stops at 15): the mantissa
                    // shifted up and sign-extended, `(unsigned)` so that the
                    // shift cannot overflow.
                    const q: u5 = @intCast(quantization_tab[bap]);
                    const v: u32 = @bitCast(r.signed(q));
                    mantissa = @bitCast(v << @intCast(24 - @as(u6, q)));
                },
            }
            // An int of at most 2^24 in magnitude: exactly a float.
            s.coeffs[ch_index][freq] = @as(f32, @floatFromInt(mantissa)) * scale_factors[@intCast(s.dexps[ch_index][freq])];
        }
    }

    fn removeDithering(s: *State) void {
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            if (!s.dither_flag[ch] and s.channel_in_cpl[ch]) {
                for (s.start_freq[cpl_ch]..s.end_freq[cpl_ch]) |i| {
                    if (s.bap[cpl_ch][i] == 0) s.coeffs[ch][i] = 0;
                }
            }
        }
    }

    fn decodeTransformCoeffs(d: *Decoder, r: *bits.BitReader) void {
        const s = d.s;
        var got_cplchan = false;
        var m: MantGroups = .{};
        for (1..@as(usize, s.channels) + 1) |ch| {
            d.decodeTransformCoeffsCh(r, ch, &m);
            var end: usize = undefined;
            if (s.channel_in_cpl[ch]) {
                if (!got_cplchan) {
                    d.decodeTransformCoeffsCh(r, cpl_ch, &m);
                    d.calcTransformCoeffsCpl();
                    got_cplchan = true;
                }
                end = s.end_freq[cpl_ch];
            } else end = s.end_freq[ch];
            // `do ... while (++end < 256)`: at least one.
            while (true) {
                s.coeffs[ch][end] = 0;
                end += 1;
                if (end >= 256) break;
            }
        }
        removeDithering(s);
    }

    fn doRematrixing(s: *State) void {
        const end = @min(s.end_freq[1], s.end_freq[2]);
        for (0..s.num_rematrixing_bands) |bnd| {
            if (!s.rematrixing_flags[bnd]) continue;
            const bndend = @min(end, rematrix_band_tab[bnd + 1]);
            var i: usize = rematrix_band_tab[bnd];
            while (i < bndend) : (i += 1) {
                const tmp0 = s.coeffs[1][i];
                s.coeffs[1][i] += s.coeffs[2][i];
                s.coeffs[2][i] = tmp0 - s.coeffs[2][i];
            }
        }
    }

    fn doImdct(d: *Decoder, channels: usize) void {
        const s = d.s;
        for (1..channels + 1) |ch| {
            const out = d.slice(s.outptr[ch - 1]);
            if (s.block_switch[ch]) {
                var x: [128]f32 = undefined;
                for (&x, 0..) |*v, i| v.* = s.transform_coeffs[ch][2 * i];
                // FFmpeg's x is tmp_output + 128, which the first transform
                // leaves alone.
                @memcpy(s.tmp_output[128..], &x);
                d.mdct128.run(s.tmp_output[0..128], s.tmp_output[128..256]);
                float_dsp.fmulWindow(out, &s.delay[ch - 1], &s.tmp_output, &window, 128);
                for (&x, 0..) |*v, i| v.* = s.transform_coeffs[ch][2 * i + 1];
                @memcpy(s.tmp_output[128..], &x);
                d.mdct128.run(s.delay[ch - 1][0..128], s.tmp_output[128..256]);
            } else {
                d.mdct256.run(&s.tmp_output, &s.transform_coeffs[ch]);
                float_dsp.fmulWindow(out, &s.delay[ch - 1], &s.tmp_output, &window, 128);
                @memcpy(s.delay[ch - 1][0..128], s.tmp_output[128..256]);
            }
        }
    }

    /// ac3_upmix_delay, which FFmpeg runs on the first block whose channels
    /// differ in block switching, its delay never having been downmixed.
    fn upmixDelay(s: *State) void {
        switch (s.channel_mode) {
            ac3.ChannelMode.dual_mono, ac3.ChannelMode.stereo => s.delay[1] = s.delay[0],
            ac3.ChannelMode.f2r2, ac3.ChannelMode.f2r1 => {
                if (s.channel_mode == ac3.ChannelMode.f2r2) s.delay[3] = @splat(0);
                s.delay[2] = @splat(0);
            },
            ac3.ChannelMode.f3r2, ac3.ChannelMode.f3r1, ac3.ChannelMode.f3 => {
                if (s.channel_mode == ac3.ChannelMode.f3r2) s.delay[4] = @splat(0);
                if (s.channel_mode != ac3.ChannelMode.f3) s.delay[3] = @splat(0);
                s.delay[2] = s.delay[1];
                s.delay[1] = @splat(0);
            },
            else => {},
        }
    }

    /// decode_band_structure for AC-3's coupling (not E-AC-3, no enhanced
    /// coupling).
    fn decodeBandStructure(s: *State, r: *bits.BitReader, blk: usize, start_subband: usize, end_subband: usize) void {
        const n_subbands = end_subband - start_subband;
        if (blk == 0) s.cpl_band_struct = default_cpl_band_struct;
        const band_struct = s.cpl_band_struct[start_subband + 1 ..];
        for (0..n_subbands - 1) |subbnd| band_struct[subbnd] = r.bit();
        var bnd_sz: [22]u8 = undefined;
        var n_bands = n_subbands;
        bnd_sz[0] = 12;
        var bnd: usize = 0;
        for (1..n_subbands) |subbnd| {
            if (band_struct[subbnd - 1] != 0) {
                n_bands -= 1;
                bnd_sz[bnd] += 12;
            } else {
                bnd += 1;
                bnd_sz[bnd] = 12;
            }
        }
        s.num_cpl_bands = n_bands;
        @memcpy(s.cpl_band_sizes[0..n_bands], bnd_sz[0..n_bands]);
    }

    fn couplingStrategy(s: *State, r: *bits.BitReader, blk: usize, stages: *[max_channels]u8) bool {
        @memset(stages, 3);
        s.cpl_in_use[blk] = r.bit() != 0;
        if (s.cpl_in_use[blk]) {
            if (s.channel_mode < ac3.ChannelMode.stereo) return false; // "coupling not allowed in mono or dual-mono"
            for (1..@as(usize, s.fbw_channels) + 1) |ch| s.channel_in_cpl[ch] = r.bit() != 0;
            if (s.channel_mode == ac3.ChannelMode.stereo) s.phase_flags_in_use = r.bit() != 0;
            const cpl_start_subband: usize = r.bits(4);
            const cpl_end_subband: usize = r.bits(4) + 3;
            if (cpl_start_subband >= cpl_end_subband) return false; // "invalid coupling range"
            s.start_freq[cpl_ch] = cpl_start_subband * 12 + 37;
            s.end_freq[cpl_ch] = cpl_end_subband * 12 + 37;
            decodeBandStructure(s, r, blk, cpl_start_subband, cpl_end_subband);
        } else {
            for (1..@as(usize, s.fbw_channels) + 1) |ch| {
                s.channel_in_cpl[ch] = false;
                s.first_cpl_coords[ch] = true;
            }
            s.first_cpl_leak = false;
            s.phase_flags_in_use = false;
        }
        return true;
    }

    fn couplingCoordinates(s: *State, r: *bits.BitReader, blk: usize) bool {
        var cpl_coords_exist = false;
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            if (s.channel_in_cpl[ch]) {
                if (r.bit() != 0) {
                    s.first_cpl_coords[ch] = false;
                    cpl_coords_exist = true;
                    const master: u32 = 3 * r.bits(2);
                    for (0..s.num_cpl_bands) |bnd| {
                        const cexp = r.bits(4);
                        const cmant: i32 = @intCast(r.bits(4));
                        var c: i32 = if (cexp == 15) cmant << 22 else (cmant + 16) << 21;
                        c >>= @intCast(cexp + master);
                        s.cpl_coords[ch][bnd] = c;
                    }
                } else if (blk == 0) return false; // "new coupling coordinates must be present in block 0"
            } else s.first_cpl_coords[ch] = true;
        }
        if (s.channel_mode == ac3.ChannelMode.stereo and cpl_coords_exist) {
            for (0..s.num_cpl_bands) |bnd| s.phase_flags[bnd] = if (s.phase_flags_in_use) r.bit() != 0 else false;
        }
        return true;
    }

    /// decode_audio_block for AC-3; false where FFmpeg returns an error.
    fn decodeAudioBlock(d: *Decoder, r: *bits.BitReader, blk: usize) bool {
        const s = d.s;
        const fbw: usize = s.fbw_channels;
        const nch: usize = s.channels;
        var stages: [max_channels]u8 = @splat(0);
        // Block switch and dither flags.
        var different_transforms = false;
        for (1..fbw + 1) |ch| {
            s.block_switch[ch] = r.bit() != 0;
            if (ch > 1 and s.block_switch[ch] != s.block_switch[1]) different_transforms = true;
        }
        for (1..fbw + 1) |ch| s.dither_flag[ch] = r.bit() != 0;
        // Dynamic range: `powf(range, drc_scale)` with the scale 1 is the
        // range itself.
        var i: usize = @intFromBool(s.channel_mode == 0);
        while (true) {
            if (r.bit() != 0) {
                s.dynamic_range[i] = dynamic_range_tab[r.bits(8)];
            } else if (blk == 0) s.dynamic_range[i] = 1.0;
            if (i == 0) break;
            i -= 1;
        }
        // No spectral extension in AC-3.
        // Coupling strategy.
        if (r.bit() != 0) {
            if (!couplingStrategy(s, r, blk, &stages)) return false;
        } else {
            if (blk == 0) return false; // "new coupling strategy must be present in block 0"
            s.cpl_in_use[blk] = s.cpl_in_use[blk - 1];
        }
        const cpl_in_use = s.cpl_in_use[blk];
        if (cpl_in_use and !couplingCoordinates(s, r, blk)) return false;
        // Stereo rematrixing.
        if (s.channel_mode == ac3.ChannelMode.stereo) {
            if (r.bit() != 0) {
                s.num_rematrixing_bands = 4;
                if (cpl_in_use and s.start_freq[cpl_ch] <= 61) s.num_rematrixing_bands -= 1 + @as(usize, @intFromBool(s.start_freq[cpl_ch] == 37));
                for (0..s.num_rematrixing_bands) |bnd| s.rematrixing_flags[bnd] = r.bit() != 0;
            } else if (blk == 0) {
                // "new rematrixing strategy not present in block 0".
                s.num_rematrixing_bands = 0;
            }
        }
        const first_ch: usize = @intFromBool(!cpl_in_use);
        // Exponent strategies.
        for (first_ch..nch + 1) |ch| {
            s.exp_strategy[blk][ch] = @intCast(r.bits(if (ch == s.lfe_ch) 1 else 2));
            if (s.exp_strategy[blk][ch] != exp_reuse) stages[ch] = 3;
        }
        // Channel bandwidth.
        for (1..fbw + 1) |ch| {
            s.start_freq[ch] = 0;
            if (s.exp_strategy[blk][ch] != exp_reuse) {
                const prev = s.end_freq[ch];
                if (s.channel_in_cpl[ch]) {
                    s.end_freq[ch] = s.start_freq[cpl_ch];
                } else {
                    const bandwidth_code = r.bits(6);
                    if (bandwidth_code > 60) return false; // "bandwidth code > 60"
                    s.end_freq[ch] = bandwidth_code * 3 + 73;
                }
                const group_size = @as(usize, 3) << @intCast(s.exp_strategy[blk][ch] - 1);
                s.num_exp_groups[ch] = (s.end_freq[ch] + group_size - 4) / group_size;
                if (blk > 0 and s.end_freq[ch] != prev) @memset(&stages, 3);
            }
        }
        if (cpl_in_use and s.exp_strategy[blk][cpl_ch] != exp_reuse) {
            s.num_exp_groups[cpl_ch] = (s.end_freq[cpl_ch] - s.start_freq[cpl_ch]) / (@as(usize, 3) << @intCast(s.exp_strategy[blk][cpl_ch] - 1));
        }
        // Exponents.
        for (first_ch..nch + 1) |ch| {
            if (s.exp_strategy[blk][ch] == exp_reuse) continue;
            const absexp: u8 = @intCast(r.bits(4) << @intFromBool(ch == 0));
            s.dexps[ch][0] = @intCast(absexp);
            const at = s.start_freq[ch] + @intFromBool(ch != 0);
            if (!decodeExponents(r, s.exp_strategy[blk][ch], s.num_exp_groups[ch], absexp, s.dexps[ch][at..])) return false;
            if (ch != cpl_ch and ch != s.lfe_ch) r.skip(2); // gainrng
        }
        // Bit allocation information.
        if (r.bit() != 0) {
            const ba = &s.bit_alloc_params;
            ba.slow_decay = slow_decay_tab[r.bits(2)] >> @intCast(ba.sr_shift);
            ba.fast_decay = fast_decay_tab[r.bits(2)] >> @intCast(ba.sr_shift);
            ba.slow_gain = slow_gain_tab[r.bits(2)];
            ba.db_per_bit = db_per_bit_tab[r.bits(2)];
            ba.floor = floor_tab[r.bits(3)];
            for (first_ch..nch + 1) |ch| stages[ch] = @max(stages[ch], 2);
        } else if (blk == 0) return false; // "new bit allocation info must be present in block 0"
        // SNR offsets and fast gains.
        if (r.bit() != 0) {
            var snr: i32 = 0;
            const csnr: i32 = (@as(i32, @intCast(r.bits(6))) - 15) << 4;
            for (first_ch..nch + 1) |ch| {
                // snr_offset_strategy 2: an offset for every channel.
                snr = (csnr + @as(i32, @intCast(r.bits(4)))) << 2;
                if (blk != 0 and s.snr_offset[ch] != snr) stages[ch] = @max(stages[ch], 1);
                s.snr_offset[ch] = snr;
                const prev = s.fast_gain[ch];
                s.fast_gain[ch] = fast_gain_tab[r.bits(3)];
                if (blk != 0 and prev != s.fast_gain[ch]) stages[ch] = @max(stages[ch], 2);
            }
        } else if (blk == 0) return false; // "new snr offsets must be present in block 0"
        // AC-3's frame type is AC3_CONVERT: no converter SNR offset.
        // Coupling leak.
        if (cpl_in_use) {
            if (s.first_cpl_leak or r.bit() != 0) {
                const fl: i32 = @intCast(r.bits(3));
                const sl: i32 = @intCast(r.bits(3));
                if (blk != 0 and (fl != s.bit_alloc_params.cpl_fast_leak or sl != s.bit_alloc_params.cpl_slow_leak)) stages[cpl_ch] = @max(stages[cpl_ch], 2);
                s.bit_alloc_params.cpl_fast_leak = fl;
                s.bit_alloc_params.cpl_slow_leak = sl;
            } else if (blk == 0) return false; // "new coupling leak info must be present in block 0"
            s.first_cpl_leak = false;
        }
        // Delta bit allocation.
        if (r.bit() != 0) {
            for (first_ch..fbw + 1) |ch| {
                s.dba_mode[ch] = @intCast(r.bits(2));
                if (s.dba_mode[ch] == dba_reserved) return false; // "delta bit allocation strategy reserved"
                stages[ch] = @max(stages[ch], 2);
            }
            for (first_ch..fbw + 1) |ch| {
                if (s.dba_mode[ch] != dba_new) continue;
                s.dba_nsegs[ch] = @intCast(r.bits(3) + 1);
                for (0..@intCast(s.dba_nsegs[ch])) |seg| {
                    s.dba_offsets[ch][seg] = @intCast(r.bits(5));
                    s.dba_lengths[ch][seg] = @intCast(r.bits(4));
                    s.dba_values[ch][seg] = @intCast(r.bits(3));
                }
                stages[ch] = @max(stages[ch], 2);
            }
        } else if (blk == 0) {
            for (0..nch + 1) |ch| s.dba_mode[ch] = dba_none;
        }
        // Bit allocation.
        for (first_ch..nch + 1) |ch| {
            if (stages[ch] > 2) calcPsd(&s.dexps[ch], s.start_freq[ch], s.end_freq[ch], &s.psd[ch], &s.band_psd[ch]);
            if (stages[ch] > 1) {
                const dba: Dba = .{ .mode = s.dba_mode[ch], .nsegs = s.dba_nsegs[ch], .offsets = &s.dba_offsets[ch], .lengths = &s.dba_lengths[ch], .values = &s.dba_values[ch] };
                if (!calcMask(&s.bit_alloc_params, &s.band_psd[ch], s.start_freq[ch], s.end_freq[ch], s.fast_gain[ch], ch == s.lfe_ch, dba, &s.mask[ch])) return false; // "error in bit allocation"
            }
            if (stages[ch] > 0) calcBap(&s.mask[ch], &s.psd[ch], s.start_freq[ch], s.end_freq[ch], s.snr_offset[ch], s.bit_alloc_params.floor, &s.bap[ch]);
        }
        // Unused dummy data.
        if (r.bit() != 0) {
            const skipl: i64 = r.bits(9);
            r.skipLong(8 * skipl);
        }
        d.decodeTransformCoeffs(r);
        if (s.channel_mode == ac3.ChannelMode.stereo) doRematrixing(s);
        // Headroom and dynamic range.
        for (1..nch + 1) |ch| {
            var audio_channel: usize = 0;
            if (s.channel_mode == ac3.ChannelMode.dual_mono and ch <= 2) audio_channel = 2 - ch;
            var gain = s.dynamic_range[audio_channel];
            gain *= 1.0 / 4194304.0;
            float_dsp.fmulScalar(&s.transform_coeffs[ch], &s.coeffs[ch], gain);
        }
        // No downmix (the decoder's default): every channel through the
        // IMDCT, the delay upmixed once where block switching differs.
        if (different_transforms and s.downmixed) {
            s.downmixed = false;
            upmixDelay(s);
        }
        d.doImdct(nch);
        return true;
    }

    /// ac3_decode_frame: one call on `packet` (what remains of it), as
    /// decode.c calls the decoder until the packet is consumed.
    pub fn decode(d: *Decoder, packet: []const u8) Error!Decoded {
        const s = d.s;
        s.superframe_size = 0;
        const full_buf_size = packet.len;
        const sync_at = ac3.findSyncword(packet) orelse return error.InvalidData;
        // A sync word past the first 11 bytes: those bytes consumed, no
        // frame.
        if (sync_at > 10) return .{ .consumed = sync_at, .frame = null };
        const buf = packet[sync_at..];
        const buf_size = buf.len;
        const copy = @min(buf_size, frame_buffer_size);
        if (buf_size >= 2 and buf[0] == 0x77 and buf[1] == 0x0B) {
            // Byte-swapped AC-3: whole 16-bit words swapped in.
            var k: usize = 0;
            while (k + 1 < copy) : (k += 2) {
                d.input[k] = buf[k + 1];
                d.input[k + 1] = buf[k];
            }
        } else @memcpy(d.input[0..copy], buf[0..copy]);
        // init_get_bits8 over buf_size bytes of the input buffer; past them
        // the reader sees what the buffer holds.
        var r = bits.BitReader.initIn(d.input, @min(buf_size, d.input.len)) catch return error.InvalidData;
        var err = false;
        if (d.parseFrameHeader(&r)) |e| switch (e) {
            error.Sync => return error.InvalidData, // "frame sync error"
            error.Bsid, error.SampleRate, error.FrameSize, error.Crc => err = true,
            error.FrameType => {
                // A substream: the previous frame's id, as FFmpeg reads it.
                if (s.substreamid != 0) return .{ .consumed = buf_size, .frame = null };
                err = true; // "invalid frame type"
            },
            error.ChannelMap => return error.InvalidData,
            error.Unsupported => return error.Unsupported,
            else => return error.InvalidData,
        } else if (s.frame_size > buf_size) err = true; // "incomplete frame"
        // A dependent frame without an independent one is E-AC-3's, which
        // never parses here.
        if (!err or (s.channels != 0 and s.out_channels != s.channels)) {
            s.out_channels = s.channels;
            s.output_mode = s.channel_mode;
            if (s.lfe_on != 0) s.output_mode |= output_lfeon;
        } else if (s.channels == 0) return error.InvalidData; // "unable to determine channel mode"
        var mask = ac3.channel_layout_tab[s.output_mode & ~@as(u8, output_lfeon)];
        if (s.output_mode & output_lfeon != 0) mask |= ac3.ch.low_frequency;
        const channel_map = dec_channel_map[s.output_mode & ~@as(u8, output_lfeon)][s.lfe_on];
        var output: [max_channels]Ptr = undefined;
        for (0..max_channels) |ch| {
            output[ch] = .{ .frame = false, .ch = @intCast(ch), .off = 0 };
            s.outptr[ch] = output[ch];
        }
        for (0..s.channels) |ch| {
            if (ch < s.out_channels) s.outptr[channel_map[ch]] = .{ .frame = true, .ch = @intCast(ch), .off = 0 };
        }
        const out_channels: usize = s.out_channels;
        for (0..s.num_blocks) |blk| {
            if (!err and !d.decodeAudioBlock(&r, blk)) err = true; // "error decoding the audio block"
            if (err) {
                for (0..out_channels) |ch| {
                    const src = d.slice(output[ch])[0..block_size];
                    var tmp: [block_size]f32 = undefined;
                    @memcpy(&tmp, src);
                    @memcpy(s.output_buffer[ch][block_size * blk ..][0..block_size], &tmp);
                }
            }
            for (0..out_channels) |ch| output[ch] = s.outptr[channel_map[ch]];
            for (0..out_channels) |ch| {
                if (ch == 0 or channel_map[ch] != 0) s.outptr[channel_map[ch]].off += block_size;
            }
        }
        // The last block, kept for concealment in the next frame.
        for (0..out_channels) |ch| {
            var tmp: [block_size]f32 = undefined;
            @memcpy(&tmp, d.slice(output[ch])[0..block_size]);
            s.output[ch] = tmp;
        }
        // A dependent frame after this one: more than 16 bytes left.
        var skip: usize = 0;
        if (buf_size > s.frame_size) {
            if (buf_size - s.frame_size <= 16) {
                skip = buf_size - s.frame_size;
            } else {
                // init_get_bits8 at buf + frame_size: a header that does not
                // parse fails the call, its frame lost.
                var rest = bits.BitReader.initIn(d.input[s.frame_size..], @min(buf_size, d.input.len) - s.frame_size) catch return error.InvalidData;
                const hdr = ac3.parseHeader(&rest) catch |e| return switch (e) {
                    error.Sync => error.NextSync,
                    error.Bsid => error.NextBsid,
                    error.SampleRate => error.NextSampleRate,
                    error.FrameSize => error.NextFrameSize,
                    error.FrameType => error.NextFrameType,
                    error.ChannelMap => error.NextChannelMap,
                    error.Crc => unreachable, // the header parser never names it
                };
                // Only an E-AC-3 dependent frame continues this one, which
                // the reference build cannot decode.
                if (hdr.frame_type == ac3.FrameType.dependent and hdr.num_blocks == s.num_blocks and s.sample_rate == hdr.sample_rate) {
                    return error.Unsupported;
                }
            }
        }
        if (!err) {
            d.sample_rate = s.sample_rate;
            d.bit_rate = s.bit_rate;
        }
        if (d.sample_rate == 0) return error.InvalidData; // "Could not determine the sample rate"
        const samples: u32 = s.num_blocks * block_size;
        var frame: Frame = .{
            .planes = undefined,
            .channels = s.out_channels,
            .channel_layout = mask,
            .samples = samples,
            .sample_rate = d.sample_rate,
            .concealed = err,
            .downmix = if (s.channel_mode > ac3.ChannelMode.stereo and (s.output_mode & ~@as(u8, output_lfeon)) > ac3.ChannelMode.stereo) .{
                .center_mix_level = gain_levels[@intCast(s.center_mix_level)],
                .surround_mix_level = gain_levels[@intCast(s.surround_mix_level)],
            } else null,
        };
        for (0..out_channels) |ch| frame.planes[ch] = s.output_buffer[ch][0..samples];
        const total = (if (s.superframe_size == 0) s.frame_size else s.superframe_size) + skip;
        return .{ .consumed = @min(full_buf_size, total), .frame = frame };
    }
};

const testing = std.testing;

test "the mantissa and band tables match FFmpeg's generated values" {
    try testing.expectEqual(-5592405, bap1_mantissas[0][0]);
    try testing.expectEqual(0, bap1_mantissas[13][1]);
    try testing.expectEqual(49, bin_to_band_tab[252]);
    try testing.expectEqual(28, bin_to_band_tab[30]);
    try testing.expectEqual(1.0, dynamic_range_tab[0]);
    try testing.expectEqual(15.75, dynamic_range_tab[127]);
    try testing.expectEqual(0.0625, dynamic_range_tab[128]);
}

const hostile = @import("../testing/hostile.zig");

/// The fuzz entry's input: a packet, then the stream's rate code (0 to 3,
/// 3 for none), as a value. Every decode call ends in a frame, a frame-less
/// skip or an error, and consumes what FFmpeg's would.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [4096 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const rate_code = smith.valueRangeAtMost(u8, 0, 3);
    var d = try Decoder.init(testing.allocator, ac3.sample_rate_tab[rate_code]);
    defer d.deinit();
    // The packet twice, so that the second decode has state to conceal.
    for (0..2) |_| {
        var rest: []const u8 = input[0..len];
        while (rest.len > 0) {
            const got = d.decode(rest) catch break;
            try testing.expect(got.consumed > 0 and got.consumed <= rest.len);
            if (got.frame) |f| {
                try testing.expectEqual(@popCount(f.channel_layout), f.channels);
                try testing.expectEqual(d.s.num_blocks * block_size, f.samples);
            }
            rest = rest[got.consumed..];
        }
    }
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_ffmpeg_coupling.ac3")[0..512], &.{1}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_ffmpeg_51_48k.ac3")[0..1536], &.{0}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_ffmpeg_mono_32k.ac3")[0..256], &.{2}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_byteswapped.ac3")[0..768], &.{3}),
};

test "fuzz: the AC-3 decoder on arbitrary packets" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: the AC-3 decoder on mutated packets" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 64, 0x61633364);
}

fn decodeUnderFailures(gpa: std.mem.Allocator, packet: []const u8) !void {
    var d = try Decoder.init(gpa, 48000);
    defer d.deinit();
    _ = d.decode(packet) catch return error.TestUnexpectedResult;
}

test "the AC-3 decoder frees everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, @as([]const u8, @embedFile("../testing/fixtures/ac3/ac3_ffmpeg_stereo_48k.ac3")[0..768]), decodeUnderFailures);
}

test "malformed AC-3 packets: FFmpeg's errors and concealment" {
    var d = try Decoder.init(testing.allocator, 0);
    defer d.deinit();
    // No sync word.
    try testing.expectError(error.InvalidData, d.decode(&.{ 1, 2, 3, 4, 5, 6 }));
    // A sync word past the first 11 bytes: those bytes consumed, no frame.
    var late: [20]u8 = @splat(0);
    late[12] = 0x0B;
    late[13] = 0x77;
    const got = try d.decode(&late);
    try testing.expectEqual(12, got.consumed);
    try testing.expectEqual(null, got.frame);
    // A header with sample rate code 3, before any good frame: no channel
    // mode, INVALIDDATA.
    try testing.expectError(error.InvalidData, d.decode(&.{ 0x0B, 0x77, 0, 0, 0xC0, 0x40, 0x43, 0 }));
    // A cut first frame: concealed, silence, the frame's sizes.
    const frame = @embedFile("../testing/fixtures/ac3/ac3_ffmpeg_stereo_48k.ac3")[0..768];
    var e = try Decoder.init(testing.allocator, 48000);
    defer e.deinit();
    const cut = try e.decode(frame[0..300]);
    try testing.expect(cut.frame.?.concealed);
    try testing.expectEqual(300, cut.consumed);
    for (cut.frame.?.planes[0..2]) |p| for (p) |v| try testing.expectEqual(0, v);
}
