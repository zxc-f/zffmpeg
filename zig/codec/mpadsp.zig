// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/mpegaudiodsp.c (mpadsp_init_tabs),
// mpegaudiodsp_template.c (mpa_synth_init, ff_mpa_synth_filter, imdct36,
// ff_imdct36_blocks), x86/mpegaudiodsp.c (apply_window_mp3, the inline SSE
// window the reference build runs), mpegaudiodsp_data.c (ff_mpa_enwindow)
// and dct32_template.c (dct32) at the pinned reference revision, for the
// float decoder (USE_FLOATS, DCT32_FLOAT).
// Copyright (c) 2001, 2002 Fabrice Bellard
// Copyright (c) 2011 Mans Rullgard
// Copyright (c) 2010 Vitor Sessak
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! The MPEG audio decoder's DSP (TODO.md T29b): the 36-point IMDCT of the
//! long blocks with its windows and overlap, and the 32-band polyphase
//! synthesis (a 32-point DCT, then the window). Each expression keeps
//! FFmpeg's operation order in single precision, as the reference build
//! (Clang, x86-64 without FMA) evaluates it, so every sample is bit-exact.
//!
//! The reference build compiles FFmpeg's C with `-fno-signed-zeros`, which
//! lets Clang rewrite a few expressions in ways that only change the sign
//! of a zero result; where its code does, the port computes what the
//! compiled code computes (see `applyWindow` and `imdct36`).

const std = @import("std");
const libm = @import("../core/libm.zig");
const tab = @import("mp3_tab.zig");

/// `SBLIMIT`: the subbands.
pub const sblimit = 32;

/// `MDCT_BUF_SIZE`: a window's length, FFALIGN(36, 2 * 4).
pub const mdct_buf_size = 40;

/// `ff_mdct_win_float`: the IMDCT windows (long, start, short, stop, then
/// the same four with their odd coefficients negated, the frequency
/// inversion of the odd subbands), the IMDCT's last stage folded in
/// (mpadsp_init_tabs). A long window's first half is at 0 to 17, its
/// second at 20 to 37; the short window's 12 at 0 to 11.
pub const mdct_win: [8][mdct_buf_size]f32 = blk: {
    @setEvalBranchQuota(400_000);
    var w: [8][mdct_buf_size]f32 = @splat(@splat(0));
    for (0..36) |i| {
        for (0..4) |j| {
            if (j == 2 and i % 3 != 1) continue;
            const fi: f64 = @floatFromInt(i);
            var d = libm.sin(std.math.pi * (fi + 0.5) / 36.0);
            if (j == 1) {
                if (i >= 30) {
                    d = 0;
                } else if (i >= 24) {
                    d = libm.sin(std.math.pi * (@as(f64, @floatFromInt(i - 18)) + 0.5) / 12.0);
                } else if (i >= 18) {
                    d = 1;
                }
            } else if (j == 3) {
                if (i < 6) {
                    d = 0;
                } else if (i < 12) {
                    d = libm.sin(std.math.pi * (@as(f64, @floatFromInt(i - 6)) + 0.5) / 12.0);
                } else if (i < 18) {
                    d = 1;
                }
            }
            // The IMDCT's last stage merged into the window.
            d *= 0.5 * tab.imdct_scalar / libm.cos(std.math.pi * @as(f64, @floatFromInt(2 * i + 19)) / 72);
            const idx = if (j == 2) i / 3 else if (i < 18) i else i + (mdct_buf_size / 2 - 18);
            w[j][idx] = @floatCast(d / (1 << 5));
        }
    }
    for (0..4) |j| {
        var i: usize = 0;
        while (i < mdct_buf_size) : (i += 2) {
            w[j + 4][i] = w[j][i];
            w[j + 4][i + 1] = -w[j][i + 1];
        }
    }
    break :blk w;
};

/// `ff_mpa_enwindow`: half the synthesis window, in units of 2^-16.
pub const enwindow = [257]i32{
    0,      -1,     -1,     -1,     -1,     -1,     -1,     -2,
    -2,     -2,     -2,     -3,     -3,     -4,     -4,     -5,
    -5,     -6,     -7,     -7,     -8,     -9,     -10,    -11,
    -13,    -14,    -16,    -17,    -19,    -21,    -24,    -26,
    -29,    -31,    -35,    -38,    -41,    -45,    -49,    -53,
    -58,    -63,    -68,    -73,    -79,    -85,    -91,    -97,
    -104,   -111,   -117,   -125,   -132,   -139,   -147,   -154,
    -161,   -169,   -176,   -183,   -190,   -196,   -202,   -208,
    213,    218,    222,    225,    227,    228,    228,    227,
    224,    221,    215,    208,    200,    189,    177,    163,
    146,    127,    106,    83,     57,     29,     -2,     -36,
    -72,    -111,   -153,   -197,   -244,   -294,   -347,   -401,
    -459,   -519,   -581,   -645,   -711,   -779,   -848,   -919,
    -991,   -1064,  -1137,  -1210,  -1283,  -1356,  -1428,  -1498,
    -1567,  -1634,  -1698,  -1759,  -1817,  -1870,  -1919,  -1962,
    -2001,  -2032,  -2057,  -2075,  -2085,  -2087,  -2080,  -2063,
    2037,   2000,   1952,   1893,   1822,   1739,   1644,   1535,
    1414,   1280,   1131,   970,    794,    605,    402,    185,
    -45,    -288,   -545,   -814,   -1095,  -1388,  -1692,  -2006,
    -2330,  -2663,  -3004,  -3351,  -3705,  -4063,  -4425,  -4788,
    -5153,  -5517,  -5879,  -6237,  -6589,  -6935,  -7271,  -7597,
    -7910,  -8209,  -8491,  -8755,  -8998,  -9219,  -9416,  -9585,
    -9727,  -9838,  -9916,  -9959,  -9966,  -9935,  -9863,  -9750,
    -9592,  -9389,  -9139,  -8840,  -8492,  -8092,  -7640,  -7134,
    6574,   5959,   5288,   4561,   3776,   2935,   2037,   1082,
    70,     -998,   -2122,  -3300,  -4533,  -5818,  -7154,  -8540,
    -9975,  -11455, -12980, -14548, -16155, -17799, -19478, -21189,
    -22929, -24694, -26482, -28289, -30112, -31947, -33791, -35640,
    -37489, -39336, -41176, -43006, -44821, -46617, -48390, -50137,
    -51853, -53534, -55178, -56778, -58333, -59838, -61289, -62684,
    -64019, -65290, -66494, -67629, -68692, -69679, -70590, -71420,
    -72169, -72835, -73415, -73908, -74313, -74630, -74856, -74992,
    75038,
};

/// `ff_mpa_synth_window_float` (mpa_synth_init): the 512-tap window from
/// its half, scaled by 2^-(16 + FRAC_BITS), then two reordered copies of
/// parts of it that FFmpeg's assembly reads.
pub const synth_window: [512 + 256]f32 = blk: {
    @setEvalBranchQuota(10_000);
    var w: [512 + 256]f32 = undefined;
    for (0..257) |i| {
        var v: f32 = @floatFromInt(enwindow[i]);
        // `v *= 1.0 / (1LL << (16 + FRAC_BITS))`: a power of two, exact.
        v = @floatCast(@as(f64, v) * (1.0 / @as(f64, 1 << (16 + 23))));
        w[i] = v;
        if (i & 63 != 0) v = -v;
        if (i != 0) w[512 - i] = v;
    }
    for (0..8) |i| {
        for (0..16) |j| w[512 + 16 * i + j] = w[64 * i + 32 - j];
    }
    for (0..8) |i| {
        for (0..16) |j| w[512 + 128 + 16 * i + j] = w[64 * i + 48 - j];
    }
    break :blk w;
};

// dct32 ------------------------------------------------------------------

/// `FIXHR(x / d)`: the double literal over `d` (a power of two, exact), in
/// double as C evaluates it, then rounded to float. A comptime_float
/// quotient would round once from a wider value.
fn fixhr(comptime x: f64, comptime d: f64) f32 {
    return @floatCast(x / d);
}

const cos0 = [16]f32{
    fixhr(0.50060299823519630134, 2), fixhr(0.50547095989754365998, 2), fixhr(0.51544730992262454697, 2), fixhr(0.53104259108978417447, 2),
    fixhr(0.55310389603444452782, 2), fixhr(0.58293496820613387367, 2), fixhr(0.62250412303566481615, 2), fixhr(0.67480834145500574602, 2),
    fixhr(0.74453627100229844977, 2), fixhr(0.83934964541552703873, 2), fixhr(0.97256823786196069369, 2), fixhr(1.16943993343288495515, 4),
    fixhr(1.48416461631416627724, 4), fixhr(2.05778100995341155085, 8), fixhr(3.40760841846871878570, 8), fixhr(10.19000812354805681150, 32),
};
const cos1 = [8]f32{
    fixhr(0.50241928618815570551, 2), fixhr(0.52249861493968888062, 2), fixhr(0.56694403481635770368, 2), fixhr(0.64682178335999012954, 2),
    fixhr(0.78815462345125022473, 2), fixhr(1.06067768599034747134, 4), fixhr(1.72244709823833392782, 4), fixhr(5.10114861868916385802, 16),
};
const cos2 = [4]f32{ fixhr(0.50979557910415916894, 2), fixhr(0.60134488693504528054, 2), fixhr(0.89997622313641570463, 2), fixhr(2.56291544774150617881, 8) };
const cos3 = [2]f32{ fixhr(0.54119610014619698439, 2), fixhr(1.30656296487637652785, 4) };
/// `COS4_0`: M_SQRT1_2 / 2.
const cos4_0 = fixhr(0.70710678118654752440, 2);

/// `MULH3(x, c, 1 << s)` of the float DCT: `((1 << s) * c) * x`, the
/// power-of-two product exact.
inline fn mulh3(x: f32, c: f32, comptime s: u5) f32 {
    const k: f32 = @floatFromInt(1 << s);
    return (k * c) * x;
}

/// The DCT's 32 values, `val0` to `val31`.
const Dct = struct {
    v: [32]f32,
    tab: *const [32]f32,

    /// `BF(a, b, c, s)`.
    inline fn bf(d: *Dct, comptime a: usize, comptime b: usize, c: f32, comptime s: u5) void {
        const tmp0 = d.v[a] + d.v[b];
        const tmp1 = d.v[a] - d.v[b];
        d.v[a] = tmp0;
        d.v[b] = mulh3(tmp1, c, s);
    }

    /// `BF0(a, b, c, s)`: the first pass, from the input.
    inline fn bf0(d: *Dct, comptime a: usize, comptime b: usize, c: f32, comptime s: u5) void {
        const tmp0 = d.tab[a] + d.tab[b];
        const tmp1 = d.tab[a] - d.tab[b];
        d.v[a] = tmp0;
        d.v[b] = mulh3(tmp1, c, s);
    }

    /// `BF1(a, b, c, d)`.
    inline fn bf1(d: *Dct, comptime a: usize, comptime b: usize, comptime c: usize, comptime e: usize) void {
        d.bf(a, b, cos4_0, 1);
        d.bf(c, e, -cos4_0, 1);
        d.v[c] += d.v[e];
    }

    /// `BF2(a, b, c, d)`.
    inline fn bf2(d: *Dct, comptime a: usize, comptime b: usize, comptime c: usize, comptime e: usize) void {
        d.bf(a, b, cos4_0, 1);
        d.bf(c, e, -cos4_0, 1);
        d.v[c] += d.v[e];
        d.v[a] += d.v[c];
        d.v[c] += d.v[b];
        d.v[b] += d.v[e];
    }

    /// `ADD(a, b)`.
    inline fn add(d: *Dct, comptime a: usize, comptime b: usize) void {
        d.v[a] += d.v[b];
    }
};

/// `ff_dct32_float`: the 32-point DCT of the synthesis, without the
/// 1/sqrt(2) scaling of coefficient 0, `in` to `out` in FFmpeg's order of
/// butterflies.
pub fn dct32(out: *[32]f32, in: *const [32]f32) void {
    @setFloatMode(.strict);
    var d: Dct = .{ .v = undefined, .tab = in };
    // pass 1
    d.bf0(0, 31, cos0[0], 1);
    d.bf0(15, 16, cos0[15], 5);
    // pass 2
    d.bf(0, 15, cos1[0], 1);
    d.bf(16, 31, -cos1[0], 1);
    // pass 1
    d.bf0(7, 24, cos0[7], 1);
    d.bf0(8, 23, cos0[8], 1);
    // pass 2
    d.bf(7, 8, cos1[7], 4);
    d.bf(23, 24, -cos1[7], 4);
    // pass 3
    d.bf(0, 7, cos2[0], 1);
    d.bf(8, 15, -cos2[0], 1);
    d.bf(16, 23, cos2[0], 1);
    d.bf(24, 31, -cos2[0], 1);
    // pass 1
    d.bf0(3, 28, cos0[3], 1);
    d.bf0(12, 19, cos0[12], 2);
    // pass 2
    d.bf(3, 12, cos1[3], 1);
    d.bf(19, 28, -cos1[3], 1);
    // pass 1
    d.bf0(4, 27, cos0[4], 1);
    d.bf0(11, 20, cos0[11], 2);
    // pass 2
    d.bf(4, 11, cos1[4], 1);
    d.bf(20, 27, -cos1[4], 1);
    // pass 3
    d.bf(3, 4, cos2[3], 3);
    d.bf(11, 12, -cos2[3], 3);
    d.bf(19, 20, cos2[3], 3);
    d.bf(27, 28, -cos2[3], 3);
    // pass 4
    d.bf(0, 3, cos3[0], 1);
    d.bf(4, 7, -cos3[0], 1);
    d.bf(8, 11, cos3[0], 1);
    d.bf(12, 15, -cos3[0], 1);
    d.bf(16, 19, cos3[0], 1);
    d.bf(20, 23, -cos3[0], 1);
    d.bf(24, 27, cos3[0], 1);
    d.bf(28, 31, -cos3[0], 1);

    // pass 1
    d.bf0(1, 30, cos0[1], 1);
    d.bf0(14, 17, cos0[14], 3);
    // pass 2
    d.bf(1, 14, cos1[1], 1);
    d.bf(17, 30, -cos1[1], 1);
    // pass 1
    d.bf0(6, 25, cos0[6], 1);
    d.bf0(9, 22, cos0[9], 1);
    // pass 2
    d.bf(6, 9, cos1[6], 2);
    d.bf(22, 25, -cos1[6], 2);
    // pass 3
    d.bf(1, 6, cos2[1], 1);
    d.bf(9, 14, -cos2[1], 1);
    d.bf(17, 22, cos2[1], 1);
    d.bf(25, 30, -cos2[1], 1);

    // pass 1
    d.bf0(2, 29, cos0[2], 1);
    d.bf0(13, 18, cos0[13], 3);
    // pass 2
    d.bf(2, 13, cos1[2], 1);
    d.bf(18, 29, -cos1[2], 1);
    // pass 1
    d.bf0(5, 26, cos0[5], 1);
    d.bf0(10, 21, cos0[10], 1);
    // pass 2
    d.bf(5, 10, cos1[5], 2);
    d.bf(21, 26, -cos1[5], 2);
    // pass 3
    d.bf(2, 5, cos2[2], 1);
    d.bf(10, 13, -cos2[2], 1);
    d.bf(18, 21, cos2[2], 1);
    d.bf(26, 29, -cos2[2], 1);
    // pass 4
    d.bf(1, 2, cos3[1], 2);
    d.bf(5, 6, -cos3[1], 2);
    d.bf(9, 10, cos3[1], 2);
    d.bf(13, 14, -cos3[1], 2);
    d.bf(17, 18, cos3[1], 2);
    d.bf(21, 22, -cos3[1], 2);
    d.bf(25, 26, cos3[1], 2);
    d.bf(29, 30, -cos3[1], 2);

    // pass 5
    d.bf1(0, 1, 2, 3);
    d.bf2(4, 5, 6, 7);
    d.bf1(8, 9, 10, 11);
    d.bf2(12, 13, 14, 15);
    d.bf1(16, 17, 18, 19);
    d.bf2(20, 21, 22, 23);
    d.bf1(24, 25, 26, 27);
    d.bf2(28, 29, 30, 31);

    // pass 6
    d.add(8, 12);
    d.add(12, 10);
    d.add(10, 14);
    d.add(14, 9);
    d.add(9, 13);
    d.add(13, 11);
    d.add(11, 15);

    const v = &d.v;
    out[0] = v[0];
    out[16] = v[1];
    out[8] = v[2];
    out[24] = v[3];
    out[4] = v[4];
    out[20] = v[5];
    out[12] = v[6];
    out[28] = v[7];
    out[2] = v[8];
    out[18] = v[9];
    out[10] = v[10];
    out[26] = v[11];
    out[6] = v[12];
    out[22] = v[13];
    out[14] = v[14];
    out[30] = v[15];

    d.add(24, 28);
    d.add(28, 26);
    d.add(26, 30);
    d.add(30, 25);
    d.add(25, 29);
    d.add(29, 27);
    d.add(27, 31);

    out[1] = v[16] + v[24];
    out[17] = v[17] + v[25];
    out[9] = v[18] + v[26];
    out[25] = v[19] + v[27];
    out[5] = v[20] + v[28];
    out[21] = v[21] + v[29];
    out[13] = v[22] + v[30];
    out[29] = v[23] + v[31];
    out[3] = v[24] + v[20];
    out[19] = v[25] + v[21];
    out[11] = v[26] + v[22];
    out[27] = v[27] + v[23];
    out[7] = v[28] + v[18];
    out[23] = v[29] + v[19];
    out[15] = v[30] + v[17];
    out[31] = v[31];
}

// Synthesis --------------------------------------------------------------

/// One channel's synthesis state: `synth_buf` (512 values, then 32 more
/// that each window copies the first 32 into, as the SIMD versions read
/// it) and `synth_buf_offset`.
pub const Synth = struct {
    buf: [1024]f32 = @splat(0),
    offset: u32 = 0,

    /// `ff_mpa_synth_filter_float`: 32 subband samples to 32 output
    /// samples.
    pub fn filter(s: *Synth, out: *[32]f32, sb_samples: *const [32]f32) void {
        const at = s.buf[s.offset..][0 .. 512 + 32];
        dct32(at[0..32], sb_samples);
        applyWindow(at, out);
        s.offset = (s.offset -% 32) & 511;
    }
};

/// apply_window of x86/mpegaudiodsp.c: eight products per lane summed from
/// zero, by subtraction, as the SSE code sums them (`len` 16, lanes of
/// `buf`, `win1` and `win2` at strides 64, 64 and 16).
inline fn windowSums(buf: []const f32, win1: []const f32, win2: []const f32, sum1: *[17]f32, sum2: *[17]f32) void {
    for (0..16) |k| {
        var s1: f32 = 0;
        var s2: f32 = 0;
        inline for (0..8) |m| {
            const p = buf[k + 64 * m];
            s1 -= win1[k + 64 * m] * p;
            s2 -= p * win2[k + 16 * m];
        }
        sum1[k] = s1;
        sum2[k] = s2;
    }
}

/// x86/mpegaudiodsp.c's `apply_window_mp3` with `incr` 1, which the
/// reference build selects for every x86 CPU (inline SSE, kept under
/// --disable-x86asm): `in[0 .. 32]` copied to `in[512 ..]`, then the 32
/// output samples from the window's partial sums. It sums in another
/// order than the C `ff_mpadsp_apply_window_float` (notes.md "MP3
/// decoding"). Every lane is IEEE single precision, so the scalar code
/// here gives the SSE code's results.
fn applyWindow(in: *[512 + 32]f32, out: *[32]f32) void {
    @setFloatMode(.strict);
    const win = &synth_window;
    @memcpy(in[512..][0..32], in[0..32]);
    var suma: [17]f32 = undefined;
    var sumb: [17]f32 = undefined;
    var sumc: [17]f32 = undefined;
    var sumd: [17]f32 = undefined;
    windowSums(in[16..], win[0..], win[512..], &suma, &sumc);
    windowSums(in[32..], win[48..], win[640..], &sumb, &sumd);
    // `SUM8(MACS, suma[0], win + 32, in + 48)`, compiled C.
    inline for (0..8) |m| suma[0] += win[32 + 64 * m] * in[48 + 64 * m];
    sumc[0] = 0;
    sumb[16] = 0;
    sumd[16] = 0;
    // The SUMS blocks: reversed sumd minus suma, reversed sumc plus sumb.
    for (0..16) |j| out[j] = sumd[16 - j] - suma[j];
    for (1..17) |j| out[32 - j] = sumc[j] + sumb[16 - j];
    // `sum = 0; SUM8(MLSS, sum, win + 48, in + 32)`, compiled C: under
    // -fno-signed-zeros Clang computes it as -(first product) minus the
    // others (its code starts from the second product negated, the same
    // value), so silence gives -0 here where 0 - 0 would give +0.
    var sum: f32 = -(win[48] * in[32]);
    inline for (1..8) |m| sum -= win[48 + 64 * m] * in[32 + 64 * m];
    out[16] = sum;
}

// IMDCT ------------------------------------------------------------------

// cos(pi * i / 18), halved.
const c1 = fixhr(0.98480775301220805936, 2);
const c2 = fixhr(0.93969262078590838405, 2);
const c3 = fixhr(0.86602540378443864676, 2);
const c4 = fixhr(0.76604444311897803520, 2);
const c5 = fixhr(0.64278760968653932632, 2);
const c7 = fixhr(0.34202014332566873304, 2);
const c8 = fixhr(0.17364817766693034885, 2);

/// `icos36`: 0.5 / cos(pi * (2i + 1) / 36).
const icos36 = [9]f32{
    fixhr(0.50190991877167369479, 1), fixhr(0.51763809020504152469, 1), fixhr(0.55168895948124587824, 1),
    fixhr(0.61038729438072803416, 1), fixhr(0.70710678118654752439, 1), fixhr(0.87172339781054900991, 1),
    fixhr(1.18310079157624925896, 1), fixhr(1.93185165257813657349, 1), fixhr(5.73685662283492756461, 1),
};

/// `icos36h`: the same, halved (the last two quartered), 8 of 9.
const icos36h = [8]f32{
    fixhr(0.50190991877167369479, 2), fixhr(0.51763809020504152469, 2), fixhr(0.55168895948124587824, 2),
    fixhr(0.61038729438072803416, 2), fixhr(0.70710678118654752439, 2), fixhr(0.87172339781054900991, 2),
    fixhr(1.18310079157624925896, 4), fixhr(1.93185165257813657349, 4),
};

/// `SHR(a, 1)`: `a * (1.0f / 2)`.
inline fn half(a: f32) f32 {
    return a * 0.5;
}

/// `imdct36`: one long block's 18 coefficients `in` (modified in place, as
/// FFmpeg's) through a Lee-like decomposition and a 9-point DCT, windowed
/// by `win`, the first half added to the saved `buf` into `out` (stride
/// 32) and the second half saved into `buf` (stride 4).
fn imdct36(out: []f32, buf: []f32, in: *[18]f32, win: *const [mdct_buf_size]f32) void {
    @setFloatMode(.strict);
    var i: usize = 17;
    while (i >= 1) : (i -= 1) in[i] += in[i - 1];
    i = 17;
    while (i >= 3) : (i -= 2) in[i] += in[i - 2];

    var tmp: [18]f32 = undefined;
    for (0..2) |j| {
        const in1 = in[j..];
        const tmp1 = tmp[j..];

        var t2 = in1[2 * 4] + in1[2 * 8] - in1[2 * 2];

        var t3 = in1[2 * 0] + half(in1[2 * 6]);
        var t1 = in1[2 * 0] - in1[2 * 6];
        tmp1[6] = t1 - half(t2);
        tmp1[16] = t1 + t2;

        var t0 = mulh3(in1[2 * 2] + in1[2 * 4], c2, 1);
        t1 = mulh3(in1[2 * 4] - in1[2 * 8], -2 * c8, 0);
        t2 = mulh3(in1[2 * 2] + in1[2 * 8], -c4, 1);

        tmp1[10] = t3 - t0 - t2;
        tmp1[2] = t3 + t0 + t1;
        tmp1[14] = t3 + t2 - t1;

        tmp1[4] = mulh3(in1[2 * 5] + in1[2 * 7] - in1[2 * 1], -c3, 1);
        t2 = mulh3(in1[2 * 1] + in1[2 * 5], c1, 1);
        t3 = mulh3(in1[2 * 5] - in1[2 * 7], -2 * c7, 0);
        t0 = mulh3(in1[2 * 3], c3, 1);

        t1 = mulh3(in1[2 * 1] + in1[2 * 7], -c5, 1);

        tmp1[0] = t2 + t3 + t0;
        tmp1[12] = t2 + t1 - t0;
        tmp1[8] = t3 - t1 - t0;
    }

    const half_buf = mdct_buf_size / 2;
    var k: usize = 0;
    for (0..4) |j| {
        var t0 = tmp[k];
        var t1 = tmp[k + 2];
        const s0 = t1 + t0;
        const s2 = t1 - t0;

        const t2 = tmp[k + 1];
        const t3 = tmp[k + 3];
        const s1 = mulh3(t3 + t2, icos36h[j], 1);
        const s3 = icos36[8 - j] * (t3 - t2);

        t0 = s0 + s1;
        t1 = s0 - s1;
        out[(9 + j) * sblimit] = t1 * win[9 + j] + buf[4 * (9 + j)];
        out[(8 - j) * sblimit] = t1 * win[8 - j] + buf[4 * (8 - j)];
        buf[4 * (9 + j)] = t0 * win[half_buf + 9 + j];
        buf[4 * (8 - j)] = t0 * win[half_buf + 8 - j];

        t0 = s2 + s3;
        t1 = s2 - s3;
        out[(9 + 8 - j) * sblimit] = t1 * win[9 + 8 - j] + buf[4 * (9 + 8 - j)];
        out[j * sblimit] = t1 * win[j] + buf[4 * j];
        buf[4 * (9 + 8 - j)] = t0 * win[half_buf + 9 + 8 - j];
        buf[4 * j] = t0 * win[half_buf + j];
        k += 4;
    }

    const s0 = tmp[16];
    const s1 = mulh3(tmp[17], icos36h[4], 1);
    const t0 = s0 + s1;
    const t1 = s0 - s1;
    out[(9 + 4) * sblimit] = t1 * win[9 + 4] + buf[4 * (9 + 4)];
    out[(8 - 4) * sblimit] = t1 * win[8 - 4] + buf[4 * (8 - 4)];
    buf[4 * (9 + 4)] = t0 * win[half_buf + 9 + 4];
    buf[4 * (8 - 4)] = t0 * win[half_buf + 8 - 4];
}

/// Where subband `j`'s overlap starts in a channel's `mdct_buf`: groups
/// of four subbands, interleaved at stride 4, 72 values a group.
pub fn overlapOffset(j: usize) usize {
    return 4 * 18 * (j >> 2) + (j & 3);
}

/// `ff_imdct36_blocks_float`: the first `count` subbands of a granule's
/// 576 coefficients `in` (modified in place), long blocks of type
/// `block_type` (the first two long windows with `switch_point`), into
/// `out` (18 rows of 32 subbands) with the overlap `buf`.
pub fn imdct36Blocks(out: *[18 * sblimit]f32, buf: *[576]f32, in: *[576]f32, count: usize, switch_point: bool, block_type: u2) void {
    for (0..count) |j| {
        const win_idx: usize = if (switch_point and j < 2) 0 else block_type;
        const win = &mdct_win[win_idx + (4 & (0 -% (j & 1)))];
        imdct36(out[j..], buf[overlapOffset(j)..], in[18 * j ..][0..18], win);
    }
}
