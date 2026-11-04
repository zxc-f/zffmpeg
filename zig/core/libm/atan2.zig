// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/e_atan2.c,
// atnat2.h and dla.h (IBM Accurate Mathematical Library; copyright (C)
// 2001-2026 Free Software Foundation, Inc.), as built on x86-64 in its FMA
// variant (e_atan2-fma.c). The GNU C Library is free software; you can
// redistribute it and/or modify it under the terms of the GNU Lesser
// General Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any later version.
//! glibc's double `atan2` (core/libm.zig): the quotient of the smaller
//! magnitude by the larger as u + du, then atan's polynomial or table,
//! placed in its quadrant. `fma` and `fnma` mark GCC's contractions
//! (sin.zig has the rule).

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

// atnat2.h.
const d3 = f(0xbfd5555555555555);
const d5 = f(0x3fc99999999997fd);
const d7 = f(0xbfc24924923f7603);
const d9 = f(0x3fbc71c6e5129a3b);
const d11 = f(0xbfb7458022b13c25);
const d13 = f(0x3fb375f08b31cbce);
const inv16 = f(0x3fb0000000000000);
const opi = f(0x400921fb54442d18);
const opi1 = f(0x3ca1a62633145c07);
const mopi = f(0xc00921fb54442d18);
const hpi = f(0x3ff921fb54442d18);
const hpi1 = f(0x3c91a62633145c07);
const mhpi = f(0xbff921fb54442d18);
const qpi = f(0x3fe921fb54442d18);
const mqpi = f(0xbfe921fb54442d18);
const tqpi = f(0x4002d97c7f3321d2);
const mtqpi = f(0xc002d97c7f3321d2);
const two500 = f(0x5f30000000000000);
const twom500 = f(0x20b0000000000000);

const two52 = 0x1.0p52;

fn words(x: f64) struct { hi: i32, lo: i32 } {
    const b: u64 = @bitCast(x);
    return .{ .hi = @bitCast(@as(u32, @truncate(b >> 32))), .lo = @bitCast(@as(u32, @truncate(b))) };
}

/// The polynomial d3 + v (d5 + ... + v d13).
fn poly(v: f64) f64 {
    return fma(v, fma(v, fma(v, fma(v, fma(v, d13, d11), d9), d7), d5), d3);
}

/// The table row for u in [1/16, 1).
fn row(u: f64) *const [7]u64 {
    const t = fma(256, u, two52) - two52;
    return &cij[@as(usize, @intFromFloat(t)) - 16];
}

/// The row's polynomial c2 + v (c3 + ... + v c6).
fn polyRow(r: *const [7]u64, v: f64) f64 {
    return fma(v, fma(v, fma(v, fma(v, f(r[6]), f(r[5])), f(r[4])), f(r[3])), f(r[2]));
}

/// glibc's atan2.
pub fn atan2(y: f64, x: f64) f64 {
    const wx = words(x);
    const wy = words(y);
    const ux = wx.hi;
    const dx = wx.lo;
    const uy = wy.hi;
    const dy = wy.lo;
    if (ux & 0x7ff00000 == 0x7ff00000 and ((ux & 0x000fffff) | dx) != 0) return x + y;
    if (uy & 0x7ff00000 == 0x7ff00000 and ((uy & 0x000fffff) | dy) != 0) return y + y;
    // y = +-0.
    if (uy == 0 and dy == 0) return if (ux & @as(i32, @bitCast(@as(u32, 0x80000000))) == 0) 0 else opi;
    if (uy == @as(i32, @bitCast(@as(u32, 0x80000000))) and dy == 0) return if (ux & @as(i32, @bitCast(@as(u32, 0x80000000))) == 0) -0.0 else mopi;
    // x = +-0.
    if (x == 0) return if (uy >= 0) hpi else mhpi;
    const pinf: i32 = 0x7ff00000;
    const ninf: i32 = @bitCast(@as(u32, 0xfff00000));
    // x = +-inf.
    if (ux == pinf and dx == 0) {
        if (uy == pinf) {
            if (dy == 0) return qpi;
        } else if (uy == ninf) {
            if (dy == 0) return mqpi;
        } else return if (uy >= 0) 0 else -0.0;
    } else if (ux == ninf and dx == 0) {
        if (uy == pinf) {
            if (dy == 0) return tqpi;
        } else if (uy == ninf) {
            if (dy == 0) return mtqpi;
        } else return if (uy >= 0) opi else mopi;
    }
    // y = +-inf.
    if (uy == pinf) {
        if (dy == 0) return hpi;
    } else if (uy == ninf) {
        if (dy == 0) return mhpi;
    }

    var ax = if (x < 0) -x else x;
    var ay = if (y < 0) -y else y;
    // Either quotient very close to zero.
    const de = (uy & 0x7ff00000) - (ux & 0x7ff00000);
    if (de >= 59768832) return if (y > 0) hpi else mhpi;
    if (de <= -59768832) {
        if (x > 0) return std.math.copysign(ay / ax, y);
        return if (y > 0) opi else mopi;
    }
    // Scale extreme magnitudes.
    if (ax < twom500 or ay < twom500) {
        ax *= two500;
        ay *= two500;
    }
    if (ax > two500 or ay > two500) {
        ax *= twom500;
        ay *= twom500;
    }
    var u: f64 = undefined;
    var du: f64 = undefined;
    if (ay < ax) {
        u = ay / ax;
        const v = ax * u;
        const vv = @mulAdd(f64, ax, u, -v);
        du = ((ay - v) - vv) / ax;
    } else {
        u = ax / ay;
        const v = ay * u;
        const vv = @mulAdd(f64, ay, u, -v);
        du = ((ax - v) - vv) / ay;
    }
    if (x > 0) {
        // (i) x > 0, |y| < |x|: atan(ay / ax).
        if (ay < ax) {
            if (u < inv16) {
                const v = u * u;
                const zz = fma(u * v, poly(v), du);
                return std.math.copysign(u + zz, y);
            }
            const r = row(u);
            const t3 = u - f(r[0]);
            // EADD(t3, du, v, dv).
            const v = t3 + du;
            const dv = if (@abs(t3) > @abs(du)) (t3 - v) + du else (du - v) + t3;
            const t1 = f(r[1]);
            const t2 = f(r[2]);
            const q = fma(v, fma(v, fma(v, f(r[6]), f(r[5])), f(r[4])), f(r[3]));
            const zz = fma(v, t2, fma(dv, t2, (v * v) * q));
            return std.math.copysign(t1 + zz, y);
        }
        // (ii) x > 0, |x| <= |y|: pi/2 - atan(ax / ay).
        if (u < inv16) {
            const v = u * u;
            // Not fused: ESUB's branch separates zz from its use.
            const zz = (u * v) * poly(v);
            // ESUB(hpi, u, t2, cor).
            const t2 = hpi - u;
            const cor = if (@abs(hpi) > @abs(u)) ((hpi - t2) - u) else (hpi - (u + t2));
            const t3 = ((hpi1 + cor) - du) - zz;
            return std.math.copysign(t2 + t3, y);
        }
        const r = row(u);
        const v = (u - f(r[0])) + du;
        const zz = fnma(v, polyRow(r, v), hpi1);
        const t1 = hpi - f(r[1]);
        return std.math.copysign(t1 + zz, y);
    }
    // (iii) x < 0, |x| < |y|: pi/2 + atan(ax / ay).
    if (ax < ay) {
        if (u < inv16) {
            const v = u * u;
            // Not fused: EADD's branch separates zz from its use.
            const zz = (u * v) * poly(v);
            // EADD(hpi, u, t2, cor).
            const t2 = hpi + u;
            const cor = if (@abs(hpi) > @abs(u)) ((hpi - t2) + u) else ((u - t2) + hpi);
            const t3 = ((hpi1 + cor) + du) + zz;
            return std.math.copysign(t2 + t3, y);
        }
        const r = row(u);
        const v = (u - f(r[0])) + du;
        const zz = fma(v, polyRow(r, v), hpi1);
        const t1 = hpi + f(r[1]);
        return std.math.copysign(t1 + zz, y);
    }
    // (iv) x < 0, |y| <= |x|: pi - atan(ax / ay).
    if (u < inv16) {
        const v = u * u;
        // Not fused: ESUB's branch separates zz from its use.
        const zz = (u * v) * poly(v);
        // ESUB(opi, u, t2, cor).
        const t2 = opi - u;
        const cor = if (@abs(opi) > @abs(u)) ((opi - t2) - u) else (opi - (u + t2));
        const t3 = ((opi1 + cor) - du) - zz;
        return std.math.copysign(t2 + t3, y);
    }
    const r = row(u);
    const v = (u - f(r[0])) + du;
    const zz = fnma(v, polyRow(r, v), opi1);
    const t1 = opi - f(r[1]);
    return std.math.copysign(t1 + zz, y);
}
