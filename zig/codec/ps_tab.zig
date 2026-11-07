// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aacpsdata.c (huff_sizes,
// aacps_huff_tabs, huff_offset, ff_k_to_i_20, ff_k_to_i_34) and
// aacps_common.c (ff_ps_init_common) at the pinned reference revision, the
// values transcribed by a script.
// Copyright (c) 2010 Alex Converse <alex.converse@gmail.com>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! The bitstream tables of FFmpeg's parametric stereo decoder (TODO.md
//! T30d): the ten Huffman codes of the IID, ICC, IPD and OPD data with the
//! VLC tables `ff_ps_init_common` builds (9-bit levels for the IID and ICC
//! codes, 5-bit for the others), and the maps from hybrid subbands to
//! parameter bands. Built at compile time.

const vlc = @import("vlc.zig");

/// `ff_k_to_i_20`: the parameter band of each of the 71 hybrid subbands.
pub const k_to_i_20 = [71]u8{
    1,  0,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 14, 15,
    15, 15, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 18,
    18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
};

/// `ff_k_to_i_34`: the parameter band of each of the 91 hybrid subbands.
pub const k_to_i_34 = [91]u8{
    0,  1,  2,  3,  4,  5,  6,  6,  7,  2,  1,  0,  10, 10, 4,  5,  6,  7,  8,
    9,  10, 11, 12, 9,  14, 11, 12, 13, 14, 15, 16, 13, 16, 17, 18, 19, 20, 21,
    22, 22, 23, 23, 24, 24, 25, 25, 26, 26, 27, 27, 27, 28, 28, 28, 29, 29, 29,
    30, 30, 30, 31, 31, 31, 31, 32, 32, 32, 32, 33, 33, 33, 33, 33, 33, 33, 33,
    33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33,
};

/// `aacps_huff_tabs`: each code's symbol and length, the ten codes one
/// after another (`huff_sizes`).
const huff_tabs = [_][2]u8{
    .{ 28, 4 },  .{ 32, 4 },  .{ 29, 3 },  .{ 31, 3 },  .{ 27, 5 },  .{ 33, 5 },
    .{ 26, 6 },  .{ 34, 6 },  .{ 25, 7 },  .{ 35, 7 },  .{ 24, 8 },  .{ 36, 8 },
    .{ 37, 9 },  .{ 40, 11 }, .{ 19, 12 }, .{ 41, 12 }, .{ 22, 10 }, .{ 38, 10 },
    .{ 9, 17 },  .{ 51, 17 }, .{ 11, 17 }, .{ 49, 17 }, .{ 13, 16 }, .{ 47, 16 },
    .{ 16, 14 }, .{ 18, 13 }, .{ 42, 13 }, .{ 44, 14 }, .{ 12, 17 }, .{ 48, 17 },
    .{ 4, 18 },  .{ 5, 18 },  .{ 2, 18 },  .{ 3, 18 },  .{ 15, 15 }, .{ 21, 11 },
    .{ 39, 11 }, .{ 45, 15 }, .{ 8, 18 },  .{ 52, 18 }, .{ 6, 18 },  .{ 7, 18 },
    .{ 55, 18 }, .{ 56, 18 }, .{ 53, 18 }, .{ 54, 18 }, .{ 17, 14 }, .{ 43, 14 },
    .{ 59, 18 }, .{ 60, 18 }, .{ 57, 18 }, .{ 58, 18 }, .{ 0, 18 },  .{ 1, 18 },
    .{ 10, 18 }, .{ 50, 18 }, .{ 14, 16 }, .{ 46, 16 }, .{ 20, 12 }, .{ 23, 10 },
    .{ 30, 1 },  .{ 31, 2 },  .{ 26, 7 },  .{ 34, 7 },  .{ 27, 6 },  .{ 33, 6 },
    .{ 35, 8 },  .{ 24, 9 },  .{ 36, 9 },  .{ 39, 11 }, .{ 41, 12 }, .{ 9, 15 },
    .{ 10, 15 }, .{ 48, 15 }, .{ 49, 15 }, .{ 17, 13 }, .{ 23, 10 }, .{ 37, 10 },
    .{ 43, 13 }, .{ 11, 15 }, .{ 12, 15 }, .{ 4, 16 },  .{ 56, 16 }, .{ 2, 16 },
    .{ 3, 16 },  .{ 59, 16 }, .{ 60, 16 }, .{ 57, 16 }, .{ 58, 16 }, .{ 0, 16 },
    .{ 1, 16 },  .{ 5, 16 },  .{ 55, 16 }, .{ 6, 16 },  .{ 54, 16 }, .{ 13, 15 },
    .{ 15, 14 }, .{ 20, 12 }, .{ 40, 12 }, .{ 22, 11 }, .{ 38, 11 }, .{ 45, 14 },
    .{ 47, 15 }, .{ 7, 16 },  .{ 53, 16 }, .{ 18, 13 }, .{ 42, 13 }, .{ 16, 14 },
    .{ 44, 14 }, .{ 8, 16 },  .{ 52, 16 }, .{ 14, 15 }, .{ 46, 15 }, .{ 50, 16 },
    .{ 51, 16 }, .{ 19, 13 }, .{ 21, 12 }, .{ 25, 9 },  .{ 28, 5 },  .{ 32, 5 },
    .{ 29, 3 },  .{ 30, 1 },  .{ 14, 1 },  .{ 15, 3 },  .{ 13, 3 },  .{ 16, 4 },
    .{ 12, 4 },  .{ 17, 5 },  .{ 11, 5 },  .{ 10, 6 },  .{ 18, 6 },  .{ 19, 6 },
    .{ 9, 7 },   .{ 20, 8 },  .{ 8, 9 },   .{ 7, 10 },  .{ 21, 11 }, .{ 22, 13 },
    .{ 6, 13 },  .{ 23, 14 }, .{ 24, 14 }, .{ 5, 15 },  .{ 25, 15 }, .{ 4, 16 },
    .{ 3, 17 },  .{ 0, 17 },  .{ 1, 17 },  .{ 2, 17 },  .{ 26, 17 }, .{ 27, 18 },
    .{ 28, 18 }, .{ 14, 1 },  .{ 13, 2 },  .{ 15, 3 },  .{ 12, 4 },  .{ 16, 5 },
    .{ 11, 6 },  .{ 17, 7 },  .{ 10, 8 },  .{ 18, 9 },  .{ 9, 10 },  .{ 19, 11 },
    .{ 8, 12 },  .{ 20, 13 }, .{ 21, 14 }, .{ 7, 15 },  .{ 22, 17 }, .{ 6, 17 },
    .{ 23, 19 }, .{ 0, 19 },  .{ 1, 19 },  .{ 2, 19 },  .{ 3, 20 },  .{ 4, 20 },
    .{ 5, 20 },  .{ 24, 20 }, .{ 25, 20 }, .{ 26, 20 }, .{ 27, 20 }, .{ 28, 20 },
    .{ 7, 1 },   .{ 8, 2 },   .{ 6, 3 },   .{ 9, 4 },   .{ 5, 5 },   .{ 10, 6 },
    .{ 4, 7 },   .{ 11, 8 },  .{ 12, 9 },  .{ 3, 10 },  .{ 13, 11 }, .{ 2, 12 },
    .{ 14, 13 }, .{ 1, 14 },  .{ 0, 14 },  .{ 7, 1 },   .{ 8, 2 },   .{ 6, 3 },
    .{ 9, 4 },   .{ 5, 5 },   .{ 10, 6 },  .{ 4, 7 },   .{ 11, 8 },  .{ 3, 9 },
    .{ 12, 10 }, .{ 2, 11 },  .{ 13, 12 }, .{ 1, 13 },  .{ 0, 14 },  .{ 14, 14 },
    .{ 1, 3 },   .{ 4, 4 },   .{ 5, 4 },   .{ 3, 4 },   .{ 6, 4 },   .{ 2, 4 },
    .{ 7, 4 },   .{ 0, 1 },   .{ 5, 4 },   .{ 4, 5 },   .{ 3, 5 },   .{ 2, 4 },
    .{ 6, 4 },   .{ 1, 3 },   .{ 7, 3 },   .{ 0, 1 },   .{ 7, 3 },   .{ 1, 3 },
    .{ 3, 4 },   .{ 6, 4 },   .{ 2, 4 },   .{ 5, 5 },   .{ 4, 5 },   .{ 0, 1 },
    .{ 5, 4 },   .{ 2, 4 },   .{ 6, 4 },   .{ 4, 5 },   .{ 3, 5 },   .{ 1, 3 },
    .{ 7, 3 },   .{ 0, 1 },
};

const huff_sizes = [10]u8{ 61, 61, 29, 29, 15, 15, 8, 8, 8, 8 };
const huff_offset = [10]i8{ -30, -30, -14, -14, -7, -7, 0, 0, 0, 0 };

/// The codes, in `vlc_ps`'s order.
pub const Huff = enum(u4) { iid_df1, iid_dt1, iid_df0, iid_dt0, icc_df, icc_dt, ipd_df, ipd_dt, opd_df, opd_dt };

/// The levels each table's first lookup reads.
pub fn vlcBits(h: Huff) u5 {
    return if (@backingInt(h) <= 5) 9 else 5;
}

/// `vlc_ps`: built as `ff_vlc_init_tables_from_lengths` builds them, the
/// canonical codes of the lengths in each table's order, each symbol plus
/// the table's offset.
pub const huff_vlc: [10][]const vlc.Elem = blk: {
    @setEvalBranchQuota(200_000);
    var tables: [10][]const vlc.Elem = undefined;
    var start: usize = 0;
    for (0..10) |t| {
        const count = huff_sizes[t];
        var lens: [count]u8 = undefined;
        var symbols: [count]i16 = undefined;
        var codes: [count]u32 = undefined;
        var code: u64 = 0;
        for (0..count) |i| {
            lens[i] = huff_tabs[start + i][1];
            symbols[i] = @as(i16, huff_tabs[start + i][0]) + huff_offset[t];
            codes[i] = @intCast(code >> (32 - lens[i]));
            code += @as(u64, 1) << (32 - lens[i]);
        }
        if (code != 1 << 32) @compileError("an incomplete PS Huffman code");
        var out: [2048]vlc.Elem = undefined;
        var work: [count]vlc.Code = undefined;
        const nb_bits = if (t <= 5) 9 else 5;
        const used = vlc.build(&out, &work, nb_bits, &lens, &codes, &symbols, .{}) catch |err| @compileError(@errorName(err));
        const table = out[0..used].*;
        tables[t] = &table;
        start += count;
    }
    break :blk tables;
};
