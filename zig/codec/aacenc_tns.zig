// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aacenc_tns.c, lpc.c
// (ff_lpc_calc_ref_coefs_f, compute_ref_coefs), lpc_functions.h
// (compute_lpc_coefs) and aacenc_utils.h (quant_array_idx) at the pinned
// reference revision.
// Copyright (C) 2015 Rostislav Pehlivanov
// Copyright (c) 2006 Justin Ruggles <justin.ruggles@gmail.com>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's AAC temporal noise shaping encoder (TODO.md T32d): the filter
//! search on the perceptually weighted spectrum, accepted by its measured
//! prediction gain (long blocks: two filters over the band regions; short
//! blocks: one filter pooled per window group), the filter applied to the
//! coefficients, and its bitstream.

const std = @import("std");
const aacenc = @import("aacenc.zig");
const aac_tab = @import("aac_tab.zig");
const lpc = @import("lpc.zig");
const bits = @import("bits.zig");
const libm = @import("../core/libm.zig");

const Encoder = aacenc.Encoder;
const Sce = aacenc.Sce;

/// TNS_MAX_ORDER.
pub const max_order = 20;
/// MAX_LPC_ORDER.
const max_lpc_order = 32;

const tns_predgain_gate: f32 = 1.4;
const tns_pg_c1_long: f32 = 1.4;
const tns_pg_c1_short: f32 = 3.2;
const tns_pg_clamp: f32 = 6.0;
const tns_weight_floor: f32 = 0.01;

/// tns_min_sfb: the first band TNS covers, long and short.
const tns_min_sfb = [2][16]u8{
    .{ 12, 13, 15, 16, 17, 20, 25, 26, 24, 28, 30, 31, 31, 31, 31, 31 },
    .{ 2, 2, 2, 3, 3, 4, 6, 6, 8, 10, 10, 12, 12, 12, 12, 12 },
};

/// The LPC context's windowed buffer (`ff_lpc_init` with a block of 2048
/// and order 20): the samples follow 20 zeroed doubles, which the SSE2
/// autocorrelation reads before the block; it persists across calls.
pub const LpcBuffer = struct {
    buf: [20 + 2048 + 2]f64 = @splat(0),
};

/// ff_lpc_calc_ref_coefs_f: `order` reflection coefficients of `samples`
/// (a Hann window when `apply_window`), returning the prediction gain or
/// NaN.
fn calcRefCoefsF(lb: *LpcBuffer, samples: []const f32, order: usize, ref: *[max_lpc_order]f64, apply_window: bool) f64 {
    const len = samples.len;
    const ws = lb.buf[20..][0..len];
    var autoc: [lpc.max_order + 1]f64 = @splat(0);
    var err: [max_lpc_order + 1]f64 = @splat(0);
    const a: f64 = 0.5;
    const b: f64 = 1.0 - a;
    // FFmpeg's loop runs to len/2 inclusive, so the middle pair is written
    // twice, the second time with i = len/2's weight.
    var i: usize = 0;
    while (i <= len / 2) : (i += 1) {
        const weight: f64 = if (apply_window)
            a - b * libm.cos((2 * std.math.pi * @as(f64, @floatFromInt(i))) / @as(f64, @floatFromInt(@as(i64, @intCast(len)) - 1)))
        else
            1.0;
        ws[i] = weight * samples[i];
        ws[len - 1 - i] = weight * samples[len - 1 - i];
    }
    lpc.computeAutocorr(ws, order, &autoc);
    const signal = autoc[0];
    computeRefCoefs(&autoc, order, ref, &err);
    var avg_err: f64 = 0;
    for (0..order) |k| avg_err = (avg_err + err[k]) / 2.0;
    return if (avg_err != 0) signal / avg_err else std.math.nan(f64);
}

/// compute_ref_coefs (lpc.c, double).
fn computeRefCoefs(autoc: []const f64, max: usize, ref: *[max_lpc_order]f64, err_out: *[max_lpc_order + 1]f64) void {
    var gen0: [max_lpc_order]f64 = undefined;
    var gen1: [max_lpc_order]f64 = undefined;
    for (0..max) |i| {
        gen0[i] = autoc[i + 1];
        gen1[i] = autoc[i + 1];
    }
    var err = autoc[0];
    ref[0] = -gen1[0] / (if (err != 0) err else 1);
    err += gen1[0] * ref[0];
    err_out[0] = err;
    for (1..max) |i| {
        for (0..max - i) |j| {
            gen1[j] = gen1[j + 1] + ref[i - 1] * gen0[j];
            gen0[j] = gen1[j + 1] * ref[i - 1] + gen0[j];
        }
        ref[i] = -gen1[0] / (if (err != 0) err else 1);
        err += gen1[0] * ref[i];
        err_out[i] = err;
    }
}

/// compute_lpc_coefs in float, without normalization and in place
/// (`lpc_stride` 0): the direct-form filter of reflection coefficients.
fn computeLpcCoefs(refl: []const f32, order: usize, out: *[max_order]f32) void {
    for (0..order) |i| {
        const r = -refl[i];
        out[i] = r;
        for (0..(i + 1) >> 1) |j| {
            const f = out[j];
            const b = out[i - 1 - j];
            out[j] = f + r * b;
            out[i - 1 - j] = b + r * f;
        }
    }
}

/// quant_array_idx: the nearest entry (the first of equals).
fn quantArrayIdx(val: f32, arr: []const f32) usize {
    var index: usize = 0;
    var min_err = std.math.inf(f32);
    for (arr, 0..) |v, i| {
        const e = (val - v) * (val - v);
        if (e < min_err) {
            min_err = e;
            index = i;
        }
    }
    return index;
}

/// quantize_coefs with 4-bit coefficients (`c_bits` 1).
fn quantizeCoefs(coef: []const f64, idx: []i32, out: []f32) void {
    const quant_arr = aac_tab.tns_tmp2_map[1];
    for (coef, idx, out) |c, *i, *o| {
        const k = quantArrayIdx(@floatCast(c), quant_arr);
        i.* = @intCast(k);
        o.* = quant_arr[k];
    }
}

/// tns_max_nonpns: the band range capped at the first PNS band.
fn maxNonPns(sce: *const Sce, mmm_in: usize) usize {
    var mmm = mmm_in;
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..mmm) |g| {
            if (sce.band_type[w * 16 + g] == aacenc.BandType.noise) {
                mmm = g;
                break;
            }
        }
    }
    return mmm;
}

fn fmax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn fmin(a: f32, b: f32) f32 {
    return if (a > b) b else a;
}

/// compress_coeffs: 3-bit coefficients when every index fits.
fn compressCoeffs(coef: []i32) bool {
    const low_idx = 4;
    const shift_val = 8;
    const high_idx = 11;
    for (coef) |c| {
        if (c >= low_idx and c <= high_idx) return false;
    }
    for (coef) |*c| {
        if (c.* > high_idx) c.* -= shift_val;
    }
    return true;
}

/// ff_aac_encode_tns_info.
pub fn encodeTnsInfo(pb: *bits.BitWriter, sce: *Sce) void {
    const tns = &sce.tns;
    const is8 = sce.ics.window_sequence[0] == .eight_short;
    const c_bits: u1 = 1;
    if (!tns.present) return;
    const i8b: u6 = @intFromBool(is8);
    for (0..sce.ics.num_windows) |i| {
        pb.bits(2 - i8b, @intCast(tns.n_filt[i]));
        if (tns.n_filt[i] == 0) continue;
        pb.bits(1, c_bits);
        for (0..@intCast(tns.n_filt[i])) |filt| {
            pb.bits(6 - 2 * i8b, @intCast(tns.length[i][filt]));
            pb.bits(5 - 2 * i8b, @intCast(tns.order[i][filt]));
            if (tns.order[i][filt] == 0) continue;
            pb.bits(1, @intCast(tns.direction[i][filt]));
            const order: usize = @intCast(tns.order[i][filt]);
            const coef_compress = compressCoeffs(tns.coef_idx[i][filt][0..order]);
            pb.bits(1, @intFromBool(coef_compress));
            const coef_len: u6 = @as(u6, c_bits) + 3 - @intFromBool(coef_compress);
            for (0..order) |w| pb.signed(coef_len, tns.coef_idx[i][filt][w]);
        }
    }
}

/// ff_aac_apply_tns: the filters on the coefficients, predicting from
/// the coefficients as they were (after M/S and I/S).
pub fn applyTns(sce: *Sce) void {
    const tns = &sce.tns;
    const ics = &sce.ics;
    const mmm = maxNonPns(sce, @min(ics.tns_max_bands, ics.max_sfb));
    var lpc_q: [max_order]f32 = undefined;
    const hist = sce.coeffs;
    for (0..ics.num_windows) |w| {
        var bottom: i32 = ics.num_swb;
        for (0..@intCast(tns.n_filt[w])) |filt| {
            const top = bottom;
            bottom = @max(0, top - tns.length[w][filt]);
            const order: usize = @intCast(tns.order[w][filt]);
            if (order == 0) continue;
            computeLpcCoefs(tns.coef[w][filt][0..order], order, &lpc_q);
            const b0: usize = @min(@as(usize, @intCast(bottom)), mmm);
            const e0: usize = @min(@as(usize, @intCast(top)), mmm);
            var start: i32 = ics.swb_offset[b0];
            const end: i32 = ics.swb_offset[e0];
            const size = end - start;
            if (size <= 0) continue;
            var inc: i32 = 1;
            if (tns.direction[w][filt] != 0) {
                inc = -1;
                start = end - 1;
            }
            start += @intCast(w * 128);
            // The AR filter.
            var m: i32 = 0;
            while (m < size) : ({
                m += 1;
                start += inc;
            }) {
                var i: i32 = 1;
                while (i <= @min(m, @as(i32, @intCast(order)))) : (i += 1) {
                    const s: usize = @intCast(start);
                    sce.coeffs[s] += lpc_q[@intCast(i - 1)] * hist[@intCast(start - i * inc)];
                }
            }
        }
    }
}

/// The weighted spectrum of bands `g_lo..g_hi` of window `w` into `out`
/// (X / sqrt(threshold per line), floored at 1% of the region's largest).
fn weightedSpectrum(sce: *const Sce, bands: *const [128]aacenc.PsyBand, w: usize, g_lo: usize, g_hi: usize, c_lo: usize, out: []f32) void {
    var maxrms: f32 = 0;
    for (g_lo..g_hi) |g| {
        const s0: i32 = sce.ics.swb_offset[g];
        const s1: i32 = sce.ics.swb_offset[g + 1];
        const rms = @sqrt(fmax(bands[w * 16 + g].threshold, 0) / @as(f32, @floatFromInt(@max(s1 - s0, 1))));
        maxrms = fmax(maxrms, rms);
    }
    const floorrms = fmax(maxrms * tns_weight_floor, 1e-9);
    for (g_lo..g_hi) |g| {
        const s0: usize = sce.ics.swb_offset[g];
        const s1: usize = sce.ics.swb_offset[g + 1];
        const rms = @sqrt(fmax(bands[w * 16 + g].threshold, 0) / @as(f32, @floatFromInt(@max(@as(i32, @intCast(s1)) - @as(i32, @intCast(s0)), 1))));
        const wgt = 1.0 / fmax(rms, floorrms);
        for (s0..s1) |k| out[k - c_lo] = sce.coeffs[w * 128 + k] * wgt;
    }
}

/// search_for_tns_short_pooled: one filter per window group of a short
/// frame, fitted on the group's weighted spectra end to end.
fn searchShortPooled(e: *Encoder, sce: *Sce) void {
    const tns = &sce.tns;
    const lim: usize = if (sce.ics.max_sfb != 0) sce.ics.max_sfb else sce.ics.num_swb;
    const mmm = maxNonPns(sce, @min(sce.ics.tns_max_bands, lim));
    const sfb_start: usize = @min(tns_min_sfb[1][e.samplerate_index], mmm);
    const sfb_end: usize = @min(@as(usize, sce.ics.num_swb), mmm);
    var count: usize = 0;
    const bands = e.psyBands(e.cur_channel);
    tns.* = .{};
    if (sfb_end <= sfb_start) return;
    const c_lo: usize = sce.ics.swb_offset[sfb_start];
    const c_hi: usize = sce.ics.swb_offset[sfb_end];
    const clen = c_hi - c_lo;
    const ord_g = 7;
    if (clen <= 2 * ord_g) return;
    var wh: usize = 0;
    while (wh < sce.ics.num_windows) : (wh += sce.ics.group_len[wh]) {
        const gl: usize = sce.ics.group_len[wh];
        var coefs: [max_lpc_order]f64 = undefined;
        var pooled: [1024]f32 = undefined;
        var lpc_q: [max_order]f32 = undefined;
        var ok = true;
        for (0..gl) |w2| weightedSpectrum(sce, bands, wh + w2, sfb_start, sfb_end, c_lo, pooled[w2 * clen ..]);
        const gain = calcRefCoefsF(&e.lpc_buffer, pooled[0 .. clen * gl], ord_g, &coefs, false);
        if (!std.math.isFinite(gain) or gain < tns_predgain_gate or gain > tns_pg_clamp) continue;
        for (coefs[0..ord_g]) |*c| c.* = -c.*;
        quantizeCoefs(coefs[0..ord_g], tns.coef_idx[wh][0][0..ord_g], tns.coef[wh][0][0..ord_g]);
        computeLpcCoefs(tns.coef[wh][0][0..ord_g], ord_g, &lpc_q);
        // Every window must clear the measured bar after quantization.
        var gmin = std.math.floatMax(f32);
        for (0..gl) |w2| {
            const msrc = pooled[w2 * clen ..][0..clen];
            var orig_e: f32 = 0;
            var filt_e: f32 = 0;
            for (0..clen) |m| {
                var acc = msrc[m];
                for (1..@as(usize, @min(m, ord_g)) + 1) |i| acc += lpc_q[i - 1] * msrc[m - i];
                orig_e += msrc[m] * msrc[m];
                filt_e += acc * acc;
            }
            gmin = fmin(gmin, orig_e / fmax(filt_e, 1e-9));
        }
        // Without the NMR coder's short-run state the bar is the base one.
        if (gmin < tns_pg_c1_short) ok = false;
        if (ok) {
            for (0..gl) |w2| {
                const w = wh + w2;
                tns.n_filt[w] = 1;
                tns.length[w][0] = @intCast(sfb_end - sfb_start);
                tns.order[w][0] = ord_g;
                tns.direction[w][0] = 0;
                if (w2 != 0) {
                    tns.coef_idx[w][0] = tns.coef_idx[wh][0];
                    tns.coef[w][0] = tns.coef[wh][0];
                }
                count += 1;
            }
        }
    }
    tns.present = count != 0;
}

/// ff_aac_search_for_tns.
pub fn searchForTns(e: *Encoder, sce: *Sce) void {
    const tns = &sce.tns;
    var count: usize = 0;
    const mmm = maxNonPns(sce, @min(sce.ics.tns_max_bands, sce.ics.max_sfb));
    const is8 = sce.ics.window_sequence[0] == .eight_short;
    const sfb_start: usize = @min(tns_min_sfb[@intFromBool(is8)][e.samplerate_index], mmm);
    const sfb_end: usize = @min(@as(usize, sce.ics.num_swb), mmm);
    const order: usize = if (is8) 7 else 12;
    const slant: u8 = switch (sce.ics.window_sequence[0]) {
        .long_stop => 1,
        .long_start => 0,
        else => 2,
    };
    const sfb_len: i32 = @as(i32, @intCast(sfb_end)) - @as(i32, @intCast(sfb_start));
    const coef_len: i32 = @as(i32, sce.ics.swb_offset[sfb_end]) - sce.ics.swb_offset[sfb_start];
    const n_filt: usize = if (is8) 1 else if (order != max_order) 2 else 3;
    const ord_g = order / n_filt;
    const c1 = if (is8) tns_pg_c1_short else tns_pg_c1_long;
    const bands = e.psyBands(e.cur_channel);
    if (coef_len <= 0 or sfb_len <= 0) {
        tns.present = false;
        return;
    }
    if (is8) {
        searchShortPooled(e, sce);
        return;
    }
    // A long block's MDCT is fed 2048 windowed samples.
    const tlen = 2048;
    for (0..sce.ics.num_windows) |w| {
        var any = false;
        // The filter runs in the direction of the temporal energy, so the
        // noise stays in the loud part.
        const tw = sce.ret_buf[w * tlen ..][0..tlen];
        var e_early: f32 = 0;
        var e_late: f32 = 0;
        for (tw[0 .. tlen / 2]) |x| e_early += x * x;
        for (tw[tlen / 2 ..]) |x| e_late += x * x;
        const tdir: u8 = @intFromBool(e_early > e_late);
        // The regions as the decoder walks them: filter 0 at the top.
        var top_sfb: i32 = sce.ics.num_swb;
        for (0..n_filt) |filt| {
            var coefs: [max_lpc_order]f64 = undefined;
            var wspec: [1024]f32 = undefined;
            var tmp: [1024]f32 = undefined;
            var lpc_q: [max_order]f32 = undefined;
            const nf: i32 = @intCast(n_filt);
            const len_sfb: i32 = if (filt == n_filt - 1) sfb_len - @as(i32, @intCast(filt)) * @divTrunc(sfb_len, nf) else @divTrunc(sfb_len, nf);
            const bot_sfb = @max(0, top_sfb - len_sfb);
            const g_lo: usize = @min(@as(usize, @intCast(bot_sfb)), mmm);
            const g_hi: usize = @min(@as(usize, @intCast(top_sfb)), mmm);
            const c_lo: usize = sce.ics.swb_offset[g_lo];
            const c_hi: usize = sce.ics.swb_offset[g_hi];
            const clen = c_hi -| c_lo;
            const dir = if (slant != 2) slant else tdir;
            tns.length[w][filt] = len_sfb;
            tns.order[w][filt] = 0;
            top_sfb = bot_sfb;
            if (c_hi < c_lo or clen <= 2 * ord_g) continue;
            weightedSpectrum(sce, bands, w, g_lo, g_hi, c_lo, &wspec);
            // Long blocks keep the window; short ones fit unwindowed.
            const gain = calcRefCoefsF(&e.lpc_buffer, wspec[0..clen], ord_g, &coefs, !is8);
            // The first gate and the clamp (poles near the unit circle).
            if (!std.math.isFinite(gain) or gain < tns_predgain_gate or gain > tns_pg_clamp) continue;
            // The sign apply_tns's filter needs.
            for (coefs[0..ord_g]) |*c| c.* = -c.*;
            quantizeCoefs(coefs[0..ord_g], tns.coef_idx[w][filt][0..ord_g], tns.coef[w][filt][0..ord_g]);
            computeLpcCoefs(tns.coef[w][filt][0..ord_g], ord_g, &lpc_q);
            // The quantized filter on the weighted spectrum, and its gain.
            const msrc = wspec[0..clen];
            const inc: i32 = if (dir != 0) -1 else 1;
            const st: i32 = if (dir != 0) @as(i32, @intCast(clen)) - 1 else 0;
            for (0..clen) |mu| {
                const m: i32 = @intCast(mu);
                const idx = st + m * inc;
                var acc = msrc[@intCast(idx)];
                var i: i32 = 1;
                while (i <= @min(m, @as(i32, @intCast(ord_g)))) : (i += 1) acc += lpc_q[@intCast(i - 1)] * msrc[@intCast(idx - i * inc)];
                tmp[@intCast(idx)] = acc;
            }
            var orig_e: f32 = 0;
            var filt_e: f32 = 0;
            for (0..clen) |m| {
                orig_e += msrc[m] * msrc[m];
                filt_e += tmp[m] * tmp[m];
            }
            filt_e = fmax(filt_e, 1e-9);
            // Kept only past the measured bar.
            if (orig_e < c1 * filt_e) continue;
            tns.order[w][filt] = @intCast(ord_g);
            tns.direction[w][filt] = dir;
            any = true;
        }
        tns.n_filt[w] = if (any) @intCast(n_filt) else 0;
        if (any) count += 1;
    }
    tns.present = count != 0;
}
