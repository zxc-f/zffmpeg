// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/flt-32/e_exp2f.c,
// e_exp2f_data.c, math_config.h, s_sinf.c, s_cosf.c, sincosf.h and
// s_sincosf_data.c, which came from Arm's optimized-routines: copyright
// (c) 2017-2018 Arm Ltd. The GNU C Library is free software; you can
// redistribute it and/or modify it under the terms of the GNU Lesser
// General Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any later version.
// The constants are those of the reference platform's libm.so.6, read from
// its __exp2f_data and __sincosf_table.
//! The reference platform's C library math where FFmpeg's C code calls it
//! and Zig's own functions round differently (notes.md "Floating-point
//! library"): single-precision `exp2f`, `sinf` and `cosf` (every float)
//! here, `powf`, `log2f`, `cbrtf`, `atanf` and `atan2f` in libm/, and there
//! the double functions FFmpeg's code paths
//! here call: `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`,
//! `exp2`, `log`, `pow`, `hypot`, `sinh`, `cosh`, `tanh`, `cbrt` and
//! `ldexp`. Zig's `@exp2` and `@sin` follow musl's older code and differ
//! from glibc in the last bit for about one float in 12,000 and for 1579 of
//! CELT's rotation angles.
//!
//! glibc picks a variant by CPU at load time; on x86-64 with FMA and AVX2
//! (every machine the project verifies on, AVX-512 ones included) it runs
//! the variants built with fused multiply-adds, which `@mulAdd` reproduces
//! on any target. The float functions are checked against the installed
//! glibc for every float (exp2f) and every float in [0, pi/4) (sinf,
//! cosf), and all of them by vectors/libm.txt.

const std = @import("std");
const sin_mod = @import("libm/sin.zig");
const exp_mod = @import("libm/exp.zig");

/// glibc's double functions (libm/*.zig), each checked against the
/// installed glibc on 32 million samples across the exponent range and by
/// vectors/libm.txt.
pub const sin = sin_mod.sin;
pub const cos = sin_mod.cos;
pub const exp = exp_mod.exp;
pub const exp2 = exp_mod.exp2;
pub const atan = @import("libm/atan.zig").atan;
pub const tan = @import("libm/tan.zig").tan;
pub const asin = @import("libm/asin.zig").asin;
pub const acos = @import("libm/asin.zig").acos;
pub const atan2 = @import("libm/atan2.zig").atan2;
pub const log = @import("libm/log.zig").log;
pub const pow = @import("libm/pow.zig").pow;
pub const hypot = @import("libm/hypot.zig").hypot;
/// Not correctly rounded; musl's, `std.math.cbrt`, differs (T29b).
pub const cbrt = @import("libm/cbrt.zig").cbrt;
pub const cbrtf = @import("libm/cbrtf.zig").cbrtf;
/// Checked against the installed glibc on 48 million random pairs, every
/// float x for eight exponents and every integer exponent to 2^20 of the
/// AAC decoder's four coupling bases, and by vectors/libm.txt (T30b).
pub const powf = @import("libm/powf.zig").powf;
pub const log2f = @import("libm/log2f.zig").log2f;
pub const atanf = @import("libm/atanf.zig").atanf;
pub const atan2f = @import("libm/atanf.zig").atan2f;
/// Exact apart from one rounding (libm/ldexp.zig: std.math.ldexp
/// mis-scales a zero); checked against glibc's in its tests.
pub const ldexp = @import("libm/ldexp.zig").ldexp;
/// Correctly rounded since glibc 2.44 (CORE-MATH); earlier releases differ.
pub const sinh = @import("libm/hyperbolic.zig").sinh;
pub const cosh = @import("libm/hyperbolic.zig").cosh;
pub const tanh = @import("libm/hyperbolic.zig").tanh;

/// __exp2f_data.tab: 2^(i/32) with i/32 taken out of the exponent (also
/// powf's, libm/powf.zig).
pub const exp2f_tab = [32]u64{
    0x3ff0000000000000, 0x3fefd9b0d3158574, 0x3fefb5586cf9890f, 0x3fef9301d0125b51,
    0x3fef72b83c7d517b, 0x3fef54873168b9aa, 0x3fef387a6e756238, 0x3fef1e9df51fdee1,
    0x3fef06fe0a31b715, 0x3feef1a7373aa9cb, 0x3feedea64c123422, 0x3feece086061892d,
    0x3feebfdad5362a27, 0x3feeb42b569d4f82, 0x3feeab07dd485429, 0x3feea47eb03a5585,
    0x3feea09e667f3bcd, 0x3fee9f75e8ec5f74, 0x3feea11473eb0187, 0x3feea589994cce13,
    0x3feeace5422aa0db, 0x3feeb737b0cdc5e5, 0x3feec49182a3f090, 0x3feed503b23e255d,
    0x3feee89f995ad3ad, 0x3feeff76f2fb5e47, 0x3fef199bdd85529c, 0x3fef3720dcef9069,
    0x3fef5818dcfba487, 0x3fef7c97337b9b5f, 0x3fefa4afa2a490da, 0x3fefd0765b6e4540,
};

fn f64Bits(b: u64) f64 {
    return @bitCast(b);
}

/// glibc's exp2f.
pub fn exp2f(x: f32) f32 {
    const ux: u32 = @bitCast(x);
    const abstop = (ux >> 20) & 0x7ff;
    if (abstop >= 0x430) {
        // |x| >= 128 or NaN.
        if (ux == 0xff800000) return 0;
        if (abstop >= 0x7f8) return x + x;
        if (x > 0) return std.math.inf(f32);
        if (x <= -150) return 0;
    }
    const shift = f64Bits(0x42e8000000000000); // 0x1.8p52 / 32
    const xd: f64 = x;
    var kd = xd + shift;
    const ki: u64 = @bitCast(kd);
    kd -= shift;
    const r = xd - kd;
    // 2^x = 2^(k/32) * 2^r, 2^r ~= C0 r^3 + C1 r^2 + C2 r + 1.
    const t = exp2f_tab[ki % 32] +% (ki << 47);
    const s: f64 = @bitCast(t);
    const z = @mulAdd(f64, f64Bits(0x3fac6af84b912394), r, f64Bits(0x3fcebfce50fac4f3));
    const r2 = r * r;
    var y = @mulAdd(f64, r, f64Bits(0x3fe62e42ff0c52d6), 1.0);
    y = @mulAdd(f64, z, r2, y);
    return @floatCast(y * s);
}

/// __sincosf_table[0]'s polynomials.
const sin1 = f64Bits(0xbfc555545995a603);
const sin2 = f64Bits(0x3f81107605230bc4);
const sin3 = f64Bits(0xbf2994eb3774cf24);
const cos1 = f64Bits(0xbfdffffffd0c621c);
const cos2 = f64Bits(0x3fa55553e1068f19);
const cos3 = f64Bits(0xbf56c087e89a359d);
const cos4 = f64Bits(0x3ef99343027bf8c3);

/// The bound below which `sinf` and `cosf` need no argument reduction
/// (the C's `pio4`), as float.
pub const quarter_pi: f32 = std.math.pi / 4.0;

/// __sincosf_table's `hpi_inv` (2/pi scaled by 2^24, the build without
/// TOINT_INTRINSICS) and `hpi`, and reduce_large's pi/2^63.
const hpi_inv = f64Bits(0x41645f306dc9c883);
const hpi = f64Bits(0x3ff921fb54442d18);
const pi63 = f64Bits(0x3c1921fb54442d18);

/// `__inv_pio4`: 4/pi to 192 bits, 8 new bits an entry.
const inv_pio4 = [24]u32{
    0xa2,       0xa2f9,     0xa2f983,   0xa2f9836e, 0xf9836e4e, 0x836e4e44, 0x6e4e4415, 0x4e441529,
    0x441529fc, 0x1529fc27, 0x29fc2757, 0xfc2757d1, 0x2757d1f5, 0x57d1f534, 0xd1f534dd, 0xf534ddc0,
    0x34ddc0db, 0xddc0db62, 0xc0db6295, 0xdb629599, 0x6295993c, 0x95993c43, 0x993c4390, 0x3c439041,
};

fn abstop12(x: f32) u32 {
    return (@as(u32, @bitCast(x)) >> 20) & 0x7ff;
}

/// reduce_fast: x modulo pi/2 in [-pi/4, pi/4], and its quadrant, for
/// |x| < 120; the FMA build fuses `x - n * hpi`.
fn reduceFast(x: f64, n: *i32) f64 {
    const r = x * hpi_inv;
    const ri: i32 = @trunc(r); // |r| < 2^31 for |x| < 120
    n.* = (ri +% 0x800000) >> 24;
    return @mulAdd(f64, -@as(f64, @floatFromInt(n.*)), hpi, x);
}

/// reduce_large: for |x| >= 120, from the float's bits (the sign
/// ignored), with 4/pi to 192 bits.
fn reduceLarge(xi_in: u32, np: *i32) f64 {
    const arr = inv_pio4[(xi_in >> 26) & 15 ..];
    const shift: u5 = @intCast((xi_in >> 23) & 7);
    const xi = ((xi_in & 0xffffff) | 0x800000) << shift;
    // The C's 32-bit product, then widened.
    var res0: u64 = xi *% arr[0];
    const res1: u64 = @as(u64, xi) * arr[4];
    const res2: u64 = @as(u64, xi) * arr[8];
    res0 = (res2 >> 32) | (res0 << 32);
    res0 +%= res1;
    const n = (res0 +% (@as(u64, 1) << 61)) >> 62;
    res0 -%= n << 62;
    np.* = @truncate(@as(i64, @bitCast(n)));
    const x: f64 = @floatFromInt(@as(i64, @bitCast(res0)));
    return x * pi63;
}

/// sinf_poly, x86's: the sine polynomial of `x` for an even quadrant `n`,
/// the cosine one (negated for `neg`, `__sincosf_table[1]`) for an odd one,
/// with the FMA build's fusions.
fn sinfPoly(x: f64, x2: f64, neg: bool, n: i32) f32 {
    if (n & 1 == 0) {
        const x3 = x * x2;
        const s1 = @mulAdd(f64, x2, sin3, sin2);
        const x7 = x3 * x2;
        const s = @mulAdd(f64, x3, sin1, x);
        return @floatCast(@mulAdd(f64, x7, s1, s));
    }
    const sg: f64 = if (neg) -1.0 else 1.0;
    const x4 = x2 * x2;
    const c2 = @mulAdd(f64, x2, sg * cos4, sg * cos3);
    const c1 = @mulAdd(f64, x2, sg * cos1, sg);
    const x6 = x4 * x2;
    const c = @mulAdd(f64, x4, sg * cos2, c1);
    return @floatCast(@mulAdd(f64, x6, c2, c));
}

/// `p->sign`: the sine's sign in each quadrant.
const quadrant_sign = [4]f64{ 1.0, -1.0, -1.0, 1.0 };

/// glibc's sinf, its FMA build (`__sinf_fma`), for every float: the
/// polynomial below pi/4, reduce_fast below 120, reduce_large above.
pub fn sinf(y: f32) f32 {
    var x: f64 = y;
    var n: i32 = 0;
    if (abstop12(y) < abstop12(quarter_pi)) {
        const s = x * x;
        // Tiny: y itself (the C forces an underflow, without effect here).
        if (abstop12(y) < abstop12(0x1p-12)) return y;
        return sinfPoly(x, s, false, 0);
    } else if (abstop12(y) < abstop12(120.0)) {
        x = reduceFast(x, &n);
        const s = quadrant_sign[@intCast(n & 3)];
        return sinfPoly(x * s, x * x, n & 2 != 0, n);
    } else if (abstop12(y) < abstop12(std.math.inf(f32))) {
        const xi: u32 = @bitCast(y);
        const sign: i32 = @intCast(xi >> 31);
        x = reduceLarge(xi, &n);
        const q = n +% sign;
        const s = quadrant_sign[@intCast(q & 3)];
        return sinfPoly(x * s, x * x, q & 2 != 0, n);
    }
    return (y - y) / (y - y); // __math_invalidf
}

/// glibc's cosf, its FMA build (`__cosf_fma`), for every float.
pub fn cosf(y: f32) f32 {
    var x: f64 = y;
    var n: i32 = 0;
    if (abstop12(y) < abstop12(quarter_pi)) {
        const x2 = x * x;
        if (abstop12(y) < abstop12(0x1p-12)) return 1.0;
        return sinfPoly(x, x2, false, 1);
    } else if (abstop12(y) < abstop12(120.0)) {
        x = reduceFast(x, &n);
        const s = quadrant_sign[@intCast(n & 3)];
        return sinfPoly(x * s, x * x, n & 2 != 0, n ^ 1);
    } else if (abstop12(y) < abstop12(std.math.inf(f32))) {
        const xi: u32 = @bitCast(y);
        const sign: i32 = @intCast(xi >> 31);
        x = reduceLarge(xi, &n);
        const q = n +% sign;
        const s = quadrant_sign[@intCast(q & 3)];
        return sinfPoly(x * s, x * x, q & 2 != 0, n ^ 1);
    }
    return (y - y) / (y - y);
}

const testing = std.testing;
const Md5 = std.crypto.hash.Md5;

fn put(md5: *Md5, v: f32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @bitCast(v), .little);
    md5.update(&b);
}

fn expectLine(line: []const u8, head: []const u8, md5: *Md5) !void {
    var digest: [Md5.digest_length]u8 = undefined;
    md5.final(&digest);
    var text: [128]u8 = undefined;
    const got = try std.fmt.bufPrint(&text, "{s} {x}", .{ head, digest });
    try testing.expectEqualStrings(line, got);
}

test {
    _ = @import("libm/ldexp.zig");
    _ = @import("libm/cbrt.zig");
    _ = @import("libm/cbrtf.zig");
    _ = @import("libm/powf.zig");
    _ = @import("libm/log2f.zig");
    _ = @import("libm/atanf.zig");
}

test "exp2f, sinf and cosf return glibc's results (vectors/libm.txt)" {
    var lines = std.mem.splitScalar(u8, @embedFile("../testing/vectors/libm.txt"), '\n');
    var head: [64]u8 = undefined;

    var md5: Md5 = .init(.{});
    for (0..65536) |i| put(&md5, exp2f(@bitCast(@as(u32, @intCast(i)) *% 65537)));
    try expectLine(lines.next().?, "E 65537 65536", &md5);

    md5 = .init(.{});
    var count: u32 = 0;
    for (1..401) |len_usize| {
        const len: u32 = @intCast(len_usize);
        var k: u32 = 1;
        while (2 * k < len) : (k += 1) {
            for (1..4) |spread| {
                const theta = rotationAngle(len, k, @intCast(spread));
                put(&md5, sinf(theta));
                put(&md5, cosf(theta));
                count += 1;
            }
        }
    }
    try expectLine(lines.next().?, try std.fmt.bufPrint(&head, "T {d}", .{count}), &md5);

    md5 = .init(.{});
    count = 0;
    var i: u32 = 0;
    while (true) : (i += 1) {
        const x: f32 = @bitCast(i *% 4099);
        if (!(x < quarter_pi)) break;
        put(&md5, sinf(x));
        put(&md5, cosf(x));
        count += 1;
    }
    try expectLine(lines.next().?, try std.fmt.bufPrint(&head, "Q 4099 {d}", .{count}), &md5);
}

/// libm_vectors.c's xorshift generator and input distributions.
const Sampler = struct {
    state: u64,

    fn next(g: *Sampler) u64 {
        g.state ^= g.state << 13;
        g.state ^= g.state >> 7;
        g.state ^= g.state << 17;
        return g.state;
    }

    fn unit(g: *Sampler) f64 {
        return @as(f64, @floatFromInt(g.next() >> 11)) * 0x1p-53;
    }

    fn sample(g: *Sampler, dist: u32) f64 {
        return switch (dist) {
            0 => @bitCast(g.next()),
            1 => (g.unit() * 2 - 1) * 10,
            2 => (g.unit() * 2 - 1) * 1000,
            3 => g.unit() * 2 - 1,
            4 => blk: {
                const k: f64 = @floatFromInt(@as(i64, @intCast(g.next() % 2001)) - 1000);
                break :blk k * (std.math.pi / 2.0) + (g.unit() - 0.5) * 1e-6;
            },
            5 => (g.unit() * 2 - 1) * 1e9,
            6 => (g.unit() * 2 - 1) * 800,
            else => blk: {
                const m = g.unit() + 0.5;
                const e: i32 = @as(i32, @intCast(g.next() % 120)) - 60;
                const sign: f64 = if (g.next() & 1 != 0) -1.0 else 1.0;
                break :blk std.math.ldexp(m, e) * sign;
            },
        };
    }
};

fn putDouble(md5: *Md5, v: f64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, @bitCast(v), .little);
    md5.update(&b);
}

test "the double functions return glibc's results (vectors/libm.txt)" {
    const Func = struct { name: []const u8, kind: u8, one: ?*const fn (f64) f64 = null, two: ?*const fn (f64, f64) f64 = null };
    const funcs = [_]Func{
        .{ .name = "sin", .kind = 'D', .one = sin },     .{ .name = "cos", .kind = 'D', .one = cos },
        .{ .name = "exp", .kind = 'D', .one = exp },     .{ .name = "exp2", .kind = 'D', .one = exp2 },
        .{ .name = "atan", .kind = 'D', .one = atan },   .{ .name = "tan", .kind = 'D', .one = tan },
        .{ .name = "asin", .kind = 'D', .one = asin },   .{ .name = "acos", .kind = 'D', .one = acos },
        .{ .name = "log", .kind = 'D', .one = log },     .{ .name = "pow", .kind = 'D', .two = pow },
        .{ .name = "atan2", .kind = 'D', .two = atan2 }, .{ .name = "hypot", .kind = 'D', .two = hypot },
        .{ .name = "sinh", .kind = 'C', .one = sinh },   .{ .name = "cosh", .kind = 'C', .one = cosh },
        .{ .name = "tanh", .kind = 'C', .one = tanh },   .{ .name = "cbrt", .kind = 'D', .one = cbrt },
    };
    var lines = std.mem.splitScalar(u8, @embedFile("../testing/vectors/libm.txt"), '\n');
    for (0..3) |_| _ = lines.next();
    var text: [256]u8 = undefined;
    for (funcs, 0..) |func, fi| {
        for (0..8) |dist| {
            var g: Sampler = .{ .state = 0x9E3779B97F4A7C15 +% 1000003 * @as(u64, fi * 8 + dist) };
            var small: Md5 = .init(.{});
            var large: Md5 = .init(.{});
            var n_small: u32 = 0;
            var n_large: u32 = 0;
            for (0..20000) |_| {
                const x = g.sample(@intCast(dist));
                const y = if (func.two) |two| blk: {
                    const x2 = g.sample(@intCast((dist + 3) % 8));
                    break :blk two(if (two == pow) @abs(x) else x, x2);
                } else func.one.?(x);
                if (@abs(x) >= 1e8) {
                    putDouble(&large, y);
                    n_large += 1;
                } else {
                    putDouble(&small, y);
                    n_small += 1;
                }
            }
            var ds: [16]u8 = undefined;
            var dl: [16]u8 = undefined;
            small.final(&ds);
            large.final(&dl);
            var got = try std.fmt.bufPrint(&text, "{c} {s} {d} small {d} {x}", .{ func.kind, func.name, dist, n_small, ds });
            try testing.expectEqualStrings(lines.next().?, got);
            got = try std.fmt.bufPrint(&text, "{c} {s} {d} large {d} {x}", .{ func.kind, func.name, dist, n_large, dl });
            try testing.expectEqualStrings(lines.next().?, got);
        }
    }
    // The cube roots FFmpeg's MP3 tables take, every integer below 8208 (T29b).
    var cubes: Md5 = .init(.{});
    for (0..8208) |v| {
        const x: f64 = @floatFromInt(v);
        putDouble(&cubes, cbrt(x));
    }
    var dc: [16]u8 = undefined;
    cubes.final(&dc);
    const got = try std.fmt.bufPrint(&text, "I cbrt 8208 {x}", .{dc});
    try testing.expectEqualStrings(lines.next().?, got);
}

/// pvq.c's celt_exp_rotation angle, as the vectors compute it.
fn rotationAngle(len: u32, k: u32, spread: u32) f32 {
    const gain = @as(f32, @floatFromInt(len)) / @as(f32, @floatFromInt(len + (20 - 5 * spread) * k));
    return @floatCast(std.math.pi * @as(f64, gain) * gain / 4);
}
