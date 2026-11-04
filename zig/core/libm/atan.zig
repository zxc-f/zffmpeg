// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/s_atan.c,
// atnat.h and dla.h (IBM Accurate Mathematical Library; copyright (C)
// 2001-2026 Free Software Foundation, Inc.), as built on x86-64 in its FMA
// variant (s_atan-fma.c). The GNU C Library is free software; you can
// redistribute it and/or modify it under the terms of the GNU Lesser
// General Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any later version.
//! glibc's double `atan` (core/libm.zig): a polynomial near 0 and past 16,
//! a table of Taylor expansions between. `fma` and `fnma` mark GCC's
//! contractions (sin.zig has the rule).

const std = @import("std");
const cij = @import("atantab.zig").cij;

fn f(b: u64) f64 {
    return @bitCast(b);
}

fn fma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}

fn fnma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, -a, b, c);
}

// atnat.h, polynomial I.
const d3 = f(0xbfd5555555555555);
const d5 = f(0x3fc99999999997fd);
const d7 = f(0xbfc24924923f7603);
const d9 = f(0x3fbc71c6e5129a3b);
const d11 = f(0xbfb7458022b13c25);
const d13 = f(0x3fb375f08b31cbce);
// Constants: the bounds A to E, pi/2 and its low part.
const lim_a = f(0x3e4bb67a00000000);
const lim_b = f(0x3fb0000000000000);
const lim_c = f(0x3ff0000000000000);
const lim_d = f(0x4030000000000000);
const lim_e = f(0x43349ff200000000);
pub const hpi = f(0x3ff921fb54442d18);
const mhpi = f(0xbff921fb54442d18);
pub const hpi1 = f(0x3c91a62633145c07);

const two52 = 0x1.0p52;

/// polynomial I in v = x^2, without its first term.
fn poly1(v: f64) f64 {
    var yy = fma(v, d13, d11);
    yy = fma(v, yy, d9);
    yy = fma(v, yy, d7);
    yy = fma(v, yy, d5);
    return fma(v, yy, d3);
}

/// The table row for u in [1/16, 1).
fn row(u: f64) usize {
    const t = fma(256, u, two52) - two52;
    return @as(usize, @intFromFloat(t)) - 16;
}

/// The row's polynomial in z, without its constant term.
fn polyRow(r: *const [7]u64, z: f64) f64 {
    var yy = fma(z, f(r[6]), f(r[5]));
    yy = fma(z, yy, f(r[4]));
    yy = fma(z, yy, f(r[3]));
    return fma(z, yy, f(r[2]));
}

/// glibc's atan.
pub fn atan(x: f64) f64 {
    if (std.math.isNan(x)) return x + x;
    const u = @abs(x);
    if (u < lim_c) {
        if (u < lim_b) {
            if (u < lim_a) return x;
            // A <= u < B. Max ULP 0.511.
            const v = x * x;
            return fma(poly1(v), x * v, x);
        }
        // B <= u < C. Max ULP 0.56.
        const r = &cij[row(u)];
        const z = u - f(r[0]);
        return std.math.copysign(fma(polyRow(r, z), z, f(r[1])), x);
    }
    if (u < lim_d) {
        // C <= u < D. Max ULP 0.503.
        const w = 1 / u;
        // EMULV with FMA: w * u as t1 + t2 exactly.
        const t1 = w * u;
        const t2 = @mulAdd(f64, w, u, -t1);
        const r = &cij[row(w)];
        const z = fma(w, (1 - t1) - t2, w - f(r[0]));
        const yy = fnma(z, polyRow(r, z), hpi1);
        const t = hpi - f(r[1]);
        return std.math.copysign(t + yy, x);
    }
    if (u < lim_e) {
        // D <= u < E. Max ULP 0.5003.
        const w = 1 / u;
        const v = w * w;
        const t1 = w * u;
        const t2 = @mulAdd(f64, w, u, -t1);
        // ESUB(HPI, w, t3, cor).
        const t3 = hpi - w;
        const cor = if (@abs(hpi) > @abs(w)) ((hpi - t3) - w) else (hpi - (w + t3));
        const yy = fnma(poly1(v), w * v, fnma(w, (1 - t1) - t2, hpi1 + cor));
        return std.math.copysign(t3 + yy, x);
    }
    return if (x > 0) hpi else mhpi;
}
