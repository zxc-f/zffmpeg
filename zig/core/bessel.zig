// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg at commit 5d5a38a7e46be296eab75982c0986054f731e19e:
// libavutil/mathematics.c (av_bessel_i0 and eval_poly), Copyright (c)
// 2005-2012 Michael Niedermayer <michaelni@gmx.at>. Its coefficients are
// the minimax rational approximations of Blair and Edwards (Chalk River
// Report AECL-4928, 1974), taken by FFmpeg from the Boost project
// (Copyright John Maddock 2006, Boost Software License 1.0, whose notice
// FFmpeg's file keeps).
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! `av_bessel_i0`, as libavutil computes it: the resampler's Kaiser window
//! (T24) and the AAC decoder's KBD windows (T30b) take it, at run time and
//! at compile time.

const libm = @import("libm.zig");

const bessel_p1 = [_]f64{
    -2.2335582639474375249e+15, -5.5050369673018427753e+14, -3.2940087627407749166e+13,
    -8.4925101247114157499e+11, -1.1912746104985237192e+10, -1.0313066708737980747e+08,
    -5.9545626019847898221e+05, -2.4125195876041896775e+03, -7.0935347449210549190e+00,
    -1.5453977791786851041e-02, -2.5172644670688975051e-05, -3.0517226450451067446e-08,
    -2.6843448573468483278e-11, -1.5982226675653184646e-14, -5.2487866627945699800e-18,
};
const bessel_q1 = [_]f64{
    -2.2335582639474375245e+15, 7.8858692566751002988e+12,  -1.2207067397808979846e+10,
    1.0377081058062166144e+07,  -4.8527560179962773045e+03, 1.0,
};
const bessel_p2 = [_]f64{
    -2.2210262233306573296e-04, 1.3067392038106924055e-02,  -4.4700805721174453923e-01,
    5.5674518371240761397e+00,  -2.3517945679239481621e+01, 3.1611322818701131207e+01,
    -9.6090021968656180000e+00,
};
const bessel_q2 = [_]f64{
    -5.5194330231005480228e-04, 3.2547697594819615062e-02,  -1.1151759188741312645e+00,
    1.3982595353892851542e+01,  -6.0228002066743340583e+01, 8.5539563258012929600e+01,
    -3.1446690275135491500e+01, 1.0,
};

/// FFmpeg's `eval_poly`: Horner's rule from the highest coefficient.
fn evalPoly(coeff: []const f64, x: f64) f64 {
    var sum = coeff[coeff.len - 1];
    var i = coeff.len - 1;
    while (i > 0) {
        i -= 1;
        sum *= x;
        sum += coeff[i];
    }
    return sum;
}

/// `av_bessel_i0`: the modified Bessel function of the first kind, order 0.
pub fn besselI0(x_in: f64) f64 {
    if (x_in == 0) return 1;
    const x = @abs(x_in);
    if (x <= 15) {
        const y = x * x;
        return evalPoly(&bessel_p1, y) / evalPoly(&bessel_q1, y);
    }
    const y = 1 / x - 1.0 / 15.0;
    const r = evalPoly(&bessel_p2, y) / evalPoly(&bessel_q2, y);
    return libm.exp(x) / @sqrt(x) * r;
}
