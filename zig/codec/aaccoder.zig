// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aaccoder.c, aaccoder_twoloop.h,
// aaccoder_trellis.h, aacenc_utils.h, aacenc_quantization.h,
// aacenc_quantization_misc.h, aacenc_is.c and aacencdsp.c at the pinned
// reference revision.
// Copyright (C) 2008-2009 Konstantin Shishkov
// Copyright (C) 2015 Claudio Freire
// Copyright (C) 2015 Rostislav Pehlivanov
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's AAC coefficient coders (TODO.md T32d): the quantization cost of
//! a band in each codebook (with its memo), the codebook trellis that
//! codes the section data, the `twoloop` and `fast` scalefactor searches,
//! perceptual noise substitution (marking and search), mid/side and
//! intensity stereo searches, and the scalefactors of PNS and I/S bands.
//! FFmpeg's `nmr` coder, which shares these helpers, is aaccoder_nmr.zig.

const std = @import("std");
const aacenc = @import("aacenc.zig");
const aac_tab = @import("aac_tab.zig");
const enc_tab = @import("aacenc_tab.zig");
const bits = @import("bits.zig");
const libm = @import("../core/libm.zig");
const cconv = @import("../core/cconv.zig");

const Encoder = aacenc.Encoder;
const Sce = aacenc.Sce;
const Cpe = aacenc.Cpe;
const bt = aacenc.BandType;

pub const round_standard: f32 = 0.4054;
pub const round_to_zero: f32 = 0.1054;
const c_quant: f32 = 0.4054;

const scale_one_pos = aacenc.scale_one_pos;
const scale_div_512 = aacenc.scale_div_512;
const scale_max_pos = aacenc.scale_max_pos;
const scale_max_diff = aacenc.scale_max_diff;
const scale_diff_zero = aacenc.scale_diff_zero;
const pow_sf2_zero = aacenc.pow_sf2_zero;

/// NOISE_SPREAD_THRESHOLD and NOISE_LAMBDA_REPLACE.
const noise_spread_threshold: f32 = 0.9;
const noise_lambda_replace: f32 = 1.948;
/// NOISE_LOW_LIMIT: the lowest frequency PNS takes, in Hz.
pub const noise_low_limit = 4000;
/// INT_STEREO_LOW_LIMIT.
const int_stereo_low_limit = 6100;

const aac_cb_out_map = [15]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15 };
const aac_cb_in_map = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 12, 13, 14 };
const aac_cb_range = [12]u8{ 0, 3, 3, 3, 3, 9, 9, 8, 8, 13, 13, 17 };
const aac_cb_maxval = [12]u8{ 0, 1, 1, 2, 2, 4, 4, 7, 7, 12, 12, 16 };
const aac_maxval_cb = [14]u8{ 0, 1, 3, 5, 5, 7, 7, 7, 9, 9, 9, 9, 9, 11 };
const run_value_bits_long = [64]u8{
    5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,
    5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 15,
};
const run_value_bits_short = [16]u8{ 3, 3, 3, 3, 3, 3, 3, 6, 6, 6, 6, 6, 6, 6, 6, 9 };
/// CB_TOT_ALL.
const cb_tot_all = 15;

fn f32Bits(b: u32) f32 {
    return @bitCast(b);
}

pub fn pow2sf(i: i32) f32 {
    return aac_tab.pow2sf_tab[@intCast(i)];
}

fn pow34sf(i: i32) f32 {
    return f32Bits(enc_tab.pow34sf_tab[@intCast(i)]);
}

/// FFMIN and FFMAX on floats, as the C macros evaluate them.
fn fmin(a: f32, b: f32) f32 {
    return if (a > b) b else a;
}
fn fmax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
/// av_clipf (its C version): FFMIN(FFMAX(a, amin), amax).
pub fn clipf(a: f32, amin: f32, amax: f32) f32 {
    return fmin(fmax(a, amin), amax);
}

/// abs_pow34_v.
pub fn absPow34(out: []f32, in: []const f32) void {
    for (out, in) |*o, x| {
        const a = @abs(x);
        o.* = @sqrt(a * @sqrt(a));
    }
}

/// pos_pow34.
fn posPow34(a: f32) f32 {
    return @sqrt(a * @sqrt(a));
}

/// quant: `(int)(sqrtf(a * sqrtf(a)) + rounding)`, the conversion as the
/// reference build's `cvttss2si` makes it.
fn quant(coef: f32, q: f32, rounding: f32) i32 {
    const a = coef * q;
    return cconv.cvttsd2si32(@sqrt(a * @sqrt(a)) + rounding);
}

/// av_log2 of a non-negative int.
fn log2i(v: i32) i32 {
    const u: u32 = @bitCast(v | 1);
    return 31 - @as(i32, @clz(u));
}

/// av_clip_uintp2(a, 13).
fn clipUintp2_13(a: i32) i32 {
    if (a & ~@as(i32, (1 << 13) - 1) != 0) return (~a >> 31) & ((1 << 13) - 1);
    return a;
}

/// find_max_val.
pub fn findMaxVal(group_len: usize, swb_size: usize, scaled: []const f32) f32 {
    var maxval: f32 = 0;
    for (0..group_len) |w2| {
        for (0..swb_size) |i| maxval = fmax(maxval, scaled[w2 * 128 + i]);
    }
    return maxval;
}

/// find_min_book.
pub fn findMinBook(maxval: f32, sf: i32) u8 {
    const q34 = pow34sf(pow_sf2_zero - sf + scale_one_pos - scale_div_512);
    const qmaxval = cconv.cvttsd2si32(maxval * q34 + c_quant);
    if (qmaxval < 0 or qmaxval >= aac_maxval_cb.len) {
        // A negative index is the C's out-of-bounds read; no input reaches it
        // (maxval >= 0).
        return 11;
    }
    return aac_maxval_cb[@intCast(qmaxval)];
}

/// find_form_factor.
fn findFormFactor(group_len: usize, swb_size: usize, thresh: f32, scaled: []const f32, nzslope: f32) f32 {
    const iswb_size = 1.0 / @as(f32, @floatFromInt(swb_size));
    const iswb_sizem1 = 1.0 / @as(f32, @floatFromInt(@as(i32, @intCast(swb_size)) - 1));
    const ethresh = thresh;
    var form: f32 = 0;
    var weight: f32 = 0;
    for (0..group_len) |w2| {
        var e: f32 = 0;
        var e2: f32 = 0;
        var variance: f32 = 0;
        var maxval: f32 = 0;
        var nzl: f32 = 0;
        for (0..swb_size) |i| {
            var s = @abs(scaled[w2 * 128 + i]);
            maxval = fmax(maxval, s);
            e += s;
            s *= s;
            e2 += s;
            // A steep but smooth fall towards zero below the threshold.
            if (s >= ethresh) {
                nzl += 1.0;
            } else if (nzslope == 2.0) {
                nzl += (s / ethresh) * (s / ethresh);
            } else {
                // ff_fast_powf: expf(logf(x) * y).
                nzl += libm.expf(libm.logf(s / ethresh) * nzslope);
            }
        }
        if (e2 > thresh) {
            e *= iswb_size;
            for (0..swb_size) |i| {
                const d = @abs(scaled[w2 * 128 + i]) - e;
                variance += d * d;
            }
            variance = @sqrt(variance * iswb_sizem1);
            e2 *= iswb_size;
            const frm = e / fmin(e + 4 * variance, maxval);
            form += e2 * @sqrt(frm) / fmax(0.5, nzl);
            weight += e2;
        }
    }
    return if (weight > 0) form / weight else 1.0;
}

/// coef2minsf: av_clip_uint8(log2f(coef) * 4 - 69 + SCALE_ONE_POS - SCALE_DIV_512).
pub fn coef2minsf(coef: f32) u8 {
    const v = libm.log2f(coef) * 4 - 69 + scale_one_pos - scale_div_512;
    const i = cconv.cvttsd2si32(v);
    return @intCast(std.math.clamp(i, 0, 255));
}

/// bval2bmax.
fn bval2bmax(b: f32) f32 {
    return 0.001 + 0.0035 * (b * b * b) / (15.5 * 15.5 * 15.5);
}

/// ff_init_nextband_map.
pub fn initNextbandMap(sce: *const Sce, nextband: *[128]u8) void {
    var prevband: u8 = 0;
    for (nextband, 0..) |*n, g| n.* = @intCast(g);
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            if (sce.zeroes[w * 16 + g] == 0 and sce.band_type[w * 16 + g] < bt.reserved) {
                nextband[prevband] = @intCast(w * 16 + g);
                prevband = @intCast(w * 16 + g);
            }
        }
    }
    nextband[prevband] = prevband;
}

/// ff_sfdelta_can_remove_band.
pub fn sfdeltaCanRemoveBand(sce: *const Sce, nextband: *const [128]u8, prev_sf: i32, band: usize) bool {
    const next = sce.sf_idx[nextband[band]];
    return prev_sf >= 0 and next >= prev_sf - scale_max_diff and next <= prev_sf + scale_max_diff;
}

/// ff_sfdelta_can_replace.
fn sfdeltaCanReplace(sce: *const Sce, nextband: *const [128]u8, prev_sf: i32, new_sf: i32, band: usize) bool {
    const next = sce.sf_idx[nextband[band]];
    return new_sf >= prev_sf - scale_max_diff and new_sf <= prev_sf + scale_max_diff and
        next >= new_sf - scale_max_diff and next <= new_sf + scale_max_diff;
}

/// lcg_random.
fn lcgRandom(previous: i32) i32 {
    const u: u32 = @bitCast(previous);
    return @bitCast(u *% 1664525 +% 1013904223);
}

const CostKind = enum { zero, squad, uquad, spair, upair, esc, none, noise, stereo };

fn costKind(cb: u8) CostKind {
    return switch (cb) {
        0 => .zero,
        1, 2 => .squad,
        3, 4 => .uquad,
        5, 6 => .spair,
        7, 8, 9, 10 => .upair,
        11 => .esc,
        12 => .none,
        13 => .noise,
        else => .stereo,
    };
}

/// quantize_and_encode_band_cost: the rate-distortion cost of `in` in
/// codebook `cb` at scalefactor `scale_idx`, writing the band to `pb` and
/// its dequantized values to `out` when given; `uplim` cuts the cost
/// short (`bits` and `energy` are then left as they were, as the C leaves
/// them).
pub fn quantizeAndEncodeBandCost(
    e: *Encoder,
    pb: ?*bits.BitWriter,
    in: []const f32,
    out: ?[]f32,
    scaled_in: ?[]const f32,
    size: usize,
    scale_idx: i32,
    cb_in: u8,
    lambda: f32,
    uplim: f32,
    bits_out: ?*i32,
    energy_out: ?*f32,
    rtz: bool,
) f32 {
    const kind = costKind(cb_in);
    const rounding: f32 = if (kind == .esc and rtz) round_to_zero else round_standard;
    var cost: f32 = 0;
    var qenergy: f32 = 0;
    switch (kind) {
        .zero, .noise, .stereo => {
            for (in[0..size]) |x| cost += x * x;
            if (bits_out) |b| b.* = 0;
            if (energy_out) |en| en.* = qenergy;
            if (out) |o| @memset(o[0..size], 0);
            return cost * lambda;
        },
        // CB 12 does not exist (av_assert0).
        .none => unreachable,
        else => {},
    }
    const unsigned = kind == .uquad or kind == .upair or kind == .esc;
    const pair = kind == .spair or kind == .upair or kind == .esc;
    const esc = kind == .esc;
    const cb: u8 = if (esc) bt.esc else cb_in;
    const q_idx = pow_sf2_zero - scale_idx + scale_one_pos - scale_div_512;
    const q = pow2sf(q_idx);
    const q34 = pow34sf(q_idx);
    const iq = pow2sf(pow_sf2_zero + scale_idx - scale_one_pos + scale_div_512);
    const clipped_escape = 165140.0 * iq;
    const dim: usize = if (pair) 2 else 4;
    var resbits: i32 = 0;

    const scaled = scaled_in orelse blk: {
        absPow34(e.scoefs[0..size], in[0..size]);
        break :blk e.scoefs[0..size];
    };
    // quantize_bands.
    const maxval = aac_cb_maxval[cb];
    for (0..size) |i| {
        const qc = scaled[i] * q34;
        var tmp = cconv.cvttsd2si32(fmin(qc + rounding, @floatFromInt(maxval)));
        if (!unsigned and in[i] < 0) tmp = -%tmp;
        e.qcoefs[i] = tmp;
    }
    const off: i32 = if (unsigned) 0 else maxval;
    const vectors = enc_tab.codebook_vectors[cb - 1];
    var i: usize = 0;
    while (i < size) : (i += dim) {
        var curidx: i32 = 0;
        for (0..dim) |j| {
            curidx *%= aac_cb_range[cb];
            curidx +%= e.qcoefs[i + j] + off;
        }
        const idx: usize = @intCast(curidx);
        var curbits: i32 = aac_tab.spectral_bits[cb - 1][idx];
        const vec = vectors[idx * dim ..][0..dim];
        var rd: f32 = 0;
        if (unsigned) {
            for (0..dim) |j| {
                const t = @abs(in[i + j]);
                var quantized: f32 = undefined;
                const v = f32Bits(vec[j]);
                if (esc and v == 64.0) {
                    if (t >= clipped_escape) {
                        quantized = clipped_escape;
                        curbits += 21;
                    } else {
                        const c = clipUintp2_13(quant(t, q, rounding));
                        quantized = e.esc_pow43[@intCast(c)] * iq;
                        curbits += log2i(c) * 2 - 4 + 1;
                    }
                } else {
                    quantized = v * iq;
                }
                const di = t - quantized;
                if (out) |o| o[i + j] = if (in[i + j] >= 0) quantized else -quantized;
                if (v != 0) curbits += 1;
                qenergy += quantized * quantized;
                rd += di * di;
            }
        } else {
            for (0..dim) |j| {
                const quantized = f32Bits(vec[j]) * iq;
                qenergy += quantized * quantized;
                if (out) |o| o[i + j] = quantized;
                rd += (in[i + j] - quantized) * (in[i + j] - quantized);
            }
        }
        cost += rd * lambda + @as(f32, @floatFromInt(curbits));
        resbits += curbits;
        if (cost >= uplim) return uplim;
        if (pb) |w| {
            w.bits(@intCast(aac_tab.spectral_bits[cb - 1][idx]), aac_tab.spectral_codes[cb - 1][idx]);
            if (unsigned) {
                for (0..dim) |j| {
                    if (f32Bits(vec[j]) != 0) w.bits(1, @intFromBool(in[i + j] < 0));
                }
            }
            if (esc) {
                for (0..2) |j| {
                    if (f32Bits(vec[j]) == 64.0) {
                        const coef = std.math.clamp(quant(@abs(in[i + j]), q, rounding), 16, (1 << 13) - 1);
                        const len: u6 = @intCast(log2i(coef));
                        w.bits(len - 4 + 1, (@as(u64, 1) << (len - 4 + 1)) - 2);
                        w.signed(len, coef);
                    }
                }
            }
        }
    }
    if (bits_out) |b| b.* = resbits;
    if (energy_out) |en| en.* = qenergy;
    return cost;
}

/// quantize_band_cost.
pub fn quantizeBandCost(e: *Encoder, in: []const f32, scaled: ?[]const f32, size: usize, scale_idx: i32, cb: u8, lambda: f32, uplim: f32, bits_out: ?*i32, energy: ?*f32) f32 {
    return quantizeAndEncodeBandCost(e, null, in, null, scaled, size, scale_idx, cb, lambda, uplim, bits_out, energy, false);
}

/// quantize_band_cost_bits.
fn quantizeBandCostBits(e: *Encoder, in: []const f32, scaled: ?[]const f32, size: usize, scale_idx: i32, cb: u8) i32 {
    var auxbits: i32 = 0;
    _ = quantizeAndEncodeBandCost(e, null, in, null, scaled, size, scale_idx, cb, 0, std.math.inf(f32), &auxbits, null, false);
    return auxbits;
}

/// quantize_band_cost_cached: the cost memoized by scalefactor, window
/// and band for the cache's generation.
pub fn quantizeBandCostCached(e: *Encoder, w: usize, g: usize, in: []const f32, scaled: []const f32, size: usize, scale_idx: i32, cb: u8, lambda: f32, uplim: f32, bits_out: ?*i32, energy: ?*f32, rtz: bool) f32 {
    const entry = &e.cost_cache[@intCast(scale_idx)][w * 16 + g];
    if (entry.generation != e.cost_cache_generation or entry.cb != cb or entry.rtz != rtz) {
        entry.rd = quantizeBandCost(e, in, scaled, size, scale_idx, cb, lambda, uplim, &entry.bits, &entry.energy);
        entry.cb = cb;
        entry.rtz = rtz;
        entry.generation = e.cost_cache_generation;
    }
    if (bits_out) |b| b.* = entry.bits;
    if (energy) |en| en.* = entry.energy;
    return entry.rd;
}

/// quantize_and_encode_band.
pub fn quantizeAndEncodeBand(e: *Encoder, pb: *bits.BitWriter, in: []const f32, out: ?[]f32, size: usize, scale_idx: i32, cb: u8, lambda: f32, rtz: bool) void {
    _ = quantizeAndEncodeBandCost(e, pb, in, out, null, size, scale_idx, cb, lambda, std.math.inf(f32), null, null, rtz);
}

const TrellisPath = struct { prev_idx: i32, cost: f32, run: i32 };

/// codebook_trellis_rate: the cheapest sections of codebooks for a window
/// group's bands, written as section data.
pub fn codebookTrellisRate(e: *Encoder, pb: *bits.BitWriter, sce: *Sce, win: usize, group_len: usize) void {
    var path: [120][cb_tot_all]TrellisPath = undefined;
    const max_sfb: usize = sce.ics.max_sfb;
    const short = sce.ics.num_windows == 8;
    const run_bits: u6 = if (sce.ics.num_windows == 1) 5 else 3;
    const run_esc: i32 = (@as(i32, 1) << @as(u5, @intCast(run_bits))) - 1;
    const rvb: []const u8 = if (short) &run_value_bits_short else &run_value_bits_long;
    var next_minbits = std.math.inf(f32);
    var next_mincb: i32 = 0;

    absPow34(&e.scoefs, &sce.coeffs);
    var start = win * 128;
    for (&path[0]) |*p| p.* = .{ .cost = @floatFromInt(@as(i32, run_bits) + 4), .prev_idx = -1, .run = 0 };
    for (0..max_sfb) |swb| {
        const size: usize = sce.ics.swb_sizes[swb];
        if (sce.zeroes[win * 16 + swb] != 0) {
            var cost_stay_here = path[swb][0].cost;
            const cost_get_here = next_minbits + @as(f32, @floatFromInt(run_bits)) + 4;
            if (rvb[@intCast(path[swb][0].run)] != rvb[@intCast(path[swb][0].run + 1)]) cost_stay_here += @floatFromInt(run_bits);
            if (cost_get_here < cost_stay_here) {
                path[swb + 1][0] = .{ .prev_idx = next_mincb, .cost = cost_get_here, .run = 1 };
            } else {
                path[swb + 1][0] = .{ .prev_idx = 0, .cost = cost_stay_here, .run = path[swb][0].run + 1 };
            }
            next_minbits = path[swb + 1][0].cost;
            next_mincb = 0;
            for (1..cb_tot_all) |cb| path[swb + 1][cb] = .{ .cost = 61450, .prev_idx = -1, .run = 0 };
        } else {
            const minbits = next_minbits;
            const mincb = next_mincb;
            const startcb: usize = aac_cb_in_map[sce.band_type[win * 16 + swb]];
            next_minbits = std.math.inf(f32);
            next_mincb = 0;
            for (0..startcb) |cb| path[swb + 1][cb] = .{ .cost = 61450, .prev_idx = -1, .run = 0 };
            for (startcb..cb_tot_all) |cb| {
                if (cb >= 12 and sce.band_type[win * 16 + swb] != aac_cb_out_map[cb]) {
                    path[swb + 1][cb] = .{ .cost = 61450, .prev_idx = -1, .run = 0 };
                    continue;
                }
                var band_bits: f32 = 0;
                for (0..group_len) |w| {
                    band_bits += @floatFromInt(quantizeBandCostBits(e, sce.coeffs[start + w * 128 ..], e.scoefs[start + w * 128 ..], size, sce.sf_idx[win * 16 + swb], aac_cb_out_map[cb]));
                }
                var cost_stay_here = path[swb][cb].cost + band_bits;
                const cost_get_here = minbits + band_bits + @as(f32, @floatFromInt(run_bits)) + 4;
                if (rvb[@intCast(path[swb][cb].run)] != rvb[@intCast(path[swb][cb].run + 1)]) cost_stay_here += @floatFromInt(run_bits);
                if (cost_get_here < cost_stay_here) {
                    path[swb + 1][cb] = .{ .prev_idx = mincb, .cost = cost_get_here, .run = 1 };
                } else {
                    path[swb + 1][cb] = .{ .prev_idx = @intCast(cb), .cost = cost_stay_here, .run = path[swb][cb].run + 1 };
                }
                if (path[swb + 1][cb].cost < next_minbits) {
                    next_minbits = path[swb + 1][cb].cost;
                    next_mincb = @intCast(cb);
                }
            }
        }
        start += sce.ics.swb_sizes[swb];
    }

    // The path, from its backward-linked form.
    var stackrun: [120]i32 = undefined;
    var stackcb: [120]usize = undefined;
    var stack_len: usize = 0;
    var idx: usize = 0;
    for (1..cb_tot_all) |cb| {
        if (path[max_sfb][cb].cost < path[max_sfb][idx].cost) idx = cb;
    }
    var ppos: usize = max_sfb;
    while (ppos > 0) {
        const cb = idx;
        stackrun[stack_len] = path[ppos][cb].run;
        stackcb[stack_len] = cb;
        idx = @intCast(path[ppos - @as(usize, @intCast(path[ppos][cb].run)) + 1][cb].prev_idx);
        ppos -= @intCast(path[ppos][cb].run);
        stack_len += 1;
    }
    // The section data.
    var at: usize = 0;
    var si = stack_len;
    while (si > 0) {
        si -= 1;
        const cb = aac_cb_out_map[stackcb[si]];
        pb.bits(4, cb);
        var count = stackrun[si];
        const n: usize = @intCast(count);
        @memset(sce.zeroes[win * 16 + at ..][0..n], @intFromBool(cb == 0));
        for (0..n) |_| {
            sce.band_type[win * 16 + at] = cb;
            at += 1;
        }
        while (count >= run_esc) {
            pb.bits(run_bits, @intCast(run_esc));
            count -= run_esc;
        }
        pb.bits(run_bits, @intCast(count));
    }
}

/// set_special_band_scalefactors: the PNS energies' and I/S positions'
/// scalefactors, each chain limited to the coded differences.
pub fn setSpecialBandScalefactors(sce: *Sce) void {
    var prevscaler_n: i32 = -255;
    var prevscaler_i: i32 = 0;
    var bands: usize = 0;
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            if (sce.zeroes[b] != 0) continue;
            if (sce.band_type[b] == bt.intensity or sce.band_type[b] == bt.intensity2) {
                const v = cconv.cvttsd2si32(@round(libm.log2f(sce.is_ener[b]) * 2));
                sce.sf_idx[b] = std.math.clamp(v, -155, 100);
                bands += 1;
            } else if (sce.band_type[b] == bt.noise) {
                const v = cconv.cvttsd2si32(3 + @ceil(libm.log2f(sce.pns_ener[b]) * 2));
                sce.sf_idx[b] = std.math.clamp(v, -100, 155);
                if (prevscaler_n == -255) prevscaler_n = sce.sf_idx[b];
                bands += 1;
            }
        }
    }
    if (bands == 0) return;
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            if (sce.zeroes[b] != 0) continue;
            if (sce.band_type[b] == bt.intensity or sce.band_type[b] == bt.intensity2) {
                prevscaler_i = std.math.clamp(sce.sf_idx[b], prevscaler_i - scale_max_diff, prevscaler_i + scale_max_diff);
                sce.sf_idx[b] = prevscaler_i;
            } else if (sce.band_type[b] == bt.noise) {
                prevscaler_n = std.math.clamp(sce.sf_idx[b], prevscaler_n - scale_max_diff, prevscaler_n + scale_max_diff);
                sce.sf_idx[b] = prevscaler_n;
            }
        }
    }
}

/// search_for_quantizers_fast.
pub fn searchForQuantizersFast(e: *Encoder, sce: *Sce, lambda: f32) void {
    var destbits: i32 = cconv.cvttsd2si32(@as(f64, @floatFromInt(e.bit_rate)) * 1024.0 / @as(f64, @floatFromInt(e.sample_rate)) / @as(f64, @floatFromInt(e.channels)) * @as(f64, lambda / 120.0));
    var dists: [128]f32 = @splat(0);
    var uplims: [128]f32 = @splat(0);
    var maxvals: [128]f32 = undefined;
    var minscaler: i32 = undefined;
    var its: i32 = 0;
    var allz = false;
    var minthr = std.math.inf(f32);
    const bands = e.psyBands(e.cur_channel);
    // Above this the decoder may loop forever on bits it cannot code.
    destbits = @min(destbits, 5800);
    // Zero bands and upper limits.
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            var nz = false;
            var uplim: f32 = 0;
            for (0..sce.ics.group_len[w]) |w2| {
                const band = &bands[(w + w2) * 16 + g];
                uplim += band.threshold;
                if (band.energy <= band.threshold or band.threshold == 0) {
                    sce.zeroes[(w + w2) * 16 + g] = 1;
                    continue;
                }
                nz = true;
            }
            uplims[w * 16 + g] = uplim * 512;
            sce.band_type[w * 16 + g] = 0;
            sce.zeroes[w * 16 + g] = @intFromBool(!nz);
            if (nz) minthr = fmin(minthr, uplim);
            allz = allz or nz;
        }
    }
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            if (sce.zeroes[w * 16 + g] != 0) {
                sce.sf_idx[w * 16 + g] = scale_one_pos;
                continue;
            }
            const v = fmin(libm.log2f(uplims[w * 16 + g] / minthr) * 4, 59);
            sce.sf_idx[w * 16 + g] = cconv.cvttsd2si32(@as(f32, scale_one_pos) + v);
        }
    }
    if (!allz) return;
    absPow34(&e.scoefs, &sce.coeffs);
    e.costCacheInit();
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        var start = w * 128;
        for (0..sce.ics.num_swb) |g| {
            maxvals[w * 16 + g] = findMaxVal(sce.ics.group_len[w], sce.ics.swb_sizes[g], e.scoefs[start..]);
            start += sce.ics.swb_sizes[g];
        }
    }
    // The two-loop search: the outer loop improves the quality.
    while (true) {
        minscaler = sce.sf_idx[0];
        // The inner loop fits the spectrum into the bits.
        var qstep: i32 = if (its != 0) 1 else 32;
        while (true) {
            var prev: i32 = -1;
            var tbits: i32 = 0;
            w = 0;
            while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
                var start = w * 128;
                for (0..sce.ics.num_swb) |g| {
                    var band_bits: i32 = 0;
                    var dist: f32 = 0;
                    if (sce.zeroes[w * 16 + g] != 0 or sce.sf_idx[w * 16 + g] >= 218) {
                        start += sce.ics.swb_sizes[g];
                        continue;
                    }
                    minscaler = @min(minscaler, sce.sf_idx[w * 16 + g]);
                    const cb = findMinBook(maxvals[w * 16 + g], sce.sf_idx[w * 16 + g]);
                    for (0..sce.ics.group_len[w]) |w2| {
                        var b: i32 = 0;
                        dist += quantizeBandCostCached(e, w + w2, g, sce.coeffs[start + w2 * 128 ..], e.scoefs[start + w2 * 128 ..], sce.ics.swb_sizes[g], sce.sf_idx[w * 16 + g], cb, 1.0, std.math.inf(f32), &b, null, false);
                        band_bits += b;
                    }
                    dists[w * 16 + g] = dist - @as(f32, @floatFromInt(band_bits));
                    if (prev != -1) band_bits += aac_tab.scalefactor_bits[@intCast(sce.sf_idx[w * 16 + g] - prev + scale_diff_zero)];
                    tbits += band_bits;
                    start += sce.ics.swb_sizes[g];
                    prev = sce.sf_idx[w * 16 + g];
                }
            }
            if (tbits > destbits) {
                for (&sce.sf_idx) |*sf| {
                    if (sf.* < 218 - qstep) sf.* += qstep;
                }
            } else {
                for (&sce.sf_idx) |*sf| {
                    if (sf.* > 60 - qstep) sf.* -= qstep;
                }
            }
            qstep >>= 1;
            if (qstep == 0 and @as(f64, @floatFromInt(tbits)) > @as(f64, @floatFromInt(destbits)) * 1.02 and sce.sf_idx[0] < 217) qstep = 1;
            if (qstep == 0) break;
        }
        var fflag = false;
        minscaler = std.math.clamp(minscaler, 60, 255 - scale_max_diff);
        w = 0;
        while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
            for (0..sce.ics.num_swb) |g| {
                const b = w * 16 + g;
                const prevsc = sce.sf_idx[b];
                if (dists[b] > uplims[b] and sce.sf_idx[b] > 60) {
                    if (findMinBook(maxvals[b], sce.sf_idx[b] - 1) != 0) {
                        sce.sf_idx[b] -= 1;
                    } else {
                        // Some energy in every band.
                        sce.sf_idx[b] -= 2;
                    }
                }
                sce.sf_idx[b] = std.math.clamp(sce.sf_idx[b], minscaler, minscaler + scale_max_diff);
                sce.sf_idx[b] = @min(sce.sf_idx[b], 219);
                if (sce.sf_idx[b] != prevsc) fflag = true;
                sce.band_type[b] = findMinBook(maxvals[b], sce.sf_idx[b]);
            }
        }
        its += 1;
        if (!(fflag and its < 10)) break;
    }
}

/// ff_pns_bits: the cost of changing codebooks into a PNS band.
fn pnsBits(sce: *const Sce, w: usize, g: usize) i32 {
    return if (g == 0 or sce.zeroes[w * 16 + g - 1] == 0 or sce.can_pns[w * 16 + g - 1] == 0) 9 else 5;
}

/// search_for_quantizers_twoloop: ISO 13818-7 Appendix C's two-loop
/// search, with FFmpeg's distortion limits, noisy-band zeroing and its
/// two index slips (`nzs[g]` and `swb_sizes[w]` where the window group's
/// band is meant, notes.md "AAC encoding").
pub fn searchForQuantizersTwoloop(e: *Encoder, sce: *Sce, lambda: f32) void {
    const qscale = e.opt.qscale;
    const divisor: f64 = if (qscale) 2.0 else @floatFromInt(e.channels);
    // `int destbits = avctx->bit_rate * 1024.0 / avctx->sample_rate / (...)
    // * (lambda / 120.f)`: double arithmetic, truncated.
    var destbits: i32 = cconv.cvttsd2si32(@as(f64, @floatFromInt(e.bit_rate)) * 1024.0 / @as(f64, @floatFromInt(e.sample_rate)) / divisor * @as(f64, lambda / 120.0));
    var toomanybits: i32 = undefined;
    var toofewbits: i32 = undefined;
    var nzs: [128]i8 = undefined;
    var nextband: [128]u8 = undefined;
    var maxsf: [128]i32 = undefined;
    var minsf: [128]i32 = undefined;
    var dists: [128]f32 = @splat(0);
    var qenergies: [128]f32 = @splat(0);
    var uplims: [128]f32 = undefined;
    var euplims: [128]f32 = undefined;
    var energies: [128]f32 = undefined;
    var maxvals: [128]f32 = undefined;
    var spread_thr_r: [128]f32 = undefined;
    var min_spread_thr_r: f32 = undefined;
    var max_spread_thr_r: f32 = undefined;
    const bands = e.psyBands(e.cur_channel);

    // rdlambda bounds the tolerated distortion; rdmin and rdmax its
    // tonality compensation.
    var rdlambda = clipf(2.0 * 120.0 / lambda, 0.0625, 16.0);
    const nzslope: f32 = 1.5;
    const rdmin: f32 = 0.03125;
    const rdmax: f32 = 1.0;
    // sfoffs offsets the allocation by lambda.
    var sfoffs = clipf(libm.log2f(120.0 / lambda) * 4.0, -5, 10);
    var fflag = false;
    var minscaler: i32 = undefined;
    var nminscaler: i32 = undefined;
    var its: i32 = 0;
    var maxits: i32 = 30;
    var allz = false;
    var tbits: i32 = 0;
    var prev: i32 = undefined;
    var recomprd = false;

    // zeroscale: below this multiple of the threshold a band is zeroed.
    const zeroscale: f32 = if (lambda > 120.0) clipf(libm.powf(120.0 / lambda, 0.25), 0.0625, 1.0) else 1.0;

    if (e.psy.bitres.alloc >= 0) {
        // Psy granted bits from the reservoir, adjusted for lambda.
        const gq: f32 = @floatFromInt(if (e.opt.global_quality != 0) e.opt.global_quality else 120);
        destbits = cconv.cvttsd2si32(@as(f32, @floatFromInt(e.psy.bitres.alloc)) * (lambda / gq));
    }

    if (qscale) {
        // A constant Q-scale does not compensate M/S coding.
        if (e.opt.mid_side != 0 and e.cur_type == aacenc.ElementType.cpe) destbits *= 2;
        // Only RD, within 8 times the psy target.
        toomanybits = 5800;
        toofewbits = @divTrunc(destbits, 16);
        sfoffs = @floatFromInt(@as(i32, sce.ics.num_windows) - 1);
        rdlambda = @sqrt(rdlambda);
        maxits *= 2;
    } else {
        // ABR: strict, with a symmetric leeway for the rate control.
        toomanybits = destbits + @divTrunc(destbits, 8);
        toofewbits = destbits - @divTrunc(destbits, 8);
        sfoffs = 0;
        rdlambda = @sqrt(rdlambda);
    }

    // Zeros above the cutoff frequency.
    const wlen: i32 = @divTrunc(1024, @as(i32, sce.ics.num_windows));
    const cutoff: i32 = @divTrunc(e.bandwidth * 2 * wlen, @as(i32, @intCast(e.sample_rate)));
    const pns_start_pos: i32 = @divTrunc(noise_low_limit * 2 * wlen, @as(i32, @intCast(e.sample_rate)));

    destbits = @min(destbits, 5800);
    toomanybits = @min(toomanybits, 5800);
    toofewbits = @min(toofewbits, 5800);

    // Zero bands and the distortion limits.
    min_spread_thr_r = -1;
    max_spread_thr_r = -1;
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        var start: i32 = 0;
        for (0..sce.ics.num_swb) |g| {
            var nz: i32 = 0;
            var uplim: f32 = 0;
            var energy: f32 = 0;
            var spread: f32 = 0;
            for (0..sce.ics.group_len[w]) |w2| {
                const band = &bands[(w + w2) * 16 + g];
                if (start >= cutoff or band.energy <= band.threshold * zeroscale or band.threshold == 0) {
                    sce.zeroes[(w + w2) * 16 + g] = 1;
                    continue;
                }
                nz = 1;
            }
            if (nz == 0) {
                uplim = 0;
            } else {
                nz = 0;
                for (0..sce.ics.group_len[w]) |w2| {
                    const band = &bands[(w + w2) * 16 + g];
                    if (band.energy <= band.threshold * zeroscale or band.threshold == 0) continue;
                    uplim += band.threshold;
                    energy += band.energy;
                    spread += band.spread;
                    nz += 1;
                }
            }
            const b = w * 16 + g;
            uplims[b] = uplim;
            energies[b] = energy;
            nzs[b] = @intCast(nz);
            sce.zeroes[b] = @intFromBool(nz == 0);
            allz = allz or nz != 0;
            if (nz != 0 and sce.can_pns[b] != 0) {
                spread_thr_r[b] = energy * @as(f32, @floatFromInt(nz)) / (uplim * spread);
                if (min_spread_thr_r < 0) {
                    min_spread_thr_r = spread_thr_r[b];
                    max_spread_thr_r = spread_thr_r[b];
                } else {
                    min_spread_thr_r = fmin(min_spread_thr_r, spread_thr_r[b]);
                    max_spread_thr_r = fmax(max_spread_thr_r, spread_thr_r[b]);
                }
            }
            start += sce.ics.swb_sizes[g];
        }
    }

    // The initial scalers: 1.75 times log2 of the threshold per line (a
    // conservative log-to-distortion ratio).
    minscaler = 65535;
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            if (sce.zeroes[b] != 0) {
                sce.sf_idx[b] = scale_one_pos;
                continue;
            }
            // `SCALE_ONE_POS + 1.75*log2f(...) + sfoffs` in double, then int.
            const v: f64 = @as(f64, scale_one_pos) + 1.75 * @as(f64, libm.log2f(fmax(0.00125, uplims[b]) / @as(f32, @floatFromInt(sce.ics.swb_sizes[g])))) + @as(f64, sfoffs);
            sce.sf_idx[b] = std.math.clamp(cconv.cvttsd2si32(v), 60, scale_max_pos);
            minscaler = @min(minscaler, sce.sf_idx[b]);
        }
    }
    minscaler = std.math.clamp(minscaler, scale_one_pos - scale_div_512, scale_max_pos - scale_div_512);
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            if (sce.zeroes[b] == 0) sce.sf_idx[b] = std.math.clamp(sce.sf_idx[b], minscaler, minscaler + scale_max_diff - 1);
        }
    }

    if (!allz) return;
    absPow34(&e.scoefs, &sce.coeffs);
    e.costCacheInit();

    minsf = @splat(0);
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        var start = w * 128;
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            maxvals[b] = findMaxVal(sce.ics.group_len[w], sce.ics.swb_sizes[g], e.scoefs[start..]);
            if (maxvals[b] > 0) {
                const minsfidx = coef2minsf(maxvals[b]);
                for (0..sce.ics.group_len[w]) |w2| minsf[(w + w2) * 16 + g] = minsfidx;
            }
            start += sce.ics.swb_sizes[g];
        }
    }

    // Distortion limits scaled by tonality: noisy bands relaxed, tonal
    // ones prioritized.
    euplims = uplims;
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        // Psy already prioritizes transients.
        const de_psy_factor: f32 = if (sce.ics.num_windows > 1) 8.0 / @as(f32, @floatFromInt(sce.ics.group_len[w])) else 1.0;
        var start: i32 = @intCast(w * 128);
        for (0..sce.ics.num_swb) |g| {
            // FFmpeg reads `nzs[g]` and `swb_sizes[w]` here, not the
            // group's band.
            if (nzs[g] > 0) {
                const b = w * 16 + g;
                const cf = clipf(@as(f32, @floatFromInt(start)) / (@as(f32, @floatFromInt(cutoff)) * 0.75), 1.0, 2.0);
                const cleanup_factor = cf * cf;
                const nzg: f32 = @floatFromInt(nzs[g]);
                const sw: f32 = @floatFromInt(sce.ics.swb_sizes[w]);
                var energy2uplim = findFormFactor(sce.ics.group_len[w], sce.ics.swb_sizes[g], uplims[b] / (nzg * sw), sce.coeffs[@intCast(start)..], nzslope * cleanup_factor);
                energy2uplim *= de_psy_factor;
                if (!qscale) energy2uplim = @sqrt(energy2uplim);
                energy2uplim = fmax(0.015625, fmin(1.0, energy2uplim));
                uplims[b] *= clipf(rdlambda * energy2uplim, rdmin, rdmax) * @as(f32, @floatFromInt(sce.ics.group_len[w]));

                energy2uplim = findFormFactor(sce.ics.group_len[w], sce.ics.swb_sizes[g], uplims[b] / (nzg * sw), sce.coeffs[@intCast(start)..], 2.0);
                energy2uplim *= de_psy_factor;
                if (!qscale) energy2uplim = @sqrt(energy2uplim);
                energy2uplim = fmax(0.015625, fmin(1.0, energy2uplim));
                euplims[b] *= clipf(rdlambda * energy2uplim * @as(f32, @floatFromInt(sce.ics.group_len[w])), 0.5, 1.0);
            }
            start += sce.ics.swb_sizes[g];
        }
    }

    maxsf = @splat(scale_max_pos);

    // The two-loop search: the outer loop improves the quality.
    while (true) {
        // The inner loop fits the spectrum into the bits.
        var qstep: i32 = if (its != 0) 1 else 32;
        while (true) {
            var changed = false;
            prev = -1;
            recomprd = false;
            tbits = 0;
            w = 0;
            while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
                var start = w * 128;
                for (0..sce.ics.num_swb) |g| {
                    const b = w * 16 + g;
                    var band_bits: i32 = 0;
                    var dist: f32 = 0;
                    var qenergy: f32 = 0;
                    if (sce.zeroes[b] != 0 or sce.sf_idx[b] >= 218) {
                        start += sce.ics.swb_sizes[g];
                        // PNS isn't free.
                        if (sce.can_pns[b] != 0) tbits += pnsBits(sce, w, g);
                        continue;
                    }
                    const cb = findMinBook(maxvals[b], sce.sf_idx[b]);
                    for (0..sce.ics.group_len[w]) |w2| {
                        var bb: i32 = 0;
                        var sqenergy: f32 = 0;
                        dist += quantizeBandCostCached(e, w + w2, g, sce.coeffs[start + w2 * 128 ..], e.scoefs[start + w2 * 128 ..], sce.ics.swb_sizes[g], sce.sf_idx[b], cb, 1.0, std.math.inf(f32), &bb, &sqenergy, false);
                        band_bits += bb;
                        qenergy += sqenergy;
                    }
                    dists[b] = dist - @as(f32, @floatFromInt(band_bits));
                    qenergies[b] = qenergy;
                    if (prev != -1) {
                        const sfdiff = std.math.clamp(sce.sf_idx[b] - prev + scale_diff_zero, 0, 2 * scale_max_diff);
                        band_bits += aac_tab.scalefactor_bits[@intCast(sfdiff)];
                    }
                    tbits += band_bits;
                    start += sce.ics.swb_sizes[g];
                    prev = sce.sf_idx[b];
                }
            }
            if (tbits > toomanybits) {
                recomprd = true;
                for (0..128) |i| {
                    if (sce.sf_idx[i] < scale_max_pos - scale_div_512) {
                        const maxsf_i = if (tbits > 5800) scale_max_pos else maxsf[i];
                        const new_sf = @min(maxsf_i, sce.sf_idx[i] + qstep);
                        if (new_sf != sce.sf_idx[i]) {
                            sce.sf_idx[i] = new_sf;
                            changed = true;
                        }
                    }
                }
            } else if (tbits < toofewbits) {
                recomprd = true;
                for (0..128) |i| {
                    if (sce.sf_idx[i] > scale_one_pos) {
                        const new_sf = @max(@max(minsf[i], scale_one_pos), sce.sf_idx[i] - qstep);
                        if (new_sf != sce.sf_idx[i]) {
                            sce.sf_idx[i] = new_sf;
                            changed = true;
                        }
                    }
                }
            }
            qstep >>= 1;
            if (qstep == 0 and tbits > toomanybits and sce.sf_idx[0] < 217 and changed) qstep = 1;
            if (qstep == 0) break;
        }

        var overdist = true;
        fflag = tbits < toofewbits;
        var pass: usize = 0;
        while (pass < 2 and (overdist or recomprd)) : (pass += 1) {
            if (recomprd) {
                // The distortion, recomputed.
                prev = -1;
                tbits = 0;
                w = 0;
                while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
                    var start = w * 128;
                    for (0..sce.ics.num_swb) |g| {
                        const b = w * 16 + g;
                        var band_bits: i32 = 0;
                        var dist: f32 = 0;
                        var qenergy: f32 = 0;
                        if (sce.zeroes[b] != 0 or sce.sf_idx[b] >= 218) {
                            start += sce.ics.swb_sizes[g];
                            if (sce.can_pns[b] != 0) tbits += pnsBits(sce, w, g);
                            continue;
                        }
                        const cb = findMinBook(maxvals[b], sce.sf_idx[b]);
                        for (0..sce.ics.group_len[w]) |w2| {
                            var bb: i32 = 0;
                            var sqenergy: f32 = 0;
                            dist += quantizeBandCostCached(e, w + w2, g, sce.coeffs[start + w2 * 128 ..], e.scoefs[start + w2 * 128 ..], sce.ics.swb_sizes[g], sce.sf_idx[b], cb, 1.0, std.math.inf(f32), &bb, &sqenergy, false);
                            band_bits += bb;
                            qenergy += sqenergy;
                        }
                        dists[b] = dist - @as(f32, @floatFromInt(band_bits));
                        qenergies[b] = qenergy;
                        if (prev != -1) {
                            const sfdiff = std.math.clamp(sce.sf_idx[b] - prev + scale_diff_zero, 0, 2 * scale_max_diff);
                            band_bits += aac_tab.scalefactor_bits[@intCast(sfdiff)];
                        }
                        tbits += band_bits;
                        start += sce.ics.swb_sizes[g];
                        prev = sce.sf_idx[b];
                    }
                }
            }
            if (pass == 0 and e.opt.pns != 0 and its > @divTrunc(maxits, 2) and tbits > toofewbits) {
                var maxoverdist: f32 = 0;
                const ovrfactor: f32 = 1.0 + @as(f32, @floatFromInt(maxits - its)) * 16.0 / @as(f32, @floatFromInt(maxits));
                var overdist_count: i32 = 0;
                recomprd = false;
                w = 0;
                while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
                    for (0..sce.ics.num_swb) |g| {
                        const b = w * 16 + g;
                        if (sce.zeroes[b] == 0 and sce.sf_idx[b] > scale_one_pos and dists[b] > uplims[b] * ovrfactor) {
                            const ovrdist = dists[b] / fmax(uplims[b], euplims[b]);
                            maxoverdist = fmax(maxoverdist, ovrdist);
                            overdist_count += 1;
                        }
                    }
                }
                overdist = overdist_count != 0;
                if (overdist) {
                    // Trade over-distorted bands for zeros (noise): the
                    // lowest 1.25% of the spread-energy-threshold ranking.
                    var minspread = max_spread_thr_r;
                    var maxspread = min_spread_thr_r;
                    var zeroable: i32 = 0;
                    var zeroed: i32 = 0;
                    w = 0;
                    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
                        var start: i32 = 0;
                        for (0..sce.ics.num_swb) |g| {
                            const b = w * 16 + g;
                            if (start >= pns_start_pos and sce.zeroes[b] == 0 and sce.can_pns[b] != 0) {
                                minspread = fmin(minspread, spread_thr_r[b]);
                                maxspread = fmax(maxspread, spread_thr_r[b]);
                                zeroable += 1;
                            }
                            start += sce.ics.swb_sizes[g];
                        }
                    }
                    var zspread = (maxspread - minspread) * 0.0125 + minspread;
                    // PNS only a fraction of the range, by how starved
                    // for bits the frame is; search_for_pns does the rest.
                    const by_rate = (@as(f32, @floatFromInt(toomanybits - tbits)) * min_spread_thr_r + @as(f32, @floatFromInt(tbits - toofewbits)) * max_spread_thr_r) / @as(f32, @floatFromInt(toomanybits - toofewbits + 1));
                    zspread = fmin(fmin(min_spread_thr_r * 8.0, zspread), by_rate);
                    const maxzeroed = @min(zeroable, @max(1, @divTrunc(zeroable * its + maxits - 1, 2 * maxits)));
                    for (0..2) |zloop| {
                        // Distorted bands first, then any viable one.
                        const loopovrfactor: f32 = if (zloop != 0) 1.0 else ovrfactor;
                        const loopminsf: i32 = if (zloop != 0) scale_one_pos - scale_div_512 else scale_one_pos;
                        var g: usize = sce.ics.num_swb - 1;
                        while (g > 0 and zeroed < maxzeroed) : (g -= 1) {
                            if (sce.ics.swb_offset[g] < pns_start_pos) continue;
                            w = 0;
                            while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
                                const b = w * 16 + g;
                                if (sce.zeroes[b] == 0 and sce.can_pns[b] != 0 and spread_thr_r[b] <= zspread and sce.sf_idx[b] > loopminsf) {
                                    const zero_it = blk: {
                                        if (dists[b] > loopovrfactor * uplims[b]) break :blk true;
                                        const mcb = findMinBook(maxvals[b], sce.sf_idx[b]);
                                        if (mcb == 0) break :blk true;
                                        break :blk mcb <= 1 and dists[b] > fmin(uplims[b], euplims[b]);
                                    };
                                    if (zero_it) {
                                        sce.zeroes[b] = 1;
                                        sce.band_type[b] = 0;
                                        zeroed += 1;
                                    }
                                }
                            }
                        }
                    }
                    if (zeroed != 0) {
                        recomprd = true;
                        fflag = true;
                    }
                } else {
                    overdist = false;
                }
            }
        }

        minscaler = scale_max_pos;
        w = 0;
        while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
            for (0..sce.ics.num_swb) |g| {
                if (sce.zeroes[w * 16 + g] == 0) minscaler = @min(minscaler, sce.sf_idx[w * 16 + g]);
            }
        }
        minscaler = std.math.clamp(minscaler, scale_one_pos - scale_div_512, scale_max_pos - scale_div_512);
        nminscaler = minscaler;
        prev = -1;
        w = 0;
        while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
            // Big steps first, fine-tuning at the end.
            const depth: usize = if (its > @divTrunc(maxits, 2)) (if (its > @divTrunc(maxits * 2, 3)) 1 else 3) else 10;
            const edepth = depth + 2;
            var uplmax: f32 = @as(f32, @floatFromInt(its)) / (@as(f32, @floatFromInt(maxits)) * 0.25) + 1.0;
            uplmax *= if (tbits > destbits) fmin(2.0, @as(f32, @floatFromInt(tbits)) / @as(f32, @floatFromInt(@max(1, destbits)))) else 1.0;
            var start = w * 128;
            for (0..sce.ics.num_swb) |g| {
                const b = w * 16 + g;
                const prevsc = sce.sf_idx[b];
                if (prev < 0 and sce.zeroes[b] == 0) prev = sce.sf_idx[0];
                if (sce.zeroes[b] == 0) {
                    const coefs = sce.coeffs[start..];
                    const scaled = e.scoefs[start..];
                    const cmb = findMinBook(maxvals[b], sce.sf_idx[b]);
                    const mindeltasf = @max(0, prev - scale_max_diff);
                    const maxdeltasf = @min(scale_max_pos - scale_div_512, prev + scale_max_diff);
                    if ((cmb == 0 or dists[b] > uplims[b]) and sce.sf_idx[b] > @max(mindeltasf, minsf[b])) {
                        // Some energy in every nonzero band, pushing harder
                        // on holes and the most distorted bands first.
                        var i: usize = 0;
                        while (i < edepth and sce.sf_idx[b] > mindeltasf) : (i += 1) {
                            var dist: f32 = 0;
                            var qenergy: f32 = 0;
                            var band_bits: i32 = 0;
                            const mb = findMinBook(maxvals[b], sce.sf_idx[b] - 1);
                            const cb = findMinBook(maxvals[b], sce.sf_idx[b]);
                            if (cb == 0) {
                                maxsf[b] = @min(sce.sf_idx[b] - 1, maxsf[b]);
                            } else if (i >= depth and dists[b] < euplims[b]) {
                                break;
                            }
                            // The DC band of short windows sticks to psy:
                            // its error spans less than a cycle.
                            if (g == 0 and sce.ics.num_windows > 1 and dists[b] >= euplims[b]) maxsf[b] = @min(sce.sf_idx[b], maxsf[b]);
                            for (0..sce.ics.group_len[w]) |w2| {
                                var bb: i32 = 0;
                                var sqenergy: f32 = 0;
                                dist += quantizeBandCostCached(e, w + w2, g, coefs[w2 * 128 ..], scaled[w2 * 128 ..], sce.ics.swb_sizes[g], sce.sf_idx[b] - 1, cb, 1.0, std.math.inf(f32), &bb, &sqenergy, false);
                                band_bits += bb;
                                qenergy += sqenergy;
                            }
                            sce.sf_idx[b] -= 1;
                            dists[b] = dist - @as(f32, @floatFromInt(band_bits));
                            qenergies[b] = qenergy;
                            if (mb != 0 and (sce.sf_idx[b] < mindeltasf or
                                ((dists[b] < fmin(uplmax * uplims[b], euplims[b])) and
                                    (@abs(qenergies[b] - energies[b]) < euplims[b]))))
                            {
                                break;
                            }
                        }
                    } else if (tbits > toofewbits and sce.sf_idx[b] < @min(maxdeltasf, maxsf[b]) and
                        (dists[b] < fmin(euplims[b], uplims[b])) and
                        (@abs(qenergies[b] - energies[b]) < euplims[b]))
                    {
                        // Over target: save bits for more important bands.
                        var i: usize = 0;
                        while (i < depth and sce.sf_idx[b] < maxdeltasf) : (i += 1) {
                            const cb = findMinBook(maxvals[b], sce.sf_idx[b] + 1);
                            if (cb > 0) {
                                var dist: f32 = 0;
                                var qenergy: f32 = 0;
                                var band_bits: i32 = 0;
                                for (0..sce.ics.group_len[w]) |w2| {
                                    var bb: i32 = 0;
                                    var sqenergy: f32 = 0;
                                    dist += quantizeBandCostCached(e, w + w2, g, coefs[w2 * 128 ..], scaled[w2 * 128 ..], sce.ics.swb_sizes[g], sce.sf_idx[b] + 1, cb, 1.0, std.math.inf(f32), &bb, &sqenergy, false);
                                    band_bits += bb;
                                    qenergy += sqenergy;
                                }
                                dist -= @floatFromInt(band_bits);
                                if (dist < fmin(euplims[b], uplims[b])) {
                                    sce.sf_idx[b] += 1;
                                    dists[b] = dist;
                                    qenergies[b] = qenergy;
                                } else {
                                    break;
                                }
                            } else {
                                maxsf[b] = @min(sce.sf_idx[b], maxsf[b]);
                                break;
                            }
                        }
                    }
                    sce.sf_idx[b] = std.math.clamp(sce.sf_idx[b], mindeltasf, maxdeltasf);
                    prev = sce.sf_idx[b];
                    if (sce.sf_idx[b] != prevsc) fflag = true;
                    nminscaler = @min(nminscaler, sce.sf_idx[b]);
                    sce.band_type[b] = findMinBook(maxvals[b], sce.sf_idx[b]);
                }
                start += sce.ics.swb_sizes[g];
            }
        }

        // The differences may have left the coded range: clamp again.
        prev = -1;
        w = 0;
        while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
            for (0..sce.ics.num_swb) |g| {
                const b = w * 16 + g;
                if (sce.zeroes[b] == 0) {
                    const prevsf = sce.sf_idx[b];
                    if (prev < 0) prev = prevsf;
                    sce.sf_idx[b] = std.math.clamp(sce.sf_idx[b], prev - scale_max_diff, prev + scale_max_diff);
                    sce.band_type[b] = findMinBook(maxvals[b], sce.sf_idx[b]);
                    prev = sce.sf_idx[b];
                    if (!fflag and prevsf != sce.sf_idx[b]) fflag = true;
                }
            }
        }
        its += 1;
        if (!(fflag and its < maxits)) break;
    }

    initNextbandMap(sce, &nextband);
    prev = -1;
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        // The codebooks.
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            if (sce.zeroes[b] == 0) {
                sce.band_type[b] = findMinBook(maxvals[b], sce.sf_idx[b]);
                if (sce.band_type[b] <= 0) {
                    if (!sfdeltaCanRemoveBand(sce, &nextband, prev, b)) {
                        // Cannot be zeroed: keep a codebook.
                        sce.band_type[b] = 1;
                    } else {
                        sce.zeroes[b] = 1;
                        sce.band_type[b] = 0;
                    }
                }
            } else {
                sce.band_type[b] = 0;
            }
            if (sce.zeroes[b] == 0) {
                if (prev == -1 and sce.zeroes[0] != 0) {
                    // A useful global gain.
                    sce.sf_idx[0] = sce.sf_idx[b];
                }
                prev = sce.sf_idx[b];
            }
        }
    }
}

/// search_for_pns.
pub fn searchForPns(e: *Encoder, sce: *Sce) void {
    const wlen: i32 = @divTrunc(1024, @as(i32, sce.ics.num_windows));
    const pns = e.scoefs[0 * 128 ..][0..128];
    var pns34: [128]f32 = undefined;
    var nor34: [128]f32 = undefined;
    var nextband: [128]u8 = undefined;
    const lambda = e.lambda;
    const freq_mult = @as(f32, @floatFromInt(e.sample_rate)) * 0.5 / @as(f32, @floatFromInt(wlen));
    const thr_mult = noise_lambda_replace * (100.0 / lambda);
    const spread_threshold = fmin(0.75, noise_spread_threshold * fmax(0.5, lambda / 100.0));
    const dist_bias = clipf(4.0 * 120 / lambda, 0.25, 4.0);
    const pns_transient_energy_r = fmin(0.7, lambda / 140.0);
    const bands = e.psyBands(e.cur_channel);
    var prev: i32 = -1000;
    var prev_sf: i32 = -1;
    const cutoff: i32 = @divTrunc(e.bandwidth * 2 * wlen, @as(i32, @intCast(e.sample_rate)));

    sce.band_alt = sce.band_type;
    initNextbandMap(sce, &nextband);
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        const wstart = w * 128;
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            var dist1: f32 = 0;
            var dist2: f32 = 0;
            var pns_energy: f32 = 0;
            var sfb_energy: f32 = 0;
            var threshold: f32 = 0;
            var spread: f32 = 2.0;
            var min_energy: f32 = -1.0;
            var max_energy: f32 = 0;
            const start = wstart + sce.ics.swb_offset[g];
            const freq = @as(f32, @floatFromInt(start - wstart)) * freq_mult;
            const freq_boost = fmax(0.88 * freq / noise_low_limit, 1.0);
            if (freq < noise_low_limit or @as(i32, @intCast(start - wstart)) >= cutoff) {
                if (sce.zeroes[b] == 0) prev_sf = sce.sf_idx[b];
                continue;
            }
            for (0..sce.ics.group_len[w]) |w2| {
                const band = &bands[(w + w2) * 16 + g];
                sfb_energy += band.energy;
                spread = fmin(spread, band.spread);
                threshold += band.threshold;
                if (w2 == 0) {
                    min_energy = band.energy;
                    max_energy = band.energy;
                } else {
                    min_energy = fmin(min_energy, band.energy);
                    max_energy = fmax(max_energy, band.energy);
                }
            }
            // Ramps down at ~8 kHz and loosens the distortion threshold.
            const dist_thresh = clipf(2.5 * noise_low_limit / freq, 0.5, 2.5) * dist_bias;
            // PNS needs a noise-like band, near-threshold energy and, on
            // short groups, windows of similar energy.
            if ((sce.zeroes[b] == 0 and !sfdeltaCanRemoveBand(sce, &nextband, prev_sf, b)) or
                ((sce.zeroes[b] != 0 or sce.band_alt[b] == 0) and sfb_energy < threshold * @sqrt(1.0 / freq_boost)) or spread < spread_threshold or
                (sce.zeroes[b] == 0 and sce.band_alt[b] != 0 and sfb_energy > threshold * thr_mult * freq_boost) or
                min_energy < pns_transient_energy_r * max_energy)
            {
                sce.pns_ener[b] = sfb_energy;
                if (sce.zeroes[b] == 0) prev_sf = sce.sf_idx[b];
                continue;
            }
            const pns_tgt_energy = sfb_energy * fmin(1.0, spread * spread);
            const noise_sfi = std.math.clamp(cconv.cvttsd2si32(@round(libm.log2f(pns_tgt_energy) * 2)), -100, 155);
            const noise_amp = -pow2sf(noise_sfi + pow_sf2_zero);
            if (prev != -1000) {
                const noise_sfdiff = noise_sfi - prev + scale_diff_zero;
                if (noise_sfdiff < 0 or noise_sfdiff > 2 * scale_max_diff) {
                    if (sce.zeroes[b] == 0) prev_sf = sce.sf_idx[b];
                    continue;
                }
            }
            for (0..sce.ics.group_len[w]) |w2| {
                const start_c = (w + w2) * 128 + sce.ics.swb_offset[g];
                const band = &bands[(w + w2) * 16 + g];
                const size: usize = sce.ics.swb_sizes[g];
                for (0..size) |i| {
                    e.random_state = lcgRandom(e.random_state);
                    pns[i] = @floatFromInt(e.random_state);
                }
                const band_energy = scalarProduct(pns[0..size], pns[0..size]);
                const scale = noise_amp / @sqrt(band_energy);
                for (pns[0..size]) |*p| p.* *= scale;
                const pns_senergy = scalarProduct(pns[0..size], pns[0..size]);
                pns_energy += pns_senergy;
                absPow34(nor34[0..size], sce.coeffs[start_c..][0..size]);
                absPow34(pns34[0..size], pns[0..size]);
                dist1 += quantizeBandCost(e, sce.coeffs[start_c..], &nor34, size, sce.sf_idx[(w + w2) * 16 + g], sce.band_alt[(w + w2) * 16 + g], lambda / band.threshold, std.math.inf(f32), null, null);
                // On average 5 bits for the SF and 4 for the CB, plus the
                // spread energy times lambda over the threshold.
                dist2 += band.energy / (band.spread * band.spread) * lambda * dist_thresh / band.threshold;
            }
            if (g != 0 and sce.band_type[b - 1] == bt.noise) dist2 += 5 else dist2 += 9;
            // Compensates the quantization error.
            const energy_ratio = pns_tgt_energy / pns_energy;
            sce.pns_ener[b] = energy_ratio * pns_tgt_energy;
            if (sce.zeroes[b] != 0 or sce.band_alt[b] == 0 or (energy_ratio > 0.85 and energy_ratio < 1.25 and dist2 < dist1)) {
                sce.band_type[b] = bt.noise;
                sce.zeroes[b] = 0;
                prev = noise_sfi;
            } else if (sce.zeroes[b] == 0) {
                prev_sf = sce.sf_idx[b];
            }
        }
    }
}

/// scalarproduct_float_c.
fn scalarProduct(v1: []const f32, v2: []const f32) f32 {
    var p: f32 = 0;
    for (v1, v2) |a, b| p += a * b;
    return p;
}

/// mark_pns: the bands PNS may take.
pub fn markPns(e: *Encoder, sce: *Sce) void {
    const wlen: i32 = @divTrunc(1024, @as(i32, sce.ics.num_windows));
    const lambda = e.lambda;
    const freq_mult = @as(f32, @floatFromInt(e.sample_rate)) * 0.5 / @as(f32, @floatFromInt(wlen));
    const spread_threshold = fmin(0.75, noise_spread_threshold * fmax(0.5, lambda / 100.0));
    const pns_transient_energy_r = fmin(0.7, lambda / 140.0);
    const bands = e.psyBands(e.cur_channel);
    const cutoff: i32 = @divTrunc(e.bandwidth * 2 * wlen, @as(i32, @intCast(e.sample_rate)));

    sce.band_alt = sce.band_type;
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            const b = w * 16 + g;
            var sfb_energy: f32 = 0;
            var threshold: f32 = 0;
            var spread: f32 = 2.0;
            var min_energy: f32 = -1.0;
            var max_energy: f32 = 0;
            const start: i32 = sce.ics.swb_offset[g];
            const freq = @as(f32, @floatFromInt(start)) * freq_mult;
            const freq_boost = fmax(0.88 * freq / noise_low_limit, 1.0);
            if (freq < noise_low_limit or start >= cutoff) {
                sce.can_pns[b] = 0;
                continue;
            }
            for (0..sce.ics.group_len[w]) |w2| {
                const band = &bands[(w + w2) * 16 + g];
                sfb_energy += band.energy;
                spread = fmin(spread, band.spread);
                threshold += band.threshold;
                if (w2 == 0) {
                    min_energy = band.energy;
                    max_energy = band.energy;
                } else {
                    min_energy = fmin(min_energy, band.energy);
                    max_energy = fmax(max_energy, band.energy);
                }
            }
            sce.pns_ener[b] = sfb_energy;
            // A near-mask band (E in [thr/4, 2 thr]) goes to noise rather
            // than silence.
            const near = sfb_energy < 2.0 * threshold and sfb_energy > threshold * 0.25;
            if (near) {
                sce.can_pns[b] = @intFromBool(spread >= spread_threshold and min_energy >= 0.2 * max_energy);
            } else if (sfb_energy < threshold * @sqrt(1.5 / freq_boost) or spread < spread_threshold or min_energy < pns_transient_energy_r * max_energy) {
                sce.can_pns[b] = 0;
            } else {
                sce.can_pns[b] = 1;
            }
        }
    }
}

/// search_for_ms.
pub fn searchForMs(e: *Encoder, cpe: *Cpe) void {
    var m: [128]f32 = undefined;
    var s: [128]f32 = undefined;
    var l34: [128]f32 = undefined;
    var r34: [128]f32 = undefined;
    var m34: [128]f32 = undefined;
    var s34: [128]f32 = undefined;
    const lambda = e.lambda;
    const mslambda = fmin(1.0, lambda / 120.0);
    const sce0 = &cpe.ch[0];
    const sce1 = &cpe.ch[1];
    var nextband0: [128]u8 = undefined;
    var nextband1: [128]u8 = undefined;
    if (!cpe.common_window) return;
    const bands0 = e.psyBands(e.cur_channel);
    const bands1 = e.psyBands(e.cur_channel + 1);

    initNextbandMap(sce0, &nextband0);
    initNextbandMap(sce1, &nextband1);
    var prev_mid = sce0.sf_idx[0];
    var prev_side = sce1.sf_idx[0];
    var w: usize = 0;
    while (w < sce0.ics.num_windows) : (w += sce0.ics.group_len[w]) {
        var start: usize = 0;
        for (0..sce0.ics.num_swb) |g| {
            const b = w * 16 + g;
            const size: usize = sce0.ics.swb_sizes[g];
            const bmax = bval2bmax(@as(f32, @floatFromInt(g)) * 17.0 / @as(f32, @floatFromInt(sce0.ics.num_swb))) / 0.0045;
            if (cpe.is_mask[b] == 0) cpe.ms_mask[b] = 0;
            if (sce0.zeroes[b] == 0 and sce1.zeroes[b] == 0 and cpe.is_mask[b] == 0) {
                var mmax: f32 = 0;
                var smax: f32 = 0;
                // The mid/side scalefactor and codebook for the whole group.
                for (0..sce0.ics.group_len[w]) |w2| {
                    for (0..size) |i| {
                        m[i] = @floatCast((@as(f64, sce0.coeffs[start + (w + w2) * 128 + i] + sce1.coeffs[start + (w + w2) * 128 + i])) * 0.5);
                        s[i] = m[i] - sce1.coeffs[start + (w + w2) * 128 + i];
                    }
                    absPow34(m34[0..size], m[0..size]);
                    absPow34(s34[0..size], s[0..size]);
                    for (0..size) |i| {
                        mmax = fmax(mmax, m34[i]);
                        smax = fmax(smax, s34[i]);
                    }
                }
                for (0..4) |boost| {
                    const sid_sf_boost: i32 = @intCast(boost);
                    var dist1: f32 = 0;
                    var dist2: f32 = 0;
                    var b0: i32 = 0;
                    var b1: i32 = 0;
                    const minidx = @min(sce0.sf_idx[b], sce1.sf_idx[b]);
                    const mididx = std.math.clamp(minidx, 0, scale_max_pos - scale_div_512);
                    const sididx = std.math.clamp(minidx - sid_sf_boost * 3, 0, scale_max_pos - scale_div_512);
                    if (sce0.band_type[b] != bt.noise and sce1.band_type[b] != bt.noise and
                        (!sfdeltaCanReplace(sce0, &nextband0, prev_mid, mididx, b) or
                            !sfdeltaCanReplace(sce1, &nextband1, prev_side, sididx, b)))
                    {
                        // A scalefactor range violation.
                        continue;
                    }
                    // No codebook can be zero.
                    const midcb = @max(1, findMinBook(mmax, mididx));
                    const sidcb = @max(1, findMinBook(smax, sididx));
                    for (0..sce0.ics.group_len[w]) |w2| {
                        const band0 = &bands0[(w + w2) * 16 + g];
                        const band1 = &bands1[(w + w2) * 16 + g];
                        const minthr = fmin(band0.threshold, band1.threshold);
                        var bb1: i32 = 0;
                        var bb2: i32 = 0;
                        var bb3: i32 = 0;
                        var bb4: i32 = 0;
                        const c0 = sce0.coeffs[start + (w + w2) * 128 ..];
                        const c1 = sce1.coeffs[start + (w + w2) * 128 ..];
                        for (0..size) |i| {
                            m[i] = @floatCast(@as(f64, c0[i] + c1[i]) * 0.5);
                            s[i] = m[i] - c1[i];
                        }
                        absPow34(l34[0..size], c0[0..size]);
                        absPow34(r34[0..size], c1[0..size]);
                        absPow34(m34[0..size], m[0..size]);
                        absPow34(s34[0..size], s[0..size]);
                        dist1 += quantizeBandCost(e, c0, &l34, size, sce0.sf_idx[b], sce0.band_type[b], lambda / (band0.threshold + std.math.floatMin(f32)), std.math.inf(f32), &bb1, null);
                        dist1 += quantizeBandCost(e, c1, &r34, size, sce1.sf_idx[b], sce1.band_type[b], lambda / (band1.threshold + std.math.floatMin(f32)), std.math.inf(f32), &bb2, null);
                        dist2 += quantizeBandCost(e, &m, &m34, size, mididx, midcb, lambda / (minthr + std.math.floatMin(f32)), std.math.inf(f32), &bb3, null);
                        dist2 += quantizeBandCost(e, &s, &s34, size, sididx, sidcb, mslambda / (minthr * bmax + std.math.floatMin(f32)), std.math.inf(f32), &bb4, null);
                        b0 += bb1 + bb2;
                        b1 += bb3 + bb4;
                        dist1 -= @floatFromInt(bb1 + bb2);
                        dist2 -= @floatFromInt(bb3 + bb4);
                    }
                    cpe.ms_mask[b] = @intFromBool(dist2 <= dist1 and b1 < b0);
                    if (cpe.ms_mask[b] != 0) {
                        if (sce0.band_type[b] != bt.noise and sce1.band_type[b] != bt.noise) {
                            sce0.sf_idx[b] = mididx;
                            sce1.sf_idx[b] = sididx;
                            sce0.band_type[b] = midcb;
                            sce1.band_type[b] = sidcb;
                        } else if ((sce0.band_type[b] != bt.noise) != (sce1.band_type[b] != bt.noise)) {
                            // The mask would confuse some decoders.
                            cpe.ms_mask[b] = 0;
                        }
                        break;
                    } else if (b1 > b0) {
                        // More boost won't fix this.
                        break;
                    }
                }
            }
            if (sce0.zeroes[b] == 0 and sce0.band_type[b] < bt.reserved) prev_mid = sce0.sf_idx[b];
            if (sce1.zeroes[b] == 0 and cpe.is_mask[b] == 0 and sce1.band_type[b] < bt.reserved) prev_side = sce1.sf_idx[b];
            start += size;
        }
    }
}

const IsError = struct {
    pass: bool = false,
    phase: i32 = 0,
    err: f32 = 0,
    dist1: f32 = 0,
    dist2: f32 = 0,
    ener01: f32 = 0,
};

/// aac_is_encoding_err.
fn isEncodingErr(e: *Encoder, cpe: *Cpe, start: usize, w: usize, g: usize, ener0: f32, ener1: f32, ener01: f32, phase: i32) IsError {
    const sce0 = &cpe.ch[0];
    const sce1 = &cpe.ch[1];
    var l34: [128]f32 = undefined;
    var r34: [128]f32 = undefined;
    var is: [128]f32 = undefined;
    var is34: [128]f32 = undefined;
    var dist1: f32 = 0;
    var dist2: f32 = 0;
    if (ener01 <= 0 or ener0 <= 0) return .{};
    const fphase: f32 = @floatFromInt(phase);
    const e01_34 = fphase * posPow34(ener1 / ener0);
    const bands0 = e.psyBands(e.cur_channel);
    const bands1 = e.psyBands(e.cur_channel + 1);
    const size: usize = sce0.ics.swb_sizes[g];
    // `sqrt(ener0/ener01)` in double.
    const ratio = @sqrt(@as(f64, ener0 / ener01));
    for (0..sce0.ics.group_len[w]) |w2| {
        const band0 = &bands0[(w + w2) * 16 + g];
        const band1 = &bands1[(w + w2) * 16 + g];
        const is_sf_idx = @max(1, sce0.sf_idx[w * 16 + g] - 4);
        var dist_spec_err: f32 = 0;
        const minthr = fmin(band0.threshold, band1.threshold);
        const lc = sce0.coeffs[start + (w + w2) * 128 ..];
        const rc = sce1.coeffs[start + (w + w2) * 128 ..];
        for (0..size) |i| is[i] = @floatCast(@as(f64, lc[i] + fphase * rc[i]) * ratio);
        absPow34(l34[0..size], lc[0..size]);
        absPow34(r34[0..size], rc[0..size]);
        absPow34(is34[0..size], is[0..size]);
        const maxval = findMaxVal(1, size, &is34);
        const is_band_type = findMinBook(maxval, is_sf_idx);
        dist1 += quantizeBandCost(e, lc, &l34, size, sce0.sf_idx[w * 16 + g], sce0.band_type[w * 16 + g], e.lambda / band0.threshold, std.math.inf(f32), null, null);
        dist1 += quantizeBandCost(e, rc, &r34, size, sce1.sf_idx[w * 16 + g], sce1.band_type[w * 16 + g], e.lambda / band1.threshold, std.math.inf(f32), null, null);
        dist2 += quantizeBandCost(e, &is, &is34, size, is_sf_idx, is_band_type, e.lambda / minthr, std.math.inf(f32), null, null);
        for (0..size) |i| {
            dist_spec_err += (l34[i] - is34[i]) * (l34[i] - is34[i]);
            dist_spec_err += (r34[i] - is34[i] * e01_34) * (r34[i] - is34[i] * e01_34);
        }
        dist_spec_err *= e.lambda / minthr;
        dist2 += dist_spec_err;
    }
    return .{ .pass = dist2 <= dist1, .phase = phase, .err = dist2 - dist1, .dist1 = dist1, .dist2 = dist2, .ener01 = ener01 };
}

/// ff_aac_search_for_is.
pub fn searchForIs(e: *Encoder, cpe: *Cpe) void {
    const sce0 = &cpe.ch[0];
    const sce1 = &cpe.ch[1];
    var count: usize = 0;
    var prev_sf1: i32 = -1;
    var prev_bt: i32 = -1;
    var prev_is = false;
    const freq_mult: f32 = @as(f32, @floatFromInt(e.sample_rate)) / (1024.0 / @as(f32, @floatFromInt(sce0.ics.num_windows))) / 2.0;
    var nextband1: [128]u8 = undefined;
    if (!cpe.common_window) return;
    initNextbandMap(sce1, &nextband1);
    var w: usize = 0;
    while (w < sce0.ics.num_windows) : (w += sce0.ics.group_len[w]) {
        var start: usize = 0;
        for (0..sce0.ics.num_swb) |g| {
            const b = w * 16 + g;
            if (@as(f32, @floatFromInt(start)) * freq_mult > int_stereo_low_limit * (e.lambda / 170.0) and
                cpe.ch[0].band_type[b] != bt.noise and cpe.ch[0].zeroes[b] == 0 and
                cpe.ch[1].band_type[b] != bt.noise and cpe.ch[1].zeroes[b] == 0 and
                sfdeltaCanRemoveBand(sce1, &nextband1, prev_sf1, b))
            {
                var ener0: f32 = 0;
                var ener1: f32 = 0;
                var ener01: f32 = 0;
                var ener01p: f32 = 0;
                for (0..sce0.ics.group_len[w]) |w2| {
                    for (0..sce0.ics.swb_sizes[g]) |i| {
                        const coef0 = sce0.coeffs[start + (w + w2) * 128 + i];
                        const coef1 = sce1.coeffs[start + (w + w2) * 128 + i];
                        ener0 += coef0 * coef0;
                        ener1 += coef1 * coef1;
                        ener01 += (coef0 + coef1) * (coef0 + coef1);
                        ener01p += (coef0 - coef1) * (coef0 - coef1);
                    }
                }
                var ph_err1 = isEncodingErr(e, cpe, start, w, g, ener0, ener1, ener01p, -1);
                var ph_err2 = isEncodingErr(e, cpe, start, w, g, ener0, ener1, ener01, 1);
                const best = if (ph_err1.pass and ph_err1.err < ph_err2.err) &ph_err1 else &ph_err2;
                if (best.pass) {
                    cpe.is_mask[b] = 1;
                    cpe.ms_mask[b] = 0;
                    cpe.ch[0].is_ener[b] = @floatCast(@sqrt(@as(f64, ener0 / best.ener01)));
                    cpe.ch[1].is_ener[b] = ener0 / ener1;
                    cpe.ch[1].band_type[b] = if (best.phase > 0) bt.intensity else bt.intensity2;
                    if (prev_is and prev_bt != cpe.ch[1].band_type[b]) {
                        // Flip the M/S mask and take the other codebook,
                        // which codes it better.
                        cpe.ms_mask[b] = 1;
                        cpe.ch[1].band_type[b] = if (best.phase > 0) bt.intensity2 else bt.intensity;
                    }
                    prev_bt = cpe.ch[1].band_type[b];
                    count += 1;
                }
            }
            if (sce1.zeroes[b] == 0 and sce1.band_type[b] < bt.reserved) prev_sf1 = sce1.sf_idx[b];
            prev_is = cpe.is_mask[b] != 0;
            start += sce0.ics.swb_sizes[g];
        }
    }
    cpe.is_mode = @intFromBool(count != 0);
}
