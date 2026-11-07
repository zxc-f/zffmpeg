// SPDX-License-Identifier: LGPL-2.1-or-later
// Translated from FFmpeg at the pinned reference revision:
// libavcodec/lpc.c (Copyright (c) 2006 Justin Ruggles), x86/lpc_init.c
// (lpc_compute_autocorr_sse2's summation order), lpc_functions.h
// (compute_lpc_coefs), lpc.h, and libavutil/lls.c (Copyright (c) 2006 Michael
// Niedermayer) with float_dsp.c's ff_scalarproduct_double_c; LGPL 2.1 or
// later, as LICENSE holds.
//! Linear prediction analysis for the FLAC encoder (TODO.md T26c): the
//! Welch window, autocorrelation, Levinson-Durbin recursion, FFmpeg's
//! Cholesky least squares with its reweighting passes, coefficient
//! quantization and order estimation.
//!
//! Every double operation runs in the order of FFmpeg's x86-64 build: its
//! C code, except the autocorrelation, whose inline SSE2 version the
//! reference's `--disable-x86asm` keeps (libavcodec/x86/lpc_init.c), so
//! the coefficients and shifts are FFmpeg's bit for bit. Zig contracts no
//! multiply-add without `@mulAdd`, as FFmpeg's x86-64 baseline build has
//! none to contract to.

const std = @import("std");
const cconv = @import("../core/cconv.zig");

pub const min_order = 1;
pub const max_order = 32;

/// `enum FFLPCType`.
pub const Type = enum(u2) { none = 0, fixed = 1, levinson = 2, cholesky = 3 };

/// `ORDER_METHOD_*`.
pub const OrderMethod = enum(u3) { estimation = 0, two_level = 1, four_level = 2, eight_level = 3, search = 4, log = 5 };

/// Quantized coefficients for every order: row `order - 1`.
pub const Coefs = [max_order][max_order]i32;

/// `MAX_VARS_ALIGN`: the covariance matrix's row stride.
const vars_align = 36;

/// libavutil's `LLSModel`: the covariance matrix holds the Cholesky factor
/// in place, aliased as FFmpeg's `factor` and `covar` views alias it.
const Lls = struct {
    covariance: [vars_align * vars_align]f64,
    coeff: [max_order][max_order]f64,
    variance: [max_order]f64,
    indep_count: usize,

    /// `avpriv_init_lls`.
    fn init(m: *Lls, indep_count: usize) void {
        @memset(&m.covariance, 0);
        for (&m.coeff) |*row| @memset(row, 0);
        @memset(&m.variance, 0);
        m.indep_count = indep_count;
    }

    fn cov(m: *Lls, row: usize, col: usize) *f64 {
        return &m.covariance[row * vars_align + col];
    }

    /// `factor[i][k]`, which is `covariance[1 + i][k]`.
    fn factor(m: *Lls, i: usize, k: usize) *f64 {
        return m.cov(1 + i, k);
    }

    /// `covar[i][j]`, which is `covariance[1 + i][1 + j]`.
    fn covar(m: *Lls, i: usize, j: usize) *f64 {
        return m.cov(1 + i, 1 + j);
    }

    /// `update_lls`.
    fn update(m: *Lls, v: []const f64) void {
        for (0..m.indep_count + 1) |i| {
            for (i..m.indep_count + 1) |j| m.cov(i, j).* += v[i] * v[j];
        }
    }

    /// `evaluate_lls`: `ff_scalarproduct_double_c` over `order + 1` terms.
    fn evaluate(m: *const Lls, param: []const f64, order: usize) f64 {
        var p: f64 = 0.0;
        for (0..order + 1) |i| p += m.coeff[order][i] * param[i];
        return p;
    }

    /// `avpriv_solve_lls` with a `min_order` of 0.
    fn solve(m: *Lls, threshold: f64) void {
        const count = m.indep_count;
        for (0..count) |i| {
            for (i..count) |j| {
                var sum = m.covar(i, j).*;
                for (0..i) |k| sum -= m.factor(i, k).* * m.factor(j, k).*;
                if (i == j) {
                    if (sum < threshold) sum = 1.0;
                    m.factor(i, i).* = @sqrt(sum);
                } else {
                    m.factor(j, i).* = sum / m.factor(i, i).*;
                }
            }
        }
        for (0..count) |i| {
            var sum = m.cov(0, i + 1).*;
            for (0..i) |k| sum -= m.factor(i, k).* * m.coeff[0][k];
            m.coeff[0][i] = sum / m.factor(i, i).*;
        }
        var j = count;
        while (j > 0) {
            j -= 1;
            var i = j + 1;
            while (i > 0) {
                i -= 1;
                var sum = m.coeff[0][i];
                for (i + 1..j + 1) |k| sum -= m.factor(k, i).* * m.coeff[j][k];
                m.coeff[j][i] = sum / m.factor(i, i).*;
            }
            m.variance[j] = m.cov(0, 0).*;
            for (0..j + 1) |ii| {
                var sum = m.coeff[j][ii] * m.covar(ii, ii).* - 2 * m.cov(0, ii + 1).*;
                for (0..ii) |k| sum += 2 * m.coeff[j][k] * m.covar(k, ii).*;
                m.variance[j] += m.coeff[j][ii] * sum;
            }
        }
    }
};

/// `LPCContext`: the windowed samples and the two least-squares models.
pub const Context = struct {
    /// The windowed block (FFmpeg's padding around it reads as zeros in
    /// `computeAutocorr`).
    windowed: []f64,
    lls: *[2]Lls,

    /// Room for blocks of up to `max_blocksize` samples.
    pub fn init(gpa: std.mem.Allocator, max_blocksize: usize) std.mem.Allocator.Error!Context {
        const windowed = try gpa.alloc(f64, max_blocksize);
        errdefer gpa.free(windowed);
        @memset(windowed, 0);
        const lls = try gpa.create([2]Lls);
        return .{ .windowed = windowed, .lls = lls };
    }

    pub fn deinit(ctx: *Context, gpa: std.mem.Allocator) void {
        gpa.free(ctx.windowed);
        gpa.destroy(ctx.lls);
        ctx.* = undefined;
    }

    /// `ff_lpc_calc_coefs` for the FLAC encoder: coefficients for orders
    /// `min` to `max` (every one, or only the estimated one with
    /// `.estimation`), quantized to `precision` bits with a shift from
    /// `min_shift` to `max_shift`; returns the order to use first.
    pub fn calcCoefs(
        ctx: *Context,
        samples: []const i32,
        min: usize,
        max: usize,
        precision: u5,
        coefs: *Coefs,
        shift: *[max_order]i32,
        lpc_type: Type,
        passes_option: u32,
        omethod: OrderMethod,
        min_shift: i32,
        max_shift: u5,
        zero_shift: i32,
    ) usize {
        std.debug.assert(max >= min_order and max <= max_order and min >= min_order and min <= max);
        std.debug.assert(lpc_type == .levinson or lpc_type == .cholesky);
        // A block no longer than the order (ALAC's last frame, T31b): the
        // autocorrelation reads zeros around it, as FFmpeg's padded buffer.
        std.debug.assert(samples.len <= ctx.windowed.len and samples.len >= 1);
        std.debug.assert(lpc_type == .levinson or samples.len > max);
        const blocksize = samples.len;
        var autoc: [max_order + 1]f64 = undefined;
        var ref: [max_order]f64 = @splat(0);
        var lpc: [max_order][max_order]f64 = undefined;
        var pass: u32 = 0;
        const lpc_passes: u32 = if (passes_option == 0) 2 else passes_option;

        if (lpc_type == .levinson or (lpc_type == .cholesky and lpc_passes > 1)) {
            const data = ctx.windowed[0..blocksize];
            applyWelchWindow(samples, data);
            computeAutocorr(data, max, &autoc);
            computeLpcCoefs(autoc[0 .. max + 1], max, &lpc);
            for (0..max) |i| ref[i] = @abs(lpc[i][i]);
            pass += 1;
        }

        if (lpc_type == .cholesky) {
            const m = ctx.lls;
            var v: [vars_align]f64 = @splat(0);
            var weight: f64 = undefined;
            if (lpc_passes > 1) {
                for (0..max) |j| m[0].coeff[max - 1][j] = -lpc[max - 1][j];
            }
            while (pass < lpc_passes) : (pass += 1) {
                const cur = &m[pass & 1];
                cur.init(max);
                weight = 0;
                for (max..blocksize) |i| {
                    for (0..max + 1) |j| v[j] = @floatFromInt(samples[i - j]);
                    if (pass != 0) {
                        var eval = m[(pass - 1) & 1].evaluate(v[1..], max - 1);
                        // `512 >> pass`: x86 masks the count to 5 bits.
                        const bias: f64 = @floatFromInt(@as(u32, 512) >> @intCast(pass & 31));
                        eval = bias + @abs(eval - v[0]);
                        const inv = 1 / eval;
                        const rinv = @sqrt(inv);
                        for (0..max + 1) |j| v[j] *= rinv;
                        weight += inv;
                    } else {
                        weight += 1;
                    }
                    cur.update(&v);
                }
                cur.solve(0.001);
            }
            const last = &m[(pass - 1) & 1];
            const span: f64 = @floatFromInt(blocksize - max);
            for (0..max) |i| {
                for (0..max) |j| lpc[i][j] = -last.coeff[i][j];
                ref[i] = @sqrt(last.variance[i] / weight) * span / 4000;
            }
            var i = max - 1;
            while (i > 0) : (i -= 1) ref[i] = ref[i - 1] - ref[i];
        }

        var opt_order = max;
        if (omethod == .estimation) {
            opt_order = estimateBestOrder(&ref, min, max);
            const i = opt_order - 1;
            quantizeCoefs(lpc[i][0 .. i + 1], precision, coefs[i][0 .. i + 1], &shift[i], min_shift, max_shift, zero_shift);
        } else {
            for (min - 1..max) |i| {
                quantizeCoefs(lpc[i][0 .. i + 1], precision, coefs[i][0 .. i + 1], &shift[i], min_shift, max_shift, zero_shift);
            }
        }
        return opt_order;
    }
};

/// `lpc_apply_welch_window_c`.
fn applyWelchWindow(data: []const i32, w_data: []f64) void {
    const len = data.len;
    if (len == 1) {
        w_data[0] = 0.0;
        return;
    }
    const n2 = len >> 1;
    const c = 2.0 / (@as(f64, @floatFromInt(len)) - 1.0);
    if (len & 1 != 0) {
        for (0..n2) |i| {
            var w = c - @as(f64, @floatFromInt(i)) - 1.0;
            w = 1.0 - (w * w);
            w_data[i] = @as(f64, @floatFromInt(data[i])) * w;
            w_data[len - 1 - i] = @as(f64, @floatFromInt(data[len - 1 - i])) * w;
        }
        w_data[n2] = 0.0;
        return;
    }
    for (0..n2) |i| {
        var w = c - @as(f64, @floatFromInt(n2)) + @as(f64, @floatFromInt(i));
        w = 1.0 - (w * w);
        w_data[n2 - i - 1] = @as(f64, @floatFromInt(data[n2 - i - 1])) * w;
        w_data[n2 + i] = @as(f64, @floatFromInt(data[n2 + i])) * w;
    }
}

/// `lpc_compute_autocorr_sse2` (libavcodec/x86/lpc_init.c), which
/// FFmpeg's x86 builds use whenever the CPU has SSE2, the reference's
/// `--disable-x86asm` included (it is inline assembly): `autoc[0..lag + 1]`
/// of `data`. Each sum runs in two lanes, the even positions from 1.0 and
/// the odd ones from 0.0, over sample pairs (an odd block's last pair reads
/// the zero after it) and the zeros before the block, and the lanes are
/// added at the end. FFmpeg's C loop, one lane from 1.0, can differ in the
/// last bits, which can change a quantized coefficient.
fn computeAutocorr(data: []const f64, lag: usize, autoc: *[max_order + 1]f64) void {
    const len = data.len;
    // The positions the pairs cover: `len` rounded up to even.
    const span = len + (len & 1);
    const sum = struct {
        fn at(d: []const f64, k: isize) f64 {
            return if (k < 0 or k >= d.len) 0 else d[@intCast(k)];
        }

        fn of(d: []const f64, n: usize, lagged: usize) f64 {
            var lanes = [2]f64{ 1.0, 0.0 };
            var m: usize = 0;
            while (m < n) : (m += 1) {
                const k: isize = @intCast(m);
                lanes[m & 1] += at(d, k) * at(d, k - @as(isize, @intCast(lagged)));
            }
            return lanes[0] + lanes[1];
        }
    };
    var j: usize = 0;
    while (j < lag) : (j += 2) {
        autoc[j] = sum.of(data, span, j);
        autoc[j + 1] = sum.of(data, span, j + 1);
        if (j + 2 == lag) autoc[j + 2] = sum.of(data, span, j + 2);
    }
}

/// `compute_lpc_coefs` (Levinson-Durbin) with normalization, from order 0,
/// without failing: row `i` of `lpc` holds the order `i + 1` predictor.
fn computeLpcCoefs(autoc_all: []const f64, max: usize, lpc: *[max_order][max_order]f64) void {
    var err = autoc_all[0];
    const autoc = autoc_all[1..];
    for (0..max) |i| {
        var r = -autoc[i];
        if (i > 0) {
            const last = &lpc[i - 1];
            for (0..i) |j| r -= last[j] * autoc[i - j - 1];
        }
        if (err != 0) r /= err;
        err *= 1.0 - (r * r);
        lpc[i][i] = r;
        if (i > 0) {
            const last = &lpc[i - 1];
            for (0..(i + 1) >> 1) |j| {
                const f = last[j];
                const b = last[i - 1 - j];
                lpc[i][j] = f + r * b;
                lpc[i][i - 1 - j] = b + r * f;
            }
        }
    }
}

/// `estimate_best_order`.
fn estimateBestOrder(ref: *const [max_order]f64, min: usize, max: usize) usize {
    var i = max;
    while (i >= min) : (i -= 1) {
        if (ref[i - 1] > 0.10) return i;
    }
    return min;
}

/// `quantize_lpc_coefs`: scales `lpc_in` in place when no shift fits.
fn quantizeCoefs(lpc_in: []f64, precision: u5, lpc_out: []i32, shift: *i32, min_shift: i32, max_shift: u5, zero_shift: i32) void {
    const qmax: i32 = (@as(i32, 1) << (precision - 1)) - 1;
    const qmax_f: f64 = @floatFromInt(qmax);
    // FFMAX(cmax, x): NaN propagates from x, as `a > b ? a : b` does.
    var cmax: f64 = 0.0;
    for (lpc_in) |c| {
        const x = @abs(c);
        cmax = if (cmax > x) cmax else x;
    }
    if (cmax * @as(f64, @floatFromInt(@as(u32, 1) << max_shift)) < 1.0) {
        shift.* = zero_shift;
        @memset(lpc_out, 0);
        return;
    }
    var sh: i32 = max_shift;
    while (cmax * @as(f64, @floatFromInt(@as(u32, 1) << @intCast(sh))) > qmax_f and sh > min_shift) sh -= 1;
    if (sh == 0 and cmax > qmax_f) {
        const scale = qmax_f / cmax;
        for (lpc_in) |*c| c.* *= scale;
    }
    const scale_sh: f64 = @floatFromInt(@as(u32, 1) << @intCast(sh));
    var err: f64 = 0;
    for (lpc_in, lpc_out) |c, *out| {
        err -= c * scale_sh;
        // av_clip takes an int: lrintf's long is narrowed to 32 bits first.
        const rounded = cconv.lrintfInt(err);
        out.* = std.math.clamp(rounded, -qmax, qmax);
        err -= @floatFromInt(out.*);
    }
    shift.* = sh;
}

const testing = std.testing;

test "quantization: shifts, scaling and the zero case" {
    var coefs = [_]f64{ 0.5, -0.25 };
    var out: [2]i32 = undefined;
    var shift: i32 = undefined;
    quantizeCoefs(&coefs, 15, &out, &shift, 0, 15, 0);
    // 0.5 << 15 = 16384 fits 15 bits (qmax 16383)? No: one shift less.
    try testing.expectEqual(14, shift);
    try testing.expectEqualSlices(i32, &.{ -8192, 4096 }, &out);
    var tiny = [_]f64{ 1e-6, 0 };
    quantizeCoefs(&tiny, 15, &out, &shift, 0, 15, 0);
    try testing.expectEqual(0, shift);
    try testing.expectEqualSlices(i32, &.{ 0, 0 }, &out);
    // Too large for shift 0: scaled down to qmax.
    var big = [_]f64{ 40000, 20000 };
    quantizeCoefs(&big, 15, &out, &shift, 0, 15, 0);
    try testing.expectEqual(0, shift);
    try testing.expectEqualSlices(i32, &.{ -16383, -8192 }, &out);
}

test "Levinson-Durbin solves a first-order process exactly" {
    // Autocorrelation of x[n] = a x[n-1] + e: r[k] = a^k r[0].
    const a = 0.5;
    const autoc = [_]f64{ 1.0, a, a * a, a * a * a };
    var lpc: [max_order][max_order]f64 = undefined;
    computeLpcCoefs(&autoc, 3, &lpc);
    try testing.expectEqual(-a, lpc[0][0]);
    try testing.expectEqual(-a, lpc[2][0]);
    try testing.expectEqual(0, lpc[2][1]);
    try testing.expectEqual(0, lpc[2][2]);
}
