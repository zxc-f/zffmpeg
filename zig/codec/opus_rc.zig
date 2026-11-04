// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/opus/rc.c and rc.h at the pinned
// reference revision (the decoding half: ff_opus_rc_dec_init,
// opus_rc_dec_normalize, opus_rc_dec_update, ff_opus_rc_dec_cdf,
// ff_opus_rc_dec_log, ff_opus_rc_get_raw, ff_opus_rc_dec_uint,
// ff_opus_rc_dec_uint_step, ff_opus_rc_dec_uint_tri,
// ff_opus_rc_dec_laplace, ff_opus_rc_dec_raw_init, opus_rc_tell and
// opus_rc_tell_frac) and libavcodec/mathops.h's ff_sqrt.
// Copyright (c) 2012 Andrew D'Addesio
// Copyright (c) 2013-2014 Mozilla Corporation
// Copyright (c) 2017 Rostislav Pehlivanov <atomnuker@gmail.com>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! Opus' range decoder (RFC 6716 section 4.1, TODO.md T28a) as FFmpeg's
//! decoder runs it: symbols from the front of a frame, raw bits from its
//! end backwards (CELT), and the bit counts the codecs' allocation reads.
//! Reads past either end give zeros, as FFmpeg's padded buffers do; no read
//! leaves the slice.

const std = @import("std");
const bits = @import("bits.zig");

const sym = 8;
const ceil: u32 = (1 << sym) - 1;
const top: u32 = 1 << 31;
const bot: u32 = top >> sym;

/// av_log2 of a nonzero value.
fn log2(x: u32) u32 {
    return std.math.log2_int(u32, x);
}

/// opus_ilog: the bits of `i` (0 for 0).
pub fn ilog(i: u32) u32 {
    return if (i == 0) 0 else log2(i) + 1;
}

pub const RangeDecoder = struct {
    gb: bits.BitReader,
    /// The raw bits, read from the end of the frame backwards.
    raw_bytes: []const u8 = &.{},
    /// FFmpeg's `rb.position`: the next raw byte is the one before it.
    raw_pos: usize = 0,
    /// FFmpeg's `rb.bytes`: how many raw bytes may still be read.
    raw_left: u32 = 0,
    raw_cachelen: u32 = 0,
    raw_cacheval: u32 = 0,
    range: u32,
    value: u32,
    total_bits: u32,

    /// ff_opus_rc_dec_init over a frame's bytes.
    pub fn init(data: []const u8) error{InputTooLarge}!RangeDecoder {
        var rc: RangeDecoder = .{ .gb = try .init(data), .range = 128, .value = 0, .total_bits = 9 };
        rc.value = 127 - rc.gb.bits(7);
        rc.normalize();
        return rc;
    }

    /// ff_opus_rc_dec_raw_init: raw bits from the end of `frame` backwards,
    /// `bytes` of them at most.
    pub fn initRaw(rc: *RangeDecoder, frame: []const u8, bytes: u32) void {
        rc.raw_bytes = frame;
        rc.raw_pos = frame.len;
        rc.raw_left = bytes;
        rc.raw_cachelen = 0;
        rc.raw_cacheval = 0;
    }

    fn normalize(rc: *RangeDecoder) void {
        while (rc.range <= bot) {
            rc.value = ((rc.value << sym) | (rc.gb.bits(sym) ^ ceil)) & (top - 1);
            rc.range <<= sym;
            rc.total_bits +%= sym;
        }
    }

    fn update(rc: *RangeDecoder, scale: u32, low: u32, high: u32, total: u32) void {
        rc.value -%= scale *% (total -% high);
        rc.range = if (low != 0) scale *% (high -% low) else rc.range -% scale *% (total -% high);
        rc.normalize();
    }

    /// opus_rc_tell: the bits used so far, rounded up.
    pub fn tell(rc: *const RangeDecoder) u32 {
        return rc.total_bits -% log2(rc.range) -% 1;
    }

    /// opus_rc_tell_frac: the bits used so far in eighths.
    pub fn tellFrac(rc: *const RangeDecoder) u32 {
        const total = rc.total_bits << 3;
        var rcbuffer = log2(rc.range) + 1;
        var range = rc.range >> @intCast(rcbuffer - 16);
        for (0..3) |_| {
            range = range *% range >> 15;
            const bit = range >> 16;
            rcbuffer = rcbuffer << 1 | bit;
            range >>= @intCast(bit);
        }
        return total -% rcbuffer;
    }

    /// ff_opus_rc_dec_cdf: a symbol of `cdf` (its total, then each
    /// symbol's cumulative frequency).
    pub fn cdf(rc: *RangeDecoder, table: []const u16) u32 {
        const total: u32 = table[0];
        const c = table[1..];
        const scale = rc.range / total;
        var symbol = rc.value / scale + 1;
        symbol = total - @min(symbol, total);
        var k: usize = 0;
        while (c[k] <= symbol) k += 1;
        const high: u32 = c[k];
        const low: u32 = if (k != 0) c[k - 1] else 0;
        rc.update(scale, low, high, total);
        return @intCast(k);
    }

    /// ff_opus_rc_dec_log: a bit whose probability of 1 is 1 / 2^bits.
    pub fn log(rc: *RangeDecoder, n: u5) u32 {
        const scale = rc.range >> n;
        var k: u32 = undefined;
        if (rc.value >= scale) {
            rc.value -= scale;
            rc.range -= scale;
            k = 0;
        } else {
            rc.range = scale;
            k = 1;
        }
        rc.normalize();
        return k;
    }

    /// ff_opus_rc_get_raw: `count` (0 to 25) raw bits from the frame's end;
    /// zeros once its bytes run out, as FFmpeg's counter wraps.
    pub fn raw(rc: *RangeDecoder, count: u32) u32 {
        while (rc.raw_left != 0 and rc.raw_cachelen < count) {
            rc.raw_left -= 1;
            // A budget past the frame's start reads zeros.
            const byte: u32 = if (rc.raw_pos > 0) rc.raw_bytes[rc.raw_pos - 1] else 0;
            if (rc.raw_pos > 0) rc.raw_pos -= 1;
            rc.raw_cacheval |= byte << @intCast(rc.raw_cachelen);
            rc.raw_cachelen += 8;
        }
        const value = if (count >= 32) rc.raw_cacheval else rc.raw_cacheval & ((@as(u32, 1) << @intCast(count)) - 1);
        rc.raw_cacheval = if (count >= 32) 0 else rc.raw_cacheval >> @intCast(count);
        rc.raw_cachelen -%= count;
        rc.total_bits +%= count;
        return value;
    }

    /// ff_opus_rc_dec_uint: uniform on [0, size), the bits above 8 raw.
    pub fn uint(rc: *RangeDecoder, size: u32) u32 {
        const b = ilog(size - 1);
        const total = if (b > 8) ((size - 1) >> @intCast(b - 8)) + 1 else size;
        const scale = rc.range / total;
        var k = rc.value / scale + 1;
        k = total - @min(k, total);
        rc.update(scale, k, k + 1, total);
        if (b > 8) {
            k = k << @intCast(b - 8) | rc.raw(b - 8);
            return @min(k, size - 1);
        }
        return k;
    }

    /// ff_opus_rc_dec_uint_step: probability 3 up to k0, then 1.
    pub fn uintStep(rc: *RangeDecoder, k0: u32) u32 {
        const total = (k0 + 1) * 3 + k0;
        const scale = rc.range / total;
        var symbol = rc.value / scale + 1;
        symbol = total - @min(symbol, total);
        const k = if (symbol < (k0 + 1) * 3) symbol / 3 else symbol - (k0 + 1) * 2;
        const low = if (k <= k0) 3 * k else (k - 1 - k0) + 3 * (k0 + 1);
        const high = if (k <= k0) 3 * (k + 1) else (k - k0) + 3 * (k0 + 1);
        rc.update(scale, low, high, total);
        return k;
    }

    /// ff_opus_rc_dec_uint_tri: a triangular distribution over [0, qn].
    pub fn uintTri(rc: *RangeDecoder, qn: u32) u32 {
        const half = (qn >> 1) + 1;
        const total = half * half;
        const scale = rc.range / total;
        var center = rc.value / scale + 1;
        center = total - @min(center, total);
        var k: u32 = undefined;
        var low: u32 = undefined;
        var symbol: u32 = undefined;
        if (center < total >> 1) {
            k = (sqrt(8 * center + 1) - 1) >> 1;
            low = k * (k + 1) >> 1;
            symbol = k + 1;
        } else {
            k = (2 * (qn + 1) - sqrt(8 * (total - center - 1) + 1)) >> 1;
            low = total - ((qn + 1 - k) * (qn + 2 - k) >> 1);
            symbol = qn + 1 - k;
        }
        rc.update(scale, low, low + symbol, total);
        return k;
    }

    /// ff_opus_rc_dec_laplace: a Laplace-distributed integer whose zero has
    /// frequency `symbol` (of 32768) and whose tail decays by `decay`.
    pub fn laplace(rc: *RangeDecoder, symbol_in: u32, decay: i32) i32 {
        var value: i32 = 0;
        var symbol = symbol_in;
        var low: u32 = 0;
        const scale = rc.range >> 15;
        var center = rc.value / scale + 1;
        center = (1 << 15) - @min(center, 1 << 15);
        if (center >= symbol) {
            value += 1;
            low = symbol;
            symbol = 1 + ((32768 - 32 - symbol) *% @as(u32, @intCast(16384 - decay)) >> 15);
            while (symbol > 1 and center >= low + 2 * symbol) {
                value += 1;
                symbol *= 2;
                low += symbol;
                symbol = (((symbol - 2) *% @as(u32, @intCast(decay))) >> 15) + 1;
            }
            if (symbol <= 1) {
                const distance: u32 = (center - low) >> 1;
                value += @intCast(distance);
                low += 2 * distance;
            }
            if (center < low + symbol) {
                value *= -1;
            } else low += symbol;
        }
        rc.update(scale, low, @min(low + symbol, 32768), 32768);
        return value;
    }
};

/// ff_sqrt: the integer square root, rounded down.
fn sqrt(a: u32) u32 {
    return std.math.sqrt(a);
}

const testing = std.testing;

test "ilog counts the bits of a value" {
    try testing.expectEqual(0, ilog(0));
    try testing.expectEqual(1, ilog(1));
    try testing.expectEqual(8, ilog(255));
    try testing.expectEqual(9, ilog(256));
}

const vectors = @embedFile("../testing/vectors/opus_rc.txt");

/// opus_rc_vectors.c's generator.
const Generator = struct {
    state: u32,

    fn next(g: *Generator) u32 {
        g.state = g.state *% 1103515245 +% 12345;
        return g.state >> 16;
    }
};

test "the range decoder reads as FFmpeg's does (vectors/opus_rc.txt)" {
    const cdf_a = [_]u16{ 32, 4, 12, 20, 28, 32 };
    const cdf_b = [_]u16{ 256, 1, 128, 255, 256 };
    const cdf_c = [_]u16{ 128, 64, 96, 112, 120, 124, 126, 127, 128 };
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next();
        const seed = try std.fmt.parseInt(u32, f.next().?, 10);
        const size = try std.fmt.parseInt(usize, f.next().?, 10);
        const ops = try std.fmt.parseInt(usize, f.next().?, 10);
        var g: Generator = .{ .state = seed };
        var frame: [1275]u8 = undefined;
        for (frame[0..size]) |*b| b.* = @truncate(g.next());
        var rc = try RangeDecoder.init(frame[0..size]);
        rc.initRaw(frame[0..size], @intCast(size));
        var md5: std.crypto.hash.Md5 = .init(.{});
        const put = struct {
            fn put(h: *std.crypto.hash.Md5, v: anytype) void {
                var le: [4]u8 = undefined;
                std.mem.writeInt(u32, &le, @bitCast(@as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, v)))))))), .little);
                h.update(&le);
            }
        }.put;
        for (0..ops) |_| {
            switch (g.next() % 8) {
                0 => {
                    const t = g.next() % 3;
                    put(&md5, rc.cdf(if (t == 0) &cdf_a else if (t == 1) &cdf_b else &cdf_c));
                },
                1 => put(&md5, rc.log(@intCast(g.next() % 15 + 1))),
                2 => {
                    const shift: u5 = @intCast(g.next() % 20);
                    put(&md5, rc.uint(g.next() % (@as(u32, 1) << shift) + 2));
                },
                3 => put(&md5, rc.uintStep(g.next() % 16)),
                4 => put(&md5, rc.uintTri(g.next() % 60 + 1)),
                5 => {
                    const symbol = g.next() % 32736 + 1;
                    put(&md5, rc.laplace(symbol, @intCast(g.next() % 16384)));
                },
                6 => put(&md5, rc.raw(g.next() % 25 + 1)),
                else => {
                    put(&md5, rc.tell());
                    put(&md5, rc.tellFrac());
                },
            }
        }
        var digest: [16]u8 = undefined;
        md5.final(&digest);
        var got: [160]u8 = undefined;
        const text = try std.fmt.bufPrint(&got, "R {d} {d} {d} {x} {d} {d} {d} {d} {d}", .{ seed, size, ops, digest, rc.range, rc.value, rc.total_bits, rc.tell(), rc.tellFrac() });
        try testing.expectEqualStrings(line, text);
        cases += 1;
    }
    try testing.expectEqual(108, cases);
}
