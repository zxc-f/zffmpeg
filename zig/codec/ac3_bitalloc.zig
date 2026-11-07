// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/ac3.c (ff_ac3_bit_alloc_calc_psd,
// ff_ac3_bit_alloc_calc_mask), ac3dsp.c (ac3_bit_alloc_calc_bap_c) and
// ac3tab.c at the pinned reference revision.
// Copyright (c) 2001-2003 Fabrice Bellard
// Copyright (c) 2006 Justin Ruggles
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! AC-3's bit allocation, shared by FFmpeg's decoder (ac3dec.zig, T32a)
//! and encoder (ac3enc.zig, T32c): the power spectral density, the
//! masking curve and the bit allocation pointers, with their tables.

const std = @import("std");

pub const max_coefs = 256;
pub const critical_bands = 50;
pub const dba_new = 1;

pub const bap_tab = [64]u8{
    0,  1,  1,  1,  1,  1,  2,  2,  3,  3,  3,  4,  4,  5,  5,  6,
    6,  6,  6,  7,  7,  7,  7,  8,  8,  8,  8,  9,  9,  9,  9,  10,
    10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14,
    14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15,
};

pub const slow_decay_tab = [4]i32{ 0x0f, 0x11, 0x13, 0x15 };
pub const fast_decay_tab = [4]i32{ 0x3f, 0x53, 0x67, 0x7b };
pub const slow_gain_tab = [4]i32{ 0x540, 0x4d8, 0x478, 0x410 };
pub const db_per_bit_tab = [4]i32{ 0x000, 0x700, 0x900, 0xb00 };
/// `ff_ac3_floor_tab` (int16_t: 0xf800 is -2048).
pub const floor_tab = [8]i32{ 0x2f0, 0x2b0, 0x270, 0x230, 0x1f0, 0x170, 0x0f0, -0x800 };
pub const fast_gain_tab = [8]i32{ 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380, 0x400 };

pub const rematrix_band_tab = [5]u8{ 13, 25, 37, 61, 253 };
pub const default_cpl_band_struct = [18]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1 };

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

pub const log_add_tab = [260]u8{
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

pub const hearing_threshold_tab = [critical_bands][3]i32{
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

pub const BitAllocParams = struct {
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

pub fn calcLowcomp1(a: i32, b0: i32, b1: i32, c: i32) i32 {
    if (b0 + 256 == b1) return c;
    if (b0 > b1) return @max(a - 64, 0);
    return a;
}

pub fn calcLowcomp(a: i32, b0: i32, b1: i32, bin: usize) i32 {
    if (bin < 7) return calcLowcomp1(a, b0, b1, 384);
    if (bin < 20) return calcLowcomp1(a, b0, b1, 320);
    return @max(a - 128, 0);
}

/// ff_ac3_bit_alloc_calc_psd. The int16_t stores keep the low bits (the
/// values stay well inside them for exponents 0 to 24).
pub fn calcPsd(exp: []const i8, start: usize, end: usize, psd: []i16, band_psd: []i16) void {
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

pub const Dba = struct { mode: i32, nsegs: i32, offsets: []const u8, lengths: []const u8, values: []const u8 };

/// ff_ac3_bit_alloc_calc_mask; false where FFmpeg returns an error.
pub fn calcMask(s: *const BitAllocParams, band_psd: []const i16, start: usize, end: usize, fast_gain: i32, is_lfe: bool, dba: Dba, mask: []i16) bool {
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
pub fn calcBap(mask: []const i16, psd: []const i16, start: usize, end: usize, snr_offset: i32, floor: i32, tab: *const [64]u8, bap: []u8) void {
    if (snr_offset == -960) {
        @memset(bap[0..max_coefs], 0);
        return;
    }
    var bin = start;
    while (bin < @min(end, 28)) : (bin += 1) {
        const m = (@max(@as(i32, mask[bin]) - snr_offset - floor, 0) & 0x1FE0) + floor;
        bap[bin] = tab[clipUintp2_6((@as(i32, psd[bin]) - m) >> 5)];
    }
    if (bin >= end) return;
    var band: usize = bin_to_band_tab[bin];
    while (true) {
        const m = (@max(@as(i32, mask[band]) - snr_offset - floor, 0) & 0x1FE0) + floor;
        band += 1;
        const band_end = @min(band_start_tab[band], end);
        while (bin < band_end) : (bin += 1) bap[bin] = tab[clipUintp2_6((@as(i32, psd[bin]) - m) >> 5)];
        if (!(end > band_end)) break;
    }
}

/// av_clip_uintp2(a, 6).
pub fn clipUintp2_6(a: i32) usize {
    return @intCast(std.math.clamp(a, 0, 63));
}
