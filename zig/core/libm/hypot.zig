// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from the GNU C Library 2.44's sysdeps/ieee754/dbl-64/e_hypot.c
// (copyright (C) 2021-2026 Free Software Foundation, Inc.), as built for
// baseline x86-64, without FMA. The GNU C Library is free software; you can
// redistribute it and/or modify it under the terms of the GNU Lesser
// General Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any later version.
//! glibc's double `hypot` (core/libm.zig): sqrt(ax^2 + ay^2) corrected by
//! one Newton-like step, with scaling for huge and tiny inputs. glibc has
//! no FMA variant of it on x86-64.

const std = @import("std");

const scale = 0x1p-600;
const large_val = 0x1p+511;
const tiny_val = 0x1p-459;
const eps = 0x1p-54;

/// The kernel for ax >= ay >= 0 whose squares neither overflow nor
/// underflow.
fn kernel(ax: f64, ay: f64) f64 {
    var h = @sqrt(ax * ax + ay * ay);
    var t1: f64 = undefined;
    var t2: f64 = undefined;
    if (h <= 2.0 * ay) {
        const delta = h - ay;
        t1 = ax * (2.0 * delta - ax);
        t2 = (delta - 2.0 * (ax - ay)) * delta;
    } else {
        const delta = h - ax;
        t1 = 2.0 * delta * (ax - 2.0 * ay);
        t2 = (4.0 * delta - ay) * ay + delta * delta;
    }
    h -= (t1 + t2) / (2.0 * h);
    return h;
}

/// glibc's hypot.
pub fn hypot(x_in: f64, y_in: f64) f64 {
    if (!std.math.isFinite(x_in) or !std.math.isFinite(y_in)) {
        if ((std.math.isInf(x_in) or std.math.isInf(y_in)) and !std.math.isSignalNan(x_in) and !std.math.isSignalNan(y_in))
            return std.math.inf(f64);
        return x_in + y_in;
    }
    const x = @abs(x_in);
    const y = @abs(y_in);
    var ax = if (x < y) y else x;
    const ay = if (x < y) x else y;
    // Huge ax: scale both down.
    if (ax > large_val) {
        if (ay <= ax * eps) return ax + ay;
        return kernel(ax * scale, ay * scale) / scale;
    }
    // Tiny ay: scale both up.
    if (ay < tiny_val) {
        if (ax >= ay / eps) return ax + ay;
        ax = kernel(ax / scale, ay / scale) * scale;
        return ax;
    }
    if (ay <= ax * eps) return ax + ay;
    return kernel(ax, ay);
}
