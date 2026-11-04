// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/opus/dec_celt.c, celt.c (ff_celt_quant_bands,
// ff_celt_bitalloc), celt.h, pvq.c (the decoding path) and dsp.c
// (postfilter_c, deemphasis_c) at the pinned reference revision.
// Copyright (c) 2012 Andrew D'Addesio
// Copyright (c) 2013-2014 Mozilla Corporation
// Copyright (c) 2016 Rostislav Pehlivanov <atomnuker@gmail.com>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's CELT decoder (RFC 6716 section 4.3, TODO.md T28a), as the
//! reference build's C code runs it: the silence and post-filter flags,
//! coarse, fine and final energy, time-frequency changes, the bit
//! allocation, the bands' PVQ vectors with splitting, stereo coupling and
//! folding, anti-collapse, denormalization, the inverse MDCT (T27c's
//! 15 x 2^k transforms) with the windowed overlap-add, the pitch
//! post-filter and the de-emphasis, into 48 kHz float samples.
//!
//! Every float operation keeps the C order and precision (including its
//! double-precision steps), and `exp2f`, `sinf` and `cosf` are glibc's
//! (core/libm.zig), so the output is bit for bit the reference's
//! (vectors/celt.txt). Integer arithmetic follows C's: truncating
//! division, arithmetic shifts, and unsigned comparisons where the C
//! compares the range coder's unsigned bit counts.

const std = @import("std");
const tab = @import("celt_tab.zig");
const opus_rc = @import("opus_rc.zig");
const tx = @import("tx.zig");
const float_dsp = @import("float_dsp.zig");
const libm = @import("../core/libm.zig");

const RangeDecoder = opus_rc.RangeDecoder;

pub const short_blocksize = 120;
pub const overlap = short_blocksize;
pub const max_log_blocks = 3;
pub const max_frame_size = short_blocksize << max_log_blocks;
pub const max_bands = 21;
const vectors_count = 11;
const alloc_steps = 6;
const fine_offset = 21;
const max_fine_bits = 8;
const qtheta_offset = 4;
const qtheta_offset_twophase = 16;
const postfilter_minperiod = 15;
const energy_silence: f32 = -28.0;

pub const Spread = enum(u2) { none, light, normal, aggressive };

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA: a channel count, band range or frame
    /// size the decoder refuses.
    InvalidData,
};

/// FFMAX and FFMIN on floats, as the C macros compare (a NaN picks `b`).
fn fmax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn fmin(a: f32, b: f32) f32 {
    return if (a > b) b else a;
}

/// av_clip.
fn clip(a: i32, lo: i32, hi: i32) i32 {
    return if (a < lo) lo else if (a > hi) hi else a;
}

/// av_clip_uintp2(a, 14).
fn clipUintp2_14(a: i32) i32 {
    const mask: i32 = (1 << 14) - 1;
    if (a & ~mask != 0) return (~a >> 31) & mask;
    return a;
}

/// av_zero_extend: the low `bits` bits.
fn zeroExtend(a: u32, bits: u32) u32 {
    return a & ((@as(u32, 1) << @intCast(bits)) - 1);
}

/// A C int from the range coder's unsigned bit count.
fn signed(x: u32) i32 {
    return @bitCast(x);
}

pub const Block = struct {
    energy: [max_bands]f32,
    prev_energy: [2][max_bands]f32,
    collapse_masks: [max_bands]u8,
    /// The inverse MDCT output and the post-filter's history.
    buf: [2048]f32,
    coeffs: [max_frame_size]f32,
    pf_period_new: i32,
    pf_gains_new: [3]f32,
    pf_period: i32,
    pf_gains: [3]f32,
    pf_period_old: i32,
    pf_gains_old: [3]f32,
    emph_coeff: f32,
};

/// `CeltFrame` with its `CeltPVQ`, for decoding. Large (two blocks of
/// about 12 KiB); keep it in place.
pub const Decoder = struct {
    /// The inverse MDCTs for 120, 240, 480 and 960 coefficients.
    imdct: [4]tx.Mdct,
    block: [2]Block,
    output_channels: u32,
    apply_phase_inv: bool,

    channels: u32 = 0,
    size: u32 = 0,
    start_band: u32 = 0,
    end_band: u32 = 0,
    coded_bands: u32 = 0,
    transient: bool = false,
    alloc_trim: i32 = 0,
    blocks: u32 = 0,
    blocksize: u32 = 0,
    silence: bool = false,
    anticollapse_needed: i32 = 0,
    anticollapse: bool = false,
    intensity_stereo: i32 = 0,
    dual_stereo: bool = false,
    flushed: bool = false,
    seed: u32 = 0,
    spread: Spread = .normal,

    framebits: i32 = 0,
    remaining: i32 = 0,
    remaining2: i32 = 0,
    caps: [max_bands]i32 = undefined,
    fine_bits: [max_bands]i32 = undefined,
    fine_priority: [max_bands]i32 = undefined,
    pulses: [max_bands]i32 = undefined,
    tf_change: [max_bands]i32 = undefined,

    qcoeff: [256]i32 = undefined,
    hadamard_tmp: [256]f32 = undefined,

    /// ff_celt_init: `output_channels` 1 or 2 (FFmpeg's EINVAL otherwise);
    /// `apply_phase_inv` the decoder's option of that name.
    pub fn init(gpa: std.mem.Allocator, output_channels: u32, apply_phase_inv: bool) (tx.InitError || error{InvalidArgument})!Decoder {
        if (output_channels != 1 and output_channels != 2) return error.InvalidArgument;
        var d: Decoder = .{
            .imdct = undefined,
            .block = undefined,
            .output_channels = output_channels,
            .apply_phase_inv = apply_phase_inv,
        };
        var made: usize = 0;
        errdefer for (d.imdct[0..made]) |*m| m.deinit();
        for (&d.imdct, 0..) |*m, i| {
            m.* = try .init(gpa, @as(usize, short_blocksize) << @intCast(i), true, -1.0 / 32768.0);
            made += 1;
        }
        // av_mallocz.
        for (&d.block) |*b| b.* = std.mem.zeroes(Block);
        d.flush();
        return d;
    }

    pub fn deinit(d: *Decoder) void {
        for (&d.imdct) |*m| m.deinit();
        d.* = undefined;
    }

    /// ff_celt_flush: silent energy history, an empty overlap and filter.
    pub fn flush(d: *Decoder) void {
        if (d.flushed) return;
        for (&d.block) |*b| {
            for (&b.prev_energy[0], &b.prev_energy[1]) |*p0, *p1| {
                p0.* = energy_silence;
                p1.* = energy_silence;
            }
            @memset(&b.energy, 0);
            @memset(&b.buf, 0);
            b.pf_gains = .{ 0, 0, 0 };
            b.pf_gains_old = .{ 0, 0, 0 };
            b.pf_gains_new = .{ 0, 0, 0 };
            // 0.0f / ff_opus_deemph_weights[0].
            b.emph_coeff = 0.0 / tab.opus_deemph_weights[0];
        }
        d.seed = 0;
        d.flushed = true;
    }

    /// celt_rng: the noise generator's LCG.
    fn rng(d: *Decoder) u32 {
        d.seed = 1664525 *% d.seed +% 1013904223;
        return d.seed;
    }

    /// ff_celt_decode_frame: one CELT frame of `frame_size` samples (120,
    /// 240, 480 or 960) for `channels` coded channels, bands `start_band`
    /// to `end_band`, into `output[0 .. output_channels]`. `rc` holds the
    /// frame with its raw bits initialized (initRaw).
    pub fn decodeFrame(d: *Decoder, rc: *RangeDecoder, output: [2][]f32, channels: u32, frame_size: u32, start_band: u32, end_band: u32) Error!void {
        if (channels != 1 and channels != 2) return error.InvalidData;
        // FFmpeg accepts start_band == end_band, then divides by zero in
        // the band skipping; its callers never pass it.
        if (start_band >= end_band or end_band > max_bands) return error.InvalidData;
        const size: u32 = switch (frame_size) {
            120 => 0,
            240 => 1,
            480 => 2,
            960 => 3,
            else => return error.InvalidData,
        };
        for (output[0..d.output_channels]) |o| std.debug.assert(o.len >= frame_size);

        d.silence = false;
        d.transient = false;
        d.anticollapse = false;
        d.flushed = false;
        d.channels = channels;
        d.start_band = start_band;
        d.end_band = end_band;
        d.framebits = signed(rc.raw_left *% 8);
        d.size = size;

        for (d.block[0..channels]) |*b| {
            @memset(&b.coeffs, 0);
            @memset(&b.collapse_masks, 0);
        }

        var consumed = signed(rc.tell());
        if (consumed >= d.framebits) {
            d.silence = true;
        } else if (consumed == 1) {
            d.silence = rc.log(15) != 0;
        }
        if (d.silence) {
            consumed = d.framebits;
            rc.total_bits +%= @as(u32, @bitCast(d.framebits)) -% rc.tell();
        }

        consumed = d.parsePostfilter(rc, consumed);

        if (size != 0 and consumed + 3 <= d.framebits) d.transient = rc.log(3) != 0;

        d.blocks = if (d.transient) @as(u32, 1) << @intCast(size) else 1;
        d.blocksize = frame_size / d.blocks;
        const imdct = &d.imdct[if (d.transient) 0 else size];

        if (channels == 1) {
            for (&d.block[0].energy, d.block[1].energy) |*e0, e1| e0.* = fmax(e0.*, e1);
        }

        d.decodeCoarseEnergy(rc);
        d.decodeTfChanges(rc);
        d.bitalloc(rc);
        d.decodeFineEnergy(rc);
        d.quantBands(rc);

        if (d.anticollapse_needed != 0) d.anticollapse = rc.raw(1) != 0;

        d.decodeFinalEnergy(rc);

        for (0..channels) |i| {
            if (d.anticollapse) d.processAnticollapse(&d.block[i]);
            d.denormalize(&d.block[i]);
        }

        var downmix = false;
        if (d.output_channels < channels) {
            // FFALIGN(frame_size, 16) coefficients: past frame_size both
            // are zeros.
            const n = std.mem.alignForward(usize, frame_size, 16);
            float_dsp.fmacScalar(d.block[0].coeffs[0..n], d.block[1].coeffs[0..n], 1.0);
            downmix = true;
        } else if (d.output_channels > channels) {
            @memcpy(d.block[1].coeffs[0..frame_size], d.block[0].coeffs[0..frame_size]);
        }

        if (d.silence) {
            for (&d.block) |*b| {
                @memset(&b.energy, energy_silence);
                @memset(&b.coeffs, 0);
            }
        }

        for (0..d.output_channels) |i| {
            const b = &d.block[i];
            // The inverse MDCT of each block, interleaved by `blocks`,
            // then the overlap-add with the previous one.
            for (0..d.blocks) |j| {
                const dst = b.buf[1024 + j * d.blocksize ..];
                imdct.runInverseStrided(dst[overlap / 2 ..][0..d.blocksize], b.coeffs[j..][0 .. (d.blocksize - 1) * d.blocks + 1], d.blocks);
                float_dsp.fmulWindow(dst, dst, dst[overlap / 2 ..], tab.celt_window_padded[8..], overlap / 2);
            }
            if (downmix) float_dsp.fmulScalar(b.buf[1024..][0..frame_size], b.buf[1024..][0..frame_size], 0.5);

            d.postfilter(b);

            // deemphasis_c.
            const c = tab.opus_deemph_weights[0];
            var coeff = b.emph_coeff;
            for (output[i][0..frame_size], b.buf[1024 - frame_size ..][0..frame_size]) |*y, x| {
                y.* = x + coeff * c;
                coeff = y.*;
            }
            b.emph_coeff = if (std.math.isNormal(coeff)) coeff else 0.0;
        }

        if (channels == 1) d.block[1].energy = d.block[0].energy;

        for (&d.block) |*b| {
            if (!d.transient) {
                b.prev_energy[1] = b.prev_energy[0];
                b.prev_energy[0] = b.energy;
            } else {
                for (&b.prev_energy[0], b.energy) |*p, e| p.* = fmin(p.*, e);
            }
            for (0..start_band) |j| {
                b.prev_energy[0][j] = energy_silence;
                b.energy[j] = 0.0;
            }
            for (end_band..max_bands) |j| {
                b.prev_energy[0][j] = energy_silence;
                b.energy[j] = 0.0;
            }
        }

        d.seed = rc.range;
    }

    /// parse_postfilter: the period, gain and taps, for both blocks.
    fn parsePostfilter(d: *Decoder, rc: *RangeDecoder, consumed_in: i32) i32 {
        var consumed = consumed_in;
        d.block[0].pf_gains_new = .{ 0, 0, 0 };
        d.block[1].pf_gains_new = .{ 0, 0, 0 };
        if (d.start_band == 0 and consumed + 16 <= d.framebits) {
            if (rc.log(1) != 0) {
                const octave = rc.uint(6);
                const period: i32 = (@as(i32, 16) << @intCast(octave)) + signed(rc.raw(4 + octave)) - 1;
                const gain: f32 = 0.09375 * @as(f32, @floatFromInt(rc.raw(3) + 1));
                const tapset: usize = if (rc.tell() + 2 <= @as(u32, @bitCast(d.framebits))) rc.cdf(&tab.celt_model_tapset) else 0;
                for (&d.block) |*b| {
                    b.pf_period_new = @max(period, postfilter_minperiod);
                    for (&b.pf_gains_new, tab.celt_postfilter_taps[tapset]) |*g, t| g.* = gain * t;
                }
            }
            consumed = signed(rc.tell());
        }
        return consumed;
    }

    /// celt_decode_coarse_energy: Laplace-coded deltas predicted in time
    /// (alpha) and frequency (beta).
    fn decodeCoarseEnergy(d: *Decoder, rc: *RangeDecoder) void {
        var prev = [2]f32{ 0, 0 };
        var alpha = tab.celt_alpha_coef[d.size];
        var beta = tab.celt_beta_coef[d.size];
        var model: []const u8 = &tab.celt_coarse_energy_dist[d.size][0];
        const framebits: u32 = @bitCast(d.framebits);
        // Intra frame.
        if (rc.tell() +% 3 <= framebits and rc.log(3) != 0) {
            alpha = 0.0;
            beta = 1.0 - (4915.0 / 32768.0);
            model = &tab.celt_coarse_energy_dist[d.size][1];
        }
        for (0..max_bands) |i| {
            for (0..d.channels) |j| {
                const b = &d.block[j];
                if (i < d.start_band or i >= d.end_band) {
                    b.energy[i] = 0.0;
                    continue;
                }
                const available = signed(framebits -% rc.tell());
                var value: f32 = undefined;
                if (available >= 15) {
                    // The usize keeps @min from narrowing to u5 before the shift.
                    const k = @as(usize, @min(i, 20)) << 1;
                    value = @floatFromInt(rc.laplace(@as(u32, model[k]) << 7, @as(i32, model[k + 1]) << 6));
                } else if (available >= 2) {
                    // ff_celt_model_energy_small is ff_celt_model_tapset.
                    const x = signed(rc.cdf(&tab.celt_model_tapset));
                    value = @floatFromInt((x >> 1) ^ -(x & 1));
                } else if (available >= 1) {
                    value = -@as(f32, @floatFromInt(rc.log(1)));
                } else {
                    value = -1;
                }
                b.energy[i] = fmax(-9.0, b.energy[i]) * alpha + prev[j] + value;
                prev[j] += beta * value;
            }
        }
    }

    fn decodeFineEnergy(d: *Decoder, rc: *RangeDecoder) void {
        for (d.start_band..d.end_band) |i| {
            const fb = d.fine_bits[i];
            if (fb == 0) continue;
            for (d.block[0..d.channels]) |*b| {
                const q2 = rc.raw(@intCast(fb));
                const offset = (@as(f32, @floatFromInt(q2)) + 0.5) * @as(f32, @floatFromInt(@as(i32, 1) << @intCast(14 - fb))) / 16384.0 - 0.5;
                b.energy[i] += offset;
            }
        }
    }

    fn decodeFinalEnergy(d: *Decoder, rc: *RangeDecoder) void {
        var bits_left = d.framebits -% signed(rc.tell());
        for (0..2) |priority| {
            var i = d.start_band;
            while (i < d.end_band and bits_left >= signed(d.channels)) : (i += 1) {
                if (d.fine_priority[i] != priority or d.fine_bits[i] >= max_fine_bits) continue;
                for (d.block[0..d.channels]) |*b| {
                    const q2 = rc.raw(1);
                    const offset = (@as(f32, @floatFromInt(q2)) - 0.5) * @as(f32, @floatFromInt(@as(i32, 1) << @intCast(14 - d.fine_bits[i] - 1))) / 16384.0;
                    b.energy[i] += offset;
                    bits_left -= 1;
                }
            }
        }
    }

    fn decodeTfChanges(d: *Decoder, rc: *RangeDecoder) void {
        var diff: u32 = 0;
        var tf_select: usize = 0;
        var tf_changed: u32 = 0;
        var bits: u5 = if (d.transient) 2 else 4;
        var consumed = signed(rc.tell());
        const tf_select_bit: i32 = @intFromBool(d.size != 0 and consumed + bits + 1 <= d.framebits);
        for (d.start_band..d.end_band) |i| {
            if (consumed + bits + tf_select_bit <= d.framebits) {
                diff ^= rc.log(bits);
                consumed = signed(rc.tell());
                tf_changed |= diff;
            }
            d.tf_change[i] = @intCast(diff);
            bits = if (d.transient) 4 else 5;
        }
        const sel = &tab.celt_tf_select[d.size][@intFromBool(d.transient)];
        if (tf_select_bit != 0 and sel[0][tf_changed] != sel[1][tf_changed]) tf_select = rc.log(1);
        for (d.tf_change[d.start_band..d.end_band]) |*t| t.* = sel[tf_select][@intCast(t.*)];
    }

    /// celt_denormalize: each band times 2^(energy + mean), the exponent
    /// capped at 32.
    fn denormalize(d: *Decoder, b: *Block) void {
        for (d.start_band..d.end_band) |i| {
            const dst = b.coeffs[@as(usize, tab.celt_freq_bands[i]) << @intCast(d.size) ..][0 .. @as(usize, tab.celt_freq_range[i]) << @intCast(d.size)];
            const log_norm = b.energy[i] + tab.celt_mean_energy[i];
            const norm = libm.exp2f(fmin(log_norm, 32.0));
            for (dst) |*v| v.* *= norm;
        }
    }

    /// process_anticollapse: noise into the short blocks a band left empty.
    fn processAnticollapse(d: *Decoder, b: *Block) void {
        for (d.start_band..d.end_band) |i| {
            var renormalize = false;
            const n: i32 = @as(i32, tab.celt_freq_range[i]) << @intCast(d.size);
            // Depth in 1/8 bits.
            const depth = @divTrunc(1 + d.pulses[i], n);
            const thresh = libm.exp2f(@floatCast(-1.0 - @as(f64, 0.125 * @as(f32, @floatFromInt(depth)))));
            const sqrt_1 = 1.0 / @sqrt(@as(f32, @floatFromInt(n)));
            const xptr = b.coeffs[@as(usize, tab.celt_freq_bands[i]) << @intCast(d.size) ..];

            var prev = [2]f32{ b.prev_energy[0][i], b.prev_energy[1][i] };
            if (d.channels == 1) {
                const b1 = &d.block[1];
                prev[0] = fmax(prev[0], b1.prev_energy[0][i]);
                prev[1] = fmax(prev[1], b1.prev_energy[1][i]);
            }
            var ediff = b.energy[i] - fmin(prev[0], prev[1]);
            ediff = fmax(0, ediff);

            // r times 2 or 2 sqrt(2) by the frame size: short blocks have
            // less energy than long ones.
            var r = libm.exp2f(1 - ediff);
            if (d.size == 3) r = @floatCast(@as(f64, r) * std.math.sqrt2);
            r = fmin(thresh, r) * sqrt_1;
            for (0..@as(usize, 1) << @intCast(d.size)) |k| {
                if (b.collapse_masks[i] & (@as(u32, 1) << @intCast(k)) == 0) {
                    for (0..tab.celt_freq_range[i]) |j| {
                        xptr[(j << @intCast(d.size)) + k] = if (d.rng() & 0x8000 != 0) r else -r;
                    }
                    renormalize = true;
                }
            }
            if (renormalize) renormalizeVector(xptr[0..@intCast(n)], 1.0);
        }
    }

    /// celt_postfilter_apply_transition: the old filter fading into the
    /// current one over the overlap, in double precision where the C is.
    fn postfilterTransition(b: *Block, at: usize) void {
        const t0: isize = b.pf_period_old;
        const t1: isize = b.pf_period;
        if (b.pf_gains[0] == 0.0 and b.pf_gains_old[0] == 0.0) return;
        const g00: f64 = b.pf_gains_old[0];
        const g01: f64 = b.pf_gains_old[1];
        const g02: f64 = b.pf_gains_old[2];
        const g10 = b.pf_gains[0];
        const g11 = b.pf_gains[1];
        const g12 = b.pf_gains[2];
        const data = &b.buf;
        const base: isize = @intCast(at);
        const get = struct {
            fn get(buf: *const [2048]f32, idx: isize) f32 {
                return buf[@intCast(idx)];
            }
        }.get;
        const getd = struct {
            fn getd(buf: *const [2048]f32, idx: isize) f64 {
                return buf[@intCast(idx)];
            }
        }.getd;
        var x1 = get(data, base - t1 + 1);
        var x2 = get(data, base - t1);
        var x3 = get(data, base - t1 - 1);
        var x4 = get(data, base - t1 - 2);
        for (0..overlap) |iu| {
            const i: isize = @intCast(iu);
            const w = tab.celt_window2[iu];
            const x0 = get(data, base + i - t1 + 2);
            const omw: f64 = 1.0 - @as(f64, w);
            const sum = omw * g00 * getd(data, base + i - t0) +
                omw * g01 * @as(f64, get(data, base + i - t0 - 1) + get(data, base + i - t0 + 1)) +
                omw * g02 * @as(f64, get(data, base + i - t0 - 2) + get(data, base + i - t0 + 2)) +
                @as(f64, w * g10 * x2) +
                @as(f64, w * g11 * (x1 + x3)) +
                @as(f64, w * g12 * (x0 + x4));
            const out = &data[@intCast(base + i)];
            out.* = @floatCast(@as(f64, out.*) + sum);
            x4 = x3;
            x3 = x2;
            x2 = x1;
            x1 = x0;
        }
    }

    /// celt_postfilter with postfilter_c.
    fn postfilter(d: *Decoder, b: *Block) void {
        const len = d.blocksize * d.blocks;
        postfilterTransition(b, 1024);
        b.pf_period_old = b.pf_period;
        b.pf_gains_old = b.pf_gains;
        b.pf_period = b.pf_period_new;
        b.pf_gains = b.pf_gains_new;
        if (len > overlap) {
            postfilterTransition(b, 1024 + overlap);
            if (b.pf_gains[0] > std.math.floatEps(f32) and len > 2 * overlap) {
                const period: usize = @intCast(b.pf_period);
                const g0 = b.pf_gains[0];
                const g1 = b.pf_gains[1];
                const g2 = b.pf_gains[2];
                const data = b.buf[1024 + 2 * overlap - period - 2 ..];
                var x4 = data[0];
                var x3 = data[1];
                var x2 = data[2];
                var x1 = data[3];
                for (0..len - 2 * overlap) |i| {
                    const x0 = data[i + 4];
                    data[period + 2 + i] += g0 * x2 + g1 * (x1 + x3) + g2 * (x0 + x4);
                    x4 = x3;
                    x3 = x2;
                    x2 = x1;
                    x1 = x0;
                }
            }
            b.pf_period_old = b.pf_period;
            b.pf_gains_old = b.pf_gains;
        }
        std.mem.copyForwards(f32, b.buf[0 .. 1024 + overlap / 2], b.buf[len..][0 .. 1024 + overlap / 2]);
    }

    /// NORMC: bits scaled by the channels and the frame size.
    fn normc(d: *const Decoder, bits: i32) i32 {
        return bits << @intCast(d.channels - 1) << @intCast(d.size) >> 2;
    }

    /// ff_celt_bitalloc, decoding: spread, band boosts, the allocation
    /// trim, reservations, the static allocation's bisections, band
    /// skipping, intensity and dual stereo, then the split between fine
    /// energy and PVQ.
    fn bitalloc(d: *Decoder, rc: *RangeDecoder) void {
        const freq_range = &tab.celt_freq_range;
        const freq_bands = &tab.celt_freq_bands;
        const channels: i32 = @intCast(d.channels);
        const size = d.size;
        const start = d.start_band;
        const end = d.end_band;
        var skip_startband = start;
        var skip_bit: i32 = 0;
        var intensitystereo_bit: i32 = 0;
        var dualstereo_bit: i32 = 0;
        var dynalloc: i32 = 6;
        var extrabits: i32 = 0;
        var boost: [max_bands]i32 = @splat(0);
        var trim_offset: [max_bands]i32 = undefined;
        var threshold: [max_bands]i32 = undefined;
        var bits1: [max_bands]i32 = undefined;
        var bits2: [max_bands]i32 = undefined;

        // Spread.
        if (rc.tell() +% 4 <= @as(u32, @bitCast(d.framebits))) {
            d.spread = @fromBackingInt(@intCast(rc.cdf(&tab.celt_model_spread)));
        } else {
            d.spread = .normal;
        }

        // Static allocation caps.
        for (&d.caps, 0..) |*cap, i| {
            cap.* = d.normc((@as(i32, tab.celt_static_caps[size][d.channels - 1][i]) + 64) * freq_range[i]);
        }

        // Band boosts.
        var tbits_8ths: i32 = d.framebits << 3;
        for (start..end) |i| {
            var quanta: i32 = @as(i32, freq_range[i]) << @intCast(d.channels - 1) << @intCast(size);
            var b_dynalloc = dynalloc;
            quanta = @min(quanta << 3, @max(6 << 3, quanta));
            while (rc.tellFrac() +% @as(u32, @bitCast(b_dynalloc << 3)) < @as(u32, @bitCast(tbits_8ths)) and boost[i] < d.caps[i]) {
                const is_boost = rc.log(@intCast(b_dynalloc));
                if (is_boost == 0) break;
                boost[i] += quanta;
                tbits_8ths -= quanta;
                b_dynalloc = 1;
            }
            if (boost[i] != 0) dynalloc = @max(dynalloc - 1, 2);
        }

        // Allocation trim.
        d.alloc_trim = 5;
        if (rc.tellFrac() +% (6 << 3) <= @as(u32, @bitCast(tbits_8ths))) d.alloc_trim = signed(rc.cdf(&tab.celt_model_alloc_trim));

        // Anti-collapse bit reservation.
        tbits_8ths = signed(@as(u32, @bitCast(d.framebits << 3)) -% rc.tellFrac() -% 1);
        d.anticollapse_needed = 0;
        if (d.transient and size >= 2 and tbits_8ths >= @as(i32, @intCast((size + 2) << 3))) d.anticollapse_needed = 1 << 3;
        tbits_8ths -= d.anticollapse_needed;

        // Band skip bit reservation.
        if (tbits_8ths >= 1 << 3) skip_bit = 1 << 3;
        tbits_8ths -= skip_bit;

        // Intensity and dual stereo bit reservations.
        if (d.channels == 2) {
            intensitystereo_bit = tab.celt_log2_frac[end - start];
            if (intensitystereo_bit <= tbits_8ths) {
                tbits_8ths -= intensitystereo_bit;
                if (tbits_8ths >= 1 << 3) {
                    dualstereo_bit = 1 << 3;
                    tbits_8ths -= 1 << 3;
                }
            } else {
                intensitystereo_bit = 0;
            }
        }

        // Trim offsets.
        for (start..end) |i| {
            const trim: i32 = d.alloc_trim - 5 - @as(i32, @intCast(size));
            const band: i32 = @as(i32, freq_range[i]) * (@as(i32, @intCast(end - i)) - 1);
            const duration = size + 3;
            const scale = duration + d.channels - 1;
            // The PVQ's minimum: below it the band is skipped.
            threshold[i] = @max(3 * @as(i32, freq_range[i]) << @intCast(duration) >> 4, channels << 3);
            trim_offset[i] = trim * (band << @intCast(scale)) >> 6;
            if (@as(u32, freq_range[i]) << @intCast(size) == 1) trim_offset[i] -= channels << 3;
        }

        // Bisection over the static allocation vectors.
        var low: i32 = 1;
        var high: i32 = vectors_count - 1;
        while (low <= high) {
            const center = (low + high) >> 1;
            var done = false;
            var total: i32 = 0;
            var i = end;
            while (i > start) {
                i -= 1;
                var bandbits = d.normc(@as(i32, freq_range[i]) * tab.celt_static_alloc[@intCast(center)][i]);
                if (bandbits != 0) bandbits = @max(bandbits + trim_offset[i], 0);
                bandbits += boost[i];
                if (bandbits >= threshold[i] or done) {
                    done = true;
                    total += @min(bandbits, d.caps[i]);
                } else if (bandbits >= channels << 3) {
                    total += channels << 3;
                }
            }
            if (total > tbits_8ths) high = center - 1 else low = center + 1;
        }
        high = low;
        low -= 1;

        for (start..end) |i| {
            bits1[i] = d.normc(@as(i32, freq_range[i]) * tab.celt_static_alloc[@intCast(low)][i]);
            bits2[i] = if (high >= vectors_count) d.caps[i] else d.normc(@as(i32, freq_range[i]) * tab.celt_static_alloc[@intCast(high)][i]);
            if (bits1[i] != 0) bits1[i] = @max(bits1[i] + trim_offset[i], 0);
            if (bits2[i] != 0) bits2[i] = @max(bits2[i] + trim_offset[i], 0);
            if (low != 0) bits1[i] += boost[i];
            bits2[i] += boost[i];
            if (boost[i] != 0) skip_startband = @intCast(i);
            bits2[i] = @max(bits2[i] - bits1[i], 0);
        }

        // Bisection between the two vectors.
        low = 0;
        high = 1 << alloc_steps;
        for (0..alloc_steps) |_| {
            const center = (low + high) >> 1;
            var done = false;
            var total: i32 = 0;
            var j = end;
            while (j > start) {
                j -= 1;
                const bandbits = bits1[j] + (center * bits2[j] >> alloc_steps);
                if (bandbits >= threshold[j] or done) {
                    done = true;
                    total += @min(bandbits, d.caps[j]);
                } else if (bandbits >= channels << 3) {
                    total += channels << 3;
                }
            }
            if (total > tbits_8ths) high = center else low = center;
        }

        var done = false;
        var total: i32 = 0;
        {
            var i = end;
            while (i > start) {
                i -= 1;
                var bandbits = bits1[i] + (low * bits2[i] >> alloc_steps);
                if (bandbits >= threshold[i] or done) {
                    done = true;
                } else {
                    bandbits = if (bandbits >= channels << 3) channels << 3 else 0;
                }
                bandbits = @min(bandbits, d.caps[i]);
                d.pulses[i] = bandbits;
                total += bandbits;
            }
        }

        // Band skipping.
        d.coded_bands = end;
        while (true) : (d.coded_bands -= 1) {
            const j = d.coded_bands - 1;
            if (j == skip_startband) {
                // The remaining bands are all coded.
                tbits_8ths += skip_bit;
                break;
            }
            // The bits available for coding "do not skip" markers.
            var remaining = tbits_8ths - total;
            const span: i32 = @as(i32, freq_bands[j + 1]) - freq_bands[start];
            const bandbits = @divTrunc(remaining, span);
            remaining -= bandbits * span;
            var allocation = d.pulses[j] + bandbits * freq_range[j];
            allocation += @max(remaining - (@as(i32, freq_bands[j]) - freq_bands[start]), 0);

            // A marker only where the allocation reaches the threshold.
            if (allocation >= @max(threshold[j], (channels + 1) << 3)) {
                if (rc.log(1) != 0) break;
                total += 1 << 3;
                allocation -= 1 << 3;
            }

            // The band is skipped: reclaim its bits.
            total -= d.pulses[j];
            if (intensitystereo_bit != 0) {
                total -= intensitystereo_bit;
                intensitystereo_bit = tab.celt_log2_frac[j - start];
                total += intensitystereo_bit;
            }
            d.pulses[j] = if (allocation >= channels << 3) channels << 3 else 0;
            total += d.pulses[j];
        }

        // Intensity stereo's start band.
        d.intensity_stereo = 0;
        d.dual_stereo = false;
        if (intensitystereo_bit != 0) d.intensity_stereo = @intCast(start + rc.uint(d.coded_bands + 1 - start));

        // The dual stereo flag.
        if (d.intensity_stereo <= start) {
            // No intensity stereo means no dual stereo.
            tbits_8ths += dualstereo_bit;
        } else if (dualstereo_bit != 0) {
            d.dual_stereo = rc.log(1) != 0;
        }

        // The remaining bits go to the lower bands.
        var remaining = tbits_8ths - total;
        const span: i32 = @as(i32, freq_bands[d.coded_bands]) - freq_bands[start];
        const bandbits = @divTrunc(remaining, span);
        remaining -= bandbits * span;
        for (start..d.coded_bands) |i| {
            const bits = @min(remaining, freq_range[i]);
            d.pulses[i] += bits + bandbits * freq_range[i];
            remaining -= bits;
        }

        // The final split between fine energy and PVQ.
        var i = start;
        while (i < d.coded_bands) : (i += 1) {
            const n: i32 = @as(i32, freq_range[i]) << @intCast(size);
            const prev_extra = extrabits;
            d.pulses[i] += extrabits;
            if (n > 1) {
                extrabits = @max(d.pulses[i] - d.caps[i], 0);
                d.pulses[i] -= extrabits;
                // Degrees of freedom: intensity stereo adds one.
                const dof: i32 = n * channels + @intFromBool(d.channels == 2 and n > 2 and !d.dual_stereo and i < d.intensity_stereo);
                const temp = dof * (@as(i32, tab.celt_log_freq_range[i]) + @as(i32, @intCast(size << 3)));
                var offset = (temp >> 1) - dof * fine_offset;
                // dof 2 is the only case that does not fit the model.
                if (n == 2) offset += dof << 1;
                // An extra bias for the first and second pulses.
                if (d.pulses[i] + offset < 2 * (dof << 3)) {
                    offset += temp >> 2;
                } else if (d.pulses[i] + offset < 3 * (dof << 3)) {
                    offset += temp >> 3;
                }
                const fine_bits = @divTrunc(d.pulses[i] + offset + (dof << 2), dof << 3);
                var max_bits = @min((d.pulses[i] >> 3) >> @intCast(d.channels - 1), max_fine_bits);
                max_bits = @max(max_bits, 0);
                d.fine_bits[i] = clip(fine_bits, 0, max_bits);
                // Rounded down or capped: priority in the final pass.
                d.fine_priority[i] = @intFromBool(d.fine_bits[i] * (dof << 3) >= d.pulses[i] + offset);
                // The rest goes to PVQ.
                d.pulses[i] -= d.fine_bits[i] << @intCast(d.channels - 1) << 3;
            } else {
                // All to fine energy but the sign bit.
                extrabits = @max(d.pulses[i] - (channels << 3), 0);
                d.pulses[i] -= extrabits;
                d.fine_bits[i] = 0;
                d.fine_priority[i] = 1;
            }
            // A few extra fine energy bits back to this band.
            if (extrabits > 0) {
                var fineextra = @min(extrabits >> @intCast(d.channels + 2), max_fine_bits - d.fine_bits[i]);
                d.fine_bits[i] += fineextra;
                fineextra <<= @intCast(d.channels + 2);
                d.fine_priority[i] = @intFromBool(fineextra >= extrabits - prev_extra);
                extrabits -= fineextra;
            }
        }
        d.remaining = extrabits;

        // Skipped bands put all their bits into fine energy.
        while (i < end) : (i += 1) {
            d.fine_bits[i] = d.pulses[i] >> @intCast(d.channels - 1) >> 3;
            d.pulses[i] = 0;
            d.fine_priority[i] = @intFromBool(d.fine_bits[i] < 1);
        }
    }

    /// ff_celt_quant_bands, decoding: each band's share of the bits, its
    /// folding source, then its PVQ vectors.
    fn quantBands(d: *Decoder, rc: *RangeDecoder) void {
        const freq_bands = &tab.celt_freq_bands;
        const freq_range = &tab.celt_freq_range;
        var lowband_scratch: [8 * 22]f32 = undefined;
        // C leaves these uninitialized; no value is read before written.
        var norm: [2 * 8 * 100]f32 = @splat(0);
        const norm1 = norm[0 .. 8 * 100];
        const norm2 = norm[8 * 100 ..];
        const size: u5 = @intCast(d.size);
        const totalbits = (d.framebits << 3) - d.anticollapse_needed;
        var update_lowband = true;
        var lowband_offset: usize = 0;

        for (d.start_band..d.end_band) |i| {
            const all: u32 = (@as(u32, 1) << @intCast(d.blocks)) - 1;
            var cm = [2]u32{ all, all };
            const band_offset = @as(usize, freq_bands[i]) << size;
            const band_size = @as(u32, freq_range[i]) << size;
            const x = d.block[0].coeffs[band_offset..];
            const y: ?[]f32 = if (d.channels == 2) d.block[1].coeffs[band_offset..] else null;
            const consumed = signed(rc.tellFrac());
            var effective_lowband: i32 = -1;
            var b: i32 = 0;

            // This band's bits.
            if (i != d.start_band) d.remaining -= consumed;
            d.remaining2 = totalbits - consumed - 1;
            if (i + 1 <= d.coded_bands) {
                const curr_balance = @divTrunc(d.remaining, @min(3, @as(i32, @intCast(d.coded_bands - i))));
                b = clipUintp2_14(@min(d.remaining2 + 1, d.pulses[i] + curr_balance));
            }

            if ((@as(i32, freq_bands[i]) - freq_range[i] >= freq_bands[d.start_band] or i == d.start_band + 1) and
                (update_lowband or lowband_offset == 0)) lowband_offset = i;

            if (i == d.start_band + 1) {
                // Special hybrid folding (RFC 8251 section 9): the first
                // band copied into the second, so that it never needs the
                // LCG.
                const count = (@as(usize, freq_range[i]) - freq_range[i - 1]) << size;
                @memcpy(norm1[band_offset..][0..count], norm1[band_offset - count ..][0..count]);
                if (d.channels == 2) @memcpy(norm2[band_offset..][0..count], norm2[band_offset - count ..][0..count]);
            }

            // A conservative estimate of the collapse masks of the bands
            // folded from.
            if (lowband_offset != 0 and (d.spread != .aggressive or d.blocks > 1 or d.tf_change[i] < 0)) {
                // Never repeat spectral content within one band.
                effective_lowband = @max(@as(i32, freq_bands[d.start_band]), @as(i32, freq_bands[lowband_offset]) - freq_range[i]);
                var foldstart = lowband_offset;
                while (true) {
                    foldstart -= 1;
                    if (!(freq_bands[foldstart] > effective_lowband)) break;
                }
                var foldend = lowband_offset - 1;
                while (true) {
                    foldend += 1;
                    if (!(foldend < i and freq_bands[foldend] < effective_lowband + freq_range[i])) break;
                }
                cm = .{ 0, 0 };
                for (foldstart..foldend) |j| {
                    cm[0] |= d.block[0].collapse_masks[j];
                    cm[1] |= d.block[d.channels - 1].collapse_masks[j];
                }
            }

            if (d.dual_stereo and i == d.intensity_stereo) {
                // Dual stereo off for intensity.
                d.dual_stereo = false;
                for (@as(usize, freq_bands[d.start_band]) << size..band_offset) |j| norm1[j] = (norm1[j] + norm2[j]) / 2;
            }

            const lowband_at: usize = if (effective_lowband != -1) @as(usize, @intCast(effective_lowband)) << size else 0;
            const norm_loc1: ?[]f32 = if (effective_lowband != -1) norm1[lowband_at..] else null;
            const norm_loc2: ?[]f32 = if (effective_lowband != -1) norm2[lowband_at..] else null;

            if (d.dual_stereo) {
                cm[0] = d.quantBand(rc, i, x, null, band_size, b >> 1, d.blocks, norm_loc1, size, norm1[band_offset..], 0, 1.0, &lowband_scratch, cm[0]);
                cm[1] = d.quantBand(rc, i, y.?, null, band_size, b >> 1, d.blocks, norm_loc2, size, norm2[band_offset..], 0, 1.0, &lowband_scratch, cm[1]);
            } else {
                cm[0] = d.quantBand(rc, i, x, y, band_size, b, d.blocks, norm_loc1, size, norm1[band_offset..], 0, 1.0, &lowband_scratch, cm[0] | cm[1]);
                cm[1] = cm[0];
            }

            d.block[0].collapse_masks[i] = @truncate(cm[0]);
            d.block[d.channels - 1].collapse_masks[i] = @truncate(cm[1]);
            d.remaining += d.pulses[i] + consumed;

            // Move the folding source only while at 1 bit per sample.
            update_lowband = b > @as(i32, @intCast(band_size << 3));
        }
    }

    /// The band's cache of bits per pulse count (ff_celt_cache_bits from
    /// ff_celt_cache_index). The index is -1 only for bands 0 to 7 at
    /// duration -1, which no split reaches: they have one bin per block,
    /// and splitting stops at two bins with duration 1.
    fn cacheFor(duration: i32, band: usize) []const u8 {
        const idx = tab.celt_cache_index[@as(usize, @intCast(duration + 1)) * max_bands + band];
        std.debug.assert(idx >= 0);
        return tab.celt_cache_bits[@intCast(idx)..];
    }

    /// quant_band_template, decoding: a band's vector (`x`, or `x` and
    /// `y` coupled), split in two while the bits allow, each half as its
    /// own band, else decoded as one PVQ codeword or folded.
    fn quantBand(
        d: *Decoder,
        rc: *RangeDecoder,
        band: usize,
        x: []f32,
        y_in: ?[]f32,
        n_in: u32,
        b_in: i32,
        blocks_in: u32,
        lowband_in: ?[]f32,
        duration_in: i32,
        lowband_out: ?[]f32,
        level: u32,
        gain: f32,
        lowband_scratch: ?[]f32,
        fill_in: u32,
    ) u32 {
        var n = n_in;
        var b = b_in;
        var blocks = blocks_in;
        var lowband = lowband_in;
        var duration = duration_in;
        var fill = fill_in;
        var y = y_in;
        const stereo = y_in != null;
        var split = stereo;
        const n0 = n;
        var n_b: u32 = n / blocks;
        var n_b0 = n_b;
        var b0 = blocks;
        var time_divide: u32 = 0;
        var recombine: u32 = 0;
        var inv = false;
        var mid: f32 = 0;
        var side: f32 = 0;
        const longblocks = b0 == 1;
        var cm: u32 = 0;

        if (n == 1) {
            var v = x;
            for (0..@as(usize, @intFromBool(stereo)) + 1) |c| {
                var sign: u32 = 0;
                if (d.remaining2 >= 1 << 3) {
                    sign = rc.raw(1);
                    d.remaining2 -= 1 << 3;
                }
                v[0] = 1.0 - 2.0 * @as(f32, @floatFromInt(sign));
                if (c == 0 and stereo) v = y.?;
            }
            if (lowband_out) |lo| lo[0] = x[0];
            return 1;
        }

        if (!stereo and level == 0) {
            var tf_change = d.tf_change[band];
            if (tf_change > 0) recombine = @intCast(tf_change);
            // Band recombining to increase the frequency resolution.
            if (lowband) |lb| {
                if (recombine != 0 or ((n_b & 1) == 0 and tf_change < 0) or b0 > 1) {
                    const scratch = lowband_scratch.?;
                    @memcpy(scratch[0..n], lb[0..n]);
                    lowband = scratch;
                }
            }
            for (0..recombine) |k| {
                if (lowband) |lb| haar1(lb, n >> @intCast(k), @as(u32, 1) << @intCast(k));
                fill = @as(u32, tab.celt_bit_interleave[fill & 0xf]) | @as(u32, tab.celt_bit_interleave[fill >> 4]) << 2;
            }
            blocks >>= @intCast(recombine);
            n_b <<= @intCast(recombine);

            // Increasing the time resolution.
            while ((n_b & 1) == 0 and tf_change < 0) {
                if (lowband) |lb| haar1(lb, n_b, blocks);
                fill |= fill << @intCast(blocks);
                blocks <<= 1;
                n_b >>= 1;
                time_divide += 1;
                tf_change += 1;
            }
            b0 = blocks;
            n_b0 = n_b;

            // The samples in time order instead of frequency order.
            if (b0 > 1) if (lowband) |lb| d.deinterleaveHadamard(lb, n_b >> @intCast(recombine), b0 << @intCast(recombine), longblocks);
        }

        // Split the band in two where it needs 1.5 bits more than it can
        // produce.
        if (!stereo and duration >= 0 and n > 2) {
            const cache = cacheFor(duration, band);
            if (b > @as(i32, cache[cache[0]]) + 12) {
                n >>= 1;
                y = x[n..];
                split = true;
                duration -= 1;
                if (blocks == 1) fill = (fill & 1) | (fill << 1);
                blocks = (blocks + 1) >> 1;
            }
        }

        if (split) {
            const yv = y.?;
            const ni: i32 = @intCast(n);
            var itheta: i32 = 0;
            // The resolution of the split angle theta.
            const pulse_cap: i32 = @as(i32, tab.celt_log_freq_range[band]) + duration * 8;
            const offset: i32 = (pulse_cap >> 1) - @as(i32, if (stereo and n == 2) qtheta_offset_twophase else qtheta_offset);
            const qn: i32 = if (stereo and @as(i32, @intCast(band)) >= d.intensity_stereo) 1 else computeQn(ni, b, offset, pulse_cap, stereo);
            const tell = signed(rc.tellFrac());
            if (qn != 1) {
                // A step pdf for stereo, uniform for the time split,
                // triangular for the rest.
                if (stereo and n > 2) {
                    itheta = signed(rc.uintStep(@intCast(@divTrunc(qn, 2))));
                } else if (stereo or b0 > 1) {
                    itheta = signed(rc.uint(@intCast(qn + 1)));
                } else {
                    itheta = signed(rc.uintTri(@intCast(qn)));
                }
                itheta = @divTrunc(itheta * 16384, qn);
            } else if (stereo) {
                inv = if (b > 2 << 3 and d.remaining2 > 2 << 3) rc.log(2) != 0 else false;
                inv = d.apply_phase_inv and inv;
                itheta = 0;
            }
            const qalloc = signed(rc.tellFrac()) - tell;
            b -= qalloc;

            const orig_fill = fill;
            var imid: i32 = undefined;
            var iside: i32 = undefined;
            var delta: i32 = undefined;
            if (itheta == 0) {
                imid = 32767;
                iside = 0;
                fill = zeroExtend(fill, blocks);
                delta = -16384;
            } else if (itheta == 16384) {
                imid = 0;
                iside = 32767;
                fill &= ((@as(u32, 1) << @intCast(blocks)) - 1) << @intCast(blocks);
                delta = 16384;
            } else {
                imid = celtCos(itheta);
                iside = celtCos(16384 - itheta);
                // The mid against side split that minimizes the squared
                // error.
                delta = roundMul16((ni - 1) << 7, log2tan(iside, imid));
            }
            mid = @as(f32, @floatFromInt(imid)) / 32768.0;
            side = @as(f32, @floatFromInt(iside)) / 32768.0;

            if (n == 2 and stereo) {
                // N = 2 stereo: mid and side are orthogonal, so the side
                // takes one bit.
                var mbits = b;
                const sbits: i32 = if (itheta != 0 and itheta != 16384) 1 << 3 else 0;
                mbits -= sbits;
                const c = itheta > 8192;
                d.remaining2 -= qalloc + sbits;
                const x2 = if (c) yv else x;
                const y2 = if (c) x else yv;
                var sign: i32 = 0;
                if (sbits != 0) sign = signed(rc.raw(1));
                sign = 1 - 2 * sign;
                // orig_fill: fold the side even where itheta 16384
                // cleared the low bits of fill.
                cm = d.quantBand(rc, band, x2, null, n, mbits, blocks, lowband, duration, lowband_out, level, gain, lowband_scratch, orig_fill);
                // No N = 2 split: cm is 1 or 0 (a fold collapse), and the
                // other channel needs no mixing.
                y2[0] = @as(f32, @floatFromInt(-sign)) * x2[1];
                y2[1] = @as(f32, @floatFromInt(sign)) * x2[0];
                x[0] *= mid;
                x[1] *= mid;
                yv[0] *= side;
                yv[1] *= side;
                var tmp = x[0];
                x[0] = tmp - yv[0];
                yv[0] = tmp + yv[0];
                tmp = x[1];
                x[1] = tmp - yv[1];
                yv[1] = tmp + yv[1];
            } else {
                // The normal split.
                var next_lowband2: ?[]f32 = null;
                var next_lowband_out1: ?[]f32 = null;
                var next_level: u32 = 0;
                // More bits to low-energy MDCTs than they would deserve.
                if (b0 > 1 and !stereo and (itheta & 0x3fff) != 0) {
                    if (itheta > 8192) {
                        // A rough pre-echo masking.
                        delta -= delta >> @intCast(4 - duration);
                    } else {
                        // A forward masking slope of 1.5 dB per 10 ms.
                        delta = @min(0, delta + (ni << 3 >> @intCast(5 - duration)));
                    }
                }
                var mbits = clip(@divTrunc(b - delta, 2), 0, b);
                var sbits = b - mbits;
                d.remaining2 -= qalloc;

                if (lowband != null and !stereo) {
                    // The >32-bit split case.
                    next_lowband2 = lowband.?[n..];
                }
                // Only stereo passes lowband_out on; otherwise the end
                // handles it.
                if (stereo) next_lowband_out1 = lowband_out else next_level = level + 1;

                const shift: u5 = if (stereo) 0 else @intCast(b0 >> 1);
                var rebalance = d.remaining2;
                if (mbits >= sbits) {
                    // Stereo does not scale the mid: folding needs it
                    // normalized.
                    cm = d.quantBand(rc, band, x, null, n, mbits, blocks, lowband, duration, next_lowband_out1, next_level, if (stereo) 1.0 else gain * mid, lowband_scratch, fill);
                    rebalance = mbits - (rebalance - d.remaining2);
                    if (rebalance > 3 << 3 and itheta != 0) sbits += rebalance - (3 << 3);
                    // In a stereo split the high bits of fill are zero:
                    // the side is not folded.
                    const cmt = d.quantBand(rc, band, yv, null, n, sbits, blocks, next_lowband2, duration, null, next_level, gain * side, null, fill >> @intCast(blocks));
                    cm |= cmt << shift;
                } else {
                    cm = d.quantBand(rc, band, yv, null, n, sbits, blocks, next_lowband2, duration, null, next_level, gain * side, null, fill >> @intCast(blocks));
                    cm <<= shift;
                    rebalance = sbits - (rebalance - d.remaining2);
                    if (rebalance > 3 << 3 and itheta != 16384) mbits += rebalance - (3 << 3);
                    cm |= d.quantBand(rc, band, x, null, n, mbits, blocks, lowband, duration, next_lowband_out1, next_level, if (stereo) 1.0 else gain * mid, lowband_scratch, fill);
                }
            }
        } else {
            // No split.
            const cache = cacheFor(duration, band);
            var q = bits2pulses(cache, b);
            var curr_bits = pulses2bits(cache, q);
            d.remaining2 -= curr_bits;
            // Never past the budget.
            while (d.remaining2 < 0 and q > 0) {
                d.remaining2 += curr_bits;
                q -= 1;
                curr_bits = pulses2bits(cache, q);
                d.remaining2 -= curr_bits;
            }
            if (q != 0) {
                const k: u32 = if (q < 8) q else (8 + (q & 7)) << @intCast((q >> 3) - 1);
                cm = d.algUnquant(rc, x, n, k, blocks, gain);
            } else {
                // No pulse: fill the band anyway.
                const cm_mask = (@as(u32, 1) << @intCast(blocks)) - 1;
                fill &= cm_mask;
                if (fill != 0) {
                    if (lowband) |lb| {
                        // The folded spectrum, about 48 dB below the
                        // normal folding level.
                        for (x[0..n], lb[0..n]) |*v, l| v.* = l + (if (d.rng() & 0x8000 != 0) @as(f32, 1.0 / 256.0) else -1.0 / 256.0);
                        cm = fill;
                    } else {
                        // Noise.
                        for (x[0..n]) |*v| v.* = @floatFromInt(@as(i32, @bitCast(d.rng())) >> 20);
                        cm = cm_mask;
                    }
                    renormalizeVector(x[0..n], gain);
                } else {
                    @memset(x[0..n], 0);
                }
            }
        }

        if (stereo) {
            const yv = y.?;
            if (n > 2) stereoMerge(x, yv, mid, n);
            if (inv) {
                for (yv[0..n]) |*v| v.* *= -1;
            }
        } else if (level == 0) {
            // Back from time order to frequency order.
            if (b0 > 1) d.interleaveHadamard(x, n_b >> @intCast(recombine), b0 << @intCast(recombine), longblocks);
            // Undo the time-frequency changes.
            n_b = n_b0;
            blocks = b0;
            for (0..time_divide) |_| {
                blocks >>= 1;
                n_b <<= 1;
                cm |= cm >> @intCast(blocks);
                haar1(x, n_b, blocks);
            }
            for (0..recombine) |k| {
                cm = tab.celt_bit_deinterleave[cm];
                haar1(x, n0 >> @intCast(k), @as(u32, 1) << @intCast(k));
            }
            blocks <<= @intCast(recombine);
            // The output scaled for later folding.
            if (lowband_out) |lo| {
                const scale = @sqrt(@as(f32, @floatFromInt(n0)));
                for (lo[0..n0], x[0..n0]) |*o, v| o.* = scale * v;
            }
            cm = zeroExtend(cm, blocks);
        }
        return cm;
    }

    /// celt_alg_unquant: a PVQ codeword's pulses, normalized to `gain`,
    /// rotated back; the collapse mask of its short blocks.
    fn algUnquant(d: *Decoder, rc: *RangeDecoder, x: []f32, n: u32, k: u32, blocks: u32, gain_in: f32) u32 {
        const y = d.qcoeff[0..n];
        const idx = rc.uint(pvqV(n, k));
        const norm: f32 = @floatFromInt(cwrsi(n, k, idx, y));
        const gain = gain_in / @sqrt(norm);
        // celt_normalize_residual.
        for (x[0..n], y) |*v, p| v.* = gain * @as(f32, @floatFromInt(p));
        expRotation(x, n, blocks, k, d.spread);
        // celt_extract_collapse_mask.
        if (blocks <= 1) return 1;
        const n0 = n / blocks;
        var mask: u32 = 0;
        for (0..blocks) |i| {
            for (y[i * n0 ..][0..n0]) |p| mask |= @as(u32, @intFromBool(p != 0)) << @intCast(i);
        }
        return mask;
    }

    /// celt_deinterleave_hadamard.
    fn deinterleaveHadamard(d: *Decoder, x: []f32, n0: u32, stride: u32, hadamard: bool) void {
        const n = n0 * stride;
        const order = tab.celt_hadamard_order[if (hadamard) stride - 2 else 30..];
        const tmp = d.hadamard_tmp[0..n];
        for (0..stride) |i| {
            for (0..n0) |j| tmp[order[i] * n0 + j] = x[j * stride + i];
        }
        @memcpy(x[0..n], tmp);
    }

    /// celt_interleave_hadamard.
    fn interleaveHadamard(d: *Decoder, x: []f32, n0: u32, stride: u32, hadamard: bool) void {
        const n = n0 * stride;
        const order = tab.celt_hadamard_order[if (hadamard) stride - 2 else 30..];
        const tmp = d.hadamard_tmp[0..n];
        for (0..stride) |i| {
            for (0..n0) |j| tmp[j * stride + i] = x[order[i] * n0 + j];
        }
        @memcpy(x[0..n], tmp);
    }
};

/// celt_renormalize_vector: `x` scaled to the norm `gain`.
fn renormalizeVector(x: []f32, gain: f32) void {
    var g: f32 = 1e-15;
    for (x) |v| g += v * v;
    g = gain / @sqrt(g);
    for (x) |*v| v.* *= g;
}

/// ROUND_MUL16.
fn roundMul16(a: i32, b: i32) i32 {
    return (a * b + 16384) >> 15;
}

/// celt_cos: a cosine in Q15 of an angle in [0, 16384], as int16.
fn celtCos(x_in: i32) i32 {
    const x16: i16 = @truncate(x_in);
    var x: i16 = @truncate((@as(i32, x16) * x16 + 4096) >> 13);
    const xi: i32 = x;
    x = @truncate((32767 - xi) + roundMul16(xi, -7651 + roundMul16(xi, 8277 + roundMul16(-626, xi))));
    const r: i16 = @truncate(@as(i32, x) + 1);
    return r;
}

/// celt_log2tan.
fn log2tan(isin_in: i32, icos_in: i32) i32 {
    const lc: i32 = @intCast(opus_rc.ilog(@intCast(icos_in)));
    const ls: i32 = @intCast(opus_rc.ilog(@intCast(isin_in)));
    const icos = icos_in << @intCast(15 - lc);
    const isin = isin_in << @intCast(15 - ls);
    return (ls << 11) - (lc << 11) +
        roundMul16(isin, roundMul16(isin, -2597) + 7932) -
        roundMul16(icos, roundMul16(icos, -2597) + 7932);
}

/// celt_compute_qn: the split angle's resolution.
fn computeQn(n: i32, b: i32, offset: i32, pulse_cap: i32, stereo: bool) i32 {
    var n2 = 2 * n - 1;
    if (stereo and n == 2) n2 -= 1;
    // The upper limit leaves enough bits for one pulse in the side of a
    // stereo split with itheta 16384, which is not folded.
    const qb = @min(b - pulse_cap - (4 << 3), @divTrunc(b + n2 * offset, n2), 8 << 3);
    if (qb < (1 << 3 >> 1)) return 1;
    return ((@as(i32, tab.celt_qn_exp2[@intCast(qb & 0x7)]) >> @intCast(14 - (qb >> 3))) + 1) >> 1 << 1;
}

/// celt_bits2pulses: the most pulses `bits` buys, by bisection.
fn bits2pulses(cache: []const u8, bits_in: i32) u32 {
    var low: i32 = 0;
    var high: i32 = cache[0];
    const bits = bits_in - 1;
    for (0..6) |_| {
        const center = (low + high + 1) >> 1;
        if (@as(i32, cache[@intCast(center)]) >= bits) high = center else low = center;
    }
    const below: i32 = if (low == 0) -1 else cache[@intCast(low)];
    return @intCast(if (bits - below <= @as(i32, cache[@intCast(high)]) - bits) low else high);
}

/// celt_pulses2bits.
fn pulses2bits(cache: []const u8, pulses: u32) i32 {
    return if (pulses == 0) 0 else @as(i32, cache[pulses]) + 1;
}

/// CELT_PVQ_U: the codewords of `k` pulses in `n` dimensions with the
/// first nonzero.
fn pvqU(n: u32, k: u32) u32 {
    return tab.pvq_u_row[@min(n, k)][@max(n, k)];
}

/// CELT_PVQ_V: every codeword of `k` pulses in `n` dimensions.
fn pvqV(n: u32, k: u32) u32 {
    return pvqU(n, k) +% pvqU(n, k + 1);
}

/// celt_cwrsi: codeword `i` of `k` pulses in `n` dimensions into `y`; the
/// squared norm.
fn cwrsi(n_in: u32, k_in: u32, i_in: u32, y: []i32) u64 {
    var n = n_in;
    var k = k_in;
    var i = i_in;
    var norm: u64 = 0;
    var at: usize = 0;
    var p: u32 = undefined;
    var s: i32 = undefined;
    var val: i32 = undefined;
    var k0: i32 = undefined;
    while (n > 2) : (n -= 1) {
        if (k >= n) {
            // Lots of pulses: are this dimension's negative?
            const row = tab.pvq_u_row[n];
            p = row[k + 1];
            s = -@as(i32, @intFromBool(i >= p));
            i -%= p & @as(u32, @bitCast(s));
            // How many pulses this dimension holds.
            k0 = @intCast(k);
            const q = row[n];
            if (q > i) {
                k = n;
                while (true) {
                    k -= 1;
                    p = tab.pvq_u_row[k][n];
                    if (!(p > i)) break;
                }
            } else {
                p = row[k];
                while (p > i) {
                    k -= 1;
                    p = row[k];
                }
            }
            i -%= p;
            val = (k0 - @as(i32, @intCast(k)) + s) ^ s;
            norm += @intCast(val * val);
            y[at] = val;
            at += 1;
        } else {
            // Lots of dimensions: any pulse in this one?
            p = tab.pvq_u_row[k][n];
            const q = tab.pvq_u_row[k + 1][n];
            if (p <= i and i < q) {
                i -%= p;
                y[at] = 0;
                at += 1;
            } else {
                s = -@as(i32, @intFromBool(i >= q));
                i -%= q & @as(u32, @bitCast(s));
                k0 = @intCast(k);
                while (true) {
                    k -= 1;
                    p = tab.pvq_u_row[k][n];
                    if (!(p > i)) break;
                }
                i -%= p;
                val = (k0 - @as(i32, @intCast(k)) + s) ^ s;
                norm += @intCast(val * val);
                y[at] = val;
                at += 1;
            }
        }
    }
    // N = 2.
    p = 2 * k + 1;
    s = -@as(i32, @intFromBool(i >= p));
    i -%= p & @as(u32, @bitCast(s));
    k0 = @intCast(k);
    k = (i +% 1) / 2;
    if (k != 0) i -%= 2 * k - 1;
    val = (k0 - @as(i32, @intCast(k)) + s) ^ s;
    norm += @intCast(val * val);
    y[at] = val;
    at += 1;
    // N = 1.
    s = @bitCast(0 -% i);
    val = (@as(i32, @intCast(k)) + s) ^ s;
    norm += @intCast(val * val);
    y[at] = val;
    return norm;
}

/// celt_exp_rotation, decoding: the spreading rotation undone.
fn expRotation(x: []f32, len_in: u32, stride: u32, k: u32, spread: Spread) void {
    var len = len_in;
    if (2 * k >= len or spread == .none) return;
    const spread_i: u32 = @backingInt(spread);
    const gain = @as(f32, @floatFromInt(len)) / @as(f32, @floatFromInt(len +% (20 - 5 * spread_i) *% k));
    const theta: f32 = @floatCast(std.math.pi * @as(f64, gain) * gain / 4);
    const c = libm.cosf(theta);
    const s = libm.sinf(theta);
    var stride2: u32 = 0;
    if (len >= stride << 3) {
        // sqrt(len / stride), rounded: while (stride2 + 0.5)^2 < len / stride.
        stride2 = 1;
        while ((stride2 * stride2 + stride2) * stride + (stride >> 2) < len) stride2 += 1;
    }
    len /= stride;
    for (0..stride) |i| {
        const v = x[i * len ..][0..len];
        if (stride2 != 0) rotate(v, stride2, s, c);
        rotate(v, 1, c, s);
    }
}

/// celt_exp_rotation_impl: one pass forwards and one backwards.
fn rotate(x: []f32, stride: u32, c: f32, s: f32) void {
    const len = x.len;
    for (0..len - stride) |i| {
        const x1 = x[i];
        const x2 = x[i + stride];
        x[i + stride] = c * x2 + s * x1;
        x[i] = c * x1 - s * x2;
    }
    var i: isize = @as(isize, @intCast(len)) - 2 * @as(isize, @intCast(stride)) - 1;
    while (i >= 0) : (i -= 1) {
        const at: usize = @intCast(i);
        const x1 = x[at];
        const x2 = x[at + stride];
        x[at + stride] = c * x2 + s * x1;
        x[at] = c * x1 - s * x2;
    }
}

/// celt_stereo_merge: mid and side back to left and right.
fn stereoMerge(x: []f32, y: []f32, mid: f32, n: u32) void {
    var xp: f32 = 0;
    var side: f32 = 0;
    for (x[0..n], y[0..n]) |a, b| {
        xp += a * b;
        side += b * b;
    }
    // The mid's normalization compensated.
    xp *= mid;
    const mid2 = mid;
    const e0 = mid2 * mid2 + side - 2 * xp;
    const e1 = mid2 * mid2 + side + 2 * xp;
    if (e0 < 6e-4 or e1 < 6e-4) {
        @memcpy(y[0..n], x[0..n]);
        return;
    }
    const gain0 = 1.0 / @sqrt(e0);
    const gain1 = 1.0 / @sqrt(e1);
    for (x[0..n], y[0..n]) |*a, *b| {
        const v0 = mid * a.*;
        const v1 = b.*;
        a.* = gain0 * (v0 - v1);
        b.* = gain1 * (v0 + v1);
    }
}

/// celt_haar1, M_SQRT1_2 in double precision.
fn haar1(x: []f32, n0_in: u32, stride: u32) void {
    const n0 = n0_in >> 1;
    for (0..stride) |i| {
        for (0..n0) |j| {
            const a = &x[stride * (2 * j + 0) + i];
            const b = &x[stride * (2 * j + 1) + i];
            const x0 = a.*;
            const x1 = b.*;
            a.* = @floatCast(@as(f64, x0 + x1) * std.math.sqrt1_2);
            b.* = @floatCast(@as(f64, x0 - x1) * std.math.sqrt1_2);
        }
    }
}

const testing = std.testing;

/// celt_vectors.c's generator.
const Generator = struct {
    state: u32,

    fn next(g: *Generator) u32 {
        g.state = g.state *% 1103515245 +% 12345;
        return g.state >> 16;
    }
};

test "frames decode as FFmpeg's ff_celt_decode_frame decodes them (vectors/celt.txt)" {
    const gpa = testing.allocator;
    var lines = std.mem.splitScalar(u8, @embedFile("../testing/vectors/celt.txt"), '\n');
    var frame: [1275]u8 = undefined;
    var out: [2][960]f32 = undefined;
    var text: [256]u8 = undefined;
    var frames: usize = 0;
    // Too large for the test runner's stack in Debug.
    const d = try gpa.create(Decoder);
    defer gpa.destroy(d);
    for (1..49) |run| {
        var g: Generator = .{ .state = @intCast(run) };
        const output_channels = g.next() % 2 + 1;
        const phase_inv = g.next() % 4 != 0;
        const hybrid = g.next() % 4 == 0;
        d.* = try .init(gpa, output_channels, phase_inv);
        defer d.deinit();
        for (0..20) |f| {
            const flush = g.next() % 16 == 0;
            const channels: u32 = if (g.next() % 3 == 0) 1 else 2;
            const frame_size = @as(u32, 120) << @intCast(g.next() % 4);
            const start: u32 = if (hybrid) 17 else 0;
            const end: u32 = if (hybrid) tab.celt_band_end[g.next() % 2 + 3] else tab.celt_band_end[g.next() % 5];
            const bytes: usize = if (g.next() % 8 == 0) g.next() % 4 else g.next() % 400 + 1;
            for (frame[0..bytes]) |*b| b.* = @truncate(g.next());

            if (flush) d.flush();
            var rc: RangeDecoder = try .init(frame[0..bytes]);
            rc.initRaw(frame[0..bytes], @intCast(bytes));
            out = @splat(@splat(0));
            const result: i32 = if (d.decodeFrame(&rc, .{ &out[0], &out[1] }, channels, frame_size, start, end)) 0 else |_| -1;

            var md5: std.crypto.hash.Md5 = .init(.{});
            for (out[0..output_channels]) |o| {
                for (o[0..frame_size]) |v| {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, @bitCast(v), .little);
                    md5.update(&b);
                }
            }
            var digest: [16]u8 = undefined;
            md5.final(&digest);
            const got = try std.fmt.bufPrint(&text, "C {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {x}", .{
                run,        f,             @intFromBool(flush), channels, output_channels, @intFromBool(phase_inv),
                frame_size, bytes,         start,               end,      result,          rc.range,
                rc.value,   rc.total_bits, digest,
            });
            const want = lines.next().?;
            testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("run {d} frame {d}\n", .{ run, f });
                return err;
            };
            frames += 1;
        }
    }
    try testing.expectEqual(960, frames);
}
