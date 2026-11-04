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

    /// ff_tx_mdct_init: `len` a power of two from 4 to 2 * max_fft_len;
    /// `scale` FFmpeg's (a negative scale shifts the phase by a half
    /// turn, as ff_tx_mdct_gen_exp's theta does).
    pub fn init(gpa: std.mem.Allocator, len: usize, inv: bool, scale: f32) InitError!Mdct {
        if (len < 4 or !isLength(len / 2) or !std.math.isPowerOfTwo(len)) return error.UnsupportedLength;
        const len2 = len / 2;
        var tables: Tables = try .init(gpa, len2);
        errdefer tables.deinit(gpa);
        const map = try revtab(gpa, len2, inv, if (inv) .gather else .scatter);
        errdefer gpa.free(map);
        const exp = try gpa.alloc(Complex, if (inv) 2 * len2 else len2);
        errdefer gpa.free(exp);
        // ff_tx_mdct_gen_exp.
        const scale_d: f64 = scale;
        const theta = (if (scale_d < 0) @as(f64, @floatFromInt(len2)) else 0) + 1.0 / 8.0;
        const magnitude = @sqrt(@abs(scale_d));
        const off: usize = if (inv) len2 else 0;
        for (0..len2) |i| {
            const alpha = std.math.pi / 2.0 * (@as(f64, @floatFromInt(i)) + theta) / @as(f64, @floatFromInt(len2));
            exp[off + i] = .{ .re = @floatCast(@cos(alpha) * magnitude), .im = @floatCast(@sin(alpha) * magnitude) };
        }
        if (inv) {
            for (0..len2) |i| exp[i] = exp[len2 + map[i]];
            // "Saves a multiply in a hot path."
            for (map) |*m| m.* <<= 1;
        }
        const z = try gpa.alloc(Complex, len2);
        return .{ .gpa = gpa, .len = len, .inv = inv, .map = map, .exp = exp, .tables = tables, .z = z };
    }

    pub fn deinit(m: *Mdct) void {
        m.gpa.free(m.map);
        m.gpa.free(m.exp);
        m.gpa.free(m.z);
        m.tables.deinit(m.gpa);
        m.* = undefined;
    }

    /// The inverse: `len` coefficients in `src` to `len` samples in `dst`;
    /// the forward: 2 * len samples to `len` coefficients.
    pub fn run(m: *const Mdct, dst: []f32, src: []const f32) void {
        if (m.inv) m.inverse(dst, src) else m.forward(dst, src);
    }

    /// ff_tx_mdct_inv.
    fn inverse(m: *const Mdct, dst: []f32, src: []const f32) void {
        const len2 = m.len / 2;
        const len4 = m.len / 4;
        std.debug.assert(dst.len == m.len and src.len == m.len);
        const z = m.z;
        for (z, m.map, m.exp[0..len2]) |*c, k, e| {
            const tmp: Complex = .{ .re = src[m.len - 1 - k], .im = src[k] };
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
    // 17 FFT lengths and 13 MDCT lengths, both directions, four scales.
    try testing.expectEqual(17 * 2 + 13 * 2 * 4, cases);
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
    n = 4;
    while (n <= 2048) : (n *= 2) {
        for ([_]bool{ false, true }) |inv| {
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
