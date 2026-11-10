// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from libavcodec/pcm_tablegen.h at FFmpeg commit
// 5d5a38a7e46be296eab75982c0986054f731e19e:
//   Copyright (c) 2010 Reimar Döffinger <Reimar.Doeffinger@gmx.de>
//   Header file for hardcoded PCM tables; part of FFmpeg, LGPL-2.1-or-later.
// Its A-law and mu-law conversions come "from g711.c by SUN microsystems
// (unrestricted use)". The algorithm is restated in Zig; tables are built at
// compile time instead of at first use.
//! G.711 A-law and mu-law: 8-bit companded codes to signed 16-bit linear
//! samples and back (TODO.md T20b), with FFmpeg's exact tables.
//!
//! Decoding is a 256-entry table. Encoding indexes a 16384-entry table with
//! the top 14 bits of the sample, `(v + 32768) >> 2`, built from the decoding
//! curve so that each code covers the samples nearest to it, as FFmpeg does.

const std = @import("std");

const sign_bit = 0x80;
const quant_mask = 0xf;
const seg_shift = 4;
const seg_mask = 0x70;
/// The bias of mu-law's linear code.
const bias = 0x84;

fn alawToLinear(code: u8) i16 {
    const a = code ^ 0x55;
    var t: i32 = a & quant_mask;
    const seg: u5 = (a & seg_mask) >> seg_shift;
    if (seg != 0) {
        t = (t + t + 1 + 32) << (seg + 2);
    } else {
        t = (t + t + 1) << 3;
    }
    // The largest magnitude is (15 + 15 + 1 + 32) << 9 = 32256, within i16.
    return if (a & sign_bit != 0) t else -t;
}

fn mulawToLinear(code: u8) i16 {
    const u = ~code;
    var t: i32 = ((u & quant_mask) << 3) + bias;
    const seg: u5 = (u & seg_mask) >> seg_shift;
    t <<= seg;
    return if (u & sign_bit != 0) bias - t else t - bias;
}

fn decodeTable(comptime toLinear: fn (u8) i16) [256]i16 {
    var table: [256]i16 = undefined;
    for (&table, 0..) |*entry, code| entry.* = toLinear(code);
    return table;
}

/// FFmpeg's `build_xlaw_table`: entry `8192 ± j` is the code for linear
/// values near `±j * 4`, switching code where the curve passes the midpoint
/// between two neighboring codes.
fn encodeTable(comptime toLinear: fn (u8) i16, comptime mask: u8) [16384]u8 {
    @setEvalBranchQuota(200_000);
    var table: [16384]u8 = undefined;
    table[8192] = mask;
    var j: usize = 1;
    for (0..127) |i| {
        const code: u8 = i;
        const v1: i32 = toLinear(code ^ mask);
        const v2: i32 = toLinear((code + 1) ^ mask);
        const v: i32 = (v1 + v2 + 4) >> 3;
        while (j < v) : (j += 1) {
            table[8192 - j] = code ^ (mask ^ 0x80);
            table[8192 + j] = code ^ mask;
        }
    }
    while (j < 8192) : (j += 1) {
        table[8192 - j] = 127 ^ (mask ^ 0x80);
        table[8192 + j] = 127 ^ mask;
    }
    table[0] = table[1];
    return table;
}

const alaw_decode = decodeTable(alawToLinear);
const mulaw_decode = decodeTable(mulawToLinear);
const alaw_encode = encodeTable(alawToLinear, 0xd5);
const mulaw_encode = encodeTable(mulawToLinear, 0xff);

pub fn decodeAlaw(code: u8) i16 {
    return alaw_decode[code];
}

pub fn decodeMulaw(code: u8) i16 {
    return mulaw_decode[code];
}

/// The table index of a sample: its top 14 bits, offset to be unsigned.
fn index(sample: i16) u14 {
    const offset: u16 = @bitCast(sample);
    return @intCast((offset ^ 0x8000) >> 2);
}

pub fn encodeAlaw(sample: i16) u8 {
    return alaw_encode[index(sample)];
}

pub fn encodeMulaw(sample: i16) u8 {
    return mulaw_encode[index(sample)];
}

test "the decoding curves have G.711's endpoints and symmetry" {
    // A-law 0xd5 and 0x55 are the smallest magnitudes, 0xaa and 0x2a the largest.
    try std.testing.expectEqual(8, decodeAlaw(0xd5));
    try std.testing.expectEqual(-8, decodeAlaw(0x55));
    try std.testing.expectEqual(32256, decodeAlaw(0xaa));
    try std.testing.expectEqual(-32256, decodeAlaw(0x2a));
    // mu-law 0xff and 0x7f are zero, 0x80 and 0x00 the extremes.
    try std.testing.expectEqual(0, decodeMulaw(0xff));
    try std.testing.expectEqual(0, decodeMulaw(0x7f));
    try std.testing.expectEqual(32124, decodeMulaw(0x80));
    try std.testing.expectEqual(-32124, decodeMulaw(0x00));
    for (0..128) |code| {
        try std.testing.expectEqual(-decodeAlaw(@intCast(code)), decodeAlaw(@intCast(code | 0x80)));
        try std.testing.expectEqual(-decodeMulaw(@intCast(code)), decodeMulaw(@intCast(code | 0x80)));
    }
}

test "the table index takes the top 14 bits of the offset sample" {
    try std.testing.expectEqual(0, index(-32768));
    try std.testing.expectEqual(8192, index(0));
    try std.testing.expectEqual(16383, index(32767));
    try std.testing.expectEqual(8191, index(-1));
}
