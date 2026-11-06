// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/s_cbrt.c
// (copyright (C) 1997-2026 Free Software Foundation, Inc.), which x86-64
// builds as it is, without an FMA variant. The GNU C Library is free
// software; you can redistribute it and/or modify it under the terms of the
// GNU Lesser General Public License as published by the Free Software
// Foundation; either version 2.1 of the License, or (at your option) any
// later version.
//! glibc's double `cbrt` (core/libm.zig): a polynomial first guess on the
//! mantissa in [0.5, 1), one Halley step, the exponent's third scaled by
//! 2^(1/3) or 2^(2/3). It is not correctly rounded, and Zig 0.17's
//! `std.math.cbrt` (musl's) differs from it for 3346 of the integers 0 to
//! 8207 that FFmpeg's MP3 tables take the cube root of (notes.md
//! "Floating-point library").

const std = @import("std");
const ldexp = @import("ldexp.zig").ldexp;

const cbrt2: f64 = 1.2599210498948731648; // 2^(1/3)
const sqr_cbrt2: f64 = 1.5874010519681994748; // 2^(2/3)

const factor = [5]f64{ 1.0 / sqr_cbrt2, 1.0 / cbrt2, 1.0, cbrt2, sqr_cbrt2 };

/// glibc's `cbrt`. Each product and sum rounds on its own, as the generic
/// x86-64 build computes it (no contraction into fused multiply-adds).
pub fn cbrt(x: f64) f64 {
    @setFloatMode(.strict);
    // glibc returns x + x for a zero, an infinity or a NaN.
    if (x == 0 or !std.math.isFinite(x)) return x + x;
    const parts = std.math.frexp(@abs(x));
    const xm = parts.significand;
    const xe = parts.exponent;
    const u = 0.354895765043919860 +
        (1.50819193781584896 +
            (-2.11499494167371287 +
                (2.44693122563534430 +
                    (-1.83469277483613086 +
                        (0.784932344976639262 - 0.145263899385486377 * xm) * xm) * xm) * xm) * xm) * xm;
    const t2 = u * u * u;
    // C's `%` and `/` truncate toward zero: xe % 3 lies in -2..2.
    const index: usize = @intCast(2 + @rem(xe, 3));
    const ym = u * (t2 + 2.0 * xm) / (2.0 * t2 + xm) * factor[index];
    return ldexp(if (x > 0.0) ym else -ym, @divTrunc(xe, 3));
}

test "cbrt keeps zeros, infinities and NaN, and its sign" {
    try std.testing.expectEqual(0.0, cbrt(0.0));
    try std.testing.expect(std.math.signbit(cbrt(-0.0)));
    try std.testing.expectEqual(std.math.inf(f64), cbrt(std.math.inf(f64)));
    try std.testing.expectEqual(-std.math.inf(f64), cbrt(-std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(cbrt(std.math.nan(f64))));
    try std.testing.expectEqual(-cbrt(27.0), cbrt(-27.0));
    // glibc's results, not correctly rounded: cbrt(27) is 3 plus one ulp.
    try std.testing.expectEqual(0x4008000000000001, @as(u64, @bitCast(cbrt(27.0))));
    try std.testing.expectEqual(2.0, cbrt(8.0));
}
