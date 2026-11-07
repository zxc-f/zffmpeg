// SPDX-License-Identifier: MIT
// Derived from the GNU C Library 2.44's sysdeps/ieee754/flt-32/s_cbrtf.c,
// from the CORE-MATH project (https://core-math.gitlabpages.inria.fr/,
// file src/binary32/cbrt/cbrtf.c); copyright (c) 2023, 2024 Alexei
// Sibidanov. Permission is hereby granted, free of charge, to any person
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
//! glibc's `cbrtf` (core/libm.zig), CORE-MATH's correctly rounded cube root
//! since glibc 2.40: a polynomial first guess in double, one Newton step
//! when its rounding is in doubt, and an exact-case fix. Being correctly
//! rounded, its result does not depend on where GCC fused operations, so
//! this port computes as the C source reads (FFmpeg's AAC decoder's pulse
//! tool calls it, T30b).

const std = @import("std");

pub fn cbrtf(x: f32) f32 {
    const escale = [3]u64{
        @bitCast(@as(f64, 1.0)),
        @bitCast(@as(f64, 0x1.428a2f98d728bp+0)), // 2^(1/3)
        @bitCast(@as(f64, 0x1.965fea53d6e3dp+0)), // 2^(2/3)
    };
    const u: u32 = @bitCast(x);
    var au = u << 1;
    const sgn = u >> 31;
    var e = au >> 24;
    if (au < 1 << 24 or au >= 0xff << 24) {
        if (au >= 0xff << 24) return x + x; // inf, nan
        if (au == 0) return x; // +-0
        // Subnormal.
        const nz: u5 = @intCast(@clz(au) - 7);
        au <<= nz;
        e -%= @as(u32, nz) - 1;
    }
    const mant = au & 0xffffff;
    e +%= 899;
    const et = e / 3;
    const it = e % 3;
    var isc = escale[it];
    isc +%= @as(u64, et -% 342) << 52;
    isc |= @as(u64, sgn) << 63;
    const cvt2: f64 = @bitCast(isc);
    const c = [8]f64{
        0x1.2319d352ea5d5p-1,  0x1.67ad8ee258d1ap-1, -0x1.9342edf9cbad9p-2, 0x1.b6388fc510a75p-3,
        -0x1.6002455599e2fp-4, 0x1.7b096936192c4p-6, -0x1.e5577187e8bf8p-9, 0x1.169ef81d6c34ep-12,
    };
    const z: f64 = @bitCast(@as(u64, mant) << 28 | @as(u64, 0x3ff) << 52);
    const r0 = -0x1.9931c6c2d19d1p-6 / z;
    const z2 = z * z;
    const z4 = z2 * z2;
    var f = ((c[0] + z * c[1]) + z2 * (c[2] + z * c[3])) + z4 * ((c[4] + z * c[5]) + z2 * (c[6] + z * c[7])) + r0;
    var r = f * cvt2;
    var ub: f32 = @floatCast(r);
    const lb: f32 = @floatCast(r - cvt2 * 1.4182e-9);
    if (ub == lb) return ub;
    const newton = -0x1.ab16ec65d138fp+3; // C's u0
    const h = f * f * f - z;
    f -= (f * r0 * newton) * h;
    r = f * cvt2;
    var cvt1: u64 = @bitCast(r);
    ub = @floatCast(r);
    const m0: i64 = @bitCast(cvt1 << 19);
    const m1 = m0 >> 63;
    if ((m0 ^ m1) < (@as(i64, 1) << 31)) {
        cvt1 = (cvt1 +% (@as(u64, 1) << 31)) & 0xffffffff00000000;
        ub = @floatCast(@as(f64, @bitCast(cvt1)));
    }
    return ub;
}

test "cube roots of exact cubes, signs, subnormals and the special values" {
    try std.testing.expectEqual(@as(f32, 3), cbrtf(27));
    try std.testing.expectEqual(@as(f32, -2), cbrtf(-8));
    try std.testing.expectEqual(@as(f32, 0x1p-49), cbrtf(0x1p-147));
    try std.testing.expect(std.math.isNan(cbrtf(std.math.nan(f32))));
    try std.testing.expectEqual(std.math.inf(f32), cbrtf(std.math.inf(f32)));
    try std.testing.expectEqual(@as(f32, -0.0), cbrtf(-0.0));
    // Correct rounding: the double cube root rounded, for values far from
    // a rounding boundary.
    var v: f32 = 1.0e-30;
    while (v < 1.0e30) : (v *= 3.7) {
        const want: f32 = @floatCast(std.math.cbrt(@as(f64, v)));
        const got = cbrtf(v);
        try std.testing.expect(@abs(@as(f64, got) - @as(f64, want)) <= @as(f64, std.math.floatEps(f32)) * @abs(@as(f64, want)));
    }
}

test "cbrtf returns glibc's results (vectors/libm.txt)" {
    const Md5 = std.crypto.hash.Md5;
    const FloatSampler = @import("powf.zig").FloatSampler;
    var lines = std.mem.splitScalar(u8, @embedFile("../../testing/vectors/libm.txt"), '\n');
    var line = lines.next().?;
    while (!std.mem.startsWith(u8, line, "R cbrtf ")) line = lines.next().?;
    var text: [128]u8 = undefined;
    var md5: Md5 = .init(.{});
    for (0..65536) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(cbrtf(@floatFromInt(v))), .little);
        md5.update(&b);
    }
    var digest: [Md5.digest_length]u8 = undefined;
    md5.final(&digest);
    try std.testing.expectEqualStrings(line, try std.fmt.bufPrint(&text, "R cbrtf 65536 {x}", .{digest}));
    for (0..8) |d| {
        var g: FloatSampler = .{ .state = 0x9E3779B97F4A7C15 +% 1000003 * @as(u64, 2000 + d) };
        md5 = .init(.{});
        for (0..20000) |_| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(cbrtf(g.sample(@intCast(d)))), .little);
            md5.update(&b);
        }
        md5.final(&digest);
        try std.testing.expectEqualStrings(lines.next().?, try std.fmt.bufPrint(&text, "S cbrtf {d} 20000 {x}", .{ d, digest }));
    }
}
