// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aaccoder_nmr.h (search_for_quantizers_nmr
// and its helpers), aacencdsp.c (nmr_trellis_step_c), aacenc.h (NMRSlot,
// AACNMRCurves) and aacenc.c (nmr_decide_stereo, nmr_apply_ms_band,
// nmr_is_image_masked, nmr_apply_is_band) at the pinned reference revision.
// Copyright (c) 2026 Lynne <dev@lynne.ee>
// Copyright (C) 2008 Konstantin Shishkov
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's default AAC coder, `nmr` (TODO.md T32d2), bit for bit: a
//! Viterbi search over each channel's scalefactors that minimizes the
//! noise-to-mask ratio plus lambda times the bits, with lambda bisected to
//! the frame's budget (a coarse grid, then a fine one around its pick); a
//! CPE's two channels pooled under one lambda; the rate controls (CBR's
//! corridor and virtual reservoir, `-q:a`'s noise-to-mask target and ABR's
//! slow servo of that target); PNS decided inside the trellis; and the
//! encoder's per-band stereo decision (L/R, M/S or intensity) made from
//! the psychoacoustic model before quantization.
//!
//! The coder's state (`AACNMRCurves`, about 260 KiB) lives in `State`,
//! which the encoder allocates when it uses this coder.

const std = @import("std");
const aacenc = @import("aacenc.zig");
const aac_tab = @import("aac_tab.zig");
const coder = @import("aaccoder.zig");
const libm = @import("../core/libm.zig");
const cconv = @import("../core/cconv.zig");

const Encoder = aacenc.Encoder;
const Sce = aacenc.Sce;
const Cpe = aacenc.Cpe;
const bt = aacenc.BandType;

const scale_max_pos = aacenc.scale_max_pos;
const scale_max_diff = aacenc.scale_max_diff;
const scale_diff_zero = aacenc.scale_diff_zero;

/// NMR_NCAND: scalefactor candidates per band.
pub const ncand = 96;

const iters_full = 14; // NMR_ITERS
const iters_fine = 9; // NMR_IFINE
const iters_coarse = 7; // NMR_CITERS
const iters_warm = 5; // NMR_CWARM
const coarse = 8; // NMR_COARSE
const fine = 1; // NMR_STEP
const pns_bits = 9; // NMR_PNS_BITS
const pns_hole_frac: f32 = 0.5;
const pns_hole_spread: f32 = 0.5;
const pns_hole_lam: f32 = 20.0;
const rc_k_cbr: f32 = 0.5;
const rc_iters = 8;
const rc_corr: f32 = 1.5;
const rc_capk: f32 = 3.0;
const vbr_anchor: f32 = -0.75;
const vbr_tmin: f32 = -3.8;
const abr_tmin: f32 = -3.0;
const abr_tmax: f32 = 2.5;
const abr_k: f32 = 0.003;
const abr_ema_k: f32 = 0.0023;
const abr_step: f32 = 0.15;
const abr_hold_frames = 120;
const abr_boot_gain: f32 = 1.2;
const abr_tol: f32 = 0.02;
const abr_boots_max = 6;
const abr_settle = 100;
const infl_hf: f32 = 0.10;
const cbr_buf = 1536;
const slew: f32 = 1.6;
const slew_run: f32 = 1.15;
const rc_citers = 3;
const trans_pm: f32 = 2.0;
const zero_sticky: f32 = 0.5;
const group_keep: f32 = 0.25;
const hf_taper: f32 = 0.08;
const hf_taper_knee: f32 = 8000.0;
const burst_gap = 10;
const burst_gain: f32 = 8.0;
const short_boost: f32 = 2.0;
const rc_fiters = 4;
const rc_track: f32 = 0.1;
const pns_ndgate: f32 = 4.0;
const pns_max_et: f32 = 8.0;
const pns_lam: f32 = 100.0;
const pns_enter: f32 = 0.7;
const pns_stay: f32 = 1.4;
const pns_on = 8;
const pns_off = 4;

// nmr_decide_stereo's constants (aacenc.c).
const is_img_gate: f32 = 8000.0;
const is_low_limit = 6100;
const ms_equiv: f32 = 0.5;
const ms_mask: f32 = 0.0;
const decorr_lo: f32 = 0.20;
const sticky: f32 = 2.0;
const sdec_ema: f32 = 0.75;
const pns_stereo_decorr: f32 = 0.6;
const ms_balance: f32 = 0.25;
const is_perc_freq: f32 = 8000.0;
const is_perc_corr: f32 = 0.85;
const is_perc_gate: f32 = 50.0;

/// FLT_MAX and FLT_MIN.
const flt_max = std.math.floatMax(f32);
const flt_min = std.math.floatMin(f32);

/// NMRSlot: one channel's trellis state for a solve.
pub const Slot = struct {
    sce: ?*Sce = null,
    /// The curve bank (`nd`/`nb` index).
    si: usize = 0,
    /// The encoder channel.
    cur_ch: usize = 0,
    nbnd: usize = 0,
    is8: bool = false,
    /// Each coded band's index in the channel (w * 16 + g).
    bidx: [128]usize = @splat(0),
    bw: [128]usize = @splat(0),
    bg: [128]usize = @splat(0),
    bst: [128]usize = @splat(0),
    /// The finest candidate scalefactor.
    blo: [128]i32 = @splat(0),
    bnc: [128]usize = @splat(0),
    chosen: [128]usize = @splat(0),
    /// The active (non-PNS) bands, in coding order.
    act: [128]usize = @splat(0),
    nact: usize = 0,
    minsf: [128]i32 = @splat(0),
    maxvals: [128]f32 = @splat(0),
    thr: [128]f32 = @splat(0),
    thr_real: [128]f32 = @splat(0),
    tnsg: [128]f32 = @splat(0),
    pener: [128]f32 = @splat(0),
    pspread: [128]f32 = @splat(0),
    is_pns: [128]bool = @splat(false),
    hftx: [128]bool = @splat(false),
};

/// AACNMRCurves: the candidate curves and the state the coder carries
/// across frames, zeroed at allocation as av_mallocz zeroes it.
pub const State = struct {
    nd: [2][128][ncand]f32 = @splat(@splat(@splat(0))),
    nb: [2][128][ncand]i32 = @splat(@splat(@splat(0))),
    slot: [2]Slot = .{ .{}, .{} },
    pair: bool = false,
    rc_gl: bool = false,
    rc_fill_seeded: bool = false,
    pending: bool = false,
    zero_prev: [16][128]u8 = @splat(@splat(0)),
    zero_nw: [16]u8 = @splat(0),
    thr_prev: [16][64]f32 = @splat(@splat(0)),
    thr_prev_ok: [16]bool = @splat(false),
    pns_prev: [16][128]u8 = @splat(@splat(0)),
    pns_run_on: [16][128]u8 = @splat(@splat(0)),
    pns_run_off: [16][128]u8 = @splat(@splat(0)),
    smode: [16][128]u8 = @splat(@splat(0)),
    smode_band: [8][128]u8 = @splat(@splat(0)),
    tns8_prev: [16]u8 = @splat(0),
    sinit: [16]bool = @splat(false),
    sema_es: [16][128]f32 = @splat(@splat(0)),
    sema_em: [16][128]f32 = @splat(@splat(0)),
    sema_img: [16][128]f32 = @splat(@splat(0)),
    lam: [16]f32 = @splat(0),
    counted: [16]i32 = @splat(0),
    side_ema: f32 = 0,
    side_inited: bool = false,

    rc_frame_num: i64 = 0,
    lam_rc: f32 = 0,
    rc_fill: i32 = 0,
    rc_satrun: i32 = 0,
    rc_sat_frame: bool = false,
    frames_since_short: i32 = 0,
    prev_was_short: bool = false,
    win_frame_num: i64 = 0,
    run_burst: f32 = 0,
    lam_slew: f32 = 0,
    lam_slew_ch: [16]f32 = @splat(0),
    vbr_infl: [16]f32 = @splat(0),
    nd_ema: f32 = 0,
    press: f32 = 0,
    lam_short_ema: f32 = 0,
    lam_long_ema: f32 = 0,
    lam_floor: f32 = 0,

    abr_t: f32 = 0,
    abr_glide: f32 = 0,
    abr_ema: f32 = 0,
    abr_acc: f32 = 0,
    abr_hold: i32 = 0,
    abr_booted: bool = false,
    abr_boots: i32 = 0,
    abr_alloc_ema: f32 = 0,
    abr_longs: i32 = 0,
    abr_frame_num: i64 = 0,
};

/// `avctx->bit_rate_tolerance`: libavcodec's default (`bt`), which
/// neither the ffmpeg program nor the encoder's users change.
const bit_rate_tolerance = 4000000;

// FFMIN, FFMAX, av_clip, av_clipf and av_clipd as the C evaluates them.
fn fmin(a: f32, b: f32) f32 {
    return if (a > b) b else a;
}
fn fmax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
const clipf = coder.clipf;
fn clipd(a: f64, amin: f64, amax: f64) f64 {
    const x = if (a > amin) a else amin;
    return if (x > amax) amax else x;
}
fn clip(a: i32, amin: i32, amax: i32) i32 {
    if (a < amin) return amin;
    if (a > amax) return amax;
    return a;
}
/// C's float-to-int conversion, `cvttss2si` / `cvttsd2si`.
fn toInt(x: f64) i32 {
    return cconv.cvttsd2si32(x);
}
fn f(x: i32) f32 {
    return @floatFromInt(x);
}

/// NMR_SFBITS: the differential scalefactor cost, clamped to the legal range.
fn sfBits(d: i32) i32 {
    return aac_tab.scalefactor_bits[@intCast(clip(d + scale_diff_zero, 0, 2 * scale_max_diff))];
}

/// nmr_trellis_step_c: for each current candidate, the previous candidate
/// minimizing `dpp[op] + lamsf[d]`, then `dp[o] = node[o] + that cost` and
/// the back-pointer.
fn trellisStep(dp: *[ncand]f32, bp: *[ncand]u8, dpp: *const [ncand]f32, node: *const [ncand]f32, lamsf: *const [2 * scale_max_diff + 1]f32, n_cur: usize, n_prev: usize, base: i32, step: i32, mdiff: i32) void {
    // d = base + (o - op) * step lies in [-mdiff, mdiff] for op in
    // [o - dlo, o + dhi]; FFUDIV is a floor division.
    const dlo = @divFloor(mdiff - base, step);
    const dhi = @divFloor(mdiff + base, step);
    const np: i32 = @intCast(n_prev);
    for (0..n_cur) |ou| {
        const o: i32 = @intCast(ou);
        const op_end = @min(np, o + dhi + 1);
        const edge = base + o * step + mdiff;
        var best: i32 = -1;
        var bestc = flt_max;
        var op = @max(0, o - dlo);
        while (op < op_end) : (op += 1) {
            const c = dpp[@intCast(op)] + lamsf[@intCast(edge - op * step)];
            if (c < bestc) {
                bestc = c;
                best = op;
            }
        }
        bp[ou] = if (best < 0) 0 else @intCast(best);
        dp[ou] = if (best < 0) flt_max else node[ou] + bestc;
    }
}

const Curves = struct {
    nd: *[128][ncand]f32,
    nb: *[128][ncand]i32,
};

fn curves(n: *State, t: *const Slot) Curves {
    return .{ .nd = &n.nd[t.si], .nb = &n.nb[t.si] };
}

/// nmr_solve: the Viterbi over the slot's active bands with lambda
/// bisected so the coded size meets `destbits`; fills `chosen`.
fn solve(c: Curves, t: *Slot, step: i32, destbits: i32, lo_in: f32, hi_in: f32, iters: u32) f32 {
    var dp: [ncand]f32 = @splat(0);
    var dpp: [ncand]f32 = @splat(0);
    var node: [ncand]f32 = @splat(0);
    var lamsf: [2 * scale_max_diff + 1]f32 = undefined;
    var bp: [128][ncand]u8 = undefined;
    var lam: f32 = 1.0;
    var lo_l = lo_in;
    var hi_l = hi_in;
    const act = t.act[0..t.nact];
    if (act.len == 0) return lam;
    for (0..iters) |it| {
        lam = @sqrt(lo_l * hi_l);
        for (&lamsf, aac_tab.scalefactor_bits) |*l, sb| l.* = lam * f(sb);
        const b0 = act[0];
        for (0..t.bnc[b0]) |o| dp[o] = c.nd[b0][o] + lam * f(c.nb[b0][o]);
        for (1..act.len) |k| {
            const b = act[k];
            const pb = act[k - 1];
            dpp = dp;
            for (0..t.bnc[b]) |o| node[o] = c.nd[b][o] + lam * f(c.nb[b][o]);
            trellisStep(&dp, &bp[k], &dpp, &node, &lamsf, t.bnc[b], t.bnc[pb], t.blo[b] - t.blo[pb], step, scale_max_diff);
        }
        // Backtrack.
        var beo: usize = 0;
        const bl = act[act.len - 1];
        var bec = flt_max;
        for (0..t.bnc[bl]) |o| {
            if (dp[o] < bec) {
                bec = dp[o];
                beo = o;
            }
        }
        t.chosen[bl] = beo;
        var k = act.len - 1;
        while (k > 0) : (k -= 1) t.chosen[act[k - 1]] = bp[k][t.chosen[act[k]]];
        if (it == iters - 1) break;
        // Over budget: go coarser.
        if (slotBits(t, c.nb, step) > destbits) lo_l = lam else hi_l = lam;
    }
    return lam;
}

/// nmr_band_curve: one coded band's (distortion / threshold, bits) curve,
/// candidates `lo + o * step` until the band would drop.
fn bandCurve(e: *Encoder, sce: *Sce, w: usize, g: usize, start: usize, lo: i32, step: i32, maxn: usize, invthr: f32, maxval: f32, nd_row: *[ncand]f32, nb_row: *[ncand]i32) usize {
    var n: usize = 0;
    var sf = lo;
    while (n < maxn and sf <= scale_max_pos) : (sf += step) {
        var btot: i32 = 0;
        const cb = coder.findMinBook(maxval, sf);
        var dist: f32 = 0;
        if (cb <= 0) break;
        for (0..sce.ics.group_len[w]) |w2| {
            var bb: i32 = 0;
            dist += coder.quantizeBandCostCached(e, w + w2, g, sce.coeffs[start + w2 * 128 ..], e.scoefs[start + w2 * 128 ..], sce.ics.swb_sizes[g], sf, cb, 1.0, std.math.inf(f32), &bb, null, false);
            btot += bb;
        }
        nd_row[n] = (dist - f(btot)) * invthr;
        nb_row[n] = btot;
        n += 1;
    }
    return n;
}

/// nmr_bail_channel: a channel with nothing codeable, zeroed (I/S bands
/// kept).
fn bailChannel(sce: *Sce) void {
    for (&sce.band_type, &sce.zeroes) |*t, *z| {
        if (t.* == bt.intensity or t.* == bt.intensity2) continue;
        z.* = 1;
        t.* = 0;
    }
}

/// nmr_setup_channel: short-window threshold shaping, the allocation law,
/// the zero decisions and the coarse candidate curves into slot `t`.
/// Returns the coded band count; 0 means nothing codeable.
fn setupChannel(e: *Encoder, n: *State, sce: *Sce, t: *Slot) usize {
    const c = curves(n, t);
    const cstep: i32 = coarse;
    var allz = false;
    var nbnd: usize = 0;
    const ch = e.cur_channel;
    const bands = &e.psy.channels[ch].bands;

    const zprev = &n.zero_prev[ch & 15];
    if (n.zero_nw[ch & 15] != sce.ics.num_windows) {
        zprev.* = @splat(1);
        n.zero_nw[ch & 15] = sce.ics.num_windows;
    }

    t.sce = sce;
    t.cur_ch = ch;
    t.is8 = sce.ics.window_sequence[0] == .eight_short;
    t.nbnd = 0;
    t.nact = 0;

    // The band cutoff for this frame's window size. C's int arithmetic
    // wraps on the reference build (notes.md "Follow the reference
    // build") for a cutoff option past 2^20 Hz.
    const nw: i32 = sce.ics.num_windows;
    const sample_rate: i32 = @intCast(e.sample_rate);
    const cutoff = @divTrunc(e.bandwidth *% 2 *% @divTrunc(1024, nw), sample_rate);

    // Short blocks: temporal premask and per-window threshold flattening.
    if (sce.ics.window_sequence[0] == .eight_short) {
        const pm_p1: f32 = 0.1;
        const pm_p2: f32 = 2.0;
        const pm_p3: f32 = 4.0;
        for (0..sce.ics.num_swb) |g| {
            var t1 = flt_max;
            var t2 = flt_max;
            for (0..sce.ics.num_windows) |w| {
                const b = &bands[w * 16 + g];
                const th = b.threshold;
                const cm = fmin(th, fmin(t1 * pm_p2, t2 * pm_p3));
                b.threshold = fmax(cm, th * pm_p1);
                t2 = t1;
                t1 = th;
            }
        }
        // expf(-12.0f * (float)M_LN10 / 10.0f): M_LN10 a double first.
        const ln10_d: f64 = std.math.ln10;
        const ln10_f: f32 = @floatCast(ln10_d);
        const att = libm.expf(-12.0 * ln10_f / 10.0);
        for (0..sce.ics.num_windows) |w| {
            var sum: f32 = 0;
            var esum: f32 = 0;
            var cnt: i32 = 0;
            for (0..sce.ics.num_swb) |g| {
                const b = &bands[w * 16 + g];
                if (b.energy > b.threshold and b.threshold > 0) {
                    sum += b.threshold;
                    esum += b.energy;
                    cnt += 1;
                }
            }
            if (cnt > 0) {
                // Keep each window codeable: the mean 12 dB under the
                // window's mean audible energy at most.
                const mean = fmin(sum / f(cnt), (esum / f(cnt)) * att);
                for (0..sce.ics.num_swb) |g| {
                    const b = &bands[w * 16 + g];
                    if (b.energy > b.threshold and b.threshold > 0) b.threshold = fmin(mean, b.threshold * 1e9);
                }
            }
        }
    }

    // The allocation law; short frames blend to softer exponents under
    // rate pressure.
    var a_ae: f32 = 0.50;
    var a_at: f32 = 0.18;
    if (sce.ics.num_windows == 8) {
        a_ae += (0.35 - a_ae) * n.press;
        a_at += (0.3 - a_at) * n.press;
    }
    const sr_f = f(@intCast(e.sample_rate));
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        const gl = sce.ics.group_len[w];
        var start: usize = 0;
        for (0..sce.ics.num_swb) |g| {
            defer start += sce.ics.swb_sizes[g];
            const bi = w * 16 + g;
            var uplim: f32 = 0;
            var ener: f32 = 0;
            var spread: f32 = 2.0;
            var nz = false;
            if (sce.band_type[bi] == bt.intensity or sce.band_type[bi] == bt.intensity2) {
                // A pre-decided intensity band keeps its signalling.
                for (0..gl) |w2| sce.zeroes[(w + w2) * 16 + g] = 0;
                continue;
            }
            var zthr_mul: f32 = if (zprev[bi] != 0) 1.0 else zero_sticky;
            // M/S side bands: zero reluctance scaled by the side/mid ratio.
            // The channel's parity, not its place in the element, decides
            // (FFmpeg's test).
            if (t.cur_ch & 1 != 0 and n.pair and n.smode_band[(t.cur_ch >> 1) & 7][bi] == 1) {
                const mb = &e.psy.channels[ch - 1].bands[bi];
                var eside: f32 = 0;
                for (0..gl) |w2| eside += bands[(w + w2) * 16 + g].energy;
                const ratio = eside / fmax(mb.energy * f(gl), 1e-9);
                zthr_mul *= 0.25 + 0.75 * clipf(ratio / 0.3, 0.0, 1.0);
            }
            // The HF precision taper.
            const bfreq = f(@intCast(start)) * (sr_f * @as(f32, if (sce.ics.num_windows == 8) 4.0 else 0.5)) / 1024.0;
            const kf = fmax(0.0, bfreq - hf_taper_knee) / 1000.0;
            const hftdb = hf_taper * kf * kf;
            t.hftx[bi] = false;
            const start_i: i32 = @intCast(start);
            for (0..gl) |w2| {
                const band = &bands[(w + w2) * 16 + g];
                ener += band.energy;
                spread = fmin(spread, band.spread);
                if (start_i >= cutoff or band.energy <= band.threshold * zthr_mul or band.threshold == 0) {
                    sce.zeroes[(w + w2) * 16 + g] = 1;
                    continue;
                }
                uplim += band.threshold;
                nz = true;
            }
            if (nz and gl > 1) {
                // A coded group keeps its borderline windows. The flags of
                // windows coded above are last frame's, as FFmpeg reads
                // them (a stale one adds its threshold twice).
                for (0..gl) |w2| {
                    const band = &bands[(w + w2) * 16 + g];
                    if (sce.zeroes[(w + w2) * 16 + g] != 0 and start_i < cutoff and band.threshold > 0 and
                        band.energy > band.threshold * zthr_mul * group_keep)
                    {
                        sce.zeroes[(w + w2) * 16 + g] = 0;
                        uplim += band.threshold;
                    }
                }
            }
            zprev[bi] = @intFromBool(!nz);
            sce.zeroes[bi] = @intFromBool(!nz);
            t.thr_real[bi] = uplim;
            if (nz and ener > 0 and uplim > 0) {
                uplim = libm.expf(a_ae * libm.logf(ener) + a_at * libm.logf(uplim));
                if (hftdb != 0) {
                    uplim *= libm.powf(10.0, hftdb * 0.1);
                    if (hftdb > 2.0) t.hftx[bi] = true;
                }
            }
            t.thr[bi] = uplim;
            t.pener[bi] = ener;
            t.pspread[bi] = spread;
            allz = allz or nz;
        }
    }
    if (!allz) return 0;

    // Transition premask: a START frame's thresholds clamped toward the
    // previous long frame's.
    const ci = t.cur_ch & 15;
    if (sce.ics.num_windows == 1) {
        const ng = @min(sce.ics.num_swb, 64);
        if (sce.ics.window_sequence[0] == .long_start and n.thr_prev_ok[ci]) {
            for (0..ng) |g| {
                if (t.thr[g] > 0 and n.thr_prev[ci][g] > 0) t.thr[g] = fmin(t.thr[g], n.thr_prev[ci][g] * trans_pm);
            }
        }
        for (0..ng) |g| n.thr_prev[ci][g] = t.thr[g];
        n.thr_prev_ok[ci] = true;
    } else {
        n.thr_prev_ok[ci] = false;
    }

    coder.absPow34(&e.scoefs, &sce.coeffs);
    e.costCacheInit();

    // The TNS synthesis gain per band (short frames).
    t.tnsg = @splat(1.0);
    if (sce.ics.num_windows == 8 and sce.tns.present) {
        const mmm2: usize = @min(sce.ics.tns_max_bands, if (sce.ics.max_sfb != 0) sce.ics.max_sfb else sce.ics.num_swb);
        for (0..8) |win| {
            var bottom2: i32 = sce.ics.num_swb;
            for (0..@intCast(sce.tns.n_filt[win])) |filt| {
                const top2 = bottom2;
                bottom2 = @max(0, top2 - sce.tns.length[win][filt]);
                if (sce.tns.order[win][filt] == 0) continue;
                const lo_g: usize = @intCast(bottom2);
                const hi_g: usize = @intCast(top2);
                for (@min(lo_g, mmm2)..@min(hi_g, mmm2)) |g| {
                    const s0 = sce.ics.swb_offset[g] + win * 128;
                    const s1 = sce.ics.swb_offset[g + 1] + win * 128;
                    var eres: f32 = 0;
                    for (sce.coeffs[s0..s1]) |x| eres += x * x;
                    t.tnsg[win * 16 + g] = clipf(bands[win * 16 + g].energy / fmax(eres, 1e-12), 1.0, 64.0);
                }
            }
        }
    }

    // The finest codeable scalefactor and the peak per band.
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        var start = w * 128;
        for (0..sce.ics.num_swb) |g| {
            const bi = w * 16 + g;
            t.maxvals[bi] = coder.findMaxVal(sce.ics.group_len[w], sce.ics.swb_sizes[g], e.scoefs[start..]);
            t.minsf[bi] = if (t.maxvals[bi] > 0) coder.coef2minsf(t.maxvals[bi]) else 0;
            start += sce.ics.swb_sizes[g];
        }
    }

    // PASS 1: the coarse candidate curves of each coded band.
    w = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        var start = w * 128;
        for (0..sce.ics.num_swb) |g| {
            defer start += sce.ics.swb_sizes[g];
            const bi = w * 16 + g;
            if (sce.zeroes[bi] != 0 or !(t.maxvals[bi] > 0) or nbnd >= 128) continue;
            const lo = clip(t.minsf[bi], 0, scale_max_pos);
            const invthr = 1.0 / fmax(t.thr[bi], 1e-9);
            const nc = bandCurve(e, sce, w, g, start, lo, cstep, ncand, invthr, t.maxvals[bi], &c.nd[nbnd], &c.nb[nbnd]);
            if (t.tnsg[bi] > 1.0) {
                for (c.nd[nbnd][0..nc]) |*d| d.* *= t.tnsg[bi];
            }
            if (nc == 0) {
                // Nothing codeable: the group's band and its window flags.
                for (0..sce.ics.group_len[w]) |w2| sce.zeroes[(w + w2) * 16 + g] = 1;
            } else {
                t.bidx[nbnd] = bi;
                t.bw[nbnd] = w;
                t.bg[nbnd] = g;
                t.bst[nbnd] = start;
                t.blo[nbnd] = lo;
                t.bnc[nbnd] = nc;
                nbnd += 1;
            }
        }
    }
    t.nbnd = nbnd;
    for (0..nbnd) |b| {
        t.act[b] = b;
        t.is_pns[b] = false;
    }
    t.nact = nbnd;
    return nbnd;
}

/// nmr_slot_bits: the slot's bits at its `chosen` on grid `step`, with
/// the scalefactor differences.
fn slotBits(t: *const Slot, nb: *const [128][ncand]i32, step: i32) i32 {
    var tot: i32 = 0;
    const act = t.act[0..t.nact];
    for (act) |b| tot += nb[b][t.chosen[b]];
    for (1..act.len) |k| tot += sfBits(sfAt(t, act[k], step) - sfAt(t, act[k - 1], step));
    return tot;
}

/// Band `b`'s chosen scalefactor on grid `step`.
fn sfAt(t: *const Slot, b: usize, step: i32) i32 {
    const o: i32 = @intCast(t.chosen[b]); // below ncand
    return t.blo[b] + o * step;
}

fn groupBits(n: *State, sl: []const *Slot, step: i32) i32 {
    var tot: i32 = 0;
    for (sl) |t| tot += slotBits(t, &n.nb[t.si], step);
    return tot;
}

/// nmr_eval_slots: every slot's trellis at one lambda; the pooled bits.
fn evalSlots(n: *State, sl: []const *Slot, step: i32, lam: f32) i32 {
    var total: i32 = 0;
    for (sl) |t| {
        if (t.nact == 0) continue;
        _ = solve(curves(n, t), t, step, 0, lam, lam, 1);
        total += slotBits(t, &n.nb[t.si], step);
    }
    return total;
}

/// nmr_solve_slots: one shared lambda bisected so the pooled bits meet
/// `destbits`.
fn solveSlots(n: *State, sl: []const *Slot, step: i32, destbits: i32, lo_in: f32, hi_in: f32, iters: u32) f32 {
    var lam: f32 = 1.0;
    var lo_l = lo_in;
    var hi_l = hi_in;
    for (0..iters) |it| {
        lam = @sqrt(lo_l * hi_l);
        const total = evalSlots(n, sl, step, lam);
        if (it == iters - 1) break;
        if (total > destbits) lo_l = lam else hi_l = lam;
    }
    return lam;
}

/// nmr_nd_stat: the mean log2 achieved distortion over the real mask of
/// the slots' active bands; NaN when nothing is coded.
fn ndStat(n: *State, sl: []const *Slot) f32 {
    var ndsum: f32 = 0;
    var cnt: i32 = 0;
    for (sl) |t| {
        const nd = &n.nd[t.si];
        for (t.act[0..t.nact]) |b| {
            const bi = t.bidx[b];
            if (t.thr_real[bi] > 0 and t.thr[bi] > 0) {
                ndsum += fmax(libm.log2f(fmax(nd[b][t.chosen[b]] * t.thr[bi] / t.thr_real[bi], 1e-6)), -4.0);
                cnt += 1;
            }
        }
    }
    return if (cnt != 0) ndsum / f(cnt) else std.math.nan(f32);
}

/// nmr_solve_slots_nd: one shared lambda bisected so the noise-to-mask
/// statistic meets `target`.
fn solveSlotsNd(n: *State, sl: []const *Slot, step: i32, target: f32, lo_in: f32, hi_in: f32, iters: u32) f32 {
    var lam: f32 = 1.0;
    var lo_l = lo_in;
    var hi_l = hi_in;
    for (0..iters) |it| {
        lam = @sqrt(lo_l * hi_l);
        _ = evalSlots(n, sl, step, lam);
        const st = ndStat(n, sl);
        if (std.math.isNan(st) or it == iters - 1) break;
        if (st > target) hi_l = lam else lo_l = lam;
    }
    return lam;
}

/// nmr_commit_channel: a solved slot's band types and scalefactors, with
/// the SCALE_MAX_DIFF legality fixups.
fn commitChannel(n: *State, t: *Slot) void {
    const sce = t.sce.?; // set by setupChannel before any solve
    for (0..t.nbnd) |b| {
        const bi = t.bidx[b];
        if (t.is_pns[b]) {
            sce.band_type[bi] = bt.noise;
            sce.zeroes[bi] = 0;
            sce.pns_ener[bi] = t.pener[bi] * fmin(1.0, t.pspread[bi] * t.pspread[bi]);
        } else {
            sce.sf_idx[bi] = clip(sfAt(t, b, fine), 0, scale_max_pos);
        }
    }
    // The bits this solve accounted for (only the surviving active bands).
    n.counted[t.cur_ch] = slotBits(t, &n.nb[t.si], fine);

    var nextband: [128]u8 = undefined;
    var prev: i32 = -1;
    coder.initNextbandMap(sce, &nextband);
    var w: usize = 0;
    while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
        for (0..sce.ics.num_swb) |g| {
            const bi = w * 16 + g;
            const typ = sce.band_type[bi];
            if (typ == bt.noise or typ == bt.intensity or typ == bt.intensity2) continue;
            if (sce.zeroes[bi] != 0) {
                sce.band_type[bi] = 0;
                continue;
            }
            if (prev != -1) sce.sf_idx[bi] = clip(sce.sf_idx[bi], prev - scale_max_diff, prev + scale_max_diff);
            sce.band_type[bi] = coder.findMinBook(t.maxvals[bi], sce.sf_idx[bi]);
            if (sce.band_type[bi] <= 0) {
                if (!coder.sfdeltaCanRemoveBand(sce, &nextband, prev, bi)) {
                    sce.band_type[bi] = 1;
                } else {
                    for (0..sce.ics.group_len[w]) |w2| sce.zeroes[(w + w2) * 16 + g] = 1;
                    sce.band_type[bi] = 0;
                    continue;
                }
            }
            if (prev == -1) sce.sf_idx[0] = sce.sf_idx[bi]; // the global gain
            prev = sce.sf_idx[bi];
        }
    }
    // Every band carries a chain-legal scalefactor.
    if (prev != -1) {
        var last = sce.sf_idx[0];
        w = 0;
        while (w < sce.ics.num_windows) : (w += sce.ics.group_len[w]) {
            for (0..sce.ics.num_swb) |g| {
                const bi = w * 16 + g;
                if (sce.zeroes[bi] == 0 and sce.band_type[bi] != bt.noise and sce.band_type[bi] < bt.reserved) {
                    last = sce.sf_idx[bi];
                } else if (sce.band_type[bi] < bt.reserved and bi > 0) {
                    sce.sf_idx[bi] = last;
                }
            }
        }
    }
}

/// What a solve group needs from search_for_quantizers_nmr.
const Rc = struct {
    eligible: bool,
    global: bool,
    rate_frame: i32,
    bmax: i32,
};

/// nmr_solve_group: one element group (a channel, or a CPE's pair pooled
/// under one lambda and one budget), then PNS and the commit.
fn solveGroup(e: *Encoder, n: *State, lambda: f32, sl: []const *Slot, chans: i32, rc: Rc) void {
    const cstep: i32 = coarse;
    const gq = e.opt.global_quality;
    const channels: i32 = e.channels;
    const br: f64 = @floatFromInt(e.bit_rate);
    const sr: f64 = @floatFromInt(e.sample_rate);
    const chans_d: f64 = @floatFromInt(chans);
    const channels_d: f64 = @floatFromInt(channels);
    const bch: f64 = if (e.opt.qscale) 2 else channels_d;
    const lam_rel: f64 = lambda / 120.0;
    var destbits = toInt(br * 1024.0 / sr / bch * lam_rel * chans_d);
    var is8_any = false;
    var lam: f32 = undefined;
    var rc_off: f32 = 1.0;
    // The outer loop's starting lambda: the legality caps scale with lambda
    // relative to it.
    const lam_ref: f32 = if (e.opt.qscale and gq > 0) @floatFromInt(gq) else 120.0;

    for (sl) |t| is8_any = is8_any or t.is8;

    // Solo solves of a multichannel stream keep per-channel slew state.
    var vslew_st: *f32 = &n.lam_slew;
    if (sl.len == 1 and e.channels > 1) {
        vslew_st = &n.lam_slew_ch[sl[0].cur_ch & 15];
        if (vslew_st.* <= 0) vslew_st.* = n.lam_slew;
    }

    const alloc = e.psy.bitres.alloc;
    if (alloc >= 0) {
        const gqd: f32 = @floatFromInt(if (gq != 0) gq else 120);
        destbits = toInt(f(alloc) * (lambda / gqd) * f(chans));
    }
    if (rc.global and alloc >= 0) {
        // The CBR target: nominal plus repayment, bounded to 30% a frame.
        const rr = br * 1024.0 / sr;
        const fill_d: f64 = @floatFromInt(n.rc_fill);
        destbits = toInt((rr + clipd(fill_d / 2.0, -0.3 * rr, 0.3 * rr)) * chans_d / channels_d);
    } else if (rc.eligible and alloc >= 0) {
        // Frames before the corridor's bootstrap target the nominal rate.
        destbits = toInt(br * 1024.0 / sr * chans_d / channels_d);
    }
    destbits = @min(destbits, 5800 * chans);
    // The measured non-trellis overhead comes off the budget. C's int
    // arithmetic wraps on the reference build (notes.md "Follow the
    // reference build"): a budget converted from an out-of-range quality
    // is INT_MIN.
    if (n.side_inited) destbits = clip(destbits -% toInt(n.side_ema * f(chans) / f(channels)), 64, 5800 * chans);

    // A held transient burst spends banked bits.
    if (n.run_burst > 1.0) {
        const extra = toInt(f(destbits) * (n.run_burst - 1.0));
        const bank: i64 = n.rc_fill + @divTrunc(rc.bmax, 2);
        // C converts the int64 quotient to int.
        const avail32: i32 = @truncate(@divTrunc(bank * chans, channels));
        const avail = @max(0, avail32);
        destbits = clip(destbits +% @min(extra, avail), 64, 6800 * chans);
    }

    var vbr = e.opt.qscale;
    const abr = !vbr and e.opt.rc == 1 and e.bit_rate > 0;
    var vbr_subst = true;
    var vbr_t: f32 = 0;
    if (abr) {
        // ABR: the quality-target solve, its set-point the rate servo's.
        vbr_t = n.abr_t;
        vbr = true;
    } else if (vbr) {
        // The noise-to-mask target of -q:a.
        const q: f32 = if (gq > 0) f(gq) / 118.0 else 1.0;
        vbr_t = fmax(vbr_anchor - 1.2 * libm.log2f(q), vbr_tmin);
    }
    if (vbr and is8_any) {
        // Short frames bisect an offset target, warm off the surrounding
        // operating point, and write no solver state.
        const lam0: f32 = if (vslew_st.* > 0) fmin(vslew_st.*, 1e4) else 0;
        const infl = &n.vbr_infl[sl[0].cur_ch & 15];
        if (lam0 > 0) {
            _ = evalSlots(n, sl, cstep, lam0);
            const st0 = ndStat(n, sl);
            var ehf: f32 = 0;
            var etot: f32 = 0;
            const sr4 = f(@intCast(e.sample_rate)) * 4.0;
            for (sl) |t| {
                for (t.act[0..t.nact]) |b| {
                    const bi = t.bidx[b];
                    const en = t.pener[bi];
                    const bin: i32 = @intCast(t.bst[b] - t.bw[b] * 128);
                    etot += en;
                    if (f(bin) * sr4 / 1024.0 > 6000.0) ehf += en;
                }
            }
            const hfw: f32 = if (etot > 0) clipf(ehf / (etot * infl_hf), 0.0, 1.0) else 1.0;
            infl.* = if (std.math.isNan(st0)) 0 else clipf(st0 - vbr_t, 0.0, 4.0) * hfw;
        }
        if (lam0 > 0) {
            lam = solveSlotsNd(n, sl, cstep, vbr_t + infl.*, lam0 / 32.0, fmin(lam0 * 32.0, 1e4), iters_warm + 2);
        } else {
            lam = solveSlotsNd(n, sl, cstep, vbr_t, 1e-9, 1e4, iters_full);
        }
        if (lam0 > 0) {
            const kup: f32 = if (n.prev_was_short) slew_run else slew;
            if (lam > lam0 * kup or lam < lam0 / 4.0) {
                lam = clipf(lam, lam0 / 4.0, lam0 * kup);
                _ = evalSlots(n, sl, cstep, lam);
            }
        }
        vbr_subst = false;
    } else if (vbr) {
        // Warm-started off the previous frame's lambda.
        var lam0 = n.lam[sl[0].cur_ch];
        lam = 1.0;
        if (lam0 > 0) {
            lam0 = fmin(lam0, 1e4);
            lam = solveSlotsNd(n, sl, cstep, vbr_t, lam0 / 32.0, fmin(lam0 * 32.0, 1e4), iters_warm + 2);
            if (lam < lam0 / 16.0 or lam > lam0 * 16.0) lam0 = 0;
        }
        if (lam0 <= 0) lam = solveSlotsNd(n, sl, cstep, vbr_t, 1e-9, 1e4, iters_full);
    } else if (rc.global) {
        // The corridor bisection around the servoed centre.
        const r: f32 = @floatCast(br * 1024.0 / sr);
        rc_off = libm.exp2f(-rc_k_cbr * f(n.rc_fill) / r);
        const cen = n.lam_rc * rc_off;
        var lo = cen / rc_corr;
        if (is8_any and n.run_burst > 1.0) lo /= n.run_burst;
        lam = solveSlots(n, sl, cstep, destbits, lo, cen * rc_corr, rc_citers);

        var tot = groupBits(n, sl, cstep);
        const hardcap = clip(toInt(5800.0 * fmin(1.0, lambda / 120.0)), 256, 5800) * chans;
        const rc_cap = @min(hardcap, @divTrunc((n.rc_fill + rc.rate_frame + rc.bmax) * chans, channels));
        if (tot > rc_cap) {
            lam = solveSlots(n, sl, cstep, rc_cap, lam, lam * rc_capk, iters_coarse);
            tot = groupBits(n, sl, cstep);
            if (tot > rc_cap and n.rc_fill <= -@divTrunc(rc.bmax * 9, 10)) {
                // The bound escalates with consecutive saturated frames.
                const ek = rc_capk * f(1 + @min(n.rc_satrun, 8));
                lam = solveSlots(n, sl, cstep, rc_cap, lam, lam * ek, iters_coarse);
                n.rc_sat_frame = true;
                tot = groupBits(n, sl, cstep);
            }
            if (tot > hardcap) lam = solveSlots(n, sl, cstep, hardcap, lam, 1e4, iters_coarse);
        }
    } else {
        // Per-frame bisection, warm-started off the previous frame's
        // lambda; a result at the bracket's edge redoes the full search.
        var lam0 = n.lam[sl[0].cur_ch];
        lam = 1.0;
        if (lam0 > 0) {
            lam = solveSlots(n, sl, cstep, destbits, lam0 / 32.0, lam0 * 32.0, iters_warm);
            if (lam < lam0 / 16.0 or lam > lam0 * 16.0) lam0 = 0;
        }
        if (lam0 <= 0) lam = solveSlots(n, sl, cstep, destbits, 1e-9, 1e4, iters_coarse);
    }

    // PASS 2: each band refined at full granularity around its coarse
    // pick, then the solve again.
    {
        const win: i32 = coarse - clip(e.opt.nmr_speed, 0, 4);
        for (sl) |t| {
            if (t.nact == 0) continue;
            const sce = t.sce.?; // set by setupChannel
            const c = curves(n, t);
            // The pow34 spectrum and the cost cache are per channel.
            coder.absPow34(&e.scoefs, &sce.coeffs);
            e.costCacheInit();
            for (0..t.nbnd) |b| {
                const bi = t.bidx[b];
                const center = sfAt(t, b, cstep);
                const flo = clip(center - win, clip(t.minsf[bi], 0, scale_max_pos), scale_max_pos);
                const maxn: usize = @intCast(@min(ncand, @divTrunc(2 * win, fine) + 1));
                const invthr = 1.0 / fmax(t.thr[bi], 1e-9);
                const nc = bandCurve(e, sce, t.bw[b], t.bg[b], t.bst[b], flo, fine, maxn, invthr, t.maxvals[bi], &c.nd[b], &c.nb[b]);
                if (t.tnsg[bi] > 1.0) {
                    for (c.nd[b][0..nc]) |*d| d.* *= t.tnsg[bi];
                }
                t.blo[b] = flo;
                // A band with no candidate keeps one: its coarse curve's
                // first, as FFmpeg's does.
                t.bnc[b] = @max(1, nc);
            }
        }
        // The fine pass: a narrow corridor around the coarse solve.
        if (vbr and !vbr_subst) {
            const infl2: f32 = if (is8_any) n.vbr_infl[sl[0].cur_ch & 15] else 0;
            lam = solveSlotsNd(n, sl, fine, vbr_t + infl2, lam / 32.0, fmin(lam * 32.0, 1e4), iters_fine);
        } else if (vbr) {
            lam = solveSlotsNd(n, sl, fine, vbr_t, lam / 32.0, fmin(lam * 32.0, 1e4), iters_fine);
        } else if (rc.global) {
            lam = solveSlots(n, sl, fine, destbits, lam / 2.0, lam * 2.0, rc_fiters);
        } else {
            lam = solveSlots(n, sl, fine, destbits, lam / 16.0, lam * 16.0, iters_fine);
        }
    }

    const lam_dem = lam; // the demand-solved lambda

    if (vbr) {
        // The quality slew; low-content frames neither clamp nor write
        // solver state.
        var nact_sum: usize = 0;
        const st_fin = ndStat(n, sl);
        for (sl) |t| nact_sum += t.nact;
        const subst = vbr_subst and nact_sum >= 8 and !std.math.isNan(st_fin) and
            st_fin > vbr_t - 0.5 and st_fin < vbr_t + 0.5;
        if (subst) {
            if (vslew_st.* > 0) {
                if (lam > vslew_st.* * slew or lam < vslew_st.* / slew) {
                    lam = clipf(lam, vslew_st.* / slew, vslew_st.* * slew);
                    _ = evalSlots(n, sl, fine, lam);
                }
            }
            n.lam_slew = lam;
            vslew_st.* = lam;
        } else if (is8_any and vslew_st.* > 0) {
            const kup: f32 = if (n.prev_was_short) slew_run else slew;
            const lam0 = fmin(vslew_st.*, 1e4);
            if (lam > lam0 * kup or lam < lam0 / 4.0) {
                lam = clipf(lam, lam0 / 4.0, lam0 * kup);
                _ = evalSlots(n, sl, fine, lam);
            }
        }
        vbr_subst = subst;
    }
    if (vbr) {
        // Legality only: a frame never exceeds the reservoir's bound.
        var hardcap = clip(toInt(5800.0 * fmin(1.0, lambda / lam_ref)), 256, 5800) * chans;
        if (n.side_inited) hardcap = @max(hardcap - toInt(fmax(n.side_ema, 0.0) * f(chans) / f(channels)), 256);
        var tot = groupBits(n, sl, fine);
        if (abr and n.abr_ema < f(rc.rate_frame)) {
            // The bits fill: an easy frame topped up toward the ask by a
            // finer lambda only, shaped by the psy demand.
            var dshape: f32 = 1.0;
            if (alloc > 0) {
                const aema = &n.abr_alloc_ema;
                if (aema.* <= 0) aema.* = f(alloc) else aema.* += 0.01 * (f(alloc) - aema.*);
                dshape = clipf(f(alloc) / aema.*, 0.6, 1.7);
            }
            var fill = @divTrunc(toInt(f(rc.rate_frame + (rc.rate_frame - toInt(n.abr_ema))) * dshape) * chans, channels);
            fill = @min(@min(fill, @divTrunc(@divTrunc(3 * rc.rate_frame * chans, channels), 2)), hardcap);
            if (tot < fill) {
                var flo = lam / 64.0;
                if (vslew_st.* > 0) flo = fmin(fmax(flo, vslew_st.* / slew), lam);
                lam = solveSlots(n, sl, fine, fill, flo, lam, rc_iters);
                if (!is8_any) {
                    n.lam_slew = lam;
                    vslew_st.* = lam;
                }
                tot = groupBits(n, sl, fine);
            }
        }
        if (tot > hardcap) {
            lam = solveSlots(n, sl, fine, hardcap, lam, 1e4, rc_iters);
            tot = groupBits(n, sl, fine);
            // Shed the highest bands until the frame fits; the first band
            // anchors the scalefactor chain and stays.
            while (tot > hardcap) {
                var dropped = false;
                for (sl) |t| {
                    if (t.nact <= 1) continue;
                    const sce = t.sce.?; // set by setupChannel
                    var hi: usize = 1;
                    for (2..t.nact) |k| {
                        if (t.bg[t.act[k]] >= t.bg[t.act[hi]]) hi = k;
                    }
                    const b = t.act[hi];
                    const w0 = t.bw[b];
                    const g = t.bg[b];
                    for (0..sce.ics.group_len[w0]) |w2| sce.zeroes[(w0 + w2) * 16 + g] = 1;
                    std.mem.copyForwards(usize, t.act[hi .. t.nact - 1], t.act[hi + 1 .. t.nact]);
                    t.nact -= 1;
                    dropped = true;
                }
                if (!dropped) break;
                tot = evalSlots(n, sl, fine, lam);
            }
        }
    }

    if (rc.global) {
        // The reservoir cap on the fine grid, then the slew limiter.
        const hardcap = clip(toInt(5800.0 * fmin(1.0, lambda / 120.0)), 256, 5800) * chans;
        var tot = groupBits(n, sl, fine);
        const rc_cap = @min(hardcap, @divTrunc((n.rc_fill + rc.rate_frame + rc.bmax) * chans, channels));
        // FFmpeg leaves `tot` at the pre-solve count for the floor below.
        if (tot > rc_cap) lam = solveSlots(n, sl, fine, rc_cap, lam, 1e4, rc_iters);
        {
            // The bucket-full spend floor.
            const headroom = rc.bmax - clip(n.rc_fill, -rc.bmax, rc.bmax);
            const fbits = @divTrunc((rc.rate_frame - headroom) * chans, channels);
            if (tot < fbits) {
                lam = solveSlots(n, sl, fine, fbits, lam / 64.0, lam, rc_iters);
                tot = groupBits(n, sl, fine);
            }
        }
        if (n.lam_slew > 0) {
            const kup: f32 = if (is8_any and n.prev_was_short) slew_run else slew;
            const kdn: f32 = if (is8_any and n.run_burst > 1.0)
                slew * n.run_burst
            else if (is8_any and n.prev_was_short) slew_run else slew;
            if (lam > n.lam_slew * kup or lam < n.lam_slew / kdn) {
                lam = clipf(lam, n.lam_slew / kdn, n.lam_slew * kup);
                tot = evalSlots(n, sl, fine, lam);
                if (tot > rc_cap) lam = solveSlots(n, sl, fine, rc_cap, lam, 1e4, rc_iters);
            }
        }
        n.lam_slew = lam;
    } else if (rc.eligible and !vbr) {
        // Before the corridor's bootstrap: the same spend floor.
        const headroom = rc.bmax - clip(n.rc_fill, -rc.bmax, rc.bmax);
        const fbits = @divTrunc((rc.rate_frame - headroom) * chans, channels);
        const tot = groupBits(n, sl, fine);
        if (tot < fbits) lam = solveSlots(n, sl, fine, fbits, lam / 64.0, lam, rc_iters);
    }

    if (!vbr or vbr_subst) {
        for (sl) |t| n.lam[t.cur_ch] = lam; // the next frame's warm start
    }
    {
        // nd: the mean achieved distortion over the real mask.
        var ndsum: f32 = 0;
        var ndn: i32 = 0;
        for (sl) |t| {
            const nd = &n.nd[t.si];
            for (t.act[0..t.nact]) |b| {
                const bi = t.bidx[b];
                if (t.thr_real[bi] > 0 and t.thr[bi] > 0 and !t.hftx[bi]) {
                    ndsum += nd[b][t.chosen[b]] * t.thr[bi] / t.thr_real[bi];
                    ndn += 1;
                }
            }
        }
        // Long frames only.
        if (ndn >= 8 and !is8_any) {
            const nd = ndsum / f(ndn);
            n.nd_ema = if (n.nd_ema > 0) 0.95 * n.nd_ema + 0.05 * nd else nd;
        }
    }
    {
        // Short and long operating lambdas, and the strain floor.
        const ema = if (is8_any) &n.lam_short_ema else &n.lam_long_ema;
        ema.* = if (ema.* > 0) 0.9 * ema.* + 0.1 * lam else lam;
        // fminf.
        n.lam_floor = if (n.lam_floor > 0) @min(n.lam_floor * 1.02, lam) else lam;
    }
    {
        // The shared rate-pressure ramp.
        const scale = 1.0 + clipf(n.nd_ema / 50.0, 0.0, 8.0);
        var ramp: f32 = if (n.lam_long_ema > 0)
            clipf((n.lam_long_ema - 120.0 * scale) / (350.0 * scale - 120.0 * scale), 0.0, 1.0)
        else
            0;
        if (n.nd_ema > 0) ramp *= clipf((n.lam_long_ema * n.nd_ema - 60.0) / (120.0 - 60.0), 0.0, 1.0);
        n.press = ramp;
    }
    if (rc.global) {
        // The centre tracks the content's lambda.
        const cc = n.lam_rc * libm.powf(lam_dem / rc_off / n.lam_rc, rc_track);
        n.lam_rc = clipf(cc, 1e-6, 1e4);
    } else if (rc.eligible) {
        // The servo's bootstrap, off the first substantive frame.
        var nbnd_max: usize = 0;
        for (sl) |t| nbnd_max = @max(nbnd_max, t.nbnd);
        if (nbnd_max >= 8) {
            n.lam_rc = clipf(lam, 1e-4, 1e4);
            n.lam_slew = n.lam_rc;
        }
    }

    {
        // PNS, per channel at the group's operating lambda.
        var pns_total: i32 = 0;
        for (sl) |t| {
            const sce = t.sce.?; // set by setupChannel
            const nd = &n.nd[t.si];
            const nb = &n.nb[t.si];
            const ci = t.cur_ch & 15;
            var pns_count: i32 = 0;
            // Band 0 anchors the global gain and the scalefactor chain.
            for (1..t.nbnd) |b| {
                const bi = t.bidx[b];
                const spread = t.pspread[bi];
                // A coded band is zero only when shed for legality.
                if (sce.can_pns[bi] == 0 or sce.zeroes[bi] != 0) continue;
                const was = n.pns_prev[ci][bi] != 0;
                const bias: f32 = if (was) pns_stay else pns_enter;
                var want = false;
                var force_exit = false;
                const ndv = nd[b][t.chosen[b]];
                if (t.pener[bi] > pns_max_et * t.thr_real[bi]) {
                    force_exit = true; // the loud-band guard
                } else if (lam > pns_hole_lam and
                    ndv * t.thr[bi] / fmax(t.pener[bi], 1e-9) > pns_hole_frac * @as(f32, if (was) 0.7 else 1.0) and
                    spread > pns_hole_spread)
                {
                    want = true; // the spectral-hole fill
                } else if (lam > pns_lam) {
                    if (ndv * t.thr[bi] > pns_ndgate * t.thr_real[bi] * @as(f32, if (was) 0.5 else 1.0)) {
                        const nmr_pns = fmax(0.0, t.pener[bi] * (1.0 - spread * spread)) / fmax(t.thr[bi], 1e-9);
                        const cost_keep = ndv + lam * f(nb[b][t.chosen[b]]);
                        const cost_pns = nmr_pns + lam * pns_bits;
                        want = cost_pns < cost_keep * bias;
                    }
                }
                // Debounce.
                const ron = &n.pns_run_on[ci][bi];
                const roff = &n.pns_run_off[ci][bi];
                const near = t.pener[bi] < 2.0 * t.thr_real[bi];
                if (want) {
                    if (ron.* < 255) ron.* += 1;
                    roff.* = 0;
                } else {
                    if (roff.* < 255) roff.* += 1;
                    ron.* = 0;
                }
                if (force_exit) {
                    want = was and roff.* < 2;
                } else if (!was) {
                    want = ron.* >= @as(u8, if (near) 2 else pns_on);
                } else if (near) {
                    want = true;
                } else {
                    want = !(roff.* >= pns_off);
                }
                if (want) {
                    t.is_pns[b] = true;
                    pns_count += 1;
                }
            }
            if (pns_count != 0) {
                // Filter the active list: bands shed for legality stay out.
                var m: usize = 0;
                for (0..t.nact) |k| {
                    if (!t.is_pns[t.act[k]]) {
                        t.act[m] = t.act[k];
                        m += 1;
                    }
                }
                t.nact = m;
            }
            pns_total += pns_count;
        }
        if (pns_total != 0) {
            if (rc.global or vbr) {
                _ = evalSlots(n, sl, fine, lam);
            } else {
                // C's int arithmetic wraps on the reference build (notes.md
                // "Follow the reference build"), from an INT_MIN budget.
                _ = solveSlots(n, sl, fine, destbits -% pns_total * pns_bits, 1e-9, 1e4, iters_full);
            }
        }
    }

    for (sl) |t| {
        var now: [128]u8 = @splat(0);
        for (0..t.nbnd) |b| {
            if (t.is_pns[b]) now[t.bidx[b]] = 1;
        }
        n.pns_prev[t.cur_ch & 15] = now;
    }
    for (sl) |t| commitChannel(n, t);
}

/// search_for_quantizers_nmr for the channel `e.cur_channel`; `frame_num`
/// is the codec context's.
pub fn searchForQuantizers(e: *Encoder, sce: *Sce, lambda: f32, frame_num: i64) void {
    const n = e.nmr.?; // allocated by Encoder.init for this coder
    const channels: i32 = e.channels;
    const br: f64 = @floatFromInt(e.bit_rate);
    const sr: f64 = @floatFromInt(e.sample_rate);
    // Global-lambda rate control (CBR); not for -q:a, ABR or the bootstrap.
    const rc_eligible = !e.opt.qscale and e.bit_rate > 0 and bit_rate_tolerance != 0 and e.opt.rc == 0;
    const rc_rate_frame = toInt(br * 1024.0 / sr);
    const rc_bmax = @min(@max(6144 * channels - rc_rate_frame, 256), cbr_buf * channels);

    n.counted[e.cur_channel] = 0;

    if (e.opt.rc == 1 and !e.opt.qscale and e.bit_rate > 0 and frame_num != n.abr_frame_num) {
        // The ABR servo: the log rate error integrated, applied to the
        // set-point in rare, discrete steps.
        const rrf = f(rc_rate_frame);
        if (n.abr_frame_num == 0 and n.abr_ema <= 0) {
            // The set-point seeded from the quality anchor.
            const bps: f32 = @floatFromInt(e.bit_rate);
            n.abr_t = clipf(vbr_anchor - 2.5 * libm.log2f(bps / (81500.0 * f(channels))), abr_tmin, abr_tmax);
            n.abr_ema = rrf;
        } else if (e.last_frame_pb_count > 0) {
            if (n.abr_ema <= 0) n.abr_ema = rrf;
            n.abr_ema += (if (n.abr_booted) abr_ema_k else 0.02) * (f(e.last_frame_pb_count) - n.abr_ema);
            // C's int counters wrap on the reference build (notes.md
            // "Follow the reference build").
            n.abr_hold +%= 1;
            if (!n.abr_booted) {
                n.abr_longs +%= @intFromBool(sce.ics.window_sequence[0] != .eight_short);
                // Boot only off a representative window, or eventually.
                if ((n.abr_hold >= 86 and n.abr_longs >= @divTrunc(n.abr_hold, 2)) or n.abr_hold >= 400) {
                    n.abr_glide = abr_boot_gain * libm.log2f(n.abr_ema / rrf) / 0.24;
                    n.abr_booted = true;
                    n.abr_boots += 1;
                    n.abr_hold = 0;
                }
            } else {
                // Re-arm the open-loop correction while the rate is off.
                if (n.abr_boots < abr_boots_max and n.abr_glide == 0 and n.abr_hold >= abr_settle and
                    @abs(libm.log2f(n.abr_ema / rrf)) > abr_tol)
                {
                    n.abr_booted = false;
                    n.abr_ema = rrf;
                    n.abr_acc = 0;
                    n.abr_hold = 0;
                    n.abr_longs = 0;
                } else {
                    n.abr_acc = clipf(n.abr_acc + abr_k * libm.log2f(n.abr_ema / rrf), -4.0 * abr_step, 4.0 * abr_step);
                    // Step in calm stretches, or after three holds anyway.
                    if (@abs(n.abr_acc) >= abr_step and n.abr_hold >= abr_hold_frames and
                        (n.frames_since_short >= 12 or n.abr_hold >= 3 * abr_hold_frames))
                    {
                        const ms = abr_step * @as(f32, if (@abs(n.abr_acc) > 3.0 * abr_step) 2.0 else 1.0);
                        const step = clipf(n.abr_acc, -ms, ms);
                        n.abr_glide += step;
                        n.abr_acc -= step;
                        n.abr_hold = 0;
                    }
                }
            }
            if (n.abr_glide != 0) {
                // Pending corrections drain smoothly.
                const d = clipf(n.abr_glide, -0.012, 0.012);
                n.abr_t = clipf(n.abr_t + d, abr_tmin, abr_tmax);
                n.abr_glide -= d;
                if (@abs(n.abr_glide) < 1e-4) n.abr_glide = 0;
            }
        }
        n.abr_frame_num = frame_num;
    }
    if (rc_eligible and !n.rc_fill_seeded) {
        // The decoder's bit reservoir starts full.
        n.rc_fill = rc_bmax;
        n.rc_fill_seeded = true;
    }
    if (rc_eligible and frame_num != n.rc_frame_num) {
        if (n.rc_frame_num > 0 and n.lam_rc > 0) n.rc_fill = clip(n.rc_fill + rc_rate_frame - e.last_frame_pb_count, -rc_bmax, rc_bmax);
        n.rc_frame_num = frame_num;
        n.pending = false; // a deferred first channel never crosses a frame
        // Consecutive saturated frames, wrapping as C's int does.
        n.rc_satrun = if (n.rc_sat_frame) n.rc_satrun +% 1 else 0;
        n.rc_sat_frame = false;
        // The rate-control mode, latched per frame.
        n.rc_gl = rc_eligible and n.lam_rc > 0;
    }
    if (frame_num != n.win_frame_num) {
        // The window history, once per frame: the transient burst state,
        // set at a run's start and held across it.
        const is_short = sce.ics.window_sequence[0] == .eight_short;
        n.win_frame_num = frame_num;
        if (is_short) {
            if (!n.prev_was_short) {
                if (n.frames_since_short >= burst_gap) {
                    n.run_burst = burst_gain;
                } else {
                    // The dense-beat boost, scaled by the short frames'
                    // measured starvation.
                    var imb: f32 = 0;
                    if (n.lam_long_ema > 0 and n.lam_short_ema > 0) imb = clipf(n.lam_short_ema / n.lam_long_ema - 1.0, 0.0, 1.0);
                    n.run_burst = 1.0 + (short_boost - 1.0) * imb * f(n.frames_since_short) / burst_gap;
                }
            }
            n.frames_since_short = 0;
        } else {
            // The frame closing a run takes half the run's factor.
            n.run_burst = if (n.prev_was_short) @sqrt(n.run_burst) else 1.0;
            // C's int counter wraps on the reference build (notes.md
            // "Follow the reference build").
            n.frames_since_short +%= 1;
        }
        n.prev_was_short = is_short;
    }
    const rc_global = rc_eligible and n.rc_gl;

    // The CPE budget pool: under global-lambda RC the pair's first channel
    // waits for the second, and both solve against one budget.
    const defer_pair = n.pair and rc_global;
    const si: usize = if (defer_pair and n.pending) 1 else 0;
    const t = &n.slot[si];
    t.si = si;

    if (setupChannel(e, n, sce, t) == 0) {
        bailChannel(sce);
        t.nbnd = 0;
        t.nact = 0;
    }

    if (defer_pair and !n.pending) {
        n.pending = true; // wait for the partner channel
        return;
    }

    var sl_buf: [2]*Slot = undefined;
    var nsl: usize = 0;
    var chans: i32 = 1;
    if (defer_pair) {
        n.pending = false;
        chans = 2;
        for (&n.slot) |*s| {
            if (s.nact != 0) {
                sl_buf[nsl] = s;
                nsl += 1;
            }
        }
    } else if (t.nact != 0) {
        sl_buf[0] = t;
        nsl = 1;
    }
    if (nsl == 0) return; // nothing codeable in the group
    solveGroup(e, n, lambda, sl_buf[0..nsl], chans, .{
        .eligible = rc_eligible,
        .global = rc_global,
        .rate_frame = rc_rate_frame,
        .bmax = rc_bmax,
    });
}

// nmr_decide_stereo and its band helpers (aacenc.c).

/// nmr_apply_ms_band: one band's window group recoded as mid and side.
fn applyMsBand(e: *Encoder, cpe: *Cpe, w: usize, g: usize, start: usize, len: usize, gl: usize) void {
    cpe.ms_mask[w * 16 + g] = 1;
    for (0..gl) |w2| {
        const b0 = &e.psy.channels[e.cur_channel].bands[(w + w2) * 16 + g];
        const b1 = &e.psy.channels[e.cur_channel + 1].bands[(w + w2) * 16 + g];
        const l = cpe.ch[0].coeffs[start + (w + w2) * 128 ..][0..len];
        const r = cpe.ch[1].coeffs[start + (w + w2) * 128 ..][0..len];
        var em: f32 = 0;
        var es: f32 = 0;
        for (l, r) |*lv, *rv| {
            const m = (lv.* + rv.*) * 0.5;
            rv.* = m - rv.*;
            lv.* = m;
            em += lv.* * lv.*;
            es += rv.* * rv.*;
        }
        b0.threshold = fmin(b0.threshold, b1.threshold) * 0.5;
        b1.threshold = b0.threshold;
        b0.energy = em;
        b1.energy = es;
    }
}

const ImageTest = struct { ratio: f32, scale: f32, sr: f32, p: i32 };

/// nmr_is_image_masked: the intensity reconstruction's image error
/// against the pair's masks; null when the carrier has no energy.
fn isImageMasked(cpe: *const Cpe, w: usize, start: usize, len: usize, gl: usize, ener0: f32, ener1: f32, dot: f32, minthr0: f32, minthr1: f32) ?ImageTest {
    const p: i32 = if (dot >= 0) 1 else -1;
    const pf = f(p);
    const ener01 = ener0 + ener1 + f(2 * p) * dot; // energy of L + p*R
    if (ener01 <= flt_min) return null;
    const scale = @sqrt(ener0 / ener01); // carrier = (L + p*R)*scale
    const sr_ = @sqrt(ener1 / ener0); // decoder: R = p*sr_*carrier
    var img0: f32 = 0;
    var img1: f32 = 0;
    for (0..gl) |w2| {
        const l = cpe.ch[0].coeffs[start + (w + w2) * 128 ..][0..len];
        const r = cpe.ch[1].coeffs[start + (w + w2) * 128 ..][0..len];
        for (l, r) |lv, rv| {
            const c = (lv + pf * rv) * scale;
            const dl = lv - c;
            const dr = rv - pf * sr_ * c;
            img0 += dl * dl;
            img1 += dr * dr;
        }
    }
    const glf = f(@intCast(gl));
    return .{
        .ratio = fmax(img0 / fmax(minthr0 * glf, flt_min), img1 / fmax(minthr1 * glf, flt_min)),
        .scale = scale,
        .sr = sr_,
        .p = p,
    };
}

/// nmr_apply_is_band: one band's window group recoded as intensity
/// stereo, the pair's masking folded into the carrier.
fn applyIsBand(e: *Encoder, cpe: *Cpe, w: usize, g: usize, start: usize, len: usize, gl: usize, it: ImageTest, ener0: f32, ener1: f32) void {
    const pf = f(it.p);
    cpe.is_mask[w * 16 + g] = 1;
    cpe.ch[0].is_ener[w * 16 + g] = it.scale;
    cpe.ch[1].is_ener[w * 16 + g] = ener0 / ener1;
    cpe.ch[1].band_type[w * 16 + g] = if (it.p > 0) bt.intensity else bt.intensity2;
    for (0..gl) |w2| {
        const b0 = &e.psy.channels[e.cur_channel].bands[(w + w2) * 16 + g];
        const b1 = &e.psy.channels[e.cur_channel + 1].bands[(w + w2) * 16 + g];
        const l = cpe.ch[0].coeffs[start + (w + w2) * 128 ..][0..len];
        const r = cpe.ch[1].coeffs[start + (w + w2) * 128 ..][0..len];
        var ec: f32 = 0;
        for (l, r) |*lv, *rv| {
            lv.* = (lv.* + pf * rv.*) * it.scale;
            rv.* = 0;
            ec += lv.* * lv.*;
        }
        b0.threshold = fmin(b0.threshold, b1.threshold / fmax(it.sr * it.sr, 1e-9));
        b0.energy = ec;
        b1.energy = 0;
    }
}

/// nmr_decide_stereo: each band's stereo mode (L/R, M/S or intensity)
/// from the psy model, before quantization, applied in place; the pair
/// is `e.cur_channel` and the next channel.
pub fn decideStereo(e: *Encoder, cpe: *Cpe) void {
    const n = e.nmr.?; // allocated by Encoder.init for this coder
    const ics = &cpe.ch[0].ics;
    const nw: f32 = ics.num_windows;
    const freq_mult = f(@intCast(e.sample_rate)) / (1024.0 / nw) / 2.0;
    var is_count: i32 = 0;
    const pair_idx = (e.cur_channel >> 1) & 7;
    // Two state banks per pair, by the window grid.
    const pi = pair_idx * 2 + @intFromBool(ics.num_windows == 8);
    if (!n.sinit[pi]) {
        n.smode[pi] = @splat(0);
        n.sema_em[pi] = @splat(0);
        n.sema_img[pi] = @splat(-1.0);
        n.sinit[pi] = true;
    }

    // I/S engages under sustained strain only.
    const is_ramp = n.press * clipf((n.lam_floor - 40.0) / (120.0 - 40.0), 0.0, 1.0);
    const allow_is = e.opt.intensity_stereo != 0;
    const mid_side = e.opt.mid_side;
    const pidx = (e.cur_channel >> 1) & 15;
    const decoupled = e.psy.pair_decoupled[pidx] != 0;
    var njoint: i32 = 0;
    var nbands: i32 = 0;
    const ch0 = e.cur_channel;

    var w: usize = 0;
    while (w < ics.num_windows) : (w += ics.group_len[w]) {
        var start: usize = 0;
        for (0..ics.num_swb) |g| {
            defer start += ics.swb_sizes[g];
            const len: usize = ics.swb_sizes[g];
            const gl: usize = ics.group_len[w];
            const sidx = w * 16 + g;
            var ener0: f32 = 0;
            var ener1: f32 = 0;
            var dot: f32 = 0;
            var es_tot: f32 = 0;
            var em_tot: f32 = 0;
            var minthr0 = flt_max;
            var minthr1 = flt_max;
            cpe.is_mask[sidx] = 0;
            cpe.ms_mask[sidx] = 0;
            for (0..gl) |w2| {
                const b0 = &e.psy.channels[ch0].bands[(w + w2) * 16 + g];
                const b1 = &e.psy.channels[ch0 + 1].bands[(w + w2) * 16 + g];
                const l = cpe.ch[0].coeffs[start + (w + w2) * 128 ..][0..len];
                const r = cpe.ch[1].coeffs[start + (w + w2) * 128 ..][0..len];
                var el: f32 = 0;
                var er: f32 = 0;
                var em: f32 = 0;
                var es: f32 = 0;
                var d: f32 = 0;
                for (l, r) |lv, rv| {
                    const m = (lv + rv) * 0.5;
                    const sv = m - rv;
                    el += lv * lv;
                    er += rv * rv;
                    em += m * m;
                    es += sv * sv;
                    d += lv * rv;
                }
                ener0 += el;
                ener1 += er;
                dot += d;
                es_tot += es;
                em_tot += em;
                minthr0 = fmin(minthr0, b0.threshold);
                minthr1 = fmin(minthr1, b1.threshold);
            }
            const thr_g = fmin(minthr0, minthr1) * f(@intCast(gl)); // the group's masking budget

            // Clearly wide noise bands stay for PNS.
            {
                var es_w = es_tot;
                var em_w = em_tot;
                const pe = n.sema_es[pi][sidx];
                const pm = n.sema_em[pi][sidx];
                if (pm > 0) {
                    es_w = sdec_ema * pe + (1.0 - sdec_ema) * es_tot;
                    em_w = sdec_ema * pm + (1.0 - sdec_ema) * em_tot;
                }
                if (cpe.ch[0].can_pns[sidx] != 0 and cpe.ch[1].can_pns[sidx] != 0 and es_w > pns_stereo_decorr * em_w) continue;
            }
            cpe.ch[0].can_pns[sidx] = 0;
            cpe.ch[1].can_pns[sidx] = 0;

            const pmode = &n.smode[pi];
            const prev = pmode[sidx];
            const eqgate = ms_equiv * @as(f32, if (prev == 1) 1.5 else 1.0);
            // I/S is a lossy economy: its image-error budget scales with
            // the pressure.
            var imgate = is_img_gate * is_ramp * @as(f32, if (prev == 2) sticky else 1.0);
            // Perceptual I/S on correlated long-window HF bands.
            if (ics.num_windows != 8 and ener0 > flt_min and ener1 > flt_min) {
                const corr = dot / @sqrt(ener0 * ener1);
                if (f(@intCast(start)) * freq_mult > is_perc_freq and
                    @abs(corr) > is_perc_corr * @as(f32, if (prev == 2) 0.9 else 1.0))
                {
                    imgate = fmax(imgate, is_perc_gate * @as(f32, if (prev == 2) sticky else 1.0));
                }
            }
            const ees = &n.sema_es[pi][sidx];
            const eem = &n.sema_em[pi][sidx];
            if (eem.* <= 0) {
                ees.* = es_tot;
                eem.* = em_tot;
            } else {
                ees.* = sdec_ema * ees.* + (1.0 - sdec_ema) * es_tot;
                eem.* = sdec_ema * eem.* + (1.0 - sdec_ema) * em_tot;
            }
            const es_d = ees.*;
            const em_d = eem.*;
            // The balance gate: no M/S on a hard-panned band.
            const bal_ok = fmin(ener0, ener1) > ms_balance * fmax(ener0, ener1);
            const ms_would = mid_side != 0 and
                (mid_side == 1 or ((es_d < eqgate * em_d or es_tot < ms_mask * thr_g) and bal_ok));
            const ms_ok = ms_would and !decoupled;
            const above = f(@intCast(start)) * freq_mult > is_low_limit;
            const image: ?ImageTest = if (above and ener0 > flt_min and ener1 > flt_min)
                isImageMasked(cpe, w, start, len, gl, ener0, ener1, dot, minthr0, minthr1)
            else
                null;
            var is_ok = image != null;
            if (above) {
                // The smoothed image error, updated only while a candidate.
                const eim = &n.sema_img[pi][sidx];
                if (image) |im| {
                    if (eim.* < 0) {
                        eim.* = im.ratio;
                    } else {
                        eim.* = sdec_ema * eim.* + (1.0 - sdec_ema) * fmin(im.ratio, 100.0 * is_img_gate);
                    }
                }
                is_ok = image != null and eim.* >= 0 and eim.* < imgate;
            }

            njoint += @intFromBool(ms_would or is_ok);
            nbands += 1;
            const m_: u8 = if (is_ok and allow_is) 2 else if (ms_ok) 1 else if (is_ok and mid_side != 0) 1 else 0;
            pmode[sidx] = m_;
            n.smode_band[pair_idx][sidx] = m_;
            if (is_ok and allow_is) {
                applyIsBand(e, cpe, w, g, start, len, gl, image.?, ener0, ener1);
                is_count += 1;
            } else if (ms_ok or (is_ok and mid_side != 0)) {
                applyMsBand(e, cpe, w, g, start, len, gl);
            }
        }
    }
    cpe.is_mode = @intFromBool(is_count != 0);

    if (nbands > 0) {
        // The pair's joint-tool candidacy, read next frame by the psy
        // model's pair windowing and the M/S candidacy above.
        const r = f(njoint) / f(nbands);
        const pj = &e.psy.pair_joint[pidx];
        pj.* = if (pj.* > 0) 0.95 * pj.* + 0.05 * r else r;
        e.psy.pair_decoupled[pidx] = @intFromBool(pj.* < (if (e.psy.pair_decoupled[pidx] != 0) 1.3 * decorr_lo else decorr_lo));
    }
}

test "the trellis step picks the first cheapest legal predecessor" {
    // Against a direct search over every predecessor and its difference.
    var prng: std.Random.DefaultPrng = .init(0x6e6d72);
    const random = prng.random();
    var lamsf: [2 * scale_max_diff + 1]f32 = undefined;
    for (&lamsf, aac_tab.scalefactor_bits) |*l, sb| l.* = 0.5 * f(sb);
    for (0..500) |_| {
        var dpp: [ncand]f32 = undefined;
        var node: [ncand]f32 = undefined;
        // Few distinct costs, so ties occur.
        for (&dpp, &node) |*a, *b| {
            a.* = @floatFromInt(random.uintLessThan(u8, 4));
            b.* = @floatFromInt(random.uintLessThan(u8, 4));
        }
        const n_cur = random.intRangeAtMost(usize, 1, ncand);
        const n_prev = random.intRangeAtMost(usize, 1, ncand);
        const step: i32 = if (random.boolean()) 1 else coarse;
        const base = random.intRangeAtMost(i32, -255, 255);
        var dp: [ncand]f32 = undefined;
        var bp: [ncand]u8 = undefined;
        trellisStep(&dp, &bp, &dpp, &node, &lamsf, n_cur, n_prev, base, step, scale_max_diff);
        for (0..n_cur) |o| {
            var best: ?usize = null;
            var bestc = flt_max;
            for (0..n_prev) |op| {
                const oi: i32 = @intCast(o);
                const opi: i32 = @intCast(op);
                const d = base + (oi - opi) * step;
                if (d < -scale_max_diff or d > scale_max_diff) continue;
                const c = dpp[op] + lamsf[@intCast(d + scale_max_diff)];
                if (c < bestc) {
                    bestc = c;
                    best = op;
                }
            }
            if (best) |b| {
                try std.testing.expectEqual(b, bp[o]);
                try std.testing.expectEqual(node[o] + bestc, dp[o]);
            } else {
                try std.testing.expectEqual(0, bp[o]);
                try std.testing.expectEqual(flt_max, dp[o]);
            }
        }
    }
}
