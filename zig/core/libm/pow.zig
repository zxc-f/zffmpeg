// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/e_pow.c and
// e_pow_log_data.c (from Arm's optimized-routines; copyright (C) 2018-2026
// Free Software Foundation, Inc.), as built on x86-64 in its FMA variant
// (e_pow-fma.c). The GNU C Library is free software; you can redistribute
// it and/or modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either version 2.1
// of the License, or (at your option) any later version.
//! glibc's double `pow` (core/libm.zig): log(x) to about 68 bits from its
//! own table, times y, then exp's table and polynomial. `fma` marks GCC's
//! contractions (sin.zig has the rule).

const std = @import("std");
const e = @import("exp.zig");

fn fma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}

const table_bits = 7;
const n = 1 << table_bits;
const off: u64 = 0x3fe6955500000000;
const ln2_hi = 0x1.62e42fefa3800p-1;
const ln2_lo = 0x1.ef35793c76730p-45;
const poly = [7]f64{
    -0x1p-1,
    0x1.555555555556p-2 * -2,
    -0x1.0000000000006p-2 * -2,
    0x1.999999959554ep-3 * 4,
    -0x1.555555529a47ap-3 * 4,
    0x1.2495b9b4845e9p-3 * -8,
    -0x1.0002b8b263fc3p-3 * -8,
};

/// __pow_log_data.tab: 1/c, log(c) rounded to 43 fraction bits, and the
/// rest of log(c).
const tab = [n][3]f64{
    .{ 0x1.6a00000000000p+0, -0x1.62c82f2b9c800p-2, 0x1.ab42428375680p-48 },
    .{ 0x1.6800000000000p+0, -0x1.5d1bdbf580800p-2, -0x1.ca508d8e0f720p-46 },
    .{ 0x1.6600000000000p+0, -0x1.5767717455800p-2, -0x1.362a4d5b6506dp-45 },
    .{ 0x1.6400000000000p+0, -0x1.51aad872df800p-2, -0x1.684e49eb067d5p-49 },
    .{ 0x1.6200000000000p+0, -0x1.4be5f95777800p-2, -0x1.41b6993293ee0p-47 },
    .{ 0x1.6000000000000p+0, -0x1.4618bc21c6000p-2, 0x1.3d82f484c84ccp-46 },
    .{ 0x1.5e00000000000p+0, -0x1.404308686a800p-2, 0x1.c42f3ed820b3ap-50 },
    .{ 0x1.5c00000000000p+0, -0x1.3a64c55694800p-2, 0x1.0b1c686519460p-45 },
    .{ 0x1.5a00000000000p+0, -0x1.347dd9a988000p-2, 0x1.5594dd4c58092p-45 },
    .{ 0x1.5800000000000p+0, -0x1.2e8e2bae12000p-2, 0x1.67b1e99b72bd8p-45 },
    .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
    .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
    .{ 0x1.5400000000000p+0, -0x1.22941fbcf7800p-2, -0x1.65a242853da76p-46 },
    .{ 0x1.5200000000000p+0, -0x1.1c898c1699800p-2, -0x1.fafbc68e75404p-46 },
    .{ 0x1.5000000000000p+0, -0x1.1675cababa800p-2, 0x1.f1fc63382a8f0p-46 },
    .{ 0x1.4e00000000000p+0, -0x1.1058bf9ae4800p-2, -0x1.6a8c4fd055a66p-45 },
    .{ 0x1.4c00000000000p+0, -0x1.0a324e2739000p-2, -0x1.c6bee7ef4030ep-47 },
    .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
    .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
    .{ 0x1.4800000000000p+0, -0x1.fb9186d5e4000p-3, 0x1.d572aab993c87p-47 },
    .{ 0x1.4600000000000p+0, -0x1.ef0adcbdc6000p-3, 0x1.b26b79c86af24p-45 },
    .{ 0x1.4400000000000p+0, -0x1.e27076e2af000p-3, -0x1.72f4f543fff10p-46 },
    .{ 0x1.4200000000000p+0, -0x1.d5c216b4fc000p-3, 0x1.1ba91bbca681bp-45 },
    .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
    .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
    .{ 0x1.3e00000000000p+0, -0x1.bc286742d9000p-3, 0x1.94eb0318bb78fp-46 },
    .{ 0x1.3c00000000000p+0, -0x1.af3c94e80c000p-3, 0x1.a4e633fcd9066p-52 },
    .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
    .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
    .{ 0x1.3800000000000p+0, -0x1.9525a9cf45000p-3, -0x1.ad1d904c1d4e3p-45 },
    .{ 0x1.3600000000000p+0, -0x1.87fa06520d000p-3, 0x1.bbdbf7fdbfa09p-45 },
    .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
    .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
    .{ 0x1.3200000000000p+0, -0x1.6d60fe719d000p-3, -0x1.0e46aa3b2e266p-46 },
    .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
    .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
    .{ 0x1.2e00000000000p+0, -0x1.526e5e3a1b000p-3, -0x1.0de8b90075b8fp-45 },
    .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
    .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
    .{ 0x1.2a00000000000p+0, -0x1.371fc201e9000p-3, 0x1.178864d27543ap-48 },
    .{ 0x1.2800000000000p+0, -0x1.29552f81ff000p-3, -0x1.48d301771c408p-45 },
    .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
    .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
    .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
    .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
    .{ 0x1.2200000000000p+0, -0x1.fec9131dbe000p-4, -0x1.575545ca333f2p-45 },
    .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
    .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
    .{ 0x1.1e00000000000p+0, -0x1.c5e548f5bc000p-4, -0x1.d0c57585fbe06p-46 },
    .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
    .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
    .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
    .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
    .{ 0x1.1800000000000p+0, -0x1.6f0d28ae56000p-4, -0x1.69737c93373dap-45 },
    .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
    .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
    .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
    .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
    .{ 0x1.1200000000000p+0, -0x1.16536eea38000p-4, 0x1.47c5e768fa309p-46 },
    .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
    .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
    .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
    .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
    .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
    .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
    .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
    .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
    .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
    .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
    .{ 0x1.0600000000000p+0, -0x1.7b91b07d58000p-6, -0x1.88d5493faa639p-45 },
    .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
    .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
    .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
    .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
    .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
    .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
    .{ 0x1.fc00000000000p-1, 0x1.0101575890000p-7, -0x1.0c76b999d2be8p-46 },
    .{ 0x1.f800000000000p-1, 0x1.0205658938000p-6, -0x1.3dc5b06e2f7d2p-45 },
    .{ 0x1.f400000000000p-1, 0x1.8492528c90000p-6, -0x1.aa0ba325a0c34p-45 },
    .{ 0x1.f000000000000p-1, 0x1.0415d89e74000p-5, 0x1.111c05cf1d753p-47 },
    .{ 0x1.ec00000000000p-1, 0x1.466aed42e0000p-5, -0x1.c167375bdfd28p-45 },
    .{ 0x1.e800000000000p-1, 0x1.894aa149fc000p-5, -0x1.97995d05a267dp-46 },
    .{ 0x1.e400000000000p-1, 0x1.ccb73cdddc000p-5, -0x1.a68f247d82807p-46 },
    .{ 0x1.e200000000000p-1, 0x1.eea31c006c000p-5, -0x1.e113e4fc93b7bp-47 },
    .{ 0x1.de00000000000p-1, 0x1.1973bd1466000p-4, -0x1.5325d560d9e9bp-45 },
    .{ 0x1.da00000000000p-1, 0x1.3bdf5a7d1e000p-4, 0x1.cc85ea5db4ed7p-45 },
    .{ 0x1.d600000000000p-1, 0x1.5e95a4d97a000p-4, -0x1.c69063c5d1d1ep-45 },
    .{ 0x1.d400000000000p-1, 0x1.700d30aeac000p-4, 0x1.c1e8da99ded32p-49 },
    .{ 0x1.d000000000000p-1, 0x1.9335e5d594000p-4, 0x1.3115c3abd47dap-45 },
    .{ 0x1.cc00000000000p-1, 0x1.b6ac88dad6000p-4, -0x1.390802bf768e5p-46 },
    .{ 0x1.ca00000000000p-1, 0x1.c885801bc4000p-4, 0x1.646d1c65aacd3p-45 },
    .{ 0x1.c600000000000p-1, 0x1.ec739830a2000p-4, -0x1.dc068afe645e0p-45 },
    .{ 0x1.c400000000000p-1, 0x1.fe89139dbe000p-4, -0x1.534d64fa10afdp-45 },
    .{ 0x1.c000000000000p-1, 0x1.1178e8227e000p-3, 0x1.1ef78ce2d07f2p-45 },
    .{ 0x1.be00000000000p-1, 0x1.1aa2b7e23f000p-3, 0x1.ca78e44389934p-45 },
    .{ 0x1.ba00000000000p-1, 0x1.2d1610c868000p-3, 0x1.39d6ccb81b4a1p-47 },
    .{ 0x1.b800000000000p-1, 0x1.365fcb0159000p-3, 0x1.62fa8234b7289p-51 },
    .{ 0x1.b400000000000p-1, 0x1.4913d8333b000p-3, 0x1.5837954fdb678p-45 },
    .{ 0x1.b200000000000p-1, 0x1.527e5e4a1b000p-3, 0x1.633e8e5697dc7p-45 },
    .{ 0x1.ae00000000000p-1, 0x1.6574ebe8c1000p-3, 0x1.9cf8b2c3c2e78p-46 },
    .{ 0x1.ac00000000000p-1, 0x1.6f0128b757000p-3, -0x1.5118de59c21e1p-45 },
    .{ 0x1.aa00000000000p-1, 0x1.7898d85445000p-3, -0x1.c661070914305p-46 },
    .{ 0x1.a600000000000p-1, 0x1.8beafeb390000p-3, -0x1.73d54aae92cd1p-47 },
    .{ 0x1.a400000000000p-1, 0x1.95a5adcf70000p-3, 0x1.7f22858a0ff6fp-47 },
    .{ 0x1.a000000000000p-1, 0x1.a93ed3c8ae000p-3, -0x1.8724350562169p-45 },
    .{ 0x1.9e00000000000p-1, 0x1.b31d8575bd000p-3, -0x1.c358d4eace1aap-47 },
    .{ 0x1.9c00000000000p-1, 0x1.bd087383be000p-3, -0x1.d4bc4595412b6p-45 },
    .{ 0x1.9a00000000000p-1, 0x1.c6ffbc6f01000p-3, -0x1.1ec72c5962bd2p-48 },
    .{ 0x1.9600000000000p-1, 0x1.db13db0d49000p-3, -0x1.aff2af715b035p-45 },
    .{ 0x1.9400000000000p-1, 0x1.e530effe71000p-3, 0x1.212276041f430p-51 },
    .{ 0x1.9200000000000p-1, 0x1.ef5ade4dd0000p-3, -0x1.a211565bb8e11p-51 },
    .{ 0x1.9000000000000p-1, 0x1.f991c6cb3b000p-3, 0x1.bcbecca0cdf30p-46 },
    .{ 0x1.8c00000000000p-1, 0x1.07138604d5800p-2, 0x1.89cdb16ed4e91p-48 },
    .{ 0x1.8a00000000000p-1, 0x1.0c42d67616000p-2, 0x1.7188b163ceae9p-45 },
    .{ 0x1.8800000000000p-1, 0x1.1178e8227e800p-2, -0x1.c210e63a5f01cp-45 },
    .{ 0x1.8600000000000p-1, 0x1.16b5ccbacf800p-2, 0x1.b9acdf7a51681p-45 },
    .{ 0x1.8400000000000p-1, 0x1.1bf99635a6800p-2, 0x1.ca6ed5147bdb7p-45 },
    .{ 0x1.8200000000000p-1, 0x1.214456d0eb800p-2, 0x1.a87deba46baeap-47 },
    .{ 0x1.7e00000000000p-1, 0x1.2bef07cdc9000p-2, 0x1.a9cfa4a5004f4p-45 },
    .{ 0x1.7c00000000000p-1, 0x1.314f1e1d36000p-2, -0x1.8e27ad3213cb8p-45 },
    .{ 0x1.7a00000000000p-1, 0x1.36b6776be1000p-2, 0x1.16ecdb0f177c8p-46 },
    .{ 0x1.7800000000000p-1, 0x1.3c25277333000p-2, 0x1.83b54b606bd5cp-46 },
    .{ 0x1.7600000000000p-1, 0x1.419b423d5e800p-2, 0x1.8e436ec90e09dp-47 },
    .{ 0x1.7400000000000p-1, 0x1.4718dc271c800p-2, -0x1.f27ce0967d675p-45 },
    .{ 0x1.7200000000000p-1, 0x1.4c9e09e173000p-2, -0x1.e20891b0ad8a4p-45 },
    .{ 0x1.7000000000000p-1, 0x1.522ae0738a000p-2, 0x1.ebe708164c759p-45 },
    .{ 0x1.6e00000000000p-1, 0x1.57bf753c8d000p-2, 0x1.fadedee5d40efp-46 },
    .{ 0x1.6c00000000000p-1, 0x1.5d5bddf596000p-2, -0x1.a0b2a08a465dcp-47 },
};

fn top12(x: f64) u32 {
    return @intCast(@as(u64, @bitCast(x)) >> 52);
}

/// log_inline: log(x) as y + tail, the tail about 15 bits more.
fn logInline(ix: u64, tail: *f64) f64 {
    const tmp = ix -% off;
    const i: usize = @intCast((tmp >> (52 - table_bits)) % n);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52;
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const z: f64 = @bitCast(iz);
    const kd: f64 = @floatFromInt(k);
    const invc = tab[i][0];
    const logc = tab[i][1];
    const logctail = tab[i][2];
    const r = @mulAdd(f64, z, invc, -1.0);
    // k ln2 + log(c) + r.
    const t1 = fma(kd, ln2_hi, logc);
    const t2 = t1 + r;
    const lo1 = fma(kd, ln2_lo, logctail);
    const lo2 = t1 - t2 + r;
    const ar = poly[0] * r;
    const ar2 = r * ar;
    const ar3 = r * ar2;
    // k ln2 + log(c) + r + A[0] r^2.
    const hi = t2 + ar2;
    const lo3 = @mulAdd(f64, ar, r, -ar2);
    const lo4 = t2 - hi + ar2;
    // p = log1p(r) - r - A[0] r^2.
    const inner = fma(ar2, fma(r, poly[6], poly[5]), fma(r, poly[4], poly[3]));
    const outer = fma(ar2, inner, fma(r, poly[2], poly[1]));
    const lo = fma(ar3, outer, lo1 + lo2 + lo3 + lo4);
    const y = hi + lo;
    tail.* = hi - y + lo;
    return y;
}

const sign_bias_neg: u32 = 0x800 << e.table_bits;

/// specialcase for pow: as exp's, with a signed scale.
fn specialcase(tmp: f64, sbits_in: u64, ki: u64) f64 {
    var sbits = sbits_in;
    if (ki & 0x80000000 == 0) {
        // k > 0: the scale's exponent may have overflowed by <= 460.
        sbits -%= 1009 << 52;
        const scale: f64 = @bitCast(sbits);
        const y = fma(scale, tmp, scale);
        return y * 0x1p1009;
    }
    // k < 0: care in the subnormal range. Not fused: the product's second
    // use is in another basic block.
    sbits +%= 1022 << 52;
    const scale: f64 = @bitCast(sbits);
    const st = scale * tmp;
    var y = scale + st;
    if (@abs(y) < 1.0) {
        const one: f64 = if (y < 0.0) -1.0 else 1.0;
        var lo = scale - y + st;
        const hi = one + y;
        lo = one - hi + y + lo;
        y = (hi + lo) - one;
        // The sign of zero.
        if (y == 0.0) y = @bitCast(sbits & 0x8000000000000000);
    }
    return 0x1p-1022 * y;
}

/// __math_oflow and __math_uflow.
fn oflow(sign: u32) f64 {
    return if (sign != 0) -std.math.inf(f64) else std.math.inf(f64);
}

fn uflow(sign: u32) f64 {
    return if (sign != 0) -0.0 else 0.0;
}

/// exp_inline: sign * exp(x + xtail).
fn expInline(x: f64, xtail: f64, sign_bias: u32) f64 {
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) - top12(0x1p-54)) {
        if (abstop -% top12(0x1p-54) >= 0x80000000) {
            const one = 1.0 + x;
            return if (sign_bias != 0) -one else one;
        }
        if (abstop >= top12(1024.0)) {
            return if (@as(u64, @bitCast(x)) >> 63 != 0) uflow(sign_bias) else oflow(sign_bias);
        }
        abstop = 0;
    }
    var kd = fma(e.inv_ln2_n, x, e.shift);
    const ki: u64 = @bitCast(kd);
    kd -= e.shift;
    var r = fma(kd, e.neg_ln2_lo_n, fma(kd, e.neg_ln2_hi_n, x));
    r += xtail;
    const idx = 2 * (ki % e.n);
    const top = (ki +% sign_bias) << (52 - e.table_bits);
    const tail: f64 = @bitCast(e.tab[idx]);
    const sbits = e.tab[idx + 1] +% top;
    const r2 = r * r;
    const tmp = fma(r2 * r2, fma(r, e.c5, e.c4), fma(r2, fma(r, e.c3, e.c2), tail + r));
    if (abstop == 0) return specialcase(tmp, sbits, ki);
    const scale: f64 = @bitCast(sbits);
    return fma(scale, tmp, scale);
}

/// checkint: 0 if not an integer, 1 if odd, 2 if even.
fn checkint(iy: u64) u32 {
    const ex: u32 = @intCast(iy >> 52 & 0x7ff);
    if (ex < 0x3ff) return 0;
    if (ex > 0x3ff + 52) return 2;
    const bit: u6 = @intCast(0x3ff + 52 - ex);
    if (iy & ((@as(u64, 1) << bit) - 1) != 0) return 0;
    if (iy & (@as(u64, 1) << bit) != 0) return 1;
    return 2;
}

/// zeroinfnan: 0, infinity or NaN.
fn zeroinfnan(i: u64) bool {
    return 2 *% i -% 1 >= 2 *% @as(u64, @bitCast(std.math.inf(f64))) - 1;
}

const one_bits: u64 = @bitCast(@as(f64, 1.0));
const inf_bits: u64 = @bitCast(std.math.inf(f64));

/// glibc's pow.
pub fn pow(x: f64, y: f64) f64 {
    var sign_bias: u32 = 0;
    var ix: u64 = @bitCast(x);
    const iy: u64 = @bitCast(y);
    var topx = top12(x);
    const topy = top12(y);
    if (topx -% 0x001 >= 0x7ff - 0x001 or (topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
        // x < 0x1p-126 or inf or NaN; or |y| < 0x1p-65, |y| >= 0x1p63 or NaN.
        if (zeroinfnan(iy)) {
            if (2 *% iy == 0) return if (std.math.isSignalNan(x)) x + y else 1.0;
            if (ix == one_bits) return if (std.math.isSignalNan(y)) x + y else 1.0;
            if (2 *% ix > 2 *% inf_bits or 2 *% iy > 2 *% inf_bits) return x + y;
            if (2 *% ix == 2 *% one_bits) return 1.0;
            if ((2 *% ix < 2 *% one_bits) == (iy >> 63 == 0)) return 0.0;
            return y * y;
        }
        if (zeroinfnan(ix)) {
            var x2 = x * x;
            if (ix >> 63 != 0 and checkint(iy) == 1) {
                x2 = -x2;
                sign_bias = 1;
            }
            if (2 *% ix == 0 and iy >> 63 != 0) return if (sign_bias != 0) -std.math.inf(f64) else std.math.inf(f64);
            return if (iy >> 63 != 0) 1 / x2 else x2;
        }
        // x and y are non-zero finite.
        if (ix >> 63 != 0) {
            const yint = checkint(iy);
            if (yint == 0) return (x - x) / (x - x);
            if (yint == 1) sign_bias = sign_bias_neg;
            ix &= 0x7fffffffffffffff;
            topx &= 0x7ff;
        }
        if ((topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
            if (ix == one_bits) return 1.0;
            if ((topy & 0x7ff) < 0x3be) return if (ix > one_bits) 1.0 + y else 1.0 - y;
            return if ((ix > one_bits) == (topy < 0x800)) oflow(0) else uflow(0);
        }
        if (topx == 0) {
            // Normalize a subnormal x.
            ix = @bitCast(x * 0x1p52);
            ix &= 0x7fffffffffffffff;
            ix -%= 52 << 52;
        }
    }
    var lo: f64 = undefined;
    const hi = logInline(ix, &lo);
    const ehi = y * hi;
    const elo = fma(y, lo, @mulAdd(f64, y, hi, -ehi));
    return expInline(ehi, elo, sign_bias);
}
