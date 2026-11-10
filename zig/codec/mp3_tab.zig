// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/mpegaudiodec_common.c (the Layer III
// tables and mpegaudiodec_common_init_static), mpegaudiodec_common_tablegen.h
// (mpegaudiodec_common_tableinit), mpegaudio_tablegen.h
// (mpegaudio_tableinit), mpegaudiodec_float.c (is_table, csa_table) and
// mpegaudiodec_template.c (decode_init_static's is_table_lsf and
// scale_factor_mult, scale_factor_mult2), mpegaudiodata.c (the Layer II
// allocation and quantizer tables) and mpegaudio.c (ff_mpa_l2_select_table)
// at the pinned reference revision: the constant tables transcribed value for value, the
// computed ones computed as FFmpeg computes them, in its precision and with
// the reference platform's cbrt and exp2 (core/libm.zig).
// Copyright (c) 2001, 2002 Fabrice Bellard
// Copyright (c) 2010 Michael Niedermayer
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! The MPEG audio decoder's tables, named as FFmpeg's without the `ff_`
//! prefix. Layer III (TODO.md T29b): the band and scale factor layouts,
//! the Huffman tables as FFmpeg's VLC lookup tables, the n^(4/3) tables of
//! the requantization and the stereo and antialiasing coefficients of the
//! float decoder. Layers I and II (T29c): the scale factor multipliers,
//! Layer II's bit allocation tables, quantizers and grouping tables. Everything is built at compile time; FFmpeg builds the
//! same tables once at run time (CONFIG_HARDCODED_TABLES is off in the
//! reference build).

const std = @import("std");
const vlc = @import("vlc.zig");
const libm = @import("../core/libm.zig");
const cconv = @import("../core/cconv.zig");

/// `IMDCT_SCALAR`, folded into the power tables and the IMDCT windows.
pub const imdct_scalar: f64 = 1.759;

/// `FRAC_BITS` of the fixed-point scale the 4/3 table is normalized to.
const frac_bits = 23;

/// The 44.1/48/32 kHz, 22.05/24/16 kHz and 11.025/12/8 kHz rates, by
/// `sample_rate_index`.
pub const rate_count = 9;

/// `ff_slen_table`: MPEG-1's scale factor bits by `scalefac_compress`.
pub const slen_table = [2][16]u8{
    .{ 0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4 },
    .{ 0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3 },
};

/// `ff_lsf_nsf_table`: MPEG-2's scale factors per partition, by
/// [tindex2][block kind][partition].
pub const lsf_nsf_table = [6][3][4]u8{
    .{ .{ 6, 5, 5, 5 }, .{ 9, 9, 9, 9 }, .{ 6, 9, 9, 9 } },
    .{ .{ 6, 5, 7, 3 }, .{ 9, 9, 12, 6 }, .{ 6, 9, 12, 6 } },
    .{ .{ 11, 10, 0, 0 }, .{ 18, 18, 0, 0 }, .{ 15, 18, 0, 0 } },
    .{ .{ 7, 7, 7, 0 }, .{ 12, 12, 12, 0 }, .{ 6, 15, 12, 0 } },
    .{ .{ 6, 6, 6, 3 }, .{ 12, 9, 9, 6 }, .{ 6, 12, 9, 6 } },
    .{ .{ 8, 8, 5, 0 }, .{ 15, 12, 9, 0 }, .{ 6, 18, 9, 0 } },
};

/// `ff_mpa_huff_data`: by `table_select`, the VLC table (0 for none) and
/// its linbits.
pub const huff_data = [32][2]u8{
    .{ 0, 0 },  .{ 1, 0 },  .{ 2, 0 },  .{ 3, 0 },  .{ 0, 0 },  .{ 4, 0 },  .{ 5, 0 },   .{ 6, 0 },
    .{ 7, 0 },  .{ 8, 0 },  .{ 9, 0 },  .{ 10, 0 }, .{ 11, 0 }, .{ 12, 0 }, .{ 0, 0 },   .{ 13, 0 },
    .{ 14, 1 }, .{ 14, 2 }, .{ 14, 3 }, .{ 14, 4 }, .{ 14, 6 }, .{ 14, 8 }, .{ 14, 10 }, .{ 14, 13 },
    .{ 15, 4 }, .{ 15, 5 }, .{ 15, 6 }, .{ 15, 7 }, .{ 15, 8 }, .{ 15, 9 }, .{ 15, 11 }, .{ 15, 13 },
};

/// `mpa_quad_codes`: the count1 tables A and B.
const quad_codes = [2][16]u8{
    .{ 1, 5, 4, 5, 6, 5, 4, 4, 7, 3, 6, 0, 7, 2, 3, 1 },
    .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
};

/// `mpa_quad_bits`.
const quad_bits = [2][16]u8{
    .{ 1, 4, 4, 5, 4, 6, 5, 6, 4, 5, 5, 6, 5, 6, 6, 6 },
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4 },
};

/// `ff_band_size_long`: the long blocks' scale factor bands, by rate.
pub const band_size_long = [rate_count][22]u8{
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158 }, // 44100
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192 }, // 48000
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26 }, // 32000
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 }, // 22050
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36 }, // 24000
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 }, // 16000
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 }, // 11025
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 }, // 12000
    .{ 12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2 }, // 8000
};

/// `ff_band_size_short`: the short blocks' bands, by rate.
pub const band_size_short = [rate_count][13]u8{
    .{ 4, 4, 4, 4, 6, 8, 10, 12, 14, 18, 22, 30, 56 }, // 44100
    .{ 4, 4, 4, 4, 6, 6, 10, 12, 14, 16, 20, 26, 66 }, // 48000
    .{ 4, 4, 4, 4, 6, 8, 12, 16, 20, 26, 34, 42, 12 }, // 32000
    .{ 4, 4, 4, 6, 6, 8, 10, 14, 18, 26, 32, 42, 18 }, // 22050
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 32, 44, 12 }, // 24000
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18 }, // 16000
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18 }, // 11025
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18 }, // 12000
    .{ 8, 8, 8, 12, 16, 20, 24, 28, 36, 2, 2, 2, 26 }, // 8000
};

/// `ff_band_index_long`: where each long band starts, in pairs of
/// samples (mpegaudiodec_common_init_static).
pub const band_index_long: [rate_count][23]u16 = blk: {
    var t: [rate_count][23]u16 = undefined;
    for (0..rate_count) |i| {
        var k: u16 = 0;
        for (0..22) |j| {
            t[i][j] = k;
            k += band_size_long[i][j] >> 1;
        }
        t[i][22] = k;
    }
    break :blk t;
};

/// `ff_mpa_pretab`: the long bands' pre-emphasis, by `preflag`.
pub const pretab = [2][22]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0 },
};

comptime {
    // Every layout covers the granule's 576 samples, so the exponents
    // and the stereo walk over the bands never leave it: the long bands,
    // the short ones three times, and the mixed blocks' 36 (72 at 8 kHz)
    // long samples (long_end 8, or 6 for MPEG-2 and 2.5) then the short
    // bands from the third.
    for (0..rate_count) |i| {
        var long: u32 = 0;
        for (band_size_long[i]) |n| long += n;
        var short: u32 = 0;
        for (band_size_short[i]) |n| short += 3 * @as(u32, n);
        var mixed: u32 = 0;
        const long_end: usize = if (i <= 2) 8 else 6;
        for (band_size_long[i][0..long_end]) |n| mixed += n;
        for (band_size_short[i][3..]) |n| mixed += 3 * @as(u32, n);
        if (long != 576 or short != 576 or mixed != 576) @compileError("a band layout does not cover 576 samples");
    }
}

/// `mpa_huff_sizes_minus_one`: the codes of each big-value table.
const huff_sizes_minus_one = [15]u8{ 3, 8, 8, 15, 15, 35, 35, 35, 63, 63, 63, 255, 255, 255, 255 };

/// `mpa_hufflens`: the code lengths of the 15 big-value tables, one after
/// another, in canonical order.
const hufflens = [1378]u8{
    3,  3,  2,  1,  6,  6,  5,  5,  5,  3,  3,  3,  1,  6,  6,  5,
    5,  5,  3,  2,  2,  2,  8,  8,  7,  6,  7,  7,  7,  7,  6,  6,
    6,  6,  3,  3,  3,  1,  7,  7,  6,  6,  6,  5,  5,  5,  5,  4,
    4,  4,  3,  2,  3,  3,  10, 10, 10, 10, 9,  9,  9,  9,  8,  8,
    9,  9,  8,  9,  9,  8,  8,  7,  7,  7,  8,  8,  8,  8,  7,  7,
    7,  7,  6,  5,  6,  6,  4,  3,  3,  1,  11, 11, 10, 9,  10, 10,
    9,  9,  9,  8,  8,  9,  9,  9,  9,  8,  8,  8,  7,  8,  8,  8,
    8,  8,  8,  8,  8,  6,  6,  6,  4,  4,  2,  3,  3,  2,  9,  9,
    8,  8,  9,  9,  8,  8,  8,  8,  7,  7,  7,  8,  8,  7,  7,  7,
    7,  6,  6,  6,  6,  5,  5,  6,  6,  5,  5,  4,  4,  4,  3,  3,
    3,  3,  11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10, 10, 10, 11,
    11, 10, 9,  9,  10, 10, 9,  9,  10, 10, 9,  10, 10, 8,  8,  9,
    9,  10, 10, 9,  9,  10, 10, 8,  8,  8,  9,  9,  9,  9,  9,  9,
    8,  8,  8,  8,  8,  8,  7,  7,  7,  7,  6,  6,  6,  6,  4,  3,
    3,  1,  10, 10, 10, 10, 10, 10, 10, 11, 11, 10, 10, 9,  9,  9,
    10, 10, 10, 10, 8,  8,  9,  9,  7,  8,  8,  8,  8,  8,  9,  9,
    9,  9,  8,  7,  8,  8,  7,  7,  8,  8,  8,  9,  9,  8,  8,  8,
    8,  8,  8,  7,  7,  6,  6,  7,  7,  6,  5,  4,  5,  5,  3,  3,
    3,  2,  10, 10, 9,  9,  9,  9,  9,  9,  9,  8,  8,  9,  9,  8,
    8,  8,  8,  8,  8,  9,  9,  8,  8,  8,  8,  8,  9,  9,  7,  7,
    7,  8,  8,  8,  8,  8,  8,  7,  7,  7,  7,  8,  8,  7,  7,  7,
    6,  6,  6,  6,  7,  7,  6,  5,  5,  5,  4,  4,  5,  5,  4,  3,
    3,  3,  19, 19, 18, 17, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
    17, 17, 15, 15, 16, 16, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    16, 16, 15, 16, 16, 14, 14, 15, 15, 15, 15, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 15, 15, 14, 13, 14, 14, 13, 13, 14, 14,
    13, 14, 14, 13, 14, 14, 13, 14, 14, 13, 13, 14, 14, 12, 12, 12,
    13, 13, 13, 13, 13, 13, 12, 13, 13, 12, 12, 13, 13, 13, 13, 13,
    13, 13, 13, 13, 13, 13, 13, 12, 12, 13, 13, 12, 12, 12, 12, 13,
    13, 13, 13, 12, 13, 13, 12, 11, 12, 12, 12, 12, 12, 12, 12, 12,
    11, 11, 11, 11, 12, 12, 11, 11, 12, 12, 11, 12, 12, 12, 12, 11,
    11, 12, 12, 11, 12, 12, 11, 12, 12, 11, 12, 12, 10, 10, 10, 11,
    11, 11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 11, 11, 10, 11, 11,
    10, 11, 11, 11, 11, 10, 10, 11, 11, 10, 10, 11, 11, 11, 11, 11,
    11, 9,  9,  10, 10, 10, 10, 10, 11, 11, 9,  9,  9,  10, 10, 9,
    9,  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 8,  9,  9,  9,  9,
    9,  9,  10, 10, 9,  9,  9,  8,  8,  9,  9,  9,  9,  9,  9,  8,
    7,  8,  8,  8,  8,  7,  7,  7,  7,  7,  6,  6,  6,  6,  4,  4,
    3,  1,  13, 13, 13, 13, 12, 13, 13, 13, 13, 13, 13, 12, 13, 13,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 13, 13, 11, 11, 12, 12, 12, 12, 11,
    11, 11, 11, 11, 11, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11, 12,
    12, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
    11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 11, 11, 11, 11,
    11, 11, 10, 11, 11, 11, 11, 11, 11, 10, 10, 11, 11, 10, 10, 10,
    10, 11, 11, 10, 10, 10, 10, 10, 10, 10, 11, 11, 10, 10, 10, 10,
    10, 11, 11, 9,  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    9,  10, 10, 10, 10, 9,  10, 10, 9,  10, 10, 10, 10, 10, 10, 10,
    10, 9,  9,  9,  9,  9,  9,  9,  10, 10, 9,  9,  9,  9,  9,  9,
    10, 10, 9,  9,  9,  9,  9,  9,  8,  9,  9,  9,  9,  9,  9,  9,
    9,  9,  9,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9,  8,
    8,  8,  8,  8,  8,  9,  9,  8,  8,  8,  8,  8,  8,  8,  9,  9,
    8,  7,  8,  8,  7,  7,  7,  7,  8,  8,  7,  7,  7,  7,  7,  6,
    7,  7,  6,  6,  7,  7,  6,  6,  6,  5,  5,  5,  5,  5,  3,  4,
    4,  3,  11, 11, 11, 11, 11, 11, 11, 11, 10, 11, 11, 11, 11, 10,
    10, 10, 10, 10, 8,  10, 10, 9,  9,  9,  9,  10, 16, 17, 17, 15,
    15, 16, 16, 14, 15, 15, 14, 14, 15, 15, 14, 14, 15, 15, 15, 15,
    14, 15, 15, 14, 13, 8,  9,  9,  8,  8,  13, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 13, 13, 14, 14, 14, 14, 13, 14, 14, 13, 13,
    13, 14, 14, 14, 14, 13, 13, 14, 14, 13, 14, 14, 12, 13, 13, 13,
    13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 12, 13, 13, 13, 13,
    13, 13, 12, 13, 13, 12, 12, 13, 13, 11, 12, 12, 12, 12, 12, 12,
    12, 13, 13, 11, 12, 12, 12, 12, 11, 12, 12, 12, 12, 12, 12, 12,
    12, 11, 12, 12, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12,
    11, 12, 12, 11, 12, 12, 11, 12, 12, 11, 12, 12, 11, 10, 10, 11,
    11, 11, 11, 11, 11, 10, 10, 11, 11, 10, 10, 11, 11, 11, 11, 11,
    11, 11, 11, 10, 11, 11, 10, 10, 10, 11, 11, 10, 10, 11, 11, 10,
    10, 11, 11, 10, 9,  9,  10, 10, 10, 10, 10, 10, 9,  9,  9,  10,
    10, 9,  10, 10, 9,  9,  8,  9,  9,  9,  9,  9,  9,  9,  9,  8,
    8,  9,  9,  8,  8,  7,  7,  8,  8,  7,  6,  6,  6,  6,  4,  4,
    3,  1,  8,  8,  8,  8,  8,  8,  8,  8,  7,  8,  8,  7,  7,  8,
    8,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  8,  8,  9,
    11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
    11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 4,  11, 11, 11,
    11, 12, 12, 11, 10, 11, 11, 10, 10, 10, 10, 11, 11, 10, 10, 10,
    10, 11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 10, 11, 11, 10, 9,
    10, 10, 10, 10, 11, 11, 10, 9,  9,  10, 10, 9,  10, 10, 10, 10,
    9,  9,  10, 10, 9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,
    9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,  9,
    9,  9,  9,  9,  9,  9,  9,  9,  10, 10, 9,  9,  9,  10, 10, 8,
    9,  9,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  9,
    9,  8,  8,  8,  8,  8,  8,  9,  9,  7,  8,  8,  7,  7,  7,  7,
    7,  8,  8,  7,  7,  6,  6,  7,  7,  6,  5,  5,  6,  6,  4,  4,
    4,  4,
};

/// `mpa_huffsymbols`: each code's pair, x in the high nibble.
const huffsymbols = [1378]u8{
    0x11, 0x01, 0x10, 0x00, 0x22, 0x02, 0x12, 0x21, 0x20, 0x11, 0x01, 0x10, 0x00, 0x22, 0x02, 0x12,
    0x21, 0x20, 0x10, 0x11, 0x01, 0x00, 0x33, 0x23, 0x32, 0x31, 0x13, 0x03, 0x30, 0x22, 0x12, 0x21,
    0x02, 0x20, 0x11, 0x01, 0x10, 0x00, 0x33, 0x03, 0x23, 0x32, 0x30, 0x13, 0x31, 0x22, 0x02, 0x12,
    0x21, 0x20, 0x01, 0x11, 0x10, 0x00, 0x55, 0x45, 0x54, 0x53, 0x35, 0x44, 0x25, 0x52, 0x15, 0x51,
    0x05, 0x34, 0x50, 0x43, 0x33, 0x24, 0x42, 0x14, 0x41, 0x40, 0x04, 0x23, 0x32, 0x03, 0x13, 0x31,
    0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01, 0x10, 0x00, 0x55, 0x54, 0x45, 0x53, 0x35, 0x44,
    0x25, 0x52, 0x05, 0x15, 0x51, 0x34, 0x43, 0x50, 0x33, 0x24, 0x42, 0x14, 0x41, 0x04, 0x40, 0x23,
    0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x02, 0x20, 0x12, 0x21, 0x11, 0x01, 0x10, 0x00, 0x55, 0x45,
    0x35, 0x53, 0x54, 0x05, 0x44, 0x25, 0x52, 0x15, 0x51, 0x34, 0x43, 0x50, 0x04, 0x24, 0x42, 0x33,
    0x40, 0x14, 0x41, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x02, 0x12, 0x21, 0x20, 0x11, 0x01,
    0x10, 0x00, 0x77, 0x67, 0x76, 0x57, 0x75, 0x66, 0x47, 0x74, 0x56, 0x65, 0x37, 0x73, 0x46, 0x55,
    0x54, 0x63, 0x27, 0x72, 0x64, 0x07, 0x70, 0x62, 0x45, 0x35, 0x06, 0x53, 0x44, 0x17, 0x71, 0x36,
    0x26, 0x25, 0x52, 0x15, 0x51, 0x34, 0x43, 0x16, 0x61, 0x60, 0x05, 0x50, 0x24, 0x42, 0x33, 0x04,
    0x14, 0x41, 0x40, 0x23, 0x32, 0x03, 0x13, 0x31, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0x77, 0x67, 0x76, 0x75, 0x66, 0x47, 0x74, 0x57, 0x55, 0x56, 0x65, 0x37, 0x73, 0x46,
    0x45, 0x54, 0x35, 0x53, 0x27, 0x72, 0x64, 0x07, 0x71, 0x17, 0x70, 0x36, 0x63, 0x60, 0x44, 0x25,
    0x52, 0x05, 0x15, 0x62, 0x26, 0x06, 0x16, 0x61, 0x51, 0x34, 0x50, 0x43, 0x33, 0x24, 0x42, 0x14,
    0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x21, 0x12, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0x77, 0x67, 0x76, 0x57, 0x75, 0x66, 0x47, 0x74, 0x65, 0x56, 0x37, 0x73, 0x55, 0x27,
    0x72, 0x46, 0x64, 0x17, 0x71, 0x07, 0x70, 0x36, 0x63, 0x45, 0x54, 0x44, 0x06, 0x05, 0x26, 0x62,
    0x61, 0x16, 0x60, 0x35, 0x53, 0x25, 0x52, 0x15, 0x51, 0x34, 0x43, 0x50, 0x04, 0x24, 0x42, 0x14,
    0x33, 0x41, 0x23, 0x32, 0x40, 0x03, 0x30, 0x13, 0x31, 0x22, 0x12, 0x21, 0x02, 0x20, 0x00, 0x11,
    0x01, 0x10, 0xFE, 0xFC, 0xFD, 0xED, 0xFF, 0xEF, 0xDF, 0xEE, 0xCF, 0xDE, 0xBF, 0xFB, 0xCE, 0xDC,
    0xAF, 0xE9, 0xEC, 0xDD, 0xFA, 0xCD, 0xBE, 0xEB, 0x9F, 0xF9, 0xEA, 0xBD, 0xDB, 0x8F, 0xF8, 0xCC,
    0xAE, 0x9E, 0x8E, 0x7F, 0x7E, 0xF7, 0xDA, 0xAD, 0xBC, 0xCB, 0xF6, 0x6F, 0xE8, 0x5F, 0x9D, 0xD9,
    0xF5, 0xE7, 0xAC, 0xBB, 0x4F, 0xF4, 0xCA, 0xE6, 0xF3, 0x3F, 0x8D, 0xD8, 0x2F, 0xF2, 0x6E, 0x9C,
    0x0F, 0xC9, 0x5E, 0xAB, 0x7D, 0xD7, 0x4E, 0xC8, 0xD6, 0x3E, 0xB9, 0x9B, 0xAA, 0x1F, 0xF1, 0xF0,
    0xBA, 0xE5, 0xE4, 0x8C, 0x6D, 0xE3, 0xE2, 0x2E, 0x0E, 0x1E, 0xE1, 0xE0, 0x5D, 0xD5, 0x7C, 0xC7,
    0x4D, 0x8B, 0xB8, 0xD4, 0x9A, 0xA9, 0x6C, 0xC6, 0x3D, 0xD3, 0x7B, 0x2D, 0xD2, 0x1D, 0xB7, 0x5C,
    0xC5, 0x99, 0x7A, 0xC3, 0xA7, 0x97, 0x4B, 0xD1, 0x0D, 0xD0, 0x8A, 0xA8, 0x4C, 0xC4, 0x6B, 0xB6,
    0x3C, 0x2C, 0xC2, 0x5B, 0xB5, 0x89, 0x1C, 0xC1, 0x98, 0x0C, 0xC0, 0xB4, 0x6A, 0xA6, 0x79, 0x3B,
    0xB3, 0x88, 0x5A, 0x2B, 0xA5, 0x69, 0xA4, 0x78, 0x87, 0x94, 0x77, 0x76, 0xB2, 0x1B, 0xB1, 0x0B,
    0xB0, 0x96, 0x4A, 0x3A, 0xA3, 0x59, 0x95, 0x2A, 0xA2, 0x1A, 0xA1, 0x0A, 0x68, 0xA0, 0x86, 0x49,
    0x93, 0x39, 0x58, 0x85, 0x67, 0x29, 0x92, 0x57, 0x75, 0x38, 0x83, 0x66, 0x47, 0x74, 0x56, 0x65,
    0x73, 0x19, 0x91, 0x09, 0x90, 0x48, 0x84, 0x72, 0x46, 0x64, 0x28, 0x82, 0x18, 0x37, 0x27, 0x17,
    0x71, 0x55, 0x07, 0x70, 0x36, 0x63, 0x45, 0x54, 0x26, 0x62, 0x35, 0x81, 0x08, 0x80, 0x16, 0x61,
    0x06, 0x60, 0x53, 0x44, 0x25, 0x52, 0x05, 0x15, 0x51, 0x34, 0x43, 0x50, 0x24, 0x42, 0x33, 0x14,
    0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0xFF, 0xEF, 0xFE, 0xDF, 0xEE, 0xFD, 0xCF, 0xFC, 0xDE, 0xED, 0xBF, 0xFB, 0xCE, 0xEC,
    0xDD, 0xAF, 0xFA, 0xBE, 0xEB, 0xCD, 0xDC, 0x9F, 0xF9, 0xEA, 0xBD, 0xDB, 0x8F, 0xF8, 0xCC, 0x9E,
    0xE9, 0x7F, 0xF7, 0xAD, 0xDA, 0xBC, 0x6F, 0xAE, 0x0F, 0xCB, 0xF6, 0x8E, 0xE8, 0x5F, 0x9D, 0xF5,
    0x7E, 0xE7, 0xAC, 0xCA, 0xBB, 0xD9, 0x8D, 0x4F, 0xF4, 0x3F, 0xF3, 0xD8, 0xE6, 0x2F, 0xF2, 0x6E,
    0xF0, 0x1F, 0xF1, 0x9C, 0xC9, 0x5E, 0xAB, 0xBA, 0xE5, 0x7D, 0xD7, 0x4E, 0xE4, 0x8C, 0xC8, 0x3E,
    0x6D, 0xD6, 0xE3, 0x9B, 0xB9, 0x2E, 0xAA, 0xE2, 0x1E, 0xE1, 0x0E, 0xE0, 0x5D, 0xD5, 0x7C, 0xC7,
    0x4D, 0x8B, 0xD4, 0xB8, 0x9A, 0xA9, 0x6C, 0xC6, 0x3D, 0xD3, 0xD2, 0x2D, 0x0D, 0x1D, 0x7B, 0xB7,
    0xD1, 0x5C, 0xD0, 0xC5, 0x8A, 0xA8, 0x4C, 0xC4, 0x6B, 0xB6, 0x99, 0x0C, 0x3C, 0xC3, 0x7A, 0xA7,
    0xA6, 0xC0, 0x0B, 0xC2, 0x2C, 0x5B, 0xB5, 0x1C, 0x89, 0x98, 0xC1, 0x4B, 0xB4, 0x6A, 0x3B, 0x79,
    0xB3, 0x97, 0x88, 0x2B, 0x5A, 0xB2, 0xA5, 0x1B, 0xB1, 0xB0, 0x69, 0x96, 0x4A, 0xA4, 0x78, 0x87,
    0x3A, 0xA3, 0x59, 0x95, 0x2A, 0xA2, 0x1A, 0xA1, 0x0A, 0xA0, 0x68, 0x86, 0x49, 0x94, 0x39, 0x93,
    0x77, 0x09, 0x58, 0x85, 0x29, 0x67, 0x76, 0x92, 0x91, 0x19, 0x90, 0x48, 0x84, 0x57, 0x75, 0x38,
    0x83, 0x66, 0x47, 0x28, 0x82, 0x18, 0x81, 0x74, 0x08, 0x80, 0x56, 0x65, 0x37, 0x73, 0x46, 0x27,
    0x72, 0x64, 0x17, 0x55, 0x71, 0x07, 0x70, 0x36, 0x63, 0x45, 0x54, 0x26, 0x62, 0x16, 0x06, 0x60,
    0x35, 0x61, 0x53, 0x44, 0x25, 0x52, 0x15, 0x51, 0x05, 0x50, 0x34, 0x43, 0x24, 0x42, 0x33, 0x41,
    0x14, 0x04, 0x23, 0x32, 0x40, 0x03, 0x13, 0x31, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0xEF, 0xFE, 0xDF, 0xFD, 0xCF, 0xFC, 0xBF, 0xFB, 0xAF, 0xFA, 0x9F, 0xF9, 0xF8, 0x8F,
    0x7F, 0xF7, 0x6F, 0xF6, 0xFF, 0x5F, 0xF5, 0x4F, 0xF4, 0xF3, 0xF0, 0x3F, 0xCE, 0xEC, 0xDD, 0xDE,
    0xE9, 0xEA, 0xD9, 0xEE, 0xED, 0xEB, 0xBE, 0xCD, 0xDC, 0xDB, 0xAE, 0xCC, 0xAD, 0xDA, 0x7E, 0xAC,
    0xCA, 0xC9, 0x7D, 0x5E, 0xBD, 0xF2, 0x2F, 0x0F, 0x1F, 0xF1, 0x9E, 0xBC, 0xCB, 0x8E, 0xE8, 0x9D,
    0xE7, 0xBB, 0x8D, 0xD8, 0x6E, 0xE6, 0x9C, 0xAB, 0xBA, 0xE5, 0xD7, 0x4E, 0xE4, 0x8C, 0xC8, 0x3E,
    0x6D, 0xD6, 0x9B, 0xB9, 0xAA, 0xE1, 0xD4, 0xB8, 0xA9, 0x7B, 0xB7, 0xD0, 0xE3, 0x0E, 0xE0, 0x5D,
    0xD5, 0x7C, 0xC7, 0x4D, 0x8B, 0x9A, 0x6C, 0xC6, 0x3D, 0x5C, 0xC5, 0x0D, 0x8A, 0xA8, 0x99, 0x4C,
    0xB6, 0x7A, 0x3C, 0x5B, 0x89, 0x1C, 0xC0, 0x98, 0x79, 0xE2, 0x2E, 0x1E, 0xD3, 0x2D, 0xD2, 0xD1,
    0x3B, 0x97, 0x88, 0x1D, 0xC4, 0x6B, 0xC3, 0xA7, 0x2C, 0xC2, 0xB5, 0xC1, 0x0C, 0x4B, 0xB4, 0x6A,
    0xA6, 0xB3, 0x5A, 0xA5, 0x2B, 0xB2, 0x1B, 0xB1, 0x0B, 0xB0, 0x69, 0x96, 0x4A, 0xA4, 0x78, 0x87,
    0xA3, 0x3A, 0x59, 0x2A, 0x95, 0x68, 0xA1, 0x86, 0x77, 0x94, 0x49, 0x57, 0x67, 0xA2, 0x1A, 0x0A,
    0xA0, 0x39, 0x93, 0x58, 0x85, 0x29, 0x92, 0x76, 0x09, 0x19, 0x91, 0x90, 0x48, 0x84, 0x75, 0x38,
    0x83, 0x66, 0x28, 0x82, 0x47, 0x74, 0x18, 0x81, 0x80, 0x08, 0x56, 0x37, 0x73, 0x65, 0x46, 0x27,
    0x72, 0x64, 0x55, 0x07, 0x17, 0x71, 0x70, 0x36, 0x63, 0x45, 0x54, 0x26, 0x62, 0x16, 0x61, 0x06,
    0x60, 0x53, 0x35, 0x44, 0x25, 0x52, 0x51, 0x15, 0x05, 0x34, 0x43, 0x50, 0x24, 0x42, 0x33, 0x14,
    0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0xEF, 0xFE, 0xDF, 0xFD, 0xCF, 0xFC, 0xBF, 0xFB, 0xFA, 0xAF, 0x9F, 0xF9, 0xF8, 0x8F,
    0x7F, 0xF7, 0x6F, 0xF6, 0x5F, 0xF5, 0x4F, 0xF4, 0x3F, 0xF3, 0x2F, 0xF2, 0xF1, 0x1F, 0xF0, 0x0F,
    0xEE, 0xDE, 0xED, 0xCE, 0xEC, 0xDD, 0xBE, 0xEB, 0xCD, 0xDC, 0xAE, 0xEA, 0xBD, 0xDB, 0xCC, 0x9E,
    0xE9, 0xAD, 0xDA, 0xBC, 0xCB, 0x8E, 0xE8, 0x9D, 0xD9, 0x7E, 0xE7, 0xAC, 0xFF, 0xCA, 0xBB, 0x8D,
    0xD8, 0x0E, 0xE0, 0x0D, 0xE6, 0x6E, 0x9C, 0xC9, 0x5E, 0xBA, 0xE5, 0xAB, 0x7D, 0xD7, 0xE4, 0x8C,
    0xC8, 0x4E, 0x2E, 0x3E, 0x6D, 0xD6, 0xE3, 0x9B, 0xB9, 0xAA, 0xE2, 0x1E, 0xE1, 0x5D, 0xD5, 0x7C,
    0xC7, 0x4D, 0x8B, 0xB8, 0xD4, 0x9A, 0xA9, 0x6C, 0xC6, 0x3D, 0xD3, 0x2D, 0xD2, 0x1D, 0x7B, 0xB7,
    0xD1, 0x5C, 0xC5, 0x8A, 0xA8, 0x99, 0x4C, 0xC4, 0x6B, 0xB6, 0xD0, 0x0C, 0x3C, 0xC3, 0x7A, 0xA7,
    0x2C, 0xC2, 0x5B, 0xB5, 0x1C, 0x89, 0x98, 0xC1, 0x4B, 0xC0, 0x0B, 0x3B, 0xB0, 0x0A, 0x1A, 0xB4,
    0x6A, 0xA6, 0x79, 0x97, 0xA0, 0x09, 0x90, 0xB3, 0x88, 0x2B, 0x5A, 0xB2, 0xA5, 0x1B, 0xB1, 0x69,
    0x96, 0xA4, 0x4A, 0x78, 0x87, 0x3A, 0xA3, 0x59, 0x95, 0x2A, 0xA2, 0xA1, 0x68, 0x86, 0x77, 0x49,
    0x94, 0x39, 0x93, 0x58, 0x85, 0x29, 0x67, 0x76, 0x92, 0x19, 0x91, 0x48, 0x84, 0x57, 0x75, 0x38,
    0x83, 0x66, 0x28, 0x82, 0x18, 0x47, 0x74, 0x81, 0x08, 0x80, 0x56, 0x65, 0x17, 0x07, 0x70, 0x73,
    0x37, 0x27, 0x72, 0x46, 0x64, 0x55, 0x71, 0x36, 0x63, 0x45, 0x54, 0x26, 0x62, 0x16, 0x61, 0x06,
    0x60, 0x35, 0x53, 0x44, 0x25, 0x52, 0x15, 0x05, 0x50, 0x51, 0x34, 0x43, 0x24, 0x42, 0x33, 0x14,
    0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00,
};

/// A VLC table and the bits its first level reads.
pub const HuffTable = struct {
    table: []const vlc.Elem,
    bits: u5,
};

/// FFmpeg's `ff_vlc_init_from_lengths` codes for `lens`: canonical, each
/// code the previous plus one step at its length, right-aligned.
fn canonicalCodes(comptime lens: []const u8) [lens.len]u32 {
    var codes: [lens.len]u32 = undefined;
    var code: u64 = 0;
    for (lens, 0..) |len, i| {
        codes[i] = code >> (32 - len);
        code += @as(u64, 1) << (32 - len);
    }
    // The tables are complete prefix codes: every first-level entry and
    // every subtable entry is a code, so `get_vlc2` never returns -1.
    if (code != 1 << 32) @compileError("an incomplete MP3 Huffman table");
    return codes;
}

/// The VLC table `ff_vlc_init_tables_from_lengths` builds for one of the
/// 15 big-value tables (7-bit levels, a code at most three), with
/// mpegaudiodec_common_init_static's symbols: x << 5 | y, plus 16 when
/// both are nonzero.
fn bigValueTable(comptime index: usize) HuffTable {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        var start: usize = 0;
        for (huff_sizes_minus_one[0..index]) |n| start += @as(usize, n) + 1;
        const count = @as(usize, huff_sizes_minus_one[index]) + 1;
        const lens = hufflens[start..][0..count];
        const codes = canonicalCodes(lens);
        var symbols: [count]i16 = undefined;
        for (huffsymbols[start..][0..count], 0..) |sym, j| {
            const high: i16 = sym & 0xF0;
            const low: i16 = sym & 0xF;
            const both: i16 = if (high != 0 and low != 0) 1 else 0;
            symbols[j] = high << 1 | both << 4 | low;
        }
        var out: [1024]vlc.Elem = undefined;
        var work: [count]vlc.Code = undefined;
        const used = vlc.build(&out, &work, 7, lens, &codes, &symbols, .{}) catch |err| @compileError(@errorName(err));
        const table = out[0..used].*;
        break :blk .{ .table = &table, .bits = 7 };
    };
}

/// `ff_huff_vlc`: the big-value tables by `huff_data`'s first column, 1
/// to 15 (0 is no table).
pub const huff_vlc: [16]HuffTable = blk: {
    var t: [16]HuffTable = undefined;
    t[0] = .{ .table = &.{}, .bits = 7 };
    for (0..15) |i| t[i + 1] = bigValueTable(i);
    break :blk t;
};

/// `ff_huff_quad_vlc`: the count1 tables A (6-bit level) and B (4-bit),
/// symbols 0 to 15, from their codes (`vlc_init`).
pub const huff_quad_vlc: [2]HuffTable = blk: {
    @setEvalBranchQuota(20_000);
    var t: [2]HuffTable = undefined;
    for (0..2) |i| {
        const nb_bits = if (i == 0) 6 else 4;
        var codes: [16]u32 = undefined;
        for (&codes, quad_codes[i]) |*c, q| c.* = q;
        var out: [1 << nb_bits]vlc.Elem = undefined;
        var work: [16]vlc.Code = undefined;
        const used = vlc.build(&out, &work, nb_bits, &quad_bits[i], &codes, null, .{}) catch |err| @compileError(@errorName(err));
        if (used != out.len) @compileError("a count1 table with a second level");
        const table = out;
        t[i] = .{ .table = &table, .bits = nb_bits };
    }
    break :blk t;
};

/// `TABLE_4_3_SIZE`: n^(4/3) for n up to 15 plus the largest linbits
/// value, at each quarter exponent.
pub const table_4_3_size = (8191 + 16) * 4;

/// `ff_table_4_3_exp` and `ff_table_4_3_value`: (i / 4)^(4/3) / IMDCT_SCALAR
/// times 2^((i % 4) / 4) as a 31-bit mantissa and a shift, normalized to
/// FRAC_BITS (mpegaudiodec_common_tableinit).
pub const Table43 = struct {
    exp: [table_4_3_size]i8,
    value: [table_4_3_size]u32,
};

/// `exp2_lut` of both table generators: 2^(k / 4), M_SQRT2 for k = 2.
const exp2_lut = [4]f64{ 1.00000000000000000000, 1.18920711500272106672, 1.41421356237309504880, 1.68179283050742908606 };

pub const table_4_3: Table43 = blk: {
    @setEvalBranchQuota(20_000_000);
    var t: Table43 = .{ .exp = @splat(0), .value = @splat(0) };
    var pow43_val: f64 = 0;
    for (1..table_4_3_size) |i| {
        // `double value = i / 4`: the integer quotient.
        const value: f64 = @floatFromInt(i / 4);
        if (i & 3 == 0) pow43_val = value / imdct_scalar * libm.cbrt(value);
        const f = pow43_val * exp2_lut[i & 3];
        const parts = std.math.frexp(f);
        // `int m = llrint(fm * (1LL << 31))`: fm is below 1, so m is below
        // 2^31 or, rounded up, 2^31, which the int keeps as its bits.
        const m: u32 = @truncate(@as(u64, @bitCast(cconv.lrint(parts.significand * (1 << 31)))));
        const e = parts.exponent + frac_bits - 31 + 5 - 100;
        t.value[i] = m;
        t.exp[i] = -e;
    }
    break :blk t;
};

/// `expval_table_float` and `exp_table_float`: n^(4/3) * 2^(exponent / 4
/// - 72) / IMDCT_SCALAR as floats, for n below 16 and the 512 exponents
/// (mpegaudio_tableinit).
pub const ExpTables = struct {
    expval: [512][16]f32,
    /// `expval[e][1]`.
    exp: [512]f32,
};

pub const exp_tables: ExpTables = blk: {
    @setEvalBranchQuota(1_000_000);
    var pow43_lut: [16]f64 = undefined;
    for (&pow43_lut, 0..) |*p, i| {
        const x: f64 = @floatFromInt(i);
        p.* = x * libm.cbrt(x);
    }
    var t: ExpTables = undefined;
    var exp2_base: f64 = 2.11758236813575084767080625169910490512847900390625e-22; // 2^(-72)
    for (0..512) |exponent| {
        if (exponent != 0 and exponent & 3 == 0) exp2_base *= 2;
        const exp2_val = exp2_base * exp2_lut[exponent & 3] / imdct_scalar;
        for (0..16) |value| t.expval[exponent][value] = @floatCast(pow43_lut[value] * exp2_val);
        t.exp[exponent] = t.expval[exponent][1];
    }
    break :blk t;
};

/// mpegaudiodec_float.c's `is_table`: MPEG-1's intensity stereo weights
/// of the left and the right channel, by scale factor (7 used).
pub const is_table = [2][16]f32{
    .{ 0.000000000000000000e+00, 2.113248705863952637e-01, 3.660253882408142090e-01, 5.000000000000000000e-01, 6.339746117591857910e-01, 7.886751294136047363e-01, 1.000000000000000000e+00, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1.000000000000000000e+00, 7.886751294136047363e-01, 6.339746117591857910e-01, 5.000000000000000000e-01, 3.660253882408142090e-01, 2.113248705863952637e-01, 0.000000000000000000e+00, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// decode_init_static's `is_table_lsf`: MPEG-2's intensity stereo weights,
/// by the right channel's `scalefac_compress & 1`, then channel, then
/// scale factor: 2^(-(j + 1) * ((i + 1) / 2) / 4) on one side, 1 on the
/// other.
pub const is_table_lsf: [2][2][16]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [2][2][16]f32 = undefined;
    for (0..16) |i| {
        for (0..2) |j| {
            const e: i32 = -@as(i32, j + 1) * @as(i32, (i + 1) >> 1);
            const f = libm.exp2(@as(f64, @floatFromInt(e)) / 4.0);
            const k = i & 1;
            t[j][k ^ 1][i] = @floatCast(f);
            t[j][k][i] = 1.0;
        }
    }
    break :blk t;
};

/// mpegaudiodec_float.c's `csa_table`: the antialiasing butterflies' cs
/// and ca, and the fixed-point decoder's sums, which the float one does
/// not use.
pub const csa_table = [8][4]f32{
    .{ 8.574929237365722656e-01, -5.144957900047302246e-01, 3.429971337318420410e-01, -1.371988654136657715e+00 },
    .{ 8.817420005798339844e-01, -4.717319905757904053e-01, 4.100100100040435791e-01, -1.353474020957946777e+00 },
    .{ 9.496286511421203613e-01, -3.133774697780609131e-01, 6.362511515617370605e-01, -1.263006091117858887e+00 },
    .{ 9.833145737648010254e-01, -1.819131970405578613e-01, 8.014013767242431641e-01, -1.165227770805358887e+00 },
    .{ 9.955177903175354004e-01, -9.457419067621231079e-02, 9.009436368942260742e-01, -1.090092062950134277e+00 },
    .{ 9.991605877876281738e-01, -4.096558317542076111e-02, 9.581949710845947266e-01, -1.040126085281372070e+00 },
    .{ 9.998992085456848145e-01, -1.419856864959001541e-02, 9.857006072998046875e-01, -1.014097809791564941e+00 },
    .{ 9.999931454658508301e-01, -3.699974622577428818e-03, 9.962931871414184570e-01, -1.003693103790283203e+00 },
};

// --- Layers I and II (T29c) ---------------------------------------------

/// `FRAC_ONE`: 1.0 in the fixed-point scale Layers I and II compute in;
/// the float decoder keeps that scale and its synthesis window divides it
/// out, as for Layer III's tables.
const frac_one: i64 = 1 << frac_bits;

/// `ff_scale_factor_modshift`: each 6-bit scale factor as its third's
/// remainder (`& 3`) and quotient (`>> 2`).
pub const scale_factor_modshift: [64]u16 = blk: {
    var t: [64]u16 = undefined;
    for (&t, 0..) |*v, i| v.* = (i % 3) | ((i / 3) << 2);
    break :blk t;
};

/// `scale_factor_mult` (decode_init_static) as mpegaudiodec_float.c builds
/// it: `MULLx(norm, FIXR(c), FRAC_BITS)` is the single-precision product of
/// `(float)c` and the integer `norm`, stored into an `int32_t`, which
/// truncates. `norm` is 2^n * FRAC_ONE / (2^n - 1) for n = i + 2; every
/// product is positive and below 2^26, so the conversion is exact.
pub const scale_factor_mult: [15][3]i32 = blk: {
    @setEvalBranchQuota(10_000);
    const factors = [3]f64{ 1.0 * 2.0, 0.7937005259 * 2.0, 0.6299605249 * 2.0 };
    var t: [15][3]i32 = undefined;
    for (&t, 0..) |*row, i| {
        const n = i + 2;
        const norm: i64 = @divTrunc((@as(i64, 1) << n) * frac_one, (@as(i64, 1) << n) - 1);
        for (row, factors) |*v, c| {
            const product = @as(f32, @floatCast(c)) * @as(f32, @floatFromInt(norm));
            v.* = @intFromFloat(@trunc(product));
        }
    }
    break :blk t;
};

/// `scale_factor_mult2`: Layer II's group multipliers, `SCALE_GEN` of 4/3,
/// 4/5 and 4/9, each `FIXR_OLD`, `(int)(a * FRAC_ONE + 0.5)` in double.
pub const scale_factor_mult2: [3][3]i32 = blk: {
    const steps = [3]f64{ 4.0 / 3.0, 4.0 / 5.0, 4.0 / 9.0 };
    const factors = [3]f64{ 1.0, 0.7937005259, 0.6299605249 };
    var t: [3][3]i32 = undefined;
    for (&t, steps) |*row, v| {
        for (row, factors) |*out, f| out.* = @intFromFloat(@trunc(f * v * @as(f64, @floatFromInt(frac_one)) + 0.5));
    }
    break :blk t;
};

/// `ff_mpa_sblimit_table`: the subbands each allocation table codes.
pub const sblimit_table = [5]u8{ 27, 30, 8, 12, 30 };

/// `ff_mpa_quant_steps`.
pub const quant_steps = [17]u16{ 3, 5, 7, 9, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535 };

/// `ff_mpa_quant_bits`: negative for three samples coded as one group.
pub const quant_bits = [17]i8{ -5, -7, 3, -10, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

/// `alloc_table_1`: per subband, the allocation's bit count, then the
/// quantizer index of each allocation but the first.
const alloc_table_1 = [_]u8{
    4, 0, 2, 4,  5, 6, 7, 8,  9, 10, 11, 12, 13, 14, 15, 16,
    4, 0, 2, 4,  5, 6, 7, 8,  9, 10, 11, 12, 13, 14, 15, 16,
    4, 0, 2, 4,  5, 6, 7, 8,  9, 10, 11, 12, 13, 14, 15, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    4, 0, 1, 2,  3, 4, 5, 6,  7, 8,  9,  10, 11, 12, 13, 16,
    3, 0, 1, 2,  3, 4, 5, 16, 3, 0,  1,  2,  3,  4,  5,  16,
    3, 0, 1, 2,  3, 4, 5, 16, 3, 0,  1,  2,  3,  4,  5,  16,
    3, 0, 1, 2,  3, 4, 5, 16, 3, 0,  1,  2,  3,  4,  5,  16,
    3, 0, 1, 2,  3, 4, 5, 16, 3, 0,  1,  2,  3,  4,  5,  16,
    3, 0, 1, 2,  3, 4, 5, 16, 3, 0,  1,  2,  3,  4,  5,  16,
    3, 0, 1, 2,  3, 4, 5, 16, 3, 0,  1,  2,  3,  4,  5,  16,
    2, 0, 1, 16, 2, 0, 1, 16, 2, 0,  1,  16, 2,  0,  1,  16,
    2, 0, 1, 16, 2, 0, 1, 16, 2, 0,  1,  16,
};

const alloc_table_3 = [_]u8{
    4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1,  3,  4,  5,  6,  7,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1,  3,  4,  5,  6,  7,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1,  3,  4,  5,  6,  7,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1,  3,  4,  5,  6,  7,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1,  3,  4,  5,  6,  7,
};

const alloc_table_4 = [_]u8{
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3,  4,  5,  6,  7,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3,  4,  5,  6,  7,
    3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3,  4,  5,  6,  7,
    3, 0, 1, 3, 4, 5, 6, 7, 2, 0, 1, 3,  2,  0,  1,  3,
    2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,  2,  0,  1,  3,
    2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,  2,  0,  1,  3,
    2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,  2,  0,  1,  3,
    2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,  2,  0,  1,  3,
    2, 0, 1, 3,
};

/// `ff_mpa_alloc_tables`, by `l2SelectTable`.
pub const alloc_tables = [5][]const u8{ &alloc_table_1, &alloc_table_1, &alloc_table_3, &alloc_table_3, &alloc_table_4 };

/// `ff_mpa_l2_select_table`: the allocation table of a Layer II frame, from
/// its bit rate in kbit/s, channels, sample rate and version.
pub fn l2SelectTable(bitrate: u32, nb_channels: u32, freq: u32, lsf: bool) usize {
    if (lsf) return 4;
    const ch_bitrate = bitrate / nb_channels;
    if ((freq == 48000 and ch_bitrate >= 56) or (ch_bitrate >= 56 and ch_bitrate <= 80)) return 0;
    if (freq != 48000 and ch_bitrate >= 96) return 1;
    if (freq != 32000 and ch_bitrate <= 48) return 2;
    return 3;
}

/// `division_tab3`, `division_tab5`, `division_tab9`: a grouped code's three
/// samples, `val1 + (val2 << 4) + (val3 << 8)`, for every code of twice the
/// group's bits (FFmpeg's sizes; the reader gives fewer).
fn divisionTable(comptime steps: u16, comptime len: usize) [len]i16 {
    @setEvalBranchQuota(4 * len);
    var t: [len]i16 = undefined;
    for (&t, 0..) |*v, j| {
        const val1 = j % steps;
        const rest = j / steps;
        v.* = val1 + ((rest % steps) << 4) + ((rest / steps) << 8);
    }
    return t;
}

pub const division_tab3 = divisionTable(3, 1 << 6);
pub const division_tab5 = divisionTable(5, 1 << 8);
pub const division_tab9 = divisionTable(9, 1 << 11);

/// `ff_division_tabs[qindex]` for the grouped quantizers (`quant_bits`
/// negative: indexes 0, 1 and 3).
pub fn divisionTab(qindex: usize) []const i16 {
    return switch (qindex) {
        0 => &division_tab3,
        1 => &division_tab5,
        3 => &division_tab9,
        else => unreachable, // quant_bits is negative only for these
    };
}

const testing = std.testing;
const bits = @import("bits.zig");

/// `code` (its `len` bits) followed by ones, as a reader sees it.
fn codeBytes(code: u32, len: u8) [8]u8 {
    const ones: u64 = std.math.maxInt(u64);
    const shift: u6 = @intCast(64 - @as(u32, len));
    const w = (@as(u64, code) << shift) | (ones >> @intCast(len));
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, w, .big);
    return out;
}

test "every big-value code decodes MSB first to its symbol and length" {
    var start: usize = 0;
    for (huff_sizes_minus_one, 1..) |n, l| {
        const count = @as(usize, n) + 1;
        const lens = hufflens[start..][0..count];
        var code: u64 = 0;
        for (lens, huffsymbols[start..][0..count]) |len, sym| {
            const bytes = codeBytes(@intCast(code >> @intCast(32 - @as(u32, len))), len);
            var r = try bits.BitReader.init(&bytes);
            const got = vlc.lookup(bits.BitReader, huff_vlc[l].table, &r, 7, 3);
            const high: i32 = sym & 0xF0;
            const low: i32 = sym & 0xF;
            const both: i32 = if (high != 0 and low != 0) 16 else 0;
            try testing.expectEqual(high << 1 | both | low, got);
            try testing.expectEqual(len, r.count());
            code += @as(u64, 1) << @intCast(32 - len);
        }
        start += count;
    }
}

test "every count1 code decodes to its quadruple" {
    for (0..2) |t| {
        for (quad_codes[t], quad_bits[t], 0..) |code, len, sym| {
            const bytes = codeBytes(code, len);
            var r = try bits.BitReader.init(&bytes);
            try testing.expectEqual(@as(i32, @intCast(sym)), vlc.lookup(bits.BitReader, huff_quad_vlc[t].table, &r, huff_quad_vlc[t].bits, 1));
            try testing.expectEqual(len, r.count());
        }
    }
}

test "the power tables' corners" {
    // (1)^(4/3) * 2^(0/4 - 72) / 1.759 at exponent 0; 1 at exponent 288 / 1.759.
    try testing.expectEqual(@as(f32, @floatCast(0x1p-72 / imdct_scalar)), exp_tables.exp[0]);
    try testing.expectEqual(@as(f32, @floatCast(1.0 / imdct_scalar)), exp_tables.exp[288]);
    try testing.expectEqual(0, exp_tables.expval[100][0]);
    // 2^(-1/4) for scale factor 1 of the first LSF table.
    try testing.expectEqual(@as(f32, @floatCast(libm.exp2(-0.25))), is_table_lsf[0][0][1]);
    try testing.expectEqual(1, is_table_lsf[0][1][1]);
    // Entries 1 to 3 hold 0 with the exponent of a zero (-e of 103).
    try testing.expectEqual(0, table_4_3.value[1]);
    try testing.expectEqual(103, table_4_3.exp[3]);
    try testing.expectEqual(0, table_4_3.exp[0]);
}

test "Layer I's multipliers equal the single-precision products computed at run time" {
    // The table is built at compile time; the reference computes each
    // product in an f32 multiply at run time, which this repeats.
    var factors = [3]f64{ 1.0 * 2.0, 0.7937005259 * 2.0, 0.6299605249 * 2.0 };
    std.mem.doNotOptimizeAway(&factors);
    for (0..15) |i| {
        const n: u6 = @intCast(i + 2);
        var norm: i64 = @divTrunc((@as(i64, 1) << n) * frac_one, (@as(i64, 1) << n) - 1);
        std.mem.doNotOptimizeAway(&norm);
        for (0..3) |k| {
            const product = @as(f32, @floatCast(factors[k])) * @as(f32, @floatFromInt(norm));
            try testing.expectEqual(@as(i32, @intFromFloat(@trunc(product))), scale_factor_mult[i][k]);
        }
    }
    // FIXR_OLD(4/3) is 2^23 * 4 / 3 rounded: 11184811.
    try testing.expectEqual(11184811, scale_factor_mult2[0][0]);
    // 26 = 2 + 3 * (2 + 3 * 2): three samples of 2; 27 overflows into a
    // third sample of 3, as FFmpeg's table holds it.
    try testing.expectEqual(2 + (2 << 4) + (2 << 8), division_tab3[26]);
    try testing.expectEqual(3 << 8, division_tab3[27]);
}
