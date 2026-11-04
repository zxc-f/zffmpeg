// SPDX-License-Identifier: MIT
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/e_sinh.c,
// e_cosh.c, s_tanh.c and ddcoremath.h, from the CORE-MATH project
// (https://core-math.gitlabpages.inria.fr/); copyright (c) 2023-2026
// Alexei Sibidanov (s_tanh.c: Alexei Sibidanov, Cyprien Peignier, Paul
// Zimmermann). Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the
// following conditions: The above copyright notice and this permission
// notice shall be included in all copies or substantial portions of the
// Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.
//! glibc's double `sinh`, `cosh` and `tanh` (core/libm.zig), correctly
//! rounded since 2.44: a fast double-double evaluation whose error bound
//! decides, else an accurate one, else a table of hard cases. Being
//! correctly rounded, their results do not depend on where GCC fused
//! operations, so this port computes as the C source reads, with its
//! explicit `fma` calls only (the authors checked the fast paths' bounds
//! with and without contraction).

const std = @import("std");
const tab = @import("hyptab.zig");

const mantissa_mask: u64 = (1 << 52) - 1;

fn fma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}

fn bits(x: f64) u64 {
    return @bitCast(x);
}

fn double(b: u64) f64 {
    return @bitCast(b);
}

fn copysign(x: f64, y: f64) f64 {
    return std.math.copysign(x, y);
}

/// A double-double: high part and low part.
const DD = struct { h: f64, l: f64 };

fn fasttwosum(x: f64, y: f64) DD {
    const s = x + y;
    const z = s - x;
    return .{ .h = s, .l = y - z };
}

fn fasttwosub(x: f64, y: f64) DD {
    const s = x - y;
    const z = x - s;
    return .{ .h = s, .l = z - y };
}

fn muldd2(xh: f64, xl: f64, ch: f64, cl: f64) DD {
    const ahhh = ch * xh;
    return .{ .h = ahhh, .l = (ch * xl + cl * xh) + fma(ch, xh, -ahhh) };
}

fn mulddAcc(xh: f64, xl: f64, ch: f64, cl: f64) DD {
    const ahlh = ch * xl;
    const alhh = cl * xh;
    const ahhh = ch * xh;
    var ahhl = fma(ch, xh, -ahhh);
    ahhl += alhh + ahlh;
    const h = ahhh + ahhl;
    return .{ .h = h, .l = (ahhh - h) + ahhl };
}

fn mulddAcc2(xh: f64, xl: f64, ch: f64, cl: f64) DD {
    const ahlh = ch * xl;
    const alhh = cl * xh;
    const ahhh = ch * xh;
    var ahhl = fma(ch, xh, -ahhh);
    ahhl += alhh + ahlh;
    return fasttwosum(ahhh, ahhl);
}

fn mulddd3(xh: f64, xl: f64, ch: f64) DD {
    const hh = xh * ch;
    return .{ .h = hh, .l = fma(ch, xh, -hh) + xl * ch };
}

fn mulddd_acc(xh: f64, xl: f64, ch: f64) DD {
    const ahlh = ch * xl;
    const ahhh = ch * xh;
    var ahhl = fma(ch, xh, -ahhh);
    ahhl += ahlh;
    return fasttwosum(ahhh, ahhl);
}

/// polydd_sinh and polydd_cosh: Horner in double-double from the top,
/// whose upper part `l.*` was evaluated in double.
fn polyddSinh(xh: f64, xl: f64, c: []const [2]f64, l: *f64) f64 {
    var i = c.len - 1;
    var r = fasttwosum(c[i][0], l.*);
    var cl = r.l + c[i][1];
    var ch = r.h;
    while (i > 0) {
        i -= 1;
        const m = muldd2(xh, xl, ch, cl);
        r = fasttwosum(c[i][0], m.h);
        ch = r.h;
        cl = (m.l + c[i][1]) + r.l;
    }
    l.* = cl;
    return ch;
}

/// ddcoremath.h's polydd.
fn polydd(xh: f64, xl: f64, c: []const [2]f64, l: *f64) f64 {
    var i = c.len - 1;
    const r = fasttwosum(c[i][0], l.*);
    var ch = r.h;
    var cl = r.l + c[i][1];
    while (i > 0) {
        i -= 1;
        const m = mulddAcc(xh, xl, ch, cl);
        ch = m.h;
        cl = m.l;
        const th = ch + c[i][0];
        const tl = (c[i][0] - th) + ch;
        ch = th;
        cl += tl + c[i][1];
    }
    l.* = cl;
    return ch;
}

/// polydd_tanh.
fn polyddTanh(xh: f64, xl: f64, c: []const [2]f64, l: *f64) f64 {
    var i = c.len - 1;
    const r = fasttwosum(c[i][0], l.*);
    var ch = r.h;
    var cl = r.l + c[i][1];
    while (i > 0) {
        i -= 1;
        const m = mulddAcc2(xh, xl, ch, cl);
        const s = fasttwosum(c[i][0], m.h);
        ch = s.h;
        cl = (m.l + c[i][1]) + s.l;
    }
    l.* = cl;
    return ch;
}

const Mul = enum { dd2, acc2 };

/// as_exp_accurate: exp(x) as a double-double, x = t ln2/4096 + dx, with
/// 2^(t/4096) as th + tl; sinh and cosh multiply with muldd2, tanh with
/// muldd_acc2.
fn expAccurate(x: f64, t: f64, th: f64, tl: f64, l: *f64, comptime mul: Mul) f64 {
    const ch = [3][2]f64{
        .{ 0x1p+0, 0x1.6c16bd194535dp-94 },
        .{ 0x1p-1, -0x1.8259d904fd34fp-93 },
        .{ 0x1.5555555555555p-3, 0x1.53e93e9f26e62p-57 },
    };
    const l2h = 0x1.62e42ffp-13;
    const l2l = 0x1.718432a1b0e26p-47;
    const l2ll = 0x1.9ff0342542fc3p-102;
    const dx = x - l2h * t;
    var dxl = l2l * t;
    const dxll = l2ll * t + fma(l2l, t, -dxl);
    const dxh = dx + dxl;
    dxl = ((dx - dxh) + dxl) + dxll;
    var fl = dxh * (0x1.5555555555555p-5 + dxh * (0x1.11111113e93e9p-7 + dxh * 0x1.6c16c169400a7p-10));
    var fh = switch (mul) {
        .dd2 => polyddSinh(dxh, dxl, &ch, &fl),
        .acc2 => polyddTanh(dxh, dxl, &ch, &fl),
    };
    var m = if (mul == .dd2) muldd2(dxh, dxl, fh, fl) else mulddAcc2(dxh, dxl, fh, fl);
    m = if (mul == .dd2) muldd2(th, tl, m.h, m.l) else mulddAcc2(th, tl, m.h, m.l);
    fh = m.h;
    fl = m.l;
    const zh = th + fh;
    const zl = (th - zh) + fh;
    const uh = zh + tl;
    const ul = ((zh - uh) + tl) + zl;
    const vh = uh + fl;
    const vl = ((uh - vh) + fl) + ul;
    l.* = vl;
    return vh;
}

/// The hard-case tables' search: f unless |x| is listed.
fn database(db: []const [3]f64, x: f64, f_in: f64, comptime odd: bool) f64 {
    var a: i32 = 0;
    var b: i32 = @as(i32, @intCast(db.len)) - 1;
    var m = @divTrunc(a + b, 2);
    const ax = @abs(x);
    var f = f_in;
    while (a <= b) {
        const row = db[@intCast(m)];
        if (row[0] < ax) {
            a = m + 1;
        } else if (row[0] == ax) {
            f = if (odd) copysign(1, x) * row[1] + copysign(1, x) * row[2] else row[1] + row[2];
            break;
        } else {
            b = m - 1;
        }
        m = @divTrunc(a + b, 2);
    }
    return f;
}

/// The table index pieces of v0's bits.
const Split = struct { sp: f64, sm: f64, i0: usize, i1: usize, j0: usize, j1: usize, ie: i64 };

fn split(jt: u64) Split {
    const il: i64 = @intCast((jt << 14) >> 40);
    const jl = -il;
    const ie = il >> 12;
    const je = jl >> 12;
    return .{
        .sp = double(@as(u64, @bitCast(1022 + ie)) << 52),
        .sm = double(@as(u64, @bitCast(1022 + je)) << 52),
        .i0 = @intCast((il >> 6) & 0x3f),
        .i1 = @intCast(il & 0x3f),
        .j0 = @intCast((jl >> 6) & 0x3f),
        .j1 = @intCast(jl & 0x3f),
        .ie = ie,
    };
}

const ch4 = [4]f64{ 0x1p+0, 0x1p-1, 0x1.5555555aaaaaep-3, 0x1.55555551c98cp-5 };

fn poly4(d: f64, d2: f64) f64 {
    return d * ((ch4[0] + d * ch4[1]) + d2 * (ch4[2] + d * ch4[3]));
}

fn sinhZero(x: f64) f64 {
    const x2 = x * x;
    const x2l = fma(x, x, -x2);
    var y2 = x2 * (0x1.6124613aef206p-33 + x2 * (0x1.ae7f36beea815p-41 + x2 * 0x1.95785063cd974p-49));
    var y1 = polyddSinh(x2, x2l, &tab.sinh_ch, &y2);
    var m = mulddd3(y1, y2, x);
    m = muldd2(m.h, m.l, x2, x2l);
    const s0 = fasttwosum(x, m.h);
    const s1 = fasttwosum(s0.l, m.l);
    y1 = s1.h;
    var t = bits(y1);
    if (t & mantissa_mask == 0) {
        const w = bits(s1.l);
        if ((w ^ t) >> 63 != 0) t -%= 1 else t +%= 1;
        y1 = double(t);
    }
    return s0.h + y1;
}

/// glibc's sinh.
pub fn sinh(x: f64) f64 {
    const s = 0x1.71547652b82fep+12;
    const ax = @abs(x);
    const v0 = fma(ax, s, 0x1.8000002p+26);
    const jt = bits(v0);
    const v = jt & ~@as(u64, (1 << 26) - 1);
    const t = double(v) - 0x1.8p26;
    const aix = bits(ax);
    if (aix < 0x3fd0000000000000) {
        // |x| < 1/4.
        if (aix < 0x3e57137449123ef7) return fma(x, 0x1p-55, x);
        const c = [5]f64{ 0x1.5555555555555p-3, 0x1.111111111151ep-7, 0x1.a01a019d0c767p-13, 0x1.71de444a96e11p-19, 0x1.ae8465375242p-26 };
        const x2 = x * x;
        const x3 = x2 * x;
        const x4 = x2 * x2;
        const p = x3 * ((c[0] + x2 * c[1]) + x4 * ((c[2] + x2 * c[3]) + x4 * c[4]));
        const e = x3 * 0x1.cp-53;
        const lb = x + (p - e);
        const ub = x + (p + e);
        if (lb == ub) return lb;
        return sinhZero(x);
    }
    if (aix > 0x408633ce8fb9f87d) {
        // |x| >~ 710.47586.
        if (aix >= 0x7ff0000000000000) return x + x;
        return copysign(0x1p1023, x) * 2.0;
    }
    const sp_ = split(jt);
    var sp = sp_.sp;
    const sm = sp_.sm;
    const t0h = tab.t0[sp_.i0][1];
    const t0l = tab.t0[sp_.i0][0];
    const t1h = tab.t1[sp_.i1][1];
    const t1l = tab.t1[sp_.i1][0];
    var th = t0h * t1h;
    var tl = t0h * t1l + t1h * t0l + fma(t0h, t1h, -th);
    const l2h = 0x1.62e42ffp-13;
    const l2l = 0x1.718432a1b0e26p-47;
    const dx = (ax - l2h * t) + l2l * t;
    const dx2 = dx * dx;
    const mx = -dx;
    const pp = poly4(dx, dx2);
    var rh: f64 = undefined;
    var rl: f64 = undefined;
    const sx = copysign(1, x);
    if (aix > 0x4014000000000000) {
        // |x| > 5.
        if (aix > 0x40425e4f7b2737fa) {
            // |x| >~ 36.736801.
            sp = double(@as(u64, @bitCast(1021 + sp_.ie)) << 52);
            rh = th;
            rl = tl + th * pp;
            rh *= sx;
            rl *= sx;
            const e = 0x1.1b6p-63 * th;
            const lb = rh + (rl - e);
            const ub = rh + (rl + e);
            if (lb == ub) return (lb * sp) * 2;
            th = expAccurate(ax, t, th, tl, &tl, .dd2);
            const f = fasttwosum(th, tl);
            th = f.h * sx;
            tl = f.l * sx;
            const uh = bits(th);
            const ul = bits(tl);
            const eh: i64 = @intCast((uh >> 52) & 0x7ff);
            const el: i64 = @intCast((ul >> 52) & 0x7ff);
            const ml = (ul +% 8) & mantissa_mask;
            th += tl;
            th *= 2;
            th *= sp;
            if (ml <= 16 or eh - el > 103) return database(&tab.sinh_db, x, th, true);
            return th;
        }
        // 5 < |x| < 36.736801.
        const q0h = tab.t0[sp_.j0][1];
        const q1h = tab.t1[sp_.j1][1];
        var qh = q0h * q1h;
        th *= sp;
        tl *= sp;
        qh *= sm;
        const pm = poly4(mx, dx2);
        const em = qh + qh * pm;
        rh = th;
        rl = (tl - em) + th * pp;
        rh *= sx;
        rl *= sx;
        const e = 0x1.202p-63 * rh;
        const lb = rh + (rl - e);
        const ub = rh + (rl + e);
        if (lb == ub) return lb;
        th = expAccurate(ax, t, th, tl, &tl, .dd2);
        if (aix > 0x403f666666666666) {
            // |x| > 31.4.
            rh = th - qh;
            rl = ((th - rh) - qh) + tl;
        } else {
            qh = q0h * q1h;
            const q0l = tab.t0[sp_.j0][0];
            const q1l = tab.t1[sp_.j1][0];
            var ql = q0h * q1l + q1h * q0l + fma(q0h, q1h, -qh);
            qh *= sm;
            ql *= sm;
            qh = expAccurate(-ax, -t, qh, ql, &ql, .dd2);
            rh = th - qh;
            rl = (((th - rh) - qh) - ql) + tl;
        }
    } else {
        // 1/4 <= |x| <= 5.
        const q0h = tab.t0[sp_.j0][1];
        const q0l = tab.t0[sp_.j0][0];
        const q1h = tab.t1[sp_.j1][1];
        const q1l = tab.t1[sp_.j1][0];
        var qh = q0h * q1h;
        var ql = q0h * q1l + q1h * q0l + fma(q0h, q1h, -qh);
        th *= sp;
        tl *= sp;
        qh *= sm;
        ql *= sm;
        const pm = poly4(mx, dx2);
        const fph = th;
        const fpl = tl + th * pp;
        const fmh = qh;
        const fml = ql + qh * pm;
        rh = fph - fmh;
        rl = ((fph - rh) - fmh) - fml + fpl;
        rh *= sx;
        rl *= sx;
        const e = 0x1.c0ap-62 * rh;
        const lb = rh + (rl - e);
        const ub = rh + (rl + e);
        if (lb == ub) return lb;
        th = expAccurate(ax, t, th, tl, &tl, .dd2);
        qh = expAccurate(-ax, -t, qh, ql, &ql, .dd2);
        rh = th - qh;
        rl = ((th - rh) - qh) - ql + tl;
    }
    const f = fasttwosum(rh, rl);
    rh = f.h;
    rl = f.l;
    const uh = bits(rh);
    const ul = bits(rl);
    const eh: i64 = @intCast((uh >> 52) & 0x7ff);
    const el: i64 = @intCast((ul >> 52) & 0x7ff);
    const ml = (ul +% 8) & mantissa_mask;
    rh *= sx;
    rl *= sx;
    rh += rl;
    if (ml <= 16 or eh - el > 103) return database(&tab.sinh_db, x, rh, true);
    return rh;
}

fn coshZero(x: f64) f64 {
    const x2 = x * x;
    const x2l = fma(x, x, -x2);
    const cl = tab.cosh_cl;
    var y2 = x2 * (cl[0] + x2 * (cl[1] + x2 * (cl[2] + x2 * cl[3])));
    var y1 = polydd(x2, x2l, &tab.cosh_ch, &y2);
    const m = muldd2(y1, y2, x2, x2l);
    const s0 = fasttwosum(1.0, m.h);
    const s1 = fasttwosum(s0.l, m.l);
    y1 = s1.h;
    var t = bits(y1);
    if (t & mantissa_mask == 0) {
        const w = bits(s1.l);
        if ((w ^ t) >> 63 != 0) t -%= 1 else t +%= 1;
        y1 = double(t);
    }
    if (t & mantissa_mask == mantissa_mask) return database(&tab.cosh_db, x, s0.h + y1, false);
    return s0.h + y1;
}

/// glibc's cosh.
pub fn cosh(x: f64) f64 {
    const s = 0x1.71547652b82fep+12;
    const ax = @abs(x);
    const v0 = fma(ax, s, 0x1.8000002p+26);
    const jt = bits(v0);
    const v = jt & ~@as(u64, (1 << 26) - 1);
    const t = double(v) - 0x1.8p26;
    const aix = bits(ax);
    if (aix < 0x3fc0000000000000) {
        // |x| < 1/8.
        if (aix < 0x3e50000000000000) return fma(ax, 0x1p-55, 1);
        const c = [5]f64{ 0x1p-1, 0x1.5555555555554p-5, 0x1.6c16c16c1d0cp-10, 0x1.a01a0075066b4p-16, 0x1.27faff8dcc1c8p-22 };
        const x2 = x * x;
        const x4 = x2 * x2;
        const p = x2 * ((c[0] + x2 * c[1]) + x4 * ((c[2] + x2 * c[3]) + x4 * c[4]));
        const e = x2 * 0x1.84p-51;
        const lb = 1 + (p - e);
        const ub = 1 + (p + e);
        if (lb == ub) return lb;
        return coshZero(x);
    }
    if (aix > 0x408633ce8fb9f87d) {
        if (aix > 0x7ff0000000000000) return x + x;
        if (aix == 0x7ff0000000000000) return @abs(x);
        return std.math.inf(f64);
    }
    const sp_ = split(jt);
    var sp = sp_.sp;
    const sm = sp_.sm;
    const t0h = tab.t0[sp_.i0][1];
    const t0l = tab.t0[sp_.i0][0];
    const t1h = tab.t1[sp_.i1][1];
    const t1l = tab.t1[sp_.i1][0];
    var th = t0h * t1h;
    var tl = t0h * t1l + t1h * t0l + fma(t0h, t1h, -th);
    const l2h = 0x1.62e42ffp-13;
    const l2l = 0x1.718432a1b0e26p-47;
    const dx = (ax - l2h * t) + l2l * t;
    const dx2 = dx * dx;
    const mx = -dx;
    const pp = poly4(dx, dx2);
    var rh: f64 = undefined;
    var rl: f64 = undefined;
    if (aix > 0x4014000000000000) {
        if (aix > 0x40425e4f7b2737fa) {
            sp = double(@as(u64, @bitCast(1021 + sp_.ie)) << 52);
            rh = th;
            rl = tl + th * pp;
            const e = 0x1.1b578c96db19bp-63 * th;
            const lb = rh + (rl - e);
            const ub = rh + (rl + e);
            if (lb == ub) return (lb * sp) * 2;
            th = expAccurate(ax, t, th, tl, &tl, .dd2);
            const f = fasttwosum(th, tl);
            th = f.h;
            tl = f.l;
            const uh = bits(th);
            const ul = bits(tl);
            const eh: i64 = @intCast((uh >> 52) & 0x7ff);
            const el: i64 = @intCast((ul >> 52) & 0x7ff);
            const ml = (ul +% 8) & mantissa_mask;
            th += tl;
            th *= 2;
            th *= sp;
            if (ml <= 16 or eh - el > 103) return database(&tab.cosh_db, x, th, false);
            return th;
        }
        const q0h = tab.t0[sp_.j0][1];
        const q1h = tab.t1[sp_.j1][1];
        var qh = q0h * q1h;
        th *= sp;
        tl *= sp;
        qh *= sm;
        const pm = poly4(mx, dx2);
        const em = qh + qh * pm;
        rh = th;
        rl = (tl + em) + th * pp;
        const e = 0x1.202p-63 * rh;
        const lb = rh + (rl - e);
        const ub = rh + (rl + e);
        if (lb == ub) return lb;
        th = expAccurate(ax, t, th, tl, &tl, .dd2);
        if (aix > 0x403f666666666666) {
            rh = th + qh;
            rl = ((th - rh) + qh) + tl;
        } else {
            qh = q0h * q1h;
            const q0l = tab.t0[sp_.j0][0];
            const q1l = tab.t1[sp_.j1][0];
            var ql = q0h * q1l + q1h * q0l + fma(q0h, q1h, -qh);
            qh *= sm;
            ql *= sm;
            qh = expAccurate(-ax, -t, qh, ql, &ql, .dd2);
            rh = th + qh;
            rl = (((th - rh) + qh) + ql) + tl;
        }
    } else {
        const q0h = tab.t0[sp_.j0][1];
        const q0l = tab.t0[sp_.j0][0];
        const q1h = tab.t1[sp_.j1][1];
        const q1l = tab.t1[sp_.j1][0];
        var qh = q0h * q1h;
        var ql = q0h * q1l + q1h * q0l + fma(q0h, q1h, -qh);
        th *= sp;
        tl *= sp;
        qh *= sm;
        ql *= sm;
        const pm = poly4(mx, dx2);
        const fph = th;
        const fpl = tl + th * pp;
        const fmh = qh;
        const fml = ql + qh * pm;
        rh = fph + fmh;
        rl = ((fph - rh) + fmh) + fml + fpl;
        const e = 0x1.c0ap-62 * rh;
        const lb = rh + (rl - e);
        const ub = rh + (rl + e);
        if (lb == ub) return lb;
        th = expAccurate(ax, t, th, tl, &tl, .dd2);
        qh = expAccurate(-ax, -t, qh, ql, &ql, .dd2);
        rh = th + qh;
        rl = ((th - rh) + qh) + ql + tl;
    }
    const f = fasttwosum(rh, rl);
    rh = f.h;
    rl = f.l;
    const uh = bits(rh);
    const ul = bits(rl);
    const eh: i64 = @intCast((uh >> 52) & 0x7ff);
    const el: i64 = @intCast((ul >> 52) & 0x7ff);
    const ml = (ul +% 8) & mantissa_mask;
    rh += rl;
    if (ml <= 16 or eh - el > 103) return database(&tab.cosh_db, x, rh, false);
    return rh;
}

fn tanhZero(x: f64) f64 {
    const x2 = x * x;
    const x2l = fma(x, x, -x2);
    const cl = tab.tanh_cl;
    var y2 = x2 * (cl[0] + x2 * (cl[1] + x2 * (cl[2] + x2 * (cl[3] + x2 * cl[4]))));
    var y1 = polyddTanh(x2, x2l, &tab.tanh_ch, &y2);
    var m = mulddd_acc(y1, y2, x);
    m = mulddAcc2(m.h, m.l, x2, x2l);
    const s0 = fasttwosum(x, m.h);
    const s1 = fasttwosum(s0.l, m.l);
    y1 = s1.h;
    var t = bits(y1);
    if (t & mantissa_mask == 0) {
        const w = bits(s1.l);
        if ((w ^ t) >> 63 != 0) t -%= 1 else t +%= 1;
        y1 = double(t);
        if (@abs(x) == 0x1.ac343b179fec4p-3) return database(&tab.tanh_db, x, s0.h + y1, true);
    }
    return s0.h + y1;
}

/// glibc's tanh.
pub fn tanh(x: f64) f64 {
    const ax = @abs(x);
    const aix = bits(ax);
    if (aix >= 0x40330fc1931f09ca) {
        // Rounds to +-1.
        if (aix > 0x7ff0000000000000) return x + x;
        const f = copysign(1.0, x);
        if (aix == 0x7ff0000000000000) return f;
        return f - copysign(0x1p-55, x);
    }
    const s = -0x1.71547652b82fep+13;
    const v0 = fma(ax, s, 0x1.8000004p+25);
    const jt = bits(v0);
    const v = jt & ~@as(u64, (1 << 27) - 1);
    const t = double(v) - 0x1.8p25;
    const i_1: usize = @intCast((jt >> 27) & 0x3f);
    const i_0: usize = @intCast((jt >> 33) & 0x3f);
    const ie: i64 = @as(i64, @bitCast(jt << 13)) >> 52;
    const sp = double(@as(u64, @bitCast(1023 + ie)) << 52);
    const ch = [4]f64{ 0x1p+1, 0x1p+1, 0x1.55555557e54ffp+0, 0x1.55555553a12f4p-1 };
    const t0h = tab.t0[i_0][1];
    const t1h = tab.t1[i_1][1];
    var th = t0h * t1h;
    var tl: f64 = undefined;
    if (aix < 0x400d76c8b4395810) {
        // |x| ~< 3.683.
        if (aix < 0x3fd0000000000000) {
            // |x| < 1/4.
            if (aix <= 0x3e4d12ed0af1a27f) {
                if (aix == 0) return x;
                return fma(x, -0x1p-55, x);
            }
            const c = [8]f64{
                -0x1.5555555555555p-2,  0x1.1111111110f33p-3,
                -0x1.ba1ba1b9b8ea6p-5,  0x1.664f4838e0a43p-6,
                -0x1.226e17d1bc09bp-7,  0x1.d6c64dfba2565p-9,
                -0x1.7bdd094d327afp-10, 0x1.1535ad0c31d0ep-11,
            };
            const x2 = x * x;
            const x3 = x2 * x;
            const x4 = x2 * x2;
            const x8 = x4 * x4;
            const p1 = (c[4] + x2 * c[5]) + x4 * (c[6] + x2 * c[7]);
            var p0 = (c[0] + x2 * c[1]) + x4 * (c[2] + x2 * c[3]);
            p0 += x8 * p1;
            p0 *= x3;
            const r = fasttwosum(x, p0);
            const e = x3 * 0x1.ap-52;
            const lb = r.h + (r.l - e);
            const ub = r.h + (r.l + e);
            if (lb == ub) return lb;
            return tanhZero(x);
        }
        const t0l = tab.t0[i_0][0];
        const t1l = tab.t1[i_1][0];
        tl = t0h * t1l + t1h * t0l + fma(t0h, t1h, -th);
        th *= sp;
        tl *= sp;
        const l2h = -0x1.62e42ffp-14;
        const l2l = -0x1.718432a1b0e26p-48;
        const dx = (l2h * t - ax) - l2l * t;
        const dx2 = dx * dx;
        const p = dx * ((ch[0] + dx * ch[1]) + dx2 * (ch[2] + dx * ch[3]));
        var r = fasttwosum(th, tl + th * p);
        const ph0 = r.h;
        const pl0 = r.l;
        const q = fasttwosum(1, r.h);
        const qh = q.h;
        const ql = r.l + q.l;
        const rqh = 1 / qh;
        const rql = (ql * rqh + fma(rqh, qh, -1)) * -rqh;
        const pm = mulddAcc2(ph0, pl0, rqh, rql);
        const e = r.h * 0x1.0bp-62;
        r = fasttwosub(0.5, pm.h);
        var rh = r.h;
        var rl = r.l - pm.l;
        rh *= copysign(2, x);
        rl *= copysign(2, x);
        const lb = rh + (rl - e);
        const ub = rh + (rl + e);
        if (lb == ub) return lb;
    } else {
        // 3.683 ~< |x| < 0x1.30fc1931f09cap+4.
        const l2 = -0x1.62e42fefa39efp-14;
        const dx = fma(l2, t, -ax);
        const dx2 = dx * dx;
        const p = dx * ((ch[0] + dx * ch[1]) + dx2 * (ch[2] + dx * ch[3]));
        var rh = th * sp;
        rh += (p + ((2 * 0x1.3p-55) * ax)) * rh;
        const e = rh * 0x1.1p-49;
        rh = (2 * rh) / (1 + rh);
        const one = copysign(1, x);
        rh = copysign(rh, x);
        const lb = one - (rh + e);
        const ub = one - (rh - e);
        if (lb == ub) return lb;
        const t0l = tab.t0[i_0][0];
        const t1l = tab.t1[i_1][0];
        tl = t0h * t1l + t1h * t0l + fma(t0h, t1h, -th);
        th *= sp;
        tl *= sp;
    }
    var rl: f64 = undefined;
    var rh = expAccurate(-2 * ax, t, th, tl, &rl, .acc2);
    const q = fasttwosum(1, rh);
    var ql = rl + q.l;
    const q2 = fasttwosum(q.h, ql);
    const qh = q2.h;
    ql = q2.l;
    const rqh = 1 / qh;
    const rql = (ql * rqh + fma(rqh, qh, -1)) * -rqh;
    const pm = mulddAcc2(rh, rl, rqh, rql);
    var r = fasttwosub(0.5, pm.h);
    rh = r.h;
    rl = r.l - pm.l;
    r = fasttwosum(rh, rl);
    rh = r.h;
    rl = r.l;
    const res = copysign(2, x) * rh + copysign(2, x) * rl;
    const lu = bits(rl);
    if (((lu +% 32) & mantissa_mask) < 65) return database(&tab.tanh_db, x, res, true);
    return res;
}
