// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/opus/silk.c (ff_silk_decode_superframe
// and its helpers), silk.h and mathops.h at the pinned reference revision.
// Copyright (c) 2012 Andrew D'Addesio
// Copyright (c) 2013-2014 Mozilla Corporation
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's SILK decoder (RFC 6716 section 4.2, TODO.md T28b), as the
//! reference build's C code runs it: the header bits and LBRR frames,
//! stereo prediction weights, gains, LSFs to LPC with stabilization,
//! pitch lags and LTP filters, the shell-coded excitation, then LTP and
//! LPC synthesis and the mid/side unmixing, at the SILK rate (8, 12 or
//! 16 kHz). Integer arithmetic is C's: truncation into int16_t, wrapping
//! where the C overflows on the reference platform, truncating division;
//! floating point keeps the C's types and order (vectors/silk.txt).

const std = @import("std");
const tab = @import("silk_tab.zig");
const opus_rc = @import("opus_rc.zig");

const RangeDecoder = opus_rc.RangeDecoder;

pub const history = 322;
const max_lpc = 16;
const ltp_order = 5;
/// The longest residual history (4.2.7.6.1).
const max_lag = 288 + ltp_order / 2;

pub const Error = error{
    /// FFmpeg's AVERROR(EINVAL): a bandwidth above wideband, more than two
    /// channels or more than 60 ms.
    InvalidArgument,
};

/// MUL64.
fn mul64(a: i64, b: i64) i64 {
    return a *% b;
}

/// MULH: the high 32 bits of a product, as an int.
fn mulh(a: i32, b: i32) i32 {
    return @truncate(mul64(a, b) >> 32);
}

/// MULL, an int64.
fn mull(a: i64, b: i64, s: u6) i64 {
    return mul64(a, b) >> s;
}

/// ROUND_MULL, an int64.
fn roundMull(a: i64, b: i64, s: u6) i64 {
    return ((mul64(a, b) >> (s - 1)) + 1) >> 1;
}

/// An int64 stored into an int32_t (C's conversion keeps the low bits).
fn int32(x: i64) i32 {
    return @truncate(x);
}

/// An int stored into an int16_t.
fn int16(x: i32) i16 {
    return @truncate(x);
}

/// av_clip_uintp2.
fn clipUintp2(a: i32, comptime p: u5) i32 {
    const mask: i32 = (1 << p) - 1;
    if (a & ~mask != 0) return (~a >> 31) & mask;
    return a;
}

/// av_clip_int16.
fn clipInt16(a: i32) i16 {
    return @intCast(std.math.clamp(a, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// av_clip.
fn clip(a: i32, lo: i32, hi: i32) i32 {
    return if (a < lo) lo else if (a > hi) hi else a;
}

/// av_clipf, NaN passing through.
fn clipf(a: f32, lo: f32, hi: f32) f32 {
    return if (a < lo) lo else if (a > hi) hi else a;
}

/// av_sat_sub32 on its int arguments.
fn satSub32(a: i32, b: i32) i32 {
    const d = @as(i64, a) - b;
    return @intCast(std.math.clamp(d, std.math.minInt(i32), std.math.maxInt(i32)));
}

const Frame = struct {
    coded: bool = false,
    log_gain: i32 = 0,
    nlsf: [16]i16 = @splat(0),
    lpc: [16]f32 = @splat(0),
    output: [2 * history]f32 = @splat(0),
    lpc_history: [2 * history]f32 = @splat(0),
    primarylag: i32 = 0,
    prev_voiced: bool = false,

    /// silk_flush_frame.
    fn flush(f: *Frame) void {
        if (!f.coded) return;
        f.* = .{};
    }
};

/// `SilkContext`.
pub const Decoder = struct {
    output_channels: u32,
    midonly: bool = false,
    subframes: u32 = 0,
    sflength: u32 = 0,
    flength: u32 = 0,
    nlsf_interp_factor: i32 = 0,
    /// 0 narrowband, 1 mediumband, 2 wideband.
    bandwidth: u2 = 0,
    wb: bool = false,
    frame: [2]Frame = .{ .{}, .{} },
    prev_stereo_weights: [2]f32 = .{ 0, 0 },
    stereo_weights: [2]f32 = .{ 0, 0 },
    prev_coded_channels: u32 = 0,

    /// ff_silk_init: `output_channels` 1 or 2.
    pub fn init(output_channels: u32) Error!Decoder {
        if (output_channels != 1 and output_channels != 2) return error.InvalidArgument;
        return .{ .output_channels = output_channels };
    }

    /// ff_silk_flush.
    pub fn flush(s: *Decoder) void {
        s.frame[0].flush();
        s.frame[1].flush();
        s.prev_stereo_weights = .{ 0, 0 };
    }

    /// ff_silk_decode_superframe: a SILK frame of `duration_ms` (10 to
    /// 60) at `bandwidth` (0 to 2) for `coded_channels`, into
    /// `output[0 .. output_channels]`; the samples per channel at the SILK
    /// rate.
    pub fn decodeSuperframe(s: *Decoder, rc: *RangeDecoder, output: [2][]f32, bandwidth: u32, coded_channels: u32, duration_ms: u32) Error!u32 {
        if (bandwidth > 2 or coded_channels > 2 or duration_ms > 60) return error.InvalidArgument;
        var active: [2][6]bool = @splat(@splat(false));
        var redundancy = [2]u32{ 0, 0 };
        const nb_frames: u32 = 1 + @as(u32, @intFromBool(duration_ms > 20)) + @intFromBool(duration_ms > 40);
        s.subframes = duration_ms / nb_frames / 5;
        s.sflength = 20 * (bandwidth + 2);
        s.flength = s.sflength * s.subframes;
        s.bandwidth = @intCast(bandwidth);
        s.wb = bandwidth == 2;

        // Flush the side channel when switching from mono to stereo.
        if (coded_channels > s.prev_coded_channels) s.frame[1].flush();
        s.prev_coded_channels = coded_channels;

        // The LP layer's header bits.
        for (0..coded_channels) |i| {
            for (0..nb_frames) |j| active[i][j] = rc.log(1) != 0;
            redundancy[i] = rc.log(1);
        }
        // The per-frame LBRR flags.
        for (0..coded_channels) |i| {
            if (redundancy[i] != 0 and duration_ms > 20) {
                redundancy[i] = rc.cdf(if (duration_ms == 40) &tab.silk_model_lbrr_flags_40 else &tab.silk_model_lbrr_flags_60);
            }
        }
        // The LBRR frames.
        for (0..nb_frames) |i| {
            for (0..coded_channels) |j| {
                if (redundancy[j] & (@as(u32, 1) << @intCast(i)) != 0) {
                    const active1 = !(j == 0 and redundancy[1] & (@as(u32, 1) << @intCast(i)) == 0);
                    s.decodeFrame(rc, @intCast(i), @intCast(j), coded_channels, true, active1, true);
                }
            }
            s.midonly = false;
        }

        for (0..nb_frames) |i| {
            var j: usize = 0;
            while (j < coded_channels and !s.midonly) : (j += 1) {
                const active1 = if (coded_channels > 1) active[1][i] else false;
                s.decodeFrame(rc, @intCast(i), @intCast(j), coded_channels, active[j][i], active1, false);
            }
            // Reset the side channel when it is not coded.
            if (s.midonly and s.frame[1].coded) s.frame[1].flush();

            const at = i * s.flength;
            if (coded_channels == 1 or s.output_channels == 1) {
                for (0..s.output_channels) |c| {
                    @memcpy(output[c][at..][0..s.flength], s.frame[0].output[history - s.flength - 2 ..][0..s.flength]);
                }
            } else {
                s.unmixMs(output[0][at..][0..s.flength], output[1][at..][0..s.flength]);
            }
            s.midonly = false;
        }
        return nb_frames * s.flength;
    }

    /// silk_unmix_ms: mid and side back to left and right, the weights
    /// interpolated over the first samples.
    fn unmixMs(s: *Decoder, l: []f32, r: []f32) void {
        const mid_base = history - s.flength;
        const mid = &s.frame[0].output;
        const side = &s.frame[1].output;
        const w0_prev = s.prev_stereo_weights[0];
        const w1_prev = s.prev_stereo_weights[1];
        const w0 = s.stereo_weights[0];
        const w1 = s.stereo_weights[1];
        const n1: usize = @intCast(tab.silk_stereo_interp_len[s.bandwidth]);
        const n1f: f32 = @floatFromInt(n1);
        for (0..s.flength) |i| {
            const m = mid_base + i;
            var interp0 = w0;
            var interp1 = w1;
            if (i < n1) {
                const fi: f32 = @floatFromInt(i);
                interp0 = w0_prev + fi * (w0 - w0_prev) / n1f;
                interp1 = w1_prev + fi * (w1 - w1_prev) / n1f;
            }
            const p0: f32 = @floatCast(0.25 * @as(f64, mid[m - 2] + 2 * mid[m - 1] + mid[m]));
            l[i] = clipf((1 + interp1) * mid[m - 1] + side[m - 1] + interp0 * p0, -1.0, 1.0);
            r[i] = clipf((1 - interp1) * mid[m - 1] - side[m - 1] - interp0 * p0, -1.0, 1.0);
        }
        s.prev_stereo_weights = s.stereo_weights;
    }

    /// silk_decode_frame: one channel's 10 or 20 ms frame.
    fn decodeFrame(s: *Decoder, rc: *RangeDecoder, frame_num: u32, channel: u32, coded_channels: u32, active: bool, active1: bool, redundant: bool) void {
        const frame = &s.frame[channel];
        const Subframe = struct { gain: f32 = 0, pitchlag: i32 = 0, ltptaps: [5]f32 = @splat(0) };
        var sf: [4]Subframe = @splat(.{});

        // The stereo weights.
        if (coded_channels == 2 and channel == 0) {
            const n: i32 = @intCast(rc.cdf(&tab.silk_model_stereo_s1));
            var wi: [2]i32 = undefined;
            var ws: [2]i32 = undefined;
            wi[0] = @as(i32, @intCast(rc.cdf(&tab.silk_model_stereo_s2))) + 3 * @divTrunc(n, 5);
            ws[0] = @intCast(rc.cdf(&tab.silk_model_stereo_s3));
            wi[1] = @as(i32, @intCast(rc.cdf(&tab.silk_model_stereo_s2))) + 3 * @rem(n, 5);
            ws[1] = @intCast(rc.cdf(&tab.silk_model_stereo_s3));
            var w: [2]i32 = undefined;
            for (0..2) |i| {
                const a: i32 = tab.silk_stereo_weights[@intCast(wi[i])];
                const b: i32 = tab.silk_stereo_weights[@intCast(wi[i] + 1)];
                w[i] = a + (((b - a) * 6554) >> 16) * (ws[i] * 2 + 1);
            }
            s.stereo_weights[0] = @floatCast(@as(f64, @floatFromInt(w[0] - w[1])) / 8192.0);
            s.stereo_weights[1] = @floatCast(@as(f64, @floatFromInt(w[1])) / 8192.0);
            // The mid-only flag.
            s.midonly = if (active1) false else rc.cdf(&tab.silk_model_mid_only) != 0;
        }

        // The frame type.
        var qoffset_high: u32 = undefined;
        var voiced: bool = undefined;
        if (!active) {
            qoffset_high = rc.cdf(&tab.silk_model_frame_type_inactive);
            voiced = false;
        } else {
            const t = rc.cdf(&tab.silk_model_frame_type_active);
            qoffset_high = t & 1;
            voiced = t >> 1 != 0;
        }
        const av: usize = @as(usize, @intFromBool(active)) + @intFromBool(voiced);

        // The subframes' quantization gains.
        for (0..s.subframes) |i| {
            var log_gain: i32 = undefined;
            if (i == 0 and (frame_num == 0 or !frame.coded)) {
                // Coded absolute.
                const x: i32 = @intCast(rc.cdf(&tab.silk_model_gain_highbits[av]));
                log_gain = (x << 3) | @as(i32, @intCast(rc.cdf(&tab.silk_model_gain_lowbits)));
                if (frame.coded) log_gain = @max(log_gain, frame.log_gain - 16);
            } else {
                // Coded relative.
                const delta_gain: i32 = @intCast(rc.cdf(&tab.silk_model_gain_delta));
                log_gain = clipUintp2(@max((delta_gain << 1) - 16, frame.log_gain + delta_gain - 4), 6);
            }
            frame.log_gain = log_gain;
            // 2^(x/128) with a Q7 input.
            log_gain = ((log_gain *% 0x1D1C71) >> 16) + 2090;
            const ipart: u5 = @intCast(log_gain >> 7);
            const fpart = log_gain & 127;
            const one: i32 = @as(i32, 1) << ipart;
            const lingain = one +% ((((-174 *% fpart *% (128 - fpart)) >> 16) + fpart) *% (one >> 7));
            sf[i].gain = @as(f32, @floatFromInt(lingain)) / 65536.0;
        }

        // The LPC filter.
        var lpc_leadin: [16]f32 = @splat(0);
        var lpc_body: [16]f32 = @splat(0);
        var has_lpc_leadin = false;
        const order = s.decodeLpc(frame, rc, &lpc_leadin, &lpc_body, &has_lpc_leadin, voiced);

        // The pitch lags of a voiced frame.
        if (voiced) {
            var lag_absolute = frame_num == 0 or !frame.prev_voiced;
            var primarylag: i32 = undefined;
            if (!lag_absolute) {
                const delta: i32 = @intCast(rc.cdf(&tab.silk_model_pitch_delta));
                if (delta != 0) {
                    primarylag = frame.primarylag + delta - 9;
                } else lag_absolute = true;
            }
            if (lag_absolute) {
                const highbits: i32 = @intCast(rc.cdf(&tab.silk_model_pitch_highbits));
                const lowbits: i32 = @intCast(switch (s.bandwidth) {
                    0 => rc.cdf(&tab.silk_model_pitch_lowbits_nb),
                    1 => rc.cdf(&tab.silk_model_pitch_lowbits_mb),
                    else => rc.cdf(&tab.silk_model_pitch_lowbits_wb),
                });
                primarylag = @as(i32, tab.silk_pitch_min_lag[s.bandwidth]) + highbits * @as(i32, tab.silk_pitch_scale[s.bandwidth]) + lowbits;
            }
            frame.primarylag = primarylag;

            var offsets: []const i8 = undefined;
            if (s.subframes == 2) {
                offsets = if (s.bandwidth == 0)
                    &tab.silk_pitch_offset_nb10ms[rc.cdf(&tab.silk_model_pitch_contour_nb10ms)]
                else
                    &tab.silk_pitch_offset_mbwb10ms[rc.cdf(&tab.silk_model_pitch_contour_mbwb10ms)];
            } else {
                offsets = if (s.bandwidth == 0)
                    &tab.silk_pitch_offset_nb20ms[rc.cdf(&tab.silk_model_pitch_contour_nb20ms)]
                else
                    &tab.silk_pitch_offset_mbwb20ms[rc.cdf(&tab.silk_model_pitch_contour_mbwb20ms)];
            }
            for (0..s.subframes) |i| {
                sf[i].pitchlag = clip(primarylag + offsets[i], tab.silk_pitch_min_lag[s.bandwidth], tab.silk_pitch_max_lag[s.bandwidth]);
            }

            // The LTP filters.
            const ltpfilter = rc.cdf(&tab.silk_model_ltp_filter);
            for (0..s.subframes) |i| {
                const index = switch (ltpfilter) {
                    0 => rc.cdf(&tab.silk_model_ltp_filter0_sel),
                    1 => rc.cdf(&tab.silk_model_ltp_filter1_sel),
                    else => rc.cdf(&tab.silk_model_ltp_filter2_sel),
                };
                const taps: []const i8 = switch (ltpfilter) {
                    0 => &tab.silk_ltp_filter0_taps[index],
                    1 => &tab.silk_ltp_filter1_taps[index],
                    else => &tab.silk_ltp_filter2_taps[index],
                };
                for (&sf[i].ltptaps, taps[0..5]) |*t, v| t.* = @as(f32, v) / 128.0;
            }
        }

        // The LTP scale factor.
        const ltpscale: f32 = if (voiced and frame_num == 0)
            @as(f32, @floatFromInt(tab.silk_ltp_scale_factor[rc.cdf(&tab.silk_model_ltp_scale_index)])) / 16384.0
        else
            15565.0 / 16384.0;

        // The excitation of the whole frame.
        var residual: [max_lag + history]f32 = @splat(0);
        s.decodeExcitation(rc, residual[max_lag..], qoffset_high, active, voiced);

        // The output is not needed.
        if (s.output_channels == channel or redundant) return;

        // Synthesis.
        for (0..s.subframes) |i| {
            const lpc_coeff = if (i < 2 and has_lpc_leadin) &lpc_leadin else &lpc_body;
            const dst_at: isize = @intCast(history + i * s.sflength);
            const res_at: isize = @intCast(max_lag + i * s.sflength);
            const lpc_at: isize = @intCast(history + i * s.sflength);
            const sfl: isize = @intCast(s.sflength);
            const ii: isize = @intCast(i);

            if (voiced) {
                var out_end: isize = undefined;
                var scale: f32 = undefined;
                if (i < 2 or s.nlsf_interp_factor == 4) {
                    out_end = -ii * sfl;
                    scale = ltpscale;
                } else {
                    out_end = -(ii - 2) * sfl;
                    scale = 1.0;
                }
                // A re-whitening filter, for a residual of the changed LPC
                // coefficients.
                var j: isize = -@as(isize, sf[i].pitchlag) - ltp_order / 2;
                while (j < out_end) : (j += 1) {
                    var sum = frame.output[@intCast(dst_at + j)];
                    for (0..order) |k| sum -= lpc_coeff[k] * frame.output[@intCast(dst_at + j - @as(isize, @intCast(k)) - 1)];
                    residual[@intCast(res_at + j)] = clipf(sum, -1.0, 1.0) * scale / sf[i].gain;
                }
                if (out_end != 0) {
                    const rescale = sf[i - 1].gain / sf[i].gain;
                    j = out_end;
                    while (j < 0) : (j += 1) residual[@intCast(res_at + j)] *= rescale;
                }
                // LTP synthesis.
                for (0..s.sflength) |ju| {
                    const jj: isize = @intCast(ju);
                    var sum = residual[@intCast(res_at + jj)];
                    for (0..ltp_order) |k| {
                        sum += sf[i].ltptaps[k] * residual[@intCast(res_at + jj - sf[i].pitchlag + ltp_order / 2 - @as(isize, @intCast(k)))];
                    }
                    residual[@intCast(res_at + jj)] = sum;
                }
            }

            // LPC synthesis.
            for (0..s.sflength) |ju| {
                const jj: isize = @intCast(ju);
                var sum = residual[@intCast(res_at + jj)] * sf[i].gain;
                for (1..order + 1) |k| sum += lpc_coeff[k - 1] * frame.lpc_history[@intCast(lpc_at + jj - @as(isize, @intCast(k)))];
                frame.lpc_history[@intCast(lpc_at + jj)] = sum;
                frame.output[@intCast(dst_at + jj)] = clipf(sum, -1.0, 1.0);
            }
        }

        frame.prev_voiced = voiced;
        std.mem.copyForwards(f32, frame.lpc_history[0..history], frame.lpc_history[s.flength..][0..history]);
        std.mem.copyForwards(f32, frame.output[0..history], frame.output[s.flength..][0..history]);
        frame.coded = true;
    }

    /// silk_decode_lpc: the LSF indices, the residual, the NLSFs
    /// stabilized, the interpolated lead-in, then both as LPC; the order.
    fn decodeLpc(s: *Decoder, frame: *Frame, rc: *RangeDecoder, lpc_leadin: *[16]f32, lpc: *[16]f32, has_lpc_leadin: *bool, voiced: bool) usize {
        const order: usize = if (s.wb) 16 else 10;
        var lsf_i2: [16]i8 = undefined;
        var lsf_res: [16]i16 = undefined;
        var nlsf: [16]i16 = @splat(0);

        // The stage-1 and stage-2 indices.
        const lsf_i1: usize = rc.cdf(&tab.silk_model_lsf_s1[@intFromBool(s.wb)][@intFromBool(voiced)]);
        for (0..order) |i| {
            const index = if (s.wb) tab.silk_lsf_s2_model_sel_wb[lsf_i1][i] else tab.silk_lsf_s2_model_sel_nbmb[lsf_i1][i];
            lsf_i2[i] = @intCast(@as(i32, @intCast(rc.cdf(&tab.silk_model_lsf_s2[index]))) - 4);
            if (lsf_i2[i] == -4) {
                lsf_i2[i] -= @intCast(rc.cdf(&tab.silk_model_lsf_s2_ext));
            } else if (lsf_i2[i] == 4) {
                lsf_i2[i] += @intCast(rc.cdf(&tab.silk_model_lsf_s2_ext));
            }
        }

        // The backwards prediction reversed.
        var i: usize = order;
        while (i > 0) {
            i -= 1;
            const qstep: i32 = if (s.wb) 9830 else 11796;
            lsf_res[i] = int16(@as(i32, lsf_i2[i]) * 1024);
            if (lsf_i2[i] < 0) {
                lsf_res[i] = int16(@as(i32, lsf_res[i]) + 102);
            } else if (lsf_i2[i] > 0) {
                lsf_res[i] = int16(@as(i32, lsf_res[i]) - 102);
            }
            lsf_res[i] = int16((@as(i32, lsf_res[i]) * qstep) >> 16);
            if (i + 1 < order) {
                const weight: i32 = if (s.wb)
                    tab.silk_lsf_pred_weights_wb[tab.silk_lsf_weight_sel_wb[lsf_i1][i]][i]
                else
                    tab.silk_lsf_pred_weights_nbmb[tab.silk_lsf_weight_sel_nbmb[lsf_i1][i]][i];
                lsf_res[i] = int16(@as(i32, lsf_res[i]) + ((@as(i32, lsf_res[i + 1]) * weight) >> 8));
            }
        }

        // The NLSFs from the indices.
        for (0..order) |k| {
            const cur: i32 = if (s.wb) tab.silk_lsf_codebook_wb[lsf_i1][k] else tab.silk_lsf_codebook_nbmb[lsf_i1][k];
            const weight: i32 = if (s.wb) tab.silk_model_lsf_weight_wb[lsf_i1][k] else tab.silk_model_lsf_weight_nbmb[lsf_i1][k];
            const value = cur * 128 + @divTrunc(@as(i32, lsf_res[k]) * 16384, weight);
            nlsf[k] = @intCast(clipUintp2(value, 15));
        }

        stabilizeLsf(&nlsf, order, if (s.wb) &tab.silk_lsf_min_spacing_wb else &tab.silk_lsf_min_spacing_nbmb);

        // An interpolation for the first two subframes, then both sets to
        // LPC.
        has_lpc_leadin.* = false;
        if (s.subframes == 4) {
            var offset: i32 = @intCast(rc.cdf(&tab.silk_model_lsf_interpolation_offset));
            if (offset != 4 and frame.coded) {
                has_lpc_leadin.* = true;
                if (offset != 0) {
                    var nlsf_leadin: [16]i16 = @splat(0);
                    for (0..order) |k| {
                        nlsf_leadin[k] = int16(@as(i32, frame.nlsf[k]) + (((@as(i32, nlsf[k]) - frame.nlsf[k]) * offset) >> 2));
                    }
                    lsf2lpc(&nlsf_leadin, lpc_leadin, order);
                } else {
                    lpc_leadin.* = frame.lpc;
                }
            } else offset = 4;
            s.nlsf_interp_factor = offset;
            lsf2lpc(&nlsf, lpc, order);
        } else {
            s.nlsf_interp_factor = 4;
            lsf2lpc(&nlsf, lpc, order);
        }
        @memcpy(frame.nlsf[0..order], nlsf[0..order]);
        @memcpy(frame.lpc[0..order], lpc[0..order]);
        return order;
    }

    /// silk_decode_excitation.
    fn decodeExcitation(s: *Decoder, rc: *RangeDecoder, excitationf: []f32, qoffset_high: u32, active: bool, voiced: bool) void {
        var pulsecount: [20]u8 = undefined;
        var lsbcount: [20]u8 = @splat(0);
        var excitation: [320]i32 = undefined;

        var seed: u32 = rc.cdf(&tab.silk_model_lcg_seed);
        const shellblocks: usize = tab.silk_shell_blocks[s.bandwidth][s.subframes >> 2];
        const ratelevel = rc.cdf(&tab.silk_model_exc_rate[@intFromBool(voiced)]);

        for (0..shellblocks) |i| {
            pulsecount[i] = @intCast(rc.cdf(&tab.silk_model_pulse_count[ratelevel]));
            if (pulsecount[i] == 17) {
                while (pulsecount[i] == 17) {
                    lsbcount[i] += 1;
                    if (lsbcount[i] == 10) break;
                    pulsecount[i] = @intCast(rc.cdf(&tab.silk_model_pulse_count[9]));
                }
                if (lsbcount[i] == 10) pulsecount[i] = @intCast(rc.cdf(&tab.silk_model_pulse_count[10]));
            }
        }

        // The pulse locations, by PVQ.
        for (0..shellblocks) |i| {
            if (pulsecount[i] != 0) {
                var location: usize = 16 * i;
                var branch: [4][2]i32 = undefined;
                branch[0][0] = pulsecount[i];
                countChildren(rc, 0, branch[0][0], &branch[1]);
                for (0..2) |b| {
                    countChildren(rc, 1, branch[1][b], &branch[2]);
                    for (0..2) |c| {
                        countChildren(rc, 2, branch[2][c], &branch[3]);
                        for (0..2) |d| {
                            countChildren(rc, 3, branch[3][d], excitation[location..][0..2]);
                            location += 2;
                        }
                    }
                }
            } else @memset(excitation[16 * i ..][0..16], 0);
        }

        // The least significant bits.
        for (0..shellblocks << 4) |i| {
            for (0..lsbcount[i >> 4]) |_| {
                excitation[i] = (excitation[i] << 1) | @as(i32, @intCast(rc.cdf(&tab.silk_model_excitation_lsb)));
            }
        }

        // The signs.
        for (0..shellblocks << 4) |i| {
            if (excitation[i] != 0) {
                const sign = rc.cdf(&tab.silk_model_excitation_sign[@as(usize, @intFromBool(active)) + @intFromBool(voiced)][qoffset_high][@min(pulsecount[i >> 4], 6)]);
                if (sign == 0) excitation[i] *= -1;
            }
        }

        // The excitation assembled.
        for (0..shellblocks << 4) |i| {
            const value = excitation[i];
            excitation[i] = (value *% 256) | @as(i32, tab.silk_quant_offset[@intFromBool(voiced)][qoffset_high]);
            if (value < 0) {
                excitation[i] += 20;
            } else if (value > 0) {
                excitation[i] -= 20;
            }
            // Samples inverted pseudorandomly.
            seed = 196314165 *% seed +% 907633515;
            if (seed & 0x80000000 != 0) excitation[i] *%= -1;
            seed +%= @bitCast(value);
            excitationf[i] = @as(f32, @floatFromInt(excitation[i])) / 8388608.0;
        }
    }
};

/// silk_count_children.
fn countChildren(rc: *RangeDecoder, model: usize, total: i32, child: *[2]i32) void {
    if (total != 0) {
        const t: usize = @intCast(total);
        child[0] = @intCast(rc.cdf(tab.silk_model_pulse_location[model][((t - 1 + 5) * (t - 1)) >> 1 ..]));
        child[1] = total - child[0];
    } else {
        child.* = .{ 0, 0 };
    }
}

/// silk_stabilize_lsf.
fn stabilizeLsf(nlsf: *[16]i16, order: usize, min_delta: []const u16) void {
    for (0..20) |_| {
        var k: usize = 0;
        var min_diff: i32 = 0;
        for (0..order + 1) |i| {
            const low: i32 = if (i != 0) nlsf[i - 1] else 0;
            const high: i32 = if (i != order) nlsf[i] else 32768;
            const diff = (high - low) - @as(i32, min_delta[i]);
            if (diff < min_diff) {
                min_diff = diff;
                k = i;
            }
        }
        // Stabilized.
        if (min_diff == 0) return;
        // Wiggle one or two LSFs.
        if (k == 0) {
            nlsf[0] = @intCast(min_delta[0]);
        } else if (k == order) {
            nlsf[order - 1] = @intCast(32768 - @as(i32, min_delta[order]));
        } else {
            var min_center: i32 = 0;
            var max_center: i32 = 32768;
            for (0..k) |i| min_center += min_delta[i];
            min_center += min_delta[k] >> 1;
            var i = order;
            while (i > k) : (i -= 1) max_center -= min_delta[i];
            max_center -= min_delta[k] >> 1;
            var center_val: i32 = @as(i32, nlsf[k - 1]) + nlsf[k];
            center_val = (center_val >> 1) + (center_val & 1);
            center_val = @min(max_center, @max(min_center, center_val));
            nlsf[k - 1] = int16(center_val - (min_delta[k] >> 1));
            nlsf[k] = int16(@as(i32, nlsf[k - 1]) + min_delta[k]);
        }
    }

    // The fall-back: sort (insertion, as the LSFs are nearly sorted).
    for (1..order) |i| {
        const value = nlsf[i];
        var j: isize = @as(isize, @intCast(i)) - 1;
        while (j >= 0 and nlsf[@intCast(j)] > value) : (j -= 1) nlsf[@intCast(j + 1)] = nlsf[@intCast(j)];
        nlsf[@intCast(j + 1)] = value;
    }
    // Pushed forwards.
    if (nlsf[0] < min_delta[0]) nlsf[0] = @intCast(min_delta[0]);
    for (1..order) |i| nlsf[i] = int16(@max(@as(i32, nlsf[i]), @min(@as(i32, nlsf[i - 1]) + min_delta[i], 32767)));
    // Pushed backwards.
    if (@as(i32, nlsf[order - 1]) > 32768 - @as(i32, min_delta[order])) nlsf[order - 1] = int16(32768 - @as(i32, min_delta[order]));
    var i: usize = order - 1;
    while (i > 0) {
        i -= 1;
        if (@as(i32, nlsf[i]) > @as(i32, nlsf[i + 1]) - min_delta[i + 1]) nlsf[i] = int16(@as(i32, nlsf[i + 1]) - min_delta[i + 1]);
    }
}

/// silk_is_lpc_stable: the Levinson recursion's checks.
fn isLpcStable(lpc: *const [16]i16, order: usize) bool {
    var lpc32: [2][16]i32 = undefined;
    var totalinvgain: i32 = 1 << 30;
    var row: usize = 0;
    var dc_resp: i32 = 0;
    for (0..order) |k| {
        dc_resp += lpc[k];
        lpc32[0][k] = @as(i32, lpc[k]) * 4096;
    }
    if (dc_resp >= 4096) return false;

    // Whether the prediction gain pushes a coefficient too far.
    var k: usize = order - 1;
    while (true) : (k -= 1) {
        const rk = lpc32[row][k];
        if (@abs(rk) > 16773022) return false;
        const rc: i32 = -(rk * 128);
        const gaindiv: i32 = (1 << 30) - mulh(rc, rc);
        totalinvgain = mulh(totalinvgain, gaindiv) << 2;
        if (k == 0) return totalinvgain >= 107374;

        // 1.0 / gaindiv, approximately.
        const fbits: u6 = @intCast(opus_rc.ilog(@intCast(gaindiv)));
        var gain: i32 = @divTrunc((1 << 29) - 1, gaindiv >> @intCast(fbits + 1 - 16));
        const err: i32 = int32(@as(i64, 1 << 29) - mull(gaindiv << @intCast(15 + 16 - @as(u32, fbits)), gain, 16));
        // C's int shift, which wraps on the reference platform.
        gain = @as(i32, @bitCast(@as(u32, @bitCast(gain)) << 16)) +% ((err *% gain) >> 13);

        // The next row.
        const prev = row;
        row = k & 1;
        for (0..k) |j| {
            const x = satSub32(lpc32[prev][j], int32(roundMull(lpc32[prev][k - j - 1], rc, 31)));
            const tmp = roundMull(x, gain, fbits);
            // RFC 8251 section 6: an overflow is an unstable filter.
            if (tmp < std.math.minInt(i32) or tmp > std.math.maxInt(i32)) return false;
            lpc32[row][j] = @intCast(tmp);
        }
    }
}

/// silk_lsp2poly.
fn lsp2poly(lsp: []const i32, pol: *[9]i32, half_order: usize) void {
    pol[0] = 65536;
    pol[1] = -lsp[0];
    for (1..half_order) |i| {
        pol[i + 1] = int32(@as(i64, pol[i - 1]) * 2 - roundMull(lsp[2 * i], pol[i], 16));
        var j = i;
        while (j > 1) : (j -= 1) pol[j] = int32(@as(i64, pol[j]) + (@as(i64, pol[j - 2]) - roundMull(lsp[2 * i], pol[j - 1], 16)));
        pol[1] -%= lsp[2 * i];
    }
}

/// silk_lsf2lpc: NLSFs to LPC coefficients, limited to int16 and made
/// stable by bandwidth expansion.
fn lsf2lpc(nlsf: *const [16]i16, lpcf: *[16]f32, order: usize) void {
    var lsp: [16]i32 = undefined;
    var p: [9]i32 = undefined;
    var q: [9]i32 = undefined;
    var lpc32: [16]i32 = undefined;
    var lpc: [16]i16 = @splat(0);

    // The LSFs to LSPs, 2 cos(LSF).
    for (0..order) |k| {
        const index: usize = @intCast(nlsf[k] >> 8);
        const offset: i32 = nlsf[k] & 255;
        const k2: usize = if (order == 10) tab.silk_lsf_ordering_nbmb[k] else tab.silk_lsf_ordering_wb[k];
        const c0: i32 = tab.silk_cosine[index];
        const c1: i32 = tab.silk_cosine[index + 1];
        lsp[k2] = c0 * 256;
        lsp[k2] += (c1 - c0) * offset;
        lsp[k2] = (lsp[k2] + 4) >> 3;
    }
    lsp2poly(lsp[0..], &p, order >> 1);
    lsp2poly(lsp[1..], &q, order >> 1);

    // A(z).
    for (0..order >> 1) |k| {
        const p_tmp = p[k + 1] +% p[k];
        const q_tmp = q[k + 1] -% q[k];
        lpc32[k] = -%q_tmp -% p_tmp;
        lpc32[order - k - 1] = q_tmp -% p_tmp;
    }

    // Each coefficient within an int16_t.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var maxabs: u32 = 0;
        var k: usize = 0;
        for (0..order) |j| {
            const x: u32 = @abs(lpc32[k]);
            if (x > maxabs) {
                maxabs = x;
                k = j;
            }
        }
        maxabs = (maxabs +% 16) >> 5;
        if (maxabs > 32767) {
            // Bandwidth expansion.
            maxabs = @min(maxabs, 163838);
            const chirp_base: u32 = 65470 -% ((maxabs - 32767) << 14) / ((maxabs * @as(u32, @intCast(k + 1))) >> 2);
            var chirp = chirp_base;
            for (0..order) |kk| {
                lpc32[kk] = int32(roundMull(lpc32[kk], chirp, 16));
                chirp = (chirp_base *% chirp +% 32768) >> 16;
            }
        } else break;
    }

    if (i == 10) {
        // Out of time: clamp.
        for (0..order) |k| {
            const x = (lpc32[k] +% 16) >> 5;
            lpc[k] = clipInt16(x);
            lpc32[k] = @as(i32, lpc[k]) << 5;
        }
    } else {
        for (0..order) |k| lpc[k] = int16((lpc32[k] +% 16) >> 5);
    }

    // Further bandwidth expansion while the filter is unstable.
    i = 1;
    while (i <= 16 and !isLpcStable(&lpc, order)) : (i += 1) {
        const chirp_base: u32 = 65536 - (@as(u32, 1) << @intCast(i));
        var chirp = chirp_base;
        for (0..order) |k| {
            lpc32[k] = int32(roundMull(lpc32[k], chirp, 16));
            lpc[k] = int16((lpc32[k] +% 16) >> 5);
            chirp = (chirp_base *% chirp +% 32768) >> 16;
        }
    }
    for (0..order) |k| lpcf[k] = @as(f32, @floatFromInt(lpc[k])) / 4096.0;
}

const testing = std.testing;

/// silk_vectors.c's generator.
const Generator = struct {
    state: u32,

    fn next(g: *Generator) u32 {
        g.state = g.state *% 1103515245 +% 12345;
        return g.state >> 16;
    }
};

test "superframes decode as FFmpeg's ff_silk_decode_superframe decodes them (vectors/silk.txt)" {
    var lines = std.mem.splitScalar(u8, @embedFile("../testing/vectors/silk.txt"), '\n');
    var frame: [1275]u8 = undefined;
    var out: [2][2880]f32 = undefined;
    var text: [256]u8 = undefined;
    var frames: usize = 0;
    const durations = [4]u32{ 10, 20, 40, 60 };
    for (1..49) |run| {
        var g: Generator = .{ .state = @intCast(run) };
        const output_channels = g.next() % 2 + 1;
        var d = try Decoder.init(output_channels);
        for (0..20) |f| {
            const flush = g.next() % 16 == 0;
            const channels: u32 = if (g.next() % 3 == 0) 1 else 2;
            const bandwidth = g.next() % 3;
            const duration = durations[g.next() % 4];
            const bytes: usize = if (g.next() % 8 == 0) g.next() % 4 else g.next() % 200 + 1;
            for (frame[0..bytes]) |*b| b.* = @truncate(g.next());

            if (flush) d.flush();
            var rc: RangeDecoder = try .init(frame[0..bytes]);
            out = @splat(@splat(0));
            const n = try d.decodeSuperframe(&rc, .{ &out[0], &out[1] }, bandwidth, channels, duration);

            var md5: std.crypto.hash.Md5 = .init(.{});
            for (out[0..output_channels]) |o| {
                for (o[0..n]) |v| {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, @bitCast(v), .little);
                    md5.update(&b);
                }
            }
            var digest: [16]u8 = undefined;
            md5.final(&digest);
            const got = try std.fmt.bufPrint(&text, "S {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {x}", .{
                run,      f,     @intFromBool(flush), channels, output_channels, bandwidth,
                duration, bytes, n,                   rc.range, rc.value,        rc.total_bits,
                digest,
            });
            testing.expectEqualStrings(lines.next().?, got) catch |err| {
                std.debug.print("run {d} frame {d}\n", .{ run, f });
                return err;
            };
            frames += 1;
        }
    }
    try testing.expectEqual(960, frames);
}
