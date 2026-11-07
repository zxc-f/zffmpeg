// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aacps_common.c (read_iid_data,
// read_icc_data, read_ipdopd_data, ps_read_extension_data,
// ff_ps_read_data), aacps.c (hybrid2_re, hybrid6_cx, hybrid4_8_12_cx,
// hybrid_analysis, hybrid_synthesis, the map_idx and map_val functions,
// decorrelation, remap34, remap20, stereo_processing, ff_ps_apply),
// aacps_tablegen.h (ps_tableinit, make_filters_from_proto) and
// aacpsdsp_template.c (the C kernels) at the pinned reference revision,
// float build.
// Copyright (c) 2010 Alex Converse <alex.converse@gmail.com>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float parametric stereo decoder (TODO.md T30d), HE-AAC v2: the
//! PS data of an SBR extension (inter-channel intensity and coherence, and
//! phase differences, per envelope and band), then each frame's hybrid
//! analysis of the mono QMF signal, its decorrelated copy through the
//! all-pass chain with transient attenuation, the stereo mixing matrices
//! interpolated across envelopes, and the hybrid synthesis of left and
//! right, operation for operation as the pinned decoder computes them.
//! The tables are `ps_tableinit`'s, computed with the reference platform's
//! glibc functions (core/libm.zig).

const std = @import("std");
const bits = @import("bits.zig");
const vlc = @import("vlc.zig");
const tab = @import("ps_tab.zig");
const libm = @import("../core/libm.zig");

const max_num_env = 5;
const max_nr_iidicc = 34;
const max_nr_ipdopd = 17;
const max_ssb = 91;
const max_ap_bands = 50;
const qmf_time_slots = 32;
const max_delay = 14;
const ap_links = 3;
const max_ap_delay = 5;
const num_qmf_slots = 32;

const num_env_tab = [2][4]u8{ .{ 0, 1, 2, 4 }, .{ 1, 2, 3, 4 } };
const nr_iidicc_par_tab = [6]u8{ 10, 20, 34, 10, 20, 34 };
const nr_iidopd_par_tab = [6]u8{ 5, 11, 17, 5, 11, 17 };
/// `huff_iid`: the IID code by 2 * dt + iid_quant.
const huff_iid = [4]tab.Huff{ .iid_df0, .iid_df1, .iid_dt0, .iid_dt1 };

const nr_par_bands = [2]usize{ 20, 34 };
const nr_ipdopd_bands = [2]usize{ 11, 17 };
const nr_bands = [2]usize{ 71, 91 };
const decay_cutoff = [2]i32{ 10, 32 };
const nr_allpass_bands = [2]usize{ 30, 50 };
const short_delay_band = [2]usize{ 42, 62 };

const Par = [max_num_env][max_nr_iidicc]i8;

/// `PSCommonContext`: the bitstream state.
pub const Common = struct {
    start: bool = false,
    enable_iid: bool = false,
    iid_quant: u1 = 0,
    nr_iid_par: u8 = 0,
    nr_ipdopd_par: u8 = 0,
    enable_icc: bool = false,
    icc_mode: u32 = 0,
    nr_icc_par: u8 = 0,
    enable_ext: bool = false,
    frame_class: u1 = 0,
    num_env_old: u32 = 0,
    num_env: u32 = 0,
    enable_ipdopd: bool = false,
    border_position: [max_num_env + 1]i32 = @splat(0),
    iid_par: Par = @splat(@splat(0)),
    icc_par: Par = @splat(@splat(0)),
    ipd_par: Par = @splat(@splat(0)),
    opd_par: Par = @splat(@splat(0)),
    is34bands: bool = false,
    is34bands_old: bool = false,

    /// ff_ps_read_data: the PS data of an SBR extension, read from a copy
    /// of the host's reader, which moves past what it used (or
    /// `bits_left` on failure); the bits used.
    pub fn readData(ps: *Common, host: *bits.BitReader, bits_left: i64) i64 {
        var gbc = host.*;
        const r = &gbc;
        const bit_count_start: i64 = @intCast(r.count());
        const header = r.bit() != 0;
        if (ps.readBody(r, header)) {
            if (header) ps.start = true;
            const bits_consumed = @as(i64, @intCast(r.count())) - bit_count_start;
            if (bits_consumed <= bits_left) {
                host.skipLong(bits_consumed);
                return bits_consumed;
            }
            // "Expected to read %d PS bits actually read %d."
        }
        ps.start = false;
        host.skipLong(bits_left);
        ps.iid_par = @splat(@splat(0));
        ps.icc_par = @splat(@splat(0));
        ps.ipd_par = @splat(@splat(0));
        ps.opd_par = @splat(@splat(0));
        return bits_left;
    }

    /// The body of ff_ps_read_data up to its `err` label: false where it
    /// jumps there.
    fn readBody(ps: *Common, r: *bits.BitReader, header: bool) bool {
        if (header) { // enable_ps_header
            ps.enable_iid = r.bit() != 0;
            if (ps.enable_iid) {
                const iid_mode = r.bits(3);
                if (iid_mode > 5) return false; // "iid_mode %d is reserved."
                ps.nr_iid_par = nr_iidicc_par_tab[iid_mode];
                ps.iid_quant = @intFromBool(iid_mode > 2);
                ps.nr_ipdopd_par = nr_iidopd_par_tab[iid_mode];
            }
            ps.enable_icc = r.bit() != 0;
            if (ps.enable_icc) {
                ps.icc_mode = r.bits(3);
                if (ps.icc_mode > 5) return false; // "icc_mode %d is reserved."
                ps.nr_icc_par = nr_iidicc_par_tab[ps.icc_mode];
            }
            ps.enable_ext = r.bit() != 0;
        }
        ps.frame_class = r.bit();
        ps.num_env_old = ps.num_env;
        ps.num_env = num_env_tab[ps.frame_class][r.bits(2)];
        ps.border_position[0] = -1;
        if (ps.frame_class != 0) {
            for (1..ps.num_env + 1) |e| {
                ps.border_position[e] = @intCast(r.bits(5));
                if (ps.border_position[e] < ps.border_position[e - 1]) return false; // "border_position non monotone."
            }
        } else {
            for (1..ps.num_env + 1) |e| {
                const log2_env: u5 = std.math.log2_int(u32, ps.num_env);
                ps.border_position[e] = (@as(i32, @intCast(e)) * num_qmf_slots >> log2_env) - 1;
            }
        }
        if (ps.enable_iid) {
            for (0..ps.num_env) |e| {
                const dt = r.bit();
                if (!readPar(r, ps, &ps.iid_par, ps.nr_iid_par, huff_iid[2 * @as(usize, dt) + ps.iid_quant], e, dt != 0, .iid)) return false;
            }
        } else ps.iid_par = @splat(@splat(0));
        if (ps.enable_icc) {
            for (0..ps.num_env) |e| {
                const dt = r.bit();
                if (!readPar(r, ps, &ps.icc_par, ps.nr_icc_par, if (dt != 0) .icc_dt else .icc_df, e, dt != 0, .icc)) return false;
            }
        } else ps.icc_par = @splat(@splat(0));
        if (ps.enable_ext) {
            var cnt: i64 = r.bits(4);
            if (cnt == 15) cnt += r.bits(8);
            cnt *= 8;
            while (cnt > 7) {
                const ps_extension_id = r.bits(2);
                cnt -= 2 + ps.readExtensionData(r, ps_extension_id);
            }
            if (cnt < 0) return false; // "ps extension overflow %d"
            r.skip(@intCast(cnt));
        }
        // Not PS_BASELINE: enable_ipdopd stays.
        // Fix up envelopes.
        if (ps.num_env == 0 or ps.border_position[ps.num_env] < num_qmf_slots - 1) {
            // A fake envelope.
            const source: i64 = if (ps.num_env != 0) @as(i64, ps.num_env) - 1 else @as(i64, ps.num_env_old) - 1;
            if (source >= 0 and source != ps.num_env) {
                const src: usize = @intCast(source);
                if (ps.enable_iid) ps.iid_par[ps.num_env] = ps.iid_par[src];
                if (ps.enable_icc) ps.icc_par[ps.num_env] = ps.icc_par[src];
                if (ps.enable_ipdopd) {
                    ps.ipd_par[ps.num_env] = ps.ipd_par[src];
                    ps.opd_par[ps.num_env] = ps.opd_par[src];
                }
            }
            if (ps.enable_iid) {
                for (ps.iid_par[ps.num_env][0..ps.nr_iid_par]) |v| {
                    if (@abs(@as(i32, v)) > 7 + 8 * @as(i32, ps.iid_quant)) return false; // "iid_par invalid"
                }
            }
            if (ps.enable_icc) {
                // FFmpeg's loop runs to nr_iid_par.
                for (ps.icc_par[ps.num_env][0..ps.nr_iid_par]) |v| {
                    if (@as(u8, @bitCast(v)) > 7) return false; // "icc_par invalid"
                }
            }
            ps.num_env += 1;
            ps.border_position[ps.num_env] = num_qmf_slots - 1;
        }
        ps.is34bands_old = ps.is34bands;
        if (ps.enable_iid or ps.enable_icc) {
            ps.is34bands = (ps.enable_iid and ps.nr_iid_par == 34) or (ps.enable_icc and ps.nr_icc_par == 34);
        }
        if (!ps.enable_ipdopd) {
            ps.ipd_par = @splat(@splat(0));
            ps.opd_par = @splat(@splat(0));
        }
        return true;
    }

    /// ps_read_extension_data: the bits read.
    fn readExtensionData(ps: *Common, r: *bits.BitReader, ps_extension_id: u32) i64 {
        const count: i64 = @intCast(r.count());
        if (ps_extension_id != 0) return 0;
        ps.enable_ipdopd = r.bit() != 0;
        if (ps.enable_ipdopd) {
            for (0..ps.num_env) |e| {
                var dt = r.bit();
                _ = readPar(r, ps, &ps.ipd_par, ps.nr_ipdopd_par, if (dt != 0) .ipd_dt else .ipd_df, e, dt != 0, .ipdopd);
                dt = r.bit();
                _ = readPar(r, ps, &ps.opd_par, ps.nr_ipdopd_par, if (dt != 0) .opd_dt else .opd_df, e, dt != 0, .ipdopd);
            }
        }
        r.skip(1); // reserved_ps
        return @as(i64, @intCast(r.count())) - count;
    }
};

const ParKind = enum { iid, icc, ipdopd };

/// READ_PAR_DATA's read_iid_data, read_icc_data and read_ipdopd_data:
/// envelope `e` of `par`, coded in time (from the previous envelope) or in
/// frequency; false where they fail ("illegal iid" or "illegal icc").
fn readPar(r: *bits.BitReader, ps: *const Common, par: *Par, num: u8, h: tab.Huff, e: usize, dt: bool, kind: ParKind) bool {
    const table = tab.huff_vlc[@backingInt(h)];
    const nb_bits = tab.vlcBits(h);
    const max_depth: u2 = switch (kind) {
        .iid => 3,
        .icc => 2,
        .ipdopd => 1,
    };
    var e_prev: i64 = if (e != 0) @as(i64, @intCast(e)) - 1 else @as(i64, ps.num_env_old) - 1;
    e_prev = @max(e_prev, 0);
    var acc: i32 = 0;
    for (0..num) |b| {
        const code = vlc.lookup(bits.BitReader, table, r, nb_bits, max_depth);
        var val: i32 = if (dt) @as(i32, par[@intCast(e_prev)][b]) + code else blk: {
            acc +%= code;
            break :blk acc;
        };
        if (kind == .ipdopd) val &= 0x07;
        if (!dt) acc = val;
        // Stored into an int8_t.
        par[e][b] = @truncate(val);
        switch (kind) {
            .iid => if (@abs(@as(i32, par[e][b])) > 7 + 8 * @as(i32, ps.iid_quant)) return false,
            .icc => if (@as(u8, @bitCast(par[e][b])) > 7) return false,
            .ipdopd => {},
        }
    }
    return true;
}

/// `ps_tableinit`'s tables, computed as FFmpeg computes them.
pub const Tables = struct {
    pd_re_smooth: [512]f32,
    pd_im_smooth: [512]f32,
    ha: [46][8][4]f32,
    hb: [46][8][4]f32,
    f20_0_8: [8][8][2]f32,
    f34_0_12: [12][8][2]f32,
    f34_1_8: [8][8][2]f32,
    f34_2_4: [4][8][2]f32,
    q_fract_allpass: [2][50][3][2]f32,
    phi_fract: [2][50][2]f32,

    pub fn init(t: *Tables) void {
        const sqrt1_2: f32 = std.math.sqrt1_2;
        const ipdopd_sin = [8]f32{ 0, sqrt1_2, 1, sqrt1_2, 0, -sqrt1_2, -1, -sqrt1_2 };
        const ipdopd_cos = [8]f32{ 1, sqrt1_2, 0, -sqrt1_2, -1, -sqrt1_2, 0, sqrt1_2 };
        for (0..8) |pd0| for (0..8) |pd1| for (0..8) |pd2| {
            const re_smooth = 0.25 * ipdopd_cos[pd0] + 0.5 * ipdopd_cos[pd1] + ipdopd_cos[pd2];
            const im_smooth = 0.25 * ipdopd_sin[pd0] + 0.5 * ipdopd_sin[pd1] + ipdopd_sin[pd2];
            // A float: the double quotient rounded.
            const pd_mag: f32 = @floatCast(1 / libm.hypot(im_smooth, re_smooth));
            t.pd_re_smooth[pd0 * 64 + pd1 * 8 + pd2] = re_smooth * pd_mag;
            t.pd_im_smooth[pd0 * 64 + pd1 * 8 + pd2] = im_smooth * pd_mag;
        };
        // Double constants stored as floats.
        const iid_par_dequant = comptime blk: {
            const d = [46]f64{
                0.05623413251903, 0.12589254117942, 0.19952623149689, 0.31622776601684,
                0.44668359215096, 0.63095734448019, 0.79432823472428, 1,
                1.25892541179417, 1.58489319246111, 2.23872113856834, 3.16227766016838,
                5.01187233627272, 7.94328234724282, 17.7827941003892, 0.00316227766017,
                0.00562341325190, 0.01,             0.01778279410039, 0.03162277660168,
                0.05623413251903, 0.07943282347243, 0.11220184543020, 0.15848931924611,
                0.22387211385683, 0.31622776601684, 0.39810717055350, 0.50118723362727,
                0.63095734448019, 0.79432823472428, 1,                1.25892541179417,
                1.58489319246111, 1.99526231496888, 2.51188643150958, 3.16227766016838,
                4.46683592150963, 6.30957344480193, 8.91250938133745, 12.5892541179417,
                17.7827941003892, 31.6227766016838, 56.2341325190349, 100,
                177.827941003892, 316.227766016837,
            };
            var f: [46]f32 = undefined;
            for (&f, d) |*o, v| o.* = @floatCast(v);
            break :blk f;
        };
        const icc_invq = comptime blk: {
            const d = [8]f64{ 1, 0.937, 0.84118, 0.60092, 0.36764, 0, -0.589, -1 };
            var f: [8]f32 = undefined;
            for (&f, d) |*o, v| o.* = @floatCast(v);
            break :blk f;
        };
        const acos_icc_invq = comptime blk: {
            const d = [8]f64{ 0, 0.35685527, 0.57133466, 0.92614472, 1.1943263, std.math.pi / 2.0, 2.2006171, std.math.pi };
            var f: [8]f32 = undefined;
            for (&f, d) |*o, v| o.* = @floatCast(v);
            break :blk f;
        };
        const sqrt2_f: f32 = std.math.sqrt2;
        for (0..46) |iid| {
            const c = iid_par_dequant[iid];
            const c1 = sqrt2_f / @sqrt(1.0 + c * c);
            const c2 = c * c1;
            for (0..8) |icc| {
                {
                    const alpha = 0.5 * acos_icc_invq[icc];
                    const beta = alpha * (c1 - c2) * sqrt1_2;
                    t.ha[iid][icc][0] = c2 * libm.cosf(beta + alpha);
                    t.ha[iid][icc][1] = c1 * libm.cosf(beta - alpha);
                    t.ha[iid][icc][2] = c2 * libm.sinf(beta + alpha);
                    t.ha[iid][icc][3] = c1 * libm.sinf(beta - alpha);
                }
                {
                    const rho = @max(icc_invq[icc], 0.05);
                    var alpha: f32 = 0.5 * libm.atan2f(2.0 * c * rho, c * c - 1.0);
                    var mu = c + 1.0 / c;
                    mu = @sqrt(1 + (4 * rho * rho - 4) / (mu * mu));
                    const gamma = libm.atanf(@sqrt((1.0 - mu) / (1.0 + mu)));
                    if (alpha < 0) alpha = @floatCast(@as(f64, alpha) + std.math.pi / 2.0);
                    const alpha_c = libm.cosf(alpha);
                    const alpha_s = libm.sinf(alpha);
                    const gamma_c = libm.cosf(gamma);
                    const gamma_s = libm.sinf(gamma);
                    const sqrt2: f64 = std.math.sqrt2;
                    t.hb[iid][icc][0] = @floatCast(sqrt2 * alpha_c * gamma_c);
                    t.hb[iid][icc][1] = @floatCast(sqrt2 * alpha_s * gamma_c);
                    t.hb[iid][icc][2] = @floatCast(-sqrt2 * alpha_s * gamma_s);
                    t.hb[iid][icc][3] = @floatCast(sqrt2 * alpha_c * gamma_s);
                }
            }
        }
        const f_center_20 = [10]i8{ -3, -1, 1, 3, 5, 7, 10, 14, 18, 22 };
        const f_center_34 = [32]i8{ 2, 6, 10, 14, 18, 22, 26, 30, 34, -10, -6, -2, 51, 57, 15, 21, 27, 33, 39, 45, 54, 66, 78, 42, 102, 66, 78, 90, 102, 114, 126, 90 };
        const fractional_delay_links = [3]f32{ 0.43, 0.75, 0.347 };
        const fractional_delay_gain: f32 = 0.39;
        for (0..2) |is34| {
            for (0..nr_allpass_bands[is34]) |k| {
                var f_center: f64 = undefined;
                if (is34 == 0) {
                    f_center = if (k < f_center_20.len) @as(f64, @floatFromInt(f_center_20[k])) * 0.125 else @as(f32, @floatFromInt(k)) - 6.5;
                } else {
                    f_center = if (k < f_center_34.len) @as(f64, @floatFromInt(f_center_34[k])) / 24.0 else @as(f32, @floatFromInt(k)) - 26.5;
                }
                for (0..ap_links) |m| {
                    const theta = -std.math.pi * @as(f64, fractional_delay_links[m]) * f_center;
                    t.q_fract_allpass[is34][k][m][0] = @floatCast(libm.cos(theta));
                    t.q_fract_allpass[is34][k][m][1] = @floatCast(libm.sin(theta));
                }
                const theta = -std.math.pi * @as(f64, fractional_delay_gain) * f_center;
                t.phi_fract[is34][k][0] = @floatCast(libm.cos(theta));
                t.phi_fract[is34][k][1] = @floatCast(libm.sin(theta));
            }
        }
        const g0_q8 = [7]f32{ 0.00746082949812, 0.02270420949825, 0.04546865930473, 0.07266113929591, 0.09885108575264, 0.11793710567217, 0.125 };
        const g0_q12 = [7]f32{ 0.04081179924692, 0.03812810994926, 0.05144908135699, 0.06399831151592, 0.07428313801106, 0.08100347892914, 0.08333333333333 };
        const g1_q8 = [7]f32{ 0.01565675600122, 0.03752716391991, 0.05417891378782, 0.08417044116767, 0.10307344158036, 0.12222452249753, 0.125 };
        const g2_q4 = [7]f32{ -0.05908211155639, -0.04871498374946, 0.0, 0.07778723915851, 0.16486303567403, 0.23279856662996, 0.25 };
        makeFiltersFromProto(&t.f20_0_8, &g0_q8);
        makeFiltersFromProto(&t.f34_0_12, &g0_q12);
        makeFiltersFromProto(&t.f34_1_8, &g1_q8);
        makeFiltersFromProto(&t.f34_2_4, &g2_q4);
    }
};

/// make_filters_from_proto.
fn makeFiltersFromProto(filter: anytype, proto: *const [7]f32) void {
    const bands = filter.len;
    for (0..bands) |q| {
        for (0..7) |n| {
            const theta = 2 * std.math.pi * (@as(f64, @floatFromInt(q)) + 0.5) * (@as(f64, @floatFromInt(n)) - 6) / @as(f64, @floatFromInt(bands));
            filter[q][n][0] = @floatCast(@as(f64, proto[n]) * libm.cos(theta));
            filter[q][n][1] = @floatCast(@as(f64, proto[n]) * -libm.sin(theta));
        }
    }
}

/// `g1_Q2`: hybrid2_re's filter.
const g1_q2 = [7]f32{ 0.0, 0.01899487526049, 0.0, -0.07293139167538, 0.0, 0.30596630545168, 0.5 };

/// The QMF matrix `sbr_apply` hands over: [re, im][slot][subband].
pub const Qmf = [2][38][64]f32;

/// `PSContext`, with its tables.
pub const Ps = struct {
    common: Common = .{},
    in_buf: [5][44][2]f32 = @splat(@splat(@splat(0))),
    delay: [max_ssb][qmf_time_slots + max_delay][2]f32 = @splat(@splat(@splat(0))),
    ap_delay: [max_ap_bands][ap_links][qmf_time_slots + max_ap_delay][2]f32 = @splat(@splat(@splat(@splat(0)))),
    peak_decay_nrg: [34]f32 = @splat(0),
    power_smooth: [34]f32 = @splat(0),
    peak_decay_diff_smooth: [34]f32 = @splat(0),
    h11: [2][max_num_env + 1][max_nr_iidicc]f32 = @splat(@splat(@splat(0))),
    h12: [2][max_num_env + 1][max_nr_iidicc]f32 = @splat(@splat(@splat(0))),
    h21: [2][max_num_env + 1][max_nr_iidicc]f32 = @splat(@splat(@splat(0))),
    h22: [2][max_num_env + 1][max_nr_iidicc]f32 = @splat(@splat(@splat(0))),
    lbuf: [91][32][2]f32 = @splat(@splat(@splat(0))),
    rbuf: [91][32][2]f32 = @splat(@splat(@splat(0))),
    opd_hist: [max_nr_iidicc]i8 = @splat(0),
    ipd_hist: [max_nr_iidicc]i8 = @splat(0),
    tables: Tables = undefined,

    pub fn create(gpa: std.mem.Allocator) error{OutOfMemory}!*Ps {
        const ps = try gpa.create(Ps);
        ps.* = .{};
        ps.tables.init();
        return ps;
    }

    /// ff_ps_apply: `l` and `r` from `l`'s mono QMF signal, over the
    /// subbands below `top`.
    pub fn apply(ps: *Ps, l: *Qmf, r: *Qmf, top_in: u32) void {
        const len = 32;
        const is34: usize = @intFromBool(ps.common.is34bands);
        const top = @as(usize, top_in) + nr_bands[is34] - 64;
        for (ps.delay[top..nr_bands[is34]]) |*row| row.* = @splat(@splat(0));
        if (top < nr_allpass_bands[is34]) {
            for (ps.ap_delay[top..nr_allpass_bands[is34]]) |*row| row.* = @splat(@splat(@splat(0)));
        }
        ps.hybridAnalysis(l, is34 != 0, len);
        ps.decorrelation(is34 != 0);
        ps.stereoProcessing(is34 != 0);
        hybridSynthesis(l, &ps.lbuf, is34 != 0, len);
        hybridSynthesis(r, &ps.rbuf, is34 != 0, len);
    }

    /// hybrid_analysis into `lbuf`.
    fn hybridAnalysis(ps: *Ps, l: *const Qmf, is34: bool, len: usize) void {
        const in = &ps.in_buf;
        const out = &ps.lbuf;
        for (0..5) |i| {
            for (0..38) |j| {
                in[i][j + 6][0] = l[0][j][i];
                in[i][j + 6][1] = l[1][j][i];
            }
        }
        const t = &ps.tables;
        if (is34) {
            hybrid4_8_12(&in[0], out[0..12], &t.f34_0_12, len);
            hybrid4_8_12(&in[1], out[12..20], &t.f34_1_8, len);
            hybrid4_8_12(&in[2], out[20..24], &t.f34_2_4, len);
            hybrid4_8_12(&in[3], out[24..28], &t.f34_2_4, len);
            hybrid4_8_12(&in[4], out[28..32], &t.f34_2_4, len);
            analysisIleave(out[27..], l, 5, len);
        } else {
            hybrid6(&in[0], out[0..6], &t.f20_0_8, len);
            hybrid2Re(&in[1], out[6..8], 1, len);
            hybrid2Re(&in[2], out[8..10], 0, len);
            analysisIleave(out[7..], l, 3, len);
        }
        for (in) |*row| @memcpy(row[0..6], row[32..38]);
    }

    /// decorrelation: `rbuf` from `lbuf`.
    fn decorrelation(ps: *Ps, is34: bool) void {
        const sel: usize = @intFromBool(is34);
        var power: [34][32]f32 = @splat(@splat(0));
        var transient_gain: [34][32]f32 = undefined;
        const transient_impact: f32 = 1.5;
        const a_smooth: f32 = 0.25;
        const k_to_i: []const u8 = if (is34) &tab.k_to_i_34 else &tab.k_to_i_20;
        const peak_decay_factor: f32 = 0.76592833836465;
        if (is34 != ps.common.is34bands_old) {
            ps.peak_decay_nrg = @splat(0);
            ps.power_smooth = @splat(0);
            ps.peak_decay_diff_smooth = @splat(0);
            ps.delay = @splat(@splat(@splat(0)));
            ps.ap_delay = @splat(@splat(@splat(@splat(0))));
        }
        const s = &ps.lbuf;
        const out = &ps.rbuf;
        for (0..nr_bands[sel]) |k| {
            const i = k_to_i[k];
            for (0..32) |n| power[i][n] += s[k][n][0] * s[k][n][0] + s[k][n][1] * s[k][n][1];
        }
        for (0..nr_par_bands[sel]) |i| {
            for (0..32) |n| {
                const decayed_peak = peak_decay_factor * ps.peak_decay_nrg[i];
                ps.peak_decay_nrg[i] = if (decayed_peak > power[i][n]) decayed_peak else power[i][n];
                ps.power_smooth[i] += a_smooth * (power[i][n] - ps.power_smooth[i]);
                ps.peak_decay_diff_smooth[i] += a_smooth * (ps.peak_decay_nrg[i] - power[i][n] - ps.peak_decay_diff_smooth[i]);
                const denom = transient_impact * ps.peak_decay_diff_smooth[i];
                transient_gain[i][n] = if (denom > ps.power_smooth[i]) ps.power_smooth[i] / denom else 1.0;
            }
        }
        var k: usize = 0;
        while (k < nr_allpass_bands[sel]) : (k += 1) {
            const b = k_to_i[k];
            var g_decay_slope: f32 = 1.0 - 0.05 * @as(f32, @floatFromInt(@as(i32, @intCast(k)) - decay_cutoff[sel]));
            g_decay_slope = std.math.clamp(g_decay_slope, 0.0, 1.0);
            shiftDelay(&ps.delay[k], &s[k]);
            for (&ps.ap_delay[k]) |*link| @memcpy(link[0..5], link[32..37]);
            decorrelate(&out[k], ps.delay[k][14 - 2 ..][0..32], &ps.ap_delay[k], ps.tables.phi_fract[sel][k], &ps.tables.q_fract_allpass[sel][k], &transient_gain[b], g_decay_slope);
        }
        while (k < short_delay_band[sel]) : (k += 1) {
            const i = k_to_i[k];
            shiftDelay(&ps.delay[k], &s[k]);
            mulPairSingle(&out[k], ps.delay[k][0..32], &transient_gain[i]);
        }
        while (k < nr_bands[sel]) : (k += 1) {
            const i = k_to_i[k];
            shiftDelay(&ps.delay[k], &s[k]);
            mulPairSingle(&out[k], ps.delay[k][14 - 1 ..][0..32], &transient_gain[i]);
        }
    }

    /// stereo_processing: the mixing of `lbuf` and `rbuf`.
    fn stereoProcessing(ps: *Ps, is34: bool) void {
        const sel: usize = @intFromBool(is34);
        const ps2 = &ps.common;
        var iid_mapped_buf: Par = undefined;
        var icc_mapped_buf: Par = undefined;
        var ipd_mapped_buf: Par = undefined;
        var opd_mapped_buf: Par = undefined;
        var iid_mapped: *const Par = &iid_mapped_buf;
        var icc_mapped: *const Par = &icc_mapped_buf;
        var ipd_mapped: *const Par = &ipd_mapped_buf;
        var opd_mapped: *const Par = &opd_mapped_buf;
        const k_to_i: []const u8 = if (is34) &tab.k_to_i_34 else &tab.k_to_i_20;
        const h_lut = if (ps2.icc_mode < 3) &ps.tables.ha else &ps.tables.hb;
        const hs = [4]*[2][max_num_env + 1][max_nr_iidicc]f32{ &ps.h11, &ps.h12, &ps.h21, &ps.h22 };
        if (ps2.num_env_old != 0) {
            for (hs) |hm| {
                hm[0][0] = hm[0][ps2.num_env_old];
                hm[1][0] = hm[1][ps2.num_env_old];
            }
        }
        if (is34) {
            iid_mapped = remap34(&iid_mapped_buf, &ps2.iid_par, ps2.nr_iid_par, ps2.num_env, true);
            icc_mapped = remap34(&icc_mapped_buf, &ps2.icc_par, ps2.nr_icc_par, ps2.num_env, true);
            if (ps2.enable_ipdopd) {
                ipd_mapped = remap34(&ipd_mapped_buf, &ps2.ipd_par, ps2.nr_ipdopd_par, ps2.num_env, false);
                opd_mapped = remap34(&opd_mapped_buf, &ps2.opd_par, ps2.nr_ipdopd_par, ps2.num_env, false);
            }
            if (!ps2.is34bands_old) {
                for (hs) |hm| {
                    mapVal20To34(&hm[0][0]);
                    mapVal20To34(&hm[1][0]);
                }
                ps.ipd_hist = @splat(0);
                ps.opd_hist = @splat(0);
            }
        } else {
            iid_mapped = remap20(&iid_mapped_buf, &ps2.iid_par, ps2.nr_iid_par, ps2.num_env, true);
            icc_mapped = remap20(&icc_mapped_buf, &ps2.icc_par, ps2.nr_icc_par, ps2.num_env, true);
            if (ps2.enable_ipdopd) {
                ipd_mapped = remap20(&ipd_mapped_buf, &ps2.ipd_par, ps2.nr_ipdopd_par, ps2.num_env, false);
                opd_mapped = remap20(&opd_mapped_buf, &ps2.opd_par, ps2.nr_ipdopd_par, ps2.num_env, false);
            }
            if (ps2.is34bands_old) {
                for (hs) |hm| {
                    mapVal34To20(&hm[0][0]);
                    mapVal34To20(&hm[1][0]);
                }
                ps.ipd_hist = @splat(0);
                ps.opd_hist = @splat(0);
            }
        }
        for (0..ps2.num_env) |e| {
            for (0..nr_par_bands[sel]) |b| {
                const row: usize = @intCast(@as(i32, iid_mapped[e][b]) + 7 + 23 * @as(i32, ps2.iid_quant));
                const col: usize = @intCast(icc_mapped[e][b]);
                const lut = h_lut[row][col];
                var h11 = lut[0];
                var h12 = lut[1];
                var h21 = lut[2];
                var h22 = lut[3];
                if (ps2.enable_ipdopd and b < nr_ipdopd_bands[sel]) {
                    const opd_idx: usize = @intCast(@as(i32, ps.opd_hist[b]) * 8 + opd_mapped[e][b]);
                    const ipd_idx: usize = @intCast(@as(i32, ps.ipd_hist[b]) * 8 + ipd_mapped[e][b]);
                    const opd_re = ps.tables.pd_re_smooth[opd_idx];
                    const opd_im = ps.tables.pd_im_smooth[opd_idx];
                    const ipd_re = ps.tables.pd_re_smooth[ipd_idx];
                    const ipd_im = ps.tables.pd_im_smooth[ipd_idx];
                    ps.opd_hist[b] = @intCast(opd_idx & 0x3f);
                    ps.ipd_hist[b] = @intCast(ipd_idx & 0x3f);
                    const ipd_adj_re = opd_re * ipd_re + opd_im * ipd_im;
                    const ipd_adj_im = opd_im * ipd_re - opd_re * ipd_im;
                    const h11i = h11 * opd_im;
                    h11 = h11 * opd_re;
                    const h12i = h12 * ipd_adj_im;
                    h12 = h12 * ipd_adj_re;
                    const h21i = h21 * opd_im;
                    h21 = h21 * opd_re;
                    const h22i = h22 * ipd_adj_im;
                    h22 = h22 * ipd_adj_re;
                    ps.h11[1][e + 1][b] = h11i;
                    ps.h12[1][e + 1][b] = h12i;
                    ps.h21[1][e + 1][b] = h21i;
                    ps.h22[1][e + 1][b] = h22i;
                }
                ps.h11[0][e + 1][b] = h11;
                ps.h12[0][e + 1][b] = h12;
                ps.h21[0][e + 1][b] = h21;
                ps.h22[0][e + 1][b] = h22;
            }
            for (0..nr_bands[sel]) |k| {
                var h: [2][4]f32 = undefined;
                var h_step: [2][4]f32 = undefined;
                const start = ps2.border_position[e];
                const stop = ps2.border_position[e + 1];
                const width: f32 = 1.0 / @as(f32, @floatFromInt(if (stop - start != 0) stop - start else 1));
                const b = k_to_i[k];
                for (hs, 0..) |hm, j| h[0][j] = hm[0][e][b];
                if (ps2.enable_ipdopd) {
                    const negate = (is34 and k <= 13 and k >= 9) or (!is34 and k <= 1);
                    for (hs, 0..) |hm, j| h[1][j] = if (negate) -hm[1][e][b] else hm[1][e][b];
                }
                for (hs, 0..) |hm, j| h_step[0][j] = (hm[0][e + 1][b] - h[0][j]) * width;
                if (ps2.enable_ipdopd) {
                    for (hs, 0..) |hm, j| h_step[1][j] = (hm[1][e + 1][b] - h[1][j]) * width;
                }
                if (stop - start != 0) {
                    const from: usize = @intCast(1 + start);
                    const n: usize = @intCast(stop - start);
                    if (ps2.enable_ipdopd)
                        stereoInterpolateIpdopd(ps.lbuf[k][from..][0..n], ps.rbuf[k][from..][0..n], h, h_step)
                    else
                        stereoInterpolate(ps.lbuf[k][from..][0..n], ps.rbuf[k][from..][0..n], h, h_step);
                }
            }
        }
    }
};

/// The delay line's last 14 slots to its start, then this frame's 32.
fn shiftDelay(delay: *[qmf_time_slots + max_delay][2]f32, s: *const [32][2]f32) void {
    @memcpy(delay[0..14], delay[32..46]);
    @memcpy(delay[14..46], s);
}

/// hybrid2_re.
fn hybrid2Re(in: *const [44][2]f32, out: *[2][32][2]f32, reverse: u1, len: usize) void {
    const filter = &g1_q2;
    for (0..len) |i| {
        const x = in[i..];
        const re_in = filter[6] * x[6][0];
        var re_op: f32 = 0.0;
        const im_in = filter[6] * x[6][1];
        var im_op: f32 = 0.0;
        var j: usize = 0;
        while (j < 6) : (j += 2) {
            re_op += filter[j + 1] * (x[j + 1][0] + x[12 - j - 1][0]);
            im_op += filter[j + 1] * (x[j + 1][1] + x[12 - j - 1][1]);
        }
        out[reverse][i] = .{ re_in + re_op, im_in + im_op };
        out[1 - reverse][i] = .{ re_in - re_op, im_in - im_op };
    }
}

/// hybrid6_cx.
fn hybrid6(in: *const [44][2]f32, out: *[6][32][2]f32, filter: *const [8][8][2]f32, len: usize) void {
    var temp: [8][2]f32 = undefined;
    for (0..len) |i| {
        hybridAnalysisKernel(&temp, 1, in[i..], filter, 8);
        out[0][i] = temp[6];
        out[1][i] = temp[7];
        out[2][i] = temp[0];
        out[3][i] = temp[1];
        out[4][i] = .{ temp[2][0] + temp[5][0], temp[2][1] + temp[5][1] };
        out[5][i] = .{ temp[3][0] + temp[4][0], temp[3][1] + temp[4][1] };
    }
}

/// hybrid4_8_12_cx: `out[q][i]` for each of the filter's bands.
fn hybrid4_8_12(in: *const [44][2]f32, out: [][32][2]f32, filter: anytype, len: usize) void {
    const n = filter.len;
    std.debug.assert(out.len == n);
    for (0..len) |i| {
        var temp: [12][2]f32 = undefined;
        hybridAnalysisKernel(temp[0..n], 1, in[i..], filter, n);
        for (0..n) |q| out[q][i] = temp[q];
    }
}

/// ps_hybrid_analysis_c (the stride is the caller's layout here).
fn hybridAnalysisKernel(out: [][2]f32, comptime stride: usize, in: []const [2]f32, filter: anytype, n: usize) void {
    comptime std.debug.assert(stride == 1);
    var inre0: [6]f32 = undefined;
    var inre1: [6]f32 = undefined;
    var inim0: [6]f32 = undefined;
    var inim1: [6]f32 = undefined;
    for (0..6) |j| {
        inre0[j] = in[j][0] + in[12 - j][0];
        inre1[j] = in[j][1] - in[12 - j][1];
        inim0[j] = in[j][1] + in[12 - j][1];
        inim1[j] = in[j][0] - in[12 - j][0];
    }
    for (0..n) |i| {
        var sum_re = filter[i][6][0] * in[6][0];
        var sum_im = filter[i][6][0] * in[6][1];
        for (0..6) |j| {
            sum_re += filter[i][j][0] * inre0[j] - filter[i][j][1] * inre1[j];
            sum_im += filter[i][j][0] * inim0[j] + filter[i][j][1] * inim1[j];
        }
        out[i] = .{ sum_re, sum_im };
    }
}

/// ps_hybrid_analysis_ileave_c: the QMF subbands from `first` on, as they
/// are, into `out[first..64]`.
fn analysisIleave(out: [][32][2]f32, l: *const Qmf, first: usize, len: usize) void {
    for (first..64) |i| {
        for (0..len) |j| out[i][j] = .{ l[0][j][i], l[1][j][i] };
    }
}

/// hybrid_synthesis: `out`'s first subbands from the hybrid bands, the
/// rest as they are.
fn hybridSynthesis(out: *Qmf, in: *const [91][32][2]f32, is34: bool, len: usize) void {
    if (is34) {
        for (0..len) |n| {
            for (0..5) |c| {
                out[0][n][c] = 0;
                out[1][n][c] = 0;
            }
            for (0..12) |i| {
                out[0][n][0] += in[i][n][0];
                out[1][n][0] += in[i][n][1];
            }
            for (0..8) |i| {
                out[0][n][1] += in[12 + i][n][0];
                out[1][n][1] += in[12 + i][n][1];
            }
            for (0..4) |i| {
                out[0][n][2] += in[20 + i][n][0];
                out[1][n][2] += in[20 + i][n][1];
                out[0][n][3] += in[24 + i][n][0];
                out[1][n][3] += in[24 + i][n][1];
                out[0][n][4] += in[28 + i][n][0];
                out[1][n][4] += in[28 + i][n][1];
            }
        }
        synthesisDeint(out, in[27..], 5, len);
    } else {
        for (0..len) |n| {
            out[0][n][0] = in[0][n][0] + in[1][n][0] + in[2][n][0] + in[3][n][0] + in[4][n][0] + in[5][n][0];
            out[1][n][0] = in[0][n][1] + in[1][n][1] + in[2][n][1] + in[3][n][1] + in[4][n][1] + in[5][n][1];
            out[0][n][1] = in[6][n][0] + in[7][n][0];
            out[1][n][1] = in[6][n][1] + in[7][n][1];
            out[0][n][2] = in[8][n][0] + in[9][n][0];
            out[1][n][2] = in[8][n][1] + in[9][n][1];
        }
        synthesisDeint(out, in[7..], 3, len);
    }
}

/// ps_hybrid_synthesis_deint_c.
fn synthesisDeint(out: *Qmf, in: []const [32][2]f32, first: usize, len: usize) void {
    for (first..64) |i| {
        for (0..len) |n| {
            out[0][n][i] = in[i][n][0];
            out[1][n][i] = in[i][n][1];
        }
    }
}

/// ps_decorrelate_c: the all-pass chain of one band.
fn decorrelate(out: *[32][2]f32, delay: *const [32][2]f32, ap_delay: *[ap_links][qmf_time_slots + max_ap_delay][2]f32, phi_fract: [2]f32, q_fract: *const [3][2]f32, transient_gain: *const [32]f32, g_decay_slope: f32) void {
    const a = [3]f32{ 0.65143905753106, 0.56471812200776, 0.48954165955695 };
    var ag: [3]f32 = undefined;
    for (&ag, a) |*g, v| g.* = v * g_decay_slope;
    for (0..32) |n| {
        var in_re = delay[n][0] * phi_fract[0] - delay[n][1] * phi_fract[1];
        var in_im = delay[n][0] * phi_fract[1] + delay[n][1] * phi_fract[0];
        for (0..3) |m| {
            const a_re = ag[m] * in_re;
            const a_im = ag[m] * in_im;
            const link_delay_re = ap_delay[m][n + 2 - m][0];
            const link_delay_im = ap_delay[m][n + 2 - m][1];
            const fractional_delay_re = q_fract[m][0];
            const fractional_delay_im = q_fract[m][1];
            const apd_re = in_re;
            const apd_im = in_im;
            in_re = link_delay_re * fractional_delay_re - link_delay_im * fractional_delay_im;
            in_re -= a_re;
            in_im = link_delay_re * fractional_delay_im + link_delay_im * fractional_delay_re;
            in_im -= a_im;
            ap_delay[m][n + 5][0] = apd_re + ag[m] * in_re;
            ap_delay[m][n + 5][1] = apd_im + ag[m] * in_im;
        }
        out[n] = .{ transient_gain[n] * in_re, transient_gain[n] * in_im };
    }
}

/// ps_mul_pair_single_c.
fn mulPairSingle(dst: *[32][2]f32, src0: *const [32][2]f32, src1: *const [32]f32) void {
    for (0..32) |i| dst[i] = .{ src0[i][0] * src1[i], src0[i][1] * src1[i] };
}

/// ps_stereo_interpolate_c.
fn stereoInterpolate(l: [][2]f32, r: [][2]f32, h: [2][4]f32, h_step: [2][4]f32) void {
    var h0 = h[0][0];
    var h1 = h[0][1];
    var h2 = h[0][2];
    var h3 = h[0][3];
    for (l, r) |*lv, *rv| {
        const l_re = lv[0];
        const l_im = lv[1];
        const r_re = rv[0];
        const r_im = rv[1];
        h0 += h_step[0][0];
        h1 += h_step[0][1];
        h2 += h_step[0][2];
        h3 += h_step[0][3];
        lv.* = .{ h0 * l_re + h2 * r_re, h0 * l_im + h2 * r_im };
        rv.* = .{ h1 * l_re + h3 * r_re, h1 * l_im + h3 * r_im };
    }
}

/// ps_stereo_interpolate_ipdopd_c.
fn stereoInterpolateIpdopd(l: [][2]f32, r: [][2]f32, h: [2][4]f32, h_step: [2][4]f32) void {
    var h00 = h[0][0];
    var h10 = h[1][0];
    var h01 = h[0][1];
    var h11 = h[1][1];
    var h02 = h[0][2];
    var h12 = h[1][2];
    var h03 = h[0][3];
    var h13 = h[1][3];
    for (l, r) |*lv, *rv| {
        const l_re = lv[0];
        const l_im = lv[1];
        const r_re = rv[0];
        const r_im = rv[1];
        h00 += h_step[0][0];
        h01 += h_step[0][1];
        h02 += h_step[0][2];
        h03 += h_step[0][3];
        h10 += h_step[1][0];
        h11 += h_step[1][1];
        h12 += h_step[1][2];
        h13 += h_step[1][3];
        lv.* = .{ h00 * l_re + h02 * r_re - h10 * l_im - h12 * r_im, h00 * l_im + h02 * r_im + h10 * l_re + h12 * r_re };
        rv.* = .{ h01 * l_re + h03 * r_re - h11 * l_im - h13 * r_im, h01 * l_im + h03 * r_im + h11 * l_re + h13 * r_re };
    }
}

// ---- Parameter maps ----

fn remap34(buf: *Par, par: *const Par, num_par: u8, num_env: u32, full: bool) *const Par {
    if (num_par == 20 or num_par == 11) {
        for (0..num_env) |e| mapIdx20To34(&buf[e], &par[e], full);
    } else if (num_par == 10 or num_par == 5) {
        for (0..num_env) |e| mapIdx10To34(&buf[e], &par[e], full);
    } else return par;
    return buf;
}

fn remap20(buf: *Par, par: *const Par, num_par: u8, num_env: u32, full: bool) *const Par {
    if (num_par == 34 or num_par == 17) {
        for (0..num_env) |e| mapIdx34To20(&buf[e], &par[e], full);
    } else if (num_par == 10 or num_par == 5) {
        for (0..num_env) |e| mapIdx10To20(&buf[e], &par[e], full);
    } else return par;
    return buf;
}

fn mapIdx10To20(pm: *[34]i8, par: *const [34]i8, full: bool) void {
    var b: usize = if (full) 9 else 4;
    if (!full) pm[10] = 0;
    while (true) : (b -= 1) {
        pm[2 * b + 1] = par[b];
        pm[2 * b] = par[b];
        if (b == 0) break;
    }
}

/// C's int8 arithmetic: the sum in int, divided toward zero, stored.
fn avg(sum: i32, n: i32) i8 {
    return @truncate(@divTrunc(sum, n));
}

fn mapIdx34To20(pm: *[34]i8, p: *const [34]i8, full: bool) void {
    pm[0] = avg(2 * @as(i32, p[0]) + p[1], 3);
    pm[1] = avg(@as(i32, p[1]) + 2 * @as(i32, p[2]), 3);
    pm[2] = avg(2 * @as(i32, p[3]) + p[4], 3);
    pm[3] = avg(@as(i32, p[4]) + 2 * @as(i32, p[5]), 3);
    pm[4] = avg(@as(i32, p[6]) + p[7], 2);
    pm[5] = avg(@as(i32, p[8]) + p[9], 2);
    pm[6] = p[10];
    pm[7] = p[11];
    pm[8] = avg(@as(i32, p[12]) + p[13], 2);
    pm[9] = avg(@as(i32, p[14]) + p[15], 2);
    pm[10] = p[16];
    if (full) {
        pm[11] = p[17];
        pm[12] = p[18];
        pm[13] = p[19];
        pm[14] = avg(@as(i32, p[20]) + p[21], 2);
        pm[15] = avg(@as(i32, p[22]) + p[23], 2);
        pm[16] = avg(@as(i32, p[24]) + p[25], 2);
        pm[17] = avg(@as(i32, p[26]) + p[27], 2);
        pm[18] = avg(@as(i32, p[28]) + p[29] + p[30] + p[31], 4);
        pm[19] = avg(@as(i32, p[32]) + p[33], 2);
    }
}

fn mapIdx10To34(pm: *[34]i8, p: *const [34]i8, full: bool) void {
    if (full) {
        for (28..34) |i| pm[i] = p[9];
        for (24..28) |i| pm[i] = p[8];
        for (20..24) |i| pm[i] = p[7];
        pm[19] = p[6];
        pm[18] = p[6];
        pm[17] = p[5];
        pm[16] = p[5];
    } else pm[16] = 0;
    for (12..16) |i| pm[i] = p[4];
    pm[11] = p[3];
    pm[10] = p[3];
    for (6..10) |i| pm[i] = p[2];
    for (3..6) |i| pm[i] = p[1];
    for (0..3) |i| pm[i] = p[0];
}

fn mapIdx20To34(pm: *[34]i8, p: *const [34]i8, full: bool) void {
    if (full) {
        pm[33] = p[19];
        pm[32] = p[19];
        for (28..32) |i| pm[i] = p[18];
        pm[27] = p[17];
        pm[26] = p[17];
        pm[25] = p[16];
        pm[24] = p[16];
        pm[23] = p[15];
        pm[22] = p[15];
        pm[21] = p[14];
        pm[20] = p[14];
        pm[19] = p[13];
        pm[18] = p[12];
        pm[17] = p[11];
    }
    pm[16] = p[10];
    pm[15] = p[9];
    pm[14] = p[9];
    pm[13] = p[8];
    pm[12] = p[8];
    pm[11] = p[7];
    pm[10] = p[6];
    pm[9] = p[5];
    pm[8] = p[5];
    pm[7] = p[4];
    pm[6] = p[4];
    pm[5] = p[3];
    pm[4] = avg(@as(i32, p[2]) + p[3], 2);
    pm[3] = p[2];
    pm[2] = p[1];
    pm[1] = avg(@as(i32, p[0]) + p[1], 2);
    pm[0] = p[0];
}

fn mapVal34To20(p: *[34]f32) void {
    p[0] = (2 * p[0] + p[1]) * 0.33333333;
    p[1] = (p[1] + 2 * p[2]) * 0.33333333;
    p[2] = (2 * p[3] + p[4]) * 0.33333333;
    p[3] = (p[4] + 2 * p[5]) * 0.33333333;
    p[4] = (p[6] + p[7]) * 0.5;
    p[5] = (p[8] + p[9]) * 0.5;
    p[6] = p[10];
    p[7] = p[11];
    p[8] = (p[12] + p[13]) * 0.5;
    p[9] = (p[14] + p[15]) * 0.5;
    p[10] = p[16];
    p[11] = p[17];
    p[12] = p[18];
    p[13] = p[19];
    p[14] = (p[20] + p[21]) * 0.5;
    p[15] = (p[22] + p[23]) * 0.5;
    p[16] = (p[24] + p[25]) * 0.5;
    p[17] = (p[26] + p[27]) * 0.5;
    p[18] = (p[28] + p[29] + p[30] + p[31]) * 0.25;
    p[19] = (p[32] + p[33]) * 0.5;
}

fn mapVal20To34(p: *[34]f32) void {
    p[33] = p[19];
    p[32] = p[19];
    p[31] = p[18];
    p[30] = p[18];
    p[29] = p[18];
    p[28] = p[18];
    p[27] = p[17];
    p[26] = p[17];
    p[25] = p[16];
    p[24] = p[16];
    p[23] = p[15];
    p[22] = p[15];
    p[21] = p[14];
    p[20] = p[14];
    p[19] = p[13];
    p[18] = p[12];
    p[17] = p[11];
    p[16] = p[10];
    p[15] = p[9];
    p[14] = p[9];
    p[13] = p[8];
    p[12] = p[8];
    p[11] = p[7];
    p[10] = p[6];
    p[9] = p[5];
    p[8] = p[5];
    p[7] = p[4];
    p[6] = p[4];
    p[5] = p[3];
    p[4] = (p[2] + p[3]) * 0.5;
    p[3] = p[2];
    p[2] = p[1];
    p[1] = (p[0] + p[1]) * 0.5;
}

const testing = std.testing;

test "the VLC tables fill FFmpeg's buffer exactly" {
    const sizes = [10]usize{ 1544, 832, 1024, 1036, 544, 544, 32, 32, 32, 32 };
    var total: usize = 0;
    for (tab.huff_vlc, sizes) |t, n| {
        try testing.expectEqual(n, t.len);
        total += t.len;
    }
    try testing.expectEqual((1544 + 832 + 1024 + 1036) + (544 + 544) + (32 + 32 + 32 + 32), total);
}
