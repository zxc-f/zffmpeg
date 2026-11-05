// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's math/s_ldexp_template.c and
// sysdeps/ieee754/dbl-64/s_scalbn.c (from Sun's fdlibm; copyright (C) 1993
// by Sun Microsystems, Inc. All rights reserved. Developed at SunPro, a Sun
// Microsystems, Inc. business. Permission to use, copy, modify, and
// distribute this software is freely granted, provided that this notice is
// preserved.). The GNU C Library is free software; you can redistribute it
// and/or modify it under the terms of the GNU Lesser General Public License
// as published by the Free Software Foundation; either version 2.1 of the
// License, or (at your option) any later version.
//! glibc's double `ldexp` (core/libm.zig): x * 2^n by exponent arithmetic,
//! a subnormal result rounded once, to nearest even, by a final multiply.
//! Zig 0.17's `std.math.ldexp` is not C's: it takes a zero for a subnormal
//! and scales it (in f64, 2^(n - 1076) for 53 < n, infinity past 2099; in
//! f32, from n = 25, infinity past 278), and in f32 and f64 it rounds some
//! subnormal ties away from even: its tie test counts the exponent's zero
//! bits when the mantissa is zero, so f64 `ldexp(2.0, -1076)` is 2^-1074,
//! not 0 (notes.md "Floating-point library").
//! glibc's `errno` (ERANGE) is not modeled.

const std = @import("std");

const two54: f64 = 0x1p54;
const twom54: f64 = 0x1p-54;
const huge: f64 = 1.0e+300;
const tiny: f64 = 1.0e-300;

/// glibc's `ldexp`: x * 2^n, correctly rounded. A zero, infinity or NaN
/// comes back as `x + x` (a NaN quieted); an overflow is a signed
/// infinity and an underflow a signed zero.
pub fn ldexp(x: f64, n: i32) f64 {
    if (!std.math.isFinite(x) or x == 0) return x + x;
    return scalbn(x, n);
}

fn biasedExponent(ix: u64) i64 {
    return @intCast((ix >> 52) & 0x7ff);
}

/// `ix`'s sign and mantissa under biased exponent `k` (1 to 0x7fe).
fn withExponent(ix: u64, k: i64) f64 {
    const field: u64 = @intCast(k);
    return @bitCast((ix & 0x800fffffffffffff) | field << 52);
}

/// __scalbn for a finite nonzero x.
fn scalbn(x_in: f64, n: i32) f64 {
    var x = x_in;
    var ix: u64 = @bitCast(x);
    var k = biasedExponent(ix);
    if (k == 0) {
        // Subnormal: normalized first, its exponent taken back down.
        x *= two54;
        ix = @bitCast(x);
        k = biasedExponent(ix) - 54;
    }
    if (n < -50000) return tiny * std.math.copysign(tiny, x);
    if (n > 50000 or k + n > 0x7fe) return huge * std.math.copysign(huge, x);
    k += n;
    if (k > 0) return withExponent(ix, k);
    if (k <= -54) return tiny * std.math.copysign(tiny, x);
    // Subnormal result: the one rounding is this multiply's.
    return withExponent(ix, k + 54) * twom54;
}

fn bitsOf(v: f64) u64 {
    return @bitCast(v);
}

test "ldexp keeps zeros, infinities and NaNs, where std.math.ldexp scales a zero" {
    try std.testing.expectEqual(bitsOf(0.0), bitsOf(ldexp(0.0, 60)));
    try std.testing.expectEqual(bitsOf(0.0), bitsOf(ldexp(0.0, 2000)));
    try std.testing.expectEqual(bitsOf(-0.0), bitsOf(ldexp(-0.0, 60)));
    try std.testing.expectEqual(bitsOf(-0.0), bitsOf(ldexp(-0.0, -2000)));
    try std.testing.expect(std.math.isPositiveInf(ldexp(std.math.inf(f64), -5000)));
    try std.testing.expect(std.math.isNegativeInf(ldexp(-std.math.inf(f64), 5)));
    try std.testing.expect(std.math.isNan(ldexp(std.math.nan(f64), 3)));
}

test "ldexp rounds once, to nearest even, as glibc's ldexp" {
    // Expected values from Python's math.ldexp (C's ldexp on glibc).
    const Case = struct { x: u64, n: i32, want: u64 };
    const cases = [_]Case{
        // Ordinary scaling and the normal range's ends.
        .{ .x = 0x3ff8000000000000, .n = 10, .want = 0x4098000000000000 }, // 1.5 * 2^10
        .{ .x = 0xbff0000000000000, .n = -1022, .want = 0x8010000000000000 }, // -2^-1022
        .{ .x = 0x3ff0000000000000, .n = 1023, .want = 0x7fe0000000000000 },
        .{ .x = 0x3ff0000000000000, .n = 1024, .want = 0x7ff0000000000000 }, // overflow
        .{ .x = 0x0000000000000001, .n = 1074, .want = 0x3ff0000000000000 }, // subnormal in
        .{ .x = 0x000fffffffffffff, .n = 1, .want = 0x001ffffffffffffe },
        // Subnormal results: exact, ties to even (down and up), past half.
        .{ .x = 0x3ff0000000000000, .n = -1074, .want = 0x0000000000000001 },
        .{ .x = 0x3ff0000000000000, .n = -1075, .want = 0x0000000000000000 }, // 0.5 ulp: even 0
        .{ .x = 0x3ff8000000000000, .n = -1074, .want = 0x0000000000000002 }, // 1.5 ulp: even 2
        .{ .x = 0x4004000000000000, .n = -1074, .want = 0x0000000000000002 }, // 2.5 ulp: even 2
        .{ .x = 0x3ff0000000000001, .n = -1075, .want = 0x0000000000000001 }, // past half
        .{ .x = 0xbff8000000000000, .n = -1073, .want = 0x8000000000000003 },
        .{ .x = 0x3fefffffffffffff, .n = -1022, .want = 0x0010000000000000 }, // rounds up to normal
        .{ .x = 0x3ff0000000000000, .n = -1076, .want = 0x0000000000000000 },
        .{ .x = 0x3ff0000000000000, .n = -100000, .want = 0x0000000000000000 },
        .{ .x = 0xbff0000000000000, .n = 100000, .want = 0xfff0000000000000 },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, bitsOf(ldexp(@bitCast(c.x), c.n)));
}
