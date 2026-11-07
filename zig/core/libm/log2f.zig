// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/flt-32/e_log2f.c,
// e_log2f_data.c and math_errf.c (from Arm's optimized-routines; copyright
// (C) 2017-2026 Free Software Foundation, Inc.), as built on x86-64 in its
// FMA variant (sysdeps/x86_64/fpu/multiarch/e_log2f-fma.c).
// The GNU C Library is free software; you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published
// by the Free Software Foundation; either version 2.1 of the License, or (at
// your option) any later version.
//! glibc's single-precision `log2f` (core/libm.zig): x = 2^k z with z near
//! one of 16 table centers c, then log2(c) + k plus a degree-4 polynomial
//! in z/c - 1, in double, rounded once. FFmpeg's SBR decoder calls it for
//! its frequency band counts, `log2f(k2 / (float)k0)` (T30c).
//!
//! glibc runs `__log2f_fma` on a CPU with FMA and AVX2. Its disassembly in
//! the installed libm.so.6 fuses five products into their additions:
//! `z * invc - 1` and the four steps of the polynomial; `r * r` stays a
//! plain product. `@mulAdd` marks the fused ones. The special cases
//! return that build's values: -inf for zero, x for +inf, and
//! `(x - x) / (x - x)` (x86's default NaN, or x's NaN quieted) for a
//! negative x or a NaN. `errno` is not set.

const std = @import("std");

fn f64Bits(b: u64) f64 {
    return @bitCast(b);
}

const table_bits = 4;
const n = 1 << table_bits;
/// The start of the subinterval of table entry 0.
const off: u32 = 0x3f330000;

/// `__log2f_data.tab`: each subinterval's 1/c and log2(c).
const tab = [n]struct { invc: f64, logc: f64 }{
    .{ .invc = 0x1.661ec79f8f3bep+0, .logc = -0x1.efec65b963019p-2 },
    .{ .invc = 0x1.571ed4aaf883dp+0, .logc = -0x1.b0b6832d4fca4p-2 },
    .{ .invc = 0x1.49539f0f010bp+0, .logc = -0x1.7418b0a1fb77bp-2 },
    .{ .invc = 0x1.3c995b0b80385p+0, .logc = -0x1.39de91a6dcf7bp-2 },
    .{ .invc = 0x1.30d190c8864a5p+0, .logc = -0x1.01d9bf3f2b631p-2 },
    .{ .invc = 0x1.25e227b0b8eap+0, .logc = -0x1.97c1d1b3b7afp-3 },
    .{ .invc = 0x1.1bb4a4a1a343fp+0, .logc = -0x1.2f9e393af3c9fp-3 },
    .{ .invc = 0x1.12358f08ae5bap+0, .logc = -0x1.960cbbf788d5cp-4 },
    .{ .invc = 0x1.0953f419900a7p+0, .logc = -0x1.a6f9db6475fcep-5 },
    .{ .invc = 0x1p+0, .logc = 0x0p+0 },
    .{ .invc = 0x1.e608cfd9a47acp-1, .logc = 0x1.338ca9f24f53dp-4 },
    .{ .invc = 0x1.ca4b31f026aap-1, .logc = 0x1.476a9543891bap-3 },
    .{ .invc = 0x1.b2036576afce6p-1, .logc = 0x1.e840b4ac4e4d2p-3 },
    .{ .invc = 0x1.9c2d163a1aa2dp-1, .logc = 0x1.40645f0c6651cp-2 },
    .{ .invc = 0x1.886e6037841edp-1, .logc = 0x1.88e9c2c1b9ff8p-2 },
    .{ .invc = 0x1.767dcf5534862p-1, .logc = 0x1.ce0a44eb17bccp-2 },
};

/// `__log2f_data.poly`.
const poly = [4]f64{ -0x1.712b6f70a7e4dp-2, 0x1.ecabf496832ep-2, -0x1.715479ffae3dep-1, 0x1.715475f35c8b8p0 };

/// glibc's `log2f`, its FMA build.
pub fn log2f(x: f32) f32 {
    var ix: u32 = @bitCast(x);
    // WANT_ROUNDING: log2(1) is +0 in every rounding mode.
    if (ix == 0x3f800000) return 0;
    if (ix -% 0x00800000 >= 0x7f800000 - 0x00800000) {
        // x < 0x1p-126, inf or NaN.
        if (ix *% 2 == 0) return -std.math.inf(f32); // __math_divzerof(1)
        if (ix == 0x7f800000) return x;
        if ((ix & 0x80000000) != 0 or ix *% 2 >= 0xff000000) return (x - x) / (x - x); // __math_invalidf
        // A subnormal x, normalized.
        ix = @bitCast(x * 0x1p23);
        ix -%= 23 << 23;
    }
    const tmp = ix -% off;
    const i = (tmp >> (23 - table_bits)) % n;
    const top = tmp & 0xff800000;
    const iz = ix -% top;
    const k: i32 = @as(i32, @bitCast(tmp)) >> 23;
    const z: f64 = @as(f32, @bitCast(iz));
    const r = @mulAdd(f64, z, tab[i].invc, -1.0);
    const y0 = tab[i].logc + @as(f64, @floatFromInt(k));
    const r2 = r * r;
    var y = @mulAdd(f64, poly[1], r, poly[2]);
    y = @mulAdd(f64, poly[0], r2, y);
    const p = @mulAdd(f64, poly[3], r, y0);
    y = @mulAdd(f64, y, r2, p);
    return @floatCast(y);
}

test "log2f of powers of two, one, and the special values" {
    try std.testing.expectEqual(@as(f32, 0), log2f(1));
    try std.testing.expectEqual(@as(f32, 3), log2f(8));
    try std.testing.expectEqual(@as(f32, -149), log2f(0x1p-149));
    try std.testing.expectEqual(-std.math.inf(f32), log2f(0));
    try std.testing.expectEqual(-std.math.inf(f32), log2f(-0.0));
    try std.testing.expectEqual(std.math.inf(f32), log2f(std.math.inf(f32)));
    try std.testing.expect(std.math.isNan(log2f(-1)));
    try std.testing.expect(std.math.isNan(log2f(std.math.nan(f32))));
}

test "log2f returns glibc's results (vectors/libm.txt)" {
    const Md5 = std.crypto.hash.Md5;
    const FloatSampler = @import("powf.zig").FloatSampler;
    var lines = std.mem.splitScalar(u8, @embedFile("../../testing/vectors/libm.txt"), '\n');
    var line = lines.next().?;
    while (!std.mem.startsWith(u8, line, "L log2f ")) line = lines.next().?;
    var text: [128]u8 = undefined;
    var digest: [Md5.digest_length]u8 = undefined;
    var md5: Md5 = .init(.{});
    for (1..193) |a| {
        for (1..193) |b| {
            const q = @as(f32, @floatFromInt(a)) / @as(f32, @floatFromInt(b));
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @bitCast(log2f(q)), .little);
            md5.update(&bytes);
        }
    }
    md5.final(&digest);
    try std.testing.expectEqualStrings(line, try std.fmt.bufPrint(&text, "L log2f 192 {x}", .{digest}));
    for (0..8) |d| {
        var g: FloatSampler = .{ .state = 0x9E3779B97F4A7C15 +% 1000003 * @as(u64, 3000 + d) };
        md5 = .init(.{});
        for (0..20000) |_| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @bitCast(log2f(g.sample(@intCast(d)))), .little);
            md5.update(&bytes);
        }
        md5.final(&digest);
        try std.testing.expectEqualStrings(lines.next().?, try std.fmt.bufPrint(&text, "G log2f {d} 20000 {x}", .{ d, digest }));
    }
}
