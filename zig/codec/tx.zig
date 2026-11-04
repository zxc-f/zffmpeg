// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavutil/tx_template.c and libavutil/tx.c at the
// pinned reference revision (the float split-radix FFT codelets
// ff_tx_fftN_ns, ff_tx_fft_sr_combine, ff_tx_fft, ff_tx_mdct_fwd,
// ff_tx_mdct_inv, ff_tx_mdct_init, ff_tx_mdct_gen_exp, the SR tables,
// split_radix_permutation and ff_tx_gen_ptwo_revtab).
// Copyright (c) Lynne
// Power of two and odd factor FFT code (c) 2008 Loren Merritt,
// (c) 2002 Fabrice Bellard, (c) 2014 Takashi Nakamura.
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float transforms for power-of-two lengths (TODO.md T27c), as
//! the reference build's C code computes them (it has no x86 assembly):
//! the split-radix FFT, out of place (`Fft`), and the forward and inverse
//! MDCT (`Mdct`), whose inverse is the half transform FFmpeg's audio
//! decoders take, `len` coefficients to `len` samples.
//!
//! Every operation follows FFmpeg's codelets in order, single precision
//! throughout, so the results are FFmpeg's bit for bit (vectors/tx.txt);
//! the tables are computed in double precision and rounded once, as
//! FFmpeg's are. Zig does not contract `a * b + c` into fused operations
//! unless asked, which keeps the rounding of each step.

const std = @import("std");

pub const Complex = struct {
    re: f32,
    im: f32,
};

/// The largest FFT FFmpeg's split-radix codelets take.
pub const max_fft_len = 131072;
const max_log2 = 17;

/// FFmpeg's `ff_tx_tab_<n>`: cos(2πi/n) for i below n/4, then 0, for the
/// split-radix lengths 8 to the transform's own; owned.
const Tables = struct {
    by_log2: [max_log2 + 1][]f32 = @splat(&.{}),

    fn init(gpa: std.mem.Allocator, len: usize) error{OutOfMemory}!Tables {
        var t: Tables = .{};
        errdefer t.deinit(gpa);
        var n: usize = 8;
        while (n <= len) : (n *= 2) {
            const tab = try gpa.alloc(f32, n / 4 + 1);
            const freq = 2.0 * std.math.pi / @as(f64, @floatFromInt(n));
            for (tab[0 .. n / 4], 0..) |*v, i| v.* = @floatCast(@cos(@as(f64, @floatFromInt(i)) * freq));
            tab[n / 4] = 0;
            t.by_log2[std.math.log2_int(usize, n)] = tab;
        }
        return t;
    }

    fn deinit(t: *Tables, gpa: std.mem.Allocator) void {
        for (t.by_log2) |tab| gpa.free(tab);
    }

    fn of(t: *const Tables, n: usize) []const f32 {
        return t.by_log2[std.math.log2_int(usize, n)];
    }
};

fn isLength(len: usize) bool {
    return len >= 2 and len <= max_fft_len and std.math.isPowerOfTwo(len);
}

/// split_radix_permutation.
fn splitRadixPermutation(i: usize, len_in: usize, inv: bool) isize {
    var len = len_in >> 1;
    if (len <= 1) return @intCast(i & 1);
    if (i & len == 0) return splitRadixPermutation(i, len, inv) * 2;
    len >>= 1;
    const low: isize = @intFromBool((i & len == 0) != inv);
    return splitRadixPermutation(i, len, inv) * 4 + 1 - 2 * low;
}

const MapDir = enum { gather, scatter };

/// ff_tx_gen_ptwo_revtab: the split-radix input order, as a gather map
/// (`map[i]` is the input of position i) or a scatter map.
fn revtab(gpa: std.mem.Allocator, len: usize, inv: bool, dir: MapDir) error{OutOfMemory}![]u32 {
    const map = try gpa.alloc(u32, len);
    for (0..len) |i| {
        const p: usize = @intCast(-splitRadixPermutation(i, len, inv) & @as(isize, @intCast(len - 1)));
        switch (dir) {
            .gather => map[i] = @intCast(p),
            .scatter => map[p] = @intCast(i),
        }
    }
    return map;
}

// The codelets work in place, as FFmpeg calls them; each statement reads
// its operands before it writes, as the C macros do.

fn fft2(z: []Complex) void {
    const tmp: Complex = .{ .re = z[0].re - z[1].re, .im = z[0].im - z[1].im };
    z[0].re = z[0].re + z[1].re;
    z[0].im = z[0].im + z[1].im;
    z[1] = tmp;
}

fn fft4(z: []Complex) void {
    const t3 = z[0].re - z[1].re;
    const t1 = z[0].re + z[1].re;
    const t8 = z[3].re - z[2].re;
    const t6 = z[3].re + z[2].re;
    z[2].re = t1 - t6;
    z[0].re = t1 + t6;
    const t4 = z[0].im - z[1].im;
    const t2 = z[0].im + z[1].im;
    const t7 = z[2].im - z[3].im;
    const t5 = z[2].im + z[3].im;
    z[3].im = t4 - t8;
    z[1].im = t4 + t8;
    z[3].re = t3 - t7;
    z[1].re = t3 + t7;
    z[2].im = t2 - t5;
    z[0].im = t2 + t5;
}

/// The BUTTERFLIES macro over `t1`, `t2`, `t5`, `t6`.
fn butterflies(a0: *Complex, a1: *Complex, a2: *Complex, a3: *Complex, t1: f32, t2: f32, t5_in: f32, t6_in: f32) void {
    const r0 = a0.re;
    const j0 = a0.im;
    const r1 = a1.re;
    const j1 = a1.im;
    const t3 = t5_in - t1;
    const t5 = t5_in + t1;
    a2.re = r0 - t5;
    a0.re = r0 + t5;
    a3.im = j1 - t3;
    a1.im = j1 + t3;
    const t4 = t2 - t6_in;
    const t6 = t2 + t6_in;
    a3.re = r1 - t4;
    a1.re = r1 + t4;
    a2.im = j0 - t6;
    a0.im = j0 + t6;
}

/// The TRANSFORM macro: a2 and a3 rotated by the conjugate twiddle and the
/// twiddle, then the butterflies.
fn transform(a0: *Complex, a1: *Complex, a2: *Complex, a3: *Complex, wre: f32, wim: f32) void {
    const neg_wim = -wim;
    const t1 = a2.re * wre - a2.im * neg_wim;
    const t2 = a2.re * neg_wim + a2.im * wre;
    const t5 = a3.re * wre - a3.im * wim;
    const t6 = a3.re * wim + a3.im * wre;
    butterflies(a0, a1, a2, a3, t1, t2, t5, t6);
}

fn fft8(t: *const Tables, z: []Complex) void {
    const cos = t.of(8)[1];
    fft4(z[0..4]);
    const t1 = z[4].re - -z[5].re;
    z[5].re = z[4].re + -z[5].re;
    const t2 = z[4].im - -z[5].im;
    z[5].im = z[4].im + -z[5].im;
    const t5 = z[6].re - -z[7].re;
    z[7].re = z[6].re + -z[7].re;
    const t6 = z[6].im - -z[7].im;
    z[7].im = z[6].im + -z[7].im;
    butterflies(&z[0], &z[2], &z[4], &z[6], t1, t2, t5, t6);
    transform(&z[1], &z[3], &z[5], &z[7], cos, cos);
}

fn fft16(t: *const Tables, z: []Complex) void {
    const cos = t.of(16);
    const cos_16_1 = cos[1];
    const cos_16_2 = cos[2];
    const cos_16_3 = cos[3];
    fft8(t, z[0..8]);
    fft4(z[8..12]);
    fft4(z[12..16]);
    butterflies(&z[0], &z[4], &z[8], &z[12], z[8].re, z[8].im, z[12].re, z[12].im);
    transform(&z[2], &z[6], &z[10], &z[14], cos_16_2, cos_16_2);
    transform(&z[1], &z[5], &z[9], &z[13], cos_16_1, cos_16_3);
    transform(&z[3], &z[7], &z[11], &z[15], cos_16_3, cos_16_1);
}

/// ff_tx_fft_sr_combine: z[0 .. 8 len] from its three sub-transforms.
fn combine(z: []Complex, cos: []const f32, len: usize) void {
    const o1 = 2 * len;
    const o2 = 4 * len;
    const o3 = 6 * len;
    // Each step takes eight values of `cos` forward and eight of `wim`,
    // which starts at cos[o1 - 7] and walks back.
    for (0..len / 4) |step| {
        const c = cos[8 * step ..][0..8];
        const w = cos[o1 - 7 - 8 * step ..][0..8];
        const zz = z[8 * step ..];
        inline for (.{ 0, 2, 4, 6, 1, 3, 5, 7 }) |k| {
            transform(&zz[k], &zz[o1 + k], &zz[o2 + k], &zz[o3 + k], c[k], w[7 - k]);
        }
    }
}

/// ff_tx_fft<n>_ns: the split-radix FFT of `z` (already in the
/// permuted order), in place.
fn fftSr(t: *const Tables, z: []Complex) void {
    const n = z.len;
    switch (n) {
        2 => fft2(z),
        4 => fft4(z),
        8 => fft8(t, z),
        16 => fft16(t, z),
        else => {
            const n4 = n / 4;
            fftSr(t, z[0 .. n / 2]);
            fftSr(t, z[n4 * 2 ..][0..n4]);
            fftSr(t, z[n4 * 3 ..][0..n4]);
            combine(z, t.of(n), n4 >> 1);
        },
    }
}

/// ff_tx_mdct_gen_exp: the post-rotation's twiddles (`len2` of them,
/// after the pre-rotation's in `pre_tab`'s order when the inverse has one),
/// computed in double precision and rounded once.
fn genExp(gpa: std.mem.Allocator, len2: usize, scale: f32, pre_tab: ?[]const u32) error{OutOfMemory}![]Complex {
    const exp = try gpa.alloc(Complex, if (pre_tab != null) 2 * len2 else len2);
    const scale_d: f64 = scale;
    const theta = (if (scale_d < 0) @as(f64, @floatFromInt(len2)) else 0) + 1.0 / 8.0;
    const magnitude = @sqrt(@abs(scale_d));
    const off: usize = if (pre_tab != null) len2 else 0;
    for (0..len2) |i| {
        const alpha = std.math.pi / 2.0 * (@as(f64, @floatFromInt(i)) + theta) / @as(f64, @floatFromInt(len2));
        exp[off + i] = .{ .re = @floatCast(@cos(alpha) * magnitude), .im = @floatCast(@sin(alpha) * magnitude) };
    }
    if (pre_tab) |map| {
        for (0..len2) |i| exp[i] = exp[len2 + map[i]];
    }
    return exp;
}

/// mulinv: x with n * x = 1 modulo m.
fn mulinv(n_in: usize, m: usize) usize {
    const n = n_in % m;
    for (1..m) |x| {
        if ((n * x) % m == 1) return x;
    }
    unreachable; // coprime by construction (15 and a power of two)
}

/// ff_tx_tab_53: the 5- and 3-point transforms' constants.
fn tab53() [12]f32 {
    const pi = std.math.pi;
    const c5: f32 = @floatCast(@cos(2.0 * pi / 5.0));
    const c10: f32 = @floatCast(@cos(2.0 * pi / 10.0));
    const s5: f32 = @floatCast(@sin(2.0 * pi / 5.0));
    const s10: f32 = @floatCast(@sin(2.0 * pi / 10.0));
    const c12: f32 = @floatCast(@cos(2.0 * pi / 12.0));
    return .{ c5, c5, c10, c10, s5, s5, s10, s10, c12, c12, @floatCast(@cos(2.0 * pi / 6.0)), @floatCast(@cos(8.0 * pi / 6.0)) };
}

/// fft3: three points `in` to `out[o + k * stride]`.
fn fft3(out: []Complex, o: usize, in: [3]Complex, stride: usize, tab: *const [12]f32) void {
    const t0 = in[0];
    var t1: Complex = .{ .re = in[1].im - in[2].im, .im = in[1].re - in[2].re };
    var t2: Complex = .{ .re = in[1].re + in[2].re, .im = in[1].im + in[2].im };
    out[o].re = t0.re + t2.re;
    out[o].im = t0.im + t2.im;
    t1.re = tab[8] * t1.re;
    t1.im = tab[9] * t1.im;
    t2.re = tab[10] * t2.re;
    t2.im = tab[10] * t2.im;
    out[o + stride] = .{ .re = t0.re - t2.re + t1.re, .im = t0.im - t2.im - t1.im };
    out[o + 2 * stride] = .{ .re = t0.re - t2.re - t1.re, .im = t0.im - t2.im + t1.im };
}

/// DECL_FFT5: five points `in` to `out[o + d[k] * stride]`.
fn fft5(out: []Complex, o: usize, in: *const [5]Complex, stride: usize, d: [5]usize, tab: *const [12]f32) void {
    const dc = in[0];
    var t: [6]Complex = undefined;
    t[1].im = in[1].re - in[4].re;
    t[0].re = in[1].re + in[4].re;
    t[1].re = in[1].im - in[4].im;
    t[0].im = in[1].im + in[4].im;
    t[3].im = in[2].re - in[3].re;
    t[2].re = in[2].re + in[3].re;
    t[3].re = in[2].im - in[3].im;
    t[2].im = in[2].im + in[3].im;
    out[o + d[0] * stride] = .{ .re = dc.re + t[0].re + t[2].re, .im = dc.im + t[0].im + t[2].im };
    // SMUL and CMUL, each reading the old value it overwrites second.
    const t4re = tab[0] * t[2].re - tab[2] * t[0].re;
    t[0].re = tab[0] * t[0].re - tab[2] * t[2].re;
    t[4].re = t4re;
    const t4im = tab[0] * t[2].im - tab[2] * t[0].im;
    t[0].im = tab[0] * t[0].im - tab[2] * t[2].im;
    t[4].im = t4im;
    const t5re = tab[4] * t[3].re - tab[6] * t[1].re;
    t[1].re = tab[4] * t[1].re + tab[6] * t[3].re;
    t[5].re = t5re;
    const t5im = tab[4] * t[3].im - tab[6] * t[1].im;
    t[1].im = tab[4] * t[1].im + tab[6] * t[3].im;
    t[5].im = t5im;
    var z: [4]Complex = undefined;
    z[0].re = t[0].re - t[1].re;
    z[3].re = t[0].re + t[1].re;
    z[0].im = t[0].im - t[1].im;
    z[3].im = t[0].im + t[1].im;
    z[2].re = t[4].re - t[5].re;
    z[1].re = t[4].re + t[5].re;
    z[2].im = t[4].im - t[5].im;
    z[1].im = t[4].im + t[5].im;
    out[o + d[1] * stride] = .{ .re = dc.re + z[3].re, .im = dc.im + z[0].im };
    out[o + d[2] * stride] = .{ .re = dc.re + z[2].re, .im = dc.im + z[1].im };
    out[o + d[3] * stride] = .{ .re = dc.re + z[1].re, .im = dc.im + z[2].im };
    out[o + d[4] * stride] = .{ .re = dc.re + z[0].re, .im = dc.im + z[3].im };
}

/// fft15: five 3-point transforms, then three 5-point ones writing the
/// outputs in the prime-factor order.
fn fft15(out: []Complex, o: usize, in: *const [15]Complex, stride: usize, tab: *const [12]f32) void {
    var tmp: [15]Complex = undefined;
    for (0..5) |i| fft3(&tmp, i, in[i * 3 ..][0..3].*, 5, tab);
    fft5(out, o, tmp[0..5], stride, .{ 0, 6, 12, 3, 9 }, tab);
    fft5(out, o, tmp[5..10], stride, .{ 10, 1, 7, 13, 4 }, tab);
    fft5(out, o, tmp[10..15], stride, .{ 5, 11, 2, 8, 14 }, tab);
}

pub const InitError = error{
    /// Not a power of two the transform supports.
    UnsupportedLength,
    OutOfMemory,
};

/// FFmpeg's `fft` transform (AV_TX_FLOAT_FFT, out of place): `len`
/// complex values gathered into the split-radix order, then transformed;
/// the inverse unscaled, as FFmpeg's is.
pub const Fft = struct {
    gpa: std.mem.Allocator,
    map: []u32,
    tables: Tables,

    pub fn init(gpa: std.mem.Allocator, len: usize, inv: bool) InitError!Fft {
        if (!isLength(len)) return error.UnsupportedLength;
        var tables: Tables = try .init(gpa, len);
        errdefer tables.deinit(gpa);
        return .{ .gpa = gpa, .map = try revtab(gpa, len, inv, .gather), .tables = tables };
    }

    pub fn deinit(f: *Fft) void {
        f.gpa.free(f.map);
        f.tables.deinit(f.gpa);
        f.* = undefined;
    }

    /// `dst` and `src` hold `len` values each and do not overlap.
    pub fn run(f: *const Fft, dst: []Complex, src: []const Complex) void {
        std.debug.assert(dst.len == f.map.len and src.len == f.map.len);
        for (dst, f.map) |*d, m| d.* = src[m];
        fftSr(&f.tables, dst);
    }
};

/// FFmpeg's `mdct_fwd` and `mdct_inv` (AV_TX_FLOAT_MDCT, out of place,
/// unit stride): `len` coefficients; the forward transform takes 2 * len
/// samples, the inverse gives `len` samples (the half transform).
pub const Mdct = struct {
    gpa: std.mem.Allocator,
    len: usize,
    inv: bool,
    /// The sub-FFT's input order: gathered (inverse, doubled) or scattered.
    map: []u32,
    /// The twiddles: the inverse's pre-rotation (in the FFT's order) then
    /// its post-rotation; the forward's one set.
    exp: []Complex,
    tables: Tables,
    /// The sub-FFT's buffer, FFmpeg's in-place output.
    z: []Complex,
    /// The 15-point prime-factor transform's state, for a length of 30
    /// times a power of two (`mdct_pfa_15xM_inv`).
    pfa: ?Pfa = null,

    const Pfa = struct {
        /// The sub-FFTs' length.
        m: usize,
        /// The post-rotation's input order (the CRT output map).
        out_map: []u32,
        /// Where each 15-point transform's outputs start (the sub-FFT's
        /// scatter map).
        sub_map: []u32,
        /// The 15-point transforms' output, the sub-FFTs' buffer.
        tmp: []Complex,
        tab53: [12]f32,
    };

    /// ff_tx_mdct_init (`len` a power of two from 4 to 2 * max_fft_len) or,
    /// inverse only, ff_tx_mdct_pfa_init (`len` 30 times a power of two
    /// from 2, Opus CELT's 120 to 960); `scale` FFmpeg's (a negative scale
    /// shifts the phase by a half turn, as ff_tx_mdct_gen_exp's theta
    /// does).
    pub fn init(gpa: std.mem.Allocator, len: usize, inv: bool, scale: f32) InitError!Mdct {
        if (len % 30 == 0 and len / 30 >= 2 and std.math.isPowerOfTwo(len / 30) and isLength(len / 30)) {
            if (!inv) return error.UnsupportedLength;
            return initPfa(gpa, len, scale);
        }
        if (len < 4 or !isLength(len / 2) or !std.math.isPowerOfTwo(len)) return error.UnsupportedLength;
        const len2 = len / 2;
        var tables: Tables = try .init(gpa, len2);
        errdefer tables.deinit(gpa);
        const map = try revtab(gpa, len2, inv, if (inv) .gather else .scatter);
        errdefer gpa.free(map);
        const exp = try genExp(gpa, len2, scale, if (inv) map else null);
        errdefer gpa.free(exp);
        // "Saves a multiply in a hot path."
        if (inv) for (map) |*m| {
            m.* <<= 1;
        };
        const z = try gpa.alloc(Complex, len2);
        return .{ .gpa = gpa, .len = len, .inv = inv, .map = map, .exp = exp, .tables = tables, .z = z };
    }

    /// ff_tx_mdct_pfa_init for 15 * m complex points: the compound
    /// (Ruritanian and CRT) maps, the 15-point transform's own 3 x 5 input
    /// order embedded, the twiddles in that order, and an m-point
    /// split-radix sub-FFT.
    fn initPfa(gpa: std.mem.Allocator, len: usize, scale: f32) InitError!Mdct {
        const n = 15;
        const len2 = len / 2;
        const m = len2 / n;
        var tables: Tables = try .init(gpa, m);
        errdefer tables.deinit(gpa);
        const map = try gpa.alloc(u32, len2);
        errdefer gpa.free(map);
        const out_map = try gpa.alloc(u32, len2);
        errdefer gpa.free(out_map);
        // ff_tx_gen_compound_mapping, gathering (the codelet's own options).
        const m_inv = mulinv(m, n);
        const n_inv = mulinv(n, m);
        for (0..m) |j| {
            for (0..n) |i| {
                map[j * n + i] = @intCast((i * m + j * n) % len2);
                out_map[(i * m * m_inv + j * n * n_inv) % len2] = @intCast(i * m + j);
            }
        }
        // The inverse reverses each group but its DC.
        for (0..m) |i| {
            const group = map[i * n + 1 ..][0 .. n - 1];
            for (0..(n - 1) >> 1) |j| std.mem.swap(u32, &group[j], &group[n - j - 2]);
        }
        // TX_EMBED_INPUT_PFA_MAP(map, len2, 3, 5).
        var k: usize = 0;
        while (k < len2) : (k += n) {
            var tmp: [n]u32 = undefined;
            @memcpy(&tmp, map[k..][0..n]);
            for (0..5) |mm| {
                for (0..3) |nn| map[k + mm * 3 + nn] = tmp[(mm * 3 + nn * 5) % n];
            }
        }
        const exp = try genExp(gpa, len2, scale, map);
        errdefer gpa.free(exp);
        for (map) |*x| x.* <<= 1;
        const sub_map = try revtab(gpa, m, true, .scatter);
        errdefer gpa.free(sub_map);
        const tmp = try gpa.alloc(Complex, len2);
        errdefer gpa.free(tmp);
        const z = try gpa.alloc(Complex, len2);
        return .{
            .gpa = gpa,
            .len = len,
            .inv = true,
            .map = map,
            .exp = exp,
            .tables = tables,
            .z = z,
            .pfa = .{ .m = m, .out_map = out_map, .sub_map = sub_map, .tmp = tmp, .tab53 = tab53() },
        };
    }

    pub fn deinit(m: *Mdct) void {
        if (m.pfa) |p| {
            m.gpa.free(p.out_map);
            m.gpa.free(p.sub_map);
            m.gpa.free(p.tmp);
        }
        m.gpa.free(m.map);
        m.gpa.free(m.exp);
        m.gpa.free(m.z);
        m.tables.deinit(m.gpa);
        m.* = undefined;
    }

    /// The inverse: `len` coefficients in `src` to `len` samples in `dst`;
    /// the forward: 2 * len samples to `len` coefficients.
    pub fn run(m: *const Mdct, dst: []f32, src: []const f32) void {
        if (m.pfa) |*p| return m.inversePfa(p, dst, src, 1);
        if (m.inv) m.inverse(dst, src, 1) else m.forward(dst, src);
    }

    /// The inverse with FFmpeg's input stride: coefficient `k` at
    /// `src[k * stride]` (Opus CELT's interleaved short blocks).
    pub fn runInverseStrided(m: *const Mdct, dst: []f32, src: []const f32, stride: usize) void {
        std.debug.assert(m.inv and stride >= 1);
        if (m.pfa) |*p| m.inversePfa(p, dst, src, stride) else m.inverse(dst, src, stride);
    }

    /// ff_tx_mdct_pfa_15xM_inv: each group of 15 pre-rotated inputs
    /// through the 15-point transform into the sub-FFTs' buffer, the 15
    /// sub-FFTs, then the post-rotation in the CRT order.
    fn inversePfa(m: *const Mdct, p: *const Pfa, dst: []f32, src: []const f32, stride: usize) void {
        const n = 15;
        const len2 = m.len / 2;
        const len4 = m.len / 4;
        std.debug.assert(dst.len == m.len and src.len == (m.len - 1) * stride + 1);
        var fin: [n]Complex = undefined;
        var group: usize = 0;
        while (group * n < len2) : (group += 1) {
            const in_map = m.map[group * n ..][0..n];
            const exp = m.exp[group * n ..][0..n];
            for (&fin, in_map, exp) |*c, k, e| {
                const tmp: Complex = .{ .re = src[(m.len - 1 - k) * stride], .im = src[k * stride] };
                c.* = .{ .re = tmp.re * e.re - tmp.im * e.im, .im = tmp.re * e.im + tmp.im * e.re };
            }
            fft15(p.tmp, p.sub_map[group], &fin, p.m, &p.tab53);
        }
        for (0..n) |i| fftSr(&m.tables, p.tmp[p.m * i ..][0..p.m]);
        const exp = m.exp[len2..];
        const z = m.z;
        for (0..len4) |i| {
            const j0 = len4 + i;
            const j1 = len4 - i - 1;
            const s0 = p.out_map[j0];
            const s1 = p.out_map[j1];
            const src1: Complex = .{ .re = p.tmp[s1].im, .im = p.tmp[s1].re };
            const src0: Complex = .{ .re = p.tmp[s0].im, .im = p.tmp[s0].re };
            z[j1].re = src1.re * exp[j1].im - src1.im * exp[j1].re;
            z[j0].im = src1.re * exp[j1].re + src1.im * exp[j1].im;
            z[j0].re = src0.re * exp[j0].im - src0.im * exp[j0].re;
            z[j1].im = src0.re * exp[j0].re + src0.im * exp[j0].im;
        }
        for (z, 0..) |c, i| {
            dst[2 * i] = c.re;
            dst[2 * i + 1] = c.im;
        }
    }

    /// ff_tx_mdct_inv.
    fn inverse(m: *const Mdct, dst: []f32, src: []const f32, stride: usize) void {
        const len2 = m.len / 2;
        const len4 = m.len / 4;
        std.debug.assert(dst.len == m.len and src.len == (m.len - 1) * stride + 1);
        const z = m.z;
        for (z, m.map, m.exp[0..len2]) |*c, k, e| {
            const tmp: Complex = .{ .re = src[(m.len - 1 - k) * stride], .im = src[k * stride] };
            c.* = .{ .re = tmp.re * e.re - tmp.im * e.im, .im = tmp.re * e.im + tmp.im * e.re };
        }
        fftSr(&m.tables, z);
        const exp = m.exp[len2..];
        for (0..len4) |i| {
            const j0 = len4 + i;
            const j1 = len4 - i - 1;
            const src1: Complex = .{ .re = z[j1].im, .im = z[j1].re };
            const src0: Complex = .{ .re = z[j0].im, .im = z[j0].re };
            z[j1].re = src1.re * exp[j1].im - src1.im * exp[j1].re;
            z[j0].im = src1.re * exp[j1].re + src1.im * exp[j1].im;
            z[j0].re = src0.re * exp[j0].im - src0.im * exp[j0].re;
            z[j1].im = src0.re * exp[j0].re + src0.im * exp[j0].im;
        }
        for (z, 0..) |c, i| {
            dst[2 * i] = c.re;
            dst[2 * i + 1] = c.im;
        }
    }

    /// ff_tx_mdct_fwd: folding and pre-rotation into the FFT's order, the
    /// FFT, then the post-rotation.
    fn forward(m: *const Mdct, dst: []f32, src: []const f32) void {
        const len2 = m.len / 2;
        const len4 = m.len / 4;
        const len3 = len2 * 3;
        std.debug.assert(dst.len == m.len and src.len == 2 * m.len);
        const z = m.z;
        for (0..len2) |i| {
            const k = 2 * i;
            var tmp: Complex = undefined;
            if (k < len2) {
                tmp.re = -src[len2 + k] + src[len2 - 1 - k];
                tmp.im = -src[len3 + k] + -src[len3 - 1 - k];
            } else {
                tmp.re = -src[len2 + k] + -src[5 * len2 - 1 - k];
                tmp.im = src[k - len2] + -src[len3 - 1 - k];
            }
            const e = m.exp[i];
            const idx = m.map[i];
            z[idx].im = tmp.re * e.re - tmp.im * e.im;
            z[idx].re = tmp.re * e.im + tmp.im * e.re;
        }
        fftSr(&m.tables, z);
        for (0..len4) |i| {
            const j0 = len4 + i;
            const j1 = len4 - i - 1;
            const src1 = z[j1];
            const src0 = z[j0];
            dst[2 * j1 + 1] = src0.re * m.exp[j0].im - src0.im * m.exp[j0].re;
            dst[2 * j0] = src0.re * m.exp[j0].re + src0.im * m.exp[j0].im;
            dst[2 * j0 + 1] = src1.re * m.exp[j1].im - src1.im * m.exp[j1].re;
            dst[2 * j1] = src1.re * m.exp[j1].re + src1.im * m.exp[j1].im;
        }
    }
};

const testing = std.testing;
const vectors = @embedFile("../testing/vectors/tx.txt");

/// tx_vectors.c's input_value: 16 bits of a linear congruential sequence
/// in [-1, 1), exact in a float.
fn inputValue(i: u32, lane: u32) f32 {
    const x = i *% 1103515245 +% 12345 +% lane *% 2654435761;
    const bits: f32 = @floatFromInt((x >> 8) & 0xffff);
    return bits / 32768.0 - 1.0;
}

fn md5Hex(values: []const f32) [32]u8 {
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (values) |v| {
        var le: [4]u8 = undefined;
        std.mem.writeInt(u32, &le, @bitCast(v), .little);
        md5.update(&le);
    }
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

test "every transform equals FFmpeg's bit for bit (vectors/tx.txt)" {
    const gpa = testing.allocator;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "T ")) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next();
        const kind = f.next().?;
        const len = try std.fmt.parseInt(usize, f.next().?, 10);
        const inv = std.mem.eql(u8, f.next().?, "1");
        const scale = try std.fmt.parseFloat(f32, f.next().?);
        var out_line = lines.next().?;
        while (std.mem.startsWith(u8, out_line, "C ")) out_line = lines.next().?;
        var o = std.mem.tokenizeScalar(u8, out_line, ' ');
        try testing.expectEqualStrings("O", o.next().?);
        const count = try std.fmt.parseInt(usize, o.next().?, 10);
        const digest = o.next().?;
        const lane: u32 = @intCast(len * 2 + @intFromBool(inv));
        const mdct = std.mem.eql(u8, kind, "mdct");
        const in_count = if (mdct and inv) len else 2 * len;
        const input = try gpa.alloc(f32, in_count);
        defer gpa.free(input);
        for (input, 0..) |*v, i| v.* = inputValue(@intCast(i), lane);
        const output = try gpa.alloc(f32, count);
        defer gpa.free(output);
        if (mdct) {
            var m: Mdct = try .init(gpa, len, inv, scale);
            defer m.deinit();
            m.run(output, input);
        } else {
            var fft: Fft = try .init(gpa, len, inv);
            defer fft.deinit();
            const src = try gpa.alloc(Complex, len);
            defer gpa.free(src);
            const dst = try gpa.alloc(Complex, len);
            defer gpa.free(dst);
            for (src, 0..) |*c, i| c.* = .{ .re = input[2 * i], .im = input[2 * i + 1] };
            fft.run(dst, src);
            for (dst, 0..) |c, i| {
                output[2 * i] = c.re;
                output[2 * i + 1] = c.im;
            }
        }
        testing.expectEqualStrings(digest, &md5Hex(output)) catch |err| {
            std.debug.print("{s}\n", .{line});
            return err;
        };
        cases += 1;
    }
    // 17 FFT lengths and 13 MDCT lengths, both directions, four scales;
    // six prime-factor inverse MDCT lengths at three scales.
    try testing.expectEqual(17 * 2 + 13 * 2 * 4 + 6 * 3, cases);
}

/// The relative RMS error of `ours` against `exact`.
fn relativeError(ours: []const f32, exact: []const f64) f64 {
    var err: f64 = 0;
    var ref: f64 = 0;
    for (ours, exact) |o, e| {
        err += (@as(f64, o) - e) * (@as(f64, o) - e);
        ref += e * e;
    }
    return @sqrt(err / ref);
}

/// The declared error (T27c): a relative RMS error of at most four float
/// epsilons against the float64 definition. Measured: 1.2e-7 for the FFT
/// up to 1024 points and 1.5e-7 for the MDCT up to 2048 coefficients.
const declared_error: f64 = 4.0 * std.math.floatEps(f32);

test "the transforms equal their float64 definitions within the declared error" {
    const gpa = testing.allocator;
    var n: usize = 2;
    while (n <= 1024) : (n *= 2) {
        for ([_]bool{ false, true }) |inv| {
            var fft: Fft = try .init(gpa, n, inv);
            defer fft.deinit();
            const src = try gpa.alloc(Complex, n);
            defer gpa.free(src);
            const dst = try gpa.alloc(Complex, n);
            defer gpa.free(dst);
            for (src, 0..) |*c, i| c.* = .{ .re = inputValue(@intCast(2 * i), 7), .im = inputValue(@intCast(2 * i + 1), 7) };
            fft.run(dst, src);
            const ours = try gpa.alloc(f32, 2 * n);
            defer gpa.free(ours);
            const exact = try gpa.alloc(f64, 2 * n);
            defer gpa.free(exact);
            const sign: f64 = if (inv) 1 else -1;
            for (0..n) |k| {
                var re: f64 = 0;
                var im: f64 = 0;
                for (src, 0..) |c, j| {
                    const a = sign * 2.0 * std.math.pi * @as(f64, @floatFromInt((j * k) % n)) / @as(f64, @floatFromInt(n));
                    re += @as(f64, c.re) * @cos(a) - @as(f64, c.im) * @sin(a);
                    im += @as(f64, c.re) * @sin(a) + @as(f64, c.im) * @cos(a);
                }
                exact[2 * k] = re;
                exact[2 * k + 1] = im;
                ours[2 * k] = dst[k].re;
                ours[2 * k + 1] = dst[k].im;
            }
            try testing.expect(relativeError(ours, exact) <= declared_error);
        }
    }
    // The power-of-two lengths both ways, then the prime-factor ones
    // (inverse only).
    const lengths = [_]usize{ 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 60, 120, 240, 480, 960 };
    for (lengths) |len| {
        n = len;
        const directions: []const bool = if (std.math.isPowerOfTwo(n)) &.{ false, true } else &.{true};
        for (directions) |inv| {
            for ([_]f32{ 1, -1, 1.0 / 32768.0 }) |scale| {
                var m: Mdct = try .init(gpa, n, inv, scale);
                defer m.deinit();
                const in = try gpa.alloc(f32, if (inv) n else 2 * n);
                defer gpa.free(in);
                for (in, 0..) |*v, i| v.* = inputValue(@intCast(i), 9);
                const out = try gpa.alloc(f32, n);
                defer gpa.free(out);
                m.run(out, in);
                const exact = try gpa.alloc(f64, n);
                defer gpa.free(exact);
                const nf: f64 = @floatFromInt(n);
                for (exact, 0..) |*e, idx| {
                    var sum: f64 = 0;
                    if (inv) {
                        // The middle half of the full inverse.
                        const t: f64 = @floatFromInt(idx + n / 2);
                        for (in, 0..) |x, k| sum += @as(f64, x) * @cos(std.math.pi / nf * (t + 0.5 + nf / 2) * (@as(f64, @floatFromInt(k)) + 0.5));
                    } else {
                        for (in, 0..) |x, t| sum += @as(f64, x) * @cos(std.math.pi / nf * (@as(f64, @floatFromInt(t)) + 0.5 + nf / 2) * (@as(f64, @floatFromInt(idx)) + 0.5));
                    }
                    // FFmpeg's half inverse is the negated middle half.
                    e.* = if (inv) -sum * scale else sum * scale;
                }
                try testing.expect(relativeError(out, exact) <= declared_error);
            }
        }
    }
}

test "a strided inverse equals the inverse of the gathered coefficients" {
    const gpa = testing.allocator;
    for ([_]usize{ 120, 240, 64 }) |len| {
        var m: Mdct = try .init(gpa, len, true, -1.0 / 32768.0);
        defer m.deinit();
        const stride = 3;
        const src = try gpa.alloc(f32, (len - 1) * stride + 1);
        defer gpa.free(src);
        for (src, 0..) |*v, i| v.* = @floatFromInt(@as(i32, @intCast(i % 97)) - 48);
        const gathered = try gpa.alloc(f32, len);
        defer gpa.free(gathered);
        for (gathered, 0..) |*v, k| v.* = src[k * stride];
        const want = try gpa.alloc(f32, len);
        defer gpa.free(want);
        const got = try gpa.alloc(f32, len);
        defer gpa.free(got);
        m.run(want, gathered);
        m.runInverseStrided(got, src, stride);
        try testing.expectEqualSlices(f32, want, got);
    }
}
