// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/flt-32/e_expf.c,
// e_exp2f_data.c, e_logf.c, e_logf_data.c, math_errf.c and math_config.h
// (from Arm's optimized-routines; copyright (C) 2017-2026 Free Software
// Foundation, Inc.), as built on x86-64 in their FMA variants (e_expf-fma.c,
// e_logf-fma.c).
// The GNU C Library is free software; you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published
// by the Free Software Foundation; either version 2.1 of the License, or (at
// your option) any later version.
//! glibc's single-precision `expf` and `logf` (core/libm.zig), whose
//! product is FFmpeg's `ff_fast_powf` (the AAC encoder's form factor,
//! TODO.md T32d). glibc runs `__expf_fma` and `__logf_fma` on a CPU with
//! FMA; their disassembly in the installed libm.so.6 fuses more than the
//! source's products and sums: `expf` computes `k` and `r` each as one
//! fused `InvLn2N * x + c`, and both functions fuse every polynomial step.
//! `@mulAdd` marks those fused operations.

const std = @import("std");
const libm = @import("../libm.zig");

fn f64Bits(b: u64) f64 {
    return @bitCast(b);
}

/// `__exp2f_data.invln2_scaled`: 32 / ln 2.
const inv_ln2_n = f64Bits(0x40471547652b82fe);
/// `__exp2f_data.shift`: 0x1.8p52.
const exp_shift = f64Bits(0x4338000000000000);
/// `__exp2f_data.poly_scaled`.
const exp_c0 = f64Bits(0x3ebc6af84b912394);
const exp_c1 = f64Bits(0x3f2ebfce50fac4f3);
const exp_c2 = f64Bits(0x3f962e42ff0c52d6);

/// `xflowf`: `y * y` with the sign, which over- or underflows as the
/// result should.
fn xflowf(y: f32) f32 {
    @setFloatMode(.strict);
    return y * y;
}

/// glibc's expf.
pub fn expf(x: f32) f32 {
    @setFloatMode(.strict);
    const ux: u32 = @bitCast(x);
    const abstop = (ux >> 20) & 0x7ff;
    if (abstop >= 0x42b) {
        // |x| >= 88 or NaN.
        if (ux == 0xff800000) return 0;
        if (abstop >= 0x7f8) return x + x;
        if (x > 0x1.62e42ep6) return xflowf(0x1p97); // __math_oflowf
        if (x < -0x1.9fe368p6) return xflowf(0x1p-95); // __math_uflowf
        if (x < -0x1.9d1d9ep6) return xflowf(0x1.4p-75); // __math_may_uflowf
    }
    const xd: f64 = x;
    // k = round(x * 32 / ln 2), r = x * 32 / ln 2 - k, each one fused
    // operation in the FMA build.
    var kd = @mulAdd(f64, inv_ln2_n, xd, exp_shift);
    const ki: u64 = @bitCast(kd);
    kd -= exp_shift;
    const r = @mulAdd(f64, inv_ln2_n, xd, -kd);
    const t = libm.exp2f_tab[ki % 32] +% (ki << 47);
    const s: f64 = @bitCast(t);
    const z = @mulAdd(f64, exp_c0, r, exp_c1);
    const r2 = r * r;
    var y = @mulAdd(f64, exp_c2, r, 1.0);
    y = @mulAdd(f64, z, r2, y);
    return @floatCast(y * s);
}

/// `__logf_data.tab`: { invc, logc } by the subinterval.
const logf_tab = [16][2]u64{
    .{ 0x3ff661ec79f8f3be, 0xbfd57bf7808caade },
    .{ 0x3ff571ed4aaf883d, 0xbfd2bef0a7c06ddb },
    .{ 0x3ff49539f0f010b0, 0xbfd01eae7f513a67 },
    .{ 0x3ff3c995b0b80385, 0xbfcb31d8a68224e9 },
    .{ 0x3ff30d190c8864a5, 0xbfc6574f0ac07758 },
    .{ 0x3ff25e227b0b8ea0, 0xbfc1aa2bc79c8100 },
    .{ 0x3ff1bb4a4a1a343f, 0xbfba4e76ce8c0e5e },
    .{ 0x3ff12358f08ae5ba, 0xbfb1973c5a611ccc },
    .{ 0x3ff0953f419900a7, 0xbfa252f438e10c1e },
    .{ 0x3ff0000000000000, 0x0000000000000000 },
    .{ 0x3fee608cfd9a47ac, 0x3faaa5aa5df25984 },
    .{ 0x3feca4b31f026aa0, 0x3fbc5e53aa362eb4 },
    .{ 0x3feb2036576afce6, 0x3fc526e57720db08 },
    .{ 0x3fe9c2d163a1aa2d, 0x3fcbc2860d224770 },
    .{ 0x3fe886e6037841ed, 0x3fd1058bc8a07ee1 },
    .{ 0x3fe767dcf5534862, 0x3fd4043057b6ee09 },
};
const logf_ln2 = f64Bits(0x3fe62e42fefa39ef);
/// `__logf_data.poly`.
const logf_a0 = f64Bits(0xbfd00ea348b88334);
const logf_a1 = f64Bits(0x3fd5575b0be00b6a);
const logf_a2 = f64Bits(0xbfdffffef20a4123);

/// glibc's logf.
pub fn logf(x: f32) f32 {
    @setFloatMode(.strict);
    var ix: u32 = @bitCast(x);
    // log(1) is +0 in every rounding mode.
    if (ix == 0x3f800000) return 0;
    if (ix -% 0x00800000 >= 0x7f800000 - 0x00800000) {
        // x < 0x1p-126, inf or NaN.
        if (ix *% 2 == 0) return -std.math.inf(f32); // __math_divzerof(1)
        if (ix == 0x7f800000) return x;
        if ((ix & 0x80000000) != 0 or ix *% 2 >= 0xff000000) {
            // __math_invalidf: (x - x) / (x - x), a NaN (x's own for a
            // NaN x).
            const d = x - x;
            return d / d;
        }
        // A subnormal x, normalized.
        ix = @bitCast(x * 0x1p23);
        ix -%= 23 << 23;
    }
    const off: u32 = 0x3f330000;
    const tmp = ix -% off;
    const i = (tmp >> (23 - 4)) % 16;
    const k: i32 = @as(i32, @bitCast(tmp)) >> 23;
    const iz = ix -% (tmp & 0xff800000);
    const invc = f64Bits(logf_tab[i][0]);
    const logc = f64Bits(logf_tab[i][1]);
    const z: f64 = @as(f32, @bitCast(iz));
    // log(x) = log1p(z/c - 1) + log(c) + k ln 2.
    const r = @mulAdd(f64, z, invc, -1.0);
    const y0 = @mulAdd(f64, @floatFromInt(k), logf_ln2, logc);
    const r2 = r * r;
    var y = @mulAdd(f64, logf_a1, r, logf_a2);
    y = @mulAdd(f64, logf_a0, r2, y);
    y = @mulAdd(f64, y, r2, y0 + r);
    return @floatCast(y);
}

test "expf and logf of their special values" {
    const inf = std.math.inf(f32);
    try std.testing.expectEqual(0, expf(-inf));
    try std.testing.expectEqual(inf, expf(inf));
    try std.testing.expectEqual(inf, expf(100));
    try std.testing.expectEqual(0, expf(-200));
    try std.testing.expectEqual(1, expf(0));
    try std.testing.expect(std.math.isNan(expf(std.math.nan(f32))));
    try std.testing.expectEqual(0, logf(1));
    try std.testing.expectEqual(-inf, logf(0));
    try std.testing.expectEqual(-inf, logf(-0.0));
    try std.testing.expectEqual(inf, logf(inf));
    try std.testing.expect(std.math.isNan(logf(-1)));
}

test "expf and logf return glibc's results (vectors/libm.txt)" {
    const Md5 = std.crypto.hash.Md5;
    const FloatSampler = @import("powf.zig").FloatSampler;
    var lines = std.mem.splitScalar(u8, @embedFile("../../testing/vectors/libm.txt"), '\n');
    var line = lines.next().?;
    while (!std.mem.startsWith(u8, line, "X expf ")) line = lines.next().?;
    var text: [128]u8 = undefined;
    var digest: [Md5.digest_length]u8 = undefined;
    const fns = [2]*const fn (f32) f32{ expf, logf };
    const names = [2][]const u8{ "expf", "logf" };
    for (fns, names, 0..) |f, name, fi| {
        for (0..8) |d| {
            var g: FloatSampler = .{ .state = 0x9E3779B97F4A7C15 +% 1000003 * @as(u64, 6000 + 10 * fi + d) };
            var md5: Md5 = .init(.{});
            for (0..20000) |_| {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, @bitCast(f(g.sample(@intCast(d)))), .little);
                md5.update(&bytes);
            }
            md5.final(&digest);
            try std.testing.expectEqualStrings(line, try std.fmt.bufPrint(&text, "X {s} {d} 20000 {x}", .{ name, d, digest }));
            line = lines.next() orelse "";
        }
    }
}
