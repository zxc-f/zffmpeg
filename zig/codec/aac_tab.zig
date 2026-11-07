// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aactab.c (the AAC-LC tables and
// aac_tableinit), kbdwin.c (kbd_window_init), sinewin_tablegen.h
// (ff_sine_window_init), cbrt_tablegen.h (ff_cbrt_tableinit),
// cbrt_tablegen_common.c (ff_cbrt_dbl_tableinit), aac/aacdec_tab.c
// (init_base_tables) at the pinned reference revision: the constant tables transcribed value
// for value, the computed ones computed as FFmpeg computes them, in its
// precision and with the reference platform's sinf, exp and cbrt
// (core/libm.zig).
// Copyright (c) 2005-2006 Oded Shimon ( ods15 ods15 dyndns org )
// Copyright (c) 2006-2007 Maxim Gavrilov ( maxim.gavrilov gmail com )
// Copyright (c) 2009 Reimar Döffinger <Reimar.Doeffinger@gmx.de> (sinewin)
// Copyright (c) 2010 Reimar Döffinger <Reimar.Doeffinger@gmx.de> (cbrt)
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! The tables of FFmpeg's float AAC-LC decoder (TODO.md T30b), named as
//! FFmpeg's without the `ff_`/`ff_aac_` prefix: the scale factor band
//! layouts and TNS limits by sampling index, the scale factor and spectral
//! Huffman codes with their VLC lookup tables, the codebook vectors the
//! spectral symbols index, 2^(sf/4), the KBD and sine windows of the 1024
//! and 128 sample transforms and the n^(4/3) table of the escape values.
//!
//! Only the 1024/128 frame length is here: the 960, 768, 512, 480, 120 and
//! 96 sample layouts, LTP, SBR, PS and USAC's tables wait for their tasks.
//! Everything is built at compile time; FFmpeg builds the computed tables
//! once at run time (CONFIG_HARDCODED_TABLES is off in the reference
//! build). vectors/aac_tab.txt, printed from the reference build's own
//! tables by testing/reference/aac_tab_vectors.c, checks every value.

const std = @import("std");
const vlc = @import("vlc.zig");
const libm = @import("../core/libm.zig");
const bessel = @import("../core/bessel.zig");

/// The sampling frequency indexes the tables cover (96000 to 7350 Hz).
pub const sampling_index_count = 13;

/// `ff_aac_num_swb_1024`: scale factor bands of a long window, by sampling
/// index.
pub const num_swb_1024 = [13]u8{
    41, 41, 47, 49, 49, 51, 47, 47, 43, 43, 43, 40, 40,
};

/// `ff_aac_num_swb_128`: scale factor bands of a short window.
pub const num_swb_128 = [13]u8{
    12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15,
};

/// `ff_aac_pred_sfb_max`: the bands AAC Main prediction covers.
pub const pred_sfb_max = [13]u8{
    33, 33, 38, 40, 40, 40, 41, 41, 37, 37, 37, 34, 34,
};

/// `ff_tns_max_bands_1024`: the bands TNS can filter in a long window.
pub const tns_max_bands_1024 = [13]u8{
    31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39, 39,
};

/// `ff_tns_max_bands_128`: the same in a short window.
pub const tns_max_bands_128 = [13]u8{
    9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
};

/// `swb_offset_<frame length>_<rate>`: the band offsets behind
/// `swb_offset_1024` and `swb_offset_128`.
const swb_offset_1024_96 = [42]u16{
    0,   4,    8,   12,  16,  20,  24,  28,
    32,  36,   40,  44,  48,  52,  56,  64,
    72,  80,   88,  96,  108, 120, 132, 144,
    156, 172,  188, 212, 240, 276, 320, 384,
    448, 512,  576, 640, 704, 768, 832, 896,
    960, 1024,
};

const swb_offset_1024_64 = [48]u16{
    0,   4,   8,   12,  16,  20,  24,  28,
    32,  36,  40,  44,  48,  52,  56,  64,
    72,  80,  88,  100, 112, 124, 140, 156,
    172, 192, 216, 240, 268, 304, 344, 384,
    424, 464, 504, 544, 584, 624, 664, 704,
    744, 784, 824, 864, 904, 944, 984, 1024,
};

const swb_offset_1024_48 = [50]u16{
    0,   4,    8,   12,  16,  20,  24,  28,
    32,  36,   40,  48,  56,  64,  72,  80,
    88,  96,   108, 120, 132, 144, 160, 176,
    196, 216,  240, 264, 292, 320, 352, 384,
    416, 448,  480, 512, 544, 576, 608, 640,
    672, 704,  736, 768, 800, 832, 864, 896,
    928, 1024,
};

const swb_offset_1024_32 = [52]u16{
    0,   4,   8,   12,   16,  20,  24,  28,
    32,  36,  40,  48,   56,  64,  72,  80,
    88,  96,  108, 120,  132, 144, 160, 176,
    196, 216, 240, 264,  292, 320, 352, 384,
    416, 448, 480, 512,  544, 576, 608, 640,
    672, 704, 736, 768,  800, 832, 864, 896,
    928, 960, 992, 1024,
};

const swb_offset_1024_24 = [48]u16{
    0,   4,   8,   12,  16,  20,  24,  28,
    32,  36,  40,  44,  52,  60,  68,  76,
    84,  92,  100, 108, 116, 124, 136, 148,
    160, 172, 188, 204, 220, 240, 260, 284,
    308, 336, 364, 396, 432, 468, 508, 552,
    600, 652, 704, 768, 832, 896, 960, 1024,
};

const swb_offset_1024_16 = [44]u16{
    0,   8,   16,  24,   32,  40,  48,  56,
    64,  72,  80,  88,   100, 112, 124, 136,
    148, 160, 172, 184,  196, 212, 228, 244,
    260, 280, 300, 320,  344, 368, 396, 424,
    456, 492, 532, 572,  616, 664, 716, 772,
    832, 896, 960, 1024,
};

const swb_offset_1024_8 = [41]u16{
    0,    12,  24,  36,  48,  60,  72,  84,
    96,   108, 120, 132, 144, 156, 172, 188,
    204,  220, 236, 252, 268, 288, 308, 328,
    348,  372, 396, 420, 448, 476, 508, 544,
    580,  620, 664, 712, 764, 820, 880, 944,
    1024,
};

const swb_offset_128_96 = [13]u16{
    0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128,
};

const swb_offset_128_48 = [15]u16{
    0,  4,  8,  12, 16, 20,  28,  36,
    44, 56, 68, 80, 96, 112, 128,
};

const swb_offset_128_24 = [16]u16{
    0,  4,  8,  12, 16, 20, 24,  28,
    36, 44, 52, 64, 76, 92, 108, 128,
};

const swb_offset_128_16 = [16]u16{
    0,  4,  8,  12, 16, 20, 24,  28,
    32, 40, 48, 60, 72, 88, 108, 128,
};

const swb_offset_128_8 = [16]u16{
    0,  4,  8,  12, 16, 20, 24,  28,
    36, 44, 52, 60, 72, 88, 108, 128,
};

/// `tns_tmp2_map_<coef_compress>_<coef_res bits>`.
const tns_tmp2_map_0_3 = [8]f32{
    0.00000000, -0.43388373, -0.78183150, -0.97492790,
    0.98480773, 0.86602539,  0.64278758,  0.34202015,
};

const tns_tmp2_map_0_4 = [16]f32{
    0.00000000,  -0.20791170, -0.40673664, -0.58778524,
    -0.74314481, -0.86602539, -0.95105654, -0.99452192,
    0.99573416,  0.96182561,  0.89516330,  0.79801720,
    0.67369562,  0.52643216,  0.36124167,  0.18374951,
};

const tns_tmp2_map_1_3 = [4]f32{
    0.00000000, -0.43388373, 0.64278758, 0.34202015,
};

const tns_tmp2_map_1_4 = [8]f32{
    0.00000000, -0.20791170, -0.40673664, -0.58778524,
    0.67369562, 0.52643216,  0.36124167,  0.18374951,
};

/// `ff_aac_scalefactor_code`: the scale factor Huffman codewords, by
/// difference + 60.
pub const scalefactor_code = [121]u32{
    0x3ffe8, 0x3ffe6, 0x3ffe7, 0x3ffe5, 0x7fff5, 0x7fff1, 0x7ffed, 0x7fff6,
    0x7ffee, 0x7ffef, 0x7fff0, 0x7fffc, 0x7fffd, 0x7ffff, 0x7fffe, 0x7fff7,
    0x7fff8, 0x7fffb, 0x7fff9, 0x3ffe4, 0x7fffa, 0x3ffe3, 0x1ffef, 0x1fff0,
    0x0fff5, 0x1ffee, 0x0fff2, 0x0fff3, 0x0fff4, 0x0fff1, 0x07ff6, 0x07ff7,
    0x03ff9, 0x03ff5, 0x03ff7, 0x03ff3, 0x03ff6, 0x03ff2, 0x01ff7, 0x01ff5,
    0x00ff9, 0x00ff7, 0x00ff6, 0x007f9, 0x00ff4, 0x007f8, 0x003f9, 0x003f7,
    0x003f5, 0x001f8, 0x001f7, 0x000fa, 0x000f8, 0x000f6, 0x00079, 0x0003a,
    0x00038, 0x0001a, 0x0000b, 0x00004, 0x00000, 0x0000a, 0x0000c, 0x0001b,
    0x00039, 0x0003b, 0x00078, 0x0007a, 0x000f7, 0x000f9, 0x001f6, 0x001f9,
    0x003f4, 0x003f6, 0x003f8, 0x007f5, 0x007f4, 0x007f6, 0x007f7, 0x00ff5,
    0x00ff8, 0x01ff4, 0x01ff6, 0x01ff8, 0x03ff8, 0x03ff4, 0x0fff0, 0x07ff4,
    0x0fff6, 0x07ff5, 0x3ffe2, 0x7ffd9, 0x7ffda, 0x7ffdb, 0x7ffdc, 0x7ffdd,
    0x7ffde, 0x7ffd8, 0x7ffd2, 0x7ffd3, 0x7ffd4, 0x7ffd5, 0x7ffd6, 0x7fff2,
    0x7ffdf, 0x7ffe7, 0x7ffe8, 0x7ffe9, 0x7ffea, 0x7ffeb, 0x7ffe6, 0x7ffe0,
    0x7ffe1, 0x7ffe2, 0x7ffe3, 0x7ffe4, 0x7ffe5, 0x7ffd7, 0x7ffec, 0x7fff4,
    0x7fff3,
};

/// `ff_aac_scalefactor_bits`: their lengths.
pub const scalefactor_bits = [121]u8{
    18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 18, 19, 18, 17, 17, 16, 17, 16, 16, 16, 16, 15, 15,
    14, 14, 14, 14, 14, 14, 13, 13, 12, 12, 12, 11, 12, 11, 10, 10,
    10, 9,  9,  8,  8,  8,  7,  6,  6,  5,  4,  3,  1,  4,  4,  5,
    6,  6,  7,  7,  8,  8,  9,  9,  10, 10, 10, 11, 11, 11, 11, 12,
    12, 13, 13, 13, 14, 14, 16, 15, 16, 15, 18, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19,
};

/// `codes1` to `codes11` and `bits1` to `bits11`: the spectral codebooks.
const codes1 = [81]u16{
    0x7f8, 0x1f1, 0x7fd, 0x3f5, 0x068, 0x3f0, 0x7f7, 0x1ec,
    0x7f5, 0x3f1, 0x072, 0x3f4, 0x074, 0x011, 0x076, 0x1eb,
    0x06c, 0x3f6, 0x7fc, 0x1e1, 0x7f1, 0x1f0, 0x061, 0x1f6,
    0x7f2, 0x1ea, 0x7fb, 0x1f2, 0x069, 0x1ed, 0x077, 0x017,
    0x06f, 0x1e6, 0x064, 0x1e5, 0x067, 0x015, 0x062, 0x012,
    0x000, 0x014, 0x065, 0x016, 0x06d, 0x1e9, 0x063, 0x1e4,
    0x06b, 0x013, 0x071, 0x1e3, 0x070, 0x1f3, 0x7fe, 0x1e7,
    0x7f3, 0x1ef, 0x060, 0x1ee, 0x7f0, 0x1e2, 0x7fa, 0x3f3,
    0x06a, 0x1e8, 0x075, 0x010, 0x073, 0x1f4, 0x06e, 0x3f7,
    0x7f6, 0x1e0, 0x7f9, 0x3f2, 0x066, 0x1f5, 0x7ff, 0x1f7,
    0x7f4,
};

const bits1 = [81]u8{
    11, 9,  11, 10, 7,  10, 11, 9,  11, 10, 7,  10, 7,  5, 7,  9,
    7,  10, 11, 9,  11, 9,  7,  9,  11, 9,  11, 9,  7,  9, 7,  5,
    7,  9,  7,  9,  7,  5,  7,  5,  1,  5,  7,  5,  7,  9, 7,  9,
    7,  5,  7,  9,  7,  9,  11, 9,  11, 9,  7,  9,  11, 9, 11, 10,
    7,  9,  7,  5,  7,  9,  7,  10, 11, 9,  11, 10, 7,  9, 11, 9,
    11,
};

const codes2 = [81]u16{
    0x1f3, 0x06f, 0x1fd, 0x0eb, 0x023, 0x0ea, 0x1f7, 0x0e8,
    0x1fa, 0x0f2, 0x02d, 0x070, 0x020, 0x006, 0x02b, 0x06e,
    0x028, 0x0e9, 0x1f9, 0x066, 0x0f8, 0x0e7, 0x01b, 0x0f1,
    0x1f4, 0x06b, 0x1f5, 0x0ec, 0x02a, 0x06c, 0x02c, 0x00a,
    0x027, 0x067, 0x01a, 0x0f5, 0x024, 0x008, 0x01f, 0x009,
    0x000, 0x007, 0x01d, 0x00b, 0x030, 0x0ef, 0x01c, 0x064,
    0x01e, 0x00c, 0x029, 0x0f3, 0x02f, 0x0f0, 0x1fc, 0x071,
    0x1f2, 0x0f4, 0x021, 0x0e6, 0x0f7, 0x068, 0x1f8, 0x0ee,
    0x022, 0x065, 0x031, 0x002, 0x026, 0x0ed, 0x025, 0x06a,
    0x1fb, 0x072, 0x1fe, 0x069, 0x02e, 0x0f6, 0x1ff, 0x06d,
    0x1f6,
};

const bits2 = [81]u8{
    9, 7, 9, 8, 6, 8, 9, 8, 9, 8, 6, 7, 6, 5, 6, 7,
    6, 8, 9, 7, 8, 8, 6, 8, 9, 7, 9, 8, 6, 7, 6, 5,
    6, 7, 6, 8, 6, 5, 6, 5, 3, 5, 6, 5, 6, 8, 6, 7,
    6, 5, 6, 8, 6, 8, 9, 7, 9, 8, 6, 8, 8, 7, 9, 8,
    6, 7, 6, 4, 6, 8, 6, 7, 9, 7, 9, 7, 6, 8, 9, 7,
    9,
};

const codes3 = [81]u16{
    0x0000, 0x0009, 0x00ef, 0x000b, 0x0019, 0x00f0, 0x01eb, 0x01e6,
    0x03f2, 0x000a, 0x0035, 0x01ef, 0x0034, 0x0037, 0x01e9, 0x01ed,
    0x01e7, 0x03f3, 0x01ee, 0x03ed, 0x1ffa, 0x01ec, 0x01f2, 0x07f9,
    0x07f8, 0x03f8, 0x0ff8, 0x0008, 0x0038, 0x03f6, 0x0036, 0x0075,
    0x03f1, 0x03eb, 0x03ec, 0x0ff4, 0x0018, 0x0076, 0x07f4, 0x0039,
    0x0074, 0x03ef, 0x01f3, 0x01f4, 0x07f6, 0x01e8, 0x03ea, 0x1ffc,
    0x00f2, 0x01f1, 0x0ffb, 0x03f5, 0x07f3, 0x0ffc, 0x00ee, 0x03f7,
    0x7ffe, 0x01f0, 0x07f5, 0x7ffd, 0x1ffb, 0x3ffa, 0xffff, 0x00f1,
    0x03f0, 0x3ffc, 0x01ea, 0x03ee, 0x3ffb, 0x0ff6, 0x0ffa, 0x7ffc,
    0x07f2, 0x0ff5, 0xfffe, 0x03f4, 0x07f7, 0x7ffb, 0x0ff7, 0x0ff9,
    0x7ffa,
};

const bits3 = [81]u8{
    1,  4,  8,  4,  5,  8,  9,  9,  10, 4,  6,  9,  6,  6,  9,  9,
    9,  10, 9,  10, 13, 9,  9,  11, 11, 10, 12, 4,  6,  10, 6,  7,
    10, 10, 10, 12, 5,  7,  11, 6,  7,  10, 9,  9,  11, 9,  10, 13,
    8,  9,  12, 10, 11, 12, 8,  10, 15, 9,  11, 15, 13, 14, 16, 8,
    10, 14, 9,  10, 14, 12, 12, 15, 11, 12, 16, 10, 11, 15, 12, 12,
    15,
};

const codes4 = [81]u16{
    0x007, 0x016, 0x0f6, 0x018, 0x008, 0x0ef, 0x1ef, 0x0f3,
    0x7f8, 0x019, 0x017, 0x0ed, 0x015, 0x001, 0x0e2, 0x0f0,
    0x070, 0x3f0, 0x1ee, 0x0f1, 0x7fa, 0x0ee, 0x0e4, 0x3f2,
    0x7f6, 0x3ef, 0x7fd, 0x005, 0x014, 0x0f2, 0x009, 0x004,
    0x0e5, 0x0f4, 0x0e8, 0x3f4, 0x006, 0x002, 0x0e7, 0x003,
    0x000, 0x06b, 0x0e3, 0x069, 0x1f3, 0x0eb, 0x0e6, 0x3f6,
    0x06e, 0x06a, 0x1f4, 0x3ec, 0x1f0, 0x3f9, 0x0f5, 0x0ec,
    0x7fb, 0x0ea, 0x06f, 0x3f7, 0x7f9, 0x3f3, 0xfff, 0x0e9,
    0x06d, 0x3f8, 0x06c, 0x068, 0x1f5, 0x3ee, 0x1f2, 0x7f4,
    0x7f7, 0x3f1, 0xffe, 0x3ed, 0x1f1, 0x7f5, 0x7fe, 0x3f5,
    0x7fc,
};

const bits4 = [81]u8{
    4,  5,  8, 5,  4,  8,  9, 8,  11, 5,  5,  8,  5,  4,  8,  8,
    7,  10, 9, 8,  11, 8,  8, 10, 11, 10, 11, 4,  5,  8,  4,  4,
    8,  8,  8, 10, 4,  4,  8, 4,  4,  7,  8,  7,  9,  8,  8,  10,
    7,  7,  9, 10, 9,  10, 8, 8,  11, 8,  7,  10, 11, 10, 12, 8,
    7,  10, 7, 7,  9,  10, 9, 11, 11, 10, 12, 10, 9,  11, 11, 10,
    11,
};

const codes5 = [81]u16{
    0x1fff, 0x0ff7, 0x07f4, 0x07e8, 0x03f1, 0x07ee, 0x07f9, 0x0ff8,
    0x1ffd, 0x0ffd, 0x07f1, 0x03e8, 0x01e8, 0x00f0, 0x01ec, 0x03ee,
    0x07f2, 0x0ffa, 0x0ff4, 0x03ef, 0x01f2, 0x00e8, 0x0070, 0x00ec,
    0x01f0, 0x03ea, 0x07f3, 0x07eb, 0x01eb, 0x00ea, 0x001a, 0x0008,
    0x0019, 0x00ee, 0x01ef, 0x07ed, 0x03f0, 0x00f2, 0x0073, 0x000b,
    0x0000, 0x000a, 0x0071, 0x00f3, 0x07e9, 0x07ef, 0x01ee, 0x00ef,
    0x0018, 0x0009, 0x001b, 0x00eb, 0x01e9, 0x07ec, 0x07f6, 0x03eb,
    0x01f3, 0x00ed, 0x0072, 0x00e9, 0x01f1, 0x03ed, 0x07f7, 0x0ff6,
    0x07f0, 0x03e9, 0x01ed, 0x00f1, 0x01ea, 0x03ec, 0x07f8, 0x0ff9,
    0x1ffc, 0x0ffc, 0x0ff5, 0x07ea, 0x03f3, 0x03f2, 0x07f5, 0x0ffb,
    0x1ffe,
};

const bits5 = [81]u8{
    13, 12, 11, 11, 10, 11, 11, 12, 13, 12, 11, 10, 9,  8,  9,  10,
    11, 12, 12, 10, 9,  8,  7,  8,  9,  10, 11, 11, 9,  8,  5,  4,
    5,  8,  9,  11, 10, 8,  7,  4,  1,  4,  7,  8,  11, 11, 9,  8,
    5,  4,  5,  8,  9,  11, 11, 10, 9,  8,  7,  8,  9,  10, 11, 12,
    11, 10, 9,  8,  9,  10, 11, 12, 13, 12, 12, 11, 10, 10, 11, 12,
    13,
};

const codes6 = [81]u16{
    0x7fe, 0x3fd, 0x1f1, 0x1eb, 0x1f4, 0x1ea, 0x1f0, 0x3fc,
    0x7fd, 0x3f6, 0x1e5, 0x0ea, 0x06c, 0x071, 0x068, 0x0f0,
    0x1e6, 0x3f7, 0x1f3, 0x0ef, 0x032, 0x027, 0x028, 0x026,
    0x031, 0x0eb, 0x1f7, 0x1e8, 0x06f, 0x02e, 0x008, 0x004,
    0x006, 0x029, 0x06b, 0x1ee, 0x1ef, 0x072, 0x02d, 0x002,
    0x000, 0x003, 0x02f, 0x073, 0x1fa, 0x1e7, 0x06e, 0x02b,
    0x007, 0x001, 0x005, 0x02c, 0x06d, 0x1ec, 0x1f9, 0x0ee,
    0x030, 0x024, 0x02a, 0x025, 0x033, 0x0ec, 0x1f2, 0x3f8,
    0x1e4, 0x0ed, 0x06a, 0x070, 0x069, 0x074, 0x0f1, 0x3fa,
    0x7ff, 0x3f9, 0x1f6, 0x1ed, 0x1f8, 0x1e9, 0x1f5, 0x3fb,
    0x7fc,
};

const bits6 = [81]u8{
    11, 10, 9, 9, 9, 9, 9, 10, 11, 10, 9, 8, 7, 7, 7, 8,
    9,  10, 9, 8, 6, 6, 6, 6,  6,  8,  9, 9, 7, 6, 4, 4,
    4,  6,  7, 9, 9, 7, 6, 4,  4,  4,  6, 7, 9, 9, 7, 6,
    4,  4,  4, 6, 7, 9, 9, 8,  6,  6,  6, 6, 6, 8, 9, 10,
    9,  8,  7, 7, 7, 7, 8, 10, 11, 10, 9, 9, 9, 9, 9, 10,
    11,
};

const codes7 = [64]u16{
    0x000, 0x005, 0x037, 0x074, 0x0f2, 0x1eb, 0x3ed, 0x7f7,
    0x004, 0x00c, 0x035, 0x071, 0x0ec, 0x0ee, 0x1ee, 0x1f5,
    0x036, 0x034, 0x072, 0x0ea, 0x0f1, 0x1e9, 0x1f3, 0x3f5,
    0x073, 0x070, 0x0eb, 0x0f0, 0x1f1, 0x1f0, 0x3ec, 0x3fa,
    0x0f3, 0x0ed, 0x1e8, 0x1ef, 0x3ef, 0x3f1, 0x3f9, 0x7fb,
    0x1ed, 0x0ef, 0x1ea, 0x1f2, 0x3f3, 0x3f8, 0x7f9, 0x7fc,
    0x3ee, 0x1ec, 0x1f4, 0x3f4, 0x3f7, 0x7f8, 0xffd, 0xffe,
    0x7f6, 0x3f0, 0x3f2, 0x3f6, 0x7fa, 0x7fd, 0xffc, 0xfff,
};

const bits7 = [64]u8{
    1,  3, 6, 7,  8,  9,  10, 11, 3,  4,  6,  7,  8,  8,  9,  9,
    6,  6, 7, 8,  8,  9,  9,  10, 7,  7,  8,  8,  9,  9,  10, 10,
    8,  8, 9, 9,  10, 10, 10, 11, 9,  8,  9,  9,  10, 10, 11, 11,
    10, 9, 9, 10, 10, 11, 12, 12, 11, 10, 10, 10, 11, 11, 12, 12,
};

const codes8 = [64]u16{
    0x00e, 0x005, 0x010, 0x030, 0x06f, 0x0f1, 0x1fa, 0x3fe,
    0x003, 0x000, 0x004, 0x012, 0x02c, 0x06a, 0x075, 0x0f8,
    0x00f, 0x002, 0x006, 0x014, 0x02e, 0x069, 0x072, 0x0f5,
    0x02f, 0x011, 0x013, 0x02a, 0x032, 0x06c, 0x0ec, 0x0fa,
    0x071, 0x02b, 0x02d, 0x031, 0x06d, 0x070, 0x0f2, 0x1f9,
    0x0ef, 0x068, 0x033, 0x06b, 0x06e, 0x0ee, 0x0f9, 0x3fc,
    0x1f8, 0x074, 0x073, 0x0ed, 0x0f0, 0x0f6, 0x1f6, 0x1fd,
    0x3fd, 0x0f3, 0x0f4, 0x0f7, 0x1f7, 0x1fb, 0x1fc, 0x3ff,
};

const bits8 = [64]u8{
    5, 4, 5, 6, 7, 8, 9, 10, 4,  3, 4, 5, 6, 7, 7, 8,
    5, 4, 4, 5, 6, 7, 7, 8,  6,  5, 5, 6, 6, 7, 8, 8,
    7, 6, 6, 6, 7, 7, 8, 9,  8,  7, 6, 7, 7, 8, 8, 10,
    9, 7, 7, 8, 8, 8, 9, 9,  10, 8, 8, 8, 9, 9, 9, 10,
};

const codes9 = [169]u16{
    0x0000, 0x0005, 0x0037, 0x00e7, 0x01de, 0x03ce, 0x03d9, 0x07c8,
    0x07cd, 0x0fc8, 0x0fdd, 0x1fe4, 0x1fec, 0x0004, 0x000c, 0x0035,
    0x0072, 0x00ea, 0x00ed, 0x01e2, 0x03d1, 0x03d3, 0x03e0, 0x07d8,
    0x0fcf, 0x0fd5, 0x0036, 0x0034, 0x0071, 0x00e8, 0x00ec, 0x01e1,
    0x03cf, 0x03dd, 0x03db, 0x07d0, 0x0fc7, 0x0fd4, 0x0fe4, 0x00e6,
    0x0070, 0x00e9, 0x01dd, 0x01e3, 0x03d2, 0x03dc, 0x07cc, 0x07ca,
    0x07de, 0x0fd8, 0x0fea, 0x1fdb, 0x01df, 0x00eb, 0x01dc, 0x01e6,
    0x03d5, 0x03de, 0x07cb, 0x07dd, 0x07dc, 0x0fcd, 0x0fe2, 0x0fe7,
    0x1fe1, 0x03d0, 0x01e0, 0x01e4, 0x03d6, 0x07c5, 0x07d1, 0x07db,
    0x0fd2, 0x07e0, 0x0fd9, 0x0feb, 0x1fe3, 0x1fe9, 0x07c4, 0x01e5,
    0x03d7, 0x07c6, 0x07cf, 0x07da, 0x0fcb, 0x0fda, 0x0fe3, 0x0fe9,
    0x1fe6, 0x1ff3, 0x1ff7, 0x07d3, 0x03d8, 0x03e1, 0x07d4, 0x07d9,
    0x0fd3, 0x0fde, 0x1fdd, 0x1fd9, 0x1fe2, 0x1fea, 0x1ff1, 0x1ff6,
    0x07d2, 0x03d4, 0x03da, 0x07c7, 0x07d7, 0x07e2, 0x0fce, 0x0fdb,
    0x1fd8, 0x1fee, 0x3ff0, 0x1ff4, 0x3ff2, 0x07e1, 0x03df, 0x07c9,
    0x07d6, 0x0fca, 0x0fd0, 0x0fe5, 0x0fe6, 0x1feb, 0x1fef, 0x3ff3,
    0x3ff4, 0x3ff5, 0x0fe0, 0x07ce, 0x07d5, 0x0fc6, 0x0fd1, 0x0fe1,
    0x1fe0, 0x1fe8, 0x1ff0, 0x3ff1, 0x3ff8, 0x3ff6, 0x7ffc, 0x0fe8,
    0x07df, 0x0fc9, 0x0fd7, 0x0fdc, 0x1fdc, 0x1fdf, 0x1fed, 0x1ff5,
    0x3ff9, 0x3ffb, 0x7ffd, 0x7ffe, 0x1fe7, 0x0fcc, 0x0fd6, 0x0fdf,
    0x1fde, 0x1fda, 0x1fe5, 0x1ff2, 0x3ffa, 0x3ff7, 0x3ffc, 0x3ffd,
    0x7fff,
};

const bits9 = [169]u8{
    1,  3,  6,  8,  9,  10, 10, 11, 11, 12, 12, 13, 13, 3,  4,  6,
    7,  8,  8,  9,  10, 10, 10, 11, 12, 12, 6,  6,  7,  8,  8,  9,
    10, 10, 10, 11, 12, 12, 12, 8,  7,  8,  9,  9,  10, 10, 11, 11,
    11, 12, 12, 13, 9,  8,  9,  9,  10, 10, 11, 11, 11, 12, 12, 12,
    13, 10, 9,  9,  10, 11, 11, 11, 12, 11, 12, 12, 13, 13, 11, 9,
    10, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 11, 10, 10, 11, 11,
    12, 12, 13, 13, 13, 13, 13, 13, 11, 10, 10, 11, 11, 11, 12, 12,
    13, 13, 14, 13, 14, 11, 10, 11, 11, 12, 12, 12, 12, 13, 13, 14,
    14, 14, 12, 11, 11, 12, 12, 12, 13, 13, 13, 14, 14, 14, 15, 12,
    11, 12, 12, 12, 13, 13, 13, 13, 14, 14, 15, 15, 13, 12, 12, 12,
    13, 13, 13, 13, 14, 14, 14, 14, 15,
};

const codes10 = [169]u16{
    0x022, 0x008, 0x01d, 0x026, 0x05f, 0x0d3, 0x1cf, 0x3d0,
    0x3d7, 0x3ed, 0x7f0, 0x7f6, 0xffd, 0x007, 0x000, 0x001,
    0x009, 0x020, 0x054, 0x060, 0x0d5, 0x0dc, 0x1d4, 0x3cd,
    0x3de, 0x7e7, 0x01c, 0x002, 0x006, 0x00c, 0x01e, 0x028,
    0x05b, 0x0cd, 0x0d9, 0x1ce, 0x1dc, 0x3d9, 0x3f1, 0x025,
    0x00b, 0x00a, 0x00d, 0x024, 0x057, 0x061, 0x0cc, 0x0dd,
    0x1cc, 0x1de, 0x3d3, 0x3e7, 0x05d, 0x021, 0x01f, 0x023,
    0x027, 0x059, 0x064, 0x0d8, 0x0df, 0x1d2, 0x1e2, 0x3dd,
    0x3ee, 0x0d1, 0x055, 0x029, 0x056, 0x058, 0x062, 0x0ce,
    0x0e0, 0x0e2, 0x1da, 0x3d4, 0x3e3, 0x7eb, 0x1c9, 0x05e,
    0x05a, 0x05c, 0x063, 0x0ca, 0x0da, 0x1c7, 0x1ca, 0x1e0,
    0x3db, 0x3e8, 0x7ec, 0x1e3, 0x0d2, 0x0cb, 0x0d0, 0x0d7,
    0x0db, 0x1c6, 0x1d5, 0x1d8, 0x3ca, 0x3da, 0x7ea, 0x7f1,
    0x1e1, 0x0d4, 0x0cf, 0x0d6, 0x0de, 0x0e1, 0x1d0, 0x1d6,
    0x3d1, 0x3d5, 0x3f2, 0x7ee, 0x7fb, 0x3e9, 0x1cd, 0x1c8,
    0x1cb, 0x1d1, 0x1d7, 0x1df, 0x3cf, 0x3e0, 0x3ef, 0x7e6,
    0x7f8, 0xffa, 0x3eb, 0x1dd, 0x1d3, 0x1d9, 0x1db, 0x3d2,
    0x3cc, 0x3dc, 0x3ea, 0x7ed, 0x7f3, 0x7f9, 0xff9, 0x7f2,
    0x3ce, 0x1e4, 0x3cb, 0x3d8, 0x3d6, 0x3e2, 0x3e5, 0x7e8,
    0x7f4, 0x7f5, 0x7f7, 0xffb, 0x7fa, 0x3ec, 0x3df, 0x3e1,
    0x3e4, 0x3e6, 0x3f0, 0x7e9, 0x7ef, 0xff8, 0xffe, 0xffc,
    0xfff,
};

const bits10 = [169]u8{
    6,  5,  6,  6,  7,  8,  9,  10, 10, 10, 11, 11, 12, 5,  4,  4,
    5,  6,  7,  7,  8,  8,  9,  10, 10, 11, 6,  4,  5,  5,  6,  6,
    7,  8,  8,  9,  9,  10, 10, 6,  5,  5,  5,  6,  7,  7,  8,  8,
    9,  9,  10, 10, 7,  6,  6,  6,  6,  7,  7,  8,  8,  9,  9,  10,
    10, 8,  7,  6,  7,  7,  7,  8,  8,  8,  9,  10, 10, 11, 9,  7,
    7,  7,  7,  8,  8,  9,  9,  9,  10, 10, 11, 9,  8,  8,  8,  8,
    8,  9,  9,  9,  10, 10, 11, 11, 9,  8,  8,  8,  8,  8,  9,  9,
    10, 10, 10, 11, 11, 10, 9,  9,  9,  9,  9,  9,  10, 10, 10, 11,
    11, 12, 10, 9,  9,  9,  9,  10, 10, 10, 10, 11, 11, 11, 12, 11,
    10, 9,  10, 10, 10, 10, 10, 11, 11, 11, 11, 12, 11, 10, 10, 10,
    10, 10, 10, 11, 11, 12, 12, 12, 12,
};

const codes11 = [289]u16{
    0x000, 0x006, 0x019, 0x03d, 0x09c, 0x0c6, 0x1a7, 0x390,
    0x3c2, 0x3df, 0x7e6, 0x7f3, 0xffb, 0x7ec, 0xffa, 0xffe,
    0x38e, 0x005, 0x001, 0x008, 0x014, 0x037, 0x042, 0x092,
    0x0af, 0x191, 0x1a5, 0x1b5, 0x39e, 0x3c0, 0x3a2, 0x3cd,
    0x7d6, 0x0ae, 0x017, 0x007, 0x009, 0x018, 0x039, 0x040,
    0x08e, 0x0a3, 0x0b8, 0x199, 0x1ac, 0x1c1, 0x3b1, 0x396,
    0x3be, 0x3ca, 0x09d, 0x03c, 0x015, 0x016, 0x01a, 0x03b,
    0x044, 0x091, 0x0a5, 0x0be, 0x196, 0x1ae, 0x1b9, 0x3a1,
    0x391, 0x3a5, 0x3d5, 0x094, 0x09a, 0x036, 0x038, 0x03a,
    0x041, 0x08c, 0x09b, 0x0b0, 0x0c3, 0x19e, 0x1ab, 0x1bc,
    0x39f, 0x38f, 0x3a9, 0x3cf, 0x093, 0x0bf, 0x03e, 0x03f,
    0x043, 0x045, 0x09e, 0x0a7, 0x0b9, 0x194, 0x1a2, 0x1ba,
    0x1c3, 0x3a6, 0x3a7, 0x3bb, 0x3d4, 0x09f, 0x1a0, 0x08f,
    0x08d, 0x090, 0x098, 0x0a6, 0x0b6, 0x0c4, 0x19f, 0x1af,
    0x1bf, 0x399, 0x3bf, 0x3b4, 0x3c9, 0x3e7, 0x0a8, 0x1b6,
    0x0ab, 0x0a4, 0x0aa, 0x0b2, 0x0c2, 0x0c5, 0x198, 0x1a4,
    0x1b8, 0x38c, 0x3a4, 0x3c4, 0x3c6, 0x3dd, 0x3e8, 0x0ad,
    0x3af, 0x192, 0x0bd, 0x0bc, 0x18e, 0x197, 0x19a, 0x1a3,
    0x1b1, 0x38d, 0x398, 0x3b7, 0x3d3, 0x3d1, 0x3db, 0x7dd,
    0x0b4, 0x3de, 0x1a9, 0x19b, 0x19c, 0x1a1, 0x1aa, 0x1ad,
    0x1b3, 0x38b, 0x3b2, 0x3b8, 0x3ce, 0x3e1, 0x3e0, 0x7d2,
    0x7e5, 0x0b7, 0x7e3, 0x1bb, 0x1a8, 0x1a6, 0x1b0, 0x1b2,
    0x1b7, 0x39b, 0x39a, 0x3ba, 0x3b5, 0x3d6, 0x7d7, 0x3e4,
    0x7d8, 0x7ea, 0x0ba, 0x7e8, 0x3a0, 0x1bd, 0x1b4, 0x38a,
    0x1c4, 0x392, 0x3aa, 0x3b0, 0x3bc, 0x3d7, 0x7d4, 0x7dc,
    0x7db, 0x7d5, 0x7f0, 0x0c1, 0x7fb, 0x3c8, 0x3a3, 0x395,
    0x39d, 0x3ac, 0x3ae, 0x3c5, 0x3d8, 0x3e2, 0x3e6, 0x7e4,
    0x7e7, 0x7e0, 0x7e9, 0x7f7, 0x190, 0x7f2, 0x393, 0x1be,
    0x1c0, 0x394, 0x397, 0x3ad, 0x3c3, 0x3c1, 0x3d2, 0x7da,
    0x7d9, 0x7df, 0x7eb, 0x7f4, 0x7fa, 0x195, 0x7f8, 0x3bd,
    0x39c, 0x3ab, 0x3a8, 0x3b3, 0x3b9, 0x3d0, 0x3e3, 0x3e5,
    0x7e2, 0x7de, 0x7ed, 0x7f1, 0x7f9, 0x7fc, 0x193, 0xffd,
    0x3dc, 0x3b6, 0x3c7, 0x3cc, 0x3cb, 0x3d9, 0x3da, 0x7d3,
    0x7e1, 0x7ee, 0x7ef, 0x7f5, 0x7f6, 0xffc, 0xfff, 0x19d,
    0x1c2, 0x0b5, 0x0a1, 0x096, 0x097, 0x095, 0x099, 0x0a0,
    0x0a2, 0x0ac, 0x0a9, 0x0b1, 0x0b3, 0x0bb, 0x0c0, 0x18f,
    0x004,
};

const bits11 = [289]u8{
    4,  5,  6,  7,  8,  8,  9,  10, 10, 10, 11, 11, 12, 11, 12, 12,
    10, 5,  4,  5,  6,  7,  7,  8,  8,  9,  9,  9,  10, 10, 10, 10,
    11, 8,  6,  5,  5,  6,  7,  7,  8,  8,  8,  9,  9,  9,  10, 10,
    10, 10, 8,  7,  6,  6,  6,  7,  7,  8,  8,  8,  9,  9,  9,  10,
    10, 10, 10, 8,  8,  7,  7,  7,  7,  8,  8,  8,  8,  9,  9,  9,
    10, 10, 10, 10, 8,  8,  7,  7,  7,  7,  8,  8,  8,  9,  9,  9,
    9,  10, 10, 10, 10, 8,  9,  8,  8,  8,  8,  8,  8,  8,  9,  9,
    9,  10, 10, 10, 10, 10, 8,  9,  8,  8,  8,  8,  8,  8,  9,  9,
    9,  10, 10, 10, 10, 10, 10, 8,  10, 9,  8,  8,  9,  9,  9,  9,
    9,  10, 10, 10, 10, 10, 10, 11, 8,  10, 9,  9,  9,  9,  9,  9,
    9,  10, 10, 10, 10, 10, 10, 11, 11, 8,  11, 9,  9,  9,  9,  9,
    9,  10, 10, 10, 10, 10, 11, 10, 11, 11, 8,  11, 10, 9,  9,  10,
    9,  10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 8,  11, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 9,  11, 10, 9,
    9,  10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 9,  11, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 9,  12,
    10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 12, 12, 9,
    9,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  9,
    5,
};

/// `ff_aac_spectral_sizes`: the codewords of each spectral codebook.
pub const spectral_sizes = [11]u16{
    81, 81, 81, 81, 81, 81, 64, 64, 169, 169, 289,
};

/// `codebook_vector0_vals`: codebooks 1 and 2.
const codebook_vector0_vals = [3]f32{
    -1.0000000, 0.0000000, 1.0000000,
};

/// `codebook_vector02_idx`, codebooks 1 to 4: bits 0:1, 2:3, 4:5, 6:7 index
/// the values, 8:11 count the nonzero values, 12:15 mask them.
const codebook_vector02_idx = [81]u16{
    0x0000, 0x8140, 0x8180, 0x4110, 0xc250, 0xc290, 0x4120, 0xc260, 0xc2a0,
    0x2104, 0xa244, 0xa284, 0x6214, 0xe354, 0xe394, 0x6224, 0xe364, 0xe3a4,
    0x2108, 0xa248, 0xa288, 0x6218, 0xe358, 0xe398, 0x6228, 0xe368, 0xe3a8,
    0x1101, 0x9241, 0x9281, 0x5211, 0xd351, 0xd391, 0x5221, 0xd361, 0xd3a1,
    0x3205, 0xb345, 0xb385, 0x7315, 0xf455, 0xf495, 0x7325, 0xf465, 0xf4a5,
    0x3209, 0xb349, 0xb389, 0x7319, 0xf459, 0xf499, 0x7329, 0xf469, 0xf4a9,
    0x1102, 0x9242, 0x9282, 0x5212, 0xd352, 0xd392, 0x5222, 0xd362, 0xd3a2,
    0x3206, 0xb346, 0xb386, 0x7316, 0xf456, 0xf496, 0x7326, 0xf466, 0xf4a6,
    0x320a, 0xb34a, 0xb38a, 0x731a, 0xf45a, 0xf49a, 0x732a, 0xf46a, 0xf4aa,
};

/// `codebook_vector4_vals`: codebooks 5 and 6.
const codebook_vector4_vals = [9]f32{
    -6.3496042, -4.3267487,
    -2.5198421, -1.0000000,
    0.0000000,  1.0000000,
    2.5198421,  4.3267487,
    6.3496042,
};

/// `codebook_vector4_idx`, codebooks 5 and 6: bits 0:3 and 4:7 index the
/// values.
const codebook_vector4_idx = [81]u16{
    0x0000, 0x0010, 0x0020, 0x0030, 0x0040, 0x0050, 0x0060, 0x0070, 0x0080,
    0x0001, 0x0011, 0x0021, 0x0031, 0x0041, 0x0051, 0x0061, 0x0071, 0x0081,
    0x0002, 0x0012, 0x0022, 0x0032, 0x0042, 0x0052, 0x0062, 0x0072, 0x0082,
    0x0003, 0x0013, 0x0023, 0x0033, 0x0043, 0x0053, 0x0063, 0x0073, 0x0083,
    0x0004, 0x0014, 0x0024, 0x0034, 0x0044, 0x0054, 0x0064, 0x0074, 0x0084,
    0x0005, 0x0015, 0x0025, 0x0035, 0x0045, 0x0055, 0x0065, 0x0075, 0x0085,
    0x0006, 0x0016, 0x0026, 0x0036, 0x0046, 0x0056, 0x0066, 0x0076, 0x0086,
    0x0007, 0x0017, 0x0027, 0x0037, 0x0047, 0x0057, 0x0067, 0x0077, 0x0087,
    0x0008, 0x0018, 0x0028, 0x0038, 0x0048, 0x0058, 0x0068, 0x0078, 0x0088,
};

/// `codebook_vector6_idx`, codebooks 7 and 8: bits 0:3 and 4:7 index the
/// values, 8:11 count the nonzero values, 12:15 are 1 when only the second
/// is nonzero.
const codebook_vector6_idx = [64]u16{
    0x0000, 0x0110, 0x0120, 0x0130, 0x0140, 0x0150, 0x0160, 0x0170,
    0x1101, 0x0211, 0x0221, 0x0231, 0x0241, 0x0251, 0x0261, 0x0271,
    0x1102, 0x0212, 0x0222, 0x0232, 0x0242, 0x0252, 0x0262, 0x0272,
    0x1103, 0x0213, 0x0223, 0x0233, 0x0243, 0x0253, 0x0263, 0x0273,
    0x1104, 0x0214, 0x0224, 0x0234, 0x0244, 0x0254, 0x0264, 0x0274,
    0x1105, 0x0215, 0x0225, 0x0235, 0x0245, 0x0255, 0x0265, 0x0275,
    0x1106, 0x0216, 0x0226, 0x0236, 0x0246, 0x0256, 0x0266, 0x0276,
    0x1107, 0x0217, 0x0227, 0x0237, 0x0247, 0x0257, 0x0267, 0x0277,
};

/// `codebook_vector8_idx`, codebooks 9 and 10: the same layout.
const codebook_vector8_idx = [169]u16{
    0x0000, 0x0110, 0x0120, 0x0130, 0x0140, 0x0150, 0x0160,
    0x0170, 0x0180, 0x0190, 0x01a0, 0x01b0, 0x01c0, 0x1101,
    0x0211, 0x0221, 0x0231, 0x0241, 0x0251, 0x0261, 0x0271,
    0x0281, 0x0291, 0x02a1, 0x02b1, 0x02c1, 0x1102, 0x0212,
    0x0222, 0x0232, 0x0242, 0x0252, 0x0262, 0x0272, 0x0282,
    0x0292, 0x02a2, 0x02b2, 0x02c2, 0x1103, 0x0213, 0x0223,
    0x0233, 0x0243, 0x0253, 0x0263, 0x0273, 0x0283, 0x0293,
    0x02a3, 0x02b3, 0x02c3, 0x1104, 0x0214, 0x0224, 0x0234,
    0x0244, 0x0254, 0x0264, 0x0274, 0x0284, 0x0294, 0x02a4,
    0x02b4, 0x02c4, 0x1105, 0x0215, 0x0225, 0x0235, 0x0245,
    0x0255, 0x0265, 0x0275, 0x0285, 0x0295, 0x02a5, 0x02b5,
    0x02c5, 0x1106, 0x0216, 0x0226, 0x0236, 0x0246, 0x0256,
    0x0266, 0x0276, 0x0286, 0x0296, 0x02a6, 0x02b6, 0x02c6,
    0x1107, 0x0217, 0x0227, 0x0237, 0x0247, 0x0257, 0x0267,
    0x0277, 0x0287, 0x0297, 0x02a7, 0x02b7, 0x02c7, 0x1108,
    0x0218, 0x0228, 0x0238, 0x0248, 0x0258, 0x0268, 0x0278,
    0x0288, 0x0298, 0x02a8, 0x02b8, 0x02c8, 0x1109, 0x0219,
    0x0229, 0x0239, 0x0249, 0x0259, 0x0269, 0x0279, 0x0289,
    0x0299, 0x02a9, 0x02b9, 0x02c9, 0x110a, 0x021a, 0x022a,
    0x023a, 0x024a, 0x025a, 0x026a, 0x027a, 0x028a, 0x029a,
    0x02aa, 0x02ba, 0x02ca, 0x110b, 0x021b, 0x022b, 0x023b,
    0x024b, 0x025b, 0x026b, 0x027b, 0x028b, 0x029b, 0x02ab,
    0x02bb, 0x02cb, 0x110c, 0x021c, 0x022c, 0x023c, 0x024c,
    0x025c, 0x026c, 0x027c, 0x028c, 0x029c, 0x02ac, 0x02bc,
    0x02cc,
};

/// `codebook_vector10_vals`: codebooks 3, 4 and 7 to 11.
const codebook_vector10_vals = [16]f32{
    0.0000000,  1.0000000,
    2.5198421,  4.3267487,
    6.3496042,  8.5498797,
    10.9027236, 13.3905183,
    16.0000000, 18.7207544,
    21.5443469, 24.4637810,
    27.4731418, 30.5673509,
    33.7419917, 36.9931811,
};

/// `codebook_vector10_idx`, codebook 11: bits 0:3 and 4:7 index the values,
/// 8:9 mask the escape-coded entries, 12:15 count the nonzero values.
const codebook_vector10_idx = [289]u16{
    0x0000, 0x1010, 0x1020, 0x1030, 0x1040, 0x1050, 0x1060, 0x1070,
    0x1080, 0x1090, 0x10a0, 0x10b0, 0x10c0, 0x10d0, 0x10e0, 0x10f0,
    0x1200, 0x1001, 0x2011, 0x2021, 0x2031, 0x2041, 0x2051, 0x2061,
    0x2071, 0x2081, 0x2091, 0x20a1, 0x20b1, 0x20c1, 0x20d1, 0x20e1,
    0x20f1, 0x2201, 0x1002, 0x2012, 0x2022, 0x2032, 0x2042, 0x2052,
    0x2062, 0x2072, 0x2082, 0x2092, 0x20a2, 0x20b2, 0x20c2, 0x20d2,
    0x20e2, 0x20f2, 0x2202, 0x1003, 0x2013, 0x2023, 0x2033, 0x2043,
    0x2053, 0x2063, 0x2073, 0x2083, 0x2093, 0x20a3, 0x20b3, 0x20c3,
    0x20d3, 0x20e3, 0x20f3, 0x2203, 0x1004, 0x2014, 0x2024, 0x2034,
    0x2044, 0x2054, 0x2064, 0x2074, 0x2084, 0x2094, 0x20a4, 0x20b4,
    0x20c4, 0x20d4, 0x20e4, 0x20f4, 0x2204, 0x1005, 0x2015, 0x2025,
    0x2035, 0x2045, 0x2055, 0x2065, 0x2075, 0x2085, 0x2095, 0x20a5,
    0x20b5, 0x20c5, 0x20d5, 0x20e5, 0x20f5, 0x2205, 0x1006, 0x2016,
    0x2026, 0x2036, 0x2046, 0x2056, 0x2066, 0x2076, 0x2086, 0x2096,
    0x20a6, 0x20b6, 0x20c6, 0x20d6, 0x20e6, 0x20f6, 0x2206, 0x1007,
    0x2017, 0x2027, 0x2037, 0x2047, 0x2057, 0x2067, 0x2077, 0x2087,
    0x2097, 0x20a7, 0x20b7, 0x20c7, 0x20d7, 0x20e7, 0x20f7, 0x2207,
    0x1008, 0x2018, 0x2028, 0x2038, 0x2048, 0x2058, 0x2068, 0x2078,
    0x2088, 0x2098, 0x20a8, 0x20b8, 0x20c8, 0x20d8, 0x20e8, 0x20f8,
    0x2208, 0x1009, 0x2019, 0x2029, 0x2039, 0x2049, 0x2059, 0x2069,
    0x2079, 0x2089, 0x2099, 0x20a9, 0x20b9, 0x20c9, 0x20d9, 0x20e9,
    0x20f9, 0x2209, 0x100a, 0x201a, 0x202a, 0x203a, 0x204a, 0x205a,
    0x206a, 0x207a, 0x208a, 0x209a, 0x20aa, 0x20ba, 0x20ca, 0x20da,
    0x20ea, 0x20fa, 0x220a, 0x100b, 0x201b, 0x202b, 0x203b, 0x204b,
    0x205b, 0x206b, 0x207b, 0x208b, 0x209b, 0x20ab, 0x20bb, 0x20cb,
    0x20db, 0x20eb, 0x20fb, 0x220b, 0x100c, 0x201c, 0x202c, 0x203c,
    0x204c, 0x205c, 0x206c, 0x207c, 0x208c, 0x209c, 0x20ac, 0x20bc,
    0x20cc, 0x20dc, 0x20ec, 0x20fc, 0x220c, 0x100d, 0x201d, 0x202d,
    0x203d, 0x204d, 0x205d, 0x206d, 0x207d, 0x208d, 0x209d, 0x20ad,
    0x20bd, 0x20cd, 0x20dd, 0x20ed, 0x20fd, 0x220d, 0x100e, 0x201e,
    0x202e, 0x203e, 0x204e, 0x205e, 0x206e, 0x207e, 0x208e, 0x209e,
    0x20ae, 0x20be, 0x20ce, 0x20de, 0x20ee, 0x20fe, 0x220e, 0x100f,
    0x201f, 0x202f, 0x203f, 0x204f, 0x205f, 0x206f, 0x207f, 0x208f,
    0x209f, 0x20af, 0x20bf, 0x20cf, 0x20df, 0x20ef, 0x20ff, 0x220f,
    0x1100, 0x2110, 0x2120, 0x2130, 0x2140, 0x2150, 0x2160, 0x2170,
    0x2180, 0x2190, 0x21a0, 0x21b0, 0x21c0, 0x21d0, 0x21e0, 0x21f0,
    0x2300,
};

/// `ff_swb_offset_1024`: by sampling index, the first coefficient of each
/// scale factor band of a long window, `num_swb_1024[i] + 1` entries.
pub const swb_offset_1024 = [sampling_index_count][]const u16{
    &swb_offset_1024_96, &swb_offset_1024_96, &swb_offset_1024_64,
    &swb_offset_1024_48, &swb_offset_1024_48, &swb_offset_1024_32,
    &swb_offset_1024_24, &swb_offset_1024_24, &swb_offset_1024_16,
    &swb_offset_1024_16, &swb_offset_1024_16, &swb_offset_1024_8,
    &swb_offset_1024_8,
};

/// `ff_swb_offset_128`: the same for a short window, `num_swb_128[i] + 1`
/// entries (64 kHz shares 96 kHz's layout).
pub const swb_offset_128 = [sampling_index_count][]const u16{
    &swb_offset_128_96, &swb_offset_128_96, &swb_offset_128_96,
    &swb_offset_128_48, &swb_offset_128_48, &swb_offset_128_48,
    &swb_offset_128_24, &swb_offset_128_24, &swb_offset_128_16,
    &swb_offset_128_16, &swb_offset_128_16, &swb_offset_128_8,
    &swb_offset_128_8,
};

/// `ff_tns_tmp2_map`: TNS's dequantized reflection coefficients by
/// `2 * coef_compress + coef_res`, coef_res the bit that selects 3 or 4
/// bit coefficients.
pub const tns_tmp2_map = [4][]const f32{
    &tns_tmp2_map_0_3,
    &tns_tmp2_map_0_4,
    &tns_tmp2_map_1_3,
    &tns_tmp2_map_1_4,
};

/// `ff_aac_spectral_codes`: the codewords of spectral codebooks 1 to 11.
pub const spectral_codes = [11][]const u16{
    &codes1, &codes2,  &codes3,  &codes4, &codes5, &codes6, &codes7, &codes8,
    &codes9, &codes10, &codes11,
};

/// `ff_aac_spectral_bits`: their lengths.
pub const spectral_bits = [11][]const u8{
    &bits1, &bits2,  &bits3,  &bits4, &bits5, &bits6, &bits7, &bits8,
    &bits9, &bits10, &bits11,
};

/// `ff_aac_codebook_vector_vals`: the dequantized values (cube roots of the
/// magnitudes, signed for the signed codebooks) the symbols of each
/// spectral codebook index.
pub const codebook_vector_vals = [11][]const f32{
    &codebook_vector0_vals,  &codebook_vector0_vals,
    &codebook_vector10_vals, &codebook_vector10_vals,
    &codebook_vector4_vals,  &codebook_vector4_vals,
    &codebook_vector10_vals, &codebook_vector10_vals,
    &codebook_vector10_vals, &codebook_vector10_vals,
    &codebook_vector10_vals,
};

/// `ff_aac_codebook_vector_idx`: by codebook and codeword, the packed
/// value indexes, nonzero counts and sign or escape masks the spectral
/// VLC tables return as symbols (see each array's layout comment).
pub const codebook_vector_idx = [11][]const u16{
    &codebook_vector02_idx, &codebook_vector02_idx,
    &codebook_vector02_idx, &codebook_vector02_idx,
    &codebook_vector4_idx,  &codebook_vector4_idx,
    &codebook_vector6_idx,  &codebook_vector6_idx,
    &codebook_vector8_idx,  &codebook_vector8_idx,
    &codebook_vector10_idx,
};

/// `POW_SF2_ZERO`: the index of 2^0 in `pow2sf_tab`.
pub const pow2sf_zero = 200;

/// `ff_aac_pow2sf_tab`: 2^((i - POW_SF2_ZERO) / 4) as aac_tableinit
/// builds it, from 2^(-50) doubled in single precision and a 16-entry
/// single-precision table of 2^(k/16), not from pow.
pub const pow2sf_tab: [428]f32 = blk: {
    @setEvalBranchQuota(10_000);
    // exp2_lut: 2^(i/16), double literals stored as floats.
    const exp2_lut = [16]f32{
        1.00000000000000000000, 1.04427378242741384032,
        1.09050773266525765921, 1.13878863475669165370,
        1.18920711500272106672, 1.24185781207348404859,
        1.29683955465100966593, 1.35425554693689272830,
        1.41421356237309504880, 1.47682614593949931139,
        1.54221082540794082361, 1.61049033194925430818,
        1.68179283050742908606, 1.75625216037329948311,
        1.83400808640934246349, 1.91520656139714729387,
    };
    var t: [428]f32 = undefined;
    var t1: f32 = 8.8817841970012523233890533447265625e-16; // 2^(-50)
    var t1_inc_prev: usize = 0;
    for (&t, 0..) |*p, i| {
        const t1_inc_cur = 4 * (i % 4);
        if (t1_inc_cur < t1_inc_prev) t1 *= 2;
        p.* = t1 * exp2_lut[t1_inc_cur];
        t1_inc_prev = t1_inc_cur;
    }
    break :blk t;
};

/// `ff_kbd_window_init` (kbd_window_init's float path): the Kaiser-Bessel
/// derived window of `n` points, summed and scaled in double precision and
/// stored as floats. `alpha` is the C function's float parameter.
fn kbdWindow(comptime n: usize, comptime alpha: f32) [n]f32 {
    @setEvalBranchQuota(100 * n);
    var temp: [n / 2 + 1]f64 = undefined;
    const nd: f64 = n;
    const a: f64 = alpha;
    const alpha2 = 4 * (a * std.math.pi / nd) * (a * std.math.pi / nd);
    var scale: f64 = 0;
    for (&temp, 0..) |*t, i| {
        // The C's int product i * (n - i), then the double.
        const prod: f64 = @floatFromInt(i * (n - i));
        t.* = bessel.besselI0(@sqrt(prod * alpha2));
        const weight: f64 = if (i != 0 and i < n / 2) 2 else 1;
        scale += t.* * weight;
    }
    scale = 1.0 / (scale + 1);
    var window: [n]f32 = undefined;
    var sum: f64 = 0;
    for (window[0 .. n / 2 + 1], 0..) |*w, i| {
        sum += temp[i];
        w.* = @floatCast(@sqrt(sum * scale));
    }
    for (window[n / 2 + 1 ..], n / 2 + 1..) |*w, i| {
        sum += temp[n - i];
        w.* = @floatCast(@sqrt(sum * scale));
    }
    return window;
}

/// `ff_aac_kbd_long_1024`: the long KBD window, alpha 4.
pub const kbd_long_1024: [1024]f32 = kbdWindow(1024, 4.0);

/// `ff_aac_kbd_short_128`: the short KBD window, alpha 6.
pub const kbd_short_128: [128]f32 = kbdWindow(128, 6.0);

/// `ff_sine_window_init`: sinf((i + 0.5) * (pi / (2n))), the argument
/// computed in double and rounded to the float sinf takes.
fn sineWindow(comptime n: usize) [n]f32 {
    @setEvalBranchQuota(100 * n);
    var window: [n]f32 = undefined;
    const step: f64 = std.math.pi / (2.0 * @as(f64, n));
    for (&window, 0..) |*w, i| {
        const fi: f64 = @floatFromInt(i);
        const arg: f32 = @floatCast((fi + 0.5) * step);
        w.* = libm.sinf(arg);
    }
    return window;
}

/// `ff_sine_1024`: the long sine window.
pub const sine_1024: [1024]f32 = sineWindow(1024);

/// `ff_sine_128`: the short sine window.
pub const sine_128: [128]f32 = sineWindow(128);

/// `LUT_SIZE`: the entries of `cbrt_tab`, 0 to 8191.
pub const cbrt_lut_size = 1 << 13;

/// `ff_cbrt_tab` (ff_cbrt_tableinit's float build): n^(4/3) as the bits
/// of a float, for the escape values. FFmpeg multiplies the double
/// (2k + 1)^(4/3) of every odd number together from its prime factors'
/// i * cbrt(i) (ff_cbrt_dbl_tableinit), then reaches each n = 2^j (2k + 1)
/// by repeated multiplication by 2 * cbrt(2), rounding each to float; the
/// results are not those of pow or of n * cbrt(n). FFmpeg keeps the double
/// table in the same memory as the float one (a union, filled from the top
/// so no double is overwritten before it is read); two arrays give the
/// same values.
pub const cbrt_tab: [cbrt_lut_size]u32 = blk: {
    @setEvalBranchQuota(1_000_000);
    const tmp_lut_size = cbrt_lut_size / 2;
    // tmp_lut[idx]: (2 * idx + 1)^(4/3).
    var tmp: [tmp_lut_size]f64 = @splat(1);
    // Non-squarefree numbers: the odd primes up to sqrt(LUT_SIZE) and their
    // powers (idx 44 is 89).
    for (1..45) |idx| {
        if (tmp[idx] != 1) continue;
        const i = 2 * idx + 1;
        const fi: f64 = @floatFromInt(i);
        const cbrt_val = fi * libm.cbrt(fi);
        var k = i;
        while (k < cbrt_lut_size) : (k *= i) {
            var idx2 = k >> 1;
            while (idx2 < tmp_lut_size) : (idx2 += k) tmp[idx2] *= cbrt_val;
        }
    }
    for (45..tmp_lut_size) |idx| {
        if (tmp[idx] != 1) continue;
        const i = 2 * idx + 1;
        const fi: f64 = @floatFromInt(i);
        const cbrt_val = fi * libm.cbrt(fi);
        var idx2 = idx;
        while (idx2 < tmp_lut_size) : (idx2 += i) tmp[idx2] *= cbrt_val;
    }

    var tab: [cbrt_lut_size]u32 = undefined;
    const cbrt_2 = 2 * libm.cbrt(2.0);
    var idx: usize = tmp_lut_size;
    while (idx > 0) {
        idx -= 1;
        var cbrt_val = tmp[idx];
        var i = 2 * idx + 1;
        while (i < cbrt_lut_size) : (i *= 2) {
            const f: f32 = @floatCast(cbrt_val);
            tab[i] = @bitCast(f);
            cbrt_val *= cbrt_2;
        }
    }
    tab[0] = 0; // CBRT(0)
    break :blk tab;
};

/// The bits the first level of a spectral VLC table reads; codes reach at
/// most two levels (`get_vlc2(gb, vlc_tab, 8, 2)`).
pub const spectral_vlc_bits = 8;

/// The scale factor table's first level (`get_vlc2(gb, ff_vlc_scalefactors,
/// 7, 3)`).
pub const scalefactor_vlc_bits = 7;

/// init_base_tables' `ff_vlc_init_tables_sparse` call for spectral
/// codebook `index + 1`: the codewords and lengths above, symbols from
/// `codebook_vector_idx` stored in the int16 symbol (FFmpeg's uint16
/// read into VLCBaseType: 0x8140 becomes -32448).
fn spectralTable(comptime index: usize) []const vlc.Elem {
    return comptime blk: {
        @setEvalBranchQuota(400_000);
        const count = spectral_sizes[index];
        var codes: [count]u32 = undefined;
        for (&codes, spectral_codes[index]) |*c, code| c.* = code;
        var symbols: [count]i16 = undefined;
        for (&symbols, codebook_vector_idx[index]) |*s, idx| s.* = @bitCast(idx);
        var out: [1024]vlc.Elem = undefined;
        var work: [count]vlc.Code = undefined;
        const used = vlc.build(&out, &work, spectral_vlc_bits, spectral_bits[index], &codes, &symbols, .{}) catch |err| @compileError(@errorName(err));
        const table = out[0..used].*;
        break :blk &table;
    };
}

/// `ff_vlc_spectral`: the VLC tables of spectral codebooks 1 to 11, each as
/// long as FFmpeg's (304, 270, 550, 300, 328, 294, 306, 268, 510, 366 and
/// 462 entries in init_base_tables' buffer).
pub const spectral_vlc: [11][]const vlc.Elem = blk: {
    var t: [11][]const vlc.Elem = undefined;
    for (0..11) |i| t[i] = spectralTable(i);
    break :blk t;
};

/// `ff_vlc_scalefactors`: the scale factor differences' VLC table,
/// symbols 0 to 120 (60 is no change), filling its 352 entries exactly.
pub const scalefactor_vlc: [352]vlc.Elem = blk: {
    @setEvalBranchQuota(200_000);
    var out: [352]vlc.Elem = undefined;
    var work: [scalefactor_code.len]vlc.Code = undefined;
    const used = vlc.build(&out, &work, scalefactor_vlc_bits, &scalefactor_bits, &scalefactor_code, null, .{}) catch |err| @compileError(@errorName(err));
    if (used != out.len) @compileError("ff_vlc_scalefactors is not filled exactly");
    break :blk out;
};

const testing = std.testing;
const bits = @import("bits.zig");
const vectors = @embedFile("../testing/vectors/aac_tab.txt");

/// aac_tab_vectors.c's text: `name [index] values...`.
const Text = struct {
    w: *std.Io.Writer,

    fn start(t: Text, name: []const u8, index: ?usize) !void {
        try t.w.writeAll(name);
        if (index) |i| try t.w.print(" {d}", .{i});
    }

    fn ints(t: Text, name: []const u8, index: ?usize, comptime T: type, values: []const T) !void {
        try t.start(name, index);
        for (values) |v| try t.w.print(" {d}", .{v});
        try t.w.writeAll("\n");
    }

    fn floats(t: Text, name: []const u8, index: ?usize, values: []const f32) !void {
        try t.start(name, index);
        for (values) |v| try t.w.print(" {x:0>8}", .{@as(u32, @bitCast(v))});
        try t.w.writeAll("\n");
    }

    fn table(t: Text, name: []const u8, index: ?usize, elems: []const vlc.Elem) !void {
        try t.start(name, index);
        try t.w.print(" {d}", .{elems.len});
        for (elems) |e| try t.w.print(" {d},{d}", .{ e.sym, e.len });
        try t.w.writeAll("\n");
    }
};

fn render(w: *std.Io.Writer) !void {
    const t: Text = .{ .w = w };
    try t.ints("num_swb_1024", null, u8, &num_swb_1024);
    try t.ints("num_swb_128", null, u8, &num_swb_128);
    try t.ints("pred_sfb_max", null, u8, &pred_sfb_max);
    try t.ints("tns_max_bands_1024", null, u8, &tns_max_bands_1024);
    try t.ints("tns_max_bands_128", null, u8, &tns_max_bands_128);
    for (swb_offset_1024, num_swb_1024, 0..) |offsets, n, i| try t.ints("swb_offset_1024", i, u16, offsets[0 .. @as(usize, n) + 1]);
    for (swb_offset_128, num_swb_128, 0..) |offsets, n, i| try t.ints("swb_offset_128", i, u16, offsets[0 .. @as(usize, n) + 1]);
    for (tns_tmp2_map, 0..) |map, i| try t.floats("tns_tmp2_map", i, map);
    try t.ints("scalefactor_code", null, u32, &scalefactor_code);
    try t.ints("scalefactor_bits", null, u8, &scalefactor_bits);
    try t.ints("spectral_sizes", null, u16, &spectral_sizes);
    for (spectral_codes, 0..) |codes, i| try t.ints("spectral_codes", i, u16, codes);
    for (spectral_bits, 0..) |lens, i| try t.ints("spectral_bits", i, u8, lens);
    for (codebook_vector_vals, 0..) |vals, i| try t.floats("codebook_vector_vals", i, vals);
    for (codebook_vector_idx, 0..) |idx, i| try t.ints("codebook_vector_idx", i, u16, idx);
    try t.floats("pow2sf_tab", null, &pow2sf_tab);
    try t.floats("kbd_long_1024", null, &kbd_long_1024);
    try t.floats("kbd_short_128", null, &kbd_short_128);
    try t.floats("sine_1024", null, &sine_1024);
    try t.floats("sine_128", null, &sine_128);
    try t.start("cbrt_tab", null);
    for (cbrt_tab) |v| try w.print(" {x:0>8}", .{v});
    try w.writeAll("\n");
    for (spectral_vlc, 0..) |table, i| try t.table("spectral_vlc", i, table);
    try t.table("scalefactor_vlc", null, &scalefactor_vlc);
}

test "every table equals FFmpeg's (vectors/aac_tab.txt)" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(&out.writer);
    try testing.expectEqualStrings(vectors, out.written());
}

/// `code` (its `len` bits) followed by ones, as a reader sees it.
fn codeBytes(code: u32, len: u8) [8]u8 {
    const ones: u64 = std.math.maxInt(u64);
    const shift: u6 = @intCast(64 - @as(u32, len));
    const word = (@as(u64, code) << shift) | (ones >> @intCast(len));
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, word, .big);
    return out;
}

test "every spectral and scale factor code decodes to its symbol and length" {
    for (spectral_vlc, spectral_codes, spectral_bits, codebook_vector_idx) |table, codes, lens, idx| {
        for (codes, lens, idx) |code, len, sym| {
            const bytes = codeBytes(code, len);
            var r = try bits.BitReader.init(&bytes);
            const expected: i16 = @bitCast(sym);
            try testing.expectEqual(expected, vlc.lookup(bits.BitReader, table, &r, spectral_vlc_bits, 2));
            try testing.expectEqual(len, r.count());
        }
    }
    for (scalefactor_code, scalefactor_bits, 0..) |code, len, sym| {
        const bytes = codeBytes(code, len);
        var r = try bits.BitReader.init(&bytes);
        const expected: i32 = @intCast(sym);
        try testing.expectEqual(expected, vlc.lookup(bits.BitReader, &scalefactor_vlc, &r, scalefactor_vlc_bits, 3));
        try testing.expectEqual(len, r.count());
    }
}
