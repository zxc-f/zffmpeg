// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/s_sin.c and
// usncs.h (IBM Accurate Mathematical Library; copyright (C) 2001-2026 Free
// Software Foundation, Inc.), e_rem_pio2.c and k_rem_pio2.c (from Sun's
// fdlibm; copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
// Developed at SunSoft, a Sun Microsystems, Inc. business. Permission to
// use, copy, modify, and distribute this software is freely granted,
// provided that this notice is preserved.), as built on x86-64: sin and
// cos in their FMA variant (s_sin-fma.c), the reduction without FMA. The
// GNU C Library is free software; you can redistribute it and/or modify it
// under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation; either version 2.1 of the License, or (at
// your option) any later version.
//! glibc's double `sin` and `cos` (core/libm.zig). GCC compiles the FMA
//! variant with contraction: each product whose only uses are additions
//! or subtractions is fused into them, and of `a * b + c * d` the first
//! product; `fma`, `fms` and `fnma` below are where it did.

const std = @import("std");
const tab = @import("sincostab.zig").sincostab;
/// k_rem_pio2.c's scalbn. Its q0 stays in [-21, 2] at the first call, so
/// std.math.ldexp's zero bug (n > 53) was never reached here; the shared
/// helper is glibc's, bit for bit.
const ldexp = @import("ldexp.zig").ldexp;

fn f(b: u64) f64 {
    return @bitCast(b);
}

/// a * b + c, rounded once.
fn fma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}

/// c - a * b, rounded once.
fn fnma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, -a, b, c);
}

/// a * b - c, rounded once.
fn fms(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, -c);
}

fn high(x: f64) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(x)) >> 32)));
}

fn low(x: f64) u32 {
    return @truncate(@as(u64, @bitCast(x)));
}

// usncs.h.
const s1 = -0x1.5555555555555p-3;
const s2 = 0x1.1111111110ECEp-7;
const s3 = -0x1.A01A019DB08B8p-13;
const s4 = 0x1.71DE27B9A7ED9p-19;
const s5 = -0x1.ADDFFC2FCDF59p-26;
const big = 0x1.8000000000000p45;
const hp0 = 0x1.921FB54442D18p0;
const hp1 = 0x1.1A62633145C07p-54;
const mp1 = 0x1.921FB58000000p0;
const mp2 = -0x1.DDE973C000000p-27;
const pp3 = -0x1.CB3B398000000p-55;
const pp4 = -0x1.d747f23e32ed7p-83;
const hpinv = 0x1.45F306DC9C883p-1;
const toint = 0x1.8000000000000p52;

// s_sin.c.
const sn3 = -1.66666666666664880952546298448555E-01;
const sn5 = 8.33333214285722277379541354343671E-03;
const cs2 = 4.99999999999999999999950396842453E-01;
const cs4 = -4.16666666666664434524222570944589E-02;
const cs6 = 1.38888874007937613028114285595617E-03;

/// TAYLOR_SIN.
fn taylorSin(xx: f64, x: f64, dx: f64) f64 {
    const poly = fma(fma(fma(fma(s5, xx, s4), xx, s3), xx, s2), xx, s1);
    const t = fma(fms(poly, x, 0.5 * dx), xx, dx);
    return x + t;
}

/// SINCOS_TABLE_LOOKUP: sin, its correction, cos, its correction.
fn lookup(u: f64) [4]f64 {
    const k: usize = @intCast(@as(i32, @bitCast(low(u))) << 2);
    return .{ f(tab[k]), f(tab[k + 1]), f(tab[k + 2]), f(tab[k + 3]) };
}

fn doCos(x_in: f64, dx_in: f64) f64 {
    var dx = dx_in;
    if (x_in < 0) dx = -dx;
    const u = big + @abs(x_in);
    const x = @abs(x_in) - (u - big) + dx;
    const xx = x * x;
    const s = fma(x * xx, fma(xx, sn5, sn3), x);
    const c = xx * fma(xx, fma(xx, cs6, cs4), cs2);
    const t = lookup(u);
    const sn = t[0];
    const ssn = t[1];
    const cs = t[2];
    const ccs = t[3];
    const cor = fnma(sn, s, fnma(cs, c, fnma(s, ssn, ccs)));
    return cs + cor;
}

fn doSin(x_in: f64, dx_in: f64) f64 {
    const xold = x_in;
    // Max ULP 0.501 for |x| < 0.126, else 0.518.
    if (@abs(x_in) < 0.126) return taylorSin(x_in * x_in, x_in, dx_in);
    var dx = dx_in;
    if (x_in <= 0) dx = -dx;
    const u = big + @abs(x_in);
    const x = @abs(x_in) - (u - big);
    const xx = x * x;
    const s = x + fma(x * xx, fma(xx, sn5, sn3), dx);
    const c = fma(x, dx, xx * fma(xx, fma(xx, cs6, cs4), cs2));
    const t = lookup(u);
    const sn = t[0];
    const ssn = t[1];
    const cs = t[2];
    const ccs = t[3];
    const cor = fma(cs, s, fnma(sn, c, fma(s, ccs, ssn)));
    return std.math.copysign(sn + cor, xold);
}

/// reduce_sincos: x modulo pi/2 for |x| < 105414350, as a + da, and the
/// quadrant.
fn reduceSincos(x: f64, a: *f64, da: *f64) i32 {
    const t = fma(x, hpinv, toint);
    const xn = t - toint;
    const y = fnma(xn, mp2, fnma(xn, mp1, x));
    const n: i32 = @intCast(low(t) & 3);
    const t2 = fnma(xn, pp3, y);
    var db = fnma(xn, pp3, y - t2);
    const b = fnma(xn, pp4, t2);
    db += fnma(xn, pp4, t2 - b);
    a.* = b;
    da.* = db;
    return n;
}

fn doSincos(a: f64, da: f64, n: i32) f64 {
    const r = if (n & 1 != 0) doCos(a, da) else doSin(a, da);
    return if (n & 2 != 0) -r else r;
}

/// glibc's sin.
pub fn sin(x: f64) f64 {
    const k = high(x) & 0x7fffffff;
    if (k < 0x3e500000) return x; // sin(x) = x below 2^-26
    if (k < 0x3feb6000) return doSin(x, 0); // to 0.855469
    if (k < 0x400368fd) return std.math.copysign(doCos(hp0 - @abs(x), hp1), x); // to 2.426265
    if (k < 0x419921FB) {
        var a: f64 = undefined;
        var da: f64 = undefined;
        const n = reduceSincos(x, &a, &da);
        return doSincos(a, da, n);
    }
    if (k < 0x7ff00000) {
        var y: [2]f64 = undefined;
        const n = remPio2(x, &y);
        return doSincos(y[0], y[1], n);
    }
    return x / x;
}

/// glibc's cos.
pub fn cos(x: f64) f64 {
    const k = high(x) & 0x7fffffff;
    if (k < 0x3e400000) return 1.0; // below 2^-27
    if (k < 0x3feb6000) return doCos(x, 0);
    if (k < 0x400368fd) {
        const y = hp0 - @abs(x);
        const a = y + hp1;
        const da = (y - a) + hp1;
        return doSin(a, da);
    }
    if (k < 0x419921FB) {
        var a: f64 = undefined;
        var da: f64 = undefined;
        const n = reduceSincos(x, &a, &da);
        return doSincos(a, da, n + 1);
    }
    if (k < 0x7ff00000) {
        var y: [2]f64 = undefined;
        const n = remPio2(x, &y);
        return doSincos(y[0], y[1], n + 1);
    }
    return x / x;
}

/// e_rem_pio2.c's two_over_pi, 24 bits per entry.
const two_over_pi = [_]i32{
    0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
    0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
    0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
    0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
    0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
    0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
    0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
    0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
    0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
    0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
    0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,
};

const two24 = 1.67772160000000000000e+07;
const twon24 = 5.96046447753906250000e-08;

/// __ieee754_rem_pio2 for finite |x| >= 105414350: x modulo pi/2 as
/// y[0] + y[1], and the quadrant.
pub fn remPio2(x: f64, y: *[2]f64) i32 {
    const hx = high(x);
    const ix = hx & 0x7fffffff;
    const e0: i32 = (ix >> 20) - 1046;
    var z: f64 = @bitCast(@as(u64, @as(u32, @bitCast(ix - (e0 << 20)))) << 32 | low(x));
    var tx: [3]f64 = undefined;
    for (0..2) |i| {
        tx[i] = @floatFromInt(@as(i32, @intFromFloat(z)));
        z = (z - tx[i]) * two24;
    }
    tx[2] = z;
    var nx: usize = 3;
    while (tx[nx - 1] == 0) nx -= 1;
    const n = kernelRemPio2(tx[0..nx], y, e0, 2, &two_over_pi);
    if (hx < 0) {
        y[0] = -y[0];
        y[1] = -y[1];
        return -n;
    }
    return n;
}

const init_jk = [_]i32{ 2, 3, 4, 6 };

const pio2_parts = [_]f64{
    1.57079625129699707031e+00,
    7.54978941586159635335e-08,
    5.39030252995776476554e-15,
    3.28200341580791294123e-22,
    1.27065575308067607349e-29,
    1.22933308981111328932e-36,
    2.73370053816464559624e-44,
    2.16741683877804819444e-51,
};

fn truncI32(v: f64) i32 {
    return @intFromFloat(v);
}

/// __kernel_rem_pio2 for prec 2 (two doubles out), as e_rem_pio2.c calls
/// it.
fn kernelRemPio2(x: []const f64, y: *[2]f64, e0: i32, prec: usize, ipio2: []const i32) i32 {
    var iq: [20]i32 = undefined;
    var fv: [20]f64 = undefined;
    var fq: [20]f64 = undefined;
    var q: [20]f64 = undefined;
    const jk: i32 = init_jk[prec];
    const jp = jk;
    const jx: i32 = @as(i32, @intCast(x.len)) - 1;
    var jv: i32 = @divTrunc(e0 - 3, 24);
    if (jv < 0) jv = 0;
    var q0: i32 = e0 - 24 * (jv + 1);

    var j: i32 = jv - jx;
    const m = jx + jk;
    var i: i32 = 0;
    while (i <= m) : ({
        i += 1;
        j += 1;
    }) fv[@intCast(i)] = if (j < 0) 0 else @floatFromInt(ipio2[@intCast(j)]);

    i = 0;
    while (i <= jk) : (i += 1) {
        var fw: f64 = 0;
        j = 0;
        while (j <= jx) : (j += 1) fw += x[@intCast(j)] * fv[@intCast(jx + i - j)];
        q[@intCast(i)] = fw;
    }

    var jz = jk;
    var z: f64 = undefined;
    var n: i32 = undefined;
    var ih: i32 = undefined;
    while (true) {
        // Distill q[] into iq[] reversingly.
        i = 0;
        j = jz;
        z = q[@intCast(jz)];
        while (j > 0) : ({
            i += 1;
            j -= 1;
        }) {
            const fw: f64 = @floatFromInt(truncI32(twon24 * z));
            iq[@intCast(i)] = truncI32(z - two24 * fw);
            z = q[@intCast(j - 1)] + fw;
        }
        z = ldexp(z, q0);
        z -= 8.0 * @floor(z * 0.125);
        n = truncI32(z);
        z -= @floatFromInt(n);
        ih = 0;
        const top: usize = @intCast(jz - 1);
        if (q0 > 0) {
            const t = iq[top] >> @intCast(24 - q0);
            n += t;
            iq[top] -= t << @intCast(24 - q0);
            ih = iq[top] >> @intCast(23 - q0);
        } else if (q0 == 0) {
            ih = iq[top] >> 23;
        } else if (z >= 0.5) {
            ih = 2;
        }
        if (ih > 0) {
            n += 1;
            var carry = false;
            for (iq[0..@intCast(jz)]) |*v| {
                const w = v.*;
                if (!carry) {
                    if (w != 0) {
                        carry = true;
                        v.* = 0x1000000 - w;
                    }
                } else v.* = 0xffffff - w;
            }
            if (q0 > 0) {
                switch (q0) {
                    1 => iq[top] &= 0x7fffff,
                    2 => iq[top] &= 0x3fffff,
                    else => {},
                }
            }
            if (ih == 2) {
                z = 1.0 - z;
                if (carry) z -= ldexp(1.0, q0);
            }
        }
        // Recompute with more terms when needed.
        if (z == 0) {
            j = 0;
            i = jz - 1;
            while (i >= jk) : (i -= 1) j |= iq[@intCast(i)];
            if (j == 0) {
                var k: i32 = 1;
                while (iq[@intCast(jk - k)] == 0) k += 1;
                i = jz + 1;
                while (i <= jz + k) : (i += 1) {
                    fv[@intCast(jx + i)] = @floatFromInt(ipio2[@intCast(jv + i)]);
                    var fw: f64 = 0;
                    j = 0;
                    while (j <= jx) : (j += 1) fw += x[@intCast(j)] * fv[@intCast(jx + i - j)];
                    q[@intCast(i)] = fw;
                }
                jz += k;
                continue;
            }
        }
        break;
    }

    // Chop off zero terms.
    if (z == 0.0) {
        jz -= 1;
        q0 -= 24;
        while (iq[@intCast(jz)] == 0) {
            jz -= 1;
            q0 -= 24;
        }
    } else {
        // Break z into 24 bits if necessary.
        z = ldexp(z, -q0);
        if (z >= two24) {
            const fw: f64 = @floatFromInt(truncI32(twon24 * z));
            iq[@intCast(jz)] = truncI32(z - two24 * fw);
            jz += 1;
            q0 += 24;
            iq[@intCast(jz)] = truncI32(fw);
        } else {
            iq[@intCast(jz)] = truncI32(z);
        }
    }
    std.debug.assert(jz >= 0);

    // The integer chunks as floating point.
    var fw = ldexp(1.0, q0);
    i = jz;
    while (i >= 0) : (i -= 1) {
        q[@intCast(i)] = fw * @as(f64, @floatFromInt(iq[@intCast(i)]));
        fw *= twon24;
    }
    // PIo2[0 .. jp] * q[jz .. 0].
    i = jz;
    while (i >= 0) : (i -= 1) {
        fw = 0;
        var k: i32 = 0;
        while (k <= jp and k <= jz - i) : (k += 1) fw += pio2_parts[@intCast(k)] * q[@intCast(i + k)];
        fq[@intCast(jz - i)] = fw;
    }
    // Compress fq[] into y[] (prec 1 or 2).
    var s: f64 = 0;
    i = jz;
    while (i >= 0) : (i -= 1) s += fq[@intCast(i)];
    y[0] = if (ih == 0) s else -s;
    s = fq[0] - s;
    i = 1;
    while (i <= jz) : (i += 1) s += fq[@intCast(i)];
    y[1] = if (ih == 0) s else -s;
    return n & 7;
}
