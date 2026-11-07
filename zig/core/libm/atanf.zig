// SPDX-License-Identifier: MIT
// Derived from the GNU C Library 2.44's sysdeps/ieee754/flt-32/s_atanf.c
// and e_atan2f.c, from the CORE-MATH project
// (https://core-math.gitlabpages.inria.fr/, files src/binary32/atan/atanf.c
// and src/binary32/atan2/atan2f.c); copyright (c) 2022-2024 Alexei
// Sibidanov and Paul Zimmermann. Permission is hereby granted, free of
// charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the
// Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions: The above copyright notice and
// this permission notice shall be included in all copies or substantial
// portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT
// WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//! glibc's `atanf` and `atan2f` (core/libm.zig), CORE-MATH's correctly
//! rounded ones: a rational approximation in double, and for atan2f a
//! double-double fallback when the rounding is in doubt. x86-64 has no FMA
//! variant of either, and the installed build calls `fma` and `fmaf` where
//! the C does, so `@mulAdd` stands exactly there and nowhere else. FFmpeg's
//! parametric stereo tables call both (T30d). `errno` is not set.

const std = @import("std");
const addNan = @import("powf.zig").addNan;

/// glibc's atanf.
pub fn atanf(x: f32) f32 {
    const pi2: f64 = 0x1.921fb54442d18p+0;
    const t: u32 = @bitCast(x);
    const e: i32 = @intCast((t >> 23) & 0xff);
    const gt = e >= 127;
    const ta = t & 0x7fffffff;
    if (ta >= 0x4c700518) { // |x| > 0x1.e00a3p+25
        if (ta > 0x7f800000) return addNan(x, x); // NaN
        return @floatCast(std.math.copysign(pi2, @as(f64, x)));
    }
    if (e < 127 - 13) {
        if (e < 127 - 25) {
            if (t << 1 == 0) return x;
            return @mulAdd(f32, -x, @abs(x), x);
        }
        return @mulAdd(f32, -0x1.5555555555555p-2 * x, x * x, x);
    }
    var z: f64 = x;
    if (gt) z = 1 / z;
    const z2 = z * z;
    const z4 = z2 * z2;
    const z8 = z4 * z4;
    const cn = [7]f64{ 0x1.51eccde075d67p-2, 0x1.a76bb5637f2f2p-1, 0x1.81e0eed20de88p-1, 0x1.376c8ca67d11dp-2, 0x1.aec7b69202ac6p-5, 0x1.9561899acc73ep-9, 0x1.bf9fa5b67e6p-16 };
    const cd = [7]f64{ 0x1.51eccde075d66p-2, 0x1.dfbdd7b392d28p-1, 0x1p+0, 0x1.fd22bf0e89b54p-2, 0x1.d91ff8b576282p-4, 0x1.653ea99fc9bbp-7, 0x1.1e7fcc202340ap-12 };
    var cn0 = cn[0] + z2 * cn[1];
    const cn2 = cn[2] + z2 * cn[3];
    var cn4 = cn[4] + z2 * cn[5];
    const cn6 = cn[6];
    cn0 += z4 * cn2;
    cn4 += z4 * cn6;
    cn0 += z8 * cn4;
    cn0 *= z;
    var cd0 = cd[0] + z2 * cd[1];
    const cd2 = cd[2] + z2 * cd[3];
    var cd4 = cd[4] + z2 * cd[5];
    const cd6 = cd[6];
    cd0 += z4 * cd2;
    cd4 += z4 * cd6;
    cd0 += z8 * cd4;
    var r = cn0 / cd0;
    if (!gt) return @floatCast(r);
    const pi_over2_h: f64 = 0x1.9p0;
    const pi_over2_l: f64 = 0x1.0fdaa22168c23p-7;
    r = std.math.copysign(pi_over2_l, z) - r + std.math.copysign(pi_over2_h, z);
    return @floatCast(r);
}

/// muldd: the double-double product of (xh, xl) and (ch, cl).
fn muldd(xh: f64, xl: f64, ch: f64, cl: f64, l: *f64) f64 {
    const ahlh = ch * xl;
    const alhh = cl * xh;
    const ahhh = ch * xh;
    var ahhl = @mulAdd(f64, ch, xh, -ahhh);
    ahhl += alhh + ahlh;
    const h = ahhh + ahhl;
    l.* = (ahhh - h) + ahhl;
    return h;
}

/// polydd: the double-double polynomial `c` at (xh, xl).
fn polydd(xh: f64, xl: f64, c: []const [2]f64, l: *f64) f64 {
    var i = c.len - 1;
    var ch = c[i][0];
    var cl = c[i][1];
    while (i > 0) {
        i -= 1;
        ch = muldd(xh, xl, ch, cl, &cl);
        const th = ch + c[i][0];
        const tl = (c[i][0] - th) + ch;
        ch = th;
        cl += tl + c[i][1];
    }
    l.* = cl;
    return ch;
}

/// cr_atan2f_tiny: z - z^3/3 for a tiny y/x.
fn atan2fTiny(y: f32, x: f32) f32 {
    const dy: f64 = y;
    const dx: f64 = x;
    const z = dy / dx;
    var e = @mulAdd(f64, -z, dx, dy);
    const c: f64 = -0x1.5555555555555p-2;
    const zz = z * z;
    const cz = c * z;
    e = e / dx + cz * zz;
    var t: u64 = @bitCast(z);
    if (t & 0xfffffff == 0) { // a boundary case: avoid the double rounding
        if (z * e > 0) t +%= 1 else t -%= 1;
    }
    const r: f64 = @bitCast(t);
    const rf: f32 = @floatCast(r);
    // __math_uflowf: 0x1p-95f times itself, signed as t.
    if (rf == 0.0) return if (t >> 63 != 0) -0.0 else 0.0;
    return rf;
}

/// glibc's atan2f.
pub fn atan2f(y: f32, x: f32) f32 {
    const cn = [7]f64{ 0x1p+0, 0x1.40e0698f94c35p+1, 0x1.248c5da347f0dp+1, 0x1.d873386572976p-1, 0x1.46fa40b20f1dp-3, 0x1.33f5e041eed0fp-7, 0x1.546bbf28667c5p-14 };
    const cd = [7]f64{ 0x1p+0, 0x1.6b8b143a3f6dap+1, 0x1.8421201d18ed5p+1, 0x1.8221d086914ebp+0, 0x1.670657e3a07bap-2, 0x1.0f4951fd1e72dp-5, 0x1.b3874b8798286p-11 };
    const m = [2]f64{ 0, 1 };
    const pi: f64 = 0x1.921fb54442d18p+1;
    const pi2: f64 = 0x1.921fb54442d18p+0;
    const pi2l: f64 = 0x1.1a62633145c07p-54;
    const off = [8]f64{ 0.0, pi2, pi, pi2, -0.0, -pi2, -pi, -pi2 };
    const offl = [8]f64{ 0.0, pi2l, 2 * pi2l, pi2l, -0.0, -pi2l, -2 * pi2l, -pi2l };
    const sgn = [2]f64{ 1, -1 };
    const ux: u32 = @bitCast(x);
    const uy: u32 = @bitCast(y);
    const ax = ux & (~@as(u32, 0) >> 1);
    const ay = uy & (~@as(u32, 0) >> 1);
    if (ay >= (0xff << 23) or ax >= (0xff << 23)) {
        // NaN: the C's `x + y`, which the installed build computes with
        // y first: of two NaNs, y's comes back.
        if (ay > (0xff << 23)) return addNan(y, x);
        if (ax > (0xff << 23)) return addNan(y, x);
        const yinf = ay == (0xff << 23);
        const xinf = ax == (0xff << 23);
        if (yinf and xinf) {
            if (ux >> 31 != 0) return @floatCast(0x1.2d97c7f3321d2p+1 * sgn[uy >> 31]); // +-3pi/4
            return @floatCast(0x1.921fb54442d18p-1 * sgn[uy >> 31]); // +-pi/4
        }
        if (xinf) {
            if (ux >> 31 != 0) return @floatCast(pi * sgn[uy >> 31]);
            return @floatCast(0.0 * sgn[uy >> 31]);
        }
        if (yinf) return @floatCast(pi2 * sgn[uy >> 31]);
    }
    if (ay == 0) {
        if (ax == 0) {
            const i = (uy >> 31) * 4 + (ux >> 31) * 2;
            if (ux >> 31 != 0) return @floatCast(off[i] + offl[i]);
            return @floatCast(off[i]);
        }
        if (ux >> 31 == 0) return @floatCast(0.0 * sgn[uy >> 31]);
    }
    const gt: u32 = @intFromBool(ay > ax);
    const i = (uy >> 31) * 4 + (ux >> 31) * 2 + gt;
    const zx: f64 = x;
    const zy: f64 = y;
    var z = (m[gt] * zx + m[1 - gt] * zy) / (m[gt] * zy + m[1 - gt] * zx);
    var r: f64 = undefined;
    const d: i32 = @as(i32, @intCast(ax)) - @as(i32, @intCast(ay));
    if (d < (27 << 23) and d > -(27 << 23)) {
        const z2 = z * z;
        const z4 = z2 * z2;
        const z8 = z4 * z4;
        var cn0 = cn[0] + z2 * cn[1];
        const cn2 = cn[2] + z2 * cn[3];
        var cn4 = cn[4] + z2 * cn[5];
        const cn6 = cn[6];
        cn0 += z4 * cn2;
        cn4 += z4 * cn6;
        cn0 += z8 * cn4;
        var cd0 = cd[0] + z2 * cd[1];
        const cd2 = cd[2] + z2 * cd[3];
        var cd4 = cd[4] + z2 * cd[5];
        const cd6 = cd[6];
        cd0 += z4 * cd2;
        cd4 += z4 * cd6;
        cd0 += z8 * cd4;
        r = cn0 / cd0;
    } else r = 1;
    z *= sgn[gt];
    r = z * r + off[i];
    if (((@as(u64, @bitCast(r)) +% 8) & 0xfffffff) <= 16) {
        if (ay < ax and ((ax - ay) >> 23 >= 25)) return atan2fTiny(y, x);
        var zh: f64 = undefined;
        var zl: f64 = undefined;
        if (gt == 0) {
            zh = zy / zx;
            zl = @mulAdd(f64, zh, -zx, zy) / zx;
        } else {
            zh = zx / zy;
            zl = @mulAdd(f64, zh, -zy, zx) / zy;
        }
        var z2l: f64 = undefined;
        const z2h = muldd(zh, zl, zh, zl, &z2l);
        var pl: f64 = undefined;
        var ph = polydd(z2h, z2l, &poly, &pl);
        zh *= sgn[gt];
        zl *= sgn[gt];
        ph = muldd(zh, zl, ph, pl, &pl);
        const sh = ph + off[i];
        const sl = ((off[i] - sh) + ph) + pl + offl[i];
        const rf: f32 = @floatCast(sh);
        const th: f64 = rf;
        const dh = sh - th;
        var tm = dh + sl;
        var tth: u64 = @bitCast(th);
        if (th + th * 0x1p-60 == th - th * 0x1p-60) {
            tth &= @as(u64, 0x7ff) << 52;
            tth -%= @as(u64, 24) << 52;
            if (@abs(tm) > @as(f64, @bitCast(tth))) tm *= 1.25 else tm *= 0.75;
        }
        r = th + tm;
    }
    const rf: f32 = @floatCast(r);
    // __math_uflowf(asuint(rf) >> 1): a zero keeps its sign.
    if (rf == 0.0) return if (@as(u32, @bitCast(rf)) >> 1 != 0) -0.0 else 0.0;
    return rf;
}

/// atan2f's double-double coefficients of atan(sqrt(x))/sqrt(x).
const poly = [32][2]f64{
    .{ 0x1p+0, -0x1.8c1dac5492248p-87 },
    .{ -0x1.5555555555555p-2, -0x1.55553bf3a2abep-56 },
    .{ 0x1.999999999999ap-3, -0x1.99deed1ec9071p-57 },
    .{ -0x1.2492492492492p-3, -0x1.fd99c8d18269ap-58 },
    .{ 0x1.c71c71c71c717p-4, -0x1.651eee4c4d9dp-61 },
    .{ -0x1.745d1745d1649p-4, -0x1.632683d6c44a6p-58 },
    .{ 0x1.3b13b13b11c63p-4, 0x1.bf69c1f8af41dp-58 },
    .{ -0x1.11111110e6338p-4, 0x1.3c3e431e8bb68p-61 },
    .{ 0x1.e1e1e1dc45c4ap-5, -0x1.be2db05c77bbfp-59 },
    .{ -0x1.af286b8164b4fp-5, 0x1.a4673491f0942p-61 },
    .{ 0x1.86185e9ad4846p-5, 0x1.e12e32d79fceep-59 },
    .{ -0x1.642c6d5161faep-5, 0x1.3ce76c1ca03fp-59 },
    .{ 0x1.47ad6f277e5bfp-5, -0x1.abd8d85bdb714p-60 },
    .{ -0x1.2f64a2ee8896dp-5, 0x1.ef87d4b615323p-61 },
    .{ 0x1.1a6a2b31741b5p-5, 0x1.a5d9d973547eep-62 },
    .{ -0x1.07fbdad65e0a6p-5, -0x1.65ac07f5d35f4p-61 },
    .{ 0x1.ee9932a9a5f8bp-6, 0x1.f8b9623f6f55ap-61 },
    .{ -0x1.ce8b5b9584dc6p-6, 0x1.fe5af96e8ea2dp-61 },
    .{ 0x1.ac9cb288087b7p-6, -0x1.450cdfceaf5cap-60 },
    .{ -0x1.84b025351f3e6p-6, 0x1.579561b0d73dap-61 },
    .{ 0x1.52f5b8ecdd52bp-6, 0x1.036bd2c6fba47p-60 },
    .{ -0x1.163a8c44909dcp-6, 0x1.18f735ffb9f16p-60 },
    .{ 0x1.a400dce3eea6fp-7, -0x1.c90569c0c1b5cp-61 },
    .{ -0x1.1caa78ae6db3ap-7, -0x1.4c60f8161ea09p-61 },
    .{ 0x1.52672453c0731p-8, 0x1.834efb598c338p-62 },
    .{ -0x1.5850c5be137cfp-9, -0x1.445fc150ca7f5p-63 },
    .{ 0x1.23eb98d22e1cap-10, -0x1.388fbaf1d783p-64 },
    .{ -0x1.8f4e974a40741p-12, 0x1.271198a97da34p-66 },
    .{ 0x1.a5cf2e9cf76e5p-14, -0x1.887eb4a63b665p-68 },
    .{ -0x1.420c270719e32p-16, 0x1.efd595b27888bp-71 },
    .{ 0x1.3ba2d69b51677p-19, -0x1.4fb06829cdfc7p-73 },
    .{ -0x1.29b7e6f676385p-23, -0x1.a783b6de718fbp-77 },
};

test "atanf and atan2f: zeros, infinities and the quadrants" {
    try std.testing.expectEqual(@as(f32, 0), atanf(0));
    try std.testing.expectEqual(@as(f32, 0x1.921fb6p+0), atanf(std.math.inf(f32)));
    try std.testing.expectEqual(@as(f32, 0x1.921fb6p-1), atanf(1));
    try std.testing.expectEqual(@as(f32, 0x1.921fb6p-1), atan2f(1, 1));
    try std.testing.expectEqual(@as(f32, -0x1.2d97c8p+1), atan2f(-1, -1));
    try std.testing.expectEqual(@as(f32, 0x1.921fb6p+1), atan2f(0, -1));
    try std.testing.expect(std.math.isNan(atan2f(std.math.nan(f32), 1)));
}

test "sinf, cosf, atanf and atan2f return glibc's results (vectors/libm.txt)" {
    const libm = @import("../libm.zig");
    const Md5 = std.crypto.hash.Md5;
    const FloatSampler = @import("powf.zig").FloatSampler;
    var lines = std.mem.splitScalar(u8, @embedFile("../../testing/vectors/libm.txt"), '\n');
    var line = lines.next().?;
    while (!std.mem.startsWith(u8, line, "K sinf ")) line = lines.next().?;
    var text: [128]u8 = undefined;
    var digest: [Md5.digest_length]u8 = undefined;
    const unary = [3]*const fn (f32) f32{ libm.sinf, libm.cosf, atanf };
    const names = [3][]const u8{ "sinf", "cosf", "atanf" };
    for (unary, names, 0..) |func, name, f| {
        for (0..8) |d| {
            var g: FloatSampler = .{ .state = 0x9E3779B97F4A7C15 +% 1000003 * @as(u64, 4000 + 10 * f + d) };
            var md5: Md5 = .init(.{});
            for (0..20000) |_| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(func(g.sample(@intCast(d)))), .little);
                md5.update(&b);
            }
            md5.final(&digest);
            try std.testing.expectEqualStrings(line, try std.fmt.bufPrint(&text, "K {s} {d} 20000 {x}", .{ name, d, digest }));
            line = lines.next().?;
        }
    }
    for (0..8) |dy| {
        for (0..8) |dx| {
            var g: FloatSampler = .{ .state = 0x9E3779B97F4A7C15 +% 1000003 * @as(u64, 5000 + dy * 8 + dx) };
            var md5: Md5 = .init(.{});
            for (0..5000) |_| {
                const y = g.sample(@intCast(dy));
                const x = g.sample(@intCast(dx));
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(atan2f(y, x)), .little);
                md5.update(&b);
            }
            md5.final(&digest);
            try std.testing.expectEqualStrings(line, try std.fmt.bufPrint(&text, "A atan2f {d} {d} 5000 {x}", .{ dy, dx, digest }));
            line = lines.next() orelse "";
        }
    }
}
