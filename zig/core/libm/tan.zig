// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/s_tan.c,
// utan.h and dla.h (IBM Accurate Mathematical Library; copyright (C)
// 2001-2026 Free Software Foundation, Inc.), as built on x86-64 in its FMA
// variant (s_tan-fma.c). The GNU C Library is free software; you can
// redistribute it and/or modify it under the terms of the GNU Lesser
// General Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any later version.
//! glibc's double `tan` (core/libm.zig): a polynomial near 0, a table
//! between 0.0608 and 0.787, after reducing modulo pi/2 for larger
//! arguments. `fma` and `fnma` mark GCC's contractions (sin.zig has the
//! rule).

const std = @import("std");
const xfg = @import("tantab.zig").xfg;
const remPio2 = @import("sin.zig").remPio2;

fn f(b: u64) f64 {
    return @bitCast(b);
}

fn fma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}

fn fnma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, -a, b, c);
}

fn low(x: f64) u32 {
    return @truncate(@as(u64, @bitCast(x)));
}

// utan.h.
const d3 = f(0x3FD5555555555555);
const d5 = f(0x3FC11111111107C6);
const d7 = f(0x3FABA1BA1CDB8745);
const d9 = f(0x3F9664ED49CFC666);
const d11 = f(0x3F82385A3CF2E4EA);
const e0 = f(0x3FD5555555554DBD);
const e1 = f(0x3FC11112E0A6B45F);
const mfftnhf = f(0xc02f000000000000);
const g1 = f(0x3e4b096c00000000);
const g2 = f(0x3faf212d00000000);
const g3 = f(0x3fe92f1a00000000);
const g4 = f(0x4039000000000000);
const g5 = f(0x4197d78400000000);
const gy2 = f(0x3faf212d00000000);
const mp1 = f(0x3FF921FB58000000);
const mp2 = f(0xBE4DDE973C000000);
const mp3 = f(0xBC8CB3B399D747F2);
const pp3 = f(0xBC8CB3B398000000);
const pp4 = f(0xbacd747f23e32ed7);
const hpinv = f(0x3FE45F306DC9C883);
const toint = f(0x4338000000000000);

/// polynomial I's terms after the first, in x2 = x^2.
fn poly1(x2: f64) f64 {
    var t2 = fma(x2, d11, d9);
    t2 = fma(x2, t2, d7);
    t2 = fma(x2, t2, d5);
    return fma(x2, t2, d3);
}

/// The table's row for y in (0.0608, 0.787).
fn row(y: f64) *const [4]u64 {
    return &xfg[@intCast(@as(i32, @intFromFloat(fma(256, y, mfftnhf))))];
}

/// pz = z + z^3 (e0 + z^2 e1).
fn polyZ(z: f64) f64 {
    const z2 = z * z;
    return fma(z * z2, fma(z2, e1, e0), z);
}

/// tan, or -cot when n is odd, of a + da with |a| <= 0.0608.
fn small(a: f64, da: f64, n: bool) f64 {
    const a2 = a * a;
    const t2 = fma(a * a2, poly1(a2), da);
    if (!n) return a + t2;
    // -cot: EADD(a, t2, b, db), then DIV2(1.0, 0.0, b, db, ...).
    const b = a + t2;
    const db = if (@abs(a) > @abs(t2)) (a - b) + t2 else (t2 - b) + a;
    const c = 1.0 / b;
    const u = c * b;
    const uu = @mulAdd(f64, c, b, -u);
    const cc = fnma(c, db, ((1.0 - u) - uu) + 0.0) / b;
    const z = c + cc;
    const zz = (c - z) + cc;
    return -(z + zz);
}

/// tan, or -cot when n is odd, of sign sy times ya + yya, ya in (0.0608,
/// 0.787).
fn tabled(ya: f64, yya: f64, sy: f64, n: bool) f64 {
    const r = row(ya);
    const z = (ya - f(r[0])) + yya;
    const pz = polyZ(z);
    const fi = f(r[1]);
    const gi = f(r[2]);
    if (n) {
        const t2 = pz * (fi + gi) / (fi + pz);
        return -sy * (gi - t2);
    }
    const t2 = pz * (gi + fi) / (gi - pz);
    return sy * (fi + t2);
}

/// The reduced argument a + da with its quadrant's parity.
fn reduced(a: f64, da: f64, n: bool) f64 {
    const neg = a < 0.0;
    const ya = if (neg) -a else a;
    const yya = if (neg) -da else da;
    const sy: f64 = if (neg) -1 else 1;
    if (ya <= gy2) return small(a, da, n);
    return tabled(ya, yya, sy, n);
}

/// glibc's tan.
pub fn tan(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x)) return x - x;
    const w = @abs(x);
    // (I) |x| <= 1.259e-8.
    if (w <= g1) return x;
    // (II) |x| <= 0.0608.
    if (w <= g2) {
        const x2 = x * x;
        return fma(poly1(x2), x * x2, x);
    }
    // (III) |x| <= 0.787.
    if (w <= g3) {
        const r = row(w);
        const z = w - f(r[0]);
        const pz = polyZ(z);
        const fi = f(r[1]);
        const gi = f(r[2]);
        const s: f64 = if (x < 0.0) -1 else 1;
        const t2 = pz * (gi + fi) / (gi - pz);
        return s * (fi + t2);
    }
    if (w <= g4) {
        // |x| <= 25: reduction by algorithm i.
        const t = fma(x, hpinv, toint);
        const xn = t - toint;
        const t1 = fnma(xn, mp2, fnma(xn, mp1, x));
        const n = low(t) & 1 != 0;
        const a = fnma(xn, mp3, t1);
        const da = fnma(xn, mp3, t1 - a);
        return reduced(a, da, n);
    }
    if (w <= g5) {
        // |x| <= 1e8: reduction by algorithm ii.
        const t = fma(x, hpinv, toint);
        const xn = t - toint;
        const t1 = fnma(xn, mp2, fnma(xn, mp1, x));
        const n = low(t) & 1 != 0;
        const tt = fnma(xn, pp3, t1);
        var da = fnma(xn, pp3, t1 - tt);
        const a0 = fnma(xn, pp4, tt);
        da = fnma(xn, pp4, tt - a0) + da;
        // EADD(a, da, t1, t2).
        const s = a0 + da;
        const ds = if (@abs(a0) > @abs(da)) (a0 - s) + da else (da - s) + a0;
        return reduced(s, ds, n);
    }
    // Reduction by algorithm iii.
    var y: [2]f64 = undefined;
    const n = remPio2(x, &y) & 1 != 0;
    const s = y[0] + y[1];
    const ds = if (@abs(y[0]) > @abs(y[1])) (y[0] - s) + y[1] else (y[1] - s) + y[0];
    return reduced(s, ds, n);
}
