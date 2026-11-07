// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/flt-32/e_powf.c,
// e_powf_log2_data.c, e_exp2f_data.c, math_errf.c and math_config.h (from
// Arm's optimized-routines; copyright (C) 2017-2026 Free Software
// Foundation, Inc.), as built on x86-64 in its FMA variant (e_powf-fma.c).
// The GNU C Library is free software; you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published
// by the Free Software Foundation; either version 2.1 of the License, or (at
// your option) any later version.
//! glibc's single-precision `powf` (core/libm.zig): log2(x) in double from
//! a 16-entry table and a degree-5 polynomial, times y, then exp2f's table
//! and polynomial (`__exp2f_data`, shared with `libm.exp2f`). FFmpeg's
//! float AAC decoder calls it for its coupling gains,
//! powf(cce_scale[i], -gain) (T30b).
//!
//! glibc runs `__powf_fma` on a CPU with FMA and AVX2, built with
//! `-mfma -mavx2`. Its disassembly in the installed libm.so.6 fuses every
//! product that feeds an addition, eight in all: `z * invc - 1` and the
//! five polynomial steps of `log2_inline`, and `C[0] * r + C[1]`,
//! `C[2] * r + 1` and `z * r2 + y` in `exp2_inline`; `r * r`, `r2 * r2`,
//! `y * log2(x)` and `y * s` stay plain products. `@mulAdd` marks the
//! fused ones.
//!
//! The special cases return what that build returns: `x + y` with a NaN
//! operand is `vaddss` with x first, which returns x's NaN quieted when x
//! is one and y's otherwise; `(x - x) / (x - x)` for a negative x and a
//! non-integer y is x86's default NaN, 0xffc00000. The results assume
//! round-to-nearest, Zig's only rounding mode, under which glibc's
//! rounding-mode test near overflow always returns the largest float.

const std = @import("std");
const libm = @import("../libm.zig");

const log2_table_bits = 4;
const off: u32 = 0x3f330000;
/// glibc's SIGN_BIAS: added to the exponent of 2^(k/N), it flips the sign
/// of the result.
const sign_bias_negative: u64 = 1 << (5 + 11);

/// __powf_log2_data.tab: 1/c and log2(c) for the 16 subintervals of
/// [OFF, 2 OFF].
const log2_tab = [1 << log2_table_bits][2]f64{
    .{ 0x1.661ec79f8f3bep+0, -0x1.efec65b963019p-2 },
    .{ 0x1.571ed4aaf883dp+0, -0x1.b0b6832d4fca4p-2 },
    .{ 0x1.49539f0f010bp+0, -0x1.7418b0a1fb77bp-2 },
    .{ 0x1.3c995b0b80385p+0, -0x1.39de91a6dcf7bp-2 },
    .{ 0x1.30d190c8864a5p+0, -0x1.01d9bf3f2b631p-2 },
    .{ 0x1.25e227b0b8eap+0, -0x1.97c1d1b3b7afp-3 },
    .{ 0x1.1bb4a4a1a343fp+0, -0x1.2f9e393af3c9fp-3 },
    .{ 0x1.12358f08ae5bap+0, -0x1.960cbbf788d5cp-4 },
    .{ 0x1.0953f419900a7p+0, -0x1.a6f9db6475fcep-5 },
    .{ 0x1p+0, 0x0p+0 },
    .{ 0x1.e608cfd9a47acp-1, 0x1.338ca9f24f53dp-4 },
    .{ 0x1.ca4b31f026aap-1, 0x1.476a9543891bap-3 },
    .{ 0x1.b2036576afce6p-1, 0x1.e840b4ac4e4d2p-3 },
    .{ 0x1.9c2d163a1aa2dp-1, 0x1.40645f0c6651cp-2 },
    .{ 0x1.886e6037841edp-1, 0x1.88e9c2c1b9ff8p-2 },
    .{ 0x1.767dcf5534862p-1, 0x1.ce0a44eb17bccp-2 },
};

/// __powf_log2_data.poly: log1p(r)/ln2 ~= A0 r^5 + ... + A4 r.
const log2_poly = [5]f64{
    0x1.27616c9496e0bp-2,  -0x1.71969a075c67ap-2, 0x1.ec70a6ca7baddp-2,
    -0x1.7154748bef6c8p-1, 0x1.71547652ab82bp0,
};

/// __exp2f_data.poly: 2^r ~= C0 r^3 + C1 r^2 + C2 r + 1.
const exp2_poly = [3]f64{ 0x1.c6af84b912394p-5, 0x1.ebfce50fac4f3p-3, 0x1.62e42ff0c52d6p-1 };

/// log2(x) for the bits of a positive x, a subnormal one normalized with a
/// negative biased exponent.
fn log2Inline(ix: u32) f64 {
    // x = 2^k z, with z in [OFF, 2 OFF] and exact.
    const tmp = ix -% off;
    const i = (tmp >> (23 - log2_table_bits)) % (1 << log2_table_bits);
    const top = tmp & 0xff800000;
    const iz = ix -% top;
    const top_signed: i32 = @bitCast(top);
    const k: f64 = @floatFromInt(top_signed >> 23); // arithmetic shift
    const invc = log2_tab[i][0];
    const logc = log2_tab[i][1];
    const z: f32 = @bitCast(iz);

    // log2(x) = log1p(z/c - 1)/ln2 + log2(c) + k.
    const r = @mulAdd(f64, z, invc, -1.0);
    const y0 = logc + k;
    const r2 = r * r;
    var y = @mulAdd(f64, log2_poly[0], r, log2_poly[1]);
    const p = @mulAdd(f64, log2_poly[2], r, log2_poly[3]);
    const r4 = r2 * r2;
    var q = @mulAdd(f64, log2_poly[4], r, y0);
    q = @mulAdd(f64, p, r2, q);
    y = @mulAdd(f64, y, r4, q);
    return y;
}

/// 2^xd for xd in [-1021, 1023], negated when `sign_bias` is
/// `sign_bias_negative`.
fn exp2Inline(xd: f64, sign_bias: u64) f64 {
    // xd = k/N + r with r in [-1/(2N), 1/(2N)].
    const shift = 0x1.8p+52 / 32.0;
    var kd = xd + shift;
    const ki: u64 = @bitCast(kd);
    kd -= shift;
    const r = xd - kd;
    const ski = ki +% sign_bias;
    const t = libm.exp2f_tab[ki % 32] +% (ski << (52 - 5));
    const s: f64 = @bitCast(t);
    const z = @mulAdd(f64, exp2_poly[0], r, exp2_poly[1]);
    const r2 = r * r;
    var y = @mulAdd(f64, exp2_poly[2], r, 1.0);
    y = @mulAdd(f64, z, r2, y);
    return y * s;
}

const IntKind = enum { not_int, odd, even };

/// glibc's checkint, for the bits of a nonzero finite float.
fn checkint(iy: u32) IntKind {
    const e = (iy >> 23) & 0xff;
    if (e < 0x7f) return .not_int;
    if (e > 0x7f + 23) return .even;
    const one: u32 = 1;
    const bit = one << @intCast(0x7f + 23 - e);
    if ((iy & (bit - 1)) != 0) return .not_int;
    if ((iy & bit) != 0) return .odd;
    return .even;
}

/// Zero, infinity or NaN.
fn zeroinfnan(i: u32) bool {
    return (i *% 2) -% 1 >= 2 * 0x7f800000 - 1;
}

/// glibc's issignaling for a float.
fn isSignaling(v: f32) bool {
    const b: u32 = @bitCast(v);
    return ((b ^ 0x00400000) & 0x7fffffff) > 0x7fc00000;
}

/// glibc's `x + y` where one of them is a NaN, as `vaddss` computes it.
fn addNan(x: f32, y: f32) f32 {
    const ix: u32 = @bitCast(x);
    const iy: u32 = @bitCast(y);
    if (std.math.isNan(x)) return @bitCast(ix | 0x00400000);
    if (std.math.isNan(y)) return @bitCast(iy | 0x00400000);
    return x + y;
}

fn withSign(sign_bias: u64, v: f32) f32 {
    return if (sign_bias != 0) -v else v;
}

/// glibc's powf.
pub fn powf(x: f32, y: f32) f32 {
    var sign_bias: u64 = 0;
    var ix: u32 = @bitCast(x);
    const iy: u32 = @bitCast(y);
    if (ix -% 0x00800000 >= 0x7f800000 - 0x00800000 or zeroinfnan(iy)) {
        // x < 0x1p-126, inf or NaN, or y zero, inf or NaN.
        if (zeroinfnan(iy)) {
            if (iy *% 2 == 0) return if (isSignaling(x)) addNan(x, y) else 1.0;
            if (ix == 0x3f800000) return if (isSignaling(y)) addNan(x, y) else 1.0;
            if (ix *% 2 > 2 * 0x7f800000 or iy *% 2 > 2 * 0x7f800000) return addNan(x, y);
            if (ix *% 2 == 2 * 0x3f800000) return 1.0;
            // |x| < 1 and y == inf, or |x| > 1 and y == -inf.
            if ((ix *% 2 < 2 * 0x3f800000) == ((iy & 0x80000000) == 0)) return 0.0;
            return y * y;
        }
        if (zeroinfnan(ix)) {
            var x2 = x * x;
            if ((ix & 0x80000000) != 0 and checkint(iy) == .odd) x2 = -x2;
            // glibc's errno branch for x == 0 and y < 0,
            // __math_divzerof, returns the same +-inf as 1 / x2.
            return if ((iy & 0x80000000) != 0) 1 / x2 else x2;
        }
        // x and y are nonzero and finite.
        if ((ix & 0x80000000) != 0) {
            switch (checkint(iy)) {
                // __math_invalidf: (x - x) / (x - x).
                .not_int => return @bitCast(@as(u32, 0xffc00000)),
                .odd => sign_bias = sign_bias_negative,
                .even => {},
            }
            ix &= 0x7fffffff;
        }
        if (ix < 0x00800000) {
            // Normalize a subnormal x so that its exponent is negative.
            ix = @bitCast(x * 0x1p23);
            ix &= 0x7fffffff;
            ix -%= 23 << 23;
        }
    }
    // y * log2(x) cannot overflow since y is single precision.
    const yd: f64 = y;
    const ylogx = yd * log2Inline(ix);

    // |y * log2(x)| >= 126.
    const f126: f64 = 126.0;
    const bits_126: u64 = @bitCast(f126);
    const ylogx_bits: u64 = @bitCast(ylogx);
    if (((ylogx_bits >> 47) & 0xffff) >= bits_126 >> 47) {
        // __math_uflowf: 0x1p-95f squared.
        if (ylogx <= -150.0) return withSign(sign_bias, 0.0);
        // __math_may_uflowf: 0x1.4p-75f squared, 0x1.9p-150, rounds up.
        if (ylogx < -149.0) return withSign(sign_bias, 0x1p-149);
        if (ylogx > 0x1.fffffffa3aae2p+6) {
            // __math_oflowf: 0x1p97f squared.
            if (ylogx > 0x1.fffffffd1d571p+6) return withSign(sign_bias, std.math.inf(f32));
            // |x^y| > 0x1.fffffep127: glibc tests whether the rounding
            // mode rounds away from zero; to nearest it does not.
            return withSign(sign_bias, std.math.floatMax(f32));
        }
    }
    return @floatCast(exp2Inline(ylogx, sign_bias));
}

const testing = std.testing;

fn bits(v: f32) u32 {
    return @bitCast(v);
}

test "powf's special cases return glibc's values and NaNs" {
    const inf = std.math.inf(f32);
    try testing.expectEqual(1024, powf(2, 10));
    try testing.expectEqual(-8, powf(-2, 3));
    try testing.expectEqual(0.25, powf(-2, -2));
    try testing.expectEqual(0xffc00000, bits(powf(-8, 1.0 / 3.0)));
    try testing.expectEqual(inf, powf(0, -1));
    try testing.expectEqual(-inf, powf(-0.0, -1));
    try testing.expectEqual(inf, powf(-0.0, -2));
    try testing.expectEqual(0x80000000, bits(powf(-0.0, 3)));
    try testing.expectEqual(1, powf(std.math.nan(f32), 0));
    try testing.expectEqual(1, powf(1, std.math.nan(f32)));
    try testing.expectEqual(1, powf(-1, inf));
    try testing.expectEqual(0, powf(0.5, inf));
    try testing.expectEqual(0, powf(2, -inf));
    try testing.expectEqual(inf, powf(2, inf));
    try testing.expectEqual(inf, powf(2, 128));
    try testing.expectEqual(0x80000000, bits(powf(-2, -151)));
    try testing.expectEqual(0x80000001, bits(powf(-2, -149)));
    // A signaling NaN comes back quieted; of two NaNs, x's.
    try testing.expectEqual(0x7fe00001, bits(powf(@bitCast(@as(u32, 0x7fa00001)), 0)));
    try testing.expectEqual(0xffe00001, bits(powf(1, @bitCast(@as(u32, 0xffa00001)))));
    try testing.expectEqual(0x7fc12345, bits(powf(@bitCast(@as(u32, 0x7fc12345)), @bitCast(@as(u32, 0xffc00000)))));
    try testing.expectEqual(0x7fc00001, bits(powf(2, @bitCast(@as(u32, 0x7f800001)))));
}

/// libm_vectors.c's xorshift generator and float distributions.
pub const FloatSampler = struct {
    state: u64,

    const special = [_]u32{
        0x00000000, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0xffc00000,
        0x7fa00001, 0xffa00001, 0x7fc12345, 0x3f800000, 0xbf800000, 0x3f000000,
        0xbf000000, 0x40000000, 0xc0000000, 0x40400000, 0xc0400000, 0x00800000,
        0x80800000, 0x00000001, 0x80000001, 0x007fffff, 0x7f7fffff, 0xff7fffff,
        0x4b800000, 0x4b7fffff, 0xcb7fffff, 0x3f800001, 0x3f7fffff, 0x43000000,
        0xc3160000, 0x42fc0000, 0xc3150000, 0x4effffff, 0xcf000000, 0x5f800000,
    };

    fn next(g: *FloatSampler) u64 {
        g.state ^= g.state << 13;
        g.state ^= g.state >> 7;
        g.state ^= g.state << 17;
        return g.state;
    }

    pub fn sample(g: *FloatSampler, dist: u32) f32 {
        const u = g.next();
        const lo: u32 = @truncate(u);
        const hi: u32 = @truncate(u >> 32);
        const sign = hi & 0x80000000;
        const pick = (hi >> 8) & 0xffff;
        const mant = lo & 0x7fffff;
        const b: u32 = switch (dist) {
            0 => lo,
            1 => sign | ((127 - 8 + pick % 16) << 23) | mant,
            2 => ((pick % 255) << 23) | mant,
            3 => special[pick % special.len],
            4 => {
                const p: i32 = @intCast(pick % 601);
                return @floatFromInt(p - 300);
            },
            5 => if ((hi & 1) != 0) 0x3f800000 + lo % 4096 else 0x3f800000 - lo % 4096,
            6 => sign | ((127 - 30 + pick % 60) << 23) | mant,
            else => blk: {
                const e = pick % 32;
                const frac: u5 = if (e < 23) @intCast(23 - e) else 0;
                const one: u32 = 1;
                var m = mant & ~((one << frac) - 1);
                if (frac > 0 and (hi & 1) != 0) m |= one << (frac - 1);
                break :blk sign | ((127 + e) << 23) | m;
            },
        };
        return @bitCast(b);
    }
};

test "powf returns glibc's results (vectors/libm.txt)" {
    const Md5 = std.crypto.hash.Md5;
    var lines = std.mem.splitScalar(u8, @embedFile("../../testing/vectors/libm.txt"), '\n');
    var line = lines.next().?;
    while (!std.mem.startsWith(u8, line, "P powf ")) line = lines.next().?;
    var text: [128]u8 = undefined;

    // FFmpeg's cce_scale: double constants rounded to float.
    const scales = [4]f32{
        @floatCast(@as(f64, 1.09050773266525765921)), // 2^(1/8)
        @floatCast(@as(f64, 1.18920711500272106672)), // 2^(1/4)
        @floatCast(@as(f64, std.math.sqrt2)),
        2,
    };
    for (scales, 0..) |scale, si| {
        if (si != 0) line = lines.next().?;
        var md5: Md5 = .init(.{});
        var g: i32 = -300;
        while (g <= 300) : (g += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(powf(scale, @floatFromInt(g))), .little);
            md5.update(&b);
        }
        var digest: [Md5.digest_length]u8 = undefined;
        md5.final(&digest);
        const got = try std.fmt.bufPrint(&text, "P powf {x:0>8} -300 300 {x}", .{ bits(scale), digest });
        try testing.expectEqualStrings(line, got);
    }

    for (0..8) |dx| {
        for (0..8) |dy| {
            var g: FloatSampler = .{ .state = 0x9E3779B97F4A7C15 +% 1000003 * @as(u64, 1000 + dx * 8 + dy) };
            var md5: Md5 = .init(.{});
            for (0..5000) |_| {
                const x = g.sample(@intCast(dx));
                const y = g.sample(@intCast(dy));
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(powf(x, y)), .little);
                md5.update(&b);
            }
            var digest: [Md5.digest_length]u8 = undefined;
            md5.final(&digest);
            const got = try std.fmt.bufPrint(&text, "F powf {d} {d} 5000 {x}", .{ dx, dy, digest });
            try testing.expectEqualStrings(lines.next().?, got);
        }
    }
}
