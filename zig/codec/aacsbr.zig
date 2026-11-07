// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aacsbr.c (exp2fi, make_bands,
// sbr_dequant, sbr_hf_inverse_filter, sbr_chirp, sbr_gain_calc,
// sbr_hf_assemble), aacsbr_template.c (sbr_turnoff,
// ff_aac_sbr_ctx_alloc_init, sbr_make_f_tablelim, read_sbr_header,
// check_n_master, sbr_make_f_master, sbr_hf_calc_npatches,
// sbr_make_f_derived, read_sbr_grid, copy_sbr_grid, read_sbr_dtdf,
// read_sbr_invf, read_sbr_envelope, read_sbr_noise, read_sbr_extension,
// read_sbr_single_channel_element, read_sbr_channel_pair_element,
// read_sbr_data, sbr_reset, ff_aac_sbr_decode_extension, sbr_qmf_analysis,
// sbr_qmf_synthesis, sbr_lf_gen, sbr_hf_gen, sbr_x_gen, sbr_mapping,
// sbr_env_estimate, ff_aac_sbr_apply), sbrdsp.c and sbrdsp_template.c (the
// C kernels) at the pinned reference revision, float build.
// Copyright (c) 2008-2009 Robert Swain ( rob opendot cl )
// Copyright (c) 2009-2010 Alex Converse <alex.converse@gmail.com>
// Copyright (c) 2012 Mans Rullgard <mans@mansr.com> (sbrdsp)
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float SBR decoder (TODO.md T30c), HE-AAC v1: the SBR extension
//! payload of an AAC frame's fill element (header, grid, delta coding,
//! inverse filtering modes, envelope and noise scale factors, harmonics),
//! the master and derived frequency band tables, then each frame's
//! 32-band QMF analysis of the AAC output, the high band generated from
//! the low one by FFmpeg's patches and filters, its envelope adjustment
//! and noise and sinusoid addition, and the 64-band QMF synthesis at twice
//! the rate, operation for operation as the pinned decoder computes them.
//!
//! Parametric stereo (T30d) is `codec/aacps.zig`: a mono stream that FFmpeg
//! upmixes (`m4ac.ps == 1`) gets its PS stereo image, or without PS data
//! its left channel copied to the right, as FFmpeg's. USAC's SBR is not
//! ported. The state is FFmpeg's `SpectralBandReplication`, allocated with
//! the channel element; its unsigned (`AAC_SIGNE`) fields keep C's
//! wrapping arithmetic where hostile input can reach it.

const std = @import("std");
const bits = @import("bits.zig");
const vlc = @import("vlc.zig");
const tx = @import("tx.zig");
const float_dsp = @import("float_dsp.zig");
const tab = @import("sbr_tab.zig");
const mpeg4audio = @import("mpeg4audio.zig");
const aacps = @import("aacps.zig");
const libm = @import("../core/libm.zig");
const cconv = @import("../core/cconv.zig");

pub const Error = error{OutOfMemory};

/// The element types, as `enum RawDataBlockType` numbers them.
pub const elem_sce: u3 = 0;
pub const elem_cpe: u3 = 1;
pub const elem_cce: u3 = 2;
pub const elem_lfe: u3 = 3;

const envelope_adjustment_offset = 2;
const noise_floor_offset = 6;
const synthesis_buf_size = (1280 - 128) * 2;
/// `bs_frame_class`.
const fixfix = 0;
const fixvar = 1;
const varfix = 2;
const varvar = 3;
const extension_id_ps = 2;

/// `SpectrumParameters`; `sbr_turnoff` sets every field to 0xff.
const SpectrumParameters = struct {
    bs_start_freq: u8 = 0,
    bs_stop_freq: u8 = 0,
    bs_xover_band: u8 = 0,
    bs_freq_scale: u8 = 0,
    bs_alter_scale: u8 = 0,
    bs_noise_bands: u8 = 0,

    const unset: SpectrumParameters = .{ .bs_start_freq = 0xff, .bs_stop_freq = 0xff, .bs_xover_band = 0xff, .bs_freq_scale = 0xff, .bs_alter_scale = 0xff, .bs_noise_bands = 0xff };

    fn eql(a: SpectrumParameters, b: SpectrumParameters) bool {
        return std.meta.eql(a, b);
    }
};

/// `SBRData`: one channel's bitstream data and state.
const SbrData = struct {
    bs_frame_class: u32 = 0,
    bs_add_harmonic_flag: u32 = 0,
    bs_num_env: u32 = 0,
    bs_freq_res: [9]u8 = @splat(0),
    bs_num_noise: u32 = 0,
    bs_df_env: [9]u8 = @splat(0),
    bs_df_noise: [2]u8 = @splat(0),
    bs_invf_mode: [2][5]u8 = @splat(@splat(0)),
    bs_add_harmonic: [48]u8 = @splat(0),
    bs_amp_res: u32 = 0,
    synthesis_filterbank_samples: [synthesis_buf_size]f32 = @splat(0),
    analysis_filterbank_samples: [1312]f32 = @splat(0),
    synthesis_filterbank_samples_offset: usize = 0,
    /// l_APrev and l_A.
    e_a: [2]i32 = @splat(0),
    /// The chirp factors.
    bw_array: [5]f32 = @splat(0),
    /// The QMF values of the original signal.
    w: [2][32][32][2]f32 = @splat(@splat(@splat(@splat(0)))),
    ypos: u1 = 0,
    y: [2][38][64][2]f32 = @splat(@splat(@splat(@splat(0)))),
    g_temp: [42][48]f32 = @splat(@splat(0)),
    q_temp: [42][48]f32 = @splat(@splat(0)),
    s_indexmapped: [9][48]u8 = @splat(@splat(0)),
    env_facs_q: [9][48]u8 = @splat(@splat(0)),
    env_facs: [9][48]f32 = @splat(@splat(0)),
    noise_facs_q: [3][5]u8 = @splat(@splat(0)),
    noise_facs: [3][5]f32 = @splat(@splat(0)),
    t_env: [9]u8 = @splat(0),
    t_env_num_env_old: u8 = 0,
    t_q: [3]u8 = @splat(0),
    f_indexnoise: u32 = 0,
    f_indexsine: u32 = 0,
};

/// `SpectralBandReplication`, float, without USAC's fields.
pub const Sbr = struct {
    sample_rate: u32 = 0,
    start: bool = false,
    ready_for_dequant: bool = false,
    id_aac: u3 = 0,
    reset: bool = false,
    spectrum_params: SpectrumParameters = .{},
    bs_amp_res_header: u32 = 0,
    bs_limiter_bands: u32 = 0,
    bs_limiter_gains: u32 = 0,
    bs_interpol_freq: u32 = 0,
    bs_smoothing_mode: u32 = 0,
    bs_coupling: u32 = 0,
    /// k0, k1, k2.
    k: [5]u32 = @splat(0),
    /// kx' and kx: the first QMF subband SBR fills, the previous frame's
    /// and this one's.
    kx: [2]u32 = @splat(0),
    /// M' and M: the number of subbands SBR fills.
    m: [2]u32 = @splat(0),
    kx_and_m_pushed: bool = false,
    n_master: u32 = 0,
    data: [2]SbrData = .{ .{}, .{} },
    /// `ps`: the parametric stereo state, allocated with the first PS data
    /// (it starts in the same state either way).
    ps: ?*aacps.Ps = null,
    gpa: std.mem.Allocator,
    /// N_Low and N_High.
    n: [2]u32 = @splat(0),
    n_q: u32 = 0,
    n_lim: u32 = 0,
    f_master: [49]u16 = @splat(0),
    f_tablelow: [25]u16 = @splat(0),
    f_tablehigh: [49]u16 = @splat(0),
    f_tablenoise: [6]u16 = @splat(0),
    f_tablelim: [30]u16 = @splat(0),
    num_patches: u32 = 0,
    patch_num_subbands: [6]u8 = @splat(0),
    patch_start_subband: [6]u8 = @splat(0),
    x_low: [32][40][2]f32 = @splat(@splat(@splat(0))),
    x_high: [64][40][2]f32 = @splat(@splat(@splat(0))),
    x: [2][2][38][64]f32 = @splat(@splat(@splat(@splat(0)))),
    alpha0: [64][2]f32 = @splat(@splat(0)),
    alpha1: [64][2]f32 = @splat(@splat(0)),
    e_origmapped: [8][48]f32 = @splat(@splat(0)),
    q_mapped: [8][48]f32 = @splat(@splat(0)),
    s_mapped: [8][48]u8 = @splat(@splat(0)),
    e_curr: [8][48]f32 = @splat(@splat(0)),
    q_m: [8][48]f32 = @splat(@splat(0)),
    s_m: [8][48]f32 = @splat(@splat(0)),
    gain: [8][48]f32 = @splat(@splat(0)),
    qmf_filter_scratch: [5 * 64]f32 = @splat(0),
    mdct_ana: tx.Mdct,
    mdct: tx.Mdct,

    /// ff_aac_sbr_ctx_alloc_init: a zeroed state in pure upsampling mode,
    /// for an element of type `id_aac`.
    pub fn create(gpa: std.mem.Allocator, id_aac: u3) Error!*Sbr {
        // The synthesis scales the samples back from +/-32768.0, which the
        // analysis scales them up to, as SBR requires.
        var mdct = tx.Mdct.init(gpa, 64, true, @floatCast(1.0 / (64.0 * 32768.0))) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable, // 64 is a supported length
        };
        errdefer mdct.deinit();
        var mdct_ana = tx.Mdct.init(gpa, 64, true, -2.0 * 32768.0) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable, // 64 is a supported length
        };
        errdefer mdct_ana.deinit();
        const s = try gpa.create(Sbr);
        s.* = .{ .mdct = mdct, .mdct_ana = mdct_ana, .gpa = gpa };
        s.kx[0] = s.kx[1];
        s.id_aac = id_aac;
        s.turnoff();
        s.data[0].synthesis_filterbank_samples_offset = synthesis_buf_size - (1280 - 128);
        s.data[1].synthesis_filterbank_samples_offset = synthesis_buf_size - (1280 - 128);
        return s;
    }

    pub fn destroy(s: *Sbr, gpa: std.mem.Allocator) void {
        if (s.ps) |ps| gpa.destroy(ps);
        s.mdct.deinit();
        s.mdct_ana.deinit();
        gpa.destroy(s);
    }

    /// sbr_turnoff: pure upsampling mode.
    fn turnoff(s: *Sbr) void {
        s.start = false;
        s.ready_for_dequant = false;
        // A typo in the specification: kx' starts at 32.
        s.kx[1] = 32;
        s.m[1] = 0;
        s.data[0].e_a[1] = -1;
        s.data[1].e_a[1] = -1;
        s.spectrum_params = .unset;
    }

    // ---- Frequency band tables ----

    /// sbr_make_f_tablelim: the limiter band table.
    fn makeFTablelim(s: *Sbr) void {
        if (s.bs_limiter_bands > 0) {
            const bands_warped = [3]f32{ 1.32715174233856803909, 1.18509277094158210129, 1.11987160404675912501 };
            const lim_bands_per_octave_warped = bands_warped[s.bs_limiter_bands - 1];
            var patch_borders: [7]i16 = @splat(0);
            patch_borders[0] = @intCast(s.kx[1]);
            for (1..s.num_patches + 1) |k| patch_borders[k] = patch_borders[k - 1] + s.patch_num_subbands[k - 1];
            @memcpy(s.f_tablelim[0 .. s.n[0] + 1], s.f_tablelow[0 .. s.n[0] + 1]);
            if (s.num_patches > 1) {
                for (0..s.num_patches - 1) |k| s.f_tablelim[s.n[0] + 1 + k] = @bitCast(patch_borders[1 + k]);
            }
            std.mem.sort(u16, s.f_tablelim[0 .. s.num_patches + s.n[0]], {}, std.sort.asc(u16));
            s.n_lim = s.n[0] +% s.num_patches -% 1;
            var in: usize = 1;
            var out: usize = 0;
            while (out < s.n_lim) {
                const vin: f32 = @floatFromInt(s.f_tablelim[in]);
                if (vin >= @as(f32, @floatFromInt(s.f_tablelim[out])) * lim_bands_per_octave_warped) {
                    out += 1;
                    s.f_tablelim[out] = s.f_tablelim[in];
                    in += 1;
                } else if (s.f_tablelim[in] == s.f_tablelim[out] or !inTable(&patch_borders, s.num_patches, s.f_tablelim[in])) {
                    in += 1;
                    s.n_lim -%= 1;
                } else if (!inTable(&patch_borders, s.num_patches, s.f_tablelim[out])) {
                    s.f_tablelim[out] = s.f_tablelim[in];
                    in += 1;
                    s.n_lim -%= 1;
                } else {
                    out += 1;
                    s.f_tablelim[out] = s.f_tablelim[in];
                    in += 1;
                }
            }
        } else {
            s.f_tablelim[0] = s.f_tablelow[0];
            s.f_tablelim[1] = s.f_tablelow[s.n[0]];
            s.n_lim = 1;
        }
    }

    /// in_table_int16: whether `needle` is among `table[0 ..= last]`.
    fn inTable(table: *const [7]i16, last: u32, needle: u16) bool {
        for (table[0 .. last + 1]) |v| if (v == @as(i16, @bitCast(needle))) return true;
        return false;
    }

    /// sbr_make_f_master: the master frequency band table; false where
    /// FFmpeg returns -1.
    fn makeFMaster(s: *Sbr) bool {
        const spectrum = s.spectrum_params;
        const offset = switch (s.sample_rate) {
            16000 => &tab.sbr_offset[0],
            22050 => &tab.sbr_offset[1],
            24000 => &tab.sbr_offset[2],
            32000 => &tab.sbr_offset[3],
            44100, 48000, 64000 => &tab.sbr_offset[4],
            88200, 96000, 128000, 176400, 192000 => &tab.sbr_offset[5],
            else => return false, // "Unsupported sample rate for SBR"
        };
        const temp: u32 = if (s.sample_rate < 32000) 3000 else if (s.sample_rate < 64000) 4000 else 5000;
        const start_min = ((temp << 7) + (s.sample_rate >> 1)) / s.sample_rate;
        const stop_min = ((temp << 8) + (s.sample_rate >> 1)) / s.sample_rate;
        // Unsigned plus a signed offset: C's conversion, then wrapping.
        s.k[0] = start_min +% @as(u32, @bitCast(@as(i32, offset[spectrum.bs_start_freq & 15])));
        if (spectrum.bs_stop_freq < 14) {
            s.k[2] = stop_min;
            var stop_dk: [13]i16 = undefined;
            makeBands(&stop_dk, @intCast(stop_min), 64, 13);
            std.mem.sort(i16, &stop_dk, {}, std.sort.asc(i16));
            for (stop_dk[0..spectrum.bs_stop_freq]) |v| s.k[2] +%= @bitCast(@as(i32, v));
        } else if (spectrum.bs_stop_freq == 14) {
            s.k[2] = 2 *% s.k[0];
        } else if (spectrum.bs_stop_freq == 15) {
            s.k[2] = 3 *% s.k[0];
        } else return false; // "Invalid bs_stop_freq"
        s.k[2] = @min(64, s.k[2]);
        const max_qmf_subbands: u32 = if (s.sample_rate <= 32000) 48 else if (s.sample_rate == 44100) 35 else 32;
        if (s.k[2] -% s.k[0] > max_qmf_subbands) return false; // "too many QMF subbands"
        if (spectrum.bs_freq_scale == 0) {
            const dk: u5 = @intCast(spectrum.bs_alter_scale + 1);
            s.n_master = ((s.k[2] - s.k[0] + (dk & 2)) >> dk) << 1;
            if (!checkNMaster(s.n_master, spectrum.bs_xover_band)) return false;
            for (1..s.n_master + 1) |k| s.f_master[k] = dk;
            const k2diff: i64 = @as(i64, s.k[2]) - s.k[0] - @as(i64, s.n_master) * dk;
            if (k2diff < 0) {
                s.f_master[1] -%= 1;
                s.f_master[2] -%= @intFromBool(k2diff < -1);
            } else if (k2diff != 0) {
                s.f_master[s.n_master] +%= 1;
            }
            s.f_master[0] = @intCast(s.k[0]);
            for (1..s.n_master + 1) |k| s.f_master[k] +%= s.f_master[k - 1];
        } else {
            const half_bands: i32 = 7 - @as(i32, spectrum.bs_freq_scale);
            var vk0: [49]i16 = @splat(0);
            const two_regions = 49 * s.k[2] > 110 * s.k[0];
            s.k[1] = if (two_regions) 2 * s.k[0] else s.k[2];
            const ratio0 = @as(f32, @floatFromInt(s.k[1])) / @as(f32, @floatFromInt(s.k[0]));
            // A long times 2, stored into an int.
            const num_bands_0: i32 = @truncate(cconv.lrintf(@as(f32, @floatFromInt(half_bands)) * libm.log2f(ratio0)) *% 2);
            if (num_bands_0 <= 0 or num_bands_0 > 48) return false; // "Invalid num_bands_0"
            const nb0: usize = @intCast(num_bands_0);
            makeBands(vk0[1..][0..nb0], @intCast(s.k[0]), @intCast(s.k[1]), nb0);
            std.mem.sort(i16, vk0[1..][0..nb0], {}, std.sort.asc(i16));
            const vdk0_max = vk0[nb0];
            vk0[0] = @intCast(s.k[0]);
            for (1..nb0 + 1) |k| {
                if (vk0[k] <= 0) return false; // "Invalid vDk0"
                vk0[k] +%= vk0[k - 1];
            }
            if (two_regions) {
                var vk1: [49]i16 = @splat(0);
                const invwarp: f32 = if (spectrum.bs_alter_scale != 0) 0.76923076923076923077 else 1.0;
                const ratio1 = @as(f32, @floatFromInt(s.k[2])) / @as(f32, @floatFromInt(s.k[1]));
                const num_bands_1: i32 = @truncate(cconv.lrintf(@as(f32, @floatFromInt(half_bands)) * invwarp * libm.log2f(ratio1)) *% 2);
                // make_bands writes num_bands_1 values into vk1 + 1: past
                // 48 the C writes beyond the array; the check below
                // refuses such a table (n_master past 48) in any case.
                if (num_bands_1 <= 0 or num_bands_1 > 48 - num_bands_0) return false;
                const nb1: usize = @intCast(num_bands_1);
                makeBands(vk1[1..][0..nb1], @intCast(s.k[1]), @intCast(s.k[2]), nb1);
                const vdk1_min = std.mem.min(i16, vk1[1..][0..nb1]);
                if (vdk1_min < vdk0_max) {
                    std.mem.sort(i16, vk1[1..][0..nb1], {}, std.sort.asc(i16));
                    const change = @min(vdk0_max - vk1[1], (vk1[nb1] - vk1[1]) >> 1);
                    vk1[1] += change;
                    vk1[nb1] -= change;
                }
                std.mem.sort(i16, vk1[1..][0..nb1], {}, std.sort.asc(i16));
                vk1[0] = @intCast(s.k[1]);
                for (1..nb1 + 1) |k| {
                    if (vk1[k] <= 0) return false; // "Invalid vDk1"
                    vk1[k] +%= vk1[k - 1];
                }
                s.n_master = @intCast(nb0 + nb1);
                if (!checkNMaster(s.n_master, spectrum.bs_xover_band)) return false;
                for (vk0[0 .. nb0 + 1], 0..) |v, k| s.f_master[k] = @bitCast(v);
                for (vk1[1 .. nb1 + 1], 0..) |v, k| s.f_master[nb0 + 1 + k] = @bitCast(v);
            } else {
                s.n_master = @intCast(nb0);
                if (!checkNMaster(s.n_master, spectrum.bs_xover_band)) return false;
                for (vk0[0 .. nb0 + 1], 0..) |v, k| s.f_master[k] = @bitCast(v);
            }
        }
        return true;
    }

    /// sbr_hf_calc_npatches: the patches that build the high band; false
    /// where FFmpeg fails.
    fn hfCalcNpatches(s: *Sbr) bool {
        var last_k: i64 = -1;
        var last_msb: i64 = -1;
        var sb: i64 = 0;
        var msb: i64 = s.k[0];
        var usb: i64 = s.kx[1];
        const goal_sb: i64 = ((1000 << 11) + (s.sample_rate >> 1)) / s.sample_rate;
        s.num_patches = 0;
        var k: i64 = 0;
        if (goal_sb < @as(i64, s.kx[1]) + s.m[1]) {
            // f_master[n_master] is kx + M, past the goal: the C scan
            // stops there; stopping at the table's end guards a state
            // that breaks it.
            while (k < 49 and s.f_master[@intCast(k)] < goal_sb) k += 1;
            if (k == 49) return false;
        } else k = s.n_master;
        while (true) {
            var odd: i64 = 0;
            if (k == last_k and msb == last_msb) return false; // "patch construction failed"
            last_k = k;
            last_msb = msb;
            var i = k;
            // The C compares in unsigned arithmetic: k0 is AAC_SIGNE.
            while (true) {
                if (i != k) {
                    const bound: u32 = @truncate(@as(u64, @bitCast(@as(i64, s.k[0]) - 1 + msb - odd)));
                    if (!(@as(u32, @truncate(@as(u64, @bitCast(sb)))) > bound)) break;
                }
                if (i < 0 or i > 48) return false; // the C would read outside f_master
                sb = s.f_master[@intCast(i)];
                odd = (sb + s.k[0]) & 1;
                i -= 1;
            }
            // At most five patches; a sixth can still follow.
            if (s.num_patches > 5) return false; // "Too many patches"
            const num: i64 = @max(sb - usb, 0);
            s.patch_num_subbands[s.num_patches] = @truncate(@as(u64, @bitCast(num)));
            s.patch_start_subband[s.num_patches] = @truncate(@as(u64, @bitCast(@as(i64, s.k[0]) - odd - s.patch_num_subbands[s.num_patches])));
            if (s.patch_num_subbands[s.num_patches] > 0) {
                usb = sb;
                msb = sb;
                s.num_patches += 1;
            } else msb = s.kx[1];
            if (k < 0 or k > 48) return false;
            if (s.f_master[@intCast(k)] - sb < 3) k = s.n_master;
            if (sb == @as(i64, s.kx[1]) + s.m[1]) break;
        }
        if (s.num_patches > 1 and s.patch_num_subbands[s.num_patches - 1] < 3) s.num_patches -= 1;
        return true;
    }

    /// sbr_make_f_derived: the derived frequency band tables; false where
    /// FFmpeg returns -1.
    fn makeFDerived(s: *Sbr) bool {
        const xover = s.spectrum_params.bs_xover_band;
        s.n[1] = s.n_master - xover;
        s.n[0] = (s.n[1] + 1) >> 1;
        @memcpy(s.f_tablehigh[0 .. s.n[1] + 1], s.f_master[xover..][0 .. s.n[1] + 1]);
        s.m[1] = @as(u32, s.f_tablehigh[s.n[1]]) -% s.f_tablehigh[0];
        s.kx[1] = s.f_tablehigh[0];
        if (s.kx[1] +% s.m[1] > 64) return false; // "Stop frequency border too high"
        if (s.kx[1] > 32) return false; // "Start frequency border too high"
        s.f_tablelow[0] = s.f_tablehigh[0];
        const temp = s.n[1] & 1;
        for (1..s.n[0] + 1) |k| s.f_tablelow[k] = s.f_tablehigh[2 * k - temp];
        const ratio = @as(f32, @floatFromInt(s.k[2])) / @as(f32, @floatFromInt(s.kx[1]));
        // FFMAX of a long, stored into the unsigned n_q.
        const n_q: i64 = @max(1, cconv.lrintf(@as(f32, @floatFromInt(s.spectrum_params.bs_noise_bands)) * libm.log2f(ratio)));
        s.n_q = @truncate(@as(u64, @bitCast(n_q)));
        if (s.n_q > 5) {
            s.n_q = 1;
            return false; // "Too many noise floor scale factors"
        }
        s.f_tablenoise[0] = s.f_tablelow[0];
        var t: u32 = 0;
        for (1..s.n_q + 1) |k| {
            t += (s.n[0] - t) / (s.n_q + 1 - @as(u32, @intCast(k)));
            s.f_tablenoise[k] = s.f_tablelow[t];
        }
        if (!s.hfCalcNpatches()) return false;
        s.makeFTablelim();
        s.data[0].f_indexnoise = 0;
        s.data[1].f_indexnoise = 0;
        return true;
    }

    /// sbr_reset.
    fn resetTables(s: *Sbr) void {
        if (!(s.makeFMaster() and s.makeFDerived())) s.turnoff(); // "SBR reset failed"
    }

    // ---- Bitstream ----

    /// read_sbr_header: the bits read.
    fn readHeader(s: *Sbr, r: *bits.BitReader) usize {
        const cnt = r.count();
        const old_bs_limiter_bands = s.bs_limiter_bands;
        s.start = true;
        s.ready_for_dequant = false;
        const old = s.spectrum_params;
        s.bs_amp_res_header = r.bit();
        s.spectrum_params.bs_start_freq = @intCast(r.bits(4));
        s.spectrum_params.bs_stop_freq = @intCast(r.bits(4));
        s.spectrum_params.bs_xover_band = @intCast(r.bits(3));
        r.skip(2); // bs_reserved
        const extra_1 = r.bit();
        const extra_2 = r.bit();
        if (extra_1 != 0) {
            s.spectrum_params.bs_freq_scale = @intCast(r.bits(2));
            s.spectrum_params.bs_alter_scale = r.bit();
            s.spectrum_params.bs_noise_bands = @intCast(r.bits(2));
        } else {
            s.spectrum_params.bs_freq_scale = 2;
            s.spectrum_params.bs_alter_scale = 1;
            s.spectrum_params.bs_noise_bands = 2;
        }
        if (!old.eql(s.spectrum_params)) s.reset = true;
        if (extra_2 != 0) {
            s.bs_limiter_bands = r.bits(2);
            s.bs_limiter_gains = r.bits(2);
            s.bs_interpol_freq = r.bit();
            s.bs_smoothing_mode = r.bit();
        } else {
            s.bs_limiter_bands = 2;
            s.bs_limiter_gains = 2;
            s.bs_interpol_freq = 1;
            s.bs_smoothing_mode = 1;
        }
        if (s.bs_limiter_bands != old_bs_limiter_bands and !s.reset) s.makeFTablelim();
        return r.count() - cnt;
    }

    /// read_sbr_grid: false where FFmpeg returns -1.
    fn readGrid(s: *Sbr, r: *bits.BitReader, ch: usize, num_time_slots: u8) bool {
        const d = &s.data[ch];
        var bs_pointer: u32 = 0;
        var abs_bord_trail: u8 = num_time_slots;
        const bs_num_env_old = d.bs_num_env;
        d.bs_freq_res[0] = d.bs_freq_res[d.bs_num_env];
        d.bs_amp_res = s.bs_amp_res_header;
        d.t_env_num_env_old = d.t_env[bs_num_env_old];
        const bs_frame_class = r.bits(2);
        switch (bs_frame_class) {
            fixfix => {
                const bs_num_env = @as(u32, 1) << @intCast(r.bits(2));
                if (bs_num_env > 5) return false; // "too many SBR envelopes in FIXFIX"
                d.bs_num_env = bs_num_env;
                const num_rel_lead = d.bs_num_env - 1;
                if (d.bs_num_env == 1) d.bs_amp_res = 0;
                d.t_env[0] = 0;
                d.t_env[d.bs_num_env] = abs_bord_trail;
                const step: u8 = @intCast((abs_bord_trail + (d.bs_num_env >> 1)) / d.bs_num_env);
                for (0..num_rel_lead) |i| d.t_env[i + 1] = d.t_env[i] +% step;
                d.bs_freq_res[1] = r.bit();
                for (1..d.bs_num_env) |i| d.bs_freq_res[i + 1] = d.bs_freq_res[1];
            },
            fixvar => {
                abs_bord_trail += @intCast(r.bits(2));
                const num_rel_trail = r.bits(2);
                d.bs_num_env = num_rel_trail + 1;
                d.t_env[0] = 0;
                d.t_env[d.bs_num_env] = abs_bord_trail;
                for (0..num_rel_trail) |i| {
                    const delta: u8 = @intCast(2 * r.bits(2) + 2);
                    d.t_env[d.bs_num_env - 1 - i] = d.t_env[d.bs_num_env - i] -% delta;
                }
                bs_pointer = r.bits(ceil_log2[d.bs_num_env]);
                for (0..d.bs_num_env) |i| d.bs_freq_res[d.bs_num_env - i] = r.bit();
            },
            varfix => {
                d.t_env[0] = @intCast(r.bits(2));
                const num_rel_lead = r.bits(2);
                d.bs_num_env = num_rel_lead + 1;
                d.t_env[d.bs_num_env] = abs_bord_trail;
                for (0..num_rel_lead) |i| d.t_env[i + 1] = d.t_env[i] +% @as(u8, @intCast(2 * r.bits(2) + 2));
                bs_pointer = r.bits(ceil_log2[d.bs_num_env]);
                for (0..d.bs_num_env) |i| d.bs_freq_res[1 + i] = r.bit();
            },
            varvar => {
                d.t_env[0] = @intCast(r.bits(2));
                abs_bord_trail += @intCast(r.bits(2));
                const num_rel_lead = r.bits(2);
                const num_rel_trail = r.bits(2);
                const bs_num_env = num_rel_lead + num_rel_trail + 1;
                if (bs_num_env > 5) return false; // "too many SBR envelopes in VARVAR"
                d.bs_num_env = bs_num_env;
                d.t_env[d.bs_num_env] = abs_bord_trail;
                for (0..num_rel_lead) |i| d.t_env[i + 1] = d.t_env[i] +% @as(u8, @intCast(2 * r.bits(2) + 2));
                for (0..num_rel_trail) |i| {
                    const delta: u8 = @intCast(2 * r.bits(2) + 2);
                    d.t_env[d.bs_num_env - 1 - i] = d.t_env[d.bs_num_env - i] -% delta;
                }
                bs_pointer = r.bits(ceil_log2[d.bs_num_env]);
                for (0..d.bs_num_env) |i| d.bs_freq_res[1 + i] = r.bit();
            },
            else => unreachable, // two bits
        }
        d.bs_frame_class = bs_frame_class;
        if (bs_pointer > d.bs_num_env + 1) return false; // "bs_pointer points to a middle noise border outside the time borders table"
        for (1..d.bs_num_env + 1) |i| {
            if (d.t_env[i - 1] >= d.t_env[i]) return false; // "Not strictly monotone time borders"
        }
        d.bs_num_noise = @as(u32, @intFromBool(d.bs_num_env > 1)) + 1;
        d.t_q[0] = d.t_env[0];
        d.t_q[d.bs_num_noise] = d.t_env[d.bs_num_env];
        if (d.bs_num_noise > 1) {
            var idx: u32 = undefined;
            if (d.bs_frame_class == fixfix) {
                idx = d.bs_num_env >> 1;
            } else if (d.bs_frame_class & 1 != 0) { // FIXVAR or VARVAR
                idx = d.bs_num_env - @as(u32, @intCast(@max(@as(i64, bs_pointer) - 1, 1)));
            } else { // VARFIX
                idx = if (bs_pointer == 0) 1 else if (bs_pointer == 1) d.bs_num_env - 1 else bs_pointer - 1;
            }
            d.t_q[1] = d.t_env[idx];
        }
        d.e_a[0] = -@as(i32, @intFromBool(d.e_a[1] != @as(i64, bs_num_env_old)));
        d.e_a[1] = -1;
        if (d.bs_frame_class & 1 != 0 and bs_pointer != 0) {
            d.e_a[1] = @intCast(d.bs_num_env + 1 - bs_pointer);
        } else if (d.bs_frame_class == 2 and bs_pointer > 1) {
            d.e_a[1] = @intCast(bs_pointer - 1);
        }
        return true;
    }

    /// copy_sbr_grid: the coupled channel's grid from channel 0's.
    fn copyGrid(s: *Sbr) void {
        const dst = &s.data[1];
        const src = &s.data[0];
        dst.bs_freq_res[0] = dst.bs_freq_res[dst.bs_num_env];
        dst.t_env_num_env_old = dst.t_env[dst.bs_num_env];
        dst.e_a[0] = -@as(i32, @intFromBool(dst.e_a[1] != @as(i64, dst.bs_num_env)));
        @memcpy(dst.bs_freq_res[1..], src.bs_freq_res[1..]);
        dst.t_env = src.t_env;
        dst.t_q = src.t_q;
        dst.bs_num_env = src.bs_num_env;
        dst.bs_amp_res = src.bs_amp_res;
        dst.bs_num_noise = src.bs_num_noise;
        dst.bs_frame_class = src.bs_frame_class;
        dst.e_a[1] = src.e_a[1];
    }

    /// read_sbr_dtdf, without USAC's independence flag.
    fn readDtdf(s: *Sbr, r: *bits.BitReader, ch: usize) void {
        const d = &s.data[ch];
        for (d.bs_df_env[0..d.bs_num_env]) |*v| v.* = r.bit();
        for (d.bs_df_noise[0..d.bs_num_noise]) |*v| v.* = r.bit();
    }

    /// read_sbr_invf.
    fn readInvf(s: *Sbr, r: *bits.BitReader, ch: usize) void {
        const d = &s.data[ch];
        d.bs_invf_mode[1] = d.bs_invf_mode[0];
        for (0..s.n_q) |i| d.bs_invf_mode[0][i] = @intCast(r.bits(2));
    }

    /// read_sbr_envelope: false where FFmpeg returns AVERROR_INVALIDDATA.
    fn readEnvelope(s: *Sbr, r: *bits.BitReader, ch: usize) bool {
        const d = &s.data[ch];
        const delta: i32 = @as(i32, @intFromBool(ch == 1 and s.bs_coupling == 1)) + 1;
        const odd: usize = s.n[1] & 1;
        var nbits: u6 = undefined;
        var t_huff: tab.Huff = undefined;
        var f_huff: tab.Huff = undefined;
        if (s.bs_coupling != 0 and ch != 0) {
            if (d.bs_amp_res != 0) {
                nbits = 5;
                t_huff = .t_env_bal_3_0db;
                f_huff = .f_env_bal_3_0db;
            } else {
                nbits = 6;
                t_huff = .t_env_bal_1_5db;
                f_huff = .f_env_bal_1_5db;
            }
        } else {
            if (d.bs_amp_res != 0) {
                nbits = 6;
                t_huff = .t_env_3_0db;
                f_huff = .f_env_3_0db;
            } else {
                nbits = 7;
                t_huff = .t_env_1_5db;
                f_huff = .f_env_1_5db;
            }
        }
        const t_table = tab.huff_vlc[@backingInt(t_huff)];
        const f_table = tab.huff_vlc[@backingInt(f_huff)];
        for (0..d.bs_num_env) |i| {
            const res = d.bs_freq_res[i + 1];
            const count = s.n[res];
            if (d.bs_df_env[i] != 0) {
                for (0..count) |j| {
                    // bs_freq_res[0] is the previous frame's last.
                    const k: usize = if (res == d.bs_freq_res[i]) j else if (res != 0) (j + odd) >> 1 else if (j != 0) 2 * j - odd else 0;
                    // The C stores into a uint8_t.
                    const v = @as(i32, d.env_facs_q[i][k]) + delta * vlc.lookup(bits.BitReader, t_table, r, tab.vlc_bits, 3);
                    d.env_facs_q[i + 1][j] = @truncate(@as(u32, @bitCast(v)));
                    if (d.env_facs_q[i + 1][j] > 127) return false; // "env_facs_q %d is invalid"
                }
            } else {
                d.env_facs_q[i + 1][0] = @truncate(@as(u32, @bitCast(delta * @as(i32, @intCast(r.bits(nbits))))));
                for (1..count) |j| {
                    const v = @as(i32, d.env_facs_q[i + 1][j - 1]) + delta * vlc.lookup(bits.BitReader, f_table, r, tab.vlc_bits, 3);
                    d.env_facs_q[i + 1][j] = @truncate(@as(u32, @bitCast(v)));
                    if (d.env_facs_q[i + 1][j] > 127) return false;
                }
            }
        }
        d.env_facs_q[0] = d.env_facs_q[d.bs_num_env];
        return true;
    }

    /// read_sbr_noise: false where FFmpeg returns AVERROR_INVALIDDATA.
    fn readNoise(s: *Sbr, r: *bits.BitReader, ch: usize) bool {
        const d = &s.data[ch];
        const delta: i32 = @as(i32, @intFromBool(ch == 1 and s.bs_coupling == 1)) + 1;
        const t_table, const f_table = if (s.bs_coupling != 0 and ch != 0)
            .{ tab.huff_vlc[@backingInt(tab.Huff.t_noise_bal_3_0db)], tab.huff_vlc[@backingInt(tab.Huff.f_env_bal_3_0db)] }
        else
            .{ tab.huff_vlc[@backingInt(tab.Huff.t_noise_3_0db)], tab.huff_vlc[@backingInt(tab.Huff.f_env_3_0db)] };
        for (0..d.bs_num_noise) |i| {
            if (d.bs_df_noise[i] != 0) {
                for (0..s.n_q) |j| {
                    const v = @as(i32, d.noise_facs_q[i][j]) + delta * vlc.lookup(bits.BitReader, t_table, r, tab.vlc_bits, 2);
                    d.noise_facs_q[i + 1][j] = @truncate(@as(u32, @bitCast(v)));
                    if (d.noise_facs_q[i + 1][j] > 30) return false; // "noise_facs_q %d is invalid"
                }
            } else {
                d.noise_facs_q[i + 1][0] = @truncate(@as(u32, @bitCast(delta * @as(i32, @intCast(r.bits(5))))));
                for (1..s.n_q) |j| {
                    const v = @as(i32, d.noise_facs_q[i + 1][j - 1]) + delta * vlc.lookup(bits.BitReader, f_table, r, tab.vlc_bits, 3);
                    d.noise_facs_q[i + 1][j] = @truncate(@as(u32, @bitCast(v)));
                    if (d.noise_facs_q[i + 1][j] > 30) return false;
                }
            }
        }
        d.noise_facs_q[0] = d.noise_facs_q[d.bs_num_noise];
        return true;
    }

    /// read_sbr_extension.
    fn readExtension(s: *Sbr, r: *bits.BitReader, bs_extension_id: u32, num_bits_left: *i64, ps: i32) Error!void {
        if (bs_extension_id == extension_id_ps) {
            // "Parametric Stereo signaled to be not-present but was found
            // in the bitstream."
            if (ps == 0) {
                r.skipLong(num_bits_left.*);
                num_bits_left.* = 0;
                return;
            }
            if (s.ps == null) s.ps = try aacps.Ps.create(s.gpa);
            num_bits_left.* -= s.ps.?.common.readData(r, num_bits_left.*);
            return;
        }
        // "Reserved SBR extensions", or FFmpeg's padding.
        r.skipLong(num_bits_left.*);
        num_bits_left.* = 0;
    }

    /// read_sbr_single_channel_element: false where FFmpeg fails.
    fn readSingleChannelElement(s: *Sbr, r: *bits.BitReader, num_time_slots: u8) bool {
        if (r.bit() != 0) r.skip(4); // bs_data_extra, bs_reserved
        if (!s.readGrid(r, 0, num_time_slots)) return false;
        s.readDtdf(r, 0);
        s.readInvf(r, 0);
        if (!s.readEnvelope(r, 0)) return false;
        if (!s.readNoise(r, 0)) return false;
        s.data[0].bs_add_harmonic_flag = r.bit();
        if (s.data[0].bs_add_harmonic_flag != 0) {
            for (s.data[0].bs_add_harmonic[0..s.n[1]]) |*v| v.* = r.bit();
        }
        return true;
    }

    /// read_sbr_channel_pair_element: false where FFmpeg fails.
    fn readChannelPairElement(s: *Sbr, r: *bits.BitReader, num_time_slots: u8) bool {
        if (r.bit() != 0) r.skip(8); // bs_data_extra, bs_reserved
        s.bs_coupling = r.bit();
        if (s.bs_coupling != 0) {
            if (!s.readGrid(r, 0, num_time_slots)) return false;
            s.copyGrid();
            s.readDtdf(r, 0);
            s.readDtdf(r, 1);
            s.readInvf(r, 0);
            s.data[1].bs_invf_mode[1] = s.data[1].bs_invf_mode[0];
            s.data[1].bs_invf_mode[0] = s.data[0].bs_invf_mode[0];
            if (!s.readEnvelope(r, 0)) return false;
            if (!s.readNoise(r, 0)) return false;
            if (!s.readEnvelope(r, 1)) return false;
            if (!s.readNoise(r, 1)) return false;
        } else {
            if (!s.readGrid(r, 0, num_time_slots) or !s.readGrid(r, 1, num_time_slots)) return false;
            s.readDtdf(r, 0);
            s.readDtdf(r, 1);
            s.readInvf(r, 0);
            s.readInvf(r, 1);
            if (!s.readEnvelope(r, 0)) return false;
            if (!s.readEnvelope(r, 1)) return false;
            if (!s.readNoise(r, 0)) return false;
            if (!s.readNoise(r, 1)) return false;
        }
        for (&s.data) |*d| {
            d.bs_add_harmonic_flag = r.bit();
            if (d.bs_add_harmonic_flag != 0) {
                for (d.bs_add_harmonic[0..s.n[1]]) |*v| v.* = r.bit();
            }
        }
        return true;
    }

    /// read_sbr_data: the bits read.
    fn readData(s: *Sbr, r: *bits.BitReader, id_aac: u3, num_time_slots: u8, ps: i32) Error!usize {
        const cnt = r.count();
        s.id_aac = id_aac;
        s.ready_for_dequant = true;
        const ok = if (id_aac == elem_sce or id_aac == elem_cce)
            s.readSingleChannelElement(r, num_time_slots)
        else if (id_aac == elem_cpe)
            s.readChannelPairElement(r, num_time_slots)
        else
            false; // "cannot apply SBR to element type"
        if (!ok) {
            s.turnoff();
            return r.count() - cnt;
        }
        if (r.bit() != 0) { // bs_extended_data
            var num_bits_left: i64 = r.bits(4); // bs_extension_size
            if (num_bits_left == 15) num_bits_left += r.bits(8); // bs_esc_count
            num_bits_left <<= 3;
            while (num_bits_left > 7) {
                num_bits_left -= 2;
                try s.readExtension(r, r.bits(2), &num_bits_left, ps);
            }
            // A negative count is "SBR Extension over read."
            if (num_bits_left > 0) r.skip(@intCast(num_bits_left));
        }
        return r.count() - cnt;
    }

    /// ff_aac_sbr_decode_extension: the SBR payload of a fill element of
    /// `cnt` bytes after the element `id_aac`, read from a copy of the
    /// host's reader, which moves past the payload; the bytes used (all).
    pub fn decodeExtension(s: *Sbr, host: *bits.BitReader, crc: bool, cnt: u32, id_aac: u3, m4ac: *mpeg4audio.Config) Error!u32 {
        var gbc = host.*;
        const r = &gbc;
        const num_time_slots: u8 = if (m4ac.frame_length_short != 0) 15 else 16;
        host.skipLong(@as(i64, cnt) * 8 - 4);
        s.reset = false;
        // The nominal rate is not used: twice the core's.
        if (s.sample_rate == 0) s.sample_rate = @bitCast(2 *% m4ac.sample_rate);
        if (m4ac.ext_sample_rate == 0) m4ac.ext_sample_rate = 2 *% m4ac.sample_rate;
        var num_sbr_bits: usize = 0;
        if (crc) {
            r.skip(10); // bs_sbr_crc_bits, not checked
            num_sbr_bits += 10;
        }
        // The previous frame's.
        s.kx[0] = s.kx[1];
        s.m[0] = s.m[1];
        s.kx_and_m_pushed = true;
        num_sbr_bits += 1;
        if (r.bit() != 0) num_sbr_bits += s.readHeader(r); // bs_header_flag
        if (s.reset) s.resetTables();
        if (s.start) num_sbr_bits += try s.readData(r, id_aac, num_time_slots, m4ac.ps);
        const total: i64 = @as(i64, cnt) << 3;
        const num_align_bits: i64 = @intCast(@as(u32, @truncate(@as(u64, @bitCast(total - 4 - @as(i64, @intCast(num_sbr_bits)))))) & 7);
        const bytes_read = (@as(i64, @intCast(num_sbr_bits)) + num_align_bits + 4) >> 3;
        if (bytes_read > cnt) s.turnoff(); // "Expected to read %d SBR bytes actually read %d."
        return cnt;
    }

    // ---- Synthesis ----

    /// sbr_dequant: the envelope and noise scale factors, and their stereo
    /// decoding.
    fn dequant(s: *Sbr, id_aac: u3) void {
        const exp2_tab = [2]f64{ 1, std.math.sqrt2 };
        if (id_aac == elem_cpe and s.bs_coupling != 0) {
            const d0 = &s.data[0];
            const d1 = &s.data[1];
            const pan_offset: i32 = if (d0.bs_amp_res != 0) 12 else 24;
            for (1..d0.bs_num_env + 1) |e| {
                for (0..s.n[d0.bs_freq_res[e]]) |k| {
                    var temp1: f32 = undefined;
                    var temp2: f32 = undefined;
                    const q0: i32 = d0.env_facs_q[e][k];
                    const q1 = pan_offset - @as(i32, d1.env_facs_q[e][k]);
                    if (d0.bs_amp_res != 0) {
                        temp1 = exp2fi(q0 + 7);
                        temp2 = exp2fi(q1);
                    } else {
                        temp1 = @floatCast(@as(f64, exp2fi((q0 >> 1) + 7)) * exp2_tab[@intCast(q0 & 1)]);
                        temp2 = @floatCast(@as(f64, exp2fi(q1 >> 1)) * exp2_tab[@intCast(q1 & 1)]);
                    }
                    // "envelope scalefactor overflow in dequant"
                    if (temp1 > 1e20) temp1 = 1;
                    const fac = temp1 / (1.0 + temp2);
                    d0.env_facs[e][k] = fac;
                    d1.env_facs[e][k] = fac * temp2;
                }
            }
            for (1..d0.bs_num_noise + 1) |e| {
                for (0..s.n_q) |k| {
                    const temp1 = exp2fi(noise_floor_offset - @as(i32, d0.noise_facs_q[e][k]) + 1);
                    const temp2 = exp2fi(12 - @as(i32, d1.noise_facs_q[e][k]));
                    const fac = temp1 / (1.0 + temp2);
                    d0.noise_facs[e][k] = fac;
                    d1.noise_facs[e][k] = fac * temp2;
                }
            }
        } else {
            const nch: usize = if (id_aac == elem_cpe) 2 else 1;
            for (s.data[0..nch]) |*d| {
                for (1..d.bs_num_env + 1) |e| {
                    for (0..s.n[d.bs_freq_res[e]]) |k| {
                        const q: i32 = d.env_facs_q[e][k];
                        d.env_facs[e][k] = if (d.bs_amp_res != 0)
                            exp2fi(q + 6)
                        else
                            @floatCast(@as(f64, exp2fi((q >> 1) + 6)) * exp2_tab[@intCast(q & 1)]);
                        if (d.env_facs[e][k] > 1e20) d.env_facs[e][k] = 1;
                    }
                }
                for (1..d.bs_num_noise + 1) |e| {
                    for (0..s.n_q) |k| d.noise_facs[e][k] = exp2fi(noise_floor_offset - @as(i32, d.noise_facs_q[e][k]));
                }
            }
        }
    }

    /// sbr_hf_inverse_filter: the low band's linear prediction coefficients.
    fn hfInverseFilter(s: *Sbr, k0: u32) void {
        for (0..k0) |k| {
            var phi: [3][2][2]f32 = undefined;
            autocorrelate(&s.x_low[k], &phi);
            const dk = phi[2][1][0] * phi[1][0][0] - (phi[1][1][0] * phi[1][1][0] + phi[1][1][1] * phi[1][1][1]) / 1.000001;
            const a1 = &s.alpha1[k];
            const a0 = &s.alpha0[k];
            if (dk == 0) {
                a1.* = .{ 0, 0 };
            } else {
                const temp_real = phi[0][0][0] * phi[1][1][0] - phi[0][0][1] * phi[1][1][1] - phi[0][1][0] * phi[1][0][0];
                const temp_im = phi[0][0][0] * phi[1][1][1] + phi[0][0][1] * phi[1][1][0] - phi[0][1][1] * phi[1][0][0];
                a1[0] = temp_real / dk;
                a1[1] = temp_im / dk;
            }
            if (phi[1][0][0] == 0) {
                a0.* = .{ 0, 0 };
            } else {
                const temp_real = phi[0][0][0] + a1[0] * phi[1][1][0] + a1[1] * phi[1][1][1];
                const temp_im = phi[0][0][1] + a1[1] * phi[1][1][0] - a1[0] * phi[1][1][1];
                a0[0] = -temp_real / phi[1][0][0];
                a0[1] = -temp_im / phi[1][0][0];
            }
            if (a1[0] * a1[0] + a1[1] * a1[1] >= 16.0 or a0[0] * a0[0] + a0[1] * a0[1] >= 16.0) {
                a1.* = .{ 0, 0 };
                a0.* = .{ 0, 0 };
            }
        }
    }

    /// sbr_chirp: the chirp factors.
    fn chirp(s: *Sbr, d: *SbrData) void {
        const bw_tab = [4]f32{ 0.0, 0.75, 0.9, 0.98 };
        for (0..s.n_q) |i| {
            var new_bw: f32 = if (@as(u32, d.bs_invf_mode[0][i]) + d.bs_invf_mode[1][i] == 1) 0.6 else bw_tab[d.bs_invf_mode[0][i]];
            if (new_bw < d.bw_array[i]) {
                new_bw = 0.75 * new_bw + 0.25 * d.bw_array[i];
            } else new_bw = 0.90625 * new_bw + 0.09375 * d.bw_array[i];
            d.bw_array[i] = if (new_bw < 0.015625) 0.0 else new_bw;
        }
    }

    /// sbr_lf_gen: the low band from the analysis, this frame's slots and
    /// the previous frame's last eight.
    fn lfGen(s: *Sbr, w: *const [2][32][32][2]f32, buf_idx: u1, num_time_slots: u8) void {
        const t_hfgen = 8;
        const i_f: usize = @as(usize, num_time_slots) * 2;
        s.x_low = @splat(@splat(@splat(0)));
        for (0..s.kx[1]) |k| {
            for (t_hfgen..i_f + t_hfgen) |i| s.x_low[k][i] = w[buf_idx][i - t_hfgen][k];
        }
        const prev = 1 - buf_idx;
        for (0..s.kx[0]) |k| {
            for (0..t_hfgen) |i| s.x_low[k][i] = w[prev][i + i_f - t_hfgen][k];
        }
    }

    /// sbr_hf_gen: the high band from the patches.
    fn hfGen(s: *Sbr, d: *const SbrData) void {
        var g: i64 = 0;
        var k: usize = s.kx[1];
        for (0..s.num_patches) |j| {
            for (0..s.patch_num_subbands[j]) |x| {
                const p = @as(usize, s.patch_start_subband[j]) + x;
                while (g <= s.n_q and k >= s.f_tablenoise[@intCast(g)]) g += 1;
                g -= 1;
                if (g < 0) return; // "no subband found for frequency"
                hfGenKernel(&s.x_high[k], &s.x_low[p], s.alpha0[p], s.alpha1[p], d.bw_array[@intCast(g)], 2 * @as(usize, d.t_env[0]), 2 * @as(usize, d.t_env[d.bs_num_env]));
                k += 1;
            }
        }
        const end = s.m[1] + s.kx[1];
        if (k < end) for (s.x_high[k..end]) |*row| {
            row.* = @splat(@splat(0));
        };
    }

    /// sbr_x_gen: the QMF values the synthesis takes, from the low band
    /// and the adjusted high bands of the previous and this frame.
    fn xGen(s: *Sbr, ch: usize, y0: *const [38][64][2]f32, y1: *const [38][64][2]f32, num_time_slots: u8) void {
        const i_f: usize = @as(usize, num_time_slots) * 2;
        const x = &s.x[ch];
        const i_temp: usize = @intCast(@max(2 * @as(i64, s.data[ch].t_env_num_env_old) - @as(i64, @intCast(i_f)), 0));
        x.* = @splat(@splat(@splat(0)));
        var k: usize = 0;
        while (k < s.kx[0]) : (k += 1) {
            for (0..i_temp) |i| {
                x[0][i][k] = s.x_low[k][i + envelope_adjustment_offset][0];
                x[1][i][k] = s.x_low[k][i + envelope_adjustment_offset][1];
            }
        }
        while (k < s.kx[0] + s.m[0]) : (k += 1) {
            for (0..i_temp) |i| {
                x[0][i][k] = y0[i + i_f][k][0];
                x[1][i][k] = y0[i + i_f][k][1];
            }
        }
        k = 0;
        while (k < s.kx[1]) : (k += 1) {
            for (i_temp..38) |i| {
                x[0][i][k] = s.x_low[k][i + envelope_adjustment_offset][0];
                x[1][i][k] = s.x_low[k][i + envelope_adjustment_offset][1];
            }
        }
        while (k < s.kx[1] + s.m[1]) : (k += 1) {
            for (i_temp..i_f) |i| {
                x[0][i][k] = y1[i][k][0];
                x[1][i][k] = y1[i][k][1];
            }
        }
    }

    /// sbr_mapping: the envelope, noise and sinusoid data mapped onto the
    /// QMF subbands; false where FFmpeg returns AVERROR_BUG.
    fn mapping(s: *Sbr, d: *SbrData) bool {
        const kx1 = s.kx[1];
        for (d.s_indexmapped[1..8]) |*row| row.* = @splat(0);
        for (0..d.bs_num_env) |e| {
            const ilim = s.n[d.bs_freq_res[e + 1]];
            const table: []const u16 = if (d.bs_freq_res[e + 1] != 0) &s.f_tablehigh else &s.f_tablelow;
            if (kx1 != table[0]) {
                // "kx != f_table{high,low}[0]. Derived frequency tables
                // were not regenerated."
                s.turnoff();
                return false;
            }
            for (0..ilim) |i| {
                for (table[i]..table[i + 1]) |m| s.e_origmapped[e][m - kx1] = d.env_facs[e + 1][i];
            }
            // Two noise floors when there are two.
            const k: usize = @intFromBool(d.bs_num_noise > 1 and d.t_env[e] >= d.t_q[1]);
            for (0..s.n_q) |i| {
                for (s.f_tablenoise[i]..s.f_tablenoise[i + 1]) |m| s.q_mapped[e][m - kx1] = d.noise_facs[k + 1][i];
            }
            for (0..s.n[1]) |i| {
                if (d.bs_add_harmonic_flag != 0) {
                    const m_midpoint = (@as(u32, s.f_tablehigh[i]) + s.f_tablehigh[i + 1]) >> 1;
                    const keep = @as(i64, @intCast(e)) >= d.e_a[1] or d.s_indexmapped[0][m_midpoint - kx1] == 1;
                    d.s_indexmapped[e + 1][m_midpoint - kx1] = d.bs_add_harmonic[i] * @intFromBool(keep);
                }
            }
            for (0..ilim) |i| {
                var additional_sinusoid_present: u8 = 0;
                for (table[i]..table[i + 1]) |m| {
                    if (d.s_indexmapped[e + 1][m - kx1] != 0) {
                        additional_sinusoid_present = 1;
                        break;
                    }
                }
                @memset(s.s_mapped[e][table[i] - kx1 .. table[i + 1] - kx1], additional_sinusoid_present);
            }
        }
        d.s_indexmapped[0] = d.s_indexmapped[d.bs_num_env];
        return true;
    }

    /// sbr_env_estimate: the high band's current envelope.
    fn envEstimate(s: *Sbr, d: *const SbrData) void {
        const kx1 = s.kx[1];
        if (s.bs_interpol_freq != 0) {
            for (0..d.bs_num_env) |e| {
                const recip_env_size = 0.5 / @as(f32, @floatFromInt(@as(i32, d.t_env[e + 1]) - d.t_env[e]));
                const ilb = @as(usize, d.t_env[e]) * 2 + envelope_adjustment_offset;
                const iub = @as(usize, d.t_env[e + 1]) * 2 + envelope_adjustment_offset;
                if (ilb >= 40) return;
                for (0..s.m[1]) |m| {
                    const sum = sumSquare(s.x_high[m + kx1][ilb..iub]);
                    s.e_curr[e][m] = sum * recip_env_size;
                }
            }
        } else {
            for (0..d.bs_num_env) |e| {
                const env_size: i32 = 2 * (@as(i32, d.t_env[e + 1]) - d.t_env[e]);
                const ilb = @as(usize, d.t_env[e]) * 2 + envelope_adjustment_offset;
                const iub = @as(usize, d.t_env[e + 1]) * 2 + envelope_adjustment_offset;
                const table: []const u16 = if (d.bs_freq_res[e + 1] != 0) &s.f_tablehigh else &s.f_tablelow;
                if (ilb >= 40) return;
                for (0..s.n[d.bs_freq_res[e + 1]]) |p| {
                    var sum: f32 = 0.0;
                    const den = env_size * (@as(i32, table[p + 1]) - table[p]);
                    for (table[p]..table[p + 1]) |k| sum += sumSquare(s.x_high[k][ilb..iub]);
                    sum /= @floatFromInt(den);
                    for (table[p]..table[p + 1]) |k| s.e_curr[e][k - kx1] = sum;
                }
            }
        }
    }

    /// sbr_gain_calc: the levels of the added sinusoids and noise, and the
    /// gains, limited and boosted per limiter band.
    fn gainCalc(s: *Sbr, d: *const SbrData) void {
        // The limiter's maximum gains: -3, 0 and 3 dB, and off.
        const limgain = [4]f32{ 0.70795, 1.0, 1.41254, 10000000000 };
        const kx1 = s.kx[1];
        for (0..d.bs_num_env) |e| {
            const ei: i64 = @intCast(e);
            const delta: u1 = @intFromBool(!(ei == d.e_a[1] or ei == d.e_a[0]));
            const fdelta: f32 = @floatFromInt(delta);
            for (0..s.n_lim) |k| {
                const lo = s.f_tablelim[k] - kx1;
                const hi = s.f_tablelim[k + 1] - kx1;
                for (lo..hi) |m| {
                    const temp = s.e_origmapped[e][m] / (1.0 + s.q_mapped[e][m]);
                    s.q_m[e][m] = @sqrt(temp * s.q_mapped[e][m]);
                    s.s_m[e][m] = @sqrt(temp * @as(f32, @floatFromInt(d.s_indexmapped[e + 1][m])));
                    if (s.s_mapped[e][m] == 0) {
                        s.gain[e][m] = @sqrt(s.e_origmapped[e][m] / ((1.0 + s.e_curr[e][m]) * (1.0 + s.q_mapped[e][m] * fdelta)));
                    } else {
                        s.gain[e][m] = @sqrt(s.e_origmapped[e][m] * s.q_mapped[e][m] / ((1.0 + s.e_curr[e][m]) * (1.0 + s.q_mapped[e][m])));
                    }
                    s.gain[e][m] += std.math.floatMin(f32);
                }
                var sum = [2]f32{ 0.0, 0.0 };
                for (lo..hi) |m| {
                    sum[0] += s.e_origmapped[e][m];
                    sum[1] += s.e_curr[e][m];
                }
                var gain_max = limgain[s.bs_limiter_gains] * @sqrt((std.math.floatEps(f32) + sum[0]) / (std.math.floatEps(f32) + sum[1]));
                gain_max = @min(100000.0, gain_max);
                for (lo..hi) |m| {
                    const q_m_max = s.q_m[e][m] * gain_max / s.gain[e][m];
                    s.q_m[e][m] = @min(s.q_m[e][m], q_m_max);
                    s.gain[e][m] = @min(s.gain[e][m], gain_max);
                }
                sum = .{ 0.0, 0.0 };
                for (lo..hi) |m| {
                    sum[0] += s.e_origmapped[e][m];
                    const noise: f32 = @floatFromInt(@intFromBool(delta != 0 and s.s_m[e][m] == 0));
                    sum[1] += s.e_curr[e][m] * s.gain[e][m] * s.gain[e][m] + s.s_m[e][m] * s.s_m[e][m] + noise * s.q_m[e][m] * s.q_m[e][m];
                }
                var gain_boost = @sqrt((std.math.floatEps(f32) + sum[0]) / (std.math.floatEps(f32) + sum[1]));
                gain_boost = @min(1.584893192, gain_boost);
                for (lo..hi) |m| {
                    s.gain[e][m] *= gain_boost;
                    s.q_m[e][m] *= gain_boost;
                    s.s_m[e][m] *= gain_boost;
                }
            }
        }
    }

    /// sbr_hf_assemble: the adjusted high band, smoothed gains, noise and
    /// sinusoids, into `y1`.
    fn hfAssemble(s: *Sbr, y1: *[38][64][2]f32, d: *SbrData) void {
        const h_sl: usize = if (s.bs_smoothing_mode == 0) 4 else 0;
        const kx = s.kx[1];
        const m_max = s.m[1];
        const h_smooth = [5]f32{ 0.33333333333333, 0.30150283239582, 0.21816949906249, 0.11516383427084, 0.03183050093751 };
        var indexnoise = d.f_indexnoise;
        var indexsine = d.f_indexsine;
        const t0 = 2 * @as(usize, d.t_env[0]);
        if (s.reset) {
            for (0..h_sl) |i| {
                @memcpy(d.g_temp[i + t0][0..m_max], s.gain[0][0..m_max]);
                @memcpy(d.q_temp[i + t0][0..m_max], s.q_m[0][0..m_max]);
            }
        } else if (h_sl != 0) {
            const told = 2 * @as(usize, d.t_env_num_env_old);
            for (0..4) |i| {
                d.g_temp[i + t0] = d.g_temp[i + told];
                d.q_temp[i + t0] = d.q_temp[i + told];
            }
        }
        for (0..d.bs_num_env) |e| {
            for (2 * @as(usize, d.t_env[e])..2 * @as(usize, d.t_env[e + 1])) |i| {
                @memcpy(d.g_temp[h_sl + i][0..m_max], s.gain[e][0..m_max]);
                @memcpy(d.q_temp[h_sl + i][0..m_max], s.q_m[e][0..m_max]);
            }
        }
        for (0..d.bs_num_env) |e| {
            const ei: i64 = @intCast(e);
            const at_transient = ei == d.e_a[0] or ei == d.e_a[1];
            for (2 * @as(usize, d.t_env[e])..2 * @as(usize, d.t_env[e + 1])) |i| {
                var g_filt_tab: [48]f32 = undefined;
                var q_filt_tab: [48]f32 = undefined;
                var g_filt: []const f32 = undefined;
                var q_filt: []const f32 = undefined;
                if (h_sl != 0 and !at_transient) {
                    for (0..m_max) |m| {
                        const idx1 = i + h_sl;
                        g_filt_tab[m] = 0.0;
                        q_filt_tab[m] = 0.0;
                        for (0..h_sl + 1) |j| {
                            g_filt_tab[m] += d.g_temp[idx1 - j][m] * h_smooth[j];
                            q_filt_tab[m] += d.q_temp[idx1 - j][m] * h_smooth[j];
                        }
                    }
                    g_filt = &g_filt_tab;
                    q_filt = &q_filt_tab;
                } else {
                    // FFmpeg's: the gains delayed by h_SL, the noise not.
                    g_filt = &d.g_temp[i + h_sl];
                    q_filt = &d.q_temp[i];
                }
                // hf_g_filt.
                for (0..m_max) |m| {
                    y1[i][kx + m][0] = s.x_high[kx + m][i + envelope_adjustment_offset][0] * g_filt[m];
                    y1[i][kx + m][1] = s.x_high[kx + m][i + envelope_adjustment_offset][1] * g_filt[m];
                }
                if (!at_transient) {
                    hfApplyNoise(y1[i][kx..], &s.s_m[e], q_filt, indexnoise, kx, m_max, indexsine);
                } else {
                    const idx: u1 = @intCast(indexsine & 1);
                    const a: i32 = 1 - @as(i32, @intCast((indexsine + (kx & 1)) & 2));
                    const b: i32 = (a ^ -@as(i32, idx)) + idx;
                    const fa: f32 = @floatFromInt(a);
                    const fb: f32 = @floatFromInt(b);
                    const in = &s.s_m[e];
                    var m: usize = 0;
                    while (m + 1 < m_max) : (m += 2) {
                        y1[i][kx + m][idx] += in[m] * fa;
                        y1[i][kx + m + 1][idx] += in[m + 1] * fb;
                    }
                    if (m_max & 1 != 0) y1[i][kx + m][idx] += in[m] * fa;
                }
                indexnoise = (indexnoise + m_max) & 0x1ff;
                indexsine = (indexsine + 1) & 3;
            }
        }
        d.f_indexnoise = indexnoise;
        d.f_indexsine = indexsine;
    }

    /// ff_aac_sbr_apply: the element's 1024 samples a channel in `l` (and
    /// `r`) replaced by its 2048 SBR samples (or 1024 when downsampled),
    /// pure upsampling without SBR data.
    pub fn apply(s: *Sbr, id_aac: u3, m4ac: *const mpeg4audio.Config, l: *[2048]f32, r: *[2048]f32) void {
        const downsampled = m4ac.ext_sample_rate < @as(i64, s.sample_rate);
        var nch: usize = if (id_aac == elem_cpe) 2 else 1;
        const num_time_slots: u8 = if (m4ac.frame_length_short != 0) 15 else 16;
        if (id_aac != s.id_aac) s.turnoff(); // "element type mismatch"
        if (s.start and !s.ready_for_dequant) s.turnoff(); // "No quantized data read for sbr_dequant."
        if (!s.kx_and_m_pushed) {
            s.kx[0] = s.kx[1];
            s.m[0] = s.m[1];
        } else s.kx_and_m_pushed = false;
        if (s.start) {
            s.dequant(id_aac);
            s.ready_for_dequant = false;
        }
        for (0..nch) |ch| {
            const d = &s.data[ch];
            const input: *const [2048]f32 = if (ch != 0) r else l;
            s.qmfAnalysis(input[0 .. @as(usize, num_time_slots) * 64], d, num_time_slots);
            s.lfGen(&d.w, d.ypos, num_time_slots);
            d.ypos ^= 1;
            if (s.start) {
                s.hfInverseFilter(s.k[0]);
                s.chirp(d);
                std.debug.assert(d.bs_num_env > 0);
                s.hfGen(d);
                if (s.mapping(d)) {
                    s.envEstimate(d);
                    s.gainCalc(d);
                    s.hfAssemble(&d.y[d.ypos], d);
                }
            }
            s.xGen(ch, &d.y[1 - d.ypos], &d.y[d.ypos], num_time_slots);
        }
        if (m4ac.ps == 1) {
            if (s.ps != null and s.ps.?.common.start) {
                s.ps.?.apply(&s.x[0], &s.x[1], s.kx[1] + s.m[1]);
            } else {
                // Without PS data, FFmpeg's copy.
                s.x[1] = s.x[0];
            }
            nch = 2;
        }
        s.qmfSynthesis(l, 0, num_time_slots, downsampled);
        if (nch == 2) s.qmfSynthesis(r, 1, num_time_slots, downsampled);
    }

    /// sbr_qmf_analysis: the 32-band analysis of `in` into `d.w[d.ypos]`.
    fn qmfAnalysis(s: *Sbr, in: []const f32, d: *SbrData, num_time_slots: u8) void {
        const nb = @as(usize, num_time_slots) * 64;
        const x = &d.analysis_filterbank_samples;
        std.mem.copyForwards(f32, x[0 .. 320 - 32], x[nb..][0 .. 320 - 32]);
        @memcpy(x[288..][0..nb], in);
        const z = &s.qmf_filter_scratch;
        for (0..@as(usize, num_time_slots) * 2) |i| {
            float_dsp.fmulReverse(z[0..320], &tab.qmf_window_ds, x[i * 32 ..][0..320], 320);
            sum64x5(z);
            qmfPreShuffle(z);
            s.mdct_ana.run(z[0..64], z[64..128]);
            qmfPostShuffle(&d.w[d.ypos][i], z[0..64]);
        }
    }

    /// sbr_qmf_synthesis: the 64-band synthesis (32-band when downsampled)
    /// of `s.x[ch]` into `out`.
    fn qmfSynthesis(s: *Sbr, out_buf: *[2048]f32, ch: usize, num_time_slots: u8, div: bool) void {
        const d = &s.data[ch];
        const x = &s.x[ch];
        const window: []const f32 = if (div) &tab.qmf_window_ds else &tab.qmf_window_us;
        const sh: u3 = @intFromBool(div);
        const step: usize = @as(usize, 128) >> sh;
        const v0 = &d.synthesis_filterbank_samples;
        const mdct_buf = &s.qmf_filter_scratch;
        var out: usize = 0;
        for (0..@as(usize, num_time_slots) * 2) |i| {
            if (d.synthesis_filterbank_samples_offset < step) {
                const saved_samples = @as(usize, 1280 - 128) >> sh;
                @memcpy(v0[synthesis_buf_size - saved_samples ..], v0[0..saved_samples]);
                d.synthesis_filterbank_samples_offset = synthesis_buf_size - saved_samples - step;
            } else d.synthesis_filterbank_samples_offset -= step;
            const v = v0[d.synthesis_filterbank_samples_offset..];
            if (div) {
                for (0..32) |n| {
                    x[0][i][n] = -x[0][i][n];
                    x[0][i][32 + n] = x[1][i][31 - n];
                }
                s.mdct.run(mdct_buf[0..64], &x[0][i]);
                qmfDeintNeg(v[0..64], mdct_buf[0..64]);
            } else {
                negOdd64(&x[1][i]);
                s.mdct.run(mdct_buf[0..64], &x[0][i]);
                s.mdct.run(mdct_buf[64..128], &x[1][i]);
                qmfDeintBfly(v[0..128], mdct_buf[64..128], mdct_buf[0..64]);
            }
            const len = @as(usize, 64) >> sh;
            const o = out_buf[out..][0..len];
            float_dsp.fmul(o, v[0..], window, len);
            const taps = [9][2]usize{ .{ 192, 64 }, .{ 256, 128 }, .{ 448, 192 }, .{ 512, 256 }, .{ 704, 320 }, .{ 768, 384 }, .{ 960, 448 }, .{ 1024, 512 }, .{ 1216, 576 } };
            for (taps) |t| float_dsp.fmulAdd(o, v[t[0] >> sh ..], window[t[1] >> sh ..], o, len);
            out += len;
        }
    }
};

/// `ceil(log2(index + 1))`.
const ceil_log2 = [6]u6{ 0, 1, 2, 2, 3, 3 };

/// exp2fi: 2^x for an integer x, correctly rounded.
fn exp2fi(x: i32) f32 {
    if (-126 <= x and x <= 128) return @bitCast(@as(u32, @bitCast(x + 127)) << 23);
    if (x > 128) return std.math.inf(f32);
    if (x > -150) return @bitCast(@as(u32, 1) << @intCast(x + 149));
    return 0;
}

/// make_bands: `bands.len` band widths from `start` to `stop` growing by
/// a constant factor, rounded as FFmpeg rounds them in float.
fn makeBands(bands: []i16, start: i32, stop: i32, num_bands: usize) void {
    const base = libm.powf(@as(f32, @floatFromInt(stop)) / @as(f32, @floatFromInt(start)), 1.0 / @as(f32, @floatFromInt(num_bands)));
    var prod: f32 = @floatFromInt(start);
    var previous = start;
    for (0..num_bands - 1) |k| {
        prod *= base;
        const present: i32 = @truncate(cconv.lrintf(prod));
        bands[k] = @truncate(present -% previous);
        previous = present;
    }
    bands[num_bands - 1] = @truncate(stop -% previous);
}

/// check_n_master: the band count and crossover band FFmpeg accepts.
fn checkNMaster(n_master: u32, bs_xover_band: u32) bool {
    const n: i32 = @bitCast(n_master);
    if (n <= 0) return false; // "Invalid n_master"
    // f_master holds 49 entries; FFmpeg's checks bound n_master by 48.
    if (n > 48) return false;
    if (bs_xover_band >= n_master) return false; // "crossover band index beyond array bounds"
    return true;
}

// ---- sbrdsp's C kernels ----

fn sumSquare(x: []const [2]f32) f32 {
    var sum0: f32 = 0.0;
    var sum1: f32 = 0.0;
    var i: usize = 0;
    while (i < x.len) : (i += 2) {
        sum0 += x[i][0] * x[i][0];
        sum1 += x[i][1] * x[i][1];
        sum0 += x[i + 1][0] * x[i + 1][0];
        sum1 += x[i + 1][1] * x[i + 1][1];
    }
    return sum0 + sum1;
}

fn negOdd64(x: *[64]f32) void {
    var i: usize = 1;
    while (i < 64) : (i += 4) {
        x[i] = flipSign(x[i]);
        x[i + 2] = flipSign(x[i + 2]);
    }
}

fn flipSign(v: f32) f32 {
    return @bitCast(@as(u32, @bitCast(v)) ^ (1 << 31));
}

fn sum64x5(z: *[320]f32) void {
    for (0..64) |k| z[k] = z[k] + z[k + 64] + z[k + 128] + z[k + 192] + z[k + 256];
}

fn qmfPreShuffle(z: *[320]f32) void {
    z[64] = z[0];
    z[65] = z[1];
    var k: usize = 1;
    while (k < 31) : (k += 2) {
        z[64 + 2 * k + 0] = flipSign(z[64 - k]);
        z[64 + 2 * k + 1] = z[k + 1];
        z[64 + 2 * k + 2] = flipSign(z[63 - k]);
        z[64 + 2 * k + 3] = z[k + 2];
    }
    z[64 + 2 * 31 + 0] = flipSign(z[64 - 31]);
    z[64 + 2 * 31 + 1] = z[31 + 1];
}

fn qmfPostShuffle(w: *[32][2]f32, z: *const [64]f32) void {
    var k: usize = 0;
    while (k < 32) : (k += 2) {
        w[k][0] = flipSign(z[63 - k]);
        w[k][1] = z[k];
        w[k + 1][0] = flipSign(z[62 - k]);
        w[k + 1][1] = z[k + 1];
    }
}

fn qmfDeintNeg(v: *[64]f32, src: *const [64]f32) void {
    for (0..32) |i| {
        v[i] = src[63 - 2 * i];
        v[63 - i] = flipSign(src[63 - 2 * i - 1]);
    }
}

fn qmfDeintBfly(v: *[128]f32, src0: *const [64]f32, src1: *const [64]f32) void {
    for (0..64) |i| {
        v[i] = src0[i] - src1[63 - i];
        v[127 - i] = src0[i] + src1[63 - i];
    }
}

/// sbr_autocorrelate_c, the unrolled form the reference build runs.
fn autocorrelate(x: *const [40][2]f32, phi: *[3][2][2]f32) void {
    var real_sum2 = x[0][0] * x[2][0] + x[0][1] * x[2][1];
    var imag_sum2 = x[0][0] * x[2][1] - x[0][1] * x[2][0];
    var real_sum1: f32 = 0.0;
    var imag_sum1: f32 = 0.0;
    var real_sum0: f32 = 0.0;
    for (1..38) |i| {
        real_sum0 += x[i][0] * x[i][0] + x[i][1] * x[i][1];
        real_sum1 += x[i][0] * x[i + 1][0] + x[i][1] * x[i + 1][1];
        imag_sum1 += x[i][0] * x[i + 1][1] - x[i][1] * x[i + 1][0];
        real_sum2 += x[i][0] * x[i + 2][0] + x[i][1] * x[i + 2][1];
        imag_sum2 += x[i][0] * x[i + 2][1] - x[i][1] * x[i + 2][0];
    }
    phi[0][1][0] = real_sum2;
    phi[0][1][1] = imag_sum2;
    phi[2][1][0] = real_sum0 + x[0][0] * x[0][0] + x[0][1] * x[0][1];
    phi[1][0][0] = real_sum0 + x[38][0] * x[38][0] + x[38][1] * x[38][1];
    phi[1][1][0] = real_sum1 + x[0][0] * x[1][0] + x[0][1] * x[1][1];
    phi[1][1][1] = imag_sum1 + x[0][0] * x[1][1] - x[0][1] * x[1][0];
    phi[0][0][0] = real_sum1 + x[38][0] * x[39][0] + x[38][1] * x[39][1];
    phi[0][0][1] = imag_sum1 + x[38][0] * x[39][1] - x[38][1] * x[39][0];
}

/// sbr_hf_gen_c on rows offset by ENVELOPE_ADJUSTMENT_OFFSET, as
/// sbr_hf_gen passes them: `x_high[i + 2]` for `i` in `start..end` from
/// `x_low[i]`, `x_low[i + 1]` and `x_low[i + 2]`.
fn hfGenKernel(x_high: *[40][2]f32, x_low: *const [40][2]f32, alpha0: [2]f32, alpha1: [2]f32, bw: f32, start: usize, end: usize) void {
    const alpha = [4]f32{ alpha1[0] * bw * bw, alpha1[1] * bw * bw, alpha0[0] * bw, alpha0[1] * bw };
    for (start..end) |i| {
        x_high[i + 2][0] = x_low[i][0] * alpha[0] - x_low[i][1] * alpha[1] + x_low[i + 1][0] * alpha[2] - x_low[i + 1][1] * alpha[3] + x_low[i + 2][0];
        x_high[i + 2][1] = x_low[i][1] * alpha[0] + x_low[i][0] * alpha[1] + x_low[i + 1][1] * alpha[2] + x_low[i + 1][0] * alpha[3] + x_low[i + 2][1];
    }
}

/// sbr_hf_apply_noise_0 to _3, by `indexsine`.
fn hfApplyNoise(y: [][2]f32, s_m: *const [48]f32, q_filt: []const f32, noise_in: u32, kx: u32, m_max: u32, indexsine: u32) void {
    const phi_sign: f32 = @floatFromInt(1 - 2 * @as(i32, @intCast(kx & 1)));
    var phi_sign0: f32 = undefined;
    var phi_sign1: f32 = undefined;
    switch (indexsine) {
        0 => {
            phi_sign0 = 1.0;
            phi_sign1 = 0.0;
        },
        1 => {
            phi_sign0 = 0.0;
            phi_sign1 = phi_sign;
        },
        2 => {
            phi_sign0 = -1.0;
            phi_sign1 = 0.0;
        },
        else => {
            phi_sign0 = 0.0;
            phi_sign1 = -phi_sign;
        },
    }
    var noise = noise_in;
    for (0..m_max) |m| {
        var y0 = y[m][0];
        var y1 = y[m][1];
        noise = (noise + 1) & 0x1ff;
        if (s_m[m] != 0) {
            y0 += s_m[m] * phi_sign0;
            y1 += s_m[m] * phi_sign1;
        } else {
            y0 += q_filt[m] * tab.noise_table[noise][0];
            y1 += q_filt[m] * tab.noise_table[noise][1];
        }
        y[m][0] = y0;
        y[m][1] = y1;
        phi_sign1 = -phi_sign1;
    }
}

const testing = std.testing;

test "exp2fi: normal, subnormal, overflowing and vanishing powers" {
    try testing.expectEqual(@as(f32, 1), exp2fi(0));
    try testing.expectEqual(@as(f32, 0x1p-126), exp2fi(-126));
    try testing.expectEqual(@as(f32, 0x1p-149), exp2fi(-149));
    try testing.expectEqual(@as(f32, 0), exp2fi(-150));
    try testing.expectEqual(std.math.inf(f32), exp2fi(129));
    // FFmpeg's normal range reaches 128: the exponent field 255, infinity.
    try testing.expectEqual(std.math.inf(f32), exp2fi(128));
}

test "make_bands: widths that sum to the span, from FFmpeg's float steps" {
    var bands: [13]i16 = undefined;
    makeBands(&bands, 32, 64, 13);
    var sum: i32 = 0;
    for (bands) |b| sum += b;
    try testing.expectEqual(32, sum);
    var one: [1]i16 = undefined;
    makeBands(&one, 10, 20, 1);
    try testing.expectEqual(10, one[0]);
}

test "a state starts in pure upsampling mode; parametric stereo data allocates its state" {
    const gpa = testing.allocator;
    const s = try Sbr.create(gpa, elem_sce);
    defer s.destroy(gpa);
    try testing.expect(!s.start);
    try testing.expectEqual(32, s.kx[1]);
    try testing.expectEqual(0, s.kx[0]);
    try testing.expectEqual(SpectrumParameters.unset, s.spectrum_params);
    // Signalled absent: skipped, nothing allocated.
    var r = try bits.BitReader.init(&.{ 0xff, 0xff });
    var left: i64 = 6;
    try s.readExtension(&r, extension_id_ps, &left, 0);
    try testing.expectEqual(0, left);
    try testing.expectEqual(null, s.ps);
    // An all-ones header: iid_mode 7 is reserved, so the data fails and
    // its bits are skipped.
    left = 12;
    try s.readExtension(&r, extension_id_ps, &left, -1);
    try testing.expectEqual(0, left);
    try testing.expect(!s.ps.?.common.start);
}
