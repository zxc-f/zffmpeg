// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/e_asin.c and
// uasncs.h (IBM Accurate Mathematical Library; copyright (C) 2001-2026 Free
// Software Foundation, Inc.) with math/w_asin_compat.c and w_acos_compat.c
// (copyright (C) 2011-2026 Free Software Foundation, Inc.), as built on
// x86-64 in its FMA variant (e_asin-fma.c). The GNU C Library is free
// software; you can redistribute it and/or modify it under the terms of the
// GNU Lesser General Public License as published by the Free Software
// Foundation; either version 2.1 of the License, or (at your option) any
// later version.
//! glibc's double `asin` and `acos` (core/libm.zig): a Taylor polynomial
//! near 0, tabled expansions to 0.96875, then sqrt(z) with z = (1 - |x|)/2
//! by a Newton step. `fma` and `fnma` mark GCC's contractions (sin.zig has
//! the rule).

const std = @import("std");
const t = @import("asintab.zig");
const asncs = t.asncs;

fn f(b: u64) f64 {
    return @bitCast(b);
}

fn fma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}

fn fnma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, -a, b, c);
}

fn x(i: usize) f64 {
    return f(asncs[i]);
}

const hp0 = f(0x3FF921FB54442D18);
const hp1 = f(0x3C91A62633145C07);
const f1 = 1.66666666666664110590506577996662E-01;
const f2 = 7.50000000026122686814431784722623E-02;
const f3 = 4.46428561421059750978517350006940E-02;
const f4 = 3.03821268582119319911193410625235E-02;
const f5 = 2.23551211026525610742786300334557E-02;
const f6 = 1.81382903404565056280372531963613E-02;
const t24 = 16777216.0;
const t27 = 134217728.0;
const rt0 = 9.99999999859990725855365213134618E-01;
const rt1 = 4.99999999495955425917856814202739E-01;
const rt2 = 3.75017500867345182581453026130850E-01;
const rt3 = 3.12523626554518656309172508769531E-01;

fn high(v: f64) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(v)) >> 32)));
}

/// ((((f6 v + f5) v + f4) v + f3) v + f2) v + f1.
fn polyF(v: f64) f64 {
    return fma(fma(fma(fma(fma(f6, v, f5), v, f4), v, f3), v, f2), v, f1);
}

/// A tabled interval: its start, the polynomial's degree past xx^2 (the
/// coefficients n+2 .. n+2+deg), then the constant and the value.
const Interval = struct { n: usize, deg: usize };

/// The interval of |x| in [0.125, 0.96875), from the high word's
/// magnitude k.
fn interval(k: i32) Interval {
    const ku: u32 = @intCast(k);
    if (k < 0x3fe00000) {
        if (k < 0x3fd00000) return .{ .n = 11 * ((ku & 0x000fffff) >> 15), .deg = 4 };
        return .{ .n = 11 * ((ku & 0x000fffff) >> 14) + 352, .deg = 4 };
    }
    if (k < 0x3fe80000) return .{ .n = 1056 + ((ku & 0x000fe000) >> 11) * 3, .deg = 5 };
    if (k < 0x3fed8000) return .{ .n = 992 + ((ku & 0x000fe000) >> 13) * 13, .deg = 6 };
    if (k < 0x3fee8000) return .{ .n = 884 + ((ku & 0x000fe000) >> 13) * 14, .deg = 7 };
    return .{ .n = 768 + ((ku & 0x000fe000) >> 13) * 15, .deg = 8 };
}

/// The interval's expansion at xx = |x| - x_n, less its value (the
/// returned t), and the value's index.
fn tabled(ax: f64, iv: Interval, value: *f64) f64 {
    const n = iv.n;
    const xx = ax - x(n);
    // Q = c2 + xx (c3 + ... + xx c_{2+deg}).
    var q = x(n + 2 + iv.deg);
    var j = iv.deg;
    while (j > 0) : (j -= 1) q = fma(xx, q, x(n + 1 + j));
    const p = fma(xx * xx, q, x(n + 3 + iv.deg));
    value.* = x(n + 4 + iv.deg);
    return fma(x(n + 1), xx, p);
}

/// The square root step for |x| in [0.96875, 1): z = (1 - |x|) / 2, its
/// root as y + cc and the first approximation c, its correction t.
const Root = struct { y: f64, cc: f64, p: f64 };

fn root(z: f64, comptime acos_split: bool) Root {
    const k = high(z);
    var tt = t.inroot[@intCast((k & 0x001fffff) >> 14)] * t.powtwo[@intCast(511 - (k >> 21))];
    const r = fnma(tt * tt, z, 1.0);
    tt = tt * fma(r, fma(r, fma(r, rt3, rt2), rt1), rt0);
    const c = tt * z;
    const w = fnma(0.5 * tt, c, 1.5);
    // y: c rounded to 26 bits.
    const y = if (acos_split) fnma(t27, c, fma(t27, c, c)) else (c + t24) - t24;
    // t = c w, fused into its only use, t + y.
    const cc = fnma(y, y, z) / fma(c, w, y);
    const p = polyF(z) * z;
    return .{ .y = y, .cc = cc, .p = p };
}

/// w_asin_compat.c and w_acos_compat.c, the default symbols: |x| > 1
/// (not NaN) gives __kernel_standard's NAN, a positive quiet NaN, where
/// the kernels' (x - x) / (x - x) would give x86's negative one.
fn outOfDomain(xin: f64) bool {
    return @abs(xin) > 1.0;
}

const domain_nan: f64 = @bitCast(@as(u64, 0x7ff8000000000000));

/// glibc's asin.
pub fn asin(xin: f64) f64 {
    if (outOfDomain(xin)) return domain_nan;
    const m = high(xin);
    const k = m & 0x7fffffff;
    if (k < 0x3e500000) return xin; // asin(x) = x below 2^-26
    if (k < 0x3fc00000) {
        // 2^-26 <= |x| < 2^-3.
        const x2 = xin * xin;
        return fma(polyF(x2), x2 * xin, xin);
    }
    if (k < 0x3fef0000) {
        // 0.125 <= |x| < 0.96875.
        const ax = if (m > 0) xin else -xin;
        var value: f64 = undefined;
        const tt = tabled(ax, interval(k), &value);
        const res = value + tt;
        return if (m > 0) res else -res;
    }
    if (k < 0x3ff00000) {
        // 0.96875 <= |x| < 1.
        const z = 0.5 * (if (m > 0) 1.0 - xin else 1.0 + xin);
        const s = root(z, false);
        const cor = fnma(2.0 * (s.y + s.cc), s.p, fnma(2.0, s.cc, hp1));
        const res1 = fnma(2.0, s.y, hp0);
        const res = res1 + cor;
        return if (m > 0) res else -res;
    }
    if (k == 0x3ff00000 and @as(u32, @truncate(@as(u64, @bitCast(xin)))) == 0) return if (m > 0) hp0 else -hp0;
    return (xin - xin) / (xin - xin);
}

/// glibc's acos.
pub fn acos(xin: f64) f64 {
    if (outOfDomain(xin)) return domain_nan;
    const m = high(xin);
    const k = m & 0x7fffffff;
    if (k < 0x3c880000) return hp0; // |x| < 2.77556e-17
    if (k < 0x3fc00000) {
        // |x| < 2^-3.
        const x2 = xin * xin;
        const r = hp0 - xin;
        const cor = fnma(polyF(x2), x2 * xin, ((hp0 - r) - xin) + hp1);
        return r + cor;
    }
    if (k < 0x3fef0000) {
        // 0.125 <= |x| < 0.96875.
        const ax = if (m > 0) xin else -xin;
        var value: f64 = undefined;
        const tt = tabled(ax, interval(k), &value);
        const y = if (m > 0) hp0 - value else hp0 + value;
        const t2 = if (m > 0) hp1 - tt else hp1 + tt;
        return y + t2;
    }
    if (k < 0x3ff00000) {
        // 0.96875 <= |x| < 1.
        const z = 0.5 * (if (m > 0) 1.0 - xin else 1.0 + xin);
        const s = root(z, true);
        // GCC hoists the product both signs compute above their branch,
        // where it cannot fuse.
        const prod = (s.y + s.cc) * s.p;
        if (m < 0) {
            const cor = (hp1 - s.cc) - prod;
            const res = (hp0 - s.y) + cor;
            return res + res;
        }
        const res = s.y + (s.cc + prod);
        return res + res;
    }
    if (k == 0x3ff00000 and @as(u32, @truncate(@as(u64, @bitCast(xin)))) == 0) return if (m > 0) 0 else 2.0 * hp0;
    return (xin - xin) / (xin - xin);
}
